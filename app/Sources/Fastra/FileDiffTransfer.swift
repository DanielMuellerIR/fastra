import Foundation

enum FileDiffTransfer {
    enum Direction: Hashable, Sendable { case toLeft, toRight }
    enum Failure: Error, LocalizedError, Equatable {
        case stale, noChange, sizeLimit, incomplete
        var errorDescription: String? {
            switch self {
            case .stale:
                L10n.string("Die Vergleichsquellen haben sich geändert oder sind nicht mehr verfügbar. Berechne den Vergleich erneut; es wurde nichts übernommen.")
            case .noChange:
                L10n.string("Der gewählte Block enthält keine wirksame Änderung.")
            case .sizeLimit:
                L10n.string("Die Übernahme ist auf 32 MiB Text je Quelle und Ausgabe sowie 64 MiB Vorschautext begrenzt.")
            case .incomplete:
                L10n.string("Die Übernahmevorschau konnte nicht vollständig berechnet werden. Es wurde nichts übernommen.")
            }
        }
    }
    struct Change: Sendable {
        let direction: Direction
        let range: NSRange
        let replacement: String
        let output: String
    }

    static func prepare(left: String, right: String, result: FileDiff.Result, blockID: Int,
                        direction: Direction, maximumTextBytes: Int = Int(FileLoader.largeFileThreshold),
                        isCancelled: () -> Bool = { false }) throws -> Change {
        if isCancelled() { throw CancellationError() }
        guard left.utf8.count <= maximumTextBytes, right.utf8.count <= maximumTextBytes else { throw Failure.sizeLimit }
        let leftMap = try FileDiffLineMap(left, side: .left, isCancelled: isCancelled)
        let rightMap = try FileDiffLineMap(right, side: .right, isCancelled: isCancelled)
        guard leftMap.lines.count == result.leftLineCount, rightMap.lines.count == result.rightLineCount,
              let block = result.blocks.first(where: { $0.id == blockID }),
              block.firstRowID >= 0, block.lastRowID >= block.firstRowID,
              block.lastRowID < result.rows.count else { throw Failure.stale }
        var beforeCount = 0, afterCount = 0
        for (index, row) in result.rows.enumerated() {
            if index % FileDiff.cancellationCheckStride == 0, isCancelled() { throw CancellationError() }
            guard row.id == index else { throw Failure.stale }
            if let number = row.beforeLine {
                guard number == beforeCount + 1, number <= leftMap.lines.count,
                      row.before?.utf8.elementsEqual(leftMap.content(at: number - 1).utf8) == true else { throw Failure.stale }
                beforeCount += 1
            } else if row.before != nil { throw Failure.stale }
            if let number = row.afterLine {
                guard number == afterCount + 1, number <= rightMap.lines.count,
                      row.after?.utf8.elementsEqual(rightMap.content(at: number - 1).utf8) == true else { throw Failure.stale }
                afterCount += 1
            } else if row.after != nil { throw Failure.stale }
        }
        guard beforeCount == leftMap.lines.count, afterCount == rightMap.lines.count else { throw Failure.stale }
        let selected = result.rows[block.firstRowID...block.lastRowID]
        guard selected.allSatisfy({ $0.kind != .unchanged }) else { throw Failure.stale }
        let destination = direction == .toLeft ? leftMap : rightMap
        let source = direction == .toLeft ? rightMap : leftMap
        let destinationNumbers = selected.compactMap { direction == .toLeft ? $0.beforeLine : $0.afterLine }
        let sourceNumbers = selected.compactMap { direction == .toLeft ? $0.afterLine : $0.beforeLine }
        func rawRange(_ numbers: [Int], in map: FileDiffLineMap, previousCount: Int) -> NSRange {
            guard let first = numbers.first, let last = numbers.last else {
                let location = previousCount < map.lines.count
                    ? map.lines[previousCount].contentRange.location : (map.text as NSString).length
                return NSRange(location: location, length: 0)
            }
            let start = map.lines[first - 1].contentRange.location
            return NSRange(location: start, length: NSMaxRange(map.lines[last - 1].fullRange) - start)
        }
        let previous = result.rows.prefix(block.firstRowID)
        let previousDestinationCount = previous.compactMap { direction == .toLeft ? $0.beforeLine : $0.afterLine }.last ?? 0
        let previousSourceCount = previous.compactMap { direction == .toLeft ? $0.afterLine : $0.beforeLine }.last ?? 0
        var range = rawRange(destinationNumbers, in: destination, previousCount: previousDestinationCount)
        let sourceRange = rawRange(sourceNumbers, in: source, previousCount: previousSourceCount)
        var replacement = (source.text as NSString).substring(with: sourceRange)
        let sourceVirtualOnly = sourceNumbers.count == 1 && source.lines[sourceNumbers[0] - 1].isVirtualFinal
        let destinationVirtualOnly = destinationNumbers.count == 1 && destination.lines[destinationNumbers[0] - 1].isVirtualFinal
        if destinationNumbers.isEmpty && sourceVirtualOnly {
            // Die hinzugefügte Endleerzeile steht für den vorherigen Terminator.
            replacement = source.terminator(at: sourceNumbers[0] - 2)
        } else if sourceNumbers.isEmpty && destinationVirtualOnly {
            range = destination.lines[destinationNumbers[0] - 2].terminatorRange
        } else {
            if !replacement.isEmpty, previousDestinationCount > 0,
               destination.lines[previousDestinationCount - 1].terminatorRange.length == 0,
               NSMaxRange(destination.lines[previousDestinationCount - 1].fullRange) == range.location,
               let first = sourceNumbers.first, first > 1 {
                // Hinter einer unterminierten Zielzeile fehlt noch die Verbindung.
                replacement = source.terminator(at: first - 2) + replacement
            }
            if !replacement.isEmpty, NSMaxRange(range) < (destination.text as NSString).length,
               let lastSource = sourceNumbers.last,
               !source.lines[lastSource - 1].isVirtualFinal,
               source.lines[lastSource - 1].terminatorRange.length == 0 {
                // Ignorierte Zielzeilen hinter dem Block dürfen nicht mit dessen
                // unterminierter Quellzeile verschmelzen.
                guard let lastTarget = destinationNumbers.last,
                      destination.lines[lastTarget - 1].terminatorRange.length > 0 else { throw Failure.stale }
                replacement += destination.terminator(at: lastTarget - 1)
            }
        }
        let output = (destination.text as NSString).replacingCharacters(in: range, with: replacement)
        guard output.utf8.count <= maximumTextBytes else { throw Failure.sizeLimit }
        guard !output.utf8.elementsEqual(destination.text.utf8) else { throw Failure.noChange }
        return Change(direction: direction, range: range, replacement: replacement, output: output)
    }
}
