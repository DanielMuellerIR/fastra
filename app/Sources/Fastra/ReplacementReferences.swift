// Gemeinsame Referenzerkennung für das Einfügen und Entfernen von Gruppen.
// Beide Aktionen müssen Backslashes und Gruppennummern gleich behandeln —
// und zwar genau so, wie NSRegularExpression das Template später wirklich
// liest. Zwei Regeln von Foundation sind dabei nicht offensichtlich:
//
//   1. Nach dem `$` liest Foundation höchstens so viele Ziffern, wie die
//      höchste mögliche Gruppennummer hat. Bei zwei Gruppen ist `$12`
//      deshalb Gruppe 1 gefolgt vom Literal „2", erst ab zehn Gruppen ist
//      es Gruppe 12. Belegt gegen echte Ersetzungen (siehe
//      ReplacementReferencesTests).
//   2. Nur ASCII-Ziffern zählen. `$٠` (arabisch-indische Null) bleibt
//      literaler Text, und ein kombinierender Akzent hinter der Ziffer
//      gehört nicht zur Nummer. Deshalb läuft der Scanner über einzelne
//      Unicode-Skalare und nicht über Swift-`Character` (die fassen Ziffer
//      und Akzent zu einem sichtbaren Zeichen zusammen).

import Foundation

enum ReplacementReferences {
    /// Wie viele Ziffern Foundation nach einem `$` höchstens als
    /// Gruppennummer liest: so viele, wie `groupCount` selbst hat.
    /// Ohne Gruppen bleibt es bei einer Ziffer.
    static func maxReferenceDigits(forGroupCount groupCount: Int) -> Int {
        var digits = 1
        var rest = max(groupCount, 0) / 10
        while rest > 0 {
            digits += 1
            rest /= 10
        }
        return digits
    }

    /// Ersetzt nur ausdrücklich geänderte Referenzen. `nil` erhält die
    /// ursprüngliche Schreibweise, solange Foundation sie auch nach der
    /// geänderten Gruppenanzahl noch als dieselbe Nummer liest; sonstiger
    /// Text bleibt unangetastet.
    ///
    /// - Parameters:
    ///   - groupCount: Anzahl fangender Gruppen VOR der Änderung. Sie
    ///     bestimmt, wie das vorhandene Template gelesen wird.
    ///   - newGroupCount: Anzahl DANACH. Sie bestimmt, wie geschrieben
    ///     werden muss — beim Sprung von 9 auf 10 Gruppen wächst das
    ///     Ziffernbudget, und eine literale Ziffer hinter der Referenz
    ///     würde sonst plötzlich zur Gruppennummer gehören.
    static func rewrite(in replacement: String,
                        groupCount: Int,
                        newGroupCount: Int,
                        transform: (Int) -> Int?) -> String {
        let scalars = replacement.unicodeScalars
        var result = String.UnicodeScalarView()
        var lastEnd = scalars.startIndex
        scan(in: replacement, groupCount: groupCount) { number, range in
            result.append(contentsOf: scalars[lastEnd..<range.lowerBound])
            lastEnd = range.upperBound

            // Bisherige Ziffernzahl (ohne das `$`) — führende Nullen sollen
            // erhalten bleiben, wo sie weiterhin dasselbe bedeuten.
            let oldDigits = scalars.distance(from: scalars.index(after: range.lowerBound),
                                             to: range.upperBound)
            // Folgt direkt eine ASCII-Ziffer? Dann darf die neue
            // Schreibweise sie nicht mit einsammeln.
            let nextIsDigit = range.upperBound < scalars.endIndex
                && isASCIIDigit(scalars[range.upperBound])

            var target = number
            var digits = oldDigits
            // Eine negative Zielnummer wäre keine gültige Gruppe; dann
            // bleibt die bisherige Referenz stehen.
            if let changed = transform(number), changed >= 0 {
                target = changed
                digits = String(changed).count
            }
            let text = spelling(of: target,
                                digits: digits,
                                groupCount: newGroupCount,
                                nextIsDigit: nextIsDigit)
            result.append(contentsOf: text.unicodeScalars)
        }
        result.append(contentsOf: scalars[lastEnd...])
        return String(result)
    }

