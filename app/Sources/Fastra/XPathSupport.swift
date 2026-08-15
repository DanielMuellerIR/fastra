// XPathSupport.swift
//
// XPath-Navigation für XML (Etappe 5 Wunschpaket 2026-07) — pure Logik:
//
// 1. `XPathIndex`: eigener SAX-artiger Ein-Pass-Scanner mit QUELL-OFFSETS.
//    Foundations XPath (`XMLDocument.nodes(forXPath:)`) liefert keine
//    Textpositionen und taugt nicht zum Springen; `XMLParser` meldet
//    Zeilen/Spalten byte-orientiert (Multibyte-Falle bei Umlauten/Emoji).
//    Der eigene Scanner arbeitet direkt auf UTF-16-Code-Units — dieselben
//    Offsets, die Editor-Sprünge (`NSRange`) erwarten.
// 2. `XPathQuery`: Parser + Auswertung des dokumentierten Teilsets:
//    `/`, `//`, `*`, `[n]`, `[@attr]`, `[@attr='wert']`, `@attr`, `text()`.
//    Alles andere ergibt eine verständliche Fehlermeldung.
// 3. `XPathAutocomplete`: Kind-Element- und Attributnamen aus dem Index.

import Foundation

// MARK: - Index

struct XPathIndex {
    struct Attribute: Equatable {
        let name: String
        let value: String
        /// Range des Attributnamens im Quelltext (Sprungziel für `@attr`).
        let nameRange: NSRange
    }

    struct Element {
        let name: String
        /// Range des Elementnamens im Start-Tag (Sprungziel).
        let nameRange: NSRange
        let attributes: [Attribute]
        var children: [Int] = []
        var parent: Int?
        /// Erste nicht-leere Textstelle im Element (Sprungziel für `text()`).
        var firstTextRange: NSRange?
    }

    /// Flaches Element-Array; `children`/`parent` verweisen per Index.
    let elements: [Element]
    /// Indizes der Wurzel-Elemente (wohlgeformt: genau eines).
    let roots: [Int]

    enum IndexError: Error, Equatable {
        case mismatchedTag(expected: String, found: String, offset: Int)
        case unclosedTag(name: String, offset: Int)
        case malformed(offset: Int)

        /// Fehlermeldung in Nutzersprache für die dezente Anzeige.
        var userMessage: String {
            switch self {
            case .mismatchedTag(let expected, let found, _):
                // codereview-ok: „…“ ist das korrekte deutsche Anführungszeichen-Paar
                return L10n.format("XML unvollständig: „</%@>“ erwartet, „</%@>“ gefunden.",
                                   expected, found)
            case .unclosedTag(let name, _):
                return L10n.format("XML unvollständig: „<%@>“ wird nicht geschlossen.", name)
            case .malformed(_):
                return L10n.string("XML an dieser Stelle nicht lesbar — Navigation wartet auf gültiges XML.")
            }
        }
    }

    // MARK: Scanner

    /// Baut den Index über einen einzelnen Scan. Läuft synchron — Aufrufer
    /// schieben den Aufruf auf einen Hintergrund-Thread (nie den Main-Thread
    /// mit großen Dokumenten blockieren).
    static func build(from text: String) -> Result<XPathIndex, IndexError> {
        let scalars = Array(text.utf16)
        let count = scalars.count
        var elements: [Element] = []
        var roots: [Int] = []
        var stack: [Int] = []
        var index = 0

        func char(_ at: Int) -> Character? {
            guard at < count, let scalar = Unicode.Scalar(scalars[at]) else { return nil }
            return Character(scalar)
        }

        func hasPrefix(_ marker: [Character], at start: Int) -> Bool {
            for (offset, expected) in marker.enumerated() {
                if char(start + offset) != expected { return false }
            }
            return true
        }

        func skip(until marker: [Character], from: Int) -> Int? {
            var i = from
            while i < count {
                if hasPrefix(marker, at: i) { return i + marker.count }
                i += 1
            }
            return nil
        }

        /// Überspringt eine DOCTYPE-Deklaration einschließlich interner
        /// Teilmenge. `>` innerhalb von Quotes oder `[…]` beendet sie nicht.
        func skipDeclaration(from start: Int) -> Int? {
            var i = start
            var subsetDepth = 0
            var quote: Character?
            while i < count {
                guard let current = char(i) else { i += 1; continue }
                if let activeQuote = quote {
                    if current == activeQuote { quote = nil }
                } else if current == "\"" || current == "'" {
                    quote = current
                } else if current == "[" {
                    subsetDepth += 1
                } else if current == "]", subsetDepth > 0 {
                    subsetDepth -= 1
                } else if current == ">", subsetDepth == 0 {
                    return i + 1
                }
                i += 1
            }
            return nil
        }

        func isXMLWhitespace(_ unit: UInt16) -> Bool {
            unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
        }

        /// Liefert den sichtbaren Inhalt einer Text- oder CDATA-Stelle. Die
        /// Rechnung arbeitet auf UTF-16-Einheiten; dadurch bleibt auch ein
        /// führendes Zeichen außerhalb der BMP (etwa ein Emoji) vollständig.
        func contentRange(from start: Int, to end: Int) -> NSRange? {
            var first = start
            while first < end, isXMLWhitespace(scalars[first]) { first += 1 }
            guard first < end else { return nil }
            var last = end
            while last > first, isXMLWhitespace(scalars[last - 1]) { last -= 1 }
            return NSRange(location: first, length: last - first)
        }

        func isNameStartChar(_ c: Character) -> Bool {
            c.isLetter || c == "_"
        }

        func isNameChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_" || c == "-" || c == "." || c == ":"
        }

