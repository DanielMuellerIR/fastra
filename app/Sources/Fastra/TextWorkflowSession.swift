import AppKit
import Combine
import CodeEditTextView
import SwiftUI
import UniformTypeIdentifiers

struct TextWorkflowDocumentSnapshot {
    let tabID: UUID
    let documentID: UUID
    let url: URL?
    let revision: UInt64
    let source: String
    let selection: NSRange
    let windowID: ObjectIdentifier

    @MainActor func isCurrent(in workspace: Workspace) -> Bool {
        guard let tab = workspace.activeTab, tab.id == tabID, tab.documentID == documentID,
              tab.url?.canonicalFileURL == url, tab.contentRevision == revision,
              tab.isEditableTextDocument, workspace.activeViewMode == .text, !workspace.activeMarkdownIsVisual,
              let window = CommandTargeting.registeredWindow(for: workspace) else { return false }
        return ObjectIdentifier(window) == windowID
    }
}

@MainActor
final class TextWorkflowSession: ObservableObject, Identifiable {
    let id = UUID()
    let snapshot: TextWorkflowDocumentSnapshot
    weak var workspace: Workspace?
    private let store: TextWorkflowStore
    @Published private(set) var saved: [TextWorkflow] = []
    @Published var definition: TextWorkflow {
        didSet {
            if Self.stepsSignature(oldValue.steps) != Self.stepsSignature(definition.steps) { invalidatePreview() }
        }
    }
    @Published var selectionOnly = false { didSet { invalidatePreview() } }
    @Published var scope: TextWorkflowScope = .document { didSet { invalidatePreview(); error = nil } }
    @Published var folderURLs: [URL] = [] { didSet { invalidatePreview() } }
    @Published var fileFilter: FileTypeFilter = .knownText { didSet { invalidatePreview() } }
    @Published var projectSetID: UUID? { didSet { invalidatePreview() } }
    @Published var exclusionsText = "" { didSet { invalidatePreview() } }
    @Published private(set) var batch: TextWorkflowBatch?
    @Published private(set) var selectedInputID: String?
    @Published private(set) var progressText: String?
    @Published private(set) var status: String?
    @Published private(set) var appliedDocuments: TextWorkflowOpenDocumentsPlan.AppliedChange?
    @Published private(set) var memoryRestored = false
    @Published private(set) var diskAppliedSession: ApplySession?
    @Published private(set) var isDiskOperation = false
    @Published private(set) var preview: TextWorkflowEngine.Preview?
    @Published private(set) var diffRequest: FileDiffRequest?
    @Published private(set) var diffDocument: FileDiffDocument?
    @Published private(set) var selectedPreview = -1
    @Published private(set) var representationDetails = false
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    private var baseline: TextWorkflow?
    private var generation = 0
    private var diffGeneration = 0
    private var task: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var closed = false
    private var batchFileSource: TextWorkflowBatch.FileSource?
    private var workspaceObservation: AnyCancellable?

    init(snapshot: TextWorkflowDocumentSnapshot, workspace: Workspace, store: TextWorkflowStore? = nil) {
        self.snapshot = snapshot; self.workspace = workspace; self.store = store ?? TextWorkflowStore()
        definition = TextWorkflow(name: L10n.string("Neuer Ablauf"), steps: [TextWorkflowStep(kind: .trimTrailing)])
        folderURLs = workspace.enabledSearchFolderURLs
        fileFilter = workspace.fileTypeFilter
        projectSetID = workspace.projectSearchConfiguration.activeSetID
        exclusionsText = workspace.projectSearchConfiguration.excludePatternsText
        appliedDocuments = workspace.lastTextWorkflowMemoryChange
        memoryRestored = workspace.textWorkflowMemoryRestored
        _ = objectWillChange
        do {
            saved = try self.store.load()
            if let first = saved.first { definition = first; baseline = first }
        } catch { self.error = Self.message(error) }
        workspaceObservation = workspace.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }

