// BufferSearch.swift
//
// Reine, UI-freie Suche in einem In-Memory-Text (= aktiver Editor-Buffer).
// Bewusst getrennt von `ApplyEngine`: die Engine kümmert sich um Dateien
// auf der Platte (Encoding-Roundtrip, atomare Writes, Undo-Backups). Hier
// brauchen wir all das nicht — der Editor liefert schon Swift-Strings,
// und für die Sofort-Trefferliste in der Suchmaske reichen Range, Zeile,
// Spalte und der ersetzte Text.

import Foundation

enum BufferSearch {
    /// Ein einzelner Treffer im Buffer. `range` ist NSRange (UTF-16-
    /// Offsets, wie sie auch der CodeEdit-Editor verwendet), damit wir
    /// später ohne Rechnerei in die Cursor-Sprung-Logik fließen können.
    struct Match: Identifiable, Equatable, Sendable {
        let id = UUID()
        let range: NSRange
        /// 1-basierte Zeilennummer der Treffer-Anfangs-Position.
        let line: Int
        /// 1-basierte Spalte der Treffer-Anfangs-Position.
        let column: Int
        /// Original-Text des Treffers (zum Anzeigen in der Liste).
        let matchText: String
        /// Rest der logischen Zeile NACH dem Treffer, ohne Zeilenumbruch.
        /// Die Trefferliste zeigt ihn direkt hinter `matchText`, damit zwei
        /// gleichlautende Funde ohne Öffnen der Datei unterscheidbar sind.
        let lineRemainder: String
        /// Text, der nach Apply an dieser Stelle stünde (inkl. $1-Backrefs).
        let replacedText: String

        init(range: NSRange, line: Int, column: Int, matchText: String,
             lineRemainder: String = "", replacedText: String) {
            self.range = range
            self.line = line
            self.column = column
            self.matchText = matchText
            self.lineRemainder = lineRemainder
            self.replacedText = replacedText
        }
    }

    /// Ergebnis eines Such-Laufs. Bei ungültigem Pattern liegt `matches`
    /// leer und `invalidPatternMessage` enthält die Fehlermeldung — die
    /// Maske kann sie als roten Hinweis-Streifen anzeigen.
    struct SearchResult: Equatable {
        /// Die materialisierten Treffer — höchstens `maxMatches` Stück.
        let matches: [Match]
        /// ECHTE Gesamtzahl der Treffer im Text. Kann `matches.count`
        /// ÜBERSTEIGEN, wenn der Cap (`maxMatches`) gegriffen hat. Die Maske
        /// zeigt diese Zahl an — analog zur BBEdit-Statuszeile, die immer
        /// den wahren Count nennt, auch wenn nicht alle Zeilen gelistet sind.
        let totalMatches: Int
        /// `true`, wenn mehr Treffer existieren als materialisiert wurden
        /// (`totalMatches > matches.count`). Die Maske zeigt dann einen
        /// Hinweis-Streifen (keine stille Trunkierung).
        let wasCapped: Bool
        let invalidPatternMessage: String?

        static let empty = SearchResult(matches: [], totalMatches: 0,
                                        wasCapped: false, invalidPatternMessage: nil)
    }

    /// Höchstlänge des angezeigten Zeilenrests in UTF-16-Einheiten.
    ///
    /// Ohne Grenze kopiert jeder Treffer den kompletten Rest seiner logischen
    /// Zeile. Bei einer erlaubten 32-MiB-Datei ohne Zeilenumbruch (etwa ein
    /// einzeiliges JSON) sind das pro Treffer fast 32 MiB — mal 2.000
    /// materialisierter Treffer zig Gigabyte, an denen die App am
    /// Speicherdruck stirbt (Review 2026-08-06). Die Trefferliste zeigt
    /// ohnehin nur EINE abgeschnittene Zeile.
    static let maxLineRemainderLength = 400

