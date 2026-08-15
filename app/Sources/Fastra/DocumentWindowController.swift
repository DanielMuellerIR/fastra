import AppKit
import SwiftUI

/// Momentaufnahme eines offenen Dokumentfensters für die Routing-Entscheidung
/// beim Öffnen aus dem Finder. Bewusst ohne AppKit-Typen, damit die Auswahl
/// rein und ohne echtes Fenster unit-testbar bleibt.
struct OpenWindowSnapshot: Equatable {
    /// Projekt-/Repo-Ordner, den das Fenster gerade zeigt (falls vorhanden).
    let projectURL: URL?
    /// URLs der aktuell in dem Fenster offenen Datei-Tabs.
    let openFileURLs: [URL]
    /// `true`, wenn das Fenster leer und aufnahmebereit ist: Willkommensseite
    /// oder ausschließlich leere „Ohne Titel"-Tabs, ohne Projekt und ohne
    /// ungesicherte Arbeit. Ein solches Fenster nimmt eine geöffnete Datei auf,
    /// statt dafür ein zweites Fenster zu erzeugen (wie ein leeres BBEdit-
    /// Fenster). Default `false`, damit bestehende Aufrufe unverändert bleiben.
    var isEmptyWelcome: Bool = false
}

/// Reine Auswahl des Zielfensters für eine aus dem Finder/Dock geöffnete Datei.
///
/// Entscheidung (Nutzerwunsch 2026-07-20 „alle Fenster durchsuchen"):
/// 1. Ist die Datei bereits irgendwo als Tab offen, gewinnt dieses Fenster
///    (Dedup, vorderstes zuerst) — so entsteht kein zweiter Tab derselben Datei.
/// 2. Sonst das erste Fenster, dessen Projekt-/Repo-Ordner die Datei enthält.
/// 3. Sonst das erste leere/Willkommens-Fenster — ein solches nimmt die Datei
///    auf, statt ein zweites Fenster zu erzeugen (Daniel-Befund 2026-07-20).
/// 4. Passt keines, liefert die Funktion `nil` → ein neues Fenster ist nötig.
enum FinderOpenRouter {
    /// - Parameter windows: Kandidaten in Vordergrund-Reihenfolge (vorderstes
    ///   zuerst). Der Rückgabe-Index bezieht sich auf genau diese Reihenfolge.
    static func targetIndex(for fileURL: URL, in windows: [OpenWindowSnapshot]) -> Int? {
        let filePath = fileURL.canonicalFileURL.path

        // (1) Datei schon offen → dieses Fenster (vorderstes zuerst).
        if let dedup = windows.firstIndex(where: { snapshot in
            snapshot.openFileURLs.contains { $0.canonicalFileURL.path == filePath }
        }) {
            return dedup
        }

        // (2) Projekt/Repo enthält die Datei. Grenzsicherer Prefix-Vergleich:
        // „/tmp/projekt-alt/x“ darf NICHT als in „/tmp/projekt“ liegend gelten
        // (gleiche grenzsichere Pfadregel wie im Workspace-Projektkontext).
        if let project = windows.firstIndex(where: { snapshot in
            guard let root = snapshot.projectURL?.canonicalFileURL.path else { return false }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return filePath.hasPrefix(prefix)
        }) {
            return project
        }

        // (3) Ein leeres/Willkommens-Fenster nimmt die Datei auf, bevor ein
        // neues entsteht (vorderstes zuerst).
        return windows.firstIndex { $0.isEmptyWelcome }
    }
}

