import Foundation
import Darwin
import cmark_gfm
import cmark_gfm_extensions
import FastraMarkdownMark

/// Originale bleiben pro Block erhalten. Nur tatsächlich bearbeitete Blöcke
/// werden aus dem DOM neu geschrieben; Referenzdefinitionen und fremde
/// Erweiterungen dürfen beim Bearbeiten eines anderen Absatzes nicht verschwinden.
struct MarkdownVisualDocument {
    struct Block: Codable {
        let id: Int
        let source: String
        let html: String
        let hidden: Bool
    }
    let blocks: [Block]
    let opaqueSources: [String: String]
    let fragment: MarkdownRenderedFragment

    static func render(_ markdown: String, documentURL: URL?) -> Self {
        MarkdownRichText.renderQueue.sync { renderOnQueue(markdown, documentURL: documentURL) }
    }

    private static func renderOnQueue(_ markdown: String, documentURL: URL?) -> Self {
        let math = MarkdownMath.extract(from: normalizedLines(markdown))
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT),
              let mark = fastra_mark_extension_new() else {
            return fallback(markdown, documentURL: documentURL)
        }
        defer { cmark_parser_free(parser); fastra_mark_extension_free(mark) }
        cmark_parser_attach_syntax_extension(parser, mark)
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            name.withCString {
                if let ext = cmark_find_syntax_extension($0) {
                    cmark_parser_attach_syntax_extension(parser, ext)
                }
            }
        }
        math.markdown.withCString { cmark_parser_feed(parser, $0, math.markdown.utf8.count) }
        guard let document = cmark_parser_finish(parser) else {
            return fallback(markdown, documentURL: documentURL)
        }
        defer { cmark_node_free(document) }
        var opaqueSources: [String: String] = [:]
        if let iterator = cmark_iter_new(document) {
            var replacements: [(UnsafeMutablePointer<cmark_node>, String)] = []
            while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
                guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER,
                      let node = cmark_iter_get_node(iterator),
                      cmark_node_get_type(node) == CMARK_NODE_HTML_INLINE,
                      let literal = cmark_node_get_literal(node) else { continue }
                let raw = String(cString: literal)
                let lower = raw.lowercased()
                if lower.hasPrefix("<!--") || lower.hasPrefix("<script") || lower.hasPrefix("</script") {
                    replacements.append((node, raw))
                }
            }
            cmark_iter_free(iterator)
            for (node, raw) in replacements {
                guard let atom = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) else { continue }
                let key = UUID().uuidString
                opaqueSources[key] = raw
                let html = "<span data-md-opaque=\"\(key)\" contenteditable=\"false\" class=\"fastra-preserved-content\">⋯</span>"
                html.withCString { _ = cmark_node_set_on_enter(atom, $0) }
                _ = cmark_node_replace(node, atom)
                cmark_node_free(node)
            }
        }
        guard MarkdownHTMLSanitizing.apply(to: document) else {
            return fallback(markdown, documentURL: documentURL)
        }
        let lines = sourceLines(markdown)
        var blocks: [Block] = []
        var images: [String: URL] = [:]
        var cursor = 0
        func append(_ source: String, html: String, hidden: Bool) {
            let resolved = MarkdownImages.resolve(in: html, relativeTo: documentURL,
                                                  preservingSource: true)
            images.merge(resolved.imageURLs) { _, new in new }
            blocks.append(Block(id: blocks.count, source: source,
                                html: resolved.html, hidden: hidden))
        }
        func source(_ start: Int, _ end: Int) -> String {
            guard start < end else { return "" }
            return lines[start..<end].joined()
        }
        func appendGap(_ raw: String) {
            for line in sourceLines(raw) where !line.isEmpty {
                let content = line.trimmingCharacters(in: .newlines)
                let visible = content.count >= 2 && content.allSatisfy { $0 == " " }
                append(line, html: visible ? "<div class=\"\(MarkdownVisibleBlankLines.cssClass)\"><br></div>" : "", hidden: !visible)
            }
        }
        var node = cmark_node_first_child(document)
        while let current = node {
            node = cmark_node_next(current)
            let start = max(cursor, min(lines.count, math.originalLine(for: Int(cmark_node_get_start_line(current))) - 1))
            let after = math.originalLine(for: Int(cmark_node_get_end_line(current)) + 1) - 1
            let end = max(start, min(lines.count, after))
            if cursor < start { appendGap(source(cursor, start)) }
            guard start < end else { continue }
            let html: String
            if let rendered = cmark_render_html(current, CMARK_OPT_UNSAFE,
                                                cmark_parser_get_syntax_extensions(parser)) {
                html = math.insertingHTML(into: String(cString: rendered))
                free(rendered)
            } else {
                html = "<p>" + escaped(source(start, end)) + "</p>"
            }
            var enhancedHTML = html
            let diagrams = try! NSRegularExpression(pattern: #"(?s)<pre><code class="language-mermaid">(.*?)</code></pre>"#)
            for match in diagrams.matches(in: html, range: NSRange(location: 0, length: html.utf16.count)).reversed() {
                let code = (html as NSString).substring(with: match.range(at: 1))
                    .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
                let key = UUID().uuidString
                opaqueSources[key] = "\n\n```mermaid\n" + code + "```\n\n"
                let original = (html as NSString).substring(with: match.range)
                enhancedHTML = (enhancedHTML as NSString).replacingCharacters(in: match.range,
                    with: "<section data-md-opaque=\"\(key)\" contenteditable=\"false\">\(original)</section>")
            }
            let renderedHTML: String
            let isMermaid = cmark_node_get_type(current) == CMARK_NODE_CODE_BLOCK
                && cmark_node_get_fence_info(current).map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) == "mermaid" } == true
            if cmark_node_get_type(current) == CMARK_NODE_HTML_BLOCK || isMermaid {
                let key = UUID().uuidString
                opaqueSources[key] = source(start, end)
                renderedHTML = "<section data-md-opaque=\"\(key)\" contenteditable=\"false\">\(html.isEmpty ? "⋯" : html)</section>"
            } else { renderedHTML = enhancedHTML }
            append(source(start, end), html: renderedHTML, hidden: renderedHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            cursor = end
        }
        if cursor < lines.count { appendGap(source(cursor, lines.count)) }
        let html = blocks.filter { !$0.hidden }.map { "<div data-md-block=\"\($0.id)\">\($0.html)</div>" }.joined()
        return Self(blocks: blocks, opaqueSources: opaqueSources, fragment: MarkdownRenderedFragment(html: html, imageURLs: images))
    }

    static func normalizedLines(_ source: String) -> String {
        source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func sourceLines(_ source: String) -> [String] {
        let text = source as NSString
        var result: [String] = []
        var offset = 0
        while offset < text.length {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                              for: NSRange(location: offset, length: 0))
            result.append(text.substring(with: NSRange(location: start, length: end - start)))
            offset = end
        }
        if source.isEmpty || source.hasSuffix("\n") || source.hasSuffix("\r") { result.append("") }
        return result
    }

    private static func fallback(_ markdown: String, documentURL: URL?) -> Self {
        let html = "<p>" + escaped(markdown).replacingOccurrences(of: "\n", with: "<br>") + "</p>"
        return Self(blocks: [Block(id: 0, source: markdown, html: html, hidden: false)],
                    opaqueSources: [:], fragment: MarkdownRenderedFragment(html: "<div data-md-block=\"0\">\(html)</div>", imageURLs: [:]))
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
