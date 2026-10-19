import Foundation

/// Reiner Speicherauftrag. Seine Eingaben gehören zu genau einem Fenster;
/// Platten-Snapshots und Datei-Schreibrechte sind hier keine Schreibgrundlage.
struct TextWorkflowOpenDocumentsPlan: Sendable {
    struct Input: Sendable {
        let tabID: UUID
        let documentID: UUID
        let revision: UInt64
        let url: URL?
        let source: String
        let title: String

        @MainActor init(_ tab: EditorTab) {
            tabID = tab.id; documentID = tab.documentID; revision = tab.contentRevision
            url = tab.url?.standardizedFileURL; source = tab.content; title = tab.title
        }

        @MainActor func matches(_ tab: EditorTab, in workspace: Workspace) -> Bool {
            tabID == tab.id && documentID == tab.documentID && revision == tab.contentRevision
                && url == tab.url?.standardizedFileURL && workspace.textEditingIsAllowed(for: tab)
                && source.utf8.elementsEqual(tab.content.utf8)
        }
    }

    struct Source: Sendable {
        let workspaceID: ObjectIdentifier
        let windowID: ObjectIdentifier
        let inputs: [Input]
        fileprivate let coversAllEditableTabs: Bool

        fileprivate init(workspaceID: ObjectIdentifier, windowID: ObjectIdentifier, inputs: [Input],
                         coversAllEditableTabs: Bool = true) {
            self.workspaceID = workspaceID; self.windowID = windowID; self.inputs = inputs
            self.coversAllEditableTabs = coversAllEditableTabs
        }

        func selecting(_ tabID: UUID) throws -> Self {
            try selecting([tabID])
        }

        func selecting(_ tabIDs: Set<UUID>) throws -> Self {
            guard !tabIDs.isEmpty, tabIDs.isSubset(of: Set(inputs.map(\.tabID))) else { throw Failure.stale }
            return Self(workspaceID: workspaceID, windowID: windowID,
                        inputs: inputs.filter { tabIDs.contains($0.tabID) }, coversAllEditableTabs: false)
        }

        @MainActor static func capture(in workspace: Workspace, tabIDs: Set<UUID>? = nil) throws -> Self {
            guard let window = CommandTargeting.registeredWindow(for: workspace) else { throw Failure.stale }
            let eligible = workspace.tabs.filter {
                workspace.textEditingIsAllowed(for: $0) && (tabIDs?.contains($0.id) != false)
            }
            guard !eligible.isEmpty else { throw Failure.empty }
            if let tabIDs, Set(eligible.map(\.id)) != tabIDs { throw Failure.stale }
            guard eligible.count <= TextWorkflowFilePlan.Limits.standard.files else { throw Failure.sizeLimit }
            guard Set(eligible.map(\.documentID)).count == eligible.count,
                  Set(eligible.map(\.id)).count == eligible.count else { throw Failure.stale }
            return Self(workspaceID: ObjectIdentifier(workspace), windowID: ObjectIdentifier(window),
                        inputs: eligible.map(Input.init), coversAllEditableTabs: tabIDs == nil)
        }

        @MainActor func isCurrent(in workspace: Workspace) -> Bool {
            guard ObjectIdentifier(workspace) == workspaceID,
                  let window = CommandTargeting.registeredWindow(for: workspace),
                  ObjectIdentifier(window) == windowID else { return false }
            let eligible = workspace.tabs.filter { workspace.textEditingIsAllowed(for: $0) }
            if coversAllEditableTabs && Set(eligible.map(\.id)) != Set(inputs.map(\.tabID)) { return false }
            return inputs.allSatisfy { input in
                eligible.first(where: { $0.id == input.tabID }).map { input.matches($0, in: workspace) } == true
            }
        }
    }

    struct Document: Sendable {
        let input: Input
        let preview: TextWorkflowEngine.Preview
    }

    enum Failure: Error, LocalizedError, Equatable {
        case empty, stale, noChanges, sizeLimit, cancelled, timeout
        case processing(UUID, TextWorkflowError)
        var errorDescription: String? { TextWorkflowFailure.message(self) }
    }

