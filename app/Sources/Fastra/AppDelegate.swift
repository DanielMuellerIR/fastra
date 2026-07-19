import AppKit
import Foundation
import CodeEditTextView
import Sparkle

/// Notifications, die AppDelegate beim Drücken globaler Shortcuts postet.
/// Die SwiftUI-Schicht (`ContentView`) abonniert sie und aktualisiert den
/// `Workspace`-State.
extension Notification.Name {
    /// CMD+F — Suchmaske öffnen im Datei-Modus.
    static let fastraShowSearchFile   = Notification.Name("fastra.show.search.file")
    /// CMD+SHIFT+F — Suchmaske öffnen im Ordner-Modus.
    static let fastraShowSearchFolder = Notification.Name("fastra.show.search.folder")
    /// ESC im Suchfenster — Suchmaske ausblenden.
    static let fastraHideSearch       = Notification.Name("fastra.hide.search")
    /// CMD+G — zum nächsten Treffer springen.
    static let fastraGotoNextMatch    = Notification.Name("fastra.goto.next.match")
    /// CMD+SHIFT+G — zum vorigen Treffer springen.
    static let fastraGotoPreviousMatch = Notification.Name("fastra.goto.previous.match")
    /// Return im Suchfeld — zum ersten Treffer springen.
    static let fastraGotoFirstMatch   = Notification.Name("fastra.goto.first.match")
    /// Editor des in `object` enthaltenen Workspace soll zur Range springen.
    /// Die explizite Zieladresse ist bei mehreren Dokumentfenstern zwingend:
    /// eine app-weite Notification ohne Workspace ließe alle Editoren reagieren.
    static let fastraJumpToRange      = Notification.Name("fastra.jump.to.range")
    /// CMD+J — Zu-Zeile-Springen-Dialog öffnen.
    static let fastraShowGotoLine     = Notification.Name("fastra.show.goto.line")
    /// Workspace ist initialisiert (`Workspace.shared` steht) — AppDelegate
    /// darf jetzt per Finder/CLI gepufferte Open-URLs ausliefern (K1).
    static let fastraWorkspaceReady   = Notification.Name("fastra.workspace.ready")

    /// Menüleisten-„Text"-Operation: `object` = `TextOpKind.rawValue` (Int).
    /// Der AppDelegate wendet sie auf den aktiven Editor an (EditorContextMenu).
    static let fastraTextOp           = Notification.Name("fastra.text.op")
    /// Menüleisten-Formatierung. Der Editor-Kontext führt sie über seine
    /// native TextView aus, damit sie mit ⌘Z rückgängig gemacht werden kann.
    static let fastraFormatDocument   = Notification.Name("fastra.format.document")
    /// „Text → Dokument prüfen" (Etappe 6): JSON/XML validieren.
    static let fastraLintDocument     = Notification.Name("fastra.lint.document")
    /// „Text → Dokument minifizieren" (Etappe 6): JSON kompakt, XML konservativ.
    static let fastraMinifyDocument   = Notification.Name("fastra.minify.document")
}

/// Autosave-Name unseres Suchfensters. Konstant gehalten an einer
/// Stelle, damit AppDelegate und SearchPanelController denselben Wert
/// kennen.
enum SearchWindow {
    static let frameAutosaveName = "Fastra.SearchWindow"
    static let identifier = NSUserInterfaceItemIdentifier("Fastra.SearchWindow")

