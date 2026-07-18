// FileDiffTests.swift
//
// Unit-Tests für den UI-freien Datei-Diff-Kern (Etappe 1 Wunschpaket
// 2026-07c): Zeilen-Ausrichtung, alle Vergleichsoptionen, Leerzeilen- und
// Unicode-Fälle, Differenzen-Blöcke, Falten und die ehrlichen Grenzen.

import Testing
import Foundation
@testable import Fastra

// Kleine Helfer: Ergebnis aus einem Outcome herausholen (Test schlägt fehl,
// wenn stattdessen eine Grenze gemeldet wurde).
private func result(_ outcome: FileDiff.Outcome,
                    sourceLocation: SourceLocation = #_sourceLocation) -> FileDiff.Result? {
    guard case .result(let r) = outcome else {
        Issue.record("Erwartet: Ergebnis, bekommen: \(outcome)",
                     sourceLocation: sourceLocation)
        return nil
    }
    return r
}

@Test("Identische Texte → keine Blöcke, alle Zeilen unchanged")
func identicalTexts() {
    let text = "alpha\nbeta\ngamma"
    guard let r = result(FileDiff.compare(left: text, right: text)) else { return }
    #expect(r.isIdentical)
    #expect(r.blocks.isEmpty)
    #expect(r.rows.count == 3)
    #expect(r.rows.allSatisfy { $0.kind == .unchanged })
    #expect(r.leftLineCount == 3)
    #expect(r.rightLineCount == 3)
}

@Test("Beide leer → identisch mit genau einer (leeren) Zeile")
func bothEmpty() {
    guard let r = result(FileDiff.compare(left: "", right: "")) else { return }
    #expect(r.isIdentical)
    #expect(r.leftLineCount == 1)
}

@Test("Eine geänderte Zeile → ein changed-Block mit Intraline-Bereich")
func singleChangedLine() {
    let left = "eins\nzwei\ndrei"
    let right = "eins\nzwo\ndrei"
    guard let r = result(FileDiff.compare(left: left, right: right)) else { return }
    #expect(r.blocks.count == 1)
    #expect(r.blocks[0].kind == .changed)
    #expect(r.blocks[0].beforeLines == 2...2)
    #expect(r.blocks[0].afterLines == 2...2)
    let changed = r.rows.first { $0.kind == .changed }
    #expect(changed?.before == "zwei")
    #expect(changed?.after == "zwo")
    // „zw" gemeinsamer Präfix → Unterschied beginnt bei Offset 2.
    #expect(changed?.beforeHighlight == 2..<4)   // „ei"
    #expect(changed?.afterHighlight == 2..<3)    // „o"
}

@Test("Zeile nur links → onlyLeft-Block, Ausrichtung mit leerer Gegenseite")
func onlyLeftLine() {
    let left = "a\nb\nc"
    let right = "a\nc"
    guard let r = result(FileDiff.compare(left: left, right: right)) else { return }
    #expect(r.blocks.count == 1)
    #expect(r.blocks[0].kind == .onlyLeft)
    #expect(r.blocks[0].beforeLines == 2...2)
    #expect(r.blocks[0].afterLines == nil)
    let removed = r.rows.first { $0.kind == .removed }
    #expect(removed?.before == "b")
    #expect(removed?.after == nil)
    #expect(removed?.afterLine == nil)
}

@Test("Zeile nur rechts → onlyRight-Block")
func onlyRightLine() {
    let left = "a\nc"
    let right = "a\nb\nc"
    guard let r = result(FileDiff.compare(left: left, right: right)) else { return }
    #expect(r.blocks.count == 1)
    #expect(r.blocks[0].kind == .onlyRight)
    #expect(r.blocks[0].afterLines == 2...2)
    #expect(r.blocks[0].beforeLines == nil)
}