    /// Die gemeinsame Rücknahme bleibt nur auf der exakt angewendeten Basis
    /// möglich. Ein natives Undo in einem Tab entwertet sie ebenfalls.
    struct AppliedChange: Sendable {
        let source: Source
        let originalText: [UUID: String]

        fileprivate init(source: Source, originalText: [UUID: String]) {
            self.source = source; self.originalText = originalText
        }

        @MainActor func restore(in workspace: Workspace) throws -> Self {
            guard source.isCurrent(in: workspace) else { throw Failure.stale }
            return Self.replace(source: source, with: originalText, in: workspace)
        }

        @MainActor fileprivate static func replace(source: Source, with replacements: [UUID: String],
                                                  in workspace: Workspace) -> Self {
            var previous: [UUID: String] = [:], updated = workspace.tabs
            var detections: [(id: UUID, oldLength: Int, newLength: Int)] = []
            for input in source.inputs {
                guard let replacement = replacements[input.tabID],
                      !replacement.utf8.elementsEqual(input.source.utf8),
                      let index = updated.firstIndex(where: { $0.id == input.tabID }) else { continue }
                previous[input.tabID] = input.source
                if Workspace.isEligibleForContentDetection(updated[index]) {
                    detections.append((input.tabID, input.source.count, replacement.count))
                }
                updated[index].undoHistory.replace(input.source, with: replacement)
                updated[index].content = replacement
                updated[index].isDirty = !updated[index].matchesSavedContentBaseline
                updated[index].isPreview = false
            }
            let ids = Set(source.inputs.map(\.tabID))
            let after = updated.filter { ids.contains($0.id) }.map(Input.init)
            // Eine Array-Zuweisung veröffentlicht den vollständigen Zustand;
            // Beobachter sehen keinen halb angewendeten Dokumentensatz.
            workspace.tabs = updated
            workspace.editorReloadNonce += 1
            for id in previous.keys { workspace.cancelFourDMacroPostprocessing(ifTab: id) }
            for detection in detections {
                workspace.scheduleLanguageDetection(tabID: detection.id, oldLength: detection.oldLength,
                                                     newLength: detection.newLength, forceAnalysis: true)
            }
            return Self(source: Source(workspaceID: source.workspaceID, windowID: source.windowID, inputs: after,
                                      coversAllEditableTabs: source.coversAllEditableTabs),
                        originalText: previous)
        }
    }

    let workflow: TextWorkflow
    let source: Source
    let documents: [Document]
    var changedDocumentCount: Int { documents.filter { $0.preview.changed }.count }

    @MainActor static func applyReplacements(_ replacements: [UUID: String], source: Source,
                                             in workspace: Workspace) throws -> AppliedChange {
        guard source.isCurrent(in: workspace),
              Set(replacements.keys).isSubset(of: Set(source.inputs.map(\.tabID))) else { throw Failure.stale }
        guard source.inputs.contains(where: { input in
            replacements[input.tabID].map { !$0.utf8.elementsEqual(input.source.utf8) } == true
        }) else { throw Failure.noChanges }
        var remaining = TextWorkflowFilePlan.Limits.standard.outputBytes
        for value in replacements.values {
            guard value.utf8.count <= Int(FileLoader.largeFileThreshold),
                  value.utf8.count <= remaining else { throw Failure.sizeLimit }
            remaining -= value.utf8.count
        }
        return AppliedChange.replace(source: source, with: replacements, in: workspace)
    }

    private init(workflow: TextWorkflow, source: Source, documents: [Document]) {
        self.workflow = workflow; self.source = source; self.documents = documents
    }

