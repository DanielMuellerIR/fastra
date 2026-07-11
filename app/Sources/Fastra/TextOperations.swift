// TextOperations.swift
//
// BBEdit-„Text"-Menü-Basics als pure, UI-freie Transformationen (v0.10).
// Ergänzt `LineOperations` (sort/dedup) um die klassischen Editier-Grundlagen:
//
//   • Groß-/Kleinschreibung: GROSS / klein / Wörter Groß (Title Case)
//   • Whitespace: Leerzeichen am Zeilenende entfernen, Tabs↔Leerzeichen
//     (Entab/Detab, tab-stopp-bewusst)
//   • Ein-/Ausrücken (Shift Right/Left) um eine Tab-Weite
//   • Zeilen-Ops: umkehren, Präfix/Suffix anhängen, Leerzeilen entfernen
//
// Vertrag wie `LineOperations`: jede Funktion liefert ein
// `LineOperations.Result` (kompletter neuer Text + ersetzter Bereich im ALTEN
// Text) oder `nil`, wenn nichts zu tun ist (Aufrufer gibt dann einen Beep).
// Dadurch laufen alle über denselben `applyLineOperation`-Pfad im
// EditorContextMenu (Undo-fähig via `TextView.replaceCharacters`).
//
// Zwei Geltungsbereiche:
//   • ZEICHEN-Scope (Groß/Klein): wirkt exakt auf die Selektion; ohne
//     Selektion auf den ganzen Text. Länge bleibt i.d.R. gleich.
//   • ZEILEN-Scope (alle übrigen): Selektion wird auf ganze Zeilen ausgeweitet
//     (`LineOperations.expandToFullLines`); ohne Selektion die ganze Datei —
//     identisches Verhalten zu sort/dedup.
//
// Alle Ranges in UTF-16 (NSRange). Voll getestet (TextOperationsTests).

import Foundation

enum TextOperations {

    /// Tab-Weite für Entab/Detab/Shift. Entspricht der Editor-Konfiguration
    /// (`SourceEditorConfiguration.appearance.tabWidth = 4`).
    static let tabWidth = 4

    // MARK: - Groß-/Kleinschreibung (Zeichen-Scope)

    static func uppercase(in text: String, selection: NSRange) -> LineOperations.Result? {
        transformSelection(in: text, selection: selection) { $0.localizedUppercase }
    }

    static func lowercase(in text: String, selection: NSRange) -> LineOperations.Result? {
        transformSelection(in: text, selection: selection) { $0.localizedLowercase }
    }

    /// „Wörter Groß" — jeder Wortanfang groß, Rest klein (BBEdit „Title Case").
    static func titlecase(in text: String, selection: NSRange) -> LineOperations.Result? {
        transformSelection(in: text, selection: selection) { $0.localizedCapitalized }
    }

    // MARK: - Whitespace (Zeilen-Scope)

    /// Entfernt Leerzeichen und Tabs am ENDE jeder Zeile.
    static func trimTrailingWhitespace(in text: String, selection: NSRange) -> LineOperations.Result? {
        transformLines(in: text, selection: selection) { lines in
            lines.map { line in
                var end = line.endIndex
                while end > line.startIndex {
                    let prev = line.index(before: end)
                    let c = line[prev]
                    if c == " " || c == "\t" { end = prev } else { break }
                }
                return String(line[line.startIndex..<end])
            }
        }
    }

    /// Tabs → Leerzeichen, tab-stopp-bewusst (ein Tab füllt bis zur nächsten
    /// Spalte, die ein Vielfaches von `tabWidth` ist).
    static func detab(in text: String, selection: NSRange) -> LineOperations.Result? {
        transformLines(in: text, selection: selection) { lines in
            lines.map { line in
                var out = ""
                var col = 0
                for ch in line {
                    if ch == "\t" {
                        let spaces = tabWidth - (col % tabWidth)
                        out += String(repeating: " ", count: spaces)
                        col += spaces
                    } else {
                        out.append(ch)
                        col += 1
                    }
                }
                return out
            }
        }
    }

    /// Leerzeichen → Tabs, tab-stopp-bewusst: ein Lauf von Leerzeichen wird
    /// durch Tabs ersetzt, soweit ein Tab innerhalb des Laufs eine volle
    /// Tab-Stopp-Grenze erreicht; ein Rest bleibt als Leerzeichen.
    static func entab(in text: String, selection: NSRange) -> LineOperations.Result? {
        transformLines(in: text, selection: selection) { lines in
            lines.map { entabLine($0) }
        }
    }

    private static func entabLine(_ line: String) -> String {
        var out = ""
        var col = 0          // aktuelle Spalte in der AUSGABE
        var pending = 0      // gesammelte Leerzeichen
        var pendingStart = 0 // Spalte, an der der Leerzeichen-Lauf begann

        func flushPending() {
            guard pending > 0 else { return }
            var c = pendingStart
            let end = pendingStart + pending
            // Tabs setzen, solange ein Tab (Sprung zur nächsten Stopp-Grenze)
            // noch innerhalb des Laufs landet.
            while true {
                let nextStop = c - (c % tabWidth) + tabWidth
                if nextStop <= end { out += "\t"; c = nextStop } else { break }
            }
            if c < end { out += String(repeating: " ", count: end - c) }
            pending = 0
        }

        for ch in line {
            if ch == " " {
                if pending == 0 { pendingStart = col }
                pending += 1
                col += 1
            } else if ch == "\t" {
                flushPending()
                out += "\t"
                col = col - (col % tabWidth) + tabWidth
            } else {
                flushPending()
                out.append(ch)
                col += 1
            }
        }
        flushPending()
        return out
    }

    // MARK: - Ein-/Ausrücken (Zeilen-Scope)

    /// Rückt jede Zeile um eine Tab-Weite EIN (ein führender Tab).
    static func shiftRight(in text: String, selection: NSRange) -> LineOperations.Result? {
        transformLines(in: text, selection: selection) { lines in
            lines.map { "\t" + $0 }
        }
    }

    /// Rückt jede Zeile um eine Tab-Weite AUS: ein führender Tab wird entfernt,
    /// sonst bis zu `tabWidth` führende Leerzeichen.
    static func shiftLeft(in text: String, selection: NSRange) -> LineOperations.Result? {
        transformLines(in: text, selection: selection) { lines in
            lines.map { line in
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                var n = 0
                for ch in line {
                    if ch == " " && n < tabWidth { n += 1 } else { break }
                }
                return String(line.dropFirst(n))
            }
        }
    }

    // MARK: - Zeilen-Ops (Zeilen-Scope)

    /// Kehrt die Reihenfolge der (ausgeweiteten) Zeilen um.
    static func reverseLines(in text: String, selection: NSRange) -> LineOperations.Result? {
        transformLines(in: text, selection: selection, minLines: 2) { $0.reversed() }
    }

