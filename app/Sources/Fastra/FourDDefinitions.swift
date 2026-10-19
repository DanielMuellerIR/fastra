import Foundation

/// Gemeinsame Definitionen für Gliederung und Zielsprung. Der vorhandene
/// Tokenizer entscheidet, ob eine Kopfzeile tatsächlich Code ist.
enum FourDDefinitions {
    enum Kind: String, Equatable, Sendable { case function, getter, setter, query, orderBy, constructor }
    struct Definition: Equatable, Sendable {
        let name: String
        let kind: Kind
        let line: Int
        let range: NSRange
    }

    static let functionModifiers: Set<String> = ["exposed", "local", "server", "shared", "onhttpget"]

    private static let function = try! NSRegularExpression(
        pattern: #"^[\t ]*(?:(?:exposed|local|server|shared|onHTTPGet)[\t ]+)*(Function)[\t ]+(?:(get|set|query|orderBy)[\t ]+)?([\p{L}_][\p{L}\p{N}_]*)[\t ]*(?=\()"#,
        options: [.anchorsMatchLines, .caseInsensitive])
    private static let constructor = try! NSRegularExpression(
        pattern: #"^[\t ]*(?:(?:shared|singleton|session)[\t ]+)*(Class[\t ]+constructor)[\t ]*(?=\()"#,
        options: [.anchorsMatchLines, .caseInsensitive])

    static func definitions(in source: String, maximum: Int = 10_000,
                            isCancelled: () -> Bool = { false }) -> [Definition]? {
        guard source.utf8.count <= 10 * 1024 * 1024,
              let tokens = FourDTokenizer.tokenize(source, isCancelled: isCancelled) else { return nil }
        let text = source as NSString
        var sites = Set<Int>(), inSQL = false
        for token in tokens where token.kind == .keyword || token.kind == .command {
            if isCancelled() { return nil }
            let word = text.substring(with: token.range).lowercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if word == "begin sql" { inSQL = true; continue }
            if word == "end sql" { inSQL = false; continue }
            if !inSQL && ["function", "class constructor"].contains(word) { sites.insert(token.range.location) }
        }
        var lineStarts = [0], offset = 0
        while offset < text.length {
            if isCancelled() || lineStarts.count > 200_000 { return nil }
            var end = 0
            text.getLineStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: offset, length: 0))
            guard end > offset else { return nil }
            offset = end
            if end < text.length { lineStarts.append(end) }
        }
        func line(at location: Int) -> Int {
            var low = 0, high = lineStarts.count
            while low < high {
                let middle = (low + high) / 2
                if lineStarts[middle] <= location { low = middle + 1 } else { high = middle }
            }
            return low
        }
        var result: [Definition] = []
        for (regex, isConstructor) in [(function, false), (constructor, true)] {
            regex.enumerateMatches(in: source, range: NSRange(location: 0, length: text.length)) { match, _, stop in
                if isCancelled() || result.count >= maximum { stop.pointee = true; return }
                guard let match, sites.contains(match.range(at: 1).location) else { return }
                let kind: Kind
                let name: String
                if isConstructor { kind = .constructor; name = "Class constructor" }
                else {
                    let accessor = match.range(at: 2)
                    let word = accessor.location == NSNotFound ? "" : text.substring(with: accessor).lowercased()
                    kind = word == "get" ? .getter : word == "set" ? .setter : word == "query" ? .query : word == "orderby" ? .orderBy : .function
                    name = text.substring(with: match.range(at: 3))
                }
                result.append(.init(name: name, kind: kind, line: line(at: match.range.location),
                                    range: match.range))
            }
        }
        guard !isCancelled() else { return nil }
        return result.sorted { $0.range.location < $1.range.location }
    }
}
