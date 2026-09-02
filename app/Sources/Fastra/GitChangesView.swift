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
    @AppStorage("git.changesLayout", store: SelfTest.workspaceDefaults())
    private var changesLayoutRaw = GitChangesLayoutMode.flat.rawValue
    /// Mehrfachauswahl der Dateizeilen (Shift-/Cmd-Klick, Daniel 2026-07-30).
    /// Die Logik selbst lebt testbar in `GitChangesSelection`.
    @State private var selection = GitChangesSelection()
    /// Aufklappzustand getrennt nach Index und Working Tree. Gleichnamige
    /// Ordner in beiden Abschnitten sollen unabhängig inspiziert werden.
    @State private var expandedStagedFolders: Set<String> = []
    @State private var expandedUnstagedFolders: Set<String> = []

    private var staged: [GitChange] { workspace.gitStatus?.stagedChanges ?? [] }
    private var unstaged: [GitChange] { workspace.gitStatus?.unstagedChanges ?? [] }

    /// Sichtbare Zeilenreihenfolge beider Abschnitte — Grundlage für
    /// Shift-Bereiche und das Austragen verschwundener Zeilen.
    private var orderedRowIDs: [GitChangeRowID] {
        rowIDs(for: staged, section: .staged, expanded: expandedStagedFolders)
            + rowIDs(for: unstaged, section: .unstaged,
                     expanded: expandedUnstagedFolders)
    }

    private func rowIDs(for changes: [GitChange], section: GitChangeSection,
                        expanded: Set<String>) -> [GitChangeRowID] {
        let visibleChanges: [GitChange]
        if changesLayout == .flat {
            visibleChanges = changes
        } else {
            visibleChanges = GitChangeTreeBuilder.visibleItems(
                in: GitChangeTreeBuilder.build(changes), expanded: expanded
            ).compactMap { item in
                switch item {
                case .file(let change, _), .summarizedFolder(let change, _):
                    return change
                case .folder:
                    return nil
                }
            }
        }
        return visibleChanges.map {
            GitChangeRowID(section: section, rawPath: $0.rawPath)
        }
    }
    private var primaryAction: GitChangesPrimaryAction {
        GitChangesPrimaryAction.resolve(status: workspace.gitStatus,
                                        targets: workspace.gitPushTargets)
    }
    private var changesLayout: GitChangesLayoutMode {
        GitChangesLayoutMode(rawValue: changesLayoutRaw) ?? .flat
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if workspace.gitOperationState != nil {
                operationBanner
                Divider().opacity(0.3)
            }
            if let warning = workspace.gitPushTargetWarning {
                Text(warning)
                    .fastraFont(.small)
                    .foregroundColor(Theme.gitModified)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
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
                    // `pinnedViews: [.sectionHeaders]` hält den jeweiligen
                    // Abschnittskopf samt Sammel-Knöpfen beim Scrollen oben
                    // stehen (Daniel-Wunsch 2026-07-30) — bei 85 geänderten
                    // Dateien waren Überschrift und Knöpfe sonst weggescrollt.
                    LazyVStack(alignment: .leading, spacing: 1,
                               pinnedViews: [.sectionHeaders]) {
                        if !staged.isEmpty {
                            Section {
                                changeRows(staged, section: .staged,
                                           expandedFolders: $expandedStagedFolders)
                            } header: {
                                sectionHeader("BEREITGESTELLT",
                                              markerID: "gitSectionHeader-staged",
                                              actions: [layoutAction,
                                    HeaderAction(icon: "minus",
                                                 help: "Alle aus Bereitstellung nehmen — einzelne oder mehrere Dateien über Rechtsklick bzw. ⇧/⌘-Klick") {
                                        workspace.gitUnstageAll()
                                    },
                                ])
                            }
                        }
                        if !unstaged.isEmpty {
                            Section {
                                changeRows(unstaged, section: .unstaged,
                                           expandedFolders: $expandedUnstagedFolders)
                            } header: {
                                // Drei Sammel-Aktionen wie in VS Code, nur
                                // dauerhaft sichtbar: Gesamt-Diff, alles
                                // verwerfen, alles bereitstellen
                                // (Daniel-Wunsch 2026-07-30).
                                sectionHeader("ÄNDERUNGEN",
                                              markerID: "gitSectionHeader-unstaged",
                                              actions: unstagedHeaderActions)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                    // Stelle in der Liste über einen Wechsel des
                    // Seitenleisten-Tabs hinweg halten.
                    .sidebarScrollRetention(key: "gitChanges",
                                            memory: workspace.sidebarScrollMemory)
                }
            }
        }
        .onAppear {
            workspace.refreshGitOperationState()
            workspace.refreshGitPushTarget()
        }
        // Nach jedem Status-Refresh verschwundene Zeilen aus der Auswahl
        // nehmen — sonst wirkte eine spätere Sammel-Aktion auf Unsichtbares.
        .onChange(of: workspace.gitStatus) {
            selection.prune(existing: orderedRowIDs)
        }
        .onChange(of: changesLayoutRaw) {
            selection.prune(existing: orderedRowIDs)
        }
        .onChange(of: expandedStagedFolders) {
            selection.prune(existing: orderedRowIDs)
        }
        .onChange(of: expandedUnstagedFolders) {
            selection.prune(existing: orderedRowIDs)
        }
        .background {
            // Macht die Auswahlgröße für Fenster-Selbsttests beobachtbar:
            // Die Klick-Folge kann so nach jedem Schritt auf den erwarteten
            // Zustand warten, statt blind weiterzuklicken.
            SelfTestMarker(id: "gitChangesSelCount-\(selection.count)")
        }
    }

    /// Baut eine Dateizeile samt Auswahl-Zustand und -Reaktionen zusammen.
    private func row(for change: GitChange, section: GitChangeSection) -> some View {
        let rowID = GitChangeRowID(section: section, rawPath: change.rawPath)
        return GitChangeRow(
            change: change, section: section,
            isSelected: selection.isSelected(rowID),
            onSelectPlain: { selection.click(rowID) },
            onSelectCommand: { selection.commandClick(rowID) },
            onSelectShift: { selection.shiftClick(rowID, orderedRows: orderedRowIDs) },
            actionTargets: { actionTargets(for: change, rowID: rowID) },
            depth: 0,
            isDirectorySummary: change.path.hasSuffix("/")
        )
    }

    /// Flache oder hierarchische Zeilen desselben Abschnitts. Die Dateizeile
    /// bleibt in beiden Ansichten identisch; nur Pfad und Einrückung ändern
    /// sich, damit Auswahl und Git-Aktionen denselben geprüften Pfad nutzen.
    @ViewBuilder private func changeRows(_ changes: [GitChange],
                                         section: GitChangeSection,
                                         expandedFolders: Binding<Set<String>>) -> some View {
        if changesLayout == .flat {
            ForEach(changes) { change in
                row(for: change, section: section)
            }
        } else {
            let tree = GitChangeTreeBuilder.build(changes)
            let visible = GitChangeTreeBuilder.visibleItems(
                in: tree, expanded: expandedFolders.wrappedValue
            )
            ForEach(visible) { item in
                switch item {
                case .folder(let folder, let depth):
                    GitChangeFolderRow(
                        folder: folder, depth: depth,
                        isExpanded: expandedFolders.wrappedValue.contains(folder.path)
                    ) {
                        if expandedFolders.wrappedValue.contains(folder.path) {
                            expandedFolders.wrappedValue.remove(folder.path)
                        } else {
                            expandedFolders.wrappedValue.insert(folder.path)
                        }
                        }
                case .summarizedFolder(let change, let depth):
                    treeRow(for: change, section: section, depth: depth,
                            isDirectorySummary: true)
                case .file(let change, let depth):
                    treeRow(for: change, section: section, depth: depth)
                }
            }
        }
    }

    private func treeRow(for change: GitChange, section: GitChangeSection,
                         depth: Int, isDirectorySummary: Bool = false) -> some View {
        let rowID = GitChangeRowID(section: section, rawPath: change.rawPath)
        return GitChangeRow(
            change: change, section: section,
            isSelected: selection.isSelected(rowID),
            onSelectPlain: { selection.click(rowID) },
            onSelectCommand: { selection.commandClick(rowID) },
            onSelectShift: { selection.shiftClick(rowID, orderedRows: orderedRowIDs) },
            actionTargets: { actionTargets(for: change, rowID: rowID) },
            depth: depth,
            isDirectorySummary: isDirectorySummary
        )
    }

    private var layoutAction: HeaderAction {
        HeaderAction(
            icon: changesLayout == .flat ? "folder" : "list.bullet",
            help: changesLayout == .flat
                ? "Änderungen als aufklappbaren Ordnerbaum anzeigen"
                : "Änderungen als flache Liste anzeigen",
            markerID: "gitChangesLayoutToggle"
        ) {
            changesLayoutRaw = changesLayout == .flat
                ? GitChangesLayoutMode.tree.rawValue
                : GitChangesLayoutMode.flat.rawValue
        }
    }

    /// Der Ansichts-Umschalter erscheint genau einmal: im ersten sichtbaren
    /// Abschnitt. Bei gleichzeitig bereitgestellten und offenen Änderungen
    /// vermeidet das zwei Knöpfe, die denselben globalen Zustand verändern.
    private var unstagedHeaderActions: [HeaderAction] {
        var actions: [HeaderAction] = []
        if staged.isEmpty { actions.append(layoutAction) }
        actions.append(
            HeaderAction(icon: "rectangle.split.2x1",
                         help: "Gesamt-Diff aller offenen Änderungen anzeigen",
                         markerID: "gitHeaderOpenDiff") {
                workspace.openGitDiff()
            }
        )
        actions.append(
            HeaderAction(icon: "arrow.uturn.backward",
                         help: "Alle Änderungen verwerfen — einzelne oder mehrere Dateien über Rechtsklick bzw. ⇧/⌘-Klick",
                         markerID: "gitHeaderDiscardAll") {
                workspace.gitDiscard(changes: unstaged)
            }
        )
        actions.append(
            HeaderAction(icon: "plus",
                         help: "Alle bereitstellen — einzelne oder mehrere Dateien über Rechtsklick bzw. ⇧/⌘-Klick",
                         markerID: "gitHeaderStageAll") {
                workspace.gitStageAll()
            }
        )
        return actions
    }

    /// Ziel-Dateien einer Zeilen-Aktion: Ist die Zeile Teil einer
    /// Mehrfachauswahl, wirkt die Aktion auf alle gewählten Zeilen DESSELBEN
    /// Abschnitts — sonst nur auf die Zeile selbst. So lassen sich mehrere
    /// Dateien auf einen Schlag verwerfen oder bereitstellen.
    private func actionTargets(for change: GitChange,
                               rowID: GitChangeRowID) -> [GitChange] {
        guard selection.isSelected(rowID), selection.count > 1 else { return [change] }
        let source = rowID.section == .staged ? staged : unstaged
        return source.filter {
            selection.isSelected(GitChangeRowID(section: rowID.section,
                                                rawPath: $0.rawPath))
        }
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

    /// Commit-Feld + Knopf (VS-Code: nur auf dem Änderungen-Tab). Nach einem
    /// sauberen lokalen Commit wird derselbe Platz zu getrennten Push-Flächen:
    /// Remote-Name und effektive Adresse bleiben je Ziel gemeinsam sichtbar.
    private var commitBox: some View {
        VStack(spacing: 6) {
            switch primaryAction {
            case .commit:
                TextField("Nachricht (⌘Enter committet)",
                          text: $workspace.commitMessage, axis: .vertical)
                    .textFieldStyle(.plain)
                    .fastraFont(.small)
                    .lineLimit(1...4)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Theme.surfaceBase)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Theme.stroke, lineWidth: 1)
                            )
                    )

                primaryButton(title: L10n.string("Commit"),
                              systemImage: "checkmark") {
                    workspace.gitCommit(message: workspace.commitMessage)
                }
                .keyboardShortcut(.return, modifiers: .command)
                // fastraHelp statt .help: Der Tooltip muss den Knopf auch
                // erklären, solange er wegen eines laufenden Git-Vorgangs
                // deaktiviert ist.
                .fastraHelp(L10n.string("Bereitgestellte Änderungen committen (nichts bereitgestellt → alles)"))

            case .push(let targets):
                LazyVGrid(
                    // Zwei Ziele bleiben auch in der realen schmalen
                    // Seitenleiste nebeneinander. `adaptive(minimum:)` brach
                    // dort trotz ausreichender lesbarer Kartenbreite in zwei
                    // Zeilen um und widersprach der sichtbaren Zusage.
                    columns: targets.count > 1
                        ? [GridItem(.flexible(), spacing: 6),
                           GridItem(.flexible(), spacing: 6)]
                        : [GridItem(.flexible())],
                    spacing: 6
                ) {
                    ForEach(targets, id: \.remote) { target in
                        pushTargetButton(target)
                    }
                }
            }
        }
        .padding(10)
    }

    /// Die gesamte Karte ist klickbar (`contentShape` — mit `.plain`-Buttons
    /// wäre sonst nur der gemalte Text die Trefferfläche, Daniel 2026-08-19).
    /// Bei zwei Remotes liegen die Karten in einer normalen
    /// Seitenleistenbreite nebeneinander; weitere Ziele brechen automatisch
    /// in die nächste Zeile um, statt unlesbar schmal zu werden.
    private func pushTargetButton(_ target: GitPushTarget) -> some View {
        let phase = workspace.gitPushFeedback[target.remote]
        return Button {
            workspace.gitPush(to: target)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    // Laufender Push: drehender Kreis. Erfolg: zwei Sekunden
                    // ein Häkchen. Sonst der normale Push-Pfeil.
                    switch phase {
                    case .running:
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                    case .succeeded:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Theme.diffAddedFG)
                            .frame(width: 14, height: 14)
                    case nil:
                        Image(systemName: "arrow.up")
                            .frame(width: 14, height: 14)
                    }
                    Text(L10n.format("Push zu %@", target.remote))
                        .fastraFont(.small)
                        .lineLimit(1)
                }
                Text(target.displayAddress)
                    .fastraFont(size: 9, design: .monospaced)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        SelfTestMarker(
                            id: "gitPrimaryPushAddress-\(target.remote)-"
                                + "\(target.displayAddress.hashValue)"
                        )
                    }
            }
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(Theme.accentReadable)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.surfaceSand.opacity(0.6))
        )
        .background {
            SelfTestMarker(id: "gitPrimaryPush-\(target.remote)")
        }
        .background {
            // Macht die sichtbare Phase für Fenster-Selbsttests beobachtbar.
            if let phase {
                SelfTestMarker(id: "gitPushPhase-\(target.remote)-"
                    + (phase == .running ? "running" : "succeeded"))
            }
        }
        .disabled(workspace.gitOperationsAreBusy || phase == .running)
        // fastraHelp statt .help: gerade der deaktivierte Zustand („läuft …")
        // braucht die Erklärung.
        .fastraHelp(phase == .running
                    ? L10n.format("Push zu %@ läuft …", target.remote)
                    : L10n.format("Lokale Commits ausdrücklich zu %@ übertragen: %@",
                                  target.remote, target.displayAddress))
        .accessibilityLabel(L10n.format("Push zu %@, Ziel %@",
                                        target.remote, target.displayAddress))
        .accessibilityValue(phase == .running
                            ? L10n.string("Push läuft")
                            : phase == .succeeded
                            ? L10n.string("Push erfolgreich") : "")
    }

    private func primaryButton(title: String, systemImage: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
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
        .disabled(workspace.gitOperationsAreBusy)
    }

    /// Eine dauerhaft sichtbare Sammel-Aktion im Abschnitts-Kopf.
    private struct HeaderAction {
        let icon: String
        let help: String
        var markerID: String?
        let action: () -> Void

        init(icon: String, help: String, markerID: String? = nil,
             action: @escaping () -> Void) {
            self.icon = icon
            self.help = help
            self.markerID = markerID
            self.action = action
        }
    }

    /// Abschnitts-Kopf mit Titel und Sammel-Aktionen rechts. Die Anzahl der
    /// geänderten Dateien steht seit 1.114.0 nicht mehr hier, sondern als
    /// Badge auf dem Änderungen-Tab der Seitenleiste — dort ist sie auch
    /// sichtbar, wenn gerade der Dateien- oder Graph-Tab offen ist
    /// (Daniel-Wunsch 2026-09-01).
    /// Er bleibt beim Scrollen oben stehen und braucht deshalb einen deckenden
    /// Hintergrund — sonst schienen die durchlaufenden Dateizeilen hindurch.
    private func sectionHeader(_ title: String,
                               markerID: String,
                               actions: [HeaderAction]) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: L10n.string(title))
                .fastraFont(size: 10, weight: .semibold)
                .tracking(0.6)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)                       // nie umbrechen (Daniel 2026-07-12)
                // Seit dem dritten Knopf gilt: In einer schmal gezogenen
                // Seitenleiste weicht ZUERST der Titel (gekürzt, nie
                // umgebrochen). Mit `fixedSize` bestand er auf seiner
                // Idealbreite und schnitt stattdessen den letzten Knopf ab.
                .truncationMode(.tail)
                .layoutPriority(-1)
            Spacer(minLength: 0)
            // `enumerated`, weil die Aktionen keine eigene Identität brauchen:
            // die Liste ist klein, konstant und pro Abschnitt fest verdrahtet.
            ForEach(Array(actions.enumerated()), id: \.offset) { _, item in
                GitHeaderActionButton(item: item)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
        // Deckender Hintergrund in der Farbe der Seitenleiste: Der festgepinnte
        // Kopf liegt über den scrollenden Zeilen.
        .background(Theme.surfaceBase)
        .overlay(alignment: .bottom) {
            // Feine Kante, damit der stehende Kopf sichtbar von der ersten
            // durchlaufenden Zeile getrennt bleibt.
            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1)
        }
        .background {
            SelfTestMarker(id: markerID)
        }
    }

    /// Header-Knöpfe zeigen ihre vollständige Trefferfläche beim Hover.
    /// Das hilft besonders bei den kleinen Plus/Minus-Symbolen und gilt für
    /// alle Aktionen über der Änderungen-Liste einheitlich.
    private struct GitHeaderActionButton: View {
        let item: HeaderAction
        @State private var hovering = false

        var body: some View {
            Button(action: item.action) {
                Image(systemName: item.icon)
                    .fastraFont(size: 10, weight: .bold)
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(hovering ? Theme.surfaceRaised : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .background {
                if let markerID = item.markerID {
                    SelfTestMarker(id: markerID)
                }
            }
            .onHover { hovering = $0 }
            .help(L10n.string(item.help))
        }
    }
}

/// Ordnerzeile der hierarchischen Änderungen-Ansicht. Symbolik und
/// Aufklapp-Henkel entsprechen dem Dateibaum im ersten Seitenleisten-Reiter.
private struct GitChangeFolderRow: View {
    let folder: GitChangeTreeFolder
    let depth: Int
    let isExpanded: Bool
    let onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .fastraFont(size: 8, weight: .semibold)
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 10)
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .fastraFont(size: 11)
                    .foregroundColor(Theme.textSecondary)
                Text(folder.name)
                    .fastraFont(.small)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 14 + CGFloat(depth) * 14)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? Theme.surfaceRaised : Color.clear)
        .onHover { hovering = $0 }
        .help(folder.path)
    }
}

