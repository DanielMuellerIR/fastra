import Foundation
import Darwin
import cmark_gfm
import cmark_gfm_extensions

/// Die tatsächlich vom Parser verwendeten Bilder: Beispiele in Codeblöcken
/// und unbenutzte Referenzdefinitionen dürfen keine Dateien mitkopieren.
enum MarkdownSaveAs {
    struct Prepared {
        let content: String
        let createdImages: [MarkdownImageStore.StoredImage]
        func commit() { MarkdownImageStore.releaseReservations(createdImages) }
        func rollback() {
            defer { MarkdownImageStore.releaseReservations(createdImages) }
            guard !createdImages.isEmpty else { return }
            let mover = MarkdownImageUndoFileMover(images: createdImages)
            if mover.stashCreatedFiles() { mover.discardStash() }
        }
    }
    private struct Reference {
        let range: NSRange
        let url: URL
        let replacement: (String) -> String
    }

    static func prepare(content: String, sourceURL: URL, targetURL: URL) throws -> Prepared {
        guard sourceURL.deletingLastPathComponent().canonicalFileURL
                != targetURL.deletingLastPathComponent().canonicalFileURL else {
            return Prepared(content: content, createdImages: [])
        }
        let references = MarkdownRichText.renderQueue.sync {
            imageReferences(content, sourceURL: sourceURL)
        }
        var copies: [URL: MarkdownImageStore.StoredImage] = [:]
        var created: [MarkdownImageStore.StoredImage] = []
        do {
            for reference in references where copies[reference.url] == nil {
                let stored = try MarkdownImageStore.storeImageFile(reference.url, documentURL: targetURL, reserveForTransaction: true)
                copies[reference.url] = stored
                if stored.createdByInsertion { created.append(stored) }
            }
            let output = NSMutableString(string: content)
            for reference in references.sorted(by: { $0.range.location > $1.range.location }) {
                guard let copy = copies[reference.url],
                      let path = MarkdownImageStore.relativeLinkPath(from: targetURL, to: copy.fileURL) else { continue }
                output.replaceCharacters(in: reference.range, with: reference.replacement(path))
            }
            return Prepared(content: output as String, createdImages: created)
        } catch {
            Prepared(content: content, createdImages: created).rollback()
            throw error
        }
    }