@Test("2 entfernte + 3 eingefügte Zeilen → 2 changed-Paare + 1 added")
func pairedRuns() {
    let left = "start\nalt1\nalt2\nende"
    let right = "start\nneu1\nneu2\nneu3\nende"
    guard let r = result(FileDiff.compare(left: left, right: right)) else { return }
    let kinds = r.rows.map(\.kind)
    #expect(kinds == [.unchanged, .changed, .changed, .added, .unchanged])
    // Ein zusammenhängender Lauf → EIN Block, gemischt = changed.
    #expect(r.blocks.count == 1)
    #expect(r.blocks[0].kind == .changed)
    #expect(r.blocks[0].beforeLines == 2...3)
    #expect(r.blocks[0].afterLines == 2...4)
}

@Test("Änderungen ganz am Anfang und ganz am Ende werden gefunden")
func changesAtEdges() {
    let left = "ANFANG\nmitte\nmitte\nENDE"
    let right = "anders\nmitte\nmitte\nauch anders"
    guard let r = result(FileDiff.compare(left: left, right: right)) else { return }
    #expect(r.blocks.count == 2)
    #expect(r.rows.first?.kind == .changed)
    #expect(r.rows.last?.kind == .changed)
}

@Test("Fehlender End-Umbruch bleibt sichtbar (letzte Leerzeile differiert)")
func trailingNewlineDifference() {
    let left = "a\nb\n"
    let right = "a\nb"
    guard let r = result(FileDiff.compare(left: left, right: right)) else { return }
    // Links existiert eine dritte (leere) Zeile, rechts nicht.
    #expect(!r.isIdentical)
    #expect(r.blocks.count == 1)
    #expect(r.blocks[0].kind == .onlyLeft)
    #expect(r.leftLineCount == 3)
    #expect(r.rightLineCount == 2)
}

// MARK: - Optionen

@Test("Leerraum am Zeilenende ignorieren: nur mit Option identisch")
func ignoreTrailingWhitespace() {
    let left = "code();   \nweiter"
    let right = "code();\nweiter"
    guard let plain = result(FileDiff.compare(left: left, right: right)) else { return }
    #expect(!plain.isIdentical)
    var options = FileDiffOptions()
    options.ignoreTrailingWhitespace = true
    guard let relaxed = result(FileDiff.compare(left: left, right: right,
                                                options: options)) else { return }
    #expect(relaxed.isIdentical)
    // Angezeigt wird trotzdem die ORIGINALZEILE, nicht die normalisierte.
    #expect(relaxed.rows[0].before == "code();   ")
}

@Test("Alle Leerraum-Unterschiede ignorieren: Einrückung/Spatien egal")
func ignoreAllWhitespace() {
    let left = "if (a == b) {\n\tx = 1;\n}"
    let right = "if(a==b){\n  x=1;\n}"
    var options = FileDiffOptions()
    options.ignoreAllWhitespace = true
    guard let r = result(FileDiff.compare(left: left, right: right,
                                          options: options)) else { return }
    #expect(r.isIdentical)
}

@Test("Groß-/Kleinschreibung ignorieren")
func ignoreCase() {
    let left = "Hello World\nZeile"
    let right = "hello world\nZeile"
    guard let plain = result(FileDiff.compare(left: left, right: right)) else { return }
    #expect(!plain.isIdentical)
    var options = FileDiffOptions()
    options.ignoreCase = true
    guard let relaxed = result(FileDiff.compare(left: left, right: right,
                                                options: options)) else { return }
    #expect(relaxed.isIdentical)
}

@Test("Leerzeilen ignorieren: einseitige Leerzeile ist kein Unterschied")
func ignoreBlankLines() {
    let left = "a\n\nb"
    let right = "a\nb"
    guard let plain = result(FileDiff.compare(left: left, right: right)) else { return }
    #expect(!plain.isIdentical)
    var options = FileDiffOptions()
    options.ignoreBlankLines = true
    guard let relaxed = result(FileDiff.compare(left: left, right: right,
                                                options: options)) else { return }
    #expect(relaxed.isIdentical)
    // Die Leerzeile bleibt SICHTBAR (keine stille Auslassung), einseitig,
    // aber als ignoriert markiert und nicht als Unterschied gezählt.
    let ignored = relaxed.rows.filter(\.isIgnoredBlank)
    #expect(ignored.count == 1)
    #expect(ignored[0].beforeLine == 2)
    #expect(ignored[0].afterLine == nil)
    #expect(ignored[0].kind == .unchanged)
}

