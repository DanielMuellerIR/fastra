// MarkdownEditing.swift
//
// Markdown-Formatierungsbefehle auf den QUELLTEXT (Etappe 5 Wunschpaket
// 2026-07b): pure, unit-testbare Textfunktionen. Die Anwendung auf den
// Editor (Undo-fähig über `textView.replaceCharacters`) übernimmt
// `EditorContextMenu.applyMarkdownFormat`; sichtbar sind die Befehle nur
// für Markdown-Tabs (Toolbar, Rechtsklickmenü, Markdown-Menü).

import Foundation

/// Die angebotenen Befehle. Rohwert wandert durch die Notification
/// (`.fastraMarkdownFormat`) — neue Fälle deshalb IMMER hinten anhängen.
enum MarkdownFormatCommand: Int, CaseIterable {
    case bold, italic, code
    case heading1, heading2, heading3, plainParagraph
    case bulletList, orderedList, quote
    case link
    case insertTable
    // Rohwerte wandern durch Notifications und müssen stabil bleiben. Neue
    // Befehle stehen deshalb hinten; `displayOrder` bestimmt separat die UI.
    case highlight
    case hardBreak
}

extension MarkdownFormatCommand {
    /// Sinnvolle Reihenfolge für Toolbar und Kontextmenü, unabhängig von
    /// den stabilen Rohwerten der Notification-Kommandos.
    static let displayOrder: [MarkdownFormatCommand] = [
        .bold, .italic, .highlight, .code, .hardBreak,
        .heading1, .heading2, .heading3, .plainParagraph,
        .bulletList, .orderedList, .quote,
        .link, .insertTable,
    ]

    /// Stabiler Lokalisierungsschlüssel für alle sichtbaren Beschriftungen.
    var menuTitleKey: String {
        switch self {
        case .bold:           "Fett"
        case .italic:         "Kursiv"
        case .code:           "Code"
        case .heading1:       "Überschrift 1"
        case .heading2:       "Überschrift 2"
        case .heading3:       "Überschrift 3"
        case .plainParagraph: "Normaler Text"
        case .bulletList:     "Aufzählung"
        case .orderedList:    "Nummerierte Liste"
        case .quote:          "Zitat"
        case .link:           "Link"
        case .insertTable:    "Tabelle einfügen…"
        case .highlight:      "Hervorheben"
        case .hardBreak:      "Harter Zeilenumbruch"
        }
    }

    /// Beschriftung in Menüleiste, Rechtsklickmenü und Toolbar-Tooltips.
    var menuTitle: String { L10n.string(menuTitleKey) }

    /// Ausführlicher Tooltip für Befehle, deren Wirkung am Symbol allein
    /// nicht erkennbar ist. Die übrigen verwenden ihren Menü-Titel.
    var helpText: String {
        switch self {
        case .hardBreak:
            L10n.string("Fügt zwei Leerzeichen und einen normalen Zeilenumbruch ein.")
        default:
            menuTitle
        }
    }

    /// SF-Symbol für die Markdown-Toolbar.
    var systemImage: String {
        switch self {
        case .bold:           return "bold"
        case .italic:         return "italic"
        case .code:           return "chevron.left.forwardslash.chevron.right"
        case .heading1:       return "1.square"
        case .heading2:       return "2.square"
        case .heading3:       return "3.square"
        case .plainParagraph: return "paragraphsign"
        case .bulletList:     return "list.bullet"
        case .orderedList:    return "list.number"
        case .quote:          return "text.quote"
        case .link:           return "link"
        case .insertTable:    return "tablecells"
        case .highlight:      return "highlighter"
        case .hardBreak:      return "arrow.turn.down.left"
        }
    }
}

enum MarkdownFormat {

    /// Ein Edit als Ersetzung im ALTEN Text plus Ziel-Selektion im NEUEN.
    /// Genau die Form, die `textView.replaceCharacters` + `setSelectedRange`
    /// brauchen — so bleibt jeder Befehl ein normaler Undo-Schritt.
    struct Edit: Equatable {
        let range: NSRange
        let replacement: String
        let selection: NSRange
    }

