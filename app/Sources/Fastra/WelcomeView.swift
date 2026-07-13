import SwiftUI

/// Entscheidet, ob der Willkommensbildschirm den Editor-Bereich ersetzt.
/// Pure Funktion → unit-testbar (Muster: KeyRouting, FooterLogic).
enum WelcomeLogic {
    /// Der Willkommensbildschirm erscheint genau dann, wenn der AKTIVE Tab der
    /// Willkommen-Tab ist (per-Tab-Flag `isWelcome`). Er ist ein eigener Tab,
    /// der bestehen bleibt: ein zweiter (leerer) Editor-Tab daneben zeigt den
    /// Editor, nicht die Willkommensseite (Daniel-Wunsch 2026-07-12). Beim
    /// Öffnen einer Datei wird der Willkommen-Tab als leerer Scratch abgeräumt,
    /// beim Öffnen eines Projekts in ein normales Dokument umgewandelt.
    static func shouldShow(activeTab: EditorTab?) -> Bool {
        activeTab?.isWelcome == true
    }
}

/// Höhenbudget der Willkommen-Seite. Die Liste zeigt nur vollständige Zeilen;
/// bei großem UI-Zoom darf sie die Wortmarke niemals nach oben hinausschieben.
enum WelcomeLayout {
    private static let fixedContentHeight: CGFloat = 327
    private static let projectRowHeight: CGFloat = 30

    static func visibleRecentProjectCount(availableHeight: CGFloat,
                                          uiScale: CGFloat,
                                          total: Int) -> Int {
        guard total > 0, uiScale > 0 else { return 0 }
        let remaining = availableHeight - fixedContentHeight * uiScale
        guard remaining >= projectRowHeight * uiScale else { return 0 }
        return min(total, max(0, Int(remaining / (projectRowHeight * uiScale))))
    }
}

/// Willkommensbildschirm (VS-Code-Muster, aber Apple-dezent): erscheint statt
/// des Editors, wenn noch nichts geöffnet ist. Bietet die drei Einstiegs-
/// Aktionen und die Liste der zuletzt benutzten Projekte — ein Klick lädt
/// das Projekt in die Seitenleiste.
struct WelcomeView: View {
    @EnvironmentObject var workspace: Workspace
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        GeometryReader { geometry in
            welcomeContent(visibleProjectCount: WelcomeLayout.visibleRecentProjectCount(
                availableHeight: geometry.size.height,
                uiScale: uiScale,
                total: workspace.recentProjects.count
            ))
        }
        .background(Theme.surfaceRaised)
    }

    private func welcomeContent(visibleProjectCount: Int) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24 * uiScale)

            // Wortmarke — bewusst schlicht (kein Icon-Zirkus), Ton wie AboutWindow.
            Text("Fastra")
                .fastraFont(size: 34, weight: .semibold, design: .default)
                .foregroundColor(Theme.textPrimary)
            // Latein-Motto (Umkehrung von „per aspera ad astra") — kursiv,
            // identisch zum AboutWindow. Darunter die sachliche Erklärung,
            // was Fastra ist (ersetzt den früheren werblichen Ein-Zeiler).
            Text("facillime ad astra")
                .fastraFont(.ui)
                .italic()
                .foregroundColor(Theme.textSecondary)
                .padding(.top, 4)
            Text("Texteditor mit besonderen Suchen-&-Ersetzen-Fähigkeiten")
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .padding(.top, 2)

            // Einstiegs-Aktionen.
            VStack(alignment: .leading, spacing: 10) {
                welcomeAction("Neue Datei", system: "square.and.pencil", shortcut: "⌘T") {
                    // Identisch zum ⌘T-Menübefehl: legt DANEBEN einen neuen
                    // Editor-Tab an und springt hinein — der Willkommen-Tab
                    // bleibt als eigener Tab „Willkommen" erhalten.
                    workspace.openNewTab()
                }
                welcomeAction("Datei öffnen…", system: "doc", shortcut: "⌘O") {
                    workspace.openFile()
                }
                welcomeAction("Ordner öffnen…", system: "folder", shortcut: "⇧⌘O") {
                    workspace.openFolderAsProject()
                }
            }
            .padding(.top, 28)

            // Zuletzt benutzte Projekte.
            if workspace.recentProjects.isEmpty || visibleProjectCount > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ZULETZT BENUTZTE PROJEKTE")
                        .fastraFont(size: 10, weight: .semibold)
                        .tracking(0.6)
                        .foregroundColor(Theme.textSecondary)
                        .padding(.bottom, 6)

                    if workspace.recentProjects.isEmpty {
                        // Dezente Erklärung statt leerer Fläche — sagt zugleich,
                        // WIE Projekte in die Liste kommen (automatisch).
                        Text("Projekte merkt sich Fastra von selbst: Öffne eine Datei aus einem Git-Repository oder einen Ordner.")
                            .fastraFont(.small)
                            .foregroundColor(Theme.textSecondary)
                            .frame(maxWidth: 320, alignment: .leading)
                    } else {
                        ForEach(Array(workspace.recentProjects.prefix(visibleProjectCount))) { entry in
                            ProjectRow(entry: entry) {
                                workspace.openProject(at: entry.url)
                            }
                        }
                    }
                }
                .padding(.top, 32)
                .frame(maxWidth: 380, alignment: .leading)
            }

            Spacer(minLength: 24 * uiScale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Eine Einstiegs-Aktion: Icon + Titel + dezenter Shortcut-Hinweis.
    private func welcomeAction(_ title: String,
                               system: String,
                               shortcut: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: system)
                    .foregroundColor(Theme.accentReadable)
                    .fastraFont(size: 13)
                    .frame(width: 18)
                Text(verbatim: L10n.string(title))
                    .fastraFont(.ui)
                    .foregroundColor(Theme.textPrimary)
                Text(shortcut)
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Eine Zeile der Projekt-Liste: Ordner-Icon, Name, gedimmter Pfad.
private struct ProjectRow: View {
    let entry: ProjectEntry
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundColor(Theme.accentReadable)
                    .fastraFont(size: 12)
                    .frame(width: 18)
                Text(entry.name)
                    .fastraFont(.ui)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(entry.path)
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30 * uiScale)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? Theme.surfaceSand.opacity(0.6) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
