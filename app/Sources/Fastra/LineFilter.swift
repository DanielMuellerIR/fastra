// LineFilter.swift
//
// „Process Lines Containing" (BBEdit, Kap. 5): ein RegEx-basierter
// Zeilen-Filter. Behält oder löscht GANZE Zeilen, je nachdem ob ein
// RegEx-Muster in der Zeile einen Treffer hat. Zwei Spielarten, gesteuert
// über `keepMatching`:
//
//   • keepMatching == true  → nur Zeilen MIT Treffer bleiben übrig
//     (BBEdits „Process Lines Containing → Copy to new document" /
//      „Delete others" — hier: das gefilterte Resultat ersetzt den Block).
//   • keepMatching == false → Zeilen MIT Treffer werden GELÖSCHT, nur die
//     treffer-freien Zeilen bleiben stehen.
//
// `pattern` ist bewusst ein REGEX (kein Klartext): Fastra IST ein
// RegEx-Werkzeug, ein Plain-Text-Filter wäre hier die schwächere Variante.
// Standardmäßig case-insensitiv — wie der Such-Default des Editors; über
// `caseInsensitive: false` lässt sich exakt nach Groß-/Kleinschreibung filtern.
//
// Vertrag wie `LineOperations`/`TextOperations`: liefert ein
// `LineOperations.Result` (kompletter neuer Text + ersetzter Bereich im ALTEN
// Text) oder `nil`, wenn nichts zu tun ist (Aufrufer gibt dann einen Beep).
// Zeilen-Scope: die Selektion wird auf ganze Zeilen ausgeweitet
// (`LineOperations.expandToFullLines`); ohne Selektion gilt die ganze Datei —
// identisches Verhalten zu sort/dedup und den TextOperations-Zeilen-Ops.
//
// Alle Ranges in UTF-16 (NSRange). Pure Logik, UI-frei, voll getestet
// (LineFilterTests).

import Foundation

enum LineFilter {
    /// Behält oder löscht ganze Zeilen nach einem RegEx-Muster (BBEdit
    /// „Process Lines Containing").
    /// - `keepMatching == true`  → nur Zeilen MIT Treffer bleiben übrig.
    /// - `keepMatching == false` → Zeilen MIT Treffer werden gelöscht (nur
    ///   treffer-freie bleiben).
    /// `pattern` ist ein REGEX (Fastra ist ein RegEx-Werkzeug). `caseInsensitive`
    /// per Default `true` (wie der Such-Default des Editors).
    ///
    /// Liefert `nil` bei:
    ///   • leerem oder ungültigem Muster,
    ///   • weniger als einer Inhaltszeile,
    ///   • wenn sich nichts ändert,
    ///   • ODER wenn das Ergebnis den GANZEN Inhalt löschen würde (leeres
    ///     Resultat). Ein voller Dokument-Wipe per Menüklick wäre überraschend
    ///     und destruktiv (Produkt-DNA „keine unsichtbaren destruktiven
    ///     Aktionen") — dann lieber `nil` → Beep.
    static func filter(in text: String, selection: NSRange, pattern: String,
                       keepMatching: Bool, caseInsensitive: Bool = true) -> LineOperations.Result? {
        // Leeres Muster ist keine sinnvolle Filter-Bedingung → nichts tun.
        guard !pattern.isEmpty else { return nil }

        // Muster kompilieren; ein ungültiges RegEx wirft → wir geben nil zurück
        // (statt zu crashen), der Aufrufer beept. Case-Insensitivity über die
        // Compile-Option, nicht über ein verändertes Muster.
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }

        // Wirkbereich: Selektion auf ganze Zeilen ausgeweitet, ohne Selektion
        // der ganze Text. `range` ist im ALTEN Text und wird am Ende ersetzt.
        let range = LineOperations.expandToFullLines(in: text, selection: selection)
        let ns = text as NSString
        let block = ns.substring(with: range)
        let lines = LineOperations.splitLines(block)

        // Phantom-Leerzeile am Ende: Im Ganz-Text-Fall behält
        // `expandToFullLines` das abschließende `\n`, sodass `splitLines` ein
        // leeres Schluss-Element liefert — das ist KEIN echter Inhalt, sondern
        // nur das Datei-End-Newline. Wie in `addLineNumbers` behandeln: für die
        // Filter-Analyse weglassen und am Ende wieder anhängen, damit das
        // Datei-End-Newline erhalten bleibt.
        let hasTrailingEmpty = lines.count >= 2 && lines.last == ""
        let realLines = hasTrailingEmpty ? Array(lines.dropLast()) : lines

        // Weniger als eine echte Inhaltszeile → nichts zu filtern.
        guard realLines.count >= 1 else { return nil }

        // Prüft, ob eine Zeile irgendwo einen Treffer hat. `firstMatch` reicht —
        // mehrere Treffer in derselben Zeile zählen trotzdem als „eine
        // treffende Zeile" (wir filtern auf Zeilen-, nicht auf Treffer-Ebene).
        func matches(_ line: String) -> Bool {
            let lineRange = NSRange(location: 0, length: (line as NSString).length)
            return regex.firstMatch(in: line, range: lineRange) != nil
        }

        // Behalte genau die Zeilen, deren Treffer-Status zu `keepMatching` passt:
        //   keepMatching == true  → behalte Zeilen MIT Treffer  (matches == true)
        //   keepMatching == false → behalte Zeilen OHNE Treffer (matches == false)
        let kept = realLines.filter { matches($0) == keepMatching }

        // Voller Dokument-Wipe vermeiden: würde der Filter ALLE Inhaltszeilen
        // entfernen, lieber nil → Beep (siehe Vertrag oben). So löscht ein
        // versehentlicher Menüklick nie unbemerkt den gesamten Inhalt.
        if kept.isEmpty { return nil }

        // Resultat-Block bauen: die behaltenen Zeilen, plus — falls vorhanden —
        // die Phantom-Leerzeile wieder ans Ende, damit das Datei-End-Newline
        // bestehen bleibt.
        let out = hasTrailingEmpty ? kept + [""] : kept
        let newBlock = out.joined(separator: LineOperations.separator(of: text))

        // Ändert sich nichts (z.B. im Behalten-Modus matchen ohnehin alle
        // Zeilen), gibt es nichts zu tun → nil.
        guard newBlock != block else { return nil }

        let newText = ns.replacingCharacters(in: range, with: newBlock)
        // lineCount = Anzahl der ECHTEN Inhaltszeilen, die übrig bleiben (ohne
        // die Phantom-Leerzeile).
        return LineOperations.Result(newText: newText, affectedRange: range, lineCount: kept.count)
    }
}
