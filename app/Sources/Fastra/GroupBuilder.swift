// GroupBuilder.swift
//
// Geführte Capture-Group-Definition (Phase 3, Suchmasken-Konzept §3+§4).
//
// PRODUKT-IDEE (für Leser ohne RegEx-Hintergrund):
// In der Suchmaske sieht der Nutzer GENAU EINEN Treffer im Detail-Bereich —
// nur den nackten Match-Text (z.B. „anna@test.de"), keinen RegEx. Er markiert
// dort mit der Maus eine Teil-Stelle (z.B. „de") und klickt „Gruppe
// definieren". Diese Datei übersetzt diese Selektion in eine `(...)`-Capture-
// Group im DAHINTERLIEGENDEN Suchausdruck — ohne dass der Nutzer je eine
// Klammer tippt. Der Nutzer braucht NULL RegEx-Wissen, und ein kaputtes
// Pattern ist konstruktiv ausgeschlossen, weil die Selektion immer auf
// vollständige Token-Grenzen „snappt" (§4 Token-Schutz).
//
// ─────────────────────────────────────────────────────────────────────────
// ALGORITHMUS — „instrumentiertes Re-Matching"
//
// Das Kernproblem: Wir haben den Match-TEXT und das PATTERN, aber NICHT die
// Zuordnung, welcher Pattern-Teil welches Stück des Match-Textes erzeugt hat.
// (`\w+` kann „anna" ODER „test" sein.) Diese Zuordnung gewinnen wir, indem
// wir ein zweites, „instrumentiertes" Pattern bauen, in dem jede Pattern-
// Einheit in eine eigene Capture-Group gehüllt ist, und es erneut gegen den
// Match-Text laufen lassen. Aus dem Match lesen wir pro Einheit die Range im
// Match-Text ab. Damit wird aus der freien Maus-Selektion eine eindeutige
// Folge ganzer Pattern-Einheiten — und daraus die neue `(...)`-Gruppe.
//
//   Schritt 1  SNAP-UNITS bilden  — Pattern in Top-Level-Einheiten zerlegen.
//   Schritt 2  INSTRUMENTIEREN    — jede Einheit in `(...)` hüllen, Buch führen.
//   Schritt 3  RE-MATCH           — Instrument gegen Match-Text, Ranges lesen.
//   Schritt 4  SNAP               — Selektion auf minimale Unit-Folge runden.
//   Schritt 5  VORSCHLAG          — `(...)` ins Original-Pattern einsetzen,
//                                    neue Gruppennummer + `$N`-Rewrite.
//
// ─────────────────────────────────────────────────────────────────────────
// v1.0-EINSCHRÄNKUNGEN (bewusst, dokumentiert):
//
// * TOP-LEVEL-ALTERNATION (`a|b` außerhalb aller Gruppen): Das gesamte
//   Pattern wird EINE einzige Unit — es kann in v1.0 nur als Ganzes gruppiert
//   werden. Grund: bei `a|b` matcht je Durchlauf nur EIN Zweig; eine pro-Zweig-
//   Instrumentierung würde inkonsistente Einheiten erzeugen. Alternation
//   INNERHALB einer Gruppe (`(a|b)c`) ist unkritisch — die Gruppe bleibt eine
//   Unit.
// * wholeWord / Kontext-Anker: `buildRegex` umschließt das Pattern ggf. mit
//   `\b…\b`. GroupBuilder arbeitet aber NUR mit dem rohen Pattern (ohne diese
//   Hülle) — der Match-Text enthält die `\b`-Anker ohnehin nicht (Anker sind
//   nullbreit). Falls das Re-Matching wider Erwarten scheitert (z.B. weil der
//   Match-Text durch Kontext-Anker im Original gar nicht eigenständig matcht),
//   geben wir `nil` zurück; die UI zeigt dann „Selektion nicht zuordenbar"
//   statt ein falsches Pattern zu bauen.
// * Alle Ranges sind UTF-16-`NSRange` — dieselbe Einheit wie NSRegularExpression
//   und AppKit (NSAttributedString). Emoji (Surrogatpaare) zählen als 2
//   UTF-16-Code-Units; das ist konsistent durchgezogen.

import Foundation

enum GroupBuilder {

    // MARK: - Öffentliche Datentypen

