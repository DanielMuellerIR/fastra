import AppKit
import Foundation

/// Kleines threadsicheres Signal zwischen Main-Actor und synchronem
/// Hintergrund-Read. `FileLoader` fragt es zwischen seinen Abschnitten ab.
final class PreviewLoadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Momentaufnahme für die Freigabe eines Reads, kein zweiter Dokumentbesitzer.
struct DocumentFileLoadTarget {
    let id: UUID
    let documentID: UUID
    let url: URL?
    let contentRevision: UInt64
    let diskSnapshot: FileSnapshot?
    let hasUnsavedChanges: Bool
    let isLoading: Bool

    init(_ tab: EditorTab) {
        id = tab.id
        documentID = tab.documentID
        url = tab.url
        contentRevision = tab.contentRevision
        diskSnapshot = tab.diskSnapshot
        hasUnsavedChanges = tab.hasUnsavedChanges
        isLoading = tab.isLoading
    }
}

struct DocumentFileLoadPlaceholder {
    let id: UUID
    let documentID: UUID
    let previousActiveTabID: UUID?
}

/// Ein fenstereigener Besitzer für normale Datei-Reads und ihre Annahmerechte.
/// Der Adapter ist schwach; Worker halten diesen Besitzer bis zur Mainantwort.
/// Invalidierung entzieht nur Annahmerechte. Bestehende Abschlussverpflichtungen
/// bleiben bis zur ursprünglichen Readantwort bestehen.
@MainActor
final class DocumentFileLoads {
    private let adapter: Workspace.DocumentFileLoadAdapter
    private var latestGeneration = 0
    private var generations: [UUID: Int] = [:]
    private var previewCancellations: [UUID: PreviewLoadCancellation] = [:]

    private struct PendingFolderMatchFileLoad {
        let generation: Int
        let expectedDiskSnapshot: FileSnapshot
        let outcome: (FileLoadOutcome) -> Void
    }

    /// Dictionary und physischer Abschluss teilen genau den aktuellen Wartenden.
    /// Vor Rückrufen entnehmen/ersetzen, damit reentrante Sprünge erhalten bleiben.
    private final class FolderMatchFileLoadWaiter {
        private(set) var current: PendingFolderMatchFileLoad?

        init(_ request: PendingFolderMatchFileLoad) { current = request }

        func replace(with request: PendingFolderMatchFileLoad) -> PendingFolderMatchFileLoad? {
            let previous = current
            current = request
            return previous
        }

        func take() -> PendingFolderMatchFileLoad? {
            let request = current
            current = nil
            return request
        }
    }

    private var folderWaiters: [String: FolderMatchFileLoadWaiter] = [:]
    private var folderReadTokens: [String: UUID] = [:]

    private struct InitialRead {
        let url: URL
        let tabID: UUID
        let documentID: UUID
        let generation: Int
        let previewCancellation: PreviewLoadCancellation?
        let expectedDiskSnapshot: FileSnapshot?
        let acceptance: FileLoadAcceptance?
        let expectedGitContext: GitActionContext?
        let previousActiveTabID: UUID?
        let folderMatchReadToken: UUID?
        let outcome: ((FileLoadOutcome) -> Void)?
    }

    private struct HashRead {
        let url: URL
        let tabID: UUID
        let expectedDiskSnapshot: FileSnapshot
        let preview: Bool
        let acceptance: FileLoadAcceptance?
        let outcome: ((FileLoadOutcome) -> Void)?
    }

    private enum ReloadPolicy {
        case encoding(String.Encoding)
        case explicitOrExternal
        case afterDiskMutation
    }

    private struct ReloadRead {
        let target: DocumentFileLoadTarget
        let generation: Int
        let policy: ReloadPolicy
        let completion: ((Bool) -> Void)?
    }

    private var initialReads: [UUID: InitialRead] = [:]
    private var hashReads: [UUID: HashRead] = [:]
    private var reloadReads: [UUID: ReloadRead] = [:]

