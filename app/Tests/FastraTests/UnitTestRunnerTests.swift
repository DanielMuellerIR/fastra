import Darwin
import Foundation
import Testing

private let unitTestRunnerURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // FastraTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // app
    .appendingPathComponent("test.sh")

private struct UnitTestRunnerResult {
    let status: Int32
    let output: String
}

private final class UnitTestRunnerFixture {
    let root: URL
    let sandboxParent: URL
    let probe: URL
    let childPID: URL
    private let binaryDirectory: URL
    private let counter: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-unit-runner-phases-\(UUID().uuidString)")
        sandboxParent = root.appendingPathComponent("sandboxes")
        binaryDirectory = root.appendingPathComponent("bin")
        probe = root.appendingPathComponent("probe.txt")
        counter = root.appendingPathComponent("counter.txt")
        childPID = root.appendingPathComponent("child.pid")
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
          cleanup-failure)
            if [ "$call" -eq 2 ]; then
              /bin/chmod 500 "$(/usr/bin/dirname "$TMPDIR")"
            fi
            exit 0
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
             sandboxParent overrideSandboxParent: URL? = nil) throws
        -> UnitTestRunnerResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [unitTestRunnerURL.path] + arguments
        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": binaryDirectory.path + ":" + oldPath,
            "FASTRA_TEST_SANDBOX_PARENT": (overrideSandboxParent ?? sandboxParent).path,
            "FASTRA_TEST_PROBE": probe.path,
            "FASTRA_TEST_COUNTER": counter.path,
            "FASTRA_TEST_CHILD_PID": childPID.path,
            "FASTRA_TEST_FAKE_MODE": mode,
            "FASTRA_TEST_STATUS_1": String(firstStatus),
            "FASTRA_TEST_STATUS_2": String(secondStatus),
        ], uniquingKeysWith: { _, new in new })
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return UnitTestRunnerResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    func calls() throws -> [(tmp: String, cf: String, arguments: [String])] {
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
            return (tmp: parts[3], cf: parts[5], arguments: arguments)
        }
    }

    var sandboxIsEmpty: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: sandboxParent.path).isEmpty)
            == true
    }
}

@Suite("Unit-Test-Runner mit zwei Phasen", .serialized)
struct SerialRunnerIntegrationTests {
    @Test("Komplementärer Marker teilt den vollständigen Bestand ohne Lücke")
    func complementaryGroupingUsesOneSandbox() throws {
        let fixture = try UnitTestRunnerFixture()
        let result = try fixture.run()
        #expect(result.status == 0, "Runner-Ausgabe: \(result.output)")
        let calls = try fixture.calls()
        #expect(calls.count == 2)
        #expect(calls[0].arguments
                == ["test", "--parallel", "--skip",
                    "[Gg]itIntegration|[Ss]erialRunnerIntegration"])
        #expect(calls[1].arguments
                == ["test", "--no-parallel", "--filter",
                    "[Gg]itIntegration|[Ss]erialRunnerIntegration"])
        #expect(calls[0].tmp == calls[1].tmp)
        #expect(calls[0].cf == calls[1].cf)
        #expect(result.output.contains(
            "FASTRA_TEST_SUMMARY requested_phases=2 run_phases=2 passed_phases=2"
        ))
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

        let gitFailure = try UnitTestRunnerFixture()
        let second = try gitFailure.run(secondStatus: 9)
        #expect(second.status == 1, "Git-Fehler: \(second.output)")
        #expect(try gitFailure.calls().count == 2)
        #expect(second.output.contains("failed_phases=1"))
        #expect(gitFailure.sandboxIsEmpty)
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
}
