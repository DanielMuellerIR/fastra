// MarkdownHTMLWhitelist.swift
//
// Enge, fail-closed Positivliste für rohes HTML in der Markdown-Vorschau.
//
// Hintergrund: Die Vorschau rendert seit jeher ohne `CMARK_OPT_UNSAFE`, jedes
// rohe HTML wurde also durch „<!-- raw HTML omitted -->" ersetzt. Damit blieb
// aber auch der verbreitetste README-Aufbau unsichtbar — ein Bild in
// `<p align="center">`. Diese Datei erlaubt genau solche Bausteine und nichts
// darüber hinaus.
//
// Drei Entwurfsentscheidungen tragen die Sicherheit:
//
// 1. **Neu erzeugen statt durchreichen.** Nichts vom Eingabetext wandert
//    unverändert in die Ausgabe. Der Scanner zerlegt das Fragment, prüft jedes
//    Stück und baut daraus eine kanonische Form neu auf. Damit sieht WebKit nur
//    Text, den DIESER Code geschrieben hat — die klassische Ursache für
//    Mutation-XSS (Filter und Renderer parsen dieselben Bytes verschieden)
//    entfällt weitgehend.
// 2. **Fail-closed auf Fragmentebene.** Sobald irgendetwas nicht in die enge
//    Grammatik passt, wird das GANZE Fragment verworfen. Kein Reparieren,
//    kein „das eine Tag rauswerfen und den Rest behalten" — genau daraus
//    entstehen unbalancierte Bäume, die anders geparst werden als gedacht.
// 3. **Keine Selbstgestaltung.** Weder `style` noch `class` noch `id` sind
//    erlaubt. Das nimmt der Datei jede Möglichkeit, sich über die Vorschau zu
//    legen, Text zu verstecken oder Fastras eigene Skripte über DOM-Clobbering
//    zu stören.
//
// Was hier durchkommt, ist danach immer noch nicht am Ziel: `MarkdownImages`
// schreibt jedes `src` auf ein internes Token um oder leert es, und die
// Content-Security-Policy der Vorschau verbietet Netzabrufe vollständig.

import Foundation
import cmark_gfm

enum MarkdownHTMLWhitelist {

    // MARK: - Erlaubte Elemente

    /// Elemente ohne Inhalt. Sie landen nie auf dem Verschachtelungsstapel.
    static let voidElements: Set<String> = ["br", "hr", "img", "col", "wbr"]

    /// Bewusst NICHT enthalten und damit immer ein Verwerfungsgrund:
    /// `script`, `style`, `iframe`, `object`, `embed`, `meta`, `link`, `base`,
    /// `form`, `input`, `template`, `noscript`, `textarea`, `title`, `svg`,
    /// `math`. `svg` und `math` schalten die HTML-Parsingregeln um und sind
    /// über `foreignObject` bzw. `annotation-xml` ein Wiedereinstieg in HTML;
    /// die übrigen führen Code aus, laden nach oder gestalten das Dokument.
    static let allowedElements: Set<String> = [
        // Struktur
        "p", "div", "span", "br", "hr", "center", "blockquote", "pre",
        "h1", "h2", "h3", "h4", "h5", "h6",
        // Auszeichnung
        "b", "strong", "i", "em", "u", "s", "strike", "del", "ins", "mark",
        "small", "sub", "sup", "code", "kbd", "samp", "var", "q", "cite",
        "abbr", "dfn",
        // Listen
        "ul", "ol", "li", "dl", "dt", "dd",
        // Tabellen
        "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption",
        "colgroup", "col",
        // Verweise und Bilder
        "a", "img",
        // Aufklappbares (in READMEs verbreitet)
        "details", "summary",
    ]

    /// Attribute, die an jedem erlaubten Element zulässig sind.
    static let globalAttributes: Set<String> = ["align", "title", "dir", "lang"]

    /// Zusätzliche Attribute je Element.
    static let elementAttributes: [String: Set<String>] = [
        "a": ["href"],
        "img": ["src", "alt", "width", "height"],
        "table": ["width"],
        "td": ["colspan", "rowspan", "valign", "width"],
        "th": ["colspan", "rowspan", "valign", "width", "scope"],
        "col": ["span", "width"],
        "colgroup": ["span"],
        "ol": ["start", "type", "reversed"],
        "details": ["open"],
        "blockquote": ["cite"],
        "q": ["cite"],
    ]

