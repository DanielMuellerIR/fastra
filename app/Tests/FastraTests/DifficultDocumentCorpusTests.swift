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
    @Test("Mehrzeiliger Soft-Wrap-Gutter scrollt mit dem Dokument")
    @MainActor
    func wrappedMultilineGutterStaysSynchronized() throws {
        let longTail = String(repeating: "Wortgruppe ", count: 32)
        let content = (1...2_400).map {
            "Synchronzeile \($0)\t\(longTail)Ende \($0)"
        }.joined(separator: "\n")
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.frame = window.contentView?.bounds ?? .zero
        controller.view.layoutSubtreeIfNeeded()

        let textView = try #require(controller.textView)
        let scrollView = try #require(controller.scrollView)
        let gutter = try #require(
            descendants(of: controller.view).compactMap { $0 as? GutterView }.first
        )
        textView.layoutManager.layoutLines()
        textView.updateFrameIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        func verifyPosition(_ y: CGFloat, label: String) throws {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            textView.updatedViewport(scrollView.documentVisibleRect)
            controller.view.layoutSubtreeIfNeeded()

            let textRect = textView.visibleRect
            let textLine = textView.layoutManager.textLineForPosition(textRect.minY)?.index
            let gutterLine = gutter.visibleLineIndicesForDrawing.first
            #expect(
                textLine == gutterLine,
                "\(label): Text zeigt Zeile \(textLine.map { $0 + 1 } ?? -1), Gutter zeichnet ab Zeile \(gutterLine.map { $0 + 1 } ?? -1); Text-y=\(Int(textRect.minY)), Gutter-y=\(Int(gutter.visibleRect.minY))"
            )

            // Echtes Zeichnen anstoßen: cacheDisplay durchläuft draw(_:) und
            // damit die Zeilenauswahl UND die Y-Umrechnung wirklich. Der Hook
            // oben ist nur eine Vorberechnung derselben Auswahl und würde
            // eine falsche Zeichenposition nicht bemerken.
            let gutterVisible = gutter.visibleRect
            let cache = try #require(
                gutter.bitmapImageRepForCachingDisplay(in: gutterVisible)
            )
            gutter.cacheDisplay(in: gutterVisible, to: cache)
            let drawn = gutter.lastDrawnLineNumbers
            #expect(
                drawn.map(\.index) == gutter.visibleLineIndicesForDrawing,
                "\(label): Gezeichnete Zeilen \(drawn.map { $0.index + 1 }) weichen von der sichtbaren Auswahl ab"
            )
            #expect(drawn.first?.index == textLine,
                    "\(label): Die erste gezeichnete Nummer gehört nicht zur ersten sichtbaren Textzeile")

            // Die Y-Positionen der Nummern müssen aufsteigend im lokal
            // sichtbaren Gutter-Ausschnitt liegen — vor dem Patch lagen sie
            // in Textkoordinaten und liefen dem gespiegelten Ausschnitt
            // entgegen. Toleranz: eine Zeilenhöhe, weil die Randzeilen oben
            // und unten angeschnitten sein dürfen.
            let yPositions = drawn.map(\.yPosition)
            let lineHeightTolerance = yPositions.count > 1
                ? max(24, yPositions[1] - yPositions[0])
                : 24
            #expect(yPositions == yPositions.sorted(),
                    "\(label): Zeilennummern-Y läuft nicht aufsteigend: \(yPositions.map(Int.init))")
            #expect(
                yPositions.allSatisfy {
                    $0 >= gutterVisible.minY - lineHeightTolerance
                        && $0 <= gutterVisible.maxY + lineHeightTolerance
                },
                "\(label): Nummern außerhalb des sichtbaren Gutter-Ausschnitts \(Int(gutterVisible.minY))–\(Int(gutterVisible.maxY)): \(yPositions.map(Int.init))"
            )
            let expectedFirstY = gutter.convert(
                NSPoint(x: 0, y: textRect.minY), from: textView
            ).y
            let firstY = try #require(yPositions.first)
            #expect(
                abs(firstY - expectedFirstY) <= lineHeightTolerance,
                "\(label): Erste Nummer bei y=\(Int(firstY)) statt nahe \(Int(expectedFirstY))"
            )

            // Klick- und Hover-Ziele der Faltleiste nutzen dieselbe
            // Umrechnung: Ein Punkt oben im lokal sichtbaren
            // Leistenausschnitt muss auf die erste sichtbare Textzeile
            // zeigen — vor dem Patch traf er die gespiegelte Gegenzeile.
            let ribbonVisible = gutter.foldRibbonVisibleRect
            #expect(!ribbonVisible.isEmpty,
                    "\(label): Faltleiste hat keinen sichtbaren Ausschnitt")
            let probe = NSPoint(
                x: ribbonVisible.midX,
                y: ribbonVisible.minY + 1
            )
            let converted = try #require(
                gutter.foldRibbonTextPoint(forRibbonLocalPoint: probe)
            )
            // Ein Punkt im lokal sichtbaren Leistenausschnitt muss in das
            // sichtbare Textband umgerechnet werden — vor dem Patch landete
            // die unumgerechnete lokale Koordinate im gespiegelten,
            // unsichtbaren Gegenstück des Dokuments.
            #expect(
                converted.y >= textRect.minY - lineHeightTolerance
                    && converted.y <= textRect.maxY + lineHeightTolerance,
                "\(label): Faltleisten-Klickziel y=\(Int(converted.y)) liegt außerhalb des sichtbaren Textbandes \(Int(textRect.minY))–\(Int(textRect.maxY)); Leistenausschnitt \(Int(ribbonVisible.minY))–\(Int(ribbonVisible.maxY))"
            )
        }

        try verifyPosition(0, label: "oben")
        let bottomY = max(
            textView.frame.height - scrollView.documentVisibleRect.height,
            0
        )
        #expect(bottomY > scrollView.documentVisibleRect.height,
                "Fixture wurde nicht vertikal scrollbar")
        try verifyPosition(bottomY, label: "unten")
    }

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
            var configuration = SourceEditorConfiguration(
                appearance: .init(
                    theme: EditorView.fastraTheme,
                    font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                    wrapLines: false,
                    tabWidth: 4
                ),
                peripherals: .init(showMinimap: false)
            )
            let clock = ContinuousClock()
            let start = clock.now
            let controller = TextViewController(
                string: content,
                language: .default,
                configuration: configuration,
                cursorPositions: []
            )
            controller.loadView()
            controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            controller.view.layoutSubtreeIfNeeded()
            let textView = try #require(controller.textView)
            let scrollView = try #require(controller.scrollView)
            #expect(!textView.textStorage.fixesAttributesLazily,
                    "\(fixture.label): interner Speicher repariert vollständige Attribute erneut")
            #expect(scrollView.hasHorizontalScroller,
                    "\(fixture.label): Gegenwert ohne Soft Wrap fehlt")

            // Über denselben produktiven Konfigurationspfad umschalten, den
            // Fastras formatabhängiges Soft-Wrap-Profil beim Reconcile nutzt.
            configuration.appearance.wrapLines = true
            controller.configuration = configuration
            controller.view.layoutSubtreeIfNeeded()
            textView.layoutManager.layoutLines()
            textView.updateFrameIfNeeded()
            textView.layoutManager.layoutLines()
            let duration = start.duration(to: clock.now)

            let fragmentViews = textView.subviews
                .compactMap { $0 as? LineFragmentView }.count
            let layoutFragmentCount = Array(textView.layoutManager.lineStorage)
                .reduce(0) { $0 + $1.data.lineFragments.count }
            let visibleLength = textView.visibleTextRanges
                .reduce(0) { $0 + $1.length }
            #expect(layoutFragmentCount > 1,
                    "\(fixture.label): die Megazeile wurde nicht sichtbar umbrochen")
            #expect(!scrollView.hasHorizontalScroller,
                    "\(fixture.label): trotz Soft Wrap ist horizontales Scrollen aktiv")
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
        // Die serialisierte Suite zerstört unmittelbar zuvor einen anderen
        // 4,36-MB-Editor. Dessen AppKit-Aufräumen gehört nicht zur Messung des
        // folgenden Sprachwechsels. Ein Main-Queue-Turn schafft eine klare
        // Messgrenze; ab dem Editoraufbau zählt wieder jede Verzögerung.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

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

@MainActor
private func descendants(of root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + descendants(of: $0) }
}
