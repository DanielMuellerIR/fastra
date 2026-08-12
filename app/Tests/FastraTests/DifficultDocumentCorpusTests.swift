// DifficultDocumentCorpusTests.swift

// Reale Größenklasse, aber ausschließlich synthetische Inhalte: Laden,
// Formatwahl und Editorlayout müssen für mehrere übliche Formate begrenzt
// bleiben. Die Suite läuft serialisiert, damit die großen temporären Strings
// nicht durch parallele Testausführung unnötig viel Speicher belegen.

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Foundation
import Testing
@testable import Fastra

@Suite("Prozeduraler Korpus schwieriger 4,36-MB-Dokumente", .serialized)
struct DifficultDocumentCorpusTests {
    @Test("Alle Formate werden vollständig geladen und als Langzeile markiert")
    func corpusLoadsAndResolvesFormat() throws {
        for fixture in DifficultDocumentFixture.all {
            let content = fixture.makeContent()
            #expect(content.utf8.count == DifficultDocumentFixture.targetByteSize,
                    "\(fixture.label) hat die falsche Größenklasse")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(fixture.filename)")
            defer { try? FileManager.default.removeItem(at: url) }
            try Data(content.utf8).write(to: url)

            let loaded = try FileLoader.load(url: url)
            #expect(loaded.content == content, "\(fixture.label) wurde verändert")
            #expect(loaded.displayMode == .text)
            #expect(loaded.hasPerformanceCriticalLongLine)

            let tab = EditorTab(
                title: fixture.filename,
                path: url.path,
                url: url,
                content: "",
                hasPerformanceCriticalLongLine: true
            )
            #expect(DocumentFormatResolver.resolve(tab: tab).id
                    == fixture.expectedFormatID)
        }
    }

    @Test("Alle Formate öffnen im echten Textlayout ohne unbeschränkten Umbruch")
    @MainActor
    func corpusEditorLayoutStaysBounded() throws {
        for fixture in DifficultDocumentFixture.all {
            let content = fixture.makeContent()
            let scrollView = NSScrollView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 600)
            )
            scrollView.hasHorizontalScroller = true
            let clock = ContinuousClock()
            let start = clock.now
            let textView = TextView(
                string: content,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                wrapLines: false
            )
            scrollView.documentView = textView
            textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
            textView.layoutManager.layoutLines()
            textView.updateFrameIfNeeded()
            textView.layoutManager.layoutLines()
            let duration = start.duration(to: clock.now)

            let fragmentViews = textView.subviews
                .compactMap { $0 as? LineFragmentView }.count
            let visibleLength = textView.visibleTextRanges
                .reduce(0) { $0 + $1.length }
            #expect(fragmentViews < 10,
                    "\(fixture.label): \(fragmentViews) Fragment-Views")
            #expect(visibleLength < 16 * 1024,
                    "\(fixture.label): \(visibleLength) sichtbare Zeichen")
            #expect(duration < .seconds(2),
                    "\(fixture.label) brauchte \(duration) bis zum Layout")
        }
    }

    @Test("JSON- und XML-Formatter erhalten den synthetischen Langtext exakt")
    func structuredFormattersKeepOpaquePayload() throws {
        let jsonFixture = DifficultDocumentFixture.json
        let jsonPayload = jsonFixture.makePayload()
        let clock = ContinuousClock()
        let jsonStart = clock.now
        let formattedJSON = try DocumentFormatter.format(
            jsonFixture.makeContent(),
            fileExtension: "json"
        )
        let jsonDuration = jsonStart.duration(to: clock.now)
        let jsonObject = try #require(
            try JSONSerialization.jsonObject(with: Data(formattedJSON.utf8))
                as? [String: Any]
        )
        #expect(jsonObject["payload"] as? String == jsonPayload)
        #expect(jsonObject["sequence"] as? Int == 1)
        #expect(jsonDuration < .seconds(5),
                "JSON-Formatierung brauchte \(jsonDuration)")

        let xmlFixture = DifficultDocumentFixture.xml
        let xmlPayload = xmlFixture.makePayload()
        let xmlStart = clock.now
        let formattedXML = try DocumentFormatter.format(
            xmlFixture.makeContent(),
            fileExtension: "xml"
        )
        let xmlDuration = xmlStart.duration(to: clock.now)
        let document = try XMLDocument(xmlString: formattedXML)
        let payloadNode = try #require(
            document.nodes(forXPath: "/document/payload").first
        )
        #expect(payloadNode.stringValue == xmlPayload)
        #expect(xmlDuration < .seconds(5),
                "XML-Formatierung brauchte \(xmlDuration)")
    }

    @Test("Editoraufbau und manueller JSON-Wechsel bleiben responsiv")
    @MainActor
    func jsonLanguageSwitchStaysResponsive() async throws {
        let content = DifficultDocumentFixture.json.makeContent()
        let clock = ContinuousClock()
        let setupStart = clock.now
        let configuration = SourceEditorConfiguration(
            appearance: .init(
                theme: EditorView.fastraTheme,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                wrapLines: false,
                tabWidth: 4
            ),
            peripherals: .init(showMinimap: false)
        )
        let controller = TextViewController(
            string: content,
            language: .default,
            configuration: configuration,
            cursorPositions: []
        )
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        let setupDuration = setupStart.duration(to: clock.now)

        let switchStart = clock.now
        controller.language = .json
        let switchDuration = switchStart.duration(to: clock.now)

        // Ein unmittelbar eingereihter Main-Queue-Turn muss trotz der echten
        // tree-sitter-Analyse durchlaufen. Das belegt Responsivität stärker
        // als nur die Rückkehr des setters.
        let nextMainTurnStart = clock.now
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let nextMainTurnDuration = nextMainTurnStart.duration(to: clock.now)

        let client = try #require(controller.treeSitterClient)
        var queryFinished = false
        var querySucceeded = false
        client.queryHighlightsFor(
            textView: controller.textView,
            range: NSRange(location: 0, length: 4096)
        ) { result in
            queryFinished = true
            if case .success = result { querySucceeded = true }
        }
        let deadline = clock.now.advanced(by: .seconds(5))
        var responsiveTurns = 0
        while !queryFinished && clock.now < deadline {
            responsiveTurns += 1
            try? await Task.sleep(for: .milliseconds(10))
        }
        let parseDuration = switchStart.duration(to: clock.now)

        #expect(setupDuration < .seconds(2),
                "Editoraufbau blockierte \(setupDuration)")
        #expect(switchDuration < .milliseconds(250),
                "Sprachwechsel blockierte \(switchDuration)")
        #expect(nextMainTurnDuration < .milliseconds(250),
                "Nächster UI-Turn wartete \(nextMainTurnDuration)")
        #expect(queryFinished && querySucceeded,
                "JSON-Parser/Highlighter wurde nicht rechtzeitig fertig")
        #expect(parseDuration < .seconds(2),
                "JSON-Parser/Highlighter brauchte \(parseDuration)")
        #expect(responsiveTurns > 0,
                "Warten auf den Parser gab der Task-Schleife keinen Turn")
    }
}
