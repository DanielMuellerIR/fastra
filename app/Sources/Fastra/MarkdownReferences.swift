import Foundation
import cmark_gfm
import cmark_gfm_extensions
import FastraMarkdownMark

enum MarkdownReferences {
    struct Reference: Equatable, Sendable {
        let destination: String
        let line: Int
        let range: NSRange
        let isImage: Bool
    }

    struct Parsed: Sendable {
        var references: [Reference] = []
        var anchors: [String: Int] = [:]
        var incomplete = false
        var unsupportedHTML = false
        var anchorCount = 0
        var anchorsComplete = true
    }

    enum Destination: Equatable {
        case local(URL?, anchor: String?)
        case remote
        case invalid
    }

    static let maximumSourceBytes = 10 * 1024 * 1024
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    static func destination(_ raw: String, documentURL: URL?) -> Destination {
        guard !raw.hasPrefix("//") else { return .remote }
        // Ein codiertes Rautezeichen gehört zum Dateinamen, nicht zum Fragment.
        let parts = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        let anchor = parts.count > 1 ? String(parts[1]).removingPercentEncoding : nil
        if parts.count > 1 && anchor == nil { return .invalid }
        guard path.removingPercentEncoding?.contains("\0") == false,
              anchor?.contains("\0") != true else { return .invalid }
        if path.isEmpty { return .local(documentURL, anchor: anchor) }
        if let scheme = URLComponents(string: path)?.scheme {
            guard scheme.lowercased() == "file" else { return .remote }
            guard let components = URLComponents(string: path),
                  components.host == nil || components.host == "" || components.host == "localhost",
                  let url = components.url, url.isFileURL else { return .remote }
            return .local(url, anchor: anchor)
        }
        guard let decoded = path.removingPercentEncoding, !decoded.contains("\0") else { return .invalid }
        if decoded.hasPrefix("/") { return .local(URL(fileURLWithPath: decoded, isDirectory: false), anchor: anchor) }
        guard let documentURL else { return .local(nil, anchor: anchor) }
        return .local(documentURL.deletingLastPathComponent().appendingPathComponent(decoded, isDirectory: false), anchor: anchor)
    }

