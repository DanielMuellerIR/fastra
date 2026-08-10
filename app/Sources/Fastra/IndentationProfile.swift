// IndentationProfile.swift
//
// Etappe 4 des Soft-Wrap-Pakets (Beschluss 2026-07-19): konsistente
// Einrückung. Diese Datei bündelt das wirksame Einrückungsprofil eines
// Formats und den UI-freien Algorithmus für „Einfügen und Einrückung
// angleichen" (BBEdit „Paste and Match Indentation", Handbuch 16.0.2
// S. 89: „this command will attempt to indent the pasted text to the same
// level as the line on which you paste (or if that line is empty, the most
// recent non-empty line)").

import Foundation

/// Das wirksame Einrückungsprofil eines Formats: Tabs oder Leerzeichen,
/// Einrückungsbreite (Leerzeichen je Stufe) und Tab-DARSTELLUNGS-Breite.
/// Werkstandard ist das bisher fest verdrahtete Verhalten (vier Leerzeichen,
/// Tabbreite vier) — migrationssicher, keine geratenen Sprachdefaults.
struct IndentationProfile: Equatable {
    let usesTabs: Bool
    let indentWidth: Int
    let tabWidth: Int

    static let factory = IndentationProfile(usesTabs: false, indentWidth: 4, tabWidth: 4)

    /// Der Text EINER Einrückungsstufe (Tab-Taste, Shift-Right).
    var unitString: String {
        usesTabs ? "\t" : String(repeating: " ", count: indentWidth)
    }

    /// Drückt `columns` visuelle Spalten als Einrückungs-Whitespace des
    /// Profils aus: Tab-Profile füllen ganze Tabstopps mit Tabs und nur den
    /// Rest mit Leerzeichen; Leerzeichen-Profile verwenden nur Leerzeichen.
    func whitespace(forColumns columns: Int) -> String {
        guard columns > 0 else { return "" }
        guard usesTabs, tabWidth > 0 else {
            return String(repeating: " ", count: columns)
        }
        let tabs = columns / tabWidth
        let rest = columns % tabWidth
        return String(repeating: "\t", count: tabs)
            + String(repeating: " ", count: rest)
    }

    /// Visuelle Breite eines führenden Whitespace-Stücks (Tabstopp-bewusst).
    func visualColumns(ofLeadingWhitespace value: Substring) -> Int {
        var column = 0
        for character in value {
            if character == "\t" {
                let width = max(tabWidth, 1)
                column += width - (column % width)
            } else {
                column += 1
            }
        }
        return column
    }
}

/// UI-freier Kern von „Einfügen und Einrückung angleichen".
enum IndentationMatchingPaste {

