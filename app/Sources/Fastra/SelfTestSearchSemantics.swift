// Zusammengehörige fensterlose Suchabläufe; Laufzeit, Abschluss und Cleanup
// bleiben beim gestarteten SelfTest. Asynchrone Fortsetzungen halten diesen Wert.
import Foundation

struct SelfTestSearchSemantics {
    private let workspace: Workspace
    private let waitForBody: (TimeInterval, TimeInterval, @escaping () -> Bool,
                      @escaping (SelfTestPollBudget) -> Void, @escaping () -> Void) -> Void
    private let finish: (Bool, String) -> Never

    init(workspace: Workspace,
         waitFor: @escaping (TimeInterval, TimeInterval, @escaping () -> Bool,
                            @escaping (SelfTestPollBudget) -> Void, @escaping () -> Void) -> Void,
         finish: @escaping (Bool, String) -> Never) {
        self.workspace = workspace
        self.waitForBody = waitFor
        self.finish = finish
    }

    // Argumentlabels bleiben an den unveränderten Ablaufaufrufen lesbar;
    // der Funktionswert führt weiterhin SelfTests privaten Waiter aus.
    private func waitFor(budget: TimeInterval, pause: TimeInterval,
                         condition: @escaping () -> Bool,
                         onTimeout: @escaping (SelfTestPollBudget) -> Void,
                         then: @escaping () -> Void) {
        waitForBody(budget, pause, condition, onTimeout, then)
    }

    // MARK: - Selbsttest search

