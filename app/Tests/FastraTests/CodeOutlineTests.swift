import Foundation
import Testing
@testable import Fastra

@Suite("Codegliederung und Navigation")
struct CodeOutlineTests {
    @Test("Umbenennen aktualisiert den synthetischen 4D-Methodeneintrag ohne Textänderung")
    @MainActor func renamedMethodTitle() async throws {
        let workspace = Workspace()
        let tab = EditorTab(title: "a.4dm", path: "a.4dm", content: "#DECLARE($value : Text)\n")
        workspace.tabs = [tab]; workspace.activeTabID = tab.id
        let outline = workspace.documentOutline
        outline.refresh(in: workspace)
        try #require(await waitUntil { outline.ready })
        #expect(outline.headings.map(\.title) == ["a.4dm"])
        workspace.tabs[0].title = "b.4dm"
        outline.refresh(in: workspace)
        try #require(await waitUntil { outline.ready })
        #expect(workspace.activeTab?.contentRevision == tab.contentRevision)
        #expect(outline.headings.map(\.title) == ["b.4dm"])
    }

    @Test("Ein neuer Sprung verdrängt eine ausstehende Rückauflösung", arguments: ["range", "heading", "record"])
    @MainActor func newerJumpInvalidatesPendingHistory(_ kind: String) async throws {
        let workspace = Workspace()
        let text = "Function zero()\nFunction a()\nFunction b()\nFunction c()\n"
        let tab = EditorTab(title: "a.4dm", path: "a.4dm", content: text)
        workspace.tabs = [tab]; workspace.activeTabID = tab.id
        let outline = workspace.documentOutline
        func range(_ name: String, in source: String) -> NSRange {
            NSRange(location: (source as NSString).range(of: "Function \(name)").location, length: 0)
        }
        outline.jump(to: range("a", in: text), in: workspace, originRange: range("zero", in: text))
        outline.jump(to: range("b", in: text), in: workspace, originRange: range("a", in: text))
        workspace.tabs[0].content = "// Prefix\n" + text
        outline.refresh(in: workspace)
        try #require(await waitUntil { outline.ready })
        let changed = workspace.tabs[0].content
        let target = range("c", in: changed)
        workspace.pendingEditorJump = .init(documentID: tab.documentID, startLine: nil, startColumn: nil,
            endLine: nil, endColumn: nil, range: range("b", in: changed))
        outline.move(-1, in: workspace)
        // Bis zur nächsten Main-Actor-Freigabe kann die alte Completion
        // noch nicht wirken; der neue Sprung kommt sicher zuvor an.
        switch kind {
        case "heading": outline.jump(to: try #require(outline.headings.last), in: workspace)
        case "record":
            let origin = outline.currentPoint(in: workspace, range: range("b", in: changed))
            outline.recordJump(in: workspace, from: origin, range: target)
            workspace.pendingEditorJump = .init(documentID: tab.documentID, startLine: nil, startColumn: nil,
                endLine: nil, endColumn: nil, range: target)
        default: outline.jump(to: target, in: workspace)
        }
        let expectedIndex = outline.history.index
        try await Task.sleep(for: .milliseconds(200))
        #expect(outline.history.index == expectedIndex)
        #expect(outline.history.points.last?.offset == target.location)
        #expect(workspace.pendingEditorJump?.range?.location == target.location)
        outline.move(-1, in: workspace)
        #expect(await waitUntil { workspace.pendingEditorJump?.range?.location == range("b", in: changed).location })
    }

    @Test("4D-Definitionen in Blockkommentaren sind keine Sprungziele")
    func commentedFunctionIsNotTarget() {
        let source = "/*\nFunction phantom()\n*/\nFunction actual()\n"
        #expect(FourDGoToTarget.functionDefinitionRange(named: "phantom", in: source) == nil)
        #expect(FourDGoToTarget.functionDefinitionRange(named: "actual", in: source) != nil)
    }

    @Test("4D-Tokenizer schützt Kommentare, Strings und SQL; gültige Modifikatoren bleiben erhalten")
    func declarationsUseTokens() throws {
        let source = "// Function ignored()\r\n/*\r\nFunction phantom()\r\n*/\r\n"
            + "$text:=\"Function stringExample()\"\r\nBegin SQL\r\nFunction sqlExample()\r\nEnd SQL\r\n"
            + "shared singleton Class constructor()\r\nlocal shared Function calculate()\r\n"
            + "Function get name()->$value : Text\r\nFunction set name($value : Text)\r\n"
            + "Function incomplete\r\nFunction café()\r\n"
        let definitions = try #require(FourDDefinitions.definitions(in: source))
        #expect(definitions.map(\.name) == ["Class constructor", "calculate", "name", "name", "café"])
        #expect(definitions.map(\.kind) == [.constructor, .function, .getter, .setter, .function])
        #expect(definitions.map(\.line) == [9, 10, 11, 12, 14])
    }

    @Test("4D-Analyse respektiert Abbruch und Größen-/Ergebnisgrenzen")
    func declarationBounds() {
        #expect(FourDDefinitions.definitions(in: "Function a()", isCancelled: { true }) == nil)
        #expect(FourDDefinitions.definitions(in: String(repeating: "x", count: 10 * 1024 * 1024 + 1)) == nil)
        #expect(FourDDefinitions.definitions(in: "Function a()\nFunction b()", maximum: 1)?.count == 1)
    }

    @Test("Rücksprunganker folgen vorangestellten Zeilen und verweigern mehrdeutige Ziele")
    func sourceAnchors() {
        let original = "Vorher\r\nZiel 😀\r\nDanach\r\n"
        let offset = (original as NSString).range(of: "Ziel").location
        let anchor = NavigationAnchor(source: original, revision: 1, range: NSRange(location: offset, length: 4))
        #expect(anchor.resolve(in: original, revision: 1)?.location == offset)
        #expect(anchor.resolve(in: "Prefix\r\n" + original, revision: 2)?.location == offset + 8)
        #expect(anchor.resolve(in: original + original, revision: 2) == nil)
        #expect(anchor.resolve(in: original.replacingOccurrences(of: "Ziel", with: "Weg"), revision: 2) == nil)
    }

    @Test("Sprunganker behalten lange Zeilen nur bei unveränderter Inhaltsgeneration")
    func boundedAnchors() {
        let source = String(repeating: "x", count: 2000)
        let anchor = NavigationAnchor(source: source, revision: 1, range: NSRange(location: 100, length: 0))
        #expect(anchor.lineText == nil)
        #expect(anchor.resolve(in: source, revision: 1)?.location == 100)
        #expect(anchor.resolve(in: source + "x", revision: 2) == nil)
    }

    @Test("Codegliederung und Sprungverlauf bleiben im Fenster und folgen Dokumentidentitäten")
    @MainActor func windowHistoryAndClosedTabs() async throws {
        let workspace = Workspace(), other = Workspace()
        let first = EditorTab(title: "a.4dm", path: "a.4dm", content: "Function one()\nFunction two()\n")
        let second = EditorTab(title: "b.4dm", path: "b.4dm", content: "Function three()\n")
        workspace.tabs = [first, second]; workspace.activeTabID = first.id
        let outline = workspace.documentOutline
        outline.refresh(in: workspace)
        try #require(await waitUntil { outline.ready })
        #expect(outline.headings.map(\.title) == ["one", "two"])
        outline.jump(to: outline.headings[1], in: workspace)
        let origin = try #require(outline.currentPoint(in: workspace, range: NSRange(location: 16, length: 0)))
        workspace.selectTab(id: second.id); outline.refresh(in: workspace)
        outline.recordJump(in: workspace, from: origin, range: NSRange(location: 0, length: 0))
        outline.move(-1, in: workspace)
        #expect(workspace.activeTab?.documentID == first.documentID)
        #expect(workspace.pendingEditorJump?.documentID == first.documentID)
        #expect(other.documentOutline.history.points.isEmpty)
        outline.move(1, in: workspace)
        #expect(workspace.activeTab?.documentID == second.documentID)
        workspace.tabs.removeAll { $0.documentID == first.documentID }
        let index = outline.history.index
        outline.move(-1, in: workspace)
        #expect(workspace.activeTab?.documentID == second.documentID)
        #expect(outline.history.index == index)
    }

    @Test("Code-Rücksprung findet einen unveränderten Funktionsanker nach vorangestellten Zeilen")
    @MainActor func codeHistoryReanchors() async throws {
        let workspace = Workspace()
        let original = "Function one()\nFunction two()\nFunction three()\n"
        let tab = EditorTab(title: "a.4dm", path: "a.4dm", content: original)
        workspace.tabs = [tab]; workspace.activeTabID = tab.id
        let outline = workspace.documentOutline
        outline.refresh(in: workspace)
        try #require(await waitUntil { outline.ready })
        outline.jump(to: outline.headings[1], in: workspace)
        workspace.cursorLine = 2
        outline.jump(to: outline.headings[2], in: workspace)
        workspace.tabs[0].content = "// Prefix\n" + original
        outline.refresh(in: workspace)
        try #require(await waitUntil { outline.ready })
        outline.move(-1, in: workspace)
        #expect(workspace.pendingEditorJump?.range?.location == (workspace.tabs[0].content as NSString).range(of: "Function two").location)
    }

    @Test("Ein frisch geladenes Ziel übernimmt keine Definition des vorherigen Dokuments")
    @MainActor func targetDoesNotBorrowOriginHeading() async throws {
        let workspace = Workspace()
        let first = EditorTab(title: "a.4dm", path: "a.4dm", content: "Function origin()\n")
        let second = EditorTab(title: "b.4dm", path: "b.4dm", content: "Function target()\n")
        workspace.tabs = [first, second]; workspace.activeTabID = first.id
        workspace.documentOutline.refresh(in: workspace)
        try #require(await waitUntil { workspace.documentOutline.ready })
        workspace.activeTabID = second.id
        let target = try #require(workspace.documentOutline.currentPoint(in: workspace, range: NSRange(location: 0, length: 0)))
        #expect(target.documentID == second.documentID)
        #expect(target.heading == nil)
    }

    @Test("Dateiziele außerhalb des Projekts verwenden denselben Verlauf")
    @MainActor func externalFileHistory() async throws {
        let root = testTemporaryDirectory().appendingPathComponent("fastra-navigation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("External.4dm")
        try "Function target()\n".write(to: target, atomically: true, encoding: .utf8)
        let workspace = Workspace()
        let source = EditorTab(title: "Source.4dm", path: "Source.4dm", content: "External()\n")
        workspace.tabs = [source]; workspace.activeTabID = source.id
        workspace.documentOutline.openFile(at: target, in: workspace, originRange: NSRange(location: 3, length: 0))
        try #require(await waitUntil { workspace.activeTab?.url?.lastPathComponent == "External.4dm" && workspace.activeTab?.isLoading == false && workspace.documentOutline.history.points.count == 2 })
        workspace.documentOutline.move(-1, in: workspace)
        #expect(workspace.activeTab?.documentID == source.documentID)
        #expect(workspace.pendingEditorJump?.range?.location == 3)
    }

    @Test("Eine während des Ladens geänderte Quelle erzeugt keinen veralteten Sprungpunkt")
    @MainActor func changedOriginRejectsFileResult() async throws {
        let root = testTemporaryDirectory().appendingPathComponent("fastra-navigation-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("External.4dm")
        try "Function target()\n".write(to: target, atomically: true, encoding: .utf8)
        let workspace = Workspace()
        let source = EditorTab(title: "Source.4dm", path: "Source.4dm", content: "External()\n")
        workspace.tabs = [source]; workspace.activeTabID = source.id
        workspace.documentOutline.openFile(at: target, in: workspace)
        let index = try #require(workspace.tabs.firstIndex(where: { $0.documentID == source.documentID }))
        workspace.tabs[index].content += "// New source\n"
        try #require(await waitUntil { workspace.tabs.allSatisfy { !$0.isLoading } })
        #expect(workspace.documentOutline.history.points.isEmpty)
        #expect(workspace.tabs.first(where: { $0.documentID == source.documentID })?.content.hasSuffix("// New source\n") == true)
    }
    @Test("Identische Bytes mit neuer Generation verdoppeln denselben Sprungort nicht")
    func historyIgnoresPublicationRevision() {
        let id = UUID(), source = "First\nSecond\n"
        func point(_ offset: Int, _ revision: UInt64) -> DocumentNavigationPoint {
            .init(offset: offset, line: offset == 0 ? 1 : 2, heading: nil, documentID: id,
                  anchor: NavigationAnchor(source: source, revision: revision, range: NSRange(location: offset, length: 0)))
        }
        var history = DocumentNavigationHistory()
        history.visit(point(6, 1), from: point(0, 1))
        history.visit(point(6, 2), from: point(6, 1))
        #expect(history.points.count == 2)
        #expect(history.points.last?.anchor?.revision == 2)
    }

    @Test("Eine während des Ladens geänderte Quell-URL entwertet die alte Zielbasis")
    @MainActor func renamedOriginRejectsFileResult() async throws {
        let root = testTemporaryDirectory().appendingPathComponent("fastra-navigation-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("External.4dm")
        try "Function target()\n".write(to: target, atomically: true, encoding: .utf8)
        let workspace = Workspace()
        let source = EditorTab(title: "Source.4dm", path: root.appendingPathComponent("Source.4dm").path,
                               url: root.appendingPathComponent("Source.4dm"), content: "External()\n")
        workspace.tabs = [source]; workspace.activeTabID = source.id
        workspace.documentOutline.openFile(at: target, in: workspace)
        let index = try #require(workspace.tabs.firstIndex(where: { $0.documentID == source.documentID }))
        let renamed = root.appendingPathComponent("Renamed.4dm")
        workspace.tabs[index].url = renamed
        try #require(await waitUntil { workspace.tabs.allSatisfy { !$0.isLoading } })
        #expect(workspace.documentOutline.history.points.isEmpty)
        #expect(workspace.tabs.first(where: { $0.documentID == source.documentID })?.url == renamed)
    }

    @Test("Namenssprünge wählen weder einen Accessor noch eine doppelte Funktion willkürlich")
    func ambiguousDefinitionIsNotChosen() {
        #expect(FourDGoToTarget.functionDefinitionRange(named: "name", in: "Function get name()\nFunction set name($x)\n") == nil)
        #expect(FourDGoToTarget.functionDefinitionRange(named: "same", in: "Function same()\nFunction same()\n") == nil)
    }

    @Test("Modifikatoren einer gültigen Function-Kopfzeile bleiben beim Namenssprung erhalten")
    func modifiedFunctionHeaderResolves() {
        let source = "local shared Function calculate()\n"
        let location = (source as NSString).range(of: "calculate").location + 1
        let action = FourDGoToTarget.resolve(.init(text: source, location: location, documentURL: nil, projectURL: nil))
        guard case .jumpToRange(let range) = action else { Issue.record("Function-Kopfzeile wurde nicht aufgelöst"); return }
        #expect(range.location == 0)
    }

}