        func readName(from: Int) -> (String, Int) {
            var i = from
            var name = ""
            while i < count, let c = char(i), isNameChar(c) {
                name.append(c)
                i += 1
            }
            return (name, i)
        }

        /// XML-Attributwerte werden logisch verglichen, nicht in ihrer
        /// Quellschreibweise. Aus Sicherheitsgründen expandieren wir nur die
        /// fünf XML-Entities und numerische Zeichenreferenzen, niemals DTD-
        /// definierte Entities.
        func isAllowedXMLScalar(_ value: UInt32) -> Bool {
            value == 0x09 || value == 0x0A || value == 0x0D
                || (0x20...0xD7FF).contains(value)
                || (0xE000...0xFFFD).contains(value)
                || (0x10000...0x10FFFF).contains(value)
        }

        func decodedAttributeValue(_ source: String) -> String? {
            var result = ""
            var cursor = source.startIndex
            while cursor < source.endIndex {
                if source[cursor] != "&" {
                    guard source[cursor] != "<",
                          source[cursor].unicodeScalars.allSatisfy({
                              isAllowedXMLScalar($0.value)
                          }) else { return nil }
                    result.append(source[cursor])
                    cursor = source.index(after: cursor)
                    continue
                }
                guard let semicolon = source[cursor...].firstIndex(of: ";") else {
                    return nil
                }
                let tokenStart = source.index(after: cursor)
                let token = String(source[tokenStart..<semicolon])
                switch token {
                case "amp": result.append("&")
                case "lt": result.append("<")
                case "gt": result.append(">")
                case "quot": result.append("\"")
                case "apos": result.append("'")
                default:
                    let value: UInt32?
                    if token.hasPrefix("#x") || token.hasPrefix("#X") {
                        value = UInt32(token.dropFirst(2), radix: 16)
                    } else if token.hasPrefix("#") {
                        value = UInt32(token.dropFirst(), radix: 10)
                    } else {
                        value = nil
                    }
                    guard let value, isAllowedXMLScalar(value),
                          let scalar = Unicode.Scalar(value) else {
                        return nil
                    }
                    result.unicodeScalars.append(scalar)
                }
                cursor = source.index(after: semicolon)
            }
            return result
        }

