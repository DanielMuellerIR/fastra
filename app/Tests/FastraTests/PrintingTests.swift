// PrintingTests.swift
//
// Prüfungen der reinen Druck-Logik aus `PrintSetup.swift`: Welche Fassung
// eines Dokuments lässt sich drucken, was nimmt ⌘P, wie sehen Kopf- und
// Fußzeile aus, wie breit ist die Zeilennummernspalte, und wie sieht ein
// Hex-Abzug als Text aus. Den ganzen Druckweg bis zum fertigen PDF beweist
// zusätzlich der `print`-Selbsttest.

import AppKit
import Foundation
import Testing
@testable import Fastra

// MARK: - Was ist druckbar

private func textDocument(viewMode: EditorViewMode = .text,
                          isMarkdown: Bool = false,
                          integratedPreviewVisible: Bool = false)
    -> PrintableDocument {
    PrintableDocument(
        fileExtension: isMarkdown ? "md" : "txt",
        hasURL: true,
        isMarkdown: isMarkdown,
        hasEditorText: true,
        viewMode: viewMode,
        integratedPreviewVisible: integratedPreviewVisible
    )
}

@Suite("Druckvorlagen eines Tabs")
struct PrintRoutingTests {

    @Test("Eine Textdatei druckt ihren Quelltext")
    func plainText() {
        let document = textDocument()
        #expect(PrintRouting.availableTargets(document) == [.source])
        #expect(PrintRouting.defaultTarget(document) == .source)
    }

    @Test("Markdown bietet beide Fassungen an; sichtbare Vorschau gewinnt bei ⌘P")
    func markdownChoice() {
        let hidden = textDocument(isMarkdown: true, integratedPreviewVisible: false)
        #expect(PrintRouting.availableTargets(hidden) == [.source, .markdownPreview])
        #expect(PrintRouting.defaultTarget(hidden) == .source)

        let visible = textDocument(isMarkdown: true, integratedPreviewVisible: true)
        #expect(PrintRouting.availableTargets(visible) == [.source, .markdownPreview])
        #expect(PrintRouting.defaultTarget(visible) == .markdownPreview)
    }

    @Test("Die Hex-Ansicht druckt den sichtbaren Abzug")
    func hexView() {
        let document = PrintableDocument(
            fileExtension: "bin", hasURL: true, isMarkdown: false,
            hasEditorText: false, viewMode: .hex
        )
        #expect(PrintRouting.availableTargets(document) == [.hexDump])
        #expect(PrintRouting.defaultTarget(document) == .hexDump)
    }

    @Test("Bild und PDF sind in der Vorschau druckbar")
    func previewModes() {
        let image = PrintableDocument(
            fileExtension: "png", hasURL: true, isMarkdown: false,
            hasEditorText: false, viewMode: .preview
        )
        #expect(PrintRouting.defaultTarget(image) == .image)

        let pdf = PrintableDocument(
            fileExtension: "pdf", hasURL: true, isMarkdown: false,
            hasEditorText: false, viewMode: .preview
        )
        #expect(PrintRouting.defaultTarget(pdf) == .pdf)

        // SVG ist Text mit gerenderter Vorschau: In der Textansicht der
        // Quelltext, in der Vorschau das Bild.
        let svgSource = PrintableDocument(
            fileExtension: "svg", hasURL: true, isMarkdown: false,
            hasEditorText: true, viewMode: .text
        )
        #expect(PrintRouting.defaultTarget(svgSource) == .source)
        let svgPreview = PrintableDocument(
            fileExtension: "svg", hasURL: true, isMarkdown: false,
            hasEditorText: true, viewMode: .preview
        )
        #expect(PrintRouting.defaultTarget(svgPreview) == .image)
    }

    @Test("Eine große Datei druckt ihren sichtbaren Abschnitt")
    func pagedText() {
        // Kennzeichen einer abschnittsweise geladenen Datei: kein Editor-Text.
        let document = PrintableDocument(
            fileExtension: "log", hasURL: true, isMarkdown: false,
            hasEditorText: false, viewMode: .text, showsPagedText: true
        )
        #expect(PrintRouting.availableTargets(document) == [.source])
        #expect(PrintRouting.defaultTarget(document) == .source)
    }

