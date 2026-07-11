import Testing
import Foundation
@testable import Fastra

// Tests für die BBEdit-„Text"-Basics (TextOperations). Pur, UI-frei:
// (Text, Selektion) rein → kompletter neuer Text raus, oder nil = nichts zu tun.

private let whole = NSRange(location: 0, length: 0)   // leere Selektion = ganze Datei

// MARK: - Groß-/Kleinschreibung

@Test("uppercase wirkt auf die Selektion, nicht auf den Rest")
func upper_selectionOnly() {
    let text = "hallo welt"
    // „hallo" selektieren (0..5).
    let r = TextOperations.uppercase(in: text, selection: NSRange(location: 0, length: 5))
    #expect(r?.newText == "HALLO welt")
}

@Test("lowercase ohne Selektion wirkt auf den ganzen Text")
func lower_wholeDoc() {
    #expect(TextOperations.lowercase(in: "Hallo WELT", selection: whole)?.newText == "hallo welt")
}

@Test("titlecase macht jeden Wortanfang groß")
func title_words() {
    #expect(TextOperations.titlecase(in: "max mustermann", selection: whole)?.newText == "Max Mustermann")
}

@Test("Groß/Klein ohne Änderung → nil")
func case_noChange() {
    #expect(TextOperations.uppercase(in: "ABC", selection: whole) == nil)
}

// MARK: - Whitespace

@Test("trimTrailingWhitespace entfernt Leerzeichen/Tabs am Zeilenende")
func trim_trailing() {
    let text = "abc   \ndef\t\nghi"
    #expect(TextOperations.trimTrailingWhitespace(in: text, selection: whole)?.newText == "abc\ndef\nghi")
}

@Test("trim: nichts zu trimmen → nil")
func trim_noChange() {
    #expect(TextOperations.trimTrailingWhitespace(in: "abc\ndef", selection: whole) == nil)
}

@Test("detab: Tab füllt bis zur nächsten Tab-Stopp-Spalte (Weite 4)")
func detab_tabStops() {
    // "a\tb" → 'a'(Spalte1), Tab füllt 3 Leerzeichen bis Spalte 4 → "a   b"
    #expect(TextOperations.detab(in: "a\tb", selection: whole)?.newText == "a   b")
    // Tab am Anfang → 4 Leerzeichen
    #expect(TextOperations.detab(in: "\tx", selection: whole)?.newText == "    x")
}

@Test("entab: Leerzeichen zu Tab-Stopp werden zu Tab")
func entab_tabStops() {
    #expect(TextOperations.entab(in: "a   b", selection: whole)?.newText == "a\tb")
    #expect(TextOperations.entab(in: "    x", selection: whole)?.newText == "\tx")
}

@Test("entab/detab sind zueinander invers bei tab-stopp-ausgerichtetem Text")
func entab_detab_roundtrip() {
    let tabbed = "\tfoo\tbar"
    let spaced = TextOperations.detab(in: tabbed, selection: whole)!.newText
    #expect(TextOperations.entab(in: spaced, selection: whole)?.newText == tabbed)
}

// MARK: - Ein-/Ausrücken

@Test("shiftRight stellt jeder Zeile einen Tab voran")
func shift_right() {
    #expect(TextOperations.shiftRight(in: "a\nb", selection: whole)?.newText == "\ta\n\tb")
}

@Test("shiftLeft entfernt führenden Tab oder bis zu tabWidth Leerzeichen")
func shift_left() {
    #expect(TextOperations.shiftLeft(in: "\ta\n    b\n  c", selection: whole)?.newText == "a\nb\nc")
}

@Test("shiftLeft ohne führenden Whitespace → nil")
func shift_left_noChange() {
    #expect(TextOperations.shiftLeft(in: "a\nb", selection: whole) == nil)
}

// MARK: - Zeilen-Ops

@Test("reverseLines kehrt die Reihenfolge um")
func reverse_lines() {
    #expect(TextOperations.reverseLines(in: "1\n2\n3", selection: whole)?.newText == "3\n2\n1")
}

@Test("reverseLines mit einer Zeile → nil")
func reverse_single() {
    #expect(TextOperations.reverseLines(in: "nur eine", selection: whole) == nil)
}

