import AppKit
import CodeEditSourceEditor
import CodeEditLanguages
@testable import CodeEditTextView
import Testing
@testable import Fastra

@Suite("Editor-Darstellungsoptionen")
struct EditorDisplayOptionsTests {
    @Test("Anzeige bleibt je Dokument erhalten und ändert keine Inhalte")
    @MainActor
    func documentIsolation() {
        let workspace = Workspace()
        let first = EditorTab(title: "a.txt", path: "", content: "A  B\n\tC\n")
        let second = EditorTab(title: "b.txt", path: "", content: "Zwei\n")
        workspace.tabs = [first, second]
        workspace.activeTabID = first.id
        workspace.setEditorDisplayOption(\.showInvisibles, true)
        workspace.setEditorDisplayOption(\.showSpaces, false)
        workspace.setEditorDisplayOption(\.showGutter, false)
        #expect(workspace.editorDisplayOptions.invisibleCharacters.showTabs)
        #expect(!workspace.editorDisplayOptions.invisibleCharacters.showSpaces)
        workspace.setEditorDisplayOption(\.showInvisibles, false)
        workspace.setEditorDisplayOption(\.showInvisibles, true)
        #expect(!workspace.editorDisplayOptions.showSpaces)
        workspace.activeTabID = second.id
        #expect(workspace.editorDisplayOptions == .init())
        workspace.activeTabID = first.id
        #expect(workspace.editorDisplayOptions.showInvisibles)
        #expect(!workspace.editorDisplayOptions.showGutter)
        #expect(workspace.tabs.map(\.content) == [first.content, second.content])
        #expect(workspace.tabs.allSatisfy { !$0.isDirty && $0.contentRevision == 0 })
        workspace.tabs[0].displayMode = .hex
        workspace.setEditorDisplayOption(\.showInvisibles, false)
        #expect(workspace.editorDisplayOptions.showInvisibles)
    }

    @Test("Andere Fenster und WYSIWYG werden nicht versehentlich mitgeschaltet")
    @MainActor
    func windowAndModeIsolation() {
        let first = Workspace(), second = Workspace()
        var markdown = EditorTab(title: "a.md", path: "", content: "- Eintrag\n")
        markdown.markdownVisualOverride = false
        first.tabs = [markdown]
        first.activeTabID = markdown.id
        second.tabs = [EditorTab(title: "b.txt", path: "", content: "Anderes Fenster")]
        second.activeTabID = second.tabs[0].id
        first.setEditorDisplayOption(\.showInvisibles, true)
        #expect(first.editorDisplayOptions.showInvisibles)
        #expect(!second.editorDisplayOptions.showInvisibles)
        first.tabs[0].markdownVisualOverride = true
        #expect(!first.canConfigureTextDisplay)
        first.setEditorDisplayOption(\.showInvisibles, false)
        #expect(first.editorDisplayOptions.showInvisibles)
        first.tabs[0].markdownVisualOverride = false
        #expect(first.canConfigureTextDisplay)
        #expect(first.activeTab?.content == markdown.content)
    }

    @Test("Echter Renderer zeichnet Zeichen zusätzlich ohne Text oder Auswahl zu verändern",
          arguments: ["A B", "A\tB", "A\r\nB\rC\n", "😀 \tB\n"])
    @MainActor
    func rendering(_ source: String) throws {
        let controller = TextViewController(string: source, language: .default,
            configuration: .init(appearance: .init(theme: EditorView.fastraTheme,
                font: .monospacedSystemFont(ofSize: 16, weight: .regular), wrapLines: false),
                peripherals: .init(showMinimap: false)), cursorPositions: [])
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        controller.view.layoutSubtreeIfNeeded()
        let text = controller.textView!
        text.layoutManager.layoutLines()
        text.selectionManager.setSelectedRange(NSRange(location: 0, length: 1))
        func rendered() throws -> Data {
            let rect = NSRect(x: 0, y: 0, width: 400, height: 150)
            let bitmap = try #require(text.bitmapImageRepForCachingDisplay(in: rect))
            text.cacheDisplay(in: rect, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        let original = try rendered()
        controller.configuration.peripherals.invisibleCharactersConfiguration =
            .init(showSpaces: true, showTabs: true, showLineEndings: true)
        let visible = try rendered()
        #expect(visible != original, "Der sichtbare Text muss um Zeichenmarkierungen ergänzt werden")
        controller.configuration.peripherals.invisibleCharactersConfiguration = .empty
        #expect(try rendered() == original, "Ausschalten muss die ursprüngliche Darstellung zurückbringen")
        #expect(text.string == source)
        #expect(text.selectedRange() == NSRange(location: 0, length: 1))
    }

    @Test("Zeichenmarkierungen folgen laufenden Themen-, Schrift- und Einrückungswechseln")
    @MainActor
    func liveAppearanceChanges() throws {
        let controller = TextViewController(string: "A   B\n", language: .default,
            configuration: .init(appearance: .init(theme: EditorView.fastraTheme,
                font: .monospacedSystemFont(ofSize: 14, weight: .regular), wrapLines: false),
                peripherals: .init(showMinimap: false,
                    invisibleCharactersConfiguration: .init(showSpaces: true, showTabs: true, showLineEndings: true))),
            cursorPositions: [])
        controller.loadView()
        let text = controller.textView!
        func style(_ location: Int) throws -> (NSColor, NSFont) {
            let value = try #require(text.layoutManager.invisibleCharacterDelegate?.invisibleStyle(
                for: 32, at: NSRange(location: location, length: 1), lineRange: NSRange(location: 0, length: 6)))
            guard case let .replace(_, color, font) = value else {
                Issue.record("Leerzeichen besitzt keinen Ersatz"); throw CocoaError(.coderInvalidValue)
            }
            return (color, font)
        }
        let original = try style(1)
        controller.configuration.appearance.theme = EditorView.fastraThemeDark
        let dark = try style(1)
        #expect(dark.0 == EditorView.fastraThemeDark.invisibles.color)
        #expect(dark.0 != original.0)
        controller.configuration.appearance.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
        #expect(try style(1).1.pointSize == 22)
        controller.configuration.behavior.indentOption = .spaces(count: 2)
        let emphasized = try style(1).1
        let normal = try style(2).1
        #expect(emphasized != normal, "Betonte Leerzeichen müssen der neuen Einrückungsbreite folgen")
        #expect(text.string == "A   B\n")
    }
}
