import SwiftUI

/// Einzeiliger Fenster-Chrome nach dem Muster der Codex-Desktop-App.
///
/// Die obere Zeile liegt im vollflächigen Inhaltsbereich an Stelle einer
/// sichtbaren macOS-Titelleiste: Ampelknöpfe und Bereichsschalter bleiben
/// nativ, die Tabs sitzen daneben als kompakte, abgerundete Controls. Der
/// Markenblock gehört zur Seitenleiste unterhalb dieser Zeile.
struct TabBarView: View {
    @EnvironmentObject var workspace: Workspace
    @Environment(\.uiScale) private var uiScale

    @AppStorage("editor.sidebarVisible", store: SelfTest.workspaceDefaults()) private var showSidebar = true
    @AppStorage("markdown.integratedPreview", store: SelfTest.workspaceDefaults()) private var showPreview = true

    private let sidebarMinWidth = SidebarLayout.minimumSidebarWidth
    private let sidebarMaxWidth = SidebarLayout.maximumSidebarWidth
    private let dividerWidth: CGFloat = 11

    @State private var contentWidth: CGFloat = 0

    /// Dieselbe Regel wie in `EditorView`: Ohne Projekt keine Seitenleiste,
    /// also auch kein Vorlauf in Seitenleistenbreite und kein Umschalter.
    private var hasProject: Bool { workspace.projectURL != nil }
    private var sidebarVisible: Bool {
        SidebarVisibility.isVisible(userWantsSidebar: showSidebar, hasProject: hasProject)
    }

    // Die Seitenleisten-Breite liegt pro Fenster auf dem `workspace`, damit der
    // Titelleisten-Vorlauf exakt mit der Seitenleiste darunter fluchtet und der
    // Splitter nur dieses Fenster verändert (Daniel-Befund 2026-07-20).
    private var effectiveSidebarWidth: CGFloat {
        let maximum = contentWidth > 0
            ? SplitterSizing.leadingMaximum(
                total: Double(contentWidth), splitter: Double(dividerWidth),
                minimumLeading: sidebarMinWidth, minimumTrailing: 240,
                absoluteMaximum: sidebarMaxWidth
            )
            : sidebarMaxWidth
        return CGFloat(min(max(workspace.sidebarWidth, sidebarMinWidth), maximum))
    }

    var body: some View {
        titlebarControls
            .frame(height: 36 * uiScale)
            // Header-Hintergründe dienen zugleich als greifbare Fläche zum
            // Verschieben des Fensters (`isMovableByWindowBackground`).
            .background(Theme.surfaceRaised)
            .focusEffectDisabled()
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { contentWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in
                            contentWidth = width
                        }
                }
            )
    }

    private var titlebarControls: some View {
        HStack(spacing: 0) {
            titlebarLeadingControls

            if sidebarVisible {
                chromeDivider
            }

            tabs
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            previewToggle
                .padding(.trailing, 8)
        }
        .background(Theme.surfaceRaised)
    }

    /// Links bleiben die ersten rund 120 Punkte für die echten Ampelknöpfe
    /// frei. Home und Seitenschalter sitzen rechts in diesem Bereich wie in
    /// Codex.
    /// Ohne Seitenleiste bleibt ein kompakter Vorlauf, damit Tabs nie unter
    /// den Ampeln liegen und der Einblende-Schalter weiterhin erreichbar ist.
    private var titlebarLeadingControls: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 120)
            Button { workspace.returnToWelcome() } label: {
                titlebarIcon("house", active: workspace.isWelcomeScreen)
            }
            .buttonStyle(.plain)
            .disabled(workspace.folderApplying)
            .help("Zum Willkommensbildschirm")
            .accessibilityLabel("Zum Willkommensbildschirm")
            .accessibilityHint("Schließt den aktuellen Arbeitsbereich sicher und zeigt Willkommen.")
            if SidebarVisibility.offersToggle(hasProject: hasProject) {
                Button { showSidebar.toggle() } label: {
                    titlebarIcon("sidebar.left", active: !showSidebar)
                }
                .buttonStyle(.plain)
                .help(showSidebar ? "Seitenleiste ausblenden" : "Seitenleiste einblenden")
                .padding(.trailing, 8)
            } else {
                Spacer(minLength: 8)
            }
        }
        .frame(width: sidebarVisible ? effectiveSidebarWidth : 180)
        .frame(maxHeight: .infinity)
        .background(sidebarVisible ? Theme.surfaceBase : Theme.surfaceRaised)
    }

    /// Rechter Schalter für die integrierte Markdown-Vorschau. Bei normalen
    /// Textdateien bleibt er an Ort und Stelle, ist aber deaktiviert.
    private var previewToggle: some View {
        Button {
            guard activeTabIsMarkdown else { return }
            showPreview.toggle()
        } label: {
            titlebarIcon("sidebar.right", active: activeTabIsMarkdown && showPreview)
                .foregroundColor(activeTabIsMarkdown && showPreview
                                 ? Theme.accentReadable : Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(!activeTabIsMarkdown)
        .help(showPreview
              ? "Markdown-Vorschau ausblenden"
              : "Markdown-Vorschau einblenden")
    }

    private var activeTabIsMarkdown: Bool {
        workspace.activeTabIsMarkdown
    }

    private func titlebarIcon(_ systemName: String, active: Bool) -> some View {
        Image(systemName: systemName)
            .fastraFont(size: 12, weight: .medium)
            .frame(width: 26, height: 22)
            .foregroundColor(Theme.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Theme.surfaceSand : Color.clear)
            )
    }

}

