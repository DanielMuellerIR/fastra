import SwiftUI

struct ApplyRecoverySheet: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var session: ApplyRecoverySession
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTarget: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Dateiwiederherstellung").fontWeight(.semibold)
                Text("Wähle ausdrücklich eine vollständige Sitzung. Erst die Bestätigung stellt die gezeigten Originaldateien wieder her und entfernt zugehörige temporäre Reste. Die Änderung erfolgt atomar pro Datei und kann bei einem Fehler teilweise erfolgt sein.")
                    .foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(L10n.format("Gewählte Quellen:\n%@", session.roots.map(\.path).joined(separator: "\n")))
                        .fastraFont(.small).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 75)
                Picker("Aufbewahrte Sitzung", selection: Binding(get: { session.selectedName ?? "" }, set: { name in
                    selectedTarget = nil; session.select(name)
                })) {
                    Text("Sitzung auswählen…").tag("")
                    ForEach(session.candidates) { candidate in
                        Text(verbatim: candidate.sessionName).tag(candidate.sessionName)
                    }
                }.disabled(session.isExecuting)
                if let notice = session.listingNotice {
                    Text(notice).fastraFont(.small).foregroundStyle(Theme.textSecondary)
                }
            }.padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if session.isBusy { ProgressView().controlSize(.small) }
                    if let error = session.error {
                        Label("Wiederherstellung angehalten", systemImage: "exclamationmark.triangle")
                        Text(error).textSelection(.enabled)
                    }
                    if let status = session.status { Text(status).foregroundStyle(Theme.textSecondary) }
                    if let review = session.review {
                        reviewContent(review)
                    } else if !session.isBusy, session.error == nil, session.status == nil {
                        Text(session.candidates.isEmpty
                             ? L10n.string("Keine frühere Sitzung in der geschützten Ablage gefunden.")
                             : L10n.string("Wähle eine Sitzung, um ihre Dateien und verbleibenden Aufräumarbeiten zu prüfen."))
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button(session.isExecuting ? L10n.string("Abbruch anfordern") : L10n.string("Schließen")) {
                    if session.isExecuting { session.cancel() }
                    else { session.close(); dismiss() }
                }.keyboardShortcut(.cancelAction)
                Button("Sitzung erneut prüfen") { session.refreshSelected() }
                    .disabled(session.isBusy || session.isExecuting || !session.contextIsCurrent)
                Spacer()
                Button(session.review?.preview.hasFileWrites == true
                       ? L10n.string("Gezeigte Dateien wiederherstellen") : L10n.string("Gezeigte Sitzung abschließen")) {
                    session.confirm()
                }.disabled(!session.canConfirm)
                    .background(SelfTestMarker(id: session.canConfirm ? "fileRecoveryConfirmReady" : "fileRecoveryConfirmBlocked").frame(width: 0, height: 0))
            }.padding(12)
        }
        .frame(minWidth: 700, idealWidth: 960, minHeight: 500, idealHeight: 700)
        .background(SelfTestMarker(id: "fileRecoverySheet").frame(width: 0, height: 0))
        .interactiveDismissDisabled(session.isExecuting)
        .onAppear { session.load() }
        .onDisappear { session.close() }
        .onReceive(workspace.$scope) { proposed in
            if proposed != session.scope { session.revoke() }
        }
        .onReceive(workspace.$recentSearchFolders) { proposed in
            if session.scope == .folder, proposed.filter(\.enabled).map(\.url) != session.roots { session.revoke() }
        }
        .onReceive(workspace.$projectSearchConfiguration) { proposed in
            if session.scope == .project, proposed != session.projectConfiguration { session.revoke() }
        }
        .onReceive(workspace.$projectURL) { proposed in
            if session.scope == .project, proposed != session.projectRoot { session.revoke() }
        }
        .onReceive(workspace.$showSearchDialog) { proposed in
            if !proposed { session.revoke() }
        }
    }

    @ViewBuilder private func reviewContent(_ review: ApplyRecoveryReview) -> some View {
        let preview = review.preview
        Text(L10n.format("Dateien: %ld · Verbleibende Aufräumpfade: %ld", preview.targets.count, preview.remainingCleanupURLs.count))
            .fontWeight(.medium)
        ForEach(Array(preview.targets.enumerated()), id: \.offset) { index, target in
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: target.url.path).textSelection(.enabled)
                    Text(stateDescription(target.state)).fastraFont(.small).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if review.differences[index] != nil {
                    Button("Unterschiede zeigen") { selectedTarget = index }
                }
            }
        }
        if let index = selectedTarget ?? review.differences.keys.sorted().first,
           let difference = review.differences[index] {
            if difference.hasAnnotations {
                Text("Markierungen in ⟦…⟧ zeigen Zeilenenden und exakte Unicode-Zeichen; sie werden nicht eingefügt.")
                    .fastraFont(.small).foregroundStyle(Theme.textSecondary)
            }
            Text(L10n.format("BOM aktuell: %@ · BOM Original: %@", hex(difference.currentBOM), hex(difference.originalBOM)))
                .fastraFont(.small).foregroundStyle(Theme.textSecondary)
            FileDiffView(request: FileDiffRequest(
                left: .text("", name: L10n.string("Aktueller Dateistand"), path: difference.target.url.path),
                right: .text("", name: L10n.string("Gesichertes Original"), path: difference.target.url.path),
                options: .init()), document: difference.document, allowsExport: false)
                .id(index).frame(minHeight: 260)
        }
        if !preview.remainingCleanupURLs.isEmpty {
            Text("Diese zugehörigen temporären Ressourcen werden entfernt:").fontWeight(.medium)
            ForEach(preview.remainingCleanupURLs, id: \.path) { url in
                Text(verbatim: url.path).fastraFont(.small).textSelection(.enabled)
            }
        }
    }

    private func stateDescription(_ state: ApplyRecoveryPreview.TargetState) -> String {
        switch state {
        case .restore: return L10n.string("Wird durch das gesicherte Original ersetzt.")
        case .originalAlreadyPresent: return L10n.string("Originalbytes sind bereits vorhanden; kein Zurückschreiben nötig.")
        case .previouslyRestored: return L10n.string("Bereits wiederhergestellt; bleibt unverändert.")
        }
    }

    private func hex(_ data: Data) -> String {
        data.isEmpty ? L10n.string("keine") : data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