@Test("removeBlankLines entfernt leere und Whitespace-Zeilen")
func remove_blanks() {
    #expect(TextOperations.removeBlankLines(in: "a\n\nb\n   \nc", selection: whole)?.newText == "a\nb\nc")
}

@Test("prefixLines stellt jeder Zeile den Präfix voran")
func prefix_lines() {
    #expect(TextOperations.prefixLines(in: "a\nb", selection: whole, with: "> ")?.newText == "> a\n> b")
}

@Test("suffixLines hängt jeder Zeile den Suffix an")
func suffix_lines() {
    #expect(TextOperations.suffixLines(in: "a\nb", selection: whole, with: ";")?.newText == "a;\nb;")
}

@Test("prefix/suffix mit leerem Argument → nil")
func affix_empty() {
    #expect(TextOperations.prefixLines(in: "a", selection: whole, with: "") == nil)
    #expect(TextOperations.suffixLines(in: "a", selection: whole, with: "") == nil)
}

// MARK: - CRLF-Robustheit

@Test("CRLF-Trenner bleibt bei Zeilen-Ops erhalten")
func crlf_preserved() {
    let text = "b\r\na\r\nc"
    let r = TextOperations.reverseLines(in: text, selection: whole)
    #expect(r?.newText == "c\r\na\r\nb")
}

// MARK: - Selektion auf ganze Zeilen ausgeweitet

@Test("Zeilen-Op weitet eine Teil-Selektion auf ganze Zeilen aus")
func line_op_expands_selection() {
    let text = "alpha\nbeta\ngamma"
    // Selektion mitten in „beta" (Position 7, Länge 1) → ganze Zeile 2.
    let r = TextOperations.shiftRight(in: text, selection: NSRange(location: 7, length: 1))
    #expect(r?.newText == "alpha\n\tbeta\ngamma")
}

// MARK: - Zap Gremlins (Steuerzeichen entfernen)

@Test("zapGremlins entfernt NUL und sonstige Steuerzeichen")
func zap_removesControls() {
    // BEL (0x07), NUL (0x00), ESC (0x1B), DEL (0x7F) zwischen sichtbaren Zeichen.
    let text = "a\u{0007}b\u{0000}c\u{001B}d\u{007F}e"
    #expect(TextOperations.zapGremlins(in: text, selection: whole)?.newText == "abcde")
}

@Test("zapGremlins BEHÄLT Tab, Zeilenumbruch und Wagenrücklauf")
func zap_keepsStructural() {
    let text = "a\tb\nc\r\nd"
    // Nichts zu tun → nil (Tab/LF/CR sind keine Gremlins).
    #expect(TextOperations.zapGremlins(in: text, selection: whole) == nil)
}

@Test("zapGremlins lässt Emoji (Surrogatpaar) unversehrt")
func zap_keepsEmoji() {
    let text = "x\u{0000}😀y"
    #expect(TextOperations.zapGremlins(in: text, selection: whole)?.newText == "x😀y")
}

@Test("zapGremlins ohne Gremlins → nil")
func zap_noChange() {
    #expect(TextOperations.zapGremlins(in: "saubere Zeile", selection: whole) == nil)
}

// MARK: - Straighten Quotes (Anführungszeichen gerade richten)

@Test("straightenQuotes wandelt geschwungene doppelte und einfache Quotes")
func straighten_basic() {
    // “ ” → "   und   ‘ ’ → '
    let text = "\u{201C}Hallo\u{201D} und \u{2018}Welt\u{2019}"
    #expect(TextOperations.straightenQuotes(in: text, selection: whole)?.newText == "\"Hallo\" und 'Welt'")
}

@Test("straightenQuotes deckt deutsche Anführungszeichen ab")
func straighten_german() {
    // „ … " (U+201E … U+201C) und ‚ … ' (U+201A … U+2019)
    let text = "\u{201E}Tag\u{201C} \u{201A}x\u{2019}"
    #expect(TextOperations.straightenQuotes(in: text, selection: whole)?.newText == "\"Tag\" 'x'")
}

