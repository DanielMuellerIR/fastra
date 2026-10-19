import SwiftUI

struct FolderComparisonDialog: View {
    @ObservedObject var workspace: Workspace
    @State private var left: URL?
    @State private var right: URL?
    @State private var knownTextOnly = false
    @State private var exclusions = ""
    private var canStart: Bool { left != nil && right != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ordner vergleichen").fastraFont(.headline)
            Text("Vergleicht ausschließlich lesend. Dateipaare lassen sich anschließend im Dateivergleich öffnen; es werden keine Dateien synchronisiert.")
                .foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 20) {
                folder(L10n.string("Links"), selection: $left, marker: "folderComparisonChooseLeft")
                folder(L10n.string("Rechts"), selection: $right, marker: "folderComparisonChooseRight")
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text("Dateityp")
                    Picker("Dateityp", selection: $knownTextOnly) {
                        Text("Alle Dateien").tag(false)
                        Text("Bekannte Textformate").tag(true)
                    }.labelsHidden().pickerStyle(.menu)
                }
                GridRow {
                    Text("Ausschlüsse")
                    TextField("Ausschlüsse", text: $exclusions).textFieldStyle(.roundedBorder)
                        .help("Mehrere Ausschlussmuster mit Komma oder Zeilenumbruch trennen. Die Muster entsprechen der Ordnersuche.")
                }
            }
            Text("Versteckte Einträge bleiben ausgeschlossen. Symlinks werden angezeigt, aber nicht verfolgt. Grenzen: 20.000 Einträge je Ordner, 256 MiB je Datei und 2 GiB Lesebudget.")
                .fastraFont(.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Abbrechen") { workspace.showFolderComparisonDialog = false }.keyboardShortcut(.cancelAction)
                    .background(SelfTestMarker(id: "folderComparisonDialogCancel").frame(width: 0, height: 0))
                Spacer()
                Button("Vergleichen") {
                    guard let left, let right else { return }
                    let patterns = exclusions.split(whereSeparator: { $0 == "," || $0.isNewline })
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    workspace.openFolderComparison(request: FolderComparisonRequest(left: left, right: right,
                        options: .init(knownTextOnly: knownTextOnly, excludedPatterns: patterns)))
                    workspace.showFolderComparisonDialog = false
                }.keyboardShortcut(.defaultAction).disabled(!canStart)
                    .background(SelfTestMarker(id: "folderComparisonStart").frame(width: 0, height: 0))
                    .background(SelfTestMarker(id: canStart ? "folderComparisonStartReady" : "folderComparisonStartBlocked").frame(width: 0, height: 0))
            }
        }.padding(20).frame(minWidth: 640, idealWidth: 760)
            .fastraScalingRoot()
            .onAppear {
                left = workspace.folderComparisonPrefill.left
                right = workspace.folderComparisonPrefill.right
                exclusions = workspace.projectSearchConfiguration.excludePatternsText
            }
    }

    private func folder(_ title: String, selection: Binding<URL?>, marker: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title).fontWeight(.semibold)
            Label(selection.wrappedValue?.lastPathComponent ?? L10n.string("Ordner auswählen…"), systemImage: "folder")
                .lineLimit(1).truncationMode(.middle)
            Text(verbatim: selection.wrappedValue?.path ?? "—").fastraFont(.small)
                .foregroundStyle(Theme.textSecondary).lineLimit(2).truncationMode(.middle)
                .help(selection.wrappedValue?.path ?? "")
            Button("Auswählen…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true; panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK { selection.wrappedValue = panel.url }
            }.background(SelfTestMarker(id: marker).frame(width: 0, height: 0))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