/// Eine Datei-Zeile in der Änderungen-Ansicht — abhängig vom Abschnitt zeigt sie
/// beim Überfahren die passenden Aktions-Icons und im Kontextmenü dieselben
/// Aktionen (Daniel-Wunsch 2026-07-12). Zeilen sind per Shift-/Cmd-Klick
/// mehrfach markierbar; Aktionen einer markierten Zeile wirken dann auf die
/// ganze Auswahl (Daniel-Wunsch 2026-07-30).
private struct GitChangeRow: View {
    let change: GitChange
    let section: GitChangeSection
    /// Auswahl-Zustand und -Reaktionen kommen vom Elternview, das die
    /// `GitChangesSelection` über beide Abschnitte hinweg besitzt.
    let isSelected: Bool
    let onSelectPlain: () -> Void
    let onSelectCommand: () -> Void
    let onSelectShift: () -> Void
    /// Liefert die Dateien, auf die eine Zeilen-Aktion wirken soll (die
    /// Auswahl, wenn diese Zeile markiert ist — sonst nur diese Zeile).
    let actionTargets: () -> [GitChange]
    /// Einrückung im Baum; null in der flachen Ansicht.
    let depth: Int
    let isDirectorySummary: Bool
    @EnvironmentObject var workspace: Workspace
    @State private var hovering = false

