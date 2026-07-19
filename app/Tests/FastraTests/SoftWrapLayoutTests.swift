import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Testing
@testable import Fastra

@Suite("Soft-Wrap-Umbruchziele")
struct SoftWrapLayoutTests {
    @MainActor
    private func controller(
        text: String = String(repeating: "wort ", count: 100),
        column: Int? = 40,
        guideColumn: Int = 40,
        fontSize: CGFloat = 13,
        width: CGFloat = 900
    ) -> TextViewController {
        let configuration = SourceEditorConfiguration(
            appearance: .init(
                theme: EditorView.fastraTheme,
                font: .monospacedSystemFont(ofSize: fontSize, weight: .regular),
                wrapLines: true,
                tabWidth: 4
            ),
            behavior: .init(
                reformatAtColumn: guideColumn,
                wrapAtColumn: column
            ),
            peripherals: .init(
                showMinimap: false,
                showReformattingGuide: true
            )
        )
        let result = TextViewController(
            string: text,
            language: .default,
            configuration: configuration,
            cursorPositions: []
        )
        result.loadView()
        result.view.frame = CGRect(x: 0, y: 0, width: width, height: 500)
        result.view.layoutSubtreeIfNeeded()
        result.textView.layoutManager.layoutLines()
        return result
    }

    @Test("Feste Spalte begrenzt den echten Layout-Manager")
    @MainActor
    func fixedColumnControlsRealLayoutWidth() throws {
        let editor = controller()
        let maximum = try #require(
            editor.textView.layoutManager.maximumWrapWidth
        )
        #expect(abs(editor.textView.layoutManager.maxLineLayoutWidth - maximum) < 0.5)
        #expect(editor.textView.layoutManager.lineStorage.first?.data.lineFragments.count ?? 0 > 1)
    }

    @Test("Fensterbreite bleibt Obergrenze eines breiteren Spaltenziels")
    @MainActor
    func viewportRemainsUpperBound() throws {
        let editor = controller(column: 120, width: 260)
        let configured = try #require(
            editor.textView.layoutManager.maximumWrapWidth
        )
        #expect(editor.textView.layoutManager.maxLineLayoutWidth < configured)
        #expect(editor.textView.layoutManager.maxLineLayoutWidth > 0)
    }

    @Test("Seitenlinie und Umbruch verwenden mit Gutter exakt dieselbe Spalte")
    @MainActor
    func guideAndWrapShareGeometry() throws {
        let editor = controller()
        let guide = try #require(findGuide(in: editor.view))
        let textOrigin = editor.textView.layoutManager.edgeInsets.left
        let wrapWidth = try #require(
            editor.textView.layoutManager.maximumWrapWidth
        )
        #expect(!guide.isHidden)
        #expect(textOrigin > 0)
        #expect(abs((guide.frame.minX - textOrigin) - wrapWidth) < 1.1)
    }

    @Test("Versetzte Seitenlinie zeichnet in ihren lokalen Bounds sichtbar")
    @MainActor
    func guideDrawsInsideItsOwnBounds() throws {
        let editor = controller()
        let guide = try #require(findGuide(in: editor.view))
        #expect(guide.frame.minX > 0)
        let rect = NSRect(
            x: 0, y: 0,
            width: min(guide.bounds.width, 40),
            height: min(guide.bounds.height, 40)
        )
        let bitmap = try #require(
            guide.bitmapImageRepForCachingDisplay(in: rect)
        )
        guide.cacheDisplay(in: rect, to: bitmap)
        let hasDrawnPixel = (0..<bitmap.pixelsWide).contains { x in
            (0..<bitmap.pixelsHigh).contains { y in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0
            }
        }
        #expect(hasDrawnPixel)
    }

    @Test("Fontwechsel skaliert Umbruch und Seitenlinie gemeinsam")
    @MainActor
    func fontChangeUpdatesBothGeometries() throws {
        let editor = controller()
        let oldWidth = try #require(
            editor.textView.layoutManager.maximumWrapWidth
        )
        var changed = editor.configuration
        changed.appearance.font =
            .monospacedSystemFont(ofSize: 20, weight: .regular)
        editor.configuration = changed
        editor.view.layoutSubtreeIfNeeded()

        let newWidth = try #require(
            editor.textView.layoutManager.maximumWrapWidth
        )
        let guide = try #require(findGuide(in: editor.view))
        let textOrigin = editor.textView.layoutManager.edgeInsets.left
        #expect(newWidth > oldWidth)
        #expect(abs((guide.frame.minX - textOrigin) - newWidth) < 1.1)
    }

    @Test("Extrem schmale Breite macht bei Unicode mindestens ein Graphem Fortschritt")
    @MainActor
    func narrowUnicodeAlwaysAdvances() throws {
        let storage = NSTextStorage(
            string: "👨‍👩‍👧‍👦abc",
            attributes: [.font: NSFont.monospacedSystemFont(
                ofSize: 13, weight: .regular
            )]
        )
        let delegate = NarrowLayoutDelegate()
        let manager = TextLayoutManager(
            textStorage: storage,
            lineHeightMultiplier: 1.2,
            wrapLines: true,
            textView: NSView(),
            delegate: delegate
        )
        manager.layoutLines()
        let fragments = try #require(manager.lineStorage.first?.data.lineFragments)
        #expect(fragments.count > 1)
        #expect(fragments.allSatisfy { $0.range.length > 0 })
        #expect(fragments.reduce(0) { $0 + $1.range.length } == storage.length)
    }

    @MainActor
    private func findGuide(in root: NSView) -> NSView? {
        if String(describing: type(of: root)).contains("ReformattingGuideView") {
            return root
        }
        for child in root.subviews {
            if let found = findGuide(in: child) { return found }
        }
        return nil
    }
}

private final class NarrowLayoutDelegate: TextLayoutManagerDelegate {
    var visibleRect = NSRect(x: 0, y: 0, width: 1, height: 500)

    func layoutManagerHeightDidUpdate(newHeight: CGFloat) {}
    func layoutManagerMaxWidthDidChange(newWidth: CGFloat) {}
    func layoutManagerYAdjustment(_ yAdjustment: CGFloat) {}
    func textViewportSize() -> CGSize { CGSize(width: 1, height: 500) }
    func layoutManagerTypingAttributes() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]
    }
}