    /// Zeilenweise Zerlegung, die \n, \r\n und \r sicher erkennt und sich
    /// merkt, ob der Text mit einem Zeilenumbruch endete.
    static func splitLines(_ text: String) -> (lines: [String], endsWithNewline: Bool) {
        guard !text.isEmpty else { return ([], false) }
        var lines: [String] = []
        var current = ""
        var endsWithNewline = false
        // Swift fasst "\r\n" als EINEN Character-Cluster zusammen — der
        // Vergleich deckt deshalb alle drei Umbrucharten je Cluster ab.
        for character in text {
            if character == "\n" || character == "\r" || character == "\r\n" {
                lines.append(current)
                current = ""
                endsWithNewline = true
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            lines.append(current)
            endsWithNewline = false
        }
        return (lines, endsWithNewline)
    }

    /// Führender Whitespace (Space/Tab) einer Zeile.
    static func leadingWhitespace(of line: String) -> Substring {
        line.prefix(while: { $0 == " " || $0 == "\t" })
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Einrückungskontext der Einfügestelle:
    /// - `columns`: visuelle Einrückung der Zielzeile — bei einer leeren
    ///   Zielzeile die der zuletzt vorangehenden nicht leeren Zeile
    ///   (BBEdit-Semantik, Handbuch S. 89).
    /// - `prefixIsWhitespaceOnly`: `true`, wenn vor der Einfügestelle auf
    ///   ihrer Zeile nur Whitespace steht — nur dann wird auch die ERSTE
    ///   eingefügte Zeile eingerückt; mitten in einer Zeile bliebe sonst
    ///   Whitespace im Satz stehen.
    /// - `replacementStart`: Dokumentposition, ab der ersetzt werden muss.
    ///   Steht vor der Einfügestelle nur Einrückung (typisch auf einer
    ///   automatisch eingerückten Leerzeile), gehört diese zum Block und wird
    ///   MIT ersetzt — sonst addierte sie sich zu der Einrückung, die
    ///   `matchedText` der ersten Zeile ohnehin voranstellt, und der Block
    ///   säße eine Ebene zu tief. Sonst ist es die Einfügestelle selbst.
    static func targetContext(documentText: String, insertionLocation: Int,
                              profile: IndentationProfile)
        -> (columns: Int, prefixIsWhitespaceOnly: Bool, replacementStart: Int) {
        let ns = documentText as NSString
        let location = max(0, min(insertionLocation, ns.length))
        // Die Position HINTER einem End-Umbruch ist der Anfang einer leeren
        // letzten Zeile — `lineRange` kennt diese implizite Zeile nicht und
        // fiele sonst auf die Zeile davor zurück (deren Umbruch den Präfix
        // „nicht nur Whitespace" machte).
        let lineRange: NSRange
        if ns.length == 0 {
            lineRange = NSRange(location: 0, length: 0)
        } else if location == ns.length,
                  ns.substring(with: NSRange(location: ns.length - 1, length: 1))
                      .rangeOfCharacter(from: .newlines) != nil {
            lineRange = NSRange(location: location, length: 0)
        } else {
            lineRange = ns.lineRange(for: NSRange(location: min(location, ns.length - 1),
                                                  length: 0))
        }
        let prefix = ns.substring(with: NSRange(location: lineRange.location,
                                                length: max(0, location - lineRange.location)))
        let prefixIsWhitespaceOnly = prefix.allSatisfy { $0 == " " || $0 == "\t" }
        // Reiner Whitespace vor der Einfügestelle ist bereits vorhandene
        // Einrückung: Sie wird mit ersetzt, statt sich zu verdoppeln.
        let replacementStart = prefixIsWhitespaceOnly ? lineRange.location : location

        var probeRange = lineRange
        var probeLine = ns.substring(with: probeRange)
            .trimmingCharacters(in: .newlines)
        // Leere Zielzeile: rückwärts die zuletzt nicht leere Zeile suchen.
        while isBlank(probeLine), probeRange.location > 0 {
            probeRange = ns.lineRange(for: NSRange(location: probeRange.location - 1, length: 0))
            probeLine = ns.substring(with: probeRange)
                .trimmingCharacters(in: .newlines)
        }
        guard !isBlank(probeLine) else {
            return (0, prefixIsWhitespaceOnly, replacementStart)
        }
        let columns = profile.visualColumns(
            ofLeadingWhitespace: leadingWhitespace(of: probeLine))
        return (columns, prefixIsWhitespaceOnly, replacementStart)
    }

    /// Der Kernalgorithmus (Spezifikation Etappe 4, Punkt 2):
    /// 1. Zeilenenden des Clipboard-Texts sicher erkennen,
    /// 2. gemeinsame minimale visuelle Einrückung aller nicht leeren Zeilen
    ///    bestimmen,
    /// 3. diese Basis entfernen,
    /// 4. die relative Einrückung der Zeilen erhalten,
    /// 5. den Block auf die Ziel-Einrückung setzen,
    /// 6. das Ergebnis in Tabs/Leerzeichen des Profils ausdrücken.
    /// Leere Zeilen bleiben leer; der Zeilenendungsstil des Dokuments gilt
    /// für alle erzeugten Umbrüche; ohne abschließenden Clipboard-Umbruch
    /// endet auch das Ergebnis ohne Umbruch.
    static func matchedText(clipboard: String,
                            targetColumns: Int,
                            indentFirstLine: Bool,
                            lineEnding: LineEnding,
                            profile: IndentationProfile) -> String {
        let (lines, endsWithNewline) = splitLines(clipboard)
        guard !lines.isEmpty else { return "" }

        let indents = lines.map { line -> Int? in
            isBlank(line) ? nil
                : profile.visualColumns(ofLeadingWhitespace: leadingWhitespace(of: line))
        }
        let base = indents.compactMap { $0 }.min() ?? 0

        var result: [String] = []
        result.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            if isBlank(line) {
                // Leerzeilen bleiben leer — keine erfundene Einrückung, kein
                // stehen gelassener Alt-Whitespace.
                result.append("")
                continue
            }
            let content = String(line.dropFirst(leadingWhitespace(of: line).count))
            let relative = (indents[index] ?? base) - base
            if index == 0 && !indentFirstLine {
                // Mitten in einer Zeile eingefügt: Die erste Zeile beginnt an
                // der Einfügestelle; nur ihre RELATIVE Tiefe über der Basis
                // bleibt erhalten.
                result.append(profile.whitespace(forColumns: relative) + content)
            } else {
                result.append(profile.whitespace(forColumns: targetColumns + relative)
                    + content)
            }
        }
        let joined = result.joined(separator: "\n")
            + (endsWithNewline ? "\n" : "")
        // Ein Durchlauf durch die Dokument-Konvention macht alle Umbrüche
        // einheitlich (CRLF-/CR-Dokumente eingeschlossen).
        return lineEnding.converting(joined)
    }
}
