// PrintSetup.swift
//
// Reine Druck-Logik ohne AppKit: Was lässt sich am aktiven Tab drucken, was
// druckt ⌘P, wie sind Kopf- und Fußzeile beschriftet, wie breit ist die
// Zeilennummernspalte, und wie sieht ein Hex-Abzug als Text aus.
//
// Die Trennung ist dieselbe wie bei `EditorViewMode.swift` gegenüber
// `EditorView.swift`: Die Entscheidungen sind ohne Fenster und ohne Drucker
// prüfbar, die Ausführung (NSPrintOperation, NSTextView, WebKit) liegt in
// `DocumentPrinting.swift`.

import Foundation

// MARK: - Was gedruckt wird

/// Druckvorlage eines Tabs. Ein Tab kann mehrere anbieten: Ein Markdown-
/// Dokument lässt sich als gerenderte Vorschau ODER als Quelltext drucken.
enum PrintTarget: String, CaseIterable, Equatable, Hashable {
    /// Der Text, den der Editor zeigt (auch der sichtbare Abschnitt einer
    /// großen Datei sowie Git-Text-Tabs wie Verlauf oder Diff).
    case source
    /// Die gerenderte Markdown-Vorschau — also das, was rechts steht.
    case markdownPreview
    /// Der sichtbare Abschnitt der Hex-Ansicht.
    case hexDump
    /// Bild- oder SVG-Vorschau, auf eine Seite eingepasst.
    case image
    /// Eine PDF-Datei — Seite für Seite, unverändert.
    case pdf

    /// Zeichnet dieses Ziel eine eigene Kopf-/Fußzeile in den Seitenrand?
    /// Markdown druckt über WebKit und ein PDF druckt PDFKit unverändert —
    /// beide zeichnen keine Dekoration. Der zusätzliche Rand dafür darf dort
    /// also auch nicht reserviert werden: Er verkleinerte sonst wirkungslos
    /// die Druckfläche (Reviewfund 2026-08-18).
    var drawsDecoration: Bool {
        switch self {
        case .source, .hexDump, .image: return true
        case .markdownPreview, .pdf:    return false
        }
    }

    /// Beschriftung für Menü und Fehlermeldungen.
    var title: String {
        switch self {
        case .source:          return L10n.string("Quelltext")
        case .markdownPreview: return L10n.string("Markdown-Vorschau")
        case .hexDump:         return L10n.string("Hex-Abzug")
        case .image:           return L10n.string("Bildvorschau")
        case .pdf:             return L10n.string("PDF-Dokument")
        }
    }
}

/// Beschreibt einen Tab so weit, wie das Drucken ihn kennen muss. Bewusst
/// eine eigene kleine Struktur statt `EditorTab`: Damit lässt sich jede
/// Kombination im Unit-Test durchspielen, auch solche, die per Hand nur
/// schwer herzustellen wäre.
struct PrintableDocument: Equatable {
    /// Endung der Datei, klein geschrieben oder leer.
    let fileExtension: String
    let hasURL: Bool
    let isMarkdown: Bool
    /// Editor-Inhalt vorhanden? Große Dateien (Abschnittsmodus) und erkannte
    /// Binärdateien haben absichtlich keinen — sie werden von der Platte
    /// gelesen, nicht in einen String geladen.
    let hasEditorText: Bool
    /// Ansicht, die der Nutzer gerade sieht (Text/Vorschau/Hex).
    let viewMode: EditorViewMode
    /// Zeigt die Textansicht einen seitenweisen Abschnitt (große Datei)?
    let showsPagedText: Bool
    /// Steht die Markdown-Vorschau gerade neben dem Editor?
    let integratedPreviewVisible: Bool
    /// Side-by-side-Vergleiche (Git-Diff, Dateivergleich) haben keinen
    /// druckbaren Fließtext; ihr Inhalt lebt in zwei Spalten-Modellen.
    let isStructuredDiff: Bool

    init(fileExtension: String,
         hasURL: Bool,
         isMarkdown: Bool,
         hasEditorText: Bool,
         viewMode: EditorViewMode,
         showsPagedText: Bool = false,
         integratedPreviewVisible: Bool = false,
         isStructuredDiff: Bool = false) {
        self.fileExtension = fileExtension.lowercased()
        self.hasURL = hasURL
        self.isMarkdown = isMarkdown
        self.hasEditorText = hasEditorText
        self.viewMode = viewMode
        self.showsPagedText = showsPagedText
        self.integratedPreviewVisible = integratedPreviewVisible
        self.isStructuredDiff = isStructuredDiff
    }
}

