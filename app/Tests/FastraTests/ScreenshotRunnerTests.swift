import Darwin
import Foundation
import Testing
@testable import Fastra

private let screenshotAppDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private final class ScreenshotRunnerFixture {
    let root: URL
    let app: URL
    let capture: URL
    let output: URL
    let probe: URL
    let pids: URL
    let capturePIDs: URL
    let sandbox: URL
    let lock: URL

    init() throws {
        root = testTemporaryDirectory().appendingPathComponent("fastra-shots-\(UUID().uuidString)")
        app = root.appendingPathComponent("Fastra")
        capture = root.appendingPathComponent("capture")
        output = root.appendingPathComponent("images")
        probe = root.appendingPathComponent("calls")
        pids = root.appendingPathComponent("pids")
        capturePIDs = root.appendingPathComponent("capture-pids")
        sandbox = root.appendingPathComponent("sandboxes")
        lock = root.appendingPathComponent("gui.lock")
        for directory in [root, output, sandbox] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try #"""
        #!/bin/bash
        set -u
        [ "$HOME" = "$CFFIXED_USER_HOME" ] || exit 91
        [[ "$TMPDIR" == "$FASTRA_TEST_SANDBOX_PARENT/"* ]] || exit 92
        [[ "$FASTRA_SELFTEST_DEFAULTS_SUITE" == Fastra-* ]] || exit 93
        [[ " $* " == *" -app.appearance light "* ]] || exit 94
        # `-AppleLanguages` bestimmt die Oberfläche der Aufnahme;
        # `FASTRA_SCREENSHOT_LANGUAGE` nur die Beispieldaten. Beide sind nötig,
        # damit etwa `.en.png` tatsächlich eine englische Oberfläche zeigt.
        [[ " $* " == *" -AppleLanguages ($FASTRA_SCREENSHOT_LANGUAGE) "* ]] || exit 96
        case "$FASTRA_SCREENSHOT_LANGUAGE" in
          de) expected_locale=de_DE ;;
          en) expected_locale=en_US ;;
          *) exit 97 ;;
        esac
        [[ " $* " == *" -AppleLocale $expected_locale "* ]] || exit 98
        test_name="$2"
        case "$test_name" in
          projectshot) marker=PROJECTSHOT-WINDOW ;;
          wildcardshot) marker=WILDCARDSHOT-WINDOW ;;
          regexshot) marker=REGEXSHOT-WINDOW ;;
          aboutshot) marker=ABOUTSHOT-WINDOW ;;
          *) exit 95 ;;
        esac
        printf '%s\n' "$$" >> "$FASTRA_TEST_SHOT_PIDS"
        printf '%s|%s\n' "$test_name" "$FASTRA_SCREENSHOT_LANGUAGE" >> "$FASTRA_TEST_SHOT_PROBE"
        trap 'exit 0' TERM
        printf '%s 42\n' "$marker" >&2
        if [ -n "$FASTRA_TEST_SHOT_CAPTURE_PIDS" ]; then
          # Den Helfer mit seiner regulären Bereitschaftsfrist abwarten.
          deadline=$((SECONDS + 45))
          while [ ! -s "$FASTRA_TEST_SHOT_CAPTURE_PIDS" ]; do
            [ "$SECONDS" -lt "$deadline" ] || exit 99
            /bin/sleep 0.05
          done
          exit 73
        fi
        while :; do /bin/sleep 1; done
        """#.write(to: app, atomically: true, encoding: .utf8)
        try #"""
        #!/usr/bin/python3
        import os, pathlib, sys, time
        assert '-x' in sys.argv and '-l42' in sys.argv
        assert os.environ['HOME'] == os.environ['CFFIXED_USER_HOME']
        assert os.environ['TMPDIR'].startswith(os.environ['FASTRA_TEST_SANDBOX_PARENT'] + '/')
        process_record = os.environ['FASTRA_TEST_SHOT_CAPTURE_PIDS']
        if process_record:
            record = pathlib.Path(process_record)
            pending = record.with_suffix('.tmp')
            pending.write_text(f'{os.getpid()} {os.getppid()}\n', encoding='ascii')
            pending.replace(record)
            # Der echte Helfer wartet auf die Aufnahme. Der Runner muss das
            # App-Ende vorher erkennen und beide Aufnahmeprozesse aufräumen.
            time.sleep(30)
        if os.environ.get('FASTRA_TEST_SHOT_FAIL') == '1':
            raise SystemExit(7)
        pathlib.Path(sys.argv[-1]).write_bytes(b'\x89PNG\r\n\x1a\nfixture')
        """#.write(to: capture, atomically: true, encoding: .utf8)
        for executable in [app, capture] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
    }

    deinit {
        // Unabhängiger Notausgang auch bei einer Regression des Runners.
        for pid in recordedPIDs { stopTestFixtureProcess(pid, marker: app.path) }
        let captures = recordedCapturePIDs
        if captures.count == 2 {
            stopTestFixtureProcess(captures[1], marker: output.path)
            stopTestFixtureProcess(captures[0], marker: capture.path)
        }
        try? FileManager.default.removeItem(at: root)
    }

    var recordedPIDs: [pid_t] { readPIDs(from: pids) }
    var recordedCapturePIDs: [pid_t] { readPIDs(from: capturePIDs) }

    private func readPIDs(from url: URL) -> [pid_t] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
    }

    func run(failure: Bool = false, blocked: Bool = false,
             diagnostic: String? = nil, language: String = "de",
             crashDuringCapture: Bool = false) throws -> TestProcessResult {
        let runner = screenshotAppDirectory.appendingPathComponent("screenshot-run.sh")
        var arguments = [runner.path, "all", "search"]
        if let diagnostic {
            arguments = [screenshotAppDirectory.appendingPathComponent("selftest.sh").path, diagnostic]
        }
        if blocked {
            arguments = ["-c", #"""
            . "$1"
            acquire_fastra_gui_test_lock || exit 90
            trap release_fastra_gui_test_lock EXIT
            "$2" all search
            """#, "blocked-shot", screenshotAppDirectory.appendingPathComponent("tools/gui-test-lock.sh").path,
                         runner.path]
        }
        return try runTestProcess("/bin/bash", arguments: arguments, environment: [
            "PATH": try pathIgnoringForeignFastraProcess(in: root),
            "FASTRA_SELFTEST_APP_BIN": app.path,
            "FASTRA_SELFTEST_SCREENSHOT_DIR": output.path,
            "FASTRA_SELFTEST_LANGUAGE": language,
            "FASTRA_TEST_SCREENCAPTURE": capture.path,
            "FASTRA_TEST_SCREEN_CAPTURE_ALLOWED": "1",
            "FASTRA_SELFTEST_TEST_CONSOLE_UNLOCKED": "1",
            "FASTRA_TEST_SHOT_FAIL": failure ? "1" : "0",
            "FASTRA_TEST_SHOT_PROBE": probe.path,
            "FASTRA_TEST_SHOT_PIDS": pids.path,
            "FASTRA_TEST_SHOT_CAPTURE_PIDS": crashDuringCapture ? capturePIDs.path : "",
            "FASTRA_TEST_SANDBOX_PARENT": sandbox.path,
            // `screenshot-run.sh` verwendet das echte `selftest.sh`. Für Fixtures den
            // Produktzustand umleiten, damit der Runner keine Nutzereinstellungen sichert.
            "FASTRA_SELFTEST_PRODUCT_DEFAULTS_DOMAIN": throwawayProductDefaultsDomain(),
            "FASTRA_SELFTEST_PRODUCT_SAVED_STATE_DIR":
                throwawayProductSavedStateDirectory(in: sandbox).path,
            "FASTRA_GUI_LOCK_DIR": lock.path,
        ])
    }
}

@Suite("Screenshot-Runner", .serialized)
struct SerialRunnerIntegrationScreenshotTests {
    @Test("Über-Dialog-Diagnose erzeugt eine Aufnahme und beendet ihre App", arguments: ["de", "en"])
    func capturesAboutDiagnostic(_ language: String) throws {
        let fixture = try ScreenshotRunnerFixture()
        let result = try fixture.run(diagnostic: "aboutshot", language: language)
        try #require(result.status == 0, "Über-Dialog-Aufnahme: \(result.output)")
        #expect(result.output.contains("SELFTEST-RESULT v=1 test=aboutshot status=PASS"))
        let filename = language == "en" ? "about.en.png" : "about.png"
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path) == [filename])
        #expect(try String(contentsOf: fixture.probe, encoding: .utf8) == "aboutshot|\(language)\n")
        #expect(fixture.recordedPIDs.count == 1)
        for pid in fixture.recordedPIDs { #expect(kill(pid, 0) != 0) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.sandbox.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.lock.path))
    }

    @Test("Runner meldet den App-Exit während der Aufnahme und räumt die Testprozesse auf")
    func detectsAppExitWhileCaptureHelperIsLive() throws {
        let fixture = try ScreenshotRunnerFixture()
        let result = try fixture.run(diagnostic: "aboutshot", crashDuringCapture: true)
        #expect(result.status == 1, "App-Ende während der Aufnahme: \(result.output)")
        #expect(result.output.split(separator: "\n")
            .filter { $0.hasPrefix("SELFTEST-RESULT ") }
            == ["SELFTEST-RESULT v=1 test=aboutshot status=FAIL"])
        #expect(result.output.contains("Testprozess endete vorzeitig ohne Ergebnis-Zeile (Exit 73)"))
        #expect(!result.output.contains("Aufräumfehler"))

        #expect(fixture.recordedCapturePIDs.count == 2)
        #expect(fixture.recordedPIDs.count == 1)
        let pids = Set(fixture.recordedPIDs + fixture.recordedCapturePIDs)
        #expect(pids.count == 3)
        for pid in pids { #expect(kill(pid, 0) != 0) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(at: fixture.sandbox, includingPropertiesForKeys: nil)
        try #require(remaining.count == 1)
        let evidence = try #require(remaining.first)
        #expect(evidence.lastPathComponent.hasPrefix("fastra-selftest-befunde-"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: evidence.path) == ["aboutshot.stderr"])
        let log = evidence.appendingPathComponent("aboutshot.stderr")
        let label = "  Diagnose: "
        let line = try #require(result.output.split(separator: "\n").first { $0.hasPrefix(label) })
        let reported = URL(fileURLWithPath: String(line.dropFirst(label.count))).resolvingSymlinksInPath()
        #expect(reported.path == log.resolvingSymlinksInPath().path)
        #expect(try String(contentsOf: log, encoding: .utf8).contains("ABOUTSHOT-WINDOW 42"))
        #expect(!FileManager.default.fileExists(atPath: fixture.lock.path))
    }

    @Test("Fehlgeschlagene Über-Dialog-Aufnahme erhält das vorhandene Bild")
    func aboutCaptureFailureKeepsExistingImage() throws {
        let fixture = try ScreenshotRunnerFixture()
        let image = fixture.output.appendingPathComponent("about.png")
        try Data("vorher".utf8).write(to: image)
        let result = try fixture.run(failure: true, diagnostic: "aboutshot")
        #expect(result.status == 2, "Über-Dialog-Aufnahmefehler: \(result.output)")
        #expect(try Data(contentsOf: image) == Data("vorher".utf8))
        #expect(fixture.recordedPIDs.count == 1)
        for pid in fixture.recordedPIDs { #expect(kill(pid, 0) != 0) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.sandbox.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.lock.path))
    }

    @Test("Bilder beider Sprachen entstehen im gemeinsamen isolierten Runner")
    func createsBothLanguagesAndStopsApps() throws {
        let fixture = try ScreenshotRunnerFixture()
        let result = try fixture.run()
        #expect(result.status == 0, "Screenshot-Runner: \(result.output)")
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).sorted()
        #expect(names == ["search-regex.en.png", "search-regex.png", "search-wildcards.en.png", "search-wildcards.png"])
        let calls = try String(contentsOf: fixture.probe, encoding: .utf8)
        #expect(calls == "wildcardshot|de\nregexshot|de\nwildcardshot|en\nregexshot|en\n")
        #expect(fixture.recordedPIDs.count == 4)
        for pid in fixture.recordedPIDs { #expect(kill(pid, 0) != 0) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.sandbox.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.lock.path))
    }

    @Test("Aufnahmefehler behalten vorhandene Bilder und räumen die App auf")
    func captureFailureKeepsExistingImage() throws {
        let fixture = try ScreenshotRunnerFixture()
        let image = fixture.output.appendingPathComponent("search-wildcards.png")
        try Data("vorher".utf8).write(to: image)
        let result = try fixture.run(failure: true)
        #expect(result.status == 2, "Screenshot-Fehler: \(result.output)")
        #expect(try Data(contentsOf: image) == Data("vorher".utf8))
        #expect(fixture.recordedPIDs.count == 2)
        for pid in fixture.recordedPIDs { #expect(kill(pid, 0) != 0) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.sandbox.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.lock.path))
    }

    @Test("Gemeinsame GUI-Sperre verhindert bereits den Screenshot-App-Start")
    func rejectsConcurrentRunner() throws {
        let fixture = try ScreenshotRunnerFixture()
        let result = try fixture.run(blocked: true)
        #expect(result.status == 2, "Screenshot-Sperre: \(result.output)")
        #expect(!FileManager.default.fileExists(atPath: fixture.probe.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.sandbox.path).isEmpty)
    }

    @Test("Aufnahme-Helfer prüft Berechtigung, Dateinamen und fehlgeschlagene Ausgabe")
    func captureHelperRegressions() throws {
        let script = screenshotAppDirectory.appendingPathComponent("tools/tests/test_selftest_screenshot.py")
        let result = try runTestProcess("/usr/bin/python3", arguments: [script.path])
        #expect(result.status == 0, "Aufnahme-Helfer: \(result.output)")
        #expect(result.output.contains("\nOK\n"))
    }
}
