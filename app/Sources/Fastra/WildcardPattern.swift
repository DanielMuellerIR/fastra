// WildcardPattern.swift
//
// Feature J — Platzhalter-Suche `*` ohne RegEx-Kenntnisse (v0.10).
//
// REINE Übersetzungs-Logik, bewusst ohne jeden UI- oder Workspace-Bezug,
// damit sie vollständig per Unit-Test absicherbar ist (genauso getrennt wie
// `BufferSearch`/`ApplyEngine`). Diese Datei verdrahtet noch NICHTS in die
// Such-Engines — das ist Schritt 2 („Plain-Text-Vertrag umstellen"). Hier
// entsteht nur der Baustein, den beide Engines später benutzen werden.
//
// Die Idee in einem Satz:
//   Ein Stern `*` in der Suche steht für „beliebiger Text innerhalb einer
//   Zeile". Aus `*, the` (suchen) / `the *` (ersetzen) wird so aus
//   „ring, The" ein „The ring" — ganz ohne dass der Nutzer eine
//   reguläre Ausdruck-Syntax kennen muss.
//
// Wie das technisch passiert:
//   * In der SUCHE wird jedes `*` zu einer GIERIGEN Fanggruppe `(.+)`.
//     Alles andere wird wörtlich genommen (über `escapedPattern`, damit
//     Sonderzeichen wie `.` oder `(` nicht versehentlich als RegEx wirken).
//   * Im ERSETZEN wird das N-te `*` zur Rückreferenz `$N` (`$1`, `$2`, …).
//     Der umgebende Text wird wörtlich genommen (über `escapedTemplate`,
//     damit ein getipptes `$` oder `\` nicht als Backref/Escape verrutscht).
//
// Bewusste Semantik-Entscheidungen (final mit Daniel, 2026-06-14 —
// siehe ROADMAP.md → Funktionsumfang J):
//
//   1. GIERIG (`.+`, nicht `.+?`): Der Stern nimmt so VIEL wie möglich und
//      verankert am LETZTEN Vorkommen des nachfolgenden Literals. Genau das
//      will der Artikel-am-Ende-Fall: „Hello, There, The" + Muster `*, the`
//      ergibt `*` = „Hello, There" (nicht nur „Hello").
//   2. NUR INNERHALB EINER ZEILE: `*` wird `(.+)`. Der Punkt `.` matcht von
//      Haus aus KEIN `\n` — solange der Aufrufer beim Bau der
//      `NSRegularExpression` die Option `.dotMatchesLineSeparators` NICHT
//      setzt, springt ein `*` also nie über einen Zeilenumbruch. Diese Datei
//      liefert nur das Pattern; die Optionen setzt der Aufrufer (Schritt 2).
//   3. Der Literal-Teil hinter dem `*` ist der ANKER und wird nie vom `*`
//      mitgefangen — das ergibt sich automatisch daraus, dass die gierige
//      Gruppe vor dem Literal stoppen MUSS, damit das Literal noch matcht.
//   4. Der Literal-Teil wird (vom Aufrufer) per `.caseInsensitive` gesucht;
//      die gewünschte Schreibweise schreibt der Nutzer im Ersetzen-Feld.
//   5. Mehrere `*` → mehrere gierige Gruppen, getrennt durch die Literale
//      dazwischen. Die Aufteilung ist bei mehreren `*` inhärent mehrdeutig —
//      die Live-Vorschau in der Maske ist das Sicherheitsnetz.
//   6. DOPPELSTERN `**` (v1.2, Daniel 2026-07-10): ein Lauf aus ZWEI ODER
//      MEHR direkt benachbarten Sternen ist EINE Fanggruppe, die auch über
//      Zeilenumbrüche fängt (`([\s\S]+)` — die Klasse umgeht die Punkt-
//      Semantik, egal welche Optionen der Aufrufer setzt). Vorher war `**`
//      ein sinnfreies `(.+)(.+)`; echte Doppelstern-LITERALE (z.B.
//      Markdown-Fett) sucht man weiterhin über den Schalter „∗ wörtlich".
//      Auf der Ersetzen-Seite gilt dieselbe Lauf-Regel: `**` ist EIN
//      Verweis, nicht zwei.

import Foundation

/// Übersetzt `*`-Platzhalter-Muster in echte RegEx-Bausteine. Reines
/// Namespacing über ein `enum` ohne Fälle (gleiche Konvention wie
/// `BufferSearch`/`ApplyEngine`) — es gibt keinen Zustand, nur Funktionen.
enum WildcardPattern {

