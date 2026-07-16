// GitRunnerTests.swift
//
// Tests für die git-Pfad-Auflösung (Projekt- & Git-Ausbau, Etappe 2).
// Der Prozess-Aufruf selbst wird end-to-end vom Selbsttest `git` abgedeckt;
// hier die reine, dialogsichere Auswahl-Logik.

import Foundation
import Testing
@testable import Fastra

/// FileManager-Stub, der nur die als „ausführbar" markierten Pfade bejaht.
private final class StubFileManager: FileManager {
    let executables: Set<String>
    init(executables: Set<String>) { self.executables = executables; super.init() }
    override func isExecutableFile(atPath path: String) -> Bool {
        executables.contains(path)
    }
}

@Test("Homebrew-git hat Vorrang vor CLT")
func gitPath_prefersHomebrew() {
    let fm = StubFileManager(executables: [
        "/opt/homebrew/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
    ])
    let path = GitRunner.resolvePath(candidates: GitRunner.candidatePaths,
                                     developerDir: nil, fileManager: fm)
    #expect(path == "/opt/homebrew/bin/git")
}

@Test("Nur CLT-git vorhanden → CLT-Pfad (nie /usr/bin/git-Stub)")
func gitPath_cltOnly() {
    let fm = StubFileManager(executables: ["/Library/Developer/CommandLineTools/usr/bin/git"])
    let path = GitRunner.resolvePath(candidates: GitRunner.candidatePaths,
                                     developerDir: nil, fileManager: fm)
    #expect(path == "/Library/Developer/CommandLineTools/usr/bin/git")
}

@Test("Kein git → nil (Funktionen bleiben still weg)")
func gitPath_none() {
    let fm = StubFileManager(executables: [])
    let path = GitRunner.resolvePath(candidates: GitRunner.candidatePaths,
                                     developerDir: nil, fileManager: fm)
    #expect(path == nil)
}

@Test("Xcode-only-Setup: git aus dem Developer-Ordner")
func gitPath_xcodeFallback() {
    let dev = "/Applications/Xcode.app/Contents/Developer"
    let fm = StubFileManager(executables: ["\(dev)/usr/bin/git"])
    let path = GitRunner.resolvePath(candidates: GitRunner.candidatePaths,
                                     developerDir: dev, fileManager: fm)
    #expect(path == "\(dev)/usr/bin/git")
}

@Test("/usr/bin/git ist NIE ein Kandidat (Stub-Dialog-Vermeidung)")
func gitPath_neverUsrBinStub() {
    #expect(!GitRunner.candidatePaths.contains("/usr/bin/git"))
}

private func temporaryExecutable(_ body: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Fastra-GitRunner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("fixture")
    try Data(("#!/bin/zsh\n" + body).utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                          ofItemAtPath: script.path)
    return script
}

private func execute(_ executable: URL, arguments: [String] = [],
                     limit: GitOutputLimit = .default,
                     policy: GitExecutionPolicy = .default) async -> GitExecutionOutcome {
    await withCheckedContinuation { continuation in
        GitRunner.runExecutable(executable, arguments: arguments,
                                in: executable.deletingLastPathComponent(),
                                outputLimit: limit, policy: policy) {
            continuation.resume(returning: $0)
        }
    }
}

private final class ExecutableTestExecutor: GitCommandExecuting {
    let executable: URL
    init(_ executable: URL) { self.executable = executable }

    func execute(arguments: [String], in directory: URL,
                 outputLimit: GitOutputLimit, policy: GitExecutionPolicy,
                 completion: @escaping (GitExecutionOutcome) -> Void) -> GitCancelling {
        GitRunner.runExecutable(executable, arguments: arguments, in: directory,
                                outputLimit: outputLimit, policy: policy,
                                completion: completion)
    }
}

@Test("stdout und stderr werden gleichzeitig ohne Pipe-Deadlock geleert",
      .timeLimit(.minutes(1)))
func gitRunner_drainsBothPipesConcurrently() async throws {
    let script = try temporaryExecutable("""
    i=0
    while (( i < 20000 )); do
      print -r -- 'OOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO'
      print -r -- 'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE' >&2
      (( i += 1 ))
    done
    """)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let outcome = await execute(script)
    guard case .completed(let result) = outcome else {
        Issue.record("Fixture konnte nicht gestartet werden")
        return
    }
    #expect(result.exitCode == 0)
    #expect(result.stdoutData.count > 1_000_000)
    #expect(result.stderrData.count > 1_000_000)
    #expect(!result.stdoutWasTruncated)
    #expect(!result.stderrWasTruncated)
}