/// Erzeugt zusätzliche Dokumentfenster für ⌘N.
///
/// Das Startfenster bleibt eine SwiftUI-`Window`-Scene. Weitere sowie
/// wiederhergestellte Fenster werden bewusst kontrolliert über AppKit
/// angelegt. Entscheidend ist: Jedes Fenster besitzt einen eigenen
/// `Workspace`; Tabs, Suchzustand und ungesicherter Inhalt werden daher
/// niemals zwischen zwei Fenstern geteilt.
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

    private init(defaults: UserDefaults,
                 restoredFrame: NSRect? = nil) {
        workspace = Workspace(defaults: defaults)
        // Jedes Fenster startet gleich: mit einem unberührten leeren Tab,
        // über dem der Willkommens-Platzhalter liegt (Firefox-Muster,
        // Daniel-Entscheidung 2026-07-30 — ersetzt die Sonderrolle des
        // ersten Fensters vom 2026-07-12). Beim Wiederherstellen ersetzen
        // die geladenen Dateien diesen Tab gleich wieder.
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

        // Eine wiederhergestellte Sitzung gewinnt vor dem normalen Kaskadieren.
        // SwiftUI kann den Rahmen beim ersten Layout noch überschreiben; der
        // gespeicherte Wert wird deshalb über denselben Einmal-Mechanismus
        // nachgezogen wie ein neu kaskadiertes Fenster.
        if let restoredFrame {
            frameToRestoreAfterFirstLayout = restoredFrame
            window.setFrame(restoredFrame, display: false)
        } else if let front = Self.frontmostVisibleDocumentWindow() {
            // Neue Fenster leicht versetzt zum zuletzt sichtbaren
            // Dokumentfenster öffnen. Ein Suchdialog darf dessen Größe nicht
            // versehentlich vorgeben.
            let frame = MainWindowSizing.cascadedFrame(from: front.frame)
            frameToRestoreAfterFirstLayout = frame
            window.setFrame(frame,
                            display: false)
        } else if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            // Erstes Fenster ohne Vorbild: praktische Startgröße statt der
            // festen 1100×720. Auf einem großen Bildschirm ist ein 720 Punkte
            // hohes Fenster unnötig flach (Daniel-Wunsch 2026-08-06).
            let frame = MainWindowSizing.newWindowFrame(inVisibleScreen: visible)
            frameToRestoreAfterFirstLayout = frame
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
    }

    /// Liefert das vorderste sichtbare Fenster mit eigenem Dokument-Workspace.
    /// `NSApp.keyWindow` kann auch ein Suchdialog sein und ist daher für ⌘N
    /// nicht zuverlässig die zuletzt benutzte Dokumentgröße.
    private static func frontmostVisibleDocumentWindow() -> NSWindow? {
        visibleDocumentWindows().first
    }

    /// Echte sichtbare Dokumentfenster (Startfenster + ⌘N-Fenster).
    /// Das Suchfenster besitzt für sein Routing ebenfalls einen Workspace,
    /// ist aber kein Dokumentfenster.
    private static func isVisibleDocumentWindow(_ window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        guard !SearchWindow.isSearchWindow(window) else {
            return false
        }
        if window.identifier?.rawValue == "Fastra.DocumentWindow" { return true }
        return WorkspaceWindowRegistry.workspace(for: window) != nil
    }

    /// Anzahl der sichtbaren Dokumentfenster. Für den ⌘N-Sonderfall der
    /// Willkommensseite (Etappe 1 Wunschpaket 2026-07): nur wenn genau EIN
    /// Fenster offen ist und dieses nur Willkommen zeigt, wirkt ⌘N wie ⌘T.
    static func visibleDocumentWindowCount() -> Int {
        visibleDocumentWindows().count
    }

    /// Sichtbare Dokumentfenster in AppKits Vordergrund-Reihenfolge. Die
    /// Sitzungswiederherstellung verwendet exakt dieselbe Klassifikation wie
    /// Fokus-Routing und ⌘N.
    static func visibleDocumentWindows() -> [NSWindow] {
        NSApp.orderedWindows.filter(isVisibleDocumentWindow)
    }

    /// Dokumentfenster für einen sicheren Sitzungssnapshot. Beim Beginn von
    /// ⌘Q kann AppKit weiter hinten liegende Fenster bereits `orderOut`
    /// gesetzt haben; `isVisible` würde dann nur das Vorderfenster speichern.
    /// Die Registry enthält ausschließlich noch nicht geschlossene Fenster
    /// und ist deshalb hier die verlässlichere Quelle.
    static func restorableDocumentWindows() -> [NSWindow] {
        var seen = Set<ObjectIdentifier>()
        return (NSApp.orderedWindows + WorkspaceWindowRegistry.registeredWindows())
            .filter { window in
                let identifier = ObjectIdentifier(window)
                guard seen.insert(identifier).inserted,
                      !SearchWindow.isSearchWindow(window),
                      WorkspaceWindowRegistry.workspace(for: window) != nil else {
                    return false
                }
                return true
            }
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
        // Ein echtes Key-Dokumentfenster ist das eindeutigste Ziel. Direkt
        // nach makeKeyAndOrderFront kann AppKits orderedWindows-Reihenfolge
        // noch den vorherigen Rahmen zuerst liefern; genau dann darf ein aus
        // Finder/Dock geöffneter Ordner nicht im Hintergrundfenster landen.
        CommandTargeting.targetWorkspace()
            ?? frontmostVisibleWorkspace()
            ?? openNewDocument(defaults: defaults)
    }

    /// Öffnet eine Liste aus dem Finder/Dock stammender URLs im jeweils am
    /// besten passenden Fenster und holt dieses nach vorn (Nutzerwunsch
    /// 2026-07-20). Ordner werden wie bisher als Projekt geladen; für Dateien
    /// entscheidet `FinderOpenRouter`. Findet sich kein Fenster, entsteht ein
    /// neues — mehrere gemeinsam geöffnete Dateien desselben (neuen) Auto-
    /// Projektordners teilen dabei genau ein Fenster.
    static func openFinderItems(
        _ urls: [URL],
        defaults: UserDefaults = SelfTest.workspaceDefaults()
    ) {
        var newWindowByFolder: [String: Workspace] = [:]
        for url in urls {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path,
                                                        isDirectory: &isDirectory)

            // Ordner → Projekt. Für das Laden eines ganzen Projekts bleibt es
            // beim bisherigen Verhalten (Vorderfenster oder neu).
            if exists && isDirectory.boolValue {
                let workspace = workspaceForOpening(defaults: defaults)
                workspace.openFileOrFolder(at: url)
                raiseWindow(for: workspace)
                continue
            }

            // Datei → passendes offenes Fenster suchen.
            if let workspace = existingWorkspace(forOpeningFile: url) {
                workspace.openFileOrFolder(at: url)
                raiseWindow(for: workspace)
                continue
            }

            // Kein passendes Fenster: pro Auto-Projektordner genau ein neues
            // Fenster. So bleiben mehrere zusammen geöffnete Dateien desselben
            // Ordners im selben Fenster, obwohl das frische Fenster seinen
            // projectURL erst asynchron setzt.
            let folderKey = Workspace.autoProjectFolder(for: url)?
                .canonicalFileURL.path ?? url.deletingLastPathComponent().canonicalFileURL.path
            let workspace = newWindowByFolder[folderKey] ?? openNewDocument(defaults: defaults)
            newWindowByFolder[folderKey] = workspace
            workspace.openFileOrFolder(at: url)
            raiseWindow(for: workspace)
        }
    }

    /// Sucht unter allen sichtbaren Dokumentfenstern das für diese Datei
    /// passende (bereits offen oder Projekt/Repo enthält sie). `nil` = keines.
    private static func existingWorkspace(forOpeningFile url: URL) -> Workspace? {
        let windows = visibleDocumentWindows()
        let snapshots = windows.map { window in
            let workspace = WorkspaceWindowRegistry.workspace(for: window)
            return OpenWindowSnapshot(
                projectURL: workspace?.projectURL,
                openFileURLs: workspace?.tabs.compactMap { $0.url } ?? [],
                isEmptyWelcome: workspace.map(windowIsEmptyWelcome) ?? false
            )
        }
        guard let index = FinderOpenRouter.targetIndex(for: url, in: snapshots) else {
            return nil
        }
        return WorkspaceWindowRegistry.workspace(for: windows[index])
    }

    /// `true`, wenn das Fenster leer und aufnahmebereit ist: kein Projekt und
    /// nur leere „Ohne Titel"-/Willkommen-Tabs ohne ungesicherte Arbeit. Nur
    /// dann darf eine aus dem Finder geöffnete Datei dieses Fenster übernehmen,
    /// statt ein neues zu erzeugen. Ein Fenster mit ungesichertem Tippinhalt
    /// (dirty) oder einer Git-/Vergleichsansicht zählt bewusst NICHT als leer.
    private static func windowIsEmptyWelcome(_ workspace: Workspace) -> Bool {
        guard workspace.projectURL == nil else { return false }
        return workspace.tabs.allSatisfy { tab in
            tab.gitKind == nil && tab.fileDiffRequest == nil
                && tab.url == nil && tab.content.isEmpty && !tab.isDirty
        }
    }

    /// Holt das Fenster des angegebenen Workspace nach vorn und macht es zum
    /// aktiven Dokument. Behebt, dass beim Öffnen aus dem Finder zwar der
    /// richtige Tab entstand, aber ein anderes Fenster nach vorn kam
    /// (Daniel-Befund 2026-07-20).
    private static func raiseWindow(for workspace: Workspace) {
        let window = windowForRaising(
            workspace,
            orderedWindows: NSApp.orderedWindows,
            registeredWindows: WorkspaceWindowRegistry.registeredWindows()
        )
        guard let window else { return }
        // Bewusst KEIN zusätzliches NSApp.activate(): Der Finder-Öffnen-Vorgang
        // aktiviert die App bereits. Ein zweites Aktivieren holte zuerst das
        // bisherige Vorderfenster nach vorn und schaltete erst danach auf das
        // Zielfenster um (sichtbares Gezappel, Daniel-Befund 2026-07-20).
        // `makeKeyAndOrderFront` holt das Zielfenster direkt nach vorn und
        // aktiviert die App dabei bei Bedarf selbst.
        window.makeKeyAndOrderFront(nil)
        Workspace.shared = workspace
    }

    /// Getrennte Auswahl für einen fensterlosen Regressionstest. Die Listen
    /// werden im Produkt aus AppKits Vordergrundordnung und der Registry
    /// gespeist; der Test muss deshalb kein Fenster sichtbar machen.
    static func windowForRaising(
        _ workspace: Workspace,
        orderedWindows: [NSWindow],
        registeredWindows: [NSWindow]
    ) -> NSWindow? {
        (orderedWindows + registeredWindows)
            .first {
                // Die Suchmaske ist absichtlich mit demselben Workspace
                // registriert, damit Befehle zum richtigen Dokument finden.
                // Beim Finder-Öffnen ist sie aber niemals das Fenster, das
                // nach vorn gehört.
                !SearchWindow.isSearchWindow($0)
                    && !HelpWindow.isHelpWindow($0)
                    && WorkspaceWindowRegistry.workspace(for: $0) === workspace
            }
    }

    /// Öffnet ein leeres, unabhängiges Dokumentfenster und gibt dessen
    /// Workspace für den Fenster-Selbsttest zurück. Willkommen zeigt es nur,
    /// wenn noch kein anderes Dokumentfenster offen ist (Daniel-Wunsch
    /// 2026-07-12): ⌘N ohne offenes Fenster → Willkommen, sonst direkt Editor.
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

    /// Baut ein zusätzliches Fenster aus einem sicheren Sitzungssnapshot auf.
    /// `state` enthält nur Pfade, keinen ungesicherten Dokumentinhalt.
    @discardableResult
    static func openRestoredDocument(
        _ state: RestorableWindowState,
        defaults: UserDefaults = SelfTest.workspaceDefaults(),
        screenFrames: [NSRect] = NSScreen.screens.map(\.visibleFrame),
        completion: (() -> Void)? = nil
    ) -> Workspace {
        let restoredFrame = state.frame?.visibleRect(in: screenFrames)
        let controller = DocumentWindowController(
            defaults: defaults,
            restoredFrame: restoredFrame
        )
        openControllers[ObjectIdentifier(controller.window)] = controller
        controller.workspace.restore(state, completion: completion)
        controller.window.orderFront(nil)
        controller.restoreFrameAfterFirstSwiftUILayout()
        NSApp.addWindowsItem(controller.window,
                             title: controller.window.title,
                             filename: false)
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
        WorkspaceWindowRegistry.unregister(window)
        NSApp.removeWindowsItem(window)
        Self.openControllers.removeValue(forKey: ObjectIdentifier(window))
    }
}