    /// Der sichtbare Zeilenrest hinter einem Treffer, auf `limit`
    /// UTF-16-Einheiten begrenzt.
    ///
    /// Der Schnitt landet nie mitten in einem Graphem (Emoji, kombinierende
    /// Zeichen): `rangeOfComposedCharacterSequence` liefert die Grenzen des
    /// Clusters an der Schnittstelle, und der Rest endet davor. Wurde gekürzt,
    /// macht ein angehängtes „…" das sichtbar — keine stille Trunkierung.
    static func lineRemainder(in ns: NSString, from start: Int, to contentEnd: Int,
                              limit: Int = maxLineRemainderLength) -> String {
        guard contentEnd > start else { return "" }
        let available = contentEnd - start
        guard available > limit else {
            return ns.substring(with: NSRange(location: start, length: available))
        }
        var end = start + limit
        let cluster = ns.rangeOfComposedCharacterSequence(at: end)
        // Beginnt das Graphem nach dem Trefferende, endet der Rest davor.
        // Ein einzelnes übergroßes Graphem bleibt sonst lieber vollständig,
        // als in zwei kaputte Hälften zu zerfallen.
        end = cluster.location > start
            ? cluster.location
            : min(contentEnd, NSMaxRange(cluster))
        return ns.substring(with: NSRange(location: start, length: end - start)) + "…"
    }

    /// Standard-Obergrenze für materialisierte Treffer in der Live-Liste.
    /// Eine flache Liste mit Zehntausenden Zeilen ist kein Navigations-
    /// werkzeug (BBEdits gruppierter Results-Browser schon) — und pro
    /// Treffer fällt teure Arbeit an (Substring + Replacement-Template).
    /// Wir materialisieren daher nur die ersten N, zählen aber ALLE.
    static let defaultMaxMatches = 2000

    /// Hauptfunktion. Wird auf jeden Tastendruck (debounced) aufgerufen.
    /// Leerer Find-String → leeres Ergebnis (kein Pattern = kein Treffer,
    /// vermeidet UI-Geflacker mit „1000 Treffer" bei jedem Backspace bis 0).
    ///
    /// `maxMatches`: höchstens so viele Treffer werden als `Match`-Objekte
    /// gebaut; `totalMatches` zählt trotzdem alle. `shouldCancel`: wird
    /// während der Enumeration periodisch abgefragt — liefert sie `true`,
    /// bricht der Lauf ab und gibt `.empty` zurück (der Aufrufer verwirft
    /// veraltete Läufe ohnehin). So scannt ein vom nächsten Tastendruck
    /// überholter Lauf eine Riesendatei nicht sinnlos zu Ende.
    ///
    /// `searchRange`: Wenn gesetzt, wird NUR innerhalb dieser NSRange gesucht
    /// (BBEdit „Selected Text Only" / „Nur in Auswahl"). Zeile/Spalte bleiben
    /// trotzdem absolut zum GESAMTEN Text — sonst zeigte die Trefferliste
    /// falsche Zeilennummern. `nil` = ganzer Text (Normalfall).
    static func find(in text: String, options: SearchOptions,
                     maxMatches: Int = defaultMaxMatches,
                     searchRange: NSRange? = nil,
                     shouldCancel: () -> Bool = { false }) -> SearchResult {
        guard !options.isEmpty else { return .empty }
        do {
            return find(
                in: text, plan: try SearchPlan(options: options),
                maxMatches: maxMatches, searchRange: searchRange,
                shouldCancel: shouldCancel
            )
        } catch {
            // Mensch-lesbare Erklärung. NSRegularExpression-Errors liefern
            // selbst schon einen Beschreibungstext; wir reichen ihn durch.
            let msg = (error as NSError).localizedDescription
            return SearchResult(matches: [], totalMatches: 0,
                                wasCapped: false, invalidPatternMessage: msg)
        }
    }