@Test("straightenQuotes ohne geschwungene Quotes → nil")
func straighten_noChange() {
    #expect(TextOperations.straightenQuotes(in: "\"schon\" 'gerade'", selection: whole) == nil)
}

// MARK: - Zeilen verbinden (Join Lines)

@Test("joinLines mit Leerzeichen zieht Zeilen zu einer zusammen")
func join_withSpace() {
    #expect(TextOperations.joinLines(in: "eins\nzwei\ndrei", selection: whole)?.newText == "eins zwei drei")
}

@Test("joinLines ohne Trenner verbindet direkt (Daten-Spalte)")
func join_tight() {
    let r = TextOperations.joinLines(in: "12\n34\n56", selection: whole, separator: "")
    #expect(r?.newText == "123456")
}

@Test("joinLines schluckt das Datei-End-Newline (kein Trenner am Ende)")
func join_trailingNewline() {
    // Ganz-Text-Fall mit abschließendem \n → kein „a b c " mit Schluss-Leerzeichen.
    #expect(TextOperations.joinLines(in: "a\nb\nc\n", selection: whole)?.newText == "a b c")
}

@Test("joinLines bei nur einer Zeile → nil")
func join_singleLine() {
    #expect(TextOperations.joinLines(in: "allein\n", selection: whole) == nil)
}

@Test("joinLines verbindet nur die selektierten Zeilen")
func join_selectionOnly() {
    let text = "a\nb\nc"
    // Selektion über „a\nb" (0..3) → nur diese zwei verbinden, „c" bleibt.
    let r = TextOperations.joinLines(in: text, selection: NSRange(location: 0, length: 3))
    #expect(r?.newText == "a b\nc")
}

@Test("joinLines CRLF-Eingabe erzeugt kein verirrtes \\r")
func join_crlf() {
    #expect(TextOperations.joinLines(in: "a\r\nb\r\nc", selection: whole)?.newText == "a b c")
}

// MARK: - Educate Quotes (Anführungszeichen geschwungen machen)

@Test("educateQuotes öffnet am Zeilen-/Textanfang, schließt nach einem Wort")
func educate_openClose() {
    // " am Textanfang → öffnend U+201C; nach „Hallo" → schließend U+201D.
    let text = "\"Hallo\""
    #expect(TextOperations.educateQuotes(in: text, selection: whole)?.newText
            == "\u{201C}Hallo\u{201D}")
}

@Test("educateQuotes: einfache Quotes öffnend/schließend nach Kontext")
func educate_singleOpenClose() {
    let text = "'Welt'"
    #expect(TextOperations.educateQuotes(in: text, selection: whole)?.newText
            == "\u{2018}Welt\u{2019}")
}

@Test("educateQuotes macht Apostroph in don't/it's zu U+2019")
func educate_apostrophe() {
    // Vor dem ' steht jeweils ein Buchstabe → schließend = typografischer Apostroph.
    #expect(TextOperations.educateQuotes(in: "don't", selection: whole)?.newText
            == "don\u{2019}t")
    #expect(TextOperations.educateQuotes(in: "it's", selection: whole)?.newText
            == "it\u{2019}s")
}

@Test("educateQuotes: öffnende Klammer davor → öffnendes Quote")
func educate_afterBracket() {
    // Nach '(' soll " öffnend werden.
    let text = "(\"x\")"
    #expect(TextOperations.educateQuotes(in: text, selection: whole)?.newText
            == "(\u{201C}x\u{201D})")
}

@Test("educateQuotes verschachtelt: 'single \"double\"'")
func educate_nested() {
    // ' am Anfang → öffnend; " nach Space → öffnend; " nach „double" → schließend;
    // ' am Ende nach " → schließend (Apostroph-Regel).
    let text = "'single \"double\"'"
    #expect(TextOperations.educateQuotes(in: text, selection: whole)?.newText
            == "\u{2018}single \u{201C}double\u{201D}\u{2019}")
}

@Test("educateQuotes ohne gerade Quotes → nil")
func educate_noChange() {
    #expect(TextOperations.educateQuotes(in: "kein Zitat hier", selection: whole) == nil)
}

