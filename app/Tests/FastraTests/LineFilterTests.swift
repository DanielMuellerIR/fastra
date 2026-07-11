import Testing
import Foundation
@testable import Fastra

// Tests für LineFilter — „Process Lines Containing" (BBEdit, Kap. 5).
// RegEx-basierter Zeilen-Filter: behält oder löscht ganze Zeilen nach einem
// Muster. Pur, UI-frei: (Text, Selektion, Muster, Modus) rein → kompletter
// neuer Text raus, oder nil = nichts zu tun.

private let whole = NSRange(location: 0, length: 0)   // leere Selektion = ganze Datei

// MARK: - Behalten / Löschen (Grundverhalten)

@Test("filter behält nur Zeilen mit Treffer (keepMatching = true)")
func filter_keepMatching() {
    let text = "INFO start\nERROR boom\nINFO ok\nERROR crash"
    // Nur Zeilen, die „ERROR" enthalten, sollen übrig bleiben. (Muster ohne Anker,
    // damit es auch „ERROR" am Zeilenanfang trifft.)
    let r = LineFilter.filter(in: text, selection: whole, pattern: "ERROR",
                              keepMatching: true)
    #expect(r?.newText == "ERROR boom\nERROR crash")
    #expect(r?.lineCount == 2)
}

@Test("filter löscht Zeilen mit Treffer (keepMatching = false)")
func filter_deleteMatching() {
    let text = "INFO start\nERROR boom\nINFO ok\nERROR crash"
    // Die „ERROR"-Zeilen sollen verschwinden, die „INFO"-Zeilen bleiben.
    let r = LineFilter.filter(in: text, selection: whole, pattern: "ERROR",
                              keepMatching: false)
    #expect(r?.newText == "INFO start\nINFO ok")
    #expect(r?.lineCount == 2)
}

// MARK: - Groß-/Kleinschreibung

@Test("filter ist per Default case-insensitiv (wie der Such-Default)")
func filter_caseInsensitiveDefault() {
    let text = "Apfel\nBIRNE\napfel\nKirsche"
    // „apfel" matcht per Default auch „Apfel" (case-insensitiv).
    let r = LineFilter.filter(in: text, selection: whole, pattern: "apfel",
                              keepMatching: true)
    #expect(r?.newText == "Apfel\napfel")
}

@Test("filter case-sensitiv unterscheidet Groß-/Kleinschreibung")
func filter_caseSensitive() {
    let text = "Apfel\nBIRNE\napfel\nKirsche"
    // Exakt „apfel" klein → nur die kleingeschriebene Zeile bleibt.
    let r = LineFilter.filter(in: text, selection: whole, pattern: "apfel",
                              keepMatching: true, caseInsensitive: false)
    #expect(r?.newText == "apfel")
}

// MARK: - Ungültige / leere Muster

@Test("filter mit ungültigem RegEx → nil")
func filter_invalidRegex() {
    // Unbalancierte Klammer ist kein gültiges NSRegularExpression-Muster.
    #expect(LineFilter.filter(in: "a\nb\nc", selection: whole, pattern: "(unbalanced",
                              keepMatching: true) == nil)
}

@Test("filter mit leerem Muster → nil")
func filter_emptyPattern() {
    #expect(LineFilter.filter(in: "a\nb\nc", selection: whole, pattern: "",
                              keepMatching: true) == nil)
}

// MARK: - Keine Änderung

@Test("filter ohne Änderung (im Behalten-Modus matchen alle Zeilen) → nil")
func filter_noChange() {
    let text = "alpha\nbeta\ngamma"
    // „.+" matcht jede nicht-leere Zeile → im Behalten-Modus bleibt alles → nil.
    #expect(LineFilter.filter(in: text, selection: whole, pattern: ".+",
                              keepMatching: true) == nil)
}

// MARK: - Datei-End-Newline