    @Test("Ein Side-by-side-Vergleich hat keine druckbare Fassung")
    func structuredDiff() {
        let document = PrintableDocument(
            fileExtension: "swift", hasURL: false, isMarkdown: false,
            hasEditorText: true, viewMode: .text, isStructuredDiff: true
        )
        #expect(PrintRouting.availableTargets(document).isEmpty)
        #expect(PrintRouting.defaultTarget(document) == nil)
    }

    @Test("Ein leerer unbenannter Tab ist nicht druckbar")
    func emptyScratchTab() {
        let document = PrintableDocument(
            fileExtension: "", hasURL: false, isMarkdown: false,
            hasEditorText: false, viewMode: .text
        )
        #expect(PrintRouting.defaultTarget(document) == nil)
    }
}

// MARK: - Kopf- und Fußzeile

@Suite("Beschriftung der Seitenränder")
struct PrintDecorationTests {

    @Test("Ein sichtbarer Abschnitt steht in der Kopfzeile")
    func sectionNote() {
        let page = VisiblePrintPage(
            url: URL(fileURLWithPath: "/tmp/gross.log"),
            pageIndex: 1, pageCount: 12, text: "Inhalt"
        )
        let header = PrintDecoration.headerLeft(title: "gross.log", section: page)
        #expect(header.contains("gross.log"))
        // Menschen zählen ab eins.
        #expect(header.contains("2"))
        #expect(header.contains("12"))
    }

    @Test("Eine einzige Seite braucht keine Abschnittsangabe")
    func singleSection() {
        let page = VisiblePrintPage(
            url: URL(fileURLWithPath: "/tmp/klein.txt"),
            pageIndex: 0, pageCount: 1, text: "Inhalt"
        )
        #expect(PrintDecoration.headerLeft(title: "klein.txt", section: page)
                == "klein.txt")
        #expect(PrintDecoration.headerLeft(title: "klein.txt", section: nil)
                == "klein.txt")
    }

    @Test("Ein ungesicherter Tab behauptet keinen Dateipfad")
    func footerWithoutPath() {
        #expect(PrintDecoration.footerLeft(path: nil) == "")
        #expect(PrintDecoration.footerLeft(path: "/tmp/a.txt") == "/tmp/a.txt")
    }

    @Test("Die Seitenzahl nennt die Gesamtzahl nur, wenn sie bekannt ist")
    func pageNumbers() {
        let withTotal = PrintDecoration.footerRight(page: 2, of: 7)
        #expect(withTotal.contains("2"))
        #expect(withTotal.contains("7"))
        let withoutTotal = PrintDecoration.footerRight(page: 2, of: nil)
        #expect(withoutTotal.contains("2"))
        #expect(!withoutTotal.contains("7"))
        // Eine Gesamtzahl von 0 ist keine Angabe, sondern „unbekannt".
        #expect(PrintDecoration.footerRight(page: 1, of: 0)
                == PrintDecoration.footerRight(page: 1, of: nil))
    }
}

// MARK: - Zeilennummern

@Suite("Zeilennummern im Ausdruck")
struct PrintLineNumberTests {

    @Test("Die Spaltenbreite folgt der größten Zeilennummer")
    func digits() {
        #expect(PrintLineNumbers.digits(forLineCount: 1) == 3)
        #expect(PrintLineNumbers.digits(forLineCount: 999) == 3)
        #expect(PrintLineNumbers.digits(forLineCount: 1000) == 4)
        #expect(PrintLineNumbers.digits(forLineCount: 123456) == 6)
    }

