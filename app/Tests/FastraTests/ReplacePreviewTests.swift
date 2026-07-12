import Testing
import Foundation
@testable import Fastra

// Tests für die Vorher/Nachher-Vorschau-Logik (ReplacePreview). Pur, ohne UI:
// echte BufferSearch-Treffer rein, geprüfte Vorher/Nachher-Zeilen raus.

private func matches(in text: String, find: String, replace: String,
                     isRegex: Bool = false) -> [BufferSearch.Match] {
    let opts = SearchOptions(find: find, replace: replace, isRegex: isRegex)
    return BufferSearch.find(in: text, options: opts).matches
}

@Test("Eine einfache Ersetzung → eine geänderte Zeile, before/after korrekt")
func preview_singleReplacement() {
    let text = "alpha\nbeta\ngamma"
    let m = matches(in: text, find: "beta", replace: "BETA")
    let r = ReplacePreview.build(text: text, matches: m)
    #expect(r.totalChangedLines == 1)
    #expect(r.rows.count == 1)
    #expect(r.rows.first?.line == 2)
    #expect(r.rows.first?.before == "beta")
    #expect(r.rows.first?.after == "BETA")
}

@Test("Mehrere Treffer in EINER Zeile werden korrekt zusammengesetzt")
func preview_multipleMatchesOneLine() {
    let text = "foo bar foo baz foo"
    let m = matches(in: text, find: "foo", replace: "X")
    let r = ReplacePreview.build(text: text, matches: m)
    #expect(r.totalChangedLines == 1)
    #expect(r.rows.first?.before == "foo bar foo baz foo")
    #expect(r.rows.first?.after == "X bar X baz X")
}

@Test("Treffer in mehreren Zeilen → je betroffene Zeile eine Row, Zeilennummern stimmen")
func preview_multipleLines() {
    let text = "match here\nclean line\nmatch again\nmatch last"
    let m = matches(in: text, find: "match", replace: "HIT")
    let r = ReplacePreview.build(text: text, matches: m)
    #expect(r.totalChangedLines == 3)
    #expect(r.rows.map(\.line) == [1, 3, 4])
    #expect(r.rows[0].after == "HIT here")
    #expect(r.rows[2].after == "HIT last")
}

@Test("Ersetzung gleich Original → Zeile erscheint NICHT (keine sichtbare Änderung)")
func preview_noVisibleChangeFiltered() {
    let text = "keep this\nkeep that"
    // Suchen und Ersetzen identisch → after == before → nicht anzeigen.
    let m = matches(in: text, find: "keep", replace: "keep")
    let r = ReplacePreview.build(text: text, matches: m)
    #expect(r.totalChangedLines == 0)
    #expect(r.rows.isEmpty)
}

@Test("Keine Treffer → leeres Ergebnis")
func preview_empty() {
    let r = ReplacePreview.build(text: "nothing here", matches: [])
    #expect(r == .empty)
}

@Test("maxRows kappt die Anzeige, totalChangedLines bleibt die wahre Zahl")
func preview_truncation() {
    // 5 Zeilen mit je einem Treffer.
    let text = (1...5).map { "match\($0)" }.joined(separator: "\n")
    let m = matches(in: text, find: "match", replace: "X")
    let r = ReplacePreview.build(text: text, matches: m, maxRows: 2)
    #expect(r.totalChangedLines == 5)
    #expect(r.rows.count == 2)
    #expect(r.truncated == true)
}

@Test("CR-Zeilenenden: Terminator wird aus der Vorher-Zeile entfernt")
func preview_crLineEndings() {
    let text = "first\rsecond\rthird"
    let m = matches(in: text, find: "second", replace: "ZWEI")
    let r = ReplacePreview.build(text: text, matches: m)
    #expect(r.rows.count == 1)
    // Kein \r im Vorher-/Nachher-Text.
    #expect(r.rows.first?.before == "second")
    #expect(r.rows.first?.after == "ZWEI")
}

@Test("Demo-Szenario Namens-Swap: (\\w+), (\\w+) + $2 $1 → 'Mustermann, Max' wird 'Max Mustermann'")
func preview_nameSwapDemo() {
    // Genau Daniels Präsentations-Demo: zwei Gruppen umgekehrt einsetzen.
    // Die Capture-Group-Pillen fügen per DnD/Klick `$2` bzw. `$1` ein — das
    // Replace-Template ist also `$2 $1`. Hier auf der Engine-Ebene abgesichert.
    let text = "Mustermann, Max\nSchmidt, Anna"
    let opts = SearchOptions(find: "(\\w+), (\\w+)", replace: "$2 $1", isRegex: true)
    let m = BufferSearch.find(in: text, options: opts).matches
    let r = ReplacePreview.build(text: text, matches: m)
    #expect(r.totalChangedLines == 2)
    #expect(r.rows[0].before == "Mustermann, Max")
    #expect(r.rows[0].after == "Max Mustermann")
    #expect(r.rows[1].after == "Anna Schmidt")
}

