import Foundation
import Combine

/// Die Freigabe trägt die ganze Trefferbasis; nur ihre Ausgabe ist gefiltert.
struct SearchApprovalPreview: Sendable {
    struct MemoryInput: Sendable {
        let tabID: UUID
        let matches: [BufferSearch.Match]
        let approvedIDs: Set<UUID>
    }

    enum Source: Sendable {
        case memory(TextWorkflowOpenDocumentsPlan.Source, [MemoryInput], NSRange?)
        case files([ApplyTransaction.Input])
    }

    struct Request: Identifiable, Sendable {
        let id = UUID()
        let ticket: SearchApproval.Ticket
        let options: SearchOptions
        let scope: Workspace.SearchScope
        let source: Source
        let workspaceID: ObjectIdentifier
        let windowID: ObjectIdentifier

        private init(ticket: SearchApproval.Ticket, options: SearchOptions, scope: Workspace.SearchScope, source: Source,
                     workspaceID: ObjectIdentifier, windowID: ObjectIdentifier) {
            self.ticket = ticket; self.options = options; self.scope = scope; self.source = source
            self.workspaceID = workspaceID; self.windowID = windowID
        }

        @MainActor static func capture(in workspace: Workspace) throws -> Self {
            guard let ticket = workspace.searchApproval.ticket,
                  ticket.approvedIDs.isSubset(of: workspace.editableSearchMatchIDs),
                  !workspace.folderApplying,
                  let window = CommandTargeting.registeredWindow(for: workspace) else { throw Failure.stale }
            let source: Source
            if workspace.scope.isFolderLike {
                let results = workspace.folderResults.filter { !$0.matches.isEmpty }
                guard results.count <= Limits.standard.files else { throw Failure.limits }
                let inputs = try results.map { result in
                    guard let snapshot = result.snapshot else { throw Failure.stale }
                    return ApplyTransaction.Input(url: result.url, snapshot: snapshot,
                        matches: result.matches.map { PlannedMatch(range: $0.range, before: $0.matchText, after: $0.replacedText) },
                        approvedRanges: Set(result.matches.filter { ticket.approvedIDs.contains($0.id) }.map(\.range)))
                }
                source = .files(inputs)
            } else {
                let nav = workspace.navMatches
                let editable = workspace.editableSearchMatchIDs
                let ids = Set(nav.filter { editable.contains($0.id) }.compactMap {
                    $0.tabID ?? (workspace.scope == .file ? workspace.activeTabID : nil)
                })
                let memory: TextWorkflowOpenDocumentsPlan.Source
                do { memory = try .capture(in: workspace, tabIDs: ids) }
                catch TextWorkflowOpenDocumentsPlan.Failure.sizeLimit { throw Failure.limits }
                guard memory.inputs.reduce(0, { $0 + $1.source.utf8.count }) <= Limits.standard.originalBytes else {
                    throw Failure.limits
                }
                let inputs = memory.inputs.map { input in
                    MemoryInput(tabID: input.tabID,
                        matches: nav.filter { ($0.tabID ?? workspace.activeTabID) == input.tabID }.map(\.match),
                        approvedIDs: ticket.approvedIDs)
                }
                source = .memory(memory, inputs, workspace.scope == .file ? workspace.activeSearchRange : nil)
            }
            return Self(ticket: ticket, options: workspace.currentSearchOptions, scope: workspace.scope, source: source,
                        workspaceID: ObjectIdentifier(workspace), windowID: ObjectIdentifier(window))
        }

        @MainActor func isCurrent(in workspace: Workspace) -> Bool {
            guard workspaceID == ObjectIdentifier(workspace),
                  CommandTargeting.registeredWindow(for: workspace).map(ObjectIdentifier.init) == windowID,
                  workspace.scope == scope, workspace.currentSearchOptions == options,
                  workspace.searchApproval.ticket == ticket, !workspace.folderApplying,
                  ticket.approvedIDs.isSubset(of: workspace.editableSearchMatchIDs) else { return false }
            if case .memory(let memory, _, let range) = source {
                return memory.isCurrent(in: workspace)
                    && (scope != .file || range == workspace.activeSearchRange)
            }
            return true
        }
    }

