import Foundation

struct FileDiffTransferPreview: Identifiable, Sendable {
    /// Der Main-Thread bekommt diesen Auftrag nur nach dem Datei-Preflight.
    struct ValidatedApply: Sendable {
        let preview: FileDiffTransferPreview
        private let files: [FileDiffSource.ValidatedFile]
        fileprivate init(_ preview: FileDiffTransferPreview, files: [FileDiffSource.ValidatedFile]) {
            self.preview = preview; self.files = files
        }

        // Der Worker hat die Bytes geprüft. Unmittelbar vor der Mutation
        // schließen kurze Kernel-Abfragen die Rückkehrlücke zur Main-Queue;
        // auch gleich große Writes mit restaurierter mtime ändern die ctime.
        func filesAreCurrent() -> Bool { files.allSatisfy { $0.isCurrent() } }
    }
    let id = UUID()
    let comparisonTabID: UUID
    let requestID: UUID
    let direction: FileDiffTransfer.Direction
    let blockID: Int
    let targetName: String
    let left: FileDiffSource
    let right: FileDiffSource
    let change: FileDiffTransfer.Change
    let document: FileDiffDocument
    let previewRequest: FileDiffRequest
    let hasAnnotations: Bool

    var destination: FileDiffSource { direction == .toLeft ? left : right }

    func validateForApply(isCancelled: () -> Bool = { false }) throws -> ValidatedApply {
        let files = try FileDiffSource.validateFiles([left, right], isCancelled: isCancelled)
        return ValidatedApply(self, files: files)
    }

    static func prepare(tabID: UUID, requestID: UUID, direction: FileDiffTransfer.Direction,
                        blockID: Int, targetName: String, document: FileDiffDocument,
                        isCancelled: () -> Bool = { false }) throws -> Self {
        guard let result = document.result, let left = document.leftSource, let right = document.rightSource else {
            throw FileDiffTransfer.Failure.stale
        }
        try FileDiffSource.validateFiles([left, right], isCancelled: isCancelled)
        let change = try FileDiffTransfer.prepare(left: left.text, right: right.text, result: result,
            blockID: blockID, direction: direction, isCancelled: isCancelled)
        let destination = direction == .toLeft ? left : right
        let preview: TextWorkflowDiff.Result
        do {
            preview = try TextWorkflowDiff.build(before: destination.text, after: change.output,
                maximumDisplayBytes: Int(FileLoader.largeFileThreshold), maximumTotalDisplayBytes: 64 * 1024 * 1024,
                isCancelled: isCancelled)
        } catch TextWorkflowError.sizeLimit { throw FileDiffTransfer.Failure.sizeLimit }
        guard let verified = preview.document.result, !verified.isIdentical else { throw FileDiffTransfer.Failure.incomplete }
        let previewRequest = FileDiffRequest(left: .text("", name: L10n.string("Vorher")),
            right: .text("", name: L10n.string("Nachher")), options: FileDiffOptions())
        return Self(comparisonTabID: tabID, requestID: requestID, direction: direction, blockID: blockID, targetName: targetName,
            left: left, right: right, change: change, document: preview.document, previewRequest: previewRequest,
            hasAnnotations: preview.hasAnnotations)
    }

    @MainActor func isCurrent(in workspace: Workspace, checkingText: Bool = true) -> Bool {
        guard workspace.activeTabID == comparisonTabID,
              let tab = workspace.tabs.first(where: { $0.id == comparisonTabID }),
              tab.fileDiffRequest?.id == requestID,
              left.referencesCurrentDocument(in: workspace), right.referencesCurrentDocument(in: workspace),
              let target = destination.documentOrigin?.currentTab(in: workspace),
              workspace.textEditingIsAllowed(for: target) else { return false }
        return !checkingText || (left.isCurrent(in: workspace) && right.isCurrent(in: workspace))
    }
}