    /// Variante für einen bereits vorbereiteten Lauf. Mehrdatei- und
    /// Mehrtab-Suchen bauen den `SearchPlan` einmal und rufen diese Funktion
    /// für jede Eingabe auf; die Suchsemantik bleibt exakt dieselbe wie beim
    /// bequemen `options`-Wrapper oben.
    static func find(in text: String, plan: SearchPlan,
                     maxMatches: Int = defaultMaxMatches,
                     searchRange: NSRange? = nil,
                     shouldCancel: () -> Bool = { false }) -> SearchResult {
        guard !plan.options.isEmpty else { return .empty }

        if shouldCancel() { return .empty }
        let ns = text as NSString
        // RegEx liefert aufsteigende Positionen. Wir zählen Zeilen nur bis
        // zum jeweils angezeigten Treffer, statt vorab das ganze Dokument
        // zu indizieren. Ohne Treffer entfällt die Zeilenarbeit vollständig.
        var line = 1
        var lineStart = 0
        var nextLineStart = 0
        // Nur die zuletzt abgefragte Restzeile merken. NSString bestimmt
        // ihre echten Grenzen einschließlich CRLF; die nächste Zeile beginnt
        // genau am exklusiven Ende und erzwingt deshalb eine neue Abfrage.
        var remainderLineStart = NSNotFound
        var remainderLineEnd = NSNotFound
        var remainderContentEnd = NSNotFound
        // RegEx und Ersetzungstemplate liegen bereits im Plan; ab hier fällt
        // nur noch die textspezifische Zeilen- und Trefferarbeit an.
        var matches: [Match] = []
        matches.reserveCapacity(min(maxMatches, 1024))
        var total = 0
        var cancelled = false
        // Scan-Bereich bestimmen: bei „Nur in Auswahl" auf die übergebene
        // Range begrenzen (gegen die Gesamtlänge geschnitten, damit eine
        // veraltete Selektion nach einer Inhalts-Änderung nicht crasht).
        let fullRange = NSRange(location: 0, length: ns.length)
        let scanRange = searchRange.map { NSIntersectionRange($0, fullRange) } ?? fullRange
        // `enumerateMatches` statt `matches(in:)`: erzeugt KEIN Zwischen-
        // Array über alle Treffer (das wäre bei kurzen Pattern in großen
        // Dateien selbst schon riesig) und erlaubt Abbruch via `stop`.
        // `.reportProgress` sorgt auch bei riesigen Texten OHNE Treffer für
        // regelmäßige Callbacks. Ohne diese Option könnte nur bei gefundenen
        // Treffern abgebrochen werden und ein No-Match-Scan liefe zu Ende.
        plan.regex.enumerateMatches(in: text, options: [.reportProgress],
                                    range: scanRange) { result, _, stop in
            if shouldCancel() {
                cancelled = true
                stop.pointee = true
                return
            }
            guard let result = result else { return }
            total += 1
            // Nur die ersten `maxMatches` als Objekte bauen — der teure Teil
            // (Substring, Replacement-Template) entfällt für den Rest.
            if matches.count < maxMatches {
                let r = result.range
                while nextLineStart <= r.location {
                    if line & 0x3FF == 0, shouldCancel() {
                        cancelled = true
                        stop.pointee = true
                        return
                    }
                    if nextLineStart > 0 {
                        lineStart = nextLineStart
                        line += 1
                    }
                    var end = NSNotFound
                    ns.getLineStart(nil, end: &end, contentsEnd: nil,
                                    for: NSRange(location: lineStart, length: 0))
                    // Wie collectLineStarts zählt ein abschließender Umbruch
                    // keine zusätzliche leere Zeile für den Treffer am EOF.
                    nextLineStart = end > lineStart && end < ns.length ? end : Int.max
                }
                let column = r.location - lineStart + 1
                let matchText = ns.substring(with: r)
                // Kontext endet am Inhaltsende der Zeile, also VOR CR/LF.
                // Bei mehrzeiligen Treffern zählt die Zeile des Trefferendes:
                // Genau dort setzt der sichtbare Rest nach dem Treffer an.
                let afterMatch = NSMaxRange(r)
                if remainderLineStart == NSNotFound
                    || afterMatch < remainderLineStart
                    || afterMatch >= remainderLineEnd {
                    remainderLineStart = afterMatch
                    remainderLineEnd = afterMatch
                    remainderContentEnd = afterMatch
                    ns.getLineStart(&remainderLineStart, end: &remainderLineEnd,
                                    contentsEnd: &remainderContentEnd,
                                    for: NSRange(location: afterMatch, length: 0))
                }
                let contentEnd = remainderContentEnd
                let lineRemainder = Self.lineRemainder(in: ns, from: afterMatch,
                                                       to: contentEnd)
                // Über CaseTemplate statt direkt: unterstützt BBEdits
                // \U/\L/\u/\l/\E im Ersetzungsmuster (Fast Path ohne
                // Operatoren = unverändert NSRegularExpression).
                let replacedText = CaseTemplate.replacement(
                    for: result, in: text, regex: plan.regex,
                    template: plan.replacementTemplate
                )
                matches.append(Match(range: r, line: line, column: column,
                                     matchText: matchText, lineRemainder: lineRemainder,
                                     replacedText: replacedText))
            }
        }
        if cancelled { return .empty }
        guard total > 0 else { return .empty }
        return SearchResult(matches: matches, totalMatches: total,
                            wasCapped: total > matches.count, invalidPatternMessage: nil)
    }