@Test("Wildcard-Ersetzung (RegEx aus): $1-Backref ist im replacedText bereits aufgelöst")
func preview_wildcardReplacement() {
    // „ring, The" → „The ring" über Platzhalter *, the / the *.
    let text = "ring, The"
    let opts = SearchOptions(find: "*, The", replace: "The *", isRegex: false)
    let m = BufferSearch.find(in: text, options: opts).matches
    let r = ReplacePreview.build(text: text, matches: m)
    #expect(r.rows.first?.before == "ring, The")
    #expect(r.rows.first?.after == "The ring")
}

@Test("Wildcard-Vorschau löst per Drag&Drop eingefügte $2/$1-Pillen auf")
func preview_wildcardPillReplacement() {
    // Regression Daniel 2026-07-10: Die Vorschau zeigte zuvor buchstäblich
    // „$2 $1", weil der Plain-Text-Pfad alle Dollarzeichen escapte.
    let text = "Müller, Daniel"
    let opts = SearchOptions(find: "*, *", replace: "$2 $1", isRegex: false)
    let matches = BufferSearch.find(in: text, options: opts).matches
    let preview = ReplacePreview.build(text: text, matches: matches)
    #expect(preview.rows.first?.before == "Müller, Daniel")
    #expect(preview.rows.first?.after == "Daniel Müller")
}

// MARK: - Stale-Treffer-Robustheit (Regression: inline Live-Vorschau)

@Test("STALE Treffer auf leerem Text → leeres Ergebnis statt Absturz")
func preview_staleMatchesEmptyText() {
    // Treffer aus einem langen Text holen …
    let old = "Mustermann, Max\nSchmidt, Anna\nMeyer, Eva"
    let stale = matches(in: old, find: "(\\w+), (\\w+)", replace: "$2 $1", isRegex: true)
    #expect(!stale.isEmpty)
    // … und gegen einen LEEREN (frisch gewechselten) Buffer verwenden. Früher
    // crashte `lineRange(for:)` an der out-of-bounds Range; jetzt: leer.
    let r = ReplacePreview.build(text: "", matches: stale)
    #expect(r == .empty)
}

@Test("Gemischt: nur in-bounds Treffer überleben, out-of-bounds wird übersprungen")
func preview_staleMatchesMixed() {
    // Treffer aus einem 3-Zeilen-Text; danach ein KÜRZERER Text, in dem nur
    // die erste Zeile (Treffer 1) noch existiert.
    let old = "Mustermann, Max\nSchmidt, Anna\nMeyer, Eva"
    let stale = matches(in: old, find: "(\\w+), (\\w+)", replace: "$2 $1", isRegex: true)
    let shorter = "Mustermann, Max"
    let r = ReplacePreview.build(text: shorter, matches: stale)
    // Kein Crash; nur der noch passende Treffer ergibt eine Row.
    #expect(r.rows.count == 1)
    #expect(r.rows.first?.after == "Max Mustermann")
}

@Test("Vollständiger Side-by-side-Diff richtet mehrzeilige Ersetzung aus")
func preview_sideBySideMultilineAlignment() {
    let text = "a\nMARK\nz"
    let found = matches(in: text, find: "MARK", replace: "x\ny")
    let result = ReplacePreview.buildSideBySide(text: text, matches: found)

    #expect(result.changedRows == 2)
    #expect(result.rows.map(\.kind) == [.unchanged, .changed, .added, .unchanged])
    #expect(result.rows[1].before == "MARK")
    #expect(result.rows[1].after == "x")
    #expect(result.rows[2].before == nil)
    #expect(result.rows[2].after == "y")
    #expect(result.rows[3].before == "z")
    #expect(result.rows[3].after == "z")
}

@Test("Side-by-side-Diff kappt nur die Anzeige und behält Gesamtzahlen")
func preview_sideBySideTruncation() {
    let text = "eins\nzwei\ndrei"
    let found = matches(in: text, find: "zwei", replace: "ZWEI")
    let result = ReplacePreview.buildSideBySide(text: text, matches: found, maxRows: 2)
    #expect(result.rows.count == 2)
    #expect(result.totalRows == 3)
    #expect(result.changedRows == 1)
    #expect(result.truncated)
}