    private static func imageReferences(_ source: String, sourceURL: URL) -> [Reference] {
        cmark_gfm_core_extensions_ensure_registered()
        let formulas = MarkdownMath.formulaRanges(in: source)
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return [] }
        defer { cmark_parser_free(parser) }
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            name.withCString { if let ext = cmark_find_syntax_extension($0) { cmark_parser_attach_syntax_extension(parser, ext) } }
        }
        source.withCString { cmark_parser_feed(parser, $0, source.utf8.count) }
        guard let document = cmark_parser_finish(parser) else { return [] }
        defer { cmark_node_free(document) }
        let lines = MarkdownVisualDocument.sourceLines(source)
        let offsets = lines.reduce(into: [0]) { $0.append($0.last! + $1.utf16.count) }
        func position(_ line: Int, _ column: Int, end: Bool = false) -> Int? {
            let originalLine = line - 1
            guard lines.indices.contains(originalLine), column > 0 else { return nil }
            let text = lines[originalLine]
            let bytes = min(text.utf8.count, column - (end ? 0 : 1))
            return offsets[originalLine] + String(decoding: text.utf8.prefix(bytes), as: UTF8.self).utf16.count
        }
        func range(_ node: UnsafeMutablePointer<cmark_node>) -> NSRange? {
            guard let start = position(Int(cmark_node_get_start_line(node)), Int(cmark_node_get_start_column(node))),
                  let end = position(Int(cmark_node_get_end_line(node)), Int(cmark_node_get_end_column(node)), end: true),
                  end >= start, end <= source.utf16.count else { return nil }
            return NSRange(location: start, length: end - start)
        }
        func local(_ destination: String) -> URL? {
            guard !destination.hasPrefix("/"),
                  URLComponents(string: destination)?.scheme == nil,
                  !destination.isEmpty else { return nil }
            let path = destination.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? destination
            guard let decoded = path.removingPercentEncoding else { return nil }
            let url = sourceURL.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL
            return MarkdownPreviewAssets.imageMIMEType(for: url) != nil ? url : nil
        }
        guard let iterator = cmark_iter_new(document) else { return [] }
        defer { cmark_iter_free(iterator) }
        var references: [Reference] = []
        let srcPattern = try! NSRegularExpression(pattern: #"(?i)<img\b[^>]*?\bsrc\s*=\s*(["'])([^"']*)\1[^>]*>"#)
        while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
            guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER,
                  let node = cmark_iter_get_node(iterator), let span = range(node) else { continue }
            let overlapsFormula = formulas.contains {  $0.location <= span.location && $0.upperBound >= span.upperBound }
            var parent = cmark_node_parent(node)
            var imageAncestor = false
            while let current = parent {
                if cmark_node_get_type(current) == CMARK_NODE_IMAGE { imageAncestor = true; break }
                parent = cmark_node_parent(current)
            }
            if !overlapsFormula, !imageAncestor, cmark_node_get_type(node) == CMARK_NODE_IMAGE,
               let destination = cmark_node_get_url(node),
               let url = local(String(cString: destination)) {
                // CommonMark rendert einen einzelnen Bildknoten samt Alt-Text
                // und Titel. Nur dessen tatsächlich benutzte Referenz wird ersetzt.
                references.append(Reference(range: span, url: url, replacement: { path in
                    path.withCString { _ = cmark_node_set_url(node, $0) }
                    guard let rendered = cmark_render_commonmark(node, CMARK_OPT_DEFAULT, 0) else { return "" }
                    defer { free(rendered) }
                    return String(cString: rendered).trimmingCharacters(in: .newlines)
                }))
            } else if [CMARK_NODE_HTML_BLOCK, CMARK_NODE_HTML_INLINE].contains(cmark_node_get_type(node)),
                      cmark_node_get_literal(node) != nil {
                // Die Literalspalten gehören zum Original, einschließlich
                // CRLF. Normalisierte Parser-Literale wären hier falsch.
                let raw = (source as NSString).substring(with: span)
                var sanitizer = MarkdownHTMLWhitelist.Sanitizer()
                let sanitized = sanitizer.sanitize(raw)
                let commentPattern = try! NSRegularExpression(pattern: #"(?s)<!--.*?(?:-->|$)"#)
                let comments = commentPattern.matches(in: raw, range: NSRange(location: 0, length: raw.utf16.count)).map(\.range)
                for match in srcPattern.matches(in: raw, range: NSRange(location: 0, length: raw.utf16.count)) {
                    let value = (raw as NSString).substring(with: match.range(at: 2))
                        .replacingOccurrences(of: "&amp;", with: "&")
                        .replacingOccurrences(of: "&quot;", with: "\"")
                        .replacingOccurrences(of: "&#39;", with: "'")
                    guard !comments.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                          sanitized.contains("src="), let url = local(value),
                          match.range(at: 2).upperBound <= span.length else { continue }
                    references.append(Reference(range: NSRange(location: span.location + match.range(at: 2).location,
                                                               length: match.range(at: 2).length), url: url, replacement: { $0 }))
                }
            }
        }
        // Die Closures dürfen den freigegebenen Parserbaum nicht behalten.
        return references.map { reference in
            let template = reference.replacement("FASTRA_IMAGE_DESTINATION_TOKEN")
            return Reference(range: reference.range, url: reference.url,
                             replacement: { template.replacingOccurrences(of: "FASTRA_IMAGE_DESTINATION_TOKEN", with: $0) })
        }
    }
}