    init(adapter: Workspace.DocumentFileLoadAdapter) { self.adapter = adapter }

    func invalidateAll() { generations.removeAll() }

    func remove(tabID: UUID) {
        cancelPreview(tabID: tabID)
        generations.removeValue(forKey: tabID)
    }

    func supersede(tabID: UUID) {
        _ = nextGeneration(tabID: tabID)
        cancelPreview(tabID: tabID)
    }

    func cancelPreviews() {
        let cancellations = previewCancellations.values
        previewCancellations.removeAll()
        cancellations.forEach { $0.cancel() }
    }

    private func cancelPreview(tabID: UUID) {
        previewCancellations.removeValue(forKey: tabID)?.cancel()
    }

    private func nextGeneration(tabID: UUID) -> Int {
        // Abgeschlossene Reads geben ihren Tab-Eintrag frei. Eine noch
        // ausstehende Antwort darf dieselbe Kennung nie wieder vorfinden.
        latestGeneration += 1
        generations[tabID] = latestGeneration
        return latestGeneration
    }

    func openFolderMatch(at url: URL, expectedDiskSnapshot: FileSnapshot,
                         jumpGeneration: Int, outcome: @escaping (FileLoadOutcome) -> Void) {
        guard adapter.isCurrentMatchJump(jumpGeneration) else {
            outcome(.cancelled)
            return
        }
        adapter.clearFolderNavigationNotice()
        let key = url.path
        let request = PendingFolderMatchFileLoad(generation: jumpGeneration,
                                                expectedDiskSnapshot: expectedDiskSnapshot,
                                                outcome: outcome)
        if let waiting = folderWaiters[key] {
            waiting.replace(with: request)?.outcome(.cancelled)
            return
        }
        let waiting = FolderMatchFileLoadWaiter(request)
        folderWaiters[key] = waiting
        let readToken = UUID()
        folderReadTokens[key] = readToken

        // Die bestehende Workspace-Fassade enthält den starken Visualsync-
        // Vorstart. Der logische Wartende und seine Kennung bestehen schon hier;
        // der physische Read beginnt weiterhin erst nach dieser Fassade.
        adapter.openFolderFile(
            at: url, expectedDiskSnapshot: expectedDiskSnapshot,
            acceptance: FileLoadAcceptance { [self] in
                MainActor.assumeIsolated {
                    guard adapter.isAlive, folderReadTokens[key] == readToken,
                          let latest = waiting.current else { return false }
                    return adapter.isCurrentMatchJump(latest.generation)
                        && latest.expectedDiskSnapshot == expectedDiskSnapshot
                }
            },
            readToken: readToken
        ) { [self] physicalOutcome in
            MainActor.assumeIsolated {
                finishFolderRead(at: url, expectedDiskSnapshot: expectedDiskSnapshot,
                                 token: readToken, waiting: waiting, outcome: physicalOutcome)
            }
        }
    }

    private func finishFolderRead(at url: URL, expectedDiskSnapshot: FileSnapshot,
                                  token: UUID, waiting: FolderMatchFileLoadWaiter,
                                  outcome: FileLoadOutcome) {
        guard adapter.isAlive else {
            // Auch nach Workspace-Abbau den jüngsten gemeinsamen Wartenden
            // entnehmen. Ein bereits transferierter Wartender ist hier leer.
            if folderReadTokens[url.path] == token {
                folderReadTokens.removeValue(forKey: url.path)
                folderWaiters.removeValue(forKey: url.path)
            }
            waiting.take()?.outcome(.cancelled)
            return
        }
        let key = url.path
        guard folderReadTokens[key] == token else { return }
        folderReadTokens.removeValue(forKey: key)
        folderWaiters.removeValue(forKey: key)
        guard let latest = waiting.take() else { return }
        guard latest.expectedDiskSnapshot == expectedDiskSnapshot else {
            openFolderMatch(at: url, expectedDiskSnapshot: latest.expectedDiskSnapshot,
                            jumpGeneration: latest.generation, outcome: latest.outcome)
            return
        }
        guard adapter.isCurrentMatchJump(latest.generation) else {
            latest.outcome(.cancelled)
            return
        }
        latest.outcome(outcome)
    }

