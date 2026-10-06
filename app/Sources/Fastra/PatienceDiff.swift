import Foundation

/// Große Vergleiche an eindeutigen gemeinsamen Zeilen aufteilen. Innerhalb
/// des bisherigen Budgets bleibt Myers samt seiner Zuordnung unverändert.
enum PatienceDiff {
    private struct Anchor {
        let old: Int
        let new: Int
    }

    private struct Gap {
        var old: Range<Int>
        var new: Range<Int>
    }

    /// `nil` bedeutet Rechenlimit, ein Abbruch wirft CancellationError.
    /// Die Offsets beziehen sich stets auf die vollständigen Eingabefolgen.
    static func changes(from old: [Int], to new: [Int],
                        maximumInputLines: Int,
                        isCancelled: () -> Bool) throws -> MyersDiff.Changes? {
        func checkCancellation() throws {
            if isCancelled() { throw CancellationError() }
        }
        try checkCancellation()
        if old.count + new.count <= maximumInputLines {
            guard let changes = MyersDiff.changes(from: old, to: new,
                                                  isCancelled: isCancelled) else {
                throw CancellationError()
            }
            return changes
        }

        let anchors = try increasingUniqueAnchors(old: old, new: new,
                                                  isCancelled: isCancelled)
        var gaps: [Gap] = []
        var oldStart = 0
        var newStart = 0
        // Die Summe der quadratischen Obergrenzen darf nicht größer sein
        // als bei EINEM bisherigen Maximalvergleich. Viele kleine Blöcke
        // dürfen das Schutzbudget nicht vervielfachen.
        var remainingWork = maximumInputLines * maximumInputLines
        for index in 0...anchors.count {
            if index % FileDiff.cancellationCheckStride == 0 { try checkCancellation() }
            let anchor = index < anchors.count
                ? anchors[index] : Anchor(old: old.count, new: new.count)
            var gap = Gap(old: oldStart..<anchor.old, new: newStart..<anchor.new)
            var trimmed = 0
            while !gap.old.isEmpty, !gap.new.isEmpty,
                  old[gap.old.lowerBound] == new[gap.new.lowerBound] {
                if trimmed % FileDiff.cancellationCheckStride == 0 { try checkCancellation() }
                trimmed += 1
                gap.old = (gap.old.lowerBound + 1)..<gap.old.upperBound
                gap.new = (gap.new.lowerBound + 1)..<gap.new.upperBound
            }
            while !gap.old.isEmpty, !gap.new.isEmpty,
                  old[gap.old.upperBound - 1] == new[gap.new.upperBound - 1] {
                if trimmed % FileDiff.cancellationCheckStride == 0 { try checkCancellation() }
                trimmed += 1
                gap.old = gap.old.lowerBound..<(gap.old.upperBound - 1)
                gap.new = gap.new.lowerBound..<(gap.new.upperBound - 1)
            }
            if !gap.old.isEmpty, !gap.new.isEmpty {
                let count = gap.old.count + gap.new.count
                guard count <= maximumInputLines,
                      count * count <= remainingWork else { return nil }
                remainingWork -= count * count
            }
            if !gap.old.isEmpty || !gap.new.isEmpty { gaps.append(gap) }
            oldStart = anchor.old + 1
            newStart = anchor.new + 1
        }

        // Erst alle Bereiche zulassen, dann rechnen: keine lange Vorarbeit
        // für einen Vergleich, dessen letzter Bereich ohnehin zu groß ist.
        var result = MyersDiff.Changes()
        for gap in gaps {
            try checkCancellation()
            if gap.old.isEmpty {
                for offset in gap.new {
                    if offset % FileDiff.cancellationCheckStride == 0 { try checkCancellation() }
                    result.insertedOffsets.append(offset)
                }
            } else if gap.new.isEmpty {
                for offset in gap.old {
                    if offset % FileDiff.cancellationCheckStride == 0 { try checkCancellation() }
                    result.removedOffsets.append(offset)
                }
            } else {
                guard let changes = MyersDiff.changes(
                    from: Array(old[gap.old]), to: Array(new[gap.new]),
                    isCancelled: isCancelled
                ) else { throw CancellationError() }
                for (index, offset) in changes.removedOffsets.enumerated() {
                    if index % FileDiff.cancellationCheckStride == 0 { try checkCancellation() }
                    result.removedOffsets.append(gap.old.lowerBound + offset)
                }
                for (index, offset) in changes.insertedOffsets.enumerated() {
                    if index % FileDiff.cancellationCheckStride == 0 { try checkCancellation() }
                    result.insertedOffsets.append(gap.new.lowerBound + offset)
                }
            }
        }
        try checkCancellation()
        return result
    }

    private static func increasingUniqueAnchors(
        old: [Int], new: [Int], isCancelled: () -> Bool
    ) throws -> [Anchor] {
        func checkCancellation(_ index: Int) throws {
            if index % FileDiff.cancellationCheckStride == 0, isCancelled() {
                throw CancellationError()
            }
        }
        func uniquePositions(_ values: [Int]) throws -> [Int: Int] {
            var positions: [Int: Int] = [:]
            for (index, value) in values.enumerated() {
                try checkCancellation(index)
                // -1 bleibt auch beim dritten Vorkommen uneindeutig.
                positions[value] = positions[value] == nil ? index : -1
            }
            return positions
        }
        let oldPositions = try uniquePositions(old)
        let newPositions = try uniquePositions(new)
        var candidates: [Anchor] = []
        for (index, value) in old.enumerated() {
            try checkCancellation(index)
            if oldPositions[value] == index,
               let other = newPositions[value], other >= 0 {
                candidates.append(Anchor(old: index, new: other))
            }
        }

        // Kandidaten stehen bereits in linker Reihenfolge. Die längste
        // streng steigende rechte Teilfolge verhindert sich kreuzende Anker.
        // Binäre Suche hält die Auswahl bei O(n log n); Dictionary-Reihenfolge
        // entscheidet nie über die dargestellten Unterschiede.
        var tails: [Int] = []
        var predecessors = [Int](repeating: -1, count: candidates.count)
        for (index, candidate) in candidates.enumerated() {
            try checkCancellation(index)
            var lower = 0
            var upper = tails.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if candidates[tails[middle]].new < candidate.new {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            if lower > 0 { predecessors[index] = tails[lower - 1] }
            if lower == tails.count { tails.append(index) } else { tails[lower] = index }
        }
        var result: [Anchor] = []
        var index = tails.last ?? -1
        while index >= 0 {
            try checkCancellation(result.count)
            result.append(candidates[index])
            index = predecessors[index]
        }
        return result.reversed()
    }
}
