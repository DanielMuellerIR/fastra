// BufferSearchTests.swift
//
// Sichert die reine Buffer-Suche ab (in-memory, ohne Datei-System).
// Diese Tests sind das Sicherheitsnetz, BEVOR die Maske die Demo-Daten
// gegen echte Suchergebnisse tauscht — sonst landet ein Off-by-one in der
// Zeilen-/Spalten-Berechnung still in der UI.

import Testing
import Foundation
@testable import Fastra

// MARK: - Leere Eingaben

@Test("Leerer Find-String liefert leeres Ergebnis (kein Pattern, keine Treffer)")
func empty_findReturnsEmpty() {
    let r = BufferSearch.find(in: "irgendwas\n", options: SearchOptions(find: "", replace: "x"))
    #expect(r.matches.isEmpty)
    #expect(r.invalidPatternMessage == nil)
}

@Test("Leerer Text liefert leeres Ergebnis ohne Fehler")
func empty_textReturnsEmpty() {
    let r = BufferSearch.find(in: "", options: SearchOptions(find: "foo", replace: "x"))
    #expect(r.matches.isEmpty)
    #expect(r.invalidPatternMessage == nil)
}

// MARK: - Treffer-Anzahl

@Test("find() zählt alle Treffer in mehrzeiligem Text")
func find_countsAcrossLines() {
    let text = "foo bar\nfoo baz\nqux foo\n"
    let r = BufferSearch.find(in: text,
                              options: SearchOptions(find: "foo", replace: "X",
                                                     isRegex: false, caseSensitive: true))
    #expect(r.matches.count == 3)
}

// MARK: - Zeile/Spalte (1-basiert)

@Test("Treffer in der ersten Zeile beginnt bei Zeile 1, Spalte 1")
func lineColumn_firstLineStartsAt1_1() {
    let r = BufferSearch.find(in: "foo bar\nbaz\n",
                              options: SearchOptions(find: "foo", replace: "X",
                                                     isRegex: false))
    let m = r.matches.first!
    #expect(m.line == 1)
    #expect(m.column == 1)
}

@Test("Treffer in zweiter Zeile, dritter Spalte")
func lineColumn_secondLineThirdColumn() {
    // Zeile 2, Spalte 3 = nach „ab" in „abXY"
    let r = BufferSearch.find(in: "ZZZ\nabFOO\n",
                              options: SearchOptions(find: "FOO", replace: "x",
                                                     isRegex: false, caseSensitive: true))
    let m = r.matches.first!
    #expect(m.line == 2)
    #expect(m.column == 3)
}

@Test("Treffer auf vielen Zeilen liegen alle in der richtigen Zeile")
func lineColumn_walksEntireBuffer() {
    let lines = (1...20).map { "z\($0) foo" }
    let text = lines.joined(separator: "\n") + "\n"
    let r = BufferSearch.find(in: text,
                              options: SearchOptions(find: "foo", replace: "X",
                                                     isRegex: false))
    #expect(r.matches.count == 20)
    for (i, m) in r.matches.enumerated() {
        #expect(m.line == i + 1, "Treffer \(i) in falscher Zeile")
    }
}

@Test("CRLF-Zeilenenden werden korrekt gezählt (LF bestimmt die Zeile)")
func lineColumn_handlesCRLF() {
    let r = BufferSearch.find(in: "eins\r\nzwei\r\nfoo\r\n",
                              options: SearchOptions(find: "foo", replace: "X",
                                                     isRegex: false))
    let m = r.matches.first!
    #expect(m.line == 3)
    #expect(m.column == 1)
}

@Test("Reine CR-Zeilenenden (klassisches Mac / 4D-Logs) werden als Zeilen gezählt")
func lineColumn_handlesLoneCR() {
    // Genau Daniels 4D-Log-Fall: nur \r als Trenner. Frühere LF-only-Logik
    // hätte alle Treffer fälschlich in Zeile 1 gemeldet.
    let r = BufferSearch.find(in: "zeile1\rzeile2\r14 uhr\r",
                              options: SearchOptions(find: "14", replace: "",
                                                     isRegex: false, caseSensitive: true))
    #expect(r.matches.count == 1)
    let m = r.matches.first!
    #expect(m.line == 3)        // dritte CR-Zeile, NICHT Zeile 1
    #expect(m.column == 1)
}