    /// Gilt der Dateiname als Markdown? (Gleiche Regel wie die integrierte
    /// Vorschau: .md/.markdown, Groß-/Kleinschreibung egal.)
    static func isMarkdownFilename(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
    }

    // MARK: Inline-Auszeichnung (Fett/Kursiv/Textmarker/Code)

    /// Umschaltende Inline-Auszeichnung: Auswahl einpacken bzw. eine schon
    /// vorhandene Auszeichnung wieder entfernen. Ohne Auswahl wird ein
    /// leeres Markerpaar eingefügt und der Cursor mittig platziert.
    static func toggleInline(_ text: String, selection: NSRange,
                             marker: String) -> Edit {
        let ns = text as NSString
        let markerLength = (marker as NSString).length
        let selected = ns.substring(with: selection)

        // Auswahl ENTHÄLT die Marker („**fett**“ markiert) → auspacken.
        if selection.length >= 2 * markerLength,
           selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            return Edit(range: selection, replacement: inner,
                        selection: NSRange(location: selection.location,
                                           length: (inner as NSString).length))
        }
        // Marker liegen direkt UM die Auswahl („fett“ markiert) → entfernen.
        let before = NSRange(location: selection.location - markerLength,
                             length: markerLength)
        let after = NSRange(location: NSMaxRange(selection), length: markerLength)
        if before.location >= 0, NSMaxRange(after) <= ns.length,
           ns.substring(with: before) == marker, ns.substring(with: after) == marker {
            let full = NSRange(location: before.location,
                               length: selection.length + 2 * markerLength)
            return Edit(range: full, replacement: selected,
                        selection: NSRange(location: before.location,
                                           length: selection.length))
        }
        // Einpacken (bzw. leeres Paar bei leerer Auswahl).
        let replacement = marker + selected + marker
        return Edit(range: selection, replacement: replacement,
                    selection: NSRange(location: selection.location + markerLength,
                                       length: selection.length))
    }

    /// Fügt den dokumentierten CommonMark-Hartumbruch als zwei Leerzeichen
    /// plus normales Newline ein. Eine Auswahl bleibt bewusst erhalten: Der
    /// Umbruch landet dahinter, statt versehentlich markierten Text zu löschen.
    static func insertHardBreak(in text: String, after selection: NSRange) -> Edit? {
        let ns = text as NSString
        let target = min(NSMaxRange(selection), ns.length)
        let beforeTarget = NSRange(location: 0, length: target)
        let previousNewline = ns.range(of: "\n", options: .backwards, range: beforeTarget)
        let lineStart = previousNewline.location == NSNotFound
            ? 0
            : NSMaxRange(previousNewline)
        let linePrefix = ns.substring(with: NSRange(location: lineStart,
                                                    length: target - lineStart))
        guard !linePrefix.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }

        // Direkt vor dem Ziel vorhandene normale Leerzeichen kanonisch auf
        // genau zwei bringen. Tabs werden nicht umgedeutet: Sie haben in
        // Markdown eine eigene Einrückungs-/Codeblock-Semantik.
        var existingSpaces = 0
        while target - existingSpaces > lineStart,
              ns.character(at: target - existingSpaces - 1) == 0x20 {
            existingSpaces += 1
        }
        let alreadyBeforeNewline = target < ns.length && ns.character(at: target) == 0x0A
        let replacement = "  " + (alreadyBeforeNewline ? "" : "\n")
        if existingSpaces == 2 && alreadyBeforeNewline { return nil }

        let range = NSRange(location: target - existingSpaces, length: existingSpaces)
        return Edit(
            range: range,
            replacement: replacement,
            selection: NSRange(location: range.location + (replacement as NSString).length,
                               length: 0)
        )
    }

    // MARK: Zeilenbefehle (Überschriften, Listen, Zitat)

    /// Zeilenbereich (ganze Zeilen ohne das abschließende \n) der Auswahl.
    private static func lineRange(of text: String, selection: NSRange) -> NSRange {
        let ns = text as NSString
        var range = ns.lineRange(for: selection)
        // Das abschließende Zeilenende gehört nicht zum bearbeiteten Block —
        // sonst würde jede Ersetzung das \n der letzten Zeile mitschleifen.
        while range.length > 0 {
            let last = ns.character(at: range.location + range.length - 1)
            if last == 0x0A || last == 0x0D { range.length -= 1 } else { break }
        }
        return range
    }

    /// Wendet `transform` auf jede Zeile des Auswahlbereichs an und liefert
    /// den Edit mit selektiertem Ergebnisblock.
    private static func mapLines(_ text: String, selection: NSRange,
                                 transform: (String, Int) -> String) -> Edit {
        let range = lineRange(of: text, selection: selection)
        let block = (text as NSString).substring(with: range)
        let lines = block.components(separatedBy: "\n")
        var visibleIndex = 0
        let mapped = lines.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            visibleIndex += 1
            return transform(line, visibleIndex)
        }
        let replacement = mapped.joined(separator: "\n")
        return Edit(range: range, replacement: replacement,
                    selection: NSRange(location: range.location,
                                       length: (replacement as NSString).length))
    }

    private static let headingPrefix = try! NSRegularExpression(pattern: "^#{1,6}\\s+")
    private static let bulletPrefix = try! NSRegularExpression(pattern: "^[-*+]\\s+")
    private static let orderedPrefix = try! NSRegularExpression(pattern: "^\\d+\\.\\s+")
    private static let quotePrefix = try! NSRegularExpression(pattern: "^>\\s?")

    private static func stripping(_ regex: NSRegularExpression, from line: String) -> String {
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line,
                                           range: NSRange(location: 0, length: ns.length))
        else { return line }
        return ns.substring(from: match.range.length)
    }

    private static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line,
                         range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// Überschrift Ebene 1–3 setzen; `level 0` = zurück zu normalem Text.
    /// Ersetzt eine vorhandene Überschriften-Ebene, statt zu stapeln.
    static func setHeading(_ text: String, selection: NSRange, level: Int) -> Edit {
        mapLines(text, selection: selection) { line, _ in
            let plain = stripping(headingPrefix, from: line)
            guard level > 0 else { return plain }
            return String(repeating: "#", count: level) + " " + plain
        }
    }

    /// Aufzählung umschalten: Sind alle (nicht-leeren) Zeilen bereits
    /// Listenpunkte, wird die Auszeichnung entfernt — sonst gesetzt.
    static func toggleBulletList(_ text: String, selection: NSRange) -> Edit {
        toggleLinePrefix(text, selection: selection, regex: bulletPrefix) { _ in "- " }
    }

    /// Nummerierte Liste umschalten (1., 2., … in Auswahlreihenfolge).
    static func toggleOrderedList(_ text: String, selection: NSRange) -> Edit {
        toggleLinePrefix(text, selection: selection, regex: orderedPrefix) { "\($0). " }
    }

    /// Zitat umschalten („> “).
    static func toggleQuote(_ text: String, selection: NSRange) -> Edit {
        toggleLinePrefix(text, selection: selection, regex: quotePrefix) { _ in "> " }
    }

    private static func toggleLinePrefix(_ text: String, selection: NSRange,
                                         regex: NSRegularExpression,
                                         prefix: (Int) -> String) -> Edit {
        let range = lineRange(of: text, selection: selection)
        let block = (text as NSString).substring(with: range)
        let visible = block.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allPrefixed = !visible.isEmpty && visible.allSatisfy { matches(regex, $0) }
        return mapLines(text, selection: selection) { line, index in
            // Andersartige Listen-/Zitat-Präfixe zuerst räumen, damit die
            // Befehle sich gegenseitig ERSETZEN statt zu stapeln.
            var plain = stripping(bulletPrefix, from: line)
            plain = stripping(orderedPrefix, from: plain)
            plain = stripping(quotePrefix, from: plain)
            return allPrefixed ? plain : prefix(index) + plain
        }
    }

    // MARK: Link und Tabelle

    /// Link: Auswahl wird Linktext, der Cursor landet zwischen den Klammern
    /// für die URL. Ohne Auswahl entsteht `[]()` mit Cursor im Linktext.
    static func makeLink(_ text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selected = ns.substring(with: selection)
        if selection.length > 0 {
            let replacement = "[\(selected)]()"
            return Edit(range: selection, replacement: replacement,
                        selection: NSRange(
                            location: selection.location + selection.length + 3,
                            length: 0))
        }
        return Edit(range: selection, replacement: "[]()",
                    selection: NSRange(location: selection.location + 1, length: 0))
    }

    /// GFM-Tabelle: `columns` Spalten, optional mit beschrifteter Kopfzeile
    /// (GFM verlangt strukturell immer eine Kopfzeile — ohne Beschriftung
    /// bleibt sie leer). Eine leere Datenzeile zum Lostippen.
    static func tableTemplate(columns: Int, header: Bool) -> String {
        let count = max(1, columns)
        let headerCells = (1...count).map { header ? L10n.format("Spalte %ld", $0) : "   " }
        let headerRow = "| " + headerCells.joined(separator: " | ") + " |"
        let separator = "|" + Array(repeating: " --- |", count: count).joined()
        let emptyRow = "|" + Array(repeating: "   |", count: count).joined()
        return headerRow + "\n" + separator + "\n" + emptyRow
    }

    /// Fügt die Tabelle als eigenen Absatz an der Cursorposition ein
    /// (Leerzeilen davor/danach nur, wo nötig).
    static func insertTable(_ text: String, selection: NSRange,
                            columns: Int, header: Bool) -> Edit {
        let ns = text as NSString
        let table = tableTemplate(columns: columns, header: header)
        let location = selection.location
        let before = ns.substring(to: location)
        let after = ns.substring(from: NSMaxRange(selection))
        var prefix = ""
        if !before.isEmpty && !before.hasSuffix("\n\n") {
            prefix = before.hasSuffix("\n") ? "\n" : "\n\n"
        }
        var suffix = ""
        if !after.isEmpty && !after.hasPrefix("\n") { suffix = "\n" }
        let replacement = prefix + table + suffix
        // Cursor in die erste Zelle der leeren Datenzeile setzen.
        let firstDataCell = (prefix as NSString).length
            + ((table as NSString).length
               - ((table.components(separatedBy: "\n").last ?? "") as NSString).length)
            + 2
        return Edit(range: selection, replacement: replacement,
                    selection: NSRange(location: location + firstDataCell, length: 0))
    }

    // MARK: Befehls-Routing

    /// Liefert den Edit für einen parameterlosen Befehl. `insertTable`
    /// braucht den Dialog (Spalten/Kopfzeile) und läuft über `insertTable`.
    static func edit(for command: MarkdownFormatCommand,
                     text: String, selection: NSRange) -> Edit? {
        switch command {
        case .bold:           return toggleInline(text, selection: selection, marker: "**")
        case .italic:         return toggleInline(text, selection: selection, marker: "*")
        case .code:           return toggleInline(text, selection: selection, marker: "`")
        case .heading1:       return setHeading(text, selection: selection, level: 1)
        case .heading2:       return setHeading(text, selection: selection, level: 2)
        case .heading3:       return setHeading(text, selection: selection, level: 3)
        case .plainParagraph: return setHeading(text, selection: selection, level: 0)
        case .bulletList:     return toggleBulletList(text, selection: selection)
        case .orderedList:    return toggleOrderedList(text, selection: selection)
        case .quote:          return toggleQuote(text, selection: selection)
        case .link:           return makeLink(text, selection: selection)
        case .insertTable:    return nil
        case .highlight:      return toggleInline(text, selection: selection, marker: "==")
        case .hardBreak:      return insertHardBreak(in: text, after: selection)
        }
    }
}