    /// Der Autosave-Name ist bei mehreren gleichzeitigen Suchfenstern nicht
    /// eindeutig verfügbar: AppKit akzeptiert ihn nur für eine Instanz. Die
    /// feste Fenster-ID klassifiziert deshalb auch den zweiten Dialog sicher.
    static func isSearchWindow(_ window: NSWindow) -> Bool {
        window.identifier == identifier
            || window.frameAutosaveName == frameAutosaveName
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Sparkle verwaltet Suche, Download, Signaturprüfung, Austausch der App
    /// und Neustart. Der Controller lebt exakt einmal für die App-Laufzeit.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    /// SwiftUI baut das App-Menü nach `applicationDidFinishLaunching` noch
    /// einmal neu. Mehrere Menü-Notifications werden in einen Main-Runloop-
    /// Durchlauf zusammengefasst, damit der Sparkle-Eintrag danach erhalten bleibt.
    private var updateMenuInstallScheduled = false
    /// Gleiches Coalescing für den checkbaren Soft-Wrap-Menüpunkt.
    private var softWrapMenuSyncScheduled = false

    /// Hält den Local-Event-Monitor am Leben — sonst wird er deinitialisiert.
    private var keyMonitor: Any?
    /// Monitor auf Modifier-Änderungen — siehe installFlagsMonitor.
    private var flagsMonitor: Any?
    /// Rechtsklick-Menü des Editors (Zeilen sortieren, Duplikate,
    /// Smart-Paste) — eigener Monitor, siehe EditorContextMenu.swift.
    private let editorContextMenu = EditorContextMenu()
    /// Alt-Doppelklick „Gehe zum Ziel" (Etappe 7 Wunschpaket 2026-07c).
    private let goToTargetGesture = GoToTargetGesture()

    /// Eingangskorb für Dateien, die per Finder-Doppelklick / `open -a`
    /// hereinkommen (K1). Puffert beim Kaltstart, bis der Workspace bereit
    /// ist — siehe `OpenFilesInbox` und `deliverPendingOpenFiles`.
    private var openFilesInbox = OpenFilesInbox()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Erscheinungsbild anwenden (Einstellungen → Erscheinungsbild):
        // automatisch dem System folgen oder manuell Hell/Dunkel. Ersetzt das
        // v1.0-Erzwingen von .aqua — damals hatten alle Theme-Farben feste
        // helle Werte und der System-Dark-Mode erzeugte weiß-auf-weiß. Seit
        // v1.1 sind alle `Theme`-Tokens dynamisch (hell + dunkel), ein echtes
        // Dark-Theme existiert (Theme.swift, EditorView.fastraThemeDark).
        AppearanceSetting.current().apply()
        NSWindow.allowsAutomaticWindowTabbing = false
        installKeyMonitor()
        installFlagsMonitor()
        editorContextMenu.install()
        goToTargetGesture.install()
        // SwiftUI hat die App-Menüleiste erst nach dem Scene-Aufbau vollständig
        // erzeugt. Die Synchronisierung läuft deshalb im nächsten Main-Runloop
        // und erneut, wenn SwiftUI später Menüpunkte ergänzt oder ersetzt.
        scheduleUpdateMenuInstallation()
        // Donation-Logik: App-Starts zählen (nur echte Starts — Selbsttest-
        // Läufe nutzen die isolierte Defaults-Suite und verfälschen den
        // Zähler des Nutzers nicht).
        DonationPrompt.recordLaunch(defaults: SelfTest.workspaceDefaults())
        SelfTest.runIfRequested()

        // Sobald der Workspace bereit ist (Notification aus `Workspace.init`),
        // beim Kaltstart gepufferte Finder-/CLI-Open-URLs ausliefern (K1).
        // codereview-ok: AppDelegate ist App-Lebenszeit-Singleton, Closure nutzt [weak self], Observer wird bei Prozess-Ende abgeräumt — kein Leak (2026-07-01)
        NotificationCenter.default.addObserver(
            forName: .fastraWorkspaceReady,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.deliverPendingOpenFiles()
        }

        // Menüleisten-„Text"-Operationen (BBEdit-Basics) auf den aktiven Editor
        // anwenden. Der Rechtsklick-Pfad nutzt dieselbe Logik im EditorContextMenu.
        NotificationCenter.default.addObserver(
            forName: .fastraTextOp,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.object as? Int,
                  let kind = TextOpKind(rawValue: raw) else { return }
            self?.editorContextMenu.applyToActiveEditor(kind)
        }
        NotificationCenter.default.addObserver(
            forName: .fastraFormatDocument,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.editorContextMenu.formatActiveDocument()
        }
        // Markdown-Formatbefehle (Etappe 5 Wunschpaket 2026-07b) aus
        // Menüleiste und Toolbar auf den aktiven Editor anwenden.
        NotificationCenter.default.addObserver(
            forName: .fastraMarkdownFormat,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.object as? Int,
                  let command = MarkdownFormatCommand(rawValue: raw) else { return }
            self?.editorContextMenu.applyMarkdownFormatToActiveEditor(command)
        }
        NotificationCenter.default.addObserver(
            forName: .fastraLintDocument,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.editorContextMenu.lintActiveDocument()
        }
        NotificationCenter.default.addObserver(
            forName: .fastraMinifyDocument,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.editorContextMenu.minifyActiveDocument()
        }
        NotificationCenter.default.addObserver(
            forName: .fastraReplaceConflictText,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let request = note.object as? ConflictEditorReplacementRequest else { return }
            self?.editorContextMenu.replaceConflictText(request)
        }

        // WICHTIG (Zombie-Find-Bar): CodeEditSourceEditor installiert beim
        // Laden seines Editors einen EIGENEN lokalen keyDown-Monitor, der
        // CMD+F abfängt und sein internes Find-Panel zeigt (siehe
        // TextViewController.handleCommand). Lokale Monitore werden in
        // umgekehrter Reihenfolge der Registrierung aufgerufen — der zuletzt
        // hinzugefügte zuerst. Da der Editor SPÄTER lädt als unser Monitor
        // aus `applicationDidFinishLaunching`, gewann bisher der Editor.
        //
        // Lösung: unseren Monitor neu installieren, sobald ein Fenster Key
        // wird (da ist der Editor längst geladen) — dann ist UNSER Monitor
        // der neueste und fängt CMD+F zuerst ab. Zusätzlich (Gürtel +
        // Hosenträger) schalten wir den NSTextView-Find-Bar aus.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.installKeyMonitor()
            if let window = note.object as? NSWindow {
                // Dokument-, Such- und Vorschaufenster sind ihrem Workspace
                // zentral zugeordnet. So routen alle globalen Commands nach
                // JEDEM Fokuswechsel in das richtige Dokument.
                if let workspace = WorkspaceWindowRegistry.workspace(for: window) {
                    Workspace.shared = workspace
                }
                if let root = window.contentView {
                    Self.disableFindBars(in: root)
                }
            }
        }
        // Schließt der Nutzer das vorderste oder letzte Dokumentfenster,
        // darf der globale Soft-Wrap-Menüpunkt keinen alten Tab behalten.
        // Nach AppKits Schließdurchlauf wählen wir das nächste sichtbare
        // Dokument oder einen stabilen „kein Dokument"-Zustand.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow,
                  !SearchWindow.isSearchWindow(window),
                  let closingWorkspace = WorkspaceWindowRegistry.workspace(for: window),
                  Workspace.shared === closingWorkspace else { return }
            DispatchQueue.main.async {
                Workspace.shared = DocumentWindowController.frontmostVisibleWorkspace()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .fastraActiveDocumentContextChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleSoftWrapMenuSynchronization()
        }
        // Auch bei App-Aktivierung neu installieren (App-Wechsel zurück).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.installKeyMonitor()
            GitAutoFetchController.shared.setActive(true)
            // Extern-Änderungs-Erkennung (BBEdit „Automatically refresh
            // documents", Kap. 3 S. 59): beim Zurückwechseln in die App alle
            // offenen Tabs gegen die Platte prüfen — sauber → still neu
            // laden, dirty → Rückfrage. Der dominante Fall „woanders
            // editiert" ist genau dieser App-Wechsel.
            // Bei mehreren Dokumentfenstern jede Datei prüfen, nicht nur den
            // Workspace des vordersten Fensters.
            Workspace.allLive.forEach { $0.checkExternalChanges() }
            // Gleicher Anlass, gleiche Geste (Etappe 2): der Git-Status kann
            // sich außerhalb geändert haben (Terminal-Commit, Branch-Wechsel).
            // Beim Zurückwechseln still auffrischen.
            Workspace.allLive.forEach { $0.refreshGitStatus() }
            Workspace.allLive.forEach { $0.refreshGitIdentity(force: true) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            GitAutoFetchController.shared.setActive(false)
        }
        NotificationCenter.default.addObserver(
            forName: .fastraGitPreferencesChanged,
            object: nil,
            queue: .main
        ) { _ in
            GitAutoFetchController.shared.preferencesDidChange()
        }