/// Markenblock am Kopf der sichtbaren Seitenleiste. Liegt absichtlich in
/// `EditorView`, damit rechts daneben kein leerer zweiter Header entsteht.
struct SidebarBrandView: View {
    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            BrandWordmark(size: 19)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                // Der Markenname ist die unveränderliche Identität und darf
                // deshalb niemals zugunsten der Metadaten gekürzt werden.
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)

            ViewThatFits(in: .horizontal) {
                // Das Datum erscheint nur, wenn es vollständig hineinpasst.
                // `fixedSize` macht diese Variante unteilbar; bei Platzmangel
                // wählt ViewThatFits automatisch die reine Versionszeile.
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "v\(AppInfo.version)")
                    Text(verbatim: AppInfo.versionDate)
                }
                .fixedSize(horizontal: true, vertical: false)

                Text(verbatim: "v\(AppInfo.version)")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .fastraFont(size: 9.5, weight: .medium)
            .foregroundColor(Theme.textSecondary)
            .layoutPriority(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.surfaceBase)
    }
}

private extension TabBarView {
    private var tabs: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(workspace.tabs) { tab in
                            TabPill(
                                tab: tab,
                                displayTitle: tab.title,
                                isActive: tab.id == workspace.activeTabID,
                                isComparisonSelected: tab.id == workspace.comparisonTabID,
                                canCloseOthers: workspace.tabs.count > 1,
                                canCompareSelection: workspace.selectedComparisonTabIDs?
                                    .contains(tab.id) == true,
                                onSelect: { workspace.selectTab(id: tab.id) },
                                onExtendSelection: {
                                    workspace.selectTab(
                                        id: tab.id,
                                        extendingComparison: true
                                    )
                                },
                                onCompareSelection: {
                                    _ = workspace.presentComparisonForSelectedTabs(
                                        contextTabID: tab.id
                                    )
                                },
                                onClose: { workspace.closeTab(id: tab.id) },
                                onCloseOthers: { workspace.closeOtherTabs(keeping: tab.id) }
                            )
                            .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .onAppear { revealActiveTab(using: proxy) }
                .onChange(of: workspace.activeTabID) { _, _ in
                    revealActiveTab(using: proxy)
                }
                .onChange(of: workspace.tabs.map(\.id)) { _, _ in
                    revealActiveTab(using: proxy)
                }
                // Der flüchtige Vorschau-Tab behält absichtlich seine ID,
                // wenn der nächste Dateiklick ihn ersetzt. Sein Name und
                // damit seine Breite ändern sich trotzdem; auch dann muss der
                // vollständige aktive Tab in den sichtbaren Bereich rücken.
                .onChange(of: workspace.tabs.map(\.title)) { _, _ in
                    revealActiveTab(using: proxy)
                }
            }

