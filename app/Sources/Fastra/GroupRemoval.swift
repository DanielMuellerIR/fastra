// GroupRemoval.swift
//
// Gegenstück zu „Gruppe definieren" (GroupBuilder): löst eine bestehende
// Capture Group wieder auf — die Klammern verschwinden, der Inhalt bleibt.
// Pure Logik, voll testbar (GroupRemovalTests).
//
// Sicherheits-Philosophie wie überall in Fastra: Lieber eine Aktion
// VERWEIGERN (nil + Beep/Hinweis in der UI) als ein Pattern erzeugen,
// das still etwas anderes matcht. Drei Verweigerungs-Gründe:
//
//   1. Das Replace-Template referenziert die Gruppe (`$k`) — nach dem
//      Löschen wäre die Referenz kaputt. Erst Replace anpassen.
//   2. Direkt hinter der Gruppe steht ein Quantifier: `(abc)+` ohne
//      Klammern wäre `abc+` — der Quantifier würde plötzlich nur noch
//      das letzte Zeichen treffen. Semantik-Änderung → verweigern.
//   3. Im Gruppen-Inhalt liegt eine Alternation (`|`), die nicht in einer
//      tieferen Gruppe steckt: `(a|b)c` ohne Klammern wäre `a|bc`.
//      Ebenfalls Semantik-Änderung → verweigern. (Konservativ geprüft:
//      auch eine Alternation in einer nicht-fangenden Untergruppe führt
//      zur Verweigerung — falsch-negativ ist hier billiger als ein
//      verändertes Suchverhalten.)

import Foundation

enum GroupRemoval {
    /// Ergebnis einer erfolgreichen Gruppen-Auflösung.
    struct Result: Equatable {
        /// Pattern ohne die Klammern der gelöschten Gruppe.
        let newPattern: String
        /// Replace-Template mit heruntergeschobenen `$N`-Referenzen
        /// (alle N > gelöschte Nummer → N-1).
        let rewrittenReplacement: String
    }

    /// Löst die Capture Group `number` im Pattern auf.
    /// `nil` = Verweigerung (Gründe siehe Datei-Kopf) — die UI zeigt dann
    /// einen Hinweis statt still ein anderes Pattern zu erzeugen.
    static func remove(group number: Int,
                       pattern: String,
                       tokenization: RegexTokenization,
                       replacement: String) -> Result? {
        guard let group = tokenization.groups.first(where: { $0.number == number }) else {
            return nil
        }

        // Verweigerungs-Grund 1: Replace referenziert $number.
        if references(replacement, group: number) { return nil }

        // Verweigerungs-Grund 2: Quantifier direkt hinter der Gruppe.
        let groupEnd = group.range.location + group.range.length
        let quantifierFollows = tokenization.tokens.contains {
            $0.kind == .quantifier && $0.range.location == groupEnd
        }
        if quantifierFollows { return nil }

        // Verweigerungs-Grund 3: Alternation im Gruppen-Inhalt, die nicht
        // in einer TIEFEREN fangenden Gruppe steckt.
        let innerEnd = group.innerRange.location + group.innerRange.length
        let hasTopLevelAlternation = tokenization.tokens.contains { token in
            guard token.kind == .alternation,
                  token.range.location >= group.innerRange.location,
                  token.range.location < innerEnd else { return false }
            // Liegt das `|` vollständig in einer ANDEREN Gruppe, die
            // ihrerseits komplett im Inhalt unserer Gruppe liegt? Dann
            // schützt deren Klammerung die Semantik.
            let shielded = tokenization.groups.contains { other in
                other.number != number
                    && other.range.location >= group.innerRange.location
                    && other.range.location + other.range.length <= innerEnd
                    && token.range.location >= other.range.location
                    && token.range.location < other.range.location + other.range.length
            }
            return !shielded
        }
        if hasTopLevelAlternation { return nil }

        // Pattern umbauen: Präfix (`(` bzw. `(?<name>`) und Suffix (`)`)
        // der Gruppe entfernen, Inhalt behalten. Alles in UTF-16-Indizes
        // (NSString), passend zu den Token-Ranges.
        let ns = pattern as NSString
        let prefixRange = NSRange(location: group.range.location,
                                  length: group.innerRange.location - group.range.location)
        let suffixRange = NSRange(location: innerEnd,
                                  length: groupEnd - innerEnd)
        var newPattern = ns.replacingCharacters(in: suffixRange, with: "")
        newPattern = (newPattern as NSString).replacingCharacters(in: prefixRange, with: "")

        // Replace-Template: alle Referenzen ÜBER der gelöschten Nummer
        // eins herunterschieben.
        let rewritten = shiftReferencesDown(in: replacement, above: number)

        return Result(newPattern: newPattern, rewrittenReplacement: rewritten)
    }

    /// `true`, wenn das Replace-Template `$number` referenziert.
    /// Berücksichtigt Escapes (`\$` ist KEINE Referenz) und maximale
    /// Ziffernfolgen (`$12` referenziert Gruppe 12, nicht Gruppe 1).
    static func references(_ replacement: String, group number: Int) -> Bool {
        var found = false
        ReplacementReferences.scan(in: replacement) { refNumber, _ in
            if refNumber == number { found = true }
        }
        return found
    }

    /// Schiebt alle `$N`-Referenzen mit N > `above` um eins herunter.
    /// `$0` (ganzer Treffer) und Referenzen ≤ `above` bleiben unverändert.
    static func shiftReferencesDown(in replacement: String, above: Int) -> String {
        ReplacementReferences.rewrite(in: replacement) { number in
            number > above ? number - 1 : nil
        }
    }
}
