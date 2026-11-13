import AppKit
@testable import CodeEditSourceEditor
import CodeEditTextView
import Testing
@testable import Fastra

@Suite("Anfangsmetrik des gemeinsamen Quelltextspeichers", .serialized)
struct SharedSourceLayoutTests {
    @MainActor private func configuration() -> SourceEditorConfiguration {
        .init(appearance: .init(theme: EditorView.fastraTheme,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: true),
              peripherals: .init(showMinimap: true))
    }

    @Test("Neu angehängter Dokument-Speicher nutzt bedarfsgesteuerte Glyphen bis zum Dateiende")
    @MainActor func persistentStorageUsesFixedCells() throws {
        let source = "[{\"blob\":\"" + String(repeating: "A7+/qZ09mN4xB", count: 64 * 1024) + "\"}]"
        let config = configuration()
        let history = DocumentUndoHistory()
        let storage = history.textStorage(for: source,
            initialAttributes: SourceEditorPane.initialTextAttributes(for: config))
        let controller = TextViewController(string: "", language: .default,
            configuration: config, cursorPositions: [])
        controller.textView.setTextStorage(storage)
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        controller.textView.layoutManager.layoutLines()
        for offset in [0, storage.length / 2, storage.length - 1] {
            #expect((storage.attribute(.font, at: offset, effectiveRange: nil) as? NSFont) == config.appearance.font)
        }
        let line = try #require(controller.textView.layoutManager.lineStorage.first)
        #expect(line.data.lineFragments.count > 100)
        for index in [0, line.data.lineFragments.count / 2, line.data.lineFragments.count - 1] {
            let fragment = try #require(line.data.lineFragments.getLine(atIndex: index)?.data)
            #expect(fragment.fastraHasFixedCells)
        }
        let mini = try #require(controller.minimapView)
        mini.contentView.needsLayout = true
        mini.contentView.layoutSubtreeIfNeeded()
        #expect(mini.contentView.subviews.contains { $0 is LineFragmentView })
    }

    @Test("Wiederverwendeter Speicher behält bereits berechnete Syntaxattribute")
    @MainActor func reusedStoragePreservesHighlighting() {
        let history = DocumentUndoHistory(), source = "let value = 42"
        let config = configuration()
        let storage = history.textStorage(for: source,
            initialAttributes: SourceEditorPane.initialTextAttributes(for: config))
        storage.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: 3))
        var other = config
        other.appearance.font = .monospacedSystemFont(ofSize: 19, weight: .bold)
        let reused = history.textStorage(for: source,
            initialAttributes: SourceEditorPane.initialTextAttributes(for: other))
        #expect(reused === storage)
        #expect((reused.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == .systemRed)
        #expect((reused.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) == config.appearance.font)
    }

    @Test("Anfangsattribute entsprechen der tatsächlichen Controller-Konfiguration")
    @MainActor func attributesMatchController() {
        for styled in [false, true] {
            var config = configuration()
            config.appearance.font = styled ? .systemFont(ofSize: 13) : config.appearance.font
            config.appearance.letterSpacing = styled ? 1.2 : 1
            config.appearance.theme.text = .init(color: .systemOrange, bold: styled, italic: styled)
            let controller = TextViewController(string: "", language: .default,
                configuration: config, cursorPositions: [])
            controller.loadView()
            let expected = controller.attributesFor(nil)
            let actual = SourceEditorPane.initialTextAttributes(for: config)
            #expect(NSDictionary(dictionary: actual).isEqual(to: expected))
        }
    }
}
