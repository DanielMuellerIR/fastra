// SidebarProjectHeader.swift
//
// Gemeinsamer Kopf der Projekt-Seitenleiste (Etappe 1 Wunschpaket 2026-07b).
// Vorher existierte der Kopf (Ordnername + Schließen-X) nur im Dateien-Tab;
// jetzt zeigen ihn alle drei Tabs (Dateien/Änderungen/Graph) über diese eine
// Komponente. Neu für alle Tabs:
// - Tooltip mit dem vollen Pfad auf dem Namen.
// - Rechtsklickmenü mit „Im Finder zeigen…“ und „Projektansicht schließen“
//   (der Dateien-Tab hängt sein bestehendes Vollmenü zusätzlich an).
// - Cmd-Klick auf den Namen öffnet ein Menü mit allen GESCHWISTER-Ordnern
//   im selben Elternordner — Auswahl wechselt das Projekt wie „Ordner öffnen“.

import SwiftUI
import AppKit

/// Unsichtbare AppKit-Markierung für Fenster-Selbsttests. SwiftUI erzeugt
/// die NSView nur, wenn der umgebende View wirklich im Layout hängt — die
/// Selbsttests finden sie deterministisch im NSView-Baum (der SwiftUI-
/// Accessibility-Baum wird dagegen erst lazy für echte AX-Clients gebaut
/// und ist programmatisch nicht zuverlässig sichtbar).
struct SelfTestMarker: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityIdentifier(id)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.setAccessibilityIdentifier(id)
    }
}

/// Reine, unit-testbare Logik für das Geschwisterordner-Menü: Welche Ordner
/// liegen neben dem Projektordner? Nur echte Ordner, versteckte ausgeblendet,
/// alphabetisch sortiert (Finder-artige `localizedStandardCompare`-Ordnung).
/// Der aktuelle Ordner selbst bleibt in der Liste (Häkchen im Menü).
enum SiblingFolderListing {
    static func siblings(of folder: URL,
                         fileManager: FileManager = .default) throws -> [URL] {
        let parent = folder.deletingLastPathComponent()
        let entries = try fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return entries
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
    }
}

/// Präsentiert das Geschwisterordner-Menü als natives `NSMenu` an der
/// Mausposition. Ein Singleton als Target, weil `NSMenuItem` seine Aktion
/// erst nach Ende des Menü-Trackings zustellt — ein kurzlebiges Objekt wäre
/// bis dahin womöglich schon wieder freigegeben.
@MainActor
final class SiblingFolderMenuPresenter: NSObject {
    static let shared = SiblingFolderMenuPresenter()
    private weak var workspace: Workspace?

    /// Startet das asynchrone Ordner-Listing (nie auf dem Main-Thread) und
    /// zeigt danach das Menü. Die Mausposition wird beim Klick festgehalten,
    /// damit das Menü dort erscheint, wo geklickt wurde.
    func present(for projectURL: URL, workspace: Workspace) {
        self.workspace = workspace
        let location = NSEvent.mouseLocation
        Task.detached(priority: .userInitiated) {
            let result: Result<[URL], Error>
            do {
                result = .success(try SiblingFolderListing.siblings(of: projectURL))
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                SiblingFolderMenuPresenter.shared.show(result, current: projectURL,
                                                       at: location)
            }
        }
    }

    private func show(_ result: Result<[URL], Error>, current: URL, at location: NSPoint) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch result {
        case .failure(let error):
            // Nicht lesbarer Elternordner → verständliche Meldung statt
            // eines leeren Menüs (Leitplanke: keine stillen Fehlschläge).
            let message = L10n.format(
                "Ordner „%@“ lässt sich nicht lesen: %@",
                current.deletingLastPathComponent().lastPathComponent,
                error.localizedDescription
            )
            let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        case .success(let folders):
            for folder in folders {
                let item = NSMenuItem(title: folder.lastPathComponent,
                                      action: #selector(openSibling(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = folder
                let isCurrent = folder.path == current.path
                item.state = isCurrent ? .on : .off
                item.isEnabled = !isCurrent
                let icon = NSWorkspace.shared.icon(forFile: folder.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                menu.addItem(item)
            }
        }
        // `view: nil` → der Punkt gilt in Bildschirmkoordinaten.
        menu.popUp(positioning: nil, at: location, in: nil)
    }

    @objc private func openSibling(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        // Gleiches Verhalten wie „Ordner öffnen“: ausdrücklicher
        // Projektwechsel, fremde saubere Tabs werden aufgeräumt.
        workspace?.openProject(at: url)
    }
}

/// Kopfzeile der Projekt-Seitenleiste: Ordnername + Schließen-X.
/// `extraMenu` erlaubt dem Dateien-Tab, sein Vollmenü (Neue Datei/Ordner,
/// Terminal) unter die gemeinsamen Punkte zu hängen.
struct SidebarProjectHeader<ExtraMenu: View>: View {
    let rootURL: URL
    @ViewBuilder var extraMenu: () -> ExtraMenu
    @EnvironmentObject var workspace: Workspace

    /// Bequemer Aufruf ohne Zusatzmenü (Änderungen-/Graph-Tab).
    init(rootURL: URL) where ExtraMenu == EmptyView {
        self.init(rootURL: rootURL, extraMenu: { EmptyView() })
    }

    init(rootURL: URL, @ViewBuilder extraMenu: @escaping () -> ExtraMenu) {
        self.rootURL = rootURL
        self.extraMenu = extraMenu
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(rootURL.lastPathComponent.uppercased())
                .fastraFont(size: 10, weight: .semibold)
                .tracking(0.6)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                // Voller Pfad als Tooltip — der Name allein ist oft mehrdeutig.
                .help(Text(verbatim: rootURL.path))
                .accessibilityLabel(L10n.format("Projektordner %@", rootURL.lastPathComponent))
                .accessibilityHint("⌘-Klick zeigt die Nachbarordner zum Projektwechsel.")
                .contentShape(Rectangle())
                // Cmd-Klick → Geschwisterordner-Menü. Ein normaler Klick
                // bleibt wirkungslos (kein verstecktes Verhalten).
                .gesture(
                    TapGesture().modifiers(.command).onEnded {
                        SiblingFolderMenuPresenter.shared.present(
                            for: rootURL, workspace: workspace
                        )
                    }
                )
            Spacer(minLength: 0)
            Button {
                workspace.closeProject()
            } label: {
                Image(systemName: "xmark")
                    .fastraFont(size: 9, weight: .semibold)
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Projektansicht schließen")
            .accessibilityLabel("Projektansicht schließen")
            .accessibilityHint("Blendet die Projekt-Seitenleiste aus. Offene Tabs bleiben erhalten.")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
        // Für den Fenster-Selbsttest `sidebarheader`: nur wenn der Kopf
        // wirklich layoutet wird, existiert diese Marker-NSView im Fenster.
        .background(SelfTestMarker(id: "sidebarProjectHeader").frame(width: 0, height: 0))
        .contextMenu {
            Button("Im Finder zeigen…") {
                NSWorkspace.shared.activateFileViewerSelecting([rootURL])
            }
            Button("Projektansicht schließen") { workspace.closeProject() }
            extraMenu()
        }
    }
}
