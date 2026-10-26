import AppKit
import SwiftUI

final class MarkdownTableController: ObservableObject {
    struct Context: Equatable {
        let row: Int
        let column: Int
        let rows: Int
        let columns: Int
        let reason: String
        let token: String
        let alignment: String
    }
    @Published private(set) var context: Context?
    @Published private(set) var error: String?
    @Published private(set) var isRunning = false
    private var request = 0

    init() { _ = objectWillChange }

    func clear() {
        request += 1
        if context != nil { context = nil }
        if error != nil { error = nil }
        if isRunning { isRunning = false }
    }

    func update(_ value: [String: Any]?) {
        guard let value, let row = value["row"] as? Int, let column = value["column"] as? Int,
              let rows = value["rows"] as? Int, let columns = value["columns"] as? Int,
              let reason = value["reason"] as? String, let token = value["token"] as? String else {
            if context != nil { context = nil; error = nil }
            return
        }
        let next = Context(row: row, column: column, rows: rows, columns: columns,
                           reason: reason, token: token, alignment: value["alignment"] as? String ?? "default")
        if context != next { context = next; error = nil }
    }

    func showError(_ reason: String) {
        switch reason {
        case "html": error = L10n.string("Diese HTML-Tabelle hat keine bearbeitbare Markdown-Struktur.")
        case "selection": error = L10n.string("Bitte den Cursor in eine einzelne Tabellenzelle setzen.")
        case "size": error = L10n.string("Die Tabelle darf höchstens 1.000 Zeilen, 100 Spalten und 10.000 Zellen enthalten; eingefügter Text höchstens 1 MiB.")
        case "edge": error = L10n.string("Die Kopfzeile und die letzte Spalte bleiben erhalten. Verschieben ist an dieser Position nicht möglich.")
        case "busy": error = L10n.string("Bitte die laufende Eingabe oder Bildaktion zuerst abschließen.")
        case "format": error = MarkdownFormatCommand.tableCellRestriction
        default: error = L10n.string("Die Tabellenposition hat sich geändert. Bitte die gewünschte Zelle erneut auswählen.")
        }
    }

    @MainActor func perform(_ command: String, value: String = "", token: String? = nil, in workspace: Workspace) {
        guard !isRunning, workspace.activeMarkdownIsVisual, let context,
              context.reason.isEmpty, let editor = workspace.visualMarkdownEditor,
              editor.tabID == workspace.activeTabID else { return }
        request += 1
        let currentRequest = request, document = workspace.activeTab?.documentID
        isRunning = true; error = nil
        editor.editTable(command, value: value, token: token ?? context.token) { [weak self, weak workspace] reason in
            guard let self, let workspace, self.request == currentRequest,
                  workspace.activeTab?.documentID == document else { return }
            self.isRunning = false
            if let reason { self.showError(reason) }
        }
    }
}