@Test("Gemischte Zeilenenden (CR + LF gemischt) zählen jeden Umbruch einzeln")
func lineColumn_handlesMixedCRandLF() {
    // a\rb\nc\r14 → 4 Zeilen: „a", „b", „c", „14".
    let r = BufferSearch.find(in: "a\rb\nc\r14",
                              options: SearchOptions(find: "14", replace: "",
                                                     isRegex: false, caseSensitive: true))
    let m = r.matches.first!
    #expect(m.line == 4)
    #expect(m.column == 1)
}

@Test("CR-Datei: zweiter Treffer in korrekter Folge-Zeile")
func lineColumn_loneCR_secondMatchLine() {
    // „14" in Zeile 2 UND Zeile 4 (nur \r) → korrekte, unterschiedliche Zeilen.
    let r = BufferSearch.find(in: "kopf\r14:00 start\rmitte\r14:30 ende\r",
                              options: SearchOptions(find: "14", replace: "",
                                                     isRegex: false, caseSensitive: true))
    #expect(r.matches.count == 2)
    #expect(r.matches[0].line == 2)
    #expect(r.matches[1].line == 4)
}

// MARK: - Replacement-Vorschau

@Test("Match.replacedText liefert den ersetzten Text inklusive $1-Backrefs")
func replaced_includesBackrefs() {
    let r = BufferSearch.find(in: "kunde@example.com\n",
                              options: SearchOptions(find: "([a-z]+)@([a-z]+)",
                                                     replace: "$1 AT $2",
                                                     isRegex: true))
    let m = r.matches.first!
    #expect(m.matchText == "kunde@example")
    #expect(m.replacedText == "kunde AT example")
}

// MARK: - Ungültige RegEx

@Test("Ungültige RegEx liefert invalidPatternMessage statt zu crashen")
func invalidPattern_returnsMessage() {
    let r = BufferSearch.find(in: "irgendwas",
                              options: SearchOptions(find: "(unbalanced",
                                                     replace: "x",
                                                     isRegex: true))
    #expect(r.matches.isEmpty)
    #expect(r.invalidPatternMessage != nil)
}

// MARK: - Plain-Text-Modus

@Test("Plain-Text-Modus interpretiert Meta-Zeichen literal")
func plain_escapesMeta() {
    let regex = BufferSearch.find(in: "kunde@example.com",
                                  options: SearchOptions(find: "k.nde", replace: "X",
                                                         isRegex: true))
    let plain = BufferSearch.find(in: "kunde@example.com",
                                  options: SearchOptions(find: "k.nde", replace: "X",
                                                         isRegex: false))
    #expect(regex.matches.count == 1)
    #expect(plain.matches.count == 0)
}

@Test("Plain-Text-Replace setzt $N literal ein (kein Backref)")
func plain_replaceDollarIsLiteral() {
    // RegEx aus → der Replace-String soll WÖRTLICH stehen, auch wenn er
    // wie ein Backref aussieht. Früher wurde „$0" als ganzer Treffer
    // und „$5" als (leerer) Gruppe-5-Backref interpretiert.
    let r = BufferSearch.find(in: "Preis: alt",
                              options: SearchOptions(find: "alt", replace: "$5.00",
                                                     isRegex: false, caseSensitive: true))
    #expect(r.matches.first?.replacedText == "$5.00")
}

@Test("Plain-Text-Replace setzt Backslash literal ein (keine Escape-Deutung)")
func plain_replaceBackslashIsLiteral() {
    // „\n" im Replace-Feld bei RegEx-aus bedeutet die zwei Zeichen
    // Backslash+n, KEINEN Zeilenumbruch.
    let r = BufferSearch.find(in: "pfad",
                              options: SearchOptions(find: "pfad", replace: "C:\\neu",
                                                     isRegex: false, caseSensitive: true))
    #expect(r.matches.first?.replacedText == "C:\\neu")
}

@Test("RegEx-Replace deutet $N weiterhin als Backref (Gegenprobe)")
func regex_replaceDollarStillBackref() {
    // Sicherstellen, dass der Fix den RegEx-Modus NICHT verändert.
    let r = BufferSearch.find(in: "ab",
                              options: SearchOptions(find: "(a)(b)", replace: "$2$1",
                                                     isRegex: true))
    #expect(r.matches.first?.replacedText == "ba")
}