    /// Attribute ohne Wert. Alles andere braucht einen gequoteten Wert.
    static let booleanAttributes: Set<String> = ["open", "reversed"]

    // MARK: - Ergebnis

    /// Zerlegt und prüft rohe HTML-Fragmente eines Dokuments in Lesereihenfolge.
    ///
    /// Der Stapel läuft über das GANZE Dokument, weil `<details>` und sein
    /// `</details>` in getrennten cmark-Blöcken liegen können. Am Dokumentende
    /// schließt `closingTail()` alles noch Offene — ein Fragment kann die
    /// Struktur des Dokuments dadurch nicht über sein Ende hinaus verändern.
    struct Sanitizer {
        private var openElements: [String] = []

        init() {}

        /// Gibt die geprüfte, neu erzeugte Form zurück — oder einen leeren
        /// String, wenn das Fragment verworfen wurde.
        mutating func sanitize(_ fragment: String) -> String {
            var stackCopy = openElements
            guard let output = MarkdownHTMLWhitelist.scan(fragment, openElements: &stackCopy) else {
                // Verworfen: Der Stapel des Dokuments bleibt unangetastet, sonst
                // brächte ein abgelehntes Fragment die folgenden aus dem Tritt.
                return ""
            }
            openElements = stackCopy
            return output
        }

        /// Schließt am Dokumentende alles, was offen geblieben ist.
        mutating func closingTail() -> String {
            let tail = openElements.reversed().map { "</\($0)>" }.joined()
            openElements.removeAll()
            return tail
        }
    }

    // MARK: - Scanner

    /// Die eigentliche Grammatik. `nil` bedeutet: irgendetwas war nicht
    /// eindeutig verständlich — das Fragment fällt komplett weg.
    static func scan(_ fragment: String, openElements: inout [String]) -> String? {
        var output = ""
        var index = fragment.startIndex
        let end = fragment.endIndex

        while index < end {
            guard let nextTag = fragment[index...].firstIndex(of: "<") else {
                guard let text = escapedText(String(fragment[index..<end])) else { return nil }
                output += text
                break
            }
            if nextTag > index {
                guard let text = escapedText(String(fragment[index..<nextTag])) else { return nil }
                output += text
            }
            index = nextTag

            // Kommentar: streng geformt und ohne inneres „--". Er wird geprüft,
            // aber nie ausgegeben — ein durchgereichter Kommentar ist bei
            // abweichender Parserlaune ein bekannter Ausbruchsweg.
            if fragment[index...].hasPrefix("<!--") {
                guard let close = fragment.range(of: "-->", range: index..<end) else { return nil }
                let inner = fragment[fragment.index(index, offsetBy: 4)..<close.lowerBound]
                guard !inner.contains("--") else { return nil }
                index = close.upperBound
                continue
            }
            // `<!doctype`, `<?…`, CDATA und alles Übrige sind nicht vorgesehen.
            if fragment[index...].hasPrefix("<!") || fragment[index...].hasPrefix("<?") {
                return nil
            }

            guard let close = fragment[index...].firstIndex(of: ">") else { return nil }
            let raw = String(fragment[fragment.index(after: index)..<close])
            index = fragment.index(after: close)
            guard !raw.contains("<") else { return nil }

            if raw.hasPrefix("/") {
                guard let name = elementName(String(raw.dropFirst()).trimmingCharacters(in: .whitespaces)),
                      openElements.last == name else { return nil }
                openElements.removeLast()
                output += "</\(name)>"
                continue
            }

            guard let tag = parseStartTag(raw) else { return nil }
            output += tag.serialized
            if !voidElements.contains(tag.name) {
                openElements.append(tag.name)
                // Eine bösartige Datei soll den Baum nicht beliebig tief machen.
                guard openElements.count <= 64 else { return nil }
            }
        }
        return output
    }

    private struct StartTag {
        let name: String
        let serialized: String
    }

