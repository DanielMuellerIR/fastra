import Darwin
import Foundation
import Testing
@testable import Fastra

@Suite("Begrenzte Testprozesse", .serialized)
struct SerialRunnerIntegrationTestProcessTests {
    @Test("Ausgabe größer als die Pipe, Exit und Umgebung bleiben erhalten")
    func drainsLargeOutputAndPreservesContract() throws {
        let result = try runTestProcess("/usr/bin/python3", arguments: ["-c", """
            import os, sys
            assert sys.stdin.read() == ''
            sys.stdout.write('ä' * 100000)
            sys.stdout.flush()
            sys.stderr.write(os.environ['FASTRA_HELPER_FIXTURE'])
            sys.exit(7)
            """], environment: ["FASTRA_HELPER_FIXTURE": "fertig"])
        #expect(result.status == 7)
        #expect(result.output == String(repeating: "ä", count: 100_000) + "fertig")
    }

    @Test("Startfehler wirft, statt eine uninitialisierte PID zu verwenden")
    func rejectsMissingExecutable() {
        #expect(throws: POSIXError.self) {
            try runTestProcess("/fastra-missing-\(UUID().uuidString)", arguments: [])
        }
    }

    @Test("Signalstatus entspricht Foundation.Process")
    func preservesSignalStatus() throws {
        let result = try runTestProcess("/bin/sh", arguments: ["-c", "kill -KILL $$"])
        #expect(result.status == SIGKILL)
    }

    @Test("Timeout beendet TERM-resistentes Kind und Elternprozess")
    func escalatesAndRetainsDiagnostics() throws {
        try expectTimeout("""
            trap '' TERM
            /bin/sleep 30 &
            printf '%s %s\n' "$$" "$!"
            wait
            """)
    }

    @Test("Geerbte offene Pipe bleibt auch nach Elternende begrenzt")
    func boundsInheritedPipeAfterParentExit() throws {
        try expectTimeout("""
            /bin/sleep 30 &
            printf '%s %s\n' "$$" "$!"
            exit 0
            """)
    }

    /// Die Frist gilt auch, wenn die Pipe von einem Kind AUSSERHALB der
    /// eigenen Prozessgruppe offengehalten wird. `boundsInheritedPipeAfterParentExit`
    /// prüft nur ein Enkelkind derselben Gruppe — das wird beim Timeout
    /// mitsignalisiert und schließt die Pipe dadurch selbst. Ein per
    /// `setsid` abgesetztes Kind bekommt bewusst kein Signal (die
    /// Aufräumarbeit bleibt auf die eigene Gruppe begrenzt), hält die Pipe
    /// also bis zu seinem eigenen Ende offen. Der Helfer muss trotzdem
    /// innerhalb der Frist zurückkehren (Review-Hinweis 2026-09-17).
    @Test("Frist gilt auch bei geerbter Pipe in fremder Prozessgruppe")
    func boundsInheritedPipeFromForeignProcessGroup() throws {
        let root = testTemporaryDirectory()
            .appendingPathComponent("fastra-foreign-pipe-\(UUID().uuidString)")
        let ready = root.appendingPathComponent("ready")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Das Kind erbt stdout (die Pipe), läuft aber in eigener Sitzung und
        // endet nach sechs Sekunden auch ohne jedes Signal von selbst.
        let script = """
            import os, pathlib, subprocess, sys
            child = subprocess.Popen(
                ['/usr/bin/python3', '-c', 'import time; time.sleep(6)', sys.argv[1]],
                start_new_session=True, stdin=subprocess.DEVNULL)
            ready = pathlib.Path(sys.argv[1])
            staged = ready.with_suffix('.tmp')
            staged.write_text(str(os.getpid()) + ' ' + str(child.pid))
            staged.replace(ready)
            sys.exit(0)
            """
        let start = ProcessInfo.processInfo.systemUptime
        var timedOut = false
        do {
            let result = try runTestProcess("/usr/bin/python3",
                                            arguments: ["-c", script, ready.path],
                                            timeout: 1)
            Issue.record("Offene Pipe eines fremden Kindes meldete Erfolg: \(result.output)")
        } catch let error as TestProcessTimeout {
            timedOut = true
            // Die Zusage ist genau diese: Rückkehr innerhalb der Frist plus
            // Eskalationszuschlag, obwohl die Pipe noch offen ist.
            #expect(ProcessInfo.processInfo.systemUptime - start < 3,
                    "Frist überschritten: \(error.output)")
        }
        #expect(timedOut)
        // Auf einer stark belasteten Maschine kann das atomare Umbenennen der
        // Diagnosedatei knapp nach dem Fristablauf fertig werden.
        let fileDeadline = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: ready.path),
              ProcessInfo.processInfo.systemUptime < fileDeadline { usleep(10_000) }
        let pids = try String(contentsOf: ready, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
        try #require(pids.count == 2 && pids.allSatisfy { $0 > 1 },
                     "Diagnoseausgabe der Fixture fehlt")
        // Nachweis, dass der Test wirklich den fremden Fall prüft: Das Kind
        // leitet seine eigene Gruppe, der abgewartete Elternprozess eine andere.
        #expect(getpgid(pids[1]) == pids[1])
        #expect(getpgid(pids[1]) != pids[0])
        // Der Elternprozess wurde abgeholt; das abgesetzte Kind lebt weiter und
        // räumt sich selbst auf — so ist die Grenze der Zusage dokumentiert.
        #expect(kill(pids[1], 0) == 0, "Das abgesetzte Kind sollte noch laufen")
        stopTestFixtureProcess(pids[1], marker: ready.path)
    }

    @Test("Fixture-Cleanup verlangt den Marker und begrenzt Kind-Signale auf das Kind",
          arguments: [true, false])
    func stopsOnlyIdentifiedFixtureProcesses(leader: Bool) throws {
        let root = testTemporaryDirectory()
            .appendingPathComponent("fastra-cleanup-\(UUID().uuidString)")
        let ready = root.appendingPathComponent("ready")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Auch bei einem defekten Cleanup endet diese unabhängige Fixture nach
        // acht Sekunden selbst. Kein geprüfter Runner muss sie dafür aufräumen.
        let script = """
            import os, pathlib, signal, sys, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            child = os.fork()
            if child == 0:
                time.sleep(8)
                os._exit(0)
            ready = pathlib.Path(sys.argv[1])
            staged = ready.with_suffix('.tmp')
            staged.write_text(str(os.getpid()) + ' ' + str(child))
            staged.replace(ready)
            time.sleep(8)
            """
        let launch = try runTestProcess("/usr/bin/python3", arguments: ["-c", """
            import subprocess, sys
            subprocess.Popen(['/usr/bin/python3', '-c', sys.argv[1], sys.argv[2]],
                             start_new_session=True, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            """, script, ready.path])
        try #require(launch.status == 0)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: ready.path),
              ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        let pids = try String(contentsOf: ready, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
        try #require(pids.count == 2 && pids.allSatisfy { $0 > 1 })
        defer { stopTestFixtureProcess(pids[0], marker: ready.path) }

        stopTestFixtureProcess(pids[0], marker: root.appendingPathComponent("foreign").path)
        stopTestFixtureProcess(pids[0], marker: "")
        #expect(kill(pids[0], 0) == 0, "Falscher oder leerer Marker darf nichts beenden")
        let target = leader ? pids[0] : pids[1]
        stopTestFixtureProcess(target, marker: ready.path)
        // launchd beziehungsweise der noch lebende Elternprozess können einen
        // beendeten Prozess kurz als Zombie behalten. Er arbeitet dann nicht mehr.
        let state = try runTestProcess("/bin/ps", arguments: ["-p", "\(target)", "-o", "stat="])
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(state.isEmpty || state.hasPrefix("Z"))
        if leader {
            let childState = try runTestProcess("/bin/ps", arguments: ["-p", "\(pids[1])", "-o", "stat="])
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(childState.isEmpty || childState.hasPrefix("Z"))
        } else {
            #expect(kill(pids[0], 0) == 0, "Ein Kind legitimiert kein Signal an die ganze Gruppe")
        }
    }

    private func expectTimeout(_ script: String) throws {
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try runTestProcess("/bin/sh", arguments: ["-c", script], timeout: 0.5)
            Issue.record("Hängender Prozess meldete Erfolg")
        } catch let error as TestProcessTimeout {
            #expect(ProcessInfo.processInfo.systemUptime - start < 3)
            let pids = error.output.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
            #expect(pids.count == 2, "Diagnoseausgabe fehlt: \(error.output)")
            for pid in pids where pid > 0 {
                // Verwaiste Enkel werden von launchd abgeholt. Das kann etwas
                // später geschehen als das Schließen ihrer geerbten Pipe.
                for _ in 0..<100 where kill(pid, 0) == 0 { usleep(10_000) }
                #expect(kill(pid, 0) == -1 && errno == ESRCH,
                        "Eigener Prozess \(pid) blieb nach Timeout aktiv")
            }
        }
    }
}

