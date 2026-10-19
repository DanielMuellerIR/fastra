import AppKit
import SwiftUI

final class MarkdownReferenceController: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var running = false
    @Published private(set) var cancelled = false
    @Published private(set) var report: MarkdownReferenceCheck.Report?
    @Published private(set) var progress: MarkdownReferenceCheck.Progress?
    @Published private(set) var notice: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var checkedRevisions: [UUID: (revision: UInt64, matches: Bool)] = [:]
    private(set) var documentID: UUID?

    init() { _ = objectWillChange }
    deinit { task?.cancel() }

    @MainActor func present(in workspace: Workspace) {
        if workspace.synchronizeVisualMarkdownBefore({ self.present(in: workspace) }) { return }
        guard workspace.activeTabIsMarkdown, let tab = workspace.activeTab else { return }
        cancel()
        documentID = tab.documentID
        report = nil; notice = nil; cancelled = false
        checkedRevisions = [:]
        isPresented = true
    }

    @MainActor func start(in workspace: Workspace, project: Bool) {
        if workspace.synchronizeVisualMarkdownBefore({ self.start(in: workspace, project: project) }) { return }
        guard !project || workspace.projectURL != nil else { notice = L10n.string("Es ist kein Projekt geöffnet."); return }
        guard let tab = workspace.tabs.first(where: { $0.documentID == documentID }),
              !tab.isLoading, tab.displayMode == .text else { notice = L10n.string("Die Ausgangsdatei ist nicht mehr geöffnet."); return }
        cancel()
        report = nil; notice = nil; progress = nil; cancelled = false; running = true
        checkedRevisions = [:]
        let request = UUID(); generation = request
        let source = MarkdownReferenceCheck.Source(documentID: tab.documentID, contentRevision: tab.contentRevision,
            url: tab.url, title: tab.title, content: tab.content)
        let opened = workspace.tabs.filter {
            $0.isOrdinaryTextDocument && !$0.isLoading
                && MarkdownFormat.isMarkdown(format: DocumentFormatResolver.resolve(tab: $0))
        }.map {
            MarkdownReferenceCheck.Source(documentID: $0.documentID, contentRevision: $0.contentRevision,
                url: $0.url, title: $0.title, content: $0.content)
        }
        let root = project ? workspace.projectURL : nil
        var options = MarkdownReferenceCheck.Options()
        options.excludedPatterns = workspace.projectSearchConfiguration.excludePatterns
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<MarkdownReferenceCheck.Report, Error>
            do {
                outcome = .success(try MarkdownReferenceCheck.check(document: source, openDocuments: opened,
                    project: root, options: options, isCancelled: { Task.isCancelled }, progress: { value in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == request, self.running else { return }
                            self.progress = value
                        }
                    }))
            } catch is CancellationError { return }
            catch { outcome = .failure(error) }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.generation == request else { return }
                self.task = nil; self.running = false; self.progress = nil
                switch outcome {
                case .success(let report): self.report = report
                case .failure(let error): self.notice = error.localizedDescription
                }
            }
        }
    }

    @MainActor func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        if running { cancelled = true }
        running = false; progress = nil
    }

    @MainActor func close() { cancel(); isPresented = false }

    @MainActor func invalidateScope() {
        cancel()
        report = nil; notice = nil; cancelled = false; checkedRevisions = [:]
    }

    @MainActor func hasChanged(in workspace: Workspace) -> Bool {
        guard let report else { return false }
        return report.sources.contains { source in
            guard let id = source.documentID else { return false }
            return !workspace.tabs.contains { $0.documentID == id && sourceMatches(source, tab: $0) }
        }
    }

    @MainActor private func sourceMatches(_ source: MarkdownReferenceCheck.Source, tab: EditorTab) -> Bool {
        guard tab.url == source.url else { return false }
        if source.contentRevision == tab.contentRevision { return true }
        if let checked = checkedRevisions[source.id], checked.revision == tab.contentRevision { return checked.matches }
        // WYSIWYG darf dieselben Bytes erneut publizieren. Nur eine neue
        // Inhaltsgeneration braucht einmalig den vollständigen Vergleich.
        let matches = tab.content.utf8.elementsEqual(source.content.utf8)
        checkedRevisions[source.id] = (tab.contentRevision, matches)
        return matches
    }

    @MainActor func jump(to finding: MarkdownReferenceCheck.Finding, in workspace: Workspace) {
        if workspace.synchronizeVisualMarkdownBefore({ self.jump(to: finding, in: workspace) }) { return }
        guard !running, let report, report.findings.contains(where: { $0.id == finding.id }),
              let source = report.sources.first(where: { $0.id == finding.sourceID }) else { return }
        let request = generation
        let origin = workspace.documentOutline.currentPoint(in: workspace)
        func apply() {
            guard self.generation == request, let tab = workspace.activeTab,
                  tab.content.utf8.elementsEqual(source.content.utf8) else { self.notice = L10n.string("Die Quelle wurde geändert. Bitte erneut prüfen."); return }
            self.isPresented = false
            if workspace.activeMarkdownIsVisual { workspace.toggleMarkdownEditingMode() }
            let range = SelectionClamping.clamp(finding.reference.range, textLength: tab.content.utf16.count)
            workspace.pendingEditorJump = PendingEditorJump(documentID: tab.documentID, startLine: nil,
                startColumn: nil, endLine: nil, endColumn: nil, range: range)
            workspace.documentOutline.recordJump(in: workspace, from: origin, range: range)
            NotificationCenter.default.post(name: .fastraJumpToRange, object: workspace,
                userInfo: ["range": NSValue(range: range)])
        }
        if let id = source.documentID {
            guard let tab = workspace.tabs.first(where: { $0.documentID == id }),
                  sourceMatches(source, tab: tab) else { notice = L10n.string("Die Quelle wurde geändert oder geschlossen. Bitte erneut prüfen."); return }
            workspace.activeTabID = tab.id
            apply()
        } else if let url = source.url, let snapshot = source.snapshot {
            let acceptance = FileLoadAcceptance { [weak self] in self?.generation == request }
            workspace.loadFile(at: url, expectedDiskSnapshot: snapshot, acceptance: acceptance) { success in
                guard self.generation == request else { return }
                if success { apply() }
                else { self.notice = L10n.string("Die Quelle konnte nicht auf der geprüften Basis geöffnet werden. Bitte erneut prüfen.") }
            }
        }
    }
}