    /// Ersetzt ALLE Treffer im Text in EINEM Durchgang — unabhängig vom
    /// Listen-Cap. Nutzt `stringByReplacingMatches`, materialisiert also
    /// keine Treffer-Objekte und bleibt auch bei sehr vielen Treffern
    /// schnell. Das ist der korrekte Pfad für „Alle ersetzen": die gekappte
    /// `bufferMatches`-Liste würde sonst nur die ersten N Treffer ersetzen.
    /// `nil` bei leerem oder ungültigem Pattern (Aufrufer ersetzt dann nichts).
    ///
    /// `searchRange`: Wenn gesetzt, wird NUR innerhalb dieser NSRange ersetzt
    /// (BBEdit „Replace All in Selection"); der Rest des Texts bleibt
    /// unverändert. `nil` = ganzer Text.
    static func replaceAll(in text: String, options: SearchOptions,
                           searchRange: NSRange? = nil) -> String? {
        guard !options.isEmpty else { return nil }
        guard let plan = try? SearchPlan(options: options) else { return nil }
        return replaceAll(in: text, plan: plan, searchRange: searchRange)
    }

    /// `replaceAll` mit einem für den gesamten Lauf vorbereiteten Plan.
    /// Besonders der Geöffnet-Scope verwendet ihn über alle Tabs hinweg.
    static func replaceAll(in text: String, plan: SearchPlan,
                           searchRange: NSRange? = nil) -> String? {
        guard !plan.options.isEmpty else { return nil }
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let scanRange = searchRange.map { NSIntersectionRange($0, fullRange) } ?? fullRange
        // Case-Operatoren (\U/\L/…) kann `stringByReplacingMatches` nicht
        // deuten — dann selbst enumerieren + zusammensetzen. Ohne Operatoren
        // bleibt der schnelle Original-Pfad.
        if CaseTemplate.containsOperators(plan.replacementTemplate) {
            return CaseTemplate.replaceAllAssembling(
                in: text, regex: plan.regex,
                template: plan.replacementTemplate, range: scanRange
            )
        }
        return plan.regex.stringByReplacingMatches(
            in: text, options: [],
            range: scanRange,
            withTemplate: plan.replacementTemplate)
    }

    // MARK: - Zeilen-/Spalten-Berechnung

    /// Sammelt die Start-Offsets ALLER Zeilen — `[0, Start_Zeile2, …]`.
    ///
    /// WICHTIG: Nutzt die NSString-Zeilensemantik (`getLineStart:end:`), die
    /// `\n` (LF), `\r` (CR, klassisches Mac), `\r\n` (CRLF) UND die Unicode-
    /// Zeilen-/Absatztrenner (U+2028/U+2029/U+0085) gleichermaßen als
    /// Zeilenende behandelt. Genau so zählt auch der Editor (CodeEditTextView
    /// baut sein Zeilen-Layout über dieselbe API — `NSTextStorage.getNextLine`).
    ///
    /// Frühere Fassung zählte NUR LF. Bei reinen CR-Dateien (z.B. 4D-Logs)
    /// liefen so tausende Editor-Zeilen in wenige „Zeilen" zusammen → falsche
    /// Zeilennummern in der Trefferliste und ein ins Leere zielender Sprung.
    static func collectLineStarts(in ns: NSString) -> [Int] {
        collectLineStarts(in: ns, shouldCancel: { false }) ?? [0]
    }

