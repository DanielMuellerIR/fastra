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
            workspace.$activeTabID.dropFirst().map { _ in SearchInput.activeDocument }.eraseToAnyPublisher(),
            workspace.$tabs.dropFirst().map { _ in SearchInput.activeDocument }.eraseToAnyPublisher(),
            workspace.$scope.dropFirst().map { _ in SearchInput.scope }.eraseToAnyPublisher(),
            workspace.$recentSearchFolders.dropFirst().map { _ in SearchInput.folderSources }.eraseToAnyPublisher(),
            workspace.$fileTypeFilter.dropFirst().map { _ in SearchInput.folderSources }.eraseToAnyPublisher(),
            workspace.$projectSearchConfiguration.dropFirst().map { _ in SearchInput.projectSources }.eraseToAnyPublisher(),
            workspace.$projectURL.dropFirst().map { _ in SearchInput.projectSources }.eraseToAnyPublisher(),
        ]

        let triggerStream = Publishers.MergeMany(triggers)
            .filter { [weak workspace] input in
                guard let scope = workspace?.scope else { return false }
                return Self.inputAffectsSearch(input, in: scope)
            }
            .map { _ in () }
            .share()

        // Sicherheitspfad ohne Debounce: Sobald ein Suchinput wechselt,
        // gehören die sichtbaren Projekt-/Ordner-Treffer nicht mehr zur
        // aktuellen Semantik. Sofort leeren und laufende Tasks abbrechen;
        // Navigation, Vorschau und Apply sehen damit nie einen Altstand.
        triggerStream
            .sink { [weak self] in self?.searchInputsDidChange() }
            .store(in: &bag)

        triggerStream
            // 120 ms ist knapp genug fürs Tipp-Gefühl, lang genug, damit
            // selbst auf großen Buffern nicht jede Taste ein Re-Search
            // anstößt. Bei Bedarf später konfigurierbar machen.
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.rerun() }
            .store(in: &bag)

        // Initial einmal laufen lassen, damit die Maske beim Öffnen
        // direkt etwas zeigt (falls schon ein findPattern voreingestellt
        // ist — der Prototyp startet mit einer E-Mail-Demo-RegEx).
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

    private static func clearFolderPreview(_ ws: Workspace) {
        ws.folderResults = []
        ws.folderTotalMatches = 0
        ws.folderResultsWereCapped = false
        ws.activeMatchIndex = 0
    }

    /// Unmittelbare Invalidierung vor beiden Debounce-Stufen.
    private func searchInputsDidChange() {
        guard let ws = workspace else { return }
        cancelPendingWork()
        Self.clearFolderPreview(ws)
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

        // Laufende Folder- UND Buffer-Suche + armierten Live-Timer immer
        // abbrechen — entweder weil der Scope wechselt oder weil sich die
        // Eingaben geändert haben (frischer Tastendruck → alles neu starten).
        cancelPendingWork()

        if SearchRunner.runsLive(for: ws.scope) {
            if ws.scope == .open {
                runOpenSearch(ws)
            } else {
                runBufferSearch(ws)
            }
            return
        }

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
        Self.clearFolderPreview(ws)

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
            }
        }
    }

    /// Explizite Ordner-Suche — wird NUR auf den „Suchen"-Klick / Enter
    /// ausgelöst (Konzept Abschnitt C). Läuft asynchron via `Task.detached`
    /// und bricht eine schon laufende Suche ab.
    func runFolderSearch() {
        guard let ws = workspace, ws.scope.isFolderLike else { return }
        cancelPendingWork()
        Self.clearFolderPreview(ws)
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

        // Pattern vor dem Async-Lauf validieren — roter Streifen sofort,
        // statt erst nach dem (potenziell langen) Folder-Lauf.
        if let msg = SearchRunner.validationError(for: options) {
            ws.searchError = msg
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
            let result = FolderSearch.find(in: urls, filter: filter, options: options,
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
