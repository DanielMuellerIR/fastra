import Darwin
import Foundation
import Testing

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

    @Test("Fixture-Cleanup verlangt den Marker und begrenzt Kind-Signale auf das Kind",
          arguments: [true, false])
    func stopsOnlyIdentifiedFixtureProcesses(leader: Bool) throws {
        let root = FileManager.default.temporaryDirectory
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