    struct Limits: Sendable {
        var files = TextWorkflowFilePlan.Limits.standard.files
        var originalBytes = TextWorkflowFilePlan.Limits.standard.originalBytes
        var outputBytes = TextWorkflowFilePlan.Limits.standard.outputBytes
        var previewBytes = TextWorkflowFilePlan.Limits.standard.previewBytes
        var rows = 100_000
        var seconds = TextWorkflowFilePlan.Limits.standard.seconds
        static let standard = Limits()
    }

    enum Failure: Error, LocalizedError {
        case stale, limits, timeout, cancelled, incomplete
        case tooManyLines(Int), tooDifferent(Int)
        var errorDescription: String? {
            switch self {
            case .stale: return TextWorkflowFailure.stale
            case .limits: return L10n.string("Die Freigabevorschau ist unvollständig: höchstens 500 Dateien, je 64 MiB Original-, Ausgabe- und Vorschautext, 32 MiB pro Datei sowie 100.000 Vorschauzeilen. Verfeinere die Suche.")
            case .timeout: return L10n.string("Die gemeinsame Vorschau überschreitet 60 Sekunden. Verfeinere den Bereich.")
            case .cancelled: return L10n.string("Die Berechnung wurde abgebrochen.")
            case .incomplete: return L10n.string("Der Vergleich konnte nicht vollständig berechnet werden. Verfeinere die Suche; es wurde nichts angewendet.")
            case .tooManyLines(let limit): return L10n.format("Der Vergleich verarbeitet bis zu %ld Zeilen je Datei. Teile die Datei auf oder vergleiche Ausschnitte.", limit)
            case .tooDifferent(let limit): return L10n.format("Nach Abzug gleicher Anfangs- und Endzeilen bleiben mehr als %ld unterschiedliche Zeilen — das übersteigt das Rechenbudget des zeilengenauen Vergleichs. Ein Ergebnis würde Minuten dauern oder unvollständig sein.", limit)
            }
        }
    }

    struct Entry: Identifiable, Sendable {
        let id: String
        let title: String
        let detail: String
        let request: FileDiffRequest
        let document: FileDiffDocument
        let changed: Bool
        let hasAnnotations: Bool
    }

    let request: Request
    let entries: [Entry]
    let replacements: [UUID: String]
    var changedCount: Int { entries.filter(\.changed).count }

    private init(request: Request, entries: [Entry], replacements: [UUID: String]) {
        self.request = request; self.entries = entries; self.replacements = replacements
    }

