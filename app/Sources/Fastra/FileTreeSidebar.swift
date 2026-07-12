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
                    .fastraFont(size: 10, weight: .semibold)
                    .tracking(0.6)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    workspace.closeProject()
                } label: {
                    Image(systemName: "xmark")
                        .fastraFont(size: 9, weight: .semibold)
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Projekt schließen (Dateibaum ausblenden)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)

            // Branch-Zeile (Etappe 2): nur sichtbar, wenn das Projekt ein
            // Git-Repo ist und git verfügbar (sonst still weg). Zeigt Branch,
            // Ahead/Behind und einen dezenten Auffrisch-Knopf.
            if let status = workspace.gitStatus, let branch = status.branch {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .fastraFont(size: 10)
                        .foregroundColor(Theme.accentReadable)
                    Text(branch)
                        .fastraFont(.small)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if status.ahead > 0 {
                        Label("\(status.ahead)", systemImage: "arrow.up")
                            .labelStyle(.titleAndIcon)
                            .fastraFont(size: 9)
                            .foregroundColor(Theme.textSecondary)
                    }
                    if status.behind > 0 {
                        Label("\(status.behind)", systemImage: "arrow.down")
                            .labelStyle(.titleAndIcon)
                            .fastraFont(size: 9)
                            .foregroundColor(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    // Verlauf öffnen (git log --graph als read-only-Tab).
                    Button {
                        workspace.openGitLog()
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .fastraFont(size: 10)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Verlauf anzeigen (git log)")
                    // Diff öffnen (git diff HEAD als read-only-Tab). Nur sinnvoll,
                    // wenn es überhaupt Änderungen gibt — sonst gedimmt lassen,
                    // aber klickbar (zeigt dann „keine Änderungen").
                    Button {
                        workspace.openGitDiff()
                    } label: {
                        Image(systemName: "plusminus")
                            .fastraFont(size: 10)
                            .foregroundColor(status.entries.isEmpty ? Theme.textSecondary.opacity(0.5) : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Änderungen anzeigen (git diff)")
                    // Aktions-Menü (Commit/Push/Pull + pfiffige Varianten).
                    // Die dezenten Hilfe-Texte hängen als Tooltip an jedem Punkt.
                    Menu {
                        gitActionMenuItems
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .fastraFont(size: 10)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Git-Aktionen")

                    Button {
                        workspace.refreshGitStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .fastraFont(size: 9, weight: .semibold)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Git-Status neu einlesen")
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    FileTreeLevel(url: rootURL, depth: 0, expanded: $expanded)
                }
                .padding(.bottom, 6)
            }
        }
    }

    /// Die Git-Aktions-Einträge — geteilt zwischen Seitenleisten-Popup und dem
    /// „Git"-Menü in der Menüleiste (via `GitActionMenu`).
    @ViewBuilder private var gitActionMenuItems: some View {
        GitActionMenu(workspace: workspace)
    }
}

/// Die kuratierten Git-Aktionen als Menü-Einträge (Etappe 2, Schritt 4).
/// Einmal definiert, an zwei Stellen eingehängt: Seitenleisten-Popup und
/// „Git"-Menü in der Menüleiste. Jeder Punkt trägt seinen dezenten Hilfe-Text
/// als Tooltip (`.help`) — sichtbar bei Bedarf, nie aufdringlich.
struct GitActionMenu: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        Button("Alles committen…") { workspace.gitCommitAll() }
            .help("Alle Änderungen stagen und committen (git add -A + commit).")
        Button("Letzten Commit ergänzen") { workspace.gitAmendNoEdit() }
            .help("Aktuelle Änderungen in den letzten Commit aufnehmen, Botschaft bleibt (git commit --amend --no-edit).")

        Divider()

        Button("Push") { workspace.gitPush() }
            .help("Lokale Commits zum entfernten Repository hochladen (git push).")
        Button("Pull (Fast-Forward)") { workspace.gitPullFastForward() }
            .help("Entfernte Commits nur übernehmen, wenn nichts kollidiert — kein Merge-Commit (git pull --ff-only).")
        Button("Pull (mit Merge)") { workspace.gitPull() }
            .help("Entfernte Commits holen und einbinden, notfalls mit Merge-Commit (git pull).")
        Button("Fetch") { workspace.gitFetch() }
            .help("Entfernten Stand holen, ohne lokal etwas zu ändern (git fetch).")

        Divider()

        Button("Verlauf durchsuchen…") { workspace.gitPickaxe() }
            .help("Finde den Commit, der eine Textstelle eingeführt oder entfernt hat (git log -S).")
        Button("Zum vorherigen Branch") { workspace.gitSwitchPrevious() }
            .help("Zum zuletzt ausgecheckten Branch zurückspringen (git switch -).")
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
                        isActive: workspace.activeTab?.url == node.url,
                        gitState: workspace.gitState(for: node.url),
                        gitFolderChanged: node.isDirectory
                            && workspace.gitFolderHasChanges(node.url)) {
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
    /// Git-Zustand dieser Datei (nil = unverändert / kein Repo).
    let gitState: GitFileState?
    /// Enthält dieser Ordner geänderte Dateien? (Rollup-Punkt an Ordnern.)
    let gitFolderChanged: Bool
    let action: () -> Void

    /// Textfarbe des Namens: geänderte Datei in ihrer Git-Farbe, aktive Datei
    /// betont, sonst gedämpft. Git-Farbe schlägt den Aktiv-Zustand nicht —
    /// die Aktiv-Hervorhebung reicht über den Hintergrund.
    private var nameColor: Color {
        if let gitState { return Theme.gitColor(for: gitState) }
        return isActive ? Theme.textPrimary : Theme.textSecondary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if node.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .fastraFont(size: 8, weight: .semibold)
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 10)
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .fastraFont(size: 11)
                        .foregroundColor(Theme.textSecondary)
                } else {
                    Spacer().frame(width: 10)
                    Image(systemName: "doc")
                        .fastraFont(size: 11)
                        .foregroundColor(isActive ? Theme.accentReadable : Theme.textSecondary)
                }
                Text(node.name)
                    .fastraFont(.small)
                    .foregroundColor(nameColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                // Git-Badge rechts: Datei-Kürzel (M/U/A/…) oder ein dezenter
                // Punkt am Ordner, dessen Inhalt Änderungen enthält.
                if let gitState {
                    Text(gitState.badge)
                        .fastraFont(size: 10, weight: .semibold, design: .monospaced)
                        .foregroundColor(Theme.gitColor(for: gitState))
                        .help(gitState.tooltip)
                } else if gitFolderChanged {
                    Circle()
                        .fill(Theme.accentReadable)
                        .frame(width: 5, height: 5)
                }
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