@Test("Rohe Ausgabe wird begrenzt, die Ausführung endet trotzdem")
func gitRunner_limitsRetainedOutput() async throws {
    let script = try temporaryExecutable("""
    i=0
    while (( i < 2000 )); do
      print -r -- '012345678901234567890123456789012345678901234567890123456789'
      (( i += 1 ))
    done
    """)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let outcome = await execute(script,
                                limit: GitOutputLimit(stdoutBytes: 1024,
                                                      stderrBytes: 1024))
    guard case .completed(let result) = outcome else {
        Issue.record("Fixture konnte nicht gestartet werden")
        return
    }
    #expect(result.stdoutData.count == 1024)
    #expect(result.stdoutWasTruncated)
    #expect(result.stdoutForDisplay.count > result.stdout.count)
}

@Test("Startfehler ist von einem Git-Exit-Code unterscheidbar")
func gitRunner_reportsLaunchFailure() async {
    let outcome = await execute(URL(fileURLWithPath: "/definitely/missing/fastra-fixture"))
    guard case .startFailed(.launchFailed(let message)) = outcome else {
        Issue.record("Erwarteter Startfehler fehlt")
        return
    }
    #expect(!message.isEmpty)
}

/// Thread-sicherer Behälter für den Zeitpunkt des Abbruchs. Der Abbruch läuft
/// auf einer anderen Queue als die Auswertung, deshalb reicht eine einfache
/// Variable hier nicht.
private final class InstantBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ContinuousClock.Instant?
    func set(_ instant: ContinuousClock.Instant) { lock.lock(); stored = instant; lock.unlock() }
    var instant: ContinuousClock.Instant? { lock.lock(); defer { lock.unlock() }; return stored }
}

@Test("Abbruch-Handle beendet einen laufenden Prozess")
func gitRunner_cancelsRunningProcess() async {
    let cancelledAt = InstantBox()
    let outcome = await withCheckedContinuation { continuation in
        let token = GitRunner.runExecutable(URL(fileURLWithPath: "/bin/sleep"),
                                            arguments: ["5"],
                                            in: FileManager.default.temporaryDirectory) {
            continuation.resume(returning: $0)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            cancelledAt.set(ContinuousClock.now)
            token.cancel()
        }
    }
    let finished = ContinuousClock.now
    #expect(outcome == .cancelled)
    // Gemessen wird ausdrücklich ab dem Abbruch, nicht ab dem Teststart: Start
    // und Einplanung des Prozesses können auf ausgelasteten Maschinen (parallele
    // Testsuite, CI) mehrere Sekunden dauern und sagen nichts über die Frage aus,
    // die dieser Test stellt — ob der Abbruch den laufenden Prozess zügig beendet.
    // Das Budget deckt Kulanzfrist (0,5 s) und Drain-Fristen (max. 1,0 s) ab.
    if let cancelledAt = cancelledAt.instant {
        #expect(finished - cancelledAt < .seconds(2))
    } else {
        Issue.record("Abbruchzeitpunkt wurde nicht erfasst")
    }
}

@Test("Abbruch unmittelbar vor dem Prozessstart bleibt ein Abbruch")
func gitRunner_cancelsBeforeAttach() async {
    let outcome = await withCheckedContinuation { continuation in
        let token = GitRunner.runExecutable(URL(fileURLWithPath: "/bin/sleep"),
                                            arguments: ["5"],
                                            in: FileManager.default.temporaryDirectory) {
            continuation.resume(returning: $0)
        }
        token.cancel()
    }
    #expect(outcome == .cancelled)
}

@Test("Zeitlimit ist von Nutzerabbruch und Exit-Code unterscheidbar")
func gitRunner_reportsTimeout() async {
    let started = ContinuousClock.now
    // Das Kind schläft bewusst weit länger als das Budget: Greift das Zeitlimit
    // nicht, dauert der Aufruf 30 s und der Test schlägt eindeutig fehl. Der
    // großzügige Abstand hält die Aussage auch dann gültig, wenn Prozessstart
    // und Einplanung auf einer ausgelasteten Maschine mehrere Sekunden kosten.
    let outcome = await execute(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                                policy: GitExecutionPolicy(timeout: 0.05,
                                                           terminationGracePeriod: 0.05))
    #expect(outcome == .timedOut)
    #expect(ContinuousClock.now - started < .seconds(10))
}

