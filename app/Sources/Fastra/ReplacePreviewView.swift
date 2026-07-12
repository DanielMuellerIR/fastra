import SwiftUI

/// Vorher/Nachher-Vorschau der Ersetzungen (v0.10) — die „Vorschau der
/// Änderungen" aus der Suchmaske. Wird als Sheet über dem Hauptfenster gezeigt
/// (an `workspace.livePreview` gekoppelt) und liest die ECHTEN Treffer des
/// aktiven Buffers über die pure `ReplacePreview`-Logik. Ersetzt den früheren
/// No-Op-Button, dessen Flag niemand auswertete (Daniel-Befund 2026-06-23).
struct ReplacePreviewView: View {
    @EnvironmentObject var workspace: Workspace

    /// Obergrenze angezeigter Zeilen — bei mehr erscheint ein Hinweis.
    private let maxRows = 5_000

    private var result: ReplacePreview.SideBySideResult {
        ReplacePreview.buildSideBySide(text: workspace.activeTab?.content ?? "",
                                       matches: workspace.bufferMatches,
                                       maxRows: maxRows)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            if result.rows.isEmpty {
                emptyState
            } else {
                columnHeader
                Divider().opacity(0.3)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(result.rows) { row in
                            DocumentDiffRow(row: row)
                        }
                    }
                }
                if result.truncated {
                    Text("… und \(result.totalRows - result.rows.count) weitere ausgerichtete "
                         + "Zeilen (Anzeige auf \(maxRows) begrenzt).")
                        .fastraFont(.small)
                        .foregroundColor(Theme.textSecondary)
                        .padding(.vertical, 6)
                }
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 880, height: 560)
        .background(Theme.surfaceBase)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.fill")
                .foregroundColor(Theme.accentReadable)
            Text("Vorschau der Änderungen")
                .fastraFont(.headline)
            if let title = workspace.activeTab?.title {
                Text("· \(title)")
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Text(summaryText)
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surfaceSand.opacity(0.5))
    }

    private var summaryText: String {
        let n = result.changedRows
        if n == 0 { return "Keine Änderungen" }
        return n == 1 ? "1 geänderte Zeile" : "\(n) geänderte Zeilen"
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Vorher")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Nachher")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fastraFont(size: 10, weight: .semibold)
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.surfaceSand.opacity(0.3))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "eye.slash")
                .fastraFont(size: 28)
                .foregroundColor(Theme.textSecondary)
            Text("Keine Ersetzungen in der aktuellen Datei.")
                .fastraFont(.headline)
                .foregroundColor(Theme.textSecondary)
            Text("Suchbegriff UND Ersetzen-Text eingeben — die Vorschau zeigt dann "
                 + "jede betroffene Zeile vorher und nachher.")
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button("Schließen") { workspace.livePreview = false }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Alle ersetzen") {
                workspace.applyAllInActiveBuffer()
                workspace.livePreview = false
            }
            .keyboardShortcut(.defaultAction)
            .disabled(result.rows.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surfaceSand.opacity(0.4))
    }
}

/// Eine Diff-Zeile: Zeilennummer · Vorher (getönt entfernt) · Nachher (getönt
/// hinzugefügt). Monospaced, beide Spalten gleich breit.
private struct DocumentDiffRow: View {
    let row: ReplacePreview.SideBySideRow

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            pane(line: row.beforeLine, text: row.before, before: true)
            Divider()
            pane(line: row.afterLine, text: row.after, before: false)
        }
        .padding(.horizontal, 8)
    }

    private func pane(line: Int?, text: String?, before: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(line.map(String.init) ?? "")
                .fastraFont(size: 10, design: .monospaced)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 44, alignment: .trailing)
            Text(text ?? " ")
                .fastraFont(.monoSmall)
                .foregroundColor(foreground(before: before))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(background(before: before))
    }

    private func foreground(before: Bool) -> Color {
        switch row.kind {
        case .unchanged: return Theme.textSecondary
        case .added: return before ? Theme.textSecondary : Theme.diffAddedFG
        case .removed: return before ? Theme.diffRemovedFG : Theme.textSecondary
        case .changed: return before ? Theme.diffRemovedFG : Theme.diffAddedFG
        }
    }

    private func background(before: Bool) -> Color {
        switch row.kind {
        case .unchanged: return .clear
        case .added: return before ? Theme.surfaceSand.opacity(0.2) : Theme.diffAddedBG
        case .removed: return before ? Theme.diffRemovedBG : Theme.surfaceSand.opacity(0.2)
        case .changed: return before ? Theme.diffRemovedBG : Theme.diffAddedBG
        }
    }
}