        while index < count {
            if scalars[index] != 0x3C { // „<“
                var end = index
                while end < count, scalars[end] != 0x3C { end += 1 }
                guard let sourceRange = Range(NSRange(location: index,
                                                      length: end - index), in: text) else {
                    return .failure(.malformed(offset: index))
                }
                let source = String(text[sourceRange])
                guard !source.contains("]]>") && decodedAttributeValue(source) != nil else {
                    return .failure(.malformed(offset: index))
                }
                if let range = contentRange(from: index, to: end) {
                    guard let top = stack.last else {
                        return .failure(.malformed(offset: range.location))
                    }
                    if elements[top].firstTextRange == nil {
                        elements[top].firstTextRange = range
                    }
                }
                index = end
                continue
            }

            // `<`-Konstrukte unterscheiden.
            if char(index + 1) == "!" {
                if hasPrefix(["!", "-", "-"], at: index + 1) {
                    guard let end = skip(until: ["-", "-", ">"], from: index + 4) else {
                        return .failure(.malformed(offset: index))
                    }
                    var commentIndex = index + 4
                    while commentIndex < end - 3 {
                        guard !hasPrefix(["-", "-"], at: commentIndex) else {
                            return .failure(.malformed(offset: commentIndex))
                        }
                        commentIndex += 1
                    }
                    index = end
                } else if hasPrefix(["!", "[", "C", "D", "A", "T", "A", "["],
                                    at: index + 1) {
                    // CDATA zählt als Text des offenen Elements.
                    guard let top = stack.last,
                          let end = skip(until: ["]", "]", ">"], from: index + 9) else {
                        return .failure(.malformed(offset: index))
                    }
                    if elements[top].firstTextRange == nil,
                       let range = contentRange(from: index + 9, to: end - 3) {
                        elements[top].firstTextRange = range
                    }
                    index = end
                } else if hasPrefix(["!", "D", "O", "C", "T", "Y", "P", "E"],
                                    at: index + 1), roots.isEmpty, stack.isEmpty,
                          let end = skipDeclaration(from: index + 9) {
                    index = end
                } else {
                    return .failure(.malformed(offset: index))
                }
                continue
            }
            if char(index + 1) == "?" {
                guard let end = skip(until: ["?", ">"], from: index + 2) else {
                    return .failure(.malformed(offset: index))
                }
                index = end
                continue
            }
            if char(index + 1) == "/" {
                // Schließ-Tag: muss zum obersten Stapel-Element passen.
                let (name, afterName) = readName(from: index + 2)
                guard !name.isEmpty else {
                    return .failure(.malformed(offset: index))
                }
                guard let top = stack.popLast() else {
                    return .failure(.malformed(offset: index))
                }
                guard elements[top].name == name else {
                    return .failure(.mismatchedTag(expected: elements[top].name,
                                                   found: name, offset: index))
                }
                var close = afterName
                while close < count, char(close)?.isWhitespace == true { close += 1 }
                guard char(close) == ">" else {
                    return .failure(.malformed(offset: close))
                }
                index = close + 1
                continue
            }

            // Start-Tag.
            let nameStart = index + 1
            let (name, afterName) = readName(from: nameStart)
            guard let firstNameChar = char(nameStart), isNameStartChar(firstNameChar),
                  !name.isEmpty else {
                return .failure(.malformed(offset: index))
            }
            var attributes: [Attribute] = []
            var attributeNames = Set<String>()
            var i = afterName
            var selfClosing = false
            var tagTerminated = false
            attributeScan: while i < count {
                guard let ac = char(i) else { break }
                if ac == ">" { i += 1; tagTerminated = true; break }
                if ac == "/" && char(i + 1) == ">" {
                    selfClosing = true
                    tagTerminated = true
                    i += 2
                    break
                }
                if ac.isWhitespace { i += 1; continue }
                // Attributname lesen.
                let attrNameStart = i
                let (attrName, afterAttrName) = readName(from: i)
                guard let firstAttrChar = char(attrNameStart),
                      isNameStartChar(firstAttrChar), !attrName.isEmpty,
                      attributeNames.insert(attrName).inserted else {
                    return .failure(.malformed(offset: i))
                }
                i = afterAttrName
                while i < count, char(i)?.isWhitespace == true { i += 1 }
                guard char(i) == "=" else {
                    return .failure(.malformed(offset: i))
                }
                i += 1
                while i < count, char(i)?.isWhitespace == true { i += 1 }
                guard let quote = char(i), quote == "\"" || quote == "'" else {
                    return .failure(.malformed(offset: i))
                }
                i += 1
                let valueStart = i
                while i < count, char(i) != quote { i += 1 }
                guard i < count,
                      let range = Range(NSRange(location: valueStart,
                                                length: i - valueStart), in: text),
                      let value = decodedAttributeValue(String(text[range])) else {
                    return .failure(.malformed(offset: valueStart))
                }
                i += 1   // schließendes Quote
                attributes.append(Attribute(
                    name: attrName, value: value,
                    nameRange: NSRange(location: attrNameStart,
                                       length: afterAttrName - attrNameStart)
                ))
                continue attributeScan
            }
            guard tagTerminated else {
                return .failure(.malformed(offset: index))
            }

            var element = Element(
                name: name,
                nameRange: NSRange(location: nameStart,
                                   length: afterName - nameStart),
                attributes: attributes
            )
            element.parent = stack.last
            let newIndex = elements.count
            elements.append(element)
            if let top = stack.last {
                elements[top].children.append(newIndex)
            } else {
                guard roots.isEmpty else {
                    return .failure(.malformed(offset: index))
                }
                roots.append(newIndex)
            }
            if !selfClosing {
                stack.append(newIndex)
            }
            index = i
        }

