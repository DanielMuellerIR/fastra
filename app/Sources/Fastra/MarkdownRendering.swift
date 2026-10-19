import Foundation
import ImageIO
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
                       extraction: MarkdownMath.Extraction,
                       includingLine: (Int) -> Bool = { _ in true }) {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for (offset, line) in normalized.components(separatedBy: "\n").enumerated()
            where isVisibleBlankLine(line) && includingLine(offset + 1) {
            let preparedLine = offset + 1
            let originalLine = extraction.originalLine(for: preparedLine)
            _ = insert(line: preparedLine, originalLine: originalLine, into: document)
        }
    }

    private static func isVisibleBlankLine(_ line: String) -> Bool {
        var content = line[...]
        // Zitatmarker gehören zur Blockstruktur, nicht zur sichtbaren Zeile.
        // Codeblöcke werden beim Einsetzen weiterhin ausdrücklich übersprungen.
        while let marker = content.firstIndex(where: { $0 != " " }), content[marker] == ">" {
            content = content[content.index(after: marker)...]
            if content.first == " " { content = content.dropFirst() }
        }
        return content.count >= 2 && content.utf8.allSatisfy { $0 == 0x20 }
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
            // cmark rechnet nachlaufenden Leerraum einer Liste dem letzten
            // Listeneintrag zu. Ist dieser Eintrag leer, hat er keine Kinder,
            // obwohl sein Quellbereich die Leerraumzeilen umfasst. Die Blöcke
            // müssen hinter die Liste, sonst erscheint ihr erster Abstand als
            // Aufzählungspunkt statt als vollständig leere Textzeile.
            if addAfterTrailingListItem(originalLine: originalLine, item: enclosing) {
                return true
            }
            // Ein Blatt kann keine echte Leerzeile enthalten. Falls eine
            // Erweiterung dennoch einen übergreifenden Bereich meldet, lassen
            // wir ihn lieber unverändert, statt seine Semantik zu erraten.
            return true
        }

        let next = children.first { Int(cmark_node_get_start_line($0)) > line }
        let previous = children.last { Int(cmark_node_get_end_line($0)) < line }

        // Hat der letzte Eintrag einer Liste noch Text, kann cmark die
        // folgenden Leerraumzeilen trotzdem seinem Quellbereich zuschlagen.
        // Nach dem erfolglosen Abstieg liegt der Abstand sicher hinter seinem
        // letzten echten Kind und wird deshalb genauso hinter die Liste gelegt.
        if let lastChild = children.last,
           Int(cmark_node_get_end_line(lastChild)) < line,
           addAfterTrailingListItem(originalLine: originalLine, item: container) {
            return true
        }

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

    /// Fügt den Abstand nach einer Liste und nicht in ihren letzten Eintrag.
    /// Eigene Custom-Blöcke werden beim wiederholten Einfügen übersprungen,
    /// damit mehrere Quellzeilen ihre natürliche Reihenfolge behalten.
    private static func addAfterTrailingListItem(
        originalLine: Int,
        item: UnsafeMutablePointer<cmark_node>
    ) -> Bool {
        guard cmark_node_get_type(item) == CMARK_NODE_ITEM,
              cmark_node_next(item) == nil,
              let list = cmark_node_parent(item),
              cmark_node_get_type(list) == CMARK_NODE_LIST,
              let parent = cmark_node_parent(list),
              cmark_node_can_contain_type(parent, CMARK_NODE_CUSTOM_BLOCK) else {
            return false
        }
        var next = cmark_node_next(list)
        while let current = next,
              cmark_node_get_type(current) == CMARK_NODE_CUSTOM_BLOCK {
            next = cmark_node_next(current)
        }
        return addBlankNode(originalLine: originalLine, to: parent, before: next)
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
        private let originalEndLine: Int?

        private let replacements: [(token: String, html: String, block: Bool)]

        init(markdown: String,
             replacements: [(token: String, html: String, block: Bool)],
             sourceLines: [Int] = [], originalEndLine: Int? = nil) {
            self.markdown = markdown
            self.replacements = replacements
            self.sourceLines = sourceLines
            self.originalEndLine = originalEndLine
        }

        /// Rechnet eine 1-basierte Zeile aus dem vorverarbeiteten Text auf die
        /// zugehörige 1-basierte Zeile im Originaldokument um.
        func originalLine(for line: Int) -> Int {
            guard line >= 1 else { return 1 }
            guard !sourceLines.isEmpty else { return line }
            guard line <= sourceLines.count else { return originalEndLine ?? line }
            return sourceLines[line - 1]
        }

        func insertingHTML(into renderedHTML: String) -> String {
            let values = Dictionary(uniqueKeysWithValues: replacements.map { ($0.token, $0) })
            let ns = renderedHTML as NSString
            let changes = MarkdownMath.htmlTokens.matches(
                in: renderedHTML, range: NSRange(location: 0, length: ns.length)
            ).compactMap { match -> (NSRange, String)? in
                let paragraphToken = match.range(at: 1)
                let tokenRange = paragraphToken.location != NSNotFound ? paragraphToken : match.range(at: 2)
                guard let value = values[ns.substring(with: tokenRange)] else { return nil }
                // Ein alleinstehender Block ersetzt auch den Absatz mit seinen
                // Quellzeilen-Attributen; Inline-Formeln behalten den Absatz.
                return (value.block && paragraphToken.location != NSNotFound ? match.range : tokenRange, value.html)
            }
            return MarkdownMath.applying(changes, to: renderedHTML)
        }
    }

    private static let mathTokenPattern = #"FASTRAMATH[0-9A-F]{32}TOKEN"#
    private static let mathTokens = try! NSRegularExpression(pattern: mathTokenPattern)
    private static let htmlTokens = try! NSRegularExpression(
        pattern: "<p[^>]*>(\(mathTokenPattern))</p>|(\(mathTokenPattern))"
    )
    private static let codeTokens = try! NSRegularExpression(
        pattern: #"FASTRACODE(?:BLOCK|SPAN)[0-9A-F]{32}TOKEN"#
    )

    /// Alle Spannen beziehen sich auf denselben Quellstand. Ein Vorwärtslauf
    /// vermeidet wiederholtes Verschieben und erneutes Durchsuchen des Textes.
    private static func applying(_ changes: [(NSRange, String)], to source: String) -> String {
        guard !changes.isEmpty else { return source }
        let ns = source as NSString
        var result = "", cursor = 0
        result.reserveCapacity(source.utf8.count)
        for (range, replacement) in changes {
            result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            result += replacement
            cursor = range.upperBound
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func restoringCode(in source: String, values: [String: String]) -> String {
        let ns = source as NSString
        let changes = codeTokens.matches(in: source, range: NSRange(location: 0, length: ns.length))
            .compactMap { match -> (NSRange, String)? in
                guard let value = values[ns.substring(with: match.range)] else { return nil }
                return (match.range, value)
            }
        return applying(changes, to: source)
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

    private struct Match: Equatable {
        let range: NSRange
        let content: NSRange
    }

    private static let fenceOpen = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]{0,3}(`{3,}+|~{3,}+)"#
    )
    private static let fenceClose = try! NSRegularExpression(
        pattern: #"(?m)\n[ \t]{0,3}(`{3,}+|~{3,}+)[ \t]*+(?=\n|$)"#
    )
    private static let blockOpen = try! NSRegularExpression(pattern: #"(?m)^[ \t]*+\$\$"#)
    private static let blockClose = try! NSRegularExpression(pattern: #"(?m)\$\$[ \t]*+$"#)
    private static let doubleOpen = try! NSRegularExpression(pattern: #"(?=(?<!\\)\$\$(?!\s))"#)
    private static let doubleClose = try! NSRegularExpression(pattern: #"(?=((?<!\s)\$\$))"#)

    /// Die TeX-Syntax bleibt bei den bisherigen regulären Ausdrücken. Ein
    /// vorher indizierter Schlussmarker verhindert aber, dass jeder erfolglose
    /// Anfang erneut den gesamten Rest des Dokuments durchsucht.
    private static func boundedMatches(of regex: NSRegularExpression, in source: String) -> [Match] {
        boundedMatches(of: regex, in: source, checkCancellation: {})
    }

    private static func boundedMatches(of regex: NSRegularExpression, in source: String,
                                       checkCancellation: () throws -> Void) rethrows -> [Match] {
        try checkCancellation()
        let ns = source as NSString
        let full = NSRange(location: 0, length: ns.length)
        if regex === fencedCode { return try fenceMatches(in: source, checkCancellation: checkCancellation) }
        let openings: NSRegularExpression
        let closings: NSRegularExpression
        if regex === blockMath { openings = blockOpen; closings = blockClose }
        else if regex === inlineDoubleMath { openings = doubleOpen; closings = doubleClose }
        else {
            return regex.matches(in: source, range: full).map {
                Match(range: $0.range, content: $0.numberOfRanges > 1 ? $0.range(at: 1) : $0.range)
            }
        }
        let ends = closings.matches(in: source, range: full).map {
            regex === inlineDoubleMath ? $0.range(at: 1) : $0.range
        }
        guard !ends.isEmpty else { return [] }
        var result: [Match] = [], consumed = 0
        // Bei Inline-Formeln ist der letzte Schlussmarker derselben Zeile
        // nötig: Der Punkt im bestehenden Ausdruck überschreitet keine Zeile.
        var lineEnds: [Int: Int] = [:]
        var lineForOffset: [Int] = []
        if regex === inlineDoubleMath {
            lineForOffset = [Int](repeating: 0, count: ns.length + 1)
            var line = 0
            for offset in 0..<ns.length {
                if offset % 4096 == 0 { try checkCancellation() }
                lineForOffset[offset] = line
                if [UInt16(10), 13, 0x85, 0x2028, 0x2029].contains(ns.character(at: offset)) { line += 1 }
            }
            for end in ends { lineEnds[lineForOffset[end.location]] = end.upperBound }
        }
        for opening in openings.matches(in: source, range: full) where opening.range.location >= consumed {
            try checkCancellation()
            let start = opening.range.location
            let end = regex === inlineDoubleMath ? lineEnds[lineForOffset[start]] : ends.last?.upperBound
            guard let end, end > start + 2,
                  let match = regex.firstMatch(in: source,
                    options: [.anchored, .withTransparentBounds, .withoutAnchoringBounds],
                    range: NSRange(location: start, length: end - start)) else { continue }
            result.append(Match(range: match.range, content: match.range(at: 1)))
            consumed = match.range.upperBound
        }
        return result
    }

    private static func fenceMatches(in source: String,
                                     checkCancellation: () throws -> Void) rethrows -> [Match] {
        let ns = source as NSString, full = NSRange(location: 0, length: source.utf16.count)
        var closingByMarker: [UInt16: [Int: [NSRange]]] = [:]
        for closing in fenceClose.matches(in: source, range: full) {
            try checkCancellation()
            let marker = closing.range(at: 1)
            closingByMarker[ns.character(at: marker.location), default: [:]][marker.length, default: []].append(closing.range)
        }
        let newlines = Array(source.utf16).enumerated().compactMap { $0.element == 10 ? $0.offset : nil }
        var result: [Match] = [], consumed = 0
        for opening in fenceOpen.matches(in: source, range: full) {
            try checkCancellation()
            let rawStart = opening.range.location
            let start = rawStart > 0 && ns.character(at: rawStart - 1) == 10 && rawStart - 1 >= consumed ? rawStart - 1 : rawStart
            guard start >= consumed else { continue }
            let marker = opening.range(at: 1)
            var lineLower = 0, lineUpper = newlines.count
            while lineLower < lineUpper {
                let middle = (lineLower + lineUpper) / 2
                if newlines[middle] < marker.upperBound { lineLower = middle + 1 } else { lineUpper = middle }
            }
            guard lineLower < newlines.count else { continue }
            let openingEnd = newlines[lineLower] + 1
            guard let lengths = closingByMarker[ns.character(at: marker.location)] else { continue }
            // Der alte Backreference-Ausdruck versucht zuerst die längste
            // öffnende Fence und verkürzt sie nur, wenn dafür kein Ende folgt.
            var selected: NSRange?
            for length in stride(from: marker.length, through: 3, by: -1) {
                guard let candidates = lengths[length] else { continue }
                var lower = 0, upper = candidates.count
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if candidates[middle].location < openingEnd { lower = middle + 1 }
                    else { upper = middle }
                }
                if lower < candidates.count { selected = candidates[lower]; break }
            }
            guard let selected else { continue }
            let range = NSRange(location: start, length: selected.upperBound - start)
            result.append(Match(range: range, content: range))
            consumed = range.upperBound
        }
        return result
    }

    /// Quellbereiche, die der Renderer als Formel behandelt. Andere Parser
    /// dürfen darin keine vermeintlichen Bildlinks oder Formatierungen übernehmen.
    static func formulaRanges(in markdown: String) -> [NSRange] {
        formulaRanges(in: markdown, checkCancellation: {})
    }

    static func formulaRanges(in markdown: String,
                              checkCancellation: () throws -> Void) rethrows -> [NSRange] {
        try checkCancellation()
        // CRLF schrumpft nur im Analyse-Text; die Grenzpositionen bleiben
        // auf UTF-16-Indizes der unveränderten Quelle abgebildet.
        let units = Array(markdown.utf16)
        var normalized: [UInt16] = [], positions = [0]
        var offset = 0
        while offset < units.count {
            if offset % 4096 == 0 { try checkCancellation() }
            let unit = units[offset]
            offset += 1
            if unit == 13, offset < units.count, units[offset] == 10 { offset += 1 }
            normalized.append(unit == 13 ? 10 : unit)
            positions.append(offset)
        }
        let source = String(decoding: normalized, as: UTF16.self)
        let code = try [fencedCode, inlineCode].flatMap {
            try boundedMatches(of: $0, in: source, checkCancellation: checkCancellation).map(\.range)
        }.sorted { $0.location < $1.location }
        var codeEnds: [Int] = []
        for range in code { codeEnds.append(max(codeEnds.last ?? 0, range.upperBound)) }
        return try [blockMath, inlineDoubleMath, inlineMath].flatMap {
            try boundedMatches(of: $0, in: source, checkCancellation: checkCancellation).map(\.range)
        }.filter { candidate in
            try checkCancellation()
            var lower = 0, upper = code.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if code[middle].location < candidate.upperBound { lower = middle + 1 } else { upper = middle }
            }
            return lower == 0 || codeEnds[lower - 1] <= candidate.location
        }
            .map { NSRange(location: positions[$0.location], length: positions[$0.upperBound] - positions[$0.location]) }
    }

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

        working = restoringCode(in: working, values: Dictionary(uniqueKeysWithValues: protected.map { ($0.token, $0.source) }))
        return Extraction(
            markdown: working,
            replacements: replacements,
            sourceLines: sourceLineMap(for: working,
                                       consumed: consumed,
                                       protected: protected),
            originalEndLine: markdown.components(separatedBy: "\n").count + 1
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
        let code = Dictionary(uniqueKeysWithValues: protected.map { ($0.token, $0.source) })
        for item in consumed {
            var raw = item.rawSource
            // Ein `$$`-Block kann geschützte Code-Token enthalten. Für die
            // Zeilenzählung muss dort der echte Quelltext stehen.
            if raw.contains("FASTRACODE") {
                raw = restoringCode(in: raw, values: code)
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
            let ns = line as NSString
            for match in mathTokens.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                offset += extraLines[ns.substring(with: match.range)] ?? 0
            }
        }
        return map
    }

    private static func stashMatches(of regex: NSRegularExpression,
                                     in source: String,
                                     prefix: String,
                                     storage: inout [(token: String, source: String)]) -> String {
        var changes: [(NSRange, String)] = []
        let matches = boundedMatches(of: regex, in: source)
        for match in matches {
            let token = "\(prefix)\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))TOKEN"
            let original = (source as NSString).substring(with: match.range)
            storage.append((token, original))
            changes.append((match.range, token))
        }
        return applying(changes, to: source)
    }

    private static func replaceMath(
        using regex: NSRegularExpression,
        in source: String,
        block: Bool,
        storage: inout [(token: String, html: String, block: Bool)],
        consumed: inout [(token: String, rawSource: String)]
    ) -> String {
        var changes: [(NSRange, String)] = []
        let matches = boundedMatches(of: regex, in: source)
        for match in matches {
            let tex = (source as NSString).substring(with: match.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tex.isEmpty else { continue }
            let token = "FASTRAMATH\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))TOKEN"
            let kind = block ? "div" : "span"
            let cssClass = block ? "math-block" : "math-inline"
            let html = "<\(kind) class=\"\(cssClass)\" data-tex=\"\(htmlAttributeEscaped(tex))\"></\(kind)>"
            storage.append((token, html, block))
            // Ganzen ersetzten Bereich merken (nicht nur die TeX-Gruppe): nur
            // daraus lässt sich die im Original belegte Zeilenzahl bestimmen.
            consumed.append((token, (source as NSString).substring(with: match.range)))
            changes.append((match.range, token))
        }
        return applying(changes, to: source)
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
    private final class ImageSize: NSObject {
        let width: Double?
        init(width: Double?) { self.width = width }
    }

    private static let imageSizes: NSCache<NSString, ImageSize> = {
        let cache = NSCache<NSString, ImageSize>()
        cache.countLimit = 512
        return cache
    }()

    private static let imageTags = try! NSRegularExpression(
        pattern: #"(?i)<img\b(?:[^"'<>]|"[^"]*"|'[^']*')*>"#
    )

    static func resolve(in html: String, relativeTo documentURL: URL?,
                        preservingSource: Bool = false) -> MarkdownRenderedFragment {
        let mutable = NSMutableString(string: html)
        let ns = html as NSString
        var images: [String: URL] = [:]
        for tag in imageTags.matches(in: html, range: NSRange(location: 0, length: ns.length)).reversed() {
            let rawTag = ns.substring(with: tag.range)
            let attributes = MarkdownHTMLAttributes.parse(rawTag)
            guard let attribute = attributes.first(where: { $0.name == "src" }) else { continue }
            let replacement: String
            var displayWidth: Double?
            if let imageURL = localImageURL(from: attribute.value, documentURL: documentURL),
               MarkdownPreviewAssets.imageMIMEType(for: imageURL) != nil {
                let token = imageToken(for: imageURL)
                images[token] = imageURL
                replacement = "\(MarkdownPreviewAssets.scheme)://image/\(token)"
                if !attributes.contains(where: { $0.name == "width" || $0.name == "height" }) {
                    displayWidth = logicalWidth(of: imageURL, token: token)
                }
            } else { replacement = "" }
            let output = NSMutableString(string: rawTag)
            // Ein eigenes Attribut vermeidet Abhängigkeiten vom Quote-Zeichen des src.
            output.replaceCharacters(in: attribute.valueRange, with: replacement)
            if let displayWidth {
                output.insert(" width=\"\(displayWidth)\"", at: 4)
            }
            if preservingSource {
                let escaped = attribute.value.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "\"", with: "&quot;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                output.insert(" data-md-src=\"\(escaped)\"", at: 4)
            }
            mutable.replaceCharacters(in: tag.range, with: output as String)
        }
        return MarkdownRenderedFragment(html: mutable as String, imageURLs: images)
    }

    //DM 2026-10-14 WebKit ignoriert die DPI für die Layoutgröße. Metadaten ohne
    // Pixeldekodierung lesen und nach Dateiidentität puffern, nicht bei jedem Tastendruck.
    private static func logicalWidth(of url: URL, token: String) -> Double? {
        if let cached = imageSizes.object(forKey: token as NSString) { return cached.width }
        var width: Double?
        if let data = try? MarkdownPreviewAssets.readImageData(url),
           let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let rotated = (5...8).contains((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1)
            let pixels = (properties[rotated ? kCGImagePropertyPixelHeight : kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
            let dpi = (properties[rotated ? kCGImagePropertyDPIHeight : kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 0
            if pixels.isFinite, pixels > 0, dpi.isFinite, dpi > 72 {
                width = pixels * 72 / dpi
            }
        }
        imageSizes.setObject(ImageSize(width: width), forKey: token as NSString)
        return width
    }

    /// Interner Name, unter dem WebKit ein Bild anfordert.
    ///
    /// Er beschreibt die IDENTITÄT der Datei (Pfad, Inode, Größe, Änderungs-
    /// und Statusänderungszeit) und nicht mehr ihre Position im Dokument. Der
    /// frühere Name „image-0" war für das erste Bild jedes Renderlaufs
    /// derselbe: Nach dem Austausch eines Bildes lieferte WebKit unter der
    /// unveränderten Adresse die zuvor geladene Datei aus seinem
    /// Speicher-Cache — im Quelltext stand der neue Dateiname, die Vorschau
    /// zeigte das alte Bild, und erst ein Neustart der App räumte den Cache
    /// (Daniel-Befund 2026-08-06).
    ///
    /// Unverändertes Bild → unveränderter Name → WebKit lädt es beim Tippen
    /// nicht bei jedem Zeichen neu.
    static func imageToken(for url: URL) -> String {
        // Der Zielpfad ist symlink-aufgelöst, damit ein Link die Identität
        // seiner Zieldatei meldet und nicht die des Links (AGENTS.md).
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        // Bewusst `stat(2)` statt `URL.resourceValues` oder
        // `FileManager.attributesOfItem`:
        //   • Eine URL merkt sich einmal gelesene Dateiattribute und lieferte
        //     für dieselbe URL weiterhin die ALTE Größe, nachdem die Datei
        //     ersetzt wurde.
        //   • `attributesOfItem` baut für jedes Bild ein Wörterbuch mit
        //     Objective-C-Objekten auf. Das läuft bei JEDEM Renderlauf, also
        //     beim Tippen — ein einzelner Systemaufruf ist hier deutlich
        //     billiger.
        //   • Nur `stat` liefert Inode und `st_ctime`, und genau die fehlten
        //     der Identität: Ein inhaltlich anderes Bild kann mit GLEICHER
        //     Größe und beibehaltenem Änderungsdatum eintreffen — etwa durch
        //     ein Sync-Werkzeug, das Zeitstempel erhält, oder auf einem
        //     Dateisystem mit grober Zeitauflösung. Beim atomaren Ersetzen
        //     wechselt das Inode, und `st_ctime` lässt sich aus dem
        //     Nutzerraum nicht zurückstellen: Selbst das Zurücksetzen des
        //     Änderungsdatums setzt es auf „jetzt" (Review 2026-08-06).
        var info = stat()
        guard stat(path, &info) == 0 else {
            // Fehlt die Datei (oder verweigert sie Auskunft), bleibt der Pfad
            // allein die Identität — dann gibt es ohnehin nichts anzuzeigen.
            return "image-\(stableHash(path))"
        }
        let identity = """
        \(path)|\(info.st_dev)|\(info.st_ino)|\(info.st_size)|\
        \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)|\
        \(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)
        """
        return "image-\(stableHash(identity))"
    }

    /// FNV-1a (64 Bit) als Hexzeichenkette. Swifts eingebauter `Hasher` ist
    /// pro Programmstart zufällig gesalzen und taugt deshalb weder für einen
    /// stabilen Test noch für eine über Renderläufe hinweg gleiche Adresse.
    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private static func localImageURL(from rawSource: String,
                                      documentURL: URL?) -> URL? {
        let unescaped = rawSource
        // Ein echtes `#` trennt das URL-Fragment ab. `%23` ist dagegen ein
        // zulässiges Rautezeichen IM Dateinamen und darf erst danach decodiert
        // werden. Die frühere Reihenfolge kürzte solche Pfade auf den Teil vor
        // `%23` und ließ vorhandene Bilder dadurch scheinbar verschwinden.
        let encodedPath = unescaped.split(
            separator: "#",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? unescaped
        let decoded = encodedPath.removingPercentEncoding ?? encodedPath
        guard !decoded.isEmpty,
              !decoded.hasPrefix("//") else { return nil }

        if let components = URLComponents(string: decoded), components.scheme != nil {
            return nil
        }
        guard !decoded.hasPrefix("/"), let documentURL else { return nil }
        return documentURL.deletingLastPathComponent()
            .appendingPathComponent(decoded)
            .standardizedFileURL
    }

}
