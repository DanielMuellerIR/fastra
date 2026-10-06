import Foundation
import Darwin
import Testing
@testable import Fastra

@Suite("Fortschritt und sicherer Abbruch der Dokumentumwandlung")
struct MarkdownImportProgressTests {
    @Test("Die belegte CLI-Option wird genutzt; alte Werkzeuge behalten gültige Argumente",
          arguments: [false, true])
    @MainActor
    func capabilityArguments(hasProgress: Bool) throws {
        let folder = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Quelle.rtf")
        try "Original".write(to: source, atomically: true, encoding: .utf8)
        let service = MarkdownImportService()
        service.locateTool = { URL(fileURLWithPath: "/bin/echo") }
        var conversionArguments: [String] = []
        service.runProcess = { _, arguments, _, _, completion in
            let text: String
            if arguments.contains("--formats") {
                text = #"{"ok":true,"version":"unknown","formats":[{"format":"rtf","extensions":["rtf"],"available":true}]}"#
            } else if arguments == ["--help"] {
                text = hasProgress ? "  --progress Report phases on stderr.\n" : "Usage: converter INPUT\n"
            } else {
                conversionArguments = arguments
                return nil
            }
            completion(MarkdownImportProcessOutcome(exitCode: 0, stdout: Data(text.utf8),
                                                     stderr: Data(), outputIsComplete: true))
            return nil
        }
        var catalogReady = false
        service.withCatalog { catalogReady = $0?.isUsable == true }
        #expect(catalogReady)
        service.convert(source)
        #expect(conversionArguments.contains("--progress") == hasProgress)
        #expect(conversionArguments.suffix(2) == ["--", source.path])
    }

    @Test("UTF-8, Doppelpunkte und Chunk-Grenzen verändern keinen Zähler")
    func chunkedProgress() {
        let name = "日本: Bericht.rtf"
        let data = Data("Progress: \(name): converting page 2/7\n".utf8)
        for cut in 0...data.count {
            var parser = MarkdownImportProgressParser(sourceName: name)
            let first = parser.consume(Data(data.prefix(cut)))
            let second = parser.consume(Data(data.dropFirst(cut)))
            #expect((second ?? first) == MarkdownImportProgress(
                phase: .converting, unit: .page, completed: 2, total: 7))
        }
    }

    @Test("Ungültige, fremde und überlange Meldungen ergeben keinen erfundenen Fortschritt")
    func invalidProgress() {
        var parser = MarkdownImportProgressParser(sourceName: "Quelle")
        for line in ["Warning: Quelle: converting", "Progress: Fremd: converting",
                     "Progress: Quelle: unknown", "Progress: Quelle: converting page 9/2",
                     "Progress: Quelle: converting page -1/2", "Progress: Quelle: converting page 0/0",
                     "Progress: Quelle: converting page 92233720368547758070/99"] {
            #expect(parser.consume(Data((line + "\n").utf8)) == nil)
        }
        #expect(parser.consume(Data(repeating: 65, count: 100_000)) == nil)
        #expect(parser.consume(Data("\nProgress: Quelle: preparingOutput\n".utf8))?.phase == .preparingOutput)
    }

    @Test("Mehrere Zeilen ergeben die zuletzt gemeldete Phase")
    func latestPhase() {
        var parser = MarkdownImportProgressParser(sourceName: "Quelle")
        #expect(parser.consume(Data("Progress: Quelle: converting page 1/2\nProgress: Quelle: publishing\n".utf8))
            == MarkdownImportProgress(phase: .publishing, unit: nil, completed: nil, total: nil))
    }

    @Test("Abbruch unmittelbar vor der Erfolgsmeldung verhindert jede Übernahme")
    @MainActor
    func cancellationWinsOverQueuedSuccess() throws {
        let folder = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Quelle.rtf")
        try "Original".write(to: source, atomically: true, encoding: .utf8)
        let service = MarkdownImportService()
        service.locateTool = { URL(fileURLWithPath: "/bin/echo") }
        var finish: ((MarkdownImportProcessOutcome) -> Void)?
        var output: URL?
        var chunks: ((Data) -> Void)?
        service.runProcess = { _, arguments, _, onStderr, completion in
            output = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "--output")! + 1])
            finish = completion
            chunks = onStderr
            return nil
        }
        var completed = false
        service.convert(source) { result in
            #expect(result == nil)
            #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["Quelle.rtf"])
            completed = true
        }
        #expect(service.isRunning)
        service.cancelConversion()
        #expect(service.isCancelling && service.isRunning)
        service.clearState()
        #expect(service.isRunning)
        let directory = try #require(output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = directory.appendingPathComponent("Quelle.md")
        try "Fertiges Ergebnis".write(to: result, atomically: true, encoding: .utf8)
        chunks?(Data("Progress: Quelle.rtf: finished\n".utf8))
        finish?(MarkdownImportProcessOutcome(exitCode: 0,
            stdout: try JSONSerialization.data(withJSONObject: ["ok": true, "markdownFile": result.path]),
            stderr: Data(), outputIsComplete: true))
        #expect(completed)
        #expect(service.state == .cancelled)
        #expect(!service.isRunning && !service.isCancelling)
        #expect(try String(contentsOf: source, encoding: .utf8) == "Original")
    }

    @Test("Das echte Werkzeug liefert Fortschritt vor Prozessende und wird samt Kind gestoppt")
    @MainActor
    func serialRunnerIntegration_markdownProcessProgressAndCancellation() async throws {
        let folder = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Quelle.rtf")
        try "Original".write(to: source, atomically: true, encoding: .utf8)
        let childMarker = folder.appendingPathComponent("child-finished")
        let childPID = folder.appendingPathComponent("child-pid")
        let tool = folder.appendingPathComponent("converter")
        // Der Kindprozess würde ohne Gruppenabbruch erst nach dem Test schreiben.
        let script = """
        #!/bin/sh
        (sleep 30; touch '\(childMarker.path)') &
        echo $! > '\(childPID.path)'
        printf 'Progress: Quelle.rtf: converting page 2/5\\n' >&2
        wait
        """
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        let service = MarkdownImportService()
        service.locateTool = { tool }
        var complete = false
        service.convert(source) { result in #expect(result == nil); complete = true }
        let hasProgress = await waitUntil { service.progress?.completed == 2 }
        #expect(hasProgress, "Zustand: \(service.state), laufend: \(service.isRunning)")
        let wasRunning = !complete && service.isRunning
        #expect(wasRunning)
        service.cancelConversion()
        #expect(await waitUntil { complete })
        #expect(service.state == .cancelled)
        let pid = try #require(Int32(try String(contentsOf: childPID, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await waitUntil { Darwin.kill(pid, 0) == -1 && errno == ESRCH })
        #expect(!FileManager.default.fileExists(atPath: childMarker.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            == ["Quelle.rtf", "child-pid", "converter"])
    }

    @Test("Zeitlimit, Startfehler und CLI-Abbruch bleiben unterscheidbar")
    func terminationMessages() {
        #expect(MarkdownImportProcessOutcome(.cancelled).exitCode == 130)
        #expect(MarkdownImportProcessOutcome(.timedOut).exitCode == 124)
        #expect(!MarkdownImportProcessOutcome(.timedOut).stderr.isEmpty)
        #expect(String(decoding: MarkdownImportProcessOutcome(.startFailed(.launchFailed("reason"))).stderr,
                       as: UTF8.self) == "reason")
    }
}
