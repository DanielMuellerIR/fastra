// PrintSyntaxHighlightingTests.swift
//
// Syntaxfarben im Quelltext-Ausdruck (Folgeauftrag 2026-09-05): der helle
// Druck-Farbsatz ist unabhängig vom Bildschirm-Thema, die Farbbereiche
// landen hinter der Nummernspalte an der richtigen Stelle (auch bei CRLF
// und über Zeilengrenzen), die Analyse färbt das GANZE Dokument, und ein
// großes Dokument bleibt in messbaren Grenzen.

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import Foundation
import Testing
@testable import Fastra

private func swiftFormat(content: String = "") -> DocumentFormat {
    DocumentFormatResolver.resolve(tab: EditorTab(
        title: "farben.swift", path: "/tmp",
        url: URL(fileURLWithPath: "/tmp/farben.swift"), content: content))
}

private func plainFormat(content: String = "") -> DocumentFormat {
    DocumentFormatResolver.resolve(tab: EditorTab(
        title: "notiz.txt", path: "/tmp",
        url: URL(fileURLWithPath: "/tmp/notiz.txt"), content: content))
}

private func fourDFormat(content: String = "") -> DocumentFormat {
    DocumentFormatResolver.resolve(tab: EditorTab(
        title: "Methode.4dm", path: "/tmp",
        url: URL(fileURLWithPath: "/tmp/Methode.4dm"), content: content))
}

/// Mehrseitiger Swift-Quelltext mit Kommentaren, Schlüsselwörtern, Strings
/// und Zahlen in JEDER Zeile — die Farben müssen bis zur letzten Zeile reichen.
private func swiftSample(lines: Int) -> String {
    (1...lines).map { index in
        "let wert\(index) = \"Text \(index)\" // Kommentar \(index) mit \(index * 2)"
    }.joined(separator: "\n")
}

private func foregroundColors(in text: NSAttributedString) -> Set<NSColor> {
    var colors = Set<NSColor>()
    text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) {
        value, _, _ in
        if let color = value as? NSColor { colors.insert(color) }
    }
    return colors
}

@Suite("Syntaxfarben im Ausdruck")
struct PrintSyntaxHighlightingTests {

    @Test("Der Druck-Farbsatz ist der helle Farbsatz mit schwarzem Grundtext")
    func printThemeIsLightWithBlackText() {
        let theme = PrintSyntaxHighlighting.printTheme(for: swiftFormat())
        #expect(theme.text.color == .black)
        #expect(theme.keywords == EditorView.fastraTheme.keywords)
        #expect(theme.comments == EditorView.fastraTheme.comments)
        #expect(theme.strings != EditorView.fastraThemeDark.strings)
        // 4D bekommt seinen eigenen hellen Farbsatz.
        let fourD = PrintSyntaxHighlighting.printTheme(for: fourDFormat())
        #expect(fourD.keywords == EditorView.fourDTheme.keywords)
        #expect(fourD.keywords != EditorView.fourDThemeDark.keywords)
        #expect(fourD.text.color == .black)
    }

    @Test("Capture-Zuordnung folgt dem Theme")
    func captureMapping() {
        let theme = PrintSyntaxHighlighting.printTheme(for: swiftFormat())
        #expect(PrintSyntaxHighlighting.attribute(for: .keyword, in: theme) == theme.keywords)
        #expect(PrintSyntaxHighlighting.attribute(for: .comment, in: theme) == theme.comments)
        #expect(PrintSyntaxHighlighting.attribute(for: .string, in: theme) == theme.strings)
        #expect(PrintSyntaxHighlighting.attribute(for: .number, in: theme) == theme.numbers)
        #expect(PrintSyntaxHighlighting.attribute(for: nil, in: theme) == theme.text)
    }

