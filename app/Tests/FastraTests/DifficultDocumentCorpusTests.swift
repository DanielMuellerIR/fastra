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
    @Test("Alle Formate werden vollständig geladen und richtig aufgelöst")
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

            let tab = EditorTab(
                title: fixture.filename,
                path: url.path,
                url: url,
                content: ""
            )
            #expect(DocumentFormatResolver.resolve(tab: tab).id
                    == fixture.expectedFormatID)
        }
    }

    @Test("Alle Formate öffnen mit Soft Wrap im echten Textlayout")
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
                wrapLines: true
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
            #expect(fragmentViews < 100,
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

    @Test("Formatierter 4,36-MB-JSON-Text wird mit Soft Wrap schnell übernommen")
    @MainActor
    func formattedJSONAppliesToWrappedEditorQuickly() throws {
        let source = DifficultDocumentFixture.json.makeContent()
        let formatted = try DocumentFormatter.format(
            source,
            fileExtension: "json"
        )
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        scrollView.hasVerticalScroller = true
        let textView = TextView(
            string: source,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            wrapLines: true
        )
        scrollView.documentView = textView
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.layoutManager.layoutLines()
        textView.updateFrameIfNeeded()

        let clock = ContinuousClock()
        let start = clock.now
        textView.fastraApplyTextOperation(
            replacing: NSRange(location: 0, length: textView.textStorage.length),
            with: formatted
        )
        let duration = start.duration(to: clock.now)

        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(textView.string.utf8))
                as? [String: Any]
        )["payload"] as? String
        let fragmentViews = textView.subviews
            .compactMap { $0 as? LineFragmentView }
            .filter { $0.lineFragment != nil }.count
        #expect(textView.string == formatted)
        #expect(payload == DifficultDocumentFixture.json.makePayload())
        #expect(duration < .seconds(2),
                "Editorübernahme brauchte \(duration)")
        #expect(fragmentViews < 100,
                "Editorübernahme erzeugte \(fragmentViews) Fragment-Views")
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
                wrapLines: true,
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

        let defaultColor = try #require(
            controller.attributesFor(nil)[.foregroundColor] as? NSColor
        )
        let stringColor = try #require(
            controller.attributesFor(.string)[.foregroundColor] as? NSColor
        )
        #expect(!defaultColor.isEqual(stringColor),
                "Das Test-Theme muss Strings sichtbar unterscheiden")
        func hasStringColor(at location: Int) -> Bool {
            (controller.textView.textStorage.attribute(
                .foregroundColor,
                at: location,
                effectiveRange: nil
            ) as? NSColor)?.isEqual(stringColor) == true
        }

        let firstPayloadCharacter = DifficultDocumentFixture.json.prefix.utf16.count
        let initialHighlightDeadline = clock.now.advanced(by: .seconds(5))
        while !hasStringColor(at: firstPayloadCharacter),
              clock.now < initialHighlightDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let initialColor = controller.textView.textStorage.attribute(
            .foregroundColor,
            at: firstPayloadCharacter,
            effectiveRange: nil
        ) as? NSColor

        // Das Einfärben bleibt abschnittsweise: Nach echtem Scrollen wird nur
        // der neue sichtbare Teil der Megazeile angefordert und anschließend
        // korrekt als JSON-String dargestellt.
        let scrollView = try #require(controller.textView.enclosingScrollView)
        let initialVisibleRange = try #require(controller.textView.visibleTextRange)
        let middleY = max(0, controller.textView.layoutManager.estimatedHeight() / 2)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: middleY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        controller.textView.layoutManager.layoutLines(in: NSRect(
            x: 0,
            y: middleY,
            width: scrollView.contentView.bounds.width,
            height: scrollView.contentView.bounds.height
        ))
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        let scrolledVisibleRange = try #require(controller.textView.visibleTextRange)
        let scrolledCharacter = min(
            scrolledVisibleRange.location + 32,
            controller.textView.textStorage.length - 1
        )
        let colorBeforeScrolledHighlight = controller.textView.textStorage.attribute(
            .foregroundColor,
            at: scrolledCharacter,
            effectiveRange: nil
        ) as? NSColor
        let scrolledHighlightDeadline = clock.now.advanced(by: .seconds(5))
        while !hasStringColor(at: scrolledCharacter),
              clock.now < scrolledHighlightDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let colorAfterScrolledHighlight = controller.textView.textStorage.attribute(
            .foregroundColor,
            at: scrolledCharacter,
            effectiveRange: nil
        ) as? NSColor

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
        #expect(initialColor?.isEqual(stringColor) == true,
                "Der erste sichtbare JSON-Ausschnitt wurde nicht eingefärbt")
        #expect(scrolledVisibleRange.location > initialVisibleRange.max,
                "Der Test hat die Megazeile nicht bis zu einem neuen Ausschnitt gescrollt")
        #expect(colorBeforeScrolledHighlight?.isEqual(stringColor) != true,
                "Ein unsichtbarer JSON-Bereich wurde vorab vollständig eingefärbt")
        #expect(colorAfterScrolledHighlight?.isEqual(stringColor) == true,
                "Der neu sichtbare JSON-Ausschnitt wurde nicht eingefärbt")
    }
}