    /// Entfernt leere und nur-aus-Whitespace-bestehende Zeilen.
    static func removeBlankLines(in text: String, selection: NSRange) -> LineOperations.Result? {
        transformLines(in: text, selection: selection) { lines in
            lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    /// Hängt `prefix` an jeden Zeilen-ANFANG. Leerer Präfix → nil.
    static func prefixLines(in text: String, selection: NSRange, with prefix: String) -> LineOperations.Result? {
        guard !prefix.isEmpty else { return nil }
        return transformLines(in: text, selection: selection, requireChange: false) { lines in
            lines.map { prefix + $0 }
        }
    }

    /// Hängt `suffix` an jedes Zeilen-ENDE. Leerer Suffix → nil.
    static func suffixLines(in text: String, selection: NSRange, with suffix: String) -> LineOperations.Result? {
        guard !suffix.isEmpty else { return nil }
        return transformLines(in: text, selection: selection, requireChange: false) { lines in
            lines.map { $0 + suffix }
        }
    }

    // MARK: - Texthygiene (Zeichen-Scope)

    /// „Zap Gremlins" (BBEdit, Kap. 5 „Text Transformations"): entfernt
    /// unsichtbare Steuerzeichen aus dem Text — den gesamten C0-Bereich
    /// (U+0000–U+001F, inkl. NUL) sowie U+007F (DEL). Tab (U+0009),
    /// Zeilenumbruch (U+000A) und Wagenrücklauf (U+000D) bleiben ERHALTEN —
    /// sonst zerstörte die Operation die Zeilen-/Spaltenstruktur. Arbeitet pro
    /// Unicode-Scalar (Surrogatpaare/Emoji bleiben unversehrt). Zeichen-Scope:
    /// Selektion oder — ohne Selektion — der ganze Text. Typischer Fall: aus
    /// Logs/4D-Exporten geschmuggelte Steuerbytes loswerden.
    static func zapGremlins(in text: String, selection: NSRange) -> LineOperations.Result? {
        transformSelection(in: text, selection: selection) { s in
            var kept = String.UnicodeScalarView()
            for scalar in s.unicodeScalars {
                let v = scalar.value
                let isControl = v <= 0x1F || v == 0x7F
                // Tab/LF/CR sind strukturell und bleiben — der Rest fliegt raus.
                let isStructural = (v == 0x09 || v == 0x0A || v == 0x0D)
                if isControl && !isStructural { continue }
                kept.append(scalar)
            }
            return String(kept)
        }
    }

    /// „Straighten Quotes" (BBEdit, Kap. 5): wandelt typografische
    /// („geschwungene") Anführungszeichen in gerade um — doppelte (“ ” „ ‟) → ",
    /// einfache (‘ ’ ‚ ‛) → '. Häufiger Daten-Killer: aus Word/Web kopierte
    /// Quotes brechen CSV/JSON/SQL. Zeichen-Scope, längenstabil (1:1-Ersetzung).
    static func straightenQuotes(in text: String, selection: NSRange) -> LineOperations.Result? {
        transformSelection(in: text, selection: selection) { s in
            var out = s
            for q in ["\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}"] {   // “ ” „ ‟
                out = out.replacingOccurrences(of: q, with: "\"")
            }
            for q in ["\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}"] {   // ‘ ’ ‚ ‛
                out = out.replacingOccurrences(of: q, with: "'")
            }
            return out
        }
    }

    /// „Educate Quotes" (BBEdit, Kap. 5): die kontextsensitive UMKEHRUNG von
    /// `straightenQuotes`. Wandelt gerade Quotes in typografische („geschwungene")
    /// um — und entscheidet dabei je Vorkommen, ob es ein ÖFFNENDES oder
    /// SCHLIESSENDES Zeichen ist:
    ///   "  →  U+201C “ (öffnend)  /  U+201D ” (schließend)
    ///   '  →  U+2018 ‘ (öffnend)  /  U+2019 ’ (schließend)
    ///
    /// Die Entscheidung fällt allein über das ZEICHEN DAVOR (im Originaltext):
    /// Steht davor Textanfang, ein Whitespace (inkl. Zeilenumbruch) oder eine
    /// öffnende Klammer ( [ {, ist es öffnend — sonst schließend. Genau dadurch
    /// wird ein Apostroph mitten im Wort korrekt: bei „don't"/„it's" steht vor
    /// dem ' ein Buchstabe (kein Whitespace, keine offene Klammer) → es wird zum
    /// schließenden U+2019 ’, dem typografisch richtigen Apostroph.
    ///
    /// Weil für das erste Zeichen der Selektion das Zeichen DAVOR (also AUSSERHALB
    /// der Selektion) gebraucht wird, ist dies — wie `joinLines` — eine
    /// eigenständige Funktion über den ganzen NSString. GEÄNDERT werden aber NUR
    /// Scalars INNERHALB der Selektion (ohne Selektion der ganze Text). Arbeitet
    /// pro Unicode-Scalar (Emoji/Surrogatpaare bleiben unversehrt), längenstabil
    /// (1:1-Ersetzung). `nil`, wenn in der Selektion gar keine geraden Quotes
    /// stehen (No-Op → Aufrufer gibt einen Beep).
    ///
    /// SCOPE: nur englischer Stil (“ ” ‘ ’), exakt wie BBEdit. Deutsche
    /// Anführungszeichen („…" / ‚…') sind bewusst NICHT abgedeckt — die deutsche
    /// Konvention (öffnend unten, schließend oben) ist eine andere Operation.
    static func educateQuotes(in text: String, selection: NSRange) -> LineOperations.Result? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let full = NSRange(location: 0, length: ns.length)
        // Wirkbereich: Selektion (geschnitten auf den gültigen Bereich) oder,
        // ohne Selektion, der ganze Text.
        let range = selection.length > 0 ? NSIntersectionRange(selection, full) : full
        guard range.length > 0 else { return nil }

        // Den GANZEN Text als Scalar-Array, plus die Wirk-Grenzen in
        // Scalar-Indizes — so können wir links über die Selektion „hinauslugen",
        // ändern aber nur, was innerhalb liegt. (NSRange ist UTF-16; der
        // Wirkbereich liegt hier stets auf Scalar-Grenzen, weil unsere Selektion
        // aus der GUI von Zeichen-/Cursor-Positionen stammt.)
        let scalars = Array(text.unicodeScalars)
        // UTF-16-Offset → Scalar-Index abbilden (ein Surrogatpaar = 2 Einheiten).
        var utf16ToScalar: [Int] = []
        utf16ToScalar.reserveCapacity(ns.length + 1)
        for (i, s) in scalars.enumerated() {
            let width = s.value > 0xFFFF ? 2 : 1
            for _ in 0..<width { utf16ToScalar.append(i) }
        }
        utf16ToScalar.append(scalars.count)        // Endmarke
        let startScalar = utf16ToScalar[range.location]
        let endScalar = utf16ToScalar[range.location + range.length]

        // Eine geschlossene Menge von „öffner"-Vorzeichen: Whitespace,
        // Zeilenumbrüche und öffnende Klammern. Steht NICHTS davor (Textanfang),
        // gilt ebenfalls „öffnend".
        let openingBrackets: Set<Unicode.Scalar> = ["(", "[", "{"]
        func precedesOpening(_ idx: Int) -> Bool {
            guard idx > 0 else { return true }     // Textanfang → öffnend
            let prev = scalars[idx - 1]
            if prev.properties.isWhitespace { return true }
            if openingBrackets.contains(prev) { return true }
            return false
        }

        var changed = false
        var out = scalars
        var i = startScalar
        while i < endScalar {
            let s = scalars[i]
            if s == "\"" {
                out[i] = precedesOpening(i) ? "\u{201C}" : "\u{201D}"   // “ / ”
                changed = true
            } else if s == "'" {
                out[i] = precedesOpening(i) ? "\u{2018}" : "\u{2019}"   // ‘ / ’
                changed = true
            }
            i += 1
        }
        guard changed else { return nil }

        // Neuen Gesamttext aus den (teilweise ersetzten) Scalars bauen.
        var view = String.UnicodeScalarView()
        view.append(contentsOf: out)
        let newText = String(view)
        return LineOperations.Result(newText: newText, affectedRange: range, lineCount: 0)
    }

    // MARK: - Escape-Sequenzen auflösen (Zeichen-Scope)

    /// Kuratierte Liste benannter HTML-Entities (`&name;` → Zeichen).
    /// BEWUSST NICHT die vollständige HTML5-Tabelle (über 2000 Einträge),
    /// sondern die im Daten-/Log-Alltag häufigen plus die deutschen Umlaute
    /// und „ß". Numerische Entities (`&#NN;` / `&#xNN;`) decken den Rest
    /// vollständig ab — wer ein exotisches benanntes Entity braucht, kann es
    /// als numerisches schreiben. Für die Zielgruppe (Daten/Logs) ausreichend.
    private static let namedEntities: [String: Unicode.Scalar] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "copy": "\u{00A9}", "reg": "\u{00AE}",
        "trade": "\u{2122}", "mdash": "\u{2014}", "ndash": "\u{2013}",
        "hellip": "\u{2026}", "euro": "\u{20AC}", "pound": "\u{00A3}",
        "deg": "\u{00B0}", "times": "\u{00D7}", "divide": "\u{00F7}",
        // Deutsche Umlaute und „ß".
        "auml": "\u{00E4}", "ouml": "\u{00F6}", "uuml": "\u{00FC}",
        "Auml": "\u{00C4}", "Ouml": "\u{00D6}", "Uuml": "\u{00DC}",
        "szlig": "\u{00DF}",
    ]

