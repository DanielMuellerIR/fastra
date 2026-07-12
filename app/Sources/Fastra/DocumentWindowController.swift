import AppKit
import SwiftUI

/// Erzeugt zusätzliche Dokumentfenster für ⌘N.
///
/// Das Startfenster bleibt eine SwiftUI-`Window`-Scene, damit die bewährte
/// Einfenster-Restauration erhalten bleibt. Weitere Fenster werden bewusst
/// kontrolliert über AppKit angelegt. Entscheidend ist: Jedes Fenster besitzt
/// einen eigenen `Workspace`; Tabs, Suchzustand und ungesicherter Inhalt werden
/// daher niemals zwischen zwei Fenstern geteilt.
@MainActor
final class DocumentWindowController: NSObject, NSWindowDelegate {
    /// NSWindow hält seinen Delegate nur schwach. Diese Tabelle hält deshalb
    /// Controller und Workspace, bis das zugehörige Fenster wirklich schließt.
    private static var openControllers: [ObjectIdentifier: DocumentWindowController] = [:]

    let workspace: Workspace
    private let window: NSWindow

    private init(defaults: UserDefaults) {
        workspace = Workspace(defaults: defaults)
        // Der Willkommensbildschirm ist die EINMALIGE Einstiegs-Fläche des
        // Startfensters. Ein per ⌘N geöffnetes Fenster ist dagegen eine aktive
        // „ich will arbeiten"-Absicht → es startet direkt mit dem leeren Editor,
        // nicht mit einer weiteren Willkommensseite. Sonst ließen sich per ⌘N
        // beliebig viele Willkommens-Fenster stapeln (Daniel-Befund 2026-07-12:
        // „nie mehr als ein Willkommen").
        workspace.welcomeDismissed = true
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.identifier = NSUserInterfaceItemIdentifier("Fastra.DocumentWindow")
        // Ein frisches ⌘N-Fenster startet im Willkommen-Zustand (leerer,
        // unbenannter Tab) → Titel wie das Startfenster, nicht „Ohne Titel".
        // Danach hält die `MainWindowTitleBridge` (in ContentView) den Titel
        // live aktuell, sobald echte Dateien geöffnet werden.
        window.title = workspace.isWelcomeScreen
            ? "Fastra – Texteditor"
            : (workspace.activeTab?.title ?? "Fastra")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 1100, height: 720)
        window.delegate = self
        WorkspaceWindowRegistry.register(workspace, for: window)

        // Dieselbe Root-View wie im Startfenster verwenden. Die eigene
        // EnvironmentObject-Instanz ist die Trennlinie zwischen den Dokumenten.
        window.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(workspace)
                .frame(minWidth: 1100, minHeight: 720)
                .background(Theme.surfaceBase.ignoresSafeArea())
        )

        // Neue Fenster leicht versetzt zum bisherigen Vorderfenster öffnen,
        // damit sofort sichtbar ist, dass tatsächlich ein zweites entstand.
        if let front = NSApp.keyWindow {
            var frame = front.frame
            frame.origin.x += 24
            frame.origin.y -= 24
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
    }

    /// Öffnet ein leeres, unabhängiges Dokumentfenster und gibt dessen
    /// Workspace für den Fenster-Selbsttest zurück.
    @discardableResult
    static func openNewDocument(defaults: UserDefaults = SelfTest.workspaceDefaults()) -> Workspace {
        let controller = DocumentWindowController(defaults: defaults)
        openControllers[ObjectIdentifier(controller.window)] = controller
        controller.window.makeKeyAndOrderFront(nil)
        // Ins „Fenster"-Menü aufnehmen. Per AppKit erzeugte Fenster tauchen dort
        // sonst nicht auf — bei mehreren Fenstern war nur das SwiftUI-Startfenster
        // gelistet (Daniel-Befund 2026-07-12). Den Titel hält AppKit danach
        // automatisch synchron zu `window.title`; `removeWindowsItem` räumt beim
        // Schließen wieder auf.
        NSApp.addWindowsItem(controller.window,
                             title: controller.window.title,
                             filename: false)
        Workspace.shared = controller.workspace
        return controller.workspace
    }

    func windowDidBecomeKey(_ notification: Notification) {
        Workspace.shared = workspace
    }

    /// Anders als das bisher offene Rotknopf-Todo darf ein zusätzliches
    /// Fenster nicht ungefragt ungesicherte Tabs verwerfen. Derselbe geprüfte
    /// Workspace-Pfad wie bei letztem ⌘W schützt deshalb das komplette Fenster.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        workspace.prepareToCloseWindow()
    }

    func windowWillClose(_ notification: Notification) {
        workspace.showSearchDialog = false
        NSApp.removeWindowsItem(window)
        Self.openControllers.removeValue(forKey: ObjectIdentifier(window))
    }
}
