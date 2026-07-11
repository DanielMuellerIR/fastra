// LineOperations.swift
//
// Zeilen-Werkzeuge fürs Editor-Kontextmenü (v0.8):
//   - „Zeilen sortieren": sortiert die selektierten Zeilen alphabetisch —
//     sind sie BEREITS alphabetisch sortiert, wird umgekehrt sortiert
//     (Toggle-Verhalten, Daniel-Spezifikation).
//   - „Duplikate entfernen": entfernt doppelte Zeilen (exakter Vergleich),
//     das jeweils ERSTE Vorkommen bleibt stehen.
//
// Beide Operationen arbeiten auf GANZEN Zeilen: Die Selektion wird auf
// Zeilengrenzen ausgeweitet (BBEdit-Verhalten — wer eine halbe Zeile
// markiert, meint die ganze). Ohne Selektion (Länge 0) gilt die GANZE
// Datei — das deckt den häufigsten Fall „Liste in Datei sortieren" ohne
// vorheriges ⌘A ab.
//
// Pure Logik, UI-frei, voll getestet (LineOperationsTests). Alle Ranges
// in UTF-16 (NSRange) — kompatibel mit Editor-Selektion und BufferSearch.

import Foundation

enum LineOperations {
    /// Ergebnis einer Zeilen-Operation.
    struct Result: Equatable {
        /// Der komplette neue Text (Datei-Inhalt nach der Operation).
        let newText: String
        /// Der Bereich (im ALTEN Text), der ersetzt wurde — ganze Zeilen.
        let affectedRange: NSRange
        /// Anzahl betroffener Zeilen (sortiert bzw. nach Dedupe übrig).
        let lineCount: Int
    }

    /// Weitet eine Selektion auf ganze Zeilen aus. Leere Selektion
    /// (Länge 0) → der gesamte Text. Das Zeilenende (`\n`) der letzten
    /// betroffenen Zeile gehört NICHT mit zum Bereich — so bleibt ein
    /// fehlendes Newline am Dateiende erhalten.
    static func expandToFullLines(in text: String, selection: NSRange) -> NSRange {
        let ns = text as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        guard selection.length > 0 else { return NSRange(location: 0, length: ns.length) }

        // NSString.lineRange liefert die Zeilen inkl. abschließendem \n.
        let safeSelection = NSIntersectionRange(selection,
                                                NSRange(location: 0, length: ns.length))
        var expanded = ns.lineRange(for: safeSelection)
        // Abschließendes Zeilenende der letzten Zeile abschneiden — wir
        // sortieren ZEILENINHALTE und bauen die Trenner selbst wieder ein.
        if expanded.length > 0 {
            let lastChar = ns.character(at: expanded.location + expanded.length - 1)
            if lastChar == 0x0A {                     // \n
                expanded.length -= 1
                // CRLF: das \r vor dem \n gehört auch zum Trenner.
                if expanded.length > 0,
                   ns.character(at: expanded.location + expanded.length - 1) == 0x0D {
                    expanded.length -= 1
                }
            }
        }
        return expanded
    }

    /// Sortiert die (auf ganze Zeilen ausgeweiteten) selektierten Zeilen.
    /// Bereits aufsteigend sortiert → absteigend (Toggle). Vergleich via
    /// `localizedStandardCompare` (wie der Finder: „a2" < „a10",
    /// Umlaute korrekt eingeordnet).
    /// `nil`, wenn weniger als 2 Zeilen betroffen sind (nichts zu tun).
    static func sortLines(in text: String, selection: NSRange) -> Result? {
        let range = expandToFullLines(in: text, selection: selection)
        let ns = text as NSString
        let block = ns.substring(with: range)
        let lines = splitLines(block)
        guard lines.count >= 2 else { return nil }

        let ascending = lines.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        // Toggle: Ist der Block schon aufsteigend sortiert, drehen wir um.
        let alreadySorted = (lines == ascending)
        let sorted = alreadySorted ? ascending.reversed().map { $0 } : ascending

        let newBlock = sorted.joined(separator: separator(of: text))
        let newText = ns.replacingCharacters(in: range, with: newBlock)
        return Result(newText: newText, affectedRange: range, lineCount: lines.count)
    }

