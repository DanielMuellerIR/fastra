// SearchRunner.swift
//
// Beobachtet Such-relevante Felder im `Workspace`, ruft debounced
// `BufferSearch.find(...)` auf dem aktiven Tab und schreibt das
// Ergebnis nach `workspace.bufferMatches` / `workspace.searchError`
// zurück. Ein Objekt pro Workspace.
//
// Verwaltet die laufenden Suchaufträge und ihre Gültigkeit pro Fenster.
// Die Suchlogik selbst liegt in BufferSearch, OpenTabsSearch und FolderSearch;
// erst ein weiterhin aktueller Auftrag darf sein Ergebnis veröffentlichen.

import Foundation
import Combine

final class SearchRunner {
    private weak var workspace: Workspace?
    private var bag = Set<AnyCancellable>()
    /// Aktive Folder-Suche; wird beim nächsten Re-Run abgebrochen, damit
    /// während des Tippens nicht zwei Suchen gleichzeitig fertig werden
    /// und die Ergebnisse durcheinanderbringen.
    private var folderTask: Task<Void, Never>?
    /// Ein manueller Start entwertet bereits wartende Live-Auslöser.
    private let explicitSearchLock = NSLock()
    private var explicitSearchGeneration = 0

    private func currentExplicitSearchGeneration() -> Int {
        explicitSearchLock.lock()
        defer { explicitSearchLock.unlock() }
        return explicitSearchGeneration
    }

    private func invalidatePendingLiveTrigger() {
        // Combine kann Testeingaben auf fremden Threads zustellen.
        explicitSearchLock.lock()
        explicitSearchGeneration &+= 1
        explicitSearchLock.unlock()
    }
    /// Aktive Buffer-Suche (Datei-/Geöffnet-Scope). Läuft async, damit ein
    /// großer Buffer + kurzes Pattern den Main-Thread nie blockiert; wird
    /// beim nächsten Tastendruck/Toggle abgebrochen (kein Auflaufen veralteter
    /// Läufe). Vorher lief die Buffer-Suche synchron → Beachball.
    private var bufferTask: Task<Void, Never>?
    /// Extra-Debounce-Timer nur für die Live-Ordner-Suche. Liegt zusätzlich
    /// zum 120-ms-Pipeline-Debounce, damit die (teure) Ordner-Suche erst
    /// ~0,4 s nach dem letzten Tastendruck startet (siehe `rerun`).
    private var folderDebounce: DispatchWorkItem?

    /// Mindestlänge des Suchausdrucks, ab der der Ordner-Scope live beim
    /// Tippen sucht. Kürzere Pattern (1–2 Zeichen) träfen in großen Repos
    /// zehntausende Stellen und würden die App beim Live-Tippen lahmlegen —
    /// darunter sucht der Ordner-Scope erst auf expliziten „Suchen"/Return.
    static let minFolderLiveChars = 3
    /// Zusätzliche Verzögerung (ms) der Live-Ordner-Suche, on top des
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

    private static func sameSearchDocuments(_ previous: [EditorTab], _ current: [EditorTab]) -> Bool {
        previous.count == current.count && zip(previous, current).allSatisfy { old, new in
            old.id == new.id && old.documentID == new.documentID
                && old.title == new.title
                && old.contentRevision == new.contentRevision
                && old.isOrdinaryTextDocument == new.isOrdinaryTextDocument
                // String-Gleichheit ignoriert Unicode-Normalisierungsunterschiede,
                // obwohl sie die UTF-16-Bereiche der Treffer verschieben können.
                && old.content.utf8.elementsEqual(new.content.utf8)
                && old.isLoading == new.isLoading
        }
    }