    @Test("Nummern stehen rechtsbündig mit festem Abstand")
    func prefixes() {
        let first = PrintLineNumbers.prefix(line: 7, digits: 3)
        let later = PrintLineNumbers.prefix(line: 123, digits: 3)
        #expect(first == "  7" + String(repeating: " ", count: PrintLineNumbers.gap))
        #expect(later == "123" + String(repeating: " ", count: PrintLineNumbers.gap))
        #expect(first.count == later.count)
    }

    @Test("Ein abschließendes Zeilenende erzeugt keine leere Nummernzeile")
    func trailingNewline() {
        #expect(PrintLineNumbers.lines(of: "a\nb\n") == ["a", "b"])
        #expect(PrintLineNumbers.lines(of: "a\nb") == ["a", "b"])
        // Windows- und alte Mac-Zeilenenden zählen genauso.
        #expect(PrintLineNumbers.lines(of: "a\r\nb\r\n") == ["a", "b"])
        #expect(PrintLineNumbers.lines(of: "a\rb") == ["a", "b"])
        #expect(PrintLineNumbers.lines(of: "") == [""])
        // Eine bewusst leere Zeile in der Mitte bleibt erhalten.
        #expect(PrintLineNumbers.lines(of: "a\n\nb\n") == ["a", "", "b"])
    }
}

// MARK: - Hex-Abzug

@Suite("Hex-Abzug als Text")
struct HexDumpTests {

    @Test("Eine Zeile trägt Adresse, Bytes und ASCII-Spalte")
    func singleLine() {
        let line = HexDump.line(bytes: [0x41, 0x00, 0x7F], address: 0x10)
        #expect(line.hasPrefix("000000000010"))
        #expect(line.contains("41 00 7F"))
        // Nicht druckbare Bytes werden zum Punkt, druckbare bleiben lesbar.
        #expect(line.hasSuffix("|A..|"))
    }

    @Test("Die gemeldete Zeilenbreite stimmt mit der echten Zeile überein")
    func lineWidth() {
        let full = HexDump.line(bytes: Array(repeating: 0x41,
                                             count: HexDump.bytesPerRow),
                                address: 0)
        #expect(full.count == HexDump.lineWidthInCharacters)
    }

    @Test("Ein Abschnitt wird zeilenweise abgebildet, die letzte Zeile darf kurz sein")
    func pageDump() {
        let data = Data((0..<20).map { UInt8($0) })
        let rows = HexDump.text(data: data, baseOffset: 0x100)
            .components(separatedBy: "\n")
        #expect(rows.count == 2)
        #expect(rows[0].hasPrefix("000000000100"))
        #expect(rows[1].hasPrefix("000000000110"))
        #expect(HexDump.text(data: Data(), baseOffset: 0) == "")
    }
}

// MARK: - Schrift an die Seitenbreite anpassen

@Suite("Feste Zeilenbreite auf der Seite")
struct PrintTextFitTests {

    @Test("Passt die Zeile, bleibt die gewünschte Größe unverändert")
    func noShrinkNeeded() {
        let size = PrintTextFit.fittedFontSize(
            desired: 10, characterWidthAtDesired: 6, columns: 60,
            availableWidth: 400
        )
        #expect(size == 10)
    }

    @Test("Eine zu breite Zeile verkleinert die Schrift genau so weit wie nötig")
    func shrinks() {
        // 81 Zeichen à 6 pt = 486 pt, verfügbar sind 400 pt.
        let size = PrintTextFit.fittedFontSize(
            desired: 10, characterWidthAtDesired: 6, columns: 81,
            availableWidth: 400
        )
        #expect(size < 10)
        #expect(size >= 8.2 && size <= 8.3)
        // Und die verkleinerte Zeile passt dann wirklich.
        #expect(size * 0.6 * 81 <= 400)
    }

    @Test("Unter die Mindestgröße geht es nicht")
    func minimum() {
        let size = PrintTextFit.fittedFontSize(
            desired: 10, characterWidthAtDesired: 6, columns: 5000,
            availableWidth: 400, minimum: 5
        )
        #expect(size == 5)
    }