// MARK: - Case-Sensitivity / Whole-Word (Wiederholung gegen Regression)

@Test("caseSensitive=false matched Groß-/Kleinschreibung")
func caseInsensitive_inBuffer() {
    let r = BufferSearch.find(in: "Foo FOO foo",
                              options: SearchOptions(find: "foo", replace: "X",
                                                     isRegex: false, caseSensitive: false))
    #expect(r.matches.count == 3)
}

@Test("wholeWord schließt Substring-Treffer aus")
func wholeWord_excludesSubstring() {
    let r = BufferSearch.find(in: "foo foobar foo",
                              options: SearchOptions(find: "foo", replace: "X",
                                                     isRegex: false, caseSensitive: true,
                                                     wholeWord: true))
    #expect(r.matches.count == 2)
}

// MARK: - applyReplacements (in-memory)

@Test("applyReplacements: leere Trefferliste → unveränderter Text")
func apply_emptyMatchesUnchanged() {
    let result = BufferSearch.applyReplacements(in: "hello world", matches: [])
    #expect(result == "hello world")
}

@Test("applyReplacements: einzelner Treffer in der Mitte")
func apply_singleMatch() {
    let text = "foo bar baz"
    let r = BufferSearch.find(in: text,
                              options: SearchOptions(find: "bar", replace: "BAR",
                                                     isRegex: false))
    let after = BufferSearch.applyReplacements(in: text, matches: r.matches)
    #expect(after == "foo BAR baz")
}

@Test("applyReplacements: mehrere Treffer inklusive Anfang und Ende")
func apply_multipleMatches() {
    let text = "foo bar foo bar foo"
    let r = BufferSearch.find(in: text,
                              options: SearchOptions(find: "foo", replace: "X",
                                                     isRegex: false))
    let after = BufferSearch.applyReplacements(in: text, matches: r.matches)
    #expect(after == "X bar X bar X")
}

@Test("applyReplacements: Capture-Backrefs aus match.replacedText")
func apply_backrefsHonored() {
    let text = "kunde@example.com"
    let r = BufferSearch.find(in: text,
                              options: SearchOptions(find: "([a-z]+)@([a-z]+)",
                                                     replace: "$1 AT $2",
                                                     isRegex: true))
    let after = BufferSearch.applyReplacements(in: text, matches: r.matches)
    #expect(after == "kunde AT example.com")
}

// Einzel-Ersetzen (Workspace.replaceActiveMatch) übergibt applyReplacements
// bewusst nur EINEN Treffer aus einer Liste mit mehreren. Dieser Test sichert
// die Grundlage ab: nur der ausgewählte Treffer ändert sich, die übrigen
// bleiben unangetastet.
@Test("applyReplacements: nur der ausgewählte Treffer wird ersetzt (Einzel-Ersetzen)")
func apply_singleOfManyMatches() {
    let text = "foo bar foo bar foo"
    let r = BufferSearch.find(in: text,
                              options: SearchOptions(find: "foo", replace: "X",
                                                     isRegex: false))
    #expect(r.matches.count == 3)
    // Nur den zweiten Treffer ersetzen — wie es replaceActiveMatch mit
    // activeMatchIndex == 1 täte.
    let after = BufferSearch.applyReplacements(in: text, matches: [r.matches[1]])
    #expect(after == "foo bar X bar foo")
}

// endLineColumn liefert die End-Position eines Treffers für den Editor-Sprung
// über Zeile/Spalte (statt absoluter Range — robust gegen Offset-Drift).
@Test("endLineColumn: einzeiliger Treffer → Endspalte = Start + UTF-16-Länge")
func endLineColumn_singleLine() {
    let end = BufferSearch.endLineColumn(startLine: 6, startColumn: 36, matchText: "Daniel")
    #expect(end.line == 6)
    #expect(end.column == 42)   // 36 + 6 (exklusives Ende)
}

@Test("endLineColumn: mehrzeiliger Treffer → Endzeile + Spalte ab letztem LF")
func endLineColumn_multiLine() {
    let end = BufferSearch.endLineColumn(startLine: 2, startColumn: 5, matchText: "ab\ncd")
    #expect(end.line == 3)
    #expect(end.column == 3)   // „cd" endet exklusiv bei Spalte 3
}

