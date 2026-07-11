import Foundation
import Testing
@testable import Fastra

// Tests für LineOperations „Process Duplicate Lines" (BBEdit Kap. 5):
//   - keepDuplicateLines        — behält NUR die mehrfach vorkommenden Zeilen (je einmal).
//   - removeAllDuplicatedLines  — entfernt JEDE mehrfach vorkommende Zeile (auch das Original).
// Beide unterscheiden sich vom älteren removeDuplicateLines (das das erste Vorkommen behält).
// Pur, UI-frei: (Text, Selektion) rein → kompletter neuer Text raus, oder nil = nichts zu tun.

private let whole = NSRange(location: 0, length: 0)   // leere Selektion = ganze Datei

// MARK: - keepDuplicateLines

@Test("keepDuplicateLines behält je Dublette eine, in Reihenfolge des ersten Auftretens")
func keepDup_firstOccurrenceOrder() {
    // „a" (×2) und „b" (×2) sind Dubletten, „c" (×1) nicht. Reihenfolge: a vor b.
    let result = LineOperations.keepDuplicateLines(in: "a\nb\na\nc\nb",
                                                   selection: whole)
    #expect(result?.newText == "a\nb")
    #expect(result?.lineCount == 2)
}

@Test("keepDuplicateLines ohne Dubletten liefert nil")
func keepDup_noDuplicates() {
    #expect(LineOperations.keepDuplicateLines(in: "a\nb\nc", selection: whole) == nil)
}

@Test("keepDuplicateLines zählt eine dreifach vorkommende Zeile trotzdem nur einmal")
func keepDup_triplicateOnce() {
    // „x" kommt dreimal vor → genau EINMAL im Ergebnis; „y" einmal → raus.
    let result = LineOperations.keepDuplicateLines(in: "x\ny\nx\nx",
                                                   selection: whole)
    #expect(result?.newText == "x")
    #expect(result?.lineCount == 1)
}

@Test("keepDuplicateLines mit nur einer Zeile liefert nil")
func keepDup_singleLine() {
    #expect(LineOperations.keepDuplicateLines(in: "einzeiler", selection: whole) == nil)
}

@Test("keepDuplicateLines wirkt nur im selektierten Bereich")
func keepDup_selectionOnly() {
    // „a" doppelt innerhalb der Selektion, das letzte „b" liegt außerhalb.
    let text = "a\nb\na\nc\nb"
    // Selektion über die ersten vier Zeilen „a\nb\na\nc" = {0,7}.
    let result = LineOperations.keepDuplicateLines(in: text,
                                                   selection: NSRange(location: 0, length: 7))
    // Innerhalb der Selektion: a(×2), b(×1), c(×1) → nur „a" ist Dublette,
    // b und c werden entfernt. Die 5. Zeile „b" liegt AUSSERHALB der Selektion
    // und bleibt unangetastet → „a" (selektierter Block) + „\nb" (Rest) = „a\nb".
    #expect(result?.newText == "a\nb")
}

@Test("keepDuplicateLines erhält das Datei-End-Newline (Phantom-Leerzeile)")
func keepDup_trailingNewline() {
    // „a" doppelt, abschließendes \n soll erhalten bleiben.
    let result = LineOperations.keepDuplicateLines(in: "a\nb\na\n",
                                                   selection: whole)
    #expect(result?.newText == "a\n")
}

@Test("keepDuplicateLines erhält den CRLF-Trenner")
func keepDup_crlf() {
    let result = LineOperations.keepDuplicateLines(in: "a\r\nb\r\na\r\nc",
                                                   selection: whole)
    #expect(result?.newText == "a")
    // Nur eine Zeile übrig → kein Trenner, aber kein verirrtes \r.
    #expect(result?.newText.contains("\r") == false)
}

@Test("keepDuplicateLines: zwei echte Leerzeilen unter Inhalt sind Dubletten, Phantom nicht")
func keepDup_blankLinesAreContent() {
    // Zwei echte Leerzeilen (zwischen Inhalt) sind eine Dublette der leeren Zeile;
    // „a" ist einmalig. Kein abschließendes \n → keine Phantom-Leerzeile.
    let text = "a\n\nb\n"   // Zeilen: "a", "", "b", "" (Phantom)
    // Hier ist nur EINE echte Leerzeile + Phantom → keine Dublette unter den echten.
    #expect(LineOperations.keepDuplicateLines(in: text, selection: whole) == nil)
}