/// Die drei Ausgangslagen des Notausgang-Tests.
enum FixtureReuseCase: Equatable, Sendable {
    /// Alles unverändert — die Fixture gehört wirklich noch uns.
    case unchanged
    /// Die PID wird nach dem Marker-Nachweis neu vergeben.
    case pidReused
    /// Die Gruppen-ID lebt wieder, ihr Leiter ist aber ein fremder Prozess.
    case groupLeaderReplaced
}

/// Deterministische Attrappe der Kernel-Abfragen aus `TestProcess.swift`.
/// Startzeit-Kennungen kommen aus einer Regel statt aus `sysctl`, Signale
/// werden nur protokolliert. So lässt sich eine neu vergebene PID oder
/// Gruppen-ID durchspielen, ohne darauf zu warten, dass macOS eine Nummer
/// wirklich zweimal ausgibt (Review-Hinweis 2026-09-17).
private final class StubProcessWorld: @unchecked Sendable {
    private let lock = NSLock()
    private let tokenRule: (pid_t, Int) -> UInt64?
    private let groupRule: (pid_t) -> [ProcessIdentity]
    private var tokenQueries = 0
    private var queriedGroups: [pid_t] = []
    private var signals: [(pid: pid_t, signal: Int32)] = []

    /// `tokenRule` bekommt zusätzlich die laufende Nummer der Abfrage. Damit
    /// kann ein Test die Startzeit MITTEN im Ablauf wechseln lassen — genau
    /// der Fall, gegen den die Wächter gebaut sind.
    init(tokenRule: @escaping (pid_t, Int) -> UInt64?,
         groupRule: @escaping (pid_t) -> [ProcessIdentity]) {
        self.tokenRule = tokenRule
        self.groupRule = groupRule
    }

