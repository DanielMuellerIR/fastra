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

    @AppStorage("editor.sidebarVisible") private var showSidebar = true
    @AppStorage("editor.sidebarWidth") private var sidebarWidth = 200.0
    @AppStorage("markdown.integratedPreview") private var showPreview = true

    private let sidebarMinWidth = 180.0
    private let sidebarMaxWidth = 480.0
    private let dividerWidth: CGFloat = 11

    private var effectiveSidebarWidth: CGFloat {
        CGFloat(min(max(sidebarWidth, sidebarMinWidth), sidebarMaxWidth))
    }

    var body: some View {
        titlebarControls
            .frame(height: 36 * uiScale)
            // Header-Hintergründe dienen zugleich als greifbare Fläche zum
            // Verschieben des Fensters (`isMovableByWindowBackground`).
            .background(Theme.surfaceRaised)
            .focusEffectDisabled()
    }

    private var titlebarControls: some View {
        HStack(spacing: 0) {
            titlebarLeadingControls

            if showSidebar {
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
    /// frei. Der Schalter sitzt am rechten Rand dieses Bereichs wie in Codex.
    /// Ohne Seitenleiste bleibt ein kompakter Vorlauf, damit Tabs nie unter
    /// den Ampeln liegen und der Einblende-Schalter weiterhin erreichbar ist.
    private var titlebarLeadingControls: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 120)
            Button { showSidebar.toggle() } label: {
                titlebarIcon("sidebar.left", active: !showSidebar)
            }
            .buttonStyle(.plain)
            .help(showSidebar ? "Seitenleiste ausblenden" : "Seitenleiste einblenden")
            .padding(.trailing, 8)
        }
        .frame(width: showSidebar ? effectiveSidebarWidth : 180)
        .frame(maxHeight: .infinity)
        .background(showSidebar ? Theme.surfaceBase : Theme.surfaceRaised)
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
        guard let title = workspace.activeTab?.title.lowercased() else { return false }
        return title.hasSuffix(".md") || title.hasSuffix(".markdown")
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
            Text("Fastra")
                .fastraFont(size: 19, weight: .semibold)
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(workspace.tabs) { tab in
                        TabPill(
                            tab: tab,
                            displayTitle: tab.isWelcome ? L10n.string("Willkommen") : tab.title,
                            isActive: tab.id == workspace.activeTabID,
                            canCloseOthers: workspace.tabs.count > 1,
                            onSelect: { workspace.activeTabID = tab.id },
                            onClose: { workspace.closeTab(id: tab.id) },
                            onCloseOthers: { workspace.closeOtherTabs(keeping: tab.id) }
                        )
                    }
                }
                .padding(.horizontal, 10)
            }

            Button(action: workspace.openNewTab) {
                Image(systemName: "plus")
                    .fastraFont(size: 12, weight: .medium)
                    .frame(width: 28 * uiScale, height: 28 * uiScale)
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Neuer Tab (⌘T)")
            .padding(.trailing, 8)
        }
    }

    /// Elf Punkte breit wie der echte Splitter unterhalb des Headers. Nur die
    /// mittige Ein-Punkt-Linie ist sichtbar; dadurch fluchten beide Bereiche.
    private var chromeDivider: some View {
        ZStack {
            Theme.surfaceRaised
            Rectangle().fill(Theme.strokeStrong).frame(width: 1)
        }
        .frame(width: dividerWidth)
    }
}

private struct TabPill: View {
    let tab: EditorTab
    let displayTitle: String
    let isActive: Bool
    let canCloseOthers: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void

    @State private var hovering = false
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
                if tab.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 11 * uiScale, height: 11 * uiScale)
                } else {
                    Image(systemName: tab.isWelcome ? "sparkles" : "doc.text")
                        .fastraFont(size: 11)
                        .foregroundColor(Theme.textSecondary)
                }

                Text(displayTitle)
                    .fastraFont(.small)
                    .lineLimit(1)
                    .foregroundColor(isActive ? Theme.textPrimary : Theme.textSecondary)

                if !tab.isLoading, tab.hits > 0 {
                    Text("\(tab.hits)")
                        .fastraFont(size: 10, weight: .semibold, design: .monospaced)
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.surfaceRaised))
                }

                Button(action: onClose) {
                    Image(systemName: (tab.isDirty && !hovering) ? "circle.fill" : "xmark")
                        .fastraFont(size: (tab.isDirty && !hovering) ? 7 : 8, weight: .bold)
                        .frame(width: 14 * uiScale, height: 14 * uiScale)
                        .foregroundColor(hovering ? Theme.textPrimary
                                         : (tab.isDirty ? Theme.accentReadable
                                            : Theme.textSecondary.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .help(tab.isDirty
                      ? "Ungespeicherte Änderungen — klicken zum Schließen"
                      : "Tab schließen")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7 * uiScale)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isActive ? Theme.surfaceSand : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(isActive ? Theme.strokeStrong : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Andere Tabs schließen", action: onCloseOthers)
                .disabled(!canCloseOthers)
        }
    }
}
