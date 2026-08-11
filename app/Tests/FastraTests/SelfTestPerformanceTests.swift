import Foundation
import Darwin
import Testing
@testable import Fastra

private let performanceToolsDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // FastraTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // app
    .appendingPathComponent("tools")

private struct PerformanceToolResult {
    let status: Int32
    let output: String
}

private func runPerformanceTool(_ executable: String,
                                arguments: [String],
                                environment: [String: String]? = nil) throws
    -> PerformanceToolResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment {
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment, uniquingKeysWith: { _, new in new }
        )
    }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return PerformanceToolResult(
        status: process.terminationStatus,
        output: String(decoding: data, as: UTF8.self)
    )
}

@Suite("Lokale Selbsttest-Performance", .serialized)
struct SelfTestPerformanceTests {
    @Test("Prozesszuordnung verlangt den vollständigen Selbsttestnamen")
    func processMatchingUsesWholeSelfTestName() throws {
        let helper = performanceToolsDirectory
            .appendingPathComponent("test-process-tree.sh")
        let script = """
        set -u
        . "$1"
        fastra_test_command_names_selftest \
          '/tmp/Fastra -selftest coldopen -ApplePersistenceIgnoreState YES' coldopen \
          || exit 91
        fastra_test_command_names_selftest \
          '/tmp/Fastra FASTRA_SELFTEST=coldopen ApplePersistenceIgnoreState=YES' coldopen \
          || exit 92
        ! fastra_test_command_names_selftest \
          '/tmp/Fastra -selftest coldopenoff -ApplePersistenceIgnoreState YES' coldopen \
          || exit 93
        ! fastra_test_command_names_selftest \
          '/tmp/Fastra FASTRA_SELFTEST=coldopenoff ApplePersistenceIgnoreState=YES' coldopen \
          || exit 94
        """
        let result = try runPerformanceTool(
            "/bin/bash", arguments: ["-c", script, "test", helper.path]
        )
        #expect(result.status == 0, "Selbsttest-Prozesszuordnung: \(result.output)")
    }