@Test("filter über die ganze Datei erhält das abschließende Newline")
func filter_preservesTrailingNewline() {
    // Ganz-Text-Fall mit abschließendem \n: die Phantom-Leerzeile zählt nicht
    // als Inhalt, das Datei-End-Newline bleibt aber erhalten.
    let text = "keep1\ndrop\nkeep2\n"
    let r = LineFilter.filter(in: text, selection: whole, pattern: "keep",
                              keepMatching: true)
    #expect(r?.newText == "keep1\nkeep2\n")
    #expect(r?.lineCount == 2)   // nur die zwei echten Inhaltszeilen
}

// MARK: - Teil-Selektion

@Test("filter wirkt nur auf die selektierten Zeilen, Rest bleibt unangetastet")
func filter_selectionOnly() {
    let text = "drop A\nkeep\ndrop B\ntail drop"
    // Selektion über die ersten DREI Zeilen „drop A\nkeep\ndrop B" (0..20).
    // „tail drop" liegt außerhalb der Selektion und bleibt — obwohl es „drop"
    // enthält.
    let selLength = ("drop A\nkeep\ndrop B" as NSString).length
    let r = LineFilter.filter(in: text, selection: NSRange(location: 0, length: selLength),
                              pattern: "drop", keepMatching: false)
    #expect(r?.newText == "keep\ntail drop")
}

// MARK: - Voller Dokument-Wipe verhindern

@Test("filter würde alles löschen (keine Zeile matcht im Behalten-Modus) → nil")
func filter_wouldBeEmpty() {
    let text = "alpha\nbeta\ngamma"
    // Kein „xyz" irgendwo → im Behalten-Modus bliebe nichts übrig → nil
    // statt vollem Dokument-Wipe.
    #expect(LineFilter.filter(in: text, selection: whole, pattern: "xyz",
                              keepMatching: true) == nil)
}

@Test("filter würde alles löschen (alle Zeilen matchen im Lösch-Modus) → nil")
func filter_wouldBeEmptyDeleteMode() {
    let text = "x1\nx2\nx3"
    // Alle Zeilen enthalten „x" → im Lösch-Modus bliebe nichts übrig → nil.
    #expect(LineFilter.filter(in: text, selection: whole, pattern: "x",
                              keepMatching: false) == nil)
}

// MARK: - CRLF-Robustheit

@Test("filter erhält den CRLF-Trenner")
func filter_crlf() {
    let text = "keep1\r\ndrop\r\nkeep2"
    let r = LineFilter.filter(in: text, selection: whole, pattern: "drop",
                              keepMatching: false)
    #expect(r?.newText == "keep1\r\nkeep2")
}

// MARK: - Sonderfälle Muster / Treffer

@Test("filter mit RegEx-Metazeichen-Literal (Punkt escaped)")
func filter_metacharLiteral() {
    let text = "192.168.0.1\nlocalhost\n10.0.0.5"
    // Escaped „\." trifft nur Zeilen mit echtem Punkt → die IP-Zeilen bleiben.
    let r = LineFilter.filter(in: text, selection: whole, pattern: "\\.",
                              keepMatching: true)
    #expect(r?.newText == "192.168.0.1\n10.0.0.5")
}

@Test("filter zählt mehrere Treffer in einer Zeile als EINE treffende Zeile")
func filter_multipleMatchesCountOnce() {
    let text = "aaa\nbbb\naba"
    // „a" kommt in „aaa" dreimal und in „aba" zweimal vor — beide Zeilen
    // bleiben (eine treffende Zeile ist eine treffende Zeile), „bbb" fliegt.
    let r = LineFilter.filter(in: text, selection: whole, pattern: "a",
                              keepMatching: true)
    #expect(r?.newText == "aaa\naba")
    #expect(r?.lineCount == 2)
}

// MARK: - Einzelzeile

@Test("filter auf einer einzelnen Inhaltszeile, die matcht und behalten würde → nil")
func filter_singleLineNoChange() {
    // Eine Zeile, sie matcht, Behalten-Modus → unverändert → nil.
    #expect(LineFilter.filter(in: "nur diese eine", selection: whole, pattern: "eine",
                              keepMatching: true) == nil)
}
