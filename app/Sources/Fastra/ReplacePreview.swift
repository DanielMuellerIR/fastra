// ReplacePreview.swift
//
// Vorher/Nachher-Vorschau der Ersetzungen im aktiven Buffer (v0.10).
//
// REINE, voll testbare Logik (kein UI, kein Workspace) — gleiche Trennung wie
// `BufferSearch`/`ApplyEngine`. Aus den ECHTEN Treffern (jeder `Match` trägt
// `matchText` und den fertig aufgelösten `replacedText` inkl. $1-Backrefs)
// wird pro betroffener Zeile eine Vorher- und eine Nachher-Fassung gebaut.
//
// Warum pro Zeile statt global Vorher-Text vs. Nachher-Text:
//   Ein globaler Zeilen-Diff bräuchte eine Zeilen-Ausrichtung (LCS), sobald
//   eine Ersetzung Zeilenumbrüche einfügt/entfernt. Der Per-Zeile-Ansatz ist
//   für den häufigen Fall (Treffer bleiben in IHRER Zeile) immer korrekt und
//   ohne Alignment-Risiko: jede betroffene Zeile bildet genau ein
//   Vorher/Nachher-Paar. Mehrzeilige RegEx-Treffer (selten) werden auf das
//   Zeilenende geklammert — kein Crash, nur eine leicht verkürzte Nachzeile.

import Foundation

enum ReplacePreview {

    enum SideKind: Equatable, Sendable {
        case unchanged, changed, removed, added
    }

    struct SideBySideRow: Identifiable, Equatable, Sendable {
        let id: Int
        let beforeLine: Int?
        let afterLine: Int?
        let before: String?
        let after: String?
        let kind: SideKind
    }

    struct SideBySideResult: Equatable, Sendable {
        let rows: [SideBySideRow]
        let totalRows: Int
        let changedRows: Int
        var truncated: Bool { rows.count < totalRows }
        var visibleChangedRows: Int {
            rows.reduce(0) { $0 + ($1.kind == .unchanged ? 0 : 1) }
        }
        /// Apply darf nur laufen, wenn jede geänderte Zeile in der Vorschau
        /// enthalten ist. Ausgeblendeter unveränderter Kontext ist zulässig.
        var allChangedRowsVisible: Bool { visibleChangedRows == changedRows }
        static let empty = SideBySideResult(rows: [], totalRows: 0, changedRows: 0)
    }

    /// Harte Rechengrenzen des vollständigen Dokument-Diffs. Anders als
    /// `maxRows` begrenzen sie nicht bloß die Anzeige, sondern lehnen einen
    /// Auftrag sichtbar ab: Ein nur teilweise berechneter Diff dürfte Apply
    /// niemals als vollständige Vorschau freigeben.
    struct SideBySideLimits: Equatable, Sendable {
        let maximumTextBytes: Int
        let maximumLineCount: Int
        let maximumDiffInputLines: Int

        /// Die Textgrenze entspricht der Volllade-Grenze editierbarer Dateien.
        /// Der Zeilen- und Myers-Mittelteil folgen den bewährten Grenzen des
        /// Datei-Vergleichs (`FileDiff`).
        static let standard = SideBySideLimits(
            maximumTextBytes: Int(FileLoader.largeFileThreshold),
            maximumLineCount: FileDiff.maximumLineCount,
            maximumDiffInputLines: FileDiff.maximumDiffInputLines)
    }

    enum SideBySideLimitation: Equatable, Sendable {
        case tooLarge(maximumBytes: Int)
        case tooManyLines(maximumLines: Int)
        case tooDifferent(maximumLines: Int)
        /// Die Suche hat nicht alle Treffer materialisiert. Ein Diff aus der
        /// gekappten Teilmenge wäre keine vollständige Apply-Vorschau.
        case incompleteMatchSet(visibleMatches: Int, totalMatches: Int)
    }

    /// Vollständiges Ergebnis, erklärte Grenze oder kooperativer Abbruch.
    /// `cancelled` wird nie als Nutzerfehler gezeigt: Das Modell verwirft den
    /// überholten Lauf und startet für die neue Dokumentgeneration neu.
    enum SideBySideOutcome: Equatable, Sendable {
        case result(SideBySideResult)
        case limitation(SideBySideLimitation)
        case cancelled
    }