@Test("applyReplacements: idempotent, wenn Replacement nicht mehr matched")
func apply_idempotentAfterReplace() {
    let text = "foo foo foo"
    let r1 = BufferSearch.find(in: text,
                               options: SearchOptions(find: "foo", replace: "FOO",
                                                      isRegex: false, caseSensitive: true))
    let once = BufferSearch.applyReplacements(in: text, matches: r1.matches)
    // Erneute Suche mit demselben Pattern fängt nichts mehr (case-sensitive!)
    let r2 = BufferSearch.find(in: once,
                               options: SearchOptions(find: "foo", replace: "FOO",
                                                      isRegex: false, caseSensitive: true))
    #expect(r2.matches.isEmpty)
    let twice = BufferSearch.applyReplacements(in: once, matches: r2.matches)
    #expect(twice == once)
}

// MARK: - Cap & echte Gesamtzahl (Performance-Schutz, v0.10)

@Test("Cap: bei mehr Treffern als maxMatches wird gekürzt, Gesamtzahl bleibt ehrlich")
func cap_materializesAtMostMaxButCountsAll() {
    // 5000 Zeilen mit je einem „1" → 5000 Treffer.
    let text = String(repeating: "x1y\n", count: 5000)
    let r = BufferSearch.find(in: text,
                              options: SearchOptions(find: "1", replace: "",
                                                     isRegex: false, caseSensitive: true),
                              maxMatches: 100)
    #expect(r.matches.count == 100)        // nur 100 materialisiert
    #expect(r.totalMatches == 5000)        // aber alle gezählt
    #expect(r.wasCapped == true)
}

@Test("Kein Cap: wenn Treffer ≤ maxMatches, ist totalMatches == matches.count und nicht gekappt")
func cap_notTriggeredWhenWithinLimit() {
    let text = "a1b\nc1d\ne1f\n"   // 3 Treffer
    let r = BufferSearch.find(in: text,
                              options: SearchOptions(find: "1", replace: "",
                                                     isRegex: false, caseSensitive: true),
                              maxMatches: 100)
    #expect(r.matches.count == 3)
    #expect(r.totalMatches == 3)
    #expect(r.wasCapped == false)
}

@Test("Abbruch: shouldCancel == true liefert ein leeres Ergebnis")
func cancel_returnsEmpty() {
    let text = String(repeating: "z1z\n", count: 100)
    let r = BufferSearch.find(in: text,
                              options: SearchOptions(find: "1", replace: "",
                                                     isRegex: false, caseSensitive: true),
                              shouldCancel: { true })   // sofort abbrechen
    #expect(r.matches.isEmpty)
    #expect(r.totalMatches == 0)
    #expect(r.wasCapped == false)
}

// MARK: - replaceAll: cap-unabhängiges Voll-Replace

@Test("replaceAll ersetzt ALLE Treffer, auch jenseits des Listen-Caps")
func replaceAll_replacesBeyondCap() {
    // 3000 Treffer, Standard-Cap (2000) würde die Liste kürzen — replaceAll
    // darf trotzdem alle ersetzen.
    let text = String(repeating: "a1b\n", count: 3000)
    let opts = SearchOptions(find: "1", replace: "X", isRegex: false, caseSensitive: true)
    let capped = BufferSearch.find(in: text, options: opts)
    #expect(capped.wasCapped == true)          // Liste ist gekappt …
    let replaced = BufferSearch.replaceAll(in: text, options: opts)
    #expect(replaced != nil)
    // … aber im Ergebnis darf keine „1" mehr stehen.
    #expect(replaced?.contains("1") == false)
    #expect(replaced?.contains("X") == true)
}

@Test("replaceAll mit Capture-Backrefs")
func replaceAll_withBackrefs() {
    let text = "kunde@example.com\nfirma@test.org\n"
    let opts = SearchOptions(find: "(\\w+)@(\\w+)", replace: "$2.$1",
                             isRegex: true, caseSensitive: false)
    let replaced = BufferSearch.replaceAll(in: text, options: opts)
    #expect(replaced?.contains("example.kunde") == true)
    #expect(replaced?.contains("test.firma") == true)
}

@Test("replaceAll: leeres Pattern → nil (nichts ersetzen)")
func replaceAll_emptyPatternNil() {
    let r = BufferSearch.replaceAll(in: "egal", options: SearchOptions(find: "", replace: "x"))
    #expect(r == nil)
}