/// Entscheidet, was ein Tab zum Drucken anbietet und was ⌘P nimmt.
///
/// Leitregel: **Gedruckt wird, was zu sehen ist.** ⌘P in der Hex-Ansicht
/// druckt den Hex-Abzug, ⌘P bei sichtbarer Markdown-Vorschau die Vorschau.
/// Die abweichende Wahl bleibt über eigene Menüpunkte erreichbar — sie ist
/// eine ausdrückliche Entscheidung des Nutzers und keine Überraschung.
enum PrintRouting {

    /// Alle Vorlagen, die dieser Tab drucken kann — in Menü-Reihenfolge.
    static func availableTargets(_ document: PrintableDocument) -> [PrintTarget] {
        var targets: [PrintTarget] = []

        // Fließtext: der Editor-Inhalt oder der sichtbare Abschnitt einer
        // großen Datei. Ein strukturierter Vergleich hat beides nicht.
        if !document.isStructuredDiff,
           document.hasEditorText || (document.showsPagedText && document.viewMode == .text) {
            targets.append(.source)
        }
        if document.isMarkdown, document.hasEditorText, !document.isStructuredDiff {
            targets.append(.markdownPreview)
        }
        // Vorschau und Hex lesen von der Platte. Sie sind deshalb nur
        // druckbar, wenn der Nutzer sie auch wirklich vor sich hat: Sonst
        // müsste Fastra raten, welchen Abschnitt einer 4-GB-Datei es meint.
        if document.hasURL, document.viewMode == .preview {
            targets.append(
                ViewModeRouting.pdfExtensions.contains(document.fileExtension)
                    ? .pdf : .image
            )
        }
        if document.hasURL, document.viewMode == .hex {
            targets.append(.hexDump)
        }
        return targets
    }

    /// Vorlage für „Drucken…" (⌘P). `nil` = an diesem Tab ist nichts zu
    /// drucken; der Menüpunkt bleibt dann sichtbar, aber grau.
    static func defaultTarget(_ document: PrintableDocument) -> PrintTarget? {
        let available = availableTargets(document)
        guard !available.isEmpty else { return nil }
        switch document.viewMode {
        case .hex:
            return available.contains(.hexDump) ? .hexDump : available.first
        case .preview:
            if available.contains(.pdf) { return .pdf }
            if available.contains(.image) { return .image }
            return available.first
        case .text:
            // Markdown mit sichtbarer Vorschau: Der Nutzer sieht die
            // gerenderte Fassung, also ist sie auch gemeint.
            if document.isMarkdown, document.integratedPreviewVisible,
               available.contains(.markdownPreview) {
                return .markdownPreview
            }
            return available.contains(.source) ? .source : available.first
        }
    }
}

// MARK: - Sichtbarer Abschnitt seitenweiser Ansichten

/// Der Abschnitt, den eine seitenweise Ansicht gerade zeigt.
///
/// Hex-Ansicht und große Textdateien laden nie die ganze Datei, sondern
/// immer nur eine Seite. Genau diese Seite ist die Druckvorlage — und sie
/// muss aus der Ansicht kommen, nicht aus einem zweiten Lesevorgang:
/// Andernfalls druckte Fastra einen anderen Abschnitt als den sichtbaren.
struct VisiblePrintPage: Equatable {
    let url: URL
    /// 0-basierter Abschnitt, wie ihn die Ansicht zählt.
    let pageIndex: Int
    let pageCount: Int
    /// Der Text dieses Abschnitts — bei Hex der fertige Abzug.
    let text: String
}

// MARK: - Kopf- und Fußzeile

/// Beschriftung der Seitenrandzeilen. Reine Textzusammensetzung, damit sich
/// die Formulierungen ohne Drucker prüfen lassen.
enum PrintDecoration {

    /// Kopfzeile links: Dokumentname, bei seitenweisen Ansichten mit
    /// Abschnittsangabe. Ohne diese Angabe entstünde ein Ausdruck, der
    /// aussieht wie die ganze Datei, aber nur ein Stück davon ist.
    static func headerLeft(title: String, section: VisiblePrintPage?) -> String {
        guard let section, section.pageCount > 1 else { return title }
        let note = L10n.format("Abschnitt %ld von %ld",
                               section.pageIndex + 1, section.pageCount)
        return "\(title) — \(note)"
    }

