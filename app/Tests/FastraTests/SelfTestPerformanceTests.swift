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

private func canonicalPath(for url: URL) -> String? {
    url.path.withCString { source in
        guard let resolved = realpath(source, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
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

/// Die Runner-Fixtures dürfen eine parallel benutzte Produkt-App nicht als
/// Teil ihrer künstlichen Prozesswelt behandeln. Nur die eine globale
/// Fremd-App-Abfrage wird ausgeblendet; Kindprozess-Abfragen gehen weiter an
/// das echte `pgrep`, damit die Cleanup-Tests aussagekräftig bleiben.
private func pathIgnoringForeignFastraProcess(in root: URL) throws -> String {
    let bin = root.appendingPathComponent("bin")
    let pgrep = bin.appendingPathComponent("pgrep")
    try FileManager.default.createDirectory(
        at: bin, withIntermediateDirectories: true
    )
    try #"""
    #!/bin/bash
    if [ "${1:-}" = "-f" ] \
       && [ "${2:-}" = '/Fastra\.app/Contents/MacOS/Fastra([[:space:]]|$)' ]; then
      exit 1
    fi
    exec /usr/bin/pgrep "$@"
    """#.write(to: pgrep, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: pgrep.path
    )
    let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    return bin.path + ":" + oldPath
}

@Suite("Lokale Selbsttest-Performance", .serialized)
struct SerialRunnerIntegrationSelfTestPerformanceTests {
    @Test("Fehlende Bildschirmfreigabe startet kein Aufnahme-Werkzeug")
    func deniedScreenCaptureUsesOnlyFallback() {
        var systemCalls = 0
        var fallbackCalls = 0
        let denied: String? = SelfTestCaptureRouting.capture(
            screenCaptureAllowed: false,
            systemCapture: {
                systemCalls += 1
                return "system"
            },
            fallback: {
                fallbackCalls += 1
                return "fallback"
            }
        )
        #expect(denied == "fallback")
        #expect(systemCalls == 0)
        #expect(fallbackCalls == 1)

        let allowed: String? = SelfTestCaptureRouting.capture(
            screenCaptureAllowed: true,
            systemCapture: {
                systemCalls += 1
                return "system"
            },
            fallback: {
                fallbackCalls += 1
                return "fallback"
            }
        )
        #expect(allowed == "system")
        #expect(systemCalls == 1)
        #expect(fallbackCalls == 1)
    }

    @Test("Soak-Kopie löst Links auf und lässt Originale unangetastet")
    func soakFixtureCopyResolvesSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-soak-copy-test-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let original = root.appendingPathComponent("original.md")
        let linkedFile = source.appendingPathComponent("linked.md")
        let helper = performanceToolsDirectory.appendingPathComponent("test-sandbox.sh")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: source, withIntermediateDirectories: true
        )
        try "original\n".write(to: original, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: linkedFile, withDestinationURL: original
        )

        let script = """
        set -u
        . "$1"
        copy_fastra_test_directory_resolving_symlinks "$2" "$3" || exit 91
        [ -f "$3/linked.md" ] && [ ! -L "$3/linked.md" ] || exit 92
        printf 'sandbox\n' > "$3/linked.md"
        [ "$(cat "$4")" = original ] || exit 93
        """
        let result = try runPerformanceTool(
            "/bin/bash",
            arguments: [
                "-c", script, "soak-copy", helper.path, source.path,
                destination.path, original.path,
            ]
        )
        #expect(result.status == 0, "Sichere Soak-Kopie: \(result.output)")
    }

    @Test("LaunchServices-Abmeldung schützt installierte und fremde Bundles")
    func launchServicesCleanupRejectsUnsafeBundles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-ls-safety-test-\(UUID().uuidString)")
        let wrongApp = root.appendingPathComponent("Wrong.app")
        let wrongInfo = wrongApp.appendingPathComponent("Contents/Info.plist")
        let protectedApplications = root.appendingPathComponent("Applications")
        let protectedApp = protectedApplications.appendingPathComponent("Fastra.app")
        let applicationsLink = root.appendingPathComponent("Applications-link.app")
        let fakeLSRegister = root.appendingPathComponent("lsregister")
        let probe = root.appendingPathComponent("calls.txt")
        let helper = performanceToolsDirectory.appendingPathComponent("test-sandbox.sh")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: wrongInfo.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "example.not-fastra"],
            format: .xml,
            options: 0
        )
        try infoData.write(to: wrongInfo)
        try FileManager.default.createDirectory(
            at: protectedApp, withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: applicationsLink, withDestinationURL: protectedApp
        )
        try "#!/bin/bash\nprintf '%s\\n' \"$@\" >> \"$FASTRA_TEST_LSREGISTER_LOG\"\n"
            .write(to: fakeLSRegister, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeLSRegister.path
        )

        let script = """
        set -u
        . "$1"
        FASTRA_TEST_LSREGISTER="$2"
        FASTRA_TEST_LSREGISTER_LOG="$3"
        ! unregister_fastra_test_bundle_from_launch_services "$4" || exit 91
        canonical_link=$(cd "$5" && pwd -P) || exit 92
        canonical_root=$(cd "$6" && pwd -P) || exit 93
        fastra_test_bundle_path_is_protected "$canonical_link" "$canonical_root" \
          || exit 94
        fastra_test_bundle_path_is_protected /Applications || exit 95
        [ ! -e "$3" ] || exit 96
        """
        let result = try runPerformanceTool(
            "/bin/bash",
            arguments: [
                "-c", script, "ls-safety", helper.path, fakeLSRegister.path,
                probe.path, wrongApp.path, applicationsLink.path,
                protectedApplications.path,
            ]
        )
        #expect(result.status == 0, "LaunchServices-Schutz: \(result.output)")
    }

    @Test("Portabilitäts-Frühfehler meldet kein nie gestartetes Bundle ab")
    func portableRunnerDoesNotUnregisterBeforeStart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-portable-early-test-\(UUID().uuidString)")
        let sandboxParent = root.appendingPathComponent("sandboxes")
        let fakeApp = root.appendingPathComponent("Fastra.app")
        let fakeBinary = fakeApp.appendingPathComponent("Contents/MacOS/Fastra")
        let fakeInfo = fakeApp.appendingPathComponent("Contents/Info.plist")
        let resources = root.appendingPathComponent("empty-resources")
        let fakeLSRegister = root.appendingPathComponent("lsregister")
        let launchProbe = root.appendingPathComponent("launch.txt")
        let unregisterProbe = root.appendingPathComponent("unregister.txt")
        let runner = performanceToolsDirectory.deletingLastPathComponent()
            .appendingPathComponent("verify-portable-app.sh")
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [sandboxParent, fakeBinary.deletingLastPathComponent(), resources] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "de.dm0.fastra"],
            format: .xml,
            options: 0
        )
        try infoData.write(to: fakeInfo)
        try "#!/bin/bash\ntouch \"$FASTRA_TEST_LAUNCH_PROBE\"\nexit 90\n"
            .write(to: fakeBinary, atomically: true, encoding: .utf8)
        try "#!/bin/bash\nprintf '%s\\n' \"$@\" >> \"$FASTRA_TEST_LSREGISTER_LOG\"\n"
            .write(to: fakeLSRegister, atomically: true, encoding: .utf8)
        for executable in [fakeBinary, fakeLSRegister] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path
            )
        }

        let result = try runPerformanceTool(
            "/bin/bash", arguments: [runner.path, fakeApp.path, resources.path],
            environment: [
                "FASTRA_TEST_SANDBOX_PARENT": sandboxParent.path,
                "FASTRA_TEST_LAUNCH_PROBE": launchProbe.path,
                "FASTRA_TEST_LSREGISTER": fakeLSRegister.path,
                "FASTRA_TEST_LSREGISTER_LOG": unregisterProbe.path,
            ]
        )
        #expect(result.status == 1, "Erwarteter Ressourcen-Frühfehler: \(result.output)")
        #expect(!FileManager.default.fileExists(atPath: launchProbe.path))
        #expect(!FileManager.default.fileExists(atPath: unregisterProbe.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandboxParent.path).isEmpty)
    }

    @Test("Direkter Selbsttest meldet nur das Bundle seines überschriebenen Binarys ab")
    func directSelftestUnregistersActualExecutableBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-direct-bundle-test-\(UUID().uuidString)")
        let sandboxParent = root.appendingPathComponent("sandboxes")
        let lock = root.appendingPathComponent("gui.lock")
        let fakeApp = root.appendingPathComponent("Alternate.app")
        let fakeBinary = fakeApp.appendingPathComponent("Contents/MacOS/Fastra")
        let fakeInfo = fakeApp.appendingPathComponent("Contents/Info.plist")
        let fakeLSRegister = root.appendingPathComponent("lsregister")
        let unregisterProbe = root.appendingPathComponent("unregister.txt")
        let runner = performanceToolsDirectory.deletingLastPathComponent()
            .appendingPathComponent("selftest.sh")
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [sandboxParent, fakeBinary.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "de.dm0.fastra"],
            format: .xml,
            options: 0
        )
        try infoData.write(to: fakeInfo)
        try """
        #!/bin/bash
        echo 'SELFTEST-METRIC test=search app_ms=1' >&2
        echo 'SELFTEST search: PASS — Probe' >&2
        """.write(to: fakeBinary, atomically: true, encoding: .utf8)
        try "#!/bin/bash\nprintf '%s\\n' \"$@\" >> \"$FASTRA_TEST_LSREGISTER_LOG\"\n"
            .write(to: fakeLSRegister, atomically: true, encoding: .utf8)
        for executable in [fakeBinary, fakeLSRegister] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path
            )
        }
        let isolatedPath = try pathIgnoringForeignFastraProcess(in: root)

        let result = try runPerformanceTool(
            "/bin/bash", arguments: [runner.path, "search"], environment: [
                "PATH": isolatedPath,
                "FASTRA_GUI_LOCK_DIR": lock.path,
                "FASTRA_SELFTEST_APP_BIN": fakeBinary.path,
                "FASTRA_TEST_SANDBOX_PARENT": sandboxParent.path,
                "FASTRA_TEST_LSREGISTER": fakeLSRegister.path,
                "FASTRA_TEST_LSREGISTER_LOG": unregisterProbe.path,
            ]
        )
        #expect(result.status == 0, "Direkter Selbsttest: \(result.output)")
        let unregisterArguments = try String(
            contentsOf: unregisterProbe, encoding: .utf8
        ).split(whereSeparator: \Character.isNewline).map(String.init)
        let canonicalFakeApp = try #require(canonicalPath(for: fakeApp))
        #expect(unregisterArguments == ["-u", canonicalFakeApp])
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandboxParent.path).isEmpty)
    }

    @Test("LaunchServices-Signal meldet nur den belegten Test-Bundlepfad ab")
    func launchServicesSignalTracksBundleBeforeNormalBookkeeping() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-ls-signal-test-\(UUID().uuidString)")
        let sandboxParent = root.appendingPathComponent("sandboxes")
        let lock = root.appendingPathComponent("gui.lock")
        let fakeApp = root.appendingPathComponent("Signal.app")
        let fakeBinary = fakeApp.appendingPathComponent("Contents/MacOS/Fastra")
        let fakeSource = root.appendingPathComponent("fake-app.c")
        let fakeInfo = fakeApp.appendingPathComponent("Contents/Info.plist")
        let fakeOpen = root.appendingPathComponent("open")
        let fakeLSRegister = root.appendingPathComponent("lsregister")
        let childPIDFile = root.appendingPathComponent("child.pid")
        let childCommandFile = root.appendingPathComponent("child-command.txt")
        let unregisterProbe = root.appendingPathComponent("unregister.txt")
        let runner = performanceToolsDirectory.deletingLastPathComponent()
            .appendingPathComponent("selftest.sh")
        var canonicalFakeBinary: String?
        defer {
            if let pid = try? String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let childPID = Int32(pid), kill(childPID, 0) == 0,
               let command = try? runPerformanceTool(
                   "/bin/ps", arguments: ["-p", "\(childPID)", "-o", "command="]
               ), command.output.contains(canonicalFakeBinary ?? fakeBinary.path) {
                kill(childPID, SIGKILL)
                for _ in 0..<100 where kill(childPID, 0) == 0 { usleep(10_000) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        for directory in [sandboxParent, fakeBinary.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "de.dm0.fastra"],
            format: .xml,
            options: 0
        )
        try infoData.write(to: fakeInfo)
        try """
        #include <signal.h>
        #include <unistd.h>
        int main(void) {
            signal(SIGTERM, SIG_IGN);
            for (;;) pause();
        }
        """.write(to: fakeSource, atomically: true, encoding: .utf8)
        let compile = try runPerformanceTool(
            "/usr/bin/clang", arguments: [fakeSource.path, "-o", fakeBinary.path]
        )
        try #require(compile.status == 0, "Fake-App-Kompilierung: \(compile.output)")
        try """
        #!/bin/bash
        "$FASTRA_TEST_OPEN_APP/Contents/MacOS/Fastra" -selftest cmdw -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
        child_pid=$!
        printf '%s\n' "$child_pid" > "$FASTRA_TEST_CHILD_PID"
        child_ready=0
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
          child_command="$(ps eww -p "$child_pid" -o command= 2>/dev/null || true)"
          if [[ "$child_command" == "$FASTRA_TEST_OPEN_APP/Contents/MacOS/Fastra -selftest cmdw "* ]]; then
            printf '%s\n' "$child_command" > "$FASTRA_TEST_CHILD_COMMAND"
            child_ready=1
            break
          fi
          sleep .05
        done
        if [ "$child_ready" -ne 1 ]; then
          kill -KILL "$child_pid" 2>/dev/null || true
          wait "$child_pid" 2>/dev/null || true
          exit 74
        fi
        # Ein nicht-interaktives Bash-Skript kann beim Verlassen noch auf ein
        # eigenes Hintergrundkind warten. Der open-Ersatz muss dagegen wie das
        # echte `open` sofort zurückkehren, damit Bash das TERM vor der normalen
        # Runner-Buchhaltung verarbeitet und genau dieses Fenster testet.
        disown "$child_pid" 2>/dev/null || true
        # Bash führt den Trap nach Rückkehr dieses `open`-Ersatzes aus: exakt
        # vor der normalen track_started_app_bundle-Zeile des Runners.
        kill -TERM "$PPID"
        """.write(to: fakeOpen, atomically: true, encoding: .utf8)
        try "#!/bin/bash\nprintf '%s\\n' \"$@\" >> \"$FASTRA_TEST_LSREGISTER_LOG\"\n"
            .write(to: fakeLSRegister, atomically: true, encoding: .utf8)
        for executable in [fakeBinary, fakeOpen, fakeLSRegister] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path
            )
        }
        let isolatedPath = try pathIgnoringForeignFastraProcess(in: root)

        let canonicalFakeApp = try #require(canonicalPath(for: fakeApp))
        canonicalFakeBinary = canonicalFakeApp + "/Contents/MacOS/Fastra"
        let result = try runPerformanceTool(
            "/bin/bash", arguments: [runner.path, "cmdw"], environment: [
                "PATH": isolatedPath,
                "FASTRA_GUI_LOCK_DIR": lock.path,
                "FASTRA_SELFTEST_APP_BIN": fakeBinary.path,
                "FASTRA_SELFTEST_APP_BUNDLE": fakeApp.path,
                "FASTRA_TEST_OPEN_COMMAND": fakeOpen.path,
                "FASTRA_TEST_OPEN_APP": canonicalFakeApp,
                "FASTRA_TEST_CHILD_PID": childPIDFile.path,
                "FASTRA_TEST_CHILD_COMMAND": childCommandFile.path,
                "FASTRA_TEST_SANDBOX_PARENT": sandboxParent.path,
                "FASTRA_TEST_LSREGISTER": fakeLSRegister.path,
                "FASTRA_TEST_LSREGISTER_LOG": unregisterProbe.path,
                "FASTRA_SELFTEST_TEST_CONSOLE_UNLOCKED": "1",
            ]
        )
        // Der injizierte TERM-Abbruch ist beabsichtigt; entscheidend ist, dass
        // Prozess-, Sandbox- und LaunchServices-Cleanup vollständig liefen.
        #expect(result.status != 0)
        let childCommand = (try? String(
            contentsOf: childCommandFile, encoding: .utf8
        )) ?? "<kein Prozessbeleg>"
        try #require(
            FileManager.default.fileExists(atPath: unregisterProbe.path),
            "Runner-Ausgabe: \(result.output); Prozess: \(childCommand)"
        )
        let unregisterArguments = try String(
            contentsOf: unregisterProbe, encoding: .utf8
        ).split(whereSeparator: \Character.isNewline).map(String.init)
        #expect(unregisterArguments == ["-u", canonicalFakeApp])
        guard let childPID = Int32(
            try String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            Issue.record("LaunchServices-Kindprozess-PID ist ungültig")
            return
        }
        errno = 0
        #expect(kill(childPID, 0) == -1 && errno == ESRCH)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: sandboxParent.path
        ).isEmpty)
    }

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
        let isolatedPath = try pathIgnoringForeignFastraProcess(in: root)

        let result = try runPerformanceTool(
            "/bin/bash", arguments: [runner.path, "search"], environment: [
                "PATH": isolatedPath,
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

    @Test("Signal nach Prozessfreigabe räumt auch vor der Übernahme auf")
    func pendingProcessStartRemainsOwnedUntilAdoption() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-pending-start-test-\(UUID().uuidString)")
        let sandbox = root.appendingPathComponent("sandbox")
        let temporaryDirectory = sandbox.appendingPathComponent("tmp")
        let ready = root.appendingPathComponent("runner-ready")
        let childPIDFile = root.appendingPathComponent("child.pid")
        let marker = root.appendingPathComponent("unique-child-marker")
        let helper = performanceToolsDirectory
            .appendingPathComponent("test-process-tree.sh")
        var childPID: pid_t?
        let process = Process()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            // Auch ein Fehler VOR der normalen Swift-Buchhaltung darf die
            // absichtlich TERM-resistente Fixture nicht verlieren.
            let cleanupPID = childPID ?? (try? String(
                contentsOf: childPIDFile, encoding: .utf8
            )).flatMap {
                Int32($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let cleanupPID, kill(cleanupPID, 0) == 0,
               let command = try? runPerformanceTool(
                   "/bin/ps", arguments: ["-p", "\(cleanupPID)", "-o", "command="]
               ), command.output.contains(marker.path) {
                let group = getpgid(cleanupPID)
                if group > 1 { kill(-group, SIGKILL) }
                for _ in 0..<100 where kill(cleanupPID, 0) == 0 { usleep(10_000) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true
        )

        let script = """
        set -u
        . "$1"
        FASTRA_TEST_TMPDIR="$2"
        ready="$3"
        child_pid_file="$4"
        marker="$5"
        cleanup_pending_start() {
          trap - EXIT INT TERM
          target="${FASTRA_TEST_PENDING_PID:-}"
          [[ "$target" =~ ^[0-9]+$ ]] || exit 92
          terminate_fastra_test_process_trees "$target" || exit 93
          wait "$target" 2>/dev/null || true
          fastra_test_discard_pending_session || exit 94
          exit 143
        }
        trap cleanup_pending_start TERM
        fastra_test_start_new_session /bin/bash -c 'trap "" TERM; printf "%s\\n" "$$" > "$1"; marker="$2"; while :; do sleep .1; done' pending-child "$child_pid_file" "$marker" || exit 91
        # Absichtlich NICHT übernehmen: Genau hier lag das Signal-Fenster.
        : > "$ready"
        while :; do sleep .1; done
        """
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c", script, "pending-start", helper.path, temporaryDirectory.path,
            ready.path, childPIDFile.path, marker.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let readyDeadline = Date().addingTimeInterval(4)
        while (!FileManager.default.fileExists(atPath: ready.path)
               || !FileManager.default.fileExists(atPath: childPIDFile.path)),
              Date() < readyDeadline {
            usleep(20_000)
        }
        try #require(FileManager.default.fileExists(atPath: ready.path))
        guard let parsedChildPID = Int32(
            try String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            Issue.record("Kindprozess-PID ist ungültig")
            return
        }
        childPID = parsedChildPID

        #expect(kill(process.processIdentifier, SIGTERM) == 0)
        let exitDeadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < exitDeadline { usleep(20_000) }
        let timedOut = process.isRunning
        if timedOut { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        #expect(!timedOut, "Signal-Cleanup des freigegebenen Starts hing")
        #expect(process.terminationStatus == 143)
        if let childPID {
            errno = 0
            #expect(kill(childPID, 0) == -1 && errno == ESRCH,
                    "Freigegebener Testprozess blieb nach dem Signal aktiv")
        }
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: temporaryDirectory.path
        ).isEmpty)
    }

    @Test("Signal während Handshake-Löschung bleibt ein sicherer No-op")
    func pendingHandshakeDiscardIsSignalSafe() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-discard-signal-test-\(UUID().uuidString)")
        let temporaryDirectory = root.appendingPathComponent("tmp")
        let handshake = temporaryDirectory.appendingPathComponent("process-start.fixture")
        let bin = root.appendingPathComponent("bin")
        let fakeRemove = bin.appendingPathComponent("rm")
        let helper = performanceToolsDirectory
            .appendingPathComponent("test-process-tree.sh")
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [handshake, bin] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        try """
        #!/bin/bash
        /bin/rm "$@" || exit $?
        kill -TERM "$PPID"
        """.write(to: fakeRemove, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeRemove.path
        )

        let script = """
        set -u
        . "$1"
        FASTRA_TEST_TMPDIR="$2"
        FASTRA_TEST_PENDING_PID=424242
        FASTRA_TEST_PENDING_HANDSHAKE="$3"
        FASTRA_TEST_PENDING_BUNDLE=/tmp/Fastra.app
        cleanup_discard() {
          trap - EXIT INT TERM
          fastra_test_discard_pending_session || exit 92
          [ -z "$FASTRA_TEST_PENDING_PID" ] || exit 93
          [ -z "$FASTRA_TEST_PENDING_HANDSHAKE" ] || exit 94
          [ -z "$FASTRA_TEST_PENDING_BUNDLE" ] || exit 95
          exit 143
        }
        trap cleanup_discard TERM
        PATH="$4:$PATH"
        fastra_test_discard_pending_session || exit 91
        exit 96
        """
        let result = try runPerformanceTool(
            "/bin/bash", arguments: [
                "-c", script, "discard-signal", helper.path,
                temporaryDirectory.path, handshake.path, bin.path,
            ]
        )
        #expect(result.status == 143, "Handshake-Signal: \(result.output)")
        #expect(!FileManager.default.fileExists(atPath: handshake.path))
    }

    @Test("Soak-Hilfsprozess bleibt während der Übernahme global gebunden")
    func soakHelperRemainsOwnedDuringAdoption() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-soak-helper-signal-test-\(UUID().uuidString)")
        let temporaryDirectory = root.appendingPathComponent("tmp")
        let bin = root.appendingPathComponent("bin")
        let fakeRemove = bin.appendingPathComponent("rm")
        let childPIDFile = root.appendingPathComponent("child.pid")
        let marker = root.appendingPathComponent("unique-soak-helper-marker")
        let helper = performanceToolsDirectory
            .appendingPathComponent("test-process-tree.sh")
        let soakState = performanceToolsDirectory
            .appendingPathComponent("soak-process-state.sh")
        defer {
            if let value = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
               kill(pid, 0) == 0,
               let command = try? runPerformanceTool(
                   "/bin/ps", arguments: ["-p", "\(pid)", "-o", "command="]
               ), command.output.contains(marker.path) {
                let group = getpgid(pid)
                if group > 1 { kill(-group, SIGKILL) }
                for _ in 0..<100 where kill(pid, 0) == 0 { usleep(10_000) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        for directory in [temporaryDirectory, bin] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        try """
        #!/bin/bash
        /bin/rm "$@" || exit $?
        kill -TERM "$PPID"
        """.write(to: fakeRemove, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeRemove.path
        )

        let script = """
        set -u
        . "$1"
        . "$2"
        FASTRA_TEST_TMPDIR="$3"
        child_pid_file="$4"
        marker="$5"
        cleanup_soak_helper() {
          trap - EXIT INT TERM
          target="${SOAK_PHASE_PID:-}"
          [[ "$target" =~ ^[0-9]+$ ]] || exit 92
          terminate_fastra_test_process_trees "$target" || exit 93
          wait "$target" 2>/dev/null || true
          fastra_test_discard_pending_session || exit 94
          exit 143
        }
        trap cleanup_soak_helper TERM
        fastra_test_start_new_session /bin/bash -c 'trap "" TERM; printf "%s\\n" "$$" > "$1"; marker="$2"; while :; do sleep .1; done' soak-helper "$child_pid_file" "$marker" || exit 91
        SOAK_PHASE_PID="$FASTRA_TEST_STARTED_PID"
        PATH="$6:$PATH"
        adopt_soak_process "$SOAK_PHASE_PID" || exit 95
        exit 96
        """
        let result = try runPerformanceTool(
            "/bin/bash", arguments: [
                "-c", script, "soak-helper", helper.path, soakState.path,
                temporaryDirectory.path, childPIDFile.path, marker.path, bin.path,
            ]
        )
        #expect(result.status == 143, "Soak-Hilfsprozess-Signal: \(result.output)")
        guard let childPID = Int32(
            try String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            Issue.record("Soak-Hilfsprozess-PID ist ungültig")
            return
        }
        errno = 0
        #expect(kill(childPID, 0) == -1 && errno == ESRCH,
                "Soak-Hilfsprozess blieb nach dem Signal aktiv")
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: temporaryDirectory.path
        ).isEmpty)
    }

    @Test("Soak-Adoptionsfehler beendet den Helfer und sperrt Folgestarts")
    func soakAdoptionFailureStopsHelperAndFollowups() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-soak-adopt-failure-\(UUID().uuidString)")
        let temporaryDirectory = root.appendingPathComponent("tmp")
        let bin = root.appendingPathComponent("bin")
        let fakeRemove = bin.appendingPathComponent("rm")
        let childPIDFile = root.appendingPathComponent("child.pid")
        let marker = root.appendingPathComponent("unique-soak-adopt-marker")
        let processHelper = performanceToolsDirectory
            .appendingPathComponent("test-process-tree.sh")
        let soakState = performanceToolsDirectory
            .appendingPathComponent("soak-process-state.sh")
        defer {
            if let value = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
               kill(pid, 0) == 0,
               let command = try? runPerformanceTool(
                   "/bin/ps", arguments: ["-p", "\(pid)", "-o", "command="]
               ), command.output.contains(marker.path) {
                let group = getpgid(pid)
                if group > 1 { kill(-group, SIGKILL) }
                for _ in 0..<100 where kill(pid, 0) == 0 { usleep(10_000) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        for directory in [temporaryDirectory, bin] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        try "#!/bin/bash\nexit 73\n"
            .write(to: fakeRemove, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeRemove.path
        )

        let script = """
        set -u
        . "$1"
        . "$2"
        FASTRA_TEST_TMPDIR="$3"
        child_pid_file="$4"
        marker="$5"
        fastra_test_start_new_session /bin/bash -c 'trap "" TERM; printf "%s\\n" "$$" > "$1"; marker="$2"; while :; do sleep .1; done' soak-adopt "$child_pid_file" "$marker" || exit 91
        SOAK_PHASE_PID="$FASTRA_TEST_STARTED_PID"
        PATH="$6:$PATH"
        adopt_soak_process "$SOAK_PHASE_PID" && exit 92
        [ "$SOAK_ABORT_FOLLOWING_PHASES" -eq 1 ] || exit 93
        [ -z "$SOAK_PHASE_PID" ] || exit 94
        ! fastra_test_pid_is_live "$(cat "$child_pid_file")" || exit 95
        ! soak_followup_is_safe || exit 96
        SOAK_ABORT_FOLLOWING_PHASES=0
        SOAK_PROCESS_CLEANUP_BLOCKED=1
        ! soak_followup_is_safe || exit 97
        [ -z "$FASTRA_TEST_PENDING_PID" ] || exit 98
        """
        let result = try runPerformanceTool(
            "/bin/bash", arguments: [
                "-c", script, "soak-adopt", processHelper.path, soakState.path,
                temporaryDirectory.path, childPIDFile.path, marker.path, bin.path,
            ]
        )
        #expect(result.status == 0, "Soak-Adoptionsfehler: \(result.output)")
        guard let childPID = Int32(
            try String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            Issue.record("Soak-Adoptionsfehler-PID ist ungültig")
            return
        }
        errno = 0
        #expect(kill(childPID, 0) == -1 && errno == ESRCH)
    }

    @Test("Soak-Exit-Cleanup wiederholt eine fehlgeschlagene Prozessbeendigung")
    func soakExitCleanupRetriesFailedTermination() throws {
        let soakState = performanceToolsDirectory
            .appendingPathComponent("soak-process-state.sh")
        let script = """
        set -u
        attempts=0
        terminate_fastra_test_process_trees() {
          attempts=$((attempts + 1))
          [ "$attempts" -ge 2 ]
        }
        . "$1"
        SOAK_PHASE_PID=4242
        cleanup_soak_process "$SOAK_PHASE_PID" && exit 91
        [ "$SOAK_PROCESS_CLEANUP_BLOCKED" -eq 1 ] || exit 92
        [ "${#SOAK_REMAINING_PIDS[@]}" -eq 1 ] || exit 93
        ! soak_followup_is_safe || exit 94
        retry_soak_cleanup_failures || exit 95
        [ "$attempts" -eq 2 ] || exit 96
        [ "$SOAK_PROCESS_CLEANUP_BLOCKED" -eq 0 ] || exit 97
        [ "${#SOAK_REMAINING_PIDS[@]}" -eq 0 ] || exit 98
        [ -z "$SOAK_PHASE_PID" ] || exit 99
        soak_followup_is_safe || exit 100
        """
        let result = try runPerformanceTool(
            "/bin/bash", arguments: ["-c", script, "soak-retry", soakState.path]
        )
        #expect(result.status == 0, "Soak-Exit-Retry: \(result.output)")
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
        # Der neue Runner führt nach einem Funktionsfehler auch die zweite
        # Phase aus. Das Fixture erzeugt seine Cleanup-Spuren nur im ersten
        # Aufruf; der zweite belegt die korrekte Fehleraggregation.
        [ ! -e "$FASTRA_TEST_PROBE" ] || exit 0
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
        #expect(result.status == 1, "Testfehler müssen als Exit 1 zusammengeführt werden")
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
        let fakeInfo = fakeApp.appendingPathComponent("Contents/Info.plist")
        let fakeTools = root.appendingPathComponent("bin")
        let fakeLSRegister = fakeTools.appendingPathComponent("lsregister")
        let launchServicesProbe = root.appendingPathComponent("lsregister.txt")
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
                          fakeTools, bundle, preferences, realPreferences] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        try Data("bundle bleibt erhalten".utf8).write(to: bundleFile)
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "de.dm0.fastra"],
            format: .xml,
            options: 0
        )
        try infoData.write(to: fakeInfo)
        try """
        #!/bin/bash
        printf '%s\n' "$@" >> "$FASTRA_TEST_LSREGISTER_LOG"
        """.write(to: fakeLSRegister, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeLSRegister.path
        )
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
                "FASTRA_TEST_LSREGISTER": fakeLSRegister.path,
                "FASTRA_TEST_LSREGISTER_LOG": launchServicesProbe.path,
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
        let unregisterArguments = try String(
            contentsOf: launchServicesProbe, encoding: .utf8
        ).split(whereSeparator: \Character.isNewline).map(String.init)
        let canonicalFakeApp = try #require(canonicalPath(for: fakeApp))
        #expect(unregisterArguments == ["-u", canonicalFakeApp],
                "Das direkte Test-Bundle muss am kanonischen Pfad abgemeldet werden")
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
        #expect(result.status == 1)
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
        // Eine wiederverwendete PID darf nicht genügen: Der Startzeit-Token
        // gehört zu einem anderen Prozess und macht die Sperre damit verwaist.
        try "\(ProcessInfo.processInfo.processIdentifier)\nfremder-start-token\n".write(
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
