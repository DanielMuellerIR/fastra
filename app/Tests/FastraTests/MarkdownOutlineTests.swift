import Foundation
import Testing
@testable import Fastra

struct MarkdownOutlineTests {
    @Test("Gliederung folgt CommonMark statt Zeichen in Code oder HTML zu zählen")
    func parsedStructure() {
        let source = "# Anfang **fett** &amp; 😀\r\n\r\n```md\r\n# Kein Titel\r\n```\r\n\r\n<div>\r\n# Auch keiner\r\n</div>\r\n\r\nUntertitel\r\n----------\r\n\r\n> ### Zitat\r\n\r\n$$\r\n# Formel\r\nx^2\r\n$$\r\n\r\n## Ende $x$\r\n"
        let headings = MarkdownOutline.headings(in: source)
        #expect(headings.map(\.level) == [1, 2, 3, 2])
        #expect(headings.map(\.line) == [1, 11, 14, 21])
        #expect(headings[0].title == "Anfang fett & 😀")
        #expect(headings.last?.title == "Ende $x$")
        #expect((source as NSString).substring(from: headings.last!.range.location).hasPrefix("## Ende"))
    }

    @Test("UTF-16-Ziele berücksichtigen Emoji, CR und doppelte Überschriften")
    func positions() {
        let source = "😀 Text\r\r## Gleich\r\r## Gleich\r"
        let headings = MarkdownOutline.headings(in: source)
        #expect(headings.map(\.line) == [3, 5])
        #expect(headings[0].range.location == ("😀 Text\r\r" as NSString).length)
        #expect(headings[0].id != headings[1].id)
        #expect(MarkdownOutline.headings(in: "Nur Text\n").isEmpty)
    }

    @Test("Titel zeigen Auszeichnungen und Zeilenumbrüche als lesbaren Text")
    func formattedTitles() {
        let source = "# ==Wichtig== und ~~alt~~<br>Neu `a  b`\n\n> ## [Link](target.md) &amp; **fett**\n"
        #expect(MarkdownOutline.headings(in: source).map(\.title) == ["Wichtig und alt Neu a  b", "Link & fett"])
    }

    @Test("Sprungverlauf begrenzt Speicher und verwirft eine verlassene Vorwärtsstrecke")
    func historyBranches() {
        func point(_ offset: Int) -> DocumentNavigationPoint { .init(offset: offset, line: offset + 1, heading: nil) }
        var history = DocumentNavigationHistory()
        history.visit(point(1), from: point(0))
        history.visit(point(2), from: point(1))
        #expect(history.move(-1) == point(1))
        history.visit(point(9), from: point(1))
        #expect(!history.canGoForward)
        #expect(history.move(-1) == point(1))
        for offset in 10..<150 { history.visit(point(offset), from: point(offset - 1)) }
        #expect(history.points.count == 100)
        #expect(history.points.last == point(149))
    }

    @Test("Gleich aussehende Unicode-Änderungen berechnen UTF-16-Sprungziele neu")
    @MainActor func unicodeRevision() async throws {
        let workspace = Workspace()
        let original = "# Caf\u{e9}\n\n## Ende\n"
        let changed = "# Cafe\u{301}\n\n## Ende\n"
        #expect(original == changed)
        #expect(original.utf16.count != changed.utf16.count)
        var tab = EditorTab(title: "a.md", path: "a.md", content: original)
        tab.markdownVisualOverride = false
        workspace.tabs = [tab]; workspace.activeTabID = tab.id
        let outline = workspace.documentOutline
        outline.refresh(in: workspace)
        try #require(await waitUntil { outline.ready })
        let oldOffset = outline.headings[1].range.location
        workspace.tabs[0].content = changed
        outline.refresh(in: workspace)
        try #require(await waitUntil { outline.ready })
        #expect(outline.headings[1].range.location == oldOffset + 1)
        outline.jump(to: outline.headings[1], in: workspace)
        #expect(workspace.pendingEditorJump?.range?.location == oldOffset + 1)
    }

