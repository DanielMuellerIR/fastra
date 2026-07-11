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

    // MARK: - Intern

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
