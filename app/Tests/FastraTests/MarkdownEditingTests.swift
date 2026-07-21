// MarkdownEditingTests.swift
//
// Tests für die puren Markdown-Formatierungsbefehle (Etappe 5 Wunschpaket
// 2026-07b): reine Textfunktionen — Anwendung/Undo prüft der Editor-Pfad.

import Foundation
import Testing
@testable import Fastra

/// Wendet einen Edit auf den Text an (Test-Nachbau von replaceCharacters).
private func applied(_ edit: MarkdownFormat.Edit, to text: String) -> String {
    (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
}

private func range(_ location: Int, _ length: Int) -> NSRange {
    NSRange(location: location, length: length)
}

// MARK: - Inline (Fett/Kursiv/Hervorhebung/Code)

@Test("Fett: Auswahl wird eingepackt, Selektion bleibt auf dem Wort")
func bold_wrapsSelection() {
    let text = "ein wort hier"
    let edit = MarkdownFormat.toggleInline(text, selection: range(4, 4), marker: "**")
    #expect(applied(edit, to: text) == "ein **wort** hier")
    #expect(edit.selection == range(6, 4))
}

@Test("Fett: erneuter Befehl auf markiertem Wort entfernt die Marker (Toggle)")
func bold_unwrapsWhenSurrounded() {
    let text = "ein **wort** hier"
    // Auswahl NUR auf „wort“ (Marker außen).
    let edit = MarkdownFormat.toggleInline(text, selection: range(6, 4), marker: "**")
    #expect(applied(edit, to: text) == "ein wort hier")
    #expect(edit.selection == range(4, 4))
}

@Test("Fett: Auswahl INKLUSIVE Marker wird ebenfalls ausgepackt")
func bold_unwrapsWhenSelectedWithMarkers() {
    let text = "ein **wort** hier"
    let edit = MarkdownFormat.toggleInline(text, selection: range(4, 8), marker: "**")
    #expect(applied(edit, to: text) == "ein wort hier")
}

@Test("Kursiv ohne Auswahl: leeres Markerpaar, Cursor in der Mitte")
func italic_emptySelection() {
    let edit = MarkdownFormat.toggleInline("abc", selection: range(3, 0), marker: "*")
    #expect(applied(edit, to: "abc") == "abc**")
    #expect(edit.selection == range(4, 0))
}

@Test("Hervorheben: Auswahl wird mit doppelten Gleichheitszeichen umschlossen")
func highlight_wrapsSelection() {
    let text = "Das ist wichtig."
    let edit = MarkdownFormat.edit(for: .highlight, text: text,
                                   selection: range(8, 7))
    #expect(edit != nil)
    #expect(applied(edit!, to: text) == "Das ist ==wichtig==.")
    #expect(edit!.selection == range(10, 7))
}

@Test("Hervorheben: erneuter Befehl entfernt die Marker")
func highlight_togglesOff() {
    let text = "Das ist ==wichtig==."
    let edit = MarkdownFormat.edit(for: .highlight, text: text,
                                   selection: range(10, 7))
    #expect(edit != nil)
    #expect(applied(edit!, to: text) == "Das ist wichtig.")
}

@Test("Harter Zeilenumbruch: zwei Leerzeichen und Newline als ein Edit")
func hardBreak_insertsMarkdownBreak() {
    let text = "Erste ZeileZweite Zeile"
    let edit = MarkdownFormat.edit(for: .hardBreak, text: text,
                                   selection: range(11, 0))
    #expect(edit != nil)
    #expect(applied(edit!, to: text) == "Erste Zeile  \nZweite Zeile")
    #expect(edit!.selection == range(14, 0))
}

@Test("Harter Zeilenumbruch: Auswahl bleibt erhalten und Umbruch folgt danach")
func hardBreak_preservesSelection() {
    let text = "Erste ZeileZweite Zeile"
    let edit = MarkdownFormat.edit(for: .hardBreak, text: text,
                                   selection: range(0, 11))
    #expect(edit != nil)
    #expect(applied(edit!, to: text) == "Erste Zeile  \nZweite Zeile")
    #expect(edit!.range == range(11, 0))
}

@Test("Harter Zeilenumbruch: vorhandenes Newline wird nicht verdoppelt")
func hardBreak_reusesExistingNewline() {
    let text = "Erste Zeile\nZweite Zeile"
    let edit = MarkdownFormat.edit(for: .hardBreak, text: text,
                                   selection: range(11, 0))
    #expect(edit != nil)
    #expect(applied(edit!, to: text) == "Erste Zeile  \nZweite Zeile")
    #expect(edit!.replacement == "  ")
}

@Test("Harter Zeilenumbruch: vorhandene Spaces werden auf genau zwei normalisiert")
func hardBreak_normalizesTrailingSpaces() {
    for spaces in [" ", "   "] {
        let text = "Zeile\(spaces)\nDanach"
        let location = ("Zeile\(spaces)" as NSString).length
        let edit = MarkdownFormat.edit(for: .hardBreak, text: text,
                                       selection: range(location, 0))
        #expect(edit != nil)
        #expect(applied(edit!, to: text) == "Zeile  \nDanach")
    }
}

@Test("Harter Zeilenumbruch: auf einer leeren Zeile kein irreführender Edit")
func hardBreak_emptyLineIsNoOp() {
    #expect(MarkdownFormat.edit(for: .hardBreak, text: "Davor\n\nDanach",
                                selection: range(7, 0)) == nil)
}