    @Test("Farbbereiche landen hinter der Nummernspalte, auch bei CRLF und über Zeilen")
    @MainActor
    func highlightsMapBehindLineNumbers() throws {
        // Zeile 1: `let` (0..<3); Zeile 2: Kommentar über das Zeilenende
        // hinaus bis in Zeile 3 (Blockkommentar).
        let text = "let a = 1\r\n/* Kommentar\r\nEnde */ let b\r\n"
        let normalized = PrintSyntaxHighlighting.normalizedText(text)
        #expect(normalized == "let a = 1\n/* Kommentar\nEnde */ let b")
        let theme = PrintSyntaxHighlighting.printTheme(for: swiftFormat())
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let highlights = [
            HighlightRange(range: NSRange(location: 0, length: 3), capture: .keyword),
            // "/* Kommentar\nEnde */" = 10 + 1 + 7 = 20 Zeichen ab Offset 10.
            HighlightRange(range: NSRange(location: 10, length: 20), capture: .comment),
            HighlightRange(range: NSRange(location: 31, length: 3), capture: .keyword),
        ]
        let printed = DocumentPrinting.attributedText(
            text, font: font, showsLineNumbers: true, highlights: highlights, theme: theme)
        let prefix = PrintLineNumbers.prefix(line: 1, digits: 3).count
        let string = printed.string as NSString
        func color(at offset: Int) -> NSColor? {
            printed.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
        }
        // Zeile 1: Nummer grau, `let` in Schlüsselwortfarbe, Rest schwarz.
        #expect(color(at: 0) == .gray)
        #expect(string.substring(with: NSRange(location: prefix, length: 3)) == "let")
        #expect(color(at: prefix) == theme.keywords.color)
        #expect(color(at: prefix + 4) == .black)
        // Zeile 2 beginnt hinter "let a = 1\n" + zweiter Nummernspalte.
        let line2 = prefix + 10 + prefix
        #expect(string.substring(with: NSRange(location: line2, length: 2)) == "/*")
        #expect(color(at: line2) == theme.comments.color)
        #expect(color(at: prefix + 9) == .black, "Zeilenende bleibt Grundfarbe")
        #expect(color(at: line2 - 1) == .gray, "Nummernspalte bleibt grau")
        // Zeile 3 beginnt hinter "/* Kommentar\n" (13 Zeichen) + Nummernspalte;
        // Kommentarende gefärbt, danach `let` als Schlüsselwort.
        let line3 = line2 + 13 + prefix
        #expect(string.substring(with: NSRange(location: line3, length: 7)) == "Ende */")
        #expect(color(at: line3) == theme.comments.color)
        #expect(color(at: line3 + 6) == theme.comments.color)
        #expect(string.substring(with: NSRange(location: line3 + 8, length: 3)) == "let")
        #expect(color(at: line3 + 8) == theme.keywords.color)
        // Fett/kursiv folgen dem Attribut (Schlüsselwörter fett, Kommentare kursiv).
        let keywordFont = try #require(printed.attribute(.font, at: prefix, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: keywordFont).contains(.boldFontMask))
        let commentFont = try #require(printed.attribute(.font, at: line2, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: commentFont).contains(.italicFontMask))
    }

    @Test("Ein langer Bereich mit vielen inneren Bereichen: innen gewinnt, Laufzeit bleibt linear")
    @MainActor
    func nestedRangesSweep() {
        // Ein Markdown-Codeblock oder Doc-Kommentar: EIN Bereich über alle
        // Zeilen, darin pro Zeile ein kurzer Bereich. Der alte Zwei-Zeiger-
        // Durchlauf blieb am äußeren Bereich hängen und lief pro Zeile über
        // alle inneren — quadratisch.
        let lineCount = 10_000
        let line = "let x = 1"          // 9 Zeichen, `let` = 0..<3
        let text = Array(repeating: line, count: lineCount).joined(separator: "\n")
        let stride = (line as NSString).length + 1
        var highlights = [HighlightRange(range: NSRange(location: 0, length: (text as NSString).length),
                                         capture: .comment)]
        for index in 0..<lineCount {
            highlights.append(HighlightRange(range: NSRange(location: index * stride, length: 3),
                                             capture: .keyword))
        }
        let theme = PrintSyntaxHighlighting.printTheme(for: swiftFormat())
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let started = ProcessInfo.processInfo.systemUptime
        let printed = DocumentPrinting.attributedText(
            text, font: font, showsLineNumbers: false, highlights: highlights, theme: theme)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        func color(at offset: Int) -> NSColor? {
            printed.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
        }
        // Erste, mittlere und letzte Zeile: `let` in Schlüsselwortfarbe, der
        // Rest in Kommentarfarbe (der äußere Bereich gilt bis zum Ende).
        for index in [0, lineCount / 2, lineCount - 1] {
            #expect(color(at: index * stride) == theme.keywords.color, "Zeile \(index + 1): innen gewinnt")
            #expect(color(at: index * stride + 4) == theme.comments.color, "Zeile \(index + 1): außen gilt")
        }
        // Großzügige Schranke: linear liegt das im Millisekundenbereich,
        // quadratisch (50 Mio. Durchläufe) im Sekundenbereich.
        #expect(elapsed < 5, "Einfärben von \(lineCount) verschachtelten Zeilen dauerte \(elapsed) s")
    }

