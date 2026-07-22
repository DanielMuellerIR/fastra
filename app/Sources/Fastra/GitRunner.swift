import Foundation
import Darwin

/// Sicherheitsfristen dürfen nicht hinter umfangreicher Datei- oder Testarbeit
/// auf der globalen Utility-Queue verhungern. Die Handler sind kurz (Lock/Kill)
/// und teilen deshalb bewusst eine eigene serielle Queue mit hoher Priorität.
private let gitDeadlineQueue = DispatchQueue(
    label: "com.fastra.git-deadlines",
    qos: .userInitiated
)

/// Ergebnis eines git-Aufrufs — roher Prozess-Ausgang, absichtlich un-interpretiert.
/// Die UX-Regel „Fehler = echte git-Ausgabe zeigen" lebt davon, dass `stderr`
/// wortwörtlich erhalten bleibt (ROADMAP → Projekt- & Git-Ausbau).
struct GitResult: Equatable {
    let exitCode: Int32
    let stdoutData: Data
    let stderrData: Data
    let stdoutWasTruncated: Bool
    let stderrWasTruncated: Bool

    var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
    var stderr: String { String(decoding: stderrData, as: UTF8.self) }

    var stdoutForDisplay: String {
        Self.display(stdout, truncated: stdoutWasTruncated,
                     retainedBytes: stdoutData.count)
    }

    var stderrForDisplay: String {
        Self.display(stderr, truncated: stderrWasTruncated,
                     retainedBytes: stderrData.count)
    }

    var ok: Bool { exitCode == 0 }

    init(exitCode: Int32, stdoutData: Data, stderrData: Data,
         stdoutWasTruncated: Bool = false, stderrWasTruncated: Bool = false) {
        self.exitCode = exitCode
        self.stdoutData = stdoutData
        self.stderrData = stderrData
        self.stdoutWasTruncated = stdoutWasTruncated
        self.stderrWasTruncated = stderrWasTruncated
    }

    init(exitCode: Int32, stdout: String, stderr: String) {
        self.init(exitCode: exitCode, stdoutData: Data(stdout.utf8),
                  stderrData: Data(stderr.utf8))
    }

    private static func display(_ value: String, truncated: Bool,
                                retainedBytes: Int) -> String {
        guard truncated else { return value }
        let notice = L10n.format("Ausgabe nach %lld Bytes gekürzt.",
                                 Int64(retainedBytes))
        return value.isEmpty ? notice : value + "\n\n" + notice
    }
}

/// Startfehler sind keine Git-Exit-Codes: Der Prozess ist in diesen Fällen nie
/// gelaufen. Neue Aufrufer können den Grund dadurch ehrlich unterscheiden;
/// der alte optionale Callback bleibt für bestehende UI-Aufrufer kompatibel.
enum GitStartFailure: Error, Equatable {
    case gitUnavailable
    case launchFailed(String)
}

enum GitExecutionOutcome: Equatable {
    case completed(GitResult)
    case startFailed(GitStartFailure)
    case cancelled
    case timedOut
    case captureFailed(GitCaptureFailure)
}

struct GitCaptureFailure: Equatable {
    let stdoutError: String?
    let stderrError: String?
    let partialResult: GitResult
}

/// Obergrenzen für die im Speicher behaltenen Bytes. Die Pipes werden trotzdem
/// vollständig geleert, damit der Kindprozess nie an einem vollen Puffer hängt.
struct GitOutputLimit: Equatable {
    var stdoutBytes: Int
    var stderrBytes: Int

    static let `default` = GitOutputLimit(stdoutBytes: 16 * 1024 * 1024,
                                          stderrBytes: 4 * 1024 * 1024)
}

struct GitExecutionPolicy: Equatable {
    /// Auch Netzwerkfehler müssen die Repo-Queue irgendwann freigeben.
    var timeout: TimeInterval?
    var terminationGracePeriod: TimeInterval
    /// Standardmäßig beendet `/usr/bin/false` jeden unerwarteten Editoraufruf.
    /// Continue-Kommandos dürfen ausschließlich die bereits von Git erzeugte
    /// Nachricht unverändert über `/usr/bin/true` bestätigen.
    var editorPolicy: GitEditorPolicy = .reject
    /// `nil` bedeutet ausdrücklich `/dev/null`, niemals geerbtes stdin. Daten
    /// werden ohne Shell direkt in die Pipe des gestarteten Prozesses geschrieben.
    var standardInput: Data? = nil

    static let `default` = GitExecutionPolicy(timeout: 120,
                                              terminationGracePeriod: 0.5)
}

enum GitEditorPolicy: Equatable {
    case reject
    case acceptExistingMessage

    var command: String {
        switch self {
        case .reject: return "/usr/bin/false"
        case .acceptExistingMessage: return "/usr/bin/true"
        }
    }
}

fileprivate enum GitTerminationReason {
    case cancelled
    case timedOut
}

