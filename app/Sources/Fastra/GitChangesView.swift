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
    /// Mehrfachauswahl der Dateizeilen (Shift-/Cmd-Klick, Daniel 2026-07-30).
    /// Die Logik selbst lebt testbar in `GitChangesSelection`.
    @State private var selection = GitChangesSelection()
    /// Ein gemeinsamer Warteposten für den verzögerten Einzelklick-Öffner
    /// über ALLE Zeilen beider Abschnitte — siehe `PendingSingleOpen`.
    @State private var pendingSingleOpen = PendingSingleOpen()

    private var staged: [GitChange] { workspace.gitStatus?.stagedChanges ?? [] }
    private var unstaged: [GitChange] { workspace.gitStatus?.unstagedChanges ?? [] }

    /// Sichtbare Zeilenreihenfolge beider Abschnitte — Grundlage für
    /// Shift-Bereiche und das Austragen verschwundener Zeilen.
    private var orderedRowIDs: [GitChangeRowID] {
        staged.map { GitChangeRowID(section: .staged, rawPath: $0.rawPath) }
            + unstaged.map { GitChangeRowID(section: .unstaged, rawPath: $0.rawPath) }
    }
    private var primaryAction: GitChangesPrimaryAction {
        GitChangesPrimaryAction.resolve(status: workspace.gitStatus,
                                        target: workspace.gitPushTarget)
    }

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
                    // `pinnedViews: [.sectionHeaders]` hält den jeweiligen
                    // Abschnittskopf samt Sammel-Knöpfen beim Scrollen oben
                    // stehen (Daniel-Wunsch 2026-07-30) — bei 85 geänderten
                    // Dateien waren Überschrift und Knöpfe sonst weggescrollt.
                    LazyVStack(alignment: .leading, spacing: 1,
                               pinnedViews: [.sectionHeaders]) {
                        if !staged.isEmpty {
                            Section {
                                ForEach(staged) { change in
                                    row(for: change, section: .staged)
                                }
                            } header: {
                                sectionHeader("BEREITGESTELLT", count: staged.count,
                                              markerID: "gitSectionHeader-staged",
                                              actions: [
                                    HeaderAction(icon: "minus",
                                                 help: "Alle aus Bereitstellung nehmen — einzelne oder mehrere Dateien über Rechtsklick bzw. ⇧/⌘-Klick") {
                                        workspace.gitUnstageAll()
                                    },
                                ])
                            }
                        }
                        if !unstaged.isEmpty {
                            Section {
                                ForEach(unstaged) { change in
                                    row(for: change, section: .unstaged)
                                }
                            } header: {
                                // Drei Sammel-Aktionen wie in VS Code, nur
                                // dauerhaft sichtbar: Gesamt-Diff, alles
                                // verwerfen, alles bereitstellen
                                // (Daniel-Wunsch 2026-07-30).
                                sectionHeader("ÄNDERUNGEN", count: unstaged.count,
                                              markerID: "gitSectionHeader-unstaged",
                                              actions: [
                                    HeaderAction(icon: "rectangle.split.2x1",
                                                 help: "Gesamt-Diff aller offenen Änderungen anzeigen",
                                                 markerID: "gitHeaderOpenDiff") {
                                        workspace.openGitDiff()
                                    },
                                    HeaderAction(icon: "arrow.uturn.backward",
                                                 help: "Alle Änderungen verwerfen — einzelne oder mehrere Dateien über Rechtsklick bzw. ⇧/⌘-Klick",
                                                 markerID: "gitHeaderDiscardAll") {
                                        workspace.gitDiscard(changes: unstaged)
                                    },
                                    HeaderAction(icon: "plus",
                                                 help: "Alle bereitstellen — einzelne oder mehrere Dateien über Rechtsklick bzw. ⇧/⌘-Klick",
                                                 markerID: "gitHeaderStageAll") {
                                        workspace.gitStageAll()
                                    },
                                ])
                            }
                        }
                    }
                    .padding(.bottom, 8)
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
            pendingSingleOpen: pendingSingleOpen
        )
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
    /// sauberen lokalen Commit wird derselbe Platz zum expliziten Push-Ziel:
    /// Remote-Name im Knopf, effektive Adresse unmittelbar darunter.
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
                .help("Bereitgestellte Änderungen committen (nichts bereitgestellt → alles)")

            case .push(let target):
                primaryButton(title: L10n.format("Push zu %@", target.remote),
                              systemImage: "arrow.up") {
                    workspace.gitPush(to: target)
                }
                .background {
                    SelfTestMarker(id: "gitPrimaryPush-\(target.remote)")
                }
                .help(L10n.format("Lokale Commits ausdrücklich zu %@ übertragen",
                                  target.remote))

                Text(L10n.format("Push-Ziel: %@", target.displayAddress))
                    .fastraFont(size: 9, design: .monospaced)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(target.displayAddress)
                    .background {
                        SelfTestMarker(
                            id: "gitPrimaryPushAddress-\(target.remote)-"
                                + "\(target.displayAddress.hashValue)"
                        )
                    }
                    .accessibilityLabel(L10n.format("Push-Ziel: %@",
                                                    target.displayAddress))
            }
        }
        .padding(10)
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

    /// Abschnitts-Kopf mit Titel, Anzahl-Badge und Sammel-Aktionen rechts.
    /// Er bleibt beim Scrollen oben stehen und braucht deshalb einen deckenden
    /// Hintergrund — sonst schienen die durchlaufenden Dateizeilen hindurch.
    private func sectionHeader(_ title: String, count: Int,
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
            Text("\(count)")
                .fastraFont(size: 9, weight: .semibold, design: .monospaced)
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Theme.surfaceSand))
                // Seit dem dritten Knopf im Kopf ist der Platz knapp: Ohne
                // eigene Idealbreite quetschte SwiftUI zuerst diese Zahl —
                // bei 60 Änderungen war sie nur noch ein Strich.
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            // `enumerated`, weil die Aktionen keine eigene Identität brauchen:
            // die Liste ist klein, konstant und pro Abschnitt fest verdrahtet.
            ForEach(Array(actions.enumerated()), id: \.offset) { _, item in
                Button(action: item.action) {
                    Image(systemName: item.icon)
                        .fastraFont(size: 10, weight: .bold)
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 16, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if let markerID = item.markerID {
                        SelfTestMarker(id: markerID)
                    }
                }
                .help(L10n.string(item.help))
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
}

