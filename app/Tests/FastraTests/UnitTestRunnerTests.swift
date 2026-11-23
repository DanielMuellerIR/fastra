import Darwin
import Foundation
import Testing

private let unitTestRunnerURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // FastraTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // app
    .appendingPathComponent("test.sh")

private final class UnitTestRunnerFixture {
    let root: URL
    let sandboxParent: URL
    let probe: URL
    let childPID: URL
    let realPreferences: URL
    private let binaryDirectory: URL
    private let counter: URL

    init() throws {
        root = testTemporaryDirectory()
            .appendingPathComponent("fastra-unit-runner-phases-\(UUID().uuidString)")
        sandboxParent = root.appendingPathComponent("sandboxes")
        binaryDirectory = root.appendingPathComponent("bin")
        probe = root.appendingPathComponent("probe.txt")
        counter = root.appendingPathComponent("counter.txt")
        childPID = root.appendingPathComponent("child.pid")
        realPreferences = root.appendingPathComponent("preferences")
        try FileManager.default.createDirectory(
            at: realPreferences, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sandboxParent, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: binaryDirectory, withIntermediateDirectories: true
        )

        let fakeSwift = binaryDirectory.appendingPathComponent("swift")
        try #"""
        #!/bin/bash
        set -u

        call=0
        if [ -f "$FASTRA_TEST_COUNTER" ]; then
          read -r call < "$FASTRA_TEST_COUNTER"
        fi
        call=$((call + 1))
        printf '%s\n' "$call" > "$FASTRA_TEST_COUNTER"
        printf 'CALL %s TMP %s CF %s\n' \
          "$call" "$TMPDIR" "$CFFIXED_USER_HOME" >> "$FASTRA_TEST_PROBE"
        suite="${FASTRA_SELFTEST_DEFAULTS_SUITE:-unset}"
        registry="$FASTRA_TEST_DEFAULTS_REGISTRY"
        bound=no
        /usr/bin/grep -Fxq "$suite" "$registry" && bound=yes
        printf 'DEFAULTS %s %s %s %s %s\n' \
          "$call" "$suite" "$registry" "$bound" "$HOME" >> "$FASTRA_TEST_PROBE"
        # Die echten Cleanup-Pfade müssen beide eigenen Preferences-Dateien
        # entfernen; eine bloß entfernte Registry wäre kein ausreichender Beleg.
        if [[ "$suite" =~ ^Fastra-[0-9A-Fa-f-]{36}$ ]] && [ "$bound" = yes ]; then
          /bin/mkdir -p "$CFFIXED_USER_HOME/Library/Preferences"
          /usr/bin/touch "$CFFIXED_USER_HOME/Library/Preferences/$suite.plist" || exit 96
          /usr/bin/touch "$FASTRA_TEST_REAL_PREFERENCES_DIRECTORY/$suite.plist" || exit 96
          printf 'CREATED %s\n' "$call" >> "$FASTRA_TEST_PROBE"
        fi
        for argument in "$@"; do
          printf 'ARG %s %s\n' "$call" "$argument" >> "$FASTRA_TEST_PROBE"
        done

        case "${FASTRA_TEST_FAKE_MODE:-statuses}" in
          statuses)
            if [ "$call" -eq 1 ]; then
              exit "${FASTRA_TEST_STATUS_1:-0}"
            fi
            exit "${FASTRA_TEST_STATUS_2:-0}"
            ;;
          orphan)
            if [ "$call" -eq 1 ]; then
              /bin/bash -c \
                'trap "" TERM; while :; do /bin/sleep 1; done' \
                fastra-unit-runner-orphan &
              printf '%s\n' "$!" > "$FASTRA_TEST_CHILD_PID"
              exit 0
            fi
            read -r orphan_pid < "$FASTRA_TEST_CHILD_PID"
            for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
              kill -0 "$orphan_pid" 2>/dev/null || exit 0
              /bin/sleep 0.02
            done
            exit 97
            ;;
          signal)
            kill -TERM "$PPID"
            /bin/sleep 10
            exit 99
            ;;
          cleanup-failure)
            if [ "$call" -eq 2 ]; then
              /bin/chmod 500 "$(/usr/bin/dirname "$TMPDIR")"
            fi
            if [ "$call" -eq 1 ]; then
              exit "${FASTRA_TEST_STATUS_1:-0}"
            fi
            exit "${FASTRA_TEST_STATUS_2:-0}"
            ;;
          *)
            exit 98
            ;;
        esac
        """#.write(to: fakeSwift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeSwift.path
        )
    }

    deinit {
        // Der absichtlich rote Cleanup-Test hinterlässt eine nicht schreibbare
        // Sandbox. Nur dieses eindeutig eigene Fixture wird für das Test-Defer
        // wieder zugänglich gemacht und entfernt.
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: sandboxParent,
            includingPropertiesForKeys: nil
        ) {
            for entry in entries {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: entry.path
                )
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func run(arguments: [String] = [], mode: String = "statuses",
             firstStatus: Int = 0, secondStatus: Int = 0,
             sandboxParent overrideSandboxParent: URL? = nil,
             callerSuite: String? = nil, runner: URL = unitTestRunnerURL) throws
        -> TestProcessResult {
        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        // Ohne Caller-Suite auch die vom äußeren Unitlauf geerbte Suite
        // entfernen: Dieser Fall prüft einen tatsächlich fehlenden ENV-Eingang.
        let executable = callerSuite == nil ? "/usr/bin/env" : "/bin/bash"
        let prefix = callerSuite == nil ? ["-u", "FASTRA_SELFTEST_DEFAULTS_SUITE", "/bin/bash"] : []
        return try runTestProcess(executable, arguments: prefix + [runner.path] + arguments,
                                  environment: [
            "PATH": binaryDirectory.path + ":" + oldPath,
            "FASTRA_TEST_SANDBOX_PARENT": (overrideSandboxParent ?? sandboxParent).path,
            "FASTRA_TEST_PROBE": probe.path,
            "FASTRA_TEST_COUNTER": counter.path,
            "FASTRA_TEST_CHILD_PID": childPID.path,
            "FASTRA_TEST_FAKE_MODE": mode,
            "FASTRA_TEST_STATUS_1": String(firstStatus),
            "FASTRA_TEST_STATUS_2": String(secondStatus),
            "FASTRA_SELFTEST_DEFAULTS_SUITE": callerSuite ?? "",
            "FASTRA_TEST_REAL_PREFERENCES_DIRECTORY": realPreferences.path,
        ])
    }

    func calls() throws -> [(tmp: String, cf: String, suite: String,
                             registry: String, bound: Bool, created: Bool, home: String, arguments: [String])] {
        let lines = try String(contentsOf: probe, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline).map(String.init)
        return [1, 2].compactMap { wanted in
            guard let call = lines.first(where: { $0.hasPrefix("CALL \(wanted) ") }) else {
                return nil
            }
            let parts = call.split(separator: " ").map(String.init)
            guard parts.count == 6 else { return nil }
            let arguments = lines.compactMap { line -> String? in
                let prefix = "ARG \(wanted) "
                return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
            }
            guard let defaults = lines.first(where: { $0.hasPrefix("DEFAULTS \(wanted) ") })?
                .split(separator: " ").map(String.init), defaults.count == 6 else { return nil }
            return (tmp: parts[3], cf: parts[5], suite: defaults[2],
                    registry: defaults[3], bound: defaults[4] == "yes",
                    created: lines.contains("CREATED \(wanted)"), home: defaults[5], arguments: arguments)
        }
    }

    var sandboxIsEmpty: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: sandboxParent.path).isEmpty)
            == true
    }
}

@Suite("Unit-Test-Runner mit zwei Phasen", .serialized)
struct SerialRunnerIntegrationTests {
    @Test("Originalrunner erhält registrierte Testdaten bei ungeklärtem Folgestart")
    func failedTerminationPreservesSandboxWithoutWaiting() throws {
        let fixture = try UnitTestRunnerFixture()
        let runner = fixture.root.appendingPathComponent("test.sh")
        let tools = fixture.root.appendingPathComponent("tools")
        let files = FileManager.default
        try files.copyItem(at: unitTestRunnerURL, to: runner)
        try files.createDirectory(at: tools, withIntermediateDirectories: false)
        try files.createSymbolicLink(at: tools.appendingPathComponent("test-sandbox.sh"),
                                     withDestinationURL: unitTestRunnerURL.deletingLastPathComponent()
                                        .appendingPathComponent("tools/test-sandbox.sh"))
        // Der erste Start führt die Swift-Attrappe aus. Beim zweiten bleibt
        // die simulierte Pending-PID unaufgelöst; das Fixture sendet kein Signal.
        try #"""
        FASTRA_TEST_STARTED_ROOTS=()
        FASTRA_TEST_PENDING_PID=""

        fastra_test_start_new_session() {
            if [ "${#FASTRA_TEST_STARTED_ROOTS[@]}" -ne 0 ]; then
                FASTRA_TEST_PENDING_PID=2147483647
                return 2
            fi
            "$@" &
            FASTRA_TEST_STARTED_PID=$!
            FASTRA_TEST_STARTED_ROOTS+=("$FASTRA_TEST_STARTED_PID")
            printf 'TRACKED_ROOT %s\n' "$FASTRA_TEST_STARTED_PID"
        }
        fastra_test_adopt_started_session() { return 0; }
        terminate_fastra_test_process_trees() {
            [ -n "$FASTRA_TEST_PENDING_PID" ] || return 0
            printf 'CLEANUP_TARGETS %s\n' "$*"
            return 2
        }
        wait() {
            if [ -n "$FASTRA_TEST_PENDING_PID" ]; then
                printf 'UNEXPECTED_WAIT %s\n' "$*" >> "$FASTRA_TEST_PROBE"
                return 91
            fi
            builtin wait "$@"
        }
        """#.write(to: tools.appendingPathComponent("test-process-tree.sh"), atomically: true, encoding: .utf8)

        let result = try fixture.run(runner: runner)
        #expect(result.status == 2, "\(result.output)")
        let probe = try String(contentsOf: fixture.probe, encoding: .utf8)
        #expect(!probe.contains("UNEXPECTED_WAIT"), "\(probe)")
        #expect(result.output.contains("Sandbox bleiben unangetastet"))
        #expect(result.output.contains("requested_phases=2 run_phases=2 passed_phases=1 failed_phases=0 environment_errors=2 exit=2"))
        let lines = result.output.split(whereSeparator: \.isNewline)
        let tracked = try #require(lines.first { $0.hasPrefix("TRACKED_ROOT ") }?.split(separator: " ").last)
        #expect(lines.filter { $0.hasPrefix("CLEANUP_TARGETS ") } == ["CLEANUP_TARGETS \(tracked) 2147483647"])

        let calls = try fixture.calls()
        try #require(calls.count == 1)
        let call = calls[0]
        #expect(call.bound && call.created)
        let registry = try String(contentsOfFile: call.registry, encoding: .utf8).split(whereSeparator: \.isNewline)
        #expect(registry.count == 2 && registry.first == Substring(call.suite))
        let preferences = URL(fileURLWithPath: call.cf)
            .appendingPathComponent("Library/Preferences/\(call.suite).plist")
        #expect(files.fileExists(atPath: preferences.path))
        #expect(files.fileExists(atPath: fixture.realPreferences.appendingPathComponent("\(call.suite).plist").path))
    }

    @Test("Komplementärer Marker teilt den vollständigen Bestand ohne Lücke")
    func complementaryGroupingUsesOneSandbox() throws {
        let fixture = try UnitTestRunnerFixture()
        let result = try fixture.run()
        #expect(result.status == 0, "Runner-Ausgabe: \(result.output)")
        let calls = try fixture.calls()
        #expect(calls.count == 2)
        #expect(calls[0].arguments
                == ["test", "--parallel", "--skip",
                    "[Gg]itIntegration|[Ss]erialRunnerIntegration|MarkdownVisualTests"])
        #expect(calls[1].arguments
                == ["test", "--no-parallel", "--filter",
                    "[Gg]itIntegration|[Ss]erialRunnerIntegration|MarkdownVisualTests"])
        #expect(calls[0].tmp == calls[1].tmp)
        #expect(calls[0].cf == calls[1].cf)
        #expect(result.output.contains(
            "FASTRA_TEST_SUMMARY requested_phases=2 run_phases=2 passed_phases=2"
        ))
        #expect(fixture.sandboxIsEmpty)
    }

    @Test("Jede Phase erhält eine frische registrierte Suite und lässt die Caller-Suite unberührt",
          arguments: [false, true])
    func phaseDefaultsAreIsolatedAndCleaned(_ inheritsSuite: Bool) throws {
        let fixture = try UnitTestRunnerFixture()
        let callerSuite = "Fastra-\(UUID().uuidString)"
        let callerFile = fixture.realPreferences.appendingPathComponent("\(callerSuite).plist")
        let original = Data("caller-owned".utf8)
        try original.write(to: callerFile)
        let result = try fixture.run(callerSuite: inheritsSuite ? callerSuite : nil)
        #expect(result.status == 0, "\(result.output)")
        let calls = try fixture.calls()
        try #require(calls.count == 2)
        #expect(calls[0].suite != calls[1].suite)
        #expect(calls[0].registry == calls[1].registry)
        for call in calls {
            #expect(call.suite.hasPrefix("Fastra-"))
            #expect(UUID(uuidString: String(call.suite.dropFirst("Fastra-".count))) != nil)
            #expect(call.suite != callerSuite)
            #expect(call.bound && call.created)
            #expect(call.registry == URL(fileURLWithPath: call.tmp)
                .deletingLastPathComponent().appendingPathComponent("defaults-registry.txt").path)
            #expect(call.home == ProcessInfo.processInfo.environment["HOME"])
            #expect(!FileManager.default.fileExists(atPath:
                fixture.realPreferences.appendingPathComponent("\(call.suite).plist").path))
        }
        #expect(try Data(contentsOf: callerFile) == original)
        #expect(fixture.sandboxIsEmpty)
    }

    @Test("TERM beendet den Runner mit Signalstatus und räumt die registrierte Suite auf")
    func signalCleansPhaseDefaults() throws {
        let fixture = try UnitTestRunnerFixture()
        let result = try fixture.run(mode: "signal")
        #expect(result.status == 143, "\(result.output)")
        let calls = try fixture.calls()
        try #require(calls.count == 1)
        #expect(calls[0].bound && calls[0].created)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.realPreferences.path).isEmpty)
        #expect(fixture.sandboxIsEmpty)
    }

    @Test("Fehler jeder Phase ergeben Exit 1 und lassen die andere Phase laufen")
    func phaseFailuresAggregateToFunctionalFailure() throws {
        let fastFailure = try UnitTestRunnerFixture()
        let first = try fastFailure.run(firstStatus: 7)
        #expect(first.status == 1, "Fast-Fehler: \(first.output)")
        #expect(try fastFailure.calls().count == 2)
        #expect(first.output.contains("failed_phases=1"))
        #expect(fastFailure.sandboxIsEmpty)
        #expect(try fastFailure.calls().allSatisfy { $0.bound && $0.created })
        #expect(try FileManager.default.contentsOfDirectory(atPath: fastFailure.realPreferences.path).isEmpty)

        let gitFailure = try UnitTestRunnerFixture()
        let second = try gitFailure.run(secondStatus: 9)
        #expect(second.status == 1, "Git-Fehler: \(second.output)")
        #expect(try gitFailure.calls().count == 2)
        #expect(second.output.contains("failed_phases=1"))
        #expect(gitFailure.sandboxIsEmpty)
        #expect(try gitFailure.calls().allSatisfy { $0.bound && $0.created })
        #expect(try FileManager.default.contentsOfDirectory(atPath: gitFailure.realPreferences.path).isEmpty)
    }

    @Test("Aufruferfilter bleibt in beiden Phasen eine Schnittmenge")
    func callerFilterIntersectsPhaseFilter() throws {
        let fixture = try UnitTestRunnerFixture()
        let result = try fixture.run(arguments: [
            "--filter", "(?<probe>SelfTestOutcomeTests)",
            "--filter=(?<probe>UnitTestRunnerTests)",
        ])

        #expect(result.status == 0, "Runner-Ausgabe: \(result.output)")
        let calls = try fixture.calls()
        #expect(calls.count == 2)
        #expect(calls[0].arguments == [
            "test", "--parallel", "--skip",
            "[Gg]itIntegration|[Ss]erialRunnerIntegration|MarkdownVisualTests",
            "--filter", "(?<probe>SelfTestOutcomeTests)",
            "--filter", "(?<probe>UnitTestRunnerTests)",
        ])
        #expect(calls[1].arguments == [
            "test", "--no-parallel", "--filter",
            "^(?=.*(?:[Gg]itIntegration|[Ss]erialRunnerIntegration|MarkdownVisualTests))"
                + "(?=.*(?:(?<probe>SelfTestOutcomeTests))).*$",
            "--filter",
            "^(?=.*(?:[Gg]itIntegration|[Ss]erialRunnerIntegration|MarkdownVisualTests))"
                + "(?=.*(?:(?<probe>UnitTestRunnerTests))).*$",
        ])
    }

    @Test("Erste Phase räumt verwaiste Kinder vor der Git-Phase auf")
    func phaseCleanupPreventsProcessOverlap() throws {
        let fixture = try UnitTestRunnerFixture()
        let result = try fixture.run(mode: "orphan")
        #expect(result.status == 0, "Prozess-Cleanup: \(result.output)")
        let pid = try #require(Int32(
            String(contentsOf: fixture.childPID, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        errno = 0
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(try fixture.calls().count == 2)
        #expect(fixture.sandboxIsEmpty)
    }

    @Test("Sandbox- und Cleanup-Probleme ergeben ausschließlich Exit 2")
    func environmentAndCleanupFailuresUseExitTwo() throws {
        let missingParent = try UnitTestRunnerFixture()
        let unavailable = missingParent.root.appendingPathComponent("fehlt")
        let startFailure = try missingParent.run(sandboxParent: unavailable)
        #expect(startFailure.status == 2)
        #expect(!FileManager.default.fileExists(atPath: missingParent.probe.path))

        let cleanupFailure = try UnitTestRunnerFixture()
        let cleanup = try cleanupFailure.run(mode: "cleanup-failure")
        #expect(cleanup.status == 2, "Cleanup-Fehler: \(cleanup.output)")
        #expect(cleanup.output.contains("Test-Sandbox konnte nicht entfernt werden"))
        #expect(cleanup.output.contains("environment_errors=1 exit=2"))
        #expect(try cleanupFailure.calls().count == 2)
    }

    @Test("Funktionsfehler gewinnt auch bei späterem Cleanup-Problem")
    func functionalFailureWinsOverLaterCleanupFailure() throws {
        let fixture = try UnitTestRunnerFixture()
        let result = try fixture.run(
            mode: "cleanup-failure", firstStatus: 7
        )

        #expect(result.status == 1, "Runner-Ausgabe: \(result.output)")
        #expect(result.output.contains("failed_phases=1"))
        #expect(result.output.contains("environment_errors=1 exit=1"))
        #expect(try fixture.calls().count == 2)
    }
}