@Test("educateQuotes wirkt nur auf die Selektion und nutzt das Zeichen davor")
func educate_selectionOnly() {
    // Text: word "x"  — selektiere nur das erste Quote (Position 5, Länge 1).
    // Davor steht ein Leerzeichen → öffnend; das zweite Quote bleibt gerade.
    let text = "word \"x\""
    let r = TextOperations.educateQuotes(in: text, selection: NSRange(location: 5, length: 1))
    #expect(r?.newText == "word \u{201C}x\"")
}

@Test("educateQuotes: Apostroph als erstes Selektions-Zeichen schaut über die Selektion hinaus")
func educate_selectionPeeksLeft() {
    // „don't": selektiere nur das ' (Position 3, Länge 1). Davor (außerhalb der
    // Selektion) steht 'n' → schließend U+2019, nicht öffnend.
    let text = "don't"
    let r = TextOperations.educateQuotes(in: text, selection: NSRange(location: 3, length: 1))
    #expect(r?.newText == "don\u{2019}t")
}

@Test("educateQuotes lässt Emoji (Surrogatpaar) unversehrt")
func educate_keepsEmoji() {
    // " direkt nach einem Emoji: davor kein Whitespace → schließend; Emoji bleibt.
    let text = "😀\"x\""
    #expect(TextOperations.educateQuotes(in: text, selection: whole)?.newText
            == "😀\u{201D}x\u{201D}")
}

// MARK: - Exchange Characters (Zeichen tauschen)

@Test("exchangeCharacters mitten in der Zeile tauscht links/rechts vom Cursor")
func exchar_mid() {
    // "abcd", Cursor zwischen b und c (Position 2) → b und c tauschen → "acbd".
    let r = TextOperations.exchangeCharacters(in: "abcd", selection: NSRange(location: 2, length: 0))
    #expect(r?.newText == "acbd")
}

@Test("exchangeCharacters am Zeilenanfang tauscht die beiden folgenden Zeichen")
func exchar_lineStart() {
    // Cursor bei 0 → die beiden ersten Zeichen a,b tauschen → "bacd".
    #expect(TextOperations.exchangeCharacters(in: "abcd", selection: NSRange(location: 0, length: 0))?.newText == "bacd")
}

@Test("exchangeCharacters am Zeilenende tauscht die beiden letzten Zeichen")
func exchar_lineEnd() {
    // Cursor bei 4 (Dokumentende) → die beiden letzten Zeichen c,d tauschen → "abdc".
    #expect(TextOperations.exchangeCharacters(in: "abcd", selection: NSRange(location: 4, length: 0))?.newText == "abdc")
}

@Test("exchangeCharacters mit Selektion tauscht erstes und letztes Zeichen")
func exchar_selection() {
    // "abcd", Selektion „bcd" (1..3) → erstes (b) und letztes (d) tauschen → "adcb".
    let r = TextOperations.exchangeCharacters(in: "abcd", selection: NSRange(location: 1, length: 3))
    #expect(r?.newText == "adcb")
}

@Test("exchangeCharacters bei nur einem Zeichen → nil")
func exchar_single() {
    #expect(TextOperations.exchangeCharacters(in: "a", selection: NSRange(location: 0, length: 0)) == nil)
    #expect(TextOperations.exchangeCharacters(in: "", selection: whole) == nil)
}

@Test("exchangeCharacters respektiert Zeilengrenzen (\\n)")
func exchar_lineBoundaries() {
    // "ab\ncd": Cursor bei 0 = Zeilenanfang → a,b tauschen → "ba\ncd".
    #expect(TextOperations.exchangeCharacters(in: "ab\ncd", selection: NSRange(location: 0, length: 0))?.newText == "ba\ncd")
    // Cursor bei 2 (direkt vor \n) = Zeilenende → die zwei davor (a,b) tauschen → "ba\ncd".
    #expect(TextOperations.exchangeCharacters(in: "ab\ncd", selection: NSRange(location: 2, length: 0))?.newText == "ba\ncd")
    // Cursor bei 3 (direkt hinter \n) = Anfang Zeile 2 → c,d tauschen → "ab\ndc".
    #expect(TextOperations.exchangeCharacters(in: "ab\ncd", selection: NSRange(location: 3, length: 0))?.newText == "ab\ndc")
}