/// Abbruch-Handle, das auch den Race „Abbruch unmittelbar vor process.run()"
/// abdeckt. `Process.terminate()` sendet SIGTERM; Git kann dadurch seine eigenen
/// Lock-/Cleanup-Handler ausführen.
final class GitCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var processGroupID: pid_t?
    private var terminationReason: GitTerminationReason?
    private var timeoutWorkItem: DispatchWorkItem?
    private let terminationGracePeriod: TimeInterval

    init(terminationGracePeriod: TimeInterval = GitExecutionPolicy.default.terminationGracePeriod) {
        self.terminationGracePeriod = max(0, terminationGracePeriod)
    }

    func cancel() {
        requestTermination(.cancelled)
    }

    fileprivate func timeOut() {
        requestTermination(.timedOut)
    }

    private func requestTermination(_ reason: GitTerminationReason) {
        lock.lock()
        if terminationReason == nil { terminationReason = reason }
        let runningProcess = process
        let group = processGroupID
        lock.unlock()
        if let runningProcess, runningProcess.isRunning {
            terminateSafely(runningProcess, processGroupID: group)
        }
    }

    fileprivate func attach(_ process: Process, processGroupID: pid_t?) {
        lock.lock()
        self.process = process
        self.processGroupID = processGroupID
        let shouldTerminate = terminationReason != nil
        lock.unlock()
        if shouldTerminate, process.isRunning {
            terminateSafely(process, processGroupID: processGroupID)
        }
    }

    fileprivate func scheduleTimeout(_ seconds: TimeInterval?) {
        guard let seconds else { return }
        let item = DispatchWorkItem { [weak self] in self?.timeOut() }
        lock.lock()
        timeoutWorkItem = item
        lock.unlock()
        gitDeadlineQueue.asyncAfter(
            deadline: .now() + max(0, seconds), execute: item
        )
    }

    fileprivate func finish() -> GitTerminationReason? {
        lock.lock()
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        process = nil
        processGroupID = nil
        let reason = terminationReason
        lock.unlock()
        return reason
    }

    /// Git erhält direkt nach dem Start eine eigene Prozessgruppe. Abbruch und
    /// Timeout treffen dadurch auch Hooks und Helper, die sonst nach dem
    /// Git-Elternprozess weiterlaufen oder geerbte Pipes offen halten könnten.
    private func terminateSafely(_ process: Process, processGroupID: pid_t?) {
        let pid = process.processIdentifier
        if let processGroupID {
            Darwin.kill(-processGroupID, SIGTERM)
            // Ein extern angehaltener Prozess muss den bereits zugestellten
            // SIGTERM noch ausführen dürfen, damit Git seine Lockdateien räumt.
            Darwin.kill(-processGroupID, SIGCONT)
        } else {
            process.terminate()
        }
        gitDeadlineQueue.asyncAfter(
            deadline: .now() + terminationGracePeriod
        ) {
            guard process.processIdentifier == pid else { return }
            if let processGroupID {
                // Auch nach beendetem Git-Elternprozess können Helper in der
                // Gruppe leben; deshalb nicht nur `process.isRunning` prüfen.
                Darwin.kill(-processGroupID, SIGKILL)
            } else if process.isRunning {
                Darwin.kill(pid, SIGKILL)
            }
        }
    }
}

private final class GitLockTransactionCancellation: GitCancelling {
    private let lock = NSLock()
    private var tokens: [GitCancellationToken] = []
    private var terminationReason: GitTerminationReason?
    private var commitBoundaryReached = false
    private var finished = false
    private var timeoutWorkItem: DispatchWorkItem?

    func add(_ token: GitCancellationToken) {
        lock.lock()
        if finished { lock.unlock(); return }
        if let terminationReason {
            lock.unlock()
            switch terminationReason {
            case .timedOut: token.timeOut()
            case .cancelled: token.cancel()
            }
            return
        }
        tokens.append(token)
        lock.unlock()
    }

    func cancel() {
        terminate(.cancelled)
    }

    /// Liefert den bereits atomar gewonnenen Abbruchgrund auch dann, wenn noch
    /// kein Git-Prozess gestartet wurde. So wird ein gleichzeitig sichtbarer
    /// fremder Lock nicht fälschlich als Startfehler vor dem Abbruch gemeldet.
    func terminationOutcome() -> GitExecutionOutcome? {
        lock.lock(); defer { lock.unlock() }
        switch terminationReason {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case nil: return nil
        }
    }

    private func terminate(_ reason: GitTerminationReason) {
        lock.lock()
        guard terminationReason == nil, !commitBoundaryReached, !finished else {
            lock.unlock(); return
        }
        terminationReason = reason
        let current = tokens
        lock.unlock()
        current.forEach {
            switch reason {
            case .timedOut: $0.timeOut()
            case .cancelled: $0.cancel()
            }
        }
    }

    func scheduleTimeout(_ seconds: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.terminate(.timedOut) }
        lock.lock()
        guard !finished else { lock.unlock(); return }
        timeoutWorkItem = item
        lock.unlock()
        gitDeadlineQueue.asyncAfter(
            deadline: .now() + max(0, seconds), execute: item
        )
    }

    /// Ab diesem atomaren Punkt ist der vollständige Indexrecord an Git zur
    /// Ausgabe freigegeben. Ein späterer UI-Abbruch darf die tatsächliche
    /// Mutation nicht mehr fälschlich als „abgebrochen“ ausgeben.
    func beginCommit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard terminationReason == nil, !finished else { return false }
        commitBoundaryReached = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        return true
    }

    func finish() {
        lock.lock()
        finished = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        tokens.removeAll()
        lock.unlock()
    }

    /// Lock-Kollision und Abbruch/Timeout entscheiden unter demselben Lock,
    /// welches Ereignis zuerst gewinnt. Ein erst danach eintreffender Timer darf den
    /// bereits feststehenden Startfehler ebenso wenig umetikettieren wie eine
    /// bereits gewonnene Cancellation als Lockfehler verloren gehen darf.
    func finishPreflight(fallback: GitExecutionOutcome) -> GitExecutionOutcome {
        lock.lock()
        let outcome: GitExecutionOutcome
        switch terminationReason {
        case .cancelled: outcome = .cancelled
        case .timedOut: outcome = .timedOut
        case nil: outcome = fallback
        }
        finished = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        tokens.removeAll()
        lock.unlock()
        return outcome
    }
}