        if let top = stack.last {
            return .failure(.unclosedTag(name: elements[top].name,
                                         offset: elements[top].nameRange.location))
        }
        guard roots.count == 1 else {
            return .failure(.malformed(offset: 0))
        }
        return .success(XPathIndex(elements: elements, roots: roots))
    }
}

// MARK: - Query (Teilset)

struct XPathQuery: Equatable {
    struct Step: Equatable {
        let descendant: Bool     // true = „//“ vor diesem Schritt
        let name: String?        // nil = *
        let predicates: [Predicate]
    }

    enum Predicate: Equatable {
        case position(Int)                    // [n]
        case hasAttribute(String)             // [@a]
        case attributeEquals(String, String)  // [@a='v']
    }

    enum Terminal: Equatable {
        case element
        case attribute(String)   // …/@a
        case text                // …/text()
    }

    let steps: [Step]
    let terminal: Terminal

    enum ParseError: Error, Equatable {
        case empty
        case unsupported(String)
        case malformed(String)

        var userMessage: String {
            switch self {
            case .empty:
                return L10n.string("XPath eingeben — z. B. //buch[@id='42']/titel")
            case .unsupported(let what):
                return L10n.format("„%@“ gehört nicht zum unterstützten XPath-Teilset (/, //, *, [n], [@attr], [@attr='wert'], @attr, text()).", what)
            case .malformed(let what):
                return L10n.format("XPath unvollständig oder ungültig bei „%@“.", what)
            }
        }
    }

    /// Parst das dokumentierte Teilset. Relativer Einstieg (ohne führenden
    /// Schrägstrich) sucht wie `//…` in beliebiger Tiefe.
    static func parse(_ input: String) -> Result<XPathQuery, ParseError> {
        var rest = Substring(input.trimmingCharacters(in: .whitespaces))
        guard !rest.isEmpty else { return .failure(.empty) }

        // Achsen besitzen immer `::`; die bloßen Wörter „ancestor“ oder
        // „following“ dürfen dagegen ganz normale Elementnamen sein.
        for unsupported in ["::", ".."] where rest.contains(unsupported) {
            return .failure(.unsupported(unsupported))
        }

        func closingPredicateBracket(in source: Substring) -> Substring.Index? {
            var cursor = source.index(after: source.startIndex)
            var quote: Character?
            while cursor < source.endIndex {
                let current = source[cursor]
                if let activeQuote = quote {
                    if current == activeQuote { quote = nil }
                } else if current == "'" || current == "\"" {
                    quote = current
                } else if current == "]" {
                    return cursor
                }
                cursor = source.index(after: cursor)
            }
            return nil
        }

        var steps: [Step] = []
        var terminal: Terminal = .element
        var descendant: Bool
        if rest.hasPrefix("//") {
            descendant = true
            rest = rest.dropFirst(2)
        } else if rest.hasPrefix("/") {
            descendant = false
            rest = rest.dropFirst(1)
        } else {
            descendant = true   // relativer Einstieg
        }

        while !rest.isEmpty {
            if rest.hasPrefix("@") {
                let name = String(rest.dropFirst())
                guard isValidName(name) else {
                    return .failure(.malformed(String(rest)))
                }
                terminal = .attribute(name)
                rest = ""
                break
            }
            if rest.hasPrefix("text()") {
                guard rest == "text()" else {
                    return .failure(.malformed(String(rest)))
                }
                terminal = .text
                rest = ""
                break
            }

            // Schrittname (oder *) lesen.
            var name = ""
            while let c = rest.first, c != "/" && c != "[" {
                name.append(c)
                rest = rest.dropFirst()
            }
            let stepName: String?
            if name == "*" {
                stepName = nil
            } else if isValidName(name) {
                stepName = name
            } else if name.contains("(") {
                return .failure(.unsupported(name))
            } else {
                return .failure(.malformed(name.isEmpty ? String(rest) : name))
            }

            // Prädikate lesen.
            var predicates: [Predicate] = []
            while rest.hasPrefix("[") {
                guard let close = closingPredicateBracket(in: rest) else {
                    return .failure(.malformed(String(rest)))
                }
                let body = String(rest[rest.index(after: rest.startIndex)..<close])
                rest = rest[rest.index(after: close)...]
                if let position = Int(body), position > 0 {
                    predicates.append(.position(position))
                } else if body.hasPrefix("@") {
                    let attrBody = body.dropFirst()
                    if let eq = attrBody.firstIndex(of: "=") {
                        let attrName = String(attrBody[..<eq])
                        var value = String(attrBody[attrBody.index(after: eq)...])
                        guard isValidName(attrName) else {
                            return .failure(.malformed(body))
                        }
                        guard (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2)
                            || (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2) else {
                            return .failure(.malformed(body))
                        }
                        value = String(value.dropFirst().dropLast())
                        predicates.append(.attributeEquals(attrName, value))
                    } else {
                        let attrName = String(attrBody)
                        guard isValidName(attrName) else {
                            return .failure(.malformed(body))
                        }
                        predicates.append(.hasAttribute(attrName))
                    }
                } else {
                    return .failure(.unsupported("[\(body)]"))
                }
            }

            steps.append(Step(descendant: descendant, name: stepName,
                              predicates: predicates))

            if rest.hasPrefix("//") {
                descendant = true
                rest = rest.dropFirst(2)
            } else if rest.hasPrefix("/") {
                descendant = false
                rest = rest.dropFirst(1)
            } else if rest.isEmpty {
                break
            } else {
                return .failure(.malformed(String(rest)))
            }
            // `…/` am Ende ohne weiteren Schritt.
            if rest.isEmpty { return .failure(.malformed(input)) }
        }

        guard !steps.isEmpty else { return .failure(.malformed(input)) }
        return .success(XPathQuery(steps: steps, terminal: terminal))
    }