    /// Eine Top-Level-Einheit des Patterns plus ihr Beitrag im Match-Text.
    /// Wird auch fürs UI gebraucht (Snap-Visualisierung der Token-Grenzen).
    struct SnapUnit: Equatable {
        /// Bereich dieser Einheit im ORIGINAL-Pattern (UTF-16).
        let patternRange: NSRange
        /// Beitrag dieser Einheit im Match-Text (UTF-16). `nil`, wenn die
        /// Einheit nichts beigetragen hat — entweder weil sie nullbreit ist
        /// (Anker) oder weil ein optionaler Quantifier (`u?`) sie auf 0
        /// Treffer reduziert hat. Über solche Einheiten snappt die Selektion
        /// hinweg, als wären sie nicht da.
        let matchRange: NSRange?
        /// `true`, wenn diese Einheit GENAU einer bestehenden fangenden
        /// Top-Level-Gruppe entspricht (ohne folgenden Quantifier).
        let isExistingGroup: Bool
        /// 1-basierte Gruppennummer (NSRegularExpression-Zählung), falls
        /// `isExistingGroup`. Sonst `nil`.
        let existingGroupNumber: Int?
        /// `true` für Anker (`^`, `$`, `\b`, `\B`) — nullbreit, kein
        /// Match-Beitrag, nicht gruppierbar.
        let isZeroWidth: Bool
    }

    /// Vorschlag, was beim Klick auf „Gruppe definieren" passieren soll.
    struct Proposal: Equatable {
        /// Auf Token-Grenzen gerundete Selektion im Match-Text (für die
        /// UI-Markierung „so wird wirklich gruppiert").
        let snappedMatchRange: NSRange
        /// Das neue Pattern mit eingefügter `(...)`-Gruppe. Bei
        /// `isAlreadyGroup` identisch zum alten Pattern.
        let newPattern: String
        /// Nummer der neuen (oder bei `isAlreadyGroup`: der getroffenen
        /// bestehenden) Gruppe.
        let newGroupNumber: Int
        /// Der Replacement-String mit nach oben verschobenen `$N`-Backrefs.
        let rewrittenReplacement: String
        /// `true`, wenn die Selektion exakt eine bestehende Gruppe trifft —
        /// dann ist nichts zu tun, die UI kann das melden („ist schon G2").
        let isAlreadyGroup: Bool
    }

    // MARK: - Öffentliche API

    /// Zerlegt das Pattern in Snap-Units und reichert sie mit ihren Match-
    /// Beiträgen an (Schritte 1–3). Auch fürs UI nutzbar.
    ///
    /// - Returns: `nil`, wenn das Pattern ungültig ist oder das instrumentierte
    ///   Re-Matching scheitert (siehe v1.0-Einschränkungen am Dateikopf).
    static func units(pattern: String,
                      tokenization: RegexTokenization,
                      matchText: String,
                      caseSensitive: Bool) -> [SnapUnit]? {
        // Schritt 1: rohe Einheiten (ohne Match-Beiträge) bilden.
        guard let raw = buildRawUnits(pattern: pattern, tokenization: tokenization) else {
            return nil
        }
        // Schritte 2+3: instrumentieren + re-matchen → Match-Beiträge füllen.
        return attachMatchRanges(raw: raw,
                                 pattern: pattern,
                                 matchText: matchText,
                                 caseSensitive: caseSensitive)
    }

