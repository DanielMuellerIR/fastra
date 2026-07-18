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

// MARK: - Inline (Fett/Kursiv/Code)

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