    /// Entfernt doppelte Zeilen im (ausgeweiteten) Selektions-Bereich.
    /// Exakter String-Vergleich; das erste Vorkommen bleibt, die
    /// Reihenfolge der verbleibenden Zeilen ändert sich nicht.
    /// `nil`, wenn keine Duplikate vorhanden sind (nichts zu tun).
    static func removeDuplicateLines(in text: String, selection: NSRange) -> Result? {
        let range = expandToFullLines(in: text, selection: selection)
        let ns = text as NSString
        let block = ns.substring(with: range)
        let lines = splitLines(block)
        guard lines.count >= 2 else { return nil }

        var seen = Set<String>()
        var unique: [String] = []
        for line in lines {
            // `insert` liefert `inserted == false` für bereits Gesehenes —
            // ein Durchlauf, Reihenfolge bleibt stabil.
            if seen.insert(line).inserted {
                unique.append(line)
            }
        }
        guard unique.count < lines.count else { return nil }

        let newBlock = unique.joined(separator: separator(of: text))
        let newText = ns.replacingCharacters(in: range, with: newBlock)
        return Result(newText: newText, affectedRange: range, lineCount: unique.count)
    }

    /// „Nur doppelte Zeilen behalten" (BBEdit „Process Duplicate Lines" / Find duplicates):
    /// behält NUR die Zeilen, die im (auf ganze Zeilen ausgeweiteten) Bereich mindestens ZWEIMAL
    /// vorkommen — je EINMAL, in Reihenfolge ihres ersten Auftretens. Nützlich, um Dubletten in
    /// Logs/Listen sichtbar zu machen.
    ///
    /// Sorgfältiger als das ältere `removeDuplicateLines`: Eine leere Phantom-Schlusszeile
    /// (sie entsteht im Ganz-Text-Fall durch das Datei-End-Newline, das `expandToFullLines`
    /// behält) wird HIER bewusst NICHT als echte Zeile mitgezählt — sonst verfälschte sie die
    /// Häufigkeit echter Leerzeilen. Sie wird vor der Analyse abgetrennt und danach wieder
    /// angehängt, damit das Datei-End-Newline erhalten bleibt.
    /// `nil`, wenn weniger als 2 Zeilen betroffen sind, keine Dubletten existieren oder das
    /// Ergebnis leer wäre (ein Menü-Klick darf das Dokument nicht leerräumen — Produkt-DNA).
    static func keepDuplicateLines(in text: String, selection: NSRange) -> Result? {
        let range = expandToFullLines(in: text, selection: selection)
        let ns = text as NSString
        let block = ns.substring(with: range)
        let lines = splitLines(block)

        // Phantom-Schlusszeile (Datei-End-Newline) abtrennen — sie ist kein echter Inhalt.
        let hasTrailingEmpty = lines.count >= 2 && lines.last == ""
        let real = hasTrailingEmpty ? Array(lines.dropLast()) : lines
        guard real.count >= 2 else { return nil }

        // Häufigkeit jeder echten Zeile zählen.
        var counts: [String: Int] = [:]
        for line in real { counts[line, default: 0] += 1 }

        // Jede mindestens zweimal vorkommende Zeile EINMAL ausgeben, in Reihenfolge des
        // ersten Auftretens. Das Set verhindert, dass eine Dublette mehrfach emittiert wird.
        var emitted = Set<String>()
        var keptReal: [String] = []
        for line in real where (counts[line] ?? 0) >= 2 {
            if emitted.insert(line).inserted {
                keptReal.append(line)
            }
        }
        // Kein Dublett gefunden → nichts zu tun (statt das Dokument zu leeren).
        guard !keptReal.isEmpty else { return nil }

        // Phantom-Leerzeile wieder anhängen, damit das Datei-End-Newline erhalten bleibt.
        let out = hasTrailingEmpty ? keptReal + [""] : keptReal
        let newBlock = out.joined(separator: separator(of: text))
        guard newBlock != block else { return nil }
        let newText = ns.replacingCharacters(in: range, with: newBlock)
        return Result(newText: newText, affectedRange: range, lineCount: keptReal.count)
    }