    var recordedSignals: [(pid: pid_t, signal: Int32)] {
        lock.lock(); defer { lock.unlock() }
        return signals
    }

    var firstQueriedGroup: pid_t? {
        lock.lock(); defer { lock.unlock() }
        return queriedGroups.first
    }

    var operations: ProcessGroupOperations {
        ProcessGroupOperations(
            groupSnapshot: { [self] group in
                lock.lock()
                queriedGroups.append(group)
                lock.unlock()
                return groupRule(group)
            },
            startToken: { [self] pid in
                lock.lock()
                tokenQueries += 1
                let query = tokenQueries
                lock.unlock()
                return tokenRule(pid, query)
            },
            signalProcess: { [self] pid, signal in
                lock.lock()
                signals.append((pid, signal))
                lock.unlock()
            }
        )
    }
}

@Suite("Wiederverwendete Prozessnummern im Testprozesshelfer", .serialized)
struct SerialRunnerIntegrationTestProcessIdentityTests {
    /// Der Timeout-Pfad von `runTestProcess` signalisiert nur Mitglieder mit
    /// unveränderter Startzeit. Mit echten Prozessen ist das nicht herstellbar:
    /// Niemand kann erzwingen, dass macOS eine Gruppen-ID neu vergibt. Über die
    /// Attrappe wird der Wächter dagegen direkt prüfbar.
    @Test("Neu vergebene Gruppen-ID bleibt beim Timeout unberührt",
          arguments: [true, false])
    func timeoutChecksEachMemberIdentity(leaderWasReused: Bool) {
        let world = StubProcessWorld(
            // Jede lebende PID trägt in dieser Welt dieselbe Startzeit 111.
            tokenRule: { _, _ in 111 },
            groupRule: { group in
                [
                    // Ein Leiter mit ANDERER Startzeit bedeutet: Die Gruppen-ID
                    // gehört längst einer fremden Gruppe.
                    ProcessIdentity(pid: group, startToken: leaderWasReused ? 222 : 111),
                    // Gemerkte Startzeit 999, aktuelle 111: Diese PID wurde
                    // seit der Momentaufnahme neu vergeben.
                    ProcessIdentity(pid: group + 100_000, startToken: 999),
                ]
            }
        )
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: TestProcessTimeout.self) {
            // `/bin/sleep` schreibt nie und endet nie von selbst. Beendet wird
            // es am Ende vom echten `kill` des Helfers, nicht von der Attrappe.
            try runTestProcess("/bin/sleep", arguments: ["30"], timeout: 0.3,
                               operations: world.operations)
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 3)
        let signals = world.recordedSignals
        if leaderWasReused {
            #expect(signals.isEmpty,
                    "Eine fremde Gruppe darf kein einziges Signal bekommen: \(signals)")
        } else {
            let leader = world.firstQueriedGroup
            #expect(leader != nil)
            #expect(signals.allSatisfy { $0.pid == leader },
                    "Nur das Mitglied mit unveränderter Startzeit darf ein Signal bekommen: \(signals)")
            #expect(signals.contains { $0.signal == SIGTERM })
            #expect(signals.contains { $0.signal == SIGKILL })
        }
    }

    /// Dasselbe für den unabhängigen Notausgang: Zwischen dem Marker-Nachweis
    /// per `ps` und dem Signal kann die PID frei werden. Die echte Fixture
    /// lebt dabei weiter — die Attrappe tötet nicht, sie protokolliert nur.
    @Test("Notausgang lässt eine wiederverwendete PID oder Gruppen-ID unberührt",
          arguments: [FixtureReuseCase.unchanged, .pidReused, .groupLeaderReplaced])
    func fixtureCleanupChecksIdentityBeforeSignalling(_ reuse: FixtureReuseCase) throws {
        let root = testTemporaryDirectory()
            .appendingPathComponent("fastra-stop-identity-\(UUID().uuidString)")
        let ready = root.appendingPathComponent("ready")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Eigene Sitzung, Marker in der Kommandozeile, Selbstende nach acht
        // Sekunden: Auch ein defekter Notausgang lässt hier nichts zurück.
        let launch = try runTestProcess("/usr/bin/python3", arguments: ["-c", """
            import pathlib, subprocess, sys
            child = subprocess.Popen(
                ['/usr/bin/python3', '-c', 'import time; time.sleep(8)', sys.argv[2]],
                start_new_session=True, stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            ready = pathlib.Path(sys.argv[1])
            staged = ready.with_suffix('.tmp')
            staged.write_text(str(child.pid))
            staged.replace(ready)
            """, ready.path, ready.path])
        try #require(launch.status == 0, "Fixture-Start: \(launch.output)")
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: ready.path),
              ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        let recorded = try String(contentsOf: ready, encoding: .utf8)
        let pid = try #require(
            pid_t(recorded.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        try #require(pid > 1)
        defer { stopTestFixtureProcess(pid, marker: ready.path) }
        // Die Fixture ist Sitzungsleiterin; der Notausgang nimmt deshalb den
        // Gruppenweg und liest die Momentaufnahme aus der Attrappe.
        try #require(getpgid(pid) == pid)

        let world = StubProcessWorld(
            tokenRule: { queried, query in
                // Nur die Fixture-PID wechselt ihre Startzeit, und zwar erst
                // nach dem Marker-Nachweis (zweite Abfrage).
                guard reuse == .pidReused, queried == pid, query > 1 else { return 100 }
                return 200
            },
            groupRule: { group in
                [
                    ProcessIdentity(pid: group,
                                    startToken: reuse == .groupLeaderReplaced ? 555 : 100),
                    ProcessIdentity(pid: group + 100_000, startToken: 999),
                ]
            }
        )
        stopTestFixtureProcess(pid, marker: ready.path, operations: world.operations)

        let signals = world.recordedSignals
        switch reuse {
        case .unchanged:
            #expect(signals.map(\.pid) == [pid],
                    "Nur die nachgewiesene Fixture darf ein Signal bekommen: \(signals)")
            #expect(signals.map(\.signal) == [SIGKILL])
        case .pidReused, .groupLeaderReplaced:
            #expect(signals.isEmpty,
                    "Eine neu vergebene Nummer darf kein Signal bekommen: \(signals)")
        }
        // Die Attrappe hat nicht wirklich signalisiert. Läuft die Fixture
        // trotzdem nicht mehr, hätte der Notausgang an ihr vorbei echt getötet.
        #expect(kill(pid, 0) == 0, "Die Attrappe darf keinen echten Kill auslösen")
    }
}