/// Nach der Commit-Grenze darf ein Nutzerabbruch das Ergebnis nicht mehr als
/// „abgebrochen“ ausgeben. Eine eigene harte Deadline beendet dennoch beide
/// Prozessgruppen, falls `update-index` oder die vorbereitete Ref-Transaktion
/// hängen. Der Aufrufer meldet diesen Fall anschließend ausdrücklich als
/// ungewiss und liest den Repository-Zustand neu ein.
private final class GitPostSubmitDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var workItem: DispatchWorkItem?
    private var expired = false

    func schedule(after seconds: TimeInterval,
                  tokens: [GitCancellationToken]) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.expired = true
            self.lock.unlock()
            tokens.forEach { $0.timeOut() }
        }
        lock.lock()
        workItem = item
        lock.unlock()
        gitDeadlineQueue.asyncAfter(
            deadline: .now() + max(0, seconds), execute: item
        )
    }

    func finish() -> Bool {
        lock.lock()
        workItem?.cancel()
        workItem = nil
        let didExpire = expired
        lock.unlock()
        return didExpire
    }
}

private final class GitLockDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    func setOnce(_ newValue: Bool) {
        lock.lock()
        if value == nil { value = newValue }
        lock.unlock()
    }

    func get() -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Dünner Wrapper um das `git`-Kommandozeilenprogramm. Philosophie der Etappe:
/// **Git liefert Logik und Daten, Fastra liefert Sichtbarkeit und Knöpfe.**
/// Kein libgit2, kein Eigenbau — nur Unterprozess-Aufrufe. Der CLI-Weg erbt
/// automatisch die Auth-Konfiguration des Nutzers (SSH-Keys, Keychain-Helper).
///
/// UX-Regeln, die hier verdrahtet sind:
/// - **Git fehlt → still weg.** `resolvedPath` liefert `nil`, ohne je den
///   `/usr/bin/git`-Stub anzufassen (der löst sonst den CLT-Installations-
///   Dialog aus — genau das „nervige Gefrage", das wir vermeiden).
/// - **Nie den Main-Thread blockieren.** `run` arbeitet auf einer eigenen Queue
///   und ruft die Completion auf Main.
enum GitRunner {
    enum RefPreparationPhase: Equatable {
        case beforeFirst
    }

    private struct PreparedRefConclusion {
        let result: GitResult
        let termination: GitTerminationReason?
        let captureError: String?
        let protocolSucceeded: Bool
    }

    private enum PreparedRefPreparation {
        case success(PreparedRefTransaction)
        case failure(GitExecutionOutcome)
    }

    /// Eine einzelne Git-eigene verify-only-Reftransaktion. Beim beobachteten
    /// files-ref-Backend sperrt `verify refs/heads/...` auch jeden symbolischen
    /// Worktree-HEAD, der auf diesen Branch zeigt. Fastra verlangt deshalb nach
    /// `prepare` ausdrücklich Branch- UND eigenen Worktree-HEAD-Lock. Fehlt der
    /// zweite Lock bei einem anderen Backend, scheitert der Ablauf fail-closed.
    private final class PreparedRefTransaction {
        let process: Process
        let token: GitCancellationToken
        let groupID: pid_t
        private let input: Pipe
        private let output: Pipe
        private let stderrCapture: PipeCapture
        private let readers: DispatchGroup
        private var protocolOutput: Data

        private init(process: Process, token: GitCancellationToken,
                     groupID: pid_t, input: Pipe, output: Pipe,
                     stderrCapture: PipeCapture, readers: DispatchGroup,
                     protocolOutput: Data) {
            self.process = process
            self.token = token
            self.groupID = groupID
            self.input = input
            self.output = output
            self.stderrCapture = stderrCapture
            self.readers = readers
            self.protocolOutput = protocolOutput
        }

        static func prepare(gitPath: String, launcherURL: URL,
                            directory: URL, commands: String,
                            expectedLockPaths: [String],
                            cancellation: GitLockTransactionCancellation,
                            policy: GitExecutionPolicy)
            -> PreparedRefPreparation {
            let token = GitCancellationToken(
                terminationGracePeriod: policy.terminationGracePeriod
            )
            cancellation.add(token)
            let process = Process()
            process.executableURL = launcherURL
            process.arguments = [FastraProcessGroupLauncher.flag, gitPath,
                                 "--no-pager", "update-ref", "--stdin"]
            process.currentDirectoryURL = directory
            process.environment = sanitizedEnvironment(
                base: ProcessInfo.processInfo.environment
            )
            let input = Pipe()
            let output = Pipe()
            let error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            do {
                try process.run()
            } catch {
                _ = token.finish()
                return .failure(.startFailed(.launchFailed(error.localizedDescription)))
            }
            let pid = process.processIdentifier
            var groupID: pid_t?
            for _ in 0..<500 {
                if Darwin.getpgid(pid) == pid { groupID = pid; break }
                if !process.isRunning { break }
                usleep(1_000)
            }
            guard let groupID else {
                process.terminate()
                process.waitUntilExit()
                _ = token.finish()
                return .failure(.startFailed(.launchFailed(L10n.string(
                    "Der Git-Prozess konnte nicht sicher isoliert werden."))))
            }
            token.attach(process, processGroupID: groupID)
            let stderrCapture = PipeCapture()
            let readers = DispatchGroup()
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stderrCapture.store(drain(error.fileHandleForReading,
                                          retainingAtMost: 64 * 1024))
                readers.leave()
            }
            do {
                try input.fileHandleForWriting.write(
                    contentsOf: Data("start\n\(commands)prepare\n".utf8)
                )
            } catch {
                try? input.fileHandleForWriting.close()
            }
            let startAck = readProtocolLine(output.fileHandleForReading)
            let prepareAck = readProtocolLine(output.fileHandleForReading)
            let prepared = startAck == "start: ok" && prepareAck == "prepare: ok"
                && expectedLockPaths.allSatisfy {
                    FileManager.default.fileExists(atPath: $0)
                }
                && process.isRunning
            var protocolOutput = Data()
            if let startAck { protocolOutput.append(Data("\(startAck)\n".utf8)) }
            if let prepareAck { protocolOutput.append(Data("\(prepareAck)\n".utf8)) }
            guard prepared else {
                try? input.fileHandleForWriting.close()
                process.waitUntilExit()
                _ = readers.wait(timeout: .now() + 1)
                let termination = token.finish()
                switch termination {
                case .cancelled: return .failure(.cancelled)
                case .timedOut: return .failure(.timedOut)
                case nil:
                    let partial = stderrCapture.snapshot()
                    let detail = String(decoding: partial.data, as: UTF8.self)
                    let message = detail.isEmpty
                        ? L10n.string("Diese Git-Version unterstützt die sichere Referenztransaktion nicht.")
                        : detail
                    return .failure(.startFailed(.launchFailed(message)))
                }
            }
            return .success(PreparedRefTransaction(
                process: process, token: token, groupID: groupID,
                input: input, output: output, stderrCapture: stderrCapture,
                readers: readers, protocolOutput: protocolOutput
            ))
        }

