// SearchRunner.swift
//
// Beobachtet Such-relevante Felder im `Workspace`, ruft debounced
// `BufferSearch.find(...)` auf dem aktiven Tab und schreibt das
// Ergebnis nach `workspace.bufferMatches` / `workspace.searchError`
// zurück. Ein Objekt pro Workspace.
//
// Bewusst dünn gehalten: kein eigener Zustand außer dem Combine-
// Subscription-Bag. Die Suchlogik selbst lebt pur in `BufferSearch`
// und ist dort getestet.

import Foundation
import Combine

final class SearchRunner {
    private weak var workspace: Workspace?
    private var bag = Set<AnyCancellable>()
    /// Aktive Folder-Suche; wird beim nächsten Re-Run abgebrochen, damit
    /// während des Tippens nicht zwei Suchen gleichzeitig fertig werden
    /// und die Ergebnisse durcheinanderbringen.
    private var folderTask: Task<Void, Never>?
    /// Monotoner Lauf-Schlüssel. Er schließt das enge Race, in dem ein alter
    /// Task direkt vor `cancel()` fertig wird und sein Main-Actor-Update erst
    /// nach dem neuen Lauf zustellt.
    private var folderRunID = 0
    /// Aktive Buffer-Suche (Datei-/Geöffnet-Scope). Läuft async, damit ein
    /// großer Buffer + kurzes Pattern den Main-Thread NIE blockiert; wird
    /// beim nächsten Tastendruck/Toggle abgebrochen (kein Auflaufen veralteter
    /// Läufe). Vorher lief die Buffer-Suche synchron → Beachball.
    private var bufferTask: Task<Void, Never>?
    /// Derselbe Completion-Guard wie für Folder-Läufe. `cancel()` allein
    /// schließt das Race zwischen letzter Abbruchprüfung und MainActor-Update
    /// nicht; nur der aktuelle Lauf darf Treffer oder Spinner publizieren.
    private var bufferRunID = 0
    /// Extra-Debounce-Timer NUR für die Live-Ordner-Suche. Liegt zusätzlich
    /// zum 120-ms-Pipeline-Debounce, damit die (teure) Ordner-Suche erst
    /// ~0,4 s nach dem letzten Tastendruck startet (siehe `rerun`).
    private var folderDebounce: DispatchWorkItem?

    /// Mindestlänge des Suchausdrucks, ab der der Ordner-Scope LIVE beim
    /// Tippen sucht. Kürzere Pattern (1–2 Zeichen) träfen in großen Repos
    /// zehntausende Stellen und würden die App beim Live-Tippen lahmlegen —
    /// darunter sucht der Ordner-Scope erst auf expliziten „Suchen"/Return.
    static let minFolderLiveChars = 3
    /// Zusätzliche Verzögerung (ms) der Live-Ordner-Suche, ON TOP des
    /// 120-ms-Pipeline-Debounce → ~0,42 s nach dem letzten Tastendruck.
    static let folderLiveExtraDebounceMs = 300

    /// Art einer Modelländerung, die möglicherweise eine neue Suche braucht.
    /// Nicht jeder publizierte Workspace-Wert gehört in jedem Scope zur
    /// Trefferbasis: Ein Tabwechsel ist für Datei/Geöffnet relevant, darf aber
    /// eine fertige Ordnersuche beim Öffnen ihres Treffers nicht verwerfen.
    enum SearchInput {
        case options
        case activeTab
        case activeDocument
        case scope
        case folderSources
        case projectSources
    }

    static func inputAffectsSearch(_ input: SearchInput,
                                   in scope: Workspace.SearchScope) -> Bool {
        switch input {
        case .options, .scope:
            return true
        case .activeTab:
            // Der aktive Tab ändert nur die Datei-Suche. „Geöffnet" umfasst
            // ohnehin alle Tabs; ein Treffer-Sprung über eine Tabgrenze darf
            // dort weder neu suchen noch seinen flachen Index verwerfen.
            return scope == .file
        case .activeDocument:
            return scope == .file || scope == .open
        case .folderSources:
            return scope == .folder
        case .projectSources:
            return scope == .project
        }
    }

