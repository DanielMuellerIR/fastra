// FooterLogicTests.swift
//
// Deckt Cursor-/Selektions-Position (bewegte Kante) und die
// Dokument-Statistik-Zählung ab.

import Testing
import Foundation
@testable import Fastra

// MARK: - CursorFooter (bewegte Kante)

@Test("Reiner Cursor: zeigt start-Position, Anker = Offset")
func cursor_noSelection() {
    let r = CursorFooter.resolve(
        rangeLocation: 42, rangeLength: 0,
        startLine: 3, startColumn: 5,
        endLine: nil, endColumn: nil,
        previousAnchor: nil
    )
    #expect(r == CursorFooter.Resolved(line: 3, column: 5, anchor: 42))
}

@Test("Selektion nach unten: zeigt obere Kante (end), Anker bleibt unten")
func selection_draggingDown() {
    // Cursor stand bei Offset 10 (Z2). Nutzer zieht nach unten bis Offset 30 (Z4).
    // range = [10, 30]. Erster Frame: previousAnchor nil → Anker = location = 10.
    let r = CursorFooter.resolve(
        rangeLocation: 10, rangeLength: 20,
        startLine: 2, startColumn: 1,
        endLine: 4, endColumn: 3,
        previousAnchor: 10
    )
    // Anker unten (10) → Kopf oben (end) = Z4.
    #expect(r == CursorFooter.Resolved(line: 4, column: 3, anchor: 10))
}

@Test("Selektion nach oben: zeigt untere Kante (start), Anker bleibt oben")
func selection_draggingUp() {
    // Cursor stand bei Offset 30 (Z4). Nutzer zieht nach oben bis Offset 10 (Z2).
    // range = [10, 30], aber Anker war 30 (max).
    let r = CursorFooter.resolve(
        rangeLocation: 10, rangeLength: 20,
        startLine: 2, startColumn: 1,
        endLine: 4, endColumn: 3,
        previousAnchor: 30
    )
    // Anker == maxLoc (30) → Kopf unten (start) = Z2.
    #expect(r == CursorFooter.Resolved(line: 2, column: 1, anchor: 30))
}

@Test("Selektion wächst nach unten: Kopf folgt weiter nach unten")
func selection_growsDownward() {
    // Anker unten bei 10, Selektion jetzt bis Offset 50 (Z6).
    let r = CursorFooter.resolve(
        rangeLocation: 10, rangeLength: 40,
        startLine: 2, startColumn: 1,
        endLine: 6, endColumn: 1,
        previousAnchor: 10
    )
    #expect(r.line == 6)
    #expect(r.anchor == 10)
}

@Test("Erster Frame ohne vorherigen Anker: Kopf unten (end)")
func selection_firstFrameDefaultsDown() {
    let r = CursorFooter.resolve(
        rangeLocation: 10, rangeLength: 20,
        startLine: 2, startColumn: 1,
        endLine: 4, endColumn: 3,
        previousAnchor: nil
    )
    #expect(r.line == 4)
    #expect(r.anchor == 10)
}

// MARK: - DocumentStats

@Test("Statistik: einfacher Satz")
func stats_simple() {
    let c = DocumentStats.counts(of: "hallo welt")
    #expect(c == DocumentStats.Counts(characters: 10, words: 2, lines: 1))
}

@Test("Statistik: mehrere Zeilen")
func stats_multiline() {
    let c = DocumentStats.counts(of: "a\nb\nc")
    #expect(c == DocumentStats.Counts(characters: 5, words: 3, lines: 3))
}

@Test("Statistik: leerer Text → 0 Zeichen, 0 Wörter, 1 Zeile")
func stats_empty() {
    let c = DocumentStats.counts(of: "")
    #expect(c == DocumentStats.Counts(characters: 0, words: 0, lines: 1))
}

@Test("Statistik: trailing newline zählt als zusätzliche (leere) Zeile")
func stats_trailingNewline() {
    let c = DocumentStats.counts(of: "a\n")
    #expect(c.lines == 2)
}

@Test("Format: chars / words / lines")
func stats_format() {
    let s = DocumentStats.format(DocumentStats.Counts(characters: 12, words: 3, lines: 2))
    #expect(s == "12 / 3 / 2")
}

// MARK: - FooterLogic.searchSummary

@Test("Datei-Scope mit Treffern: Text zeigt Anzahl, Label ist Datei")
func searchSummary_file_withMatches() {
    let r = FooterLogic.searchSummary(scope: .file, bufferCount: 7, folderTotal: 0, folderFiles: 0)
    #expect(r.text  == L10n.format("%ld Treffer", 7))
    #expect(r.label == L10n.string("Datei"))
}

@Test("Datei-Scope ohne Treffer: Text ist 'Keine Treffer', Label ist Datei")
func searchSummary_file_noMatches() {
    let r = FooterLogic.searchSummary(scope: .file, bufferCount: 0, folderTotal: 0, folderFiles: 0)
    #expect(r.text  == L10n.string("Keine Treffer"))
    #expect(r.label == L10n.string("Datei"))
}

@Test("Ordner-Scope mit Treffern: Text zeigt Treffer und Dateianzahl, Label ist Ordner")
func searchSummary_folder_withMatches() {
    let r = FooterLogic.searchSummary(scope: .folder, bufferCount: 0, folderTotal: 51, folderFiles: 4)
    #expect(r.text  == L10n.format("%ld Treffer · %ld Dateien", 51, 4))
    #expect(r.label == L10n.string("Ordner"))
}

@Test("Ordner-Scope ohne Treffer: Text ist 'Keine Treffer', Label ist Ordner")
func searchSummary_folder_noMatches() {
    let r = FooterLogic.searchSummary(scope: .folder, bufferCount: 0, folderTotal: 0, folderFiles: 0)
    #expect(r.text  == L10n.string("Keine Treffer"))
    #expect(r.label == L10n.string("Ordner"))
}

@Test("Datei-Scope: bufferCount 1 liefert '1 Treffer' (singular)")
func searchSummary_file_singleMatch() {
    let r = FooterLogic.searchSummary(scope: .file, bufferCount: 1, folderTotal: 0, folderFiles: 0)
    #expect(r.text == L10n.string("1 Treffer"))
}

@Test("Ordner-Scope: eine Datei mit einem Treffer korrekt formatiert")
func searchSummary_folder_singleFileMatch() {
    let r = FooterLogic.searchSummary(scope: .folder, bufferCount: 0, folderTotal: 1, folderFiles: 1)
    #expect(r.text == L10n.format("%@ · %@", L10n.string("1 Treffer"),
                                  L10n.string("1 Datei")))
}