    private static func isValidName(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        guard first.isLetter || first == "_" else { return false }
        return name.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." || $0 == ":"
        }
    }
}

// MARK: - Auswertung

enum XPathEvaluator {
    struct Match: Equatable {
        /// Sprungziel im Quelltext (Elementname, Attributname oder Text).
        let range: NSRange
    }

    /// Wertet die Query gegen den Index aus. Reihenfolge = Dokumentreihenfolge.
    static func evaluate(_ query: XPathQuery, in index: XPathIndex) -> [Match] {
        // Kontext beginnt bei einer virtuellen Wurzel über den Root-Elementen.
        var context: [Int] = [-1]

        for step in query.steps {
            var next: [Int] = []
            // Positions-Prädikate zählen je KONTEXT-Knoten (XPath-Semantik).
            for node in context {
                var candidates: [Int] = []
                if step.descendant {
                    collectDescendants(of: node, in: index, into: &candidates)
                } else {
                    candidates = children(of: node, in: index)
                }
                var matched = candidates.filter { matches(index.elements[$0], step: step) }
                for predicate in step.predicates {
                    if case .position(let position) = predicate {
                        matched = position <= matched.count ? [matched[position - 1]] : []
                    }
                }
                next.append(contentsOf: matched)
            }
            // Dokumentreihenfolge + Dubletten raus (descendant-Kaskaden).
            var seen = Set<Int>()
            context = next.filter { seen.insert($0).inserted }
                .sorted { index.elements[$0].nameRange.location
                    < index.elements[$1].nameRange.location }
            if context.isEmpty { return [] }
        }

        switch query.terminal {
        case .element:
            return context.map { Match(range: index.elements[$0].nameRange) }
        case .attribute(let name):
            return context.compactMap { node in
                index.elements[node].attributes
                    .first { $0.name == name }
                    .map { Match(range: $0.nameRange) }
            }
        case .text:
            return context.compactMap { node in
                index.elements[node].firstTextRange.map { Match(range: $0) }
            }
        }
    }

    private static func children(of node: Int, in index: XPathIndex) -> [Int] {
        node == -1 ? index.roots : index.elements[node].children
    }

    private static func collectDescendants(of node: Int, in index: XPathIndex,
                                           into result: inout [Int]) {
        // Fremdes XML darf beliebig tief verschachtelt sein. Ein expliziter
        // Stapel bewahrt die Dokumentreihenfolge, ohne den Swift-Callstack zu
        // verbrauchen und bei tiefen Dokumenten abzustürzen.
        var pending = Array(children(of: node, in: index).reversed())
        while let current = pending.popLast() {
            result.append(current)
            pending.append(contentsOf: index.elements[current].children.reversed())
        }
    }