            Button(action: workspace.openNewTab) {
                Image(systemName: "plus")
                    .fastraFont(size: 12, weight: .medium)
                    .frame(width: 28 * uiScale, height: 28 * uiScale)
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Neuer Tab (⌘T)")

            tabCountMenu
                .padding(.trailing, 8)
        }
    }

    /// Tab-Übersicht neben der Leiste (Daniel-Wunsch 2026-09-01): Die Kapsel
    /// zeigt die Anzahl der offenen Tabs DIESES Fensters; ein Klick öffnet
    /// ein Menü mit allen Tabs zum direkten Springen. Nützlich, sobald die
    /// scrollende Leiste nicht mehr alle Tabs gleichzeitig zeigt.
    private var tabCountMenu: some View {
        Menu {
            ForEach(workspace.tabs) { tab in
                Button {
                    workspace.selectTab(id: tab.id)
                } label: {
                    // Gleiche Beschriftung wie die Tab-Untermenüs im
                    // Fenster-Menü: Häkchen am aktiven Tab, Dirty-Punkt an
                    // ungesicherten.
                    if tab.id == workspace.activeTabID {
                        Label(WindowTabsMenuModel.rowTitle(
                            title: tab.title,
                            hasUnsavedChanges: tab.hasUnsavedChanges
                        ), systemImage: "checkmark")
                    } else {
                        Text(WindowTabsMenuModel.rowTitle(
                            title: tab.title,
                            hasUnsavedChanges: tab.hasUnsavedChanges
                        ))
                    }
                }
            }
        } label: {
            Text("\(workspace.tabs.count)")
                .fastraFont(size: 10, weight: .semibold, design: .monospaced)
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.surfaceSand))
                // Idealbreite halten, damit dreistellige Zahlen nicht zu
                // einem Strich gequetscht werden (gleiche Falle wie bei der
                // Änderungen-Badge der Seitenleiste).
                .fixedSize(horizontal: true, vertical: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tabCountDescription)
        .accessibilityLabel(tabCountDescription)
        .accessibilityHint("Öffnet ein Menü mit allen Tabs dieses Fensters zum direkten Wechseln.")
        // Macht die angezeigte Zahl für Fenster-Selbsttests beobachtbar
        // (tabflood prüft nach dem Fluten den Stand „41").
        .background {
            SelfTestMarker(id: "tabCountButton-\(workspace.tabs.count)")
                .frame(width: 0, height: 0)
        }
    }

    /// Lesbare Beschreibung für Tooltip und VoiceOver, mit korrektem
    /// Singular („1 offener Tab").
    private var tabCountDescription: String {
        workspace.tabs.count == 1
            ? L10n.string("1 offener Tab — zum Tab springen")
            : L10n.format("%ld offene Tabs — zum Tab springen", workspace.tabs.count)
    }

    /// Nur ein echter Dokumentwechsel beziehungsweise eine geänderte
    /// Tab-Menge greift in die horizontale Position ein. Freies manuelles
    /// Scrollen bleibt dazwischen unangetastet.
    private func revealActiveTab(using proxy: ScrollViewProxy) {
        guard let activeTabID = workspace.activeTabID else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(activeTabID, anchor: .center)
        }
    }

    /// Elf Punkte breit wie der echte Splitter unterhalb des Headers. Nur die
    /// mittige Ein-Punkt-Linie ist sichtbar; dadurch fluchten beide Bereiche.
    private var chromeDivider: some View {
        HStack(spacing: 0) {
            Theme.surfaceBase.frame(width: 5)
            Rectangle().fill(Theme.strokeStrong).frame(width: 1)
            Theme.surfaceRaised.frame(width: 5)
        }
        .frame(width: dividerWidth)
    }
}

private struct TabPill: View {
    let tab: EditorTab
    let displayTitle: String
    let isActive: Bool
    let isComparisonSelected: Bool
    let canCloseOthers: Bool
    let canCompareSelection: Bool
    let onSelect: () -> Void
    let onExtendSelection: () -> Void
    let onCompareSelection: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void

