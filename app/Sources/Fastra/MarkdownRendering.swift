import Foundation
import cmark_gfm

/// Ergebnis eines Render-Schritts: HTML plus die bewusst freigegebenen lokalen
/// Bilder. Im HTML stehen nur blickdichte Tokens, nie absolute Dateipfade.
struct MarkdownRenderedFragment {
    let html: String
    let imageURLs: [String: URL]
}

/// Fastra-Dialekt für bewusst sichtbare Leerzeilen: Eine Quellzeile aus
/// mindestens zwei ASCII-Leerzeichen wird als genau eine leere Textzeile in
/// den bereits geparsten CommonMark-Baum eingesetzt.
///
/// Die Ergänzung geschieht absichtlich NACH dem Parsen. Ein Texttoken vor dem
/// Parser würde zum Beispiel eine zusammenhängende Liste in zwei Listen
/// zerlegen. Der kontrollierte Custom-Block ändert dagegen keine vorhandene
/// GFM-Struktur und wird auch ohne `CMARK_OPT_UNSAFE` gerendert. Nutzer-HTML
/// gelangt über diesen Weg nie in die Ausgabe.
enum MarkdownVisibleBlankLines {
    static let cssClass = "fastra-visible-blank-line"

    static func insert(into document: UnsafeMutablePointer<cmark_node>,
                       markdown: String,
                       extraction: MarkdownMath.Extraction) {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for (offset, line) in normalized.components(separatedBy: "\n").enumerated()
            where isVisibleBlankLine(line) {
            let preparedLine = offset + 1
            let originalLine = extraction.originalLine(for: preparedLine)
            _ = insert(line: preparedLine, originalLine: originalLine, into: document)
        }
    }

    private static func isVisibleBlankLine(_ line: String) -> Bool {
        line.count >= 2 && line.utf8.allSatisfy { $0 == 0x20 }
    }

    /// Sucht im vorhandenen Baum den Quellabstand, zu dem die Leerzeile
    /// gehört. Innerhalb einer Liste landet sie im vorangehenden Listeneintrag;
    /// dadurch bleibt der vom Parser bestimmte Listenblock unangetastet.
    private static func insert(line: Int,
                               originalLine: Int,
                               into container: UnsafeMutablePointer<cmark_node>) -> Bool {
        let children = originalChildren(of: container)

        if let enclosing = children.first(where: {
            Int(cmark_node_get_start_line($0)) <= line
                && line <= Int(cmark_node_get_end_line($0))
        }) {
            let type = cmark_node_get_type(enclosing)
            // Wörtliche Blöcke besitzen ihre eigene Leerraumsemantik. Eine
            // Leerzeichenzeile darin bleibt deshalb exakt Code bzw. Rohtext.
            if type == CMARK_NODE_CODE_BLOCK || type == CMARK_NODE_HTML_BLOCK {
                return true
            }
            if cmark_node_first_child(enclosing) != nil,
               insert(line: line, originalLine: originalLine, into: enclosing) {
                return true
            }
            // Ein Blatt kann keine echte Leerzeile enthalten. Falls eine
            // Erweiterung dennoch einen übergreifenden Bereich meldet, lassen
            // wir ihn lieber unverändert, statt seine Semantik zu erraten.
            return true
        }

        let next = children.first { Int(cmark_node_get_start_line($0)) > line }
        let previous = children.last { Int(cmark_node_get_end_line($0)) < line }

        if cmark_node_can_contain_type(container, CMARK_NODE_CUSTOM_BLOCK) {
            return addBlankNode(originalLine: originalLine,
                                to: container,
                                before: next)
        }

        // Listen akzeptieren laut cmark ausschließlich Item-Knoten. Die leere
        // Zeile wird deshalb ans Ende des vorherigen bzw. an den Anfang des
        // nächsten Eintrags gehängt; die Listenstruktur selbst bleibt gleich.
        if cmark_node_get_type(container) == CMARK_NODE_LIST {
            if let previous {
                return addBlankNode(originalLine: originalLine,
                                    to: previous,
                                    before: nil)
            }
            if let next {
                return addBlankNode(originalLine: originalLine,
                                    to: next,
                                    before: cmark_node_first_child(next))
            }
        }
        return false
    }