    /// Der für den Abschnitt maßgebliche Zustand (Index bzw. Working-Tree).
    private var state: GitFileState {
        (section == .staged ? change.staged : change.unstaged) ?? .modified
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Zeilenbedienung und Aktionsknöpfe sind Geschwister. Lägen die
            // Knöpfe innerhalb des Zeilen-Buttons, könnte SwiftUI den
            // Plus-Klick als Zeilenklick behandeln und einen Ordner als
            // Datei öffnen. Die Zeile selbst ist bewusst ein Button statt
            // einer Tap-Geste: Buttons sind der im Projekt erprobte, auch
            // für synthetische Testklicks verlässliche Klickpfad; Modifier
            // und Klickzahl liest der Handler aus dem auslösenden Event.
            Button(action: handleRowClick) {
                HStack(spacing: 6) {
                    Image(systemName: isDirectorySummary ? "folder" : "doc")
                        .fastraFont(size: 11)
                        .foregroundColor(Theme.textSecondary)
                    HStack(spacing: 6) {
                        Text(change.name)
                            .fastraFont(.small)
                            .foregroundColor(Theme.textPrimary)
                            .strikethrough(state == .deleted,
                                           color: Theme.gitColor(for: state))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            // Dateinamen sind wichtiger als der ergänzende Ordnerpfad:
                            // SwiftUI kürzt deshalb zuerst den Pfad und erst danach den Namen.
                            .layoutPriority(1)
                        if depth == 0, !change.directory.isEmpty {
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
                    statusBadge
                }
                .padding(.leading, 14 + CGFloat(depth) * 14)
                .padding(.trailing, 8)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Die Aktionen überlagern nur beim Hover das rechte Textende.
            // Das Badge bleibt Teil der Überlagerung, damit keine geschätzte
            // feste Einrückung zwischen Knöpfen und Badge nötig ist.
            HStack(spacing: 6) {
                HStack(spacing: 2) { actionButtons }
                    .padding(.leading, 4)
                    .background(Theme.surfaceRaised)
                statusBadge
            }
            .padding(.trailing, 8)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .accessibilityHidden(!hovering)
        }
        // Markierte Zeilen bleiben auch ohne Hover sichtbar hervorgehoben —
        // die Auswahl ist die Wirkfläche der folgenden Sammel-Aktion.
        .background(isSelected ? Theme.accent.opacity(0.18)
                    : hovering ? Theme.surfaceRaised : Color.clear)
        .contentShape(Rectangle())
        .background {
            // Anker für Fenster-Selbsttests, die echte Klicks auf genau
            // diese Zeile senden (z.B. Mehrfachauswahl + Verwerfen).
            SelfTestMarker(id: "gitChangeRow-"
                + (section == .staged ? "staged" : "unstaged")
                + "-\(change.rawPath.hashValue)")
        }
        .onHover { hovering = $0 }
        .onAppear {
            // Der Fenster-Selbsttest muss den echten Hover-Knopf klicken,
            // ohne dafür den Systemzeiger des Nutzers zu bewegen.
            if SelfTest.requestedTest == "gitstagefolder"
                || SelfTest.requestedTest == "gitmultidiscard" { hovering = true }
        }
        .contextMenu { contextItems }
        .help(isDirectorySummary
              ? L10n.string("Git fasst diesen unversionierten Ordner zusammen; Datei-Vorschau ist nicht verfügbar.")
              : change.isPathActionable
              ? L10n.format("Einfachklick: Vorschau, Doppelklick: Tab dauerhaft öffnen — %@", change.path)
              : L10n.string("Dieser Dateipfad ist kein gültiges UTF-8. Fastra zeigt ihn nur an und führt keine Dateiaktion aus."))
    }

    /// Status-Badge (farbig, mit erklärendem Tooltip). Es erscheint im
    /// Grundlayout und im Hover-Overlay an derselben Stelle.
    private var statusBadge: some View {
        Text(state.badge)
            .fastraFont(size: 10, weight: .semibold, design: .monospaced)
            .foregroundColor(Theme.gitColor(for: state))
            .help(state.tooltip)
    }

    /// Ein Handler für alle Zeilenklicks. Modifier und Klickzahl kommen aus
    /// dem auslösenden Event: Shift/Cmd markieren nur (wie in macOS-Listen),
    /// der Einzelklick öffnet sofort den gemeinsamen Vorschau-Tab und ein
    /// Doppelklick steckt genau diesen Tab dauerhaft fest.
    private func handleRowClick() {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags
            .intersection([.command, .shift, .option, .control]) ?? []
        // `clickCount` ist NUR für Maus-Events definiert — für andere
        // Event-Typen (z.B. Space-Taste auf dem fokussierten Button) wirft
        // AppKit eine Assertion. Dann zählt der Klick als Einzelklick.
        let clickCount: Int
        switch event?.type {
        case .leftMouseUp, .leftMouseDown, .rightMouseUp, .rightMouseDown,
             .otherMouseUp, .otherMouseDown:
            clickCount = event?.clickCount ?? 1
        default:
            clickCount = 1
        }
        // Modifier-Klicks bauen nur die AUSWAHL um und öffnen keinen Tab.
        if flags == .command {
            onSelectCommand()
            return
        }
        if flags == .shift {
            onSelectShift()
            return
        }
        guard flags.isEmpty else { return }
        onSelectPlain()
        guard change.isPathActionable, !isDirectorySummary else { return }
        openFile(preview: clickCount < 2)
    }

    /// Hover-Aktionen: Verwerfen/Bereitstellen (unstaged) bzw. Unstage (staged).
    /// Auf einer markierten Zeile wirken sie auf die gesamte Auswahl.
    @ViewBuilder private var actionButtons: some View {
        switch section {
        case .unstaged:
            iconButton("arrow.uturn.backward",
                       help: L10n.string("Änderungen verwerfen"),
                       markerID: "gitDiscardAction-\(change.rawPath.hashValue)") {
                workspace.gitDiscard(changes: actionTargets())
            }
            iconButton("plus", help: L10n.string("Änderungen bereitstellen"),
                       markerID: "gitStageAction-\(change.rawPath.hashValue)") {
                workspace.gitStage(paths: actionTargets().compactMap(\.actionPath))
            }
        case .staged:
            iconButton("minus", help: L10n.string("Aus Bereitstellung nehmen")) {
                workspace.gitUnstage(paths: actionTargets().compactMap(\.actionPath))
            }
        }
    }

    /// Kontextmenü mit denselben Aktionen sowie Diff und „Datei öffnen“. Bei
    /// Mehrfachauswahl weisen die Einträge ehrlich aus, auf wie viele Dateien
    /// sie wirken.
    @ViewBuilder private var contextItems: some View {
        let targets = actionTargets()
        Button("Änderungen anzeigen (Diff)") { openDiff() }
            .disabled(!change.isPathActionable)
        Button("Datei öffnen") { openFile(preview: false) }
            .disabled(!change.isPathActionable || isDirectorySummary)
        Divider()
        switch section {
        case .unstaged:
            Button(targets.count > 1
                   ? L10n.format("Änderungen bereitstellen (%ld Dateien)", targets.count)
                   : L10n.string("Änderungen bereitstellen")) {
                workspace.gitStage(paths: targets.compactMap(\.actionPath))
            }.disabled(!change.isPathActionable)
            Button(targets.count > 1
                   ? L10n.format("Änderungen verwerfen (%ld Dateien)", targets.count)
                   : L10n.string("Änderungen verwerfen")) {
                workspace.gitDiscard(changes: targets)
            }.disabled(!change.isPathActionable)
        case .staged:
            Button(targets.count > 1
                   ? L10n.format("Aus Bereitstellung nehmen (%ld Dateien)", targets.count)
                   : L10n.string("Aus Bereitstellung nehmen")) {
                workspace.gitUnstage(paths: targets.compactMap(\.actionPath))
            }.disabled(!change.isPathActionable)
        }
    }

    private func iconButton(_ system: String, help: String,
                            markerID: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .fastraFont(size: 11, weight: .medium)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if let markerID {
                SelfTestMarker(id: markerID)
            }
        }
        .disabled(!change.isPathActionable)
        // fastraHelp statt .help: auch für nicht bedienbare Pfade soll der
        // Tooltip erklären, was der Knopf täte. Das Overlay setzt nur den
        // AppKit-Tooltip, keinen Accessibility-Text — VoiceOver bekäme sonst
        // nur den Symbolnamen und könnte die drei Aktionen nicht
        // unterscheiden (Review 2026-09-02). Der Tooltip-Text ist zugleich
        // die Beschriftung.
        .fastraHelp(help)
        .accessibilityLabel(Text(verbatim: help))
    }

    /// Öffnet die Arbeitsdatei beziehungsweise bei einer Löschung die
    /// letzte Git-Version. Der Workspace hält dabei die Vorschau-/Pin-Semantik
    /// an einer Stelle zusammen.
    private func openFile(preview: Bool) {
        workspace.openGitChangeFile(change: change,
                                    staged: section == .staged,
                                    preview: preview)
    }

    /// Zeigt genau den Diff des Abschnitts, in dem diese Zeile steht.
    private func openDiff() {
        workspace.openGitChangeDiff(change: change, staged: section == .staged)
    }
}