    init(workspace: Workspace) {
        self.workspace = workspace

        // Alle Such-Inputs in einen Trigger-Stream zusammenführen. Wir
        // brauchen die konkreten Werte hier nicht — beim Re-Run lesen
        // wir sie direkt vom Workspace. Combine erlaubt CombineLatest
        // nur bis Arity 4, deshalb über MergeMany.
        let triggers: [AnyPublisher<SearchInput, Never>] = [
            workspace.$findPattern.dropFirst().map { _ in SearchInput.options }.eraseToAnyPublisher(),
            workspace.$replacePattern.dropFirst().map { _ in SearchInput.options }.eraseToAnyPublisher(),
            workspace.$useRegex.dropFirst().map { _ in SearchInput.options }.eraseToAnyPublisher(),
            workspace.$caseSensitive.dropFirst().map { _ in SearchInput.options }.eraseToAnyPublisher(),
            workspace.$wholeWord.dropFirst().map { _ in SearchInput.options }.eraseToAnyPublisher(),
            // Mini-Schalter „* wörtlich nehmen" → Such-Semantik
            // ändert sich (Platzhalter ⇄ literal) → neu suchen.
            workspace.$treatWildcardLiterally.dropFirst().map { _ in SearchInput.options }.eraseToAnyPublisher(),
            // „Nur in Auswahl" (K3) umschalten → Buffer-Suche neu laufen
            // lassen (anderer Such-Bereich).
            workspace.$searchInSelectionOnly.dropFirst().map { _ in SearchInput.activeDocument }.eraseToAnyPublisher(),
            workspace.$activeTabID.dropFirst().map { _ in SearchInput.activeTab }.eraseToAnyPublisher(),
            // Ein Ansichtswechsel verändert keine Trefferbasis. Insbesondere
            // darf der Wechsel aus WYSIWYG den auslösenden Sprung nicht entwerten.
            workspace.$tabs.removeDuplicates(by: Self.sameSearchDocuments)
                .dropFirst().map { _ in SearchInput.activeDocument }.eraseToAnyPublisher(),
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
                // Combine liefert auf dem schreibenden Thread. Auf Main muss die
                // Invalidierung synchron bleiben, damit Navigation, Vorschau und Apply
                // keinen Altstand sehen. Fremde Threads der parallelen Testsuite wechseln
                // auf die Main-Queue: Gleichzeitige Änderungen starker Referenzen wie
                // `folderTask` und `folderDebounce` könnten sonst dasselbe Objekt doppelt
                // freigeben. Regressionstest: `WorkspaceParallelStressTests`.
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.searchInputsDidChange(input) }
                } else {
                    DispatchQueue.main.async { self?.searchInputsDidChange(input) }
                }
            }
            .store(in: &bag)

        triggerStream
            .map { [weak self] _ in self?.currentExplicitSearchGeneration() }
            // 120 ms ist knapp genug fürs Tipp-Gefühl, lang genug, damit
            // selbst auf großen Buffern nicht jede Taste ein Re-Search
            // anstößt. Bei Bedarf später konfigurierbar machen.
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] generation in
                guard let self, generation == self.currentExplicitSearchGeneration() else { return }
                self.rerun()
            }
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
                    MainActor.assumeIsolated { self?.searchVisibilityDidChange(false) }
                } else {
                    DispatchQueue.main.async {
                        self?.searchVisibilityDidChange(false)
                    }
                }
            }
            .store(in: &bag)

        // Initial einmal prüfen. Die Maske startet normalerweise geschlossen;
        // `rerun()` beendet sich dann ohne Volltextarbeit.
        // Dieser Dispatch ist der früheste Weg, auf dem ein frisch
        // erzeugter Workspace die Main-Queue erreicht — noch vor
        // `Workspace.shared`. `Workspace.init` muss deshalb alle
        // @Published-Speicher anlegen, bevor es den SearchRunner erzeugt
        // (siehe dort, Vorwärm-Kommentar).
        DispatchQueue.main.async { [weak self] in self?.rerun() }
    }

    deinit {
        folderDebounce?.cancel()
        folderTask?.cancel()
        bufferTask?.cancel()
    }

    /// Entscheidet, ob ein Such-Input (Tippen, Options-Toggle) bedingungslos
    /// sofort eine Suche auslösen darf. Buffer-Scopes (Datei/Geöffnet) liegen
    /// im RAM — Live-Suche ist günstig, daher immer live. Der Ordner-Scope
    /// sucht nicht bedingungslos live (kann tausende Dateien betreffen);
    /// er sucht live nur oberhalb einer Mindestlänge + mit längerem Debounce
    /// (siehe `shouldRunFolderLive` / `rerun`). Pur + statisch → unit-testbar.
    static func runsLive(for scope: Workspace.SearchScope) -> Bool {
        switch scope {
        case .file, .open:       return true
        case .folder, .project:  return false
        }
    }

    /// Entscheidet, ob der Ordner-Scope für dieses Pattern live beim Tippen
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

    /// Nur fremde Testthreads stellen asynchron zu. Main-Eingaben entwerten
    /// synchron, auch während @Published seinen neuen Wert erst ankündigt.
    private func onMain(_ action: @escaping @MainActor (SearchRunner) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { action(self) }
        } else {
            DispatchQueue.main.async { [weak self] in if let self { action(self) } }
        }
    }

    @MainActor private func cancelPendingWork() {
        folderTask?.cancel()
        folderTask = nil
        bufferTask?.cancel()
        bufferTask = nil
        folderDebounce?.cancel()
        folderDebounce = nil
    }

    @MainActor private func searchVisibilityDidChange(_ isVisible: Bool) {
        guard let ws = workspace else { return }
        ws.invalidateSearchResults(.visibility, next: isVisible ? .empty : .closed, error: ws.searchError)
        cancelPendingWork()
        guard isVisible else {
            ws.discardPendingOpenReplaceNavigation()
            Self.clearAllPreview(ws)
            return
        }
        rerunOnMain()
    }

    @MainActor private static func clearFolderPreview(_ ws: Workspace) {
        ws.folderResults = []
        ws.folderTotalMatches = 0
        ws.folderResultsWereCapped = false
        ws.activeMatchIndex = 0
    }

    @MainActor private static func clearAllPreview(_ ws: Workspace) {
        clearFolderPreview(ws)
        ws.bufferMatches = []
        ws.bufferTotalMatches = 0
        ws.bufferResultsWereCapped = false
        ws.openResults = []
        ws.openTotalMatches = 0
        ws.openResultsWereCapped = false
        ws.activeMatchIndex = 0
    }

    @MainActor private func searchInputsDidChange(_: SearchInput) {
        guard let ws = workspace else { return }
        // Wie zuvor bestimmen die noch gespeicherten willSet-Werte den
        // sofortigen Warte-/Spinnerzustand. Erst der verzögerte Start erfasst
        // die neuen Werte als Suchbasis; gültig ist die alte Basis ab jetzt nie.
        let error = ws.scope.isFolderLike
            ? Self.validationError(for: ws.currentSearchOptions) : ws.searchError
        let next: SearchPhase
        if ws.scope.isFolderLike {
            let willRunLive = Self.shouldRunFolderLive(for: ws.findPattern)
                && !ws.currentSearchOptions.isEmpty && error == nil
                && !ws.activeMultiFileSearchURLs.isEmpty
            next = willRunLive ? .debouncing : .waiting
        } else {
            next = .debouncing
        }
        ws.invalidateSearchResults(.inputs, next: next, error: error)
        cancelPendingWork()
        Self.clearFolderPreview(ws)
    }

    /// Eigene Apply-/Undo-Schreibgänge verlangen einen ausdrücklichen Neulauf;
    /// Trefferöffnen und Hintergrundfenster sind dagegen keine Entwertungsgründe.
    func folderResultsBecameStale() {
        onMain { runner in
            guard let ws = runner.workspace, ws.scope.isFolderLike else { return }
            ws.invalidateSearchResults(.ownMutation, next: .stale, error: ws.searchError)
            runner.cancelPendingWork()
            Self.clearFolderPreview(ws)
        }
    }

    func rerun() { onMain { $0.rerunOnMain() } }

    @MainActor private func rerunOnMain() {
        guard let ws = workspace else { return }
        ws.folderNavigationNotice = nil
        let next: SearchPhase = ws.showSearchDialog
            ? (ws.scope.isFolderLike ? .empty : .debouncing) : .closed
        ws.invalidateSearchResults(.rescan, next: next, error: ws.searchError)
        cancelPendingWork()
        guard ws.showSearchDialog else {
            ws.discardPendingOpenReplaceNavigation()
            return
        }
        if SearchRunner.runsLive(for: ws.scope) {
            if ws.scope == .open { runOpenSearch(ws) }
            else {
                ws.discardPendingOpenReplaceNavigation()
                runBufferSearch(ws)
            }
            return
        }
        ws.discardPendingOpenReplaceNavigation()
        Self.clearAllPreview(ws)
        let options = ws.currentSearchOptions
        let error = Self.validationError(for: options)
        let willRunLive = Self.shouldRunFolderLive(for: ws.findPattern)
            && !options.isEmpty && !ws.activeMultiFileSearchURLs.isEmpty
        ws.invalidateSearchResults(.rescan, next: willRunLive ? .debouncing : .waiting, error: error)
        guard willRunLive else { return }
        let work = DispatchWorkItem { [weak self] in self?.runFolderSearch() }
        folderDebounce = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Self.folderLiveExtraDebounceMs), execute: work)
    }

    /// Gemeinsamer echter Completion-Eingang, auch für gezielt verspätete Tests.
    @MainActor @discardableResult
    static func publish(_ publication: SearchResultPublication,
                        for token: SearchResultSession.RunToken, in workspace: Workspace) -> Bool {
        workspace.commitSearchResult(token, publication: publication)
    }

    @MainActor private func runBufferSearch(_ ws: Workspace) {
        Self.clearFolderPreview(ws)
        ws.openResults = []
        ws.openTotalMatches = 0
        ws.openResultsWereCapped = false
        let options = ws.currentSearchOptions
        let text = ws.activeTab?.content ?? ""
        let searchRange = ws.activeSearchRange
        guard !options.isEmpty else {
            ws.bufferMatches = []
            ws.bufferTotalMatches = 0
            ws.bufferResultsWereCapped = false
            ws.invalidateSearchResults(.rescan, next: .empty)
            return
        }
        guard let token = ws.beginSearchResultRun() else { return }
        bufferTask = Task.detached(priority: .userInitiated) { [weak ws] in
            let result = BufferSearch.find(in: text, options: options, searchRange: searchRange,
                                           shouldCancel: { Task.isCancelled })
            if Task.isCancelled { return }
            await MainActor.run { [weak ws] in
                guard let ws, Self.publish(.buffer(result), for: token, in: ws) else { return }
                if ws.activeMatchIndex >= result.matches.count {
                    ws.activeMatchIndex = max(0, result.matches.count - 1)
                }
            }
        }
    }

    @MainActor private func runOpenSearch(_ ws: Workspace) {
        Self.clearFolderPreview(ws)
        ws.bufferMatches = []
        ws.bufferTotalMatches = 0
        ws.bufferResultsWereCapped = false
        let options = ws.currentSearchOptions
        // Lade-Tabs behalten ihre Identität in der Basis, werden wie bisher
        // vom eigentlichen Suchalgorithmus aber noch nicht durchsucht.
        let inputs = ws.tabs.filter { !$0.isLoading }.map {
            OpenTabsSearch.TabInput(id: $0.id, title: $0.title, content: $0.content)
        }
        guard !options.isEmpty else {
            ws.discardPendingOpenReplaceNavigation()
            ws.openResults = []
            ws.openTotalMatches = 0
            ws.openResultsWereCapped = false
            ws.invalidateSearchResults(.rescan, next: .empty)
            return
        }
        guard let token = ws.beginSearchResultRun() else { return }
        bufferTask = Task.detached(priority: .userInitiated) { [weak ws] in
            let result = OpenTabsSearch.find(tabs: inputs, options: options,
                                            shouldCancel: { Task.isCancelled })
            if Task.isCancelled { return }
            await MainActor.run { [weak ws] in
                guard let ws, Self.publish(.open(result), for: token, in: ws) else { return }
                let count = result.perTab.reduce(0) { $0 + $1.matches.count }
                if ws.activeMatchIndex >= count { ws.activeMatchIndex = max(0, count - 1) }
                ws.finishPendingOpenReplaceNavigation(for: options)
            }
        }
    }

    func runFolderSearch() { onMain { $0.runFolderSearchOnMain() } }

    @MainActor private func runFolderSearchOnMain() {
        guard let ws = workspace, ws.scope.isFolderLike else { return }
        ws.folderNavigationNotice = nil
        invalidatePendingLiveTrigger()
        ws.invalidateSearchResults(.rescan, next: .empty)
        cancelPendingWork()
        Self.clearAllPreview(ws)
        let options = ws.currentSearchOptions
        guard !options.isEmpty else { return }
        let searchPlan: SearchPlan
        do { searchPlan = try SearchPlan(options: options) }
        catch {
            ws.invalidateSearchResults(.rescan, next: .empty, error: (error as NSError).localizedDescription)
            return
        }
        let urls = ws.activeMultiFileSearchURLs
        let filter = ws.activeMultiFileFilter
        let exclusions = ws.scope == .project ? ws.projectSearchConfiguration.excludePatterns : []
        let projectRoot = ws.scope == .project ? ws.projectURL : nil
        guard let token = ws.beginSearchResultRun() else { return }
        folderTask = Task.detached(priority: .userInitiated) { [weak ws] in
            let result = FolderSearch.find(in: urls, filter: filter, plan: searchPlan,
                excludedPatterns: exclusions, relativeTo: projectRoot, shouldCancel: { Task.isCancelled })
            if Task.isCancelled { return }
            await MainActor.run { [weak ws] in
                guard let ws else { return }
                Self.publish(.folder(result), for: token, in: ws)
            }
        }
    }
}