    @State private var tabHovering = false
    @State private var closeHovering = false
    @Environment(\.uiScale) private var uiScale
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onSelect) {
                HStack(spacing: 7) {
                    if tab.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 11 * uiScale, height: 11 * uiScale)
                    } else {
                        Image(systemName: tab.readOnlyReason == nil ? "doc.text" : "lock.fill")
                            .fastraFont(size: 11)
                            .foregroundColor(tab.readOnlyReason == nil
                                             ? Theme.textSecondary : Theme.diffRemovedFG)
                    }

                    Text(displayTitle)
                        .fastraFont(.small)
                        .italic(tab.isPreview)
                        .lineLimit(1)
                        // Die Tab-Leiste scrollt horizontal. Der Dateiname darf
                        // deshalb seine echte Breite beanspruchen und wird nie
                        // zugunsten weiterer Tabs verstümmelt.
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundColor(
                            tab.readOnlyReason != nil ? Theme.diffRemovedFG
                            : isActive || isComparisonSelected
                                ? Theme.textPrimary : Theme.textSecondary
                        )
                        .help(displayTitle)

                    if !tab.isLoading, tab.hits > 0 {
                        Text("\(tab.hits)")
                            .fastraFont(size: 10, weight: .semibold, design: .monospaced)
                            .foregroundColor(Theme.textSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.surfaceRaised))
                    }

                    // Der Auswahl-Button reserviert nur die Breite der
                    // Schließen-Fläche. Der echte Schließen-Button liegt als
                    // Geschwister darüber, damit SwiftUI keine verschachtelten
                    // Button-Hitbereiche gegeneinander auflösen muss.
                    Color.clear
                        .frame(width: closeHitSide, height: 14 * uiScale)
                }
                .padding(.leading, 12)
                .padding(.trailing, 7)
                .padding(.vertical, 7 * uiScale)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(tabBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(tabStroke, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(
                "documentTab-\(selectionMarker)-\(tab.id.uuidString)"
            )
            .accessibilityValue(accessibilitySelectionValue)
            // NSView-Anker für echte Fenster-Selbsttests. Anders als der
            // SwiftUI-Accessibility-Identifier ist dieser Marker im AppKit-
            // Viewbaum positionsstabil und liegt mittig im Auswahl-Button.
            .background(
                SelfTestMarker(
                    id: "documentTab-\(selectionMarker)-\(tab.id.uuidString)"
                ).frame(width: 0, height: 0)
            )

            Button(action: onClose) {
                Image(systemName: closeSymbolName)
                    .fastraFont(
                        size: showsDirtyIndicator ? 7 : 8,
                        weight: .bold
                    )
                    .frame(width: 14 * uiScale, height: 14 * uiScale)
                    // Das Symbol bleibt klein; nur die unsichtbare Mausfläche
                    // wächst. 22 pt bleiben auch bei minimalem UI-Zoom erhalten.
                    .frame(width: closeHitSide, height: closeHitSide)
                    .contentShape(Rectangle())
                    .foregroundColor(closeForegroundColor)
            }
            .buttonStyle(.plain)
            .disabled(tab.hexEditSession.isSaving)
            .background(
                SelfTestMarker(id: "tabClose-\(tab.id.uuidString)")
            )
            .help(tab.hexEditSession.isSaving
                  ? "Der Tab bleibt bis zum Ende des Speicherns geöffnet."
                  : tab.hasUnsavedChanges
                      ? "Ungespeicherte Änderungen — klicken zum Schließen"
                      : "Tab schließen")
            .padding(.trailing, 7)
            .onHover { closeHovering = $0 }
        }
        // Shift-Klick markiert genau einen zweiten Dokument-Tab. Der normale
        // Button-Klick wird durch die höher priorisierte Geste nicht zusätzlich
        // ausgelöst; der aktive Editor bleibt deshalb eindeutig erhalten.
        .highPriorityGesture(
            TapGesture().modifiers(.shift).onEnded(onExtendSelection)
        )
        // Cmd-Klick zeigt das Pfadmenü der Tab-Datei (Etappe 1 Wunschpaket
        // 2026-07b). `highPriorityGesture`, damit der Cmd-Klick NICHT
        // zusätzlich als normaler Tab-Klick durchschlägt. Ungespeicherte
        // Tabs haben keinen Pfad → dort wählt der Cmd-Klick nur den Tab.
        .highPriorityGesture(
            TapGesture().modifiers(.command).onEnded {
                if let url = tab.url {
                    TabPathMenuPresenter.shared.present(for: url)
                } else {
                    onSelect()
                }
            }
        )
        .onHover { tabHovering = $0 }
        // Vollflächiger Geometrieanker für `tabvisibility`: Der ältere
        // Nullpunkt-Marker im Button bleibt für Klickrollen erhalten.
        .background(SelfTestMarker(id: "documentTabFrame-\(tab.id.uuidString)"))
        .contextMenu {
            if canCompareSelection {
                Button("Dateien vergleichen…", action: onCompareSelection)
                Divider()
            }

            if let url = tab.url {
                FileTreeContextMenu(
                    directory: url.deletingLastPathComponent(),
                    node: FileTreeNode(url: url, isDirectory: false),
                    onMutation: { workspace.refreshGitStatus() }
                )
            } else {
                unavailableFileActions
            }

            Divider()
            Button("Speichern") { workspace.saveTab(id: tab.id) }
                .disabled(!canSave)
            Button("Diesen Tab schließen", action: onClose)
            Button("Andere Tabs schließen", action: onCloseOthers)
                .disabled(!canCloseOthers)
        }
    }

    private var closeHitSide: CGFloat {
        max(22, 24 * uiScale)
    }

    private var showsDirtyIndicator: Bool {
        tab.hasUnsavedChanges && !tabHovering && !closeHovering
    }

    private var closeSymbolName: String {
        showsDirtyIndicator ? "circle.fill" : "xmark"
    }

    private var closeForegroundColor: Color {
        if tabHovering || closeHovering { return Theme.textPrimary }
        if tab.hasUnsavedChanges { return Theme.accentReadable }
        return Theme.textSecondary.opacity(0.55)
    }

    private var tabBackground: Color {
        if isActive { return Theme.surfaceSand }
        if isComparisonSelected { return Theme.surfaceBase }
        if tabHovering { return Theme.surfaceBase }
        return Theme.surfaceRaised.opacity(0.82)
    }

    private var tabStroke: Color {
        if isActive { return Theme.strokeStrong }
        if isComparisonSelected { return Theme.stroke }
        return Theme.stroke.opacity(0.72)
    }

    private var selectionMarker: String {
        if isActive { return "current" }
        if isComparisonSelected { return "comparison" }
        return "idle"
    }

    private var accessibilitySelectionValue: String {
        if isActive { return L10n.string("Aktueller Tab") }
        if isComparisonSelected {
            return L10n.string("Für Dateivergleich ausgewählt")
        }
        return ""
    }

    private var canSave: Bool {
        tab.gitKind == nil && tab.fileDiffRequest == nil
            && tab.readOnlyReason == nil
            && (tab.displayMode == .text || tab.hexEditSession.hasChanges)
            && !tab.isLoading && !tab.hexEditSession.isSaving
            && !workspace.fileMutationIsInFlight(for: tab.url)
    }

    /// Ein ungesicherter Tab besitzt weder Datei noch Elternordner. Die
    /// Dateimenü-Struktur bleibt sichtbar, erklärt ihre Grenze aber über
    /// deaktivierte Einträge statt die Befehle überraschend verschwinden zu
    /// lassen.
    @ViewBuilder private var unavailableFileActions: some View {
        Group {
            Button("Neue Datei…") { }.disabled(true)
            Button("Neuer Ordner…") { }.disabled(true)
            Divider()
            Button("Im Finder zeigen…") { }.disabled(true)
            Button("Terminal hier öffnen …") { }.disabled(true)
            Divider()
            Button("Duplizieren") { }.disabled(true)
            Button("Umbenennen…") { }.disabled(true)
            Button("In den Papierkorb legen…", role: .destructive) { }.disabled(true)
        }
    }
}
