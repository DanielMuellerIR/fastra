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

private func sideBySideResult(
    _ outcome: ReplacePreview.SideBySideOutcome,
    sourceLocation: SourceLocation = #_sourceLocation
) -> ReplacePreview.SideBySideResult? {
    guard case .result(let result) = outcome else {
        Issue.record("Vollständiges Vorschauergebnis erwartet, erhalten: \(outcome)",
                     sourceLocation: sourceLocation)
        return nil
    }
    return result
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
    guard let result = sideBySideResult(
        ReplacePreview.buildSideBySide(text: text, matches: found)
    ) else { return }

    #expect(result.changedRows == 2)
    #expect(result.rows.map(\.kind) == [.unchanged, .changed, .added, .unchanged])
    #expect(result.rows[1].before == "MARK")
    #expect(result.rows[1].after == "x")
    #expect(result.rows[2].before == nil)
    #expect(result.rows[2].after == "y")
    #expect(result.rows[3].before == "z")
    #expect(result.rows[3].after == "z")
}

@Test("Side-by-side-Diff behandelt CRLF als einen Zeilenumbruch")
func preview_sideBySideCRLFLineNumbers() {
    let text = "alpha\r\nfoo\r\nomega"
    let found = matches(in: text, find: "foo", replace: "bar")
    guard let result = sideBySideResult(
        ReplacePreview.buildSideBySide(text: text, matches: found)
    ) else { return }

    #expect(result.totalRows == 3)
    #expect(result.changedRows == 1)
    #expect(result.rows.map(\.beforeLine) == [1, 2, 3])
    #expect(result.rows.map(\.afterLine) == [1, 2, 3])
    #expect(result.rows[1].before == "foo")
    #expect(result.rows[1].after == "bar")
}

@Test("Side-by-side-Diff kappt nur die Anzeige und behält Gesamtzahlen")
func preview_sideBySideTruncation() {
    let text = "eins\nzwei\ndrei"
    let found = matches(in: text, find: "zwei", replace: "ZWEI")
    guard let result = sideBySideResult(
        ReplacePreview.buildSideBySide(text: text, matches: found, maxRows: 2)
    ) else { return }
    #expect(result.rows.count == 2)
    #expect(result.totalRows == 3)
    #expect(result.changedRows == 1)
    #expect(result.truncated)
    #expect(result.allChangedRowsVisible)
    #expect(result.rows.contains { $0.kind == .changed && $0.before == "zwei" })
}

@Test("Side-by-side-Diff zeigt eine späte Änderung trotz Zeilenlimit")
func preview_sideBySidePrioritizesLateChange() {
    let unchanged = (1...5_100).map { "Zeile \($0)" }
    let text = (unchanged + ["foo am Ende"]).joined(separator: "\n")
    let found = matches(in: text, find: "foo", replace: "bar")

    guard let result = sideBySideResult(ReplacePreview.buildSideBySide(
        text: text, matches: found, maxRows: 12
    )) else { return }

    #expect(result.changedRows == 1)
    #expect(result.allChangedRowsVisible)
    #expect(result.rows.contains {
        $0.kind == .changed && $0.before == "foo am Ende" && $0.after == "bar am Ende"
    }, "Das Zeilenlimit darf die eigentliche Änderung nicht hinter Kontext verstecken")
}

@Test("Side-by-side-Diff kennzeichnet zu viele Änderungszeilen als unvollständig")
func preview_sideBySideRejectsHiddenChanges() {
    let text = (1...5).map { "foo \($0)" }.joined(separator: "\n")
    let found = matches(in: text, find: "foo", replace: "bar")

    guard let result = sideBySideResult(ReplacePreview.buildSideBySide(
        text: text, matches: found, maxRows: 3
    )) else { return }

    #expect(result.changedRows == 5)
    #expect(result.visibleChangedRows == 3)
    #expect(!result.allChangedRowsVisible)
    #expect(result.rows.allSatisfy { $0.kind == .changed })
}

@Test("Side-by-side-Diff bricht einen überholten Lauf kooperativ ab")
func preview_sideBySideCancellation() {
    let text = "foo\nbar"
    let found = matches(in: text, find: "foo", replace: "FOO")
    let outcome = ReplacePreview.buildSideBySide(
        text: text, matches: found, shouldCancel: { true }
    )
    #expect(outcome == .cancelled)
}

@Test("Side-by-side-Diff lehnt einen zu großen Nachher-Text ehrlich ab")
func preview_sideBySideOutputLimit() {
    let text = "foo"
    let found = matches(in: text, find: "foo", replace: "123456")
    let limits = ReplacePreview.SideBySideLimits(
        maximumTextBytes: 5, maximumLineCount: 10,
        maximumDiffInputLines: 10)

    let outcome = ReplacePreview.buildSideBySide(
        text: text, matches: found, limits: limits
    )

    #expect(outcome == .limitation(.tooLarge(maximumBytes: 5)))
}

@Test("Side-by-side-Diff begrenzt den unterschiedlichen Myers-Mittelteil")
func preview_sideBySideDifferenceLimit() {
    let text = "a\nb\nc"
    let found = matches(in: text, find: "a\nb\nc", replace: "x\ny\nz",
                        isRegex: false)
    let limits = ReplacePreview.SideBySideLimits(
        maximumTextBytes: 100, maximumLineCount: 10,
        maximumDiffInputLines: 5)

    let outcome = ReplacePreview.buildSideBySide(
        text: text, matches: found, limits: limits
    )

    #expect(outcome == .limitation(.tooDifferent(maximumLines: 5)))
}