    static func parse(_ source: String, maximumReferences: Int = 10_000, maximumAnchors: Int = 10_000,
                      isCancelled: () -> Bool = { false }) throws -> Parsed {
        guard source.utf8.count <= maximumSourceBytes else { throw FileSnapshotReadError.tooLarge(byteCount: UInt64(source.utf8.count)) }
        guard source.utf8.reduce(0, { $0 + ($1 == 10 || $1 == 13 ? 1 : 0) }) <= 200_000 else { throw CocoaError(.fileReadTooLarge) }
        let parsed: Parsed = try MarkdownRichText.renderQueue.sync {
            if isCancelled() { throw CancellationError() }
            let formulas = try MarkdownMath.formulaRanges(in: source) {
                if isCancelled() { throw CancellationError() }
            }.sorted { $0.location < $1.location }
            var formulaEnds: [Int] = []
            for formula in formulas { formulaEnds.append(max(formulaEnds.last ?? 0, formula.upperBound)) }
            let lines = MarkdownVisualDocument.sourceLines(source)
            var offsets = [0]
            for line in lines { offsets.append(offsets.last! + line.utf16.count) }
            func position(_ node: UnsafeMutablePointer<cmark_node>) -> (Int, NSRange) {
                let line = max(1, min(lines.count, Int(cmark_node_get_start_line(node))))
                return (line, NSRange(location: offsets[line - 1], length: 0))
            }
            // Derselbe Quellspannweg wie bei MarkdownSaveAs: cmark zählt
            // UTF-8-Spalten, Sprünge und Formelbereiche dagegen originales UTF-16.
            func offset(_ line: Int, _ column: Int, end: Bool = false) -> Int? {
                guard lines.indices.contains(line - 1), column > 0 else { return nil }
                let text = lines[line - 1]
                let count = min(text.utf8.count, column - (end ? 0 : 1))
                return offsets[line - 1] + String(decoding: text.utf8.prefix(count), as: UTF8.self).utf16.count
            }
            func span(_ node: UnsafeMutablePointer<cmark_node>) -> NSRange? {
                guard let start = offset(Int(cmark_node_get_start_line(node)), Int(cmark_node_get_start_column(node))),
                      let end = offset(Int(cmark_node_get_end_line(node)), Int(cmark_node_get_end_column(node)), end: true),
                      end >= start, end <= source.utf16.count else { return nil }
                return NSRange(location: start, length: end - start)
            }
            func isFormula(_ span: NSRange) -> Bool {
                var lower = 0, upper = formulas.count
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if formulas[middle].location <= span.location { lower = middle + 1 } else { upper = middle }
                }
                return lower > 0 && formulaEnds[lower - 1] >= span.upperBound
            }
            func sourceLine(_ offset: Int) -> Int {
                var lower = 0, upper = lines.count
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if offsets[middle] <= offset { lower = middle + 1 } else { upper = middle }
                }
                return max(1, lower)
            }
            cmark_gfm_core_extensions_ensure_registered()
            guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { throw CocoaError(.coderInvalidValue) }
            guard let mark = fastra_mark_extension_new() else { cmark_parser_free(parser); throw CocoaError(.coderInvalidValue) }
            defer { cmark_parser_free(parser); fastra_mark_extension_free(mark) }
            cmark_parser_attach_syntax_extension(parser, mark)
            for name in ["table", "strikethrough", "autolink", "tasklist"] {
                if let ext = name.withCString({ cmark_find_syntax_extension($0) }) { cmark_parser_attach_syntax_extension(parser, ext) }
            }
            try source.withCString { bytes in
                var offset = 0
                while offset < source.utf8.count {
                    if isCancelled() { throw CancellationError() }
                    let count = min(65_536, source.utf8.count - offset)
                    cmark_parser_feed(parser, bytes.advanced(by: offset), count)
                    offset += count
                }
            }
            guard let document = cmark_parser_finish(parser) else { throw CocoaError(.coderInvalidValue) }
            defer { cmark_node_free(document) }
            guard let iterator = cmark_iter_new(document) else { throw CocoaError(.coderInvalidValue) }
            defer { cmark_iter_free(iterator) }
            var result = Parsed()
            func add(_ value: String, line: Int, range: NSRange, image: Bool) {
                guard result.references.count < maximumReferences else { result.incomplete = true; return }
                result.references.append(Reference(destination: value, line: line, range: range, isImage: image))
            }
            while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
                if isCancelled() { throw CancellationError() }
                guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator) else { continue }
                let type = cmark_node_get_type(node), (line, range) = position(node)
                if type == CMARK_NODE_LINK || type == CMARK_NODE_IMAGE {
                    if let span = span(node), isFormula(span) { continue }
                    if let value = cmark_node_get_url(node) { add(String(cString: value), line: line, range: range, image: type == CMARK_NODE_IMAGE) }
                } else if type == CMARK_NODE_HTML_INLINE || type == CMARK_NODE_HTML_BLOCK,
                          cmark_node_get_literal(node) != nil {
                    guard let span = span(node) else { result.incomplete = true; continue }
                    let html = (source as NSString).substring(with: span)
                    let ns = html as NSString
                    let comments = commentPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).map(\.range)
                    let opaque = opaquePattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).map(\.range)
                    if !opaque.isEmpty { result.unsupportedHTML = true }
                    for tag in tagPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                        guard !(comments + opaque).contains(where: { NSIntersectionRange($0, tag.range).length > 0 }) else { continue }
                        let tagSpan = NSRange(location: span.location + tag.range.location, length: tag.range.length)
                        if isFormula(tagSpan) { continue }
                        let tagText = ns.substring(with: tag.range)
                        if tagText.range(of: #"(?i)^<\s*(script|style)\b"#, options: .regularExpression) != nil { result.unsupportedHTML = true; continue }
                        let attributes = MarkdownHTMLAttributes.parse(html, range: tag.range)
                        let tagLine = sourceLine(tagSpan.location)
                        let offset = offsets[min(max(0, tagLine - 1), offsets.count - 1)]
                        for attribute in attributes {
                            if ["href", "src"].contains(attribute.name) {
                                add(attribute.value, line: tagLine, range: NSRange(location: offset, length: 0), image: attribute.name == "src")
                            } else if attribute.name == "id" || (attribute.name == "name" && tagText.range(of: #"(?i)^<a(?=[\s/>])"#, options: .regularExpression) != nil) {
                                if result.anchorCount < maximumAnchors {
                                    result.anchors[attribute.value, default: 0] += 1; result.anchorCount += 1
                                } else { result.incomplete = true; result.anchorsComplete = false }
                            }
                        }
                        if tagText.range(of: #"(?i)\b(?:srcset|style|poster|data|xlink:href)\s*=|\b(?:href|src|id|name)\s*=\s*[^\s\"']"#, options: .regularExpression) != nil { result.unsupportedHTML = true }
                    }
                }
            }
            return result
        }
        if isCancelled() { throw CancellationError() }
        let result = parsed.addingHeadings(source, maximum: maximumAnchors, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        return result
    }

    private static let commentPattern = try! NSRegularExpression(pattern: #"(?s)<!--.*?(?:-->|$)"#)
    private static let opaquePattern = try! NSRegularExpression(pattern: #"(?is)<\s*(script|style)\b[^>]*>.*?(?:</\s*\1\s*>|$)"#)
    private static let tagPattern = try! NSRegularExpression(pattern: #"(?i)<[a-z][a-z0-9:-]*\b(?:[^\"'<>]|\"[^\"]*\"|'[^']*')*>"#)
}

private extension MarkdownReferences.Parsed {
    func addingHeadings(_ source: String, maximum: Int, isCancelled: () -> Bool) -> Self {
        var result = self
        let headings = MarkdownOutline.headings(in: source, maximumHeadings: maximum + 1, isCancelled: isCancelled)
        // Auch Überschriften ohne Slug verbrauchen das Analysebudget.
        if headings.count > maximum { result.incomplete = true; result.anchorsComplete = false }
        for heading in headings.prefix(maximum) {
            let anchor = HelpContent.anchor(forHeading: heading.title)
            if !anchor.isEmpty {
                guard result.anchorCount < maximum else { result.incomplete = true; result.anchorsComplete = false; break }
                result.anchors[anchor, default: 0] += 1; result.anchorCount += 1
            }
        }
        return result
    }
}