    /// `name attr="wert" attr2='wert'` — Werte MÜSSEN gequotet sein.
    private static func parseStartTag(_ raw: String) -> StartTag? {
        var body = raw
        var selfClosing = false
        if body.hasSuffix("/") {
            selfClosing = true
            body.removeLast()
        }
        var scanner = Substring(body)
        guard let name = elementName(String(takeToken(&scanner))) else { return nil }
        // `<img …/>` ist üblich; `<div/>` wäre dagegen eine Struktur-Aussage,
        // die HTML gar nicht kennt, und damit ein Parser-Unterschied.
        if selfClosing, !voidElements.contains(name) { return nil }

        var serialized = "<\(name)"
        var seen = Set<String>()
        while true {
            skipWhitespace(&scanner)
            if scanner.isEmpty { break }
            let attributeName = String(takeAttributeName(&scanner)).lowercased()
            guard !attributeName.isEmpty,
                  attributeName.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil,
                  !attributeName.hasPrefix("on"),
                  seen.insert(attributeName).inserted,
                  isAllowed(attribute: attributeName, on: name) else { return nil }

            skipWhitespace(&scanner)
            guard scanner.first == "=" else {
                // Wertloses Attribut nur, wo HTML das auch so meint.
                guard booleanAttributes.contains(attributeName) else { return nil }
                serialized += " \(attributeName)"
                continue
            }
            scanner = scanner.dropFirst()
            skipWhitespace(&scanner)
            guard let quote = scanner.first, quote == "\"" || quote == "'" else { return nil }
            scanner = scanner.dropFirst()
            guard let valueEnd = scanner.firstIndex(of: quote) else { return nil }
            let value = String(scanner[scanner.startIndex..<valueEnd])
            scanner = scanner[scanner.index(after: valueEnd)...]
            guard isValid(value: value, for: attributeName, on: name),
                  let escaped = escapedAttributeValue(value) else { return nil }
            serialized += " \(attributeName)=\"\(escaped)\""
        }
        serialized += ">"
        return StartTag(name: name, serialized: serialized)
    }

    // MARK: - Prüfungen

    private static func elementName(_ raw: String) -> String? {
        let name = raw.lowercased()
        guard allowedElements.contains(name) else { return nil }
        return name
    }

    private static func isAllowed(attribute: String, on element: String) -> Bool {
        if globalAttributes.contains(attribute) { return true }
        return elementAttributes[element]?.contains(attribute) ?? false
    }

    private static func isValid(value: String, for attribute: String, on element: String) -> Bool {
        // Steuerzeichen haben in keinem Attributwert etwas zu suchen; über sie
        // laufen die üblichen Umgehungen von Schema-Prüfungen.
        guard !value.unicodeScalars.contains(where: {
            $0.value < 0x20 || $0.value == 0x7F
        }) else { return false }

        switch attribute {
        case "align":
            return ["left", "center", "right", "justify"].contains(value.lowercased())
        case "valign":
            return ["top", "middle", "bottom", "baseline"].contains(value.lowercased())
        case "dir":
            return ["ltr", "rtl", "auto"].contains(value.lowercased())
        case "scope":
            return ["row", "col", "rowgroup", "colgroup"].contains(value.lowercased())
        case "type":
            return ["1", "a", "A", "i", "I"].contains(value)
        case "width", "height":
            return value.range(of: "^[0-9]{1,5}%?$", options: .regularExpression) != nil
        case "colspan", "rowspan", "span", "start":
            return value.range(of: "^[0-9]{1,4}$", options: .regularExpression) != nil
        case "href", "cite":
            return isSafeLink(value)
        case "src":
            // Absichtlich nur grob: `MarkdownImages` entscheidet danach, ob
            // daraus ein lokales Token wird oder ein leerer Wert. Ein zweites,
            // abweichendes Regelwerk an dieser Stelle wäre eine Fehlerquelle.
            return !value.isEmpty
        case "alt", "title", "lang":
            return value.count <= 512
        default:
            return false
        }
    }

    /// Erlaubt sind Dokumentanker, relative Ziele und die drei Schemata, die
    /// Fastra ohnehin an den Browser weitergibt.
    static func isSafeLink(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { return false }
        guard let schemeEnd = trimmed.firstIndex(of: ":") else { return true }
        // Ein Doppelpunkt hinter einem `/`, `?` oder `#` gehört zum Pfad,
        // nicht zu einem Schema.
        let beforeScheme = trimmed[trimmed.startIndex..<schemeEnd]
        if beforeScheme.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { return true }
        return ["http", "https", "mailto"].contains(beforeScheme.lowercased())
    }