    /// Kernfunktion: aus einer Nutzer-Selektion im Match-Text einen Gruppen-
    /// Vorschlag bauen (Schritte 1–5).
    ///
    /// - Parameters:
    ///   - selection: Markierter Bereich im Match-Text (UTF-16). Länge 0 =
    ///     reine Cursor-Position.
    /// - Returns: `nil`, wenn die Selektion nicht zuordenbar ist (kein
    ///   Unit-Beitrag schneidet sie, oder Re-Matching scheitert).
    static func propose(selection: NSRange,
                        pattern: String,
                        tokenization: RegexTokenization,
                        matchText: String,
                        replacement: String,
                        caseSensitive: Bool) -> Proposal? {
        guard let snapUnits = units(pattern: pattern,
                                    tokenization: tokenization,
                                    matchText: matchText,
                                    caseSensitive: caseSensitive) else {
            return nil
        }

        // Schritt 4: Selektion auf die minimale Unit-Folge [i…j] snappen.
        guard let (i, j) = snapRange(selection: selection, units: snapUnits) else {
            return nil
        }

        // Snapped-Range = Vereinigung der Match-Beiträge von Unit i…j.
        // (Beide haben garantiert einen Beitrag — snapRange wählt nur Units
        // MIT Beitrag als Endpunkte.)
        let snappedMatchRange = unionMatchRange(units: snapUnits, from: i, to: j)

        // Schritt 5a: Trifft [i…j] EXAKT eine bestehende fangende Gruppe?
        // Dann ist nichts einzufügen — wir melden die bestehende Gruppe.
        if i == j, snapUnits[i].isExistingGroup, let n = snapUnits[i].existingGroupNumber {
            return Proposal(snappedMatchRange: snappedMatchRange,
                            newPattern: pattern,
                            newGroupNumber: n,
                            rewrittenReplacement: replacement,
                            isAlreadyGroup: true)
        }

        // Schritt 5b: `(` vor Unit i und `)` nach Unit j ins Pattern einsetzen.
        // Wir arbeiten in Pattern-Koordinaten (UTF-16) über die Unit-Ranges.
        let openAt = snapUnits[i].patternRange.location
        let closeAt = snapUnits[j].patternRange.location + snapUnits[j].patternRange.length

        let newPattern = insertParentheses(in: pattern, openAt: openAt, closeAt: closeAt)

        // Neue Gruppennummer = 1 + Anzahl fangender Gruppen, deren öffnende
        // Klammer im ALTEN Pattern VOR `openAt` liegt. (Alle bestehenden
        // Gruppen, die VOLLSTÄNDIG in [i…j] liegen, öffnen NACH `openAt` und
        // verschieben sich daher um +1 — siehe Replace-Rewrite.)
        let groupsBefore = tokenization.groups.filter { $0.range.location < openAt }.count
        let newGroupNumber = groupsBefore + 1

        // Schritt 5c: Replace-Template anheben — alle `$N` mit N >= neuer
        // Nummer werden N+1, weil ab hier eine fangende Klammer dazukommt.
        let rewritten = shiftBackreferencesUp(in: replacement, atOrAbove: newGroupNumber)

        return Proposal(snappedMatchRange: snappedMatchRange,
                        newPattern: newPattern,
                        newGroupNumber: newGroupNumber,
                        rewrittenReplacement: rewritten,
                        isAlreadyGroup: false)
    }

    // MARK: - Schritt 5c (pur + separat testbar): $N-Verschiebung