    @Test("Ohne Farbbereiche bleibt der Ausdruck einfarbig wie bisher")
    @MainActor
    func withoutHighlightsStaysMonochrome() {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let printed = DocumentPrinting.attributedText(
            swiftSample(lines: 50), font: font, showsLineNumbers: true)
        #expect(foregroundColors(in: printed) == [.gray, .black])
        let plain = DocumentPrinting.attributedText(
            swiftSample(lines: 50), font: font, showsLineNumbers: false)
        #expect(foregroundColors(in: plain) == [.black])
    }

    @Test("Die Analyse färbt das ganze Dokument, nicht nur den Anfang")
    @MainActor
    func analysisCoversWholeDocument() async throws {
        let text = PrintSyntaxHighlighting.normalizedText(swiftSample(lines: 600))
        var outcome: PrintSyntaxHighlighting.Outcome?
        var completions = 0
        // Frist bewusst weit über der Produktfrist: Im parallelen Gesamtlauf
        // halten fremde Main-Actor-Tests den Main-Thread sekundenlang, und
        // tree-sitter liest seinen Text über die Main-Queue. Eine knappe Frist
        // misst dann Fremdlast statt Verhalten (siehe AGENTS.md, Wanduhr-Frist).
        PrintSyntaxHighlighting.analyze(text: text, format: swiftFormat(content: text),
                                        fourDMethodIndex: .empty, timeout: 120) {
            outcome = $0
            completions += 1
        }
        #expect(await waitUntil(timeout: 60) { outcome != nil })
        guard case .colored(let ranges)? = outcome else {
            Issue.record("Erwartet: Farbbereiche, bekommen: \(String(describing: outcome))")
            return
        }
        let length = (text as NSString).length
        let last = try #require(ranges.map(\.range.upperBound).max())
        #expect(last > length * 9 / 10, "Farben enden bei \(last) von \(length)")
        #expect(ranges.contains { $0.capture == .comment })
        #expect(ranges.contains { $0.capture == .keyword })
        #expect(ranges.contains { $0.capture == .string })
        // Genau eine Rückmeldung — auch nach Ablauf der Frist keine zweite.
        _ = await waitUntil(timeout: 0.2) { false }
        #expect(completions == 1)

        // Der fertige Drucktext trägt echte Tokenfarben bis in die letzte Zeile.
        let theme = PrintSyntaxHighlighting.printTheme(for: swiftFormat())
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let printed = DocumentPrinting.attributedText(
            text, font: font, showsLineNumbers: true, highlights: ranges, theme: theme)
        #expect(foregroundColors(in: printed).count >= 4)
        let tail = printed.attributedSubstring(
            from: NSRange(location: printed.length - 60, length: 60))
        #expect(foregroundColors(in: tail).contains(theme.comments.color))
    }

    @Test("Reiner Text und 4D-Quelltext: kein Farbsatz bzw. der 4D-Tokenizer")
    @MainActor
    func plainAndFourD() async {
        var plainOutcome: PrintSyntaxHighlighting.Outcome?
        PrintSyntaxHighlighting.analyze(text: "nur Text", format: plainFormat(content: "nur Text"),
                                        fourDMethodIndex: .empty) { plainOutcome = $0 }
        #expect(await waitUntil { plainOutcome != nil })
        #expect(plainOutcome == .plain)

        let code = "// Kommentar\nIf (True)\n  $x:=\"Text\"\nEnd if\n"
        var fourDOutcome: PrintSyntaxHighlighting.Outcome?
        PrintSyntaxHighlighting.analyze(text: code, format: fourDFormat(content: code),
                                        fourDMethodIndex: .empty, timeout: 120) { fourDOutcome = $0 }
        #expect(await waitUntil { fourDOutcome != nil })
        guard case .colored(let ranges)? = fourDOutcome else {
            Issue.record("4D: erwartet Farbbereiche, bekommen \(String(describing: fourDOutcome))")
            return
        }
        #expect(ranges.contains { $0.capture == .comment })
        #expect(ranges.contains { $0.capture == .string })
    }