    private static func matches(_ element: XPathIndex.Element,
                                step: XPathQuery.Step) -> Bool {
        if let name = step.name, element.name != name { return false }
        for predicate in step.predicates {
            switch predicate {
            case .position:
                continue   // separat je Kontext angewendet
            case .hasAttribute(let attr):
                if !element.attributes.contains(where: { $0.name == attr }) {
                    return false
                }
            case .attributeEquals(let attr, let value):
                if !element.attributes.contains(where: { $0.name == attr
                    && $0.value == value }) {
                    return false
                }
            }
        }
        return true
    }
}

// MARK: - Autovervollständigung

enum XPathAutocomplete {
    /// Vorschläge für die aktuelle Eingabe: Kind-Element-Namen des bereits
    /// eingegebenen Pfads bzw. Attributnamen nach `@`. Der letzte
    /// (unvollständige) Schritt filtert als Präfix.
    static func completions(for input: String, index: XPathIndex,
                            limit: Int = 8) -> [String] {
        // Eingabe in „fertigen Pfad“ + „angefangenen Rest“ teilen.
        let (rawPrefix, partial) = splitForCompletion(input)
        // Ein relativer Einstieg und `//` beginnen einen Descendant-Schritt.
        // Diese Information muss bis zur Vorschlagsquelle erhalten bleiben;
        // sonst würde `//ti` nur Wurzelelemente statt tiefer `titel` anbieten.
        let descendantStep = rawPrefix.isEmpty || rawPrefix.hasSuffix("//")
        let prefixPath = rawPrefix.hasSuffix("//")
            ? String(rawPrefix.dropLast(2))
            : rawPrefix

        let contextElements: [Int]
        if prefixPath.isEmpty || prefixPath == "/" || prefixPath == "//" {
            contextElements = [-1]
        } else {
            guard case .success(let query) = XPathQuery.parse(prefixPath),
                  query.terminal == .element else { return [] }
            let matches = XPathEvaluator.evaluate(query, in: index)
            guard !matches.isEmpty else { return [] }
            // Element-Indizes über die Ranges zurückfinden.
            contextElements = index.elements.indices.filter { idx in
                matches.contains { $0.range == index.elements[idx].nameRange }
            }
        }

        var names: [String] = []
        var seen = Set<String>()
        if partial.hasPrefix("@") {
            let attrPrefix = String(partial.dropFirst()).lowercased()
            for node in contextElements where node >= 0 {
                for attribute in index.elements[node].attributes
                where attrPrefix.isEmpty
                    || attribute.name.lowercased().hasPrefix(attrPrefix) {
                    if seen.insert(attribute.name).inserted {
                        names.append("@" + attribute.name)
                    }
                }
            }
        } else {
            let childSource: [Int]
            if descendantStep {
                var pending = contextElements == [-1]
                    ? Array(index.roots.reversed())
                    : Array(contextElements.flatMap { index.elements[$0].children }.reversed())
                var descendants: [Int] = []
                while let current = pending.popLast() {
                    descendants.append(current)
                    pending.append(contentsOf: index.elements[current].children.reversed())
                }
                childSource = descendants
            } else if contextElements == [-1] {
                childSource = index.roots
            } else {
                childSource = contextElements.flatMap {
                    $0 >= 0 ? index.elements[$0].children : index.roots
                }
            }
            let lowered = partial.lowercased()
            for child in childSource {
                let name = index.elements[child].name
                if lowered.isEmpty || name.lowercased().hasPrefix(lowered) {
                    if seen.insert(name).inserted { names.append(name) }
                }
            }
        }
        return Array(names.prefix(limit))
    }

    /// Trennt „/a/b/te“ in („/a/b“, „te“). Öffentlich für die Übernahme
    /// eines Vorschlags (Ersetzen des letzten Teilstücks).
    static func splitForCompletion(_ input: String) -> (path: String, partial: String) {
        guard let slash = input.range(of: "/", options: .backwards) else {
            return ("", input)
        }
        let path = String(input[..<slash.lowerBound])
        let partial = String(input[slash.upperBound...])
        // Bei `//` den zweiten Schrägstrich im Pfad behalten. Nur dann kann
        // sowohl die Vorschlagsquelle als auch die spätere Übernahme die
        // Descendant-Achse unverändert fortsetzen.
        if path.hasSuffix("/") {
            return (String(input[..<slash.upperBound]), partial)
        }
        if path.isEmpty || path == "/" {
            return (String(input[..<slash.upperBound]), partial)
        }
        return (path, partial)
    }
}