    private func releaseFolderRead(token: UUID, url: URL) {
        let key = url.path
        guard folderReadTokens[key] == token else { return }
        folderReadTokens.removeValue(forKey: key)
        guard let waiting = folderWaiters.removeValue(forKey: key)?.take() else { return }
        openFolderMatch(at: url, expectedDiskSnapshot: waiting.expectedDiskSnapshot,
                        jumpGeneration: waiting.generation, outcome: waiting.outcome)
    }

    func open(at url: URL, preview: Bool, expectedGitContext: GitActionContext?,
              expectedDiskSnapshot: FileSnapshot?, acceptance: FileLoadAcceptance?,
              folderMatchReadToken: UUID?, outcome: ((FileLoadOutcome) -> Void)?) {
        if let existing = adapter.target(at: url) {
            if let expectedDiskSnapshot {
                if existing.hasUnsavedChanges { outcome?(.unsavedChanges); return }
                if existing.isLoading { outcome?(.busyLoading); return }
                guard existing.diskSnapshot == expectedDiskSnapshot else {
                    outcome?(.staleSnapshot)
                    return
                }
                startHashRead(HashRead(url: url, tabID: existing.id,
                                       expectedDiskSnapshot: expectedDiskSnapshot, preview: preview,
                                       acceptance: acceptance, outcome: outcome))
                return
            }
            adapter.selectExisting(tabID: existing.id, pin: !preview, recentURL: url)
            outcome?(.opened)
            return
        }
        guard let placeholder = adapter.preparePlaceholder(
            url: url, preview: preview, snapshotBound: expectedDiskSnapshot != nil,
            cancelReusedPreview: { cancelPreview(tabID: $0) }
        ) else {
            outcome?(.failed)
            return
        }
        let generation = nextGeneration(tabID: placeholder.id)
        let cancellation = preview ? PreviewLoadCancellation() : nil
        if let cancellation { previewCancellations[placeholder.id] = cancellation }
        startInitialRead(InitialRead(
            url: url, tabID: placeholder.id, documentID: placeholder.documentID,
            generation: generation, previewCancellation: cancellation,
            expectedDiskSnapshot: expectedDiskSnapshot, acceptance: acceptance,
            expectedGitContext: expectedGitContext, previousActiveTabID: placeholder.previousActiveTabID,
            folderMatchReadToken: folderMatchReadToken, outcome: outcome
        ))
    }

    private func startHashRead(_ read: HashRead) {
        let id = UUID()
        hashReads[id] = read
        Task.detached(priority: .userInitiated) { [self] in
            let snapshot = try? FileSnapshot.readSnapshotOnly(
                from: read.url, byteLimit: FileLoader.largeFileThreshold)
            await finishHashRead(id: id, snapshot: snapshot)
        }
    }

    private func finishHashRead(id: UUID, snapshot: FileSnapshot?) {
        adapter.withWorkspaceLifetime { finishHashReadWhileWorkspaceAlive(id: id, snapshot: snapshot) }
    }

    private func finishHashReadWhileWorkspaceAlive(id: UUID, snapshot: FileSnapshot?) {
        guard let read = hashReads.removeValue(forKey: id) else { return }
        guard adapter.isAlive, read.acceptance?.acceptsResult() != false else {
            read.outcome?(.cancelled)
            return
        }
        guard snapshot == read.expectedDiskSnapshot else { read.outcome?(.staleSnapshot); return }
        guard let current = adapter.target(id: read.tabID), current.url == read.url else {
            read.outcome?(.cancelled)
            return
        }
        if current.hasUnsavedChanges { read.outcome?(.unsavedChanges); return }
        if current.isLoading { read.outcome?(.busyLoading); return }
        guard current.diskSnapshot == read.expectedDiskSnapshot else {
            read.outcome?(.staleSnapshot)
            return
        }
        adapter.selectExisting(tabID: read.tabID, pin: !read.preview, recentURL: read.url)
        read.outcome?(.opened)
    }