    /// Hebt im Replacement-Template alle `$N`-Backrefs mit `N >= atOrAbove`
    /// um genau 1 an. Regeln:
    /// * `$0` (der ganze Match) bleibt IMMER unverändert.
    /// * `\$` ist ein escapter Dollar (literaler `$`) und wird NICHT als
    ///   Backref gewertet — bleibt unangetastet.
    /// * `$12` ist Gruppe 12 (gesamte Ziffernfolge), NICHT `$1` + „2".
    ///
    /// - Parameter atOrAbove: ab dieser Gruppennummer (inkl.) wird verschoben.
    // codereview-ok: `\$`-Escaping wird hier (Zeilenanfang der while-Schleife) UND in GroupRemoval.scanReferences äquivalent respektiert — literales $N wird nicht verschoben (2026-07-06)
    static func shiftBackreferencesUp(in replacement: String, atOrAbove: Int) -> String {
        // Wir gehen Skalar für Skalar durch und bauen das Ergebnis neu auf.
        // `chars` als Array, damit wir mit Indizes vor-/zurückschauen können.
        let chars = Array(replacement)
        var out = String()
        out.reserveCapacity(replacement.count)

        var k = 0
        while k < chars.count {
            let c = chars[k]

            // Escapter Dollar `\$`: Backslash + Dollar wörtlich übernehmen,
            // KEIN Backref. (Ein einzelnes `\` vor irgendwas anderem ebenfalls
            // unverändert weiterreichen — wir interpretieren nur `\$`.)
            if c == "\\", k + 1 < chars.count, chars[k + 1] == "$" {
                out.append("\\")
                out.append("$")
                k += 2
                continue
            }

            // Kandidat für einen Backref `$<Ziffern>`.
            if c == "$", k + 1 < chars.count, chars[k + 1].isNumber {
                // Gesamte folgende Ziffernfolge einsammeln (greedy) —
                // `$12` ist Gruppe 12, nicht `$1`+„2".
                var d = k + 1
                var digits = String()
                while d < chars.count, chars[d].isNumber {
                    digits.append(chars[d])
                    d += 1
                }
                let n = Int(digits) ?? 0
                // $0 bleibt; sonst ggf. anheben.
                let shifted = (n != 0 && n >= atOrAbove) ? n + 1 : n
                out.append("$")
                out.append(String(shifted))
                k = d
                continue
            }

            // Alles andere unverändert.
            out.append(c)
            k += 1
        }
        return out
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Schritt 1: rohe Snap-Units (ohne Match-Beiträge)
    // ─────────────────────────────────────────────────────────────────────

    /// Eine rohe Einheit vor dem Re-Matching. `instrumentNumber` füllen wir
    /// erst in Schritt 2.
    private struct RawUnit {
        var patternRange: NSRange
        var isExistingGroup: Bool
        var existingGroupNumber: Int?
        var isZeroWidth: Bool
    }

    private static func buildRawUnits(pattern: String,
                                      tokenization: RegexTokenization) -> [RawUnit]? {
        // Defensiv: bei vom Tokenizer gemeldeten Fehlern lieber abbrechen,
        // als auf einem kaputten Token-Baum zu raten.
        if tokenization.hasErrors { return nil }

        let tokens = tokenization.tokens
        if tokens.isEmpty { return [] }

        // SONDERFALL Top-Level-Alternation: ein `|` außerhalb aller Gruppen
        // macht das GANZE Pattern zu einer einzigen Unit (v1.0-Einschränkung).
        if hasTopLevelAlternation(tokens: tokens) {
            let whole = NSRange(location: 0, length: (pattern as NSString).length)
            return [RawUnit(patternRange: whole,
                            isExistingGroup: false,
                            existingGroupNumber: nil,
                            isZeroWidth: false)]
        }

        var units: [RawUnit] = []

        // Wir laufen die flache Token-Liste von links nach rechts durch.
        // Bei einer öffnenden Top-Level-Gruppe springen wir über die ganze
        // Gruppe (inkl. Inhalt + schließender Klammer + folgendem Quantifier).
        var idx = 0
        while idx < tokens.count {
            let tok = tokens[idx]

            // (a) Beginnt hier eine Top-Level-Gruppe? Erkennbar an einem
            //     `.groupDelimiter`, der eine öffnende Klammer ist. Wir
            //     suchen die zugehörige Gruppe in `tokenization.groups` ODER
            //     (für nicht-fangende Gruppen/Lookarounds) per Klammer-Balance.
            if tok.kind == .groupDelimiter, isOpeningDelimiter(tok.text) {
                if let unit = consumeGroup(startIndex: idx,
                                           tokens: tokens,
                                           groups: tokenization.groups,
                                           pattern: pattern,
                                           nextIndex: &idx) {
                    units.append(unit)
                    continue
                }
                // Sollte nicht passieren (unbalancierte Klammer) → abbrechen.
                return nil
            }

            // (b) Anker = eigene nullbreite Unit.
            if tok.kind == .anchor {
                units.append(RawUnit(patternRange: tok.range,
                                     isExistingGroup: false,
                                     existingGroupNumber: nil,
                                     isZeroWidth: true))
                idx += 1
                continue
            }

            // (c) Quantifier, der allein steht (sollte einem Token folgen) —
            //     defensiv überspringen; eigentlich von (d) mitkonsumiert.
            if tok.kind == .quantifier {
                // Hängt an nichts → als eigene (literale) Unit behandeln,
                // damit kein Token verloren geht.
                units.append(RawUnit(patternRange: tok.range,
                                     isExistingGroup: false,
                                     existingGroupNumber: nil,
                                     isZeroWidth: false))
                idx += 1
                continue
            }

            // (d) Normales Token (Literal, Zeichenklasse, Escape, Backref …).
            //     Folgt direkt ein Quantifier?
            let hasQuantifierNext = idx + 1 < tokens.count && tokens[idx + 1].kind == .quantifier

            if hasQuantifierNext {
                let quant = tokens[idx + 1]
                // SONDERFALL Literal vor Quantifier: Der Quantifier bezieht
                // sich nur auf das LETZTE Zeichen. `abc?` heißt „ab" + „c?",
                // nicht „(abc)?". Wir spalten ein mehrzeichiges Literal-Token
                // in Kopf („ab") + letztes Graphem („c") auf.
                if tok.kind == .literal,
                   let split = splitTrailingGrapheme(of: tok, in: pattern) {
                    // Kopf-Teil (ohne Quantifier) — eigene Unit, falls nicht leer.
                    if split.head.length > 0 {
                        units.append(RawUnit(patternRange: split.head,
                                             isExistingGroup: false,
                                             existingGroupNumber: nil,
                                             isZeroWidth: false))
                    }
                    // Letztes Zeichen + Quantifier = eine Unit.
                    let tail = NSRange(location: split.last.location,
                                       length: split.last.length + quant.range.length)
                    units.append(RawUnit(patternRange: tail,
                                         isExistingGroup: false,
                                         existingGroupNumber: nil,
                                         isZeroWidth: false))
                } else {
                    // Nicht-Literal (z.B. `\d+`, `[a-z]*`) oder ein-Zeichen-
                    // Literal: ganzes Token + Quantifier = eine Unit.
                    let merged = NSRange(location: tok.range.location,
                                         length: tok.range.length + quant.range.length)
                    units.append(RawUnit(patternRange: merged,
                                         isExistingGroup: false,
                                         existingGroupNumber: nil,
                                         isZeroWidth: false))
                }
                idx += 2
                continue
            }

            // (e) Token ohne folgenden Quantifier = eine Unit wie sie ist.
            units.append(RawUnit(patternRange: tok.range,
                                 isExistingGroup: false,
                                 existingGroupNumber: nil,
                                 isZeroWidth: false))
            idx += 1
        }

        return units
    }

    /// Verschlingt eine komplette Top-Level-Gruppe ab `startIndex` (ein
    /// öffnender `.groupDelimiter`) und gibt sie als eine RawUnit zurück.
    /// `nextIndex` wird auf das erste Token NACH der Gruppe (+ Quantifier)
    /// gesetzt.
    private static func consumeGroup(startIndex: Int,
                                     tokens: [RegexToken],
                                     groups: [CaptureGroupInfo],
                                     pattern: String,
                                     nextIndex: inout Int) -> RawUnit? {
        let openTok = tokens[startIndex]
        let openLoc = openTok.range.location

        // Balance über die Klammer-Delimiter zählen, um das ZUGEHÖRIGE `)`
        // zu finden. Wir verlassen uns NICHT auf `groups`, weil auch nicht-
        // fangende Gruppen (`(?:…)`) und Lookarounds als Units zählen.
        var depth = 0
        var closeIndex: Int? = nil
        var k = startIndex
        while k < tokens.count {
            let t = tokens[k]
            if t.kind == .groupDelimiter {
                if isOpeningDelimiter(t.text) {
                    depth += 1
                } else if t.text.contains(")") {
                    depth -= 1
                    if depth == 0 {
                        closeIndex = k
                        break
                    }
                }
            }
            k += 1
        }
        guard let close = closeIndex else { return nil }

        // Folgt direkt ein Quantifier? Dann gehört er zur Unit — UND macht
        // sie zu einer NICHT wiederverwendbaren Gruppe (`(\w)+` als Ganzes
        // ist keine fangende Einzel-Gruppe mehr).
        var endIndex = close
        var hasQuantifier = false
        if close + 1 < tokens.count, tokens[close + 1].kind == .quantifier {
            endIndex = close + 1
            hasQuantifier = true
        }

        let endTok = tokens[endIndex]
        let fullRange = NSRange(location: openLoc,
                                length: endTok.range.location + endTok.range.length - openLoc)

        // Ist das eine FANGENDE Gruppe (anonym oder benannt)? Wir matchen
        // über die EXAKTE Klammer-Range (`group.range` inkl. Klammern) gegen
        // die Gruppe ohne folgenden Quantifier.
        let closeTok = tokens[close]
        let groupRange = NSRange(location: openLoc,
                                 length: closeTok.range.location + closeTok.range.length - openLoc)
        let matchingGroup = groups.first { NSEqualRanges($0.range, groupRange) }

        // Wiederverwendbar nur, wenn fangend UND ohne folgenden Quantifier.
        let isExisting = (matchingGroup != nil) && !hasQuantifier

        nextIndex = endIndex + 1
        return RawUnit(patternRange: fullRange,
                       isExistingGroup: isExisting,
                       existingGroupNumber: isExisting ? matchingGroup?.number : nil,
                       isZeroWidth: false)
    }

    // MARK: - Schritt-1-Helfer

    /// `true` für öffnende Gruppen-Delimiter: `(`, `(?:`, `(?<name>`, `(?=` …
    /// (Alle beginnen mit `(` und enthalten kein `)`.)
    private static func isOpeningDelimiter(_ text: String) -> Bool {
        text.hasPrefix("(") && !text.contains(")")
    }

    /// Gibt es ein `|` auf Top-Level (Klammer-Tiefe 0)? Dann greift der
    /// Alternation-Sonderfall.
    private static func hasTopLevelAlternation(tokens: [RegexToken]) -> Bool {
        var depth = 0
        for t in tokens {
            if t.kind == .groupDelimiter {
                if isOpeningDelimiter(t.text) {
                    depth += 1
                } else if t.text.contains(")") {
                    depth -= 1
                }
            } else if t.kind == .alternation, depth == 0 {
                return true
            }
        }
        return false
    }

    /// Spaltet ein mehrzeichiges Literal-Token in „alles bis aufs letzte
    /// Zeichen" (`head`) und „letztes Zeichen" (`last`). Maßeinheit ist das
    /// EXTENDED GRAPHEME CLUSTER (also robust gegen Surrogatpaare/Emoji), die
    /// Ranges sind aber UTF-16. Gibt `nil`, wenn das Token nur ein Graphem
    /// hat (dann gibt es nichts zu spalten — der Aufrufer merged ganz normal).
    private static func splitTrailingGrapheme(of token: RegexToken,
                                              in pattern: String)
        -> (head: NSRange, last: NSRange)? {
        let text = token.text
        // Letztes Graphem (Character = extended grapheme cluster in Swift).
        guard let lastChar = text.last else { return nil }
        // Länge des letzten Graphems in UTF-16-Code-Units (Emoji = 2).
        let lastUTF16 = String(lastChar).utf16.count
        // Nur ein Graphem insgesamt → nichts zu spalten.
        if lastUTF16 == token.range.length { return nil }

        let headLength = token.range.length - lastUTF16
        let head = NSRange(location: token.range.location, length: headLength)
        let last = NSRange(location: token.range.location + headLength, length: lastUTF16)
        return (head, last)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Schritte 2+3: instrumentieren + re-matchen
    // ─────────────────────────────────────────────────────────────────────

    private static func attachMatchRanges(raw: [RawUnit],
                                          pattern: String,
                                          matchText: String,
                                          caseSensitive: Bool) -> [SnapUnit]? {
        let nsPattern = pattern as NSString

        // Schritt 2: Instrument-Pattern bauen. Wir gehen die Units in
        // Pattern-Reihenfolge durch und hüllen jede NICHT-nullbreite Unit in
        // `(...)`. Bereits-fangende Top-Level-Gruppen (isExistingGroup) sind
        // schon eine Klammer — die NICHT doppelt wrappen, sonst stimmt die
        // Nummerierung nicht.
        //
        // `instrumentNumber[idx]` = Gruppennummer im Instrument-Pattern, aus
        // der wir später die Match-Range dieser Unit lesen.
        var instrument = String()
        var instrumentNumber = [Int?](repeating: nil, count: raw.count)
        // Laufende Zahl bereits geöffneter fangender Klammern im Instrument.
        var openCount = 0

        for (idx, unit) in raw.enumerated() {
            let snippet = nsPattern.substring(with: unit.patternRange)

            if unit.isZeroWidth {
                // Anker unverpackt übernehmen — sie tragen nichts bei und
                // dürfen keine Gruppe öffnen.
                instrument += snippet
                continue
            }

            if unit.isExistingGroup {
                // Schon eine fangende Gruppe — ihre eigene öffnende Klammer
                // bekommt die nächste Nummer. ABER: sie kann GESCHACHTELTE
                // fangende Gruppen enthalten, die in der Instrument-Zählung
                // mitzählen. Deshalb zählen wir alle öffnenden fangenden
                // Klammern in ihrem Snippet.
                let myNumber = openCount + 1
                instrumentNumber[idx] = myNumber
                instrument += snippet
                openCount += countCapturingOpens(in: snippet)
            } else {
                // Unit selbst in eine fangende Klammer hüllen. Diese äußere
                // Klammer bekommt die nächste Nummer; etwaige geschachtelte
                // fangende Klammern IM Snippet zählen danach.
                let myNumber = openCount + 1
                instrumentNumber[idx] = myNumber
                instrument += "(" + snippet + ")"
                openCount += 1 + countCapturingOpens(in: snippet)
            }
        }

        // Schritt 3: Instrument verankert gegen den GESAMTEN Match-Text
        // matchen. `\A(?:…)\z` erzwingt „komplett von Anfang bis Ende" —
        // robuster als Anchored-Optionen, deckt auch mehrzeilige Texte ab.
        let anchored = "\\A(?:" + instrument + ")\\z"
        var options: NSRegularExpression.Options = [.dotMatchesLineSeparators]
        if !caseSensitive { options.insert(.caseInsensitive) }

        guard let regex = try? NSRegularExpression(pattern: anchored, options: options) else {
            // Instrument ließ sich nicht kompilieren → nicht zuordenbar.
            return nil
        }

        let nsMatch = matchText as NSString
        let fullRange = NSRange(location: 0, length: nsMatch.length)
        guard let result = regex.firstMatch(in: matchText, options: [], range: fullRange) else {
            // Re-Matching scheitert (z.B. wholeWord-Kontext, s. Dateikopf).
            return nil
        }

        // Schritt 3-Ergebnis: pro Unit die Match-Range auslesen und die
        // öffentlichen SnapUnits bauen.
        var result2: [SnapUnit] = []
        result2.reserveCapacity(raw.count)
        for (idx, unit) in raw.enumerated() {
            var matchRange: NSRange? = nil
            if let n = instrumentNumber[idx] {
                let r = result.range(at: n)
                // Zwei „kein Beitrag"-Fälle, beide als nil behandelt:
                //  1. {NSNotFound, 0} — Unit nahm gar nicht teil (z.B. ein
                //     nicht-genommener Alternation-Zweig).
                //  2. Länge 0 — Unit nahm teil, matchte aber 0 Zeichen
                //     (z.B. `u?` in „color"). Trägt nichts zum sichtbaren
                //     Match-Text bei → für Snap unsichtbar.
                if r.location != NSNotFound && r.length > 0 {
                    matchRange = r
                }
            }
            result2.append(SnapUnit(patternRange: unit.patternRange,
                                    matchRange: matchRange,
                                    isExistingGroup: unit.isExistingGroup,
                                    existingGroupNumber: unit.existingGroupNumber,
                                    isZeroWidth: unit.isZeroWidth))
        }
        return result2
    }

    /// Zählt öffnende FANGENDE Klammern in einem Pattern-Schnipsel — also `(`,
    /// die KEINE nicht-fangende Gruppe (`(?:`, `(?=`, `(?!`, `(?<=`, `(?<!`)
    /// und keine escapte Klammer (`\(`) sind. `(?<name>` IST fangend.
    private static func countCapturingOpens(in snippet: String) -> Int {
        let chars = Array(snippet)
        var count = 0
        var k = 0
        var inClass = false  // innerhalb `[...]` sind `(` literal
        while k < chars.count {
            let c = chars[k]
            // Escape: nächstes Zeichen überspringen (`\(`, `\[` …).
            if c == "\\" {
                k += 2
                continue
            }
            if inClass {
                if c == "]" { inClass = false }
                k += 1
                continue
            }
            if c == "[" {
                inClass = true
                k += 1
                continue
            }
            if c == "(" {
                // `(?...` ist nicht-fangend, AUSSER `(?<name>` und `(?'name'`.
                if k + 1 < chars.count, chars[k + 1] == "?" {
                    // `(?<name>` / `(?P<name>` sind fangend; `(?<=`/`(?<!`
                    // (Lookbehind) NICHT.
                    if k + 2 < chars.count, chars[k + 2] == "<",
                       k + 3 < chars.count, chars[k + 3] != "=", chars[k + 3] != "!" {
                        count += 1
                    } else if k + 2 < chars.count, chars[k + 2] == "P",
                              k + 3 < chars.count, chars[k + 3] == "<" {
                        count += 1
                    }
                    // sonst nicht-fangend → nicht zählen
                } else {
                    count += 1
                }
            }
            k += 1
        }
        return count
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Schritt 4: Selektion → minimale Unit-Folge [i…j]
    // ─────────────────────────────────────────────────────────────────────

    /// Findet die minimale zusammenhängende Folge von Units, deren Match-
    /// Beiträge die Selektion abdecken. Nur Units MIT Beitrag (nicht
    /// nullbreit, nicht beitragslos) kommen als Endpunkte infrage.
    ///
    /// - Returns: `(i, j)` Indizes in `units` (inklusive), oder `nil`, wenn
    ///   keine beitragende Unit die Selektion schneidet.
    private static func snapRange(selection: NSRange, units: [SnapUnit]) -> (Int, Int)? {
        let selStart = selection.location
        let selEnd = selection.location + selection.length

        // Indizes aller Units, deren Match-Beitrag die Selektion SCHNEIDET.
        // Schneiden = die Bereiche überlappen sich um >0, ODER (für leere
        // Selektion) der Cursor liegt im/am Beitrag.
        var hits: [Int] = []
        for (idx, unit) in units.enumerated() {
            guard let m = unit.matchRange else { continue }
            let mStart = m.location
            let mEnd = m.location + m.length

            if selection.length == 0 {
                // Leere Selektion: Cursor in [mStart, mEnd] INKLUSIVE Rändern.
                // (Cursor genau an einer Token-Grenze → wir nehmen die Unit,
                // in der er liegt; bei Grenze gewinnt die LINKE, s.u.)
                if selStart >= mStart && selStart <= mEnd {
                    hits.append(idx)
                }
            } else {
                // Nicht-leere Selektion: echte Überlappung (>0 gemeinsame Länge).
                let overlapStart = max(selStart, mStart)
                let overlapEnd = min(selEnd, mEnd)
                if overlapStart < overlapEnd {
                    hits.append(idx)
                }
            }
        }

        guard let first = hits.first, let last = hits.last else { return nil }

        // Bei leerer Selektion an einer Grenze können ZWEI Units passen
        // (Cursor == Ende von Unit A == Anfang von Unit B, weil wir oben
        // beide Ränder inklusive prüfen). Das Konzept (§4, Schritt 4) gibt
        // die Tie-Break-Regel vor: an der Kante gewinnt die RECHTE Unit —
        // der Cursor „gehört" zu dem, was nach ihm kommt. Wir nehmen daher
        // den GRÖSSTEN passenden Index (`last`).
        if selection.length == 0 && hits.count > 1 {
            return (last, last)
        }

        // [first…last] umfasst alle schneidenden Units. Endpunkte sind per
        // Konstruktion beitragende Units. Units OHNE Beitrag DAZWISCHEN
        // (z.B. `u?` in „colour"/„color") liegen im Bereich, sind aber
        // unschädlich — die Vereinigung der Pattern-Klammern umschließt sie
        // einfach mit (snapRange liefert Indizes, das Einsetzen nutzt die
        // Pattern-Ranges der Endpunkte).
        return (first, last)
    }

    /// Vereinigt die Match-Beiträge der Units von Index `i` bis `j` (inkl.).
    private static func unionMatchRange(units: [SnapUnit], from i: Int, to j: Int) -> NSRange {
        var lo = Int.max
        var hi = Int.min
        for idx in i...j {
            guard let m = units[idx].matchRange else { continue }
            lo = min(lo, m.location)
            hi = max(hi, m.location + m.length)
        }
        if lo == Int.max { return NSRange(location: 0, length: 0) }
        return NSRange(location: lo, length: hi - lo)
    }

    // MARK: - Schritt 5b: Klammern ins Pattern einsetzen

    /// Fügt `(` an UTF-16-Position `openAt` und `)` an `closeAt` (Position im
    /// ORIGINAL-Pattern) ein. Weil das Einfügen von `(` alle nachfolgenden
    /// Positionen um 1 verschiebt, setzen wir die HINTERE Klammer zuerst.
    private static func insertParentheses(in pattern: String, openAt: Int, closeAt: Int) -> String {
        let ns = NSMutableString(string: pattern)
        ns.insert(")", at: closeAt)   // erst hinten (Index bleibt gültig)
        ns.insert("(", at: openAt)    // dann vorn
        return ns as String
    }
}