    @Test("Unsinnige Werte lassen die gewünschte Größe unverändert")
    func guardsAgainstZero() {
        #expect(PrintTextFit.fittedFontSize(
            desired: 10, characterWidthAtDesired: 0, columns: 81,
            availableWidth: 400) == 10)
        #expect(PrintTextFit.fittedFontSize(
            desired: 10, characterWidthAtDesired: 6, columns: 0,
            availableWidth: 400) == 10)
        #expect(PrintTextFit.fittedFontSize(
            desired: 10, characterWidthAtDesired: 6, columns: 81,
            availableWidth: 0) == 10)
    }
}

// MARK: - Sehr großer Ausdruck

@Suite("Umfang eines Ausdrucks")
struct PrintVolumeTests {

    @Test("Nur ein wirklich großer Text löst die Rückfrage aus")
    func threshold() {
        #expect(!PrintVolume.needsConfirmation(byteCount: 0))
        #expect(!PrintVolume.needsConfirmation(
            byteCount: PrintVolume.confirmationThresholdBytes))
        #expect(PrintVolume.needsConfirmation(
            byteCount: PrintVolume.confirmationThresholdBytes + 1))
    }

    @Test("Die Schätzung zählt umgebrochene Zeilen mit")
    func estimate() {
        // 100 kurze Zeilen, 50 pro Seite → zwei Seiten.
        let short = Array(repeating: "kurz", count: 100)
        #expect(PrintVolume.estimatedPageCount(lines: short, columnsPerLine: 80,
                                               linesPerPage: 50) == 2)
        // Eine Zeile mit 240 Zeichen belegt bei 80 Spalten drei Druckzeilen.
        let long = Array(repeating: String(repeating: "x", count: 240), count: 50)
        #expect(PrintVolume.estimatedPageCount(lines: long, columnsPerLine: 80,
                                               linesPerPage: 50) == 3)
        // Eine leere Zeile ist trotzdem eine Zeile.
        #expect(PrintVolume.estimatedPageCount(lines: ["", "", ""],
                                               columnsPerLine: 80,
                                               linesPerPage: 2) == 2)
    }

    @Test("Unsinnige Maße ergeben eine Seite statt einer Division durch null")
    func degenerate() {
        #expect(PrintVolume.estimatedPageCount(lines: ["a"], columnsPerLine: 0,
                                               linesPerPage: 50) == 1)
        #expect(PrintVolume.estimatedPageCount(lines: ["a"], columnsPerLine: 80,
                                               linesPerPage: 0) == 1)
        #expect(PrintVolume.estimatedPageCount(lines: [], columnsPerLine: 80,
                                               linesPerPage: 50) == 1)
    }
}

// MARK: - Einstellungen

@Suite("Druckeinstellungen")
struct PrintPreferencesTests {

    @Test("Ohne gespeicherten Wert gelten die Voreinstellungen")
    func defaultsWhenUnset() {
        let suite = "fastra-print-tests-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        // Der entscheidende Fall: `bool(forKey:)` liefert für einen nie
        // gesetzten Schlüssel `false`. Eine Voreinstellung, die AN ist, wäre
        // damit versehentlich AUS.
        #expect(PrintPreferences.showsLineNumbers(defaults))
        #expect(PrintPreferences.showsHeaderFooter(defaults))
        #expect(PrintPreferences.fontSize(defaults) == PrintPreferences.defaultFontSize)
    }

    @Test("Gespeicherte Werte gelten, unsinnige Größen werden geklemmt")
    func storedValues() {
        let suite = "fastra-print-tests-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: PrintPreferences.Keys.lineNumbers)
        defaults.set(false, forKey: PrintPreferences.Keys.headerFooter)
        #expect(!PrintPreferences.showsLineNumbers(defaults))
        #expect(!PrintPreferences.showsHeaderFooter(defaults))

        defaults.set(400.0, forKey: PrintPreferences.Keys.fontSize)
        #expect(PrintPreferences.fontSize(defaults)
                == PrintPreferences.fontSizeRange.upperBound)
        defaults.set(1.0, forKey: PrintPreferences.Keys.fontSize)
        #expect(PrintPreferences.fontSize(defaults)
                == PrintPreferences.fontSizeRange.lowerBound)
        // Ein Nullwert ist keine Größe, sondern ein Fehler in den Daten.
        defaults.set(0.0, forKey: PrintPreferences.Keys.fontSize)
        #expect(PrintPreferences.fontSize(defaults) == PrintPreferences.defaultFontSize)
        defaults.set(12.0, forKey: PrintPreferences.Keys.fontSize)
        #expect(PrintPreferences.fontSize(defaults) == 12)
    }
}