@Test("exchangeCharacters auf leerer Zeile (Anfang==Ende) → nil")
func exchar_emptyLine() {
    // "ab\n\ncd": Cursor bei 3 sitzt auf der leeren Zeile → nichts zu tauschen.
    #expect(TextOperations.exchangeCharacters(in: "ab\n\ncd", selection: NSRange(location: 3, length: 0)) == nil)
}

@Test("exchangeCharacters hält Emoji (Surrogatpaar) zusammen")
func exchar_emojiSafe() {
    // "a😀b", Cursor zwischen a und 😀 (Position 1) → a und 😀 tauschen, ohne
    // das Surrogatpaar zu zerschneiden → "😀ab".
    let r = TextOperations.exchangeCharacters(in: "a😀b", selection: NSRange(location: 1, length: 0))
    #expect(r?.newText == "😀ab")
}

@Test("exchangeCharacters: Cursor mitten im Emoji → nil")
func exchar_caretInsideEmoji() {
    // Position 2 liegt mitten im Surrogatpaar von 😀 → keine Grapheme-Grenze → nil.
    #expect(TextOperations.exchangeCharacters(in: "a😀b", selection: NSRange(location: 2, length: 0)) == nil)
}

@Test("exchangeCharacters: zwei gleiche Nachbarn → nil (No-Op)")
func exchar_identicalNoChange() {
    // "aab", Cursor bei 1 → die beiden 'a' tauschen wäre folgenlos → nil.
    #expect(TextOperations.exchangeCharacters(in: "aab", selection: NSRange(location: 1, length: 0)) == nil)
}

// MARK: - Exchange Words (Wörter tauschen)

@Test("exchangeWords tauscht das Wort links und rechts vom Cursor")
func exword_mid() {
    // "foo bar", Cursor im Zwischenraum (Position 3) → foo,bar tauschen → "bar foo".
    let r = TextOperations.exchangeWords(in: "foo bar", selection: NSRange(location: 3, length: 0))
    #expect(r?.newText == "bar foo")
}

@Test("exchangeWords funktioniert auch bei Cursor innerhalb eines Wortes")
func exword_insideWord() {
    // "foo bar", Cursor in „foo" (Position 1): links=foo, rechts=bar → "bar foo".
    let r = TextOperations.exchangeWords(in: "foo bar", selection: NSRange(location: 1, length: 0))
    #expect(r?.newText == "bar foo")
}

@Test("exchangeWords: Cursor mitten im LETZTEN Wort tauscht mit dem Wort davor")
func exword_insideLastWord() {
    // "foo bar", Cursor bei 5 (innerhalb von „bar", kein Wort rechts) →
    // mit dem Vorgänger „foo" tauschen → "bar foo".
    #expect(TextOperations.exchangeWords(in: "foo bar", selection: NSRange(location: 5, length: 0))?.newText == "bar foo")
}

@Test("exchangeWords am Zeilenanfang tauscht die beiden folgenden Wörter")
func exword_lineStart() {
    // Cursor bei 0 → die ersten beiden Wörter foo,bar tauschen → "bar foo baz".
    #expect(TextOperations.exchangeWords(in: "foo bar baz", selection: NSRange(location: 0, length: 0))?.newText == "bar foo baz")
}

@Test("exchangeWords am Zeilenende tauscht die beiden letzten Wörter")
func exword_lineEnd() {
    // Cursor bei 11 (Dokumentende) → die letzten beiden Wörter bar,baz tauschen → "foo baz bar".
    #expect(TextOperations.exchangeWords(in: "foo bar baz", selection: NSRange(location: 11, length: 0))?.newText == "foo baz bar")
}

@Test("exchangeWords mit Selektion tauscht erstes und letztes Wort")
func exword_selection() {
    // Ganze Auswahl „foo bar baz" → erstes (foo) und letztes (baz) tauschen → "baz bar foo".
    let r = TextOperations.exchangeWords(in: "foo bar baz", selection: NSRange(location: 0, length: 11))
    #expect(r?.newText == "baz bar foo")
}