    /// Das Platzhalter-Zeichen. Als Konstante, damit es nur EINE Wahrheit
    /// gibt (Such-Engine, Mini-Schalter und Pillen-UI greifen alle hierauf
    /// zu, statt das Zeichen `*` mehrfach hart zu verdrahten).
    static let wildcard: Character = "*"

    /// Ergebnis der Übersetzung eines Such-Musters.
    struct Compiled: Equatable {
        /// Fertiges Pattern für `NSRegularExpression(pattern:options:)`.
        /// Enthält für jeden Stern-LAUF eine gierige Gruppe — `(.+)` für
        /// einen Einzelstern, `([\s\S]+)` für `**` (2+ Sterne, mehrzeilig) —
        /// alles andere wörtlich escapt.
        let regexPattern: String

        /// UTF-16-Offsets (Code-Unit-Indizes) jedes Stern-LAUFS im ORIGINAL-
        /// Suchtext (Offset des ersten Sterns des Laufs). Die Maske platziert
        /// hierüber später die nummerierten Pillen — UTF-16, weil die
        /// Text-Felder (NSRange) genauso zählen.
        let starOffsets: [Int]

        /// Anzahl der Platzhalter-Läufe = Anzahl der Fanggruppen. Direkt aus
        /// den Offsets abgeleitet, damit es keine zweite, abweichende
        /// Zählung geben kann.
        var starCount: Int { starOffsets.count }
    }

    /// Enthält der String mindestens einen Platzhalter? Gebraucht u.a. vom
    /// kontextuellen Mini-Schalter „`*` wörtlich nehmen" (erscheint nur,
    /// wenn ein `*` im Muster steht) — als Single Source of Truth.
    static func containsWildcard(_ s: String) -> Bool {
        s.contains(wildcard)
    }

    // MARK: - Such-Seite

    /// Übersetzt ein `*`-Suchmuster in ein RegEx-Pattern.
    ///
    /// Vorgehen: Zeichenweise durchgehen und Stern-LÄUFE erkennen. Jeder
    /// Lauf wird EINE gierige Gruppe — `(.+)` bei einem Einzelstern
    /// (zeilenintern, Semantik #2), `([\s\S]+)` bei `**`/2+ Sternen
    /// (zeilenübergreifend, Semantik #6). Alles andere wird wörtlich
    /// escapt (`escapedPattern`) — nur der Stern wirkt als RegEx.
    ///
    /// OHNE `*` ist das Ergebnis exakt das alte Plain-Text-Verhalten
    /// (`escapedPattern(for:)`) — der Such-Vertrag aus v0.5 ändert sich für
    /// sternlose Eingaben also kein bisschen (das sichert ein Test ab).
    static func compileFind(_ find: String) -> Compiled {
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
            // die \s\S-Klasse matcht JEDES Zeichen, unabhängig von den
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

    /// Zählt Stern-LÄUFE (aufeinanderfolgende Sterne = ein Lauf) — dieselbe
    /// Zählweise wie `compileFind`/`compileReplace`. Gebraucht von der Maske
    /// für den Hinweis „Ersetzen hat mehr ∗ als Suchen".
    static func starRunCount(_ s: String) -> Int {
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
    /// Beim REORDNEN per Drag&Drop trägt eine Pille ihre Nummer explizit mit:
    /// Die GUI fügt `$N` ein. Wenn der Aufrufer die Zahl der Suchgruppen
    /// mitliefert, bleiben nur gültige `$N`-Verweise als aktive Template-
    /// Syntax erhalten. Andere Dollar-Texte werden weiterhin wörtlich escaped.
    ///
    /// OHNE `*` ist das Ergebnis exakt das alte Plain-Text-Verhalten
    /// (`escapedTemplate(for:)`).
    static func compileReplace(_ replace: String, captureCount: Int? = nil) -> String {
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
                template += "$\(positionalCapture)"
                positionalCapture += 1
                index = replace.index(after: index)
                // Lauf-Regel (Semantik #6): direkt folgende Sterne gehören
                // zum selben Verweis — `**` ist EIN `$N`, symmetrisch zur
                // Such-Seite, wo `**` EINE Gruppe ist.
                while index < replace.endIndex, replace[index] == wildcard {
                    index = replace.index(after: index)
                }
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