    private func startInitialRead(_ read: InitialRead) {
        let id = UUID()
        initialReads[id] = read
        // Die aktuelle Test-/Produktnaht pro physischem Start kopieren, auch
        // bei einem späteren Rename-Neustart. Kein zweiter Konfigurationsstore.
        guard let loader = adapter.initialLoader else {
            finishInitialRead(id: id, result: .failure(FileLoader.LoadError.cancelled))
            return
        }
        Task.detached(priority: .userInitiated) { [self] in
            let result = Result {
                if let cancellation = read.previewCancellation {
                    return try FileLoader.load(
                        url: read.url, largeFileThreshold: FileLoader.editableFileThreshold,
                        isCancelled: { cancellation.isCancelled }
                    )
                }
                return try loader(read.url)
            }
            await finishInitialRead(id: id, result: result)
        }
    }

    private func finishInitialRead(id: UUID, result: Result<FileLoader.LoadedFile, Error>) {
        adapter.withWorkspaceLifetime { finishInitialReadWhileWorkspaceAlive(id: id, result: result) }
    }

    private func finishInitialReadWhileWorkspaceAlive(id: UUID, result: Result<FileLoader.LoadedFile, Error>) {
        // Vor jedem Rückruf entnehmen: Reentrante Starts können nur ihren
        // eigenen Zustand sehen, und kein terminaler Callback bleibt gespeichert.
        // Restore zählt seine verbleibenden Ladungen nur über diese Antworten;
        // sein Abschluss-Latch gibt danach gepufferte Finder-/CLI-Öffnungen frei.
        // Darum bleibt die Rückmeldung auch ohne Workspace bis zum Readende
        // geschuldet und darf weder verloren gehen noch bei Invalidierung vorziehen.
        guard let read = initialReads.removeValue(forKey: id) else { return }
        guard adapter.isAlive else { read.outcome?(.failed); return }
        // Ein recycelter Vorschauplatz behält die Tab-ID, bekommt aber eine
        // neue Dokument-ID. Die Antwort gehört weiterhin zum alten Dokument.
        guard generations[read.tabID] == read.generation,
              let current = adapter.target(id: read.tabID), current.documentID == read.documentID else {
            if adapter.target(id: read.tabID) == nil { generations.removeValue(forKey: read.tabID) }
            read.outcome?(.cancelled)
            return
        }
        // Nach Rename folgt derselbe physische Read dem neuen Pfad. Der
        // logische Ordner-Wartende gehört dagegen weiter zum alten Pfad: Seine
        // Readkennung zuerst lösen und ihm einen eigenen Read geben, sonst
        // würde er den Inhalt der umbenannten Datei als sein Ergebnis erhalten.
        // Der unveränderte Platzhalter braucht anschließend den Ersatzread;
        // bloßes Verwerfen ließe ihn am neuen Pfad dauerhaft im Ladezustand.
        // Den ursprünglichen Abschluss übernimmt dieser Ersatzread.
        if let movedURL = current.url, movedURL != read.url {
            var movedAcceptance = read.acceptance
            if let token = read.folderMatchReadToken {
                releaseFolderRead(token: token, url: read.url)
                movedAcceptance = nil
            }
            let next = nextGeneration(tabID: read.tabID)
            startInitialRead(InitialRead(
                url: movedURL, tabID: read.tabID, documentID: read.documentID, generation: next,
                previewCancellation: read.previewCancellation, expectedDiskSnapshot: read.expectedDiskSnapshot,
                acceptance: movedAcceptance, expectedGitContext: read.expectedGitContext,
                previousActiveTabID: read.previousActiveTabID, folderMatchReadToken: nil,
                outcome: read.outcome
            ))
            return
        }
        guard read.acceptance?.acceptsResult() != false else {
            generations.removeValue(forKey: read.tabID)
            adapter.discardPlaceholder(tabID: read.tabID, previousActiveTabID: read.previousActiveTabID)
            read.outcome?(.cancelled)
            return
        }
        generations.removeValue(forKey: read.tabID)
        if let cancellation = read.previewCancellation,
           previewCancellations[read.tabID] === cancellation {
            previewCancellations.removeValue(forKey: read.tabID)
        }
        if let context = read.expectedGitContext, !adapter.isCurrentGitContext(context) {
            adapter.discardForGitContext(tabID: read.tabID)
            read.outcome?(.cancelled)
            return
        }
        switch result {
        case .success(let loaded):
            guard let target = adapter.target(id: read.tabID), target.documentID == read.documentID else {
                read.outcome?(.cancelled)
                return
            }
            guard read.expectedDiskSnapshot == nil || loaded.diskSnapshot == read.expectedDiskSnapshot else {
                adapter.discardPlaceholder(tabID: read.tabID, previousActiveTabID: read.previousActiveTabID)
                read.outcome?(.staleSnapshot)
                return
            }
            adapter.publishInitial(tabID: read.tabID, loaded: loaded, url: read.url,
                                   snapshotBound: read.expectedDiskSnapshot != nil)
            read.outcome?(.opened)
        case .failure(let error):
            if case FileLoader.LoadError.cancelled = error {
                adapter.discardPlaceholder(tabID: read.tabID, previousActiveTabID: read.previousActiveTabID)
                read.outcome?(.cancelled)
                return
            }
            NSSound.beep()
            adapter.discardPlaceholder(tabID: read.tabID, previousActiveTabID: read.previousActiveTabID)
            read.outcome?(.failed)
        }
    }

