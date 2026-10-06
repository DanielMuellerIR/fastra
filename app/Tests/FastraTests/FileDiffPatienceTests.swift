import Foundation
import Testing
@testable import Fastra

@Suite("Große Dateivergleiche mit eindeutigen Zeilenankern")
struct FileDiffPatienceTests {
    private func changes(_ old: [Int], _ new: [Int], limit: Int) throws -> MyersDiff.Changes? {
        try PatienceDiff.changes(from: old, to: new, maximumInputLines: limit,
                                 isCancelled: { false })
    }

    private func verify(_ edits: MyersDiff.Changes, old: [Int], new: [Int]) {
        let removed = Set(edits.removedOffsets)
        let inserted = Set(edits.insertedOffsets)
        #expect(removed.count == edits.removedOffsets.count)
        #expect(inserted.count == edits.insertedOffsets.count)
        #expect(edits.removedOffsets == edits.removedOffsets.sorted())
        #expect(edits.insertedOffsets == edits.insertedOffsets.sorted())
        #expect(removed.allSatisfy { old.indices.contains($0) })
        #expect(inserted.allSatisfy { new.indices.contains($0) })
        // Unabhängiger Beleg: Nach Entfernen der Änderungen müssen beide
        // Folgen identisch sein. Kein Ausrichtungshelfer des Produkts beteiligt.
        #expect(old.indices.filter { !removed.contains($0) }.map { old[$0] }
            == new.indices.filter { !inserted.contains($0) }.map { new[$0] })
    }

    @Test("Unterhalb des Budgets bleibt die Myers-Zuordnung exakt erhalten")
    func smallInputsKeepMyers() throws {
        for old in [[], [1], [1, 2, 1, 3], [3, 2, 1]] {
            for new in [[], [2], [1, 1, 2, 3], [1, 2, 3]] {
                #expect(try changes(old, new, limit: 30)
                    == MyersDiff.changes(from: old, to: new, isCancelled: { false }))
            }
        }
    }

    @Test("Kreuzende und wiederholte Zeilen ergeben eine vollständige stabile Zuordnung")
    func adversarialInputs() throws {
        let fixtures = [
            ([0, 1, 2, 3, 4, 5], [5, 4, 3, 2, 1, 0]),
            ([0, 1, 9, 1, 8, 2, 3], [4, 1, 9, 1, 8, 2, 5]),
            ([0, 1, 2, 3, 4, 5, 6], [7, 2, 3, 8, 4, 5, 9]),
            (Array(0..<100), Array(50..<100) + Array(0..<50))
        ]
        for (old, new) in fixtures {
            let edits = try #require(try changes(old, new, limit: 10))
            verify(edits, old: old, new: new)
            #expect(try changes(old, new, limit: 10) == edits)
        }
        // Eindeutigkeit muss auf BEIDEN Seiten gelten.
        #expect(try changes([0, 1, 1, 2, 9], [8, 1, 2, 2, 7], limit: 2) == nil)
    }

    @Test("Deterministische Mischfolgen bleiben vollständig, auch mit verschobenen Blöcken")
    func mixedSequences() throws {
        var state: UInt64 = 2026_10_06
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int((state >> 32) % UInt64(bound))
        }
        var accepted = 0
        for _ in 0..<300 {
            let old = (0..<40).map { _ in next(100) }
            var new = old
            for step in 0..<8 {
                let index = next(new.count)
                switch step % 4 {
                case 0: new[index] = next(100)
                case 1: new.remove(at: index)
                case 2: new.insert(next(100), at: index)
                default:
                    let value = new.remove(at: index)
                    new.insert(value, at: next(new.count + 1))
                }
            }
            if let edits = try changes(old, new, limit: 20) {
                verify(edits, old: old, new: new)
                #expect(try changes(old, new, limit: 20) == edits)
                accepted += 1
            }
        }
        #expect(accepted > 200, "Nur \(accepted) der 300 begrenzten Mischfolgen zugelassen")
    }

    @Test("Blockqualität und Kernlaufzeit im Vergleich zum bisherigen Myers-Kern")
    func compareWithMyers() throws {
        let old = Array(0..<50_000)
        var new = old
        let changed = stride(from: 0, to: old.count, by: 100).map { $0 }
        for index in changed { new[index] = -index - 1 }
        let clock = ContinuousClock()
        let baselineStart = clock.now
        let baseline = try #require(MyersDiff.changes(from: old, to: new, isCancelled: { false }))
        let baselineDuration = baselineStart.duration(to: clock.now)
        let anchoredStart = clock.now
        let anchored = try #require(try changes(old, new, limit: 30_000))
        let anchoredDuration = anchoredStart.duration(to: clock.now)
        #expect(anchored == baseline)
        #expect(anchored.removedOffsets == changed)
        #expect(anchored.insertedOffsets == changed)
        print("Diff-Kerne: 50.000 Zeilen je Seite, 500 Änderungen: Myers \(baselineDuration), Anker \(anchoredDuration)")
        #expect(anchoredDuration < .seconds(10))
    }

    @Test("Wiederholte gemeinsame Randzeilen der Teilbereiche verbrauchen kein Myers-Budget")
    func repeatedGapEdges() throws {
        let middle = Array(repeating: 7, count: 40)
        let end = Array(repeating: 8, count: 40)
        let old = [1] + middle + [100] + end + [2]
        let new = [3] + middle + [100] + end + [4]
        let edits = try #require(try changes(old, new, limit: 4))
        #expect(edits.removedOffsets == [0, 82])
        #expect(edits.insertedOffsets == [0, 82])
        verify(edits, old: old, new: new)
    }

    @Test("Ein übergroßer Restblock oder zu viel Gesamtarbeit wird vollständig abgelehnt")
    func boundedWork() throws {
        #expect(try changes(Array(repeating: 1, count: 40) + [9],
                            Array(repeating: 2, count: 40) + [9], limit: 30) == nil)
        // Beide Bereiche passen einzeln; zusammen überschreiten ihre
        // quadratischen Arbeitsgrenzen das Budget eines Maximalvergleichs.
        #expect(try changes([0, 1, 9, 2, 3], [4, 5, 9, 6, 7], limit: 4) == nil)
    }

    @Test("Große reine Einfügungen und Löschungen brauchen keinen quadratischen Kern")
    func oneSidedGaps() throws {
        let old = Array(0..<50_000)
        for (left, right) in [(old, []), ([], old)] {
            let edits = try #require(try changes(left, right, limit: 30_000))
            verify(edits, old: left, new: right)
        }
    }

    @Test("Abbruch in jeder Anker- und Ergebnisphase liefert kein Teilergebnis")
    func cancellationPhases() throws {
        let old = Array(0..<10_000)
        var new = old
        new[0] = -1
        new[9_999] = -2
        var totalChecks = 0
        _ = try PatienceDiff.changes(from: old, to: new, maximumInputLines: 100,
                                     isCancelled: { totalChecks += 1; return false })
        for stop in 1...totalChecks {
            var checks = 0
            #expect(throws: CancellationError.self) {
                _ = try PatienceDiff.changes(from: old, to: new, maximumInputLines: 100,
                                             isCancelled: { checks += 1; return checks == stop })
            }
        }
    }

    @Test("Normalisierte Anker und ignorierte Leerzeilen behalten Originaltexte und Zeilennummern")
    func normalizedAnchors() throws {
        let count = 16_000
        let left = (0..<count).map { $0 % 2 == 0 ? "\tZeile \($0) " : "" }
        var right = (0..<count).map { $0 % 2 == 0 ? "zeile \($0)" : "  " }
        right[0] = "neu am Anfang"
        right[count - 2] = "neu am Ende"
        var options = FileDiffOptions()
        options.ignoreCase = true
        options.ignoreAllWhitespace = true
        options.ignoreBlankLines = true
        // Doppelte Größe erzwingt auch nach dem Weglassen der Leerzeilen
        // den Ankerpfad (>30.000 Teilnehmer insgesamt).
        let before = left + left.enumerated().map { "\($0.offset + count):\($0.element)" }
        let after = right + right.enumerated().map { "\($0.offset + count):\($0.element)" }
        guard case .result(let result) = FileDiff.compare(
            left: before.joined(separator: "\n"), right: after.joined(separator: "\n"), options: options
        ) else { Issue.record("Normalisierter großer Vergleich wurde abgelehnt"); return }
        #expect(result.rows.compactMap(\.before) == before)
        #expect(result.rows.compactMap(\.after) == after)
        #expect(result.rows.filter { $0.kind == .changed }.map(\.beforeLine)
            == [1, count - 1, count + 1, 2 * count - 1])
        #expect(result.rows.filter(\.isIgnoredBlank).count == count / 2)
        #expect(result.rows.allSatisfy { $0.kind != .unchanged || $0.isIgnoredBlank
            || options.normalizedKey(for: $0.before ?? "") == options.normalizedKey(for: $0.after ?? "") })
    }

    @Test("Große gemischte Änderungen erhalten vollständige Texte und verschobene Zeilennummern")
    func insertedAndDeletedLines() throws {
        let left = ["gemeinsamer Anfang"] + (0..<20_000).map { "Zeile \($0)" } + ["gemeinsames Ende"]
        var right = left
        right[1] = "geänderter Anfang"
        right.insert(contentsOf: ["neu A", "neu B"], at: 8_001)
        right.remove(at: 16_003)
        right[right.count - 2] = "geändertes Ende"
        guard case .result(let result) = FileDiff.compare(
            left: left.joined(separator: "\n"), right: right.joined(separator: "\n")
        ) else { Issue.record("Großer gemischter Vergleich wurde abgelehnt"); return }
        #expect(result.rows.compactMap(\.before) == left)
        #expect(result.rows.compactMap(\.after) == right)
        #expect(result.rows.compactMap(\.beforeLine) == Array(1...left.count))
        #expect(result.rows.compactMap(\.afterLine) == Array(1...right.count))
        #expect(result.rows.allSatisfy { $0.kind != .unchanged || $0.before == $0.after })
        #expect(result.blocks.map(\.kind) == [.changed, .onlyRight, .onlyLeft, .changed])
        #expect(result.blocks.map(\.beforeLines) == [2...2, nil, 16_002...16_002, 20_001...20_001])
        #expect(result.blocks.map(\.afterLines) == [2...2, 8_002...8_003, nil, 20_002...20_002])
    }

    @Test("Verstreute Änderungen über 100.000 Zeilen bleiben einzeln zugeordnet")
    func scatteredChanges() throws {
        let left = (0..<100_000).map { "Zeile \($0)" }
        var right = left
        let changed = [0, 17_000, 50_000, 83_000, 99_999]
        for index in changed { right[index] = "Neu \(index)" }
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = FileDiff.compare(left: left.joined(separator: "\n"),
                                       right: right.joined(separator: "\n"))
        let duration = start.duration(to: clock.now)
        print("Anker-Diff: 100.000 Zeilen je Seite, fünf Änderungen: \(duration)")
        guard case .result(let result) = outcome else {
            Issue.record("Große ähnliche Dateien wurden abgelehnt: \(outcome)")
            return
        }
        #expect(result.rows.count == left.count)
        #expect(result.blocks.map(\.beforeLines) == changed.map { ($0 + 1)...($0 + 1) })
        #expect(result.blocks.map(\.afterLines) == changed.map { ($0 + 1)...($0 + 1) })
        #expect(result.rows.filter { $0.kind != .unchanged }.map(\.id) == changed)
        #expect(result.rows.compactMap(\.before) == left)
        #expect(result.rows.compactMap(\.after) == right)
        #expect(duration < .seconds(10))
    }
}
