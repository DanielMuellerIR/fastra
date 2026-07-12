import SwiftUI

struct TabBarView: View {
    @EnvironmentObject var workspace: Workspace
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(workspace.tabs) { tab in
                        TabPill(tab: tab,
                                // Der Willkommen-Tab heißt in der Leiste
                                // „Willkommen" (per-Tab, nicht global): steht ein
                                // zweiter Editor-Tab daneben, behält NUR der
                                // Willkommen-Tab diese Beschriftung.
                                displayTitle: tab.isWelcome ? "Willkommen" : tab.title,
                                isActive: tab.id == workspace.activeTabID,
                                canCloseOthers: workspace.tabs.count > 1) {
                            // Klick wechselt nur den aktiven Tab. Ist es der
                            // Willkommen-Tab, bleibt die Willkommensseite; jeder
                            // andere Tab zeigt den Editor.
                            workspace.activeTabID = tab.id
                        } onClose: {
                            // Zentrale Schließen-Logik inkl. BBEdit-Rückfrage bei
                            // ungespeicherten Änderungen (statt direktem Entfernen).
                            workspace.closeTab(id: tab.id)
                        } onCloseOthers: {
                            workspace.closeOtherTabs(keeping: tab.id)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }

            Button(action: workspace.openNewTab) {
                Image(systemName: "plus")
                    .fastraFont(size: 12, weight: .medium)
                    .frame(width: 28 * uiScale, height: 28 * uiScale)
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Neuer Tab (⌘T)")
            .padding(.horizontal, 6)
        }
        .background(Theme.surfaceSand.opacity(0.7))
        // Kein macOS-Fokusrahmen auf der Tab-Leiste: die Tabs/Buttons sind
        // anklickbare Controls, sollen aber keinen blauen Fokus-Ring zeigen,
        // wenn sie den Tastatur-Fokus bekommen (z.B. der Start-Tab des leeren
        // Dokuments). Gilt für den gesamten Leisten-Teilbaum.
        .focusEffectDisabled()
    }
}

private struct TabPill: View {
    let tab: EditorTab
    /// Anzuzeigende Beschriftung. Normalerweise `tab.title`; im Willkommen-
    /// Zustand vom Aufrufer auf „Willkommen" gesetzt.
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
            HStack(spacing: 8) {
                // Ladeanimation statt Datei-Icon während isLoading = true.
                // Sobald isLoading auf false kippt, erscheint das normale Icon.
                if tab.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 11 * uiScale, height: 11 * uiScale)
                } else {
                    Image(systemName: "doc.text")
                        .fastraFont(size: 11)
                        .foregroundColor(Theme.textSecondary)
                }
                Text(displayTitle)
                    .fastraFont(.small)
                    .lineLimit(1)
                    .foregroundColor(isActive ? Theme.textPrimary : Theme.textSecondary)
                // Treffer-Badge nur anzeigen, wenn die Datei vollständig geladen ist
                // — während isLoading sind die Treffer noch nicht berechnet.
                if !tab.isLoading, tab.hits > 0 {
                    Text("\(tab.hits)")
                        .fastraFont(size: 10, weight: .semibold, design: .monospaced)
                        .foregroundColor(isActive ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.surfaceSand))
                }
                Button(action: onClose) {
                    // Ungespeichert (K8): gefüllter Punkt statt X, solange der
                    // Tab nicht überfahren wird (BBEdit-Stil). Beim Hover wird
                    // daraus das Schließen-X. Gespeicherte Tabs zeigen immer X.
                    Image(systemName: (tab.isDirty && !hovering) ? "circle.fill" : "xmark")
                        .fastraFont(size: (tab.isDirty && !hovering) ? 7 : 8, weight: .bold)
                        .frame(width: 14 * uiScale, height: 14 * uiScale)
                        .foregroundColor(hovering ? Theme.textPrimary
                                         : (tab.isDirty ? Theme.accentReadable
                                            : Theme.textSecondary.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .help(tab.isDirty ? "Ungespeicherte Änderungen — klicken zum Schließen" : "Tab schließen")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7 * uiScale)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Theme.surfaceRaised : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isActive ? Theme.stroke : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // Rechtsklick: „Andere Tabs schließen" (K8). Nur aktiv, wenn es
        // überhaupt andere Tabs gibt.
        .contextMenu {
            Button("Andere Tabs schließen", action: onCloseOthers)
                .disabled(!canCloseOthers)
        }
    }
}