    /// Eine betroffene Zeile mit Original- und Ersetzungs-Fassung.
    struct Row: Identifiable, Equatable {
        /// 1-basierte Zeilennummer (wie in der Trefferliste). Dient ZUGLEICH als
        /// stabile `Identifiable`-Identität: `build` fasst pro Zeile genau ein
        /// Vorher/Nachher-Paar zusammen, eine Zeilennummer kommt also höchstens
        /// einmal vor. Eine frische `UUID()` (vorher) würde bei jedem
        /// `build`-Aufruf neu vergeben — die Inline-Vorschau baut bei jedem
        /// Render neu → die ForEach-Identität bräche, View-Neuerzeugung/Flackern
        /// (dieselbe Falle, die früher schon `HitGroup` getroffen hat).
        var id: Int { line }
        let line: Int
        let before: String
        let after: String

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.line == rhs.line && lhs.before == rhs.before && lhs.after == rhs.after
        }
    }

    /// Vorschau-Ergebnis. `rows` ist auf `maxRows` gekappt; `totalChangedLines`
    /// nennt die WAHRE Zahl betroffener Zeilen (für „… und N weitere").
    struct Result: Equatable {
        let rows: [Row]
        let totalChangedLines: Int
        /// Wurde die Anzeige gekappt (mehr betroffene Zeilen als angezeigt)?
        var truncated: Bool { rows.count < totalChangedLines }

        static let empty = Result(rows: [], totalChangedLines: 0)
    }

    /// Baut die Vorschau. `maxRows` begrenzt die ANGEZEIGTEN Zeilen (Schutz
    /// gegen riesige Vorschau-Listen); gezählt werden alle geänderten Zeilen.
    /// Zeilen, bei denen Ersetzung == Original (z.B. Suchen == Ersetzen-Text),
    /// erscheinen NICHT — sie sind keine echte Änderung.
    static func build(text: String, matches: [BufferSearch.Match], maxRows: Int = 500) -> Result {
        guard !matches.isEmpty else { return .empty }
        let ns = text as NSString

        // DEFENSIV gegen STALE Treffer: Bei einem Tab-/Datei-Wechsel (oder dem
        // Apply-Reload) kann `matches` noch die Treffer des VORHERIGEN Inhalts
        // tragen, während `text` bereits der neue — evtl. kürzere oder leere —
        // Inhalt ist, bis die debounced Suche neu durchläuft. Eine Range, die
        // über `ns.length` hinausragt, brächte `lineRange(for:)` zum Absturz
        // (real reproduziert über die inline Live-Vorschau beim Tab-Wechsel).
        // Solche Treffer überspringen wir, statt zu crashen — der nächste
        // Such-Lauf liefert konsistente Treffer nach.
        let inBounds = matches.filter {
            $0.range.location >= 0 && $0.range.location + $0.range.length <= ns.length
        }
        guard !inBounds.isEmpty else { return .empty }

        // Treffer nach Zeile gruppieren. `inBounds` kommen in Vorkommens-
        // Reihenfolge (BufferSearch) → `lineOrder` bleibt aufsteigend.
        var byLine: [Int: [BufferSearch.Match]] = [:]
        var lineOrder: [Int] = []
        for m in inBounds {
            if byLine[m.line] == nil { lineOrder.append(m.line) }
            byLine[m.line, default: []].append(m)
        }

        var rows: [Row] = []
        var changed = 0
        for line in lineOrder {
            guard let group = byLine[line], let first = group.first else { continue }
            let sorted = group.sorted { $0.range.location < $1.range.location }
            // Voller Zeilenbereich inkl. Terminator, dann Terminator weg.
            let full = ns.lineRange(for: first.range)
            let content = trimmingTerminator(full, in: ns)
            let before = ns.substring(with: content)
            let after = stitchedAfterLine(ns: ns, content: content, matches: sorted)
            guard before != after else { continue }  // keine sichtbare Änderung
            changed += 1
            if rows.count < maxRows {
                rows.append(Row(line: line, before: before, after: after))
            }
        }
        return Result(rows: rows, totalChangedLines: changed)
    }

    /// Vollständiger Dokument-Diff. Zuerst entsteht der echte Nachher-Text
    /// über alle Treffer hinweg; anschließend richtet `CollectionDifference`
    /// eingefügte und entfernte Zeilen aus. Damit bleiben auch mehrzeilige
    /// Ersetzungen korrekt — anders als bei der kompakten Inline-Vorschau.
    static func buildSideBySide(
        text: String,
        matches: [BufferSearch.Match],
        maxRows: Int = 5_000,
        limits: SideBySideLimits = .standard,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> SideBySideOutcome {
        guard !shouldCancel() else { return .cancelled }
        let ns = text as NSString
        let valid = matches
            .filter { $0.range.location >= 0 && NSMaxRange($0.range) <= ns.length }
            .sorted { $0.range.location < $1.range.location }
        guard !shouldCancel() else { return .cancelled }
        guard !valid.isEmpty else { return .result(.empty) }
        guard text.utf8.count <= limits.maximumTextBytes else {
            return .limitation(.tooLarge(maximumBytes: limits.maximumTextBytes))
        }

        var after = ""
        after.reserveCapacity(min(text.utf8.count, limits.maximumTextBytes))
        var afterByteCount = 0
        var cursor = 0

        /// Prüft die Nachher-Größe VOR dem Anhängen. Dadurch erzeugt selbst
        /// ein riesiger Ersetzen-Text keinen kurzzeitig unbegrenzten String.
        func appendWithinLimit(_ piece: String) -> Bool {
            let pieceBytes = piece.utf8.count
            guard pieceBytes <= limits.maximumTextBytes - afterByteCount else {
                return false
            }
            after.append(contentsOf: piece)
            afterByteCount += pieceBytes
            return true
        }

        for match in valid where match.range.location >= cursor {
            guard !shouldCancel() else { return .cancelled }
            if match.range.location > cursor {
                let unchanged = ns.substring(with: NSRange(
                    location: cursor, length: match.range.location - cursor))
                guard appendWithinLimit(unchanged) else {
                    return .limitation(.tooLarge(
                        maximumBytes: limits.maximumTextBytes))
                }
            }
            guard appendWithinLimit(match.replacedText) else {
                return .limitation(.tooLarge(maximumBytes: limits.maximumTextBytes))
            }
            cursor = NSMaxRange(match.range)
        }
        if cursor < ns.length {
            guard appendWithinLimit(ns.substring(from: cursor)) else {
                return .limitation(.tooLarge(maximumBytes: limits.maximumTextBytes))
            }
        }
        guard !shouldCancel() else { return .cancelled }

        let beforeLines: [String]
        switch logicalLines(in: text, maximum: limits.maximumLineCount,
                            shouldCancel: shouldCancel) {
        case .lines(let lines): beforeLines = lines
        case .tooMany:
            return .limitation(.tooManyLines(maximumLines: limits.maximumLineCount))
        case .cancelled: return .cancelled
        }
        let afterLines: [String]
        switch logicalLines(in: after, maximum: limits.maximumLineCount,
                            shouldCancel: shouldCancel) {
        case .lines(let lines): afterLines = lines
        case .tooMany:
            return .limitation(.tooManyLines(maximumLines: limits.maximumLineCount))
        case .cancelled: return .cancelled
        }

        // Gleiche Zeilen erhalten denselben kleinen Integer. Danach zieht der
        // Lauf den gemeinsamen Anfang und das gemeinsame Ende ab; der nicht
        // abbrechbare Myers-Schritt bleibt dadurch auf den wirklich
        // unterschiedlichen, hart begrenzten Mittelteil beschränkt.
        var aliasByLine: [String: Int] = [:]
        func aliases(for lines: [String]) -> [Int]? {
            var aliases: [Int] = []
            aliases.reserveCapacity(lines.count)
            for (index, line) in lines.enumerated() {
                if index.isMultiple(of: 256), shouldCancel() { return nil }
                if let alias = aliasByLine[line] {
                    aliases.append(alias)
                } else {
                    let alias = aliasByLine.count
                    aliasByLine[line] = alias
                    aliases.append(alias)
                }
            }
            return aliases
        }
        guard let beforeAliases = aliases(for: beforeLines),
              let afterAliases = aliases(for: afterLines) else {
            return .cancelled
        }
        var prefix = 0
        while prefix < min(beforeAliases.count, afterAliases.count),
              beforeAliases[prefix] == afterAliases[prefix] {
            if prefix.isMultiple(of: 1024), shouldCancel() { return .cancelled }
            prefix += 1
        }
        var suffix = 0
        while suffix < min(beforeAliases.count, afterAliases.count) - prefix,
              beforeAliases[beforeAliases.count - 1 - suffix]
                == afterAliases[afterAliases.count - 1 - suffix] {
            if suffix.isMultiple(of: 1024), shouldCancel() { return .cancelled }
            suffix += 1
        }
        let beforeMid = beforeAliases[prefix..<(beforeAliases.count - suffix)]
        let afterMid = afterAliases[prefix..<(afterAliases.count - suffix)]
        guard beforeMid.count + afterMid.count <= limits.maximumDiffInputLines else {
            return .limitation(.tooDifferent(
                maximumLines: limits.maximumDiffInputLines))
        }
        guard !shouldCancel() else { return .cancelled }
        let difference = Array(afterMid).difference(from: Array(beforeMid))
        guard !shouldCancel() else { return .cancelled }
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(prefix + offset)
            case .insert(let offset, _, _): inserted.insert(prefix + offset)
            }
        }

        var all: [SideBySideRow] = []
        var beforeIndex = 0
        var afterIndex = 0
        var changedRows = 0
        while beforeIndex < beforeLines.count || afterIndex < afterLines.count {
            if all.count.isMultiple(of: 256), shouldCancel() { return .cancelled }
            let isRemoved = beforeIndex < beforeLines.count && removed.contains(beforeIndex)
            let isInserted = afterIndex < afterLines.count && inserted.contains(afterIndex)
            let row: SideBySideRow
            if isRemoved && isInserted {
                row = SideBySideRow(id: all.count, beforeLine: beforeIndex + 1,
                                    afterLine: afterIndex + 1,
                                    before: beforeLines[beforeIndex], after: afterLines[afterIndex],
                                    kind: .changed)
                beforeIndex += 1; afterIndex += 1; changedRows += 1
            } else if isRemoved {
                row = SideBySideRow(id: all.count, beforeLine: beforeIndex + 1,
                                    afterLine: nil, before: beforeLines[beforeIndex],
                                    after: nil, kind: .removed)
                beforeIndex += 1; changedRows += 1
            } else if isInserted {
                row = SideBySideRow(id: all.count, beforeLine: nil,
                                    afterLine: afterIndex + 1, before: nil,
                                    after: afterLines[afterIndex], kind: .added)
                afterIndex += 1; changedRows += 1
            } else if beforeIndex < beforeLines.count && afterIndex < afterLines.count {
                let kind: SideKind = beforeLines[beforeIndex] == afterLines[afterIndex]
                    ? .unchanged : .changed
                row = SideBySideRow(id: all.count, beforeLine: beforeIndex + 1,
                                    afterLine: afterIndex + 1,
                                    before: beforeLines[beforeIndex], after: afterLines[afterIndex],
                                    kind: kind)
                beforeIndex += 1; afterIndex += 1
                if kind == .changed { changedRows += 1 }
            } else if beforeIndex < beforeLines.count {
                row = SideBySideRow(id: all.count, beforeLine: beforeIndex + 1,
                                    afterLine: nil, before: beforeLines[beforeIndex],
                                    after: nil, kind: .removed)
                beforeIndex += 1; changedRows += 1
            } else {
                row = SideBySideRow(id: all.count, beforeLine: nil,
                                    afterLine: afterIndex + 1, before: nil,
                                    after: afterLines[afterIndex], kind: .added)
                afterIndex += 1; changedRows += 1
            }
            all.append(row)
        }
        guard !shouldCancel() else { return .cancelled }
        return .result(SideBySideResult(
            rows: rowsPrioritizingChanges(all, maxRows: maxRows),
            totalRows: all.count, changedRows: changedRows))
    }

    // MARK: - Intern

    /// Zerlegt Text nach derselben logischen Zeilensemantik wie Editor und
    /// Trefferliste. `components(separatedBy: .newlines)` trennt CRLF an
    /// BEIDEN Zeichen und erfindet dadurch zwischen echten Windows-Zeilen je
    /// eine Leerzeile. `getLineStart` behandelt CRLF dagegen als gemeinsamen
    /// Terminator und erhält eine abschließende leere Zeile ausdrücklich.
    private enum LogicalLinesResult {
        case lines([String])
        case tooMany
        case cancelled
    }

    private static func logicalLines(
        in text: String,
        maximum: Int,
        shouldCancel: @Sendable () -> Bool
    ) -> LogicalLinesResult {
        let ns = text as NSString
        guard ns.length > 0 else { return .lines([""]) }

        var lines: [String] = []
        var index = 0
        var endedWithTerminator = false
        while index < ns.length {
            if lines.count.isMultiple(of: 256), shouldCancel() {
                return .cancelled
            }
            guard lines.count < maximum else { return .tooMany }
            var end = NSNotFound
            var contentsEnd = NSNotFound
            ns.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                            for: NSRange(location: index, length: 0))
            guard end != NSNotFound, contentsEnd != NSNotFound,
                  end > index, contentsEnd >= index else { break }
            lines.append(ns.substring(with: NSRange(
                location: index, length: contentsEnd - index)))
            endedWithTerminator = contentsEnd < end
            index = end
        }
        if endedWithTerminator {
            guard lines.count < maximum else { return .tooMany }
            lines.append("")
        }
        return .lines(lines)
    }

    /// Begrenzt die Anzeige, ohne eine weit unten liegende Änderung hinter
    /// tausenden unveränderten Anfangszeilen zu verstecken. Zuerst kommen alle
    /// Änderungszeilen in die Auswahl; freie Plätze werden anschließend mit
    /// möglichst nahem Kontext vor und nach den Änderungen gefüllt. Sind mehr
    /// Änderungen als Plätze vorhanden, enthält die Vorschau nur den ersten
    /// Teil der Änderungen und `allChangedRowsVisible` sperrt Apply.
    private static func rowsPrioritizingChanges(
        _ rows: [SideBySideRow], maxRows: Int
    ) -> [SideBySideRow] {
        let limit = max(0, maxRows)
        guard rows.count > limit else { return rows }
        guard limit > 0 else { return [] }

        let changedIndices = rows.indices.filter { rows[$0].kind != .unchanged }
        guard !changedIndices.isEmpty else { return Array(rows.prefix(limit)) }

        var selected = Set(changedIndices.prefix(limit))
        if changedIndices.count <= limit {
            var distance = 1
            while selected.count < limit && distance < rows.count {
                for changedIndex in changedIndices {
                    for candidate in [changedIndex - distance, changedIndex + distance]
                    where rows.indices.contains(candidate) {
                        selected.insert(candidate)
                        if selected.count == limit { break }
                    }
                    if selected.count == limit { break }
                }
                distance += 1
            }
        }

        return selected.sorted().map { rows[$0] }
    }

    /// Schneidet einen abschließenden Zeilen-Terminator (\n, \r, \r\n) vom
    /// Zeilenbereich ab — wir wollen den reinen Zeilen-Inhalt anzeigen.
    private static func trimmingTerminator(_ range: NSRange, in ns: NSString) -> NSRange {
        var len = range.length
        while len > 0 {
            let c = ns.character(at: range.location + len - 1)
            if c == 0x0A || c == 0x0D { len -= 1 } else { break }
        }
        return NSRange(location: range.location, length: len)
    }

    /// Setzt die Nachher-Zeile zusammen: Text zwischen den Treffern bleibt
    /// original, an den Treffer-Stellen steht der `replacedText`. Treffer, die
    /// über das Zeilenende hinausragen (mehrzeilige RegEx-Treffer), werden auf
    /// das Zeilenende geklammert.
    private static func stitchedAfterLine(ns: NSString, content: NSRange,
                                          matches: [BufferSearch.Match]) -> String {
        let end = content.location + content.length
        var cursor = content.location
        var out = ""
        for m in matches {
            let mStart = max(m.range.location, cursor)
            let mEnd = min(m.range.location + m.range.length, end)
            guard mStart <= end else { continue }
            if mStart > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: mStart - cursor))
            }
            out += m.replacedText
            cursor = max(cursor, mEnd)
        }
        if cursor < end {
            out += ns.substring(with: NSRange(location: cursor, length: end - cursor))
        }
        return out
    }
}