    init(workspace: Workspace) {
        self.workspace = workspace

        // Alle Such-Inputs in einen Trigger-Stream zusammenführen. Wir
        // brauchen die konkreten Werte hier NICHT — beim Re-Run lesen
        // wir sie direkt vom Workspace. Combine erlaubt CombineLatest
        // nur bis Arity 4, deshalb über MergeMany.
        let triggers: [AnyPublisher<SearchInput, Never>] = [
            workspace.$findPattern.dropFirst().map { _ in SearchInput.options }.eraseToAnyPublisher(),
            workspace.$replacePattern.dropFirst().map { _ in SearchInput.options }.eraseToAnyPublisher(),
            workspace.$useRegex.dropFirst().map { _ in SearchInput.options }.eraseToAnyPublisher(),
            workspace.$caseSensitive.dropFirst().map { _ in SearchInput.options }.eraseToAnyPublisher(),
            workspace.$wholeWord.dropFirst().map { _ in SearchInput.options }.eraseToAnyPublisher(),
            // Mini-Schalter „* wörtlich nehmen" (Feature J) → Such-Semantik
            // ändert sich (Platzhalter ⇄ literal) → neu suchen.
            workspace.$treatWildcardLiterally.dropFirst().map { _ in SearchInput.options }.eraseToAnyPublisher(),
            // „Nur in Auswahl" (K3) umschalten → Buffer-Suche neu laufen
            // lassen (anderer Such-Bereich).
            workspace.$searchInSelectionOnly.dropFirst().map { _ in SearchInput.activeDocument }.eraseToAnyPublisher(),
            workspace.$activeTabID.dropFirst().map { _ in SearchInput.activeTab }.eraseToAnyPublisher(),
            workspace.$tabs.dropFirst().map { _ in SearchInput.activeDocument }.eraseToAnyPublisher(),
            workspace.$scope.dropFirst().map { _ in SearchInput.scope }.eraseToAnyPublisher(),
            workspace.$recentSearchFolders.dropFirst().map { _ in SearchInput.folderSources }.eraseToAnyPublisher(),
            workspace.$fileTypeFilter.dropFirst().map { _ in SearchInput.folderSources }.eraseToAnyPublisher(),
            workspace.$projectSearchConfiguration.dropFirst().map { _ in SearchInput.projectSources }.eraseToAnyPublisher(),
            workspace.$projectURL.dropFirst().map { _ in SearchInput.projectSources }.eraseToAnyPublisher(),
        ]

        let triggerStream = Publishers.MergeMany(triggers)
            .filter { [weak workspace] input in
                // Solange die Suchmaske geschlossen ist, gibt es weder eine
                // sichtbare Live-Suche noch eine Vorschau, die aktuell
                // gehalten werden müsste. Vorher startete schon das Laden
                // eines Tabs die gespeicherte Demo-Suche über den kompletten
                // Buffer — bei Megazeilen reine, unsichtbare Zusatzarbeit.
                guard let workspace, workspace.showSearchDialog else {
                    return false
                }
                let scope = workspace.scope
                return Self.inputAffectsSearch(input, in: scope)
            }
            // Die Art des Inputs bleibt erhalten: Die Sofort-Invalidierung
            // unten behandelt einen Dokumentwechsel anders als ein neues
            // Muster (siehe `searchInputsDidChange`).
            .share()

        // Sicherheitspfad ohne Debounce: Sobald ein Suchinput wechselt,
        // gehören die sichtbaren Projekt-/Ordner-Treffer nicht mehr zur
        // aktuellen Semantik. Sofort leeren und laufende Tasks abbrechen;
        // Navigation, Vorschau und Apply sehen damit nie einen Altstand.
        triggerStream
            .sink { [weak self] input in
                // Combine liefert synchron auf dem Thread, der den Suchinput
                // geschrieben hat. Im Produkt ist das immer der Main-Thread —
                // dort MUSS die Invalidierung auch synchron bleiben, damit
                // Navigation, Vorschau und Apply nie einen Altstand sehen.
                // Die parallele Testsuite schreibt Inputs dagegen von eigenen
                // Threads: Liefe die Invalidierung dort, beschrieben zwei
                // Threads gleichzeitig dieselben starken Referenzen
                // (`folderTask`, `folderDebounce`, `visibleBufferResults-
                // Options`) — das alte Objekt würde doppelt freigegeben,
                // beobachtet am 2026-08-09 als Heap-Korruption (SIGSEGV mit
                // Müll-Adressen). Von fremden Threads zieht die Invalidierung
                // deshalb auf die Main-Queue um; dort serialisiert sie sich
                // mit `rerun()`. (Regressionstest:
                // WorkspaceParallelStressTests.)
                if Thread.isMainThread {
                    self?.searchInputsDidChange(input)
                } else {
                    DispatchQueue.main.async { self?.searchInputsDidChange(input) }
                }
            }
            .store(in: &bag)

        triggerStream
            // 120 ms ist knapp genug fürs Tipp-Gefühl, lang genug, damit
            // selbst auf großen Buffern nicht jede Taste ein Re-Search
            // anstößt. Bei Bedarf später konfigurierbar machen.
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.rerun() }
            .store(in: &bag)

