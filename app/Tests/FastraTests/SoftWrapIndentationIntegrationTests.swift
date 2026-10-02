import AppKit
import CodeEditLanguages
@testable import CodeEditSourceEditor
import CodeEditTextView
import Testing
@testable import Fastra

@Suite("Soft-Wrap-Profil und Minimap")
@MainActor
struct SoftWrapIndentationIntegrationTests {
    @Test("Minimap-Läufe am Fragmentende behalten ihre tatsächliche Miniaturbreite",
          arguments: ["abcd", "    abcd", "    abcd\n", String(repeating: "日本é🇩🇪", count: 70)])
    func minimapRunAtExclusiveEnd(text: String) throws {
        let controller = TextViewController(string: text, language: .default,
            configuration: .init(appearance: .init(theme: EditorView.fastraTheme,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: true),
                peripherals: .init(showMinimap: true)), cursorPositions: [])
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 760, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let mini = try #require(controller.minimapView)
        let manager = try #require(mini.layoutManager)
        manager.layoutLines()
        let line = try #require(manager.textLineForIndex(0))
        let fragment = try #require(line.data.lineFragments.first)
        mini.contentView.layoutSubtreeIfNeeded()
        let view = try #require(mini.contentView.subviews.compactMap { $0 as? MinimapLineFragmentView }
            .first(where: { $0.lineFragment === fragment.data }))
        let range = fragment.data.documentRange
        #expect(range.length > 0)
        let rect = view.fastraRunRect(range: range, fragmentRange: range)
        #expect(abs(rect.minX - 8) < 0.01)
        #expect(abs(rect.width - fragment.data.width) < 0.01)
        #expect(rect.width > 0)
        let selectionEnd = manager.characterXPosition(in: fragment.data, for: range.length)
        #expect(abs(selectionEnd - (8 + fragment.data.width)) < 0.01,
                "Auswahl und gezeichneter Lauf müssen am selben Fragmentende enden")
    }

    @Test("Minimap bildet unterschiedliche Fragmenthöhen einzeln und umkehrbar ab")
    func mixedFragmentHeights() throws {
        let controller = TextViewController(string: String(repeating: "Wort ", count: 100), language: .default,
            configuration: .init(appearance: .init(theme: EditorView.fastraTheme,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: true),
                peripherals: .init(showMinimap: true)), cursorPositions: [])
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 760, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let editor = controller.textView.layoutManager!
        controller.textView.textStorage.addAttribute(.font,
            value: NSFont.monospacedSystemFont(ofSize: 60, weight: .regular),
            range: NSRange(location: 0, length: 1))
        #expect((controller.textView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 60)
        editor.invalidateLayoutForRange(NSRange(location: 0, length: 1))
        editor.layoutLines()
        let mini = try #require(controller.minimapView)
        mini.synchronizeFastraFragmentGeometry()
        let miniManager = try #require(mini.layoutManager)
        miniManager.invalidateLayoutForRange(NSRange(location: 0, length: 1))
        miniManager.layoutLines()
        let line = try #require(editor.textLineForIndex(0))
        let miniature = try #require(miniManager.textLineForIndex(0))
        #expect(line.data.lineFragments.count > 2)
        let heights = line.data.lineFragments.map(\.height)
        #expect((heights.max() ?? 0) > (heights.min() ?? 0) * 2,
                "Fixture muss echte unterschiedliche CoreText-Höhen enthalten")
        for (source, target) in zip(line.data.lineFragments, miniature.data.lineFragments) {
            #expect(source.range == target.range)
            for fraction in [CGFloat(0.1), 0.5, 0.9] {
                let y = line.yPos + source.yPos + source.height * fraction
                let mapped = try #require(mini.fastraMinimapY(forEditorY: y))
                #expect(abs(mapped - (miniature.yPos + target.yPos + target.height * fraction)) < 0.01)
                #expect(abs((try #require(mini.fastraEditorY(forMinimapY: mapped))) - y) < 0.01)
            }
        }
    }

    @Test("Moduswechsel legt alle sichtbaren Zeilen ohne zusätzlichen Manager-Aufruf aus")
    func visibleModeChange() throws {
        let text = "    " + String(repeating: "Wort 👨‍👩‍👧‍👦 e\u{301} ", count: 25)
            + "\n \t  " + String(repeating: "Text 🇩🇪 ", count: 12)
            + "\n    " + String(repeating: "weiter ", count: 100)
        let controller = TextViewController(string: text, language: .default,
            configuration: .init(appearance: .init(theme: EditorView.fastraTheme,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: true, tabWidth: 8),
                behavior: .init(softWrapIndentationColumns: 2),
                peripherals: .init(showMinimap: true)), cursorPositions: [])
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 760, height: 800)
        for mode in SoftWrapIndentation.allCases {
            var config = controller.configuration
            config.behavior.softWrapIndentation = mode
            controller.configuration = config
            controller.view.layoutSubtreeIfNeeded()
            let manager = controller.textView.layoutManager!
            let line = try #require(manager.textLineForIndex(1))
            let continuation = try #require(line.data.lineFragments.first(where: { $0.index == 1 }))
            let firstText = try #require(manager.rectForOffset(line.range.location + 4)).minX
            let cell = (" " as NSString).size(withAttributes: controller.textView.typingAttributes).width
            let expected = mode == .flushLeft ? manager.edgeInsets.left
                : firstText + (mode == .reverse ? 2 * cell : 0)
            let view = try #require(controller.textView.subviews.compactMap { $0 as? LineFragmentView }
                .first(where: { $0.lineFragment === continuation.data }))
            #expect(abs(view.frame.minX - expected) < 0.6, "\(mode): sichtbare Tab-Zeile bleibt auf einem alten Modus")
            #expect(abs(manager.characterXPosition(in: continuation.data, for: 0)) < 0.6,
                "\(mode): CoreText-Anfang weicht vom Fragmentursprung ab")
        }
    }

    @Test("Reconcile reicht Modus und Stufe weiter; Minimap teilt Umbrüche, Cache und vertikale Abbildung")
    func controllerAndMinimap() throws {
        let text = " \t  " + String(repeating: "Wort 👨‍👩‍👧‍👦 e\u{301} ", count: 50)
            + "\n    " + String(repeating: "zweite ", count: 30)
        let controller = TextViewController(string: text, language: .default,
            configuration: .init(appearance: .init(theme: EditorView.fastraTheme,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: true, tabWidth: 8),
                behavior: .init(wrapAtColumn: 40), peripherals: .init(showMinimap: true)),
            cursorPositions: [])
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        controller.view.layoutSubtreeIfNeeded()
        let manager = controller.textView.layoutManager!
        let minimap = controller.minimapView!
        // Auch eine breite eingebettete Darstellung muss vor dem Skalieren
        // dieselbe Fragmentaufteilung wie der Editor erhalten.
        manager.attachments.add(SoftWrapMinimapTestAttachment(), for: NSRange(location: 6, length: 1))
        for size in [CGFloat(13), 22] {
            for columns in [2, 8] {
                for mode in SoftWrapIndentation.allCases {
                    var config = controller.configuration
                    config.behavior.softWrapIndentation = mode
                    config.behavior.softWrapIndentationColumns = columns
                    config.appearance.font = .monospacedSystemFont(ofSize: size, weight: .regular)
                    controller.configuration = config
                    controller.view.layoutSubtreeIfNeeded()
                    manager.layoutLines()
                    minimap.synchronizeFastraFragmentGeometry()
                    let miniManager = try #require(minimap.layoutManager)
                    miniManager.layoutLines()
                    #expect(manager.softWrapIndentation == mode)
                    #expect(manager.softWrapIndentationColumns == columns)
                    #expect(miniManager.softWrapIndentation == mode)
                    let line = try #require(manager.textLineForIndex(0))
                    let mini = try #require(miniManager.textLineForIndex(0))
                    let firstText = try #require(manager.rectForOffset(4)).minX - manager.edgeInsets.left
                    let cell = (" " as NSString).size(withAttributes: controller.textView.typingAttributes).width
                    let expected = mode == .flushLeft ? 0 : firstText + (mode == .reverse ? CGFloat(columns) * cell : 0)
                    #expect(abs((try #require(line.data.lineFragments.first(where: { $0.index == 1 }))).data.xOffset - expected) < 0.6,
                            "Tab-Einzug muss am sichtbaren ersten Text und der wirksamen Stufe ausgerichtet sein")
                    // Die Positionsabfrage liest den zuvor ausgelegten Cache.
                    _ = miniManager.rectForOffset(1)
                    #expect(line.data.lineFragments.map(\.range) == mini.data.lineFragments.map(\.range))
                    let cached = mini.data.lineFragments.first?.data
                    minimap.synchronizeFastraFragmentGeometry()
                    miniManager.layoutLines()
                    #expect(mini.data.lineFragments.first?.data === cached,
                            "Wertgleiches Reconcile darf den Minimap-Cache nicht neu typesetten")
                    let scale = minimap.editorToMinimapWidthRatio
                    for (a, b) in zip(line.data.lineFragments, mini.data.lineFragments) {
                        #expect(abs(b.data.xOffset - a.data.xOffset * scale) < 0.01)
                        let y = line.yPos + a.yPos + a.height / 2
                        let mapped = try #require(minimap.fastraMinimapY(forEditorY: y))
                        #expect(abs(mapped - (mini.yPos + b.yPos + b.height / 2)) < 0.1)
                        let reverse = try #require(minimap.fastraEditorY(forMinimapY: mapped))
                        #expect(abs(reverse - y) < 0.1)
                    }
                }
            }
        }
        #expect(controller.textView.string == text)
        #expect(controller.textView.undoManager?.canUndo != true)
    }

    @Test("Verborgene Minimap berechnet beim Scrollabgleich keine zweite Dokumentgeometrie")
    func hiddenMinimapStaysLazy() throws {
        let controller = TextViewController(string: String(repeating: "Wort ", count: 10000),
            language: .default, configuration: .init(
                appearance: .init(theme: EditorView.fastraTheme,
                    font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: true),
                behavior: .init(softWrapIndentation: .firstLine),
                peripherals: .init(showMinimap: false)), cursorPositions: [])
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        controller.view.layoutSubtreeIfNeeded()
        let mini = try #require(controller.minimapView)
        #expect(mini.isHidden)
        mini.updateDocumentVisibleViewPosition()
        let line = try #require(mini.layoutManager?.lineStorage.first)
        #expect(line.data.lineFragments.isEmpty)
    }

    @Test("Wirksame Stufe folgt Tabbreite oder Leerzeichenprofil, Modus aktiviert Wrap nicht")
    func workspaceProfile() {
        let defaults = testSuiteDefaults(named: "fastra-softwrap-\(UUID().uuidString)")
        let ws = Workspace(defaults: defaults)
        ws.setSoftWrapEnabled(false)
        ws.setIndentWidth(2)
        ws.setSoftWrapIndentation(.reverse)
        #expect(!ws.softWrapEnabled)
        #expect(ws.effectiveSoftWrapIndentationColumns == 2)
        ws.setIndentUsesTabs(true)
        ws.setEditorTabWidth(8)
        #expect(ws.effectiveSoftWrapIndentationColumns == 8)
        #expect(ws.softWrapIndentation == .reverse)
    }
}

private final class SoftWrapMinimapTestAttachment: TextAttachment {
    var width: CGFloat { 80 }
    var isSelected = false
    func draw(in context: CGContext, rect: NSRect) {}
}