    @Test("Fehlgeschlagener Clipboard-Helfer blockiert Zustands- und Sandbox-Cleanup")
    func clipboardHelperCleanupFailureKeepsRecoverySandbox() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-helper-cleanup-test-\(UUID().uuidString)")
        let sandboxParent = root.appendingPathComponent("sandboxes")
        let lock = root.appendingPathComponent("gui.lock")
        let fakeApp = root.appendingPathComponent("Fastra")
        let runner = performanceToolsDirectory.deletingLastPathComponent()
            .appendingPathComponent("selftest.sh")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: sandboxParent, withIntermediateDirectories: true
        )
        try """
        #!/bin/bash
        if [[ " $* " == *" -selftest soakpasteboardrestore "* ]]; then
          rm -f -- "$FASTRA_SELFTEST_PASTEBOARD_DIR/pasteboard-backup.plist"
          exit 0
        fi
        mkdir -p "$FASTRA_SELFTEST_PASTEBOARD_DIR"
        printf 'probe' > "$FASTRA_SELFTEST_PASTEBOARD_DIR/pasteboard-backup.plist"
        echo 'SELFTEST search: PASS — Probe' >&2
        """.write(to: fakeApp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeApp.path
        )

        let result = try runPerformanceTool(
            "/bin/bash", arguments: [runner.path, "search"], environment: [
                "FASTRA_GUI_LOCK_DIR": lock.path,
                "FASTRA_SELFTEST_APP_BIN": fakeApp.path,
                "FASTRA_TEST_SANDBOX_PARENT": sandboxParent.path,
                "FASTRA_SELFTEST_TEST_HELPER_CLEANUP_FAILURE": "1",
            ]
        )
        #expect(result.status == 2)
        #expect(result.output.contains("Private Test-Sandbox"))
        #expect(result.output.contains("Aufräumen konnte nicht vollständig"))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: sandboxParent, includingPropertiesForKeys: nil
        )
        #expect(leftovers.count == 1,
                "Die Recovery-Sandbox darf bei unbekanntem Prozesszustand nicht verschwinden")
    }

    @Test("Prozessbaum-Cleanup beendet TERM-resistente Prozessgruppe")
    func processTreeCleanupStopsDescendants() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-process-tree-test-\(UUID().uuidString)")
        let probe = root.appendingPathComponent("pids.txt")
        let helper = performanceToolsDirectory
            .appendingPathComponent("test-process-tree.sh")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let script = """
        set -u
        . "$1"
        probe="$2"
        /usr/bin/python3 - "$probe" <<'PY' &
        import os, signal, subprocess, sys, time
        os.setsid()
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        child = subprocess.Popen([
            "/bin/bash", "-c", "trap '' TERM; while :; do sleep 30; done"
        ])
        with open(sys.argv[1], "w", encoding="utf-8") as handle:
            handle.write(f"{os.getpid()} {child.pid}\\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.kill(os.getpid(), signal.SIGSTOP)
        while True:
            time.sleep(30)
        PY
        root_pid=$!
        cleanup() {
          kill -CONT "$root_pid" 2>/dev/null || true
          kill -KILL -"$root_pid" 2>/dev/null || true
          wait "$root_pid" 2>/dev/null || true
        }
        trap cleanup EXIT
        tick=0
        while [ ! -s "$probe" ] && [ "$tick" -lt 100 ]; do
          sleep 0.02
          tick=$((tick + 1))
        done
        [ -s "$probe" ] || exit 91
        child_pid=$(awk '{print $2}' "$probe")
        terminate_fastra_test_process_trees "$root_pid" || exit 92
        wait "$root_pid" 2>/dev/null || true
        ! fastra_test_pid_is_live "$root_pid" || exit 93
        ! fastra_test_pid_is_live "$child_pid" || exit 94
        ! fastra_test_group_is_live "$root_pid" || exit 95
        trap - EXIT
        """
        let result = try runPerformanceTool(
            "/bin/bash", arguments: ["-c", script, "test", helper.path, probe.path]
        )
        #expect(result.status == 0, "Prozessbaum-Helfer: \(result.output)")
    }

    @Test("Prozessbaum-Cleanup verschont eine wiederverwendete Root-PID")
    func processTreeCleanupRejectsMismatchedStartToken() throws {
        let helper = performanceToolsDirectory
            .appendingPathComponent("test-process-tree.sh")
        let script = """
        set -u
        . "$1"
        sleep 30 &
        foreign_pid=$!
        cleanup() {
          kill "$foreign_pid" 2>/dev/null || true
          wait "$foreign_pid" 2>/dev/null || true
        }
        trap cleanup EXIT
        # Dieselbe Nummer steht in der Runner-Liste, aber mit einer anderen
        # Startzeit: genau der Zustand nach einer PID-Wiederverwendung.
        FASTRA_TEST_STARTED_ROOTS=("$foreign_pid")
        FASTRA_TEST_STARTED_GROUPS=("$foreign_pid")
        FASTRA_TEST_STARTED_TOKENS=("nicht-die-echte-startzeit")
        terminate_fastra_test_process_trees "$foreign_pid" || exit 91
        kill -0 "$foreign_pid" 2>/dev/null || exit 92
        """
        let result = try runPerformanceTool(
            "/bin/bash", arguments: ["-c", script, "test", helper.path]
        )
        #expect(result.status == 0, "PID-Wiederverwendung: \(result.output)")
    }

    @Test("Unit-Test-Runner entfernt Temp- und Preferences-Sandbox auch bei Fehler")
    func unitTestRunnerRemovesSandboxOnFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-unit-runner-test-\(UUID().uuidString)")
        let sandboxParent = root.appendingPathComponent("sandboxes")
        let bin = root.appendingPathComponent("bin")
        let fakeSwift = bin.appendingPathComponent("swift")
        let probe = root.appendingPathComponent("probe.txt")
        let preferences = root.appendingPathComponent("preferences")
        let realPreferences = root.appendingPathComponent("real-preferences")
        let runner = performanceToolsDirectory.deletingLastPathComponent()
            .appendingPathComponent("test.sh")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: sandboxParent, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: preferences, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: realPreferences, withIntermediateDirectories: true
        )
        try """
        #!/bin/bash
        [ "$1" = "test" ] || exit 91
        [ "$CFPREFERENCES_AVOID_DAEMON" = "1" ] || exit 92
        printf '%s\n%s\n' "$TMPDIR" "$CFFIXED_USER_HOME" > "$FASTRA_TEST_PROBE"
        touch "$TMPDIR/fixture"
        mkdir -p "$CFFIXED_USER_HOME/Library/Preferences"
        touch "$CFFIXED_USER_HOME/Library/Preferences/test.plist"
        domain="FastraTests.RunnerProbe.9E8B2C1A-1234-4EAB-9F00-ABCDEF012345"
        printf '%s\n' "$domain" >> "$FASTRA_TEST_DEFAULTS_REGISTRY"
        touch "$FASTRA_TEST_PREFERENCES_DIRECTORY/$domain.plist"
        touch "$FASTRA_TEST_REAL_PREFERENCES_DIRECTORY/$domain.plist"
        # Bildet cfprefsd nach: Die leere Datei erscheint erst, nachdem der
        # eigentliche Testprozess schon beendet wurde.
        /usr/bin/python3 -c 'import os,sys,time; os.setsid(); time.sleep(.2); open(sys.argv[1],"ab").close()' \
          "$FASTRA_TEST_PREFERENCES_DIRECTORY/$domain.plist" &
        /usr/bin/python3 -c 'import os,sys,time; os.setsid(); time.sleep(.2); open(sys.argv[1],"ab").close()' \
          "$FASTRA_TEST_REAL_PREFERENCES_DIRECTORY/$domain.plist" &
        exit 7
        """.write(to: fakeSwift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeSwift.path
        )

        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let result = try runPerformanceTool(
            "/bin/bash", arguments: [runner.path], environment: [
                "PATH": bin.path + ":" + oldPath,
                "FASTRA_TEST_SANDBOX_PARENT": sandboxParent.path,
                "FASTRA_TEST_PROBE": probe.path,
                "FASTRA_TEST_PREFERENCES_DIRECTORY": preferences.path,
                "FASTRA_TEST_REAL_PREFERENCES_DIRECTORY": realPreferences.path,
            ]
        )
        #expect(result.status == 7, "Der echte Teststatus muss erhalten bleiben")
        let recorded = try String(contentsOf: probe, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        #expect(recorded.count == 2)
        for path in recorded {
            #expect(!FileManager.default.fileExists(atPath: path),
                    "Die aufgezeichnete Sandbox muss nach dem Runner verschwunden sein")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sandboxParent.path)
        #expect(leftovers.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: preferences.path
        ).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: realPreferences.path
        ).isEmpty)
    }

    @Test("Portabilitätsprüfung isoliert beide App-Starts und räumt verzögerte Plists")
    func portableRunnerLeavesNoPreferencesOrFixtures() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-portable-runner-test-\(UUID().uuidString)")
        let sandboxParent = root.appendingPathComponent("sandboxes")
        let fakeApp = root.appendingPathComponent("Fastra.app")
        let fakeBinary = fakeApp.appendingPathComponent("Contents/MacOS/Fastra")
        let resources = root.appendingPathComponent("build-resources")
        let bundle = resources.appendingPathComponent("Probe.bundle")
        let bundleFile = bundle.appendingPathComponent("probe.txt")
        let preferences = root.appendingPathComponent("preferences")
        let realPreferences = root.appendingPathComponent("real-preferences")
        let probe = root.appendingPathComponent("starts.txt")
        let orphanPIDs = root.appendingPathComponent("orphan-pids.txt")
        let orphanMarker = root.appendingPathComponent("portable-orphan-marker")
        let runner = performanceToolsDirectory.deletingLastPathComponent()
            .appendingPathComponent("verify-portable-app.sh")
        defer {
            // Der geprüfte Wrapper ist nicht zugleich die einzige Sicherung
            // des Tests: Bei einer Regression oder einem frühen Throw beendet
            // dieser Notausgang nur die eindeutig markierte Fixture-Gruppe.
            if let contents = try? String(contentsOf: orphanPIDs, encoding: .utf8) {
                for value in contents.split(whereSeparator: \Character.isNewline) {
                    guard let pid = pid_t(value),
                          let details = try? runPerformanceTool(
                            "/bin/ps",
                            arguments: ["-p", "\(pid)", "-o", "pgid=,command="]
                          ),
                          details.status == 0,
                          details.output.contains(orphanMarker.path),
                          let groupText = details.output.split(whereSeparator: { $0.isWhitespace }).first,
                          let group = pid_t(groupText), group > 1 else { continue }
                    _ = kill(-group, SIGKILL)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        for directory in [sandboxParent, fakeBinary.deletingLastPathComponent(),
                          bundle, preferences, realPreferences] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        try Data("bundle bleibt erhalten".utf8).write(to: bundleFile)
        try """
        #!/bin/bash
        [ "$CFPREFERENCES_AVOID_DAEMON" = "1" ] || exit 91
        [ "$HOME" = "$CFFIXED_USER_HOME" ] || exit 92
        [ -n "$FASTRA_SELFTEST_DEFAULTS_SUITE" ] || exit 93
        [ -n "$FASTRA_TEST_DEFAULTS_REGISTRY" ] || exit 94
        domain="$FASTRA_SELFTEST_DEFAULTS_SUITE"
        printf '%s\n' "$domain" >> "$FASTRA_TEST_DEFAULTS_REGISTRY"
        printf '%s|%s|%s|%s\n' \
          "$FASTRA_SELFTEST" "$domain" "$TMPDIR" "$CFFIXED_USER_HOME" \
          >> "$FASTRA_TEST_PROBE"
        touch "$FASTRA_TEST_PREFERENCES_DIRECTORY/$domain.plist"
        touch "$FASTRA_TEST_REAL_PREFERENCES_DIRECTORY/$domain.plist"
        # cfprefsd schreibt gelegentlich erst nach dem App-Ende. Die entkoppelte
        # Probe bildet genau diesen Nachlauf außerhalb der App-Prozessgruppe ab.
        /usr/bin/python3 -c \
          'import os,sys,time; os.setsid(); time.sleep(.2); open(sys.argv[1],"ab").close()' \
          "$FASTRA_TEST_PREFERENCES_DIRECTORY/$domain.plist" &
        /usr/bin/python3 -c \
          'import os,sys,time; os.setsid(); time.sleep(.2); open(sys.argv[1],"ab").close()' \
          "$FASTRA_TEST_REAL_PREFERENCES_DIRECTORY/$domain.plist" &
        # Dieses TERM-resistente Kind bleibt dagegen absichtlich in der vom
        # Runner angelegten App-Prozessgruppe. Der Wrapper muss es auch dann
        # beenden, wenn sein App-Leiter bereits normal ausgestiegen ist.
        orphan_ready="$TMPDIR/orphan-ready.$$"
        /bin/bash -c \
          'trap "" TERM; orphan_marker="$1"; orphan_ready="$2"; : > "$orphan_ready"; while :; do /bin/sleep 1; done' \
          fastra-portable-orphan "$FASTRA_TEST_ORPHAN_MARKER" "$orphan_ready" &
        orphan_pid=$!
        printf '%s\n' "$orphan_pid" >> "$FASTRA_TEST_ORPHAN_PIDS"
        for _ in 1 2 3 4 5 6 7 8 9 10; do
          [ -e "$orphan_ready" ] && break
          /bin/sleep 0.01
        done
        [ -e "$orphan_ready" ] || exit 95
        echo "SELFTEST $FASTRA_SELFTEST: PASS — Probe" >&2
        exit 0
        """.write(to: fakeBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path
        )

        let result = try runPerformanceTool(
            "/bin/bash", arguments: [runner.path, fakeApp.path, resources.path],
            environment: [
                "FASTRA_TEST_SANDBOX_PARENT": sandboxParent.path,
                "FASTRA_TEST_PREFERENCES_DIRECTORY": preferences.path,
                "FASTRA_TEST_REAL_PREFERENCES_DIRECTORY": realPreferences.path,
                "FASTRA_TEST_PROBE": probe.path,
                "FASTRA_TEST_ORPHAN_PIDS": orphanPIDs.path,
                "FASTRA_TEST_ORPHAN_MARKER": orphanMarker.path,
            ]
        )
        #expect(result.status == 0, "Portabilitäts-Runner: \(result.output)")
        let starts = try String(contentsOf: probe, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) }
        #expect(starts.count == 2)
        #expect(starts.map(\.first) == ["localization", "search"])
        #expect(starts.allSatisfy { $0.count == 4 })
        #expect(Set(starts.compactMap { $0.count > 1 ? $0[1] : nil }).count == 2,
                "Jeder App-Start braucht eine eigene Preferences-Suite")
        for start in starts where start.count == 4 {
            #expect(start[2].hasPrefix(sandboxParent.path + "/"))
            #expect(start[3].hasPrefix(sandboxParent.path + "/"))
        }
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: sandboxParent.path
        ).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: preferences.path
        ).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: realPreferences.path
        ).isEmpty)
        #expect(try String(contentsOf: bundleFile, encoding: .utf8)
            == "bundle bleibt erhalten")
        let recordedOrphans = try String(contentsOf: orphanPIDs, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .compactMap { pid_t($0) }
        #expect(recordedOrphans.count == 2)
        for pid in recordedOrphans {
            errno = 0
            #expect(kill(pid, 0) == -1 && errno == ESRCH,
                    "Verwaistes Kind \(pid) lebt nach der Portabilitätsprüfung weiter")
        }
    }

    @Test("Unit-Test-Runner beendet verwaistes Kind nach Ende des Testprozesses")
    func unitTestRunnerStopsOrphanAfterRootExit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-unit-orphan-test-\(UUID().uuidString)")
        let sandboxParent = root.appendingPathComponent("sandboxes")
        let bin = root.appendingPathComponent("bin")
        let fakeSwift = bin.appendingPathComponent("swift")
        let probe = root.appendingPathComponent("child.txt")
        let runner = performanceToolsDirectory.deletingLastPathComponent()
            .appendingPathComponent("test.sh")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: sandboxParent, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try """
        #!/bin/bash
        trap '' TERM
        sleep 30 &
        printf '%s\n' "$!" > "$FASTRA_TEST_PROBE"
        exit 7
        """.write(to: fakeSwift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeSwift.path
        )

        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let result = try runPerformanceTool(
            "/bin/bash", arguments: [runner.path], environment: [
                "PATH": bin.path + ":" + oldPath,
                "FASTRA_TEST_SANDBOX_PARENT": sandboxParent.path,
                "FASTRA_TEST_PROBE": probe.path,
            ]
        )
        #expect(result.status == 7)
        let childPID = try #require(Int32(
            String(contentsOf: probe, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        #expect(kill(childPID, 0) != 0, "Verwaistes Kind blieb nach Runner-Ende aktiv")
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: sandboxParent.path
        ).isEmpty)
    }

    @Test("Unit-Test-Runner beendet beim Signal auch gestoppte Kindprozesse")
    func unitTestRunnerStopsChildrenOnSignal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-unit-signal-test-\(UUID().uuidString)")
        let sandboxParent = root.appendingPathComponent("sandboxes")
        let bin = root.appendingPathComponent("bin")
        let fakeSwift = bin.appendingPathComponent("swift")
        let probe = root.appendingPathComponent("pids.txt")
        let runner = performanceToolsDirectory.deletingLastPathComponent()
            .appendingPathComponent("test.sh")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: sandboxParent, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try """
        #!/bin/bash
        trap '' TERM
        sleep 30 &
        child=$!
        printf '%s %s\n' "$$" "$child" > "$FASTRA_TEST_PROBE"
        kill -STOP $$
        wait "$child"
        """.write(to: fakeSwift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeSwift.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [runner.path]
        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": bin.path + ":" + oldPath,
            "FASTRA_TEST_SANDBOX_PARENT": sandboxParent.path,
            "FASTRA_TEST_PROBE": probe.path,
        ], uniquingKeysWith: { _, new in new })
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: probe.path), Date() < deadline {
            usleep(20_000)
        }
        #expect(FileManager.default.fileExists(atPath: probe.path))
        process.terminate()
        process.waitUntilExit()

        let pids = try String(contentsOf: probe, encoding: .utf8)
            .split(separator: " ").compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        #expect(pids.count == 2)
        for _ in 0..<100 where pids.contains(where: { kill($0, 0) == 0 }) {
            usleep(20_000)
        }
        for pid in pids {
            #expect(kill(pid, 0) != 0, "Runner ließ Prozess \(pid) zurück")
        }
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: sandboxParent.path
        ).isEmpty)
    }

    @Test("Messdatei ist atomar, begrenzt und ignoriert unqualifizierte Läufe")
    func performanceStorageSelfTest() throws {
        let script = performanceToolsDirectory
            .appendingPathComponent("selftest-performance.py")
        let result = try runPerformanceTool(
            "/usr/bin/python3", arguments: [script.path, "self-test"]
        )
        #expect(result.status == 0)
        #expect(result.output.contains("PERFORMANCE-SELFTEST PASS"))
    }

    @Test("Fenster-Sperre blockiert Parallelbetrieb und übernimmt tote Besitzer")
    func guiLockSerializesAcrossRunners() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-gui-lock-test-\(UUID().uuidString)")
        let release = directory.appendingPathExtension("release")
        let script = performanceToolsDirectory.appendingPathComponent("gui-test-lock.sh")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: release)
        }

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/bash")
        holder.arguments = [
            "-c",
            ". \"$1\"; FASTRA_GUI_LOCK_DIR=\"$2\"; "
                + "acquire_fastra_gui_test_lock || exit $?; "
                + "while [ ! -e \"$3\" ]; do sleep 0.01; done; "
                + "release_fastra_gui_test_lock",
            "lock-holder", script.path, directory.path, release.path,
        ]
        holder.standardOutput = FileHandle.nullDevice
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        defer {
            if holder.isRunning {
                try? Data().write(to: release)
                holder.terminate()
                holder.waitUntilExit()
            }
        }

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("pid").path
        ), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("pid").path
        ))

        let contender = try runPerformanceTool(
            "/bin/bash",
            arguments: [
                "-c",
                ". \"$1\"; FASTRA_GUI_LOCK_DIR=\"$2\"; "
                    + "acquire_fastra_gui_test_lock",
                "lock-contender", script.path, directory.path,
            ]
        )
        #expect(contender.status == 2)
        #expect(contender.output.contains("läuft bereits"))
        try Data().write(to: release)
        holder.waitUntilExit()
        #expect(holder.terminationStatus == 0)
        try? FileManager.default.removeItem(at: release)

        // Das atomare mkdir geschieht knapp vor dem Schreiben der PID. Ein
        // Mitbewerber darf diese frische, noch unvollständige Sperre nicht
        // irrtümlich als verwaist entfernen.
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: false)
        let acquiring = try runPerformanceTool(
            "/bin/bash",
            arguments: [
                "-c",
                ". \"$1\"; FASTRA_GUI_LOCK_DIR=\"$2\"; "
                    + "acquire_fastra_gui_test_lock",
                "lock-acquiring", script.path, directory.path,
            ]
        )
        #expect(acquiring.status == 2)
        #expect(acquiring.output.contains("wird gerade eingerichtet"))
        #expect(FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.removeItem(at: directory)

        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: false)
        try "999999\n".write(
            to: directory.appendingPathComponent("pid"),
            atomically: true,
            encoding: .utf8
        )
        let recovery = try runPerformanceTool(
            "/bin/bash",
            arguments: [
                "-c",
                ". \"$1\"; FASTRA_GUI_LOCK_DIR=\"$2\"; "
                    + "acquire_fastra_gui_test_lock && release_fastra_gui_test_lock",
                "lock-recovery", script.path, directory.path,
            ]
        )
        #expect(recovery.status == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Abgewiesener Runner beendet den Prozess des Sperrenbesitzers nicht")
    func rejectedRunnerDoesNotKillLockOwnersApp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-runner-lock-test-\(UUID().uuidString)")
        let lock = root.appendingPathComponent("runner.lock")
        let fakeApp = root.appendingPathComponent("Fastra")
        let childPID = root.appendingPathComponent("child.pid")
        let release = root.appendingPathComponent("release")
        let lockScript = performanceToolsDirectory.appendingPathComponent("gui-test-lock.sh")
        let runner = performanceToolsDirectory.deletingLastPathComponent()
            .appendingPathComponent("selftest.sh")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        try "#!/bin/bash\nexec sleep 30\n".write(to: fakeApp, atomically: true,
                                              encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeApp.path
        )

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/bash")
        holder.arguments = [
            "-c",
            ". \"$1\"; FASTRA_GUI_LOCK_DIR=\"$2\"; "
                + "acquire_fastra_gui_test_lock || exit $?; "
                + "\"$3\" & child=$!; printf '%s\\n' \"$child\" > \"$4\"; "
                + "while [ ! -e \"$5\" ]; do sleep 0.01; done; "
                + "kill \"$child\" 2>/dev/null || true; "
                + "wait \"$child\" 2>/dev/null || true; "
                + "release_fastra_gui_test_lock",
            "runner-holder", lockScript.path, lock.path, fakeApp.path, childPID.path,
            release.path,
        ]
        holder.standardOutput = FileHandle.nullDevice
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        defer {
            if holder.isRunning {
                try? Data().write(to: release)
                holder.terminate()
                holder.waitUntilExit()
            }
        }

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: childPID.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let pidText = try String(contentsOf: childPID, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(pidText))

        let contender = try runPerformanceTool(
            "/bin/bash",
            arguments: [runner.path, "search"],
            environment: [
                "FASTRA_GUI_LOCK_DIR": lock.path,
                "FASTRA_SELFTEST_APP_BIN": fakeApp.path,
            ]
        )
        #expect(contender.status == 2)
        #expect(kill(pid, 0) == 0)
        try Data().write(to: release)
        holder.waitUntilExit()
        #expect(holder.terminationStatus == 0)
    }
}
