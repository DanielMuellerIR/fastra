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
private final class SiblingFolderMenuContext: @unchecked Sendable {
    weak var workspace: Workspace?

    init(workspace: Workspace) {
        self.workspace = workspace
    }
}

@MainActor
private final class SiblingFolderMenuSelection: NSObject {
    let url: URL
    weak var workspace: Workspace?

    init(url: URL, workspace: Workspace?) {
        self.url = url
        self.workspace = workspace
    }
}

@MainActor
final class SiblingFolderMenuPresenter: NSObject {
    static let shared = SiblingFolderMenuPresenter()

    /// Die beiden kleinen Methoden halten die Zielauflösung getrennt vom
    /// nativen Menü-Tracking und dadurch ohne sichtbares Fenster testbar.
    func selection(for url: URL, workspace: Workspace?) -> Any {
        SiblingFolderMenuSelection(url: url, workspace: workspace)
    }

    func destination(for representedObject: Any?) -> (url: URL, workspace: Workspace)? {
        guard let selection = representedObject as? SiblingFolderMenuSelection,
              let workspace = selection.workspace else { return nil }
        return (selection.url, workspace)
    }

    /// Startet das asynchrone Ordner-Listing (nie auf dem Main-Thread) und
    /// zeigt danach das Menü. Die Mausposition wird beim Klick festgehalten,
    /// damit das Menü dort erscheint, wo geklickt wurde.
    func present(for projectURL: URL, workspace: Workspace) {
        // Der Kontext gehört zu genau diesem Klick. Der Singleton darf keine
        // globale Workspace-Referenz halten: Ein zweites Fenster kann sonst
        // vor der Menüauswahl das Ziel des ersten Fensters überschreiben.
        let context = SiblingFolderMenuContext(workspace: workspace)
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
                                                       at: location,
                                                       workspace: context.workspace)
            }
        }
    }

    private func show(_ result: Result<[URL], Error>, current: URL, at location: NSPoint,
                      workspace: Workspace?) {
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
                item.representedObject = selection(for: folder, workspace: workspace)
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
        guard let destination = destination(for: sender.representedObject) else { return }
        // Gleiches Verhalten wie „Ordner öffnen“: ausdrücklicher
        // Projektwechsel, fremde saubere Tabs werden aufgeräumt.
        destination.workspace.openProject(at: destination.url)
    }
}

/// Kopfzeile der Projekt-Seitenleiste: Ordnername links, rechts ein optionales
/// Zubehör (der Dateien-Tab legt dort sein kompaktes Filterfeld hin).
/// `extraMenu` erlaubt dem Dateien-Tab, sein Vollmenü (Neue Datei/Ordner,
/// Terminal) unter die gemeinsamen Punkte zu hängen. Das frühere Schließen-X
/// ist entfallen (Daniel 2026-09-01: kein Vorteil, der Platz gehört dem
/// Filterfeld); „Projektansicht schließen“ bleibt im Rechtsklickmenü.
struct SidebarProjectHeader<ExtraMenu: View, Accessory: View>: View {
    let rootURL: URL
    @ViewBuilder var extraMenu: () -> ExtraMenu
    @ViewBuilder var accessory: () -> Accessory
    @EnvironmentObject var workspace: Workspace

    /// Bequemer Aufruf ohne Zusatzmenü und Zubehör (Änderungen-/Graph-Tab).
    init(rootURL: URL) where ExtraMenu == EmptyView, Accessory == EmptyView {
        self.init(rootURL: rootURL, extraMenu: { EmptyView() },
                  accessory: { EmptyView() })
    }

    init(rootURL: URL, @ViewBuilder extraMenu: @escaping () -> ExtraMenu)
        where Accessory == EmptyView {
        self.init(rootURL: rootURL, extraMenu: extraMenu,
                  accessory: { EmptyView() })
    }

    init(rootURL: URL, @ViewBuilder extraMenu: @escaping () -> ExtraMenu,
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.rootURL = rootURL
        self.extraMenu = extraMenu
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(rootURL.lastPathComponent.uppercased())
                .fastraFont(size: 10, weight: .semibold)
                .tracking(0.6)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                // Der Name behält Vorrang vor dem Zubehör: Mit niedriger
                // Priorität fraß das gierige Filterfeld die ganze Zeile und
                // der Projektname verschwand vollständig (Sichtprüfung
                // 2026-09-01). Erst wenn das Zubehör auf seiner Mindestbreite
                // ist, wird der Name gekürzt.
                .layoutPriority(1)
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
            Spacer(minLength: 8)
            accessory()
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