    /// Abbrechbare Variante für die Live-Suche. Die öffentliche Hilfsfunktion
    /// oben bleibt total, weil Cursor-/Sprungberechnungen kein Abbruchsignal
    /// besitzen und weiterhin immer eine gültige `[0, …]`-Liste brauchen.
    private static func collectLineStarts(in ns: NSString,
                                          shouldCancel: () -> Bool) -> [Int]? {
        var starts: [Int] = [0]
        let length = ns.length
        starts.reserveCapacity(length / 40)  // grobe Schätzung
        var index = 0
        var inspectedLines = 0
        while index < length {
            if inspectedLines & 0x3FF == 0, shouldCancel() { return nil }
            var end = NSNotFound
            ns.getLineStart(nil, end: &end, contentsEnd: nil,
                            for: NSRange(location: index, length: 0))
            // `end` = Start der nächsten Zeile (hinter dem Terminator).
            // Schutz gegen Stillstand/NSNotFound → Abbruch.
            if end == NSNotFound || end <= index { break }
            if end < length { starts.append(end) }
            index = end
            inspectedLines += 1
        }
        return starts
    }

    /// Wendet eine Liste von Treffern auf einen Text an und gibt den
    /// ersetzten String zurück. PURE Funktion — kein Workspace, kein UI.
    /// Voraussetzung: `matches` ist nach Range-Offset aufsteigend sortiert
    /// und nicht überlappend (so liefert `BufferSearch.find` das auch).
    static func applyReplacements(in text: String, matches: [Match]) -> String {
        guard !matches.isEmpty else { return text }
        let ns = text as NSString
        var out = String()
        out.reserveCapacity(text.count)
        var cursor = 0
        for m in matches {
            // Schutz gegen überlappende Ranges: liegt ein Treffer noch
            // unterhalb des Cursors, wird er übersprungen (kann mit den
            // aktuellen Engines nicht passieren, aber besser robust).
            guard m.range.location >= cursor else { continue }
            if m.range.location > cursor {
                out.append(ns.substring(with: NSRange(location: cursor,
                                                       length: m.range.location - cursor)))
            }
            out.append(m.replacedText)
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            out.append(ns.substring(with: NSRange(location: cursor,
                                                   length: ns.length - cursor)))
        }
        return out
    }

    /// Konvertiert 1-basierte `line`/`column` in eine NSRange-Cursor-
    /// Position (length 0) im gegebenen Text. Werte werden geclampt:
    /// Zeile jenseits Dokumentende → Cursor an Dokumentende. Spalte
    /// jenseits Zeilenende → Cursor am Zeilenende. Spalte/Zeile < 1 → 1.
    static func nsRange(forLine line: Int, column: Int?, in text: String) -> NSRange {
        let ns = text as NSString
        let length = ns.length
        let lineStarts = collectLineStarts(in: ns)
        let safeLine = max(1, line)
        // Anfangs-Offset der gewünschten Zeile (jenseits Dok-Ende → Dok-Ende).
        let lineStart: Int = (safeLine - 1 < lineStarts.count) ? lineStarts[safeLine - 1] : length
        // Ende der Zeile VOR dem Terminator — über dieselbe NSString-API, die
        // CR/LF/CRLF/Unicode-Trenner einheitlich erkennt.
        var contentsEnd = NSNotFound
        if lineStart < length {
            ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd,
                            for: NSRange(location: lineStart, length: 0))
        }
        let lineEnd = (contentsEnd == NSNotFound) ? length : contentsEnd
        let col = max(1, column ?? 1)
        let offset = min(lineStart + col - 1, lineEnd)
        return NSRange(location: offset, length: 0)
    }

    /// `lineStarts` ist die sortierte Liste aller Zeilen-Start-Offsets
    /// (`[0, …]`, siehe `collectLineStarts`). Via Binärsuche bestimmen wir
    /// den größten Start ≤ `offset` — sein Index +1 ist die 1-basierte Zeile,
    /// Spalte = Offset minus diesem Start +1 (UTF-16, konsistent mit dem Editor).
    static func lineColumn(forOffset offset: Int, lineStarts: [Int]) -> (line: Int, column: Int) {
        // Größter Index `idx` mit lineStarts[idx] <= offset.
        var lo = 0
        var hi = lineStarts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= offset {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let idx = max(0, lo - 1)
        return (idx + 1, offset - lineStarts[idx] + 1)
    }

    /// Berechnet Zeile/Spalte des ENDES (exklusiv) eines Treffers aus dessen
    /// Start-Zeile/-Spalte und Treffer-Text. Spalten 1-basiert, UTF-16 —
    /// konsistent mit `lineColumn`. Mehrzeilige Treffer (Treffer-Text enthält
    /// `\n`) werden über mehrere Zeilen korrekt aufgelöst.
    ///
    /// Wird für den Editor-Sprung gebraucht: dort selektieren wir den Treffer
    /// über (start, end) als Zeile/Spalte, nicht über die absolute Range —
    /// siehe `NotificationCenter.postMatchJump`.
    static func endLineColumn(startLine: Int, startColumn: Int,
                              matchText: String) -> (line: Int, column: Int) {
        let ns = matchText as NSString
        // Zeilen-Starts INNERHALB des Treffer-Texts — gleiche NSString-
        // Semantik (CR/LF/CRLF/Unicode) wie collectLineStarts.
        let lineStarts = collectLineStarts(in: ns)
        if lineStarts.count <= 1 {
            // Einzeilig: Endspalte = Startspalte + UTF-16-Länge des Treffers.
            return (startLine, startColumn + ns.length)
        }
        // Mehrzeilig: Endzeile = Start + Anzahl Zeilenumbrüche; Endspalte =
        // Anzahl Zeichen nach dem letzten Zeilenumbruch + 1.
        let breaks = lineStarts.count - 1
        let lastStart = lineStarts[lineStarts.count - 1]
        let afterLast = ns.length - lastStart
        return (startLine + breaks, afterLast + 1)
    }
}