@Test("Ohne Eingabe liest der Prozess sofort EOF statt geerbtes stdin")
func gitRunner_usesDevNullForMissingInput() async throws {
    let script = try temporaryExecutable("""
    if IFS= read -r value; then
      print -r -- "unexpected:$value"
    else
      print -r -- 'eof'
    fi
    """)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let outcome = await execute(script)
    guard case .completed(let result) = outcome else {
        Issue.record("stdin-Fixture wurde nicht ausgeführt"); return
    }
    #expect(result.ok)
    #expect(result.stdout == "eof\n")
}

@Test("Explizite stdin-Bytes erreichen den Prozess unverändert")
func gitRunner_writesExplicitStandardInput() async throws {
    let script = try temporaryExecutable("/bin/cat")
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let input = Data([0x00, 0x41, 0x0A, 0xFF])
    var policy = GitExecutionPolicy.default
    policy.standardInput = input
    let outcome = await execute(script, policy: policy)
    guard case .completed(let result) = outcome else {
        Issue.record("stdin-Fixture wurde nicht ausgeführt"); return
    }
    #expect(result.ok)
    #expect(result.stdoutData == input)
}

@Test("Abbruch beendet auch einen gestarteten Helferprozess derselben Gruppe")
func gitRunner_cancellationKillsDescendantGroup() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Fastra-ProcessGroup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("child.pid")
    let script = try temporaryExecutable("""
    /bin/sleep 30 &
    child=$!
    print -r -- "$child" > "$1"
    wait "$child"
    """)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let outcome = await withCheckedContinuation { continuation in
        let token = GitRunner.runExecutable(
            script, arguments: [pidFile.path], in: directory,
            policy: GitExecutionPolicy(timeout: 10, terminationGracePeriod: 0.05)
        ) { continuation.resume(returning: $0) }
        DispatchQueue.global().async {
            // Der komplette Runner-Filter startet viele Prozesse parallel. Das
            // Fixture wartet deshalb auf den nachweislich gestarteten Kindprozess
            // und misst nicht versehentlich nur Scheduler-Latenz.
            for _ in 0..<5_000 where !FileManager.default.fileExists(atPath: pidFile.path) {
                usleep(1_000)
            }
            token.cancel()
        }
    }
    #expect(outcome == .cancelled)
    let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let childPID = try #require(pid_t(pidText))
    var disappeared = false
    for _ in 0..<500 {
        if Darwin.kill(childPID, 0) != 0 && errno == ESRCH {
            disappeared = true; break
        }
        usleep(1_000)
    }
    #expect(disappeared)
}

@Test("Ein abgekoppelter Kindprozess hält Pipe und Git-Slot nicht offen")
func gitRunner_descendantPipeDoesNotBlockCompletion() async throws {
    // Das abgekoppelte Kind lebt deutlich länger als das Budget: Hält es Pipe
    // und Slot doch offen, wartet der Aufruf 30 s statt weniger als 10 s. Der
    // Abstand macht die Aussage unabhängig von der Startlatenz der Maschine.
    let script = try temporaryExecutable("""
    /bin/sleep 30 &
    exit 0
    """)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let started = ContinuousClock.now
    let outcome = await execute(script)
    guard case .completed(let result) = outcome else {
        Issue.record("Elternprozess lieferte kein Ergebnis")
        return
    }
    #expect(result.ok)
    #expect(ContinuousClock.now - started < .seconds(10))
}

@Test("Offene Descendant-Pipe gibt den Koordinator-Slot für den Nachfolger frei")
func gitRunner_descendantPipeReleasesCoordinatorSlot() async throws {
    // Wie oben: Das abgekoppelte Kind überlebt das Budget deutlich, damit ein
    // blockierter Koordinator-Slot als klarer Fehlschlag sichtbar wird und nicht
    // von der Startlatenz der Maschine abhängt.
    let script = try temporaryExecutable("""
    if [[ "$1" == "first" ]]; then
      /bin/sleep 30 &
      exit 0
    fi
    print -r -- 'second completed'
    """)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let coordinator = GitOperationsCoordinator(executor: ExecutableTestExecutor(script))
    let root = script.deletingLastPathComponent()
    let started = ContinuousClock.now
    let outcome = await withCheckedContinuation { continuation in
        coordinator.perform(GitOperationRequest(repository: root, kind: .refresh,
                                                arguments: ["first"])) { _ in }
        coordinator.perform(GitOperationRequest(repository: root, kind: .push,
                                                arguments: ["second"])) {
            continuation.resume(returning: $0)
        }
    }
    guard case .completed(let result) = outcome else {
        Issue.record("Nachfolgeprozess wurde nicht abgeschlossen")
        return
    }
    #expect(result.stdout == "second completed\n")
    #expect(ContinuousClock.now - started < .seconds(10))
}

