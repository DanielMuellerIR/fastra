import SwiftUI

struct FolderComparisonView: View {
    @ObservedObject var workspace: Workspace
    let tabID: UUID
    let state: FolderComparisonTabState
    @State private var query = ""
    @State private var status: FolderComparison.Status?
    @State private var selection: Data?

    private var rows: [FolderComparison.Row] {
        (state.result?.rows ?? []).filter {
            (status == nil || $0.status == status)
                && (query.isEmpty || $0.path.localizedCaseInsensitiveContains(query))
        }
    }

    private var selected: FolderComparison.Row? {
        state.result?.rows.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Ordnervergleich").fastraFont(.headline)
                    Spacer()
                    Button(state.running ? L10n.string("Abbrechen") : L10n.string("Neu vergleichen")) {
                        if state.running { workspace.cancelFolderComparison(tabID: tabID) }
                        else { workspace.refreshFolderComparison(tabID: tabID) }
                    }.background(SelfTestMarker(id: state.running ? "folderComparisonCancel" : "folderComparisonRefresh").frame(width: 0, height: 0))
                }
                root(L10n.string("Links"), url: state.request.left)
                root(L10n.string("Rechts"), url: state.request.right)
                Text("Schreibgeschützter Bytevergleich als Momentaufnahme. Dateipaare öffnen den Textvergleich.")
                    .fastraFont(.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    .help("Kodierung, BOM oder Zeilenendenstil können abweichen, obwohl der Textvergleich keine Unterschiede zeigt.")
                if state.running {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(progressTitle).fastraFont(.small)
                    }
                } else if state.cancelled {
                    Label("Abgebrochen – Ergebnis unvollständig.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else if let error = state.error {
                    Text(verbatim: error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else if let result = state.result {
                    Label(result.isComplete ? L10n.string("Vergleich vollständig") : L10n.string("Unvollständig – nicht alle Einträge konnten geprüft werden."),
                        systemImage: result.isComplete ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(result.isComplete ? Color.secondary : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if !result.issues.isEmpty {
                        Text(verbatim: result.issues.prefix(3).joined(separator: "\n"))
                            .fastraFont(.small).foregroundStyle(Theme.textSecondary).lineLimit(3)
                            .help(result.issues.joined(separator: "\n")).textSelection(.enabled)
                    }
                    Text(L10n.format("%d Einträge · Lesebudget: %@", result.rows.count,
                        ByteCountFormatter.string(fromByteCount: Int64(result.budgetBytes), countStyle: .file)))
                        .fastraFont(.small).foregroundStyle(Theme.textSecondary)
                    if let date = state.completedAt { Text(date, style: .time).fastraFont(.small).foregroundStyle(Theme.textSecondary) }
                }
            }.padding(12)
            Divider()
            HStack(spacing: 8) {
                TextField("Ergebnisse filtern", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("folderComparisonFilter")
                Picker("Status", selection: $status) {
                    Text("Alle").tag(Optional<FolderComparison.Status>.none)
                    ForEach(FolderComparison.Status.allCases, id: \.self) { item in
                        Text(verbatim: item.title).tag(Optional(item))
                    }
                }.labelsHidden().frame(maxWidth: 180)
                Button("Dateipaar öffnen") {
                    if let selection { workspace.openFolderComparisonPair(tabID: tabID, requestID: state.request.id, rowID: selection) }
                }.disabled(state.running || selected?.canOpenPair != true)
                    .background(SelfTestMarker(id: selected?.canOpenPair == true ? "folderComparisonOpenPairReady" : "folderComparisonOpenPairBlocked").frame(width: 0, height: 0))
            }.padding(12)
            Text(L10n.format("%d von %d Einträgen angezeigt", rows.count, state.result?.rows.count ?? 0))
                .fastraFont(.small).foregroundStyle(Theme.textSecondary).padding(.horizontal, 12)
                .background(SelfTestMarker(id: "folderComparisonVisibleCount-\(rows.count)").frame(width: 0, height: 0))
            if let result = state.result, result.rows.isEmpty {
                Text("Keine Einträge im gewählten Filter.").foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows, selection: $selection) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 10) {
                            Label(row.path, systemImage: row.isDirectory ? "folder" : "doc")
                                .lineLimit(1).truncationMode(.middle).help(row.path)
                            Spacer(minLength: 8)
                            Text(verbatim: row.status.title).foregroundStyle(row.status == .unavailable ? Color.orange : .secondary)
                        }
                        if let detail = row.detail {
                            Text(verbatim: detail).fastraFont(.small).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.vertical, 3).contentShape(Rectangle()).tag(row.id)
                        .background(SelfTestMarker(id: "folderComparisonRow-" + row.id.base64EncodedString()).frame(width: 0, height: 0))
                }.listStyle(.inset)
            }
        }.background(Theme.surfaceRaised)
            .background(SelfTestMarker(id: state.running ? "folderComparisonRunning" : "folderComparisonFinished").frame(width: 0, height: 0))
            .onChange(of: query) { selection = nil }
            .onChange(of: status) { selection = nil }
            .onChange(of: state.request.id) { selection = nil }
    }

    private func root(_ title: String, url: URL) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: title).fastraFont(.small).frame(width: 42, alignment: .leading)
            Text(verbatim: url.path).fastraFont(.small).lineLimit(1).truncationMode(.middle).help(url.path)
        }
    }

    private var progressTitle: String {
        guard let progress = state.progress else { return L10n.string("Ordner werden gelesen…") }
        switch progress.phase {
        case .enumerating: return L10n.format("Ordner werden gelesen: %d Einträge", progress.completed)
        case .comparing: return L10n.format("Dateien werden verglichen: %d von %d", progress.completed, progress.total ?? 0)
        case .validating: return L10n.format("Dateistände werden geprüft: %d von %d", progress.completed, progress.total ?? 0)
        }
    }
}