        func conclude(commit: Bool) -> PreparedRefConclusion {
            let command = commit ? "commit\n" : "abort\n"
            var wrote = false
            if process.isRunning {
                do {
                    try input.fileHandleForWriting.write(contentsOf: Data(command.utf8))
                    wrote = true
                } catch { wrote = false }
            }
            let ack = wrote ? GitRunner.readProtocolLine(output.fileHandleForReading) : nil
            if let ack { protocolOutput.append(Data("\(ack)\n".utf8)) }
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            _ = readers.wait(timeout: .now() + 1)
            let stderr = stderrCapture.snapshot()
            let result = GitResult(
                exitCode: process.terminationStatus,
                stdoutData: protocolOutput, stderrData: stderr.data,
                stdoutWasTruncated: false, stderrWasTruncated: stderr.truncated
            )
            return PreparedRefConclusion(
                result: result,
                termination: token.finish(),
                captureError: stderr.error,
                protocolSucceeded: ack == (commit ? "commit: ok" : "abort: ok")
            )
        }
    }

    /// Kandidaten-Pfade für ein NUTZBARES git-Binary, in Prioritätsreihenfolge.
    /// Bewusst NICHT `/usr/bin/git`: das ist unter macOS ein Shim, der bei
    /// fehlenden Command Line Tools einen modalen Installations-Dialog öffnet.
    /// Das echte CLT-git liegt unter `/Library/Developer/...` und wird direkt
    /// angesprochen; Homebrew-git (Apple Silicon / Intel) hat Vorrang, falls da.
    static let candidatePaths = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
    ]

    static var processGroupLauncherURL: URL? {
        if let main = Bundle.main.executableURL,
           main.lastPathComponent == "Fastra" { return main }
        // `swift test` legt das Fastra-Produkt neben das Ressourcenbundle.
        let adjacent = Bundle.module.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Fastra")
        return FileManager.default.isExecutableFile(atPath: adjacent.path)
            ? adjacent : nil
    }

    /// Der aktive Xcode-Developer-Ordner (Fallback-Quelle für git). `xcode-select`
    /// liegt fest unter `/usr/bin` und löst KEINEN Installations-Dialog aus — es
    /// meldet bei fehlenden Tools nur einen Fehler. Als Closure gehalten, damit
    /// Tests die reine Pfad-Auswahl ohne echten Prozess prüfen können.
    static var developerDirProvider: () -> String? = Self.queryXcodeSelect

    /// Erster existierender, ausführbarer git-Pfad — oder `nil` (git fehlt).
    /// Reine Auswahl-Logik, injizierbar für Tests.
    static func resolvePath(candidates: [String],
                            developerDir: String?,
                            fileManager: FileManager = .default) -> String? {
        var paths = candidates
        // Xcode-only-Setups (CLT fehlt): git liegt im aktiven Developer-Ordner.
        if let dev = developerDir {
            paths.append("\(dev)/usr/bin/git")
        }
        return paths.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Gecachter git-Pfad. `nil` nach Auflösung = git nicht verfügbar.
    /// Doppelt-optional, um „noch nicht ermittelt" von „ermittelt: keins" zu
    /// unterscheiden.
    private static var cachedPath: String?? = nil

    static var resolvedPath: String? {
        if let cached = cachedPath { return cached }
        let path = resolvePath(candidates: candidatePaths,
                               developerDir: developerDirProvider())
        cachedPath = .some(path)
        return path
    }

    /// Ist ein nutzbares git vorhanden? Steuert, ob Git-UI überhaupt erscheint.
    static var isAvailable: Bool { resolvedPath != nil }

    /// Führt git asynchron aus und liefert das rohe Ergebnis auf dem Main-Thread.
    /// `completion(nil)` = git nicht verfügbar oder Start fehlgeschlagen (der
    /// Aufrufer blendet die Funktion dann still aus, statt zu meckern).
    ///
    /// - `--no-pager` erzwingt reine stdout-Ausgabe (kein `less`), und ein
    ///   leerer `GIT_TERMINAL_PROMPT=0` verhindert, dass git bei fehlenden
    ///   Credentials auf einer unsichtbaren Konsole nach einem Passwort fragt
    ///   und hängt.
    @discardableResult
    static func run(_ args: [String],
                    in directory: URL,
                    completion: @escaping (GitResult?) -> Void) -> GitCancellationToken {
        runDetailed(args, in: directory) { outcome in
            switch outcome {
            case .completed(let result): completion(result)
            default: completion(nil)
            }
        }
    }

    /// Vollständige API mit unterscheidbarem Startfehler und Abbruch-Handle.
    @discardableResult
    static func runDetailed(_ args: [String], in directory: URL,
                            outputLimit: GitOutputLimit = .default,
                            policy: GitExecutionPolicy = .default,
                            completion: @escaping (GitExecutionOutcome) -> Void)
        -> GitCancellationToken {
        guard let gitPath = resolvedPath else {
            let token = GitCancellationToken(
                terminationGracePeriod: policy.terminationGracePeriod
            )
            DispatchQueue.main.async { completion(.startFailed(.gitUnavailable)) }
            return token
        }

        return runExecutable(URL(fileURLWithPath: gitPath),
                             arguments: ["--no-pager"] + args,
                             in: directory, editorPolicy: policy.editorPolicy,
                             outputLimit: outputLimit, policy: policy,
                             completion: completion)
    }

    /// Startet `update-index --index-info` mit zunächst offenem stdin. Git legt
    /// seinen offiziellen `index.lock` bereits vor dem ersten stdin-Read an.
    /// Erst danach darf der Aufrufer den Zustand erneut prüfen und genau einen
    /// vorbereiteten Record freigeben. `false` schließt stdin leer; Git verwirft
    /// dann seine temporäre Indexkopie und gibt den Lock ohne Mutation frei.
    @discardableResult
    static func runHoldingIndexLock(indexPath: String, record: Data,
                                    headRef: String, headOID: String,
                                    headRefPath: String,
                                    headRefNeedsNoDeref: Bool,
                                    worktreeHeadPath: String,
                                    headSymbolicTarget: String?,
                                    in directory: URL,
                                    timeout: TimeInterval = 30,
                                    postSubmitTimeout: TimeInterval = 5,
                                    verify: @escaping (@escaping (Bool) -> Void) -> Void,
                                    commitBoundaryReached: @escaping () -> Void = {},
                                    beforeLockPreflight: (() -> Void)? = nil,
                                    beforeRefLockPreflight: (() -> Void)? = nil,
                                    refPreparationHook: ((RefPreparationPhase) -> Void)? = nil,
                                    postSubmitProcessGroups: (([pid_t]) -> Void)? = nil,
                                    completion: @escaping (GitExecutionOutcome, Bool) -> Void)
        -> GitCancelling {
        let policy = GitExecutionPolicy(timeout: timeout, terminationGracePeriod: 0.5)
        let cancellation = GitLockTransactionCancellation()
        let indexToken = GitCancellationToken(
            terminationGracePeriod: policy.terminationGracePeriod
        )
        cancellation.add(indexToken)
        cancellation.scheduleTimeout(policy.timeout ?? 30)
        guard let gitPath = resolvedPath,
              let launcherURL = processGroupLauncherURL else {
            let failure: GitStartFailure = resolvedPath == nil
                ? .gitUnavailable
                : .launchFailed(L10n.string("Der sichere Git-Prozesslauncher fehlt."))
            cancellation.finish()
            DispatchQueue.main.async { completion(.startFailed(failure), false) }
            return cancellation
        }

        DispatchQueue.global(qos: .userInitiated).async {
            beforeLockPreflight?()
            if let outcome = cancellation.terminationOutcome() {
                cancellation.finish()
                DispatchQueue.main.async { completion(outcome, false) }
                return
            }
            guard !FileManager.default.fileExists(atPath: indexPath + ".lock") else {
                let outcome = cancellation.finishPreflight(fallback:
                    .startFailed(.launchFailed(L10n.string(
                        "Der Git-Index wird bereits von einem anderen Prozess verändert."))))
                DispatchQueue.main.async {
                    completion(outcome, false)
                }
                return
            }
            let process = Process()
            process.executableURL = launcherURL
            process.arguments = [FastraProcessGroupLauncher.flag, gitPath,
                                 "--no-pager", "update-index", "-z", "--index-info"]
            process.currentDirectoryURL = directory
            process.environment = sanitizedEnvironment(
                base: ProcessInfo.processInfo.environment
            )
            let input = Pipe()
            let output = Pipe()
            let error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            do {
                try process.run()
            } catch {
                cancellation.finish()
                DispatchQueue.main.async {
                    completion(.startFailed(.launchFailed(error.localizedDescription)), false)
                }
                return
            }

            let pid = process.processIdentifier
            var groupID: pid_t?
            for _ in 0..<500 {
                if Darwin.getpgid(pid) == pid { groupID = pid; break }
                if !process.isRunning { break }
                usleep(1_000)
            }
            guard let groupID else {
                process.terminate()
                process.waitUntilExit()
                cancellation.finish()
                DispatchQueue.main.async {
                    completion(.startFailed(.launchFailed(L10n.string(
                        "Der Git-Prozess konnte nicht sicher isoliert werden."))), false)
                }
                return
            }
            indexToken.attach(process, processGroupID: groupID)

            let stdoutCapture = PipeCapture()
            let stderrCapture = PipeCapture()
            let readers = DispatchGroup()
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stdoutCapture.store(drain(output.fileHandleForReading,
                                          retainingAtMost: 64 * 1024))
                readers.leave()
            }
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stderrCapture.store(drain(error.fileHandleForReading,
                                          retainingAtMost: 64 * 1024))
                readers.leave()
            }

            let lockPath = indexPath + ".lock"
            for _ in 0..<5_000 {
                if FileManager.default.fileExists(atPath: lockPath) { break }
                if !process.isRunning { break }
                usleep(1_000)
            }
            let acquiredLock = FileManager.default.fileExists(atPath: lockPath)
            guard acquiredLock, process.isRunning else {
                try? input.fileHandleForWriting.close()
                process.waitUntilExit()
                _ = readers.wait(timeout: .now() + 1)
                let termination = indexToken.finish()
                cancellation.finish()
                let outcome: GitExecutionOutcome
                switch termination {
                case .cancelled: outcome = .cancelled
                case .timedOut: outcome = .timedOut
                case nil:
                    outcome = .startFailed(.launchFailed(L10n.string(
                        "Git konnte den Index nicht sicher sperren.")))
                }
                DispatchQueue.main.async {
                    completion(outcome, false)
                }
                return
            }

            // Beim files-ref-Backend sperrt die Zielbranch-Transaktion auch den
            // darauf zeigenden Worktree-HEAD. Beide Lockdateien sind hier eine
            // Sicherheitsbedingung, nicht bloß ein Implementierungsdetail.
            let refLockPaths = Set([headRefPath, worktreeHeadPath])
                .map { $0 + ".lock" }
            beforeRefLockPreflight?()
            if let outcome = cancellation.terminationOutcome() {
                try? input.fileHandleForWriting.close()
                process.waitUntilExit()
                _ = readers.wait(timeout: .now() + 1)
                _ = indexToken.finish()
                cancellation.finish()
                DispatchQueue.main.async { completion(outcome, false) }
                return
            }
            guard !refLockPaths.contains(where: {
                FileManager.default.fileExists(atPath: $0)
            }) else {
                let outcome = cancellation.finishPreflight(fallback:
                    .startFailed(.launchFailed(L10n.string(
                        "Die aktuelle Git-Referenz wird bereits von einem anderen Prozess verändert."))))
                try? input.fileHandleForWriting.close()
                process.waitUntilExit()
                _ = readers.wait(timeout: .now() + 1)
                _ = indexToken.finish()
                DispatchQueue.main.async {
                    completion(outcome, false)
                }
                return
            }
            var refTransactions: [PreparedRefTransaction] = []
            var refPreparationFailure: GitExecutionOutcome?
            refPreparationHook?(.beforeFirst)

            func prepareRef(commands: String, lockPaths: [String]) -> Bool {
                switch PreparedRefTransaction.prepare(
                    gitPath: gitPath, launcherURL: launcherURL,
                    directory: directory, commands: commands,
                    expectedLockPaths: lockPaths,
                    cancellation: cancellation, policy: policy
                ) {
                case .success(let transaction):
                    refTransactions.append(transaction)
                    return true
                case .failure(let outcome):
                    refPreparationFailure = outcome
                    return false
                }
            }

            if headSymbolicTarget != nil {
                // Der erwartete Symbolic-Target-Wert wird anschließend unter
                // beiden Locks durch die vollständige Reinspektion bestätigt.
                _ = prepareRef(commands: "verify \(headRef) \(headOID)\n",
                               lockPaths: refLockPaths)
            } else {
                let noDeref = headRefNeedsNoDeref ? "option no-deref\n" : ""
                _ = prepareRef(commands: "\(noDeref)verify \(headRef) \(headOID)\n",
                               lockPaths: [worktreeHeadPath + ".lock"])
            }

            if let refPreparationFailure {
                for transaction in refTransactions.reversed() {
                    _ = transaction.conclude(commit: false)
                }
                try? input.fileHandleForWriting.close()
                process.waitUntilExit()
                _ = readers.wait(timeout: .now() + 1)
                let indexTermination = indexToken.finish()
                cancellation.finish()
                let outcome: GitExecutionOutcome
                switch indexTermination {
                case .cancelled: outcome = .cancelled
                case .timedOut: outcome = .timedOut
                case nil: outcome = refPreparationFailure
                }
                DispatchQueue.main.async { completion(outcome, false) }
                return
            }

            let decision = GitLockDecision()
            let decided = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                verify { approved in
                    decision.setOnce(approved)
                    decided.signal()
                }
            }
            while process.isRunning,
                  refTransactions.allSatisfy({ $0.process.isRunning }),
                  decided.wait(timeout: .now() + 0.05) == .timedOut {}
            let approved = decision.get() == true
                && process.isRunning
                && refTransactions.allSatisfy { $0.process.isRunning }
            let mayCommit = approved && cancellation.beginCommit()
            let postSubmitDeadline = GitPostSubmitDeadline()
            if mayCommit {
                postSubmitDeadline.schedule(
                    after: postSubmitTimeout,
                    tokens: [indexToken] + refTransactions.map(\.token)
                )
            }
            var recordWasWritten = false
            if mayCommit {
                do {
                    try input.fileHandleForWriting.write(contentsOf: record)
                    recordWasWritten = true
                    postSubmitProcessGroups?([groupID] + refTransactions.map(\.groupID))
                    DispatchQueue.main.async(execute: commitBoundaryReached)
                } catch {
                    recordWasWritten = false
                }
            }
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            _ = readers.wait(timeout: .now() + 1)
            let stdout = stdoutCapture.snapshot()
            let stderr = stderrCapture.snapshot()
            let result = GitResult(
                exitCode: process.terminationStatus,
                stdoutData: stdout.data, stderrData: stderr.data,
                stdoutWasTruncated: stdout.truncated,
                stderrWasTruncated: stderr.truncated
            )
            let indexTermination = indexToken.finish()
            let indexSucceeded: Bool
            switch indexTermination {
            case nil: indexSucceeded = result.ok
            case .cancelled, .timedOut: indexSucceeded = false
            }
            let commitRefs = recordWasWritten && indexSucceeded
            let refConclusions = refTransactions.reversed().map {
                $0.conclude(commit: commitRefs)
            }
            let postSubmitExpired = postSubmitDeadline.finish()
            let refResult = refConclusions.first?.result ?? result
            let outcome: GitExecutionOutcome
            let wasCancelled: Bool
            let didTimeOut: Bool
            let refTerminations = refConclusions.compactMap(\.termination)
            switch indexTermination {
            case .cancelled:
                wasCancelled = true; didTimeOut = false
            case .timedOut:
                wasCancelled = false; didTimeOut = true
            case nil:
                wasCancelled = refTerminations.contains { reason in
                    if case .cancelled = reason { return true }
                    return false
                }
                didTimeOut = !wasCancelled && refTerminations.contains { reason in
                    if case .timedOut = reason { return true }
                    return false
                }
            }
            if postSubmitExpired {
                outcome = .captureFailed(GitCaptureFailure(
                    stdoutError: L10n.string(
                        "Git antwortete nach dem Einreichen der Indexänderung nicht rechtzeitig. Das Ergebnis ist ungewiss; Fastra liest den aktuellen Git-Zustand neu ein."
                    ),
                    stderrError: nil,
                    partialResult: result
                ))
            } else if wasCancelled {
                outcome = .cancelled
            } else if didTimeOut {
                outcome = .timedOut
            } else if stdout.error != nil || stderr.error != nil {
                outcome = .captureFailed(GitCaptureFailure(
                    stdoutError: stdout.error, stderrError: stderr.error,
                    partialResult: result
                ))
            } else if let failedCapture = refConclusions.first(where: {
                $0.captureError != nil
            }) {
                outcome = .captureFailed(GitCaptureFailure(
                    stdoutError: nil, stderrError: failedCapture.captureError,
                    partialResult: failedCapture.result
                ))
            } else if !result.ok {
                outcome = .completed(result)
            } else if let failedRef = refConclusions.first(where: { !$0.result.ok }) {
                outcome = .completed(failedRef.result)
            } else if let failedProtocol = refConclusions.first(where: {
                !$0.protocolSucceeded
            }) {
                outcome = .captureFailed(GitCaptureFailure(
                    stdoutError: L10n.string(
                        "Git bestätigte den Abschluss der sicheren Referenztransaktion nicht."),
                    stderrError: nil, partialResult: failedProtocol.result
                ))
            } else {
                outcome = .completed(refResult)
            }
            cancellation.finish()
            DispatchQueue.main.async { completion(outcome, recordWasWritten) }
        }
        return cancellation
    }

    /// Injizierbarer Prozesskern für deterministische Tests und spätere
    /// kontrollierte Git-CLI-Fixtures. Führt niemals über eine Shell aus.
    @discardableResult
    static func runExecutable(_ executableURL: URL, arguments: [String],
                              in directory: URL,
                              environment additions: [String: String] = [:],
                              editorPolicy: GitEditorPolicy = .reject,
                              outputLimit: GitOutputLimit = .default,
                              policy: GitExecutionPolicy = .default,
                              readerWait: @escaping (DispatchGroup, DispatchTime)
                                  -> DispatchTimeoutResult = { group, deadline in
                                      group.wait(timeout: deadline)
                                  },
                              completionQueue: DispatchQueue = .main,
                              completion: @escaping (GitExecutionOutcome) -> Void)
        -> GitCancellationToken {
        let token = GitCancellationToken(
            terminationGracePeriod: policy.terminationGracePeriod
        )
        DispatchQueue.global(qos: .userInitiated).async {
            guard let launcherURL = processGroupLauncherURL else {
                completionQueue.async {
                    completion(.startFailed(.launchFailed(
                        L10n.string("Der sichere Git-Prozesslauncher fehlt."))))
                }
                return
            }
            let process = Process()
            process.executableURL = launcherURL
            process.arguments = [FastraProcessGroupLauncher.flag,
                                 executableURL.path] + arguments
            process.currentDirectoryURL = directory
            process.environment = sanitizedEnvironment(
                base: ProcessInfo.processInfo.environment,
                additions: additions,
                editorPolicy: editorPolicy
            )

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdinPipe = policy.standardInput == nil ? nil : Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = stdinPipe ?? FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                completionQueue.async {
                    completion(.startFailed(.launchFailed(error.localizedDescription)))
                }
                return
            }
            let pid = process.processIdentifier
            // Der Launcher setzt die Gruppe vor exec. Vor dem Attach warten wir
            // kurz auf genau diesen Zustand; ein Abbruch vor Attach wird im
            // Token gespeichert und unmittelbar danach auf die Gruppe angewandt.
            var groupID: pid_t?
            for _ in 0..<500 {
                if Darwin.getpgid(pid) == pid { groupID = pid; break }
                if !process.isRunning { break }
                usleep(1_000)
            }
            guard groupID != nil else {
                process.terminate()
                process.waitUntilExit()
                completionQueue.async {
                    completion(.startFailed(.launchFailed(
                        L10n.string("Der Git-Prozess konnte nicht sicher isoliert werden."))))
                }
                return
            }
            token.attach(process, processGroupID: groupID)
            token.scheduleTimeout(policy.timeout)
            if let input = policy.standardInput, let stdinPipe {
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try stdinPipe.fileHandleForWriting.write(contentsOf: input) }
                    catch { /* Ein früh beendeter Git-Prozess darf die Pipe schließen. */ }
                    try? stdinPipe.fileHandleForWriting.close()
                }
            }

            // stdout und stderr MÜSSEN gleichzeitig geleert werden. Schreibt ein
            // Prozess in beide vollen Pipe-Puffer, würde serielles Lesen trotz
            // Hintergrundthread blockieren.
            let stdoutCapture = PipeCapture()
            let stderrCapture = PipeCapture()
            let readers = DispatchGroup()
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stdoutCapture.store(drain(stdoutPipe.fileHandleForReading,
                                          retainingAtMost: outputLimit.stdoutBytes))
                readers.leave()
            }
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stderrCapture.store(drain(stderrPipe.fileHandleForReading,
                                          retainingAtMost: outputLimit.stderrBytes))
                readers.leave()
            }
            process.waitUntilExit()

            // Ein Kindprozess kann die geerbten Pipe-Deskriptoren offen halten,
            // obwohl der gestartete Elternprozess nach Timeout/Abbruch schon
            // beendet ist. Auf EOF unbegrenzt zu warten würde dann den Git-Slot
            // für immer blockieren. Nach einer kurzen Drain-Frist schließen wir
            // nur unsere Leseenden; der Git-Prozess ist zu diesem Zeitpunkt weg.
            if readerWait(readers, .now() + 0.5) == .timedOut {
                stdoutPipe.fileHandleForReading.closeFile()
                stderrPipe.fileHandleForReading.closeFile()
                if readerWait(readers, .now() + 0.5) == .timedOut {
                    let error = L10n.string("Git-Ausgabe blieb nach dem Schließen der Pipe unvollständig.")
                    stdoutCapture.markForcedIncomplete(error)
                    stderrCapture.markForcedIncomplete(error)
                }
            }

            let stdout = stdoutCapture.snapshot()
            let stderr = stderrCapture.snapshot()

            let result = GitResult(
                exitCode: process.terminationStatus,
                stdoutData: stdout.data,
                stderrData: stderr.data,
                stdoutWasTruncated: stdout.truncated,
                stderrWasTruncated: stderr.truncated
            )
            let outcome: GitExecutionOutcome
            switch token.finish() {
            case .cancelled: outcome = .cancelled
            case .timedOut: outcome = .timedOut
            case nil:
                if stdout.error != nil || stderr.error != nil {
                    outcome = .captureFailed(GitCaptureFailure(
                        stdoutError: stdout.error,
                        stderrError: stderr.error,
                        partialResult: result
                    ))
                } else {
                    outcome = .completed(result)
                }
            }
            completionQueue.async { completion(outcome) }
        }
        return token
    }

    private final class PipeCapture {
        private let lock = NSLock()
        private var value = CapturedPipe(data: Data(), truncated: false, error: nil)
        private var forcedIncompleteError: String?

        func store(_ captured: CapturedPipe) {
            lock.lock()
            var captured = captured
            if captured.error == nil {
                captured.error = forcedIncompleteError
            }
            value = captured
            lock.unlock()
        }

        /// Der Reader darf nach dem garantierten Completion-Pfad noch
        /// zurückkehren. Dieser Marker verhindert, dass sein spätes Ergebnis
        /// den bereits festgestellten unvollständigen Capture wieder grün färbt.
        func markForcedIncomplete(_ error: String) {
            lock.lock()
            forcedIncompleteError = error
            if value.error == nil { value.error = error }
            lock.unlock()
        }

        func snapshot() -> CapturedPipe {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private struct CapturedPipe {
        var data: Data
        var truncated: Bool
        var error: String?
    }

    /// Liest kleine Chunks und behält nur den erlaubten Präfix im Speicher.
    /// Das darüber hinausgehende Material wird weiter aus der Pipe entfernt,
    /// aber bewusst nicht gesammelt.
    private static func drain(_ handle: FileHandle, retainingAtMost limit: Int)
        -> CapturedPipe {
        let safeLimit = max(0, limit)
        var retained = Data()
        var truncated = false
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            } catch {
                return CapturedPipe(data: retained, truncated: truncated,
                                    error: error.localizedDescription)
            }
            if chunk.isEmpty { break }
            let remaining = max(0, safeLimit - retained.count)
            if remaining > 0 { retained.append(chunk.prefix(remaining)) }
            if chunk.count > remaining { truncated = true }
        }
        return CapturedPipe(data: retained, truncated: truncated, error: nil)
    }

    /// Liest genau eine kleine LF-terminierte Antwort des transaktionalen
    /// `update-ref --stdin`-Protokolls. EOF, ungültiges UTF-8 oder unerwartet
    /// große Antworten gelten als fehlende Bestätigung.
    private static func readProtocolLine(_ handle: FileHandle) -> String? {
        var data = Data()
        while data.count <= 4096 {
            let byte: Data
            do { byte = try handle.read(upToCount: 1) ?? Data() }
            catch { return nil }
            guard !byte.isEmpty else { return nil }
            if byte[byte.startIndex] == 0x0A {
                return String(data: data, encoding: .utf8)
            }
            data.append(byte)
        }
        return nil
    }

    /// Entfernt nur Variablen, die Repository, Index, Objektgraph oder
    /// Git-Konfiguration auf einen anderen Ort umlenken können. PATH, SSH- und
    /// Credential-Helper-Umgebung bleiben erhalten.
    static func sanitizedEnvironment(base: [String: String],
                                     additions: [String: String] = [:],
                                     editorPolicy: GitEditorPolicy = .reject)
        -> [String: String] {
        var result = base
        for (key, value) in additions { result[key] = value }
        let forbidden = Set([
            "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
            "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_QUARANTINE_PATH", "GIT_REPLACE_REF_BASE", "GIT_GRAFT_FILE",
            "GIT_SHALLOW_FILE", "GIT_NAMESPACE", "GIT_PREFIX",
            "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM",
            "GIT_CONFIG", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM",
            "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS",
            // Diese Variablen ändern zwar nicht den Worktree-Pfad, können aber
            // Unterprogramme, Hooks oder Diff-Programme aus fremden Umgebungen
            // einschleusen beziehungsweise Schreib-Locks global abschalten.
            "GIT_EXEC_PATH", "GIT_TEMPLATE_DIR", "GIT_EXTERNAL_DIFF",
            "GIT_DIFF_OPTS", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR",
            "GIT_OPTIONAL_LOCKS", "GIT_ATTR_SOURCE",
        ])
        result = result.filter { key, _ in
            !forbidden.contains(key)
                && !key.hasPrefix("GIT_CONFIG_KEY_")
                && !key.hasPrefix("GIT_CONFIG_VALUE_")
        }
        result["GIT_TERMINAL_PROMPT"] = "0"
        // Auch GUI-fähige Askpass-Programme aus Umgebung oder core.askPass
        // dürfen in der headless Git-Pipeline niemals ein Fenster öffnen.
        // Credential-/Keychain-Helper bleiben für gespeicherte Daten erhalten.
        result["GIT_ASKPASS"] = "/usr/bin/false"
        result["SSH_ASKPASS"] = "/usr/bin/false"
        result["SSH_ASKPASS_REQUIRE"] = "never"
        result["GIT_LITERAL_PATHSPECS"] = "1"
        result["GIT_EDITOR"] = editorPolicy.command
        result["GIT_SEQUENCE_EDITOR"] = editorPolicy.command
        return result
    }

    /// Fragt den aktiven Developer-Ordner über `xcode-select -p` ab (dialogfrei).
    private static func queryXcodeSelect() -> String? {
        let path = "/usr/bin/xcode-select"
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()   // stderr verschlucken (Fehlermeldung bei fehlenden Tools)
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let dir = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.isEmpty ? nil : dir
    }
}