@Test("exchangeWords erhält die Trenner zwischen den Wörtern")
func exword_keepsSeparators() {
    // Komma+Leerzeichen zwischen den Wörtern bleibt stehen, nur die Wörter wechseln.
    let r = TextOperations.exchangeWords(in: "alpha, beta", selection: NSRange(location: 6, length: 0))
    #expect(r?.newText == "beta, alpha")
}

@Test("exchangeWords bei nur einem Wort → nil")
func exword_singleWord() {
    #expect(TextOperations.exchangeWords(in: "foo", selection: NSRange(location: 0, length: 0)) == nil)
    #expect(TextOperations.exchangeWords(in: "   ", selection: whole) == nil)
}

@Test("exchangeWords respektiert Zeilengrenzen")
func exword_lineBoundaries() {
    // "foo bar\nbaz qux": Cursor bei 0 = Zeilenanfang → nur foo,bar → "bar foo\nbaz qux".
    #expect(TextOperations.exchangeWords(in: "foo bar\nbaz qux", selection: NSRange(location: 0, length: 0))?.newText == "bar foo\nbaz qux")
}

@Test("exchangeWords am Zeilenanfang greift das nächste Wort auch über \\n (BBEdit-treu)")
func exword_startCrossesNewline() {
    // Manual: am Zeilenanfang „die beiden folgenden Wörter" — das nächste Wort
    // darf hinter einem \n liegen; der Zeilenumbruch dazwischen bleibt erhalten.
    #expect(TextOperations.exchangeWords(in: "foo\nbar", selection: NSRange(location: 0, length: 0))?.newText == "bar\nfoo")
}

// MARK: - Zeilennummern (Add / Remove Line Numbers)

@Test("addLineNumbers nummeriert relativ zum Block, Start 1")
func addnum_basic() {
    #expect(TextOperations.addLineNumbers(in: "a\nb\nc", selection: whole)?.newText == "1 a\n2 b\n3 c")
}

@Test("addLineNumbers richtet rechtsbündig an der 9→10-Grenze aus (Breite 2)")
func addnum_rightJustified() {
    // 12 Zeilen → Breite 2, einstellige Nummern bekommen ein führendes Leerzeichen.
    let text = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl"
    let want = " 1 a\n 2 b\n 3 c\n 4 d\n 5 e\n 6 f\n 7 g\n 8 h\n 9 i\n10 j\n11 k\n12 l"
    #expect(TextOperations.addLineNumbers(in: text, selection: whole)?.newText == want)
}

@Test("addLineNumbers bei einer einzelnen Zeile")
func addnum_single() {
    #expect(TextOperations.addLineNumbers(in: "solo", selection: whole)?.newText == "1 solo")
}

@Test("addLineNumbers schluckt das Datei-End-Newline (keine Nummer hinter dem Ende)")
func addnum_trailingNewline() {
    // Die Phantom-Leerzeile vom abschließenden \n bekommt keine Nummer.
    #expect(TextOperations.addLineNumbers(in: "a\nb\n", selection: whole)?.newText == "1 a\n2 b\n")
}

@Test("addLineNumbers nummeriert nur die selektierten Zeilen, relativ ab 1")
func addnum_selectionOnly() {
    let text = "alpha\nbeta\ngamma"
    // Selektion über „beta\ngamma" (ab Position 6) → diese zwei Zeilen, neu ab 1.
    let r = TextOperations.addLineNumbers(in: text, selection: NSRange(location: 6, length: 9))
    #expect(r?.newText == "alpha\n1 beta\n2 gamma")
}

@Test("addLineNumbers behält den CRLF-Trenner")
func addnum_crlf() {
    #expect(TextOperations.addLineNumbers(in: "a\r\nb\r\nc", selection: whole)?.newText == "1 a\r\n2 b\r\n3 c")
}

@Test("removeLineNumbers ist invers zu addLineNumbers (Roundtrip)")
func removenum_roundtrip() {
    let text = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl"   // 12 Zeilen, rechtsbündig nummeriert
    let numbered = TextOperations.addLineNumbers(in: text, selection: whole)!.newText
    #expect(TextOperations.removeLineNumbers(in: numbered, selection: whole)?.newText == text)
}

