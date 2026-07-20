import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
@testable import CodeEditTextView
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

    @Test("Alles auswählen umfasst bei Soft Wrap auch die letzte sichtbare Textzeile")
    @MainActor
    func selectAllIncludesLastVisibleLine() throws {
        let lines = (1...22).map { index in
            index == 22
                ? "Letzte sichtbare Textzeile"
                : "Zeile \(index): " + String(repeating: "Wort ", count: 12)
        }
        for lineEnding in ["\n", "\r\n", "\r"] {
            let editor = controller(
                // Der abschließende Zeilenumbruch erzeugt hinter der letzten
                // Textzeile die übliche leere Dateiende-Zeile.
                text: lines.joined(separator: lineEnding) + lineEnding,
                column: 40,
                width: 900
            )
            editor.view.frame.size.height = 900
            editor.view.layoutSubtreeIfNeeded()
            editor.textView.layoutManager.layoutLines()

            editor.textView.selectAll(nil)

            let documentRange = editor.textView.documentRange
            let lastLine = try #require(
                editor.textView.layoutManager.textLineForOffset(
                    documentRange.length - 1
                )
            )
            let selection = try #require(
                editor.textView.selectionManager.textSelections.first
            )
            let fillRects = editor.textView.selectionManager.getFillRects(
                in: editor.textView.bounds,
                for: selection
            )
            #expect(editor.textView.selectedRange() == documentRange)
            #expect(fillRects.contains {
                $0.width > 1
                    && $0.maxY > lastLine.yPos
                    && $0.minY < lastLine.yPos + lastLine.height
            }, "Zeilenende \(lineEnding.debugDescription)")
        }
    }

    @Test("Alles auswählen endet ohne finalen Umbruch am letzten Zeichen")
    @MainActor
    func selectAllWithoutFinalLineEndingStaysCharacterExact() throws {
        let editor = controller(
            text: "Erste Zeile\nKurzes Ende",
            column: 40,
            width: 900
        )
        editor.view.frame.size.height = 300
        editor.view.layoutSubtreeIfNeeded()
        editor.textView.layoutManager.layoutLines()
        editor.textView.selectAll(nil)

        let lastLine = try #require(
            editor.textView.layoutManager.textLineForOffset(
                editor.textView.documentRange.length
            )
        )
        let selection = try #require(
            editor.textView.selectionManager.textSelections.first
        )
        let finalRect = try #require(
            editor.textView.selectionManager.getFillRects(
                in: editor.textView.bounds,
                for: selection
            ).last(where: {
                $0.maxY > lastLine.yPos
                    && $0.minY < lastLine.yPos + lastLine.height
            })
        )
        let fullLineWidth = editor.textView.layoutManager.wrapLinesWidth
        #expect(finalRect.width > 1)
        #expect(finalRect.width < fullLineWidth - 1)
    }

    @Test("Zeilen verbinden und Undo halten Text und Layout sichtbar")
    @MainActor
    func joinLinesAndUndoKeepTextVisible() throws {
        let original = (1...94).map { index in
            if index == 1 { return "# AGENTS.md — Testdokument" }
            if index == 5 { return "## Abschnitt" }
            return index.isMultiple(of: 7)
                ? ""
                : "Zeile \(index): " + String(repeating: "Inhalt ", count: 8)
        }.joined(separator: "\n") + "\n"
        let editor = controller(
            text: original,
            column: 40,
            width: 900
        )
        let originalCursor = NSRange(
            location: (original as NSString).length,
            length: 0
        )
        editor.textView.selectionManager.setSelectedRange(
            originalCursor
        )
        let result = try #require(
            TextOperations.joinLines(
                in: original,
                selection: originalCursor
            )
        )

        editor.textView.fastraApplyTextOperation(
            replacing: result.affectedRange,
            with: result.newText
        )
        editor.view.layoutSubtreeIfNeeded()
        editor.textView.layoutManager.layoutLines()

        #expect(editor.textView.string == result.newText)
        #expect(hasVisibleTextFragment(editor))
        #expect(editor.textView.selectedRange() == NSRange(location: 0, length: 0))

        editor.textView.undoManager?.undo()
        editor.view.layoutSubtreeIfNeeded()
        editor.textView.layoutManager.layoutLines()

        #expect(editor.textView.string == original)
        #expect(hasVisibleTextFragment(editor))
        #expect(editor.textView.selectedRange() == originalCursor)

        editor.textView.undoManager?.redo()
        editor.view.layoutSubtreeIfNeeded()
        editor.textView.layoutManager.layoutLines()

        #expect(editor.textView.string == result.newText)
        #expect(hasVisibleTextFragment(editor))
        #expect(editor.textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @MainActor
    private func hasVisibleTextFragment(_ editor: TextViewController) -> Bool {
        let visible = editor.textView.visibleRect
        return editor.textView.layoutManager.lineStorage.contains { line in
            line.data.lineFragments.contains { fragment in
                let globalY = line.yPos + fragment.yPos
                let rect = NSRect(
                    x: 0,
                    y: globalY,
                    width: 1,
                    height: fragment.height
                )
                return !fragment.range.isEmpty && rect.intersects(visible)
            }
        }
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