@Test("keepDuplicateLines: doppelte echte Leerzeile gilt als Dublette, Phantom zählt nicht mit")
func keepDup_blankDuplicateVsPhantom() {
    // Echte Zeilen: "a", "", "b", "" → die leere Zeile kommt ZWEIMAL echt vor (Dublette),
    // PLUS die Phantom-Leerzeile vom Datei-End-Newline (zählt nicht).
    let text = "a\n\nb\n\n"   // splitLines → ["a", "", "b", "", ""]; letztes "" = Phantom.
    let result = LineOperations.keepDuplicateLines(in: text, selection: whole)
    // Übrig: nur die leere Zeile (Dublette), einmal — plus erhaltene Phantom-Leerzeile.
    // Ergebnis-Block ist "" + Trenner + "" (Phantom) = "\n".
    #expect(result?.newText == "\n")
    #expect(result?.lineCount == 1)
}

// MARK: - removeAllDuplicatedLines

@Test("removeAllDuplicatedLines behält nur die einmaligen Zeilen, in Originalreihenfolge")
func removeAll_keepsUniques() {
    // „a" doppelt → komplett weg; „b" und „c" einmalig → bleiben in Reihenfolge.
    let result = LineOperations.removeAllDuplicatedLines(in: "a\nb\na\nc",
                                                         selection: whole)
    #expect(result?.newText == "b\nc")
    #expect(result?.lineCount == 2)
}

@Test("removeAllDuplicatedLines bei lauter einmaligen Zeilen liefert nil (No-Op)")
func removeAll_allUnique() {
    #expect(LineOperations.removeAllDuplicatedLines(in: "a\nb\nc", selection: whole) == nil)
}

@Test("removeAllDuplicatedLines wenn alles dupliziert ist liefert nil (Leer-Guard)")
func removeAll_everythingDuplicated() {
    // „a" und „b" je doppelt → nichts einmalig → Ergebnis wäre leer → nil
    // (ein Menü-Klick darf das Dokument nicht leerräumen).
    #expect(LineOperations.removeAllDuplicatedLines(in: "a\nb\na\nb", selection: whole) == nil)
}

@Test("removeAllDuplicatedLines mit nur einer Zeile liefert nil")
func removeAll_singleLine() {
    #expect(LineOperations.removeAllDuplicatedLines(in: "einzeiler", selection: whole) == nil)
}

@Test("removeAllDuplicatedLines wirkt nur im selektierten Bereich")
func removeAll_selectionOnly() {
    // „a" doppelt INNERHALB der Selektion; ein weiteres „a" außerhalb bleibt unangetastet.
    let text = "a\nb\na\nc\na"
    // Selektion über die ersten vier Zeilen „a\nb\na\nc" = {0,7}.
    let result = LineOperations.removeAllDuplicatedLines(in: text,
                                                         selection: NSRange(location: 0, length: 7))
    // Innerhalb: a(×2) raus, b und c bleiben. Zeile 5 (das dritte „a") bleibt außerhalb.
    #expect(result?.newText == "b\nc\na")
}

@Test("removeAllDuplicatedLines erhält das Datei-End-Newline (Phantom-Leerzeile)")
func removeAll_trailingNewline() {
    // „a" doppelt → weg; „b" einmalig → bleibt; abschließendes \n erhalten.
    let result = LineOperations.removeAllDuplicatedLines(in: "a\nb\na\n",
                                                         selection: whole)
    #expect(result?.newText == "b\n")
}

@Test("removeAllDuplicatedLines erhält den CRLF-Trenner")
func removeAll_crlf() {
    let result = LineOperations.removeAllDuplicatedLines(in: "a\r\nb\r\na\r\nc",
                                                         selection: whole)
    #expect(result?.newText == "b\r\nc")
}

@Test("removeAllDuplicatedLines: doppelte echte Leerzeile fliegt raus, Phantom zählt nicht mit")
func removeAll_blankDuplicateVsPhantom() {
    // Echte Zeilen: "a", "", "b", "" → leere Zeile kommt zweimal echt vor (Dublette) → weg;
    // „a" und „b" einmalig → bleiben. Phantom-Leerzeile (Datei-End-Newline) bleibt erhalten.
    let text = "a\n\nb\n\n"   // splitLines → ["a", "", "b", "", ""]; letztes "" = Phantom.
    let result = LineOperations.removeAllDuplicatedLines(in: text, selection: whole)
    // Übrig: "a", "b" + erhaltene Phantom-Leerzeile → "a\nb\n".
    #expect(result?.newText == "a\nb\n")
    #expect(result?.lineCount == 2)
}

@Test("removeAllDuplicatedLines unterscheidet exakt (Groß/Klein, Whitespace)")
func removeAll_exactComparison() {
    // Nur das exakt doppelte „a" ist Dublette; „A" und „a " unterscheiden sich.
    let text = "a\nA\na\na "
    let result = LineOperations.removeAllDuplicatedLines(in: text, selection: whole)
    // „a" (×2) raus; „A" und „a " einmalig → bleiben.
    #expect(result?.newText == "A\na ")
}