@Test("removeLineNumbers entfernt führende Leerzeichen + Ziffern + ein Leerzeichen")
func removenum_padded() {
    // Exakt das, was addLineNumbers für 12 Zeilen erzeugt — auch zweistellig.
    #expect(TextOperations.removeLineNumbers(in: " 9 i\n10 j", selection: whole)?.newText == "i\nj")
}

@Test("removeLineNumbers lässt Zeilen ohne führende Nummer unangetastet (partiell)")
func removenum_partial() {
    // Nur die nummerierten Zeilen werden gestrippt; „nackt" bleibt stehen.
    let text = "1 eins\nnackt\n2 zwei"
    #expect(TextOperations.removeLineNumbers(in: text, selection: whole)?.newText == "eins\nnackt\nzwei")
}

@Test("removeLineNumbers tolerant: Nummer ohne Trenner-Leerzeichen")
func removenum_noSeparator() {
    // Fremd-nummeriert „5x" → Ziffern weg, x bleibt.
    #expect(TextOperations.removeLineNumbers(in: "5x\n6y", selection: whole)?.newText == "x\ny")
}

@Test("removeLineNumbers ohne führende Nummern → nil")
func removenum_noChange() {
    #expect(TextOperations.removeLineNumbers(in: "kein\ntext\nnummeriert", selection: whole) == nil)
}

@Test("removeLineNumbers wirkt nur auf die selektierten Zeilen")
func removenum_selectionOnly() {
    let text = "1 a\n2 b\n3 c"
    // Selektion über die erste Zeile (0..3) → nur dort die Nummer entfernen.
    let r = TextOperations.removeLineNumbers(in: text, selection: NSRange(location: 0, length: 3))
    #expect(r?.newText == "a\n2 b\n3 c")
}

@Test("removeLineNumbers behält den CRLF-Trenner")
func removenum_crlf() {
    #expect(TextOperations.removeLineNumbers(in: "1 a\r\n2 b\r\n3 c", selection: whole)?.newText == "a\r\nb\r\nc")
}

// MARK: - Escape-Sequenzen auflösen (Convert Escape Sequences)

@Test("Backslash-Steuerzeichen: \\n \\r \\t \\f \\\\")
func esc_backslashControls() {
    #expect(TextOperations.convertEscapeSequences(in: "a\\nb", selection: whole)?.newText == "a\nb")
    #expect(TextOperations.convertEscapeSequences(in: "a\\rb", selection: whole)?.newText == "a\rb")
    #expect(TextOperations.convertEscapeSequences(in: "a\\tb", selection: whole)?.newText == "a\tb")
    #expect(TextOperations.convertEscapeSequences(in: "a\\fb", selection: whole)?.newText == "a\u{0C}b")
    // \\ → ein einzelner Backslash.
    #expect(TextOperations.convertEscapeSequences(in: "a\\\\b", selection: whole)?.newText == "a\\b")
}

@Test("Hex-Escape \\x41 → A und \\x{1F600} → 😀")
func esc_hex() {
    #expect(TextOperations.convertEscapeSequences(in: "\\x41", selection: whole)?.newText == "A")
    #expect(TextOperations.convertEscapeSequences(in: "\\x{1F600}", selection: whole)?.newText == "😀")
    // Geklammert mit nur einer Ziffer ist erlaubt: \x{9} → Tab.
    #expect(TextOperations.convertEscapeSequences(in: "\\x{9}", selection: whole)?.newText == "\t")
}

@Test("Unicode-Escape \\u0041 → A und \\u{1F600} → 😀")
func esc_unicode() {
    #expect(TextOperations.convertEscapeSequences(in: "\\u0041", selection: whole)?.newText == "A")
    #expect(TextOperations.convertEscapeSequences(in: "\\u{1F600}", selection: whole)?.newText == "😀")
}

