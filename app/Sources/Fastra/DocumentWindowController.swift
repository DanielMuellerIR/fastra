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
    // SwiftUI kann den Rahmen beim ersten Layout noch einmal auf seine fitting
    // size setzen. Dieser gemerkte Rahmen wird deshalb genau einmal danach
    // wiederhergestellt; spätere Nutzer-Resizes bleiben davon unberührt.
    private var frameToRestoreAfterFirstLayout: NSRect?

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
            contentRect: NSRect(x: 0, y: 0,
                                width: MainWindowSizing.defaultWidth,
                                height: MainWindowSizing.defaultHeight),
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
        window.contentMinSize = NSSize(width: MainWindowSizing.minimumWidth,
                                       height: MainWindowSizing.minimumHeight)
        window.delegate = self
        WorkspaceWindowRegistry.register(workspace, for: window)

        // Dieselbe Root-View wie im Startfenster verwenden. Die eigene
        // EnvironmentObject-Instanz ist die Trennlinie zwischen den Dokumenten.
        let contentController = NSHostingController(
            rootView: ContentView()
                .environmentObject(workspace)
                .fastraScalingRoot()
                .frame(minWidth: MainWindowSizing.minimumWidth,
                       minHeight: MainWindowSizing.minimumHeight)
                .background(Theme.surfaceBase.ignoresSafeArea())
        )
        // SwiftUI meldet sonst nach dem ersten Layout seine fitting size an
        // AppKit zurück. Das würde den zuvor vom Vorderfenster übernommenen
        // Rahmen auf die technische Mindestgröße zurücksetzen. Die echte
        // Untergrenze bleibt ausdrücklich `contentMinSize`, damit kleine
        // Fenster weiter möglich sind und ⌘N trotzdem die zuletzt benutzte
        // Größe behält.
        contentController.sizingOptions = []
        window.contentViewController = contentController

        // Neue Fenster leicht versetzt zum zuletzt sichtbaren Dokumentfenster
        // öffnen. Ein gerade aktiver Suchdialog ist kein Dokumentfenster und
        // darf deshalb nicht versehentlich dessen Größe vorgeben.
        if let front = Self.frontmostVisibleDocumentWindow() {
            let frame = MainWindowSizing.cascadedFrame(from: front.frame)
            frameToRestoreAfterFirstLayout = frame
            window.setFrame(frame,
                            display: false)
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

    /// Liefert das vorderste sichtbare Fenster mit eigenem Dokument-Workspace.
    /// `NSApp.keyWindow` kann auch ein Suchdialog sein und ist daher für ⌘N
    /// nicht zuverlässig die zuletzt benutzte Dokumentgröße.
    private static func frontmostVisibleDocumentWindow() -> NSWindow? {
        NSApp.orderedWindows.first(where: isVisibleDocumentWindow)
    }

    /// Echte sichtbare Dokumentfenster (Startfenster + ⌘N-Fenster).
    /// Such- und Markdown-Vorschaufenster besitzen für ihr Routing ebenfalls
    /// einen Workspace, sind aber keine Dokumentfenster.
    private static func isVisibleDocumentWindow(_ window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        guard !SearchWindow.isSearchWindow(window),
              window.frameAutosaveName != MarkdownPreviewWindow.frameAutosaveName else {
            return false
        }
        if window.identifier?.rawValue == "Fastra.DocumentWindow" { return true }
        return WorkspaceWindowRegistry.workspace(for: window) != nil
    }

    /// Anzahl der sichtbaren Dokumentfenster. Für den ⌘N-Sonderfall der
    /// Willkommensseite (Etappe 1 Wunschpaket 2026-07): nur wenn genau EIN
    /// Fenster offen ist und dieses nur Willkommen zeigt, wirkt ⌘N wie ⌘T.
    static func visibleDocumentWindowCount() -> Int {
        NSApp.windows.filter(isVisibleDocumentWindow).count
    }

    /// Liefert den Workspace des vordersten sichtbaren Dokumentfensters.
    /// Ein geschlossenes Fenster darf nicht über `Workspace.shared` weiter
    /// Ziel eines Öffnen-Befehls bleiben.
    static func frontmostVisibleWorkspace() -> Workspace? {
        guard let window = frontmostVisibleDocumentWindow() else { return nil }
        return WorkspaceWindowRegistry.workspace(for: window)
    }

    /// Ziel für Datei-/Ordner-Öffnen: vorhandenes Vorderfenster oder ein neu
    /// erzeugtes Dokumentfenster, wenn der Nutzer alle Fenster geschlossen hat.
    static func workspaceForOpening(
        defaults: UserDefaults = SelfTest.workspaceDefaults()
    ) -> Workspace {
        frontmostVisibleWorkspace() ?? openNewDocument(defaults: defaults)
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
        restoreFrameAfterFirstSwiftUILayout()
    }

    private func restoreFrameAfterFirstSwiftUILayout() {
        guard let frame = frameToRestoreAfterFirstLayout else { return }
        frameToRestoreAfterFirstLayout = nil
        // Der nächste Main-Loop-Durchlauf liegt hinter SwiftUIs erstem
        // Größen-Update. Danach darf dieser Controller nie wieder den Rahmen
        // setzen, damit jede spätere Größenänderung allein dem Nutzer gehört.
        DispatchQueue.main.async { [weak self] in
            self?.window.setFrame(frame, display: true)
        }
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