    /// „Mehrfach vorkommende Zeilen entfernen" (BBEdit „Process Duplicate Lines"):
    /// entfernt JEDE Zeile, die mehr als einmal vorkommt (inklusive ihres ersten Vorkommens) —
    /// übrig bleiben nur die EINMALIGEN Zeilen, in Originalreihenfolge.
    ///
    /// Phantom-Behandlung wie bei `keepDuplicateLines`: die leere Datei-End-Schlusszeile zählt
    /// nicht als Inhalt und wird hinterher wieder angehängt. `nil`, wenn weniger als 2 Zeilen
    /// betroffen sind, das Ergebnis identisch wäre (alle Zeilen einmalig → No-Op) oder das
    /// Ergebnis leer wäre (alle Zeilen sind Dubletten — Dokument nicht leerräumen, Produkt-DNA).
    static func removeAllDuplicatedLines(in text: String, selection: NSRange) -> Result? {
        let range = expandToFullLines(in: text, selection: selection)
        let ns = text as NSString
        let block = ns.substring(with: range)
        let lines = splitLines(block)

        // Phantom-Schlusszeile (Datei-End-Newline) abtrennen — sie ist kein echter Inhalt.
        let hasTrailingEmpty = lines.count >= 2 && lines.last == ""
        let real = hasTrailingEmpty ? Array(lines.dropLast()) : lines
        guard real.count >= 2 else { return nil }

        // Häufigkeit jeder echten Zeile zählen.
        var counts: [String: Int] = [:]
        for line in real { counts[line, default: 0] += 1 }

        // Nur die EINMALIGEN Zeilen (count == 1) behalten, in Originalreihenfolge.
        let keptReal = real.filter { (counts[$0] ?? 0) == 1 }
        // Alle Zeilen waren Dubletten → nichts behalten (statt das Dokument zu leeren).
        guard !keptReal.isEmpty else { return nil }

        // Phantom-Leerzeile wieder anhängen, damit das Datei-End-Newline erhalten bleibt.
        let out = hasTrailingEmpty ? keptReal + [""] : keptReal
        let newBlock = out.joined(separator: separator(of: text))
        // Block unverändert (alle Zeilen waren einmalig) → No-Op.
        guard newBlock != block else { return nil }
        let newText = ns.replacingCharacters(in: range, with: newBlock)
        return Result(newText: newText, affectedRange: range, lineCount: keptReal.count)
    }

    // MARK: - Helfer

    /// Zerlegt einen Block in Zeilen-INHALTE (ohne Trenner). Versteht
    /// LF und CRLF gemischt — der Editor normalisiert zwar auf LF, aber
    /// die Logik soll auch mit roh geladenem CRLF-Inhalt nicht brechen.
    /// `internal`, damit `TextOperations` exakt dieselbe Zerlegung nutzt
    /// (eine Wahrheit für „was ist eine Zeile").
    static func splitLines(_ block: String) -> [String] {
        // components(separatedBy: "\n") + \r-Trim deckt LF und CRLF ab.
        block.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
    }

    /// Zeilentrenner des Textes: CRLF, wenn der Text CRLF verwendet,
    /// sonst LF. (Die Tab-Inhalte sind in Fastra LF-normalisiert; die
    /// Erkennung macht die Funktionen trotzdem robust.)
    /// `internal` — von `TextOperations` mitgenutzt (siehe `splitLines`).
    static func separator(of text: String) -> String {
        text.contains("\r\n") ? "\r\n" : "\n"
    }
}
