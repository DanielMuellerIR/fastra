import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import Testing
@testable import Fastra

@Suite("Initiales Minimap-Layout")
struct MinimapLayoutTests {
    @Test("Sichtbare Minimap reserviert ihre vollständige Breite")
    func visibleMinimapUsesFrameWidth() {
        #expect(MinimapLayout.trailingInset(isHidden: false, frameWidth: 140) == 140)
    }

    @Test("Ausgeblendete Minimap reserviert keinen Platz")
    func hiddenMinimapUsesNoWidth() {
        #expect(MinimapLayout.trailingInset(isHidden: true, frameWidth: 140) == 0)
    }

    @Test("Coordinator übernimmt die echte Minimap-Breite in den Editor")
    @MainActor
    func coordinatorSynchronizesRealController() {
        let configuration = SourceEditorConfiguration(
            appearance: .init(theme: EditorView.fastraThemeDark,
                              font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                              wrapLines: true,
                              tabWidth: 4),
            peripherals: .init(showMinimap: true)
        )
        let controller = TextViewController(
            string: "Ein ausreichend langer Testtext für den Umbruch",
            language: .default,
            configuration: configuration,
            cursorPositions: []
        )
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        controller.view.layoutSubtreeIfNeeded()

        let coordinator = MinimapLayoutCoordinator()
        #expect(coordinator.synchronize(controller: controller))
        #expect(controller.textView.textInsets.right > 0)
    }
}
