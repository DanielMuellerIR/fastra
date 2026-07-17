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
}
