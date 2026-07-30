import SwiftUI

/// Entscheidet, ob der Willkommensbildschirm den Editor-Bereich ersetzt.
/// Pure Funktion → unit-testbar (Muster: KeyRouting, FooterLogic).
enum WelcomeLogic {
    /// Der Willkommens-Platzhalter liegt genau dann über dem Editor, wenn der
    /// AKTIVE Tab ein unberührter leerer Tab ist (`isPristineScratch`) und
    /// KEIN Projekt geladen ist — Firefox-artig zeigt damit jeder frische Tab
    /// (Start, ⌘T, ⌘N-Fenster) die Starthilfe, und das erste getippte Zeichen
    /// blendet sie aus (Daniel-Entscheidung 2026-07-30; ersetzt den eigenen
    /// Willkommen-Tab vom 2026-07-12). Tabs mit Inhalt, Datei oder
    /// Sonderrolle zeigen den nackten Editor. Mit geladenem Projekt wäre die
    /// Starthilfe („Ordner öffnen…", Zuletzt-Liste) nur noch veralteter Lärm
    /// neben der Seitenleiste — dort bleibt ein leerer Tab einfach leer.
    ///
    /// GAR KEIN Tab (`nil`) zählt ebenfalls als Willkommen: Ein sichtbares
    /// Fenster ohne Tabs ist immer ein kaputter Zwischenzustand — dann lieber
    /// die Starthilfe als eine tippbare Editorfläche, die in kein Dokument
    /// schreibt (Daniel-Befund 2026-07-29, leeres Startfenster).
    static func shouldShow(activeTab: EditorTab?, hasProject: Bool) -> Bool {
        guard let activeTab else { return true }
        return !hasProject && activeTab.isPristineScratch
    }

    /// ⌘N-Sonderfall (Wunschpaket 2026-07, Etappe 1): Zeigt das aktive UND
    /// einzige Dokumentfenster nur einen unberührten leeren Tab ohne Projekt
    /// (= reiner Startzustand), öffnet ⌘N wie ⌘T einen neuen Tab im selben
    /// Fenster — ein zweites, fast identisches Fenster neben dem unbenutzten
    /// Startfenster wäre nur verwirrend. Sobald mehr offen ist (weiterer
    /// Tab, Projekt oder weiteres Fenster), bleibt ⌘N das gewohnte
    /// Fenster-Kommando.
    static func newWindowCommandOpensTab(tabs: [EditorTab],
                                         hasProject: Bool,
                                         visibleDocumentWindows: Int) -> Bool {
        visibleDocumentWindows <= 1 && !hasProject
            && tabs.count == 1 && tabs[0].isPristineScratch
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

/// Willkommens-Platzhalter (Firefox-Neuer-Tab-Muster, aber Apple-dezent):
/// liegt als Overlay ÜBER der Editorfläche, solange der aktive Tab ein
/// unberührter leerer Tab ist. Der Cursor blinkt dahinter in Zeile 1; das
/// erste getippte Zeichen blendet das Overlay aus (die Bedingung lebt in
/// `WelcomeLogic.shouldShow`). Bietet die drei Einstiegs-Aktionen und die
/// Liste der zuletzt benutzten Projekte — ein Klick lädt das Projekt in die
/// Seitenleiste. Bewusst OHNE eigenen Hintergrund: Klicks in freie Flächen
/// erreichen den Editor darunter, nur die eigentlichen Inhalte fangen sie ab.
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
    }

    private func welcomeContent(visibleProjectCount: Int) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24 * uiScale)

            // Wortmarke — bewusst schlicht (kein Icon-Zirkus), Ton wie AboutWindow.
            BrandWordmark(size: 34)
                .foregroundColor(Theme.textPrimary)
            // Die Startseite bleibt sachlich: Unter der Wortmarke stehen nur
            // die gebaute Version und ihr ISO-Datum aus der Info.plist.
            Text(verbatim: welcomeVersionLine)
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .padding(.top, 5)

            // Einstiegs-Aktionen.
            VStack(alignment: .leading, spacing: 10) {
                welcomeAction("Neue Datei", system: "square.and.pencil", shortcut: "⌘T") {
                    // Identisch zum ⌘T-Menübefehl: legt einen neuen leeren
                    // Tab an und springt hinein. Auch er zeigt den
                    // Platzhalter, bis das erste Zeichen getippt ist.
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

    /// Lokalisierte Versionsbezeichnung mit dem unveränderlichen ISO-Datum.
    /// Fehlt das Datum in einem Entwicklungs-Bundle, bleibt die Zeile sauber.
    private var welcomeVersionLine: String {
        let version = L10n.format("Version %@", AppInfo.version)
        return AppInfo.versionDate.isEmpty
            ? version
            : "\(version) · \(AppInfo.versionDate)"
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