/// Einmalige Korrektur zu flach gespeicherter Fensterrahmen.
///
/// Neue Fenster bekommen ihre praktische Größe schon beim Anlegen. Wer Fastra
/// aber vorher benutzt hat, trägt einen gespeicherten Rahmen mit sich herum —
/// vom Startfenster (SwiftUI merkt sich dessen Größe selbst) bis zu den
/// Rahmen der Sitzungswiederherstellung. Diese Korrektur läuft deshalb genau
/// EINMAL pro Nutzer; danach gehört jede Fenstergröße wieder allein dem
/// Nutzer, auch eine bewusst kleine.
@MainActor
enum MainWindowHeightNormalization {
    static let defaultsKey = "window.practicalHeightNormalized.v1"

    /// Fenster, deren Größe der Nutzer selbst am Rahmen gezogen hat.
    ///
    /// Die Korrektur läuft erst, wenn die Sitzungswiederherstellung ALLE
    /// Dokumente geladen hat. Die Fenster stehen aber schon vorher sichtbar da:
    /// Bei einer langsamen Wiederherstellung kann der Nutzer eines davon
    /// bewusst kleiner ziehen — und die Korrektur zog es danach wieder groß,
    /// obwohl die Größe da längst ihm gehörte (Review 2026-08-06).
    private static var userResizedWindows: Set<ObjectIdentifier> = []