    @Test("Alte Analysen und Verläufe wechseln nicht in andere Dokumente oder Fenster")
    @MainActor func documentIsolation() async throws {
        let workspace = Workspace()
        var first = EditorTab(title: "a.md", path: "a.md", content: String(repeating: "Text\n", count: 1000) + "# A\n")
        first.markdownVisualOverride = false
        var second = EditorTab(title: "b.md", path: "b.md", content: "# B\n\n## C\n")
        second.markdownVisualOverride = false
        workspace.tabs = [first, second]
        workspace.activeTabID = first.id
        workspace.documentOutline.refresh(in: workspace)
        workspace.activeTabID = second.id
        workspace.documentOutline.refresh(in: workspace)
        try #require(await waitUntil { workspace.documentOutline.ready })
        #expect(workspace.documentOutline.headings.map(\.title) == ["B", "C"])
        workspace.documentOutline.jump(to: workspace.documentOutline.headings[1], in: workspace)
        #expect(workspace.documentOutline.history.canGoBack)
        workspace.activeTabID = first.id
        workspace.documentOutline.refresh(in: workspace)
        try #require(await waitUntil { workspace.documentOutline.ready })
        #expect(workspace.documentOutline.history.canGoBack)
        #expect(Workspace().documentOutline.headings.isEmpty)
        #expect(workspace.tabs.map(\.content) == [first.content, second.content])
    }
    @Test("Zurückkehrende Markdown-Tabs starten eine verworfene Analyse erneut", arguments: [false, true])
    @MainActor func returnDuringAnalysis(_ refreshOtherTab: Bool) async throws {
        let workspace = Workspace()
        var markdown = EditorTab(title: "a.md", path: "a.md", content: "# A\n\n## B\n")
        markdown.markdownVisualOverride = false
        let other = EditorTab(title: "b.txt", path: "b.txt", content: "Text")
        workspace.tabs = [markdown, other]; workspace.activeTabID = markdown.id
        let outline = workspace.documentOutline
        outline.refresh(in: workspace)
        workspace.activeTabID = other.id
        if refreshOtherTab { outline.refresh(in: workspace) }
        try await Task.sleep(for: .milliseconds(400))
        workspace.activeTabID = markdown.id
        outline.refresh(in: workspace)
        try #require(await waitUntil { outline.ready })
        #expect(outline.headings.map(\.title) == ["A", "B"])
        let point = DocumentNavigationPoint(offset: 5, line: 3, heading: nil)
        #expect(outline.visualHeadingIndex(for: point) == 1)
    }

    @Test("Ein unverändertes Sprungziel behält den Überschriftenanker im Verlauf")
    func historyRetainsAnchor() throws {
        let headings = MarkdownOutline.headings(in: "# A\n\n## B\n\n### C\n")
        func point(_ heading: DocumentOutlineEntry) -> DocumentNavigationPoint {
            .init(offset: heading.range.location, line: heading.line, heading: heading)
        }
        var history = DocumentNavigationHistory()
        history.visit(point(headings[1]), from: point(headings[0]))
        history.visit(point(headings[2]), from: .init(offset: headings[1].range.location, line: headings[1].line, heading: nil))
        #expect(history.move(-1)?.heading == headings[1])
        history.visit(point(headings[2]), from: .init(offset: 8, line: 3, heading: nil))
        #expect(history.move(-1)?.heading == nil)
        let renamed = DocumentOutlineEntry(title: "Neu", level: headings[1].level, line: headings[1].line, range: headings[1].range)
        history.visit(point(headings[2]), from: point(renamed))
        #expect(history.move(-1)?.heading == renamed)
    }

    @Test("Sprungverlauf löst Überschriften nach einem vorangestellten Absatz neu auf")
    @MainActor func historyReanchorsAfterPrefix() async throws {
        let workspace = Workspace()
        let source = "# A\n\n## B\n\n### C\n"
        var tab = EditorTab(title: "a.md", path: "a.md", content: source)
        tab.markdownVisualOverride = false
        workspace.tabs = [tab]; workspace.activeTabID = tab.id
        let outline = workspace.documentOutline
        outline.refresh(in: workspace)
        try #require(await waitUntil { outline.ready })
        outline.jump(to: outline.headings[1], in: workspace)
        workspace.cursorLine = 3
        outline.jump(to: outline.headings[2], in: workspace)
        workspace.tabs[0].content = "Prefix\n\n" + source
        outline.refresh(in: workspace)
        try #require(await waitUntil { outline.ready })
        outline.move(-1, in: workspace)
        #expect(workspace.pendingEditorJump?.range?.location == 13)
    }

}
