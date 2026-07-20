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
    private static var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    static func register(_ workspace: Workspace, for window: NSWindow) {
        workspaces.setObject(workspace, forKey: window)
        let identifier = ObjectIdentifier(window)
        guard closeObservers[identifier] == nil else { return }
        closeObservers[identifier] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            guard let window else { return }
            unregister(window)
        }
    }

    static func workspace(for window: NSWindow) -> Workspace? {
        workspaces.object(forKey: window)
    }

    /// Entfernt wirklich geschlossene Fenster aus der Registry. Das ist für
    /// die Sitzungswiederherstellung wichtig: Beim Beenden kann AppKit offene
    /// Fenster bereits unsichtbar geschaltet haben, ein zuvor vom Nutzer
    /// geschlossenes Fenster darf dagegen niemals wieder auftauchen.
    static func unregister(_ window: NSWindow) {
        workspaces.removeObject(forKey: window)
        let identifier = ObjectIdentifier(window)
        if let observer = closeObservers.removeValue(forKey: identifier) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Alle noch registrierten Fenster. Anders als `NSApp.orderedWindows`
    /// enthält die Liste auch offene Dokumentfenster, die AppKit während
    /// eines laufenden Beenden-Vorgangs bereits ausgeblendet hat.
    static func registeredWindows() -> [NSWindow] {
        workspaces.keyEnumerator().allObjects.compactMap { $0 as? NSWindow }
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
    let chromeHeight: CGFloat

    func makeNSView(context: Context) -> WindowMetadataView {
        WindowMetadataView(metadata: metadata, workspace: workspace,
                           chromeHeight: chromeHeight)
    }

    func updateNSView(_ nsView: WindowMetadataView, context: Context) {
        nsView.metadata = metadata
        nsView.workspace = workspace
        nsView.chromeHeight = chromeHeight

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
        var chromeHeight: CGFloat {
            didSet { positionTrafficLights() }
        }
        private weak var observedWindow: NSWindow?
        private var keyObserver: NSObjectProtocol?
        /// Zuletzt in das „Fenster"-Menü geschriebener Titel — verhindert
        /// wiederholtes Neusetzen desselben Eintrags (siehe `applyMetadataToWindow`).
        private var lastWindowsMenuTitle: String?

        init(metadata: MainWindowTitleMetadata, workspace: Workspace,
             chromeHeight: CGFloat) {
            self.metadata = metadata
            self.workspace = workspace
            self.chromeHeight = chromeHeight
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
            // Dieses per NSHostingController gehostete Fenster verlässlich ins
            // „Fenster"-Menü aufnehmen. Für das SwiftUI-Startfenster fehlte der
            // Eintrag bisher ganz — das Menü blieb leer, obwohl das Fenster mit
            // seinen Tabs offen war (Daniel-Befund 2026-07-20). `changeWindowsItem`
            // fügt HINZU oder aktualisiert nur; die bereits per `addWindowsItem`
            // eingetragenen ⌘N-/wiederhergestellten Fenster bekommen dadurch
            // keinen Doppel-Eintrag, sondern nur ihren Titel nachgeführt.
            // Nur bei ECHTER Titeländerung ins Menü schreiben. Häufiges,
            // unnötiges Neusetzen während des Starts kann verhindern, dass AppKit
            // seine Standard-Fensterbefehle (Füllen, Zentriert, …) rechtzeitig
            // ergänzt — das Menü war beim ersten Öffnen unvollständig und erst
            // beim zweiten korrekt (Daniel-Befund 2026-07-20).
            if !SearchWindow.isSearchWindow(window), lastWindowsMenuTitle != metadata.title {
                lastWindowsMenuTitle = metadata.title
                NSApp.changeWindowsItem(window, title: metadata.title, filename: false)
            }
            // Codex-artiger Fensteraufbau: SwiftUI zeichnet den Chrome bis
            // hinter die native Titelleiste. Die Ampelknöpfe bleiben echte
            // AppKit-Controls; nur Dateititel und Hintergrund werden ersetzt.
            // AppKit meldet diese Properties per KVO an SwiftUI. Erneutes
            // Schreiben desselben Werts während eines SwiftUI-Updates kann
            // AttributeGraph reentrant betreten (beim Dark-Mode-Start als
            // reproduzierbarer Crash sichtbar). Deshalb nur echte Änderungen
            // setzen; nach dem ersten Fensteraufbau bleibt der Pfad schreibfrei.
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            if !window.titlebarAppearsTransparent {
                window.titlebarAppearsTransparent = true
            }
            if window.titleVisibility != .hidden {
                window.titleVisibility = .hidden
            }
            if !window.isMovableByWindowBackground {
                window.isMovableByWindowBackground = true
            }

            // Die nativen Ampeln kennen Fastras skalierte Chrome-Höhe nicht
            // und kleben sonst optisch am oberen Rand. Nach AppKits eigenem
            // Titelleisten-Layout zentrieren wir sie zur sichtbaren Leiste.
            positionTrafficLights()
            DispatchQueue.main.async { [weak self] in
                self?.positionTrafficLights()
            }
        }

        private func positionTrafficLights() {
            guard let window else { return }
            for kind in [NSWindow.ButtonType.closeButton,
                         .miniaturizeButton,
                         .zoomButton] {
                guard let button = window.standardWindowButton(kind),
                      let container = button.superview else { continue }
                let y = MainWindowSizing.trafficLightOriginY(
                    superviewHeight: container.bounds.height,
                    buttonHeight: button.frame.height,
                    chromeHeight: chromeHeight,
                    isFlipped: container.isFlipped
                )
                button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y))
            }
        }
    }
}
