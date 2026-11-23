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

    /// Fenstertitel im leeren/Willkommens-Zustand: Produktname, Version und
    /// zugehöriges Datum. Fehlt das Datum, nur die Version anzeigen.
    static var welcomeWindowTitle: String {
        let date = versionDate
        return date.isEmpty ? "Fastra v\(version)" : "Fastra v\(version) \(date)"
    }
}

/// Zuordnung eines AppKit-Fensters zu seinem Dokument-Workspace.
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
        if let workspace = workspaces.object(forKey: window) {
            return workspace
        }
        // Ein sichtbares SwiftUI-Dokument trägt seine Titelbrücke weiterhin
        // im View-Baum. Ist nur die Registry-Verknüpfung verloren gegangen,
        // stellt die Brücke Registry, Schließen-Handler und Fenster-Menü in
        // einem Schritt wieder her. Fremde Fenster enthalten keine Brücke.
        // Eine gerade geschlossene, bereits ausgeblendete SwiftUI-Hierarchie
        // kann noch kurz im Fenster hängen. Sie darf sich nach dem
        // `willClose`-Unregister nicht selbst wieder anmelden und dabei ihren
        // Fenster-Menü-Eintrag als Leiche zurückbringen.
        guard window.isVisible, Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated {
            MainWindowTitleBridge.restoreWindowBinding(for: window)
        }
    }

    /// Entfernt wirklich geschlossene Fenster aus der Registry. Das ist für
    /// die Sitzungswiederherstellung wichtig: Beim Beenden kann AppKit offene
    /// Fenster bereits unsichtbar geschaltet haben, ein zuvor vom Nutzer
    /// geschlossenes Fenster darf dagegen niemals wieder auftauchen.
    static func unregister(_ window: NSWindow) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { unregister(window) }
            return
        }
        let workspace = workspaces.object(forKey: window)
        workspaces.removeObject(forKey: window)
        MainActor.assumeIsolated {
            // Such- und Hilfefenster teilen teils den Workspace, schließen
            // aber niemals dessen Dokument-Sitzung (auch beim Startfenster).
            if !SearchWindow.isSearchWindow(window), !HelpWindow.isHelpWindow(window) {
                workspace?.closeDocumentSearchResults()
            }
        }
        // Den Tab-Untermenü-Eintrag des Fensters mit abbauen. Register/
        // Unregister laufen bereits auf dem Main-Thread (SwiftUI-Update bzw.
        // Notification-Queue .main); der Dispatch deckt nur den Fall ab, dass
        // ein künftiger Aufrufer von woanders kommt.
        if Thread.isMainThread {
            MainActor.assumeIsolated { WindowsMenuTabs.shared.removeItem(for: window) }
        } else {
            DispatchQueue.main.async { WindowsMenuTabs.shared.removeItem(for: window) }
        }
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

    /// Alle Dokument-Workspaces genau einmal. Dateibaum-Mutationen müssen
    /// dieselbe geöffnete Datei auch in einem zweiten Fenster schützen und
    /// nach Umbenennungen auf den neuen Pfad umhängen.
    static func registeredWorkspaces() -> [Workspace] {
        var seen = Set<ObjectIdentifier>()
        return registeredWindows().compactMap { window in
            guard let workspace = workspace(for: window),
                  seen.insert(ObjectIdentifier(workspace)).inserted else {
                return nil
            }
            return workspace
        }
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
    ///   soll die Titelzeile nicht „Ohne Titel" anzeigen (das leere Start-
    ///   Dokument ist noch keine Datei), sondern Version + Datum der App —
    ///   und kein Datei-Icon/Pfadmenü.
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
            isDocumentEdited: tab.hasUnsavedChanges
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

    /// Stellt eine verlorene Zuordnung aus der noch montierten SwiftUI-
    /// Titelbrücke wieder her. Das ist der sichere Rückfall für ein sichtbares
    /// Dokumentfenster: Fenster und Workspace stammen aus derselben View-
    /// Hierarchie, nicht aus globalem Fokuszustand.
    @MainActor
    static func restoreWindowBinding(for window: NSWindow) -> Workspace? {
        guard let contentView = window.contentView,
              let metadataView = descendantMetadataView(in: contentView),
              metadataView.window === window,
              let workspace = metadataView.workspace else {
            return nil
        }
        metadataView.applyMetadataToWindow()
        return workspace
    }

    @MainActor
    private static func descendantMetadataView(in view: NSView) -> WindowMetadataView? {
        if let metadataView = view as? WindowMetadataView {
            return metadataView
        }
        for subview in view.subviews {
            if let metadataView = descendantMetadataView(in: subview) {
                return metadataView
            }
        }
        return nil
    }

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
        private var titleVisibilityObservation: NSKeyValueObservation?

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
            observeWindow()
            applyMetadataToWindow()
        }

        /// Merkt, welches Dokumentfenster gerade den Fokus besitzt. Globale
        /// Commands (⌘F, ⌘S, Text-Operationen …) fragen `Workspace.shared` ab
        /// und arbeiten dadurch auch bei mehreren Fenstern im richtigen Inhalt.
        private func observeWindow() {
            guard observedWindow !== window else { return }
            titleVisibilityObservation?.invalidate()
            titleVisibilityObservation = nil
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
                self.keyObserver = nil
            }
            observedWindow = window
            guard let window else { return }
            // NSHostingController kann den Titel nach dem ersten Bridge-Update
            // wieder einblenden (Zusatz- und Restorefenster). Nicht im KVO-
            // Callback zurückschreiben: Das könnte SwiftUIs Layout reentrant
            // betreten. Die Korrektur gilt nur für die noch montierte Brücke.
            // KVO liefert für diesen AppKit-Enum kein typisiertes newValue;
            // der Getter enthält dagegen bereits den tatsächlichen Zustand.
            titleVisibilityObservation = window.observe(\.titleVisibility) { [weak self] window, _ in
                guard window.titleVisibility != .hidden else { return }
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, let window, self.window === window,
                          window.titleVisibility != .hidden else { return }
                    window.titleVisibility = .hidden
                }
            }
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                if let workspace = self?.workspace {
                    Workspace.shared = workspace
                }
                // Ein per rotem Knopf geschlossenes SwiftUI-Hauptfenster hat
                // seinen Registry-Eintrag beim `willClose` verloren. Zeigt
                // SwiftUI dieselbe Szene später wieder an (Finder-Doppelklick,
                // Dock-Klick), wandert die Brücke nicht erneut ins Fenster —
                // `viewDidMoveToWindow` bleibt aus. Der Schlüsselfenster-
                // Wechsel ist dann der verlässliche Moment, den Eintrag samt
                // Schließen-Handler neu zu setzen. Ohne ihn zählte das wieder
                // sichtbare Fenster in v1.117.2 nicht als Dokumentfenster, und
                // eine per Finder geöffnete Datei bekam ein zweites Fenster.
                // Der Aufruf ist idempotent.
                self?.applyMetadataToWindow()
                // Ein Schlüsselfenster-Wechsel ist zugleich der erste sichere
                // Zeitpunkt, an dem SwiftUIs endgültiges Startfenster sichtbar
                // ist. Der vollständige Abgleich entfernt deshalb auch einen
                // Eintrag eines kurzlebigen Startfensters; nur die Häkchen
                // nachzuführen ließ beim Kaltstart zwei gleichnamige
                // Untermenüs stehen.
                WindowsMenuTabs.shared.synchronizeWithCurrentWindowsMenu()
            }
            if window.isKeyWindow, let workspace {
                Workspace.shared = workspace
                // `didBecomeKey` kann bereits vor dem Einhängen der Brücke
                // gelaufen sein. Auch dann den Kaltstart-Abgleich ausführen.
                WindowsMenuTabs.shared.synchronizeWithCurrentWindowsMenu()
            }
        }

        func applyMetadataToWindow() {
            guard let window else { return }
            if let workspace {
                WorkspaceWindowRegistry.register(workspace, for: window)
                // Genau diese Brücke gehört zu einem Dokumentfenster. Ein
                // allgemeiner Registry-Callback wäre zu breit: Auch das
                // Suchfenster kann denselben Workspace registrieren und darf
                // die Sitzungswiederherstellung nicht verfrüht starten.
                SessionRestorationCoordinator.documentWindowDidRegister(
                    workspace,
                    window: window
                )
                // Workspace entscheidet, wann geschlossen werden darf; AppKit
                // führt danach nur noch das tatsächliche Fensterschließen aus.
                workspace.closeWindowHandler = { [weak window] in
                    window?.close()
                }
                if window.isKeyWindow {
                    Workspace.shared = workspace
                }
                routeCloseButtonThroughWorkspace(window)
            }

            // AppKit kann aus der URL vorübergehend selbst einen Titel bilden.
            // Deshalb zuerst die URL und danach den exakten Tab-Titel setzen.
            window.representedURL = metadata.representedURL
            window.title = metadata.title
            window.isDocumentEdited = metadata.isDocumentEdited
            // `WindowsMenuTabs` pflegt den einzigen Fenster-Eintrag als Tab-Untermenü.
            // `isExcludedFromWindowsMenu` unterdrückt den doppelten AppKit-Eintrag.
            //
            // `updateItem` bei jedem Apply idempotent aufrufen: Beim Sitzungsstart kann
            // `NSApp.windowsMenu` noch fehlen. Eine Bindung allein an Titeländerungen
            // würde den später nötigen Menüaufbau verpassen.
            if !SearchWindow.isSearchWindow(window), let workspace {
                if !window.isExcludedFromWindowsMenu {
                    window.isExcludedFromWindowsMenu = true
                }
                // AppKit kann seinen eigenen Eintrag schon vor dem Setzen der
                // Ausnahme angelegt haben (wiederhergestellte Fenster beim
                // Start) — die Ausnahme verhindert nur künftige Einträge,
                // entfernt aber keine bestehenden. Deshalb bei jedem Apply
                // mit abräumen; ohne vorhandenen Eintrag ist der Aufruf
                // wirkungslos, und den eigenen Untermenü-Eintrag kennt
                // AppKits Fensterverwaltung nicht.
                NSApp.removeWindowsItem(window)
                WindowsMenuTabs.shared.updateItem(for: window,
                                                  workspace: workspace,
                                                  title: metadata.title)
            }
            // Codex-artiger Fensteraufbau: SwiftUI zeichnet den Chrome bis
            // hinter die native Titelleiste. Die Ampelknöpfe bleiben echte
            // AppKit-Controls; nur Dateititel und Hintergrund werden ersetzt.
            // AppKit meldet diese Properties per KVO an SwiftUI. Erneutes
            // Schreiben desselben Werts während eines SwiftUI-Updates kann
            // AttributeGraph reentrant betreten (beim Dark-Mode-Start als
            // reproduzierbarer Crash sichtbar). Deshalb nur echte Änderungen
            // setzen; ohne eine Framework-Änderung bleibt der Pfad schreibfrei.
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

        /// SwiftUI verwaltet den Delegate des Hauptfensters selbst; dessen
        /// Schließpfad kennt weder ungesicherte Tabs noch `prepareToCloseWindow`.
        /// Den roten Schließen-Knopf deshalb auf Fastras Tab-Auflösung umleiten.
        /// Zusatzfenster haben über `DocumentWindowController` einen eigenen Delegate;
        /// das Suchfenster ist kein Dokumentfenster.
        private func routeCloseButtonThroughWorkspace(_ window: NSWindow) {
            guard !SearchWindow.isSearchWindow(window),
                  !(window.delegate is DocumentWindowController),
                  let button = window.standardWindowButton(.closeButton) else {
                return
            }
            guard button.target !== self else { return }
            button.target = self
            button.action = #selector(closeButtonPressed(_:))
        }

        /// Roter Knopf: dieselbe Tab-Auflösung wie ⌘W ausführen, dann `close()`.
        /// `performClose(_:)` würde den Knopfklick erneut auslösen und diese Methode
        /// rekursiv aufrufen.
        @objc private func closeButtonPressed(_ sender: Any?) {
            guard let window else { return }
            if let workspace {
                guard workspace.prepareToCloseWindow() else { return }
            }
            window.close()
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
