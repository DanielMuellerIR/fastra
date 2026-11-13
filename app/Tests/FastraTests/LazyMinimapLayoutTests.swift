import AppKit
@testable import CodeEditSourceEditor
import CodeEditTextView
import Testing
@testable import Fastra

@Suite("Minimap für große Zeilen", .serialized)
struct LazyMinimapLayoutTests {
    @Test("Ein unveränderter ungebrochener Minimap-Text behält seinen Layoutcache")
    @MainActor
    func unwrappedMinimapKeepsCachedFragmentsAndDraws() throws {
        let payload = String(repeating: "A7+/qZ09_-?mN4xB", count: 64 * 1024)
        let configuration = SourceEditorConfiguration(
            appearance: .init(theme: EditorView.fastraTheme,
                              font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                              wrapLines: false, tabWidth: 4),
            peripherals: .init(showMinimap: true)
        )
        let controller = TextViewController(string: payload, language: .default,
                                            configuration: configuration, cursorPositions: [])
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        let mini = try #require(controller.minimapView)
        mini.isHidden = false
        mini.contentView.needsLayout = true
        mini.contentView.layoutSubtreeIfNeeded()
        let firstViews = mini.contentView.subviews.compactMap { $0 as? LineFragmentView }
        let first = try #require(firstViews.compactMap(\.lineFragment).first)
        let id = first.id
        #expect(first.contents.count > 1, "Die Fixture muss mehrere interne Textportionen haben")
        #expect(first.contents.allSatisfy { $0.fastraIsText })
        mini.contentView.needsLayout = true
        mini.contentView.layoutSubtreeIfNeeded()
        let second = try #require(mini.contentView.subviews.compactMap { $0 as? LineFragmentView }.compactMap(\.lineFragment).first)
        #expect(second.id == id,
                "Ein unveraenderter Minimap-Durchlauf darf die Megazeile nicht neu layouten")
        let visible = mini.contentView.visibleRect
        #expect(visible.width > 0 && visible.height > 0)
        let image = try #require(mini.contentView.bitmapImageRepForCachingDisplay(in: visible))
        mini.contentView.cacheDisplay(in: visible, to: image)
        #expect(image.pixelsWide > 0)
    }
}