    /// Läuft über das Replace-Template und ruft `handler` für jede echte
    /// `$N`-Referenz auf (Range inklusive `$`, in Unicode-Skalaren).
    /// Escape-Regeln des NSRegularExpression-Templates: `\$` ist ein
    /// literales Dollar, `\\` ein literaler Backslash.
    ///
    /// - Parameter groupCount: Anzahl fangender Gruppen im zugehörigen
    ///   Suchausdruck; sie entscheidet, wie viele Ziffern zur Nummer
    ///   gehören (siehe `maxReferenceDigits(forGroupCount:)`).
    static func scan(in replacement: String,
                     groupCount: Int,
                     _ handler: (Int, Range<String.Index>) -> Void) {
        let scalars = replacement.unicodeScalars
        let budget = maxReferenceDigits(forGroupCount: groupCount)
        var index = scalars.startIndex
        while index < scalars.endIndex {
            if scalars[index] == "\\" {
                // Das Zeichen nach einem Backslash ist immer literal.
                index = scalars.index(after: index)
                if index < scalars.endIndex {
                    index = scalars.index(after: index)
                }
                continue
            }
            if scalars[index] == "$" {
                var digitsEnd = scalars.index(after: index)
                var digits = ""
                while digitsEnd < scalars.endIndex,
                      digits.count < budget,
                      isASCIIDigit(scalars[digitsEnd]) {
                    digits.unicodeScalars.append(scalars[digitsEnd])
                    digitsEnd = scalars.index(after: digitsEnd)
                }
                if let number = Int(digits) {
                    handler(number, index..<digitsEnd)
                    index = digitsEnd
                    continue
                }
            }
            index = scalars.index(after: index)
        }
    }

    /// Schreibt `number` mit mindestens `digits` Ziffern. Mehr als das
    /// Ziffernbudget geht nicht — Foundation würde die überzähligen Ziffern
    /// als Literal lesen. Folgt direkt eine Ziffer, wird bis zum vollen
    /// Budget mit Nullen aufgefüllt: `$1` + „2" wird bei zehn Gruppen zu
    /// `$012`, sonst läse Foundation daraus Gruppe 12.
    private static func spelling(of number: Int,
                                 digits: Int,
                                 groupCount: Int,
                                 nextIsDigit: Bool) -> String {
        let plain = String(number)
        let budget = maxReferenceDigits(forGroupCount: groupCount)
        var width = max(plain.count, digits)
        if width > budget {
            width = max(plain.count, budget)
        }
        if nextIsDigit, width < budget {
            width = budget
        }
        let padding = String(repeating: "0", count: max(width - plain.count, 0))
        return "$" + padding + plain
    }

    /// Foundation zählt nur ASCII-Ziffern zur Gruppennummer.
    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar >= "0" && scalar <= "9"
    }
}

// MARK: - Umnummerierung als EINE Beschreibung

extension ReplacementReferences {
    /// Wie eine Gruppenaktion die Nummerierung verschiebt.
    ///
    /// Bewusst EIN Wert für beides — das Umschreiben und die Gegenprüfung.
    /// Zwei getrennte Fassungen derselben Regel könnten auseinanderlaufen, und
    /// die Prüfung bestätigte dann eine andere Zusage als die, die tatsächlich
    /// geschrieben wurde.
    struct Renumbering {
        /// Fangende Gruppen VOR der Aktion. Sie bestimmt, wie das vorhandene
        /// Template gelesen wird.
        let groupCount: Int
        /// Fangende Gruppen DANACH. Sie bestimmt, wie geschrieben werden muss.
        let newGroupCount: Int
        /// Wohin eine VORHANDENE Gruppennummer (`0…groupCount`) wandert.
        /// `$0` ist immer der ganze Treffer und bleibt `0`.
        let move: (Int) -> Int
    }

    /// Schreibt das Template um. Reine Umschreibung ohne Gegenprüfung — für
    /// den Produktpfad ist `rewritten(_:by:)` zuständig.
    static func rewriteText(_ replacement: String,
                            by renumbering: Renumbering) -> String {
        rewrite(in: replacement,
                groupCount: renumbering.groupCount,
                newGroupCount: renumbering.newGroupCount) { number in
            guard number > renumbering.groupCount else {
                // Vorhandene Gruppe: Sie wandert mit. Bleibt die Nummer
                // gleich, gibt `nil` die ursprüngliche SCHREIBWEISE frei —
                // eine führende Null soll dann erhalten bleiben.
                let moved = renumbering.move(number)
                return moved == number ? nil : moved
            }
            return dodgingNumber(for: number, newGroupCount: renumbering.newGroupCount)
        }
    }

    /// Schreibt das Template um UND prüft am Ergebnis nach. `nil` bedeutet:
    /// Diese Eingabe lässt sich nicht gleichbedeutend abbilden — der Aufrufer
    /// muss die Aktion verweigern, statt still anderen Text zu erzeugen.
    static func rewritten(_ replacement: String,
                          by renumbering: Renumbering) -> String? {
        let text = rewriteText(replacement, by: renumbering)
        guard rewriteKeepsMeaning(original: replacement,
                                  groupCount: renumbering.groupCount,
                                  rewritten: text,
                                  newGroupCount: renumbering.newGroupCount,
                                  mapping: renumbering.move) else { return nil }
        return text
    }

