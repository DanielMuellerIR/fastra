import Foundation

/// Dieselben logischen Zeilen tragen Anzeigeinhalt und exakte Rohbereiche.
/// Die virtuelle Endleerzeile gehört zum Diff, besitzt aber keinen Rohtext.
struct FileDiffLineMap {
    struct Line {
        let contentRange: NSRange
        let terminatorRange: NSRange
        let isVirtualFinal: Bool
        var fullRange: NSRange {
            NSRange(location: contentRange.location,
                    length: NSMaxRange(terminatorRange) - contentRange.location)
        }
    }

    let text: String
    let lines: [Line]
    private let source: NSString

    init(_ text: String, side: FileDiffSideRole = .left, isCancelled: () -> Bool = { false }) throws {
        self.text = text
        let ns = text as NSString
        source = ns
        guard ns.length > 0 else {
            lines = [Line(contentRange: NSRange(location: 0, length: 0),
                          terminatorRange: NSRange(location: 0, length: 0), isVirtualFinal: false)]
            return
        }
        var result: [Line] = [], index = 0, endedWithTerminator = false
        while index < ns.length {
            if result.count % FileDiff.cancellationCheckStride == 0, isCancelled() { throw CancellationError() }
            // Viele kurze Zeilen können die Rohspan-Liste sonst schon vor
            // der späteren Diff-Prüfung weit über das Textbudget aufblasen.
            guard result.count < FileDiff.maximumLineCount else {
                throw FileDiffLimitation.tooManyLines(side: side, limit: FileDiff.maximumLineCount)
            }
            var end = NSNotFound, contentsEnd = NSNotFound
            ns.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                            for: NSRange(location: index, length: 0))
            guard end != NSNotFound, contentsEnd != NSNotFound,
                  end > index, contentsEnd >= index else { break }
            result.append(Line(contentRange: NSRange(location: index, length: contentsEnd - index),
                               terminatorRange: NSRange(location: contentsEnd, length: end - contentsEnd),
                               isVirtualFinal: false))
            endedWithTerminator = contentsEnd < end
            index = end
        }
        if endedWithTerminator {
            guard result.count < FileDiff.maximumLineCount else {
                throw FileDiffLimitation.tooManyLines(side: side, limit: FileDiff.maximumLineCount)
            }
            result.append(Line(contentRange: NSRange(location: ns.length, length: 0),
                               terminatorRange: NSRange(location: ns.length, length: 0), isVirtualFinal: true))
        }
        lines = result
    }

    func content(at index: Int) -> String { source.substring(with: lines[index].contentRange) }
    func terminator(at index: Int) -> String { source.substring(with: lines[index].terminatorRange) }
}
