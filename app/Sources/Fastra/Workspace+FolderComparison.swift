import Foundation

struct FolderComparisonRequest: Identifiable, Hashable, Sendable {
    let id = UUID()
    let left: URL
    let right: URL
    let options: FolderComparison.Options
}

struct FolderComparisonTabState: Hashable {
    let request: FolderComparisonRequest
    var result: FolderComparison.Result?
    var progress: FolderComparison.Progress?
    var running = true
    var cancelled = false
    var error: String?
    var completedAt: Date?
}

@MainActor
extension Workspace {
    func presentFolderComparisonDialog(left: URL? = nil, right: URL? = nil) {
        folderComparisonPrefill = (left ?? projectURL, right)
        showFolderComparisonDialog = true
    }

    func openFolderComparison(request: FolderComparisonRequest) {
        if synchronizeVisualMarkdownBefore({ self.openFolderComparison(request: request) }) { return }
        guard CommandTargeting.registeredWindow(for: self) != nil else { return }
        var tab = EditorTab(title: L10n.format("Ordner: %@ ↔ %@", request.left.lastPathComponent, request.right.lastPathComponent),
            path: L10n.string("Ordnervergleich"), readOnlyReason: L10n.string("Ordnervergleiche sind schreibgeschützt."))
        tab.folderComparison = FolderComparisonTabState(request: request)
        tabs.append(tab)
        activeTabID = tab.id
        runFolderComparison(tabID: tab.id, request: request)
    }

    func refreshFolderComparison(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              let old = tabs[index].folderComparison?.request else { return }
        let request = FolderComparisonRequest(left: old.left, right: old.right, options: old.options)
        tabs[index].folderComparison = FolderComparisonTabState(request: request)
        runFolderComparison(tabID: tabID, request: request)
    }

    func cancelFolderComparison(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), tabs[index].folderComparison?.running == true else { return }
        fileDiffComputations.cancel(tabID: tabID)
        tabs[index].folderComparison?.running = false
        tabs[index].folderComparison?.cancelled = true
        tabs[index].folderComparison?.progress = nil
    }

    private func runFolderComparison(tabID: UUID, request: FolderComparisonRequest) {
        let ticket = fileDiffComputations.begin(tabID: tabID)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Swift.Result<FolderComparison.Result, Error>
            do {
                outcome = .success(try FolderComparison.compare(left: request.left, right: request.right,
                    options: request.options, isCancelled: { Task.isCancelled }, progress: { progress in
                        Task { @MainActor [weak self] in
                            guard let self, self.fileDiffComputations.isCurrent(ticket),
                                  let index = self.tabs.firstIndex(where: { $0.id == tabID }),
                                  self.tabs[index].folderComparison?.request.id == request.id else { return }
                            self.tabs[index].folderComparison?.progress = progress
                        }
                    }))
            } catch is CancellationError { return }
            catch { outcome = .failure(error) }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.fileDiffComputations.isCurrent(ticket) else { return }
                self.fileDiffComputations.finish(ticket)
                guard let index = self.tabs.firstIndex(where: { $0.id == tabID }),
                      self.tabs[index].folderComparison?.request.id == request.id else { return }
                self.tabs[index].folderComparison?.running = false
                self.tabs[index].folderComparison?.progress = nil
                self.tabs[index].folderComparison?.completedAt = Date()
                switch outcome {
                case .success(let result): self.tabs[index].folderComparison?.result = result
                case .failure(let error): self.tabs[index].folderComparison?.error = error.localizedDescription
                }
            }
        }
        fileDiffComputations.attach(task, to: ticket)
    }

    func openFolderComparisonPair(tabID: UUID, requestID: UUID, rowID: Data) {
        guard let state = tabs.first(where: { $0.id == tabID })?.folderComparison,
              state.request.id == requestID, !state.running,
              let row = state.result?.rows.first(where: { $0.id == rowID }), row.canOpenPair,
              let left = row.leftURL, let right = row.rightURL else { return }
        // Der bestehende Diff liest beide Dateien frisch. Die Ordnerliste
        // bleibt eine erklärte Momentaufnahme und ist keine Schreibfreigabe.
        openFileDiffTab(request: FileDiffRequest(left: .file(left), right: .file(right), options: FileDiffOptions()))
    }
}