    /// Kopfzeile rechts: Druckdatum in der Sprache des Systems.
    static func headerRight(date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Fußzeile links: der Dateipfad, sofern es einen gibt. Ein ungesicherter
    /// Tab hat keinen — dann bleibt die Zeile leer statt „(unbenannt)" zu
    /// behaupten, es gäbe eine Datei.
    static func footerLeft(path: String?) -> String { path ?? "" }

    /// Fußzeile rechts: Seitenzahl. Die Gesamtzahl kennt der Druckvorgang
    /// nicht immer (sie steht erst nach der Seitenaufteilung fest), deshalb
    /// ist sie optional.
    static func footerRight(page: Int, of total: Int?) -> String {
        if let total, total > 0 {
            return L10n.format("Seite %ld von %ld", page, total)
        }
        return L10n.format("Seite %ld", page)
    }
}

// MARK: - Zeilennummern

/// Zeilennummern im Ausdruck. Sie stehen als Text am Zeilenanfang, nicht in
/// einer eigenen Spaltenansicht: So wandern sie bei der Seitenaufteilung
/// zwangsläufig mit ihrer Zeile mit und können nicht verrutschen.
enum PrintLineNumbers {
    /// Abstand zwischen Nummer und Text in Zeichen.
    static let gap = 2

    /// Stellen, die die größte Zeilennummer braucht (mindestens drei, damit
    /// der Textblock bei kurzen Dateien nicht flattert).
    static func digits(forLineCount count: Int) -> Int {
        max(3, String(max(count, 1)).count)
    }

    /// Rechtsbündige Nummer plus Abstand.
    static func prefix(line: Int, digits: Int) -> String {
        let number = String(line)
        let padding = String(repeating: " ", count: max(0, digits - number.count))
        return padding + number + String(repeating: " ", count: gap)
    }

    /// Zeilen eines Textes für den Ausdruck. Ein abschließendes Zeilenende
    /// erzeugt bewusst KEINE zusätzliche leere Nummernzeile.
    static func lines(of text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }
}

// MARK: - Hex-Abzug als Text

/// Eine Hex-Zeile aus Adresse, Bytes und ASCII-Spalte. Dieselbe Formatierung
/// benutzen die Hex-Ansicht auf dem Bildschirm und der Ausdruck — sonst
/// zeigte der Drucker etwas anderes als das Fenster.
enum HexDump {
    static let bytesPerRow = 16

    /// Zeichen einer vollständigen Zeile: 12 Adressstellen, zwei Leerzeichen,
    /// 16 Bytes zu je zwei Stellen mit Trennzeichen, zwei Leerzeichen und die
    /// ASCII-Spalte in senkrechten Strichen. Der Ausdruck braucht diese Zahl,
    /// um die Schrift so zu wählen, dass die Zeile ganz auf die Seite passt.
    static var lineWidthInCharacters: Int {
        12 + 2 + (bytesPerRow * 3 - 1) + 2 + bytesPerRow + 2
    }

    static func line(bytes: [UInt8], address: UInt64) -> String {
        let addressText = String(format: "%012llX", address)
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            .padding(toLength: bytesPerRow * 3 - 1, withPad: " ", startingAt: 0)
        let ascii = String(bytes.map { byte in
            (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "."
        })
        return "\(addressText)  \(hex)  |\(ascii)|"
    }

    /// Vollständiger Abzug eines geladenen Abschnitts.
    static func text(data: Data, baseOffset: UInt64) -> String {
        let bytes = [UInt8](data)
        var rows: [String] = []
        rows.reserveCapacity(bytes.count / bytesPerRow + 1)
        var index = 0
        while index < bytes.count {
            let end = min(index + bytesPerRow, bytes.count)
            rows.append(line(bytes: Array(bytes[index..<end]),
                             address: baseOffset + UInt64(index)))
            index = end
        }
        return rows.joined(separator: "\n")
    }
}

// MARK: - Sehr großer Ausdruck

/// Schätzt den Umfang eines Textausdrucks, BEVOR er entsteht.
///
/// Der Grund liegt in der Seitenaufteilung: Sie muss den vollständigen Text
/// setzen, und das läuft zwingend auf dem Main-Thread — AppKit druckt von dort.
/// Bei einer mehrere Megabyte großen Datei stünde die Oberfläche dabei ohne
/// jede Erklärung still. Fastra fragt deshalb vorher, mit einer Zahl, die sich
/// einschätzen lässt. Abschneiden wäre die schlechtere Antwort: Ein Ausdruck,
/// der stillschweigend nach Seite 50 endet, ist ein Datenverlust.
enum PrintVolume {
    /// Ab dieser Textgröße (UTF-8-Bytes) wird gefragt. Zwei Megabyte sind rund
    /// 30.000 Quelltextzeilen — schon deutlich mehr, als jemand versehentlich
    /// druckt.
    static let confirmationThresholdBytes = 2 * 1024 * 1024

