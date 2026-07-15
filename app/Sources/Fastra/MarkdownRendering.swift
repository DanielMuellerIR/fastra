import Foundation

/// Ergebnis eines Render-Schritts: HTML plus die bewusst freigegebenen lokalen
/// Bilder. Im HTML stehen nur blickdichte Tokens, nie absolute Dateipfade.
struct MarkdownRenderedFragment {
    let html: String
    let imageURLs: [String: URL]
}

/// Erkennt dieselbe bewusst strenge TeX-Schreibweise wie Number One:
/// `$…$` inline und `$$…$$` als Block. Code-Spans und Code-Fences werden vorher
/// geschützt, damit Shell-Variablen und Beispielcode unverändert bleiben.
enum MarkdownMath {
    struct Extraction {
        let markdown: String
        private let replacements: [(token: String, html: String, block: Bool)]

        init(markdown: String,
             replacements: [(token: String, html: String, block: Bool)]) {
            self.markdown = markdown
            self.replacements = replacements
        }

        func insertingHTML(into renderedHTML: String) -> String {
            replacements.reduce(renderedHTML) { html, replacement in
                var result = html
                if replacement.block {
                    result = result.replacingOccurrences(
                        of: "<p>\(replacement.token)</p>",
                        with: replacement.html
                    )
                }
                return result.replacingOccurrences(
                    of: replacement.token,
                    with: replacement.html
                )
            }
        }
    }

    private static let fencedCode = try! NSRegularExpression(
        pattern: #"(?ms)(^|\n)([ \t]{0,3})(`{3,}|~{3,})[^\n]*\n.*?\n[ \t]{0,3}\3[ \t]*(?=\n|$)"#
    )
    private static let inlineCode = try! NSRegularExpression(
        pattern: #"`+[^`\n]*`+"#
    )
    private static let blockMath = try! NSRegularExpression(
        pattern: #"(?ms)^[ \t]*\$\$[ \t]*(?:\n)?(.+?)(?:\n)?[ \t]*\$\$[ \t]*$"#
    )
    private static let inlineDoubleMath = try! NSRegularExpression(
        pattern: #"(?<!\\)\$\$(?!\s)(.+?)(?<!\s)\$\$"#
    )
    private static let inlineMath = try! NSRegularExpression(
        pattern: #"(?<![\\$])\$(?![\s$])([^$\n]+?)(?<![\s$])\$(?!\$)"#
    )

    static func extract(from markdown: String) -> Extraction {
        var protected: [(token: String, source: String)] = []
        var working = stashMatches(
            of: fencedCode,
            in: markdown,
            prefix: "FASTRACODEBLOCK",
            storage: &protected
        )
        working = stashMatches(
            of: inlineCode,
            in: working,
            prefix: "FASTRACODESPAN",
            storage: &protected
        )

        var replacements: [(token: String, html: String, block: Bool)] = []
        working = replaceMath(
            using: blockMath,
            in: working,
            block: true,
            storage: &replacements
        )
        working = replaceMath(
            using: inlineDoubleMath,
            in: working,
            block: false,
            storage: &replacements
        )
        working = replaceMath(
            using: inlineMath,
            in: working,
            block: false,
            storage: &replacements
        )

        for item in protected {
            working = working.replacingOccurrences(of: item.token, with: item.source)
        }
        return Extraction(markdown: working, replacements: replacements)
    }

    private static func stashMatches(of regex: NSRegularExpression,
                                     in source: String,
                                     prefix: String,
                                     storage: inout [(token: String, source: String)]) -> String {
        let mutable = NSMutableString(string: source)
        let matches = regex.matches(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        )
        for match in matches.reversed() {
            let token = "\(prefix)\(storage.count)TOKEN"
            let original = (source as NSString).substring(with: match.range)
            storage.append((token, original))
            mutable.replaceCharacters(in: match.range, with: token)
        }
        return mutable as String
    }

    private static func replaceMath(
        using regex: NSRegularExpression,
        in source: String,
        block: Bool,
        storage: inout [(token: String, html: String, block: Bool)]
    ) -> String {
        let mutable = NSMutableString(string: source)
        let matches = regex.matches(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        )
        for match in matches.reversed() where match.numberOfRanges > 1 {
            let tex = (source as NSString).substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tex.isEmpty else { continue }
            let token = "FASTRAMATH\(storage.count)TOKEN"
            let kind = block ? "div" : "span"
            let cssClass = block ? "math-block" : "math-inline"
            let html = "<\(kind) class=\"\(cssClass)\" data-tex=\"\(htmlAttributeEscaped(tex))\"></\(kind)>"
            storage.append((token, html, block))
            mutable.replaceCharacters(in: match.range, with: token)
        }
        return mutable as String
    }

    private static func htmlAttributeEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

/// Schreibt lokale Bildquellen in interne Tokens um. Remote-URLs, Protokoll-
/// relative URLs und beliebige Schemes werden geleert, bevor WebKit das HTML
/// sieht; dadurch kann das Öffnen einer Datei keinen Netzabruf auslösen.
enum MarkdownImages {
    private static let sourceAttribute = try! NSRegularExpression(
        pattern: #"(?i)\bsrc\s*=\s*([\"'])([^\"']*)\1"#
    )

    static func resolve(in html: String, relativeTo documentURL: URL?) -> MarkdownRenderedFragment {
        let mutable = NSMutableString(string: html)
        let matches = sourceAttribute.matches(
            in: html,
            range: NSRange(html.startIndex..., in: html)
        )
        var images: [String: URL] = [:]

        for match in matches.reversed() where match.numberOfRanges > 2 {
            let sourceRange = match.range(at: 2)
            let rawSource = (html as NSString).substring(with: sourceRange)
            let replacement: String
            if let imageURL = localImageURL(from: rawSource, documentURL: documentURL),
               MarkdownPreviewAssets.imageMIMEType(for: imageURL) != nil {
                let token = "image-\(images.count)"
                images[token] = imageURL
                replacement = "\(MarkdownPreviewAssets.scheme)://image/\(token)"
            } else {
                replacement = ""
            }
            mutable.replaceCharacters(in: sourceRange, with: replacement)
        }
        return MarkdownRenderedFragment(html: mutable as String, imageURLs: images)
    }

    private static func localImageURL(from rawSource: String,
                                      documentURL: URL?) -> URL? {
        let decoded = htmlUnescaped(rawSource).removingPercentEncoding ?? htmlUnescaped(rawSource)
        guard !decoded.isEmpty,
              !decoded.hasPrefix("//") else { return nil }

        let withoutFragment = decoded.split(separator: "#", maxSplits: 1).first.map(String.init) ?? decoded
        if let components = URLComponents(string: withoutFragment), components.scheme != nil {
            return nil
        }
        guard !withoutFragment.hasPrefix("/"), let documentURL else { return nil }
        return documentURL.deletingLastPathComponent()
            .appendingPathComponent(withoutFragment)
            .standardizedFileURL
    }

    private static func htmlUnescaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