// MARK: - Bild auf der Seite

@Suite("Bild auf eine Seite einpassen")
struct PrintImageLayoutTests {

    @Test("Das Seitenverhältnis bleibt erhalten, das Bild sitzt in der Mitte")
    func aspectAndCentering() {
        let page = NSSize(width: 400, height: 800)
        let rect = PrintImageLayout.fit(imageSize: NSSize(width: 200, height: 100),
                                        in: page)
        #expect(rect.width == 400)
        #expect(rect.height == 200)
        #expect(rect.minX == 0)
        #expect(rect.midY == 400)
    }

    @Test("Ein hohes Bild wird an der Seitenhöhe begrenzt")
    func tallImage() {
        let rect = PrintImageLayout.fit(imageSize: NSSize(width: 100, height: 400),
                                        in: NSSize(width: 400, height: 800))
        #expect(rect.height == 800)
        #expect(rect.width == 200)
        #expect(rect.midX == 200)
    }

    @Test("Ein leeres Bild füllt die Seite, statt zu rechnen")
    func degenerate() {
        let page = NSSize(width: 300, height: 500)
        #expect(PrintImageLayout.fit(imageSize: .zero, in: page)
                == NSRect(origin: .zero, size: page))
    }
}

// MARK: - Druckfassung der Markdown-Vorschau

@Suite("Markdown-Vorschau als Druckfassung")
struct MarkdownPrintDocumentTests {

    @Test("Der Ausdruck bekommt eigene Seitenregeln, die Vorschau nicht")
    func printStyleOnlyForPrinting() {
        let fragment = MarkdownRenderedFragment(html: "<p>Text</p>", imageURLs: [:])
        let preview = MarkdownRichText.htmlDocument(
            fragment: fragment, fontName: PreviewFonts.systemName,
            fontSize: 14, darkMode: false
        )
        let printed = MarkdownRichText.htmlDocument(
            fragment: fragment, fontName: PreviewFonts.systemName,
            fontSize: 11, darkMode: false, purpose: .print
        )
        // Codeblöcke und Tabellen dürfen an der Seitengrenze nicht
        // auseinanderfallen.
        #expect(printed.contains("break-inside: avoid"))
        #expect(!preview.contains("break-inside: avoid"))
        // Der Papierrand kommt aus den Druckeinstellungen, nicht aus dem
        // Innenabstand des Dokuments.
        #expect(printed.contains("body { padding: 0; }"))
        // Der Inhalt selbst ist in beiden Fassungen derselbe.
        #expect(preview.contains("<p>Text</p>"))
        #expect(printed.contains("<p>Text</p>"))
    }

    @Test("Der Ausdruck wartet auf die fertige Darstellung")
    func readinessMarker() {
        let document = MarkdownRichText.htmlDocument(
            markdown: "# Titel", fontName: PreviewFonts.systemName,
            fontSize: 11, darkMode: false, purpose: .print
        )
        // Formeln, Diagramme und Code-Einfärbung entstehen erst im Dokument.
        // Ohne diese Markierung wüsste der Druckauftrag nicht, wann sie fertig
        // sind, und würde ein halbfertiges Dokument drucken.
        #expect(document.contains("data-fastra-enhanced"))
    }
}

// MARK: - Seitenaufteilung des Textdrucks

@Suite("Seitenrechtecke des Textdrucks")
struct PrintPageRectTests {

