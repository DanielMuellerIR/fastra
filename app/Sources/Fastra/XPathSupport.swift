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
                return L10n.string("XML an dieser Stelle nicht lesbar — der letzte gültige Index bleibt aktiv.")
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

        func skip(until marker: [Character], from: Int) -> Int {
            var i = from
            while i < count {
                var matched = true
                for (offset, m) in marker.enumerated() {
                    if char(i + offset) != m { matched = false; break }
                }
                if matched { return i + marker.count }
                i += 1
            }
            return count
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

        while index < count {
            guard let c = char(index) else { index += 1; continue }
            if c != "<" {
                // Textinhalt: erste nicht-Whitespace-Stelle je Element merken.
                if !c.isWhitespace, let top = stack.last,
                   elements[top].firstTextRange == nil {
                    var end = index
                    while end < count, char(end) != "<" { end += 1 }
                    var lastNonWS = index
                    var probe = index
                    while probe < end {
                        if let pc = char(probe), !pc.isWhitespace { lastNonWS = probe }
                        probe += 1
                    }
                    elements[top].firstTextRange = NSRange(location: index,
                                                           length: lastNonWS - index + 1)
                    index = end
                    continue
                }
                index += 1
                continue
            }

            // `<`-Konstrukte unterscheiden.
            if char(index + 1) == "!" {
                if char(index + 2) == "-", char(index + 3) == "-" {
                    index = skip(until: ["-", "-", ">"], from: index + 4)
                } else if char(index + 2) == "[" {
                    // CDATA zählt als Text des offenen Elements.
                    let start = index
                    index = skip(until: ["]", "]", ">"], from: index + 9)
                    if let top = stack.last, elements[top].firstTextRange == nil {
                        elements[top].firstTextRange = NSRange(location: start,
                                                               length: index - start)
                    }
                } else {
                    index = skip(until: [">"], from: index + 2)
                }
                continue
            }
            if char(index + 1) == "?" {
                index = skip(until: ["?", ">"], from: index + 2)
                continue
            }
            if char(index + 1) == "/" {
                // Schließ-Tag: muss zum obersten Stapel-Element passen.
                let (name, afterName) = readName(from: index + 2)
                guard let top = stack.popLast() else {
                    return .failure(.malformed(offset: index))
                }
                guard elements[top].name == name else {
                    return .failure(.mismatchedTag(expected: elements[top].name,
                                                   found: name, offset: index))
                }
                index = skip(until: [">"], from: afterName)
                continue
            }

            // Start-Tag.
            let nameStart = index + 1
            let (name, afterName) = readName(from: nameStart)
            guard !name.isEmpty else {
                index += 1
                continue
            }
            var attributes: [Attribute] = []
            var i = afterName
            var selfClosing = false
            attributeScan: while i < count {
                guard let ac = char(i) else { break }
                if ac == ">" { i += 1; break }
                if ac == "/" && char(i + 1) == ">" {
                    selfClosing = true
                    i += 2
                    break
                }
                if ac.isWhitespace { i += 1; continue }
                // Attributname lesen.
                let attrNameStart = i
                let (attrName, afterAttrName) = readName(from: i)
                guard !attrName.isEmpty else {
                    return .failure(.malformed(offset: i))
                }
                i = afterAttrName
                while i < count, char(i)?.isWhitespace == true { i += 1 }
                var value = ""
                if char(i) == "=" {
                    i += 1
                    while i < count, char(i)?.isWhitespace == true { i += 1 }
                    if let quote = char(i), quote == "\"" || quote == "'" {
                        i += 1
                        let valueStart = i
                        while i < count, char(i) != quote { i += 1 }
                        if let range = Range(NSRange(location: valueStart,
                                                     length: i - valueStart), in: text) {
                            value = String(text[range])
                        }
                        i += 1   // schließendes Quote
                    } else {
                        return .failure(.malformed(offset: i))
                    }
                }
                attributes.append(Attribute(
                    name: attrName, value: value,
                    nameRange: NSRange(location: attrNameStart,
                                       length: afterAttrName - attrNameStart)
                ))
                continue attributeScan
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

        // Nicht unterstützte Achsen/Funktionen früh und verständlich melden.
        for unsupported in ["::", "..", "ancestor", "following", "preceding"] {
            if rest.contains(unsupported) {
                return .failure(.unsupported(unsupported))
            }
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
                guard let close = rest.firstIndex(of: "]") else {
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
        for child in children(of: node, in: index) {
            result.append(child)
            collectDescendants(of: child, in: index, into: &result)
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
        // `/a//te` liefert den Pfad „/a/“ — hängende Trenner fürs Parsen
        // entfernen (die Trenn-Art des angefangenen Schritts ist für die
        // Vorschlagsliste unerheblich).
        var prefixPath = rawPrefix
        while prefixPath.count > 2 && prefixPath.hasSuffix("/") {
            prefixPath = String(prefixPath.dropLast())
        }

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
            if contextElements == [-1] {
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
        // `//te` → Pfad leer, Partial „te“ (descendant bleibt beim Zusammenbau).
        if path.isEmpty || path == "/" {
            return (String(input[..<slash.upperBound]), partial)
        }
        return (path, partial)
    }
}
