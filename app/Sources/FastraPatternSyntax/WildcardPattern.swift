// WildcardPattern.swift
//
// UI-freie Übersetzung der Platzhalter-Suche und -Ersetzung.
// `*, the` / `the *` macht etwa aus „ring, The“ den Text „The ring“.
//
// Suchregeln:
// 1. Ein einzelner `*` wird zur gierigen Fanggruppe `(.+)`: mindestens ein
//    Zeichen innerhalb einer Zeile. Der Aufrufer darf dafür
//    `.dotMatchesLineSeparators` nicht setzen.
// 2. Ein Lauf aus mindestens zwei Sternen wird zu einer Gruppe `([\s\S]+)`
//    und erfasst auch Zeilenumbrüche, unabhängig von den Regex-Optionen.
// 3. Andere Zeichen werden über `escapedPattern` wörtlich behandelt.
//    Folgende Literale begrenzen die gierige Gruppe und gehören nicht zu ihr.
// 4. Literale werden vom Aufrufer per `.caseInsensitive` gesucht;
//    die gewünschte Schreibweise steht im Ersetzungsmuster.
// 5. Mehrere Sternläufe ergeben mehrere Gruppen. Bei mehrdeutiger Aufteilung
//    zeigt die Vorschau das konkrete Ergebnis.
//
// Im Ersetzungsmuster wird jeder Sternlauf zum nächsten `$N`-Verweis;
// auch `**` zählt als ein Verweis. `escapedTemplate` schützt literale `$` und
// Backslashes. Für echte Stern-Literale dient der Schalter „∗ wörtlich“.

import Foundation