    /// „Convert Escape Sequences" (BBEdit, Kap. 5): ersetzt gebräuchliche
    /// Escape-Schreibweisen durch ihre echten Zeichen — in EINEM Links-nach-
    /// rechts-Durchlauf. Abgedeckt:
    ///   1. Steuerzeichen (wie BBEdits Suche): `\n \r \t \f \\`.
    ///   2. Hex: `\xNN` (genau 2 Hex-Ziffern) und `\x{NNNN}` (1+ Hex-Ziffern).
    ///   3. Unicode (JavaScript-Stil): `\uNNNN` (genau 4) und `\u{NNNN}` (1+).
    ///   4. HTML-Entities: numerisch VOLLSTÄNDIG (`&#NN;` dezimal, `&#xNN;`
    ///      hex) sowie eine KURATIERTE Menge benannter (`&amp;` etc., siehe
    ///      `namedEntities`).
    ///   5. Prozent-Escapes: `%NN` als UTF-8-Bytefolge — aufeinanderfolgende
    ///      `%NN` werden als Byte-Lauf gesammelt und gemeinsam als UTF-8
    ///      dekodiert (so wird Mehrbyte-UTF-8 wie `%C3%A4` → „ä" korrekt).
    ///
    /// Malformte oder unbekannte Sequenzen bleiben LITERAL stehen (`\z`,
    /// `\xZZ`, `&bogus;`, `%ZZ` etc.) — wir verschlucken nie etwas, das wir
    /// nicht sicher deuten können. Ein Skalarwert, der kein gültiger
    /// Unicode-Scalar ist (z.B. Surrogat-Bereich), bleibt ebenfalls literal.
    ///
    /// Zeichen-Scope: wirkt auf die Selektion, ohne Selektion auf den ganzen
    /// Text. Bewusst ein HANDGESCHRIEBENER Scanner über die Unicode-Scalars
    /// statt NSRegularExpression — die fünf Klassen überlappen sich (`\u`/`\x`,
    /// `&#x`/`&#`) und wären als ein Regex schwer korrekt und lesbar zu halten.
    static func convertEscapeSequences(in text: String, selection: NSRange) -> LineOperations.Result? {
        transformSelection(in: text, selection: selection) { decodeEscapes($0) }
    }