    static func combining(_ plans: [Self], source: Source) throws -> Self {
        guard let first = plans.first else { throw Failure.empty }
        let documents = plans.flatMap(\.documents), limits = TextWorkflowFilePlan.Limits.standard
        guard plans.allSatisfy({ $0.workflow == first.workflow && $0.source.workspaceID == source.workspaceID && $0.source.windowID == source.windowID }),
              documents.count == source.inputs.count, documents.count <= limits.files,
              Set(documents.map { $0.input.tabID }).count == documents.count else { throw Failure.stale }
        var original = limits.originalBytes, output = limits.outputBytes, preview = limits.previewBytes
        for document in documents {
            let input = document.input
            guard let expected = source.inputs.first(where: { $0.tabID == input.tabID }),
                  expected.documentID == input.documentID, expected.revision == input.revision, expected.url == input.url,
                  expected.source.utf8.elementsEqual(input.source.utf8) else { throw Failure.stale }
            guard let retained = document.preview.retainedUTF8Bytes, input.source.utf8.count <= original,
                  document.preview.output.utf8.count <= output, retained <= preview else { throw Failure.sizeLimit }
            original -= input.source.utf8.count; output -= document.preview.output.utf8.count; preview -= retained
        }
        return Self(workflow: first.workflow, source: source, documents: documents)
    }

    static func build(_ workflow: TextWorkflow, source: Source,
                      limits: TextWorkflowFilePlan.Limits = .standard,
                      shouldCancel: () -> Bool = { false },
                      progress: (ApplyTransaction.Progress) -> Void = { _ in }) throws -> Self {
        guard !source.inputs.isEmpty else { throw Failure.empty }
        let standard = TextWorkflowFilePlan.Limits.standard
        guard source.inputs.count <= min(limits.files, standard.files),
              limits.originalBytes >= 0, limits.outputBytes >= 0, limits.previewBytes >= 0 else { throw Failure.sizeLimit }
        let deadline = ProcessInfo.processInfo.systemUptime + min(limits.seconds, standard.seconds)
        func check() throws {
            if shouldCancel() { throw Failure.cancelled }
            if ProcessInfo.processInfo.systemUptime > deadline { throw Failure.timeout }
        }
        var originalBytes = min(limits.originalBytes, standard.originalBytes)
        var outputBytes = min(limits.outputBytes, standard.outputBytes)
        var previewBytes = min(limits.previewBytes, standard.previewBytes)
        var engine = limits.engine
        engine.textBytes = min(engine.textBytes, standard.engine.textBytes)
        engine.intermediateBytes = min(engine.intermediateBytes, standard.engine.intermediateBytes)
        engine.retainedBytes = min(engine.retainedBytes, standard.engine.retainedBytes)
        engine.matches = min(engine.matches, standard.engine.matches)
        engine.seconds = min(engine.seconds, standard.engine.seconds)
        var documents: [Document] = []
        for (index, input) in source.inputs.enumerated() {
            try check()
            guard input.source.utf8.count <= originalBytes else { throw Failure.sizeLimit }
            originalBytes -= input.source.utf8.count
            engine.previewBytes = min(previewBytes, limits.engine.previewBytes ?? previewBytes)
            let preview: TextWorkflowEngine.Preview
            do {
                preview = try TextWorkflowEngine.preview(workflow, source: input.source, limits: engine,
                    shouldCancel: { shouldCancel() || ProcessInfo.processInfo.systemUptime > deadline })
            } catch let error as TextWorkflowError {
                try check()
                throw Failure.processing(input.tabID, error)
            }
            guard let retained = preview.retainedUTF8Bytes, retained <= previewBytes,
                  preview.output.utf8.count <= outputBytes else { throw Failure.sizeLimit }
            previewBytes -= retained; outputBytes -= preview.output.utf8.count
            documents.append(Document(input: input, preview: preview))
            progress(ApplyTransaction.Progress(phase: .planned, completedFiles: index + 1,
                                              totalFiles: source.inputs.count, fileName: input.title))
        }
        try check()
        return Self(workflow: workflow, source: source, documents: documents)
    }

    @MainActor func apply(in workspace: Workspace) throws -> AppliedChange {
        guard changedDocumentCount > 0 else { throw Failure.noChanges }
        guard source.isCurrent(in: workspace) else { throw Failure.stale }
        let replacements = Dictionary(uniqueKeysWithValues: documents.map { ($0.input.tabID, $0.preview.output) })
        return AppliedChange.replace(source: source, with: replacements, in: workspace)
    }
}
