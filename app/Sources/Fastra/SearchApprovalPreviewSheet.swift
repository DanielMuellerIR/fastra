import SwiftUI
import AppKit

struct SearchApprovalPreviewSheet: View {
    @ObservedObject var workspace: Workspace
    let request: SearchApprovalPreview.Request
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SearchApprovalPreviewModel()
    @State private var selectedID: String?
    @State private var applyError: String?
    @State private var applying = false

    private var selected: SearchApprovalPreview.Entry? {
        model.preview?.entries.first { $0.id == selectedID } ?? model.preview?.entries.first
    }

    private var canApply: Bool {
        (model.preview?.changedCount ?? 0) > 0 && request.isCurrent(in: workspace)
            && applyError == nil && !applying
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Freigegebene Änderungen").fontWeight(.semibold)
                Text(request.scope.isFolderLike
                    ? L10n.string("Anwenden schreibt auf die Platte: atomar pro Datei, mit geschütztem Backup. Eine fehlgeschlagene Mehrdateiänderung kann teilweise erfolgt sein.")
                    : L10n.string("Anwenden ändert nur offene Dokumente im Speicher. Speichern erfolgt wie gewohnt separat; jede Dokumentänderung besitzt natives Undo."))
                    .foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                if let preview = model.preview {
                    HStack {
                        Text(L10n.format("Freigegebene Treffer: %ld · Geänderte Dateien: %ld", request.ticket.approvedIDs.count, preview.changedCount))
                            .fastraFont(.small)
                        Spacer()
                        Picker("Datei", selection: Binding(get: { selected?.id ?? "" }, set: { selectedID = $0 })) {
                            ForEach(preview.entries) { entry in Text(entry.title).tag(entry.id) }
                        }.frame(maxWidth: 300)
                            .background(SelfTestMarker(id: "searchApprovalPreviewFile").frame(width: 0, height: 0))
                    }
                }
            }.padding(12)
            Divider()
            if let message = applyError ?? model.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Vorschau nicht anwendbar", systemImage: "exclamationmark.triangle")
                    Text(message).fixedSize(horizontal: false, vertical: true)
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let selected {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selected.detail).fastraFont(.small).foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled).lineLimit(2).padding(.horizontal, 12).padding(.top, 8)
                    if selected.hasAnnotations {
                        Text("Markierungen in ⟦…⟧ zeigen Zeilenenden und exakte Unicode-Zeichen; sie werden nicht eingefügt.")
                            .fastraFont(.small).foregroundStyle(Theme.textSecondary).padding(.horizontal, 12)
                    }
                    FileDiffView(request: selected.request, document: selected.document, allowsExport: false).id(selected.id)
                }
            } else {
                VStack(spacing: 10) {
                    if model.isBusy { ProgressView() }
                    Text(model.isBusy ? L10n.string("Freigabevorschau wird berechnet…") : L10n.string("Keine wirksame Änderung"))
                    Text(model.progress).foregroundStyle(Theme.textSecondary).fastraFont(.small)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button(model.isBusy || applying ? L10n.string("Abbrechen") : L10n.string("Schließen")) { model.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .background(SelfTestMarker(id: "searchApprovalClose").frame(width: 0, height: 0))
                Spacer()
                Button("Freigegebene Änderungen anwenden") {
                    apply()
                }.disabled(!canApply)
                    .background(SelfTestMarker(id: "searchApprovalApply").frame(width: 0, height: 0))
                    .background(SelfTestMarker(id: canApply ? "searchApprovalApplyReady" : "searchApprovalApplyBlocked").frame(width: 0, height: 0))
            }.padding(12)
                .background(SelfTestMarker(id: applying ? "searchApprovalPreparing" : "searchApprovalIdle").frame(width: 0, height: 0))
        }
        .frame(minWidth: 620, idealWidth: 900, minHeight: 440, idealHeight: 650)
        .background(SelfTestMarker(id: "searchApprovalSheet").frame(width: 0, height: 0))
        .onAppear { model.load(request) }
        .onDisappear { model.cancel() }
        .onChange(of: workspace.showSearchDialog) { _, visible in
            if !visible { model.cancel() }
        }
        .onReceive(workspace.$searchApproval) { approval in
            if approval.ticket != request.ticket { model.cancel(message: TextWorkflowFailure.stale) }
        }
    }

    private func apply() {
        guard let preview = model.preview, !applying else { return }
        if request.scope.isFolderLike {
            applying = true
            Task { @MainActor in
                let (success, editors) = await workspace.synchronizeTextWorkflowDiskDocuments()
                defer { for editor in editors { editor.completeAction() }; applying = false }
                guard success, workspace.textWorkflowDiskEditorsAreHeld(editors) else {
                    applyError = TextWorkflowFailure.stale; return
                }
                finishApply(preview)
            }
        } else {
            applying = true
            let finish = {
                defer { applying = false }
                finishApply(preview)
            }
            if !workspace.synchronizeVisualMarkdownBefore(finish, onFailure: {
                applying = false
                applyError = TextWorkflowFailure.stale
            }) { finish() }
        }
    }

    private func finishApply(_ preview: SearchApprovalPreview) {
        // Schließen entwertet auch eine noch ausstehende WebKit-Antwort.
        // Ihre Rückmeldung darf keine unsichtbare Vorschau mehr anwenden.
        guard workspace.showSearchDialog, model.preview?.request.id == preview.request.id else { return }
        do {
            if try workspace.applySearchApproval(preview) { model.cancel(); dismiss() }
        } catch { applyError = TextWorkflowFailure.message(error) }
    }
}

/// AppKits echte Checkbox behält Tastatur- und Bedienungshilfenverhalten,
/// auch wenn ein Dateikopf nur einen Teil seiner Treffer freigibt.
struct SearchApprovalCheckbox: NSViewRepresentable {
    let identifier: String
    let state: NSControl.StateValue
    let isEnabled: Bool
    let label: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.clicked))
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.setAccessibilityIdentifier(identifier + "-control")
        button.allowsMixedState = state == .mixed
        button.state = state; button.isEnabled = isEnabled
        button.setAccessibilityLabel(label); button.toolTip = label
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func clicked(_ sender: NSButton) { action() }
    }
}