    // Die Provider werden nur synchron ausgewertet und nicht gespeichert:
    // Einzelreads kopieren ihre aktuelle Loadernaht nach der Spinnerpublikation,
    // Mutationreloads nach der Zielauswahl, aber vor dem ersten Spinner.
    func reopen(target: DocumentFileLoadTarget, encoding: String.Encoding,
                loader: () -> (@Sendable (URL, String.Encoding) throws -> FileLoader.LoadedFile)) {
        guard let url = target.url else { return }
        let read = beginReload(target: target, policy: .encoding(encoding))
        let loader = loader()
        Task.detached(priority: .userInitiated) { [self] in
            let result = Result { try loader(url, encoding) }
            await finishReload(id: read, result: result)
        }
    }

    func reload(target: DocumentFileLoadTarget,
                loader: () -> (@Sendable (URL) throws -> FileLoader.LoadedFile)) -> Task<Void, Never>? {
        guard let url = target.url else { return nil }
        let read = beginReload(target: target, policy: .explicitOrExternal)
        let loader = loader()
        return Task.detached(priority: .userInitiated) { [self] in
            let result = Result { try loader(url) }
            await finishReload(id: read, result: result)
        }
    }

    func reloadAfterDiskMutation(changedURLs: [URL],
                                loader: () -> (@Sendable (URL) throws -> FileLoader.LoadedFile),
                                completion: (([URL]) -> Void)? = nil) {
        let changed = Set(changedURLs.map { $0.standardizedFileURL.path })
        let targets = adapter.targetsForReload(changedPaths: changed)
        let loader = loader()
        var remaining = targets.count
        var failed: [URL] = []
        guard remaining > 0 else { completion?([]); return }
        for target in targets {
            guard let url = target.url else { continue }
            let read = beginReload(target: target, policy: .afterDiskMutation, completion: { accepted in
                if !accepted { failed.append(url) }
                remaining -= 1
                if remaining == 0 { completion?(failed) }
            })
            Task.detached(priority: .userInitiated) { [self] in
                let result = Result { try loader(url) }
                await finishReload(id: read, result: result)
            }
        }
    }

