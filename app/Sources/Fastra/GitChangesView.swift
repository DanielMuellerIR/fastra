import SwiftUI

/// Modus der linken Seitenleiste — umschaltbar über eine kleine Segment-Leiste.
/// „Änderungen"/„Graph" erscheinen nur, wenn ein Git-Repo geladen ist.
enum SidebarMode: String, CaseIterable {
    case files    = "Dateien"
    case changes  = "Änderungen"
    case graph    = "Graph"

    /// Kompakte, auch in einer schmalen Seitenleiste eindeutige Symbole.
    var systemImage: String {
        switch self {
        case .files:   return "folder"
        case .changes: return "square.and.pencil"
        case .graph:   return "point.3.connected.trianglepath.dotted"
        }
    }
}

/// VS-Code-artige Änderungen-Ansicht: Commit-Feld + Commit-Knopf oben, darunter
/// die bereitgestellten und die offenen Änderungen mit datei-genauen Aktionen
/// (Bereitstellen/Verwerfen/Aus-Bereitstellung-nehmen). Nur bei Git-Repo aktiv.
struct GitChangesView: View {
    @EnvironmentObject var workspace: Workspace

    private var staged: [GitChange] { workspace.gitStatus?.stagedChanges ?? [] }
    private var unstaged: [GitChange] { workspace.gitStatus?.unstagedChanges ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if workspace.gitOperationState != nil {
                operationBanner
                Divider().opacity(0.3)
            }
            commitBox

            Divider().opacity(0.3)

            if staged.isEmpty && unstaged.isEmpty {
                VStack {
                    Spacer()
                    Text("Keine Änderungen")
                        .fastraFont(.small)
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        if !staged.isEmpty {
                            sectionHeader("BEREITGESTELLT", count: staged.count,
                                          action: { workspace.gitUnstageAll() },
                                          actionIcon: "minus", actionHelp: "Alle aus Bereitstellung nehmen")
                            ForEach(staged) { change in
                                GitChangeRow(change: change, section: .staged)
                            }
                        }
                        if !unstaged.isEmpty {
                            sectionHeader("ÄNDERUNGEN", count: unstaged.count,
                                          action: { workspace.gitStageAll() },
                                          actionIcon: "plus", actionHelp: "Alle bereitstellen")
                            ForEach(unstaged) { change in
                                GitChangeRow(change: change, section: .unstaged)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .onAppear { workspace.refreshGitOperationState() }
    }

    private var operationBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundColor(Theme.gitModified)
            Text(L10n.format("Laufender Git-Vorgang: %@",
                             workspace.gitOperationState?.localizedName ?? "Git"))
                .fastraFont(.small)
                .fontWeight(.semibold)
            Spacer(minLength: 2)
            Button("Fortsetzen") { workspace.gitContinueOperation() }
                .disabled(workspace.gitOperationsAreBusy || !workspace.conflictedGitChanges.isEmpty)
            Button("Abbrechen…") { workspace.gitAbortOperation() }
                .disabled(workspace.gitOperationsAreBusy)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surfaceSand.opacity(0.55))
        .help(workspace.conflictedGitChanges.isEmpty
              ? L10n.string("Der Vorgang kann fortgesetzt oder bewusst abgebrochen werden.")
              : L10n.format("Noch %ld Konfliktdateien lösen und als gelöst markieren.",
                            workspace.conflictedGitChanges.count))
        .accessibilityElement(children: .contain)
    }

    /// Commit-Feld + Knopf (VS-Code: nur auf dem Änderungen-Tab).
    private var commitBox: some View {
        VStack(spacing: 6) {
            TextField("Nachricht (⌘Enter committet)", text: $workspace.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .fastraFont(.small)
                .lineLimit(1...4)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.surfaceBase)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.stroke, lineWidth: 1))
                )

            Button {
                workspace.gitCommit(message: workspace.commitMessage)
            } label: {
                Label("Commit", systemImage: "checkmark")
                    .fastraFont(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.accentReadable)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.surfaceSand.opacity(0.6))
            )
            .keyboardShortcut(.return, modifiers: .command)
            .help("Bereitgestellte Änderungen committen (nichts bereitgestellt → alles)")
            .disabled(workspace.gitOperationsAreBusy)
        }
        .padding(10)
    }

    /// Abschnitts-Kopf mit Titel, Anzahl-Badge und einer Sammel-Aktion rechts.
    private func sectionHeader(_ title: String, count: Int,
                               action: @escaping () -> Void,
                               actionIcon: String, actionHelp: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: L10n.string(title))
                .fastraFont(size: 10, weight: .semibold)
                .tracking(0.6)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)                       // nie umbrechen (Daniel 2026-07-12)
                .fixedSize(horizontal: true, vertical: false)
            Text("\(count)")
                .fastraFont(size: 9, weight: .semibold, design: .monospaced)
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Theme.surfaceSand))
            Spacer(minLength: 0)
            Button(action: action) {
                Image(systemName: actionIcon)
                    .fastraFont(size: 10, weight: .bold)
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help(L10n.string(actionHelp))
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

/// Eine Datei-Zeile in der Änderungen-Ansicht — abhängig vom Abschnitt zeigt sie
/// beim Überfahren die passenden Aktions-Icons und im Kontextmenü dieselben
/// Aktionen (Daniel-Wunsch 2026-07-12).
private struct GitChangeRow: View {
    enum Section { case staged, unstaged }
    let change: GitChange
    let section: Section
    @EnvironmentObject var workspace: Workspace
    @State private var hovering = false

    /// Der für den Abschnitt maßgebliche Zustand (Index bzw. Working-Tree).
    private var state: GitFileState {
        (section == .staged ? change.staged : change.unstaged) ?? .modified
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
                .fastraFont(size: 11)
                .foregroundColor(Theme.textSecondary)
            ZStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    Text(change.name)
                        .fastraFont(.small)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // Dateinamen sind wichtiger als der ergänzende Ordnerpfad:
                        // SwiftUI kürzt deshalb zuerst den Pfad und erst danach den Namen.
                        .layoutPriority(1)
                    if !change.directory.isEmpty {
                        Text(change.directory)
                            .fastraFont(size: 10)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer(minLength: 0)
                    }
                }

                // Die Aktionen überlagern nur beim Hover das rechte Textende.
                // So bleibt die Zeile stabil, ohne unsichtbar Platz zu sperren.
                actionButtons
                    .padding(.leading, 4)
                    .background(Theme.surfaceRaised)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                    .accessibilityHidden(!hovering)
            }
            .frame(maxWidth: .infinity)
            // Status-Badge (farbig, mit erklärendem Tooltip).
            Text(state.badge)
                .fastraFont(size: 10, weight: .semibold, design: .monospaced)
                .foregroundColor(Theme.gitColor(for: state))
                .help(state.tooltip)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(hovering ? Theme.surfaceRaised : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Ein Einzelklick öffnet weiterhin die Datei. Der exklusive
        // Doppelklick öffnet stattdessen nur ihren passenden Git-Diff.
        .gesture(
            TapGesture(count: 2)
                .exclusively(before: TapGesture(count: 1))
                .onEnded { value in
                    guard change.isPathActionable else { return }
                    switch value {
                    case .first: openDiff()
                    case .second: openFile()
                    }
                }
        )
        .contextMenu { contextItems }
        .help(change.isPathActionable
              ? L10n.format("Doppelklick: Diff für %@ öffnen", change.path)
              : L10n.string("Dieser Dateipfad ist kein gültiges UTF-8. Fastra zeigt ihn nur an und führt keine Dateiaktion aus."))
    }

    /// Hover-Aktionen: Verwerfen/Bereitstellen (unstaged) bzw. Unstage (staged).
    @ViewBuilder private var actionButtons: some View {
        switch section {
        case .unstaged:
            iconButton("arrow.uturn.backward", help: "Änderungen verwerfen") {
                workspace.gitDiscard(change: change)
            }
            iconButton("plus", help: "Änderungen bereitstellen") {
                if let path = change.actionPath { workspace.gitStage(path: path) }
            }
        case .staged:
            iconButton("minus", help: "Aus Bereitstellung nehmen") {
                if let path = change.actionPath { workspace.gitUnstage(path: path) }
            }
        }
    }

    /// Kontextmenü mit denselben Aktionen sowie Diff und „Datei öffnen“.
    @ViewBuilder private var contextItems: some View {
        Button("Änderungen anzeigen (Diff)") { openDiff() }
            .disabled(!change.isPathActionable)
        Button("Datei öffnen") { openFile() }
            .disabled(!change.isPathActionable)
        Divider()
        switch section {
        case .unstaged:
            Button("Änderungen bereitstellen") {
                if let path = change.actionPath { workspace.gitStage(path: path) }
            }.disabled(!change.isPathActionable)
            Button("Änderungen verwerfen") { workspace.gitDiscard(change: change) }
                .disabled(!change.isPathActionable)
        case .staged:
            Button("Aus Bereitstellung nehmen") {
                if let path = change.actionPath { workspace.gitUnstage(path: path) }
            }.disabled(!change.isPathActionable)
        }
    }

    private func iconButton(_ system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .fastraFont(size: 11, weight: .medium)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!change.isPathActionable)
        .help(help)
    }

    /// Öffnet die geänderte Datei in einem Tab (untracked/gelöscht → Beep-frei
    /// über loadFile, das Fehlende meldet). Repo-relativen Pfad auflösen.
    private func openFile() {
        guard let root = workspace.projectURL, let path = change.actionPath else { return }
        workspace.loadFile(at: root.appendingPathComponent(path))
    }

    /// Zeigt genau den Diff des Abschnitts, in dem diese Zeile steht.
    private func openDiff() {
        workspace.openGitChangeDiff(change: change, staged: section == .staged)
    }
}
