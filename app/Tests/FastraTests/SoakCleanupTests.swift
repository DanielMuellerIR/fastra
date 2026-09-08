import Darwin
import Foundation
import Testing

private let soakRunnerAppDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite("Dauertest-Runner", .serialized)
struct SerialRunnerIntegrationSoakCleanupTests {
    @Test("EXIT-Pfad wartet nicht auf ungeklärte Prozesse und behält Sicherungen",
          arguments: ["early_cleanup", "cleanup"])
    func preservesRecoveryAfterTerminationFailure(function: String) throws {
        // Die echte EXIT-Funktion läuft mit kontrollierten Außenwirkungen.
        // Der übrige Runner würde echte Preferences sichern und App-Phasen starten.
        let definition = try shellFunction(named: function,
                                           in: soakRunnerAppDirectory.appendingPathComponent("soak-test.sh"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-soak-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = #"""
        set -u
        . "$1"
        WORK_ROOT="$2"
        WORK_DIR="$2"
        LOG="$2/findings.log"
        PASTEBOARD_BACKUP="$2/absent.plist"
        SOAK_PRODUCT_DEFAULTS_BACKUP=""
        SOAK_APP_STARTED=0
        SOAK_PHASE_PID=4242
        FASTRA_TEST_PENDING_PID=4242
        FASTRA_TEST_SANDBOX="$2"
        : > "$LOG"
        terminate_fastra_test_process_trees() { printf 'TERMINATION_ATTEMPT\n'; return 1; }
        # Der Test beobachtet den Aufruf selbst. Ein echtes wait auf einen
        # nicht beendbaren Prozess würde hier den gesamten Prüflauf aufhalten.
        wait() { printf 'UNEXPECTED_WAIT\n'; return 99; }
        fastra_test_pending_start_was_released() { return 1; }
        release_fastra_gui_test_lock() { printf 'LOCK_RELEASED\n'; }
        release_fastra_test_sandbox() { printf 'UNEXPECTED_SANDBOX_RELEASE\n'; }
        restore_product_defaults() { printf 'UNEXPECTED_RESTORE\n'; }
        restore_product_saved_state() { printf 'UNEXPECTED_RESTORE\n'; }
        restore_soak_pasteboard() { printf 'UNEXPECTED_RESTORE\n'; }
        purge_soak_defaults() { printf 'UNEXPECTED_PURGE\n'; }
        purge_fastra_registered_test_defaults() { printf 'UNEXPECTED_PURGE\n'; }
        fastra_test_discard_pending_session() { printf 'UNEXPECTED_PENDING_DISCARD\n'; }
        mktemp() { mkdir -p "$WORK_ROOT/evidence"; printf '%s\n' "$WORK_ROOT/evidence"; }
        prune_soak_evidence() { :; }
        """# + definition + "\ntrue\n\(function)\n"
        let result = try runTestProcess("/bin/bash", arguments: [
            "-c", script, "soak-cleanup", soakRunnerAppDirectory.appendingPathComponent("tools/soak-process-state.sh").path,
            root.path,
        ])
        #expect(result.status == 2, "\(function): \(result.output)")
        #expect(!result.output.contains("UNEXPECTED_"), "\(function): \(result.output)")
        #expect(result.output.contains("LOCK_RELEASED"))
        #expect(result.output.contains(root.path), "Pfad zur erhaltenen Sicherung fehlt")
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test("App-Auswahl folgt dem gestarteten Binary und schützt den Cleanup-Pfad",
          arguments: ["default", "bundle", "binary", "mismatch", "missing", "outside"])
    func resolvesConfiguredApp(mode: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-soak-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for bundle in [".build/debug/Fastra.app", "Configured App.app", "Actual App.app"] {
            let binary = root.appendingPathComponent(bundle + "/Contents/MacOS/Fastra")
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "#!/bin/sh\nexit 99\n".write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        let script = try shellFunction(named: "configure_soak_app",
                                       in: soakRunnerAppDirectory.appendingPathComponent("soak-test.sh")) + #"""

        set -u
        cd "$1"
        unset FASTRA_SELFTEST_APP_BIN FASTRA_SELFTEST_APP_BUNDLE
        case "$2" in
          bundle) FASTRA_SELFTEST_APP_BUNDLE="$1/Configured App.app" ;;
          binary) FASTRA_SELFTEST_APP_BIN="$1/Actual App.app/Contents/MacOS/Fastra" ;;
          mismatch)
            FASTRA_SELFTEST_APP_BUNDLE="$1/Configured App.app"
            FASTRA_SELFTEST_APP_BIN="$1/Actual App.app/Contents/MacOS/Fastra"
            ;;
          missing) FASTRA_SELFTEST_APP_BIN="$1/absent" ;;
          outside) FASTRA_SELFTEST_APP_BIN=/usr/bin/true ;;
        esac
        configure_soak_app || exit $?
        printf '%s\n%s\n' "$BINARY" "$APP_BUNDLE_CANONICAL"
        """#
        let result = try runTestProcess("/bin/bash", arguments: ["-c", script, "soak-app", root.path, mode])
        if mode == "missing" || mode == "outside" {
            #expect(result.status == 2, "\(result.output)")
        } else {
            let bundle = mode == "default" ? ".build/debug/Fastra.app"
                : mode == "bundle" ? "Configured App.app" : "Actual App.app"
            // Foundation kürzt /private/var zu /var. Hier gilt wie im
            // Shell-Runner der physische Pfad, den POSIX realpath liefert.
            let resolved = try #require(root.appendingPathComponent(bundle).path.withCString {
                realpath($0, nil)
            })
            defer { free(resolved) }
            let expected = String(cString: resolved)
            #expect(result.status == 0, "\(result.output)")
            #expect(result.output == "\(expected)/Contents/MacOS/Fastra\n\(expected)\n")
        }
    }

}
