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
func runTestProcess(_ executable: String, arguments: [String],
                    environment: [String: String]? = nil,
                    timeout: TimeInterval = 120) throws -> TestProcessResult {
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
    let operations = ProcessGroupOperations.live
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
func stopTestFixtureProcess(_ pid: pid_t, marker: String) {
    let operations = ProcessGroupOperations.live
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