    private static func originalChildren(
        of node: UnsafeMutablePointer<cmark_node>
    ) -> [UnsafeMutablePointer<cmark_node>] {
        var result: [UnsafeMutablePointer<cmark_node>] = []
        var child = cmark_node_first_child(node)
        while let current = child {
            if cmark_node_get_type(current) != CMARK_NODE_CUSTOM_BLOCK {
                result.append(current)
            }
            child = cmark_node_next(current)
        }
        return result
    }

    private static func addBlankNode(
        originalLine: Int,
        to parent: UnsafeMutablePointer<cmark_node>,
        before next: UnsafeMutablePointer<cmark_node>?
    ) -> Bool {
        guard let blank = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) else { return false }
        let html = "<div class=\"\(cssClass)\" data-srcline=\"\(originalLine)\"><br></div>"
        let configured = html.withCString { cmark_node_set_on_enter(blank, $0) != 0 }
        guard configured else {
            cmark_node_free(blank)
            return false
        }

        let inserted: Bool
        if let next {
            inserted = cmark_node_insert_before(next, blank) != 0
        } else {
            inserted = cmark_node_append_child(parent, blank) != 0
        }
        if !inserted { cmark_node_free(blank) }
        return inserted
    }
}

/// Erkennt dieselbe bewusst strenge TeX-Schreibweise wie Number One:
/// `$…$` inline und `$$…$$` als Block. Code-Spans und Code-Fences werden vorher
/// geschützt, damit Shell-Variablen und Beispielcode unverändert bleiben.
enum MarkdownMath {
    struct Extraction {
        let markdown: String

        /// Bildet die Zeilen von `markdown` auf Zeilen des Originaltextes ab:
        /// Index = 0-basierte Zeile in `markdown`, Wert = 1-basierte Zeile im
        /// Original. Ein leeres Array bedeutet „nichts hat sich verschoben",
        /// dann gilt die Identität.
        ///
        /// Nötig, weil ein mehrzeiliger `$$`-Block hier zu einem einzeiligen
        /// Token zusammenschrumpft. Ohne Umrechnung würde ein Klick in der
        /// Vorschau unterhalb eines solchen Blocks im Editor zu weit oben
        /// landen. Code-Fences schrumpfen zwar zwischenzeitlich ebenfalls,
        /// werden am Ende von `extract` aber wieder eingesetzt und sind für
        /// die Zeilenzählung deshalb unauffällig.
        let sourceLines: [Int]

        private let replacements: [(token: String, html: String, block: Bool)]

        init(markdown: String,
             replacements: [(token: String, html: String, block: Bool)],
             sourceLines: [Int] = []) {
            self.markdown = markdown
            self.replacements = replacements
            self.sourceLines = sourceLines
        }

        /// Rechnet eine 1-basierte Zeile aus dem vorverarbeiteten Text auf die
        /// zugehörige 1-basierte Zeile im Originaldokument um.
        func originalLine(for line: Int) -> Int {
            guard line >= 1 else { return 1 }
            guard !sourceLines.isEmpty else { return line }
            guard line <= sourceLines.count else { return sourceLines.last ?? line }
            return sourceLines[line - 1]
        }

        func insertingHTML(into renderedHTML: String) -> String {
            replacements.reduce(renderedHTML) { html, replacement in
                var result = html
                if replacement.block {
                    result = Extraction.replacingLoneParagraph(
                        token: replacement.token,
                        with: replacement.html,
                        in: result
                    )
                }
                return result.replacingOccurrences(
                    of: replacement.token,
                    with: replacement.html
                )
            }
        }

