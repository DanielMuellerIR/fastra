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
/// es keine laufenden Abonnements auf jede Tab-Änderung. Tauscht SwiftUI
/// oder macOS die Instanz des „Fenster"-Menüs, zieht der `AppDelegate` die
/// Einträge über `synchronizeWithCurrentWindowsMenu` sofort um.
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
    /// Reihenfolge der Einträge, wie sie angelegt wurden. Das Wörterbuch
    /// allein reicht nicht: Swift sichert für `items.values` keine
    /// Reihenfolge zu, und beim Umzug in ein neu aufgebautes Menü standen
    /// die Fenster sonst in zufälliger Folge (Review 2026-09-02).
    private var order: [ObjectIdentifier] = []
    /// Trennlinie unter dem Tab-Abschnitt — nur vorhanden, solange es
    /// mindestens einen Eintrag gibt.
    private var sectionSeparator: NSMenuItem?
    /// Wächter gegen einen Rücksprung mitten im Umzug (siehe
    /// `adoptMenuIfChanged`).
    private var isAdoptingMenu = false

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
        updateItem(for: window, workspace: workspace, title: title, in: menu)
    }

    /// Kern von `updateItem`, mit dem Zielmenü als Parameter — so lässt sich
    /// ein Menü-Neuaufbau ohne `NSApp` im Unit-Test nachstellen.
    func updateItem(for window: NSWindow, workspace: Workspace, title: String,
                    in menu: NSMenu) {
        adoptMenuIfChanged(menu)
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
            order.append(key)
            // Abschnitt am Menüanfang: erst alle Fenster-Einträge, dann die
            // Trennlinie zu AppKits Standardpunkten.
            menu.insertItem(item, at: min(order.count - 1, menu.items.count))
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

    /// Bindet alle verwalteten Einträge an das AKTUELLE „Fenster"-Menü. Der
    /// `AppDelegate` ruft das bei jeder Menüänderung und App-Aktivierung —
    /// den Stellen, an denen SwiftUI oder macOS die Menüinstanz getauscht
    /// haben kann. Vorher zog nur das nächste Titel-Update der
    /// `MainWindowTitleBridge` um, und das kommt nach einem Neuaufbau nicht
    /// garantiert: Bis dahin fehlten alle Tab-Untermenüs, obwohl die
    /// Dokumentfenster offen waren (Review 2026-09-02).
    func synchronizeWithCurrentWindowsMenu() {
        guard let menu = NSApp.windowsMenu else { return }
        adoptMenuIfChanged(menu)
    }

    /// SwiftUI baut das App-Menü nach dem Start noch einmal neu (siehe
    /// `AppDelegate`, Sparkle-/Soft-Wrap-Eintrag). Wechselt dabei die Instanz
    /// des „Fenster"-Menüs, hingen die schon angelegten Einträge am alten,
    /// nicht mehr sichtbaren Menü, und `updateItem` fand sie im Cache und
    /// legte nichts neu an — das Tab-Untermenü war dann vollständig weg
    /// (Review 2026-09-02). Deshalb alle verwalteten Einträge samt Trenner in
    /// das neue Menü umziehen, in der bisherigen Reihenfolge am Anfang.
    ///
    /// Ein Eintrag ohne Menü zählt ebenfalls als umzugspflichtig: Gibt AppKit
    /// das alte Menü frei, steht `menu` an seinen Einträgen auf nil — sie
    /// hängen dann nirgends mehr. Der Abschnitt wird als Ganzes neu gelegt
    /// (erst alle heraus, dann in `order` wieder hinein), damit auch ein halb
    /// umgezogener Zustand — ein Eintrag schon im neuen Menü, die übrigen
    /// noch im alten — in der ursprünglichen Reihenfolge endet. Intern statt
    /// privat, damit der Unit-Test den Neuaufbau ohne Bridge-Update
    /// nachstellen kann.
    func adoptMenuIfChanged(_ menu: NSMenu) {
        let managed = order.compactMap { items[$0] }
        let displaced = managed.contains { $0.menu !== menu }
            || (sectionSeparator.map { $0.menu !== menu } ?? false)
        guard displaced, !isAdoptingMenu else { return }
        // `insertItem` löst `NSMenu.didAddItemNotification` synchron aus;
        // der `AppDelegate` bündelt seine Reaktion zwar per Dispatch, aber
        // der Wächter hält auch einen synchronen Rücksprung mitten im Umzug
        // ab — der würde die restlichen Einträge in eigener Zählung vor die
        // schon umgezogenen setzen.
        isAdoptingMenu = true
        defer { isAdoptingMenu = false }
        for item in managed {
            item.menu?.removeItem(item)
        }
        if let separator = sectionSeparator {
            separator.menu?.removeItem(separator)
        }
        for (position, item) in managed.enumerated() {
            menu.insertItem(item, at: min(position, menu.items.count))
        }
        if let separator = sectionSeparator, !managed.isEmpty {
            menu.insertItem(separator, at: min(managed.count, menu.items.count))
        }
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
        let key = ObjectIdentifier(window)
        guard let item = items.removeValue(forKey: key) else {
            return
        }
        order.removeAll { $0 == key }
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
