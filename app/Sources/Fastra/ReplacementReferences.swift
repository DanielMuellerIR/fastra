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