        /// Ersetzt einen Absatz, der NUR aus dem Token besteht, komplett durch
        /// das Block-HTML — eine Formel als eigener Block soll nicht in einem
        /// überflüssigen `<p>` stecken.
        ///
        /// Der Öffnungs-Tag wird mit beliebigen Attributen gematcht, weil der
        /// Renderer inzwischen die Quellzeile daran hängt
        /// (`<p data-srcline="12">`). Ein wörtliches `<p>` würde seit dieser
        /// Ergänzung nie mehr greifen und Block-Formeln still auf den
        /// Inline-Pfad fallen lassen.
        private static func replacingLoneParagraph(token: String,
                                                   with html: String,
                                                   in source: String) -> String {
            let pattern = "<p[^>]*>\(NSRegularExpression.escapedPattern(for: token))</p>"
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return source
            }
            return regex.stringByReplacingMatches(
                in: source,
                range: NSRange(source.startIndex..., in: source),
                withTemplate: NSRegularExpression.escapedTemplate(for: html)
            )
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
        // Rohtext je Math-Token, um später zählen zu können, wie viele Zeilen
        // die Ersetzung im Original belegt hat.
        var consumed: [(token: String, rawSource: String)] = []
        working = replaceMath(
            using: blockMath,
            in: working,
            block: true,
            storage: &replacements,
            consumed: &consumed
        )
        working = replaceMath(
            using: inlineDoubleMath,
            in: working,
            block: false,
            storage: &replacements,
            consumed: &consumed
        )
        working = replaceMath(
            using: inlineMath,
            in: working,
            block: false,
            storage: &replacements,
            consumed: &consumed
        )

        for item in protected {
            working = working.replacingOccurrences(of: item.token, with: item.source)
        }
        return Extraction(
            markdown: working,
            replacements: replacements,
            sourceLines: sourceLineMap(for: working,
                                       consumed: consumed,
                                       protected: protected)
        )
    }

    /// Baut die Zeilen-Umrechnungstabelle für `Extraction.sourceLines`.
    ///
    /// Grundgedanke: Der vorbereitete Text ist bis auf die Math-Token
    /// zeilengleich mit dem Original. Steht in einer Zeile ein Token, das im
    /// Original mehrere Zeilen belegte, verschieben sich alle folgenden Zeilen
    /// um genau diese Differenz.
    private static func sourceLineMap(
        for working: String,
        consumed: [(token: String, rawSource: String)],
        protected: [(token: String, source: String)]
    ) -> [Int] {
        // Zusätzliche Zeilen je Token; einzeilige Ersetzungen sind uninteressant.
        var extraLines: [String: Int] = [:]
        for item in consumed {
            var raw = item.rawSource
            // Ein `$$`-Block kann geschützte Code-Token enthalten. Für die
            // Zeilenzählung muss dort der echte Quelltext stehen.
            if raw.contains("FASTRACODE") {
                for entry in protected {
                    raw = raw.replacingOccurrences(of: entry.token, with: entry.source)
                }
            }
            let additional = raw.components(separatedBy: "\n").count - 1
            if additional > 0 { extraLines[item.token] = additional }
        }
        // Ohne mehrzeilige Ersetzung ist die Abbildung die Identität. Das
        // leere Array spart in diesem Normalfall Speicher und Rechenzeit.
        guard !extraLines.isEmpty else { return [] }

        var map: [Int] = []
        var offset = 0
        for line in working.components(separatedBy: "\n") {
            map.append(map.count + 1 + offset)
            // Schnellprüfung: nur Zeilen mit Math-Token können etwas verschieben.
            guard line.contains("FASTRAMATH") else { continue }
            for (token, additional) in extraLines where line.contains(token) {
                offset += additional
            }
        }
        return map
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
        storage: inout [(token: String, html: String, block: Bool)],
        consumed: inout [(token: String, rawSource: String)]
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
            // Ganzen ersetzten Bereich merken (nicht nur die TeX-Gruppe): nur
            // daraus lässt sich die im Original belegte Zeilenzahl bestimmen.
            consumed.append((token, (source as NSString).substring(with: match.range)))
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
