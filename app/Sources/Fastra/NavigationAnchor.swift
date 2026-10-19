import Foundation

/// Begrenzter Quellanker statt einer vollständigen Dokumentkopie je Sprung.
struct NavigationAnchor: Equatable, Sendable {
    let revision: UInt64
    let range: NSRange
    let textLength: Int
    let lineText: String?
    let before: String?
    let after: String?
    let column: Int

    init(source: String, revision: UInt64, range: NSRange) {
        let text = source as NSString
        self.revision = revision
        self.textLength = text.length
        self.range = SelectionClamping.clamp(range, textLength: text.length)
        var start = 0, end = 0, contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: self.range.location, length: 0))
        column = self.range.location - start
        func boundedLine(at offset: Int) -> String? {
            guard offset >= 0, offset <= text.length else { return nil }
            var first = 0, last = 0
            text.getLineStart(&first, end: nil, contentsEnd: &last, for: NSRange(location: offset, length: 0))
            guard last - first <= 1024 else { return nil }
            return text.substring(with: NSRange(location: first, length: last - first))
        }
        lineText = boundedLine(at: self.range.location)
        before = start > 0 ? boundedLine(at: start - 1) : nil
        after = end < text.length ? boundedLine(at: end) : nil
    }

    func resolve(in source: String, revision: UInt64, isCancelled: () -> Bool = { false }) -> NSRange? {
        let text = source as NSString
        if revision == self.revision, text.length == textLength { return range }
        guard let lineText, source.utf8.count <= 10 * 1024 * 1024 else { return nil }
        var matches: [(range: NSRange, before: String?, after: String?)] = []
        var offset = 0, count = 0
        func line(at position: Int) -> String? {
            guard position >= 0, position <= text.length else { return nil }
            var start = 0, end = 0
            text.getLineStart(&start, end: nil, contentsEnd: &end, for: NSRange(location: position, length: 0))
            guard end - start <= 1024 else { return nil }
            return text.substring(with: NSRange(location: start, length: end - start))
        }
        while offset <= text.length {
            if isCancelled() || count >= 200_000 { return nil }
            count += 1
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
            if contentsEnd - start <= 1024, line(at: start)?.utf8.elementsEqual(lineText.utf8) == true,
               column + range.length <= contentsEnd - start {
                matches.append((NSRange(location: start + column, length: range.length),
                                start > 0 ? line(at: start - 1) : nil,
                                end < text.length ? line(at: end) : nil))
                if matches.count > 1000 { return nil }
            }
            guard end > offset else { break }
            offset = end
        }
        if matches.count == 1 { return matches[0].range }
        let contextual = matches.filter { candidate in
            equal(candidate.before, before) && equal(candidate.after, after)
        }
        return contextual.count == 1 ? contextual[0].range : nil
    }

    private func equal(_ first: String?, _ second: String?) -> Bool {
        switch (first, second) {
        case (.none, .none): return true
        case (.some(let first), .some(let second)): return first.utf8.elementsEqual(second.utf8)
        default: return false
        }
    }
}
