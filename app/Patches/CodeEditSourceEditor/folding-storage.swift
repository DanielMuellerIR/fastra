import Foundation

// Fastra: Alle verschachtelten Bereiche behalten. Ein Intervallstore mit
// einem Wert je Position verliert Eltern, sobald Kinder dieselben Zeichen belegen.
struct LineFoldStorage: Sendable {
    struct RawFold: Sendable { let depth: Int; let range: Range<Int> }
    struct DepthStartPair: Hashable { let depth: Int; let start: Int }
    var revision: UInt64 = 0
    private var folds: [FoldRange]

    init(documentLength: Int, folds raw: [RawFold] = [], collapsedRanges: Set<DepthStartPair> = []) {
        folds = raw.enumerated().compactMap { index, raw in
            guard raw.range.lowerBound >= 0, raw.range.upperBound <= documentLength,
                  !raw.range.isEmpty else { return nil }
            return FoldRange(id: UInt32(index + 1), depth: raw.depth, range: raw.range,
                             isCollapsed: collapsedRanges.contains(.init(depth: raw.depth,
                                                                         start: raw.range.lowerBound)))
        }.sorted {
            $0.range.lowerBound == $1.range.lowerBound
                ? $0.range.upperBound > $1.range.upperBound : $0.range.lowerBound < $1.range.lowerBound
        }
    }

    mutating func storageUpdated(editedRange: NSRange, changeInLength delta: Int) {
        // Bis der neue Syntaxstand vorliegt, darf kein alter Klickbereich wirken.
        folds.removeAll()
    }

    mutating func toggleCollapse(forFold fold: FoldRange) {
        guard let index = folds.firstIndex(where: { $0.id == fold.id }) else { return }
        folds[index].isCollapsed.toggle()
    }

    mutating func reconcileCollapsed(_ ranges: Set<DepthStartPair>) {
        for index in folds.indices {
            folds[index].isCollapsed = ranges.contains(.init(depth: folds[index].depth,
                                                            start: folds[index].range.lowerBound))
        }
    }

    mutating func markExpanded(range: Range<Int>) {
        guard let index = folds.firstIndex(where: { $0.range == range }) else { return }
        folds[index].isCollapsed = false
    }

    func folds(in range: Range<Int>) -> [FoldRange] {
        folds.filter { $0.range.overlaps(range) }
    }
}