@Test("Leerzeilen ignorieren: beidseitige Leerzeilen teilen sich eine Zeile")
func ignoreBlankLinesPaired() {
    let left = "a\n\nb"
    let right = "a\n   \nb"
    var options = FileDiffOptions()
    options.ignoreBlankLines = true
    guard let r = result(FileDiff.compare(left: left, right: right,
                                          options: options)) else { return }
    #expect(r.isIdentical)
    let ignored = r.rows.filter(\.isIgnoredBlank)
    #expect(ignored.count == 1)
    #expect(ignored[0].beforeLine == 2)
    #expect(ignored[0].afterLine == 2)
}

@Test("Leerzeilen ignorieren: echte Änderungen um Leerzeilen herum bleiben")
func ignoreBlankLinesKeepsRealChanges() {
    let left = "alt\n\nnoch alt"
    let right = "neu\n\nnoch alt"
    var options = FileDiffOptions()
    options.ignoreBlankLines = true
    guard let r = result(FileDiff.compare(left: left, right: right,
                                          options: options)) else { return }
    #expect(r.blocks.count == 1)
    #expect(r.blocks[0].kind == .changed)
    #expect(r.rows[0].kind == .changed)
}

@Test("Optionen kombiniert: Groß/klein + Leerraum gleichzeitig")
func combinedOptions() {
    let left = "FOO   Bar  \nrest"
    let right = "foo bar\nrest"
    var options = FileDiffOptions()
    options.ignoreAllWhitespace = true
    options.ignoreCase = true
    guard let r = result(FileDiff.compare(left: left, right: right,
                                          options: options)) else { return }
    #expect(r.isIdentical)
}

// MARK: - Unicode

@Test("Umlaute und Emoji: Intraline-Bereiche sind Zeichen-Offsets")
func unicodeIntraline() {
    let left = "Grüße 👋 Welt"
    let right = "Grüße 🌍 Welt"
    guard let r = result(FileDiff.compare(left: left, right: right)) else { return }
    let changed = r.rows.first { $0.kind == .changed }
    // Gemeinsamer Präfix „Grüße " = 6 Zeichen; das Emoji ist EIN Zeichen.
    #expect(changed?.beforeHighlight == 6..<7)
    #expect(changed?.afterHighlight == 6..<7)
}

@Test("Zusammengesetzte Grapheme werden als ganze Zeichen verglichen")
func combiningCharacters() {
    // „é" einmal vorkombiniert, einmal e + Combining Acute — String-
    // Gleichheit in Swift ist kanonisch, beide gelten als gleich.
    let left = "caf\u{00E9}"
    let right = "cafe\u{0301}"
    guard let r = result(FileDiff.compare(left: left, right: right)) else { return }
    #expect(r.isIdentical)
}

// MARK: - Differenzen-Liste und Falten

@Test("blocks(for:) trennt Läufe an unveränderten Zeilen")
func blockGrouping() {
    let left = "1\nX\n3\n4\nY\n6"
    let right = "1\nx\n3\n4\n6"
    guard let r = result(FileDiff.compare(left: left, right: right)) else { return }
    #expect(r.blocks.count == 2)
    #expect(r.blocks[0].kind == .changed)
    #expect(r.blocks[1].kind == .onlyLeft)
    #expect(r.blocks[1].beforeLines == 5...5)
}