    static func needsConfirmation(byteCount: Int) -> Bool {
        byteCount > confirmationThresholdBytes
    }

    /// Grobe Seitenschätzung: Jede Quellzeile belegt so viele Druckzeilen, wie
    /// ihre Länge bei der gegebenen Spaltenzahl ergibt — mindestens eine.
    /// Die Zahl darf ungenau sein; sie soll eine Größenordnung zeigen.
    static func estimatedPageCount(lines: [String], columnsPerLine: Int,
                                   linesPerPage: Int) -> Int {
        guard columnsPerLine > 0, linesPerPage > 0 else { return 1 }
        let printedLines = lines.reduce(0) { total, line in
            total + max(1, (line.count + columnsPerLine - 1) / columnsPerLine)
        }
        return max(1, (printedLines + linesPerPage - 1) / linesPerPage)
    }
}

// MARK: - Schrift an die Seitenbreite anpassen

/// Rechnet die Schriftgröße für Text mit FESTER Zeilenbreite.
///
/// Nur der Hex-Abzug braucht das: Seine Zeilen sind ein Raster aus Adresse,
/// Bytes und ASCII-Spalte. Bricht eine solche Zeile um, ist das Raster
/// zerstört und der Abzug praktisch unlesbar. Quelltext dagegen wird
/// absichtlich umgebrochen — dort ist die Zeilenlänge beliebig, und
/// Schrumpfen bis zur Unlesbarkeit wäre die schlechtere Wahl.
enum PrintTextFit {
    /// Größe, bei der `columns` Zeichen in `availableWidth` passen — aber
    /// höchstens die gewünschte Größe. Eine Monospace-Schrift skaliert linear:
    /// doppelte Punktgröße heißt doppelte Zeichenbreite.
    static func fittedFontSize(desired: Double,
                               characterWidthAtDesired: Double,
                               columns: Int,
                               availableWidth: Double,
                               minimum: Double = 4) -> Double {
        guard desired > 0, characterWidthAtDesired > 0, columns > 0,
              availableWidth > 0 else { return desired }
        let needed = characterWidthAtDesired * Double(columns)
        guard needed > availableWidth else { return desired }
        let scaled = desired * availableWidth / needed
        return max(minimum, (scaled * 10).rounded(.down) / 10)
    }
}

// MARK: - Einstellungen

/// Druckeinstellungen. Das Einstellungsfenster und das Zubehörfeld des
/// Systemdialogs schreiben dieselben persistenten Werte. Der laufende Auftrag
/// hält seine Dialogwerte zusätzlich im eigenen `NSPrintInfo` fest, damit
/// Seitenvorschau und gespeicherter Ausgangszustand nicht auseinanderlaufen.
enum PrintPreferences {
    enum Keys {
        static let lineNumbers = "print.lineNumbers"
        static let headerFooter = "print.headerFooter"
        static let fontSize = "print.fontSize"
    }

    static let defaultLineNumbers = true
    static let defaultHeaderFooter = true
    static let defaultFontSize = 10.0
    static let fontSizeRange: ClosedRange<Double> = 6...18

    /// Ein nie gesetzter Schlüssel liefert bei `bool(forKey:)` immer `false`.
    /// Für Voreinstellungen, die AN sind, muss deshalb das Fehlen des Werts
    /// geprüft werden — sonst wäre der Standard versehentlich AUS.
    static func showsLineNumbers(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Keys.lineNumbers) == nil
            ? defaultLineNumbers : defaults.bool(forKey: Keys.lineNumbers)
    }

    static func showsHeaderFooter(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Keys.headerFooter) == nil
            ? defaultHeaderFooter : defaults.bool(forKey: Keys.headerFooter)
    }

    /// Schriftgröße des Ausdrucks in Punkt, auf einen sinnvollen Bereich
    /// geklemmt: Unter 6 pt ist Quelltext unlesbar, über 18 pt passt kaum
    /// noch eine Zeile auf die Seite.
    static func fontSize(_ defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: Keys.fontSize) != nil else {
            return defaultFontSize
        }
        let stored = defaults.double(forKey: Keys.fontSize)
        guard stored > 0 else { return defaultFontSize }
        return min(max(stored, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }
}
