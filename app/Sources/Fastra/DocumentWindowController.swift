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
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.identifier = NSUserInterfaceItemIdentifier("Fastra.DocumentWindow")
        window.title = workspace.activeTab?.title ?? "Ohne Titel"
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
        Self.openControllers.removeValue(forKey: ObjectIdentifier(window))
    }
}