    static func build(_ request: Request, limits: Limits = .standard,
                      shouldCancel: @escaping @Sendable () -> Bool = { false },
                      progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) throws -> Self {
        let deadline = ProcessInfo.processInfo.systemUptime + limits.seconds
        @Sendable func cancelled() -> Bool { shouldCancel() || ProcessInfo.processInfo.systemUptime > deadline }
        func check() throws {
            if shouldCancel() { throw Failure.cancelled }
            if ProcessInfo.processInfo.systemUptime > deadline { throw Failure.timeout }
        }
        var originalBytes = limits.originalBytes, outputBytes = limits.outputBytes
        var previewBytes = limits.previewBytes, rows = limits.rows
        var entries: [Entry] = [], replacements: [UUID: String] = [:]
        func diff(id: String, title: String, detail: String, before: String, after: String) throws {
            try check()
            guard before.utf8.count <= originalBytes, after.utf8.count <= outputBytes,
                  before.utf8.count <= Int(FileLoader.largeFileThreshold),
                  after.utf8.count <= Int(FileLoader.largeFileThreshold) else { throw Failure.limits }
            originalBytes -= before.utf8.count; outputBytes -= after.utf8.count
            let result: TextWorkflowDiff.Result
            do {
                result = try TextWorkflowDiff.build(before: before, after: after,
                    maximumDisplayBytes: min(previewBytes, limits.previewBytes), maximumTotalDisplayBytes: previewBytes,
                    isCancelled: cancelled)
            } catch {
                try check()
                if error is TextWorkflowError { throw Failure.limits }
                throw error
            }
            try check()
            guard let document = result.document.result else {
                switch result.document.limitation {
                case .some(.tooManyLines(_, let limit)): throw Failure.tooManyLines(limit)
                case .some(.tooDifferent(let limit)): throw Failure.tooDifferent(limit)
                default: throw Failure.incomplete
                }
            }
            let retained = document.rows.reduce(0) { $0 + ($1.before?.utf8.count ?? 0) + ($1.after?.utf8.count ?? 0) }
            guard retained <= previewBytes, document.rows.count <= rows else { throw Failure.limits }
            previewBytes -= retained; rows -= document.rows.count
            let comparison = FileDiffRequest(left: .text("", name: L10n.string("Vorher")),
                right: .text("", name: L10n.string("Nachher")), options: FileDiffOptions())
            entries.append(Entry(id: id, title: title, detail: detail, request: comparison,
                document: result.document, changed: !before.utf8.elementsEqual(after.utf8), hasAnnotations: result.hasAnnotations))
        }
        switch request.source {
        case .memory(let source, let inputs, let range):
            guard inputs.count <= limits.files, source.inputs.count == inputs.count,
                  Set(inputs.map(\.tabID)).count == inputs.count else { throw Failure.limits }
            for (index, input) in inputs.enumerated() {
                try check()
                guard let document = source.inputs.first(where: { $0.tabID == input.tabID }) else { throw Failure.stale }
                let selected = input.matches.filter { input.approvedIDs.contains($0.id) }
                guard !selected.isEmpty else { continue }
                guard document.source.utf8.count <= originalBytes else { throw Failure.limits }
                let actual = BufferSearch.find(in: document.source, options: request.options,
                    maxMatches: input.matches.count + 1, searchRange: range, shouldCancel: cancelled)
                try check()
                guard actual.invalidPatternMessage == nil, !actual.wasCapped,
                      actual.totalMatches == input.matches.count,
                      zip(actual.matches, input.matches).allSatisfy({ left, right in
                        PlannedMatch(range: left.range, before: left.matchText, after: left.replacedText)
                            == PlannedMatch(range: right.range, before: right.matchText, after: right.replacedText)
                      }) else { throw Failure.stale }
                let after: String
                switch ReplacePreview.replacementText(text: document.source, matches: selected,
                    limits: .init(maximumTextBytes: min(outputBytes, Int(FileLoader.largeFileThreshold)),
                                  maximumLineCount: FileDiff.maximumLineCount,
                                  maximumDiffInputLines: FileDiff.maximumDiffInputLines), shouldCancel: cancelled) {
                case .text(let value): after = value
                case .cancelled: try check(); throw Failure.cancelled
                case .empty: throw Failure.stale
                case .limitation: throw Failure.limits
                }
                try diff(id: input.tabID.uuidString, title: document.title, detail: document.url?.path ?? document.title,
                    before: document.source, after: after)
                if !after.utf8.elementsEqual(document.source.utf8) { replacements[input.tabID] = after }
                progress(index + 1, inputs.count)
            }
        case .files(let inputs):
            guard inputs.count <= limits.files, Set(inputs.map(\.url)).count == inputs.count else { throw Failure.limits }
            let identities = inputs.compactMap { $0.snapshot.identity }
            guard Set(identities).count == identities.count else {
                throw TextWorkflowFilePlan.Failure.duplicateInput(inputs[0].url)
            }
            let searchPlan = try SearchPlan(options: request.options)
            for (index, input) in inputs.enumerated() {
                try check()
                guard let ranges = input.approvedRanges else { throw Failure.stale }
                guard !ranges.isEmpty else { continue }
                guard input.snapshot.byteCount <= min(originalBytes, Int(FileLoader.largeFileThreshold)) else { throw Failure.limits }
                guard let read = try? FileSnapshot.read(from: input.url,
                    byteLimit: UInt64(max(0, input.snapshot.byteCount))) else { throw Failure.stale }
                let plan: PlannedFileChange
                do {
                    plan = try ApplyEngine.planApprovedInput(input, data: read.data, snapshot: read.snapshot,
                        searchPlan: searchPlan, maximumOutputTextBytes: min(outputBytes, Int(FileLoader.largeFileThreshold)),
                        maximumOutputBytes: outputBytes, shouldCancel: cancelled)
                } catch ApplyEngine.PlanningError.outputTooLarge { throw Failure.limits }
                try check()
                guard let encoding = plan.encoding, plan.newBytes.count <= outputBytes,
                      let before = ApplyEngine.decode(payload: Data(plan.originalBytes.dropFirst(plan.bom.count)), encoding: encoding),
                      let after = ApplyEngine.decode(payload: Data(plan.newBytes.dropFirst(plan.bom.count)), encoding: encoding) else { throw Failure.limits }
                try diff(id: input.url.path, title: input.url.lastPathComponent, detail: input.url.path, before: before, after: after)
                originalBytes -= max(0, plan.originalBytes.count - before.utf8.count)
                outputBytes -= max(0, plan.newBytes.count - after.utf8.count)
                guard originalBytes >= 0, outputBytes >= 0 else { throw Failure.limits }
                progress(index + 1, inputs.count)
            }
            // Auch eine unfreigegebene Trefferdatei darf die gemeinsame
            // Basis nicht unbemerkt verändern. Hier bleiben nur Hash-Blöcke
            // im Speicher; Apply wiederholt seinen eigenen globalen Preflight.
            for input in inputs {
                try check()
                guard let current = try? FileSnapshot.readSnapshotOnly(from: input.url,
                    byteLimit: UInt64(max(0, input.snapshot.byteCount))),
                    current == input.snapshot else { throw Failure.stale }
            }
        }
        try check()
        guard !entries.isEmpty else { throw Failure.stale }
        return Self(request: request, entries: entries, replacements: replacements)
    }
}