@Test("Zweiter Pipe-Drain-Timeout wird ehrlich als Capture-Fehler gemeldet")
func gitRunner_reportsForcedIncompleteCapture() async throws {
    let script = try temporaryExecutable("""
    /bin/sleep 3 &
    exit 0
    """)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let outcome = await withCheckedContinuation { continuation in
        GitRunner.runExecutable(
            script, arguments: [], in: script.deletingLastPathComponent(),
            readerWait: { _, _ in .timedOut }
        ) { continuation.resume(returning: $0) }
    }
    guard case .captureFailed(let failure) = outcome else {
        Issue.record("Erzwungener zweiter Drain-Timeout blieb scheinbar erfolgreich")
        return
    }
    let expected = L10n.string("Git-Ausgabe blieb nach dem Schließen der Pipe unvollständig.")
    #expect(failure.stdoutError == expected)
    #expect(failure.stderrError == expected)
}

@Test("Argumente bleiben getrennt und Terminal-Prompt ist deaktiviert")
func gitRunner_preservesArgumentsAndEnvironment() async throws {
    let script = try temporaryExecutable("""
    print -r -- "$1"
    print -r -- "$GIT_TERMINAL_PROMPT"
    print -r -- "$GIT_LITERAL_PATHSPECS"
    """)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let value = "Leerzeichen;$(kein-shell-aufruf)\nzweite Zeile"
    let outcome = await execute(script, arguments: [value])
    guard case .completed(let result) = outcome else {
        Issue.record("Fixture konnte nicht gestartet werden")
        return
    }
    #expect(result.stdout == value + "\n0\n1\n")
}

@Test("Repository- und Konfigurations-Umleitungen werden entfernt")
func gitRunner_sanitizesRepositoryEnvironment() {
    let environment = GitRunner.sanitizedEnvironment(base: [
        "PATH": "/custom/bin", "SSH_AUTH_SOCK": "/tmp/agent",
        "GIT_DIR": "/fremd", "GIT_WORK_TREE": "/fremd/work",
        "GIT_INDEX_FILE": "/fremd/index", "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "core.sshCommand", "GIT_CONFIG_VALUE_0": "evil",
        "GIT_CONFIG_PARAMETERS": "'core.hooksPath'='/fremd'",
        "GIT_EXEC_PATH": "/fremd/exec", "GIT_EXTERNAL_DIFF": "/fremd/diff",
        "GIT_ASKPASS": "/tmp/gui-askpass", "SSH_ASKPASS": "/tmp/ssh-gui",
        "SSH_ASKPASS_REQUIRE": "force",
    ], additions: ["GIT_DIR": "/nochmals-fremd"])
    #expect(environment["PATH"] == "/custom/bin")
    #expect(environment["SSH_AUTH_SOCK"] == "/tmp/agent")
    #expect(environment["GIT_DIR"] == nil)
    #expect(environment["GIT_WORK_TREE"] == nil)
    #expect(environment["GIT_INDEX_FILE"] == nil)
    #expect(environment["GIT_CONFIG_COUNT"] == nil)
    #expect(environment["GIT_CONFIG_KEY_0"] == nil)
    #expect(environment["GIT_CONFIG_VALUE_0"] == nil)
    #expect(environment["GIT_CONFIG_PARAMETERS"] == nil)
    #expect(environment["GIT_EXEC_PATH"] == nil)
    #expect(environment["GIT_EXTERNAL_DIFF"] == nil)
    #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
    #expect(environment["GIT_ASKPASS"] == "/usr/bin/false")
    #expect(environment["SSH_ASKPASS"] == "/usr/bin/false")
    #expect(environment["SSH_ASKPASS_REQUIRE"] == "never")
    #expect(environment["GIT_LITERAL_PATHSPECS"] == "1")
}