    @Test("Messung: ein großes Dokument bleibt in der Frist und über der Grenze einfarbig")
    @MainActor
    func largeDocumentMeasurement() async {
        // ~1 MB Swift: Zeit der Analyse protokollieren; sie muss binnen der
        // Frist enden, sonst druckt Fastra einfarbig.
        let text = PrintSyntaxHighlighting.normalizedText(swiftSample(lines: 18_000))
        let clock = ContinuousClock()
        let start = clock.now
        var outcome: PrintSyntaxHighlighting.Outcome?
        PrintSyntaxHighlighting.analyze(text: text, format: swiftFormat(content: text),
                                        fourDMethodIndex: .empty, timeout: 120) { outcome = $0 }
        #expect(await waitUntil(timeout: 60) { outcome != nil })
        print("Druckfarben-Messung: \((text as NSString).length) Zeichen → \(String(describing: outcome).prefix(12)) nach \(start.duration(to: clock.now))")
        if case .colored(let ranges)? = outcome {
            #expect(!ranges.isEmpty)
        } else {
            Issue.record("Große Datei wurde nicht eingefärbt: \(String(describing: outcome))")
        }

        // Über der Obergrenze: sofort einfarbig, ohne Analyse.
        let huge = String(repeating: "x", count: PrintSyntaxHighlighting.maximumColoredLength + 1)
        var hugeOutcome: PrintSyntaxHighlighting.Outcome?
        PrintSyntaxHighlighting.analyze(text: huge, format: swiftFormat(),
                                        fourDMethodIndex: .empty) { hugeOutcome = $0 }
        #expect(hugeOutcome == .plain)
    }
}

@Suite("Druckdialog-Option Syntaxfarben")
struct PrintSyntaxColorOptionTests {

    @Test("Voreinstellung an; gespeicherter Wert gilt")
    func preference() {
        let suite = "fastra-test-print-colors-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(PrintPreferences.showsSyntaxColors(defaults))
        defaults.set(false, forKey: PrintPreferences.Keys.syntaxColors)
        #expect(!PrintPreferences.showsSyntaxColors(defaults))
    }

    @Test("Die Checkbox schreibt in Auftrag und Einstellungen; ohne Farben fehlt sie")
    @MainActor
    func accessoryWritesOption() {
        let suite = "fastra-test-print-colors-acc-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let printInfo = NSPrintInfo()
        let accessory = PrintOptionsAccessoryController(
            printInfo: printInfo, defaults: defaults, offersLineNumbers: true,
            offersSyntaxColors: true)
        #expect(accessory.syntaxColorsEnabled)
        accessory.setSyntaxColors(false)
        #expect(PrintDialogOption.value(PrintDialogOption.syntaxColors, in: printInfo) == false)
        #expect(!PrintPreferences.showsSyntaxColors(defaults))
        #expect(accessory.localizedSummaryItems().contains {
            $0[.itemName] == L10n.string("Syntaxfarben drucken")
        })
        #expect(accessory.keyPathsForValuesAffectingPreview().contains("syntaxColorsEnabled"))

        let without = PrintOptionsAccessoryController(
            printInfo: NSPrintInfo(), defaults: defaults, offersLineNumbers: true)
        #expect(!without.localizedSummaryItems().contains {
            $0[.itemName] == L10n.string("Syntaxfarben drucken")
        })
    }

    @Test("Der Druckauftrag trägt Farben nur mit Einstellung UND Farbbereichen")
    @MainActor
    func operationHonoursPreference() {
        let suite = "fastra-test-print-colors-op-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let theme = PrintSyntaxHighlighting.printTheme(for: swiftFormat())
        let highlights = [HighlightRange(range: NSRange(location: 0, length: 3), capture: .keyword)]
        func colors(_ enabled: Bool, highlights: [HighlightRange]) -> Set<NSColor> {
            defaults.set(enabled, forKey: PrintPreferences.Keys.syntaxColors)
            let operation = DocumentPrinting.makeTextPrintOperation(
                text: "let a = 1", printInfo: NSPrintInfo(), defaults: defaults,
                jobTitle: "t", headerLeft: "", footerLeft: "",
                highlights: highlights, theme: theme)
            let view = operation.view as? PrintDocumentTextView
            return foregroundColors(in: view?.textStorage ?? NSAttributedString())
        }
        #expect(colors(true, highlights: highlights).contains(theme.keywords.color))
        #expect(!colors(false, highlights: highlights).contains(theme.keywords.color))
        #expect(!colors(true, highlights: []).contains(theme.keywords.color))
    }
}
