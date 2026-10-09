import Foundation
import cmark_gfm

/// Dieselbe einmalige Entity-Auflösung wie im Markdown-Parser, vor URL-Prüfungen.
enum MarkdownHTMLEntities {
    static func decode(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var buffer = cmark_strbuf()
        cmark_strbuf_init(cmark_get_default_mem_allocator(), &buffer, 0)
        defer { cmark_strbuf_free(&buffer) }
        let bytes = Array(value.utf8)
        bytes.withUnsafeBufferPointer { input in
            houdini_unescape_html_f(&buffer, input.baseAddress, Int32(input.count))
        }
        return String(decoding: UnsafeBufferPointer(start: buffer.ptr, count: Int(buffer.size)), as: UTF8.self)
    }
}

/// Überspringt komplette gequotete Werte, auch wenn darin src= als Text vorkommt.
enum MarkdownHTMLAttributes {
    struct Attribute {
        let name: String
        let value: String
        let valueRange: NSRange
    }
    private static let pattern = try! NSRegularExpression(pattern: #"(?i)\s+([a-z][a-z0-9-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
    static func parse(_ html: String, range: NSRange? = nil) -> [Attribute] {
        let ns = html as NSString
        return pattern.matches(in: html, range: range ?? NSRange(location: 0, length: ns.length)).map { match in
            let valueRange = match.range(at: match.range(at: 2).location == NSNotFound ? 3 : 2)
            return Attribute(name: ns.substring(with: match.range(at: 1)).lowercased(),
                             value: MarkdownHTMLEntities.decode(ns.substring(with: valueRange)), valueRange: valueRange)
        }
    }
}