@Test("Capture-Fehler behält Diagnose und bereits gelesene Ausgabe")
func gitRunner_formatsCaptureFailureHonestly() {
    let partial = GitResult(exitCode: -1, stdout: "teilweise Ausgabe", stderr: "")
    let failure = GitCaptureFailure(stdoutError: "Pipe geschlossen",
                                    stderrError: nil, partialResult: partial)
    let text = Workspace.gitExecutionFailureText(.captureFailed(failure))
    #expect(text?.contains("Pipe geschlossen") == true)
    #expect(text?.contains("teilweise Ausgabe") == true)
}

private func runGit(_ arguments: [String], in repository: URL) async -> GitExecutionOutcome {
    await withCheckedContinuation { continuation in
        GitRunner.runDetailed(arguments, in: repository) {
            continuation.resume(returning: $0)
        }
    }
}

private func runGit(_ arguments: [String], in repository: URL,
                    policy: GitExecutionPolicy) async -> GitExecutionOutcome {
    await withCheckedContinuation { continuation in
        GitRunner.runDetailed(arguments, in: repository, policy: policy) {
            continuation.resume(returning: $0)
        }
    }
}

@Test("core.askPass kann trotz lokaler Konfiguration kein Prompt-Programm starten")
func gitRunner_blocksConfiguredCoreAskPass() async throws {
    let repo = FileManager.default.temporaryDirectory
        .appendingPathComponent("Fastra-CoreAskPass-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: repo) }
    guard case .completed(let initResult) = await runGit(["init", "-q"], in: repo),
          initResult.ok else {
        Issue.record("Temporäres Repository konnte nicht initialisiert werden")
        return
    }
    let askPass = repo.appendingPathComponent("configured-askpass")
    let sentinel = repo.appendingPathComponent("askpass-was-started")
    try Data("#!/bin/zsh\n/usr/bin/touch \"\(sentinel.path)\"\nprint secret\n".utf8)
        .write(to: askPass)
    try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                          ofItemAtPath: askPass.path)
    guard case .completed(let configResult) = await runGit(
        ["config", "--local", "core.askPass", askPass.path], in: repo
    ), configResult.ok,
    case .completed(let helperResult) = await runGit(
        ["config", "--local", "credential.helper", ""], in: repo
    ), helperResult.ok else {
        Issue.record("Askpass-Fixture konnte nicht konfiguriert werden")
        return
    }

    var policy = GitExecutionPolicy.default
    // Zeitlimit und Budget liegen bewusst weit über der erwarteten Dauer: Fragt
    // Git doch interaktiv nach, hängt der Aufruf bis zum Limit und endet als
    // .timedOut — der Test schlägt dann am Guard unten fehl, statt an der
    // Startlatenz einer ausgelasteten Maschine zu scheitern.
    policy.timeout = 10
    policy.standardInput = Data("protocol=https\nhost=fastra.invalid\n\n".utf8)
    let started = ContinuousClock.now
    let outcome = await runGit(["credential", "fill"], in: repo, policy: policy)
    guard case .completed(let result) = outcome else {
        Issue.record("git credential fill endete nicht regulär: \(outcome)")
        return
    }
    #expect(!result.ok)
    #expect(ContinuousClock.now - started < .seconds(10))
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
}

@Test("Wörtliche Pathspecs schützen Magic-Namen und führenden Bindestrich")
func gitRunner_usesLiteralPathspecs() async throws {
    let repo = FileManager.default.temporaryDirectory
        .appendingPathComponent("Fastra-Literal-Pathspec-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: repo) }
    guard case .completed(let initResult) = await runGit(["init", "-q"], in: repo),
          initResult.ok else {
        Issue.record("Temporäres Repository konnte nicht initialisiert werden")
        return
    }
    for name in [":(glob)**", "-leading", "ordinary.txt"] {
        try Data(name.utf8).write(to: repo.appendingPathComponent(name))
    }
    guard case .completed(let addResult) = await runGit(
        ["add", "--", ":(glob)**", "-leading"], in: repo
    ), addResult.ok else {
        Issue.record("Dateien mit Pathspec-Sonderzeichen konnten nicht gestaged werden")
        return
    }
    guard case .completed(let listResult) = await runGit(
        ["diff", "--cached", "--name-only", "-z"], in: repo
    ), listResult.ok else {
        Issue.record("Index konnte nicht gelesen werden")
        return
    }
    let names = listResult.stdoutData.split(separator: 0)
        .map { String(decoding: $0, as: UTF8.self) }
    #expect(Set(names) == Set([":(glob)**", "-leading"]))
}