@Test("Falten: langer unveränderter Lauf wird mit Kontext eingeklappt")
func foldingInterior() {
    // 20 unveränderte Zeilen zwischen zwei Änderungen.
    let middle = (1...20).map { "gleich \($0)" }.joined(separator: "\n")
    let left = "ALT\n" + middle + "\nALT2"
    let right = "NEU\n" + middle + "\nNEU2"
    guard let r = result(FileDiff.compare(left: left, right: right)) else { return }
    let items = FileDiff.visibleItems(rows: r.rows, expandedFolds: [])
    let folds = items.compactMap { item -> FileDiff.Fold? in
        if case .fold(let fold) = item { return fold }
        return nil
    }
    // 20 unveränderte − 3 Kontext oben − 3 Kontext unten = 14 gefaltet.
    #expect(folds.count == 1)
    #expect(folds[0].count == 14)
    // Sichtbar: 2 Änderungen + 6 Kontext + 1 Falt-Knopf.
    #expect(items.count == 9)
    // Ausklappen zeigt alle Zeilen; der Falt-Knopf bleibt zum
    // Wieder-Einklappen stehen (Verhalten wie im Git-Diff).
    let expanded = FileDiff.visibleItems(rows: r.rows, expandedFolds: [folds[0].id])
    #expect(expanded.count == r.rows.count + 1)
}

@Test("Falten: Lauf am Dateianfang behält nur Kontext zur Änderung hin")
func foldingAtFileStart() {
    let head = (1...15).map { "kopf \($0)" }.joined(separator: "\n")
    let left = head + "\nALT"
    let right = head + "\nNEU"
    guard let r = result(FileDiff.compare(left: left, right: right)) else { return }
    let items = FileDiff.visibleItems(rows: r.rows, expandedFolds: [])
    guard case .fold(let fold) = items.first else {
        Issue.record("Erwartet: Falt-Knopf als erstes Element")
        return
    }
    // 15 Kopfzeilen − 3 Kontext vor der Änderung = 12 gefaltet.
    #expect(fold.count == 12)
}

@Test("Falten: kurze unveränderte Läufe bleiben komplett sichtbar")
func noFoldForShortRuns() {
    let left = "A\n1\n2\n3\n4\nB"
    let right = "a\n1\n2\n3\n4\nb"
    guard let r = result(FileDiff.compare(left: left, right: right)) else { return }
    let items = FileDiff.visibleItems(rows: r.rows, expandedFolds: [])
    #expect(items.count == r.rows.count)
}

// MARK: - Ehrliche Grenzen

@Test("Zu viele Zeilen → tooManyLines statt minutenlanger Rechnung")
func tooManyLines() {
    let huge = String(repeating: "\n", count: FileDiff.maximumLineCount)
    let outcome = FileDiff.compare(left: huge, right: "kurz")
    #expect(outcome == .limitation(.tooManyLines(side: .left,
                                                 limit: FileDiff.maximumLineCount)))
    let outcomeRight = FileDiff.compare(left: "kurz", right: huge)
    #expect(outcomeRight == .limitation(.tooManyLines(side: .right,
                                                      limit: FileDiff.maximumLineCount)))
}

@Test("Zu unterschiedlich → tooDifferent (Budget nach Präfix/Suffix-Abzug)")
func tooDifferent() {
    // Zwei komplett verschiedene Texte, zusammen über dem Diff-Budget.
    let half = FileDiff.maximumDiffInputLines / 2 + 1
    let left = (0..<half).map { "links \($0)" }.joined(separator: "\n")
    let right = (0..<half).map { "rechts \($0)" }.joined(separator: "\n")
    let outcome = FileDiff.compare(left: left, right: right)
    #expect(outcome == .limitation(.tooDifferent(limit: FileDiff.maximumDiffInputLines)))
}

@Test("Große, aber ähnliche Dateien laufen durch (Präfix/Suffix-Abzug)")
func largeSimilarFiles() {
    // 100.000 gleiche Zeilen, eine Änderung in der Mitte — der Abzug
    // gemeinsamer Zeilen hält den Diff winzig.
    var leftLines = (0..<100_000).map { "zeile \($0)" }
    var rightLines = leftLines
    leftLines[50_000] = "alt"
    rightLines[50_000] = "neu"
    let outcome = FileDiff.compare(left: leftLines.joined(separator: "\n"),
                                   right: rightLines.joined(separator: "\n"))
    guard let r = result(outcome) else { return }
    #expect(r.blocks.count == 1)
    #expect(r.blocks[0].beforeLines == 50_001...50_001)
}