    /// Kern-Scanner: nimmt einen String, läuft Scalar für Scalar durch und
    /// gibt den aufgelösten String zurück. Trennt die reine Decode-Logik vom
    /// Scope-/Result-Drumherum (`transformSelection`).
    private static func decodeEscapes(_ input: String) -> String {
        // In ein Array kopieren, damit wir per Index frei vor-/zurückschauen
        // und variabel lange Sequenzen am Stück konsumieren können.
        let scalars = Array(input.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0

        while i < scalars.count {
            let s = scalars[i]

            if s == "\\" {
                // Backslash-Escape (Fälle 1–3). Wir reichen den Rest-Index
                // weiter; der Helfer konsumiert die ganze Sequenz oder gibt
                // nil zurück (→ Backslash bleibt literal).
                if let (scalarsOut, consumed) = decodeBackslash(scalars, at: i) {
                    out.append(contentsOf: scalarsOut)
                    i += consumed
                    continue
                }
            } else if s == "&" {
                // HTML-Entity (Fall 4).
                if let (scalar, consumed) = decodeEntity(scalars, at: i) {
                    out.append(scalar)
                    i += consumed
                    continue
                }
            } else if s == "%" {
                // Prozent-Escape (Fall 5): ganzen `%NN`-Lauf als UTF-8 deuten.
                if let (scalarsOut, consumed) = decodePercentRun(scalars, at: i) {
                    out.append(contentsOf: scalarsOut)
                    i += consumed
                    continue
                }
            }

            // Kein (gültiger) Start einer Sequenz → Zeichen unverändert kopieren.
            out.append(s)
            i += 1
        }

        return String(out)
    }

    // MARK: - Escape-Decode-Helfer (alle: scalars + Startindex → Ergebnis + konsumierte Anzahl)

    /// Backslash-Escapes: `\n \r \t \f \\`, `\xNN`, `\x{…}`, `\uNNNN`, `\u{…}`.
    /// `at` zeigt auf den Backslash. Liefert (Ausgabe-Scalars, konsumierte
    /// Anzahl inkl. Backslash) oder nil, wenn nichts Gültiges folgt.
    private static func decodeBackslash(_ scalars: [Unicode.Scalar], at start: Int) -> ([Unicode.Scalar], Int)? {
        let next = start + 1
        guard next < scalars.count else { return nil }   // einsamer Backslash am Ende
        let c = scalars[next]

        switch c {
        case "n":  return (["\u{0A}"], 2)   // Newline
        case "r":  return (["\u{0D}"], 2)   // Carriage Return
        case "t":  return (["\u{09}"], 2)   // Tab
        case "f":  return (["\u{0C}"], 2)   // Form Feed
        case "\\": return (["\\"], 2)       // literaler Backslash
        case "x":  return decodeHexEscape(scalars, afterPrefix: next + 1, fixedDigits: 2, prefixLen: 2)
        case "u":  return decodeHexEscape(scalars, afterPrefix: next + 1, fixedDigits: 4, prefixLen: 2)
        default:   return nil                // unbekannt (\z …) → literal
        }
    }

    /// Gemeinsame Mechanik für `\x…` und `\u…`: entweder geklammert
    /// (`{1+ Hex-Ziffern}`) oder genau `fixedDigits` Hex-Ziffern.
    /// `afterPrefix` zeigt auf das erste Zeichen NACH `\x`/`\u`. `prefixLen`
    /// ist die Länge von `\x`/`\u` (immer 2) — nur fürs Mitzählen.
    private static func decodeHexEscape(_ scalars: [Unicode.Scalar], afterPrefix: Int,
                                        fixedDigits: Int, prefixLen: Int) -> ([Unicode.Scalar], Int)? {
        guard afterPrefix < scalars.count else { return nil }

        if scalars[afterPrefix] == "{" {
            // Geklammert: 1+ Hex-Ziffern bis zur „}".
            var j = afterPrefix + 1
            var hex = ""
            while j < scalars.count, isHexDigit(scalars[j]) {
                hex.unicodeScalars.append(scalars[j]); j += 1
            }
            guard !hex.isEmpty, j < scalars.count, scalars[j] == "}" else { return nil }
            guard let scalar = scalarFromHex(hex) else { return nil }
            // Konsumiert: Präfix + „{" + Ziffern + „}".
            return ([scalar], prefixLen + 1 + hex.count + 1)
        } else {
            // Feste Anzahl Hex-Ziffern (z.B. \x41, A).
            guard afterPrefix + fixedDigits <= scalars.count else { return nil }
            var hex = ""
            for k in 0..<fixedDigits {
                let d = scalars[afterPrefix + k]
                guard isHexDigit(d) else { return nil }
                hex.unicodeScalars.append(d)
            }
            guard let scalar = scalarFromHex(hex) else { return nil }
            return ([scalar], prefixLen + fixedDigits)
        }
    }

    /// HTML-Entity ab `&`. Numerisch (`&#65;`, `&#x41;`) oder benannt
    /// (`&amp;`). Liefert (Ziel-Scalar, konsumierte Länge inkl. „&" und „;")
    /// oder nil bei unbekannt/malformt → „&" bleibt literal.
    private static func decodeEntity(_ scalars: [Unicode.Scalar], at start: Int) -> (Unicode.Scalar, Int)? {
        let afterAmp = start + 1
        guard afterAmp < scalars.count else { return nil }

        if scalars[afterAmp] == "#" {
            // Numerisch: dezimal `&#NN;` oder hex `&#xNN;` / `&#XNN;`.
            var j = afterAmp + 1
            var isHex = false
            if j < scalars.count, scalars[j] == "x" || scalars[j] == "X" {
                isHex = true; j += 1
            }
            var digits = ""
            while j < scalars.count {
                let d = scalars[j]
                if isHex ? isHexDigit(d) : isDecDigit(d) {
                    digits.unicodeScalars.append(d); j += 1
                } else { break }
            }
            guard !digits.isEmpty, j < scalars.count, scalars[j] == ";" else { return nil }
            let value = isHex ? UInt32(digits, radix: 16) : UInt32(digits, radix: 10)
            guard let v = value, let scalar = Unicode.Scalar(v) else { return nil }
            return (scalar, (j + 1) - start)   // bis einschließlich „;"
        } else {
            // Benannt: bis zur „;" sammeln, in der kuratierten Tabelle suchen.
            var j = afterAmp
            var name = ""
            while j < scalars.count, isEntityNameChar(scalars[j]) {
                name.unicodeScalars.append(scalars[j]); j += 1
            }
            guard !name.isEmpty, j < scalars.count, scalars[j] == ";",
                  let scalar = namedEntities[name] else { return nil }
            return (scalar, (j + 1) - start)
        }
    }

    /// Prozent-Lauf ab `%`: sammelt aufeinanderfolgende `%NN`-Bytes und
    /// dekodiert sie GEMEINSAM als UTF-8 (ein Zeichen wie „ä" ist `%C3%A4`,
    /// zwei Bytes). Liefert (dekodierte Scalars, konsumierte Länge) oder nil,
    /// wenn schon das erste `%NN` malformt ist oder die Byte-Folge kein
    /// gültiges UTF-8 ergibt → „%" bleibt literal.
    private static func decodePercentRun(_ scalars: [Unicode.Scalar], at start: Int) -> ([Unicode.Scalar], Int)? {
        var bytes = [UInt8]()
        var j = start
        // Solange exakt das Muster `%` + 2 Hex-Ziffern passt, Byte einsammeln.
        while j + 2 < scalars.count, scalars[j] == "%",
              isHexDigit(scalars[j + 1]), isHexDigit(scalars[j + 2]) {
            let hi = hexValue(scalars[j + 1])!
            let lo = hexValue(scalars[j + 2])!
            bytes.append(UInt8(hi * 16 + lo))
            j += 3
        }
        guard !bytes.isEmpty else { return nil }   // erstes %NN war schon malformt
        // Bytefolge als UTF-8 deuten. Ungültiges UTF-8 → literal lassen.
        guard let decoded = String(bytes: bytes, encoding: .utf8) else { return nil }
        return (Array(decoded.unicodeScalars), j - start)
    }

    // MARK: - Zeichen-Klassen / Hex-Parsing (klein, lokal)

    private static func isDecDigit(_ s: Unicode.Scalar) -> Bool {
        s >= "0" && s <= "9"
    }

    private static func isHexDigit(_ s: Unicode.Scalar) -> Bool {
        (s >= "0" && s <= "9") || (s >= "a" && s <= "f") || (s >= "A" && s <= "F")
    }

    /// Erlaubte Zeichen in einem benannten Entity (`amp`, `copy`, `auml` …):
    /// ASCII-Buchstaben und -Ziffern. Hält den Scan an „;" oder Fremdzeichen an.
    private static func isEntityNameChar(_ s: Unicode.Scalar) -> Bool {
        (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || isDecDigit(s)
    }

    private static func hexValue(_ s: Unicode.Scalar) -> UInt32? {
        switch s {
        case "0"..."9": return s.value - 48          // '0' = 48
        case "a"..."f": return s.value - 97 + 10     // 'a' = 97
        case "A"..."F": return s.value - 65 + 10     // 'A' = 65
        default:        return nil
        }
    }

    /// Hex-String → gültiger Unicode-Scalar (oder nil bei Überlauf/Surrogat).
    private static func scalarFromHex(_ hex: String) -> Unicode.Scalar? {
        guard let v = UInt32(hex, radix: 16) else { return nil }
        return Unicode.Scalar(v)
    }

    // MARK: - Zeilen verbinden (Zeilen-Scope)

    /// „Remove Line Breaks" / Join Lines (BBEdit, Kap. 5): zieht die (auf ganze
    /// Zeilen ausgeweiteten) Zeilen zu EINER Zeile zusammen, getrennt durch
    /// `joiner`. `" "` (Default) entspricht BBEdits „Remove Line Breaks" für
    /// Fließtext; `""` verbindet ohne Trenner — nützlich, um eine Spalte aus
    /// einem 4D-/CSV-Export zu einem Wert zusammenzuziehen. Braucht ≥ 2
    /// inhaltliche Zeilen, sonst `nil`.
    ///
    /// Eigene Implementierung (nicht über `transformLines`), weil ein
    /// abschließendes Datei-End-Newline (Ganz-Text-Fall) sonst einen Trenner
    /// ans Ende hängte und die Mindestzahl auf den ECHTEN Inhaltszeilen prüfen
    /// muss (nicht auf dem Newline-Artefakt).
    static func joinLines(in text: String, selection: NSRange,
                          separator joiner: String = " ") -> LineOperations.Result? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let range = LineOperations.expandToFullLines(in: text, selection: selection)
        let block = ns.substring(with: range)
        var lines = LineOperations.splitLines(block)
        // Ein einzelnes leeres Schluss-Element stammt vom Datei-End-Newline
        // (expandToFullLines behält ihn im Ganz-Text-Fall) — kein Inhalt.
        if lines.count >= 2, lines.last == "" { lines.removeLast() }
        guard lines.count >= 2 else { return nil }          // mind. 2 echte Zeilen
        let joined = lines.joined(separator: joiner)
        guard joined != block else { return nil }
        let newText = ns.replacingCharacters(in: range, with: joined)
        return LineOperations.Result(newText: newText, affectedRange: range, lineCount: 1)
    }

    // MARK: - Zeilennummern (Zeilen-Scope)

    /// „Add Line Numbers" (BBEdit, Kap. 5): stellt jeder (auf ganze Zeilen
    /// ausgeweiteten) Zeile ihre laufende Nummer voran. Fastra nutzt feste
    /// Defaults (kein Dialog, wie bei joinLines): Start = 1, Schritt = 1,
    /// rechtsbündig, ein Trenner-Leerzeichen. Die Nummerierung ist RELATIV zum
    /// Block — die erste selektierte Zeile ist 1, nicht die absolute Dateizeile.
    ///
    /// Rechtsbündig heißt: jede Zahl wird mit führenden Leerzeichen auf die
    /// Breite der GRÖSSTEN Nummer im Block aufgefüllt, damit die Zahlen-Spalte
    /// bündig bleibt (12 Zeilen → " 1 a" … "12 l").
    ///
    /// Sonderfall Datei-End-Newline: Im Ganz-Text-Fall behält
    /// `expandToFullLines` das abschließende `\n`, sodass `splitLines` ein
    /// leeres Schluss-Element liefert (gleiche Falle wie bei joinLines). Diese
    /// Phantom-Leerzeile bekommt KEINE Nummer und zählt nicht zur Spaltenbreite
    /// — sonst hinge eine Nummer hinter dem letzten Zeilenumbruch.
    static func addLineNumbers(in text: String, selection: NSRange) -> LineOperations.Result? {
        transformLines(in: text, selection: selection) { lines in
            // Eine leere Schluss-Zeile stammt vom Datei-End-Newline und ist
            // kein echter Inhalt — sie wird nicht mitnummeriert.
            let hasTrailingEmpty = lines.count >= 2 && lines.last == ""
            let realCount = hasTrailingEmpty ? lines.count - 1 : lines.count
            guard realCount >= 1 else { return lines }
            // Breite = Stellenzahl der größten Nummer (= Anzahl echter Zeilen).
            let width = String(realCount).count

            var out: [String] = []
            out.reserveCapacity(lines.count)
            for (index, line) in lines.enumerated() {
                // Die Phantom-Leerzeile am Ende unverändert durchreichen.
                if hasTrailingEmpty && index == lines.count - 1 {
                    out.append(line)
                    continue
                }
                let number = String(index + 1)                       // Start 1, Schritt 1
                let pad = String(repeating: " ", count: width - number.count)
                out.append(pad + number + " " + line)                // rechtsbündig + ein Trenner
            }
            return out
        }
    }

    /// „Remove Line Numbers" (BBEdit, Kap. 5): Umkehrung zu `addLineNumbers`.
    /// Schneidet aus jeder Zeile einen führenden Lauf aus optionalen
    /// Leerzeichen, mindestens einer Ziffer und einem optionalen Trenner-
    /// Leerzeichen weg (`^ *[0-9]+ ?`). Bewusst tolerant: trifft sowohl unsere
    /// rechtsbündig gepolsterten Nummern als auch von anderen Werkzeugen
    /// nummerierte Dateien. Zeilen OHNE führende Ziffer bleiben unangetastet
    /// (z.B. eingerückter Text ohne Nummer) — dadurch ist auch teilweises
    /// Entfernen möglich. Ändert sich keine Zeile, liefert `transformLines` nil.
    static func removeLineNumbers(in text: String, selection: NSRange) -> LineOperations.Result? {
        // Einmalig kompiliert: führende Leerzeichen, Ziffern, optionales Leerzeichen.
        // Das Anker-`^` sorgt dafür, dass `firstMatch` nur am Zeilenanfang greift.
        guard let regex = try? NSRegularExpression(pattern: "^ *[0-9]+ ?") else { return nil }
        return transformLines(in: text, selection: selection) { lines in
            lines.map { line in
                let ns = line as NSString
                let full = NSRange(location: 0, length: ns.length)
                // Nur ein echter Treffer am Anfang (Position 0, Länge > 0) wird
                // entfernt; ohne führende Nummer bleibt die Zeile unverändert.
                guard let match = regex.firstMatch(in: line, range: full),
                      match.range.location == 0, match.range.length > 0 else { return line }
                return ns.replacingCharacters(in: match.range, with: "")
            }
        }
    }

    // MARK: - Hard Wrap (Zeilen-Scope)

    /// "Hard Wrap" (BBEdit Kap. 5): bricht jede (auf ganze Zeilen ausgeweitete) Zeile an
    /// Wortgrenzen so um, dass die Ausgabezeilen `column` ZEICHEN einhalten. "Zeichen" =
    /// Unicode-Grapheme (Swift Character) — einfache, vorhersehbare Spaltenzählung (East-Asian-
    /// Doppelbreite wird bewusst nicht behandelt). Umgebrochen wird NUR an Wortgrenzen
    /// (Whitespace-Läufe); zwischen Wörtern wird der Whitespace zu EINEM Leerzeichen normalisiert.
    ///
    /// AUSNAHME von der Spaltengrenze: Da BBEdit beim Hard Wrap keine Wörter zerschneidet, kann
    /// eine Ausgabezeile `column` ÜBERSCHREITEN, wenn ein einzelnes Wort für sich schon breiter
    /// als `column` ist — oder wenn die führende Einrückung zusammen mit dem ersten Wort die
    /// Breite sprengt. Solche überlangen Wörter bleiben ganz und stehen ungebrochen auf eigener
    /// Zeile. In allen anderen Fällen gilt: jede Ausgabezeile ist höchstens `column` Zeichen lang.
    ///
    /// Führender Whitespace (Einrückung) einer Eingabezeile bleibt an deren ERSTER Ausgabezeile;
    /// Folgezeilen beginnen ohne Einrückung. Leere/whitespace-only Eingabezeilen bleiben
    /// unverändert (Absatztrenner). Zeilen-Scope. nil bei column <= 0 oder wenn sich nichts ändert.
    static func hardWrap(in text: String, selection: NSRange, column: Int) -> LineOperations.Result? {
        // Sinnlose Spaltenbreite (0 oder negativ) → es gibt keinen Umbruch, den man berechnen
        // könnte; früh raus, bevor wir überhaupt ausweiten.
        guard column > 0 else { return nil }
        // transformLines weitet auf ganze Zeilen aus, liefert nil bei No-Op und reicht die
        // Phantom-Leerzeile (Datei-End-Newline) korrekt durch — `wrapLine("")` gibt `[""]` zurück,
        // sodass aus der einen Phantom-Zeile genau eine bleibt.
        return transformLines(in: text, selection: selection) { lines in
            lines.flatMap { wrapLine($0, column) }
        }
    }

    /// Bricht EINE Eingabezeile greedy an Wortgrenzen um, sodass keine Ausgabezeile mehr als
    /// `width` Grapheme zählt. Liefert die Liste der Ausgabezeilen (mindestens eine).
    private static func wrapLine(_ line: String, _ width: Int) -> [String] {
        // Passt die Zeile ohnehin in die Spaltenbreite (`count` = Grapheme-Anzahl), bleibt sie
        // unverändert — das deckt auch leere und whitespace-only Zeilen ab (Absatztrenner).
        guard line.count > width else { return [line] }

        // Führende Einrückung (Leerzeichen/Tabs) bewahren: sie bleibt nur an der ERSTEN
        // Ausgabezeile; Folgezeilen beginnen bündig links.
        let leadingWS = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        // Der Rest hinter der Einrückung ist der umzubrechende Inhalt.
        let body = String(line.dropFirst(leadingWS.count))
        // In Wörter zerlegen: maximale Läufe ohne Leerzeichen/Tab. Damit werden Mehrfach-
        // Whitespace zwischen Wörtern automatisch zu EINEM Trenner normalisiert.
        let words = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // Nur Whitespace und kein einziges Wort → die Zeile unverändert lassen.
        guard !words.isEmpty else { return [line] }

        // Greedy auffüllen: Wörter so lange in die aktuelle Zeile packen, wie sie (plus das
        // Trenner-Leerzeichen) in die verfügbare Spaltenzahl passen.
        var out: [String] = []
        var current = ""
        for word in words {
            // Die ERSTE Ausgabezeile hat weniger Platz, weil die Einrückung Spalten belegt;
            // Folgezeilen haben die volle `width`.
            let avail = out.isEmpty ? max(0, width - leadingWS.count) : width
            if current.isEmpty {
                // Erstes Wort der aktuellen Zeile: immer aufnehmen, auch wenn es allein schon
                // zu lang ist (ein überlanges Einzelwort bleibt ungebrochen auf eigener Zeile).
                current = word
            } else if current.count + 1 + word.count <= avail {
                // Wort passt noch (inkl. einem Trenner-Leerzeichen) → anhängen.
                current += " " + word
            } else {
                // Wort passt nicht mehr → aktuelle Zeile abschließen, neue mit diesem Wort starten.
                out.append(current)
                current = word
            }
        }
        // Die zuletzt gefüllte Zeile noch ausgeben.
        if !current.isEmpty { out.append(current) }
        // Defensive: sollte nie eintreten (words war nicht leer), aber dann die Zeile unverändert.
        if out.isEmpty { return [line] }
        // Die Einrückung nur der ersten Ausgabezeile wieder voranstellen.
        out[0] = leadingWS + out[0]
        return out
    }

    // MARK: - Zeichen/Wörter tauschen (Transpose)

    /// „Exchange Characters" (BBEdit, Kap. 5): vertauscht zwei benachbarte
    /// Zeichen — der klassische „ich hab zwei Buchstaben verdreht"-Fix. Welche
    /// zwei Zeichen getauscht werden, hängt von Cursor/Selektion ab (BBEdit-Regeln):
    ///
    ///   1. Cursor MITTEN in einer Zeile (nicht am Zeilen-/Dokumentanfang oder
    ///      -ende) → die beiden Zeichen LINKS und RECHTS vom Cursor tauschen.
    ///   2. Cursor am Zeilen-/Dokumentanfang → die beiden FOLGENDEN Zeichen tauschen.
    ///   3. Cursor am Zeilen-/Dokumentende → die beiden VORANGEHENDEN Zeichen tauschen.
    ///   4. Selektion vorhanden → das ERSTE und das LETZTE Zeichen der Selektion
    ///      tauschen (der Inhalt dazwischen bleibt unangetastet).
    ///
    /// „Anfang/Ende" bezieht sich auf `\n`-Grenzen (eine logische Zeile). Ein
    /// „Zeichen" ist hier ein Unicode-GRAPHEM (Swift `Character`), nicht eine
    /// einzelne UTF-16-Code-Unit — sonst zerrisse der Tausch ein Surrogatpaar
    /// (Emoji) oder einen kombinierten Buchstaben. Wir mappen deshalb die
    /// Grapheme-Grenzen auf UTF-16-Offsets und arbeiten über die NSString, damit
    /// die standalone Funktion auch links/rechts der Selektion „spähen" kann.
    /// Liefert `nil`, wenn es nichts zu tauschen gibt (Text mit < 2 Graphemen,
    /// Cursor auf einer leeren Zeile, beide Nachbarn identisch, oder der Cursor
    /// landet mitten in einem Grapheme).
    static func exchangeCharacters(in text: String, selection: NSRange) -> LineOperations.Result? {
        let ns = text as NSString
        let starts = graphemeOffsets(text)
        // `starts` enthält den UTF-16-Start jedes Graphems plus das End-Offset;
        // ≥ 3 Einträge bedeutet ≥ 2 Grapheme (sonst gibt es nichts zu tauschen).
        guard starts.count >= 3 else { return nil }

        // --- Fall 4: Selektion → erstes und letztes Grapheme tauschen ---
        if selection.length > 0 {
            // Selektions-Grenzen müssen auf Grapheme-Grenzen liegen.
            guard let si = starts.firstIndex(of: selection.location),
                  let ei = starts.firstIndex(of: selection.location + selection.length),
                  ei - si >= 2 else { return nil }
            let firstRange = NSRange(location: starts[si], length: starts[si + 1] - starts[si])
            let lastRange  = NSRange(location: starts[ei - 1], length: starts[ei] - starts[ei - 1])
            let first = ns.substring(with: firstRange)
            let last  = ns.substring(with: lastRange)
            guard first != last else { return nil }   // identisch → No-Op
            let middle = ns.substring(with: NSRange(location: firstRange.location + firstRange.length,
                                                    length: lastRange.location - (firstRange.location + firstRange.length)))
            let replacement = last + middle + first
            return makeResult(ns, NSRange(location: selection.location, length: selection.length), replacement)
        }

        // --- Cursor-Fälle (1–3): leere Selektion = Einfügemarke bei `caret` ---
        let caret = selection.location
        // Der Cursor muss auf einer Grapheme-Grenze sitzen (sonst nil — z.B. mitten
        // in einem Emoji-Surrogatpaar).
        guard let ci = starts.firstIndex(of: caret) else { return nil }
        let (atLineStart, atLineEnd) = caretAtLineEdges(ns, caret)

        if atLineStart && atLineEnd {
            // Leere Zeile / einzelnes Zeichen vor `\n` → nichts auf beiden Seiten.
            return nil
        } else if atLineStart {
            // Fall 2: die beiden FOLGENDEN Grapheme (ci, ci+1) tauschen.
            guard ci + 2 < starts.count else { return nil }
            return swapGraphemeCells(ns, starts[ci], starts[ci + 1], starts[ci + 2])
        } else if atLineEnd {
            // Fall 3: die beiden VORANGEHENDEN Grapheme (ci-2, ci-1) tauschen.
            guard ci >= 2 else { return nil }
            return swapGraphemeCells(ns, starts[ci - 2], starts[ci - 1], starts[ci])
        } else {
            // Fall 1: Grapheme LINKS (ci-1) und RECHTS (ci) vom Cursor tauschen.
            guard ci >= 1, ci + 1 < starts.count else { return nil }
            return swapGraphemeCells(ns, starts[ci - 1], starts[ci], starts[ci + 1])
        }
    }

    /// „Exchange Words" (BBEdit, Kap. 5 — per Option-Taste aus „Exchange
    /// Characters"): wie `exchangeCharacters`, aber auf ganzen WÖRTERN statt
    /// Einzelzeichen. Ein „Wort" ist ein maximaler Lauf von `\w`-Zeichen
    /// (Buchstaben, Ziffern, `_`); alles dazwischen (Leerzeichen, Satzzeichen)
    /// bleibt an seiner Stelle stehen — getauscht werden nur die Wort-Inhalte.
    /// Gleiche vier Cursor-/Selektions-Regeln wie oben:
    ///
    ///   1. Cursor mitten drin → Wort LINKS und Wort RECHTS vom Cursor tauschen.
    ///   2. Cursor am Zeilen-/Dokumentanfang → die beiden FOLGENDEN Wörter.
    ///   3. Cursor am Zeilen-/Dokumentende → die beiden VORANGEHENDEN Wörter.
    ///   4. Selektion → erstes und letztes VOLLSTÄNDIG enthaltene Wort tauschen.
    ///
    /// Liefert `nil`, wenn auf einer Seite kein Wort steht (< 2 Wörter im Text,
    /// kein zweites Wort in der gewünschten Richtung, leere Auswahl ohne Wörter).
    static func exchangeWords(in text: String, selection: NSRange) -> LineOperations.Result? {
        let ns = text as NSString
        let words = wordRanges(ns)
        guard words.count >= 2 else { return nil }   // < 2 Wörter → nichts zu tauschen

        // --- Fall 4: Selektion → erstes/letztes vollständig enthaltenes Wort ---
        if selection.length > 0 {
            let selEnd = selection.location + selection.length
            let inside = words.filter { $0.location >= selection.location && $0.location + $0.length <= selEnd }
            guard inside.count >= 2 else { return nil }
            return swapWordRanges(ns, inside.first!, inside.last!)
        }

        // --- Cursor-Fälle (1–3) ---
        let caret = selection.location
        let (atLineStart, atLineEnd) = caretAtLineEdges(ns, caret)

        if atLineStart && atLineEnd {
            return nil
        } else if atLineStart {
            // Fall 2: die beiden ersten Wörter, die am/nach dem Cursor BEGINNEN.
            let following = words.filter { $0.location >= caret }
            guard following.count >= 2 else { return nil }
            return swapWordRanges(ns, following[0], following[1])
        } else if atLineEnd {
            // Fall 3: die beiden letzten Wörter, die VOR dem Cursor ENDEN.
            let before = words.filter { $0.location + $0.length <= caret }
            guard before.count >= 2 else { return nil }
            return swapWordRanges(ns, before[before.count - 2], before[before.count - 1])
        } else {
            // Fall 1: das Wort, in dem der Cursor sitzt bzw. das links vom Cursor
            // liegt, mit seinem Nachbarn tauschen. Bevorzugt der NACHFOLGER
            // (erstes Wort, das am/nach dem Cursor beginnt); existiert keiner
            // (Cursor mitten im LETZTEN Wort), dann der VORGÄNGER. So greift der
            // Tausch auch, wenn der Cursor im letzten Wort einer Zeile steht.
            guard let leftIdx = words.lastIndex(where: { $0.location < caret })
                else { return nil }
            if let rightIdx = words.firstIndex(where: { $0.location >= caret }),
               rightIdx != leftIdx {
                // Normalfall: aktuelles/linkes Wort mit dem folgenden tauschen.
                return swapWordRanges(ns, words[leftIdx], words[rightIdx])
            } else if leftIdx >= 1 {
                // Kein Wort rechts → mit dem vorangehenden Wort tauschen.
                return swapWordRanges(ns, words[leftIdx - 1], words[leftIdx])
            } else {
                return nil   // nur ein einziges Wort erreichbar
            }
        }
    }

    // MARK: - Interne Helfer (Transpose)

    /// UTF-16-Startoffset jedes Graphems im Text, plus das End-Offset als letztes
    /// Element. Damit lässt sich ein Cursor-/Selektions-Offset (NSRange-Location)
    /// auf „das wievielte Grapheme" abbilden und zwischen Graphemen schneiden,
    /// ohne ein Surrogatpaar zu zerteilen. Beispiel: "a😀b" → [0, 1, 3, 4].
    private static func graphemeOffsets(_ text: String) -> [Int] {
        var offsets: [Int] = []
        let utf16Start = text.utf16.startIndex
        var idx = text.startIndex
        while idx < text.endIndex {
            // `samePosition(in:)` gibt die Stelle in der UTF-16-Sicht; der Abstand
            // zum Anfang ist genau der NSString-Offset dieses Graphems.
            let u16 = text.utf16.distance(from: utf16Start, to: idx.samePosition(in: text.utf16)!)
            offsets.append(u16)
            idx = text.index(after: idx)
        }
        offsets.append((text as NSString).length)
        return offsets
    }

    /// Prüft, ob der Cursor an einer Zeilen-/Dokumentkante steht — gemessen an
    /// `\n`-Grenzen. „Anfang": ganz vorne oder direkt hinter einem `\n`.
    /// „Ende": ganz hinten oder direkt vor einem `\n`. Beides zugleich → der
    /// Cursor sitzt auf einer leeren Zeile.
    private static func caretAtLineEdges(_ ns: NSString, _ caret: Int) -> (start: Bool, end: Bool) {
        let prev = caret > 0 ? ns.substring(with: NSRange(location: caret - 1, length: 1)) : nil
        let next = caret < ns.length ? ns.substring(with: NSRange(location: caret, length: 1)) : nil
        return (caret == 0 || prev == "\n", caret == ns.length || next == "\n")
    }

    /// Tauscht die beiden Grapheme-Zellen `[a..b)` und `[b..c)` (alles in
    /// UTF-16-Offsets) und liefert das Result oder `nil`, wenn beide Zellen
    /// denselben Inhalt haben (No-Op). Eine Zelle, die ein `\n` ist, blockt den
    /// Tausch ab — sonst verschöbe man einen Zeilenumbruch.
    private static func swapGraphemeCells(_ ns: NSString, _ a: Int, _ b: Int, _ c: Int) -> LineOperations.Result? {
        let left = ns.substring(with: NSRange(location: a, length: b - a))
        let right = ns.substring(with: NSRange(location: b, length: c - b))
        guard left != "\n", right != "\n", left != right else { return nil }
        return makeResult(ns, NSRange(location: a, length: c - a), right + left)
    }

    /// Tauscht die Inhalte zweier Wort-Ranges (`w1` liegt VOR `w2`); der Text
    /// zwischen ihnen bleibt unverändert stehen.
    private static func swapWordRanges(_ ns: NSString, _ w1: NSRange, _ w2: NSRange) -> LineOperations.Result? {
        let first = ns.substring(with: w1)
        let second = ns.substring(with: w2)
        let between = ns.substring(with: NSRange(location: w1.location + w1.length,
                                                 length: w2.location - (w1.location + w1.length)))
        let range = NSRange(location: w1.location, length: (w2.location + w2.length) - w1.location)
        return makeResult(ns, range, second + between + first)
    }

    /// Findet alle „Wörter" — maximale Läufe von `\w`-Zeichen (Buchstaben,
    /// Ziffern, `_`) — als UTF-16-Ranges. `\w`-Prüfung pro Unicode-Scalar über
    /// `CharacterSet`, damit Umlaute/Akzente als Wortzeichen zählen.
    private static func wordRanges(_ ns: NSString) -> [NSRange] {
        let wordSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        func isWord(_ i: Int) -> Bool {
            let ch = ns.substring(with: NSRange(location: i, length: 1))
            // Genau eine Code-Unit, die zugleich ein einzelner Wort-Scalar ist
            // (schließt halbe Surrogatpaare/Emoji aus → die sind keine Wörter).
            return ch.unicodeScalars.count == 1 && wordSet.contains(ch.unicodeScalars.first!)
        }
        var out: [NSRange] = []
        var i = 0
        while i < ns.length {
            if isWord(i) {
                let start = i
                while i < ns.length, isWord(i) { i += 1 }
                out.append(NSRange(location: start, length: i - start))
            } else {
                i += 1
            }
        }
        return out
    }

    /// Baut aus altem NSString, ersetztem Bereich und Ersatztext ein `Result`;
    /// `nil`, wenn der Ersatz identisch zum Original wäre (No-Op-Schutz).
    private static func makeResult(_ ns: NSString, _ range: NSRange, _ replacement: String) -> LineOperations.Result? {
        guard ns.substring(with: range) != replacement else { return nil }
        let newText = ns.replacingCharacters(in: range, with: replacement)
        return LineOperations.Result(newText: newText, affectedRange: range, lineCount: 0)
    }

    // MARK: - Unicode (Zeichen-Scope)

    /// „Normalize Whitespace"-Baustein (BBEdit, Kap. 5): ersetzt ALLE
    /// Unicode-Leerzeichen-VARIANTEN durch das gewöhnliche ASCII-Leerzeichen
    /// (U+0020). Gemeint ist die Unicode-Kategorie Zs („Space Separator") —
    /// z.B. das geschützte Leerzeichen NBSP (U+00A0), die typografischen
    /// Breiten U+2000–U+200A (En-/Em-Space, Thin Space …), das schmale
    /// geschützte U+202F, das mathematische U+205F und das ideographische
    /// Leerzeichen U+3000 (CJK). Solche Zeichen schleichen sich beim Kopieren
    /// aus Word/Web/PDF ein und lassen Suchen/Vergleiche scheitern, weil sie
    /// AUSSEHEN wie ein Leerzeichen, aber keins sind.
    ///
    /// Tab (U+0009), Zeilenumbruch (U+000A) und Wagenrücklauf (U+000D) gehören
    /// NICHT zur Kategorie Zs und bleiben unangetastet — die Zeilen-/Spalten-
    /// struktur bleibt erhalten. Arbeitet pro Unicode-Scalar und ersetzt 1:1
    /// (längenstabil pro Scalar). Zeichen-Scope: Selektion oder ganzer Text.
    static func normalizeSpaces(in text: String, selection: NSRange) -> LineOperations.Result? {
        transformSelection(in: text, selection: selection) { s in
            var out = String.UnicodeScalarView()
            for scalar in s.unicodeScalars {
                // `generalCategory == .spaceSeparator` = Unicode-Kategorie Zs.
                // Das normale Leerzeichen (U+0020) ist selbst Zs — es durch
                // sich selbst zu ersetzen ist ein No-Op, kein Schaden.
                if scalar.properties.generalCategory == .spaceSeparator {
                    out.append(" ")
                } else {
                    out.append(scalar)
                }
            }
            return String(out)
        }
    }

    /// „Strip Diacriticals" (BBEdit, Kap. 5): entfernt diakritische Zeichen
    /// (Akzente, Tilden, Trema …) von Buchstaben — „á"→„a", „ç"→„c", „ü"→„u",
    /// „É"→„E". Nützlich, um Namen/Daten für Vergleiche oder ASCII-only-Systeme
    /// zu vereinheitlichen. Beachte das BBEdit-Verhalten beim deutschen Umlaut:
    /// „ü" wird zu „u" (NICHT zur Transliteration „ue") — es fällt schlicht der
    /// Akzent-Anteil weg.
    ///
    /// Umsetzung über Foundations `folding(options: .diacriticInsensitive)`:
    /// zerlegt intern jedes Zeichen (NFD) und wirft die kombinierenden
    /// Akzent-Marks weg. Bewusst NUR diese eine Option — keine Case-Faltung
    /// (Großbuchstaben bleiben groß) und keine Breiten-Faltung (Halb-/Vollbreite
    /// bleibt). `locale: nil` = locale-unabhängig, damit das Ergebnis auf jedem
    /// System gleich ist. Emoji und Schriften ohne Diakritika (Kyrillisch ohne
    /// Akzente, CJK …) gehen unverändert durch. Zeichen-Scope.
    static func stripDiacriticals(in text: String, selection: NSRange) -> LineOperations.Result? {
        transformSelection(in: text, selection: selection) { s in
            s.folding(options: .diacriticInsensitive, locale: nil)
        }
    }

    /// „Precompose Unicode" (BBEdit, Kap. 5): Unicode-Normalisierung nach
    /// NFC — kombinierte Sequenzen werden, wo möglich, zu EINEM Zeichen
    /// zusammengesetzt: „e" + kombinierender Akut (U+0065 U+0301, zwei
    /// Scalars) → „é" (U+00E9, ein Scalar). Der sichtbare Text ändert sich
    /// NICHT, nur die Byte-Darstellung. Typischer Anwendungsfall: Dateien von
    /// macOS-Dateisystemen (HFS+ lieferte dekomponiert) vereinheitlichen,
    /// damit String-Vergleiche und RegEx-Treffer wieder stimmen.
    /// Direkt Foundations `precomposedStringWithCanonicalMapping` (= NFC).
    static func precomposeUnicode(in text: String, selection: NSRange) -> LineOperations.Result? {
        transformSelection(in: text, selection: selection, scalarExactChangeCheck: true) { s in
            s.precomposedStringWithCanonicalMapping
        }
    }

    /// „Decompose Unicode" (BBEdit, Kap. 5): die Umkehrung — Normalisierung
    /// nach NFD, jedes zusammengesetzte Zeichen wird in Basiszeichen +
    /// kombinierende Marks zerlegt: „é" (U+00E9) → „e" + U+0301. Auch hier
    /// bleibt der sichtbare Text gleich; nützlich, wenn ein Zielsystem die
    /// zerlegte Form erwartet oder man die Akzent-Marks einzeln per RegEx
    /// greifen will. Direkt Foundations `decomposedStringWithCanonicalMapping`
    /// (= NFD).
    static func decomposeUnicode(in text: String, selection: NSRange) -> LineOperations.Result? {
        transformSelection(in: text, selection: selection, scalarExactChangeCheck: true) { s in
            s.decomposedStringWithCanonicalMapping
        }
    }

    // MARK: - Interne Helfer

    /// Zeichen-Scope-Transformation: wirkt auf die Selektion (oder den ganzen
    /// Text bei leerer Selektion). `nil`, wenn sich nichts ändert.
    /// `scalarExactChangeCheck`: Swifts `String ==` vergleicht KANONISCH
    /// äquivalent — „é" (NFC) und „e"+Akut (NFD) gelten als gleich. Für die
    /// NFC-/NFD-Normalisierung wäre der No-Op-Schutz damit IMMER aktiv
    /// (die Transformation ändert ja nur die Scalar-Darstellung, nie den
    /// sichtbaren Text). Diese Ops vergleichen deshalb Scalar-für-Scalar.
    private static func transformSelection(in text: String, selection: NSRange,
                                           scalarExactChangeCheck: Bool = false,
                                           _ transform: (String) -> String) -> LineOperations.Result? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let full = NSRange(location: 0, length: ns.length)
        let range = selection.length > 0 ? NSIntersectionRange(selection, full) : full
        guard range.length > 0 else { return nil }
        let original = ns.substring(with: range)
        let transformed = transform(original)
        let unchanged = scalarExactChangeCheck
            ? transformed.unicodeScalars.elementsEqual(original.unicodeScalars)
            : transformed == original
        guard !unchanged else { return nil }
        let newText = ns.replacingCharacters(in: range, with: transformed)
        return LineOperations.Result(newText: newText, affectedRange: range, lineCount: 0)
    }

    /// Zeilen-Scope-Transformation: weitet auf ganze Zeilen aus, zerlegt in
    /// Zeilen-Inhalte, wendet `transform` auf die Zeilen-Liste an und baut den
    /// Block mit dem korrekten Trenner wieder zusammen.
    /// `requireChange`: bei `true` (Default) → `nil`, wenn der Block unverändert
    /// bliebe (z.B. nichts zu trimmen). `minLines`: Mindestzeilenzahl, sonst nil.
    private static func transformLines(in text: String, selection: NSRange,
                                       requireChange: Bool = true, minLines: Int = 1,
                                       _ transform: ([String]) -> [String]) -> LineOperations.Result? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let range = LineOperations.expandToFullLines(in: text, selection: selection)
        let block = ns.substring(with: range)
        let lines = LineOperations.splitLines(block)
        guard lines.count >= minLines else { return nil }

        let newLines = transform(lines)
        let newBlock = newLines.joined(separator: LineOperations.separator(of: text))
        if requireChange && newBlock == block { return nil }
        let newText = ns.replacingCharacters(in: range, with: newBlock)
        return LineOperations.Result(newText: newText, affectedRange: range, lineCount: newLines.count)
    }
}