    private func beginReload(target: DocumentFileLoadTarget, policy: ReloadPolicy,
                             completion: ((Bool) -> Void)? = nil) -> UUID {
        let id = UUID()
        let generation = nextGeneration(tabID: target.id)
        reloadReads[id] = ReloadRead(target: target, generation: generation, policy: policy, completion: completion)
        adapter.setLoading(tabID: target.id, value: true)
        return id
    }

    private func finishReload(id: UUID, result: Result<FileLoader.LoadedFile, Error>) {
        guard let read = reloadReads.removeValue(forKey: id) else { return }
        var accepted = false
        // Die physische Antwort schuldet auch nach Tab-/Workspace-Abbau einen
        // Abschluss. Invalidierung nimmt nur das Recht zur Datenübernahme.
        defer { read.completion?(accepted) }
        adapter.withWorkspaceLifetime {
            accepted = finishReloadWhileWorkspaceAlive(read: read, result: result)
        }
    }

    private func finishReloadWhileWorkspaceAlive(read: ReloadRead,
                                                 result: Result<FileLoader.LoadedFile, Error>) -> Bool {
        guard adapter.isAlive else { return false }
        let target = read.target
        guard generations[target.id] == read.generation,
              let current = adapter.target(id: target.id) else {
            if adapter.target(id: target.id) == nil { generations.removeValue(forKey: target.id) }
            return false
        }
        generations.removeValue(forKey: target.id)
        switch read.policy {
        case .encoding(let encoding):
            finishReopen(target: target, current: current, result: result, encoding: encoding)
        case .explicitOrExternal:
            finishExplicitReload(target: target, current: current, result: result)
        case .afterDiskMutation:
            return finishMutationReload(target: target, current: current, result: result)
        }
        return true
    }

    private func finishReopen(target: DocumentFileLoadTarget, current: DocumentFileLoadTarget,
                              result: Result<FileLoader.LoadedFile, Error>, encoding: String.Encoding) {
        switch result {
        case .success(let loaded):
            guard current.url == target.url, current.contentRevision == target.contentRevision,
                  current.diskSnapshot == target.diskSnapshot else {
                adapter.setLoading(tabID: target.id, value: false)
                return
            }
            adapter.publishReload(tabID: target.id, loaded: loaded, afterDiskMutation: false)
        case .failure:
            // Der bestätigte Reopen darf Dirty-Inhalt verwerfen. Im Fehlerfall
            // galt bisher kein zusätzlicher URL-/Revisions-/Snapshotguard.
            adapter.setLoading(tabID: target.id, value: false)
            adapter.showReopenFailure(encoding: encoding)
        }
    }

    private func finishExplicitReload(target: DocumentFileLoadTarget, current: DocumentFileLoadTarget,
                                     result: Result<FileLoader.LoadedFile, Error>) {
        switch result {
        case .success(let loaded):
            guard current.url == target.url, current.contentRevision == target.contentRevision,
                  current.diskSnapshot == target.diskSnapshot else {
                adapter.setLoading(tabID: target.id, value: false)
                return
            }
            adapter.publishReload(tabID: target.id, loaded: loaded, afterDiskMutation: false)
        case .failure:
            adapter.failReload(tabID: target.id, expectedURL: target.url)
        }
    }

    private func finishMutationReload(target: DocumentFileLoadTarget, current: DocumentFileLoadTarget,
                                     result: Result<FileLoader.LoadedFile, Error>) -> Bool {
        switch result {
        case .success(let loaded):
            // Automatische Folge-Reads dürfen inzwischen Dirty gewordenes
            // Dokumentmaterial nicht wie einen bestätigten Reload verwerfen.
            guard current.url == target.url, !current.hasUnsavedChanges,
                  current.contentRevision == target.contentRevision,
                  current.diskSnapshot == target.diskSnapshot else {
                adapter.setLoading(tabID: target.id, value: false)
                return false
            }
            adapter.publishReload(tabID: target.id, loaded: loaded, afterDiskMutation: true)
            return true
        case .failure:
            adapter.failReload(tabID: target.id, expectedURL: target.url)
            return false
        }
    }
}
