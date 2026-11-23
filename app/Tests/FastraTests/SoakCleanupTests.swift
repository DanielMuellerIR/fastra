import Darwin
import Foundation
import Testing
@testable import Fastra

private let soakRunnerAppDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite("Dauertest-Runner", .serialized)
struct SerialRunnerIntegrationSoakCleanupTests {
    enum TerminationFailure: String, CaseIterable {
        case beforeSnapshot, phase, finalHelper
    }

    @Test("Originalrunner erhält Sicherungen bei ungeklärtem Prozessende",
          arguments: TerminationFailure.allCases)
    func preservesRecoveryAfterTerminationFailure(point: TerminationFailure) throws {
        var fixture = try FullRunnerFixture()
        defer { fixture.dispose() }
        let seed = try fixture.seed()
        let files = FileManager.default
        let runner = fixture.root.appendingPathComponent("soak-test.sh")
        let tools = fixture.root.appendingPathComponent("tools")
        let originalTools = soakRunnerAppDirectory.appendingPathComponent("tools")
        let receipt = fixture.root.appendingPathComponent("termination.log")
        try files.copyItem(at: soakRunnerAppDirectory.appendingPathComponent("soak-test.sh"), to: runner)
        try files.createDirectory(at: tools, withIntermediateDirectories: false)
        for helper in try files.contentsOfDirectory(at: originalTools, includingPropertiesForKeys: nil)
            where helper.lastPathComponent != "test-process-tree.sh" {
            try files.createSymbolicLink(at: tools.appendingPathComponent(helper.lastPathComponent),
                                         withDestinationURL: helper)
        }
        // Der frühe Fall simuliert einen offenen Start vor dem Snapshot.
        // In den übrigen Fällen startet der reguläre Prozess-Handshake die Attrappen.
        try #"""
        . "$SOAK_FIXTURE_PROCESS_TOOLS"
        if [ "$SOAK_FIXTURE_TERMINATION_FAILURE" = beforeSnapshot ]; then
            FASTRA_TEST_PENDING_PID=2147483647
            pgrep() { return 0; }
        fi

        unresolved_pid=""
        terminate_fastra_test_process_trees() {
            local fault="$SOAK_FIXTURE_TERMINATION_FAILURE"
            if { [ "$fault" = beforeSnapshot ] && [ "$1" = 2147483647 ]; } \
                || { [ "$fault" = phase ] && grep -q "^phase-1 $1 " "$SOAK_FIXTURE_STARTS"; } \
                || { [ "$fault" = finalHelper ] && grep -Fxq "purge $1" "$SOAK_FIXTURE_STARTS"; }; then
                unresolved_pid="$1"
                printf 'UNCERTAIN %s\n' "$1" >> "$SOAK_FIXTURE_TERMINATION_LOG"
                return 2
            fi
            if fastra_test_pid_is_live "$1"; then
                printf 'UNEXPECTED_LIVE_PROCESS %s\n' "$1" >> "$SOAK_FIXTURE_TERMINATION_LOG"
                return 2
            fi
            return 0
        }
        wait() {
            if [ -n "$unresolved_pid" ] && [ "${1:-}" = "$unresolved_pid" ]; then
                printf 'UNEXPECTED_WAIT %s\n' "$1" >> "$SOAK_FIXTURE_TERMINATION_LOG"
                return 99
            fi
            builtin wait "$@"
        }
        """#.write(to: tools.appendingPathComponent("test-process-tree.sh"), atomically: true, encoding: .utf8)
        fixture.environment["SOAK_FIXTURE_PROCESS_TOOLS"] = originalTools.appendingPathComponent("test-process-tree.sh").path
        fixture.environment["SOAK_FIXTURE_TERMINATION_FAILURE"] = point.rawValue
        fixture.environment["SOAK_FIXTURE_TERMINATION_LOG"] = receipt.path

        let result = try fixture.run(runner)
        #expect(result.status == (point == .phase ? 1 : 2), "\(result.output)")
        #expect(!result.output.contains("UNEXPECTED_STUB_ROUTE"))
        #expect(!files.fileExists(atPath: fixture.root.appendingPathComponent("gui.lock").path))
        let sandboxes = try files.contentsOfDirectory(at: fixture.parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("fastra-soak-run.") }
        try #require(sandboxes.count == 1, "Der Runner muss seine eigene Sandbox erhalten")
        let sandbox = sandboxes[0]
        #expect(result.output.contains(sandbox.path))
        let attempts = try String(contentsOf: receipt, encoding: .utf8).split(whereSeparator: \.isNewline)
        try #require(!attempts.isEmpty)
        let routes = try fixture.routes().map { $0.split(separator: " ") }
        if point == .beforeSnapshot {
            #expect(routes.isEmpty)
            #expect(attempts == ["UNCERTAIN 2147483647"])
            #expect(try fixture.defaults(["export", "-"]).output == seed)
            #expect(try Data(contentsOf: fixture.state.appendingPathComponent("window.data")) == Data([0, 42, 255, 10]))
        } else {
            let expectedRoutes = point == .phase ? ["phase-1"] : ["phase-1", "phase-2", "phase-3", "purge"]
            #expect(routes.map { String($0[0]) } == expectedRoutes)
            let uncertainPID = try #require(routes.last?[1])
            #expect(attempts.count >= 2 && attempts.allSatisfy { $0 == "UNCERTAIN \(uncertainPID)" })
            #expect(try fixture.defaults(["read", "kept"]).output.trimmingCharacters(in: .whitespacesAndNewlines) == "9")
            #expect(try Data(contentsOf: fixture.state.appendingPathComponent("window.data")) == Data("changed\n".utf8))
            let backup = try Data(contentsOf: sandbox.appendingPathComponent("product-defaults.plist"))
            let values = try PropertyListSerialization.propertyList(from: backup, options: [], format: nil)
            #expect(values as? [String: Int] == ["kept": 1])
            let savedWindow = sandbox.appendingPathComponent("product-saved-state/window.data")
            #expect(try Data(contentsOf: savedWindow) == Data([0, 42, 255, 10]))
        }
    }

    enum AppSelection: CaseIterable {
        case standard, bundle, binary, mismatch, missing, outside
    }

    @Test("Originalrunner startet das gewählte Binary und meldet nur dessen Bundle ab",
          arguments: AppSelection.allCases)
    func resolvesConfiguredApp(mode: AppSelection) throws {
        var fixture = try FullRunnerFixture()
        defer { fixture.dispose() }
        let files = FileManager.default
        let runnerDirectory = fixture.root.appendingPathComponent("App mit Leerzeichen")
        try files.createDirectory(at: runnerDirectory, withIntermediateDirectories: false)
        let runner = runnerDirectory.appendingPathComponent("soak-test.sh")
        try files.copyItem(at: soakRunnerAppDirectory.appendingPathComponent("soak-test.sh"), to: runner)
        try files.createSymbolicLink(at: runnerDirectory.appendingPathComponent("tools"),
                                     withDestinationURL: soakRunnerAppDirectory.appendingPathComponent("tools"))
        let standard = runnerDirectory.appendingPathComponent(".build/debug/Fastra.app")
        let configured = runnerDirectory.appendingPathComponent("Configured App.app")
        let actual = runnerDirectory.appendingPathComponent("Actual App.app")
        let alias = runnerDirectory.appendingPathComponent("Linked App.app")
        let binarySuffix = "Contents/MacOS/Fastra"
        let original = URL(fileURLWithPath: try #require(fixture.environment["FASTRA_SELFTEST_APP_BIN"]))
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "de.dm0.fastra"],
                                                       format: .xml, options: 0)
        for bundle in [standard, configured, actual] {
            let binary = bundle.appendingPathComponent(binarySuffix)
            try files.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: original, to: binary)
            try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        try files.createSymbolicLink(at: alias, withDestinationURL: actual)
        let outside = runnerDirectory.appendingPathComponent("Fastra")
        try files.copyItem(at: original, to: outside)

        let launched = fixture.root.appendingPathComponent("executables.log")
        let cleanup = fixture.root.appendingPathComponent("launch-services.log")
        let lsregister = fixture.root.appendingPathComponent("fake lsregister")
        try #"""
        #!/bin/bash
        [ "$#" -eq 2 ] && [ "$1" = -u ] || exit 90
        printf '%s\n' "$@" >> "$SOAK_FIXTURE_LS_RECEIPT"
        """#.write(to: lsregister, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lsregister.path)
        fixture.environment["SOAK_FIXTURE_EXECUTABLES"] = launched.path
        fixture.environment["SOAK_FIXTURE_LS_RECEIPT"] = cleanup.path
        fixture.environment["FASTRA_TEST_LSREGISTER"] = lsregister.path
        fixture.environment["FASTRA_SELFTEST_APP_BIN"] = nil

        let expectedBundle: URL?
        switch mode {
        case .standard:
            expectedBundle = standard
        case .bundle:
            fixture.environment["FASTRA_SELFTEST_APP_BUNDLE"] = configured.path
            expectedBundle = configured
        case .binary:
            fixture.environment["FASTRA_SELFTEST_APP_BIN"] = alias.appendingPathComponent(binarySuffix).path
            expectedBundle = actual
        case .mismatch:
            fixture.environment["FASTRA_SELFTEST_APP_BUNDLE"] = configured.path
            fixture.environment["FASTRA_SELFTEST_APP_BIN"] = actual.appendingPathComponent(binarySuffix).path
            expectedBundle = actual
        case .missing:
            fixture.environment["FASTRA_SELFTEST_APP_BIN"] = runnerDirectory.appendingPathComponent("absent").path
            expectedBundle = nil
        case .outside:
            fixture.environment["FASTRA_SELFTEST_APP_BIN"] = outside.path
            expectedBundle = nil
        }
        let seed = try fixture.seed()
        let result = try fixture.run(runner)
        if let expectedBundle {
            #expect(result.status == 0, "\(result.output)")
            let executables = try String(contentsOf: launched, encoding: .utf8).split(whereSeparator: \.isNewline)
            let unregister = try String(contentsOf: cleanup, encoding: .utf8).split(whereSeparator: \.isNewline)
            #expect(executables.map(String.init) == Array(repeating: expectedBundle.appendingPathComponent(binarySuffix).path, count: 4))
            #expect(unregister.map(String.init) == ["-u", expectedBundle.path])
            #expect(try fixture.routes().map { $0.split(separator: " ")[0] } == ["phase-1", "phase-2", "phase-3", "purge"])
        } else {
            #expect(result.status == 2, "\(result.output)")
            #expect(result.output.contains(mode == .missing ? "fehlt. App-Pfad prüfen" : "eines App-Bundles liegen"))
            #expect(!files.fileExists(atPath: launched.path))
            #expect(!files.fileExists(atPath: cleanup.path))
            #expect(try fixture.routes().isEmpty)
        }
        try fixture.expectRestored(seed: seed)
    }

    private struct FullRunnerFixture {
        let root: URL
        let parent: URL
        let state: URL
        let domain: String
        let starts: URL
        let externalEvidence: URL
        var environment: [String: String]

        init() throws {
            let temporary = testTemporaryDirectory().appendingPathComponent("fastra-soak-fixture-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let physical = try #require(temporary.path.withCString { realpath($0, nil) })
            defer { free(physical) }
            root = URL(fileURLWithPath: String(cString: physical))
            parent = root.appendingPathComponent("sandboxes")
            state = parent.appendingPathComponent("fixture.savedState")
            starts = root.appendingPathComponent("starts.log")
            externalEvidence = root.appendingPathComponent("external-tmp/fastra-soak-befunde-external")
            domain = "FastraTests.SoakFixture.\(UUID().uuidString)"
            // Vor jedem CLI-Zugriff anmelden; der äußere test.sh-Nachlauf
            // entfernt auch verspätete Plists nach dem xctest-Prozessende.
            _ = testSuiteDefaults(named: domain)
            let registry = try #require(ProcessInfo.processInfo.environment["FASTRA_TEST_DEFAULTS_REGISTRY"])
            let lines = try String(contentsOfFile: registry, encoding: .utf8).split(whereSeparator: \.isNewline)
            try #require(lines.contains(Substring(domain)), "Eigene Domain fehlt im äußeren Originalrunner")
            print("SOAK-FIXTURE-REGISTRY domain=\(domain) registry=\(registry) line=\(domain)")
            for directory in [parent, externalEvidence] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            try Data([7, 0, 255]).write(to: externalEvidence.appendingPathComponent("sentinel"))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: externalEvidence.path)
            let binary = root.appendingPathComponent("Stub.app/Contents/MacOS/Fastra")
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try #"""
            #!/bin/bash
            set -eu
            fail() { printf 'UNEXPECTED_STUB_ROUTE %s\n' "$*" >&2; exit 89; }
            if [ -n "$SOAK_FIXTURE_EXECUTABLES" ]; then
              printf '%s\n' "$0" >> "$SOAK_FIXTURE_EXECUTABLES"
            fi
            fixture_workdir() {
              case "$1" in "$FASTRA_TEST_SANDBOX_PARENT"/fastra-soak-run.*/fastra-soak) [ -d "$1" ] ;; *) return 1 ;; esac
            }
            outcome="$SOAK_FIXTURE_OUTCOME"
            if [ "${2:-}" = soakpasteboardrestore ]; then
              [ "$outcome" = clipboard ] && [ "$#" -eq 8 ] && [ "$1" = -selftest ] \
                && [ "$3" = -soakDir ] && fixture_workdir "$4" && [ "$5" = -soakPhase ] \
                && [ "$6" = 2 ] && [ "$7" = -ApplePersistenceIgnoreState ] && [ "$8" = YES ] || fail "$@"
              [ "$(cat "$4/pasteboard-backup.plist")" = 'private clipboard fixture' ] || fail clipboard
              printf 'restore %s\n' "$$" >> "$SOAK_FIXTURE_STARTS"
              printf 'Fixture: Clipboard-Hilfsprozess meldet Fehler\n'
              exit 1
            fi
            if [ "$#" -eq 6 ] && [ "$1" = -selftest ] && [ "$2" = soakdefaultspurge ] \
               && [ "$3" = -soakPhase ] && [ "$4" = 2 ] \
               && [ "$5" = -ApplePersistenceIgnoreState ] && [ "$6" = YES ]; then
              printf 'purge %s\n' "$$" >> "$SOAK_FIXTURE_STARTS"
              if [ "${SOAK_FIXTURE_SIGNAL_POINT:-}" = cleanup ]; then
                kill -TERM "$(cat "$SOAK_FIXTURE_STARTS.runner-pid")"
              fi
              exit 0
            fi
            [ "$#" -eq 10 ] || fail "$@"
            [ "$1" = -selftest ] && [ "$2" = soak ] && [ "$3" = -soakPhase ] || fail "$@"
            case "$4" in 1|2|3) phase="$4" ;; *) fail "$@" ;; esac
            [ "$5" = -soakRounds ] && [ "$6" = 1 ] && [ "$7" = -soakDir ] && [ "$9" = -soakLog ] || fail "$@"
            work="$8"; log="${10}"
            fixture_workdir "$work" && [ "$log" = "$work/befunde.log" ] && [ -f "$log" ] && [ ! -L "$log" ] || fail "$@"
            if [ "$outcome" = clipboard ] && [ "$phase" != 1 ]; then
              [ "$(cat "$work/pasteboard-backup.plist")" = 'private clipboard fixture' ] || fail clipboard
            else
              [ ! -e "$work/pasteboard-backup.plist" ] || fail clipboard
            fi
            printf 'phase-%s %s %s %s\n' "$phase" "$$" "$work" "$log" >> "$SOAK_FIXTURE_STARTS"
            if [ -n "${SOAK_FIXTURE_SIGNAL_POINT:-}" ]; then
              cp "$work/../owner-pid" "$SOAK_FIXTURE_STARTS.runner-pid"
            fi
            fixture_defaults_write() {
              env -u CFFIXED_USER_HOME -u CFPREFERENCES_AVOID_DAEMON HOME="$SOAK_FIXTURE_REAL_HOME" \
                /usr/bin/defaults write "$FASTRA_SELFTEST_PRODUCT_DEFAULTS_DOMAIN" "$@"
            }
            fixture_defaults_write kept -int 9
            fixture_defaults_write addedDuringRun -int 2
            fixture_defaults_write "NSWindow Frame probe window" -string "0 0 10 10"
            mkdir -p "$FASTRA_SELFTEST_PRODUCT_SAVED_STATE_DIR"
            printf 'changed\n' > "$FASTRA_SELFTEST_PRODUCT_SAVED_STATE_DIR/window.data"
            printf 'added\n' > "$FASTRA_SELFTEST_PRODUCT_SAVED_STATE_DIR/added.data"
            if [ "$phase" = 1 ] && [ "${SOAK_FIXTURE_SIGNAL_POINT:-}" = phase ]; then
              runner=$(cat "$SOAK_FIXTURE_STARTS.runner-pid")
              kill -TERM "$runner"
              for _ in {1..40}; do
                kill -0 "$runner" 2>/dev/null || break
                sleep 0.05
              done
              exit 0
            fi
            case "$outcome:$phase" in
              clipboard:1) printf 'private clipboard fixture\n' > "$work/pasteboard-backup.plist" ;;
              envReport:1) printf 'SOAK-UMGEBUNG phase=1 aktion=? detail=Fokus\n' >> "$log" ;;
              mixed:1|priorFailure:1) printf 'SOAK-BEFUND phase=1 aktion=? detail=Dateiinhalt\n' >> "$log" ;;
            esac
            status=0
            case "$outcome:$phase" in
              normal:1) status="$SOAK_FIXTURE_EXIT" ;;
              envReport:1|mixed:1|priorFailure:2|sequence:2) status=2 ;;
              sequence:3) status=1 ;;
            esac
            case "$status" in
              1) printf 'SELFTEST soak: FAIL — fixture phase %s\n' "$phase"; exit 1 ;;
              2) printf 'SELFTEST soak: ENV — Fokus fehlt\n'; exit 2 ;;
            esac
            if [ "$outcome" != empty ]; then
              printf 'SOAK-ZUSAMMENFASSUNG aktionen=1 befunde=0 runden=1 umgebung=0\n' >> "$log"
            fi
            printf 'SELFTEST soak: PASS — fixture phase %s\n' "$phase"
            """#.write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            environment = [
                "PATH": try pathIgnoringForeignFastraProcess(in: root),
                "FASTRA_TEST_SANDBOX_PARENT": parent.path,
                "FASTRA_SELFTEST_PRODUCT_DEFAULTS_DOMAIN": domain,
                "FASTRA_SELFTEST_PRODUCT_SAVED_STATE_DIR": state.path,
                "FASTRA_SELFTEST_APP_BIN": binary.path,
                "FASTRA_GUI_LOCK_DIR": root.appendingPathComponent("gui.lock").path,
                "FASTRA_PERFORMANCE_DATA_DIR": root.appendingPathComponent("performance").path,
                "FASTRA_PERFORMANCE_BASELINE_RUN": "0",
                "SOAK_FIXTURE_STARTS": starts.path,
                "SOAK_FIXTURE_EXECUTABLES": "",
                "SOAK_FIXTURE_REAL_HOME": try #require(ProcessInfo.processInfo.environment["HOME"]),
                "SOAK_FIXTURE_EXIT": "0",
                "SOAK_FIXTURE_OUTCOME": "normal",
                "TMPDIR": externalEvidence.deletingLastPathComponent().path + "/",
                // --fixtures-only muss auch geerbte reale Quellen entfernen.
                "FASTRA_SOAK_RTFD": root.appendingPathComponent("must-not-read.rtfd").path,
                "FASTRA_SOAK_MD_DIR": root.appendingPathComponent("must-not-read-md").path,
                "FASTRA_SOAK_4D_PROJECT": root.appendingPathComponent("must-not-read-4d").path,
            ]
        }

        func dispose() {
            _ = try? runTestProcess("/usr/bin/defaults", arguments: ["delete", domain], timeout: 10)
            try? FileManager.default.removeItem(at: root)
        }

        func defaults(_ arguments: [String]) throws -> TestProcessResult {
            try runTestProcess("/usr/bin/defaults", arguments: [arguments[0], domain] + arguments.dropFirst(), timeout: 10)
        }

        func seed() throws -> String {
            let result = try defaults(["write", "kept", "-int", "1"])
            try #require(result.status == 0, "Eigene Domain vorbereiten: \(result.output)")
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try Data([0, 42, 255, 10]).write(to: state.appendingPathComponent("window.data"))
            let exported = try defaults(["export", "-"])
            try #require(exported.status == 0)
            return exported.output
        }

        func run(_ runner: URL = soakRunnerAppDirectory.appendingPathComponent("soak-test.sh")) throws -> TestProcessResult {
            let arguments = [runner.path, "--fixtures-only", "--rounds", "1"]
            // Ein aus der Fixture entfernter Wert darf nicht aus der äußeren
            // Prozessumgebung zurückkehren und eine fremde Testdomain binden.
            let absent = ["FASTRA_TEST_SANDBOX_PARENT", "FASTRA_SELFTEST_PRODUCT_DEFAULTS_DOMAIN",
                          "FASTRA_SELFTEST_PRODUCT_SAVED_STATE_DIR", "FASTRA_SELFTEST_APP_BIN",
                          "FASTRA_SELFTEST_APP_BUNDLE"].filter { environment[$0] == nil }
            let result = try runTestProcess(absent.isEmpty ? "/bin/bash" : "/usr/bin/env",
                arguments: absent.isEmpty ? arguments : absent.flatMap { ["-u", $0] } + ["/bin/bash"] + arguments,
                environment: environment)
            print("SOAK-FIXTURE-RESULT domain=\(domain) status=\(result.status)\n\(result.output)")
            return result
        }

        func routes() throws -> [String] {
            guard FileManager.default.fileExists(atPath: starts.path) else { return [] }
            return try String(contentsOf: starts, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
        }

        func expectRestored(seed: String?) throws {
            // `defaults export` liefert auch für eine fehlende Domain eine
            // leere Plist mit Status 0. Existenz deshalb wie der Runner lesen.
            let after = try defaults(seed == nil ? ["read"] : ["export", "-"])
            if let seed {
                #expect(after.status == 0 && after.output == seed, "Eigene Domain nicht semantisch restauriert: \(after.output)")
                #expect(try FileManager.default.contentsOfDirectory(atPath: state.path) == ["window.data"])
                #expect(try Data(contentsOf: state.appendingPathComponent("window.data")) == Data([0, 42, 255, 10]))
            } else {
                #expect(after.status != 0, "Neu entstandene eigene Domain blieb erhalten")
                #expect(!FileManager.default.fileExists(atPath: state.path), "Neu entstandener State blieb erhalten")
            }
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            #expect(!leftovers.contains(where: { $0.hasPrefix("fastra-soak-run.") }), "Sandbox blieb erhalten: \(leftovers)")
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("gui.lock").path))
            #expect(try Data(contentsOf: externalEvidence.appendingPathComponent("sentinel")) == Data([7, 0, 255]))
            let mode = try FileManager.default.attributesOfItem(atPath: externalEvidence.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o755, "Pruning erreichte äußeren eigenen Belegbaum")
            for route in try routes() {
                let fields = route.split(separator: " ")
                if let pid = Int32(fields[1]) {
                    #expect(ProcessGroupOperations.live.startToken(pid) == nil, "Eigener Stubprozess blieb erhalten")
                }
            }
        }

        func evidence() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("fastra-soak-befunde-") }
        }
    }

    @Test("Voller Originalrunner restauriert vorhandenen und entfernt neuen Fixturezustand",
          arguments: [false, true], [0, 1, 2])
    func fullRunnerRestoresPrivateState(existing: Bool, exit: Int) throws {
        var fixture = try FullRunnerFixture()
        defer { fixture.dispose() }
        let seed = existing ? try fixture.seed() : nil
        if !existing {
            let before = try fixture.defaults(["read"])
            try #require(before.status != 0 && before.output.contains("does not exist"),
                         "Eigene Domain muss vor dem Lauf wirklich fehlen: \(before.output)")
            try #require(!FileManager.default.fileExists(atPath: fixture.state.path))
        }
        fixture.environment["SOAK_FIXTURE_EXIT"] = String(exit)
        let result = try fixture.run()
        #expect(result.status == Int32(exit), "\(result.output)")
        if exit == 0 {
            #expect(result.output.contains("SOAK OK — 3 Aktionen"))
            #expect(result.output.contains("PERFORMANCE-LANGLAUF nicht gespeichert:"))
        }
        let routes = try fixture.routes()
        #expect(routes.count == 4, "Drei Phasen plus echte Purgeroute erwartet: \(routes)")
        #expect(routes.map { $0.split(separator: " ")[0] } == ["phase-1", "phase-2", "phase-3", "purge"])
        #expect(!result.output.contains("UNEXPECTED_STUB_ROUTE"))
        #expect(!result.output.contains("SOAK: frühes Aufräumen blieb zusätzlich unvollständig."))
        #expect(!result.output.contains("SOAK: Zusätzlich blieb das Aufräumen unvollständig."))
        try fixture.expectRestored(seed: seed)
        let evidence = try fixture.evidence()
        #expect(evidence.count == (exit == 0 ? 0 : 1), "Private Fehlerbelege: \(evidence)")
        if let directory = evidence.first {
            let log = try String(contentsOf: directory.appendingPathComponent("befunde.log"), encoding: .utf8)
            let findings = log.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("SOAK-BEFUND") }
            let environment = log.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("SOAK-UMGEBUNG") }
            if exit == 1 {
                #expect(result.output.contains("(1 Fehler, 0 Umgebung)."))
                #expect(findings.count == 1 && findings.first?.hasPrefix("SOAK-BEFUND phase=1 ") == true)
                #expect(environment.isEmpty)
            } else {
                #expect(result.output.contains("SOAK ENV — 1 von 3 Phasen"))
                #expect(findings.isEmpty)
                #expect(environment.count == 1 && environment.first?.hasPrefix("SOAK-UMGEBUNG phase=1 ") == true)
            }
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("pasteboard-backup.plist").path))
        }
    }

    enum RunnerOutcome: String, CaseIterable {
        case empty, envReport, mixed, priorFailure, sequence, clipboard
    }

    @Test("Originalrunner bewertet Phasen, Meldungen und fehlgeschlagene Wiederherstellung",
          arguments: RunnerOutcome.allCases)
    func fullRunnerPreservesOutcome(_ outcome: RunnerOutcome) throws {
        var fixture = try FullRunnerFixture()
        defer { fixture.dispose() }
        fixture.environment["SOAK_FIXTURE_OUTCOME"] = outcome.rawValue
        let seed = try fixture.seed()
        let result = try fixture.run()
        #expect(result.status == (outcome == .envReport ? 2 : 1), "\(result.output)")
        #expect(!result.output.contains("UNEXPECTED_STUB_ROUTE"))
        let routes = try fixture.routes().map { String($0.split(separator: " ")[0]) }
        let evidence = try fixture.evidence()
        try #require(evidence.count == 1, "Ein privater Beleg je Lauf erwartet")
        let directory = evidence[0]
        let log = try String(contentsOf: directory.appendingPathComponent("befunde.log"), encoding: .utf8)
        let lines = log.split(whereSeparator: \.isNewline)
        let findings = lines.filter { $0.hasPrefix("SOAK-BEFUND") }
        let environment = lines.filter { $0.hasPrefix("SOAK-UMGEBUNG") }

        if outcome == .clipboard {
            #expect(routes == ["phase-1", "restore", "phase-2", "restore", "phase-3", "restore", "restore", "purge"])
            #expect(try Data(contentsOf: directory.appendingPathComponent("pasteboard-backup.plist"))
                == Data("private clipboard fixture\n".utf8))
        } else {
            #expect(routes == ["phase-1", "phase-2", "phase-3", "purge"])
        }

        switch outcome {
        case .empty:
            #expect(result.output.contains("SOAK FAIL — kein einziger Prüfschritt ausgeführt."))
            #expect(lines.isEmpty)
        case .envReport:
            #expect(result.output.contains("SOAK ENV — 1 von 3 Phasen"))
            #expect(findings.isEmpty)
            #expect(environment == ["SOAK-UMGEBUNG phase=1 aktion=? detail=Fokus"])
        case .mixed:
            #expect(result.output.contains("(1 Fehler, 0 Umgebung)."))
            #expect(findings == ["SOAK-BEFUND phase=1 aktion=? detail=Dateiinhalt"])
            #expect(environment.isEmpty)
        case .priorFailure:
            #expect(result.output.contains("SOAK FAIL — 1 Invarianten-Verstoß(e)"))
            #expect(findings == ["SOAK-BEFUND phase=1 aktion=? detail=Dateiinhalt"])
            #expect(environment.count == 1 && environment.first?.hasPrefix("SOAK-UMGEBUNG phase=2 ") == true)
        case .sequence:
            #expect(result.output.contains("(1 Fehler, 1 Umgebung)."))
            #expect(findings.count == 1 && findings.first?.hasPrefix("SOAK-BEFUND phase=3 ") == true)
            #expect(environment.count == 1 && environment.first?.hasPrefix("SOAK-UMGEBUNG phase=2 ") == true)
        case .clipboard:
            #expect(result.output.contains("(3 Fehler, 0 Umgebung)."))
            #expect(findings.count == 3 && findings.allSatisfy { $0.contains("Zwischenablage wird wiederhergestellt") })
            #expect(environment.isEmpty)
        }
        try fixture.expectRestored(seed: seed)
    }

    enum FullRunnerSignalPoint: String, CaseIterable {
        case phase, cleanup
    }

    @Test("SIGTERM lässt den vollen Soakrunner Zustand und Sperre aufräumen",
          arguments: FullRunnerSignalPoint.allCases)
    func fullRunnerRestoresPrivateStateAfterSIGTERM(point: FullRunnerSignalPoint) throws {
        var fixture = try FullRunnerFixture()
        defer { fixture.dispose() }
        let seed = try fixture.seed()
        fixture.environment["SOAK_FIXTURE_SIGNAL_POINT"] = point.rawValue
        // Im Cleanup muss der zuvor beobachtete Phasenfehler erhalten bleiben.
        fixture.environment["SOAK_FIXTURE_EXIT"] = "1"
        let result = try fixture.run()
        #expect(result.status == (point == .phase ? 143 : 1), "\(result.output)")
        let expected = point == .phase ? ["phase-1", "purge"] : ["phase-1", "phase-2", "phase-3", "purge"]
        #expect(try fixture.routes().map { String($0.split(separator: " ")[0]) } == expected)
        try fixture.expectRestored(seed: seed)
        #expect(try fixture.evidence().count == 1)
    }

    enum InvalidFixture: String, CaseIterable {
        case bothMissing, domainMissing, stateMissing, domainEmpty, stateEmpty
        case productDomain, invalidCharacters, wrongPrefix, missingUUID
        case relativeState, outsideState, parentState, nestedState, dotState, dotdotState, trailingSlashState
        case reservedEvidenceState, reservedSandboxState
        case missingParent, emptyParent, relativeParent, linkedParent, fileParent, unboundOverrides
        case fileState, linkedState, brokenState
    }

    @Test("Ungültige Fixtureeingänge scheitern vor Pruning, Sandbox, Lock, Snapshot und Start",
          arguments: InvalidFixture.allCases)
    func fullRunnerRejectsUnsafeFixture(mode: InvalidFixture) throws {
        var fixture = try FullRunnerFixture()
        defer { fixture.dispose() }
        let seed = try fixture.seed()
        // Mehr als fünf private Kandidaten: Ein verfrühter Pruner wäre am
        // Bestand und an den absichtlich offenen Rechten sichtbar.
        for index in 0..<7 {
            let directory = fixture.parent.appendingPathComponent("fastra-soak-befunde-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([UInt8(index)]).write(to: directory.appendingPathComponent("sentinel"))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        let domainKey = "FASTRA_SELFTEST_PRODUCT_DEFAULTS_DOMAIN"
        let stateKey = "FASTRA_SELFTEST_PRODUCT_SAVED_STATE_DIR"
        let parentKey = "FASTRA_TEST_SANDBOX_PARENT"
        var expectedMessage = "ohne Umlenkung"
        switch mode {
        case .bothMissing: fixture.environment[domainKey] = nil; fixture.environment[stateKey] = nil
        case .domainMissing: fixture.environment[domainKey] = nil
        case .stateMissing: fixture.environment[stateKey] = nil
        case .domainEmpty: fixture.environment[domainKey] = ""
        case .stateEmpty: fixture.environment[stateKey] = ""
        case .productDomain: fixture.environment[domainKey] = "de.dm0.fastra"; expectedMessage = "Unsichere Einstellungs-Domain"
        case .invalidCharacters: fixture.environment[domainKey] = fixture.domain + "/bad"; expectedMessage = "Unsichere Einstellungs-Domain"
        case .wrongPrefix: fixture.environment[domainKey] = "other.\(UUID().uuidString)"; expectedMessage = "Unsichere Einstellungs-Domain"
        case .missingUUID: fixture.environment[domainKey] = "FastraTests.no-uuid"; expectedMessage = "Unsichere Einstellungs-Domain"
        case .relativeState: fixture.environment[stateKey] = "relative.savedState"; expectedMessage = "Unsicherer Saved-State-Ordner"
        case .outsideState: fixture.environment[stateKey] = fixture.root.appendingPathComponent("outside").path; expectedMessage = "Unsicherer Saved-State-Ordner"
        case .parentState: fixture.environment[stateKey] = fixture.parent.path; expectedMessage = "Unsicherer Saved-State-Ordner"
        case .nestedState: fixture.environment[stateKey] = fixture.state.appendingPathComponent("nested").path; expectedMessage = "Unsicherer Saved-State-Ordner"
        case .dotState: fixture.environment[stateKey] = fixture.parent.path + "/."; expectedMessage = "Unsicherer Saved-State-Ordner"
        case .dotdotState: fixture.environment[stateKey] = fixture.parent.path + "/.."; expectedMessage = "Unsicherer Saved-State-Ordner"
        case .trailingSlashState: fixture.environment[stateKey] = fixture.state.path + "/"; expectedMessage = "Unsicherer Saved-State-Ordner"
        case .reservedEvidenceState, .reservedSandboxState:
            let directory = fixture.parent.appendingPathComponent(mode == .reservedEvidenceState
                ? "fastra-soak-befunde-state" : "fastra-soak-run.state")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([5, 0, 255]).write(to: directory.appendingPathComponent("sentinel"))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
                                                  ofItemAtPath: directory.path)
            fixture.environment[stateKey] = directory.path; expectedMessage = "Name ist für Sandbox oder Belege reserviert"
        case .missingParent: fixture.environment[parentKey] = fixture.root.appendingPathComponent("absent").path; expectedMessage = "Unsicherer Fixture-Elternordner"
        case .emptyParent: fixture.environment[parentKey] = ""; expectedMessage = "Unsicherer Fixture-Elternordner"
        case .relativeParent: fixture.environment[parentKey] = "relative"; expectedMessage = "Unsicherer Fixture-Elternordner"
        case .linkedParent:
            let link = fixture.root.appendingPathComponent("linked-parent")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.parent)
            fixture.environment[parentKey] = link.path; expectedMessage = "Unsicherer Fixture-Elternordner"
        case .fileParent:
            let file = fixture.root.appendingPathComponent("file-parent")
            try Data([2]).write(to: file)
            fixture.environment[parentKey] = file.path; expectedMessage = "Unsicherer Fixture-Elternordner"
        case .unboundOverrides:
            fixture.environment[parentKey] = nil; expectedMessage = "expliziten privaten Sandbox-Elternordner"
        case .fileState, .linkedState, .brokenState:
            try FileManager.default.moveItem(at: fixture.state, to: fixture.root.appendingPathComponent("seed-state"))
            if mode == .fileState { try Data([3, 0, 255]).write(to: fixture.state) }
            else {
                try FileManager.default.createSymbolicLink(at: fixture.state, withDestinationURL:
                    fixture.root.appendingPathComponent(mode == .linkedState ? "seed-state" : "missing-target"))
            }
            expectedMessage = "Unsicherer Saved-State-Ordner"
        }
        let before = try snapshotFixtureTree(fixture.root)
        let result = try fixture.run()
        #expect(result.status == 2 && result.output.contains(expectedMessage), "\(mode): \(result.output)")
        #expect(try fixture.routes().isEmpty, "\(mode): Stub gestartet")
        #expect(try snapshotFixtureTree(fixture.root) == before, "\(mode): Datei-, Modus- oder Linkänderung vor der Abweisung")
        let after = try fixture.defaults(["export", "-"])
        #expect(after.status == 0 && after.output == seed, "\(mode): eigene Domain verändert")
    }

    private func snapshotFixtureTree(_ root: URL) throws -> [String: String] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var result: [String: String] = [:]
        for case let path as URL in enumerator {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            let relative = String(path.path.dropFirst(root.path.count))
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                result[relative] = "\(mode):link:\(try FileManager.default.destinationOfSymbolicLink(atPath: path.path))"
            } else if type == .typeDirectory { result[relative] = "\(mode):directory" }
            else { result[relative] = "\(mode):\(try Data(contentsOf: path).base64EncodedString())" }
        }
        return result
    }

    @Test("Rotation und neue Fehlerbelege bleiben in derselben privaten Wurzel")
    func fullRunnerRotatesOnlyPrivateEvidence() throws {
        var fixture = try FullRunnerFixture()
        defer { fixture.dispose() }
        let seed = try fixture.seed()
        for index in 0..<7 {
            let directory = fixture.parent.appendingPathComponent("fastra-soak-befunde-old-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([UInt8(index)]).write(to: directory.appendingPathComponent("sentinel"))
            try FileManager.default.setAttributes([.posixPermissions: 0o755,
                .modificationDate: Date(timeIntervalSince1970: TimeInterval(1_000_000 + index))], ofItemAtPath: directory.path)
        }
        let externalBefore = try snapshotFixtureTree(fixture.externalEvidence)
        fixture.environment["SOAK_FIXTURE_EXIT"] = "1"
        let result = try fixture.run()
        #expect(result.status == 1, "\(result.output)")
        let evidence = try fixture.evidence()
        #expect(evidence.count == 5)
        let names = evidence.map(\.lastPathComponent)
        for index in 0..<7 { #expect(names.contains("fastra-soak-befunde-old-\(index)") == (index >= 3)) }
        #expect(evidence.filter { !$0.lastPathComponent.hasPrefix("fastra-soak-befunde-old-") }.count == 1)
        for directory in evidence {
            #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
        #expect(try snapshotFixtureTree(fixture.externalEvidence) == externalBefore)
        try fixture.expectRestored(seed: seed)
    }

    enum RecoveryMarker: String, CaseIterable {
        case file, symbolicLink, brokenLink, directory, absent
    }

    @Test("Beide Rotationen erhalten alte Produkt-Sicherungen ohne Marker-Nachrüstung",
          arguments: ["product-defaults.plist", "product-saved-state"], RecoveryMarker.allCases)
    func rotationsPreserveProductRecovery(backupName: String, marker: RecoveryMarker) throws {
        let root = testTemporaryDirectory().appendingPathComponent("fastra-soak-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("rotation")
        let outside = root.appendingPathComponent("outside")
        for directory in [parent, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try Data([81, 0, 255]).write(to: outside.appendingPathComponent("sentinel"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
        var protectedTrees: [URL] = []
        for prefix in ["fastra-soak-befunde-", "fastra-soak-run."] {
            for index in 0..<8 {
                let directory = parent.appendingPathComponent("\(prefix)old-\(index)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                let sentinel = directory.appendingPathComponent("sentinel")
                try Data([UInt8(index), 0, 255]).write(to: sentinel)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sentinel.path)
                if index == 0 {
                    let backup = directory.appendingPathComponent(backupName)
                    switch marker {
                    case .file:
                        try Data([82, 0, 255, 10]).write(to: backup)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                    case .directory:
                        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false,
                                                                attributes: [.posixPermissions: 0o700])
                        try Data([83, 0, 254]).write(to: backup.appendingPathComponent("window.data"))
                        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                              ofItemAtPath: backup.appendingPathComponent("window.data").path)
                    case .symbolicLink:
                        try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: outside)
                    case .brokenLink:
                        try FileManager.default.createSymbolicLink(atPath: backup.path, withDestinationPath: "missing")
                    case .absent: break
                    }
                    protectedTrees.append(directory)
                }
                try FileManager.default.setAttributes([
                    .modificationDate: Date(timeIntervalSince1970: TimeInterval(1_000_000 + index)),
                ], ofItemAtPath: directory.path)
            }
            try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent(prefix + "link"),
                                                       withDestinationURL: outside)
        }
        let before = try protectedTrees.map { try snapshotFixtureTree($0) }
        let outsideBefore = try snapshotFixtureTree(outside)
        let script = #"""
        set -eu
        . "$1"
        . "$3"
        SOAK_RUNS_INSIDE_TEST_FIXTURE=1
        SOAK_FIXTURE_PARENT=$(cd -P -- "$2" && pwd -P)
        FASTRA_TEST_SANDBOX_PARENT="$SOAK_FIXTURE_PARENT"
        active="$SOAK_FIXTURE_PARENT/fastra-soak-run.active"
        mkdir "$active"
        printf '%s\n' "$$" > "$active/owner-pid"
        ps -p $$ -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$active/owner-started"
        touch -t 199901010101 "$active"
        # rm darf ausschließlich die echten Kandidaten unter dieser Fixture erreichen.
        rm() {
            [ "$#" -eq 3 ] && [ "$1" = -rf ] && [ "$2" = -- ] || exit 90
            case "$3" in "$SOAK_FIXTURE_PARENT"/fastra-soak-befunde-*|"$SOAK_FIXTURE_PARENT"/fastra-soak-run.*|\
                 "$SOAK_FIXTURE_PARENT"/fastra-unit-tests.old|"$SOAK_FIXTURE_PARENT"/fastra-selftest-run.old)
                command /bin/rm "$@" ;; *) exit 92 ;;
            esac
        }
        prune_soak_evidence "$SOAK_FIXTURE_PARENT/unused-system-root"
        purge_stale_fastra_test_sandboxes soak-run
        [ -d "$active" ] || exit 93
        # Ein erfolgreicher Abschluss darf auch mit Snapshots weiterhin freigeben.
        FASTRA_TEST_SANDBOX="$SOAK_FIXTURE_PARENT/fastra-soak-run.success"
        FASTRA_TEST_SANDBOX_KIND=soak-run
        mkdir "$FASTRA_TEST_SANDBOX"
        printf 'snapshot' > "$FASTRA_TEST_SANDBOX/product-defaults.plist"
        mkdir "$FASTRA_TEST_SANDBOX/product-saved-state"
        release_fastra_test_sandbox
        [ ! -e "$2/fastra-soak-run.success" ] || exit 94
        for kind in unit-tests selftest-run; do
            directory="$SOAK_FIXTURE_PARENT/fastra-$kind.old"
            mkdir "$directory"
            printf 'diagnostic' > "$directory/product-defaults.plist"
            touch -t 199901010101 "$directory"
            purge_stale_fastra_test_sandboxes "$kind"
            [ ! -e "$directory" ] || exit 95
        done
        """#
        let result = try runTestProcess("/bin/bash", arguments: [
            "-c", script, "soak-retention",
            soakRunnerAppDirectory.appendingPathComponent("tools/test-sandbox.sh").path, parent.path,
            soakRunnerAppDirectory.appendingPathComponent("tools/test-evidence-retention.sh").path,
        ])
        #expect(result.status == 0, "\(backupName), \(marker): \(result.output)")
        for (index, directory) in protectedTrees.enumerated() {
            let exists = FileManager.default.fileExists(atPath: directory.path)
            #expect(exists == (marker != .absent), "\(backupName), \(marker): \(directory)")
            if exists { #expect(try snapshotFixtureTree(directory) == before[index]) }
        }
        for index in 1..<8 {
            #expect(FileManager.default.fileExists(atPath:
                parent.appendingPathComponent("fastra-soak-befunde-old-\(index)").path) == (index >= 3))
            #expect(!FileManager.default.fileExists(atPath:
                parent.appendingPathComponent("fastra-soak-run.old-\(index)").path))
        }
        #expect(try snapshotFixtureTree(outside) == outsideBefore)
        #expect((try FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        for prefix in ["fastra-soak-befunde-", "fastra-soak-run."] {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath:
                parent.appendingPathComponent(prefix + "link").path) == outside.path)
        }
    }

    enum NormalEvidenceRoots: String, CaseIterable {
        case systemAlias, duplicateAlias, separateAlias, missingInherited
    }

    @Test("Normale Rotation zählt Belegordner über Pfadverweise nur einmal",
          arguments: NormalEvidenceRoots.allCases)
    func normalRotationCountsEachEvidenceOnce(roots: NormalEvidenceRoots) throws {
        let root = testTemporaryDirectory().appendingPathComponent("fastra-soak-roots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = #"""
        set -eu
        . "$3"
        BASE=$(cd -P -- "$1" && pwd -P)
        SYSTEM_ROOT="$BASE/system alias"
        system="$BASE/system evidence"
        inherited="$BASE/inherited evidence"
        mkdir "$system" "$inherited" "$BASE/link target"
        ln -s "$system" "$SYSTEM_ROOT"
        SOAK_RUNS_INSIDE_TEST_FIXTURE=0
        unset TMPDIR
        case "$2" in
            duplicateAlias) ln -s "$system" "$BASE/inherited alias" ;;
            separateAlias) ln -s "$inherited" "$BASE/inherited alias" ;;
        esac
        [ "$2" = systemAlias ] || TMPDIR="$BASE/inherited alias/"

        evidence_path() {
            local parent="$system"
            if [ "$2" = separateAlias ] && [ $(( $1 % 2 )) -eq 0 ]; then parent="$inherited"; fi
            printf '%s/fastra-soak-befunde-%s\n' "$parent" "$1"
        }
        for index in 1 2 3 4 5 6 7 8; do
            path=$(evidence_path "$index" "$2")
            mkdir "$path"
            touch -t "20200101010$index" "$path"
        done
        backup="$system/fastra-soak-befunde-recovery"
        mkdir "$backup"
        printf 'synthetic recovery' > "$backup/pasteboard-backup.plist"
        touch -t 199901010101 "$backup"
        link="$system/fastra-soak-befunde-child-link"
        ln -s "$BASE/link target" "$link"
        rm() {
            [ "$#" -eq 3 ] && [ "$1" = -rf ] && [ "$2" = -- ] || exit 90
            case "$3" in "$BASE"/*/fastra-soak-befunde-*) command /bin/rm "$@" ;; *) exit 91 ;; esac
        }
        prune_soak_evidence "$SYSTEM_ROOT"
        for index in 1 2 3; do
            [ ! -e "$(evidence_path "$index" "$2")" ] || { printf 'Alte Probe blieb: %s\n' "$index"; exit 10; }
        done
        for index in 4 5 6 7 8; do
            [ -d "$(evidence_path "$index" "$2")" ] || { printf 'Junge Probe fehlt: %s\n' "$index"; exit 11; }
        done
        [ "$(cat "$backup/pasteboard-backup.plist")" = 'synthetic recovery' ] || exit 12
        [ -L "$link" ] && [ -d "$BASE/link target" ] || exit 13
        """#
        let result = try runTestProcess("/bin/bash", arguments: [
            "-c", script, "soak-evidence", root.path, roots.rawValue,
            soakRunnerAppDirectory.appendingPathComponent("tools/test-evidence-retention.sh").path,
        ])
        #expect(result.status == 0, "\(roots): \(result.output)")
    }

    enum EvidenceRotation: String, CaseIterable {
        case start, cleanup
    }

    @Test("Echte Start- und Cleanup-Rotation erhält Rettungsmarker und entfernt alte normale Belege",
          arguments: RecoveryMarker.allCases, EvidenceRotation.allCases)
    func fullRunnerPreservesRecoveryEvidence(marker: RecoveryMarker, rotation: EvidenceRotation) throws {
        var fixture = try FullRunnerFixture()
        defer { fixture.dispose() }
        let seed = try fixture.seed()
        let markerTree = fixture.parent.appendingPathComponent("fastra-soak-befunde-old-0")
        let count = rotation == .start ? 8 : 5
        var oldTrees: [URL] = []
        for index in 0..<count {
            let directory = fixture.parent.appendingPathComponent("fastra-soak-befunde-old-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let sentinel = directory.appendingPathComponent("sentinel")
            try Data([UInt8(index), 0, 255]).write(to: sentinel)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sentinel.path)
            oldTrees.append(directory)
        }
        let backup = markerTree.appendingPathComponent("pasteboard-backup.plist")
        switch marker {
        case .file:
            try Data([82, 0, 255, 10]).write(to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        case .symbolicLink:
            try FileManager.default.createSymbolicLink(atPath: backup.path, withDestinationPath: "sentinel")
        case .brokenLink:
            try FileManager.default.createSymbolicLink(atPath: backup.path, withDestinationPath: "missing-own-target")
        case .directory:
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        case .absent: break
        }
        let markerBefore = try snapshotFixtureTree(markerTree)
        let externalBefore = try snapshotFixtureTree(fixture.externalEvidence)
        // Erst nach vollständiger Anlage datieren: Der Marker soll beim Start
        // oder erst durch den sechsten Cleanup-Beleg außerhalb der Fünfermenge liegen.
        for (index, directory) in oldTrees.enumerated() {
            try FileManager.default.setAttributes([
                .modificationDate: Date(timeIntervalSince1970: TimeInterval(1_000_000 + index)),
            ], ofItemAtPath: directory.path)
        }
        fixture.environment["SOAK_FIXTURE_EXIT"] = rotation == .start ? "0" : "1"
        let result = try fixture.run()
        #expect(result.status == (rotation == .start ? 0 : 1), "\(result.output)")
        #expect(try fixture.routes().count == 4)
        #expect(!result.output.contains("UNEXPECTED_STUB_ROUTE"), "\(result.output)")
        try fixture.expectRestored(seed: seed)
        #expect(try snapshotFixtureTree(fixture.externalEvidence) == externalBefore)
        let evidence = try fixture.evidence()
        let names = Set(evidence.map(\.lastPathComponent))
        let protected = marker != .absent
        #expect(evidence.count == (protected ? 6 : 5), "Rettungsmarker-Ausnahme: \(names)")
        for index in 1..<count {
            let retained = rotation == .cleanup || index >= 3
            #expect(names.contains("fastra-soak-befunde-old-\(index)") == retained,
                    "Normale Belegrotation: \(names)")
        }
        #expect(evidence.filter { !$0.lastPathComponent.hasPrefix("fastra-soak-befunde-old-") }.count
                == (rotation == .start ? 0 : 1))
        let markerExists = FileManager.default.fileExists(atPath: markerTree.path)
        #expect(markerExists == protected, "Rettungsmarkerbaum: \(marker.rawValue), \(rotation.rawValue)")
        if protected {
            let markerAfter = markerExists ? try snapshotFixtureTree(markerTree) : [:]
            #expect(markerAfter == markerBefore,
                    "Rettungsmarkerbytes, Linktext oder Markerart verändert: \(marker.rawValue), \(rotation.rawValue)")
        }
    }

    enum ForeignFixtureProcess: String, CaseIterable {
        case canonical, versioned, renamed, otherExecutable, exited, missing, wrongIdentity
        var bundle: String {
            switch self {
            case .versioned: "Fastra Test-Build-42.app"
            case .renamed, .otherExecutable: "Temp.app"
            default: "Fastra.app"
            }
        }
        var blocks: Bool { [.canonical, .versioned, .renamed].contains(self) }
    }

    @Test("Voller Soakentry prüft echte fremde Prozessidentitäten vor dem Stubstart",
          arguments: ForeignFixtureProcess.allCases)
    func fullRunnerForeignProcessGuard(probe: ForeignFixtureProcess) throws {
        var fixture = try FullRunnerFixture()
        let sleeper = Process()
        var identity: ProcessIdentity?
        let binary = fixture.root.appendingPathComponent(probe.bundle + "/Contents/MacOS/" +
            (probe == .otherExecutable ? "FastraOther" : "Fastra"))
        // Process kann /private/tmp als /tmp starten. Der vollständige
        // zufällige Pfadsuffix bindet beide Aliasse an dieselbe eigene Fixture.
        let processMarker = fixture.root.lastPathComponent + "/" + probe.bundle + "/Contents/MacOS/" + binary.lastPathComponent
        defer {
            if let identity, sleeper.isRunning { stopTestFixtureProcess(identity.pid, marker: processMarker) }
            if let identity, !sleeper.isRunning {
                sleeper.waitUntilExit()
                #expect(ProcessGroupOperations.live.startToken(identity.pid) == nil)
            }
            if !sleeper.isRunning { fixture.dispose() }
            else { Issue.record("Eigener Sleeper lebt weiter; Fixture bleibt erhalten: \(fixture.root.path)") }
        }
        let seed = try fixture.seed()
        let source = fixture.root.appendingPathComponent("sleeper.c")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#include <unistd.h>\nint main(void) { alarm(180); for (;;) pause(); }\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let compiled = try runTestProcess("/usr/bin/clang", arguments: [source.path, "-o", binary.path])
        try #require(compiled.status == 0, "\(compiled.output)")
        if probe != .missing {
            sleeper.executableURL = binary
            sleeper.standardOutput = FileHandle.nullDevice
            sleeper.standardError = FileHandle.nullDevice
            try sleeper.run()
            let pid = sleeper.processIdentifier
            identity = ProcessIdentity(pid: pid, startToken: try #require(ProcessGroupOperations.live.startToken(pid)))
            let command = try runTestProcess("/bin/ps", arguments: ["-ww", "-p", "\(pid)", "-o", "command="], timeout: 2)
            try #require(command.status == 0 && command.output.contains(processMarker), "\(command.output)")
            if probe == .exited {
                stopTestFixtureProcess(pid, marker: processMarker)
                try #require(!sleeper.isRunning)
                sleeper.waitUntilExit()
            }
        }
        var filterIdentity = identity ?? ProcessIdentity(pid: .max, startToken: 0)
        if probe == .wrongIdentity {
            filterIdentity = ProcessIdentity(pid: filterIdentity.pid, startToken: filterIdentity.startToken &+ 1)
        }
        fixture.environment["PATH"] = try pathIgnoringForeignFastraProcess(in: fixture.root, matchingForeignProcess: filterIdentity)
        let result = try fixture.run()
        let routes = try fixture.routes()
        #expect(result.status == (probe.blocks ? 2 : 0), "Fall \(probe): \(result.output)")
        #expect(result.output.contains("eine andere Fastra-App läuft") == probe.blocks, "Fall \(probe): \(result.output)")
        #expect(routes.count == (probe.blocks ? 0 : 4), "Fall \(probe): \(routes)")
        try fixture.expectRestored(seed: seed)
        if let identity, probe != .exited {
            #expect(sleeper.isRunning && ProcessGroupOperations.live.startToken(identity.pid) == identity.startToken,
                    "Runner beendete den eigenen fremden Probeprozess")
        }
    }

}

/// Bereits beobachtete Dauertestbefunde müssen einen Prozessabbruch überleben.
/// Sofortiges Schreiben prüfen, statt nur den regulären Phasenabschluss.
@Suite("Dauertest-Befunde überleben den Abbruch")
@MainActor
struct SoakFindingDurabilityTests {
    @Test("Jeder Befund steht sofort im Protokoll, nicht erst am Phasenende")
    func findingsReachTheLogImmediately() throws {
        let directory = testTemporaryDirectory()
            .appendingPathComponent("fastra-soak-durability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer {
            SoakTest.reset()
            try? FileManager.default.removeItem(at: directory)
        }
        let log = directory.appendingPathComponent("report.log")

        SoakTest.reset()
        SoakTest.currentPhase = "1"
        SoakTest.beginReport(at: log)

        SoakTest.record("Fenster bleibt unberührt", "Titel geändert")
        // Genau hier würde die Frist des Runners zuschlagen: noch kein
        // `appendReport`, Phase noch nicht fertig.
        let afterFirst = try String(contentsOf: log, encoding: .utf8)
        #expect(afterFirst.contains("SOAK-BEFUND"), """
            Der erste Befund steht nicht im Protokoll — ein Abbruch an dieser \
            Stelle verlöre ihn.
            """)
        #expect(afterFirst.contains("invariante=Fenster bleibt unberührt"))
        #expect(afterFirst.contains("detail=Titel geändert"))

        SoakTest.record("Auswahl bleibt im Text", "Bereich außerhalb")
        let afterSecond = try String(contentsOf: log, encoding: .utf8)
        #expect(afterSecond.contains("invariante=Auswahl bleibt im Text"))

        // Der Abschluss ergänzt nur die Zusammenfassung — kein Befund darf
        // dabei ein zweites Mal erscheinen.
        try SoakTest.appendReport(to: log)
        let final = try String(contentsOf: log, encoding: .utf8)
        let findingLines = final.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("SOAK-BEFUND") }
        #expect(findingLines.count == 2, "Befunde doppelt im Protokoll: \(findingLines)")
        #expect(final.contains("SOAK-ZUSAMMENFASSUNG"))
        #expect(final.components(separatedBy: "SOAK-ZUSAMMENFASSUNG").count == 2)
    }

    @Test("Ein fehlgeschlagener Sofort-Flush wird am Phasenende wiederholt")
    func failedImmediateFlushStaysPending() throws {
        let directory = testTemporaryDirectory()
            .appendingPathComponent("fastra-soak-retry-\(UUID().uuidString)")
        defer {
            SoakTest.reset()
            try? FileManager.default.removeItem(at: directory)
        }
        let log = directory.appendingPathComponent("report.log")

        SoakTest.reset()
        SoakTest.currentPhase = "1"
        SoakTest.beginReport(at: log)
        SoakTest.record("Protokoll bleibt vollständig", "Sofort-Flush scheitert")
        #expect(!FileManager.default.fileExists(atPath: log.path))

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SoakTest.appendReport(to: log)
        let final = try String(contentsOf: log, encoding: .utf8)
        #expect(final.contains("invariante=Protokoll bleibt vollständig"))
        #expect(final.components(separatedBy: "SOAK-BEFUND").count == 2)
        #expect(final.contains("SOAK-ZUSAMMENFASSUNG"))
    }

    @Test("Ohne angemeldetes Protokoll bleibt das alte Verhalten")
    func withoutLogNothingIsWritten() throws {
        SoakTest.reset()
        defer { SoakTest.reset() }
        SoakTest.currentPhase = "1"
        // Kein `beginReport`: Der Befund darf nirgendwohin schreiben und muss
        // trotzdem im Bericht auftauchen.
        SoakTest.record("Ohne Protokoll", "kein Ziel")
        #expect(SoakTest.reportLogURL == nil)
        #expect(SoakTest.report().contains("invariante=Ohne Protokoll"))
    }
}