struct MarkdownTableBar: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var table: MarkdownTableController
    @State private var showPaste = false
    @State private var pasteText = ""
    @State private var pasteToken = ""

    var body: some View {
        Group {
            if let context = table.context {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "tablecells")
                        Text(String(format: L10n.string("Zeile %ld · Spalte %ld"), context.row + 1, context.column + 1))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Menu("Zeile") {
                                action("Darüber einfügen", "rowBefore", disabled: context.row == 0)
                                action("Darunter einfügen", "rowAfter")
                                Divider()
                                action("Nach oben verschieben", "rowUp", disabled: context.row <= 1)
                                action("Nach unten verschieben", "rowDown", disabled: context.row == 0 || context.row == context.rows - 1)
                                Divider()
                                action("Zeile löschen", "deleteRow", disabled: context.row == 0)
                            }.fixedSize().background(SelfTestMarker(id: "markdownTableRows").frame(width: 0, height: 0))
                            Menu("Spalte") {
                                action("Links einfügen", "columnBefore")
                                action("Rechts einfügen", "columnAfter")
                                Divider()
                                action("Nach links verschieben", "columnLeft", disabled: context.column == 0)
                                action("Nach rechts verschieben", "columnRight", disabled: context.column == context.columns - 1)
                                Divider()
                                action("Spalte löschen", "deleteColumn", disabled: context.columns == 1)
                            }.fixedSize().background(SelfTestMarker(id: "markdownTableColumns").frame(width: 0, height: 0))
                            Menu {
                                alignment("Standard", "Default", current: context)
                                alignment("Linksbündig", "Left", current: context)
                                alignment("Zentriert", "Center", current: context)
                                alignment("Rechtsbündig", "Right", current: context)
                            } label: { Image(systemName: "text.alignleft") }
                            .fixedSize().help("Ausrichtung der aktuellen Tabellenspalte ändern.")
                            .background(SelfTestMarker(id: "markdownTableAlignment").frame(width: 0, height: 0))
                            Button("TSV einfügen…") {
                                pasteText = NSPasteboard.general.string(forType: .string) ?? ""
                                pasteToken = context.token; showPaste = true
                            }.fixedSize().help("Tabulatorgetrennten Text ab der aktuellen Zelle einfügen. Tab und Shift-Tab wechseln zwischen Zellen.")
                                .background(SelfTestMarker(id: "markdownTablePaste").frame(width: 0, height: 0))
                        }.disabled(!context.reason.isEmpty || table.isRunning)
                    }
                    if !context.reason.isEmpty {
                        Text(context.reason == "selection"
                             ? L10n.string("Bitte den Cursor in eine einzelne Tabellenzelle setzen.")
                             : context.reason == "busy" ? L10n.string("Bitte die laufende Eingabe oder Bildaktion zuerst abschließen.")
                             : L10n.string("Diese HTML-Tabelle hat keine bearbeitbare Markdown-Struktur."))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let error = table.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }.fastraFont(.ui).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.surfaceRaised)
                    .background(SelfTestMarker(id: "markdownTableBar").frame(width: 0, height: 0))
                Divider().opacity(0.3)
            } else if let error = table.error {
                HStack {
                    Text(error).fastraFont(.ui).foregroundStyle(.red)
                    Spacer(minLength: 0)
                    Button { table.clear() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Hinweis ausblenden")
                        .accessibilityLabel("Hinweis ausblenden")
                }.padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.surfaceRaised)
            }
        }
        .onChange(of: workspace.activeTabID) { _, _ in table.clear(); showPaste = false }
        .sheet(isPresented: $showPaste) {
            MarkdownTablePasteSheet(text: $pasteText, cancel: { showPaste = false }) { text in
                showPaste = false
                table.perform("pasteTSV", value: text, token: pasteToken, in: workspace)
            }
        }
    }

    private func action(_ title: LocalizedStringKey, _ command: String, disabled: Bool = false) -> some View {
        Button(title) { table.perform(command, in: workspace) }.disabled(disabled)
    }

    private func alignment(_ title: LocalizedStringKey, _ value: String, current: MarkdownTableController.Context) -> some View {
        Button { table.perform("align" + value, in: workspace) } label: {
            if current.alignment == value.lowercased() { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }
}

/// Feld und Bestätigung müssen dieselbe aktuelle Bindung beobachten.
private struct MarkdownTablePasteSheet: View {
    @Binding var text: String
    let cancel: () -> Void
    let insert: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tabulatorgetrennten Text einfügen").fastraFont(size: 17, weight: .semibold)
            Text("Jede Zeile wird eine Tabellenzeile, jeder Tabulator trennt zwei Zellen. Die Tabelle wächst bei Bedarf nach rechts und unten. Bestehende Zielzellen werden ersetzt.").fastraFont(.ui)
            TextEditor(text: $text).font(.system(.body, design: .monospaced))
                .frame(minHeight: 180).border(Theme.textSecondary.opacity(0.3))
                .background(SelfTestMarker(id: "markdownTableTSVField").frame(width: 0, height: 0))
            Text("Grenzen: 1.000 Zeilen, 100 Spalten, 10.000 Zellen und 1 MiB Text.").fastraFont(.ui).foregroundStyle(Theme.textSecondary)
            HStack {
                Button("Abbrechen", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Einfügen") { insert(text) }
                    .keyboardShortcut(.defaultAction).disabled(text.isEmpty)
                    .background(SelfTestMarker(id: "markdownTableTSVInsert").frame(width: 0, height: 0))
                    .background(SelfTestMarker(id: text.isEmpty ? "markdownTableTSVInsertEmpty" : "markdownTableTSVInsertReady").frame(width: 0, height: 0))
            }
        }.padding(20).frame(width: 520, height: 380)
    }
}