// MARK: - Überschriften

@Test("Überschrift 2 setzen und mit Ebene 0 wieder entfernen")
func heading_setAndClear() {
    let set = MarkdownFormat.setHeading("Titelzeile", selection: range(0, 0), level: 2)
    #expect(applied(set, to: "Titelzeile") == "## Titelzeile")

    let cleared = MarkdownFormat.setHeading("## Titelzeile", selection: range(5, 0), level: 0)
    #expect(applied(cleared, to: "## Titelzeile") == "Titelzeile")
}

@Test("Überschrift ersetzt eine vorhandene Ebene statt zu stapeln")
func heading_replacesExistingLevel() {
    let edit = MarkdownFormat.setHeading("### Alt", selection: range(0, 0), level: 1)
    #expect(applied(edit, to: "### Alt") == "# Alt")
}

// MARK: - Listen und Zitat

@Test("Aufzählung: mehrere Zeilen bekommen '- ', Leerzeile bleibt leer")
func bullets_addAcrossLines() {
    let text = "eins\n\nzwei"
    let edit = MarkdownFormat.toggleBulletList(text, selection: range(0, (text as NSString).length))
    #expect(applied(edit, to: text) == "- eins\n\n- zwei")
}

@Test("Aufzählung: erneuter Befehl entfernt die Punkte (Toggle)")
func bullets_toggleOff() {
    let text = "- eins\n- zwei"
    let edit = MarkdownFormat.toggleBulletList(text, selection: range(0, (text as NSString).length))
    #expect(applied(edit, to: text) == "eins\nzwei")
}

@Test("Nummerierte Liste zählt 1., 2., … und ersetzt eine Aufzählung")
func orderedList_numbersAndReplaces() {
    let text = "- eins\n- zwei\n- drei"
    let edit = MarkdownFormat.toggleOrderedList(text, selection: range(0, (text as NSString).length))
    #expect(applied(edit, to: text) == "1. eins\n2. zwei\n3. drei")
}

@Test("Zitat: '> ' umschalten")
func quote_toggles() {
    let on = MarkdownFormat.toggleQuote("satz", selection: range(0, 4))
    #expect(applied(on, to: "satz") == "> satz")
    let off = MarkdownFormat.toggleQuote("> satz", selection: range(0, 6))
    #expect(applied(off, to: "> satz") == "satz")
}

@Test("Zeilenbefehle wirken auf ganze Zeilen, auch bei Teil-Auswahl mitten im Text")
func lineCommands_expandToFullLines() {
    let text = "vorher\nmittig markiert\nnachher"
    // Auswahl nur über „markiert“ in Zeile 2.
    let edit = MarkdownFormat.toggleQuote(text, selection: range(14, 8))
    #expect(applied(edit, to: text) == "vorher\n> mittig markiert\nnachher")
}

// MARK: - Link und Tabelle

@Test("Link: Auswahl wird Linktext, Cursor landet zwischen den URL-Klammern")
func link_wrapsSelection() {
    let text = "siehe Doku dazu"
    let edit = MarkdownFormat.makeLink(text, selection: range(6, 4))
    #expect(applied(edit, to: text) == "siehe [Doku]() dazu")
    // Cursor zwischen den Klammern: nach „[Doku](“.
    #expect(edit.selection == range(13, 0))
}

@Test("Link ohne Auswahl: []() mit Cursor im Linktext")
func link_emptySelection() {
    let edit = MarkdownFormat.makeLink("", selection: range(0, 0))
    #expect(edit.replacement == "[]()")
    #expect(edit.selection == range(1, 0))
}

@Test("Tabelle: 2 Spalten mit Kopfzeile — GFM-Struktur")
func table_withHeader() {
    let table = MarkdownFormat.tableTemplate(columns: 2, header: true)
    let lines = table.components(separatedBy: "\n")
    #expect(lines.count == 3)
    #expect(lines[0].contains("|"))
    #expect(lines[1] == "| --- | --- |")
}

@Test("Tabelle einfügen: Leerzeilen-Abstand vor dem Block, Cursor in erster Zelle")
func table_insertSpacing() {
    let text = "Absatz davor."
    let edit = MarkdownFormat.insertTable(text, selection: range((text as NSString).length, 0),
                                          columns: 2, header: false)
    let result = applied(edit, to: text)
    #expect(result.hasPrefix("Absatz davor.\n\n|"))
    // Cursor liegt in der leeren Datenzeile (letzte Zeile).
    let cursorLinePrefix = (result as NSString).substring(to: edit.selection.location)
    #expect(cursorLinePrefix.hasSuffix("| "))
}

// MARK: - Markdown-Erkennung

@Test("isMarkdownFilename: .md/.markdown, Groß/klein egal, sonst nein")
func markdownFilename() {
    #expect(MarkdownFormat.isMarkdownFilename("notiz.md"))
    #expect(MarkdownFormat.isMarkdownFilename("README.MD"))
    #expect(MarkdownFormat.isMarkdownFilename("doku.markdown"))
    #expect(!MarkdownFormat.isMarkdownFilename("main.swift"))
    #expect(!MarkdownFormat.isMarkdownFilename("Ohne Titel"))
}
