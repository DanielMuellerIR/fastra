import Testing
import Foundation
@testable import Fastra

// Tests für TextOperations.hardWrap — "Hard Wrap" (BBEdit Kap. 5). Pur, UI-frei:
// (Text, Selektion, Spaltenbreite) rein → kompletter neuer Text raus, oder
// nil = nichts zu tun. Greedy-Wort-Umbruch auf eine feste Spaltenzahl (Grapheme).

private let whole = NSRange(location: 0, length: 0)   // leere Selektion = ganze Datei

// MARK: - Kein-Umbruch-Fälle

@Test("hardWrap: kurze Zeile bleibt unverändert → nil")
func wrap_shortUnchanged() {
    // "abc def" (7 Zeichen) passt locker in 20 Spalten → nichts zu tun.
    #expect(TextOperations.hardWrap(in: "abc def", selection: whole, column: 20) == nil)
}

@Test("hardWrap: Zeile exakt an der Spaltengrenze wird NICHT umgebrochen")
func wrap_exactBoundary() {
    // "abcde" hat genau 5 Zeichen; bei column 5 ist die Bedingung `count > width`
    // nicht erfüllt → keine Änderung → nil.
    #expect(TextOperations.hardWrap(in: "abcde", selection: whole, column: 5) == nil)
}

@Test("hardWrap: column <= 0 → nil")
func wrap_nonPositiveColumn() {
    #expect(TextOperations.hardWrap(in: "irgendein langer text hier", selection: whole, column: 0) == nil)
    #expect(TextOperations.hardWrap(in: "irgendein langer text hier", selection: whole, column: -3) == nil)
}

// MARK: - Grundlegender Umbruch

@Test("hardWrap: langer Satz wird so umgebrochen, dass jede Zeile <= column ist")
func wrap_longSentence() {
    // "the quick brown fox" mit column 9:
    //   "the quick" (9) | "brown fox" (9)
    let r = TextOperations.hardWrap(in: "the quick brown fox", selection: whole, column: 9)
    #expect(r?.newText == "the quick\nbrown fox")
}

@Test("hardWrap: KEINE Ausgabezeile überschreitet die Spaltenbreite (Invariante)")
func wrap_invariantEveryLineWithinColumn() {
    let column = 12
    // Solange KEIN Wort (ggf. samt Einrückung) für sich breiter als column ist, MUSS jede
    // Ausgabezeile <= column bleiben — das ist die Kern-Garantie des Hard Wrap. Geprüft über
    // mehrere Eingaben, inkl. einer EINGERÜCKTEN (stresst die reduzierte Erste-Zeilen-Budget-
    // Rechnung `avail = column - leadingWS.count`):
    let inputs = [
        // (a) ohne Einrückung, gemischte Wortlängen.
        "alpha beta gamma delta epsilon zeta eta theta iota kappa",
        // (b) mit 2 Leerzeichen Einrückung; alle Wörter sind kurz genug (≤ 2), dass auch die
        //     erste Zeile (Budget 12-2 = 10) die Grenze hält → Invariante muss greifen.
        "  al be ga de ep ze et th io ka mu nu xi om pi",
        // (c) mehrere eingerückte Eingabezeilen, jede unabhängig umgebrochen.
        "   one two three four five six\n      a b c d e f g h i j k l",
    ]
    for text in inputs {
        guard let out = TextOperations.hardWrap(in: text, selection: whole, column: column)?.newText
        else { continue }   // (sollte hier nie nil sein, aber defensiv)
        // Jede einzelne Ausgabezeile prüfen: ihre Grapheme-Anzahl muss <= column sein.
        for line in out.components(separatedBy: "\n") {
            #expect(line.count <= column, "Zeile überschreitet column: \"\(line)\" (\(line.count) > \(column))")
        }
    }
}

@Test("hardWrap: bricht nur an Wortgrenzen, kein Wort wird zerschnitten")
func wrap_noWordSplit() {
    // "hello wonderful" mit column 10: "hello" (5) + 1 + "wonderful" (9) = 15 > 10,
    // also Umbruch zwischen den Wörtern, nie mitten in "wonderful".
    let r = TextOperations.hardWrap(in: "hello wonderful", selection: whole, column: 10)
    #expect(r?.newText == "hello\nwonderful")
}

// MARK: - Überlanges Einzelwort

@Test("hardWrap: ein einzelnes Wort länger als column bleibt ungebrochen auf eigener Zeile")
func wrap_singleLongWordUnbroken() {
    // "supercalifragilistic" (20 Zeichen) bei column 8: BBEdit zerschneidet keine
    // Wörter → das Wort bleibt ganz, auf seiner eigenen Zeile. Da nur EIN Wort, das
    // ohnehin schon allein steht, ändert sich nichts → nil.
    #expect(TextOperations.hardWrap(in: "supercalifragilistic", selection: whole, column: 8) == nil)
}