        // Öffnen der Maske startet genau einen Lauf mit den aktuellen
        // Eingaben. Schließen beendet laufende Arbeit sofort; die alten
        // Treffer dürfen danach insbesondere keinen Apply mehr freigeben.
        workspace.$showSearchDialog
            .dropFirst()
            .sink { [weak self] isVisible in
                if isVisible {
                    // @Published sendet vor der eigentlichen Zuweisung. Erst
                    // im nächsten Main-Turn sieht `rerun()` deshalb den
                    // neuen sichtbaren Zustand.
                    DispatchQueue.main.async {
                        self?.searchVisibilityDidChange(true)
                    }
                } else if Thread.isMainThread {
                    // Schließen muss laufende Arbeit dagegen sofort stoppen;
                    // dafür reicht der mitgelieferte neue Wert.
                    self?.searchVisibilityDidChange(false)
                } else {
                    DispatchQueue.main.async {
                        self?.searchVisibilityDidChange(false)
                    }
                }
            }
            .store(in: &bag)

        // Initial einmal prüfen. Die Maske startet normalerweise geschlossen;
        // `rerun()` beendet sich dann ohne Volltextarbeit.
        // Dieser Dispatch ist der FRÜHESTE Weg, auf dem ein frisch
        // erzeugter Workspace die Main-Queue erreicht — noch vor
        // `Workspace.shared`. `Workspace.init` muss deshalb alle
        // @Published-Speicher anlegen, BEVOR es den SearchRunner erzeugt
        // (siehe dort, Vorwärm-Kommentar).
        DispatchQueue.main.async { [weak self] in self?.rerun() }
    }

    deinit {
        folderDebounce?.cancel()
        folderTask?.cancel()
        bufferTask?.cancel()
    }

    static func completionBelongsToCurrentRun(_ completedRunID: Int,
                                              currentRunID: Int) -> Bool {
        completedRunID == currentRunID
    }

    /// Entscheidet, ob ein Such-Input (Tippen, Options-Toggle) BEDINGUNGSLOS
    /// SOFORT eine Suche auslösen darf. Buffer-Scopes (Datei/Geöffnet) liegen
    /// im RAM — Live-Suche ist günstig, daher immer live. Der Ordner-Scope
    /// sucht NICHT bedingungslos live (kann tausende Dateien betreffen);
    /// er sucht live nur OBERHALB einer Mindestlänge + mit längerem Debounce
    /// (siehe `shouldRunFolderLive` / `rerun`). Pur + statisch → unit-testbar.
    static func runsLive(for scope: Workspace.SearchScope) -> Bool {
        switch scope {
        case .file, .open:       return true
        case .folder, .project:  return false
        }
    }

    /// Entscheidet, ob der Ordner-Scope für dieses Pattern LIVE beim Tippen
    /// sucht. Schutz vor Freeze in großen Repos: erst ab `minFolderLiveChars`
    /// nicht-leeren Zeichen. Darunter wartet der Ordner-Scope auf den
    /// expliziten „Suchen"/Return-Trigger (der diese Schwelle bewusst
    /// umgeht). Pur + statisch → unit-testbar.
    static func shouldRunFolderLive(for pattern: String) -> Bool {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines).count >= minFolderLiveChars
    }

    /// Liefert die Fehlermeldung, wenn das Pattern syntaktisch ungültig ist —
    /// sonst `nil`. Ein leeres Pattern gilt als (noch) gültig.
    static func validationError(for options: SearchOptions) -> String? {
        guard !options.isEmpty else { return nil }
        do { _ = try ApplyEngine.buildRegex(options); return nil }
        catch { return (error as NSError).localizedDescription }
    }

    private func cancelPendingWork() {
        folderTask?.cancel()
        folderTask = nil
        folderRunID &+= 1
        bufferTask?.cancel()
        bufferTask = nil
        bufferRunID &+= 1
        folderDebounce?.cancel()
        folderDebounce = nil
    }

    private func searchVisibilityDidChange(_ isVisible: Bool) {
        guard let ws = workspace else { return }
        cancelPendingWork()
        guard isVisible else {
            ws.discardPendingOpenReplaceNavigation()
            ws.bufferSearching = false
            ws.folderSearching = false
            // Treffer sind außerhalb der Maske weiterhin über Statuszeile und
            // ⌘G-Navigation erreichbar. Deshalb nicht nur Apply sperren,
            // sondern die gesamte navigierbare Vorschau verwerfen. Spätere
            // Dokumentänderungen bleiben dann billig, ohne auf alte Ranges zu
            // zeigen; beim erneuten Öffnen startet ohnehin ein frischer Lauf.
            Self.clearAllPreview(ws)
            return
        }
        rerun()
    }

    /// Verwirft die sichtbare Ordner-/Projekt-Trefferbasis.
    ///
    /// `invalidatingJumps`: `true` entwertet zugleich alle offenen
    /// Sprungaufträge (`Workspace.invalidateMatchJumps`). Ein Trefferklick in
    /// einer noch ladenden Funddatei postet seinen Sprung erst in der
    /// Lade-Completion; kommt die nach einer Sucheingabe an, gehört der
    /// Treffer zu einer Liste, die es nicht mehr gibt — ohne Entwertung sprang
    /// der Editor dann zum alten Treffer und übernahm den alten Index in die
    /// neue Trefferbasis (Review 2026-08-22). Nur `false`, wenn der Aufrufer
    /// weiß, dass die Aufträge weiterhin gültig sind.
    private static func clearFolderPreview(_ ws: Workspace,
                                           invalidatingJumps: Bool) {
        ws.folderResults = []
        ws.folderTotalMatches = 0
        ws.folderResultsWereCapped = false
        ws.activeMatchIndex = 0
        if invalidatingJumps { ws.invalidateMatchJumps() }
    }

    private static func clearAllPreview(_ ws: Workspace) {
        clearFolderPreview(ws, invalidatingJumps: true)
        ws.bufferMatches = []
        ws.bufferTotalMatches = 0
        ws.bufferResultsWereCapped = false
        ws.openResults = []
        ws.openTotalMatches = 0
        ws.openResultsWereCapped = false
        ws.visibleBufferResultsOptions = nil
        ws.activeMatchIndex = 0
    }

    /// Unmittelbare Invalidierung vor beiden Debounce-Stufen.
    private func searchInputsDidChange(_: SearchInput) {
        guard let ws = workspace else { return }
        cancelPendingWork()
        // Muster, Optionen, Inhalt, Scope oder Quellen: Die navigierbare
        // Trefferbasis ist weg, offene Sprungaufträge mit ihr. Ein reiner
        // Tabwechsel im Geöffnet-Scope erreicht diesen Pfad nicht: Er ändert
        // die über alle Tabs gebildete Trefferbasis nicht und wird bereits in
        // `inputAffectsSearch` ausgefiltert. So behält ein Sprung über eine
        // Tabgrenze seinen Index und erzeugt keinen redundanten Suchlauf.
        Self.clearFolderPreview(ws, invalidatingJumps: true)
        // Die sichtbaren Buffer-/Geöffnet-Treffer bleiben absichtlich stehen
        // (sonst blinkte die Trefferzahl bei jedem Tastendruck auf 0), ihre
        // Freigabe für „Alle ersetzen" gilt aber ab sofort nicht mehr: Sie
        // gehören noch zum alten Muster. Erst der Neulauf unten setzt sie
        // wieder — dann passen Vorschau und Ersetzung wieder zusammen.
        ws.visibleBufferResultsOptions = nil

        guard ws.scope.isFolderLike else {
            ws.folderSearching = false
            ws.folderNeedsSearch = false
            return
        }

        let options = ws.currentSearchOptions
        ws.searchError = Self.validationError(for: options)
        let willRunLive = Self.shouldRunFolderLive(for: ws.findPattern)
            && !options.isEmpty
            && ws.searchError == nil
            && !ws.activeMultiFileSearchURLs.isEmpty
        ws.folderSearching = willRunLive
        ws.folderNeedsSearch = !willRunLive
    }

    /// Verwirft die sichtbaren Ordner-/Projekt-Treffer, weil FASTRA SELBST die
    /// Dateien auf der Platte verändert hat (Ordner-Apply, Rückgängig).
    ///
    /// Das ist bewusst kein Combine-Trigger: Ein Tabwechsel oder das Öffnen
    /// einer Funddatei darf eine fertige Ordnersuche weder leeren noch neu
    /// starten (siehe `inputAffectsSearch`). Nach einem eigenen
    /// Mehrdatei-Schreibgang stimmt die Trefferbasis dagegen nachweislich
    /// nicht mehr: Trefferzahl, Navigation und Sprungziele zeigten sonst auf
    /// Text, den es so nicht mehr gibt (Review 2026-08-06). Die Maske fragt
    /// danach über `folderNeedsSearch` nach einem neuen Such-Lauf, statt
    /// ungefragt eine teure Ordnersuche zu starten.
    func folderResultsBecameStale() {
        guard let ws = workspace, ws.scope.isFolderLike else { return }
        cancelPendingWork()
        Self.clearFolderPreview(ws, invalidatingJumps: true)
        ws.folderSearching = false
        ws.folderNeedsSearch = true
    }

    /// Reagiert auf einen Live-Trigger (Tippen, Options-Toggle, Tab- oder
    /// Scope-Wechsel). Buffer-Scopes (Datei/Geöffnet) suchen sofort. Der
    /// Ordner-Scope sucht gesteuert live: erst ab `minFolderLiveChars` Zeichen
    /// und mit zusätzlichem Debounce (`folderLiveExtraDebounceMs`), damit
    /// kurze Pattern in großen Repos die App nicht einfrieren. Darunter werden
    /// alte Ergebnisse verworfen und ein expliziter Such-Lauf vorgemerkt
    /// (`folderNeedsSearch`). Auch von außen aufrufbar (Tests / Refresh nach
    /// Einzel-Ersetzen).
    func rerun() {
        guard let ws = workspace else { return }
        ws.folderNavigationNotice = nil

        // Laufende Folder- UND Buffer-Suche + armierten Live-Timer immer
        // abbrechen — entweder weil der Scope wechselt oder weil sich die
        // Eingaben geändert haben (frischer Tastendruck → alles neu starten).
        cancelPendingWork()

        // `rerun()` ist auch ein interner Live-Trigger. Eine explizite Suche
        // aus dem Suchdialog geht dagegen direkt über `runFolderSearch()`.
        // So kann das bloße Öffnen oder Bearbeiten eines Dokuments niemals
        // im Hintergrund einen Volltextlauf starten.
        guard ws.showSearchDialog else {
            ws.discardPendingOpenReplaceNavigation()
            ws.bufferSearching = false
            ws.folderSearching = false
            return
        }

        if SearchRunner.runsLive(for: ws.scope) {
            if ws.scope == .open {
                runOpenSearch(ws)
            } else {
                ws.discardPendingOpenReplaceNavigation()
                runBufferSearch(ws)
            }
            return
        }

        ws.discardPendingOpenReplaceNavigation()

        // Ordner-Scope. Buffer-/Geöffnet-Treffer verwerfen (kein stale Rest
        // beim Zurückwechseln) und Pattern sofort validieren (roter Streifen).
        ws.openResults = []
        ws.openTotalMatches = 0
        ws.openResultsWereCapped = false
        ws.bufferMatches = []
        ws.bufferTotalMatches = 0
        ws.bufferResultsWereCapped = false
        ws.visibleBufferResultsOptions = nil
        // Den Buffer-Spinner ausdrücklich mit ausschalten. `cancelPendingWork()`
        // hat den laufenden Buffer-Task oben abgebrochen; ein abgebrochener Task
        // kehrt vor seinem Main-Actor-Update zurück und schaltet den Spinner
        // deshalb NIE selbst aus. Ohne diese Zeile blieb er hängen, sobald der
        // Ordner-Lauf danach am Guard scheitert (kurzes Pattern, kein Ordner) —
        // dann setzt ihn auch kein späterer `runFolderSearch` mehr zurück.
        ws.bufferSearching = false
        ws.searchError = SearchRunner.validationError(for: ws.currentSearchOptions)
        Self.clearFolderPreview(ws, invalidatingJumps: true)

        // Live nur oberhalb der Mindestlänge UND mit gültigem Pattern UND
        // mindestens einem aktivierten Ordner. Sonst: alte Ergebnisse weg,
        // expliziten Such-Lauf vormerken (Prompt in der leeren Liste).
        guard SearchRunner.shouldRunFolderLive(for: ws.findPattern),
              !ws.currentSearchOptions.isEmpty,
              !ws.activeMultiFileSearchURLs.isEmpty else {
            ws.folderResults = []
            ws.folderTotalMatches = 0
            ws.folderResultsWereCapped = false
            ws.folderSearching = false
            ws.folderNeedsSearch = true
            return
        }

        // Mindestlänge erreicht → nach kurzem Extra-Debounce live suchen.
        // (Der 120-ms-Pipeline-Debounce + diese ~300 ms ergeben ~0,42 s nach
        // dem letzten Tastendruck.) `runFolderSearch` läuft async (Task.
        // detached) → kein Main-Thread-Freeze; ein vorheriger Lauf wird oben
        // bereits abgebrochen.
        let work = DispatchWorkItem { [weak self] in self?.runFolderSearch() }
        folderDebounce = work
        ws.folderSearching = true
        ws.folderNeedsSearch = false
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(SearchRunner.folderLiveExtraDebounceMs),
            execute: work)
    }

    /// Asynchroner Such-Lauf auf dem aktiven Buffer (Datei-/Geöffnet-Scope).
    /// Läuft via `Task.detached` im Hintergrund + ist abbrechbar — der
    /// Main-Thread bleibt immer flüssig, auch bei kurzem Pattern in einem
    /// riesigen Buffer (kein Beachball, kein „sucht sich tot").
    private func runBufferSearch(_ ws: Workspace) {
        bufferTask?.cancel()
        bufferRunID &+= 1
        let runID = bufferRunID

        // Folder-/Geöffnet-Reste leeren, sonst zeigt die Maske beim
        // Zurückwechseln noch alte Treffer des anderen Scopes.
        ws.folderResults = []
        ws.folderTotalMatches = 0
        ws.folderResultsWereCapped = false
        ws.folderSearching = false
        ws.folderNeedsSearch = false
        ws.openResults = []
        ws.openTotalMatches = 0
        ws.openResultsWereCapped = false

        let options = ws.currentSearchOptions
        let text = ws.activeTab?.content ?? ""
        // „Nur in Auswahl" (K3): eingefrorene Selektions-Range mitnehmen
        // (nil, wenn die Option aus ist → ganzer Text).
        let searchRange = ws.activeSearchRange

        // Leeres Pattern → sofort leeren, ohne Hintergrund-Lauf/Spinner
        // (vermeidet Geflacker beim Tippen bis auf 0 Zeichen).
        guard !options.isEmpty else {
            bufferTask = nil
            ws.bufferMatches = []
            ws.bufferTotalMatches = 0
            ws.bufferResultsWereCapped = false
            ws.visibleBufferResultsOptions = nil
            ws.searchError = nil
            ws.bufferSearching = false
            return
        }

        // Spinner an; eigentliche Suche im Hintergrund.
        ws.bufferSearching = true
        bufferTask = Task.detached(priority: .userInitiated) { [weak self, weak ws] in
            // `Task.isCancelled` deckt beides ab: der nächste Tastendruck
            // cancelt diesen Task → find() bricht mitten im Scan ab.
            let result = BufferSearch.find(in: text, options: options,
                                           searchRange: searchRange,
                                           shouldCancel: { Task.isCancelled })
            if Task.isCancelled { return }
            await MainActor.run { [weak self, weak ws] in
                guard let self,
                      Self.completionBelongsToCurrentRun(
                        runID, currentRunID: self.bufferRunID),
                      let ws else { return }
                ws.bufferMatches = result.matches
                ws.bufferTotalMatches = result.totalMatches
                ws.bufferResultsWereCapped = result.wasCapped
                // Sichtbare Vorschau und ihre Optionen gehören zusammen und
                // werden deshalb im selben Schritt gesetzt.
                ws.visibleBufferResultsOptions = options
                ws.searchError = result.invalidPatternMessage
                ws.bufferSearching = false
                if ws.activeMatchIndex >= result.matches.count {
                    ws.activeMatchIndex = max(0, result.matches.count - 1)
                }
            }
        }
    }

    /// Asynchroner Such-Lauf über ALLE offenen Tabs (Geöffnet-Scope,
    /// BBEdit „Open text documents"). Gleiche Async-/Abbruch-Mechanik wie
    /// `runBufferSearch` — die Tabs liegen im RAM, Live-Suche ist günstig.
    /// Der Tab-Snapshot entsteht auf dem Main-Thread (Workspace-Zugriff),
    /// die eigentliche Suche läuft detached.
    private func runOpenSearch(_ ws: Workspace) {
        bufferTask?.cancel()
        bufferRunID &+= 1
        let runID = bufferRunID

        // Reste der anderen Scopes leeren (gleiches Muster wie Buffer-Pfad).
        ws.folderResults = []
        ws.folderTotalMatches = 0
        ws.folderResultsWereCapped = false
        ws.folderSearching = false
        ws.folderNeedsSearch = false
        ws.bufferMatches = []
        ws.bufferTotalMatches = 0
        ws.bufferResultsWereCapped = false
        ws.visibleBufferResultsOptions = nil

        let options = ws.currentSearchOptions
        // Lade-Tabs überspringen: deren `content` ist noch leer/halb —
        // Treffer darin wären Phantome.
        let inputs = ws.tabs.filter { !$0.isLoading }.map {
            OpenTabsSearch.TabInput(id: $0.id, title: $0.title, content: $0.content)
        }

        guard !options.isEmpty else {
            bufferTask = nil
            ws.discardPendingOpenReplaceNavigation()
            ws.openResults = []
            ws.openTotalMatches = 0
            ws.openResultsWereCapped = false
            ws.visibleBufferResultsOptions = nil
            ws.searchError = nil
            ws.bufferSearching = false
            return
        }

        ws.bufferSearching = true
        bufferTask = Task.detached(priority: .userInitiated) { [weak self, weak ws] in
            let result = OpenTabsSearch.find(tabs: inputs, options: options,
                                             shouldCancel: { Task.isCancelled })
            if Task.isCancelled { return }
            await MainActor.run { [weak self, weak ws] in
                guard let self,
                      Self.completionBelongsToCurrentRun(
                        runID, currentRunID: self.bufferRunID),
                      let ws else { return }
                ws.openResults = result.perTab
                ws.openTotalMatches = result.totalMatches
                ws.openResultsWereCapped = result.wasCapped
                // Sichtbare Vorschau und ihre Optionen gehören zusammen und
                // werden deshalb im selben Schritt gesetzt (wie im Datei-Scope).
                ws.visibleBufferResultsOptions = options
                ws.searchError = result.invalidPatternMessage
                ws.bufferSearching = false
                let materialized = result.perTab.reduce(0) { $0 + $1.matches.count }
                if ws.activeMatchIndex >= materialized {
                    ws.activeMatchIndex = max(0, materialized - 1)
                }
                ws.finishPendingOpenReplaceNavigation(for: options)
            }
        }
    }

    /// Explizite Ordner-Suche — wird NUR auf den „Suchen"-Klick / Enter
    /// ausgelöst (Konzept Abschnitt C). Läuft asynchron via `Task.detached`
    /// und bricht eine schon laufende Suche ab.
    func runFolderSearch() {
        guard let ws = workspace, ws.scope.isFolderLike else { return }
        ws.folderNavigationNotice = nil
        cancelPendingWork()
        Self.clearFolderPreview(ws, invalidatingJumps: true)
        folderRunID &+= 1
        let runID = folderRunID

        let options = ws.currentSearchOptions
        // Buffer-Zustand VOLLSTÄNDIG zurücksetzen, nicht nur die Trefferliste —
        // sonst zeigen Footer/Statuszeile nach dem Scope-Wechsel stale Werte
        // aus der letzten Buffer-Suche (Review 2026-07-03).
        ws.bufferMatches = []
        ws.bufferTotalMatches = 0
        ws.bufferResultsWereCapped = false
        ws.bufferSearching = false
        ws.visibleBufferResultsOptions = nil
        ws.folderNeedsSearch = false

        guard !options.isEmpty else {
            ws.searchError = nil
            ws.folderResults = []
            ws.folderTotalMatches = 0
            ws.folderResultsWereCapped = false
            ws.folderSearching = false
            return
        }
        // Der Plan validiert das Pattern sofort und wandert anschließend
        // unverändert in den Hintergrundlauf. So bleibt die Fehlermeldung
        // direkt sichtbar, ohne dort ein zweites Mal zu kompilieren.
        let searchPlan: SearchPlan
        do {
            searchPlan = try SearchPlan(options: options)
        } catch {
            ws.searchError = (error as NSError).localizedDescription
            ws.folderResults = []
            ws.folderTotalMatches = 0
            ws.folderResultsWereCapped = false
            ws.folderSearching = false
            return
        }

        let urls = ws.activeMultiFileSearchURLs
        let filter = ws.activeMultiFileFilter
        let exclusions = ws.scope == .project
            ? ws.projectSearchConfiguration.excludePatterns : []
        let projectRoot = ws.scope == .project ? ws.projectURL : nil
        ws.folderSearching = !options.isEmpty && !urls.isEmpty
        ws.folderNeedsSearch = false
        ws.searchError = nil
        folderTask = Task.detached(priority: .userInitiated) { [weak self, weak ws] in
            let result = FolderSearch.find(in: urls, filter: filter, plan: searchPlan,
                                           excludedPatterns: exclusions,
                                           relativeTo: projectRoot,
                                           shouldCancel: { Task.isCancelled })
            if Task.isCancelled { return }
            await MainActor.run { [weak self, weak ws] in
                guard let self,
                      Self.completionBelongsToCurrentRun(
                        runID, currentRunID: self.folderRunID
                      ),
                      let ws else { return }
                ws.folderResults = result.perFile
                ws.folderTotalMatches = result.totalMatches
                // Cap-Flag durchreichen — die Maske zeigt darauf basierend
                // einen Hinweis, damit klar ist, dass nicht alle Treffer
                // angezeigt werden (keine silent truncation).
                ws.folderResultsWereCapped = result.wasCapped
                ws.searchError = result.invalidPatternMessage
                ws.folderSearching = false
            }
        }
    }
}
