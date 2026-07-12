import SwiftUI

/// Hierarchischer Projekt-Dateibaum in der Seitenleiste. Lädt lazy: jede
/// Ordner-Ebene erst beim Aufklappen (`FileTree.children`), kein rekursiver
/// Vollscan beim Projekt-Öffnen. Klick auf eine Datei lädt sie in einen Tab
/// (derselbe Pfad wie ⌘O — Encoding-Erkennung, Tab-Dedup inklusive).
struct FileTreeSidebar: View {
    let rootURL: URL
    @EnvironmentObject var workspace: Workspace

    /// Aufgeklappte Ordner (Pfad-Set). Identität über Pfade, damit der
    /// Zustand ein Neuladen der Ebenen überlebt.
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Kopfzeile: Projektname + dezenter Schließen-Knopf.
            HStack(spacing: 6) {
                Text(rootURL.lastPathComponent.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    workspace.closeProject()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Projekt schließen (Dateibaum ausblenden)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    FileTreeLevel(url: rootURL, depth: 0, expanded: $expanded)
                }
                .padding(.bottom, 6)
            }
        }
    }
}

/// Eine Ordner-Ebene: listet die Kinder eines Ordners und rendert für
/// aufgeklappte Unterordner rekursiv die nächste Ebene. Die Kinder werden
/// direkt im `body` gelesen — ein Verzeichnis-Listing ist mikrosekunden-
/// schnell, und der Baum ist so bei jedem Neu-Render automatisch aktuell
/// (kein Live-Watch des Dateisystems nötig; `.onAppear`-Ladelogik war hier
/// zudem unzuverlässig — der Baum blieb leer, Befund Screenshot 2026-07-12).
/// Es rendern ohnehin nur AUFGEKLAPPTE Ebenen, große Repos bleiben billig.
private struct FileTreeLevel: View {
    let url: URL
    let depth: Int
    @Binding var expanded: Set<String>
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        ForEach(FileTree.children(of: url)) { node in
            FileTreeRow(node: node,
                        depth: depth,
                        isExpanded: expanded.contains(node.id),
                        isActive: workspace.activeTab?.url == node.url) {
                if node.isDirectory {
                    if expanded.contains(node.id) {
                        expanded.remove(node.id)
                    } else {
                        expanded.insert(node.id)
                    }
                } else {
                    workspace.loadFile(at: node.url)
                }
            }
            if node.isDirectory && expanded.contains(node.id) {
                FileTreeLevel(url: node.url, depth: depth + 1, expanded: $expanded)
            }
        }
    }
}

/// Eine Zeile im Dateibaum: Einrückung nach Tiefe, Chevron nur bei Ordnern,
/// aktive Datei hervorgehoben (gleiche Sprache wie `FileRow` der
/// „GEÖFFNET"-Liste).
private struct FileTreeRow: View {
    let node: FileTreeNode
    let depth: Int
    let isExpanded: Bool
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if node.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 10)
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                } else {
                    Spacer().frame(width: 10)
                    Image(systemName: "doc")
                        .font(.system(size: 11))
                        .foregroundColor(isActive ? Theme.accentReadable : Theme.textSecondary)
                }
                Text(node.name)
                    .font(Theme.uiSmall)
                    .foregroundColor(isActive ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, 14 + CGFloat(depth) * 12)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .background(isActive ? Theme.surfaceRaised : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
