import Combine
import Foundation

/// Ein ausdrücklicher Wiederherstellungsaufruf besitzt seine Freigabe selbst.
/// Historische Sitzungen werden nie in den ungebundenen RAM-Undo-Slot gelegt.
@MainActor
final class ApplyRecoverySession: ObservableObject, Identifiable {
    let id = UUID()
    let scope: Workspace.SearchScope
    let roots: [URL]
    let projectRoot: URL?
    let projectConfiguration: ProjectSearchConfiguration?
    @Published private(set) var candidates: [ApplyRecoveryPreview.Candidate] = []
    @Published private(set) var selectedName: String?
    @Published private(set) var review: ApplyRecoveryReview?
    @Published private(set) var isBusy = false
    @Published private(set) var isExecuting = false
    @Published private(set) var error: String?
    @Published private(set) var status: String?
    @Published private(set) var listingNotice: String?
    private weak var workspace: Workspace?
    private let requestedBackupRoot: URL
    private let processes: () throws -> ApplyRecoveryProcessScope.Observation
    private var generation = 0
    private var closed = false
    private var task: Task<Void, Never>?
    private var cancellation = PreviewLoadCancellation()

    init(workspace: Workspace,
         processes: @escaping () throws -> ApplyRecoveryProcessScope.Observation = { try ApplyRecoveryProcessScope.capture() }) {
        self.workspace = workspace
        scope = workspace.scope
        roots = workspace.activeMultiFileSearchURLs
        projectRoot = workspace.scope == .project ? workspace.projectURL : nil
        projectConfiguration = workspace.scope == .project ? workspace.projectSearchConfiguration : nil
        requestedBackupRoot = workspace.folderApplyBackupRoot ?? ApplyEngine.defaultBackupRoot
        self.processes = processes
    }

    var contextIsCurrent: Bool {
        guard !closed, let workspace else { return false }
        return workspace.fileRecoverySession === self && workspace.showSearchDialog
            && workspace.scope == scope && workspace.activeMultiFileSearchURLs == roots
            && (scope != .project || (workspace.projectURL == projectRoot
                && workspace.projectSearchConfiguration == projectConfiguration))
            && (workspace.folderApplyBackupRoot ?? ApplyEngine.defaultBackupRoot) == requestedBackupRoot
    }

    var canConfirm: Bool {
        guard contextIsCurrent, !isBusy, !isExecuting, let review else { return false }
        return review.preview.hasFileWrites || !review.preview.remainingCleanupURLs.isEmpty
            || review.preview.targets.contains { $0.state == .originalAlreadyPresent }
    }