/// Eine Datei-Zeile in der Änderungen-Ansicht — abhängig vom Abschnitt zeigt sie
/// beim Überfahren die passenden Aktions-Icons und im Kontextmenü dieselben
/// Aktionen (Daniel-Wunsch 2026-07-12). Zeilen sind per Shift-/Cmd-Klick
/// mehrfach markierbar; Aktionen einer markierten Zeile wirken dann auf die
/// ganze Auswahl (Daniel-Wunsch 2026-07-30).
/// Teilt den wartenden Einzelklick-Öffner über ALLE Zeilen beider Abschnitte:
/// Ein neuer Klick storniert den alten Warteposten. Vorher hielt jede Zeile
/// ihren eigenen — zwei schnelle Klicks auf verschiedene Zeilen öffneten dann
/// BEIDE Dateien statt nur der zuletzt geklickten (Review 2026-08-02).
final class PendingSingleOpen {
    private var pending: DispatchWorkItem?
    /// Storniert den alten Warteposten und übernimmt den neuen (oder nil).
    func replace(with work: DispatchWorkItem?) {
        pending?.cancel()
        pending = work
    }
}

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
    /// Wartender Einzelklick-Dateiöffner: Ein Doppelklick storniert ihn,
    /// damit wie bisher NUR der Diff aufgeht und nicht zusätzlich die Datei.
    /// Bewusst der GEMEINSAME Koordinator des Panels statt Zeilen-State.
    let pendingSingleOpen: PendingSingleOpen
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
                    Image(systemName: "doc")
                        .fastraFont(size: 11)
                        .foregroundColor(Theme.textSecondary)
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
                    statusBadge
                }
                .padding(.leading, 14)
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
        .help(change.isPathActionable
              ? L10n.format("Doppelklick: Diff für %@ öffnen", change.path)
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
    /// der Einzelklick markiert sofort und öffnet die Datei erst nach dem
    /// Doppelklick-Fenster, der Doppelklick öffnet stattdessen nur den Diff.
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
        pendingSingleOpen.replace(with: nil)
        if flags == .command {
            onSelectCommand()
            return
        }
        if flags == .shift {
            onSelectShift()
            return
        }
        guard flags.isEmpty else { return }
        if clickCount >= 2 {
            guard change.isPathActionable else { return }
            openDiff()
            return
        }
        // Einzelklick: sofort markieren (setzt auch den Shift-Anker) …
        onSelectPlain()
        guard change.isPathActionable else { return }
        // … und die Datei verzögert öffnen, falls kein zweiter Klick folgt.
        // Das Projekt zum Klickzeitpunkt festhalten: Wechselt es im
        // Wartefenster, gehört der repo-relative Pfad zum ALTEN Projekt und
        // darf im neuen nichts öffnen (Review 2026-08-02).
        let expectedRoot = workspace.projectURL
        let work = DispatchWorkItem {
            guard workspace.projectURL == expectedRoot else { return }
            openFile()
        }
        pendingSingleOpen.replace(with: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval,
                                      execute: work)
    }

    /// Hover-Aktionen: Verwerfen/Bereitstellen (unstaged) bzw. Unstage (staged).
    /// Auf einer markierten Zeile wirken sie auf die gesamte Auswahl.
    @ViewBuilder private var actionButtons: some View {
        switch section {
        case .unstaged:
            iconButton("arrow.uturn.backward", help: "Änderungen verwerfen",
                       markerID: "gitDiscardAction-\(change.rawPath.hashValue)") {
                workspace.gitDiscard(changes: actionTargets())
            }
            iconButton("plus", help: "Änderungen bereitstellen",
                       markerID: "gitStageAction-\(change.rawPath.hashValue)") {
                workspace.gitStage(paths: actionTargets().compactMap(\.actionPath))
            }
        case .staged:
            iconButton("minus", help: "Aus Bereitstellung nehmen") {
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
        Button("Datei öffnen") { openFile() }
            .disabled(!change.isPathActionable)
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
