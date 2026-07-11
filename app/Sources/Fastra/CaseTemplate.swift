// CaseTemplate.swift
//
// BBEdit-Grep-Feature „Case Transformations" im Ersetzungsmuster
// (BBEdit User Manual 16.0.1, Kap. 8 S. 216): Die Operatoren
//
//   \u  → nächstes Zeichen groß        \U  → alles Folgende groß …
//   \l  → nächstes Zeichen klein       \L  → alles Folgende klein …
//   \E  → … bis hier (beendet \U/\L)
//
// wirken auf den ERSETZTEN Text (also NACH dem Einsetzen der $N-Backrefs).
// Beispiel: Suchen `(\w+), (\w+)` · Ersetzen `\U$2\E $1` macht aus
// „Müller, Daniel" → „DANIEL Müller".
//
// NSRegularExpression kennt diese Operatoren NICHT — sein Template-Vertrag
// behandelt nur `$N` und `\`-Escapes. Wir zerlegen das Template deshalb in
// Segmente ZWISCHEN den Operatoren, lassen NSRegularExpression jedes Segment
// einzeln expandieren (Backrefs bleiben dessen Job — eine Wahrheit) und
// wenden anschließend die Groß-/Kleinschreibung per Zustandsmaschine an.
//
// Gilt nur im RegEx-Modus: Im Plain-/Platzhalter-Modus escapt
// `ApplyEngine.replacementTemplate` alle Backslashes (`\U` → `\\U`), der
// Parser erkennt dann KEINEN Operator — literale Eingaben bleiben literal,
// ganz ohne Modus-Weiche an den Call-Sites.

import Foundation

enum CaseTemplate {
    // MARK: - Parsen

    /// Ein Baustein des zerlegten Templates: entweder ein Case-Operator
    /// oder ein Stück Template-Text (das weiterhin `$N`/`\\`-Syntax
    /// enthalten darf — expandiert wird es später von NSRegularExpression).
    enum Piece: Equatable {
        case upperAll   // \U
        case lowerAll   // \L
        case upperNext  // \u
        case lowerNext  // \l
        case end        // \E
        case text(String)
    }

    /// Zerlegt ein Replacement-Template in Operator- und Text-Stücke.
    /// Escape-Regel wie im NSRegularExpression-Template: `\` schützt das
    /// Folgezeichen — `\\U` ist also KEIN Operator, sondern der literale
    /// Backslash gefolgt von `U`. Solche Paare bleiben unangetastet im
    /// Text-Stück (NSRegularExpression löst sie beim Expandieren auf).
    static func pieces(of template: String) -> [Piece] {
        var result: [Piece] = []
        var current = String()
        var iterator = template.makeIterator()
        var pendingBackslash = false

        func flush() {
            if !current.isEmpty { result.append(.text(current)); current = "" }
        }

        while let ch = iterator.next() {
            if pendingBackslash {
                pendingBackslash = false
                switch ch {
                case "U": flush(); result.append(.upperAll)
                case "L": flush(); result.append(.lowerAll)
                case "u": flush(); result.append(.upperNext)
                case "l": flush(); result.append(.lowerNext)
                case "E": flush(); result.append(.end)
                default:
                    // Kein Case-Operator → Escape-Paar unverändert übernehmen
                    // (z.B. `\\`, `\$`, `\n`) — das interpretiert später
                    // NSRegularExpression selbst.
                    current.append("\\")
                    current.append(ch)
                }
            } else if ch == "\\" {
                pendingBackslash = true
            } else {
                current.append(ch)
            }
        }
        // Einsamer Backslash am Template-Ende: literal durchreichen.
        if pendingBackslash { current.append("\\") }
        flush()
        return result
    }

    /// Schneller Vorab-Check: enthält das Template überhaupt einen
    /// Case-Operator? Wenn nein, nehmen die Call-Sites den unveränderten
    /// NSRegularExpression-Pfad (kein Verhaltens- oder Kostenunterschied).
    static func containsOperators(_ template: String) -> Bool {
        return pieces(of: template).contains { piece in
            if case .text = piece { return false }
            return true
        }
    }

    // MARK: - Expandieren

    /// Dauerhafter Case-Zustand (durch `\U`/`\L` gesetzt, durch `\E` beendet).
    private enum Mode { case none, upper, lower }

    /// Einmal-Zustand für GENAU ein Ausgabezeichen (durch `\u`/`\l` gesetzt).
    private enum OneShot { case upper, lower }

    /// Ersetzungstext für EINEN Treffer — Gegenstück zu
    /// `regex.replacementString(for:in:offset:template:)`, aber mit
    /// Case-Operator-Unterstützung. Ohne Operatoren im Template wird
    /// direkt an NSRegularExpression durchgereicht (Fast Path).
    static func replacement(for result: NSTextCheckingResult,
                            in text: String,
                            regex: NSRegularExpression,
                            template: String) -> String {
        let parsed = pieces(of: template)
        let hasOps = parsed.contains { if case .text = $0 { return false }; return true }
        guard hasOps else {
            return regex.replacementString(for: result, in: text,
                                           offset: 0, template: template)
        }

        var mode: Mode = .none
        var oneShot: OneShot? = nil
        var out = String()

        for piece in parsed {
            switch piece {
            case .upperAll: mode = .upper; oneShot = nil
            case .lowerAll: mode = .lower; oneShot = nil
            case .end:      mode = .none;  oneShot = nil
            case .upperNext: oneShot = .upper
            case .lowerNext: oneShot = .lower
            case .text(let segment):
                // Backrefs im Segment expandieren lassen — DANN erst die
                // Schreibweise anwenden (BBEdit: Operatoren wirken auf das
                // Ergebnis, nicht auf das Muster).
                let expanded = regex.replacementString(for: result, in: text,
                                                       offset: 0, template: segment)
                guard !expanded.isEmpty else { continue }  // OneShot bleibt hängen

                var rest = expanded
                if let shot = oneShot {
                    // Genau EIN Zeichen (Graphem — Umlaute/Emoji bleiben heil).
                    let first = rest.removeFirst()
                    out.append(shot == .upper ? String(first).uppercased()
                                              : String(first).lowercased())
                    oneShot = nil
                }
                switch mode {
                case .none:  out.append(rest)
                case .upper: out.append(rest.uppercased())
                case .lower: out.append(rest.lowercased())
                }
            }
        }
        return out
    }

    /// „Alle ersetzen" mit Case-Operatoren: `stringByReplacingMatches`
    /// kann das Template nicht deuten, also enumerieren wir die Treffer
    /// selbst und setzen den Text Stück für Stück zusammen (gleiches
    /// Muster wie `ApplyEngine.planFile`).
    static func replaceAllAssembling(in text: String,
                                     regex: NSRegularExpression,
                                     template: String,
                                     range: NSRange) -> String {
        let ns = text as NSString
        let raw = regex.matches(in: text, options: [], range: range)
        var out = String()
        out.reserveCapacity(text.count)
        var cursor = 0
        for result in raw {
            let r = result.range
            if r.location > cursor {
                out.append(ns.substring(with: NSRange(location: cursor,
                                                      length: r.location - cursor)))
            }
            out.append(replacement(for: result, in: text, regex: regex, template: template))
            cursor = r.location + r.length
        }
        if cursor < ns.length {
            out.append(ns.substring(with: NSRange(location: cursor,
                                                  length: ns.length - cursor)))
        }
        return out
    }
}