@Test("HTML-Entities benannt: &amp; → & sowie deutsche Umlaute")
func esc_htmlNamed() {
    #expect(TextOperations.convertEscapeSequences(in: "a&amp;b", selection: whole)?.newText == "a&b")
    #expect(TextOperations.convertEscapeSequences(in: "&lt;&gt;", selection: whole)?.newText == "<>")
    #expect(TextOperations.convertEscapeSequences(in: "&auml;", selection: whole)?.newText == "ä")
    #expect(TextOperations.convertEscapeSequences(in: "&Uuml;&szlig;", selection: whole)?.newText == "Üß")
    #expect(TextOperations.convertEscapeSequences(in: "&copy;&euro;", selection: whole)?.newText == "©€")
}

@Test("HTML-Entities numerisch: &#65; und &#x41; → A")
func esc_htmlNumeric() {
    #expect(TextOperations.convertEscapeSequences(in: "&#65;", selection: whole)?.newText == "A")
    #expect(TextOperations.convertEscapeSequences(in: "&#x41;", selection: whole)?.newText == "A")
    // Großes X ebenfalls erlaubt, und ein Emoji per dezimaler Codepoint-Zahl.
    #expect(TextOperations.convertEscapeSequences(in: "&#X41;", selection: whole)?.newText == "A")
    #expect(TextOperations.convertEscapeSequences(in: "&#128512;", selection: whole)?.newText == "😀")
}

@Test("Prozent-Escapes: %20 → Leerzeichen, %C3%A4 → ä (Mehrbyte-UTF-8)")
func esc_percent() {
    #expect(TextOperations.convertEscapeSequences(in: "a%20b", selection: whole)?.newText == "a b")
    // ä ist in UTF-8 zwei Bytes (C3 A4) — beide %NN gemeinsam dekodieren.
    #expect(TextOperations.convertEscapeSequences(in: "%C3%A4", selection: whole)?.newText == "ä")
    // Längerer Lauf: „äö" = C3 A4 C3 B6.
    #expect(TextOperations.convertEscapeSequences(in: "%C3%A4%C3%B6", selection: whole)?.newText == "äö")
}

@Test("Gemischter String mit mehreren Klassen in einem Durchlauf")
func esc_mixed() {
    let input = "Tab:\\t Hex:\\x41 Uni:\\u0042 Ent:&amp; Num:&#67; Pct:%20END"
    let expected = "Tab:\t Hex:A Uni:B Ent:& Num:C Pct: END"
    #expect(TextOperations.convertEscapeSequences(in: input, selection: whole)?.newText == expected)
}

@Test("Malformte/unbekannte Sequenzen bleiben literal")
func esc_malformedLiteral() {
    // Unbekanntes Backslash-Escape, ungültige Hex-Ziffern, Bogus-Entity, Bad-Percent.
    #expect(TextOperations.convertEscapeSequences(in: "\\z", selection: whole) == nil)
    #expect(TextOperations.convertEscapeSequences(in: "\\xZZ", selection: whole) == nil)
    #expect(TextOperations.convertEscapeSequences(in: "&bogus;", selection: whole) == nil)
    #expect(TextOperations.convertEscapeSequences(in: "%ZZ", selection: whole) == nil)
    // Einsamer Backslash/Prozent/Ampersand ohne Sequenz bleibt stehen.
    #expect(TextOperations.convertEscapeSequences(in: "100%", selection: whole) == nil)
}

@Test("Ungültiger Skalarwert (Surrogat-Bereich) bleibt literal")
func esc_invalidScalar() {
    // U+D800 ist ein Surrogat-Codepoint → kein gültiger Unicode.Scalar.
    #expect(TextOperations.convertEscapeSequences(in: "\\u{D800}", selection: whole) == nil)
    #expect(TextOperations.convertEscapeSequences(in: "&#xD800;", selection: whole) == nil)
}

@Test("Keine Escape-Sequenzen → nil")
func esc_noChange() {
    #expect(TextOperations.convertEscapeSequences(in: "ganz normaler Text", selection: whole) == nil)
}

@Test("Escape-Auflösung wirkt nur auf die Selektion")
func esc_selectionOnly() {
    let text = "\\t und \\n"
    // Nur das erste „\\t" selektieren (Position 0, Länge 2).
    let r = TextOperations.convertEscapeSequences(in: text, selection: NSRange(location: 0, length: 2))
    #expect(r?.newText == "\t und \\n")
}