@Test("hardWrap: überlanges Wort steht ungebrochen, normale Wörter daneben werden umbrochen")
func wrap_longWordAmongNormal() {
    // "ab supercalifragilistic cd" mit column 8:
    //   "ab" (current) → "supercalifragilistic" passt nicht (current 2 + 1 + 20 = 23 > 8)
    //     → out=["ab"], current="supercalifragilistic"
    //   "cd": current 20 + 1 + 2 = 23 > 8 → out=["ab","supercalifragilistic"], current="cd"
    //   Ende: out=["ab","supercalifragilistic","cd"]
    let r = TextOperations.hardWrap(in: "ab supercalifragilistic cd", selection: whole, column: 8)
    #expect(r?.newText == "ab\nsupercalifragilistic\ncd")
}

// MARK: - Einrückung

@Test("hardWrap: führende Einrückung bleibt an der ersten Zeile, Folgezeilen ohne Einrückung")
func wrap_indentationFirstLineOnly() {
    // "    one two three" (4 Leerzeichen Einrückung) mit column 6:
    //   leadingWS = "    " (4), body = "one two three", words = [one,two,three]
    //   erste Zeile hat avail = 6-4 = 2:
    //     "one" (current) → "two": current 3 + 1 + 3 = 7 > 2 → out=["one"], current="two"
    //   ab jetzt avail = 6 (Folgezeile):
    //     "three": current 3 + 1 + 5 = 9 > 6 → out=["one","two"], current="three"
    //   Ende: out=["one","two","three"], out[0] = "    one"
    let r = TextOperations.hardWrap(in: "    one two three", selection: whole, column: 6)
    #expect(r?.newText == "    one\ntwo\nthree")
}

// MARK: - Whitespace-Normalisierung

@Test("hardWrap: mehrfacher Whitespace zwischen Wörtern wird zu EINEM Leerzeichen")
func wrap_collapsesInterwordWhitespace() {
    // "foo     bar" (5 Leerzeichen) mit column 9: foo(3)+1+bar(3)=7 <= 9 → eine Zeile,
    // aber der Mehrfach-Whitespace kollabiert zu einem Leerzeichen → "foo bar".
    let r = TextOperations.hardWrap(in: "foo     bar", selection: whole, column: 9)
    #expect(r?.newText == "foo bar")
}

// MARK: - Mehrere Eingabezeilen

@Test("hardWrap: jede Eingabezeile wird unabhängig umgebrochen")
func wrap_multipleLinesIndependently() {
    // Zwei Zeilen, column 9:
    //   "the quick brown fox" → "the quick" | "brown fox"
    //   "lazy dog jumps"      → "lazy dog" (8) | "jumps" (5)
    let text = "the quick brown fox\nlazy dog jumps"
    let r = TextOperations.hardWrap(in: text, selection: whole, column: 9)
    #expect(r?.newText == "the quick\nbrown fox\nlazy dog\njumps")
}

@Test("hardWrap: leere Zeilen / Absatztrenner bleiben erhalten")
func wrap_blankLinesPreserved() {
    // Eine leere Zeile zwischen zwei (umzubrechenden) Absätzen bleibt als
    // Absatztrenner stehen.
    let text = "the quick brown\n\nlazy dog runs"
    let r = TextOperations.hardWrap(in: text, selection: whole, column: 9)
    // "the quick" | "brown" | (leer) | "lazy dog" | "runs"
    #expect(r?.newText == "the quick\nbrown\n\nlazy dog\nruns")
}

// MARK: - Datei-End-Newline / CRLF

@Test("hardWrap: abschließendes Datei-End-Newline bleibt erhalten")
func wrap_trailingNewlinePreserved() {
    // Ganz-Text-Fall mit abschließendem \n: die Phantom-Leerzeile darf nicht
    // verloren gehen oder eine eigene Umbruchzeile erzeugen.
    let r = TextOperations.hardWrap(in: "the quick brown fox\n", selection: whole, column: 9)
    #expect(r?.newText == "the quick\nbrown fox\n")
}

@Test("hardWrap: CRLF-Trenner bleibt erhalten")
func wrap_crlfPreserved() {
    // CRLF-Eingabe → der wiederzusammengebaute Block nutzt ebenfalls CRLF.
    let r = TextOperations.hardWrap(in: "the quick brown fox", selection: whole, column: 9)
    #expect(r?.newText == "the quick\nbrown fox")
    // Und mit explizitem CRLF im Text:
    let crlf = TextOperations.hardWrap(in: "the quick brown fox\r\nlazy dog ok", selection: whole, column: 9)
    #expect(crlf?.newText == "the quick\r\nbrown fox\r\nlazy dog\r\nok")
}

// MARK: - Teil-Selektion

@Test("hardWrap: Teil-Selektion bricht nur die selektierten Zeilen um")
func wrap_partialSelection() {
    // Drei Zeilen; nur die mittlere (lang) selektieren → nur die wird umgebrochen.
    let text = "kurz\nthe quick brown fox\nauch kurz"
    // Zeile 2 beginnt bei UTF-16-Offset 5 ("kurz\n"), Länge 19 ("the quick brown fox").
    // Eine Position mitten drin reicht — expandToFullLines weitet auf die ganze Zeile aus.
    let r = TextOperations.hardWrap(in: text, selection: NSRange(location: 10, length: 1), column: 9)
    #expect(r?.newText == "kurz\nthe quick\nbrown fox\nauch kurz")
}
