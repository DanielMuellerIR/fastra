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
    /// Aktive Buffer-Suche (Datei-/Geöffnet-Scope). Läuft async, damit ein
    /// großer Buffer + kurzes Pattern den Main-Thread NIE blockiert; wird
    /// beim nächsten Tastendruck/Toggle abgebrochen (kein Auflaufen veralteter
    /// Läufe). Vorher lief die Buffer-Suche synchron → Beachball.
    private var bufferTask: Task<Void, Never>?
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

    init(workspace: Workspace) {
        self.workspace = workspace

        // Alle Such-Inputs in einen Trigger-Stream zusammenführen. Wir
        // brauchen die konkreten Werte hier NICHT — beim Re-Run lesen
        // wir sie direkt vom Workspace. Combine erlaubt CombineLatest
        // nur bis Arity 4, deshalb über MergeMany.
        let triggers: [AnyPublisher<Void, Never>] = [
            workspace.$findPattern.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            workspace.$replacePattern.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            workspace.$useRegex.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            workspace.$caseSensitive.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            workspace.$wholeWord.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            // Mini-Schalter „* wörtlich nehmen" (Feature J) → Such-Semantik
            // ändert sich (Platzhalter ⇄ literal) → neu suchen.
            workspace.$treatWildcardLiterally.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            // „Nur in Auswahl" (K3) umschalten → Buffer-Suche neu laufen
            // lassen (anderer Such-Bereich).
            workspace.$searchInSelectionOnly.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            workspace.$activeTabID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            workspace.$tabs.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            workspace.$scope.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            workspace.$recentSearchFolders.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            workspace.$fileTypeFilter.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            workspace.$projectSearchConfiguration.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            workspace.$projectURL.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]

        Publishers.MergeMany(triggers)
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
        folderTask?.cancel()
        folderTask = nil
        bufferTask?.cancel()
        bufferTask = nil
        folderDebounce?.cancel()
        folderDebounce = nil

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
        ws.searchError = SearchRunner.validationError(for: ws.currentSearchOptions)

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
            ws.searchError = nil
            ws.bufferSearching = false
            return
        }

        // Spinner an; eigentliche Suche im Hintergrund.
        ws.bufferSearching = true
        bufferTask = Task.detached(priority: .userInitiated) { [weak ws] in
            // `Task.isCancelled` deckt beides ab: der nächste Tastendruck
            // cancelt diesen Task → find() bricht mitten im Scan ab.
            let result = BufferSearch.find(in: text, options: options,
                                           searchRange: searchRange,
                                           shouldCancel: { Task.isCancelled })
            if Task.isCancelled { return }
            await MainActor.run { [ws] in
                guard let ws else { return }
                ws.bufferMatches = result.matches
                ws.bufferTotalMatches = result.totalMatches
                ws.bufferResultsWereCapped = result.wasCapped
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

        // Reste der anderen Scopes leeren (gleiches Muster wie Buffer-Pfad).
        ws.folderResults = []
        ws.folderTotalMatches = 0
        ws.folderResultsWereCapped = false
        ws.folderSearching = false
        ws.folderNeedsSearch = false
        ws.bufferMatches = []
        ws.bufferTotalMatches = 0
        ws.bufferResultsWereCapped = false

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
            ws.searchError = nil
            ws.bufferSearching = false
            return
        }

        ws.bufferSearching = true
        bufferTask = Task.detached(priority: .userInitiated) { [weak ws] in
            let result = OpenTabsSearch.find(tabs: inputs, options: options,
                                             shouldCancel: { Task.isCancelled })
            if Task.isCancelled { return }
            await MainActor.run { [ws] in
                guard let ws else { return }
                ws.openResults = result.perTab
                ws.openTotalMatches = result.totalMatches
                ws.openResultsWereCapped = result.wasCapped
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
        folderTask?.cancel()
        folderTask = nil

        let options = ws.currentSearchOptions
        // Buffer-Zustand VOLLSTÄNDIG zurücksetzen, nicht nur die Trefferliste —
        // sonst zeigen Footer/Statuszeile nach dem Scope-Wechsel stale Werte
        // aus der letzten Buffer-Suche (Review 2026-07-03).
        ws.bufferMatches = []
        ws.bufferTotalMatches = 0
        ws.bufferResultsWereCapped = false
        ws.bufferSearching = false
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
        ws.searchError = nil
        folderTask = Task.detached(priority: .userInitiated) { [weak ws] in
            let result = FolderSearch.find(in: urls, filter: filter, options: options,
                                           excludedPatterns: exclusions,
                                           relativeTo: projectRoot)
            if Task.isCancelled { return }
            await MainActor.run { [ws] in
                guard let ws else { return }
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
