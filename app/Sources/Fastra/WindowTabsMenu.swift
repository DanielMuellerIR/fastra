import AppKit

// Tab-Untermenüs im „Fenster"-Menü (Daniel-Wunsch 2026-09-01): pro
// Dokumentfenster ein Eintrag, der als Untermenü alle offenen Tabs des
// Fensters zeigt. Ein Klick holt das Fenster nach vorn und wählt den Tab.
// Das ersetzt die entfernte „GEÖFFNET"-Liste der Seitenleiste — die wuchs
// ungebremst mit jedem Tab und verdrängte am Ende Dateibaum und Tab-Leiste.
//
// Bewusst AppKit statt SwiftUI-Commands: Eine `CommandGroup(before:
// .windowList)` legte in diesem AppKit-verwalteten Fenster-Menü überhaupt
// keine Einträge an (nachgemessen am 2026-09-01 im tabflood-Selbsttest).
// Die App pflegt ihre Fenster-Einträge dort ohnehin schon selbst über
// `NSApp.changeWindowsItem` (siehe `MainWindowTitleBridge`).

/// Reine, unit-testbare Beschriftungslogik — bewusst ohne AppKit-Zustand,
/// damit die Dirty-Markierung ohne Fenster prüfbar bleibt.
enum WindowTabsMenuModel {
    /// Beschriftung einer Tab-Zeile: ungesicherte Tabs tragen denselben
    /// Dirty-Punkt wie die Tab-Leiste.
    static func rowTitle(title: String, hasUnsavedChanges: Bool) -> String {
        hasUnsavedChanges ? title + " •" : title
    }
}

/// Verwaltet die Tab-Untermenü-Einträge am Anfang des „Fenster"-Menüs.
/// Die Einträge selbst entstehen und verschwinden mit ihren Fenstern
/// (`MainWindowTitleBridge` meldet Titel, die Registry das Schließen); ihre
/// Tab-Listen füllen sich erst beim Öffnen über `menuNeedsUpdate` — so gibt
/// es keine laufenden Abonnements auf jede Tab-Änderung.
@MainActor
final class WindowsMenuTabs: NSObject, NSMenuDelegate {
    static let shared = WindowsMenuTabs()

    /// Kontext eines Eintrags. Fenster und Workspace bleiben schwach —
    /// der Menü-Eintrag darf ihr Leben nicht verlängern.
    private final class Context {
        weak var window: NSWindow?
        weak var workspace: Workspace?

        init(window: NSWindow, workspace: Workspace) {
            self.window = window
            self.workspace = workspace
        }
    }

    /// Ziel eines Tab-Punkts. `NSMenuItem` stellt seine Aktion erst nach dem
    /// Menü-Tracking zu; das `representedObject` hält den Kontext so lange.
    private final class TabSelection {
        weak var window: NSWindow?
        weak var workspace: Workspace?
        let tabID: UUID

        init(window: NSWindow?, workspace: Workspace?, tabID: UUID) {
            self.window = window
            self.workspace = workspace
            self.tabID = tabID
        }
    }

    private var items: [ObjectIdentifier: NSMenuItem] = [:]
    /// Trennlinie unter dem Tab-Abschnitt — nur vorhanden, solange es
    /// mindestens einen Eintrag gibt.
    private var sectionSeparator: NSMenuItem?

    /// Legt den Eintrag eines Dokumentfensters an bzw. führt seinen Titel
    /// nach. Aufrufer ist `MainWindowTitleBridge` — dort ist der Titel schon
    /// Willkommens-bewusst („Fastra v… <Datum>" ohne echte Datei).
    func updateItem(for window: NSWindow, workspace: Workspace, title: String) {
        guard let menu = NSApp.windowsMenu else {
            // Beim App-Start (besonders mit Sitzungswiederherstellung)
            // existiert das „Fenster"-Menü noch nicht. Kurz später erneut
            // versuchen — die schwachen Referenzen lassen ein inzwischen
            // geschlossenes Fenster einfach fallen (Daniel-Befund 2026-09-01:
            // ohne diesen Retry blieb der Eintrag in der wiederhergestellten
            // Sitzung dauerhaft aus).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                [weak window, weak workspace] in
                guard let window, let workspace else { return }
                self.updateItem(for: window, workspace: workspace,
                                title: window.title)
            }
            return
        }
        let key = ObjectIdentifier(window)
        let item: NSMenuItem
        if let existing = items[key] {
            item = existing
        } else {
            item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            submenu.delegate = self
            item.submenu = submenu
            items[key] = item
            // Abschnitt am Menüanfang: erst alle Fenster-Einträge, dann die
            // Trennlinie zu AppKits Standardpunkten.
            menu.insertItem(item, at: min(items.count - 1, menu.items.count))
            if sectionSeparator == nil {
                let separator = NSMenuItem.separator()
                sectionSeparator = separator
                menu.insertItem(separator, at: min(items.count, menu.items.count))
            }
        }
        item.representedObject = Context(window: window, workspace: workspace)
        item.title = title
        item.submenu?.title = title
        // Häkchen wie bei AppKits eigenen Fenster-Einträgen: am
        // Schlüsselfenster (unsere Einträge ersetzen die AppKit-Einträge,
        // siehe `isExcludedFromWindowsMenu` in `MainWindowTitleBridge`).
        item.state = window.isKeyWindow ? .on : .off
    }

    /// Führt die Häkchen nach einem Schlüsselfenster-Wechsel nach.
    func noteKeyWindowChanged() {
        for item in items.values {
            guard let context = item.representedObject as? Context else { continue }
            item.state = context.window?.isKeyWindow == true ? .on : .off
        }
    }

    /// Entfernt den Eintrag eines geschlossenen Fensters (Aufrufer:
    /// `WorkspaceWindowRegistry.unregister`).
    func removeItem(for window: NSWindow) {
        guard let item = items.removeValue(forKey: ObjectIdentifier(window)) else {
            return
        }
        item.menu?.removeItem(item)
        if items.isEmpty, let separator = sectionSeparator {
            separator.menu?.removeItem(separator)
            sectionSeparator = nil
        }
    }

    /// Füllt ein Tab-Untermenü beim Öffnen mit dem AKTUELLEN Tab-Stand.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let context = items.values
                .first(where: { $0.submenu === menu })?
                .representedObject as? Context,
              let workspace = context.workspace,
              !workspace.tabs.isEmpty else {
            let empty = NSMenuItem(title: L10n.string("(keine Tabs)"),
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for tab in workspace.tabs {
            let item = NSMenuItem(
                title: WindowTabsMenuModel.rowTitle(
                    title: tab.title,
                    hasUnsavedChanges: tab.hasUnsavedChanges
                ),
                action: #selector(selectTab(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.state = tab.id == workspace.activeTab?.id ? .on : .off
            item.representedObject = TabSelection(window: context.window,
                                                  workspace: workspace,
                                                  tabID: tab.id)
            menu.addItem(item)
        }
    }

    @objc private func selectTab(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? TabSelection,
              let workspace = selection.workspace else { return }
        // Erst das Fenster nach vorn, dann den Tab wählen — die Reihenfolge
        // hält `Workspace.shared` und Fensterfokus konsistent (siehe
        // `MainWindowTitleBridge`).
        selection.window?.makeKeyAndOrderFront(nil)
        workspace.selectTab(id: selection.tabID)
    }
}
