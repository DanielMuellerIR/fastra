import Testing
import Foundation
@testable import Fastra

// Tests für die Unicode-Gruppe der TextOperations (BBEdit Kap. 5):
// normalizeSpaces / stripDiacriticals / precomposeUnicode / decomposeUnicode.
// Pur, UI-frei — gleiche Konvention wie TextOperationsTests.

private let whole = NSRange(location: 0, length: 0)   // leere Selektion = ganze Datei

// MARK: - normalizeSpaces (Unicode-Leerzeichen → ASCII-Space)

@Test("normalizeSpaces: NBSP (U+00A0) wird zum normalen Leerzeichen")
func spaces_nbsp() {
    #expect(TextOperations.normalizeSpaces(in: "a\u{00A0}b", selection: whole)?.newText == "a b")
}

@Test("normalizeSpaces: Em-Space (U+2003) und Thin Space (U+2009) werden zum Leerzeichen")
func spaces_typographic() {
    #expect(TextOperations.normalizeSpaces(in: "a\u{2003}b\u{2009}c", selection: whole)?.newText == "a b c")
}

@Test("normalizeSpaces: ideographisches Leerzeichen (U+3000, CJK) wird zum Leerzeichen")
func spaces_ideographic() {
    #expect(TextOperations.normalizeSpaces(in: "漢\u{3000}字", selection: whole)?.newText == "漢 字")
}

@Test("normalizeSpaces: schmales geschütztes (U+202F) und mathematisches (U+205F) Leerzeichen")
func spaces_narrowAndMath() {
    #expect(TextOperations.normalizeSpaces(in: "1\u{202F}000\u{205F}x", selection: whole)?.newText == "1 000 x")
}

@Test("normalizeSpaces: Tab und Zeilenumbruch bleiben unangetastet")
func spaces_structuralUntouched() {
    // Nur das NBSP ändert sich; Tab/LF sind keine Zs-Zeichen und bleiben.
    let text = "a\tb\nc\u{00A0}d"
    #expect(TextOperations.normalizeSpaces(in: text, selection: whole)?.newText == "a\tb\nc d")
}

@Test("normalizeSpaces: nur normale Leerzeichen → nil (nichts zu tun)")
func spaces_noChange() {
    #expect(TextOperations.normalizeSpaces(in: "a b c", selection: whole) == nil)
}

@Test("normalizeSpaces: wirkt nur auf die Selektion")
func spaces_selectionOnly() {
    // "a<NBSP>b<NBSP>c" — nur die ersten 3 UTF-16-Einheiten (a + NBSP + b)
    // selektiert: das zweite NBSP bleibt geschützt.
    let text = "a\u{00A0}b\u{00A0}c"
    let r = TextOperations.normalizeSpaces(in: text, selection: NSRange(location: 0, length: 3))
    #expect(r?.newText == "a b\u{00A0}c")
}

// MARK: - stripDiacriticals (Akzente entfernen)

@Test("stripDiacriticals: á/ç/É verlieren ihre Akzente, Großschreibung bleibt")
func diacritics_latin() {
    #expect(TextOperations.stripDiacriticals(in: "áçÉñ", selection: whole)?.newText == "acEn")
}

@Test("stripDiacriticals: deutscher Umlaut ü → u (BBEdit-Verhalten, NICHT ue)")
func diacritics_germanUmlaut() {
    #expect(TextOperations.stripDiacriticals(in: "Müller über", selection: whole)?.newText == "Muller uber")
}

@Test("stripDiacriticals: Emoji und akzentfreier Text bleiben unverändert → nil")
func diacritics_noChange() {
    // Kein Diakritikum enthalten → die Operation ist ein No-Op und liefert nil.
    #expect(TextOperations.stripDiacriticals(in: "abc 😀 xyz", selection: whole) == nil)
}

@Test("stripDiacriticals: wirkt auch auf dekomponierte Form (e + Combining Acute)")
func diacritics_decomposedInput() {
    // "e" + U+0301 (kombinierender Akut) = dekomponiertes „é" → „e".
    #expect(TextOperations.stripDiacriticals(in: "e\u{0301}", selection: whole)?.newText == "e")
}

// MARK: - precomposeUnicode / decomposeUnicode (NFC / NFD)

@Test("precomposeUnicode: e + Combining Acute wird zum einen Zeichen é (NFC)")
func nfc_compose() {
    // Eingabe: 2 Scalars (U+0065 U+0301) → Ausgabe: 1 Scalar (U+00E9).
    let r = TextOperations.precomposeUnicode(in: "e\u{0301}", selection: whole)
    #expect(r?.newText == "\u{00E9}")
    #expect(r?.newText.unicodeScalars.count == 1)
}

@Test("decomposeUnicode: é (U+00E9) zerfällt in e + Combining Acute (NFD)")
func nfd_decompose() {
    let r = TextOperations.decomposeUnicode(in: "\u{00E9}", selection: whole)
    #expect(r?.newText == "e\u{0301}")
    #expect(r?.newText.unicodeScalars.count == 2)
}

@Test("NFC/NFD-Roundtrip: zerlegen und wieder zusammensetzen ergibt das Original")
func nfc_nfd_roundtrip() {
    let original = "\u{00E9}\u{00FC}"   // é ü (precomposed)
    // Erst zerlegen (NFD) …
    let decomposed = TextOperations.decomposeUnicode(in: original, selection: whole)?.newText
    #expect(decomposed == "e\u{0301}u\u{0308}")
    // … dann wieder zusammensetzen (NFC) → exakt das Original.
    let recomposed = TextOperations.precomposeUnicode(in: decomposed ?? "", selection: whole)?.newText
    #expect(recomposed == original)
}

@Test("precomposeUnicode: bereits komponierter Text → nil (nichts zu tun)")
func nfc_noChange() {
    #expect(TextOperations.precomposeUnicode(in: "abc \u{00E9}", selection: whole) == nil)
}

@Test("Unicode-Operationen: Leerstring → nil")
func unicode_emptyString() {
    #expect(TextOperations.normalizeSpaces(in: "", selection: whole) == nil)
    #expect(TextOperations.stripDiacriticals(in: "", selection: whole) == nil)
    #expect(TextOperations.precomposeUnicode(in: "", selection: whole) == nil)
    #expect(TextOperations.decomposeUnicode(in: "", selection: whole) == nil)
}