    /// Eine Referenz, die vor der Aktion ins Leere zeigt, muss das auch danach
    /// tun. Meist bleibt sie dafür einfach stehen; nur wenn die neue
    /// Gruppenzahl sie einholt, braucht sie eine Ausweichnummer.
    ///
    /// `nil` heißt „unverändert lassen". Passt keine Ausweichnummer ins
    /// Ziffernbudget — bei neun Gruppen gibt es über der Neun keine einstellige
    /// Nummer mehr —, bleibt die Referenz ebenfalls stehen; die Gegenprüfung in
    /// `rewritten(_:by:)` verweigert die Aktion dann.
    private static func dodgingNumber(for number: Int, newGroupCount: Int) -> Int? {
        guard number <= newGroupCount else { return nil }
        let candidate = newGroupCount + 1
        guard String(candidate).count
                <= maxReferenceDigits(forGroupCount: newGroupCount) else { return nil }
        return candidate
    }
}

// MARK: - Gleichbedeutend umgeschrieben?

extension ReplacementReferences {
    /// Wie Foundation ein Replace-Template liest: abwechselnd wörtlicher Text
    /// und Gruppenreferenzen. Eine Referenz auf eine nicht vorhandene Gruppe
    /// liefert leeren Text (an echten Ersetzungen gemessen, siehe
    /// ReplacementReferencesTests) und zählt deshalb als leeres Literal.
    enum Reading: Equatable {
        case literal(String)
        case group(Int)
    }

    /// Zerlegt `template` so, wie es mit `groupCount` fangenden Gruppen
    /// gelesen wird. Der wörtliche Text bleibt in seiner Quellschreibweise
    /// (inklusive `\$`); das genügt, weil verglichen wird und beide Seiten
    /// dieselbe Schreibweise behalten.
    static func reading(of template: String, groupCount: Int) -> [Reading] {
        let scalars = template.unicodeScalars
        var segments: [Reading] = []
        var lastEnd = scalars.startIndex
        scan(in: template, groupCount: groupCount) { number, range in
            segments.append(.literal(String(String.UnicodeScalarView(scalars[lastEnd..<range.lowerBound]))))
            // Zeigt die Nummer ins Leere, trägt sie nichts zum Ergebnis bei.
            segments.append(number > groupCount ? .literal("") : .group(number))
            lastEnd = range.upperBound
        }
        segments.append(.literal(String(String.UnicodeScalarView(scalars[lastEnd...]))))
        return normalized(segments)
    }

    /// Fasst benachbarte Literale zusammen und wirft leere weg — sonst gälten
    /// zwei Schreibweisen desselben Ergebnisses als verschieden.
    private static func normalized(_ segments: [Reading]) -> [Reading] {
        var result: [Reading] = []
        for segment in segments {
            guard case .literal(let text) = segment else {
                result.append(segment)
                continue
            }
            if text.isEmpty { continue }
            if case .literal(let previous)? = result.last {
                result[result.count - 1] = .literal(previous + text)
            } else {
                result.append(.literal(text))
            }
        }
        return result
    }

    /// Erzeugt das umgeschriebene Template GENAU denselben Text wie vorher —
    /// nur eben aus den umnummerierten Gruppen?
    ///
    /// Die Prüfung misst am ERGEBNIS statt am Ziffernbudget. Das schließt zwei
    /// Fallen zugleich: eine ins Leere zeigende Referenz, die nach der Änderung
    /// plötzlich auf eine echte Gruppe fällt (`$3` bei zwei Gruppen, danach
    /// drei), und eine Schreibweise, die unter dem neuen, kleineren
    /// Ziffernbudget anders gelesen wird (`$11` bei zehn Gruppen, danach neun:
    /// Foundation liest daraus Gruppe 1 plus das Literal „1").
    ///
    /// - Parameter mapping: Wohin eine VORHANDENE Gruppennummer wandert.
    static func rewriteKeepsMeaning(original: String, groupCount: Int,
                                    rewritten: String, newGroupCount: Int,
                                    mapping: (Int) -> Int) -> Bool {
        let expected = normalized(reading(of: original, groupCount: groupCount).map { segment in
            guard case .group(let number) = segment else { return segment }
            let moved = mapping(number)
            return moved > newGroupCount ? .literal("") : .group(moved)
        })
        return expected == reading(of: rewritten, groupCount: newGroupCount)
    }
}