    var dirty: Bool { Self.signature(definition) != baseline.map(Self.signature) }
    var canCancelCalculation: Bool { task != nil }
    var canApply: Bool {
        guard !closed, !dirty, !isBusy, selectedPreview == -1, diffDocument?.result != nil else { return false }
        if scope == .document { return preview?.changed == true && workspace.map(snapshot.isCurrent(in:)) == true }
        guard let batch, batch.isComplete, batch.changedCount > 0 else { return false }
        if let plan = batch.openPlan { return workspace.map(plan.source.isCurrent(in:)) == true }
        return batch.filePlan != nil && (try? fileSource()) == batchFileSource
    }
    var visiblePreview: TextWorkflowEngine.Preview? {
        scope == .document ? preview : batch?.entries.first { $0.id == selectedInputID }?.preview
    }
    var sourceDescription: String {
        if scope == .document { return L10n.string("Die Auswahl bleibt über alle Schritte derselbe Textausschnitt. Jeder Schritt verarbeitet das Ergebnis seines Vorgängers.") }
        if scope == .openDocuments { return L10n.string("Alle editierbaren Textdokumente dieses Fensters werden im Speicher geändert. Speichern erfolgt anschließend ausdrücklich. Andere Fenster gehören nicht zu diesem Bereich.") }
        return L10n.string("Die Vorschau liest Plattendateien. Anwenden schreibt atomar pro Datei; ein später Schreibfehler kann eine geschützte Teilsitzung erzeugen. Währenddessen sind Dateiänderungen appweit kurz gesperrt.")
    }

    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { folderURLs = Array(Set(folderURLs + panel.urls)).sorted { $0.path < $1.path } }
    }

    func fileSource() throws -> TextWorkflowBatch.FileSource {
        guard let workspace else { throw TextWorkflowOpenDocumentsPlan.Failure.stale }
        if scope == .folder { return .init(roots: folderURLs, filter: fileFilter, exclusions: [], projectRoot: nil) }
        // Projektwurzel und Set-Pfade brauchen dieselbe Schreibweise;
        // Foundation standardisiert zum Beispiel /private/tmp zu /tmp.
        guard let root = workspace.projectURL?.standardizedFileURL,
              let set = workspace.projectSearchConfiguration.fileSets.first(where: { $0.id == projectSetID }) else {
            throw TextWorkflowFilePlan.Failure.empty
        }
        let rootPath = root.path
        let roots = try set.paths.map { relative -> URL in
            let url = relative == "." ? root : root.appendingPathComponent(relative).standardizedFileURL
            guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else { throw TextWorkflowFilePlan.Failure.unreadable(url) }
            return url
        }
        var exclusions = exclusionsText.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !exclusions.contains(ProjectSearchConfiguration.requiredExcludePattern) { exclusions.append(ProjectSearchConfiguration.requiredExcludePattern) }
        return .init(roots: roots, filter: fileFilter, exclusions: exclusions, projectRoot: root)
    }
    static func signature(_ definition: TextWorkflow) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(definition)) ?? Data()
    }
    private static func stepsSignature(_ steps: [TextWorkflowStep]) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(steps)) ?? Data()
    }
    var nameBinding: Binding<String> {
        let id = definition.id, revision = definition.revision, initial = definition.name
        return Binding(get: { [weak self] in self?.definition.name ?? initial }, set: { [weak self] value in
            guard let self, !self.closed, self.definition.id == id, self.definition.revision == revision else { return }
            self.definition.name = value
        })
    }

    func binding(for step: TextWorkflowStep) -> Binding<TextWorkflowStep> {
        let id = definition.id, revision = definition.revision
        // AppKit kann das Ende einer Feldeingabe erst nach Umordnen/Löschen
        // melden. Die Bindung folgt deshalb der Identität, nie dem alten Index.
        return Binding(get: { [weak self] in self?.definition.steps.first(where: { $0.id == step.id }) ?? step }, set: { [weak self] value in
            guard let self, !self.closed, self.definition.id == id, self.definition.revision == revision,
                  value.id == step.id, let index = self.definition.steps.firstIndex(where: { $0.id == step.id }) else { return }
            self.definition.steps[index] = value
        })
    }

    func choose(_ definition: TextWorkflow) { self.definition = definition; baseline = definition; error = nil }
    func reloadSaved() {
        do {
            let selected = definition.id
            saved = try store.load()
            if let value = saved.first(where: { $0.id == selected }) ?? saved.first { choose(value) }
            else { new() }
        } catch { self.error = Self.message(error) }
    }
    func new(copy: Bool = false) {
        var draft = copy ? definition : TextWorkflow(name: L10n.string("Neuer Ablauf"), steps: [TextWorkflowStep(kind: .trimTrailing)])
        draft.id = UUID(); draft.revision = UUID()
        draft.steps = draft.steps.map { step in var value = step; value.id = UUID(); return value }
        if copy { draft.name += " (2)" }
        definition = draft; baseline = nil; error = nil
    }

    @discardableResult func save() -> Bool {
        do {
            let value = try store.save(definition, expectedRevision: baseline?.revision)
            saved = try store.load(); definition = value; baseline = value; error = nil
            return true
        } catch { self.error = Self.message(error); return false }
    }

    func remove() {
        guard let baseline else { return }
        do {
            try store.remove(id: baseline.id, expectedRevision: baseline.revision)
            saved = try store.load()
            if let first = saved.first { choose(first) } else { new() }
        } catch { self.error = Self.message(error) }
    }

    func calculate() {
        guard !closed, !isDiskOperation else { return }
        if scope != .document { calculateBatch(); return }
        invalidatePreview()
        guard let workspace, snapshot.isCurrent(in: workspace) else { error = Self.staleMessage; return }
        let generation = generation, definition = definition, snapshot = snapshot, selectionOnly = selectionOnly
        isBusy = true; error = nil
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try TextWorkflowEngine.preview(definition, source: snapshot.source,
                selection: selectionOnly ? snapshot.selection : nil, shouldCancel: { Task.isCancelled }) }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.closed, self.generation == generation else { return }
                self.isBusy = false; self.task = nil
                guard let workspace = self.workspace, snapshot.isCurrent(in: workspace) else { self.error = Self.staleMessage; return }
                switch result {
                case .success(let preview): self.preview = preview; self.showPreview(-1)
                case .failure(let error): self.error = Self.message(error)
                }
            }
        }
    }

    private func calculateBatch() {
        invalidatePreview()
        guard let workspace else { error = TextWorkflowFailure.stale; return }
        let definition = definition, generation = generation, scope = scope
        let diskTabs = scope.isDisk ? workspace.textWorkflowDiskTabStates() : []
        let documents: TextWorkflowOpenDocumentsPlan.Source?
        let files: TextWorkflowBatch.FileSource?
        do {
            documents = scope == .openDocuments ? try .capture(in: workspace) : nil
            files = scope.isDisk ? try fileSource() : nil
        } catch { self.error = TextWorkflowFailure.message(error); return }
        isBusy = true; error = nil; status = nil
        progressText = L10n.string("Eingaben werden ermittelt…")
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let progress: (ApplyTransaction.Progress) -> Void = { value in
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.generation == generation, self.isBusy else { return }
                    self.progressText = L10n.format("Vorschau: %ld von %ld · %@", value.completedFiles, value.totalFiles, value.fileName)
                }
            }
            let result = Result<TextWorkflowBatch, Error> {
                if let documents { return try .documents(definition, source: documents, shouldCancel: { Task.isCancelled }, progress: progress) }
                guard let files else { throw TextWorkflowFilePlan.Failure.empty }
                let deadline = ProcessInfo.processInfo.systemUptime + TextWorkflowFilePlan.Limits.standard.seconds
                let inputs = try files.enumerate(shouldCancel: { Task.isCancelled })
                var limits = TextWorkflowFilePlan.Limits.standard
                limits.seconds = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                return try TextWorkflowBatch.files(definition, inputs: inputs, limits: limits,
                                  openTabs: diskTabs, shouldCancel: { Task.isCancelled }, progress: progress)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.closed, self.generation == generation else { return }
                self.task = nil; self.isBusy = false; self.progressText = nil
                guard let workspace = self.workspace,
                      documents.map({ $0.isCurrent(in: workspace) }) ?? true,
                      files == nil || (try? self.fileSource()) == files else { self.error = TextWorkflowFailure.stale; return }
                switch result {
                case .success(let batch):
                    self.batch = batch; self.batchFileSource = files
                    self.selectInput(batch.entries.first?.id)
                    if !batch.isComplete { self.error = L10n.string("Die Vorschau enthält Fehler. Keine Eingabe kann angewendet werden.") }
                case .failure(let error): self.error = TextWorkflowFailure.message(error)
                }
            }
        }
    }

    func selectInput(_ id: String?) {
        selectedInputID = id; showPreview(-1)
    }

    @discardableResult private func applyBatch() -> Bool {
        guard canApply, let batch, let workspace else { error = TextWorkflowFailure.stale; return false }
        if let plan = batch.openPlan {
            do {
                appliedDocuments = try plan.apply(in: workspace); memoryRestored = false
                workspace.lastTextWorkflowMemoryChange = appliedDocuments; workspace.textWorkflowMemoryRestored = false
                invalidatePreview()
                status = L10n.format("Im Speicher geänderte Dokumente: %ld. Speichere die Dokumente ausdrücklich; die gemeinsame Rücknahme bleibt auf dieser unveränderten Basis verfügbar.", plan.changedDocumentCount)
                return true
            } catch { self.error = TextWorkflowFailure.message(error); return false }
        }
        guard let plan = batch.filePlan else { return false }
        return startDiskOperation(plan: plan, undo: nil, in: workspace)
    }

    var canRestoreDocuments: Bool {
        !isBusy && appliedDocuments.map { change in workspace.map(change.source.isCurrent(in:)) == true } == true
    }
    func restoreDocuments() {
        guard let appliedDocuments, let workspace else { return }
        do {
            self.appliedDocuments = try appliedDocuments.restore(in: workspace)
            memoryRestored.toggle(); invalidatePreview(); error = nil
            workspace.lastTextWorkflowMemoryChange = self.appliedDocuments; workspace.textWorkflowMemoryRestored = memoryRestored
            status = memoryRestored ? L10n.string("Die gemeinsamen Speicheränderungen wurden zurückgenommen.") : L10n.string("Die gemeinsamen Speicheränderungen wurden wiederhergestellt.")
        } catch { self.error = TextWorkflowFailure.message(error) }
    }

    func restoreDisk() {
        guard !isBusy, let session = diskAppliedSession, let workspace else { return }
        _ = startDiskOperation(plan: nil, undo: session, in: workspace)
    }

    @discardableResult private func startDiskOperation(plan: TextWorkflowFilePlan?, undo: ApplySession?, in workspace: Workspace) -> Bool {
        isDiskOperation = true; isBusy = true; error = nil; status = nil
        progressText = L10n.string("Offene Dokumente werden synchronisiert…")
        task = Task { [self, workspace] in
            let (succeeded, editors) = await workspace.synchronizeTextWorkflowDiskDocuments()
            guard succeeded, !Task.isCancelled else {
                for editor in editors { editor.completeAction() }
                isDiskOperation = false; isBusy = false; task = nil; progressText = nil
                error = succeeded ? TextWorkflowFailure.message(ApplyError.cancelled) : TextWorkflowFailure.stale
                return
            }
            launchDiskOperation(plan: plan, undo: undo, in: workspace, heldEditors: editors)
        }
        return true
    }

    private func launchDiskOperation(plan: TextWorkflowFilePlan?, undo: ApplySession?, in workspace: Workspace,
                                     heldEditors: [MarkdownVisualCoordinator]) {
        let urls = plan?.files.map(\.url) ?? undo?.entries.filter { $0.state != .restored }.map { URL(fileURLWithPath: $0.originalPath) } ?? []
        let mutation: Workspace.TextWorkflowDiskMutation
        do {
            guard workspace.textWorkflowDiskEditorsAreHeld(heldEditors) else { throw ApplyError.conflict(TextWorkflowFailure.stale) }
            mutation = try workspace.beginTextWorkflowDiskMutation(urls: urls)
        }
        catch {
            for editor in heldEditors { editor.completeAction() }
            self.error = TextWorkflowFailure.message(error)
            isDiskOperation = false; isBusy = false; task = nil; progressText = nil
            return
        }
        let backupRoot = workspace.folderApplyBackupRoot
        isDiskOperation = true; isBusy = true; error = nil; status = nil
        progressText = undo == nil ? L10n.string("Plattenänderungen werden vorbereitet…") : L10n.string("Geschützte Rücknahme wird geprüft…")
        task = Task.detached(priority: .userInitiated) { [self, workspace] in
            let result = Result<ApplySession, Error> {
                try mutation.preflight(in: workspace, shouldCancel: { Task.isCancelled })
                if Task.isCancelled { throw ApplyError.cancelled }
                if let undo {
                    return try ApplyEngine.undo(undo, beforeAtomicReplace: { _ in try mutation.preflight(in: workspace) })
                }
                guard let plan else { throw TextWorkflowFilePlan.Failure.empty }
                return try ApplyEngine.execute(workflowPlan: plan, backupRoot: backupRoot, shouldCancel: { Task.isCancelled },
                    progress: { value in
                        Task { @MainActor [weak self] in
                            guard let self, self.isDiskOperation else { return }
                            self.progressText = L10n.format("Plattenänderung: %ld von %ld · %@", value.completedFiles, value.totalFiles, value.fileName)
                        }
                    }, beforePreflight: { try mutation.preflight(in: workspace, shouldCancel: { Task.isCancelled }) })
            }
            await MainActor.run {
                self.task = nil; self.isDiskOperation = false; self.isBusy = false
                let ownsLastSession = undo.map { workspace.lastApplySession?.sessionDirectory == $0.sessionDirectory } ?? true
                var session: ApplySession?
                switch result {
                case .success(let value):
                    session = value
                    self.diskAppliedSession = undo == nil ? value : nil
                    if undo != nil && ownsLastSession { workspace.lastApplySession = nil }
                    self.status = undo == nil
                        ? L10n.format("Auf der Platte geänderte Dateien: %ld. Die geschützte Rücknahme prüft vor jedem Zurückschreiben den aktuellen Stand.", value.entries.count)
                        : L10n.string("Die Plattenänderungen wurden zurückgenommen.")
                case .failure(let failure):
                    if case ApplyError.writeFailed(let partial, _) = failure {
                        session = partial
                        if !partial.entries.isEmpty { self.diskAppliedSession = partial }
                    }
                    if case ApplyError.undoFailed(let partial, _) = failure { session = partial; self.diskAppliedSession = partial }
                    self.error = TextWorkflowFailure.message(failure)
                }
                let changed = session?.entries.filter { undo == nil ? $0.state != .restored : $0.state == .restored }
                    .map { URL(fileURLWithPath: $0.originalPath) } ?? []
                workspace.finishTextWorkflowDiskMutation(mutation, changedURLs: changed,
                    session: undo == nil ? session.flatMap { $0.entries.isEmpty ? nil : $0 } : ownsLastSession ? self.diskAppliedSession : nil)
                for editor in heldEditors { editor.completeAction() }
                self.invalidatePreview()
            }
        }
    }

    func showPreview(_ index: Int) {
        diffGeneration += 1; diffTask?.cancel(); diffDocument = nil; diffRequest = nil
        selectedPreview = index
        guard let preview = visiblePreview else { return }
        let before: String, after: String
        if index == -1 { before = preview.source; after = preview.output }
        else if let step = preview.steps.first(where: { $0.index == index }) { before = step.before; after = step.after }
        else { return }
        let request = FileDiffRequest(left: .text(before, name: L10n.string("Vorher")),
                                      right: .text(after, name: L10n.string("Nachher")), options: FileDiffOptions())
        let generation = generation, diffGeneration = diffGeneration
        diffTask = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Result { try TextWorkflowDiff.build(before: before, after: after, isCancelled: { Task.isCancelled }) }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.closed, self.generation == generation, self.diffGeneration == diffGeneration else { return }
                self.diffTask = nil; self.diffRequest = request
                switch outcome {
                case .success(let value): self.diffDocument = value.document; self.representationDetails = value.hasAnnotations
                case .failure(let error): self.diffDocument = .failure(.failed(message: Self.message(error))); self.representationDetails = false
                }
            }
        }
    }

    @discardableResult func apply() -> Bool {
        if scope != .document { return applyBatch() }
        guard canApply, let preview, let workspace, snapshot.isCurrent(in: workspace),
              let editor = CommandTargeting.editorTextView(for: workspace),
              editor.window.map(ObjectIdentifier.init) == snapshot.windowID,
              editor.string.utf8.elementsEqual(snapshot.source.utf8),
              workspace.activeTab?.content.utf8.elementsEqual(snapshot.source.utf8) == true,
              editor.fastraColumnSelectionSnapshot == nil, editor.selectionManager.textSelections.count <= 1,
              !selectionOnly || editor.fastraSafeSelectedRange == snapshot.selection else { error = Self.staleMessage; return false }
        editor.fastraApplyTextOperation(replacing: preview.range, with: preview.replacement)
        close()
        return true
    }

    func invalidatePreview() {
        guard !isDiskOperation else { return }
        generation += 1; diffGeneration += 1
        task?.cancel(); task = nil; diffTask?.cancel(); diffTask = nil
        if preview != nil { preview = nil }
        if diffRequest != nil { diffRequest = nil }
        if diffDocument != nil { diffDocument = nil }
        if representationDetails { representationDetails = false }
        if isBusy { isBusy = false }
        batch = nil; selectedInputID = nil; progressText = nil
    }

    func close() { guard !isDiskOperation else { return }; cancel(); workspace?.textWorkflowSession = nil }
    func cancel() { closed = true; task?.cancel(); diffTask?.cancel() }
    func abortCalculation() {
        if isDiskOperation { task?.cancel(); progressText = L10n.string("Abbruch angefordert. Hat die Schreibphase begonnen, wird der vorbereitete Satz mit Journal zu Ende geführt."); return }
        invalidatePreview(); error = Self.message(TextWorkflowError.cancelled)
    }

    func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true; error = nil
        Task {
            let result = await Task.detached { Result { try FileSnapshot.read(from: url, byteLimit: UInt64(TextWorkflowArchive.maximumBytes)).data } }.value
            guard !closed else { return }
            isBusy = false
            do {
                let imported = try store.importDefinitions(result.get()); saved = try store.load()
                if let first = imported.first { choose(first) }
            } catch { self.error = Self.message(error) }
        }
    }

    func exportFile() {
        do {
            let data = try TextWorkflowArchive.encode([definition])
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Textablauf.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            isBusy = true; error = nil
            Task {
                let result = await Task.detached { Result { try data.write(to: url, options: .atomic) } }.value
                guard !closed else { return }
                isBusy = false
                if case .failure(let error) = result { self.error = Self.message(error) }
            }
        } catch { self.error = Self.message(error) }
    }

    static let staleMessage = L10n.string("Das Dokument oder die Auswahl entspricht nicht mehr der Vorschau. Schließe den Dialog und starte den Ablauf erneut.")
    nonisolated static func message(_ error: Error) -> String {
        guard let error = error as? TextWorkflowError else { return error.localizedDescription }
        switch error {
        case .invalidDefinition: return L10n.string("Ein Ablauf benötigt einen Namen und 1 bis 32 Schritte, davon mindestens einen aktiven.")
        case .invalidStep(let index, let detail):
            let text = detail == "parameters" ? L10n.string("Ein Parameter überschreitet die zulässige Grenze.") : detail == "empty" ? L10n.string("Der Suchausdruck darf nicht leer sein.") : detail
            return L10n.format("Schritt %ld ist ungültig: %@", index+1, text)
        case .invalidSelection: return L10n.string("Bitte eine zusammenhängende Auswahl vollständiger Zeichen verwenden.")
        case .sizeLimit: return L10n.string("Der Ablauf überschreitet eine Größenbegrenzung. Es wurde nichts angewendet.")
        case .matchLimit: return L10n.string("Der Ablauf enthält mehr als 100.000 Ersetzungen in einem Schritt. Es wurde nichts angewendet.")
        case .cancelled: return L10n.string("Die Berechnung wurde abgebrochen.")
        case .timeout: return L10n.string("Der Ablauf überschreitet die Rechenzeit von fünf Sekunden. Es wurde nichts angewendet.")
        case .invalidArchive: return L10n.string("Die Ablaufdatei ist beschädigt, unbekannt oder überschreitet die erlaubte Anzahl von 50 Abläufen.")
        case .staleDefinition: return L10n.string("Dieser Ablauf wurde in einem anderen Fenster geändert. Lade die gespeicherte Fassung erneut.")
        case .duplicateName: return L10n.string("Ein gespeicherter Ablauf hat bereits diesen Namen. Bitte wähle einen anderen Namen.")
        }
    }
}

extension Workspace {
    @MainActor func presentTextWorkflows() {
        guard let tab = activeTab, tab.isEditableTextDocument, activeViewMode == .text, !activeMarkdownIsVisual,
              let editor = CommandTargeting.editorTextView(for: self),
              let window = CommandTargeting.registeredWindow(for: self), editor.window === window,
              editor.fastraColumnSelectionSnapshot == nil, editor.selectionManager.textSelections.count <= 1,
              editor.string.utf8.elementsEqual(tab.content.utf8) else {
            saveSafetyWarningHandler(L10n.string("Textabläufe"), L10n.string("Textabläufe benötigen ein bearbeitbares Dokument in der Quelltextansicht und eine zusammenhängende Auswahl.")); return
        }
        textWorkflowSession = TextWorkflowSession(snapshot: TextWorkflowDocumentSnapshot(tabID: tab.id, documentID: tab.documentID,
            url: tab.url?.canonicalFileURL, revision: tab.contentRevision, source: tab.content,
            selection: editor.fastraSafeSelectedRange, windowID: ObjectIdentifier(window)), workspace: self)
    }
}
