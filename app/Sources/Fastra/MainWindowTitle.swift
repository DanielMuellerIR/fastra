import AppKit
import SwiftUI

/// App-Metadaten aus dem Bundle (`Info.plist`) — zur Laufzeit gelesen, nicht
/// hartkodiert. Beide Werte werden beim Version-Bump in `Info.plist` gepflegt
/// (`CFBundleShortVersionString` + der eigene Schlüssel `FastraVersionDate`).
enum AppInfo {
    /// Anzeige-Version, z.B. „1.6.2".
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"
    }

    /// Datum der aktuellen Version im ISO-Format „YYYY-MM-DD" (eigener
    /// Info.plist-Schlüssel `FastraVersionDate`). Leer, falls nicht gesetzt.
    static var versionDate: String {
        Bundle.main.object(forInfoDictionaryKey: "FastraVersionDate")
            as? String ?? ""
    }

    /// Fenstertitel im Willkommens-/Leerzustand: „Fastra v1.6.2 2026-07-12"
    /// (Daniel-Wunsch 2026-07-12: Version + zugehöriges Datum statt des
    /// bisherigen „Fastra – Texteditor"). Fehlt das Datum, nur die Version.
    static var welcomeWindowTitle: String {
        let date = versionDate
        return date.isEmpty ? "Fastra v\(version)" : "Fastra v\(version) \(date)"
    }
}

/// Schwache Zuordnung eines AppKit-Fensters zu seinem Dokument-Workspace.
/// AppDelegate fragt sie bei jedem `didBecomeKey` ab; damit folgen globale
/// Commands auch dann zuverlässig dem Vorderfenster, wenn SwiftUI seine
/// unsichtbare Metadaten-Brücke zwischenzeitlich neu erzeugt.
enum WorkspaceWindowRegistry {
    private static let workspaces = NSMapTable<NSWindow, Workspace>.weakToWeakObjects()

    static func register(_ workspace: Workspace, for window: NSWindow) {
        workspaces.setObject(workspace, forKey: window)
    }

    static func workspace(for window: NSWindow) -> Workspace? {
        workspaces.object(forKey: window)
    }
}

/// Testbares Abbild der aktiven Datei für die native Fenstertitelzeile.
/// Die Umwandlung ist absichtlich von `NSWindow` getrennt, damit gespeicherte
/// und ungespeicherte Tabs ohne echtes Fenster per Unit-Test prüfbar bleiben.
struct MainWindowTitleMetadata: Equatable {
    let title: String
    let representedURL: URL?
    let isDocumentEdited: Bool

    /// - Parameter welcomeActive: `true`, solange das Fenster den
    ///   Willkommensbildschirm zeigt (noch keine echte Datei offen). Dann
    ///   soll die Titelzeile NICHT „Ohne Titel" anzeigen (das leere Start-
    ///   Dokument ist noch keine Datei), sondern Version + Datum der App —
    ///   und kein Datei-Icon/Pfadmenü (Daniel-Wunsch 2026-07-12).
    /// - Parameter welcomeTitle: der im Willkommens-Zustand angezeigte Titel.
    ///   Default = `AppInfo.welcomeWindowTitle` (aus dem Bundle); als Parameter
    ///   injizierbar, damit die pure Umwandlung ohne echtes Bundle testbar bleibt.
    static func from(_ tab: EditorTab?,
                     welcomeActive: Bool = false,
                     welcomeTitle: String = AppInfo.welcomeWindowTitle) -> MainWindowTitleMetadata {
        if welcomeActive {
            return MainWindowTitleMetadata(
                title: welcomeTitle,
                representedURL: nil,
                isDocumentEdited: false
            )
        }

        guard let tab else {
            return MainWindowTitleMetadata(
                title: "Fastra",
                representedURL: nil,
                isDocumentEdited: false
            )
        }

        return MainWindowTitleMetadata(
            title: tab.title,
            representedURL: tab.url,
            isDocumentEdited: tab.isDirty
        )
    }
}

/// Verbindet SwiftUIs aktiven Tab mit dem umgebenden `NSWindow`.
///
/// `NSWindow.representedURL` ist der native macOS-Vertrag für Dokumentfenster:
/// AppKit zeigt darüber das Datei-Icon und erzeugt bei Command-Klick auf Titel
/// oder Icon automatisch das hierarchische Pfadmenü.
struct MainWindowTitleBridge: NSViewRepresentable {
    let metadata: MainWindowTitleMetadata
    let workspace: Workspace

    func makeNSView(context: Context) -> WindowMetadataView {
        WindowMetadataView(metadata: metadata, workspace: workspace)
    }

    func updateNSView(_ nsView: WindowMetadataView, context: Context) {
        nsView.metadata = metadata
        nsView.workspace = workspace

        // SwiftUI kann aktualisieren, während AppKit die View gerade in eine
        // Fensterhierarchie einhängt. Der nächste Main-Loop-Durchlauf deckt
        // dieses kurze Intervall ohne Fensterreferenz ab.
        DispatchQueue.main.async { [weak nsView] in
            nsView?.applyMetadataToWindow()
        }
    }

    final class WindowMetadataView: NSView {
        var metadata: MainWindowTitleMetadata {
            didSet { applyMetadataToWindow() }
        }
        weak var workspace: Workspace?
        private weak var observedWindow: NSWindow?
        private var keyObserver: NSObjectProtocol?

        init(metadata: MainWindowTitleMetadata, workspace: Workspace) {
            self.metadata = metadata
            self.workspace = workspace
            super.init(frame: .zero)
        }

        deinit {
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeWindowActivation()
            applyMetadataToWindow()
        }

        /// Merkt, welches Dokumentfenster gerade den Fokus besitzt. Globale
        /// Commands (⌘F, ⌘S, Text-Operationen …) fragen `Workspace.shared` ab
        /// und arbeiten dadurch auch bei mehreren Fenstern im richtigen Inhalt.
        private func observeWindowActivation() {
            guard observedWindow !== window else { return }
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
                self.keyObserver = nil
            }
            observedWindow = window
            guard let window else { return }
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                if let workspace = self?.workspace {
                    Workspace.shared = workspace
                }
            }
            if window.isKeyWindow, let workspace {
                Workspace.shared = workspace
            }
        }

        func applyMetadataToWindow() {
            guard let window else { return }
            if let workspace {
                WorkspaceWindowRegistry.register(workspace, for: window)
                // Workspace entscheidet, WANN geschlossen werden darf; AppKit
                // führt danach nur noch das tatsächliche Fensterschließen aus.
                workspace.closeWindowHandler = { [weak window] in
                    window?.close()
                }
                if window.isKeyWindow {
                    Workspace.shared = workspace
                }
            }

            // AppKit kann aus der URL vorübergehend selbst einen Titel bilden.
            // Deshalb zuerst die URL und danach den exakten Tab-Titel setzen.
            window.representedURL = metadata.representedURL
            window.title = metadata.title
            window.isDocumentEdited = metadata.isDocumentEdited
            window.titleVisibility = .visible
        }
    }
}
