import Foundation
import Testing

private let soakOutcomeAppDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite("Dauertest-Ergebnisse", .serialized)
struct SerialRunnerIntegrationSoakOutcomeTests {
    @Test("Runner erhält Umgebung und gibt echten Fehlern Vorrang",
          arguments: ["pass", "empty", "env", "env_report", "mixed", "fail", "cleanup", "priorfailure", "sequence"])
    func preservesPhaseAndOverallOutcome(_ mode: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-soak-outcome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fastra")
        let log = root.appendingPathComponent("report.log")
        try "".write(to: log, atomically: true, encoding: .utf8)
        try #"""
        #!/bin/bash
        case "$FASTRA_TEST_OUTCOME_MODE" in
          pass|empty) echo 'SELFTEST soak: PASS'; exit 0 ;;
          env_report) echo 'SOAK-UMGEBUNG phase=1 aktion=? detail=Fokus' >> "$FASTRA_TEST_OUTCOME_LOG" ;;
          mixed) echo 'SOAK-BEFUND phase=1 aktion=? detail=Dateiinhalt' >> "$FASTRA_TEST_OUTCOME_LOG" ;;
          fail) echo 'SELFTEST soak: FAIL'; exit 1 ;;
        esac
        echo 'SELFTEST soak: ENV — Fokus fehlt'
        exit 2
        """#.write(to: app, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.path)
        let runner = soakOutcomeAppDirectory.appendingPathComponent("soak-test.sh")
        let functions = try ["run_phase", "run_counted_phase", "check_soak_result"]
            .map { try shellFunction(named: $0, in: runner) }.joined(separator: "\n")
        // Start und Rückgabe bleiben echte Prozesse. Nur die außerhalb der
        // Ergebnisbewertung liegenden Sandbox-/Clipboard-Dienste sind ersetzt;
        // runTestProcess hält alle Fixture-Prozesse in seiner eigenen Gruppe.
        let script = functions + #"""
        set -u
        WORK_DIR="$1"
        LOG="$2"
        BINARY="$3"
        MODE="$FASTRA_TEST_OUTCOME_MODE"
        ROUNDS=1
        APP_BUNDLE_CANONICAL=""
        FASTRA_TEST_TMPDIR="$WORK_DIR"
        FASTRA_TEST_CF_HOME="$WORK_DIR"
        SOAK_DEFAULTS_SUITE=Fastra-Test
        FASTRA_TEST_DEFAULTS_REGISTRY="$WORK_DIR/registry"
        SOAK_PROCESS_CLEANUP_BLOCKED=0
        PHASES_FAILED=0
        ENVIRONMENT_PHASES=0
        KEEP_EVIDENCE=0
        # Hier werden Ergebnisse geprüft, keine Fristen. Die echte Rückgabe
        # der kurzen Fixture-Prozesse braucht keine Sekunde Pause je Abfrage.
        sleep() { /bin/sleep 0.01; }
        fastra_test_start_new_session() { "$@" & FASTRA_TEST_STARTED_PID=$!; }
        adopt_soak_process() { :; }
        cleanup_soak_process() { :; }
        restore_soak_pasteboard() { [ "$MODE" != cleanup ]; }
        if [ "$MODE" = priorfailure ]; then
          echo 'SOAK-BEFUND phase=0 aktion=? detail=früherer Fehler' >> "$LOG"
        fi
        if [ "$MODE" = sequence ]; then
          FASTRA_TEST_OUTCOME_MODE=pass run_counted_phase 1 Probe
          FASTRA_TEST_OUTCOME_MODE=env run_counted_phase 2 Probe
          FASTRA_TEST_OUTCOME_MODE=fail run_counted_phase 3 Probe
        else
          run_counted_phase 1 Probe
        fi
        FINDINGS=$(grep -c '^SOAK-BEFUND' "$LOG")
        ACTIONS=0
        [ "$MODE" != pass ] || ACTIONS=1
        check_soak_result
        status=$?
        printf 'COUNTS failed=%s environment=%s keep=%s\n' "$PHASES_FAILED" "$ENVIRONMENT_PHASES" "$KEEP_EVIDENCE"
        printf 'LOG-BEGIN\n'
        cat "$LOG"
        exit "$status"
        """#
        let result = try runTestProcess("/bin/bash", arguments: ["-c", script, "soak-outcome", root.path, log.path, app.path],
                                        environment: ["FASTRA_TEST_OUTCOME_MODE": mode, "FASTRA_TEST_OUTCOME_LOG": log.path])
        let expected: Int32 = mode == "pass" ? 0 : (["env", "env_report"].contains(mode) ? 2 : 1)
        #expect(result.status == expected, "Dauertest-Ergebnis: \(result.output)")
        let recorded = result.output.components(separatedBy: "LOG-BEGIN\n").last ?? ""
        if expected == 2 {
            #expect(!recorded.contains("SOAK-BEFUND"))
            #expect(recorded.split(separator: "\n").filter { $0.hasPrefix("SOAK-UMGEBUNG") }.count == 1)
            #expect(result.output.contains("COUNTS failed=0 environment=1 keep=1"))
        }
        if ["mixed", "fail", "cleanup", "priorfailure"].contains(mode) {
            #expect(recorded.contains("SOAK-BEFUND"))
        }
        if mode == "pass" { #expect(result.output.contains("COUNTS failed=0 environment=0 keep=0")) }
        if mode == "sequence" {
            #expect(result.output.contains("COUNTS failed=1 environment=1 keep=1"))
            #expect(recorded.contains("SOAK-UMGEBUNG phase=2 "))
            #expect(recorded.contains("SOAK-BEFUND phase=3 "))
        }
    }
}