/// Ein angeforderter Editor-Sprung als konsumierbarer Zustand.
///
/// Warum nicht nur die Notification? Der Sprung trifft häufig einen Editor,
/// der gerade neu erzeugt wird (Tab-Wechsel und das Ende des asynchronen
/// Ladens wechseln die SwiftUI-`.id` des Editors). Eine einmalige
/// Notification kann genau in dieses Fenster fallen: Der alte Empfänger ist
/// schon abgehängt, der neue noch nicht abonniert — der Sprung verpufft, und
/// der Klick auf einen Suchtreffer wirkt „folgenlos" (unter Last am
/// 2026-08-19 reproduziert, lokal 1 von 3 jump-Selbsttestläufen). Deshalb
/// hinterlegt jeder Sprung sich zusätzlich hier; der (neu) eingehängte
/// Editor desselben Dokuments holt ihn beim Erscheinen nach und verbraucht
/// ihn.
struct PendingEditorJump {
    /// Dokument, für das der Sprung gilt — ein später eingehängter Editor
    /// eines anderen Dokuments darf ihn nicht anwenden.
    let documentID: UUID?
    let startLine: Int?
    let startColumn: Int?
    let endLine: Int?
    let endColumn: Int?
    /// Absolute Range als Fallback (z. B. „Zu Zeile springen").
    let range: NSRange?
}

/// Dokument, dem ein VERZÖGERT gepostetes Treffer-Sprung-Ziel gilt.
/// Die Aufrufer wechseln erst den Tab beziehungsweise laden die Datei und
/// posten den Sprung danach — einen Runloop-Tick oder eine ganze Ladezeit
/// später. Wechselt der Nutzer in diesem Fenster erneut, ist der Sprung
/// hinfällig; ohne diese Prüfung markierte er den Trefferbereich im dann
/// aktiven, also falschen Dokument.
enum MatchJumpTarget {
    /// Ein bereits offenes Dokument, adressiert über seine Dokument-ID. Ein
    /// wiederverwendeter Vorschau-Tab behält seine Tab-ID, nicht aber diese
    /// Identität.
    case document(UUID)
    /// Eine Datei aus einer abgeschlossenen Ordnersuche. URL und Snapshot
    /// entstanden im Hintergrundlauf; der spätere UI-Guard vergleicht deshalb
    /// nur Werte im Speicher und berührt weder Pfadmetadaten noch Dateibytes.
    case file(url: URL, snapshot: FileSnapshot)

