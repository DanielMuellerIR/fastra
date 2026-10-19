import Foundation
import cmark_gfm
import cmark_gfm_extensions
import FastraMarkdownMark

enum MarkdownOutline {
    static func headings(in source: String, maximumHeadings: Int = .max,
                         isCancelled: () -> Bool = { false }) -> [DocumentOutlineEntry] {
        MarkdownRichText.renderQueue.sync {
            let lines = MarkdownVisualDocument.sourceLines(source)
            let math = MarkdownMath.extract(from: MarkdownVisualDocument.normalizedLines(source))
            guard let document = math.markdown.withCString({ cmark_parse_document($0, math.markdown.utf8.count, CMARK_OPT_DEFAULT) }) else { return [] }
            defer { cmark_node_free(document) }
            guard let iterator = cmark_iter_new(document) else { return [] }
            defer { cmark_iter_free(iterator) }
            var offsets = [0]
            for line in lines { offsets.append(offsets.last! + line.utf16.count) }
            var result: [DocumentOutlineEntry] = []
            while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
                if isCancelled() || result.count >= maximumHeadings { break }
                guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER,
                      let node = cmark_iter_get_node(iterator), cmark_node_get_type(node) == CMARK_NODE_HEADING else { continue }
                let start = math.originalLine(for: Int(cmark_node_get_start_line(node)))
                let end = math.originalLine(for: Int(cmark_node_get_end_line(node)))
                guard start > 0, start <= lines.count, end >= start else { continue }
                // Der Originalausschnitt erhält auch Formeln und Entities im Titel;
                // der vorverarbeitete Baum liefert nur die verlässliche Struktur.
                let original = lines[(start - 1)..<min(end, lines.count)].joined()
                result.append(.init(title: plainTitle(in: original), level: Int(cmark_node_get_heading_level(node)), line: start,
                                    range: NSRange(location: offsets[start - 1], length: 0)))
            }
            return result
        }
    }

    private static func plainTitle(in source: String) -> String {
        let fallback = source.trimmingCharacters(in: .whitespacesAndNewlines)
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return fallback }
        guard let mark = fastra_mark_extension_new() else { cmark_parser_free(parser); return fallback }
        defer { cmark_parser_free(parser); fastra_mark_extension_free(mark) }
        cmark_parser_attach_syntax_extension(parser, mark)
        if let strike = "strikethrough".withCString({ cmark_find_syntax_extension($0) }) {
            cmark_parser_attach_syntax_extension(parser, strike)
        }
        source.withCString { cmark_parser_feed(parser, $0, source.utf8.count) }
        guard let document = cmark_parser_finish(parser) else { return fallback }
        defer { cmark_node_free(document) }
        guard let iterator = cmark_iter_new(document) else { return fallback }
        defer { cmark_iter_free(iterator) }
        var parts: [String] = []
        while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
            guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER,
                  let node = cmark_iter_get_node(iterator) else { continue }
            let type = cmark_node_get_type(node)
            if type == CMARK_NODE_TEXT || type == CMARK_NODE_CODE {
                if let literal = cmark_node_get_literal(node) { parts.append(String(cString: literal)) }
            } else if type == CMARK_NODE_SOFTBREAK || type == CMARK_NODE_LINEBREAK {
                parts.append(" ")
            } else if type == CMARK_NODE_HTML_INLINE, let literal = cmark_node_get_literal(node),
                      String(cString: literal).lowercased().hasPrefix("<br") {
                parts.append(" ")
            }
        }
        return parts.joined().replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
