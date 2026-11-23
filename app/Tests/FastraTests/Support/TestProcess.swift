import Darwin
import Foundation
@testable import Fastra

struct TestProcessResult {
    let status: Int32
    let output: String
}

struct TestProcessTimeout: Error, CustomStringConvertible {
    let output: String
    var description: String { "Testprozess überschritt seine Frist. Ausgabe:\n\(output)" }
}

/// Gemeinsamer Prozesshelfer für CLI-Fixtures. Die Frist gilt auch dann, wenn
/// der Elternprozess bereits endet, aber ein Kind seine Ausgabepipe offen hält.
/// Eine eigene Prozessgruppe begrenzt die Aufräumarbeit auf dieses Fixture.
///
/// `operations` bündelt die Kernel-Abfragen der Wiederverwendungs-Wächter
/// (Startzeit einer PID, Mitglieder der Prozessgruppe, Signal an genau eine
/// PID). Standard sind die echten Aufrufe; nur Tests setzen Attrappen ein und
/// spielen damit eine neu vergebene PID oder Gruppen-ID deterministisch durch.
func runTestProcess(_ executable: String, arguments: [String],
                    environment: [String: String]? = nil,
                    timeout: TimeInterval = 120,
                    operations: ProcessGroupOperations = .live) throws -> TestProcessResult {
    precondition(timeout.isFinite && timeout > 0)
    func checked(_ status: Int32) throws {
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
    }
    let pipe = Pipe()
    let input = pipe.fileHandleForReading.fileDescriptor
    let output = pipe.fileHandleForWriting.fileDescriptor
    // Nur das Leseende ist nicht blockierend; schreibende Kinder behalten den
    // normalen Pipe-Vertrag und müssen EAGAIN nicht selbst behandeln.
    guard fcntl(input, F_SETFL, O_NONBLOCK) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var actions: posix_spawn_file_actions_t?
    try checked(posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }
    try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
    try checked(posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO))
    try checked(posix_spawn_file_actions_adddup2(&actions, output, STDERR_FILENO))
    try checked(posix_spawn_file_actions_addclose(&actions, input))
    try checked(posix_spawn_file_actions_addclose(&actions, output))
    var attributes: posix_spawnattr_t?
    try checked(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    try checked(posix_spawnattr_setflags(&attributes,
        Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)))
    // Keine vom Testhost blockierten oder ignorierten Signale erben. Die
    // Fixture kann ihre eigenen Trap-Regeln anschließend ausdrücklich setzen.
    var defaults = sigset_t()
    var mask = sigset_t()
    sigfillset(&defaults)
    sigemptyset(&mask)
    try checked(posix_spawnattr_setsigdefault(&attributes, &defaults))
    try checked(posix_spawnattr_setsigmask(&attributes, &mask))
    try checked(posix_spawnattr_setpgroup(&attributes, 0))
    let values = ProcessInfo.processInfo.environment.merging(environment ?? [:]) { _, new in new }
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp = values.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }
    var pid: pid_t = 0
    try checked(posix_spawn(&pid, executable, &actions, &attributes, argv, envp))
    precondition(pid > 0)
    // Vor waitpid merken: Selbst ein sofort beendetes Kind gehört bis zum
    // Abholen seines Status noch uns; seine PID kann nicht neu vergeben werden.
    let leaderToken = operations.startToken(pid)
    var reaped = false
    var completed = false
    func signalOwnedGroup(_ signal: Int32) {
        guard let leaderToken else { return }
        let members = operations.groupSnapshot(pid)
        if let leader = members.first(where: { $0.pid == pid }),
           leader.startToken != leaderToken { return }
        for member in members where operations.startToken(member.pid) == member.startToken {
            operations.signalProcess(member.pid, signal)
        }
    }
    defer {
        if !completed {
            signalOwnedGroup(SIGKILL)
            if !reaped {
                // Das direkte Kind wurde noch nicht abgeholt: Hier ist seine
                // PID weiterhin eindeutig. Ein Kernel-Hänger darf den Test
                // trotzdem nicht am synchronen waitpid festhalten.
                kill(pid, SIGKILL)
                let child = pid
                DispatchQueue.global().async {
                    var status: Int32 = 0
                    while waitpid(child, &status, 0) == -1 && errno == EINTR {}
                }
            }
        }
    }
    try pipe.fileHandleForWriting.close()
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var timedOut = false
    var escalated = false
    var eof = false
    var status: Int32 = 0
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 32 * 1024)
    while true {
        // Pro Durchlauf höchstens einen Block lesen: Auch eine ununterbrochen
        // schreibende Fixture darf die Prüfung ihrer Frist nicht verdrängen.
        if !eof {
            let count = read(input, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            else if count == 0 { eof = true }
            else if errno != EAGAIN && errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        if !reaped {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { reaped = true }
            else if result == -1 && errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        if reaped && eof {
            if timedOut { throw TestProcessTimeout(output: String(decoding: data, as: UTF8.self)) }
            completed = true
            // waitpid kodiert regulären Exit in Bits 8–15, ein beendendes Signal
            // in Bits 0–6. Wie Foundation.Process geben wir die Signalnummer aus.
            return TestProcessResult(status: status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f,
                                     output: String(decoding: data, as: UTF8.self))
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now >= deadline && !timedOut {
            timedOut = true
            signalOwnedGroup(SIGTERM)
        }
        if now >= deadline + 0.5 && !escalated {
            escalated = true
            signalOwnedGroup(SIGKILL)
        }
        if now >= deadline + 1 {
            throw TestProcessTimeout(output: String(decoding: data, as: UTF8.self))
        }
        if eof { usleep(1_000) }
        else {
            var descriptor = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 5)
        }
    }
}

/// Unabhängiger Notausgang für abgesetzte Runner-Fixtures. Der Marker muss
/// ein zufälliger, nur dieser Fixture gehörender Pfad in der Kommandozeile sein.
/// Ohne diesen Nachweis bleibt die PID unberührt. Bei einem Gruppenleiter
/// prüfen wir jedes Mitglied einzeln; ein beliebiges Kind legitimiert dagegen
/// niemals das Beenden seiner gesamten (möglicherweise fremden) Prozessgruppe.
/// `operations` ist wie bei `runTestProcess` nur für Attrappen in Tests da.
/// Der Nachweis über `/bin/ps` bleibt absichtlich ein echter Prozessstart:
/// Er muss die wirkliche Kommandozeile der PID lesen.
func stopTestFixtureProcess(_ pid: pid_t, marker: String,
                            operations: ProcessGroupOperations = .live) {
    guard pid > 1, !marker.isEmpty,
          let token = operations.startToken(pid),
          let command = try? runTestProcess("/bin/ps", arguments: ["-ww", "-p", "\(pid)", "-o", "command="],
                                            timeout: 2),
          command.status == 0, command.output.contains(marker),
          operations.startToken(pid) == token else { return }
    let members = getpgid(pid) == pid
        ? operations.groupSnapshot(pid)
        : [ProcessIdentity(pid: pid, startToken: token)]
    // Die Momentaufnahme darf nicht schon einen neuen Gruppenleiter zeigen.
    guard members.contains(ProcessIdentity(pid: pid, startToken: token)),
          operations.startToken(pid) == token else { return }
    for member in members where operations.startToken(member.pid) == member.startToken {
        operations.signalProcess(member.pid, SIGKILL)
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    while members.contains(where: { operations.startToken($0.pid) == $0.startToken }),
          ProcessInfo.processInfo.systemUptime < deadline {
        usleep(10_000)
    }
}

/// Die Runner-Fixtures dürfen eine parallel benutzte Produkt-App nicht als
/// Teil ihrer künstlichen Prozesswelt behandeln. Nur die eine globale
/// Fremd-App-Abfrage wird ausgeblendet; Kindprozess-Abfragen gehen weiter an
/// das echte `pgrep`, damit die Cleanup-Tests aussagekräftig bleiben.
/// Die Guardregression lässt nur die echte Antwort für ihre eigene, vorher
/// bestätigte Prozessidentität durch. Startzeit und zufällige Kommandozeile
/// binden auch die Shell-Abfrage an diese Fixture.
func pathIgnoringForeignFastraProcess(in root: URL,
                                     matchingForeignProcess: ProcessIdentity? = nil) throws -> String {
    let bin = root.appendingPathComponent("bin")
    let pgrep = bin.appendingPathComponent("pgrep")
    try FileManager.default.createDirectory(
        at: bin, withIntermediateDirectories: true
    )
    var allowedPID = ""
    var allowedStart = ""
    var allowedCommand = ""
    if let identity = matchingForeignProcess,
       ProcessGroupOperations.live.startToken(identity.pid) == identity.startToken {
        let start = try runTestProcess("/bin/ps", arguments: ["-p", "\(identity.pid)", "-o", "lstart="], timeout: 2)
        let command = try runTestProcess("/bin/ps", arguments: ["-ww", "-p", "\(identity.pid)", "-o", "command="], timeout: 2)
        if start.status == 0, command.status == 0,
           ProcessGroupOperations.live.startToken(identity.pid) == identity.startToken {
            allowedPID = String(identity.pid)
            allowedStart = start.output.trimmingCharacters(in: .newlines)
            allowedCommand = command.output.trimmingCharacters(in: .newlines)
        }
    }
    func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    try #"""
    #!/bin/bash
    if [ "$#" -eq 2 ] && [ "$1" = "-f" ]; then
      case "$2" in
        '/Fastra\.app/Contents/MacOS/Fastra([[:space:]]|$)'|'/[^/]+\.app/Contents/MacOS/Fastra([[:space:]]|$)')
          [ \#(matchingForeignProcess == nil ? "0" : "1") -eq 1 ] || exit 1
          allowed_pid=\#(quoted(allowedPID))
          owned_probe() {
            [ -n "$allowed_pid" ] \
              && [ "$(/bin/ps -p "$allowed_pid" -o lstart= 2>/dev/null)" = \#(quoted(allowedStart)) ] \
              && [ "$(/bin/ps -ww -p "$allowed_pid" -o command= 2>/dev/null)" = \#(quoted(allowedCommand)) ]
          }
          owned_probe || { /usr/bin/pgrep "$@" >/dev/null; exit 1; }
          matches="$(/usr/bin/pgrep "$@")"
          owned_probe || exit 1
          while IFS= read -r matched_pid; do
            if [ "$matched_pid" = "$allowed_pid" ]; then
              owned_probe || exit 1
              printf '%s\n' "$matched_pid"
              exit 0
            fi
          done <<< "$matches"
          exit 1
          ;;
      esac
    fi
    exec /usr/bin/pgrep "$@"
    """#.write(to: pgrep, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: pgrep.path
    )
    let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    return bin.path + ":" + oldPath
}