    func isActive(in workspace: Workspace) -> Bool {
        switch self {
        case .document(let id):
            return workspace.activeDocumentID == id
        case .file(let url, let snapshot):
            return workspace.activeTab?.url == url
                && workspace.activeTab?.diskSnapshot == snapshot
                && workspace.activeTab?.hasUnsavedChanges == false
                && workspace.activeTab?.isLoading == false
        }
    }
}

/// Der sichtbare Trefferindex darf nur mitwandern, wenn der zugehörige
/// Editor-Sprung wirklich gepostet wurde und keine neuere Nutzeraktion den
/// Index inzwischen verändert hat.
enum MatchJumpCommit {
    static func index(previous: Int, current: Int, next: Int,
                      posted: Bool) -> Int? {
        guard posted, current == previous else { return nil }
        return next
    }
}

extension NotificationCenter {
    /// Postet einen Editor-Sprung zu einem Treffer über Zeile/Spalte
    /// (Start UND Ende) statt nur der absoluten NSRange.
    ///
    /// Warum nicht die Range? Die absolute Range ist die Summe ALLER
    /// Vorzeilen-Längen. Weicht der Editor-Storage auch nur in einer
    /// früheren Zeile in der Länge ab (Encoding-/Line-Ending-Normalisierung,
    /// BOM, interne CESE-Aufbereitung), driftet die Range — der Cursor landet
    /// daneben (beobachtet: „Müller" statt „Daniel"). Zeile/Spalte hängen
    /// dagegen nur an der Zeilenumbruch-ZAHL (stabil) und der Position
    /// INNERHALB der Zeile (stabil). CodeEditSourceEditor rechnet daraus die
    /// Selektion gegen sein EIGENES Zeilen-Layout (`setCursorPositions` →
    /// `textLineForIndex`), also immer konsistent mit dem, was es anzeigt.
    ///
    /// Die absolute Range bleibt als Fallback im userInfo (z.B. für Sprünge
    /// ohne Treffer-Kontext wie „Zu Zeile springen").
    ///
    /// `requiring` nennt das Dokument, dem der Sprung gilt. Ist es nicht mehr
    /// das aktive, unterbleibt der Post ganz — siehe `MatchJumpTarget`.
    ///
    /// `generation` ist die von `Workspace.beginMatchJump()` gezogene Nummer
    /// des Auftrags. Hat der Nutzer inzwischen erneut navigiert, ist sie
    /// veraltet und der Post unterbleibt — auch dann, wenn beide Aufträge
    /// dasselbe Dokument meinen und der `requiring`-Guard deshalb wahr bleibt.
    @discardableResult
    func postMatchJump(_ match: BufferSearch.Match, for workspace: Workspace,
                       requiring target: MatchJumpTarget? = nil,
                       generation: Int? = nil) -> Bool {
        if let generation, !workspace.isCurrentMatchJump(generation) { return false }
        guard target?.isActive(in: workspace) ?? true else { return false }
        let end = BufferSearch.endLineColumn(startLine: match.line,
                                             startColumn: match.column,
                                             matchText: match.matchText)
        // Zusätzlich zum Post als konsumierbaren Zustand hinterlegen: Fällt
        // die Notification in eine Editor-Neuerzeugung, holt der frisch
        // eingehängte Editor den Sprung aus `pendingEditorJump` nach.
        workspace.pendingEditorJump = PendingEditorJump(
            documentID: workspace.activeTab?.documentID,
            startLine: match.line, startColumn: match.column,
            endLine: end.line, endColumn: end.column,
            range: match.range)
        // `object` adressiert genau EIN Dokumentfenster. Ohne diese Zuordnung
        // würden bei mehreren offenen Workspaces alle EditorView-Instanzen
        // denselben Treffer-Sprung verarbeiten.
        post(name: .fastraJumpToRange, object: workspace, userInfo: [
            "range": NSValue(range: match.range),
            "startLine": match.line, "startColumn": match.column,
            "endLine": end.line, "endColumn": end.column,
        ])
        return true
    }
}
