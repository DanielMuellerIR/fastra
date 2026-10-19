import SwiftUI

@MainActor
private final class FileDiffTransferApplyModel: ObservableObject {
    @Published private(set) var applying = false
    @Published private(set) var error: String?
    private var work: Task<FileDiffTransferPreview.ValidatedApply, Error>?
    private var completion: Task<Void, Never>?
    private var generation: UInt64 = 0

    func apply(_ preview: FileDiffTransferPreview, in workspace: Workspace) {
        guard !applying, preview.isCurrent(in: workspace, checkingText: false),
              workspace.fileDiffTransferPreview?.id == preview.id else { return }
        applying = true
        let generation = self.generation
        let work = Task.detached(priority: .userInitiated) {
            try preview.validateForApply(isCancelled: { Task.isCancelled })
        }
        self.work = work
        completion = Task { [weak self, weak workspace] in
            let result = await work.result
            guard !Task.isCancelled, let self, self.generation == generation, let workspace,
                  workspace.fileDiffTransferPreview?.id == preview.id else { return }
            self.applying = false; self.work = nil; self.completion = nil
            do {
                try workspace.applyFileDiffTransfer(result.get())
            } catch { self.error = TextWorkflowFailure.message(error) }
        }
    }

    func invalidate() {
        cancel()
        error = FileDiffTransfer.Failure.stale.localizedDescription
    }

    func cancel() {
        generation &+= 1
        work?.cancel(); completion?.cancel(); work = nil; completion = nil; applying = false
    }

    deinit { work?.cancel(); completion?.cancel() }
}

struct FileDiffTransferPreviewSheet: View {
    @ObservedObject var workspace: Workspace
    let preview: FileDiffTransferPreview
    @StateObject private var model = FileDiffTransferApplyModel()
    @Environment(\.dismiss) private var dismiss

    private var canApply: Bool {
        !model.applying && model.error == nil && preview.isCurrent(in: workspace, checkingText: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Blockübernahme prüfen").fontWeight(.semibold)
                Text(preview.targetName).textSelection(.enabled).lineLimit(2).truncationMode(.middle).help(preview.targetName)
                Text("Anwenden ändert nur das Zieldokument im Speicher und besitzt natives Undo. Speichere das Dokument anschließend wie gewohnt.")
                    .foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                if preview.hasAnnotations {
                    Text("Markierungen in ⟦…⟧ zeigen Zeilenenden und exakte Unicode-Zeichen; sie werden nicht eingefügt.")
                        .fastraFont(.small).foregroundStyle(Theme.textSecondary)
                }
            }.padding(12)
            Divider()
            if let error = model.error {
                Text(error).padding(16).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                FileDiffView(request: preview.previewRequest, document: preview.document, allowsExport: false)
            }
            Divider()
            HStack {
                Button(model.applying ? L10n.string("Abbrechen") : L10n.string("Schließen")) { close() }
                    .keyboardShortcut(.cancelAction)
                    .background(SelfTestMarker(id: "fileDiffTransferClose").frame(width: 0, height: 0))
                Spacer()
                if model.applying {
                    ProgressView().controlSize(.small)
                    Text("Quellen werden geprüft…").fastraFont(.small)
                }
                Button("Block übernehmen") { model.apply(preview, in: workspace) }
                    .disabled(!canApply).keyboardShortcut(.defaultAction)
                    .background(SelfTestMarker(id: "fileDiffTransferApply").frame(width: 0, height: 0))
                    .background(SelfTestMarker(id: canApply ? "fileDiffTransferApplyReady" : "fileDiffTransferApplyBlocked").frame(width: 0, height: 0))
            }.padding(12)
        }
        .frame(minWidth: 620, idealWidth: 900, minHeight: 440, idealHeight: 650)
        .background(SelfTestMarker(id: "fileDiffTransferSheet").frame(width: 0, height: 0))
        .onChange(of: workspace.tabs) { validate() }
        .onChange(of: workspace.activeTabID) { validate() }
        .onDisappear {
            model.cancel()
            if workspace.fileDiffTransferPreview?.id == preview.id { workspace.fileDiffTransferPreview = nil }
        }
    }

    private func validate() {
        if workspace.fileDiffTransferPreview?.id == preview.id && !preview.isCurrent(in: workspace, checkingText: false) {
            model.invalidate()
        }
    }

    private func close() {
        model.cancel()
        if workspace.fileDiffTransferPreview?.id == preview.id { workspace.fileDiffTransferPreview = nil }
        dismiss()
    }
}
