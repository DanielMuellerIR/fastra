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

    private init(defaults: UserDefaults, showWelcome: Bool) {
        workspace = Workspace(defaults: defaults)
        // Willkommen nur, wenn dies das ERSTE/einzige Dokumentfenster ist
        // (Daniel-Wunsch 2026-07-12): Beim Start ohne offenes Fenster — auch
        // per ⌘N — soll die Willkommensseite kommen. Ist dagegen schon ein
        // Fenster offen, startet das neue direkt im Editor, damit sich nicht
        // beliebig viele Willkommens-Fenster stapeln. Der Workspace legt beim
        // Folgestart ohnehin einen Willkommen-Tab an; ohne Willkommen wandeln
        // wir ihn hier in ein normales leeres Dokument um.
        if !showWelcome {
            workspace.dismissWelcomeTab()
        }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.identifier = NSUserInterfaceItemIdentifier("Fastra.DocumentWindow")
        // Titel wie das Startfenster: im Willkommen-Zustand Version + Datum,
        // sonst der Tab-Titel. Danach hält die `MainWindowTitleBridge` (in
        // ContentView) den Titel live aktuell, sobald Dateien geöffnet werden.
        window.title = workspace.isWelcomeScreen
            ? AppInfo.welcomeWindowTitle
            : (workspace.activeTab?.title ?? "Fastra")
        window.isReleasedWhenClosed = false
        // Klein ziehbar (Daniel-Wunsch 2026-07-12) — siehe FastraApp-Kommentar.
        window.contentMinSize = NSSize(width: 320, height: 200)
        window.delegate = self
        WorkspaceWindowRegistry.register(workspace, for: window)

        // Dieselbe Root-View wie im Startfenster verwenden. Die eigene
        // EnvironmentObject-Instanz ist die Trennlinie zwischen den Dokumenten.
        window.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(workspace)
                .fastraScalingRoot()
                .frame(minWidth: 320, minHeight: 200)
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

    /// `true`, wenn bereits ein sichtbares Dokumentfenster offen ist. Bestimmt,
    /// ob ein neu geöffnetes Fenster die Willkommensseite zeigt: nur das erste/
    /// einzige tut das. Zählt Startfenster (SwiftUI) und ⌘N-Fenster (AppKit)
    /// über ihre Workspace-Zuordnung bzw. den Fenster-Identifier.
    private static func hasOpenDocumentWindow() -> Bool {
        NSApp.windows.contains { win in
            guard win.isVisible else { return false }
            if win.identifier?.rawValue == "Fastra.DocumentWindow" { return true }
            return WorkspaceWindowRegistry.workspace(for: win) != nil
        }
    }

    /// Öffnet ein leeres, unabhängiges Dokumentfenster und gibt dessen
    /// Workspace für den Fenster-Selbsttest zurück. Willkommen zeigt es nur,
    /// wenn noch kein anderes Dokumentfenster offen ist (Daniel-Wunsch
    /// 2026-07-12): ⌘N ohne offenes Fenster → Willkommen, sonst direkt Editor.
    @discardableResult
    static func openNewDocument(defaults: UserDefaults = SelfTest.workspaceDefaults()) -> Workspace {
        let showWelcome = !hasOpenDocumentWindow()
        let controller = DocumentWindowController(defaults: defaults, showWelcome: showWelcome)
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
