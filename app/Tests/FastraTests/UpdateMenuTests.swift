import AppKit
import Sparkle
import Testing
@testable import Fastra

@Suite("Sparkle-Update-Menü")
struct UpdateMenuTests {
    @Test("Menüpunkt behält Sparkle als Target und Action")
    func nativeMenuItemWiring() {
        let target = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        let item = AppDelegate.makeUpdateMenuItem(target: target)

        #expect(item.title == L10n.string("Nach Updates suchen …"))
        #expect(item.action == #selector(SPUStandardUpdaterController.checkForUpdates(_:)))
        #expect(item.target === target)
        #expect(item.identifier?.rawValue == "Fastra.CheckForUpdates")
    }

    @Test("Menü-Wiederaufbau erzeugt keinen doppelten Eintrag")
    func menuSynchronizationIsIdempotent() {
        let target = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Über Fastra", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let first = AppDelegate.synchronizeUpdateMenuItem(in: menu, target: target)
        let second = AppDelegate.synchronizeUpdateMenuItem(in: menu, target: target)
        let updateItems = menu.items.filter {
            $0.identifier?.rawValue == "Fastra.CheckForUpdates"
        }

        #expect(first === second)
        #expect(updateItems.count == 1)
        #expect(menu.index(of: first) == 1)
        #expect(first.target === target)
    }

    @Test("Soft-Wrap-Menüstatus wird rekursiv und dokumentabhängig synchronisiert")
    func softWrapMenuSynchronization() throws {
        let root = NSMenu()
        let viewItem = NSMenuItem(title: "Darstellung", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let wrapItem = NSMenuItem(
            title: L10n.string("Soft Wrap"), action: nil, keyEquivalent: ""
        )
        submenu.addItem(wrapItem)
        root.setSubmenu(submenu, for: viewItem)
        root.addItem(viewItem)

        let found = try #require(AppDelegate.synchronizeSoftWrapMenuState(
            in: root, isOn: true, hasDocument: true
        ))
        #expect(found === wrapItem)
        #expect(found.state == .on)
        #expect(found.isEnabled)

        AppDelegate.synchronizeSoftWrapMenuState(
            in: root, isOn: false, hasDocument: false
        )
        #expect(wrapItem.state == .off)
        #expect(!wrapItem.isEnabled)
    }
}