/// Übersetzt `*`-Platzhalter-Muster in echte RegEx-Bausteine. Reines
/// Namespacing über ein `enum` ohne Fälle (gleiche Konvention wie
/// `BufferSearch`/`ApplyEngine`) — es gibt keinen Zustand, nur Funktionen.
package enum WildcardPattern {

    /// Das Platzhalter-Zeichen. Als Konstante, damit es nur eine Wahrheit
    /// gibt (Such-Engine, Mini-Schalter und Pillen-UI greifen alle hierauf
    /// zu, statt das Zeichen `*` mehrfach hart zu verdrahten).
    static let wildcard: Character = "*"

    /// Ergebnis der Übersetzung eines Such-Musters.
    package struct Compiled: Equatable {
        /// Fertiges Pattern für `NSRegularExpression(pattern:options:)`.
        /// Enthält für jeden Stern-Lauf eine gierige Gruppe — `(.+)` für
        /// einen Einzelstern, `([\s\S]+)` für `**` (2+ Sterne, mehrzeilig) —
        /// alles andere wörtlich escapt.
        package let regexPattern: String

        /// UTF-16-Offsets (Code-Unit-Indizes) jedes Stern-Laufs im Original-
        /// Suchtext (Offset des ersten Sterns des Laufs). Die Maske platziert
        /// hierüber später die nummerierten Pillen — UTF-16, weil die
        /// Text-Felder (NSRange) genauso zählen.
        let starOffsets: [Int]

        /// Anzahl der Platzhalter-Läufe = Anzahl der Fanggruppen. Direkt aus
        /// den Offsets abgeleitet, damit es keine zweite, abweichende
        /// Zählung geben kann.
        package var starCount: Int { starOffsets.count }
    }

    /// Enthält der String mindestens einen Platzhalter? Gebraucht u.a. vom
    /// kontextuellen Mini-Schalter „`*` wörtlich nehmen" (erscheint nur,
    /// wenn ein `*` im Muster steht) — als Single Source of Truth.
    package static func containsWildcard(_ s: String) -> Bool {
        s.contains(wildcard)
    }

    // MARK: - Such-Seite

    /// Übersetzt ein `*`-Suchmuster in ein RegEx-Pattern.
    ///
    /// Vorgehen: Zeichenweise durchgehen und Stern-Läufe erkennen. Jeder
    /// Lauf wird eine gierige Gruppe — `(.+)` bei einem Einzelstern
    /// (zeilenintern, Semantik #2), `([\s\S]+)` bei `**`/2+ Sternen
    /// (zeilenübergreifend, Semantik #6). Alles andere wird wörtlich
    /// escapt (`escapedPattern`) — nur der Stern wirkt als RegEx.
    ///
    /// Ohne `*` ist das Ergebnis exakt das alte Plain-Text-Verhalten
    /// (`escapedPattern(for:)`) — der Such-Vertrag aus v0.5 ändert sich für
    /// sternlose Eingaben also kein bisschen (das sichert ein Test ab).
    package static func compileFind(_ find: String) -> Compiled {
        // Schnellpfad ohne `*`: identisch zum bisherigen wörtlichen Pfad.
        guard containsWildcard(find) else {
            return Compiled(regexPattern: NSRegularExpression.escapedPattern(for: find),
                            starOffsets: [])
        }

        var pattern = ""
        var literal = ""            // gesammelter Literal-Abschnitt
        var runLength = 0           // Länge des aktuellen Stern-Laufs
        var offsets: [Int] = []     // UTF-16-Offset je Lauf (erster Stern)
        var utf16Position = 0       // läuft in UTF-16-Code-Units mit

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            pattern += NSRegularExpression.escapedPattern(for: literal)
            literal = ""
        }
        func flushRun() {
            guard runLength > 0 else { return }
            // Einzelstern: zeilenintern. 2+ Sterne: auch über Zeilenumbrüche —
            // die \s\S-Klasse matcht jedes Zeichen, unabhängig von den
            // NSRegularExpression-Optionen des Aufrufers.
            pattern += runLength == 1 ? "(.+)" : #"([\s\S]+)"#
            runLength = 0
        }

        for character in find {
            if character == wildcard {
                flushLiteral()
                if runLength == 0 { offsets.append(utf16Position) }
                runLength += 1
            } else {
                flushRun()
                literal.append(character)
            }
            utf16Position += String(character).utf16.count
        }
        flushRun()
        flushLiteral()

        return Compiled(regexPattern: pattern, starOffsets: offsets)
    }

    /// Zählt Stern-Läufe (aufeinanderfolgende Sterne = ein Lauf) — dieselbe
    /// Zählweise wie `compileFind`/`compileReplace`. Gebraucht von der Maske
    /// für den Hinweis „Ersetzen hat mehr ∗ als Suchen".
    package static func starRunCount(_ s: String) -> Int {
        var runs = 0
        var inRun = false
        for character in s {
            if character == wildcard {
                if !inRun { runs += 1; inRun = true }
            } else {
                inRun = false
            }
        }
        return runs
    }

    // MARK: - Ersetzen-Seite

    /// Übersetzt einen Ersetzungstext mit `*`-Platzhaltern in ein
    /// `NSRegularExpression`-Replacement-Template. Das N-te `*` (von links)
    /// wird zur Rückreferenz `$N`; der Text dazwischen wird wörtlich genommen
    /// (`escapedTemplate`, damit ein getipptes `$`/`\` nicht als Backref oder
    /// Escape umgedeutet wird).
    ///
    /// Beispiel: `the *` → `the $1`. Der häufigste Fall (genau ein Stern)
    /// funktioniert damit wortlos.
    ///
    /// Beim Reordnen per Drag&Drop trägt eine Pille ihre Nummer explizit mit:
    /// Die GUI fügt `$N` ein. Wenn der Aufrufer die Zahl der Suchgruppen
    /// mitliefert, bleiben nur gültige `$N`-Verweise als aktive Template-
    /// Syntax erhalten. Andere Dollar-Texte werden weiterhin wörtlich escaped.
    ///
    /// Ohne `*` ist das Ergebnis exakt das alte Plain-Text-Verhalten
    /// (`escapedTemplate(for:)`).
    package static func compileReplace(_ replace: String, captureCount: Int? = nil) -> String {
        var template = ""
        var literal = ""
        var positionalCapture = 1
        var index = replace.startIndex

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            template += NSRegularExpression.escapedTemplate(for: literal)
            literal = ""
        }

        while index < replace.endIndex {
            let character = replace[index]

            if character == wildcard {
                flushLiteral()
                index = replace.index(after: index)
                // Lauf-Regel (Semantik #6): direkt folgende Sterne gehören
                // zum selben Verweis — `**` ist ein `$N`, symmetrisch zur
                // Such-Seite, wo `**` eine Gruppe ist.
                while index < replace.endIndex, replace[index] == wildcard {
                    index = replace.index(after: index)
                }
                // Foundation darf eine folgende wörtliche Ziffer nicht zur
                // Gruppennummer ziehen, auch nicht mit kombinierendem Akzent.
                let next = replace[index...].unicodeScalars.first
                let nextIsDigit = next.map { $0 >= "0" && $0 <= "9" } ?? false
                if let captureCount, positionalCapture > captureCount {
                    // Ein leerer Sternlauf kann die Ziffer direkt hinter
                    // eine vorherige Referenz rücken. Escape hält sie literal.
                    if nextIsDigit { template += "\\" }
                } else {
                    template += captureCount.map {
                        ReplacementReferences.spelling(of: positionalCapture,
                            digits: String(positionalCapture).count,
                            groupCount: $0, nextIsDigit: nextIsDigit)
                    } ?? "$\(positionalCapture)"
                }
                positionalCapture += 1
                continue
            }

            // Eine Pille fügt `$N` ein. Nur Gruppen, die im aktuellen
            // Wildcard-Suchmuster wirklich existieren, dürfen aktiv bleiben;
            // `$5.00` bei zwei Gruppen wird deshalb sicher als Text behandelt.
            if character == "$", let captureCount {
                var digitIndex = replace.index(after: index)
                var digits = ""
                while digitIndex < replace.endIndex {
                    let candidate = replace[digitIndex]
                    guard candidate.isASCII, candidate.isNumber else { break }
                    digits.append(candidate)
                    digitIndex = replace.index(after: digitIndex)
                }

                if let referencedGroup = Int(digits),
                   referencedGroup > 0,
                   referencedGroup <= captureCount {
                    flushLiteral()
                    template += "$\(referencedGroup)"
                    index = digitIndex
                    continue
                }
            }

            literal.append(character)
            index = replace.index(after: index)
        }

        flushLiteral()
        return template
    }

}