    func load() {
        guard contextIsCurrent, scope.isFolderLike, !roots.isEmpty, !isExecuting else { return }
        let ticket = beginRead()
        candidates = []; selectedName = nil; review = nil; listingNotice = nil
        let root = requestedBackupRoot, processes = processes, cancellation = cancellation
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result {
                let observation = try processes()
                let resolved = try ApplyPersistenceBarriers.resolvingRootAliases(root)
                return try ApplyRecoveryPreview.list(in: resolved, createdBefore: observation.current.startedAt,
                                                     isCancelled: { cancellation.isCancelled })
            }
            await self?.finishListing(result, ticket: ticket)
        }
    }

    func select(_ name: String) {
        guard contextIsCurrent, !isExecuting,
              let candidate = candidates.first(where: { $0.sessionName == name }) else { return }
        let ticket = beginRead()
        selectedName = name; review = nil
        let roots = roots, processes = processes, cancellation = cancellation
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result {
                if cancellation.isCancelled { throw CancellationError() }
                let observation = try candidate.open()
                try Self.validateProcess(try processes(), directory: observation.directory)
                let resolvedRoots = try Self.resolveRoots(roots)
                let review = try ApplyRecoveryReview.build(observation: observation, roots: resolvedRoots,
                                                           isCancelled: { cancellation.isCancelled })
                guard try Self.resolveRoots(roots) == resolvedRoots else {
                    throw ApplyRecoveryPreview.Failure.changed(observation.session.sessionDirectory)
                }
                return review
            }
            await self?.finishReview(result, ticket: ticket)
        }
    }

    func refreshSelected() {
        guard let selectedName else { load(); return }
        select(selectedName)
    }

    func reconcile() {
        guard !contextIsCurrent else { return }
        revoke()
    }

    func revoke() {
        cancel()
        error = ApplyRecoveryFailure.stale
    }

    func cancel() {
        generation &+= 1
        cancellation.cancel(); task?.cancel()
        review = nil
        if isExecuting {
            status = L10n.string("Abbruch angefordert. Bereits erfolgte Rücknahmen bleiben im Journal erhalten.")
        } else {
            task = nil; isBusy = false
        }
    }

    func close() {
        cancel()
        closed = true
        if !isExecuting, workspace?.fileRecoverySession === self { workspace?.fileRecoverySession = nil }
    }

    func confirm() {
        guard canConfirm, let review, let workspace else { return }
        let ticket = generation
        isExecuting = true; isBusy = true; error = nil
        status = L10n.string("Offene Dokumente werden synchronisiert…")
        task = Task { [self, workspace] in
            let (succeeded, holds) = await workspace.synchronizeTextWorkflowDiskDocuments()
            guard succeeded, contextIsCurrent, generation == ticket, !Task.isCancelled,
                  workspace.textWorkflowDiskEditorsAreHeld(holds) else {
                for hold in holds { hold.finish() }
                finishBeforeMutation(succeeded ? ApplyRecoveryFailure.stale : TextWorkflowFailure.workspaceChanged)
                return
            }
            let mutation: Workspace.TextWorkflowDiskMutation
            do {
                mutation = try workspace.beginTextWorkflowDiskMutation(
                    urls: review.preview.session.undoResourceURLs(includingRestoredTargets: false))
            } catch {
                for hold in holds { hold.finish() }
                finishBeforeMutation(ApplyRecoveryFailure.message(error)); return
            }
            workspace.fileRecoveryApplying = true
            status = L10n.string("Die bestätigte Dateiwiederherstellung wird geprüft…")
            let cancellation = cancellation, processes = processes, sourceRoots = roots
            task = Task.detached(priority: .userInitiated) { [self, workspace] in
                var claim: ApplyRecoveryDirectoryClaim?
                var restoredSnapshots: [URL: FileSnapshot] = [:]
                let result = Result<ApplySession, Error> {
                    func check() throws {
                        if cancellation.isCancelled || Task.isCancelled { throw ApplyError.cancelled }
                        let current = DispatchQueue.main.sync { self.contextIsCurrent && self.generation == ticket }
                        guard current else { throw ApplyError.conflict(ApplyRecoveryFailure.stale) }
                        try Self.validateProcess(try processes(), directory: review.preview.observation.directory)
                        // Bewusst gewählte Quellen dürfen Aliase sein. Ihre
                        // Auflösung bleibt an die in der Vorschau gebundenen
                        // Wurzeln gebunden, auch zwischen zwei Dateitauschen.
                        guard try Self.resolveRoots(sourceRoots)
                            == review.preview.selectedRoots else {
                            throw ApplyError.conflict(ApplyRecoveryFailure.stale)
                        }
                        try mutation.preflight(in: workspace, shouldCancel: { cancellation.isCancelled || Task.isCancelled })
                    }
                    try check()
                    let preview = review.preview, observation = preview.observation
                    let held = try ApplyRecoveryDirectoryClaim(root: observation.backupRoot,
                        sessionName: observation.sessionName,
                        expectedRootIdentity: observation.root.identity,
                        expectedSessionIdentity: observation.directory.identity)
                    claim = held
                    try Self.validateProcess(try processes(), directory: observation.directory)
                    try preview.validate(holding: held, isCancelled: { cancellation.isCancelled || Task.isCancelled })
                    try check()
                    return try ApplyEngine.undoRecovery(preview.session, holding: held,
                        expectedManifest: observation.manifest.snapshot,
                        expectedBackups: observation.backups.mapValues(\.snapshot),
                        beforeAtomicReplace: { _ in try ApplyRecoveryFailure.checked(check) },
                        afterCleanupClaim: { _ in try ApplyRecoveryFailure.checked(check) },
                        verifiedOriginal: { restoredSnapshots[$0] = $1 })
                }
                await finishExecution(result, expectedSnapshots: restoredSnapshots,
                                      workspace: workspace, mutation: mutation, claim: claim, holds: holds)
            }
        }
    }

    private func beginRead() -> Int {
        cancel()
        cancellation = PreviewLoadCancellation()
        isBusy = true; error = nil; status = nil
        return generation
    }

    private func finishListing(_ result: Result<ApplyRecoveryPreview.Listing, Error>, ticket: Int) {
        guard contextIsCurrent, generation == ticket else { return }
        task = nil; isBusy = false
        switch result {
        case .success(let listing):
            candidates = listing.candidates
            if listing.scanWasLimited || listing.reachedLimit {
                listingNotice = L10n.string("Die begrenzte Liste zeigt nur einen Teil der aufbewahrten Sitzungen. Es wurde nichts angewendet.")
            }
        case .failure(let failure): error = ApplyRecoveryFailure.message(failure)
        }
    }

    private func finishReview(_ result: Result<ApplyRecoveryReview, Error>, ticket: Int) {
        guard contextIsCurrent, generation == ticket else { return }
        task = nil; isBusy = false
        switch result {
        case .success(let value): review = value
        case .failure(let failure): error = ApplyRecoveryFailure.message(failure)
        }
    }

    private func finishBeforeMutation(_ message: String) {
        task = nil; isBusy = false; isExecuting = false; review = nil
        error = message; status = nil
        if closed, workspace?.fileRecoverySession === self { workspace?.fileRecoverySession = nil }
    }

    private func finishExecution(_ result: Result<ApplySession, Error>,
                                 expectedSnapshots: [URL: FileSnapshot],
                                 workspace: Workspace, mutation: Workspace.TextWorkflowDiskMutation,
                                 claim: ApplyRecoveryDirectoryClaim?,
                                 holds: [MarkdownVisualCoordinator.ActionHold]) async {
        var failures: [String] = []
        if case .failure(let failure) = result { failures.append(ApplyRecoveryFailure.message(failure)) }
        let reloadFailures = await workspace.reloadRecoveryDocuments(mutation, expectedSnapshots: expectedSnapshots)
        if !reloadFailures.isEmpty {
            failures.append(L10n.format("Die Dateien wurden bearbeitet, aber diese offenen Dokumente konnten nicht bestätigt neu geladen werden:\n%@",
                                        reloadFailures.map(\.path).sorted().joined(separator: "\n")))
        }
        let finalFailures = await Task.detached(priority: .userInitiated) {
            var messages: [String] = []
            if let claim {
                do {
                    try claim.validateBinding()
                    for (url, expected) in expectedSnapshots {
                        guard try FileSnapshot.readSnapshotOnly(from: url) == expected else {
                            throw ApplyRecoveryPreview.Failure.changed(url)
                        }
                    }
                    try claim.validateBinding()
                } catch { messages.append(ApplyRecoveryFailure.message(error)) }
                do { try claim.finish() } catch { messages.append(ApplyRecoveryFailure.message(error)) }
            }
            return messages
        }.value
        failures.append(contentsOf: finalFailures)
        workspace.finishRecoveryDiskMutation(mutation)
        for hold in holds { hold.finish() }
        task = nil; isExecuting = false; isBusy = false; review = nil
        error = failures.isEmpty ? nil : failures.joined(separator: "\n\n")
        status = failures.isEmpty
            ? L10n.string("Die bestätigte Sitzung ist abgeschlossen. Für weitere Aktionen die Sitzung erneut prüfen.")
            : L10n.string("Die Freigabe ist verbraucht. Behebe die Ursache und prüfe dieselbe Sitzung vor einer Wiederholung erneut.")
        if closed || !workspace.showSearchDialog {
            if workspace.fileRecoverySession === self { workspace.fileRecoverySession = nil }
        }
    }

    nonisolated private static func resolveRoots(_ roots: [URL]) throws -> [URL] {
        try roots.map { root in
            let resolved = try ApplyPersistenceBarriers.resolvingRootAliases(root)
            // Der Ablage-Resolver liefert Directory-URLs. Ein Datei-Set muss
            // denselben Zielpfad ohne angehängten Verzeichnisschrägstrich binden.
            return URL(fileURLWithPath: resolved.path, isDirectory: false)
        }
    }

    nonisolated private static func validateProcess(_ processes: ApplyRecoveryProcessScope.Observation,
                                                    directory: ApplyRecoverySessionReader.DirectoryObservation) throws {
        let created = Date(timeIntervalSince1970: Double(directory.birthSeconds) + Double(directory.birthNanoseconds) / 1_000_000_000)
        try processes.validate(sessionCreatedAt: created)
    }
}