        // Hinweis zum Zombie-Find-Bar: Der Editor (CodeEditSourceEditor) hat
        // einen EIGENEN CMD+F-Monitor, der bei fokussiertem Editor sein Find-
        // Panel öffnet. Die Reihenfolge konkurrierender NSEvent-Monitore ist
        // NICHT zuverlässig steuerbar — deshalb verlassen wir uns NICHT aufs
        // „Gewinnen" des Monitors, sondern schließen ein doch geöffnetes
        // Editor-Find-Panel deterministisch wieder (siehe EditorView:
        // onChange(of: editorState.findPanelVisible)). Unser Monitor hier
        // deckt CMD+F bei NICHT fokussiertem Editor sowie CMD+SHIFT+F/ESC ab.

        // Standard-Find-Menüpunkte aus der Edit-Menü-Hierarchie löschen.
        // SwiftUIs `CommandGroup(replacing: .textEditing)` reicht nicht,
        // weil das Find-Untermenü von AppKit direkt eingehängt wird.
        // Wir warten kurz, bis das Menü gebaut ist, und entfernen
        // dann die Items mit dem find-bezogenen Action-Selektor.
        DispatchQueue.main.async {
            Self.purgeFindMenuItems()
        }
        // Manche AppKit-Wege bauen die Find-Items asynchron wieder ein
        // (z.B. wenn der erste NSTextView in den Fokus kommt). Daher
        // zusätzlich nach NSMenu.didChange entfernen.
        NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Self.purgeFindMenuItems()
            self?.scheduleUpdateMenuInstallation()
            self?.scheduleSoftWrapMenuSynchronization()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Beim ersten Aktivieren ist der SwiftUI-Menüaufbau sicher abgeschlossen.
        // Spätere Aktivierungen reparieren einen von macOS neu aufgebauten Block.
        scheduleUpdateMenuInstallation()
        scheduleSoftWrapMenuSynchronization()
    }

    /// Baut den nativen Update-Menüpunkt. Sparkle selbst bleibt das Target,
    /// damit es den Eintrag während Suche und Installation korrekt validiert.
    static func makeUpdateMenuItem(target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(
            title: L10n.string("Nach Updates suchen …"),
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        item.identifier = NSUserInterfaceItemIdentifier("Fastra.CheckForUpdates")
        item.target = target
        return item
    }

    /// Fügt den Eintrag idempotent in ein fertiges App-Menü ein. Diese getrennte
    /// Funktion macht auch den Wiederaufbau durch SwiftUI direkt testbar.
    @discardableResult
    static func synchronizeUpdateMenuItem(
        in appMenu: NSMenu,
        target: AnyObject
    ) -> NSMenuItem {
        let identifier = NSUserInterfaceItemIdentifier("Fastra.CheckForUpdates")
        if let existing = appMenu.items.first(where: { $0.identifier == identifier }) {
            existing.target = target
            existing.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
            return existing
        }

        let item = Self.makeUpdateMenuItem(target: target)
        // Das erste Trennzeichen folgt im Standard-App-Menü direkt auf den
        // Info-Block. Ohne Trennzeichen bleibt ein sicherer append-Fallback.
        if let separatorIndex = appMenu.items.firstIndex(where: \.isSeparatorItem) {
            appMenu.insertItem(item, at: separatorIndex)
        } else {
            appMenu.addItem(item)
        }
        return item
    }

    private func scheduleUpdateMenuInstallation() {
        guard !updateMenuInstallScheduled else { return }
        updateMenuInstallScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateMenuInstallScheduled = false
            guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
            Self.synchronizeUpdateMenuItem(in: appMenu, target: self.updaterController)
        }
    }

    private func scheduleSoftWrapMenuSynchronization() {
        guard !softWrapMenuSyncScheduled else { return }
        softWrapMenuSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.softWrapMenuSyncScheduled = false
            guard let mainMenu = NSApp.mainMenu else { return }
            _ = Self.synchronizeSoftWrapMenuState(
                in: mainMenu,
                isOn: ActiveDocumentContext.shared.workspace?.softWrapEnabled ?? false,
                hasDocument: ActiveDocumentContext.shared.workspace?.activeTab != nil
            )
        }
    }

    /// SwiftUI-`Toggle`-Commands behalten bei einem Formatwechsel den alten
    /// Haken, bis SwiftUI die Commands-Struktur neu baut. Ein normaler Button
    /// mit nativ gesetztem `state` ist deterministisch und behält zugleich
    /// SwiftUIs Action/Shortcut. Rekursiv, weil „Darstellung" ein Submenü ist.
    @discardableResult
    static func synchronizeSoftWrapMenuState(
        in menu: NSMenu,
        isOn: Bool,
        hasDocument: Bool
    ) -> NSMenuItem? {
        for item in menu.items {
            if item.title == L10n.string("Soft Wrap") {
                item.state = isOn ? .on : .off
                item.isEnabled = hasDocument
                return item
            }
            if let submenu = item.submenu,
               let found = synchronizeSoftWrapMenuState(
                   in: submenu, isOn: isOn, hasDocument: hasDocument
               ) {
                return found
            }
        }
        return nil
    }

    /// Entfernt alle find-bezogenen Menüpunkte (Selektoren
    /// `performFindPanelAction:` und `performTextFinderAction:`)
    /// aus der gesamten Menüleiste. Auch das Find-Untermenü selbst
    /// wird gelöscht, wenn es leer wird.
    private static func purgeFindMenuItems() {
        guard let main = NSApp.mainMenu else { return }
        purge(menu: main)
    }

    /// Action-Selektoren, die eine NSTextView-Find-Leiste / das Find-Panel
    /// auslösen. An EINER Stelle definiert, damit Menü-Purge und Tests
    /// dieselbe Liste nutzen.
    static let findMenuSelectors: Set<Selector> = [
        #selector(NSResponder.performTextFinderAction(_:)),
        Selector(("performFindPanelAction:"))
    ]

    /// `true`, wenn ein Menüpunkt eine find-bezogene Aktion auslöst.
    static func isFindRelated(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        return findMenuSelectors.contains(action)
    }

    static func purge(menu: NSMenu) {
        // Erst Submenüs säubern (rekursiv).
        for item in menu.items {
            if let sub = item.submenu {
                purge(menu: sub)
            }
        }
        // Items entfernen, deren Selector find-bezogen ist.
        menu.items
            .filter { isFindRelated($0) }
            .forEach { menu.removeItem($0) }

        // Items entfernen, deren Submenu nur noch find-bezogene
        // Einträge hatte und jetzt leer ist (z.B. "Find"-Submenu).
        menu.items
            .filter { item in
                guard let sub = item.submenu else { return false }
                let titleLower = item.title.lowercased()
                return sub.items.isEmpty
                    && (titleLower == "find" || titleLower == "suchen"
                        || titleLower == "finden")
            }
            .forEach { menu.removeItem($0) }
    }

    /// Rekursiv jede NSTextView in `view` finden und ihren Find-Bar
    /// abschalten — damit CMD+F dort nicht mehr konsumiert wird.
    @discardableResult
    static func disableFindBars(in view: NSView) -> Int {
        var count = 0
        if let textView = view as? NSTextView {
            textView.usesFindBar = false
            textView.usesFindPanel = false
            count += 1
        }
        for sub in view.subviews {
            count += disableFindBars(in: sub)
        }
        return count
    }

    /// Default (Daniel 2026-07-12): Nach dem Schließen des letzten Fensters
    /// bleibt die App AKTIV — Fenster-schließen ≠ App-beenden. Fortgeschrittene
    /// Nutzer wollen oft die letzte Datei schließen und dann eine neue öffnen,
    /// ohne die App neu zu starten. Über UserDefaults „app.quitOnLastWindowClose"
    /// umschaltbar (später als Einstellungs-Dialog-Option); unbelegt = false =
    /// aktiv bleiben.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        UserDefaults.standard.bool(forKey: "app.quitOnLastWindowClose")
    }

    /// Klick aufs Dock-Icon (oder Reopen), wenn kein Fenster offen ist: ein
    /// neues, leeres Dokumentfenster öffnen — sonst wäre die aktive App ohne
    /// Fenster nicht mehr bedienbar (Gegenstück zum „nicht beenden"-Default).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            DocumentWindowController.openNewDocument()
        }
        return true
    }

    /// ⌘Q / „Beenden": Bevor die App endet, bei ungespeicherten Änderungen
    /// nachfragen (BBEdit-Stil: Sichern / Nicht sichern / Abbrechen) — sonst gingen
    /// getippte Inhalte stillschweigend verloren (Daniel-Befund 2026-06-25). Die
    /// eigentliche Rückfrage-Logik liegt im Workspace (geteilt mit dem Tab-Schließen).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Jedes Dokumentfenster besitzt einen eigenen Workspace. Erst beenden,
        // wenn alle ungesicherten Tabs geklärt sind; „Abbrechen" in einem
        // beliebigen Fenster stoppt ⌘Q für die ganze App.
        for workspace in Workspace.allLive {
            guard workspace.confirmCloseAllDirtyForQuit() else { return .terminateCancel }
        }
        return .terminateNow
    }

    // MARK: - Datei-Öffnen von außen (Finder / `open -a Fastra <datei>`)
    //
    // AppKit ruft `application(_:open:)` für Doppelklick im Finder, das
    // Services-Menü und `open -a` auf. Beim KALTEN Start kommt der Aufruf
    // u.U. VOR der Workspace-Erzeugung → puffern und ausliefern, sobald
    // `Workspace.shared` steht (`Workspace.init` ruft `deliverPendingOpenFiles`).

    func application(_ application: NSApplication, open urls: [URL]) {
        // Finder, Dock und `open -a` dürfen Dateien UND Ordner liefern.
        // Ordner werden später über denselben Router als Projekt geladen.
        let openableURLs = DropHandling.openableItems(from: urls)
        guard !openableURLs.isEmpty else { return }
        openFilesInbox.enqueue(openableURLs)
        deliverPendingOpenFiles()
    }

    /// Liefert gepufferte Open-URLs an den Workspace, sofern er schon bereit
    /// ist. Sonst bleiben sie im Puffer und werden vom nächsten Aufruf (aus
    /// `Workspace.init`) ausgeliefert. Idempotent.
    func deliverPendingOpenFiles() {
        guard Workspace.shared != nil else { return }   // noch nicht bereit
        // SwiftUIs Startfenster und seine Registry-Brücke dürfen zunächst
        // ihren aktuellen Main-Loop abschließen. Bei einer bereits laufenden
        // App ist dadurch zugleich sicher erkennbar, ob wirklich kein Fenster
        // mehr sichtbar ist.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let urls = self.openFilesInbox.drain()
            guard !urls.isEmpty else { return }
            let workspace = DocumentWindowController.workspaceForOpening()
            for url in urls {
                workspace.openFileOrFolder(at: url)
            }
        }
    }

    // MARK: - Globale Tastatur-Abkürzungen
    //
    // `CodeEditSourceEditor` installiert beim Laden einen eigenen lokalen
    // keyDown-Monitor, der CMD+F abfängt und sein internes Find-Panel zeigt.
    // Lokale Monitore feuern LIFO (neuester zuerst). Damit UNSER Monitor
    // gewinnt, installieren wir ihn neu, sobald ein Fenster Key wird (siehe
    // applicationDidFinishLaunching) — dann ist er der neueste.
    //
    // Idempotent: ein evtl. vorhandener Monitor wird zuerst entfernt, damit
    // sich bei wiederholtem Aufruf keine Monitore stapeln.

    /// Sobald die Command-Taste gedrückt wird (flagsChanged kommt VOR dem
    /// folgenden F-keyDown), installieren wir unseren keyDown-Monitor neu.
    /// Damit ist er garantiert der neueste, wenn gleich darauf CMD+F kommt,
    /// und fängt es vor dem Editor-eigenen Monitor ab — das Editor-Find-Panel
    /// öffnet gar nicht erst (verhindert das kurze Aufblitzen). Die
    /// Reconciliation in EditorView bleibt als Sicherheitsnetz.
    private func installFlagsMonitor() {
        if let existing = flagsMonitor {
            NSEvent.removeMonitor(existing)
            flagsMonitor = nil
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if event.modifierFlags.contains(.command) {
                self?.installKeyMonitor()
            }
            return event
        }
    }

    private func installKeyMonitor() {
        if let existing = keyMonitor {
            NSEvent.removeMonitor(existing)
            keyMonitor = nil
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Reine `KeyRouting`-Logik (auch in KeyRoutingTests abgedeckt).
            let keyWindow = NSApp.keyWindow
            let isSearchKey = keyWindow.map(SearchWindow.isSearchWindow) ?? false
            let isHelpKey = HelpWindow.isHelpWindow(keyWindow)
            let route = KeyRouting.route(
                isKeyDown: event.type == .keyDown,
                modifierFlags: event.modifierFlags,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                keyCode: event.keyCode,
                isSearchWindowKey: isSearchKey,
                isHelpWindowKey: isHelpKey
            )

            // FN+←/FN+→ (Home/End) sind nur im echten Code-Editor sinnvoll.
            // Suchfelder und andere AppKit-Steuerelemente behalten deshalb ihr
            // normales Verhalten. CodeEditTextView erledigt Auswahl, Cursor-
            // Aktualisierung und Scrollen in seinen vorhandenen Aktionen selbst.
            switch route {
            case .closeHelp:
                MainActor.assumeIsolated { HelpWindow.close() }
                return nil

            case .moveToBeginningOfDocument(let modifySelection):
                guard let textView = NSApp.keyWindow?.firstResponder as? TextView else {
                    return event
                }
                if modifySelection {
                    textView.moveToBeginningOfDocumentAndModifySelection(nil)
                } else {
                    textView.moveToBeginningOfDocument(nil)
                }
                return nil

            case .moveToEndOfDocument(let modifySelection):
                guard let textView = NSApp.keyWindow?.firstResponder as? TextView else {
                    return event
                }
                if modifySelection {
                    textView.moveToEndOfDocumentAndModifySelection(nil)
                } else {
                    textView.moveToEndOfDocument(nil)
                }
                return nil

            default:
                break
            }

            // ⌘V mit Bildinhalt in einem Markdown-Editor (Etappe 5
            // Wunschpaket 2026-07b): Bild als Datei ablegen + verlinken.
            // Bilddaten haben definierten VORRANG vor dem normalen
            // Text-Einfügen; ⌘⇧V bleibt die explizite Rich-Text-
            // Konvertierung (SmartPaste).
            if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "v",
               MainActor.assumeIsolated({ MarkdownAssist.handlePasteCommand() }) {
                return nil     // Event verbraucht — Bild wurde eingefügt
            }

            guard let name = KeyRouting.notificationName(for: route) else {
                return event   // nicht abfangen
            }
            NotificationCenter.default.post(name: name, object: nil)
            return nil         // Event verbrauchen
        }
    }
}