@MainActor
final class SearchApprovalPreviewModel: ObservableObject {
    @Published private(set) var preview: SearchApprovalPreview?
    @Published private(set) var error: String?
    @Published private(set) var progress = ""
    @Published private(set) var isBusy = false
    private var task: Task<SearchApprovalPreview, Error>?
    private var completion: Task<Void, Never>?
    private var generation: UInt64 = 0

    func load(_ request: SearchApprovalPreview.Request) {
        cancel()
        let generation = self.generation
        isBusy = true
        let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            guard let model = self else { return }
            Task { @MainActor [weak model] in
                guard let model, model.generation == generation else { return }
                model.progress = L10n.format("Vorschau: %ld von %ld", done, total)
            }
        }
        let work = Task.detached(priority: .userInitiated) {
            try SearchApprovalPreview.build(request, shouldCancel: { Task.isCancelled }, progress: report)
        }
        task = work
        completion = Task { [weak self] in
            let result = await work.result
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.isBusy = false; self.task = nil; self.completion = nil
            switch result {
            case .success(let preview): self.preview = preview
            case .failure(let error): self.error = TextWorkflowFailure.message(error)
            }
        }
    }

    func cancel(message: String? = nil) {
        generation &+= 1
        task?.cancel(); completion?.cancel(); task = nil; completion = nil
        preview = nil; isBusy = false; error = message; progress = ""
    }

    deinit { task?.cancel(); completion?.cancel() }
}