@Test("Side-by-side-Diff lehnt zu viele logische Zeilen vollständig ab")
func preview_sideBySideLineLimit() {
    let text = "a\nb"
    let found = matches(in: text, find: "b", replace: "b\nc")
    let limits = ReplacePreview.SideBySideLimits(
        maximumTextBytes: 100, maximumLineCount: 2,
        maximumDiffInputLines: 10)

    let outcome = ReplacePreview.buildSideBySide(
        text: text, matches: found, limits: limits
    )

    #expect(outcome == .limitation(.tooManyLines(maximumLines: 2)))
}

private final class SequencedPreviewBuilder: @unchecked Sendable {
    let releaseFirst = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var callCount = 0
    private var firstFinished = false
    private var ranOnMainThread = false

    var startedCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    var didFinishFirst: Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstFinished
    }

    var anyCallRanOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ranOnMainThread
    }

    func build(
        text: String, matches: [BufferSearch.Match], maxRows: Int,
        shouldCancel: @Sendable () -> Bool
    ) -> ReplacePreview.SideBySideOutcome {
        lock.lock()
        callCount += 1
        let call = callCount
        ranOnMainThread = ranOnMainThread || Thread.isMainThread
        lock.unlock()

        if call == 1 {
            releaseFirst.wait()
            lock.lock()
            firstFinished = true
            lock.unlock()
        }
        let row = ReplacePreview.SideBySideRow(
            id: 0, beforeLine: 1, afterLine: 1,
            before: text, after: text.uppercased(), kind: .changed)
        return .result(ReplacePreview.SideBySideResult(
            rows: [row], totalRows: 1, changedRows: 1))
    }
}

@Test("Vorschau-Modell serialisiert einen nicht kooperativ abbrechbaren alten Lauf")
@MainActor
func previewModel_discardsStaleCompletion() async throws {
    let builder = SequencedPreviewBuilder()
    let model = ReplacePreviewModel { text, matches, maxRows, shouldCancel in
        builder.build(text: text, matches: matches, maxRows: maxRows,
                      shouldCancel: shouldCancel)
    }
    let documentID = UUID()
    let old = ReplacePreviewModel.Request(
        version: .init(documentID: documentID, contentRevision: 1,
                       matchIDs: []),
        text: "alt", matches: [])
    let current = ReplacePreviewModel.Request(
        version: .init(documentID: documentID, contentRevision: 2,
                       matchIDs: []),
        text: "neu", matches: [])
    defer { builder.releaseFirst.signal() }

    model.load(old)
    #expect(await waitUntil { builder.startedCalls >= 1 })
    model.load(current)
    for _ in 0..<50 { await Task.yield() }
    #expect(builder.startedCalls == 1,
            "Der neue Myers-Diff darf nicht neben dem alten laufen")

    builder.releaseFirst.signal()
    #expect(await waitUntil { builder.didFinishFirst })
    #expect(await waitUntil { builder.startedCalls >= 2 })
    #expect(await waitUntil { model.result?.rows.first?.after == "NEU" })
    #expect(model.result?.rows.first?.after == "NEU")
    #expect(!builder.anyCallRanOnMainThread,
            "Auch der injizierte Builder muss außerhalb des UI-Threads laufen")
}

@Test("Vorschau-Modell erklärt eine gekappte Trefferbasis und startet keinen Diff")
@MainActor
func previewModel_rejectsCappedMatchSet() {
    let builder = SequencedPreviewBuilder()
    let model = ReplacePreviewModel { text, matches, maxRows, shouldCancel in
        builder.build(text: text, matches: matches, maxRows: maxRows,
                      shouldCancel: shouldCancel)
    }
    let request = ReplacePreviewModel.Request(
        version: .init(documentID: UUID(), contentRevision: 1,
                       matchIDs: [], totalMatches: 3,
                       matchesWereCapped: true),
        text: "drei Treffer", matches: [])

    model.load(request)

    #expect(model.state == .limitation(.incompleteMatchSet(
        visibleMatches: 0, totalMatches: 3)))
    #expect(builder.startedCalls == 0)
}

@Test("Gekappter Zwischenauftrag unterbricht die Diff-Serialisierung nicht")
@MainActor
func previewModel_keepsSerializationAcrossCappedRequest() async {
    let builder = SequencedPreviewBuilder()
    let model = ReplacePreviewModel { text, matches, maxRows, shouldCancel in
        builder.build(text: text, matches: matches, maxRows: maxRows,
                      shouldCancel: shouldCancel)
    }
    let documentID = UUID()
    let old = ReplacePreviewModel.Request(
        version: .init(documentID: documentID, contentRevision: 1,
                       matchIDs: []),
        text: "alt", matches: [])
    let capped = ReplacePreviewModel.Request(
        version: .init(documentID: documentID, contentRevision: 2,
                       matchIDs: [], totalMatches: 1,
                       matchesWereCapped: true),
        text: "unvollständig", matches: [])
    let current = ReplacePreviewModel.Request(
        version: .init(documentID: documentID, contentRevision: 3,
                       matchIDs: []),
        text: "neu", matches: [])
    defer { builder.releaseFirst.signal() }

    model.load(old)
    #expect(await waitUntil { builder.startedCalls >= 1 })
    model.load(capped)
    #expect(model.state == .limitation(.incompleteMatchSet(
        visibleMatches: 0, totalMatches: 1)))
    model.load(current)
    for _ in 0..<50 { await Task.yield() }
    #expect(builder.startedCalls == 1,
            "Der Zwischenauftrag darf den alten Myers-Diff nicht aus der Kette lösen")

    builder.releaseFirst.signal()
    #expect(await waitUntil { builder.startedCalls >= 2 })
    #expect(await waitUntil { model.result?.rows.first?.after == "NEU" })
}