    // MARK: - Ausgabe

    /// Text zwischen den Tags. Gültige Zeichenreferenzen bleiben erhalten,
    /// jedes andere `&` wird escapet.
    static func escapedText(_ value: String) -> String? {
        guard !value.contains(">") else { return nil }
        var output = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if character == "&" {
                let rest = value[index...]
                if let semicolon = rest.firstIndex(of: ";"),
                   rest.distance(from: rest.startIndex, to: semicolon) <= 33,
                   String(rest[rest.index(after: rest.startIndex)..<semicolon])
                    .range(of: "^([a-zA-Z][a-zA-Z0-9]{1,31}|#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6})$",
                           options: .regularExpression) != nil {
                    output += rest[rest.startIndex...semicolon]
                    index = value.index(after: semicolon)
                    continue
                }
                output += "&amp;"
            } else if character == "<" {
                output += "&lt;"
            } else {
                output.append(character)
            }
            index = value.index(after: index)
        }
        return output
    }

    private static func escapedAttributeValue(_ value: String) -> String? {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Kleine Scanner-Helfer

    private static func skipWhitespace(_ scanner: inout Substring) {
        while let first = scanner.first, first.isWhitespace {
            scanner = scanner.dropFirst()
        }
    }

    private static func takeToken(_ scanner: inout Substring) -> Substring {
        skipWhitespace(&scanner)
        let start = scanner.startIndex
        while let first = scanner.first, !first.isWhitespace {
            scanner = scanner.dropFirst()
        }
        return scanner.base[start..<scanner.startIndex]
    }

    private static func takeAttributeName(_ scanner: inout Substring) -> Substring {
        let start = scanner.startIndex
        while let first = scanner.first, !first.isWhitespace, first != "=" {
            scanner = scanner.dropFirst()
        }
        return scanner.base[start..<scanner.startIndex]
    }
}

/// Wendet die Positivliste auf einen fertig geparsten cmark-Baum an.
///
/// Zwei Aufgaben, die zusammengehören, weil beide dadurch nötig werden, dass
/// die Vorschau mit `CMARK_OPT_UNSAFE` rendert:
///
/// 1. Rohe HTML-Knoten durch `MarkdownHTMLWhitelist` ersetzen.
/// 2. Die Ziel-URLs von Links und Bildern selbst prüfen. Im sicheren Modus
///    hätte cmark `javascript:`, `vbscript:`, `file:` und `data:` geleert; mit
///    `UNSAFE` tut es das nicht mehr, also muss es hier passieren.
enum MarkdownHTMLSanitizing {

    static func apply(to document: UnsafeMutablePointer<cmark_node>) {
        var sanitizer = MarkdownHTMLWhitelist.Sanitizer()
        var lastHTMLNode: UnsafeMutablePointer<cmark_node>?

        guard let iterator = cmark_iter_new(document) else { return }
        defer { cmark_iter_free(iterator) }

        while true {
            let event = cmark_iter_next(iterator)
            if event == CMARK_EVENT_DONE { break }
            guard event == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator) else {
                continue
            }
            switch cmark_node_get_type(node) {
            case CMARK_NODE_HTML_BLOCK, CMARK_NODE_HTML_INLINE:
                let raw = cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
                cmark_node_set_literal(node, sanitizer.sanitize(raw))
                lastHTMLNode = node
            case CMARK_NODE_LINK, CMARK_NODE_IMAGE:
                let url = cmark_node_get_url(node).map { String(cString: $0) } ?? ""
                if !url.isEmpty, !MarkdownHTMLWhitelist.isSafeLink(url) {
                    cmark_node_set_url(node, "")
                }
            default:
                break
            }
        }

        // Offene Elemente am letzten HTML-Knoten schließen. Ohne das könnte ein
        // nicht geschlossenes `<div>` den Rest des Dokuments einschachteln.
        if let lastHTMLNode {
            let tail = sanitizer.closingTail()
            if !tail.isEmpty {
                let existing = cmark_node_get_literal(lastHTMLNode).map { String(cString: $0) } ?? ""
                cmark_node_set_literal(lastHTMLNode, existing + tail)
            }
        }
    }
}