    /// Treibt Workspace + SearchRunner end-to-end in vier Teilprüfungen:
    ///
    /// a) Buffer-Scope: Bekannten Text laden, Pattern mit exakt N Treffern
    ///    setzen, aufs Debounce pollen (120 ms Buffer-Debounce), prüfen, dass
    ///    `bufferMatches.count == N` und Zeile/Spalte des ersten Treffers stimmen.
    ///
    /// b) Live-Ordner-Scope: Temp-Ordner mit 2 Textdateien anlegen, Scope auf
    ///    `.folder` wechseln, Pattern ≥ 3 Zeichen (Live-Schwelle) setzen, den
    ///    Temp-Ordner als einzigen aktivierten Ordner eintragen, auf das Folder-
    ///    Debounce pollen (~0,42 s + async), prüfen, dass `folderTotalMatches`
    ///    gleich der erwarteten Summe ist. Danach Temp-Ordner aufräumen.
    ///
    /// c) Negativ-Pfad (Buffer-Scope): Pattern das nichts matcht → 0 Treffer
    ///    nach Debounce-Wartezeit.
    ///
    /// d) Großer Buffer: begrenzte Trefferliste und echte Gesamtzahl prüfen.
    ///
    /// PASS nur wenn alle vier Teilprüfungen bestehen. FAIL benennt den
    /// konkreten Teilschritt und gibt Soll- vs. Ist-Wert aus.
    func runSearchTest() {
        let ws = workspace

        // ── Teiltest a: Buffer-Scope ──────────────────────────────────────
        //
        // Eindeutiger Inhalt mit genau 3 Vorkommen von „TESTMARKER".
        // Variiert die Zeilenlängen bewusst, damit Zeile/Spalte-Logik
        // nicht zufällig durch gleich lange Zeilen trivial klappt.
        // Inhalt mit genau 3 „TESTMARKER"-Vorkommen (Erwartungswerte stehen in
        // `runSearchTestAfterLoad` — ausgelagert wegen asynchronem loadFile).
        let bufferContent = "erste Zeile ohne Treffer\n"
            + "zweite Zeile TESTMARKER hier\n"
            + "kurz\n"
            + "TESTMARKER am Zeilenbeginn\n"
            + "eine mittellange vierte Zeile, dann TESTMARKER am Ende"

        // Temp-Datei für den Buffer-Test — Workspace.loadFile ist der
        // offizielle Weg, Inhalt in einen Tab zu bringen (gleicher Pfad
        // wie der Tab-Wechsel-Test).
        let tmpBuf = selfTestTemporaryDirectory()
            .appendingPathComponent("fastra-search-buf-\(UUID().uuidString).txt")
        do { try bufferContent.write(to: tmpBuf, atomically: true, encoding: .utf8) }
        catch { finish(false, "(a) Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        // loadFile ist jetzt asynchron (v0.9) — Temp-Datei-Löschung und
        // Folge-Schritte in der Completion, damit der Inhalt beim Prüfen
        // wirklich im Tab steht und die Datei beim Hintergrund-Read existiert.
        ws.loadFile(at: tmpBuf) { ok in
            // Temp-Datei erst nach erfolgtem Lesen löschen.
            try? FileManager.default.removeItem(at: tmpBuf)
            guard ok else { finish(false, "(a) loadFile schlug fehl (completion false)") }
            runSearchTestAfterLoad(ws)
        }
    }

    /// Folge-Schritte von `runSearchTest` nach erfolgreichem Datei-Laden.
    /// Ausgelagert, damit runSearchTest übersichtlich bleibt.
    private func runSearchTestAfterLoad(_ ws: Workspace) {
        // Erwartungswerte: identisch mit den lokalen Konstanten in runSearchTest.
        let expectedBufferCount = 3
        let expectedFirstLine   = 2
        let expectedFirstCol    = 14

        // Die Live-Suche arbeitet nur bei sichtbarer Suchmaske. Das ist der
        // reale Nutzerpfad und verhindert ungefragte Volltextläufe beim
        // bloßen Öffnen großer Dateien.
        ws.showSearchDialog = true

        // Scope sicher auf .file setzen. SearchRunner erkennt den Wechsel
        // über seinen Combine-Trigger und sucht im Buffer neu.
        ws.scope = .file
        ws.useRegex = false          // Plain-Text → kein Regex-Syntax-Fehler möglich
        ws.caseSensitive = true
        ws.findPattern = "TESTMARKER"

        // Buffer-Debounce = 120 ms; wir pollen bis zu 2 Sekunden engmaschig
        // und gehen erst weiter, wenn die erwartete Trefferanzahl erreicht ist
        // oder das Fenster abgelaufen ist.
        pollForBufferMatches(ws,
                             expectedCount: expectedBufferCount,
                             expectedFirstLine: expectedFirstLine,
                             expectedFirstCol: expectedFirstCol)
    }

    /// Pollt auf `bufferMatches.count == expectedCount`. Läuft max. ~2 s.
    /// Bei Erfolg → Teiltest b starten. Bei Timeout oder falschen Werten → FAIL.
    private func pollForBufferMatches(
        _ ws: Workspace,
        expectedCount: Int,
        expectedFirstLine: Int,
        expectedFirstCol: Int
    ) {
        // Bisher 67 Ticks × 30 ms ≈ 2 Sekunden Beobachtungsfenster.
        waitFor(budget: 2.01, pause: 0.03,
                condition: { ws.bufferMatches.count == expectedCount },
                onTimeout: { book in
                    finish(false,
                        "(a) Buffer-Matches: \(ws.bufferMatches.count), "
                        + "erwartet \(expectedCount) "
                        + "(Pattern=\"\(ws.findPattern)\", "
                        + "searchError=\(ws.searchError ?? "nil"), "
                        + "visible=\(ws.showSearchDialog), scope=\(ws.scope), "
                        + "searching=\(ws.bufferSearching), "
                        + "optionsCurrent=\(ws.visibleBufferResultsOptions == ws.currentSearchOptions), "
                        + "tabs=\(ws.tabs.count), loading=\(ws.activeTab?.isLoading ?? false), "
                        + "textUTF16=\((ws.activeTab?.content ?? "").utf16.count), "
                        + "selectionOnly=\(ws.searchInSelectionOnly), "
                        + "range=\(String(describing: ws.activeSearchRange))) "
                        + "— \(book.summary)")
                }) {
            // Richtige Anzahl → Zeile/Spalte des ersten Treffers prüfen.
            let first = ws.bufferMatches[0]
            if first.line != expectedFirstLine || first.column != expectedFirstCol {
                finish(false,
                    "(a) Treffer-Anzahl \(ws.bufferMatches.count) korrekt, aber erster Treffer "
                    + "an Z\(first.line)/S\(first.column), erwartet "
                    + "Z\(expectedFirstLine)/S\(expectedFirstCol)")
            }
            // Teiltest a bestanden → weiter mit b.
            runSearchTestPartB(ws)
        }
    }

    /// Teiltest b: Live-Ordner-Suche mit einem echten Temp-Ordner.
    private func runSearchTestPartB(_ ws: Workspace) {
        // Temp-Ordner mit eindeutigem Namen anlegen (die Sandbox-Wurzel der
        // Selbsttests; die App hat dort Schreibrecht).
        let tmpDir = selfTestTemporaryDirectory()
            .appendingPathComponent("fastra-search-folder-\(UUID().uuidString)").path
        do {
            try FileManager.default.createDirectory(
                atPath: tmpDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            finish(false, "(b) Temp-Ordner nicht anlegbar: \(error.localizedDescription)")
        }

        // Datei 1: 2 Treffer. Datei 2: 1 Treffer → Summe 3.
        let file1 = (tmpDir as NSString).appendingPathComponent("a.txt")
        let file2 = (tmpDir as NSString).appendingPathComponent("b.txt")
        let folderPattern = "ORDNERMARKER"   // ≥ 3 Zeichen → Live-Schwelle OK
        let expectedFolderTotal = 3

        do {
            try "Zeile 1\nORDNERMARKER erste\nORDNERMARKER zweite\n"
                .write(toFile: file1, atomically: true, encoding: .utf8)
            try "Keine Zeile davor\nORDNERMARKER dritte\n"
                .write(toFile: file2, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(atPath: tmpDir)
            finish(false, "(b) Testdatei nicht schreibbar: \(error.localizedDescription)")
        }

        // Scope wechseln und Temp-Ordner als einzigen aktivierten Eintrag
        // setzen. Alle anderen Einträge deaktivieren, damit kein alter
        // Ordner die Trefferzahl verfälscht.
        ws.recentSearchFolders = ws.recentSearchFolders.map { entry in
            var e = entry; e.enabled = false; return e
        }
        ws.recentSearchFolders.insert(
            SearchFolderEntry(path: tmpDir, enabled: true),
            at: 0
        )
        ws.scope = .folder
        ws.useRegex = false
        ws.caseSensitive = true
        // Pattern zuletzt setzen → Combine-Trigger feuert und startet
        // den SearchRunner-Debounce-Zyklus.
        ws.findPattern = folderPattern

        // Folder-Debounce: ~0,42 s nach dem Trigger (120 ms Pipeline-
        // Debounce + 300 ms Extra-Debounce in SearchRunner). Dann läuft
        // FolderSearch async via Task.detached. Wir pollen bis zu 3 s.
        pollForFolderMatches(ws,
                             expectedTotal: expectedFolderTotal,
                             tmpDir: tmpDir)
    }

    /// Pollt auf `folderTotalMatches == expectedTotal`. Läuft max. ~3 s.
    /// Bei Erfolg → Aufräumen + Teiltest c. Bei Timeout → FAIL + Aufräumen.
    private func pollForFolderMatches(
        _ ws: Workspace,
        expectedTotal: Int,
        tmpDir: String
    ) {
        // Bisher 100 Ticks × 30 ms = 3 Sekunden Beobachtungsfenster.
        //
        // Der frühe Abbruch braucht weiterhin einen Durchlaufzähler: Eine
        // abgeschlossene Suche mit falschem Ergebnis ist erst nach dem
        // Mindest-Debounce (~14 × 30 ms = 420 ms) ein Befund, vorher könnte der
        // SearchRunner noch im Extra-Debounce stehen. Der Helfer ruft
        // `condition` je Durchlauf genau einmal und nie zusätzlich im
        // Timeout-Zweig — deshalb zählt die Bedingung hier selbst mit, und
        // `polls` entspricht exakt dem früheren `tick`.
        var polls = 0
        waitFor(budget: 3, pause: 0.03,
                condition: {
                    let tick = polls
                    polls += 1
                    // Suche noch aktiv → warten (kein vorzeitiges FAIL bei 0
                    // Treffern mitten in einem laufenden Folder-Lauf).
                    if ws.folderSearching { return false }
                    if ws.folderTotalMatches == expectedTotal { return true }
                    if !ws.folderNeedsSearch, tick >= 14 {
                        try? FileManager.default.removeItem(atPath: tmpDir)
                        finish(false,
                            "(b) folderTotalMatches=\(ws.folderTotalMatches), "
                            + "erwartet \(expectedTotal) "
                            + "(folderNeedsSearch=\(ws.folderNeedsSearch), "
                            + "folderSearching=\(ws.folderSearching), "
                            + "searchError=\(ws.searchError ?? "nil"))")
                    }
                    return false
                },
                onTimeout: { book in
                    try? FileManager.default.removeItem(atPath: tmpDir)
                    if ws.folderSearching {
                        finish(false,
                            "(b) Folder-Suche noch aktiv — kein Ergebnis — \(book.summary)")
                    }
                    finish(false,
                        "(b) Folder-Treffer: \(ws.folderTotalMatches), "
                        + "erwartet \(expectedTotal) — \(book.summary)")
                }) {
            // Teiltest b bestanden → Aufräumen und weiter mit c.
            try? FileManager.default.removeItem(atPath: tmpDir)
            runSearchTestPartC(ws)
        }
    }

    /// Teiltest c: Negativ-Pfad — Pattern, das nichts matcht → 0 Treffer.
    private func runSearchTestPartC(_ ws: Workspace) {
        // Zurück auf Buffer-Scope mit dem Tab aus Teiltest a.
        ws.scope = .file
        ws.useRegex = false
        ws.caseSensitive = true
        // Pattern, das im TESTMARKER-Inhalt definitiv nicht vorkommt.
        ws.findPattern = "GIBTESNICHT_XYZ_9999"

        // Buffer-Debounce (120 ms) abwarten, dann Ergebnis prüfen.
        pollForZeroMatches(ws)
    }

    /// Pollt auf eine abgeschlossene Negativsuche. Max. ~1 s.
    private func pollForZeroMatches(_ ws: Workspace) {
        // Bisher 34 Ticks × 30 ms ≈ 1 Sekunde Beobachtungsfenster.
        waitFor(budget: 1.02, pause: 0.03,
                condition: { SelfTest.hasCompletedEmptyBufferSearch(ws) },
                onTimeout: { book in
                    finish(false,
                        "(c) bufferMatches.count=\(ws.bufferMatches.count), "
                        + "erwartet 0 (Pattern=\"\(ws.findPattern)\") — \(book.summary)")
                }) {
            // Teiltest c bestanden → weiter mit d (Cap/Async).
            runSearchTestPartD(ws)
        }
    }

    /// Teiltest d: Großer Buffer und kurzes Pattern. Die asynchrone Suche über
    /// Workspace und SearchRunner muss die Trefferliste begrenzen und zugleich
    /// die echte Gesamtzahl liefern, ohne den Main-Thread zu blockieren.
    private func runSearchTestPartD(_ ws: Workspace) {
        // 5000 Zeilen mit je einem „1" → 5000 Treffer, Cap = 2000.
        let bigContent = String(repeating: "marker1zeile\n", count: 5000)
        let tmpBig = selfTestTemporaryDirectory()
            .appendingPathComponent("fastra-search-big-\(UUID().uuidString).txt")
        do { try bigContent.write(to: tmpBig, atomically: true, encoding: .utf8) }
        catch { finish(false, "(d) Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmpBig) { ok in
            try? FileManager.default.removeItem(at: tmpBig)
            guard ok else { finish(false, "(d) loadFile schlug fehl (completion false)") }
            ws.scope = .file
            ws.useRegex = false
            ws.caseSensitive = true
            ws.findPattern = "1"
            pollForCappedBuffer(ws)
        }
    }

    /// Pollt, bis die async Buffer-Suche fertig ist (`!bufferSearching`), und
    /// prüft Cap + echte Gesamtzahl. Max. ~3 s.
    private func pollForCappedBuffer(_ ws: Workspace) {
        let expectedTotal = 5000
        let expectedCap = BufferSearch.defaultMaxMatches
        // Bisher 100 × 30 ms = 3 s — ein Zähler für beide Zweige („noch am
        // Suchen" und „fertig, aber falsche Zahl"), das bleibt so. Dass dieser
        // Poll überhaupt drankommt, belegt zugleich: die Suche läuft async,
        // der Main-Thread tickt weiter.
        waitFor(budget: 3, pause: 0.03,
                condition: { !ws.bufferSearching && ws.bufferTotalMatches == expectedTotal },
                onTimeout: { book in
                    if ws.bufferSearching {
                        finish(false, "(d) Buffer-Suche noch aktiv — \(book.summary)")
                    }
                    finish(false,
                        "(d) bufferTotalMatches=\(ws.bufferTotalMatches), "
                        + "erwartet \(expectedTotal) (searchError=\(ws.searchError ?? "nil")) "
                        + "— \(book.summary)")
                }) {
            guard ws.bufferMatches.count == expectedCap else {
                finish(false,
                    "(d) bufferMatches.count=\(ws.bufferMatches.count), "
                    + "erwartet Cap \(expectedCap)")
            }
            guard ws.bufferResultsWereCapped else {
                finish(false, "(d) bufferResultsWereCapped=false, erwartet true")
            }
            // Alles bestanden — Gesamt-PASS.
            finish(true,
                "(a) Buffer-Treffer + Zeile/Spalte korrekt, "
                + "(b) Folder-Treffer korrekt, "
                + "(c) Negativ-Pfad korrekt (0 Treffer), "
                + "(d) Cap greift: \(expectedCap) gelistet / \(expectedTotal) gezählt, async")
        }
    }

    // MARK: - „Nur in Auswahl" (K3) — fensterlos

    /// Lädt einen Buffer mit drei „foo"-Treffern (je einer pro Zeile), friert
    /// eine Selektion auf Zeile 2 ein und prüft, dass die Suche nur den
    /// Treffer in der Auswahl liefert — mit absoluter Zeilennummer (2).
    /// Danach „Nur in Auswahl" wieder aus → alle drei Treffer.
    func runSelSearchTest() {
        let ws = workspace
        ws.showSearchDialog = true
        // Zeilen je 11 Zeichen: „xxx foo yyy". foo-Offsets: 4 (Z1), 16 (Z2), 28 (Z3).
        let content = "aaa foo bbb\nccc foo ddd\neee foo fff"
        let tmp = selfTestTemporaryDirectory()
            .appendingPathComponent("fastra-selsearch-\(UUID().uuidString).txt")
        do { try content.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }

            ws.scope = .file
            ws.useRegex = false
            ws.caseSensitive = false
            ws.findPattern = "foo"
            // Selektion auf Zeile 2 („ccc foo ddd", Offset 12, Länge 11)
            // einfrieren → nur der mittlere Treffer darf zählen.
            ws.selectionRange = NSRange(location: 12, length: 11)
            ws.setSearchInSelectionOnly(true)
            pollSelSearchRestricted(ws)
        }
    }

    /// Pollt auf genau 1 Treffer (in der Auswahl), Zeile 2 / Spalte 5.
    private func pollSelSearchRestricted(_ ws: Workspace) {
        // Bisher 67 × 30 ms ≈ 2 s.
        waitFor(budget: 2.01, pause: 0.03,
                condition: { ws.bufferMatches.count == 1 },
                onTimeout: { book in
                    finish(false, "(restricted) bufferMatches=\(ws.bufferMatches.count), erwartet 1 "
                        + "(searchError=\(ws.searchError ?? "nil")) — \(book.summary)")
                }) {
            let m = ws.bufferMatches[0]
            // foo in Zeile 2 beginnt an Offset 16 → Spalte 16−12+1 = 5.
            if m.line != 2 || m.column != 5 {
                finish(false, "(restricted) Treffer an Z\(m.line)/S\(m.column), erwartet Z2/S5")
            }
            // Phase 2: „Nur in Auswahl" aus → wieder alle drei Treffer.
            ws.setSearchInSelectionOnly(false)
            pollSelSearchFull(ws)
        }
    }

    /// Pollt auf alle 3 Treffer, nachdem „Nur in Auswahl" abgeschaltet wurde.
    private func pollSelSearchFull(_ ws: Workspace) {
        // Bisher 67 × 30 ms ≈ 2 s.
        waitFor(budget: 2.01, pause: 0.03,
                condition: { ws.bufferMatches.count == 3 },
                onTimeout: { book in
                    finish(false, "(full) bufferMatches=\(ws.bufferMatches.count) nach Abschalten, "
                        + "erwartet 3 — \(book.summary)")
                }) {
            finish(true, "Nur-in-Auswahl: 1 Treffer (Z2/S5) in Auswahl, 3 ohne Auswahl")
        }
    }

    // MARK: - Platzhalter-Suche `*` — fensterlos

    /// Lädt „ring, The", sucht im Plain-Modus mit `*, the` (Platzhalter →
    /// 1 Treffer über die ganze Zeile) und schaltet dann den Mini-Schalter
    /// „* wörtlich" ein (→ 0 Treffer, weil der literale Text „*, the" fehlt).
    /// Belegt die Verdrahtung und den Live-Trigger des Schalters.
    func runWildcardTest() {
        let ws = workspace
        ws.showSearchDialog = true
        let tmp = selfTestTemporaryDirectory()
            .appendingPathComponent("fastra-wildcard-\(UUID().uuidString).txt")
        do { try "ring, The".write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            try? FileManager.default.removeItem(at: tmp)
            guard ok else { finish(false, "loadFile schlug fehl (completion false)") }
            ws.scope = .file
            ws.useRegex = false
            ws.treatWildcardLiterally = false
            // Ersetzen-Seite vor dem Find setzen, damit die erste Such-Runde
            // schon den aufgelösten `replacedText` trägt — genau dieser speist
            // die Inline-Live-Vorschau. `The *` → `The $1`.
            ws.replacePattern = "The *"
            ws.findPattern = "*, the"
            pollWildcardPlaceholder(ws)
        }
    }

    /// Phase 1: Platzhalter aktiv → genau 1 Treffer (greift über die ganze Zeile).
    private func pollWildcardPlaceholder(_ ws: Workspace) {
        // Bisher 67 × 30 ms ≈ 2 s.
        waitFor(budget: 2.01, pause: 0.03,
                condition: { ws.bufferMatches.count == 1 && ws.searchError == nil },
                onTimeout: { book in
                    finish(false, "(platzhalter) bufferMatches=\(ws.bufferMatches.count), erwartet 1 "
                        + "(searchError=\(ws.searchError ?? "nil")) — \(book.summary)")
                }) {
            let m = ws.bufferMatches[0]
            // Der Treffer deckt „ring, The" ab (gierige Gruppe + Anker „, the").
            if m.matchText != "ring, The" {
                finish(false, "(platzhalter) Treffer-Text \"\(m.matchText)\", erwartet \"ring, The\"")
            }
            // Ersetzen-Seite end-to-end: der Platzhalter-Replace „The *" muss in
            // der Live-Suche bereits zu „The ring" aufgelöst sein. Genau dieser
            // `replacedText` ist die Datenquelle der Inline-Vorschau — der Check
            // sichert den Vorschau-Pfad ohne fragiles View-Tree-Abtasten ab.
            if m.replacedText != "The ring" {
                finish(false, "(platzhalter) replacedText \"\(m.replacedText)\", erwartet \"The ring\"")
            }
            ws.treatWildcardLiterally = true   // → literal, Live-Trigger
            pollWildcardLiteral(ws)
        }
    }

    /// Phase 2: Mini-Schalter „wörtlich" an → 0 Treffer (literaler „*, the" fehlt).
    private func pollWildcardLiteral(_ ws: Workspace) {
        // Bisher 67 × 30 ms ≈ 2 s.
        waitFor(budget: 2.01, pause: 0.03,
                condition: { SelfTest.hasCompletedEmptyBufferSearch(ws) },
                onTimeout: { book in
                    finish(false, "(literal) bufferMatches=\(ws.bufferMatches.count), "
                        + "erwartet 0 — \(book.summary)")
                }) {
            finish(true, "Platzhalter: 1 Treffer (ring, The) -> ersetzt zu The ring; literal: 0 Treffer")
        }
    }

}
