// Gemeinsame Referenzerkennung für das Einfügen und Entfernen von Gruppen.
// Beide Aktionen müssen Backslashes und Gruppennummern gleich behandeln.

import Foundation

enum ReplacementReferences {
    /// Ersetzt nur ausdrücklich geänderte Referenzen. `nil` erhält die
    /// ursprüngliche Schreibweise; sonstiger Text bleibt ebenfalls erhalten.
    static func rewrite(in replacement: String, transform: (Int) -> Int?) -> String {
        var result = ""
        var lastEnd = replacement.startIndex
        scan(in: replacement) { number, range in
            result += replacement[lastEnd..<range.lowerBound]
            if let changed = transform(number) {
                result += "$\(changed)"
            } else {
                result += replacement[range]
            }
            lastEnd = range.upperBound
        }
        result += replacement[lastEnd...]
        return result
    }

    /// Läuft über das Replace-Template und ruft `handler` für jede echte
    /// `$N`-Referenz auf (Range inklusive `$`). Escape-Regeln des
    /// NSRegularExpression-Templates: `\$` ist ein literales Dollar,
    /// `\\` ein literaler Backslash.
    static func scan(in replacement: String,
                     _ handler: (Int, Range<String.Index>) -> Void) {
        var index = replacement.startIndex
        var escaped = false
        while index < replacement.endIndex {
            let ch = replacement[index]
            if escaped {
                // Das Zeichen nach einem Backslash ist immer literal.
                escaped = false
                index = replacement.index(after: index)
                continue
            }
            if ch == "\\" {
                escaped = true
                index = replacement.index(after: index)
                continue
            }
            if ch == "$" {
                // Maximale Ziffernfolge nach dem $ einsammeln.
                var digitsEnd = replacement.index(after: index)
                while digitsEnd < replacement.endIndex,
                      replacement[digitsEnd].isNumber {
                    digitsEnd = replacement.index(after: digitsEnd)
                }
                if digitsEnd > replacement.index(after: index),
                   let number = Int(replacement[replacement.index(after: index)..<digitsEnd]) {
                    handler(number, index..<digitsEnd)
                    index = digitsEnd
                    continue
                }
            }
            index = replacement.index(after: index)
        }
    }
}