    /// Baut die Druck-Textansicht so, wie `makeTextPrintOperation` es tut —
    /// nur ohne UserDefaults und Kopfzeilen, denn hier zählt allein die
    /// Seitenaufteilung.
    @MainActor
    private func makeView(lineCount: Int, pageHeight: CGFloat)
        -> (PrintDocumentTextView, NSLayoutManager, NSTextContainer) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let text = (1...lineCount).map { "Zeile \($0)" }.joined(separator: "\n")
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let container = NSTextContainer(
            size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let pageSize = NSSize(width: 300, height: pageHeight)
        let view = PrintDocumentTextView(
            frame: NSRect(origin: .zero, size: pageSize),
            textContainer: container
        )
        view.pageContentSize = pageSize
        return (view, layoutManager, container)
    }

    @MainActor
    @Test("Seitenrechtecke überlappen nie — die Grenzzeile gehört ganz der Folgeseite")
    func pageRectsDoNotOverlap() {
        // Seitenhöhe absichtlich KEIN Vielfaches der Zeilenhöhe: Genau dann
        // schneidet eine Zeile die Seitengrenze. Mit den früheren
        // Voll-Höhen-Seiten wurde diese Grenzzeile unten angeschnitten
        // gezeichnet UND auf der Folgeseite wiederholt (Reviewfund 2026-08-18).
        let (view, layoutManager, container) = makeView(lineCount: 120,
                                                        pageHeight: 100)
        var range = NSRange(location: 0, length: 0)
        #expect(view.knowsPageRange(&range))
        #expect(range.length > 1)
        for page in 2...range.length {
            let previous = view.rectForPage(page - 1)
            let current = view.rectForPage(page)
            #expect(current.minY >= previous.maxY - 0.01,
                    "Seite \(page) beginnt vor dem Ende von Seite \(page - 1)")
        }
        // Und nichts geht verloren: Die letzte Seite reicht bis unter die
        // letzte Zeile.
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        #expect(view.rectForPage(range.length).maxY >= used.maxY - 0.01)
        #expect(view.rectForPage(1).minY == 0)
    }
}

// MARK: - Druckränder je Ziel

@Suite("Dekorationsrand je Druckziel")
struct PrintDecorationSpaceTests {

    @Test("Nur Text, Hex und Bild zeichnen Kopf-/Fußzeile")
    func decorationTargets() {
        #expect(PrintTarget.source.drawsDecoration)
        #expect(PrintTarget.hexDump.drawsDecoration)
        #expect(PrintTarget.image.drawsDecoration)
        #expect(!PrintTarget.markdownPreview.drawsDecoration)
        #expect(!PrintTarget.pdf.drawsDecoration)
    }

    @MainActor
    @Test("Der Dekorationsrand wird nur für dekorierte Ziele reserviert")
    func decorationSpaceOnlyWhenDecorated() {
        // Frische Suite: Kopf-/Fußzeile steht dort auf ihrer Voreinstellung AN.
        let suiteName = "fastra-test-print-margins-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let decorated = DocumentPrinting.makePrintInfo(
            defaults: defaults, savingTo: nil, decorated: true
        )
        let plain = DocumentPrinting.makePrintInfo(
            defaults: defaults, savingTo: nil, decorated: false
        )
        // Markdown und PDF zeichnen keine Kopf-/Fußzeile — bei ihnen darf der
        // reservierte Rand die Druckfläche nicht verkleinern.
        #expect(decorated.topMargin == plain.topMargin + 24)
        #expect(decorated.bottomMargin == plain.bottomMargin + 24)
        // Abgeschaltete Kopf-/Fußzeile reserviert auch bei dekorierten
        // Zielen nichts.
        defaults.set(false, forKey: PrintPreferences.Keys.headerFooter)
        let switchedOff = DocumentPrinting.makePrintInfo(
            defaults: defaults, savingTo: nil, decorated: true
        )
        #expect(switchedOff.topMargin == plain.topMargin)
    }
}