    private static var resizeObservation: NSObjectProtocol?
    private static var resizeObservationCenter: NotificationCenter?

    /// `didEndLiveResize` feuert NUR, wenn der Nutzer den Fensterrahmen
    /// losgelassen hat — ein programmatisches `setFrame` (Wiederherstellung,
    /// diese Korrektur selbst) löst es nicht aus. Genau diese Unterscheidung
    /// braucht die Ausnahme oben. Beim App-Start einmal aufrufen, bevor die
    /// Wiederherstellung beginnt.
    ///
    /// Ist die Korrektur längst gelaufen, gibt es nichts mehr auszunehmen —
    /// dann wird gar nicht erst beobachtet und die Liste bleibt leer.
    static func observeUserResizes(
        defaults: UserDefaults,
        notificationCenter: NotificationCenter = .default
    ) {
        guard !defaults.bool(forKey: defaultsKey), resizeObservation == nil else {
            return
        }
        resizeObservationCenter = notificationCenter
        resizeObservation = notificationCenter.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { noteUserResize(of: window) }
        }
    }

    /// Nach der einmaligen Korrektur ist die Beobachtung überflüssig. Ohne
    /// dieses Abmelden würde die Liste über die ganze Programmlaufzeit
    /// weiterwachsen, ohne je wieder gelesen zu werden.
    private static func stopObservingUserResizes() {
        if let resizeObservation {
            (resizeObservationCenter ?? .default).removeObserver(resizeObservation)
        }
        resizeObservation = nil
        resizeObservationCenter = nil
        userResizedWindows.removeAll()
    }

    /// Merkt ein vom Nutzer selbst verändertes Fenster vor.
    static func noteUserResize(of window: NSWindow) {
        userResizedWindows.insert(ObjectIdentifier(window))
    }

    /// `true`, wenn dieses Fenster von der einmaligen Korrektur ausgenommen ist.
    static func isExcludedFromNormalization(_ window: NSWindow) -> Bool {
        userResizedWindows.contains(ObjectIdentifier(window))
    }

    /// Nur für Tests: setzt die vorgemerkten Fenster zurück.
    static func resetUserResizesForTesting() {
        userResizedWindows.removeAll()
    }

    /// - Parameter remainingAttempts: Beim Start kann noch kein Fenster
    ///   sichtbar sein; dann wird kurz erneut nachgesehen, statt die einmalige
    ///   Korrektur ungenutzt zu verbrauchen.
    @discardableResult
    static func runOnce(defaults: UserDefaults, remainingAttempts: Int = 20) -> Bool {
        guard !defaults.bool(forKey: defaultsKey) else { return false }
        let windows = DocumentWindowController.visibleDocumentWindows()
        guard !windows.isEmpty else {
            guard remainingAttempts > 0 else { return false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                runOnce(defaults: defaults,
                        remainingAttempts: remainingAttempts - 1)
            }
            return false
        }
        defaults.set(true, forKey: defaultsKey)
        for window in windows {
            // Vollbild und Symbolfenster haben keinen sinnvollen Rahmen.
            // Ein während der Wiederherstellung selbst gezogenes Fenster
            // bleibt unangetastet.
            guard !window.styleMask.contains(.fullScreen),
                  !window.isMiniaturized,
                  !isExcludedFromNormalization(window),
                  let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
                continue
            }
            let normalized = MainWindowSizing.heightNormalizedFrame(
                window.frame, inVisibleScreen: visible
            )
            guard normalized != window.frame else { continue }
            window.setFrame(normalized, display: true)
        }
        stopObservingUserResizes()
        return true
    }
}
