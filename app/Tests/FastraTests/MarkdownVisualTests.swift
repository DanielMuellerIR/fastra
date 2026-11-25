import AppKit
import SwiftUI
import WebKit
import PDFKit
import Testing
@testable import Fastra

// Im Produkt besitzt das Dokumentfenster seinen Workspace. Der Coordinator
// hält ihn bewusst schwach; dieselbe Lebensdauer braucht die Renderer-Fixture.
// Den Coordinator hält im Produkt der View-Context ebenfalls bis zum Schließen.
private final class MarkdownVisualFixtureWindow: NSWindow {
    var retainedWorkspace: Workspace?
    var retainedCoordinator: MarkdownVisualCoordinator?

    override func close() {
        super.close()
        retainedWorkspace = nil
        retainedCoordinator = nil
    }
}

private final class MarkdownVisualMessageTap: NSObject, WKScriptMessageHandler {
    let coordinator: MarkdownVisualCoordinator
    var observe: ((WKScriptMessage) -> Void)?
    var forwardsChanges = true
    init(_ coordinator: MarkdownVisualCoordinator) { self.coordinator = coordinator }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        observe?(message)
        if !forwardsChanges, (message.body as? [String: Any])?["kind"] as? String == "change" { return }
        coordinator.userContentController(controller, didReceive: message)
    }
}

private final class VisualImageRemovalSchedule: @unchecked Sendable {
    private let lock = NSLock()
    private let holds = (0..<8).map { _ in DispatchSemaphore(value: 0) }
    private var enabled = false
    private var arrivals = 0
    private var claims = 0
    private var unlinks = 0

    var counts: (arrivals: Int, claims: Int, unlinks: Int) {
        lock.withLock { (arrivals, claims, unlinks) }
    }

    func setEnabled(_ value: Bool) { lock.withLock { enabled = value } }
    func release(_ index: Int) { holds[index].signal() }
    func releaseAll() { holds.forEach { $0.signal() } }

    var hooks: MarkdownImageRemoval.Hooks {
        .init(afterPreparingDirectory: { [self] _ in
            let index: Int? = lock.withLock {
                guard enabled else { return nil }
                arrivals += 1
                return arrivals - 1
            }
            if let index, holds.indices.contains(index) { holds[index].wait() }
        }, beforeClaim: { [self] _ in lock.withLock { claims += 1 } },
           beforeUnlink: { [self] _ in lock.withLock { unlinks += 1 } })
    }
}

@MainActor
private final class VisualImageReferenceFixture {
    let directory: URL
    let workspace: Workspace
    let coordinator: MarkdownVisualCoordinator
    let web: MarkdownVisualWKWebView
    let window: NSWindow
    let other = Workspace()
    let schedule = VisualImageRemovalSchedule()
    let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII=")!
    var warnings: [String] = []
    var messageTap: MarkdownVisualMessageTap?

    init(directory: URL, editor: (Workspace, MarkdownVisualCoordinator, MarkdownVisualWKWebView, NSWindow)) throws {
        self.directory = directory
        (workspace, coordinator, web, window) = editor
        var tab = EditorTab(title: "other.md", path: "", content: "Version 0")
        tab.url = directory.appendingPathComponent("B/other.md")
        other.tabs = [tab]
        try "Version 0".write(to: tab.url!, atomically: true, encoding: .utf8)
        coordinator.imageRemovalHooks = schedule.hooks
        workspace.saveSafetyWarningHandler = { [weak self] _, message in self?.warnings.append(message) }
        for name in ["a.png", "b.png"] { try bytes.write(to: directory.appendingPathComponent(name)) }
    }

    func insert(_ name: String) { coordinator.insertImages([directory.appendingPathComponent(name)]) }
    var first: URL { directory.appendingPathComponent("A/images/1.png") }
    var second: URL { directory.appendingPathComponent("A/images/2.png") }
    var notSettledWarnings: [String] {
        warnings.filter { $0.contains(L10n.string("Die Prüfung offener Dokumente wurde nicht stabil abgeschlossen. Verbliebene Bilddateien wurden nicht weiter bereinigt.")) }
    }

    func drain() async -> Bool {
        var drained = false
        MarkdownImageUndoSideEffect.pendingIO.notify(queue: .main) { drained = true }
        return await waitUntil { drained }
    }

    func beginUndo(viaSynchronize: Bool, completion: @escaping (Bool) -> Void) async throws -> String {
        _ = try await web.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);")
        insert("a.png")
        try #require(await waitUntil { self.workspace.activeTab?.content.contains("images/1.png") == true })
        let inserted = try #require(workspace.activeTab?.content)
        if viaSynchronize {
            // Nur die asynchrone change-Zustellung zurückhalten. prepareAction
            // liefert danach den echten Browserstand an den zweiten Produktcaller.
            let tap = MarkdownVisualMessageTap(coordinator)
            tap.forwardsChanges = false
            web.configuration.userContentController.removeScriptMessageHandler(forName: "visualMarkdown")
            web.configuration.userContentController.add(tap, name: "visualMarkdown")
            messageTap = tap
        }
        schedule.setEnabled(true)
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        if viaSynchronize { coordinator.synchronize(completion) }
        try #require(await waitUntil { self.schedule.counts.arrivals == 1 })
        if !viaSynchronize { coordinator.synchronize(completion) }
        return inserted
    }

    // Acht mögliche Halte prüfen Endlichkeit, ohne die normale Versuchszahl
    // zum Vertrag zu machen. Main bleibt bei jedem echten Dateigate bedienbar.
    func keepChanging(startingAt firstHold: Int = 0, until finished: () -> Bool, onHold: (Int) -> Void = { _ in }) async throws {
        for index in firstHold..<8 {
            try #require(await waitUntil { self.schedule.counts.arrivals > index || finished() })
            if finished() { return }
            other.tabs[0].content = "Version \(index + 1)"
            onHold(index)
            schedule.release(index)
        }
        try #require(await waitUntil { finished() })
    }

    func cleanUp() async {
        messageTap?.forwardsChanges = true
        schedule.setEnabled(false)
        schedule.releaseAll()
        var synchronized = false
        coordinator.synchronize { _ in synchronized = true }
        guard await waitUntil({ synchronized }), await drain(),
              web.undoManager?.isUndoing != true, web.undoManager?.isRedoing != true else {
            Issue.record("Visuelle Bildaktion wurde nicht idle; Fixture bleibt in der Sandbox.")
            return
        }
        let browserIdle = try? await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool
        guard browserIdle == true else {
            Issue.record("Visueller Browser blieb gesperrt; Fixture bleibt in der Sandbox.")
            return
        }
        coordinator.invalidateForSourceReplacement()
        guard await drain() else {
            Issue.record("Visueller Bildabbau wurde nicht zugestellt; Fixture bleibt in der Sandbox.")
            return
        }
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        window.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("Markdown-WYSIWYG", .serialized)
struct MarkdownVisualTests {

    @Test("Wiederholte Texteingaben erhalten Absatzabstände und Dateiende", arguments: ["", "\n", "\n\n", "\r\n", "\r\n\r\n"])
    @MainActor
    func repeatedEditsKeepBlockSeparators(_ ending: String) async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("visual-existing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.md")
        let separator = ending.contains("\r") ? "\r\n" : "\n"
        let prefix = "Anfang äöü 😀" + separator + separator + "Vor "
        try (prefix + "Ergebnis" + ending).write(to: file, atomically: true, encoding: .utf8)
        for round in 1...3 {
            let source = try String(contentsOf: file, encoding: .utf8)
            let (workspace, coordinator, web, window) = try await editor(source, documentURL: file)
            defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
            workspace.tabs[0].diskSnapshot = try FileSnapshot.readSnapshotOnly(from: file)
            var saveError: String?
            workspace.saveSafetyWarningHandler = { saveError = $0 + ": " + $1 }
            _ = try await web.callAsyncJavaScript("""
                const root=document.querySelector('#fastra-visual'),walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
                let n;while(walker.nextNode()){if(walker.currentNode.data.includes('Ergebnis')){n=walker.currentNode;break;}}
                root.focus();const r=document.createRange();r.setStart(n,n.data.indexOf('Ergebnis'));r.setEnd(n,n.data.length);
                getSelection().removeAllRanges();getSelection().addRange(r);document.execCommand('insertText',false,text);fastraVisual.flush();
                """, arguments: ["text": "Ergebnis \(round)"], in: nil, contentWorld: .page)
            try #require(await waitUntil { workspace.activeTab?.isDirty == true })
            let expected = prefix + "Ergebnis \(round)" + ending
            #expect(workspace.activeTab?.content == expected, Comment(rawValue: "Runde \(round): \(String(reflecting: workspace.activeTab?.content))"))
            workspace.saveActiveTab()
            try #require(await waitUntil { saveError != nil || workspace.activeTab?.isDirty == false })
            try #require(saveError == nil, Comment(rawValue: saveError ?? ""))
            #expect(try Data(contentsOf: file) == Data(expected.utf8))
            let id = try #require(workspace.activeTabID)
            workspace.closeTab(id: id)
            try #require(await waitUntil { !workspace.tabs.contains { $0.id == id } })
        }
    }

    @Test("Überschrift zu Fließtext erhält die Trennung zum Folgeabsatz")
    @MainActor
    func plainParagraphKeepsAdjacentBlockBoundary() async throws {
        try await assertFormatPersistence("# Ergebnis\nDanach\n", selection: """
            const n=document.querySelector('#fastra-visual h1').firstChild,r=document.createRange();r.selectNodeContents(n);
            getSelection().removeAllRanges();getSelection().addRange(r);
            """, dark: false, command: .plainParagraph,
            expectation: "JSON.stringify(Array.from(document.querySelectorAll('#fastra-visual p:not([data-md-edit-boundary])'),n=>n.textContent)) === JSON.stringify(['Ergebnis','Danach'])")
    }

    @Test("Neu gesetzte Hervorhebung übersteht echtes Speichern und einen frischen Editor", arguments: ["Textmarker", "Vor Textmarker danach", "VorTextmarkerdanach", "Vor Textmarker", "– Textmarker", "Textmarker\n\nZweiter Textmarker", "# Textmarker", "- Textmarker", "> Textmarker", "| Textmarker |\n| --- |\n| Textmarker |"], [false, true])
    @MainActor
    func highlightSaveReopen(_ text: String, _ selectAll: Bool) async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("visual-highlight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.md"), source = text + "\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let (workspace, coordinator, web, window) = try await editor(source, documentURL: file)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        workspace.tabs[0].diskSnapshot = try FileSnapshot.readSnapshotOnly(from: file)
        var saveError: String?
        workspace.saveSafetyWarningHandler = { saveError = $0 + ": " + $1 }
        let structureScript = "JSON.stringify(Array.from(document.querySelectorAll('#fastra-visual :is(p,h1,h2,h3,ul,ol,li,blockquote,table,tr,th,td)')).filter(n=>!n.hasAttribute('data-md-edit-boundary')).map(n=>n.tagName))"
        let originalStructure = try await web.evaluateJavaScript(structureScript) as? String
        _ = try await web.evaluateJavaScript("""
            const root=document.querySelector('#fastra-visual'),walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
            let n;while(walker.nextNode()){if(walker.currentNode.data.includes('Textmarker')){n=walker.currentNode;break;}}
            const r=document.createRange(),start=n.data.indexOf('Textmarker');
            if(\(selectAll)){r.selectNodeContents(root);}else{r.setStart(n,start);r.setEnd(n,start+'Textmarker'.length);}
            getSelection().removeAllRanges();getSelection().addRange(r);fastraVisual.command('highlight');
            """)
        let live = try #require(try await web.evaluateJavaScript("document.querySelector('#fastra-visual').innerHTML") as? String)
        #expect(try await web.evaluateJavaScript(structureScript) as? String == originalStructure, Comment(rawValue: live))
        #expect(try await web.evaluateJavaScript("Array.from(document.querySelectorAll('mark')).some(n=>n.textContent.includes('Textmarker'))") as? Bool == true, Comment(rawValue: live))
        workspace.saveActiveTab()
        try #require(await waitUntil { saveError != nil || (workspace.activeTab?.isDirty == false && (try? String(contentsOf: file, encoding: .utf8)) != source) }, Comment(rawValue: "DOM: \(live); Quelle: \(workspace.activeTab?.content ?? "nil")"))
        try #require(saveError == nil, Comment(rawValue: saveError ?? ""))
        let saved = try String(contentsOf: file, encoding: .utf8)
        web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close()
        let (_, reopened, freshWeb, freshWindow) = try await editor(saved, documentURL: file)
        defer { freshWeb.configuration.userContentController.removeAllScriptMessageHandlers(); freshWindow.close(); withExtendedLifetime(reopened) {} }
        #expect(try await freshWeb.evaluateJavaScript(structureScript) as? String == originalStructure, Comment(rawValue: saved))
        #expect(try await freshWeb.evaluateJavaScript("Array.from(document.querySelectorAll('mark')).some(n=>n.textContent.includes('Textmarker'))") as? Bool == true, Comment(rawValue: "Gespeichert: \(saved); vorher: \(live)"))
        #expect(try await freshWeb.evaluateJavaScript("getComputedStyle(document.querySelector('mark') || document.body).backgroundColor") as? String == "rgb(255, 238, 154)")
    }

    @Test("Angrenzende Formatierungen und sichtbare Leerzeilen überstehen Speichern, Schließen und Öffnen",
          arguments: ["marker", "marker-end", "marker-inside", "adjacent", "mixed", "hard-break", "hard-break-list", "leading-blanks"])
    @MainActor
    func reportedFormatAndBreaksSaveReopen(_ example: String) async throws {
        let source: String, edit: String, reopened: String
        switch example {
        case "marker":
            source = "abc=def\n"
            edit = "select(paragraph().firstChild,4,6);fastraVisual.command('highlight');"
            reopened = "document.querySelector('mark')?.textContent==='de' && paragraph().textContent==='abc=def'"
        case "marker-end":
            source = "a= b\n"
            edit = "select(paragraph().firstChild,0,2);fastraVisual.command('highlight');"
            reopened = "document.querySelector('mark')?.textContent==='a=' && paragraph().textContent==='a= b'"
        case "marker-inside":
            source = "a \\=\\= b\n"
            edit = "select(paragraph().firstChild,0,paragraph().textContent.length);fastraVisual.command('highlight');"
            reopened = "document.querySelector('mark')?.textContent==='a == b' && paragraph().textContent==='a == b'"
        case "adjacent":
            source = "rotgelb\n"
            edit = """
                select(paragraph().firstChild,0,3);fastraVisual.command('highlight');
                const next=paragraph().lastChild;
                select(next,0,next.length);fastraVisual.command('highlight');
                """
            reopened = "Array.from(document.querySelectorAll('mark'),n=>n.textContent).join('')==='rotgelb' && paragraph().textContent==='rotgelb'"
        case "mixed":
            source = "ab *cd* ef\n"
            edit = """
                const r=document.createRange();r.setStart(paragraph().firstChild,0);r.setEnd(document.querySelector('em').firstChild,1);
                getSelection().removeAllRanges();getSelection().addRange(r);fastraVisual.command('bold');
                """
            reopened = "document.querySelector('strong')?.textContent==='ab c' && paragraph().textContent==='ab cd ef'"
        case "hard-break":
            source = "A\r\n\r\nB\r\n"
            edit = "select(paragraph().firstChild,1,1);fastraVisual.command('hardBreak');fastraVisual.command('hardBreak');"
            reopened = "document.querySelectorAll('#fastra-visual .fastra-visible-blank-line').length===2 && paragraph().textContent==='A'"
        case "hard-break-list":
            source = "- A B\n- C\n"
            edit = "select(document.querySelector('li').firstChild,1,1);fastraVisual.command('hardBreak');fastraVisual.command('hardBreak');"
            reopened = "document.querySelectorAll('li').length===2 && document.querySelector('li').querySelectorAll('br').length===2"
        default:
            source = ""
            edit = """
                select(paragraph(),0,0);for(let i=0;i<4;i++)document.execCommand('insertParagraph');
                document.execCommand('insertText',false,'B');
                """
            reopened = "document.querySelectorAll('.fastra-visible-blank-line').length===4 && paragraph().textContent==='B'"
        }
        let directory = testTemporaryDirectory().appendingPathComponent("visual-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.md")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let (workspace, coordinator, web, window) = try await editor(source, documentURL: file)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        workspace.tabs[0].diskSnapshot = try FileSnapshot.readSnapshotOnly(from: file)
        var failure: MarkdownVisualCoordinator.SaveCheck?
        workspace.markdownSaveWarningHandler = { failure = $0 }
        let paragraph = "const paragraph=()=>document.querySelector('#fastra-visual p:not([data-md-edit-boundary])');"
        _ = try await web.evaluateJavaScript("""
            (()=>{\(paragraph)
            function select(n,a,b){const r=document.createRange();r.setStart(n,a);r.setEnd(n,b);getSelection().removeAllRanges();getSelection().addRange(r);}
            \(edit)})()
            """)
        workspace.saveActiveTab()
        try #require(await waitUntil { failure != nil || (workspace.activeTab?.isDirty == false && (try? String(contentsOf: file, encoding: .utf8)) != source) })
        try #require(failure == nil, Comment(rawValue: String(describing: failure)))
        let saved = try Data(contentsOf: file)
        if example == "hard-break" {
            let savedText = String(decoding: saved, as: UTF8.self)
            #expect(!savedText.contains("<br"), Comment(rawValue: savedText))
            #expect(savedText.contains("\r\n  \r\n"), Comment(rawValue: savedText))
        }
        let tabID = try #require(workspace.activeTabID)
        workspace.closeTab(id: tabID)
        try #require(await waitUntil { !workspace.tabs.contains { $0.id == tabID } })
        let (_, newCoordinator, freshWeb, freshWindow) = try await reopenEditor(at: file, savedBytes: saved)
        defer { freshWeb.configuration.userContentController.removeAllScriptMessageHandlers(); freshWindow.close(); withExtendedLifetime(newCoordinator) {} }
        #expect(try await freshWeb.evaluateJavaScript("(()=>{\(paragraph)return \(reopened);})()") as? Bool == true,
                Comment(rawValue: String(decoding: saved, as: UTF8.self)))
    }

    @Test("Speicherprüfung hält eine sichtbar verlustreiche Fassung und das Schließen mit Speichern an")
    @MainActor
    func saveAppearanceRejectsLossEvenWithCleanModel() async throws {
        let file = testTemporaryDirectory().appendingPathComponent("visual-save-check-\(UUID().uuidString).md")
        let source = "Ergebnis\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let (workspace, coordinator, web, window) = try await editor(source, documentURL: file)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        workspace.tabs[0].diskSnapshot = try FileSnapshot.readSnapshotOnly(from: file)
        var warnings: [MarkdownVisualCoordinator.SaveCheck] = []
        var writes = 0
        workspace.markdownSaveWarningHandler = { warnings.append($0) }
        workspace.saveBeforeCoordinateHandler = { _ in writes += 1 }
        let tabID = try #require(workspace.activeTabID)
        _ = try await web.evaluateJavaScript("""
            (()=>{const p=document.querySelector('#fastra-visual p'),r=document.createRange();
            r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r);fastraVisual.command('highlight');
            const prepare=fastraVisual.prepareAction;
            fastraVisual.prepareAction=(...args)=>({...prepare(...args),markdown:'Ergebnis\\n'});})()
            """)
        workspace.saveActiveTab()
        try #require(await waitUntil { warnings.count == 1 || writes > 0 })
        #expect(warnings == [.format])
        #expect(writes == 0)
        #expect(workspace.tabs[0].isDirty == false)
        #expect(try String(contentsOf: file, encoding: .utf8) == source)
        #expect(try await web.evaluateJavaScript("document.querySelector('mark')?.textContent") as? String == "Ergebnis")
        workspace.confirmCloseHandler = { _ in .save }
        workspace.closeTab(id: tabID)
        try #require(await waitUntil { warnings.count == 2 || !workspace.tabs.contains { $0.id == tabID } })
        #expect(warnings == [.format, .format])
        #expect(workspace.activeTabID == tabID)
        workspace.confirmCloseHandler = { _ in .dontSave }
        workspace.closeTab(id: tabID)
        try #require(await waitUntil { !workspace.tabs.contains { $0.id == tabID } })
        #expect(writes == 0)
    }

    @Test("Alle Markdown-Werkzeuge erhalten ihre sichtbare Wirkung nach Speichern und Wiederöffnen",
          arguments: MarkdownFormatCommand.allCases, [false, true])
    @MainActor
    func formatOptionsSaveReopen(_ command: MarkdownFormatCommand, _ dark: Bool) async throws {
        var source = "Vor Ergebnis danach\n", value = "", selector = "p", expectation: String
        switch command {
        case .bold: expectation = "document.querySelector('strong,b')?.textContent === 'Ergebnis'"
        case .italic: expectation = "document.querySelector('em,i')?.textContent === 'Ergebnis'"
        case .highlight: expectation = "document.querySelector('mark')?.textContent === 'Ergebnis'"
        case .code: expectation = "document.querySelector('code')?.textContent === 'Ergebnis'"
        case .heading1: expectation = "document.querySelector('h1')?.textContent === 'Vor Ergebnis danach'"
        case .heading2: expectation = "document.querySelector('h2')?.textContent === 'Vor Ergebnis danach'"
        case .heading3: expectation = "document.querySelector('h3')?.textContent === 'Vor Ergebnis danach'"
        case .plainParagraph:
            source = "# **Ergebnis**\n"; selector = "h1"
            expectation = "!document.querySelector('h1,strong,b') && document.querySelector('p:not([data-md-edit-boundary])')?.textContent === 'Ergebnis'"
        case .bulletList: expectation = "document.querySelector('ul li')?.textContent === 'Vor Ergebnis danach'"
        case .orderedList: expectation = "document.querySelector('ol li')?.textContent === 'Vor Ergebnis danach'"
        case .taskList: expectation = "!!document.querySelector('li input[type=checkbox]')"
        case .quote: expectation = "document.querySelector('blockquote')?.textContent.includes('Ergebnis') === true"
        case .hardBreak:
            source = "ErgebnisDanach\n"
            expectation = "document.querySelector('p')?.querySelectorAll('br').length === 1"
        case .link:
            value = "https://example.invalid/ziel"
            expectation = "document.querySelector('a')?.getAttribute('href') === 'https://example.invalid/ziel'"
        case .insertTable:
            source = "Ergebnis\n"
            value = "<table data-md-table=\"gfm\"><thead><tr><th>Kopf</th></tr></thead><tbody><tr><td>Zelle</td></tr></tbody></table><p><br></p>"
            expectation = "document.querySelector('th')?.textContent === 'Kopf' && document.querySelector('td')?.textContent === 'Zelle'"
        }
        let selection = """
            const p=document.querySelector('#fastra-visual \(selector)'),walker=document.createTreeWalker(p,NodeFilter.SHOW_TEXT);
            let n;while(walker.nextNode()){if(walker.currentNode.data.includes('Ergebnis')){n=walker.currentNode;break;}}
            const r=document.createRange(),start=n.data.indexOf('Ergebnis');
            r.setStart(n,start);r.setEnd(n,start+'Ergebnis'.length);
            if(\(command == .hardBreak))r.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(r);
            """
        try await assertFormatPersistence(source, selection: selection, dark: dark,
                                          command: command, value: value, expectation: expectation)
    }

    @Test("Inline-Formate erhalten Satzzeichen zwischen Buchstaben", arguments: [MarkdownFormatCommand.bold, .italic, .highlight, .code])
    @MainActor
    func punctuationFormatSaveReopen(_ command: MarkdownFormatCommand) async throws {
        let selector: String
        switch command {
        case .bold: selector = "strong,b"
        case .italic: selector = "em,i"
        case .highlight: selector = "mark"
        default: selector = "code"
        }
        try await assertFormatPersistence("a!b\n", selection: """
            const n=document.querySelector('#fastra-visual p').firstChild,r=document.createRange();
            r.setStart(n,1);r.setEnd(n,2);getSelection().removeAllRanges();getSelection().addRange(r);
            """, dark: false, command: command,
            expectation: "document.querySelector('\(selector)')?.textContent === '!'")
    }

    @Test("Inline-Teilauswahl über zwei Absätze erhält Absatzgrenzen beim Speichern",
          arguments: [MarkdownFormatCommand.bold, .italic, .highlight, .code])
    @MainActor
    func partialMultiParagraphFormatSaveReopen(_ command: MarkdownFormatCommand) async throws {
        let selector: String
        switch command {
        case .bold: selector = "strong,b"
        case .italic: selector = "em,i"
        case .highlight: selector = "mark"
        default: selector = "code"
        }
        try await assertFormatPersistence("Alpha eins\n\nBeta zwei\n", selection: """
            const ps=document.querySelectorAll('#fastra-visual p'),r=document.createRange();
            r.setStart(ps[0].firstChild,6);r.setEnd(ps[1].firstChild,4);
            getSelection().removeAllRanges();getSelection().addRange(r);
            """, dark: false, command: command, expectation: """
            (()=>{const root=document.querySelector('#fastra-visual'),ps=Array.from(root.querySelectorAll('p:not([data-md-edit-boundary])'));
            return ps.length===2 && ps[0].textContent==='Alpha eins' && ps[1].textContent==='Beta zwei'
              && Array.from(ps[0].querySelectorAll('\(selector)')).some(n=>n.textContent==='eins')
              && Array.from(ps[1].querySelectorAll('\(selector)')).some(n=>n.textContent==='Beta');})()
            """)
    }

    @Test("Formatierungen in Tabellenzellen bleiben nach Wiederöffnen erhalten",
          arguments: [MarkdownFormatCommand.bold, .italic, .highlight, .code, .hardBreak, .link, .plainParagraph])
    @MainActor
    func tableFormatsSaveReopen(_ command: MarkdownFormatCommand) async throws {
        var source = "| Kopf |\n| --- |\n| ErgebnisDanach |\n", selector: String, expected: String
        switch command {
        case .bold: selector = "strong,b"
        case .italic: selector = "em,i"
        case .highlight: selector = "mark"
        case .code: selector = "code"
        case .heading1: selector = "h1"
        case .heading2: selector = "h2"
        case .heading3: selector = "h3"
        case .bulletList: selector = "ul li"
        case .orderedList: selector = "ol li"
        case .taskList: selector = "li input[type=checkbox]"
        case .quote: selector = "blockquote"
        case .hardBreak: selector = "br"
        case .link: selector = "a"
        default: source = "| Kopf |\n| --- |\n| **Ergebnis**Danach |\n"; selector = ""
        }
        expected = selector.isEmpty ? "!document.querySelector('td strong,td b')" : command == .hardBreak
            ? "document.querySelector('td').textContent.includes('\\n') || !!document.querySelector('td br')"
            : "!!document.querySelector('td')?.querySelector('\(selector)')"
        try await assertFormatPersistence(source, selection: """
            const cell=document.querySelector('td'),walker=document.createTreeWalker(cell,NodeFilter.SHOW_TEXT);
            walker.nextNode();const n=walker.currentNode,r=document.createRange();r.setStart(n,0);r.setEnd(n,'Ergebnis'.length);
            if(\(command == .hardBreak))r.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(r);
            """, dark: false, command: command, value: "https://example.invalid/ziel", expectation: expected)
    }

    @Test("Nicht speicherbare Blockformate in Tabellen werden vor der Änderung erklärt",
          arguments: ["heading1", "heading2", "heading3", "bulletList", "orderedList", "taskList", "quote", "insertTable"])
    @MainActor
    func tableRejectsBlockFormats(_ command: String) async throws {
        let source = "| Kopf |\n| --- |\n| Ergebnis |\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        let before = try await renderedFormatState(web)
        let applied = try await web.evaluateJavaScript("""
            const n=document.querySelector('td'),r=document.createRange();r.selectNodeContents(n);
            getSelection().removeAllRanges();getSelection().addRange(r);fastraVisual.command('\(command)','');
            """) as? Bool
        #expect(applied == false)
        try #require(await waitUntil { workspace.markdownTable.context != nil && workspace.markdownTable.error != nil })
        #expect(workspace.activeTab?.content == source)
        #expect(workspace.activeTab?.isDirty == false)
        #expect(try await renderedFormatState(web) == before)
    }

    @Test("Listen und Zitate erhalten Cursor und Teilauswahl beim anschließenden Tippen",
          arguments: [MarkdownFormatCommand.bulletList, .orderedList, .taskList, .quote], [false, true])
    @MainActor
    func blockFormatKeepsSelection(_ command: MarkdownFormatCommand, _ selected: Bool) async throws {
        let expected = selected ? "Alpha !" : "Alpha! Beta"
        try await assertFormatPersistence("Alpha Beta\n", selection: """
            const n=document.querySelector('#fastra-visual p').firstChild,r=document.createRange();
            r.setStart(n,\(selected ? 6 : 5));r.setEnd(n,\(selected ? 10 : 5));getSelection().removeAllRanges();getSelection().addRange(r);
            """, dark: false, command: command,
            expectation: "document.getElementById('fastra-visual').innerText.trim() === '\(expected)'",
            afterFormat: "document.execCommand('insertText',false,'!');fastraVisual.flush();")
    }

    @Test("Blockformatierung über eine Tabellenzellgrenze verändert keinen Inhalt")
    @MainActor
    func blockFormatAcrossCellBoundary() async throws {
        let source = "Vorher\n\n| Kopf |\n| --- |\n| Ergebnis |\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        let applied = try await web.evaluateJavaScript("""
            const p=document.querySelector('p').firstChild,cell=document.querySelector('td'),r=document.createRange();
            r.setStart(p,0);r.setEnd(cell,cell.childNodes.length);getSelection().removeAllRanges();getSelection().addRange(r);
            fastraVisual.command('bulletList');
            """) as? Bool
        #expect(applied == false)
        try #require(await waitUntil { workspace.markdownTable.error != nil })
        #expect(workspace.activeTab?.content == source)
        #expect(workspace.activeTab?.isDirty == false)
    }

    @Test("Hervorheben in einem geschützten HTML-Absatz darf keine nur vorübergehende Markierung erzeugen")
    @MainActor
    func protectedHTMLRejectsFormatting() async throws {
        let source = "<p>Vor Ergebnis danach</p>\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        var warning: String?
        workspace.saveSafetyWarningHandler = { warning = $0 + ": " + $1 }
        let applied = try await web.evaluateJavaScript("""
            const n=document.querySelector('#fastra-visual p').firstChild,r=document.createRange(),start=n.data.indexOf('Ergebnis');
            r.setStart(n,start);r.setEnd(n,start+8);getSelection().removeAllRanges();getSelection().addRange(r);
            fastraVisual.command('highlight');
            """) as? Bool
        #expect(applied == false)
        try #require(await waitUntil { warning != nil })
        #expect(try await web.evaluateJavaScript("document.querySelector('mark') === null") as? Bool == true)
        #expect(workspace.activeTab?.content == source)
    }

    @MainActor
    private func assertFormatPersistence(_ source: String, selection: String, dark: Bool,
                                         command: MarkdownFormatCommand, value: String = "", expectation: String,
                                         afterFormat: String = "") async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("visual-format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.md")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let (workspace, coordinator, web, window) = try await editor(source, documentURL: file)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        workspace.tabs[0].diskSnapshot = try FileSnapshot.readSnapshotOnly(from: file)
        coordinator.updateStyle(fontName: PreviewFonts.systemName, fontSize: 14, darkMode: dark, style: "persistence")
        _ = try await web.evaluateJavaScript(selection)
        if command == .link { coordinator.execute("link", value: value) }
        else if command == .insertTable { coordinator.execute("insertTable", value: value) }
        else { coordinator.format(command) }
        try #require(await waitUntil { workspace.activeTab?.isDirty == true })
        if !afterFormat.isEmpty { _ = try await web.evaluateJavaScript(afterFormat) }
        let liveHTML = try await web.evaluateJavaScript("document.querySelector('#fastra-visual').innerHTML") as? String ?? ""
        try #require(try await web.evaluateJavaScript(expectation) as? Bool == true, Comment(rawValue: liveHTML))
        let before = try await renderedFormatState(web)
        var saveError: String?
        workspace.saveSafetyWarningHandler = { saveError = $0 + ": " + $1 }
        workspace.saveActiveTab()
        try #require(await waitUntil { saveError != nil || workspace.activeTab?.isDirty == false })
        try #require(saveError == nil, Comment(rawValue: saveError ?? ""))
        let savedBytes = try Data(contentsOf: file)
        let saved = try #require(workspace.activeTab?.content)
        try #require(savedBytes == Data(saved.utf8))
        let id = try #require(workspace.activeTabID)
        workspace.tabs.append(EditorTab(title: "anchor.txt", path: "", content: "Anker"))
        var closeConfirmationRequested = false
        workspace.confirmCloseHandler = { _ in closeConfirmationRequested = true; return .cancel }
        let closeProbe = await visualDiagnostic(web, script: visualPhaseProbe("prepareAction"))
        let closeGeneration = coordinator.generation
        let closeStarted = Date()
        workspace.closeTab(id: id)
        // Die verdeckte WebView synchronisiert vor dem Schließen erneut mit
        // WebKit. Auf dem Hosted-Runner dauern einzelne Schließvorgänge über
        // fünf Sekunden; dafür gilt dieselbe Frist wie beim initialen Laden.
        let closed = await waitUntil(timeout: 12) { !workspace.tabs.contains { $0.id == id } }
        let closeDiagnostic = "command=\(command) dark=\(dark) elapsed=\(Date().timeIntervalSince(closeStarted)) "
            + "closed=\(closed) confirmation=\(closeConfirmationRequested) ready=\(coordinator.ready) "
            + "dirty=\(String(describing: workspace.tabs.first { $0.id == id }?.isDirty)) warning=\(saveError ?? "none") "
            + "model=\(String(describing: workspace.tabs.first { $0.id == id }?.content)) "
            + "saved=\(saved.debugDescription) browser=\(coordinator.markdown.debugDescription)"
        if !closed {
            print("FORMAT_CLOSE_PHASE_DIAGNOSTIC installed=\(closeProbe) generationBefore=\(closeGeneration) generation=\(coordinator.generation) historyPerforming=\(workspace.tabs.first { $0.id == id }?.undoHistory.isPerformingAction == true)")
            print("FORMAT_CLOSE_BROWSER_DIAGNOSTIC \(await visualDiagnostic(web, script: visualDiagnosticSnapshot))")
        }
        if !closed || Date().timeIntervalSince(closeStarted) >= 5 {
            print("FORMAT_CLOSE_DIAGNOSTIC \(closeDiagnostic)")
        }
        try #require(closed && !closeConfirmationRequested, Comment(rawValue: closeDiagnostic))
        web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close()
        let (reopenedWorkspace, reopened, fresh, freshWindow) = try await reopenEditor(
            at: file, savedBytes: savedBytes, darkMode: dark
        )
        defer { fresh.configuration.userContentController.removeAllScriptMessageHandlers(); freshWindow.close(); withExtendedLifetime((reopenedWorkspace, reopened)) {} }
        #expect(try await fresh.evaluateJavaScript(expectation) as? Bool == true, Comment(rawValue: "Gespeichert: \(saved); vorher: \(liveHTML)"))
        let after = try await renderedFormatState(fresh)
        let appearanceMatches = try renderedFormatStatesMatch(before, after)
        if !appearanceMatches {
            let details: [String: Any] = ["command": String(describing: command), "dark": dark, "before": before, "after": after,
                "liveHTML": liveHTML, "reopenedHTML": try await fresh.evaluateJavaScript("document.querySelector('#fastra-visual').innerHTML") as? String ?? ""]
            let data = try JSONSerialization.data(withJSONObject: details, options: [.sortedKeys])
            FileHandle.standardError.write(Data("FORMAT_PERSISTENCE_DIAGNOSTIC ".utf8) + data + Data("\n".utf8))
        }
        #expect(appearanceMatches, Comment(rawValue: "Darstellung geändert nach \(command): \(saved)"))
    }

    private func renderedFormatStatesMatch(_ before: String, _ after: String) throws -> Bool {
        let first = try #require(JSONSerialization.jsonObject(with: Data(before.utf8)) as? [[Any]])
        let second = try #require(JSONSerialization.jsonObject(with: Data(after.utf8)) as? [[Any]])
        guard first.count == second.count else { return false }
        for (left, right) in zip(first, second) {
            guard left.count == right.count else { return false }
            for index in left.indices {
                if (1...4).contains(index) {
                    // Textknoten-Grenzen und Kerning runden Range-Rechtecke
                    // unterschiedlich. Ein Punkt Toleranz betrifft nur Geometrie;
                    // Zeichen, Schriften und Farben müssen exakt übereinstimmen.
                    guard let a = left[index] as? Double, let b = right[index] as? Double,
                          abs(a - b) <= 1 else { return false }
                } else if left[index] as? String != right[index] as? String { return false }
            }
        }
        return true
    }

    /// Sichtbare Zeichen, tatsächliche CSS-Werte und Glyphenpositionen vergleichen.
    /// Gleiche Markdown-Texte allein würden einen Darstellungsverlust nicht bemerken.
    @MainActor
    private func renderedFormatState(_ web: WKWebView) async throws -> String {
        try #require(try await web.evaluateJavaScript("""
            (()=>{
              const root=document.getElementById('fastra-visual'),origin=root.getBoundingClientRect(),walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT),state=[];
              const round=n=>Math.round(n*10)/10;
              while(walker.nextNode()){
                const n=walker.currentNode,p=n.parentElement;
                if(p.closest('[data-md-edit-boundary]') || (!n.data.trim() && !p.closest('p,h1,h2,h3,li,td,th,code,mark,strong,b,em,i')))continue;
                const style=getComputedStyle(p);let background='';
                for(let a=p;a && a!==root;a=a.parentElement){const color=getComputedStyle(a).backgroundColor;if(color!=='rgba(0, 0, 0, 0)'){background=color;break;}}
                let offset=0;
                for(const char of n.data){
                  const r=document.createRange();r.setStart(n,offset);offset+=char.length;r.setEnd(n,offset);
                  const rect=r.getBoundingClientRect();if(!rect.width)continue;
                  state.push([char,round(rect.x-origin.x),round(rect.y-origin.y),round(rect.width),round(rect.height),style.fontWeight,style.fontStyle,style.fontFamily,style.fontSize,style.color,background,p.closest('a')?.getAttribute('href') || '']);
                }
              }
              return JSON.stringify(state);
            })()
            """) as? String)
    }

    @Test("Inline-HTML-Gliederungsmarker überleben Bearbeiten und Undo ohne Quelländerung")
    @MainActor func outlineMarkerUndoRoundtrip() async throws {
        let source = "# Echt\n\nText <h2>Inline-HTML</h2> danach.\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        _ = try await web.evaluateJavaScript("""
            const h=document.querySelector('[data-md-outline-ignore]'),r=document.createRange();
            r.selectNodeContents(h);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);
            document.execCommand('insertText',false,'X');fastraVisual.flush();
            """)
        try #require(await waitUntil { workspace.activeTab?.content != source })
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content.utf8.elementsEqual(source.utf8) == true })
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('[data-md-outline-ignore]').length") as? Int == 1)
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
        #expect(MarkdownOutline.headings(in: workspace.activeTab!.content).map(\.title) == ["Echt"])
    }

    @Test("Leerzeichenzeilen zwischen Inline-Code-Umbrüchen bleiben beim Öffnen erhalten")
    @MainActor func inlineCodeWhitespaceLine() async throws {
        let (_, coordinator, web, window) = try await editor("Text\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        _ = try await web.evaluateJavaScript("""
            const p=document.querySelector('p'),r=document.createRange();r.selectNodeContents(p);
            getSelection().removeAllRanges();getSelection().addRange(r);
            document.execCommand('insertHTML',false,'<code>A<br>  <br>B</code>');fastraVisual.flush();
            """)
        let source = try #require(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String)
        coordinator.load(source, documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "reload")
        try #require(await waitUntil { coordinator.ready })
        #expect(try await web.evaluateJavaScript("Array.from(document.querySelectorAll('code'),n=>n.textContent)") as? [String] == ["A", "  ", "B"], Comment(rawValue: source))
    }

    @Test("Quelltext-Ursprünge springen nach Moduswechsel zur bisherigen Überschrift")
    @MainActor func outlineModeSwitchHistory() async throws {
        let source = "# A\n\n## B\n\n### C\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        let outline = workspace.documentOutline
        outline.refresh(in: workspace)
        try #require(await waitUntil { outline.ready })
        workspace.tabs[0].markdownVisualOverride = false
        workspace.visualMarkdownEditor = nil
        workspace.cursorLine = 3; outline.follow(line: 3)
        outline.jump(to: outline.headings[2], in: workspace)
        workspace.tabs[0].markdownVisualOverride = true
        workspace.visualMarkdownEditor = coordinator
        outline.move(-1, in: workspace)
        try #require(await waitUntil { outline.activeHeading == 1 })
        #expect(try await web.evaluateJavaScript("(()=>{const n=getSelection().anchorNode;return (n?.nodeType===1?n:n?.parentElement)?.closest('h2')?.textContent || '';})()") as? String == "B")
    }

    @Test("DPI-Metadaten bestimmen die Bildgröße in WYSIWYG und Vorschau", arguments: [72.0, 144.0, 216.0])
    @MainActor
    func imageLogicalSize(_ dpi: Double) async throws {
        let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("image.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 594, pixelsHigh: 500,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = NSSize(width: 594 * 72 / dpi, height: 500 * 72 / dpi)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)
        let url = directory.appendingPathComponent("test.md")
        let source = "![Bild](image.png)\n"
        let (_, coordinator, visual, window) = try await editor(source, documentURL: url)
        defer { visual.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let fragment = MarkdownRichText.renderedFragment(markdown: source, documentURL: url)
        let handler = MarkdownPreviewSchemeHandler()
        handler.setImageURLs(fragment.imageURLs)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(handler, forURLScheme: MarkdownPreviewAssets.scheme)
        let preview = WKWebView(frame: visual.frame, configuration: config)
        preview.loadHTMLString(MarkdownRichText.htmlDocument(fragment: fragment, fontName: PreviewFonts.systemName,
                                                            fontSize: 14, darkMode: false), baseURL: nil)
        for web in [visual, preview] {
            var dimensions: [Double] = []
            for _ in 0..<240 {
                dimensions = (try? await web.evaluateJavaScript("""
                    (()=>{const i=document.querySelector('img');if(!i?.complete || !i.naturalWidth)return [];
                    const r=i.getBoundingClientRect();return [r.width,r.height];})()
                    """)) as? [Double] ?? []
                if dimensions.count == 2 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(dimensions.count == 2)
            #expect(abs(dimensions[0] - 594 * 72 / dpi) < 1)
            #expect(abs(dimensions[1] - 500 * 72 / dpi) < 1)
        }
        #expect(try await visual.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
        let explicit = MarkdownImages.resolve(in: "<img src=\"image.png\" width=\"123\">", relativeTo: url)
        #expect(explicit.html.contains("width=\"123\""))
        #expect(!explicit.html.contains("width=\"\(594 * 72 / dpi)\""))
        withExtendedLifetime(coordinator) {}
    }

    @Test("Die erste Entfernung geladener Bilder hält Eingabe und Speichern bis zum Dateiabschluss an")
    @MainActor
    func firstImageRemovalWaitsForFiles() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let doc = directory.appendingPathComponent("test.md")
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII=")!
        _ = try MarkdownImageStore.storePastedData(.init(data: bytes, fileExtension: "png"), documentURL: doc)
        let source = "![Bild](images/1.png)\n"
        try Data(source.utf8).write(to: doc)
        let (workspace, coordinator, web, window) = try await editor(source, documentURL: doc)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let queue = DispatchQueue(label: "test.markdown.image-removal")
        queue.async { release.wait() }
        coordinator.imageIOQueue = queue
        _ = try await web.evaluateJavaScript("document.querySelector('img').click();fastraVisual.command('deleteImage');")
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        var synchronized: Bool?
        coordinator.synchronize { synchronized = $0 }
        #expect(synchronized == nil)
        #expect(workspace.activeTab?.content == source)
        release.signal()
        try #require(await waitUntil { synchronized == true })
        #expect(workspace.activeTab?.content.contains("images/1.png") == false)
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
    }

    @Test("Ein verspäteter Vorbereitungsfehler meldet Originalfehler und erhaltene Rückbaureste vor Completion")
    @MainActor
    func staleImagePreparationFailureKeepsDetails() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("note.md")
        let (workspace, coordinator, web, window) = try await editor("Text\n", documentURL: document)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var warnings: [String] = []
        var warningsAtCompletion: [String] = []
        var completed: Bool?
        var retainedClaim: URL?
        workspace.saveSafetyWarningHandler = { _, message in warnings.append(message) }
        coordinator.insertPrepared(bookmark: nil, completion: {
            warningsAtCompletion = warnings
            completed = $0
        }) { target in
            let target = try #require(target)
            let images = try (0..<2).map { index in
                try MarkdownImageStore.storePastedData(.init(data: Data("image-\(index)".utf8), fileExtension: "png"),
                                                       documentURL: target, reserveForTransaction: true)
            }
            started.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw POSIXError(.ETIMEDOUT) }
            let hooks = MarkdownImageRemoval.Hooks(afterClaim: { original, claim in
                if original.lastPathComponent == "2.png" { retainedClaim = claim }
            }, beforeUnlink: { index in
                if index == 1 {
                    try Data("foreign".utf8).write(to: images[1].fileURL)
                    throw POSIXError(.EIO)
                }
            })
            throw MarkdownSaveAs.Prepared(content: "unchanged", createdImages: images).rollback(after: POSIXError(.ENOSPC), hooks: hooks)
        }
        try #require(await waitUntil { started.wait(timeout: .now()) == .success })
        coordinator.generation &+= 1
        release.signal()
        try #require(await waitUntil { completed != nil })
        #expect(completed == false)
        try #require(warningsAtCompletion.count == 1)
        let claim = try #require(retainedClaim)
        #expect(warningsAtCompletion[0].contains(POSIXError(.ENOSPC).localizedDescription))
        #expect(warningsAtCompletion[0].contains(POSIXError(.EIO).localizedDescription))
        #expect(warningsAtCompletion[0].contains(claim.path))
        #expect(try Data(contentsOf: claim) == Data("image-1".utf8))
        #expect(try Data(contentsOf: directory.appendingPathComponent("images/2.png")) == Data("foreign".utf8))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("images/1.png").path))
        #expect(workspace.activeTab?.content == "Text\n")
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == "Text\n")
    }

    @Test("Abgebrochene vorbereitete Einfügung schließt Rückbau und Warnung vor Completion ab", arguments: [false, true])
    @MainActor
    func imageInsertionCompletionWaitsForRollback(_ staleTarget: Bool) async throws {
        let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let second = directory.appendingPathComponent("images/2.png")
        defer {
            if let empty = acl_init(0) {
                _ = acl_set_file(second.path, ACL_TYPE_EXTENDED, empty)
                acl_free(UnsafeMutableRawPointer(empty))
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let document = directory.appendingPathComponent("note.md")
        let (workspace, coordinator, web, window) = try await editor("Text\n", documentURL: document)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let started = DispatchSemaphore(value: 0), releasePreparation = DispatchSemaphore(value: 0)
        let releaseCleanup = DispatchSemaphore(value: 0)
        defer { releasePreparation.signal(); releaseCleanup.signal() }
        // Der reale Rückbau-Dispatcher bleibt gezielt blockiert; weder ein
        // frühes false noch das bloße Einreihen des Rückbaus ist ein Abschluss.
        MarkdownImageUndoSideEffect.ioQueue.async { releaseCleanup.wait() }
        var rejectedByBrowser = false
        let tap = MarkdownVisualMessageTap(coordinator)
        tap.observe = { message in
            if (message.body as? [String: String])?["kind"] == "testInsertionRejected" { rejectedByBrowser = true }
        }
        web.configuration.userContentController.removeScriptMessageHandler(forName: "visualMarkdown")
        web.configuration.userContentController.add(tap, name: "visualMarkdown")
        if !staleTarget {
            _ = try await web.evaluateJavaScript("fastraVisual.insertBookmarked=()=>{window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'testInsertionRejected'});return false;};void 0;")
        }
        var warnings: [String] = [], warningsAtCompletion: [String] = []
        var completed: Bool?
        workspace.saveSafetyWarningHandler = { _, message in warnings.append(message) }
        coordinator.insertPrepared(bookmark: nil, completion: {
            warningsAtCompletion = warnings
            completed = $0
        }) { target in
            let target = try #require(target)
            let images = try (0..<2).map { index in
                try MarkdownImageStore.storePastedData(.init(data: Data("image-\(index)".utf8), fileExtension: "png"),
                                                       documentURL: target, reserveForTransaction: true)
            }
            let acl = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:deny:delete\n"))
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            guard acl_set_file(images[1].fileURL.path, ACL_TYPE_EXTENDED, acl) == 0 else { throw POSIXError(.EACCES) }
            started.signal()
            guard releasePreparation.wait(timeout: .now() + 5) == .success else { throw POSIXError(.ETIMEDOUT) }
            return MarkdownSaveAs.Prepared(content: images.map(\.link).joined(separator: "\n\n"), createdImages: images)
        }
        try #require(await waitUntil { started.wait(timeout: .now()) == .success })
        if staleTarget { coordinator.generation &+= 1 }
        releasePreparation.signal()
        if !staleTarget { try #require(await waitUntil { rejectedByBrowser }) }
        // Ein weiterer WebKit-Roundtrip lässt den bereits abgeschickten
        // nativen Einfügecallback laufen, während die Datei-Queue gesperrt bleibt.
        _ = try await web.evaluateJavaScript("true")
        #expect(completed == nil)
        #expect(warnings.isEmpty)
        releaseCleanup.signal()
        try #require(await waitUntil { completed != nil })
        #expect(completed == false)
        #expect(!warningsAtCompletion.isEmpty)
        #expect(warningsAtCompletion.contains(where: { $0.contains("1.png") }))
        #expect(try Data(contentsOf: directory.appendingPathComponent("images/1.png")) == Data("image-0".utf8))
        #expect(try Data(contentsOf: second) == Data("image-1".utf8))
        #expect(workspace.activeTab?.content == "Text\n")
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == "Text\n")
        withExtendedLifetime(tap) {}
    }

    @MainActor
    private func withVisualImageReferences(_ body: (VisualImageReferenceFixture) async throws -> Void) async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("visual-references-\(UUID().uuidString)")
        for name in ["A", "B"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let document = directory.appendingPathComponent("A/note.md")
        try "Text\n".write(to: document, atomically: true, encoding: .utf8)
        let fixture = try await VisualImageReferenceFixture(directory: directory, editor: editor("Text\n", documentURL: document))
        do { try await body(fixture) }
        catch { await fixture.cleanUp(); throw error }
        await fixture.cleanUp()
    }

    @Test("Visuelles Bild-Undo endet bei fortgesetzten Fremdänderungen mit gebundenem Text, Warnung und Redo")
    @MainActor
    func imageReferenceChurnCompletes() async throws {
        try await withVisualImageReferences { fixture in
            let web = fixture.web, coordinator = fixture.coordinator, workspace = fixture.workspace
            _ = try await web.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);")
            fixture.insert("a.png")
            try #require(await waitUntil { workspace.activeTab?.content.contains("images/1.png") == true })
            let inserted = try #require(workspace.activeTab?.content)
            fixture.schedule.setEnabled(true)
            _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
            try #require(await waitUntil { fixture.schedule.counts.arrivals == 1 })
            #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
            var completions: [Bool] = []
            coordinator.synchronize { completions.append($0) }
            var idle = false
            MarkdownImageUndoSideEffect.pendingIO.notify(queue: .main) { idle = true }
            var invalidationTexts: [String] = []
            try await fixture.keepChanging(until: { workspace.activeTab?.content == "Text\n" }) { _ in
                #expect(completions.isEmpty)
                #expect(!idle)
                MarkdownImageUndoBuffer.shared.invalidate { invalidationTexts.append(workspace.activeTab?.content ?? "nil") }
            }
            try #require(await waitUntil { completions == [true] && idle })
            #expect(fixture.notSettledWarnings.count == 1)
            #expect(fixture.warnings.count == 1)
            let terminalWarnings = fixture.warnings
            #expect(invalidationTexts.count == fixture.schedule.counts.arrivals)
            #expect(invalidationTexts.allSatisfy { $0 == "Text\n" })
            #expect(fixture.schedule.counts.claims == 0)
            #expect(fixture.schedule.counts.unlinks == 0)
            #expect(try Data(contentsOf: fixture.first) == fixture.bytes)
            #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == "Text\n")
            #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
            fixture.schedule.setEnabled(false)
            let arrivals = fixture.schedule.counts.arrivals
            _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
            try #require(await waitUntil { workspace.activeTab?.content == inserted })
            #expect(try Data(contentsOf: fixture.first) == fixture.bytes)
            _ = try await web.evaluateJavaScript("const end=document.createRange();end.selectNodeContents(document.getElementById('fastra-visual'));end.collapse(false);getSelection().removeAllRanges();getSelection().addRange(end);document.execCommand('insertText',false,' Ende');fastraVisual.flush();")
            try #require(await waitUntil { workspace.activeTab?.content.contains("Ende") == true })
            #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == workspace.activeTab?.content)
            try #require(await fixture.drain())
            #expect(fixture.schedule.counts.arrivals == arrivals)
            #expect(completions == [true])
            #expect(fixture.notSettledWarnings.count == 1)
            #expect(fixture.warnings == terminalWarnings)
            #expect(fixture.schedule.counts.claims == 0 && fixture.schedule.counts.unlinks == 0)
            #expect(MarkdownImageUndoBuffer.shared.byteCount == 0)
        }
    }

    @Test("Gemischtes visuelles Undo bestätigt bereits restauriertes Bild trotz instabiler Restbereinigung")
    @MainActor
    func imageReferenceMixedUndoCompletes() async throws {
        try await withVisualImageReferences { fixture in
            let web = fixture.web, workspace = fixture.workspace
            _ = try await web.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);")
            fixture.insert("a.png")
            try #require(await waitUntil { workspace.activeTab?.content.contains("images/1.png") == true })
            let firstText = try #require(workspace.activeTab?.content)
            _ = try await web.evaluateJavaScript("const selected=document.createRange();selected.selectNode(document.querySelector('#fastra-visual img'));getSelection().removeAllRanges();getSelection().addRange(selected);")
            fixture.insert("b.png")
            try #require(await waitUntil { workspace.activeTab?.content.contains("images/2.png") == true && workspace.activeTab?.content.contains("images/1.png") == false })
            let secondText = try #require(workspace.activeTab?.content)
            #expect(!FileManager.default.fileExists(atPath: fixture.first.path))
            #expect(try Data(contentsOf: fixture.second) == fixture.bytes)
            fixture.schedule.setEnabled(true)
            _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
            try #require(await waitUntil { fixture.schedule.counts.arrivals == 1 })
            #expect(try Data(contentsOf: fixture.first) == fixture.bytes)
            try await fixture.keepChanging(until: { workspace.activeTab?.content == firstText })
            try #require(await fixture.drain())
            #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == firstText)
            #expect(try Data(contentsOf: fixture.first) == fixture.bytes)
            #expect(try Data(contentsOf: fixture.second) == fixture.bytes)
            #expect(fixture.notSettledWarnings.count == 1)
            #expect(fixture.warnings.count == 1)
            let terminalWarnings = fixture.warnings
            #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
            fixture.schedule.setEnabled(false)
            _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
            try #require(await waitUntil { workspace.activeTab?.content == secondText })
            #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == secondText)
            #expect(!FileManager.default.fileExists(atPath: fixture.first.path))
            #expect(try Data(contentsOf: fixture.second) == fixture.bytes)
            #expect(fixture.notSettledWarnings.count == 1)
            try #require(await fixture.drain())
            #expect(fixture.warnings == terminalWarnings)
        }
    }

    @Test("Terminalwarnung darf bei gleicher Dokumentbasis keine neue Browsersitzung übernehmen", arguments: [false, true])
    @MainActor
    func imageTerminalWarningRejectsReentrantSession(_ viaSynchronize: Bool) async throws {
        try await withVisualImageReferences { fixture in
            let coordinator = fixture.coordinator, workspace = fixture.workspace
            let documentID = workspace.activeTab?.documentID
            var reset = false, base = ""
            var completions: [Bool] = []
            workspace.saveSafetyWarningHandler = { _, message in
                fixture.warnings.append(message)
                guard !reset, !fixture.notSettledWarnings.isEmpty else { return }
                reset = true
                // Modell und Dokumentidentität bleiben gleich; nur load erneuert
                // Generation und Sitzung innerhalb des reentranten Warnhandlers.
                base = workspace.activeTab?.content ?? ""
                coordinator.load(base, documentURL: workspace.activeTab?.url, fontName: PreviewFonts.systemName,
                                 fontSize: 14, darkMode: false, style: "reentrant")
            }
            let inserted = try await fixture.beginUndo(viaSynchronize: viaSynchronize) { completions.append($0) }
            try await fixture.keepChanging(until: { reset })
            try #require(await waitUntil { coordinator.ready && !completions.isEmpty })
            try #require(await fixture.drain())
            #expect(completions == [false])
            #expect(base == inserted && workspace.activeTab?.content == inserted)
            #expect(workspace.activeTab?.documentID == documentID)
            #expect(try await fixture.web.evaluateJavaScript("fastraVisual.markdown()") as? String == inserted)
            #expect(try Data(contentsOf: fixture.first) == fixture.bytes)
            #expect(fixture.notSettledWarnings.count == 1)
            fixture.messageTap?.forwardsChanges = true
            _ = try await fixture.web.evaluateJavaScript("const end=document.createRange();end.selectNodeContents(document.getElementById('fastra-visual'));end.collapse(false);getSelection().removeAllRanges();getSelection().addRange(end);document.execCommand('insertText',false,' neu');fastraVisual.flush();")
            try #require(await waitUntil { workspace.activeTab?.content.contains("neu") == true })
        }
    }

    @Test("Terminale Textannahme lehnt neue Basis oder fehlende Schreibbarkeit ab", arguments: [false, true], [false, true])
    @MainActor
    func imageTerminalWarningRejectsUnacceptedText(_ viaSynchronize: Bool, _ readOnly: Bool) async throws {
        try await withVisualImageReferences { fixture in
            let workspace = fixture.workspace
            var rejected = false
            var completions: [Bool] = []
            workspace.saveSafetyWarningHandler = { _, message in
                fixture.warnings.append(message)
                guard !rejected, !fixture.notSettledWarnings.isEmpty else { return }
                rejected = true
                if readOnly { workspace.tabs[0].isLoading = true }
                else { workspace.tabs[0].content = "Neuere Basis\n" }
            }
            let inserted = try await fixture.beginUndo(viaSynchronize: viaSynchronize) { completions.append($0) }
            try await fixture.keepChanging(until: { rejected })
            let terminalArrivals = fixture.schedule.counts.arrivals
            #expect(terminalArrivals <= 3)
            try #require(await waitUntil { !completions.isEmpty })
            try #require(await fixture.drain())
            #expect(completions == [false])
            #expect(fixture.schedule.counts.arrivals == terminalArrivals)
            #expect(workspace.activeTab?.content == (readOnly ? inserted : "Neuere Basis\n"))
            #expect(fixture.notSettledWarnings.count == 1)
            #expect(fixture.schedule.counts.claims == 0 && fixture.schedule.counts.unlinks == 0)
            #expect(MarkdownImageUndoBuffer.shared.byteCount == 0)
            #expect(try Data(contentsOf: fixture.first) == fixture.bytes)
            // Auch eine neue, unabhängig gestartete Anfrage trifft weiterhin
            // dieselbe Schreib-/Basisgrenze, ohne einen vierten Dateiversuch.
            var subsequent: [Bool] = []
            fixture.coordinator.synchronize { subsequent.append($0) }
            try #require(await waitUntil { !subsequent.isEmpty })
            try #require(await fixture.drain())
            #expect(subsequent == [false] && completions == [false])
            #expect(fixture.schedule.counts.arrivals == terminalArrivals)
            #expect(fixture.schedule.counts.claims == 0 && fixture.schedule.counts.unlinks == 0)
            #expect(MarkdownImageUndoBuffer.shared.byteCount == 0)
            #expect(workspace.activeTab?.content == (readOnly ? inserted : "Neuere Basis\n"))
            #expect(try Data(contentsOf: fixture.first) == fixture.bytes)
            workspace.tabs[0].isLoading = false
        }
    }

    @Test("Schreibablehnung gibt nach reentranter Dokumentverlagerung keine neue Aktion frei")
    @MainActor
    func imageWriteRejectionKeepsRelocatedActionFenced() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("visual-relocated-rejection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("note.md")
        let relocated = directory.appendingPathComponent("renamed.md")
        let (workspace, coordinator, web, window) = try await editor("Text\n", documentURL: original)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        var oldCompletions: [Bool] = [], newCompletions: [Bool] = []
        var warnings = 0
        var newHold: MarkdownVisualCoordinator.ActionHold?
        workspace.tabs[0].isLoading = true
        workspace.saveSafetyWarningHandler = { _, _ in
            warnings += 1
            guard warnings == 1 else { return }
            workspace.tabs[0].url = relocated
            // relocateDocument erneuert die Generation, behält aber bewusst
            // dieselbe WebKit-Sitzung und ready. Die neue Sperre gehört ihr.
            coordinator.relocateDocument(from: original, to: relocated)
            workspace.tabs[0].isLoading = false
            coordinator.synchronize(holdingInput: true) { succeeded, hold in newCompletions.append(succeeded); newHold = hold }
        }
        coordinator.synchronize { oldCompletions.append($0) }
        try #require(await waitUntil { !oldCompletions.isEmpty && !newCompletions.isEmpty })
        #expect(oldCompletions == [false] && newCompletions == [true])
        #expect(warnings == 1)
        #expect(workspace.activeTab?.content == "Text\n" && workspace.activeTab?.url == relocated)
        #expect(coordinator.documentURL == relocated)
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == "Text\n")
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        newHold?.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        #expect(oldCompletions == [false] && newCompletions == [true])
    }

    @Test("Sitzungswechsel nach angenommener Terminaländerung gibt keine neue Aktion frei", arguments: [false, true])
    @MainActor
    func imageTerminalCompletionKeepsCapturedSession(_ viaSynchronize: Bool) async throws {
        try await withVisualImageReferences { fixture in
            let coordinator = fixture.coordinator, workspace = fixture.workspace, web = fixture.web
            let queue = coordinator.imageIOQueue
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            var blocked = false, idle = false
            var completions: [Bool] = [], newCompletions: [Bool] = []
            var newHold: MarkdownVisualCoordinator.ActionHold?
            workspace.saveSafetyWarningHandler = { _, message in
                fixture.warnings.append(message)
                guard !blocked, !fixture.notSettledWarnings.isEmpty else { return }
                blocked = true
                queue.async { entered.signal(); release.wait() }
            }
            _ = try await fixture.beginUndo(viaSynchronize: viaSynchronize) { completions.append($0) }
            try await fixture.keepChanging(until: { workspace.activeTab?.content == "Text\n" })
            try #require(await waitUntil { entered.wait(timeout: .now()) == .success })
            MarkdownImageUndoSideEffect.pendingIO.notify(queue: .main) { idle = true }
            #expect(completions.isEmpty && !idle)
            #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == "Text\n")
            // Das terminale Undo ist angenommen. Sein Churnplan darf den
            // separaten Discard beim folgenden load nicht erneut anhalten.
            fixture.schedule.setEnabled(false)
            workspace.tabs[0].content = "Neue Sitzung\n"
            coordinator.load("Neue Sitzung\n", documentURL: workspace.activeTab?.url, fontName: PreviewFonts.systemName,
                             fontSize: 14, darkMode: false, style: "after-acceptance")
            try #require(await waitUntil { coordinator.ready })
            coordinator.synchronize(holdingInput: true) { succeeded, hold in newCompletions.append(succeeded); newHold = hold }
            #expect(newCompletions.isEmpty && completions.isEmpty && !idle)
            release.signal()
            try #require(await waitUntil { !completions.isEmpty && !newCompletions.isEmpty && idle })
            #expect(completions == [false] && newCompletions == [true])
            #expect(workspace.activeTab?.content == "Neue Sitzung\n")
            #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == "Neue Sitzung\n")
            #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
            newHold?.finish()
            try #require(await waitUntil { fixture.notSettledWarnings.count == 1 })
            try #require(await fixture.drain())
            #expect(fixture.warnings.count == 1)
        }
    }

    @Test("Speichern wartet auch nach Textannahme auf den terminalen Bildabschluss")
    @MainActor
    func imageTerminalSaveWaitsForRetirement() async throws {
        try await withVisualImageReferences { fixture in
            let workspace = fixture.workspace, coordinator = fixture.coordinator
            let document = try #require(workspace.activeTab?.url)
            try "Vor dem Speichern\n".write(to: document, atomically: true, encoding: .utf8)
            workspace.tabs[0].diskSnapshot = try FileSnapshot.readSnapshotOnly(from: document)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            var queued = false, completions: [Bool] = []
            workspace.saveSafetyWarningHandler = { _, message in
                fixture.warnings.append(message)
                guard !queued, !fixture.notSettledWarnings.isEmpty else { return }
                queued = true
                coordinator.imageIOQueue.async { entered.signal(); release.wait() }
                workspace.saveActiveTab()
            }
            _ = try await fixture.beginUndo(viaSynchronize: false) { completions.append($0) }
            try await fixture.keepChanging(until: { workspace.activeTab?.content == "Text\n" })
            try #require(await waitUntil { entered.wait(timeout: .now()) == .success })
            #expect(completions.isEmpty)
            #expect(try String(contentsOf: document) == "Vor dem Speichern\n")
            release.signal()
            try #require(await waitUntil { (try? String(contentsOf: document)) == "Text\n" && workspace.activeTab?.isDirty == false })
            try #require(await fixture.drain())
            #expect(completions == [true])
            #expect(fixture.warnings.count == 1 && fixture.notSettledWarnings.count == 1)
            #expect(try Data(contentsOf: fixture.first) == fixture.bytes)
        }
    }

    @Test("Visueller Terminalabschluss erhält echte Teilfehler und private Reste bis zum Redo-Retry", arguments: [POSIXErrorCode.EIO, .ECANCELED])
    @MainActor
    func imageTerminalRetirementKeepsPartialFailure(_ code: POSIXErrorCode) async throws {
        try await withVisualImageReferences { fixture in
            let coordinator = fixture.coordinator, web = fixture.web, workspace = fixture.workspace
            let lock = NSLock()
            var preparations = 0, fail = true
            var occupied: URL?, retained: URL?, removed: URL?
            coordinator.imageRemovalHooks = .init(afterPreparingDirectory: { url in
                let first = lock.withLock { preparations += 1; return preparations == 1 }
                if !first { try fixture.schedule.hooks.afterPreparingDirectory?(url) }
            }, afterClaim: { original, claim in
                guard lock.withLock({ fail }) else { return }
                if original.lastPathComponent == "2.png" || original.lastPathComponent == "4.png" {
                    try Data("foreign".utf8).write(to: original)
                    lock.withLock { occupied = original; retained = claim }
                } else {
                    lock.withLock { removed = original }
                }
            }, beforeUnlink: { index in
                if index == 1, lock.withLock({ fail }) { throw POSIXError(code) }
            })
            _ = try await web.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);")
            let sources = [fixture.directory.appendingPathComponent("a.png"), fixture.directory.appendingPathComponent("b.png")]
            coordinator.insertImages(sources)
            try #require(await waitUntil { workspace.activeTab?.content.contains("images/2.png") == true })
            coordinator.insertImages(sources)
            try #require(await waitUntil { workspace.activeTab?.content.contains("images/4.png") == true })
            let inserted = try #require(workspace.activeTab?.content)
            fixture.schedule.setEnabled(true)
            _ = try await web.evaluateJavaScript("const all=document.createRange();all.selectNodeContents(document.getElementById('fastra-visual'));getSelection().removeAllRanges();getSelection().addRange(all);document.execCommand('delete');fastraVisual.flush();")
            let target = try #require(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String)
            try await fixture.keepChanging(until: { workspace.activeTab?.content == target })
            try #require(await fixture.drain())
            let paths = lock.withLock { (occupied, retained, removed) }
            let foreign = try #require(paths.0), claim = try #require(paths.1), missing = try #require(paths.2)
            let terminalWarnings = fixture.warnings
            try #require(terminalWarnings.count == 1)
            #expect(fixture.notSettledWarnings.count == 1)
            #expect(terminalWarnings[0].contains(POSIXError(code).localizedDescription))
            #expect(terminalWarnings[0].contains(claim.path) && terminalWarnings[0].contains(missing.path))
            #expect(try Data(contentsOf: claim) == fixture.bytes)
            #expect(try Data(contentsOf: foreign) == Data("foreign".utf8))
            #expect(!FileManager.default.fileExists(atPath: missing.path))
            #expect(MarkdownImageUndoBuffer.shared.byteCount > 0)
            lock.withLock { fail = false }
            fixture.schedule.setEnabled(false)
            _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
            try #require(await waitUntil { fixture.warnings.count == 2 })
            try #require(await fixture.drain())
            #expect(workspace.activeTab?.content == target)
            #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == target)
            #expect(fixture.warnings[0] == terminalWarnings[0])
            #expect(fixture.warnings[1].contains(POSIXError(code).localizedDescription))
            #expect(fixture.warnings[1].contains(claim.path))
            #expect(try Data(contentsOf: claim) == fixture.bytes)
            #expect(try Data(contentsOf: foreign) == Data("foreign".utf8))
            try FileManager.default.removeItem(at: foreign)
            _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
            try #require(await waitUntil { workspace.activeTab?.content == inserted })
            try #require(await fixture.drain())
            for number in 1...4 {
                #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("A/images/\(number).png")) == fixture.bytes)
            }
            #expect(!FileManager.default.fileExists(atPath: claim.path))
            #expect(fixture.warnings.count == 2 && fixture.notSettledWarnings.count == 1)
        }
    }

    @Test("Ein neuer visueller Referenzabbruch warnt nach erledigtem Terminalabschluss erneut")
    @MainActor
    func imageTerminalRetirementDoesNotSuppressNewChurn() async throws {
        try await withVisualImageReferences { fixture in
            var completions: [Bool] = []
            let inserted = try await fixture.beginUndo(viaSynchronize: false) { completions.append($0) }
            try await fixture.keepChanging(until: { !completions.isEmpty })
            try #require(await fixture.drain())
            #expect(completions == [true] && fixture.warnings.count == 1)
            fixture.schedule.setEnabled(false)
            _ = try await fixture.web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
            try #require(await waitUntil { fixture.workspace.activeTab?.content == inserted })
            try #require(await fixture.drain())
            let first = fixture.schedule.counts.arrivals
            fixture.schedule.setEnabled(true)
            _ = try await fixture.web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
            try await fixture.keepChanging(startingAt: first, until: { fixture.workspace.activeTab?.content == "Text\n" })
            try #require(await fixture.drain())
            #expect(fixture.warnings.count == 2 && fixture.notSettledWarnings.count == 2)
            #expect(fixture.schedule.counts.claims == 0 && fixture.schedule.counts.unlinks == 0)
            #expect(try Data(contentsOf: fixture.first) == fixture.bytes)
        }
    }

    @Test("Visueller Referenzretry beruhigt sich oder schützt neue fremde Bildreferenzen", arguments: [0, 1, 2])
    @MainActor
    func imageReferenceSettlesOrProtectsForeignReferences(_ referenceKind: Int) async throws {
        try await withVisualImageReferences { fixture in
            let web = fixture.web, workspace = fixture.workspace
            _ = try await web.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);")
            fixture.insert("a.png")
            try #require(await waitUntil { workspace.activeTab?.content.contains("images/1.png") == true })
            let inserted = try #require(workspace.activeTab?.content)
            fixture.schedule.setEnabled(true)
            _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
            try #require(await waitUntil { fixture.schedule.counts.arrivals == 1 })
            switch referenceKind {
            case 1: fixture.other.tabs[0].content = "![fremd](../A/images/1.png)"
            case 2:
                var tab = EditorTab(title: "new.md", path: "", content: "![fremd](\(fixture.first.absoluteString))")
                tab.url = fixture.directory.appendingPathComponent("B/new.md")
                fixture.other.tabs.append(tab)
            default: fixture.other.tabs[0].content = "Version 1"
            }
            let foreignContents = fixture.other.tabs.map(\.content)
            fixture.schedule.setEnabled(false)
            fixture.schedule.release(0)
            try #require(await waitUntil { workspace.activeTab?.content == "Text\n" })
            try #require(await fixture.drain())
            #expect(fixture.notSettledWarnings.isEmpty)
            #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == "Text\n")
            #expect(FileManager.default.fileExists(atPath: fixture.first.path) == (referenceKind != 0))
            if referenceKind != 0 { #expect(try Data(contentsOf: fixture.first) == fixture.bytes) }
            #expect(fixture.other.tabs.map(\.content) == foreignContents)
            #expect(try String(contentsOf: fixture.directory.appendingPathComponent("B/other.md"), encoding: .utf8) == "Version 0")
            _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
            try #require(await waitUntil { workspace.activeTab?.content == inserted })
            #expect(try Data(contentsOf: fixture.first) == fixture.bytes)
            #expect(fixture.notSettledWarnings.isEmpty)
            if !fixture.warnings.isEmpty { print("VISUAL_REFERENCE_SETTLED_WARNING kind=\(referenceKind) messages=\(fixture.warnings)") }
        }
    }

    @Test("Visueller Abschluss bewahrt bereits entfernte Teilstücke für natives Undo und Redo")
    @MainActor
    func imageReferencePartialProgressCompletes() async throws {
        try await withVisualImageReferences { fixture in
            let web = fixture.web, workspace = fixture.workspace
            _ = try await web.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);")
            fixture.insert("a.png")
            try #require(await waitUntil { workspace.activeTab?.content.contains("images/1.png") == true })
            fixture.insert("b.png")
            try #require(await waitUntil { workspace.activeTab?.content.contains("images/2.png") == true })
            let inserted = try #require(workspace.activeTab?.content)
            fixture.schedule.setEnabled(true)
            _ = try await web.evaluateJavaScript("const all=document.createRange();all.selectNodeContents(document.getElementById('fastra-visual'));getSelection().removeAllRanges();getSelection().addRange(all);document.execCommand('delete');fastraVisual.flush();")
            let target = try #require(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String)
            try #require(await waitUntil { fixture.schedule.counts.arrivals == 1 })
            fixture.schedule.release(0)
            try #require(await waitUntil { fixture.schedule.counts.arrivals == 2 })
            let files = [fixture.first, fixture.second]
            #expect(files.filter { FileManager.default.fileExists(atPath: $0.path) }.count == 1)
            #expect(MarkdownImageUndoBuffer.shared.byteCount > 0)
            try await fixture.keepChanging(startingAt: 1, until: { workspace.activeTab?.content == target })
            try #require(await fixture.drain())
            #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == target)
            #expect(files.filter { FileManager.default.fileExists(atPath: $0.path) }.count == 1)
            #expect(fixture.notSettledWarnings.count == 1)
            fixture.schedule.setEnabled(false)
            _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
            try #require(await waitUntil { workspace.activeTab?.content == inserted })
            for file in files { #expect(try Data(contentsOf: file) == fixture.bytes) }
            _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
            try #require(await waitUntil { workspace.activeTab?.content == target })
            #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            #expect(fixture.notSettledWarnings.count == 1)
        }
    }

    @Test("Wartender Tabwechsel und Schließen behalten die visuelle Bildaktion am Ursprung", arguments: [false, true])
    @MainActor
    func imageReferenceWaitsForTabAction(_ close: Bool) async throws {
        try await withVisualImageReferences { fixture in
            let web = fixture.web, workspace = fixture.workspace
            let sourceID = try #require(workspace.activeTabID)
            let sourceDocumentID = try #require(workspace.activeTab?.documentID)
            let otherTab = EditorTab(title: "neighbour.txt", path: "", content: "Nachbar bleibt")
            workspace.tabs.append(otherTab)
            var confirmations = 0
            workspace.confirmCloseHandler = { _ in confirmations += 1; return .dontSave }
            _ = try await web.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);")
            fixture.insert("a.png")
            try #require(await waitUntil { workspace.activeTab?.content.contains("images/1.png") == true })
            fixture.schedule.setEnabled(true)
            _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
            try #require(await waitUntil { fixture.schedule.counts.arrivals == 1 })
            if close { workspace.closeTab(id: sourceID) } else { workspace.selectTab(id: otherTab.id) }
            #expect(workspace.activeTabID == sourceID)
            #expect(confirmations == 0)
            try await fixture.keepChanging(until: { workspace.activeTabID == otherTab.id })
            try #require(await fixture.drain())
            #expect(workspace.tabs.first { $0.id == otherTab.id }?.content == "Nachbar bleibt")
            if close {
                #expect(!workspace.tabs.contains { $0.id == sourceID })
            } else {
                #expect(workspace.tabs.first { $0.id == sourceID }?.content == "Text\n")
                #expect(workspace.tabs.first { $0.id == sourceID }?.documentID == sourceDocumentID)
                #expect(confirmations == 0)
            }
            #expect(try Data(contentsOf: fixture.first) == fixture.bytes)
            #expect(fixture.notSettledWarnings.count == 1)
        }
    }

    @Test("Echte Quelltextersetzung und spätere Modellbytes werden von altem Bild-Undo nicht überschrieben", arguments: [false, true])
    @MainActor
    func imageReferenceRejectsReplacedOrNewerDocument(_ reload: Bool) async throws {
        try await withVisualImageReferences { fixture in
            let web = fixture.web, coordinator = fixture.coordinator, workspace = fixture.workspace
            _ = try await web.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);")
            fixture.insert("a.png")
            try #require(await waitUntil { workspace.activeTab?.content.contains("images/1.png") == true })
            let documentID = try #require(workspace.activeTab?.documentID)
            fixture.schedule.setEnabled(true)
            _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
            try #require(await waitUntil { fixture.schedule.counts.arrivals == 1 })
            workspace.tabs[0].content = "Neuer Inhalt\n"
            var completions: [Bool] = []
            coordinator.synchronize { completions.append($0) }
            if reload {
                coordinator.invalidateForSourceReplacement()
                coordinator.load("Neuer Inhalt\n", documentURL: workspace.tabs[0].url, fontName: PreviewFonts.systemName,
                                 fontSize: 14, darkMode: false, style: "replacement")
                fixture.schedule.setEnabled(false)
                fixture.schedule.release(0)
                try #require(await waitUntil { coordinator.ready && !completions.isEmpty })
                #expect(fixture.schedule.counts.arrivals == 1)
                #expect(fixture.notSettledWarnings.isEmpty)
            } else {
                try await fixture.keepChanging(until: { !completions.isEmpty })
                #expect(fixture.notSettledWarnings.count == 1)
            }
            try #require(await fixture.drain())
            #expect(completions.count == 1)
            #expect(workspace.activeTab?.content == "Neuer Inhalt\n")
            #expect(workspace.activeTab?.documentID == documentID)
            if reload {
                #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == "Neuer Inhalt\n")
                _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
                #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == "Neuer Inhalt\n")
            } else {
                print("VISUAL_REFERENCE_NEWER_MODEL_BOUNDARY browser=\(String(describing: try await web.evaluateJavaScript("fastraVisual.markdown()"))) model=\(String(describing: workspace.activeTab?.content)) warnings=\(fixture.warnings)")
            }
        }
    }

    @Test("Visuelles Bild-Undo meldet Teilentfernung und erhält Text, RAM und private Reste bis Redo-Retry")
    @MainActor
    func partialImageUndoReportsRetainedFiles() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII=")!
        let sources = [directory.appendingPathComponent("a.png"), directory.appendingPathComponent("b.png")]
        for source in sources { try bytes.write(to: source) }
        let document = directory.appendingPathComponent("note.md")
        let (workspace, coordinator, web, window) = try await editor("Text\n", documentURL: document)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let first = directory.appendingPathComponent("images/1.png")
        let second = directory.appendingPathComponent("images/2.png")
        var retainedClaim: URL?
        var foreignIdentity: MarkdownImageStore.StoredFileIdentity?
        coordinator.imageRemovalHooks = .init(afterClaim: { original, claim in
            if original.lastPathComponent == "2.png" { retainedClaim = claim }
        }, beforeUnlink: { index in
            if index == 1 {
                try Data("foreign".utf8).write(to: second)
                foreignIdentity = try MarkdownImageStore.captureExisting(second).identity
                throw POSIXError(.EIO)
            }
        })
        var warnings: [String] = []
        workspace.saveSafetyWarningHandler = { _, message in warnings.append(message) }
        _ = try await web.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);")
        coordinator.insertImages(sources)
        try #require(await waitUntil { workspace.activeTab?.content.contains("images/2.png") == true })
        let inserted = try #require(workspace.activeTab?.content)
        let secondIdentity = try MarkdownImageStore.captureExisting(second).identity
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == "Text\n" && warnings.count == 1 })
        let claim = try #require(retainedClaim)
        #expect(warnings[0].contains(first.lastPathComponent))
        #expect(warnings[0].contains(claim.path))
        #expect(warnings[0].contains(POSIXError(.EIO).localizedDescription))
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(try Data(contentsOf: second) == Data("foreign".utf8))
        let retainedAttributes = try FileManager.default.attributesOfItem(atPath: claim.path)
        #expect((retainedAttributes[.systemFileNumber] as? NSNumber)?.uint64Value == secondIdentity.inode)
        #expect(try Data(contentsOf: claim) == bytes)
        let retainedBytes = MarkdownImageUndoBuffer.shared.byteCount
        #expect(retainedBytes > 0)
        _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
        try #require(await waitUntil { warnings.count >= 2 })
        #expect(workspace.activeTab?.content == "Text\n")
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#fastra-visual img').length") as? Int == 0)
        #expect(try MarkdownImageStore.captureExisting(second).identity == foreignIdentity)
        #expect(try Data(contentsOf: second) == Data("foreign".utf8))
        #expect(MarkdownImageUndoBuffer.shared.byteCount == retainedBytes)
        #expect(warnings.last?.contains(claim.path) == true)
        try FileManager.default.removeItem(at: second)
        _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == inserted })
        #expect(try Data(contentsOf: first) == bytes)
        #expect(try Data(contentsOf: second) == bytes)
        #expect(try MarkdownImageStore.captureExisting(second).identity.inode == secondIdentity.inode)
        #expect(!FileManager.default.fileExists(atPath: claim.path))
        #expect(MarkdownImageUndoBuffer.shared.byteCount < retainedBytes)
        #expect(warnings.count == 2)
    }

    @Test("Visuelles Redo erklärt fehlende Bilder und übernimmt externe Aktualisierungen am selben Pfad", arguments: [false, true])
    @MainActor
    func onDiskImageRedoChecksMissingAndUpdatedFile(_ updated: Bool) async throws {
        try await withVisualImageReferences { fixture in
            let web = fixture.web, workspace = fixture.workspace
            _ = try await web.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);")
            fixture.insert("a.png")
            try #require(await waitUntil { workspace.activeTab?.content.contains("images/1.png") == true })
            let inserted = try #require(workspace.activeTab?.content)
            let held = fixture.directory.appendingPathComponent("held.png")
            try FileManager.default.moveItem(at: fixture.first, to: held)
            let modificationDate = try #require(FileManager.default.attributesOfItem(atPath: held.path)[.modificationDate] as? Date)
            _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
            try #require(await waitUntil { workspace.activeTab?.content != inserted })
            try #require(await fixture.drain())
            let previous = try #require(workspace.activeTab?.content)
            let warningCount = fixture.warnings.count
            var expectedBytes = fixture.bytes
            var expectedModificationDate: Date?
            if updated {
                let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                bitmap.setColor(.red, atX: 0, y: 0)
                bitmap.setColor(.blue, atX: 1, y: 0)
                expectedBytes = try #require(bitmap.representation(using: .png, properties: [:]))
                try expectedBytes.write(to: fixture.first, options: .atomic)
                try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: fixture.first.path)
                let preservedDate = try #require(FileManager.default.attributesOfItem(atPath: fixture.first.path)[.modificationDate] as? Date)
                #expect(abs(preservedDate.timeIntervalSince(modificationDate)) < 0.001)
                expectedModificationDate = preservedDate
            }
            let before = updated ? try FileSnapshot.readSnapshotOnly(from: fixture.first) : nil
            let counts = fixture.schedule.counts
            _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
            if updated {
                try #require(await waitUntil { workspace.activeTab?.content == inserted })
                try #require(await fixture.drain())
                #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == inserted)
                #expect(try FileSnapshot.readSnapshotOnly(from: fixture.first) == before)
            } else {
                try #require(await waitUntil { fixture.warnings.count > warningCount })
                try #require(await fixture.drain())
                var synchronized = false
                fixture.coordinator.synchronize { _ in synchronized = true }
                try #require(await waitUntil { synchronized })
                #expect(workspace.activeTab?.content == previous)
                #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == previous)
                let imagePath = fixture.first.deletingLastPathComponent().canonicalFileURL
                    .appendingPathComponent(fixture.first.lastPathComponent).path
                let missingMessage = L10n.format("Die benötigte Bilddatei „%@“ fehlt. Stelle sie am ursprünglichen Pfad wieder bereit und versuche Wiederholen erneut.", imagePath)
                #expect(fixture.warnings.dropFirst(warningCount).contains { $0.contains(missingMessage) },
                        Comment(rawValue: "Erwartet: " + missingMessage + "\n" + fixture.warnings.joined(separator: "\n")))
                #expect(!FileManager.default.fileExists(atPath: fixture.first.path))
                try FileManager.default.moveItem(at: held, to: fixture.first)
                _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
                try #require(await waitUntil { workspace.activeTab?.content == inserted })
                try #require(await fixture.drain())
            }
            #expect(fixture.schedule.counts.claims == counts.claims && fixture.schedule.counts.unlinks == counts.unlinks)
            #expect(try Data(contentsOf: fixture.first) == expectedBytes)
            #expect(MarkdownImageUndoBuffer.shared.byteCount == 0)
            var width = 0
            for _ in 0..<120 {
                width = (try await web.evaluateJavaScript("document.querySelector('#fastra-visual img')?.naturalWidth || 0") as? NSNumber)?.intValue ?? 0
                if width == (updated ? 2 : 1) { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(width == (updated ? 2 : 1))
            if updated {
                #expect(try FileManager.default.attributesOfItem(atPath: fixture.first.path)[.modificationDate] as? Date == expectedModificationDate)
                _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
                try #require(await waitUntil { workspace.activeTab?.content == previous })
                try #require(await fixture.drain())
                #expect(try FileSnapshot.readSnapshotOnly(from: fixture.first) == before)
                _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
                try #require(await waitUntil { workspace.activeTab?.content == inserted })
                try #require(await fixture.drain())
                #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == inserted)
                for _ in 0..<120 {
                    width = (try await web.evaluateJavaScript("document.querySelector('#fastra-visual img')?.naturalWidth || 0") as? NSNumber)?.intValue ?? 0
                    if width == 2 { break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                #expect(width == 2)
                #expect(try FileSnapshot.readSnapshotOnly(from: fixture.first) == before)
            }
            #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        }
    }

    @Test("Ordner-Rückgängig schützt noch nicht übernommene Eingaben im visuellen Editor")
    @MainActor
    func folderUndoSynchronizesVisualMarkdown() async throws {
        let folder = testTemporaryDirectory().appendingPathComponent("visual-folder-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let doc = folder.appendingPathComponent("note.md").canonicalFileURL
        try Data("original\n".utf8).write(to: doc)
        let session = try ApplyEngine.apply(plan: ApplyEngine.plan(files: [doc],
            options: SearchOptions(find: "original", replace: "applied", isRegex: false)),
            backupRoot: folder.appendingPathComponent("backups"), cleanupOlderThan: nil)
        let (workspace, coordinator, web, window) = try await editor("applied\n", documentURL: doc)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        workspace.tabs[0].diskSnapshot = try FileSnapshot.readSnapshotOnly(from: doc)
        workspace.tabs[0].recordSavedContentBaseline()
        workspace.lastApplySession = session
        var blocked: [String]?
        workspace.folderApplyConflictHandler = { blocked = $0 }
        _ = try await web.evaluateJavaScript("""
            const paragraph=document.querySelector('#fastra-visual p');
            paragraph.textContent = 'ungesichert';
            true;
            """)
        #expect(workspace.activeTab?.content == "applied\n")
        #expect(!(await workspace.undoLastFolderApply()))
        #expect(blocked?.count == 1)
        #expect(workspace.activeTab?.content == "ungesichert\n" && workspace.activeTab?.hasUnsavedChanges == true)
        #expect(try Data(contentsOf: doc) == Data("applied\n".utf8))
        #expect(workspace.lastApplySession == session)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Bild-Redo-Kollision nimmt den Browser-Link trotz Eingabesperre vollständig zurück")
    @MainActor
    func imageRedoCollisionRollsBackBrowser() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII=")!
        try bytes.write(to: source)
        let (workspace, coordinator, web, window) = try await editor("Text\n", documentURL: directory.appendingPathComponent("test.md"))
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        var warnings: [String] = []
        workspace.saveSafetyWarningHandler = { _, message in warnings.append(message) }
        _ = try await web.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);")
        coordinator.insertImages([source])
        try #require(await waitUntil { workspace.activeTab?.content.contains("images/1.png") == true })
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == "Text\n" })
        let image = directory.appendingPathComponent("images/1.png")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        let foreign = Data("fremd".utf8)
        try foreign.write(to: image)
        _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
        try #require(await waitUntil { !warnings.isEmpty })
        try #require(await waitUntil { coordinator.ready })
        let links = try await web.evaluateJavaScript("document.querySelectorAll('#fastra-visual img').length") as? Int
        #expect(links == 0)
        #expect(workspace.activeTab?.content == "Text\n")
        #expect(try Data(contentsOf: image) == foreign)
    }

    @Test("Visuelles Speichern unter entfernt nur ungesicherte Herkunftskopien", arguments: [false, true])
    @MainActor
    func saveAsProtectsImageOrigins(_ saveBeforeUndo: Bool) async throws {
        let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("test.md")
        let original = "Text\n"
        try original.write(to: document, atomically: true, encoding: .utf8)
        let source = directory.appendingPathComponent("source.png")
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII=")!
        try bytes.write(to: source)
        let (workspace, coordinator, web, window) = try await editor(original, documentURL: document)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        workspace.tabs[0].diskSnapshot = try FileSnapshot.readSnapshotOnly(from: document)
        _ = try await web.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);")
        coordinator.insertImages([source])
        try #require(await waitUntil { workspace.activeTab?.content.contains("images/1.png") == true })
        if saveBeforeUndo {
            workspace.saveActiveTab()
            try #require(await waitUntil { workspace.activeTab?.isDirty == false })
            _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
            try #require(await waitUntil { workspace.activeTab?.content == original })
        }
        let targetDirectory = directory.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let target = targetDirectory.appendingPathComponent("copy.md")
        var saved: Bool?
        let saveStarted = Date()
        workspace.saveTabAs(id: workspace.activeTabID!, to: target, expectedTargetState: .absent, isMarkdown: true) { saved = $0 }
        // Speichern umfasst WebKit-Synchronisierung und Bild-Dateiarbeit.
        // Dafür gilt dieselbe begrenzte Frist wie für den Browseraufbau.
        let saveCompleted = await waitUntil(timeout: 12) { saved != nil }
        let saveElapsed = Date().timeIntervalSince(saveStarted)
        if !saveCompleted || saveElapsed >= 5 {
            print("IMAGE_SAVE_AS_DIAGNOSTIC saved=\(String(describing: saved)) elapsed=\(saveElapsed) ready=\(coordinator.ready) undoBusy=\(workspace.activeTab?.undoHistory.isPerformingAction == true)")
        }
        try #require(saveCompleted)
        try #require(saved == true)
        await withCheckedContinuation { continuation in
            MarkdownImageUndoSideEffect.pendingIO.notify(queue: .main) { continuation.resume() }
        }
        let oldImage = directory.appendingPathComponent("images/1.png")
        #expect(FileManager.default.fileExists(atPath: oldImage.path) == saveBeforeUndo)
        if saveBeforeUndo { #expect(try Data(contentsOf: oldImage) == bytes) }
        let copied = MarkdownImageCleanup.references(try String(contentsOf: target, encoding: .utf8), documentURL: target)
        #expect(copied.count == (saveBeforeUndo ? 0 : 1))
        for image in copied { #expect(try Data(contentsOf: image) == bytes) }
    }

    @Test("Getippter Minus-Anfang wird zur Liste und nicht zu escaped Text", arguments: ["", "Punkt"])
    @MainActor
    func typedMinusStartsList(_ text: String) async throws {
        let (_, coordinator, web, window) = try await editor("")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        _ = try await web.evaluateJavaScript("""
            const p=document.querySelector('#fastra-visual p'),r=document.createRange();
            r.selectNodeContents(p);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);
            document.execCommand('insertText',false,'-');document.execCommand('insertText',false,' ');
            """)
        let result = try await web.evaluateJavaScript("""
            const listAfterSpace=document.querySelectorAll('#fastra-visual li').length;
            document.execCommand('insertText',false,'\(text)');document.execCommand('insertParagraph');fastraVisual.flush();
            JSON.stringify({listAfterSpace,markdown:fastraVisual.markdown(),html:document.getElementById('fastra-visual').innerHTML});
            """) as? String
        let data = try #require(result?.data(using: .utf8))
        let state = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(state["listAfterSpace"] as? Int == 1, Comment(rawValue: result ?? ""))
        let markdown = try #require(state["markdown"] as? String)
        #expect(!markdown.contains("\\-"), Comment(rawValue: result ?? ""))
        if !text.isEmpty { #expect(markdown.contains("- Punkt"), Comment(rawValue: result ?? "")) }
    }

    @Test("Fett und Kursiv in Überschriften bleiben nach Neuaufbau erhalten",
          arguments: [1, 2, 3], [MarkdownFormatCommand.bold, .italic])
    @MainActor
    func headingInlineFormatPersists(_ level: Int, _ command: MarkdownFormatCommand) async throws {
        let source = String(repeating: "#", count: level) + " Titel\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime((workspace, coordinator)) {} }
        _ = try await web.evaluateJavaScript("""
            const h=document.querySelector('h\(level)'),r=document.createRange();r.selectNodeContents(h);
            getSelection().removeAllRanges();getSelection().addRange(r);
            """)
        coordinator.format(command)
        var saved: String?
        try #require(await waitUntil {
            if saved != nil { return true }
            web.evaluateJavaScript("fastraVisual.markdown()") { value, _ in saved = value as? String }
            return false
        })
        let markdown = try #require(saved)
        let marker = command == .bold ? "**" : "*"
        #expect(markdown.contains(marker + "Titel" + marker), Comment(rawValue: markdown))
        coordinator.load(markdown, documentURL: nil, fontName: PreviewFonts.systemName,
                         fontSize: 14, darkMode: false, style: "reload")
        try #require(await waitUntil { coordinator.ready })
        let selector = command == .bold ? "strong,b" : "em,i"
        #expect(try await web.evaluateJavaScript("document.querySelector('h\(level)')?.querySelector('\(selector)')?.textContent") as? String == "Titel")
    }

    @Test("Fett und Kursiv lassen sich in Überschriften kombinieren und wieder ausschalten")
    @MainActor
    func headingFormatToggles() async throws {
        let (workspace, coordinator, web, window) = try await editor("# Titel\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime((workspace, coordinator)) {} }
        for command in ["bold", "italic", "italic", "bold"] {
            _ = try await web.evaluateJavaScript("{const h=document.querySelector('h1'),r=document.createRange();r.selectNodeContents(h);getSelection().removeAllRanges();getSelection().addRange(r);fastraVisual.command('\(command)');}")
        }
        let markdown = try await web.evaluateJavaScript("fastraVisual.markdown()") as? String
        #expect(markdown?.trimmingCharacters(in: .whitespacesAndNewlines) == "# Titel")
    }

    @Test("Drucken bleibt nach visueller Synchronisierung am ursprünglichen Dokument",
          arguments: [false, true])
    @MainActor
    func printingKeepsDocumentContext(replaceDocument: Bool) async throws {
        let (workspace, coordinator, web, window) = try await editor("Alter Text\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        let output = testTemporaryDirectory().appendingPathComponent("print-context-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try await web.evaluateJavaScript("document.querySelector('p').textContent='Sichtbarer neuer Text';")
        var outcome: PrintOutcome?
        DocumentPrinting.prepareAndRun(target: .source, workspace: workspace,
            window: window, savingTo: output) { outcome = $0 }
        if replaceDocument {
            let other = EditorTab(title: "other.md", path: "", content: "Fremdes Dokument\n")
            workspace.tabs.append(other)
            workspace.activeTabID = other.id
        }
        try #require(await waitUntil(timeout: 8) { outcome != nil })
        if replaceDocument {
            #expect(outcome == .cancelled)
            #expect(!FileManager.default.fileExists(atPath: output.path))
        } else {
            #expect(outcome == .printed)
            let text = try #require(PDFDocument(url: output)?.string)
            #expect(text.contains("Sichtbarer neuer Text"))
            #expect(!text.contains("Alter Text"))
        }
    }

    @Test("Veralteter WebKit-Stand darf byteverschiedenes Unicode nicht zurückschreiben")
    @MainActor
    func staleUnicodeSnapshot() async throws {
        let original = "é\n"
        let current = "e\u{0301}\n"
        let (workspace, coordinator, web, window) = try await editor(original)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        workspace.activeTabContent.wrappedValue = current
        #expect(!workspace.acceptVisualMarkdown("Veraltet\n", previous: original, tabID: workspace.activeTabID!))
        #expect(workspace.activeTab?.content.utf8.elementsEqual(current.utf8) == true)
        workspace.activeTabContent.wrappedValue = current
        var accepted: Bool?
        coordinator.synchronize { accepted = $0 }
        try #require(await waitUntil { accepted != nil })
        #expect(accepted == false)
        #expect(workspace.activeTab?.content.utf8.elementsEqual(current.utf8) == true)
    }

    @Test("Montierte Markdown-Ansichten aktualisieren Unicode-Bytes", arguments: [false, true])
    @MainActor
    func mountedUnicodeUpdate(_ visual: Bool) async throws {
        let workspace = Workspace()
        var tab = EditorTab(title: "unicode.md", path: "", content: "é\n")
        tab.markdownVisualOverride = true
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        let root = visual ? AnyView(EditorView().environmentObject(workspace))
                          : AnyView(MarkdownPreviewView(workspace: workspace))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func findWeb(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(findWeb).first
        }
        try #require(await waitUntil { findWeb(host) != nil })
        let web = try #require(findWeb(host))
        var observed: String?
        func waitForText(_ expected: String) async -> Bool {
            var reading = false
            return await waitUntil {
                if observed?.utf8.elementsEqual(expected.utf8) == true { return true }
                if !reading {
                    reading = true
                    guard let currentWeb = findWeb(host) else { reading = false; return false }
                    currentWeb.evaluateJavaScript("document.querySelector('p')?.textContent") { value, _ in
                        if currentWeb === findWeb(host) { observed = value as? String }
                        reading = false
                    }
                }
                return false
            }
        }
        try #require(await waitForText("é"))
        let revision = workspace.activeTab?.contentRevision
        workspace.activeTabContent.wrappedValue = "e\u{0301}\n"
        #expect(workspace.activeTab?.content.utf8.elementsEqual("e\u{0301}\n".utf8) == true)
        #expect(workspace.activeTab?.contentRevision != revision)
        if visual {
            // Auch ein byteweiser Unicode-Wechsel lädt das Webdokument neu.
            // Seine Ladebereitschaft gehört vor die anschließende Textprüfung.
            try #require(await waitUntil(timeout: 12) {
                guard let coordinator = workspace.visualMarkdownEditor else { return false }
                return coordinator.ready && coordinator.markdown.utf8.elementsEqual("e\u{0301}\n".utf8)
                    && coordinator.web === findWeb(host)
            })
        }
        let updated = await waitForText("e\u{0301}")
        if !updated {
            let dom = try? await web.evaluateJavaScript("Array.from(document.querySelectorAll('p')).map(n=>({text:n.textContent,boundary:n.hasAttribute('data-md-edit-boundary')}))")
            Issue.record(Comment(rawValue: "Unicode-Update: Modell=\(String(reflecting: workspace.activeTab?.content)), beobachtet=\(String(reflecting: observed)), bereit=\(workspace.visualMarkdownEditor?.ready == true), Coordinator=\(String(reflecting: workspace.visualMarkdownEditor?.markdown)), DOM=\(String(describing: dom))"))
        }
        #expect(updated)
        if visual {
            #expect(workspace.visualMarkdownEditor?.markdown.utf8.elementsEqual("e\u{0301}\n".utf8) == true)
        }
    }

    @Test("Clipboard-Abschluss gibt keine fremde Dokumentaktionssperre frei", arguments: [false, true])
    @MainActor
    func clipboardDuringDocumentAction(_ actionFinishesFirst: Bool) async throws {
        let source = "Unverändert\n"
        let (_, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        _ = try await web.evaluateJavaScript("""
            window.webkit.messageHandlers.markdownCopy.postMessage=payload=>{window.clipboardRequest=payload;};
            const root=document.getElementById('fastra-visual'),r=document.createRange();r.selectNodeContents(root);
            getSelection().removeAllRanges();getSelection().addRange(r);
            root.dispatchEvent(new Event('cut',{bubbles:true,cancelable:true}));
            window.snapshot=fastraVisual.prepareAction();
            """)
        #expect(try await web.evaluateJavaScript("window.snapshot.markdown") as? String == source)
        if actionFinishesFirst {
            _ = try await web.evaluateJavaScript("fastraVisual.completeAction(window.clipboardRequest.session)")
        }
        _ = try await web.evaluateJavaScript("fastraVisual.completeClipboard(window.clipboardRequest.bookmark,true,true)")
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').contentEditable") as? String == (actionFinishesFirst ? "true" : "false"))
        if !actionFinishesFirst {
            _ = try await web.evaluateJavaScript("fastraVisual.command('bold');fastraVisual.completeAction(window.clipboardRequest.session)")
            #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
            #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').contentEditable") as? String == "true")
        }
    }

    static let samples = [
        "", "Text 😀", "$$\nx\n$$", "Before\n\n$$\nx\n$$", "$$\nx\n$$\n", "Before\n\n$$\nx\n$$\n",
        "![src='missing.png'](images/1.png \"src='other.png'\")", "# Titel\n\n**Fett** und *kursiv* mit ==Marker==.\n",
        "[Link][ziel]\n\n[ziel]: https://example.com \"Titel\"\n\n<!-- Kommentar -->\n",
        "| A | B |\n| - | - |\n| 😀 | **ja** |\n\n- [x] Fertig\n- [ ] Offen\n",
        "```swift\nlet code = \"```\"\n```\n\n$$\nx + y\n$$\n\nText $a$ danach\n",
        "<details><summary>Mehr</summary>Inhalt</details>\n\n![Fehlt](images/missing.png)\n",
        "**offen\n\n#\n\n[defekt](\n\n  \nEnde",
        "# CR\r\rAbsatz\r", "# CRLF\r\n\r\nText 😀\r\n",
        "Anfang\u{2028}weiter\u{2029}😀\u{0085}Ende\n\n# Nächster Block\n"
    ]

    @Test("Blockzerlegung bewahrt jeden Originalbuchstaben", arguments: samples)
    func blocksPreserveSource(_ source: String) {
        let document = MarkdownVisualDocument.render(source, documentURL: nil)
        #expect(document.blocks.map(\.source).joined() == source)
    }

    @Test("cmark-Zeilenzuordnung zählt Unicode-Trenner als Inhalt", arguments: ["\n", "\r\n", "\r"])
    func unicodeSourceLines(_ eol: String) {
        let first = "Anfang\u{2028}weiter\u{2029}😀\u{0085}Ende\(eol)"
        #expect(MarkdownVisualDocument.sourceLines(first + eol + "# Titel" + eol) == [first, eol, "# Titel" + eol, ""])
        let document = MarkdownVisualDocument.render(first + eol + "# Titel" + eol, documentURL: nil)
        let visible = document.blocks.filter { !$0.hidden }
        #expect(visible.map(\.source) == [first, "# Titel" + eol])
        #expect(visible.last?.html.contains("<h1>Titel</h1>") == true)
    }

    @Test("EOF-Formeln bleiben sichtbar, ihre Quelle vollständig", arguments: ["$$\nx\n$$", "Before\n\n$$\nx\n$$", "$$\nx\n$$\n", "Before\n\n$$\nx\n$$\n"])
    func eofFormula(_ source: String) {
        let document = MarkdownVisualDocument.render(source, documentURL: nil)
        #expect(document.blocks.map(\.source).joined() == source)
        #expect(document.fragment.html.contains("math-block"))
        #expect(document.fragment.html.contains("data-tex=\"x\""))
    }

    @Test("Alt und Titel mit src erzeugen genau eine Bildfreigabe")
    @MainActor
    func sourceAttributeInAlt() async throws {
        let source = "![src='missing.png'](images/1.png \"src='title.png'\")"
        let url = testTemporaryDirectory().appendingPathComponent("test.md")
        let rendered = MarkdownVisualDocument.render(source, documentURL: url)
        #expect(rendered.fragment.imageURLs.count == 1)
        #expect(rendered.fragment.html.components(separatedBy: "data-md-src=").count == 2)
        let (_, coordinator, web, window) = try await editor(source, documentURL: url)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        #expect(try await web.evaluateJavaScript("document.querySelector('img').alt") as? String == "src='missing.png'")
        #expect(try await web.evaluateJavaScript("document.querySelector('img').title") as? String == "src='title.png'")
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Gliederung springt und folgt im echten visuellen DOM ohne Markdown oder Undo zu ändern")
    @MainActor func outlineNavigation() async throws {
        let source = "# Anfang\n\nText 😀\n\n<div><h2>Geschützt</h2></div>\n\nText <h2>Inline-HTML</h2> danach.\n\nUntertitel\n----------\n\n> ### Dritter\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let outline = workspace.documentOutline
        outline.refresh(in: workspace)
        try #require(await waitUntil { outline.ready })
        #expect(outline.headings.count == 3)
        outline.jump(to: outline.headings[2], in: workspace)
        try #require(await waitUntil { outline.activeHeading == 2 })
        let selectedScript = "(()=>{const n=getSelection().anchorNode;return (n?.nodeType===1?n:n?.parentElement)?.closest('h1,h2,h3')?.textContent || '';})()"
        var selected = try await web.evaluateJavaScript(selectedScript) as? String
        #expect(selected == "Dritter")
        outline.move(-1, in: workspace)
        try #require(await waitUntil { outline.activeHeading != 2 })
        outline.move(1, in: workspace)
        try #require(await waitUntil { outline.activeHeading == 2 })
        selected = try await web.evaluateJavaScript(selectedScript) as? String
        #expect(selected == "Dritter")
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
        #expect(workspace.activeTab?.content == source)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Ein Gliederungssprung in langen Dokumenten scrollt die wirkliche WebKit-Ansicht")
    @MainActor func outlineScrollsLongDocument() async throws {
        let source = "# Anfang\n\n" + String(repeating: "Absatz.\n\n", count: 180) + "### Ende\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        workspace.documentOutline.refresh(in: workspace)
        try #require(await waitUntil { workspace.documentOutline.ready })
        workspace.documentOutline.jump(to: workspace.documentOutline.headings[1], in: workspace)
        var scroll = 0.0
        for _ in 0..<100 {
            scroll = (try await web.evaluateJavaScript("window.scrollY")) as? Double ?? 0
            if scroll > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(scroll > 0)
        #expect(try await web.evaluateJavaScript("document.querySelector('h3').getBoundingClientRect().top < innerHeight") as? Bool == true)
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Native Suche findet sichtbaren Text über Formatgrenzen und ignoriert Markdown und Linkadressen")
    @MainActor func visualFindRenderedText() async throws {
        let source = "# Titel\n\nEin **fetter** Text 😀 Ende.\n\n[Linktext](https://hidden.invalid/target)\n\n| Links | Rechts |\n| --- | --- |\n| Zelle | Wert |\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let find = workspace.markdownVisualFind
        find.present(in: workspace)
        try #require(await waitUntil { find.isPresented })
        func search(_ query: String, sensitive: Bool = false) async throws -> MarkdownVisualFindController.Status {
            find.query = query; find.caseSensitive = sensitive
            find.schedule(in: workspace)
            try #require(await waitUntil { find.status == .found || find.status == .missing })
            return find.status
        }
        #expect(try await search("fetter Text 😀") == .found)
        #expect(try await search("**fetter**") == .missing)
        #expect(try await search("hidden.invalid") == .missing)
        #expect(try await search("FETTER", sensitive: true) == .missing)
        #expect(try await search("FETTER") == .found)
        #expect(try await search("Zelle") == .found)
        find.close(in: workspace)
        #expect(!find.isPresented)
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
        #expect(workspace.activeTab?.content == source)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Geschlossene Textsuche stellt den vom Feldabbau entfernten Editorfokus wieder her")
    @MainActor func visualFindCloseRestoresFocusAfterFieldTeardown() async throws {
        let (workspace, coordinator, web, window) = try await editor("# Fokus\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        let find = workspace.markdownVisualFind
        find.present(in: workspace)
        try #require(await waitUntil { find.isPresented })
        find.close(in: workspace)
        window.makeFirstResponder(nil)
        #expect(window.firstResponder !== web)
        find.restoreEditorFocusAfterClosing(in: workspace)
        try #require(await waitUntil { window.firstResponder === web })
        #expect(workspace.activeTab?.content == "# Fokus\n")
    }

    @Test("Veraltete Fokus-Rückgabe übergeht weder neue Suche noch Dokumentwechsel", arguments: [false, true])
    @MainActor func visualFindCloseRejectsStaleFocus(changeDocument: Bool) async throws {
        let (workspace, coordinator, web, window) = try await editor("# Fokus\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        let find = workspace.markdownVisualFind
        find.present(in: workspace)
        try #require(await waitUntil { find.isPresented })
        find.close(in: workspace)
        // Die legitime WebKit-Suche des Schließens zuerst abschließen;
        // sie darf den Fokus unabhängig von unserem Rückruf verändern.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            web.find("", configuration: WKFindConfiguration()) { _ in done.resume() }
        }
        // close() reiht zusätzlich DOM-Fokus ein. Auch ihn vor dem Reset
        // abschließen, damit nur der danach angeforderte Rückruf gemessen wird.
        _ = try await web.evaluateJavaScript("true")
        window.makeFirstResponder(nil)
        find.restoreEditorFocusAfterClosing(in: workspace)
        if changeDocument {
            let tab = EditorTab(title: "Anderes Dokument", path: "", content: "Anderes Dokument")
            workspace.tabs.append(tab); workspace.activeTabID = tab.id
        } else {
            find.present(in: workspace)
        }
        let restoredOldEditor = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            DispatchQueue.main.async { done.resume(returning: window.firstResponder === web) }
        }
        #expect(!restoredOldEditor)
    }

    @Test("Native Suchnavigation scrollt vorwärts, rückwärts und um den Dokumentrand")
    @MainActor func visualFindNavigation() async throws {
        let source = "# Titel\n\nNEEDLE oben\n\n" + String(repeating: "Absatz.\n\n", count: 180) + "NEEDLE unten\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let find = workspace.markdownVisualFind
        find.present(in: workspace)
        try #require(await waitUntil { find.isPresented })
        find.query = "NEEDLE"; find.schedule(in: workspace)
        try #require(await waitUntil { find.status == .found })
        let first = (try await web.evaluateJavaScript("window.scrollY")) as? Double ?? -1
        find.find(in: workspace)
        try #require(await waitUntil { find.status == .found })
        let second = (try await web.evaluateJavaScript("window.scrollY")) as? Double ?? -1
        #expect(second > first + 100)
        find.find(in: workspace, backwards: true)
        try #require(await waitUntil { find.status == .found })
        let previous = (try await web.evaluateJavaScript("window.scrollY")) as? Double ?? -1
        #expect(abs(previous - first) < 2)
        find.find(in: workspace, backwards: true)
        try #require(await waitUntil { find.status == .found })
        let wrapped = (try await web.evaluateJavaScript("window.scrollY")) as? Double ?? -1
        #expect(abs(wrapped - second) < 2)
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Verspätete Suchantworten gehören weder zu einem anderen Tab noch zu einem anderen Fenster")
    @MainActor func visualFindIsolation() async throws {
        let (workspace, coordinator, web, window) = try await editor("# A\n\nAlpha\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let find = workspace.markdownVisualFind, originalID = workspace.activeTabID!
        find.present(in: workspace)
        try #require(await waitUntil { find.isPresented })
        find.query = "Alpha"; find.schedule(in: workspace)
        var second = EditorTab(title: "b.md", path: "", content: "# B\n\nBeta\n")
        second.markdownVisualOverride = true
        workspace.tabs.append(second); workspace.activeTabID = second.id
        find.bind(in: workspace)
        try await Task.sleep(for: .milliseconds(250))
        #expect(!find.isPresented && find.status == .idle && find.query.isEmpty)
        #expect(Workspace().markdownVisualFind.query.isEmpty)
        workspace.activeTabID = originalID
        find.bind(in: workspace)
        #expect(find.query == "Alpha")
        #expect(workspace.tabs[1].content == second.content)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Native Suche erhält den bestehenden Undo-/Redo-Schritt einer Texteingabe")
    @MainActor func visualFindPreservesUndo() async throws {
        let source = "# Titel\n\nText.\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);document.execCommand('insertText',false,'!');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content.contains("!") == true })
        let changed = workspace.activeTab!.content
        let find = workspace.markdownVisualFind
        find.present(in: workspace)
        try #require(await waitUntil { find.isPresented })
        find.query = "Text"; find.schedule(in: workspace)
        try #require(await waitUntil { find.status == .found })
        find.close(in: workspace)
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
        _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == changed })
        withExtendedLifetime(coordinator) {}
    }

    @Test("Kopierter Fettdruck mit Return/Delete erzeugt keine Format- oder Leerzeilenreste", arguments: ["<strong>Bold</strong>", "**Bold&nbsp;**"])
    @MainActor
    func reportBoldReturnDelete(_ fragment: String) async throws {
        let (workspace, coordinator, web, window) = try await editor("")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        let rendered = MarkdownVisualDocument.render(fragment, documentURL: nil)
        let inserted = try await web.callAsyncJavaScript("""
            const root=document.querySelector('#fastra-visual'),r=document.createRange();r.selectNodeContents(root);
            getSelection().removeAllRanges();getSelection().addRange(r);
            return fastraVisual.insertBookmarked(fastraVisual.bookmark(),html,atoms,null,[],true);
            """, arguments: ["html": rendered.blocks.map(\.html).joined(), "atoms": rendered.opaqueSources], in: nil, contentWorld: .page) as? Bool
        try #require(inserted == true)
        let expected = fragment.contains("&nbsp;") ? "Bold\u{00a0}" : "Bold"
        #expect(try await web.evaluateJavaScript("document.querySelector('#fastra-visual').textContent") as? String == expected)
        _ = try await web.evaluateJavaScript("""
            {const p=document.querySelector('#fastra-visual strong'),r=document.createRange();r.selectNodeContents(p);r.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(r);document.execCommand('insertParagraph');fastraVisual.flush();}
            """)
        try #require(await waitUntil { workspace.activeTab?.content.contains("\n") == true })
        let source = try #require(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String)
        #expect(!source.contains("**  "))
        #expect(!source.contains("<strong>"))
        for round in 0..<4 {
            coordinator.load(source, documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "report-\(round)")
            try #require(await waitUntil(timeout: 12) { coordinator.ready })
            #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
        }
        _ = try await web.evaluateJavaScript("""
            {const r=document.createRange();r.selectNodeContents(document.querySelector('#fastra-visual'));
            getSelection().removeAllRanges();getSelection().addRange(r);document.execCommand('delete');fastraVisual.flush();}
            """)
        try #require(await waitUntil { workspace.activeTab?.content == "" })
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == "")
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
    }

    @Test("Verschachtelte Inlineformate bleiben darstellbares Markdown", arguments: [
        ["<strong><mark>Marked</mark></strong>", "**==Marked==**", "strong mark"],
        ["a<strong><em>Bold</em></strong>b", "a***Bold***b", "strong em,em strong"],
        ["<strong>outer<strong>inner</strong>end</strong>", "**outerinnerend**", "strong"],
        ["<em>outer<em>inner</em>end</em>", "*outerinnerend*", "em"]
    ])
    @MainActor
    func reportNestedMarkdownNotation(_ sample: [String]) async throws {
        let (_, coordinator, web, window) = try await editor("")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        _ = try await web.callAsyncJavaScript("""
            const root=document.querySelector('#fastra-visual'),r=document.createRange();r.selectNodeContents(root);
            getSelection().removeAllRanges();getSelection().addRange(r);
            fastraVisual.insertBookmarked(fastraVisual.bookmark(),'<p>'+html+'</p>',{},null,[],true);
            """, arguments: ["html": sample[0]], in: nil, contentWorld: .page)
        let source = try #require(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String)
        #expect(source.trimmingCharacters(in: .newlines) == sample[1])
        coordinator.load(source, documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "report-nested")
        try #require(await waitUntil(timeout: 12) { coordinator.ready })
        #expect(try await web.callAsyncJavaScript("return !!document.querySelector(selector);", arguments: ["selector": sample[2]], in: nil, contentWorld: .page) as? Bool == true)
    }

    @Test("Clipboard exportiert Textmarkerfarbe und keine fremden Blockkennungen")
    @MainActor
    func reportHighlightClipboardMetadata() async throws {
        let source = "==Marked== und **Bold&nbsp;**\n"
        let (_, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        _ = try await web.evaluateJavaScript("""
            {const r=document.createRange();r.selectNodeContents(document.querySelector('#fastra-visual'));
            getSelection().removeAllRanges();getSelection().addRange(r);document.querySelector('#fastra-visual').dispatchEvent(new Event('copy',{bubbles:true,cancelable:true}));}
            """)
        try #require(await waitUntil { coordinator.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType) != nil })
        let html = try #require(coordinator.pasteboard.string(forType: .html))
        #expect(!html.contains("data-md-"))
        #expect(html.contains("background-color"))
        let rtf = try #require(coordinator.pasteboard.data(forType: .rtf))
        let rich = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let marked = (rich.string as NSString).range(of: "Marked").location
        try #require(marked != NSNotFound)
        #expect(rich.attribute(.backgroundColor, at: marked, effectiveRange: nil) != nil)
        let directory = testTemporaryDirectory().appendingPathComponent("visual-report-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("receiver.md")
        try "Other\n".write(to: file, atomically: true, encoding: .utf8)
        let (receiverWorkspace, receiver, receiverWeb, receiverWindow) = try await editor("Other\n", documentURL: file)
        receiverWorkspace.tabs[0].diskSnapshot = try FileSnapshot.readSnapshotOnly(from: file)
        defer { receiverWeb.configuration.userContentController.removeAllScriptMessageHandlers(); receiverWindow.close(); withExtendedLifetime(receiver) {} }
        receiver.pasteboard = coordinator.pasteboard
        _ = try await receiverWeb.evaluateJavaScript("{const r=document.createRange();r.selectNodeContents(document.querySelector('#fastra-visual'));getSelection().removeAllRanges();getSelection().addRange(r);}")
        #expect(receiver.pasteImages())
        try #require(await waitUntil { receiverWorkspace.activeTab?.content.contains("Marked") == true })
        let copied = try #require(receiverWorkspace.activeTab?.content)
        #expect(!copied.contains("Other"))
        #expect(try await receiverWeb.evaluateJavaScript("document.querySelector('mark').textContent") as? String == "Marked")
        #expect(try await receiverWeb.evaluateJavaScript("document.querySelector('strong').textContent") as? String == "Bold\u{00a0}")
        receiverWorkspace.saveActiveTab()
        try #require(await waitUntil { receiverWorkspace.activeTab?.isDirty == false && (try? String(contentsOf: file, encoding: .utf8)) == copied })
        let saved = try String(contentsOf: file, encoding: .utf8)
        let (_, reopened, reopenedWeb, reopenedWindow) = try await editor(saved, documentURL: file)
        defer { reopenedWeb.configuration.userContentController.removeAllScriptMessageHandlers(); reopenedWindow.close(); withExtendedLifetime(reopened) {} }
        #expect(try await reopenedWeb.evaluateJavaScript("document.querySelector('mark').textContent") as? String == "Marked")
        #expect(try await reopenedWeb.evaluateJavaScript("document.querySelector('strong').textContent") as? String == "Bold\u{00a0}")
    }

    @Test("WYSIWYG-Ausschnitt bleibt dokumentbezogen und verwirft veraltete Revisionen")
    @MainActor
    func reportViewportOwnership() async throws {
        let source = (0..<180).map { "Line \($0)\n\n" }.joined()
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        _ = try await web.evaluateJavaScript("window.scrollTo(0,1500)")
        let observedScroll = try await web.evaluateJavaScript("window.scrollY") as? Double ?? 0
        try #require(observedScroll > 1400)
        let synchronized: Bool = await withCheckedContinuation { done in coordinator.synchronize { done.resume(returning: $0) } }
        try #require(synchronized)
        let saved = try #require(workspace.activeTab?.markdownVisualViewport)
        #expect(saved.offset.y > 1400)
        coordinator.load(source, documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "report-restore")
        try #require(await waitUntil(timeout: 12) { coordinator.ready })
        #expect(abs((try await web.evaluateJavaScript("window.scrollY") as? Double ?? 0) - Double(saved.offset.y)) < 1)
        workspace.activeTabContent.wrappedValue += "Changed\n"
        let changed = try #require(workspace.activeTab?.content)
        coordinator.load(changed, documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "report-changed")
        try #require(await waitUntil(timeout: 12) { coordinator.ready })
        #expect(try await web.evaluateJavaScript("window.scrollY") as? Double == 0)
        let (_, other, otherWeb, otherWindow) = try await editor(source)
        defer { otherWeb.configuration.userContentController.removeAllScriptMessageHandlers(); otherWindow.close(); withExtendedLifetime(other) {} }
        #expect(try await otherWeb.evaluateJavaScript("window.scrollY") as? Double == 0)
    }

    @Test("Echter Strong-Clipboard-Rundweg in ein leeres Dokument ergänzt keinen Blank")
    @MainActor
    func reportSimpleStrongNativeClipboard() async throws {
        let (_, coordinator, web, window) = try await editor("<strong>Strong</strong>\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        _ = try await web.evaluateJavaScript("""
            {const range=document.createRange();range.selectNodeContents(document.querySelector('#fastra-visual strong'));
            getSelection().removeAllRanges();getSelection().addRange(range);
            document.querySelector('#fastra-visual').dispatchEvent(new Event('copy',{bubbles:true,cancelable:true}));}
            """)
        try #require(await waitUntil { coordinator.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType) != nil })
        #expect(coordinator.pasteboard.string(forType: .string) == "Strong")
        let (target, receiver, targetWeb, targetWindow) = try await editor("")
        defer { targetWeb.configuration.userContentController.removeAllScriptMessageHandlers(); targetWindow.close(); withExtendedLifetime(receiver) {} }
        receiver.pasteboard = coordinator.pasteboard
        _ = try await targetWeb.evaluateJavaScript("""
            {const range=document.createRange();range.selectNodeContents(document.querySelector('#fastra-visual'));
            getSelection().removeAllRanges();getSelection().addRange(range);}
            """)
        try #require(receiver.pasteImages())
        try #require(await waitUntil { target.activeTab?.content.contains("Strong") == true })
        #expect(try await targetWeb.evaluateJavaScript("document.querySelector('#fastra-visual').textContent") as? String == "Strong")
        let copied = try #require(target.activeTab?.content)
        #expect(!copied.contains("&nbsp;"))
        #expect(!copied.contains("\u{00a0}"))
    }

    @Test("Altes WYSIWYG-Scrollereignis erhält nach externer Änderung keine neue Quellrevision")
    @MainActor
    func reportViewportRejectsStaleSourceEvent() async throws {
        let source = (0..<180).map { "Line \($0)\n\n" }.joined()
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        let tap = MarkdownVisualMessageTap(coordinator)
        var copiedSession: String?
        var receivedViewport = false
        tap.observe = { message in
            guard let body = message.body as? [String: Any] else { return }
            if message.name == "markdownCopy" { copiedSession = body["session"] as? String }
            if body["kind"] as? String == "viewport", (body["viewport"] as? [String: Any])?["y"] as? Double == 1700 {
                receivedViewport = true
            }
        }
        for name in ["markdownCopy", "visualMarkdown"] {
            web.configuration.userContentController.removeScriptMessageHandler(forName: name)
            web.configuration.userContentController.add(tap, name: name)
        }
        _ = try await web.evaluateJavaScript("window.scrollTo(0,1200)")
        let synchronized: Bool = await withCheckedContinuation { done in coordinator.synchronize { done.resume(returning: $0) } }
        try #require(synchronized)
        let before = try #require(workspace.activeTab?.markdownVisualViewport)
        _ = try await web.evaluateJavaScript("""
            {const range=document.createRange();range.selectNodeContents(document.querySelector('#fastra-visual p'));
            getSelection().removeAllRanges();getSelection().addRange(range);
            document.querySelector('#fastra-visual').dispatchEvent(new Event('copy',{bubbles:true,cancelable:true}));}
            """)
        try #require(await waitUntil { copiedSession != nil })
        let session = try #require(copiedSession)
        let revision = try await web.callAsyncJavaScript("const state=fastraVisual.prepareAction();fastraVisual.completeAction(session);return state.revision;", arguments: ["session": session], in: nil, contentWorld: .page) as? Int
        let acceptedRevision = try #require(revision)
        workspace.activeTabContent.wrappedValue += "External source change\n"
        try #require(workspace.activeTab?.contentRevision != before.revision)
        // Eine bereits versandte Nachricht darf erst nach der Quelländerung
        // eintreffen; dafür braucht der Test keinen Animationsframe im verdeckten Fenster.
        _ = try await web.callAsyncJavaScript("window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'viewport',session,revision,viewport:{x:0,y:1700}});return true;", arguments: ["session": session, "revision": acceptedRevision], in: nil, contentWorld: .page)
        try #require(await waitUntil { receivedViewport })
        #expect(workspace.activeTab?.markdownVisualViewport == before)
        #expect(workspace.activeTab?.markdownVisualViewport?.revision != workspace.activeTab?.contentRevision)
    }

    // Diagnostik darf eine fehlende WebKit-Rückmeldung nicht selbst unbegrenzt abwarten.
    @MainActor
    private func visualDiagnostic(_ web: WKWebView, script: String) async -> String {
        var reply: String?
        web.evaluateJavaScript(script) { value, error in
            reply = error.map { "error: \($0)" } ?? String(describing: value ?? "nil")
        }
        let completed = await waitUntil(timeout: 1) { reply != nil }
        return completed ? (reply ?? "nil") : "diagnostic callback timed out"
    }

    private func visualPhaseProbe(_ method: String) -> String {
        """
        (() => {
          const d=window.__fastraTestPhase={document:performance.timeOrigin,installed:Date.now(),method:'\(method)',phase:'installed'};
          const original=window.fastraVisual?.['\(method)'];
          if(typeof original!=='function'){d.phase='missing method';return JSON.stringify(d);}
          const record=read=>{try{Object.assign(d,read());}catch(_){}};
          window.fastraVisual['\(method)']=function(...args){
            record(()=>({phase:'entered',entered:Date.now(),viewport:args[0]?.viewport ?? null}));
            let result;
            try { result=original.apply(this,args); }
            catch(error){record(()=>({phase:'threw',error:String(error),finished:Date.now()}));throw error;}
            if('\(method)'==='start'){
              // Nur beobachten: Der Aufrufer erhält exakt das ursprüngliche Promise.
              try{result.then(value=>record(()=>({phase:'resolved',result:value,finished:Date.now()})),
                error=>record(()=>({phase:'rejected',error:String(error),finished:Date.now()})));}catch(_){}
            }else{record(()=>({phase:'returned',result,finished:Date.now()}));}
            return result;
          };
          return JSON.stringify(d);
        })()
        """
    }

    private var visualDiagnosticSnapshot: String {
        """
        (() => {
          const root=document.getElementById('fastra-visual'),state={document:performance.timeOrigin,
            readyState:document.readyState,phase:window.__fastraTestPhase ?? null,
            enhanced:document.documentElement.hasAttribute('data-fastra-enhanced'),
            text:root?.textContent,html:root?.innerHTML};
          try{state.markdown=window.fastraVisual?.markdown();}catch(error){state.markdownError=String(error);}
          return JSON.stringify(state);
        })()
        """
    }

    @MainActor
    private func editor(_ source: String, documentURL: URL? = nil) async throws -> (Workspace, MarkdownVisualCoordinator, MarkdownVisualWKWebView, NSWindow) {
        let workspace = Workspace()
        var tab = EditorTab(title: "fixture.md", path: "", content: source)
        tab.url = documentURL
        tab.markdownVisualOverride = true
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        return try await editor(in: workspace, tab: tab, darkMode: false)
    }

    @MainActor
    private func reopenEditor(
        at file: URL, savedBytes: Data, darkMode: Bool = false
    ) async throws -> (Workspace, MarkdownVisualCoordinator, MarkdownVisualWKWebView, NSWindow) {
        let workspace = Workspace()
        var loadResult: Bool?
        workspace.loadFile(at: file) { loadResult = $0 }
        try #require(await waitUntil { loadResult != nil })
        try #require(loadResult == true)
        let index = try #require(workspace.tabs.firstIndex { $0.id == workspace.activeTabID })
        let tab = workspace.tabs[index]
        try #require(tab.url?.canonicalFileURL == file.canonicalFileURL)
        try #require(Data(tab.content.utf8) == savedBytes)
        try #require(!tab.isDirty)
        workspace.tabs[index].markdownVisualOverride = true
        return try await editor(in: workspace, tab: workspace.tabs[index], darkMode: darkMode)
    }

    @MainActor
    private func editor(
        in workspace: Workspace, tab: EditorTab, darkMode: Bool
    ) async throws -> (Workspace, MarkdownVisualCoordinator, MarkdownVisualWKWebView, NSWindow) {
        let coordinator = MarkdownVisualCoordinator()
        coordinator.pasteboard = NSPasteboard.withUniqueName()
        coordinator.workspace = workspace
        coordinator.tabID = tab.id
        workspace.visualMarkdownEditor = coordinator
        let web = MarkdownVisualWebView.makeWebView(coordinator: coordinator)
        web.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        let window = MarkdownVisualFixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.retainedWorkspace = workspace
        window.retainedCoordinator = coordinator
        window.isReleasedWhenClosed = false
        window.contentView = web
        WorkspaceWindowRegistry.register(workspace, for: window)
        var error: String?
        workspace.saveSafetyWarningHandler = { title, text in error = title + text }
        workspace.markdownSaveWarningHandler = { check in
            Issue.record(Comment(rawValue: "WYSIWYG-Speicherprüfung: \(check.rawValue)"))
        }
        coordinator.load(tab.content, documentURL: tab.url, fontName: PreviewFonts.systemName,
                         fontSize: 14, darkMode: darkMode, style: "test")
        let ready = await waitUntil(timeout: 12) { coordinator.ready || error != nil }
        if let error {
            let roundtrip = try? await web.evaluateJavaScript("window.fastraVisual.markdown()")
            Issue.record(Comment(rawValue: error + " ROUNDTRIP=" + String(describing: roundtrip)))
        }
        let loaded = ready && coordinator.ready
        if !loaded {
            // Bei fehlgeschlagenem Aufbau erhält der Aufrufer kein Fenster
            // und kann dessen Ressourcen deshalb nicht selbst freigeben.
            web.configuration.userContentController.removeAllScriptMessageHandlers()
            window.close()
        }
        try #require(loaded, "Editor wurde nicht bereit")
        return (workspace, coordinator, web, window)
    }

    @Test("Normale Absätze sind kompakt; ein Zeilenumbruch bleibt innerhalb desselben Absatzes")
    @MainActor
    func compactParagraphs() async throws {
        let source = "Erste Zeile  \nZweite Zeile\n\nNächster Absatz\n\n  \n"
        let (_, coordinator, visual, window) = try await editor(source)
        defer { visual.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(MarkdownPreviewSchemeHandler(), forURLScheme: MarkdownPreviewAssets.scheme)
        let preview = WKWebView(frame: visual.frame, configuration: config)
        preview.loadHTMLString(MarkdownRichText.htmlDocument(markdown: source, fontName: PreviewFonts.systemName,
                                                           fontSize: 14, darkMode: false), baseURL: nil)
        for web in [preview, visual] {
            var metrics: [Double] = []
            for _ in 0..<120 {
                metrics = (try? await web.evaluateJavaScript("""
                    (() => { const p = document.querySelectorAll('p:not(.fastra-visible-blank-line)');
                      const blank = document.querySelector('.fastra-visible-blank-line'); if (p.length !== 2 || !blank) return [];
                      const style = getComputedStyle(p[0]), font = parseFloat(style.fontSize);
                      const first = p[0].getBoundingClientRect(), second = p[1].getBoundingClientRect();
                      return [parseFloat(style.lineHeight)/font, parseFloat(style.marginBottom)/font,
                        first.height/font, (second.top-first.bottom)/font, blank.getBoundingClientRect().height/font]; })()
                    """)) as? [Double] ?? []
                if metrics.count == 5 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(metrics.count == 5)
            #expect(abs(metrics[0] - 1.4) < 0.01)
            #expect(abs(metrics[1] - 0.4) < 0.01)
            #expect(abs(metrics[2] - 2.8) < 0.1, "Zwei Zeilen dürfen keinen Absatzabstand enthalten: \(metrics)")
            #expect(abs(metrics[3] - 0.4) < 0.1, "Absätze behalten einen kleinen Abstand: \(metrics)")
            #expect(abs(metrics[4] - 1.4) < 0.1, "Sichtbare Leerzeilen müssen dieselbe Höhe wie Textzeilen haben: \(metrics)")
        }
        #expect(try await visual.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Shift-Return und der Umbruchbefehl erhalten Absatz, Speichern und Undo", arguments: [false, true])
    @MainActor
    func hardBreakWithinParagraph(_ keyboard: Bool) async throws {
        let source = "VorherNachher\n\nUnverändert 😀\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let result = try await web.evaluateJavaScript("""
            {const root=document.getElementById('fastra-visual'),p=root.querySelector('p'),r=document.createRange();
            r.setStart(p.firstChild,6);r.collapse(true);root.focus();getSelection().removeAllRanges();getSelection().addRange(r);
            if(\(keyboard ? "true" : "false"))root.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',shiftKey:true,bubbles:true,cancelable:true}));
            else fastraVisual.command('hardBreak');
            fastraVisual.markdown();}
            """) as? String
        let expected = try #require(result)
        #expect(expected.hasPrefix("Vorher  \nNachher\n\n"))
        #expect(expected.hasSuffix("Unverändert 😀\n"))
        try #require(await waitUntil { workspace.activeTab?.content == expected })
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#fastra-visual p').length") as? Int == 2)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#fastra-visual p:first-child br').length") as? Int == 1)
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
        _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == expected })
        coordinator.load(expected, documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "reload")
        try #require(await waitUntil { coordinator.ready })
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#fastra-visual p').length") as? Int == 2)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#fastra-visual br').length") as? Int == 1)
    }

    @Test("Return und zusätzliche Modifikatoren behalten ihre eigene Tastaturbedienung")
    @MainActor
    func hardBreakDoesNotConsumeOtherKeys() async throws {
        let source = "Text\n"
        let (_, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let allowed = try await web.evaluateJavaScript("""
            [{},{shiftKey:true,metaKey:true},{shiftKey:true,ctrlKey:true},{shiftKey:true,isComposing:true}]
            .every(flags=>document.getElementById('fastra-visual').dispatchEvent(new KeyboardEvent('keydown',
              {key:'Enter',bubbles:true,cancelable:true,...flags})))
            """) as? Bool
        #expect(allowed == true)
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
        let intercepted = try await web.evaluateJavaScript("""
            (() => {
              const root=document.getElementById('fastra-visual'),p=root.querySelector('p'),r=document.createRange();
              r.setStart(p.firstChild,2);r.collapse(true);root.focus();getSelection().removeAllRanges();getSelection().addRange(r);
              const altAllowed=root.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',altKey:true,bubbles:true,cancelable:true}));
              document.execCommand('insertText',false,'X');
              const altShiftAllowed=root.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',altKey:true,shiftKey:true,bubbles:true,cancelable:true}));
              fastraVisual.flush();
              return JSON.stringify({altAllowed,altShiftAllowed,markdown:fastraVisual.markdown()});
            })()
            """) as? String
        let jsonData = try #require(intercepted?.data(using: .utf8))
        let parsed = try #require(try JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
        #expect(parsed["altAllowed"] as? Bool == false, Comment(rawValue: intercepted ?? ""))
        #expect(parsed["altShiftAllowed"] as? Bool == false, Comment(rawValue: intercepted ?? ""))
        let md = try #require(parsed["markdown"] as? String)
        #expect(!md.contains("<br"), Comment(rawValue: md))
        #expect(md.contains("Te  \nX"), Comment(rawValue: md))
        withExtendedLifetime(coordinator) {}
    }

    @Test("Shift-Return bleibt auch in strukturierten Markdown-Blöcken erhalten", arguments: [
        ["VorherNachher\n", "p"], ["> VorherNachher\n", "blockquote p"],
        ["- VorherNachher\n", "li"], ["- [ ] VorherNachher\n", "li"],
        ["# VorherNachher\n", "h1"], ["```\nVorherNachher\n```\n", "pre code"],
        ["`VorherNachher`\n", "p"]
    ])
    @MainActor
    func hardBreakInStructuredBlocks(_ fixture: [String]) async throws {
        let (_, coordinator, web, window) = try await editor(fixture[0])
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            {const root=document.getElementById('fastra-visual'),walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
            let text;while(walker.nextNode())if(walker.currentNode.textContent.includes('VorherNachher')){text=walker.currentNode;break;}
            const r=document.createRange();r.setStart(text,text.textContent.indexOf('VorherNachher')+6);r.collapse(true);root.focus();getSelection().removeAllRanges();getSelection().addRange(r);
            root.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',shiftKey:true,bubbles:true,cancelable:true}));}
            """)
        let saved = try #require(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String)
        let before = try await web.evaluateJavaScript("document.querySelector('\(fixture[1])').innerText.trim()") as? String
        #expect(before == "Vorher\nNachher")
        coordinator.load(saved, documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "reload")
        try #require(await waitUntil { coordinator.ready })
        let after = try await web.evaluateJavaScript("document.querySelector('\(fixture[1])')?.innerText.trim()") as? String
        #expect(after == before, Comment(rawValue: "Gespeichert: " + saved))
    }

    @Test("Listen sind in Vorschau und WYSIWYG kompakt und quelltexttreu", arguments: [
        "- Suchfeld = OK\n- Art = OK\n- Firma = OK\n",
        "- Suchfeld = OK\n\n- Art = OK\n\n- Firma = OK\n",
        "1. Suchfeld = OK\n\n2. Art = OK\n\n3. Firma = OK\n",
        "- [x] Suchfeld = OK\n\n- [ ] Art = OK\n\n- [ ] Firma = OK\n",
        "- Suchfeld = OK\n  - Unterpunkt\n- Art = OK\n- Firma = OK\n"
    ])
    @MainActor
    func compactLists(_ source: String) async throws {
        let (_, coordinator, visual, window) = try await editor(source)
        defer { visual.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(MarkdownPreviewSchemeHandler(), forURLScheme: MarkdownPreviewAssets.scheme)
        let preview = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 500), configuration: config)
        preview.loadHTMLString(MarkdownRichText.htmlDocument(markdown: source, fontName: PreviewFonts.systemName,
                                                           fontSize: 14, darkMode: false), baseURL: nil)
        var loaded = false
        for _ in 0..<120 {
            if (try? await preview.evaluateJavaScript("document.querySelectorAll('li').length")) as? Int ?? 0 >= 3 {
                loaded = true; break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try #require(loaded)
        for web in [preview, visual] {
            let values = try await web.evaluateJavaScript("""
                (() => { const items = [...document.querySelectorAll('ul,ol')].find(x => x.children.length === 3).children;
                  const first = items[0].querySelector('p') || items[0];
                  const second = items[1].querySelector('p') || items[1];
                  const last = items[2].querySelector('p') || items[2];
                  const font = parseFloat(getComputedStyle(first).fontSize);
                  return [(last.getBoundingClientRect().top-second.getBoundingClientRect().top)/font,
                    parseFloat(getComputedStyle(first).lineHeight)/font]; })()
                """) as? [Double]
            let metrics = try #require(values)
            #expect(metrics[0] >= 1.1 && metrics[0] <= 1.25, "Listeneinträge müssen annähernd eine Textzeile auseinanderliegen: \(metrics)")
            #expect(metrics[1] >= 1.15 && metrics[1] <= 1.25)
        }
        #expect(try await visual.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Echter WebKit-Roundtrip verändert auch schwieriges Markdown nicht", arguments: samples)
    @MainActor
    func roundTrip(_ source: String) async throws {
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.stopLoading(); web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let result = try await web.evaluateJavaScript("window.fastraVisual.markdown()")
        #expect(result as? String == source)
        #expect(workspace.activeTab?.content == source)
        #expect(!workspace.activeTab!.isDirty)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Geschützte Leerzeichen an Stilgrenzen überleben erneutes Rendern", arguments: ["strong", "em", "mark", "del"])
    @MainActor
    func styledNonbreakingSpaces(_ tag: String) async throws {
        let (workspace, coordinator, web, window) = try await editor("Anfang\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        let html = "<p>Vor<\(tag)>&nbsp;Ziél😀&nbsp;</\(tag)>danach</p>"
        _ = try await web.callAsyncJavaScript("""
            const root=document.getElementById('fastra-visual'),r=document.createRange();
            r.selectNodeContents(root);getSelection().removeAllRanges();getSelection().addRange(r);
            document.execCommand('insertHTML',false,html);fastraVisual.flush();
            """, arguments: ["html": html], in: nil, contentWorld: .page)
        try #require(await waitUntil { workspace.activeTab?.content != "Anfang\n" })
        let source = try #require(workspace.activeTab?.content)
        for cycle in 0..<3 {
            coordinator.load(source, documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "reload-\(cycle)")
            try #require(await waitUntil(timeout: 12) { coordinator.ready })
            let text = try await web.callAsyncJavaScript("return document.querySelector('#fastra-visual '+tag)?.textContent || '';",
                arguments: ["tag": tag], in: nil, contentWorld: .page) as? String
            #expect(text == "\u{00a0}Ziél😀\u{00a0}", Comment(rawValue: source))
            #expect(try await web.evaluateJavaScript("document.querySelector('#fastra-visual').textContent.trim()") as? String == "Vor\u{00a0}Ziél😀\u{00a0}danach", Comment(rawValue: source))
        }
    }

    @Test("Formatieren, Tippen und Undo arbeiten ohne Quelltext; andere Blöcke bleiben exakt")
    @MainActor
    func editingAndUndo() async throws {
        let source = "# Original\n\nErgebnis 😀\n\n[Link][ref]\n\n[ref]: https://example.com\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.stopLoading(); web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            const p=document.querySelector('#fastra-visual > div:nth-child(2) p');
            const r=document.createRange();r.selectNodeContents(p);
            getSelection().removeAllRanges();getSelection().addRange(r);
            window.fastraVisual.command('bold');
            """)
        try #require(await waitUntil { workspace.activeTab?.content.contains("**Ergebnis 😀**") == true })
        #expect(workspace.activeTab?.content.hasPrefix("# Original\n\n") == true)
        #expect(workspace.activeTab?.content.contains("[Link][ref]\n\n[ref]: https://example.com\n") == true)
        _ = try await web.evaluateJavaScript("document.execCommand('undo'); window.fastraVisual.flush();")
        let undone = await waitUntil { workspace.activeTab?.content == source }
        if !undone {
            Issue.record(Comment(rawValue: "Undo-Markdown: " + (workspace.activeTab?.content ?? "nil")))
            let dom = try await web.evaluateJavaScript("document.getElementById('fastra-visual').innerHTML")
            Issue.record(Comment(rawValue: "Undo-DOM: " + String(describing: dom)))
        }
        try #require(undone)
        #expect(!workspace.activeTab!.isDirty)
        _ = try await web.evaluateJavaScript("document.execCommand('redo'); window.fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content.contains("**Ergebnis 😀**") == true })
        withExtendedLifetime(coordinator) {}
    }

    @Test("Tabelle, Listen, Marker und Code bleiben nach Kombination darstellbar")
    @MainActor
    func combinations() async throws {
        let (workspace, coordinator, web, window) = try await editor("Absatz\n\nZweiter Absatz\n")
        defer { web.stopLoading(); web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            const p=document.querySelector('#fastra-visual p'),r=document.createRange();r.selectNodeContents(p);
            getSelection().removeAllRanges();getSelection().addRange(r);
            window.fastraVisual.command('highlight');window.fastraVisual.command('italic');
            window.fastraVisual.command('heading2');
            """)
        try #require(await waitUntil { workspace.activeTab?.content.contains("##") == true })
        let markdown = try #require(workspace.activeTab?.content)
        let rendered = MarkdownRichText.htmlFragment(markdown: markdown)
        #expect(rendered.contains("<h2"))
        #expect(rendered.contains("<mark>"))
        #expect(rendered.contains("Zweiter Absatz"))
        withExtendedLifetime(coordinator) {}
    }

    @Test("Moduswahl bleibt dokumentbezogen und schreibt den Standard nicht um")
    @MainActor
    func perDocumentMode() {
        let ws = Workspace()
        var tab = EditorTab(title: "test.md", path: "")
        tab.markdownVisualOverride = false
        ws.tabs = [tab]; ws.activeTabID = tab.id
        let before = SelfTest.workspaceDefaults().object(forKey: MarkdownEditingMode.defaultsKey) as? Bool
        ws.toggleMarkdownEditingMode()
        #expect(ws.activeMarkdownIsVisual)
        ws.toggleMarkdownEditingMode()
        #expect(!ws.activeMarkdownIsVisual)
        #expect((SelfTest.workspaceDefaults().object(forKey: MarkdownEditingMode.defaultsKey) as? Bool) == before)
    }
    @Test("Bearbeiteter Text behält wörtliche Dollarzeichen, Marker und Kommentare")
    @MainActor
    func literalDialectAndComment() async throws {
        let source = "A \\$x\\$ und \\~\\~Text\\~\\~ <!-- merken --> Ende\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            const p=document.querySelector('#fastra-visual p'),r=document.createRange();r.selectNodeContents(p);r.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(r);document.execCommand('insertText',false,'!');fastraVisual.flush();
            """)
        try #require(await waitUntil { workspace.activeTab?.content.contains("!") == true })
        let changed = try #require(workspace.activeTab?.content)
        #expect(changed.contains("<!-- merken -->"))
        let html = MarkdownRichText.htmlFragment(markdown: changed)
        #expect(!html.contains("data-tex"))
        #expect(!html.contains("<del>"))
        #expect(html.contains("$x$"))
        withExtendedLifetime(coordinator) {}
    }

    @Test("Sofortiger Moduswechsel übernimmt die letzte WebKit-Eingabe")
    @MainActor
    func pendingInputBeforeModeSwitch() async throws {
        let (workspace, coordinator, web, window) = try await editor("Original\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        // Kein input-Ereignis: Nur die verpflichtende Synchronisierung kann
        // diese noch nicht zugestellte Eingabe sehen.
        _ = try await web.evaluateJavaScript("document.querySelector('#fastra-visual p').textContent='Letzte Eingabe';")
        workspace.toggleMarkdownEditingMode()
        try #require(await waitUntil { !workspace.activeMarkdownIsVisual })
        #expect(workspace.activeTab?.content.contains("Letzte Eingabe") == true)
        #expect(workspace.activeTab?.isDirty == true)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Zoom und Erscheinungsbild erhalten Undo; Marker entfernen ist rückgängig machbar")
    @MainActor
    func styleAndRemoveUndo() async throws {
        let source = "# Überschrift\n\n> Zitat\n\n==Markierung==\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            const n=document.querySelector('mark'),r=document.createRange();r.selectNodeContents(n);
            getSelection().removeAllRanges();getSelection().addRange(r);fastraVisual.command('highlight');
            """)
        try #require(await waitUntil { workspace.activeTab?.content.contains("==") == false })
        coordinator.updateStyle(fontName: PreviewFonts.systemName, fontSize: 22, darkMode: true, style: "changed")
        let darkColors = try await web.evaluateJavaScript("[getComputedStyle(document.querySelector('h1')).color,getComputedStyle(document.querySelector('blockquote')).color]") as? [String]
        #expect(darkColors == ["rgb(242, 242, 242)", "rgb(168, 168, 168)"])
        coordinator.updateStyle(fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "restored")
        let lightColors = try await web.evaluateJavaScript("[getComputedStyle(document.querySelector('h1')).color,getComputedStyle(document.querySelector('blockquote')).color]") as? [String]
        #expect(lightColors == ["rgb(54, 54, 54)", "rgb(115, 115, 115)"])
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
        #expect(!workspace.activeTab!.isDirty)
    }

    @Test("Diagramme wechseln das Farbschema ohne Quelltextänderung oder Undo-Verlust")
    @MainActor
    func diagramTheme() async throws {
        let source = "> ==Absatz==\n>\n> ```mermaid\n> graph TD; A-->B\n> ```\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let light = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.mermaid-render .node rect')).fill") as? String
        let darkValue: Any = try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript("""
                const p=document.querySelector('mark'),r=document.createRange();r.selectNodeContents(p);
                getSelection().removeAllRanges();getSelection().addRange(r);
                const update=fastraVisual.updateStyle('System',14,true);
                fastraVisual.command('highlight');
                await update;
                return getComputedStyle(document.querySelector('.mermaid-render .node rect')).fill;
                """, arguments: [:], in: nil, in: .page) {
                continuation.resume(with: $0)
            }
        }
        let dark = darkValue as? String
        let after = try await web.evaluateJavaScript("JSON.stringify({markdown:fastraVisual.markdown(),html:document.querySelector('#fastra-visual').innerHTML})") as? String
        try #require(await waitUntil { workspace.activeTab?.content.contains("==") == false }, Comment(rawValue: after ?? "DOM fehlt"))
        #expect(light != nil && dark != nil && light != dark)
        #expect(workspace.activeTab?.content.contains("graph TD; A-->B") == true)
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
        withExtendedLifetime(coordinator) {}
    }

    @Test("Abbauen der Tabellenansicht invalidiert keinen zerstörten SwiftUI-Graphen")
    @MainActor
    func tableViewTeardown() async throws {
        let workspace = Workspace()
        var tab = EditorTab(title: "table.md", path: "", content: "| Kopf |\n| --- |\n| Zelle |\n")
        tab.markdownVisualOverride = true
        workspace.tabs = [tab]; workspace.activeTabID = tab.id
        var host: NSHostingView<AnyView>? = NSHostingView(rootView: AnyView(EditorView().environmentObject(workspace)))
        host?.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host?.layoutSubtreeIfNeeded()
        defer { window.close() }
        try #require(await waitUntil(timeout: 12) { workspace.visualMarkdownEditor?.ready == true })
        _ = try await workspace.visualMarkdownEditor?.web?.evaluateJavaScript("{const c=document.querySelector('td'),r=document.createRange();r.selectNodeContents(c);getSelection().removeAllRanges();getSelection().addRange(r);}")
        try #require(await waitUntil { workspace.markdownTable.context != nil })
        window.contentView = nil
        host = nil
        try #require(await waitUntil { workspace.visualMarkdownEditor == nil && workspace.markdownTable.context == nil })
    }

    @Test("Strukturelle Tabellenänderung bewahrt Nachbarn und natives Undo/Redo")
    @MainActor
    func tableStructureUndo() async throws {
        let source = "Vorher 😀\n\n| Links | Rechts |\n| :--- | ---: |\n| **A** | B |\n\nNachher exakt\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let result = try await web.evaluateJavaScript("""
            (() => {const cell=document.querySelector('td'),r=document.createRange();r.selectNodeContents(cell);r.collapse(true);
            getSelection().removeAllRanges();getSelection().addRange(r);return fastraVisual.tableCommand('rowAfter');})()
            """) as? [String: Any]
        #expect(result?["ok"] as? Bool == true)
        try #require(await waitUntil { workspace.activeTab?.content != source })
        let changed = try #require(workspace.activeTab?.content)
        #expect(changed.hasPrefix("Vorher 😀\n\n"))
        #expect(changed.hasSuffix("Nachher exakt\n"))
        #expect(changed.contains("**A**"))
        #expect(try await web.evaluateJavaScript("document.querySelector('table').rows.length") as? Int == 3)
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
        _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == changed })
        withExtendedLifetime(coordinator) {}
    }

    @Test("Tabellenänderungen erreichen AppKits nativen Undo-Verwalter")
    @MainActor
    func tableAppKitUndo() async throws {
        let source = "| Kopf | Wert |\n| --- | --- |\n| A | B |\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        _ = try await web.evaluateJavaScript("{const cell=document.querySelector('td'),r=document.createRange();r.selectNodeContents(cell);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);fastraVisual.tableCommand('rowAfter');}")
        try #require(await waitUntil { workspace.activeTab?.content != source })
        let changed = try #require(workspace.activeTab?.content)
        let manager = try #require(web.undoManager)
        try #require(manager.canUndo)
        manager.undo()
        try #require(await waitUntil { workspace.activeTab?.content == source })
        try #require(manager.canRedo)
        manager.redo()
        try #require(await waitUntil { workspace.activeTab?.content == changed })
    }

    @Test("Tabellenstruktur bewahrt Pipe-Zeichen in Formeln und geschützten Kommentaren")
    @MainActor
    func tableProtectedPipes() async throws {
        let source = "| Kopf | Ende |\n| --- | --- |\n| $x\\|y$ <!-- merken \\| exakt $& $$ --> | B |\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let diagnostic = MarkdownVisualDocument.render(source, documentURL: nil)
        _ = try await web.evaluateJavaScript("{const c=document.querySelector('td'),r=document.createRange();r.selectNodeContents(c);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);fastraVisual.tableCommand('columnAfter');}")
        try #require(await waitUntil { workspace.activeTab?.content != source })
        let saved = try #require(workspace.activeTab?.content)
        #expect(saved.contains("$x\\|y$"), Comment(rawValue: saved))
        #expect(saved.contains("<!-- merken \\| exakt $& $$ -->"), Comment(rawValue: saved + "\nOPAQUE=" + String(describing: diagnostic.opaqueSources) + "\nHTML=" + diagnostic.fragment.html))
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
        _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == saved })
        coordinator.load(saved, documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "protected-pipes")
        try #require(await waitUntil { coordinator.ready })
        #expect(try await web.evaluateJavaScript("document.querySelector('[data-tex]').dataset.tex") as? String == "x\\|y")
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('[data-md-opaque]').length") as? Int == 1)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Einzeiliges Einfügen über Zelltext erhält ein nicht markiertes Bild")
    @MainActor
    func tablePastePreservesUnselectedImage() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("table-paste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII=")!
        try bytes.write(to: directory.appendingPathComponent("keep.png"))
        let source = "| Kopf |\n| --- |\n| ![Bild](keep.png) Alt |\n"
        let (workspace, coordinator, web, window) = try await editor(source, documentURL: directory.appendingPathComponent("file.md"))
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        try #require(try await web.evaluateJavaScript("document.querySelectorAll('td img').length") as? Int == 1)
        _ = try await web.evaluateJavaScript("""
            {const cell=document.querySelector('td'),text=cell.lastChild,r=document.createRange();r.selectNodeContents(text);
            getSelection().removeAllRanges();getSelection().addRange(r);
            const e=new Event('paste',{bubbles:true,cancelable:true});Object.defineProperty(e,'clipboardData',{value:{files:[],getData:t=>t==='text/html'?'<strong>Neu</strong>':t==='text/plain'?'Neu':''}});cell.dispatchEvent(e);}
            """)
        try #require(await waitUntil { workspace.activeTab?.content != source })
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('td img').length") as? Int == 1)
        #expect(workspace.activeTab?.content.contains("keep.png") == true)
        #expect(workspace.activeTab?.content.contains("Neu") == true)
    }

    @Test("Fastras Markdown-Clipboard ersetzt eine ganze Zelle ohne zusätzlichen Umbruch")
    @MainActor
    func tableInternalClipboardSingleLine() async throws {
        let source = "| Kopf |\n| --- |\n| Alt |\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        coordinator.pasteboard.setData(try JSONSerialization.data(withJSONObject: ["markdown": "**Neu**"]), forType: MarkdownVisualCoordinator.clipboardType)
        _ = try await web.evaluateJavaScript("{const r=document.createRange();r.selectNodeContents(document.querySelector('td'));getSelection().removeAllRanges();getSelection().addRange(r);}")
        #expect(coordinator.pasteImages())
        try #require(await waitUntil { workspace.activeTab?.content.contains("**Neu**") == true })
        let pasted = try await web.evaluateJavaScript("document.querySelector('td').innerText") as? String
        #expect(pasted == "Neu", "Zellinhalt: \(String(describing: pasted))")
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
        _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content.contains("**Neu**") == true })
        #expect(try await web.evaluateJavaScript("document.querySelector('td').innerText") as? String == "Neu")
    }

    @Test("Tabellenwerkzeuge bleiben während einer gezogenen Auswahl unverändert")
    @MainActor
    func tableSelectionDragContext() async throws {
        let source = "| Kopf | Andere |\n| --- | --- |\n| Alt | Bleibt |\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        _ = try await web.evaluateJavaScript("""
            {const c=document.querySelector('td'),r=document.createRange();r.selectNodeContents(c);r.collapse(true);
            getSelection().removeAllRanges();getSelection().addRange(r);}
            """)
        try #require(await waitUntil { workspace.markdownTable.context?.row == 1 })
        let context = workspace.markdownTable.context
        _ = try await web.evaluateJavaScript("""
            {const cells=document.querySelectorAll('td');cells[0].dispatchEvent(new MouseEvent('mousedown',{bubbles:true,button:0,buttons:1}));
            const r=document.createRange();r.setStart(cells[0].firstChild,0);r.setEnd(cells[1].firstChild,2);
            getSelection().removeAllRanges();getSelection().addRange(r);
            document.dispatchEvent(new MouseEvent('mousemove',{bubbles:true,buttons:0}));}
            """)
        coordinator.reportTableContext()
        try await Task.sleep(for: .milliseconds(150))
        #expect(workspace.markdownTable.context == context)
        _ = try await web.evaluateJavaScript("document.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,button:0}));")
        try #require(await waitUntil { workspace.markdownTable.context?.reason == "selection" })
        #expect(workspace.activeTab?.content == source)
    }

    @Test("Vollständiger Zelltext wird ohne zusätzlichen Umbruch ersetzt", arguments: ["", "<span>Neu</span>", "<p>Neu</p>", "<div>Neu</div>", "<strong>Neu</strong>", "<p><strong>Neu</strong></p>\n"])
    @MainActor
    func tableSingleLinePaste(_ html: String) async throws {
        let source = "| Kopf | Andere |\n| --- | --- |\n| Alt | Bleibt |\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        let result = try await web.callAsyncJavaScript("""
            const cell=document.querySelector('td'),range=document.createRange();
            range.selectNodeContents(cell);getSelection().removeAllRanges();getSelection().addRange(range);
            const event=new Event('paste',{bubbles:true,cancelable:true});
            Object.defineProperty(event,'clipboardData',{value:{files:[],getData:t=>t==='text/html'?html:t==='text/plain'?'Neu':''}});
            cell.dispatchEvent(event);const current=document.querySelector('td');return {html:current.innerHTML,text:current.innerText};
            """, arguments: ["html": html], in: nil, contentWorld: .page) as? [String: String]
        try #require(await waitUntil { workspace.activeTab?.content != source })
        #expect(result?["text"] == "Neu", "DOM: \(String(describing: result))")
        if html.contains("strong") {
            #expect(try await web.evaluateJavaScript("document.querySelector('td strong')?.textContent") as? String == "Neu")
        }
        #expect(workspace.activeTab?.content.contains("<br") == false)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('td').length") as? Int == 2)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('td')[1].textContent") as? String == "Bleibt")
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
        _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content != source })
        #expect(try await web.evaluateJavaScript("document.querySelector('td').innerText") as? String == "Neu")
        #expect(workspace.activeTab?.content.contains("<br") == false)
    }

    @Test("Formatierte Absätze werden innerhalb einer Zelle nicht versehentlich zu TSV-Zeilen")
    @MainActor
    func tableRichPaste() async throws {
        let source = "| Kopf |\n| --- |\n| Alt |\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            {const c=document.querySelector('td'),r=document.createRange();r.selectNodeContents(c);getSelection().removeAllRanges();getSelection().addRange(r);
            const event=new Event('paste',{bubbles:true,cancelable:true});Object.defineProperty(event,'clipboardData',{value:{files:[],getData:t=>t==='text/html'?'<strong>Zwei</strong><br>Drei':t==='text/plain'?'Zwei\\nDrei':''}});c.dispatchEvent(event);}
            """)
        try #require(await waitUntil { workspace.activeTab?.content != source })
        #expect(workspace.activeTab?.content.contains("**Zwei**") == true)
        #expect(try await web.evaluateJavaScript("document.querySelector('table').rows.length") as? Int == 2)
        #expect(try await web.evaluateJavaScript("document.querySelector('td strong').textContent") as? String == "Zwei")
        withExtendedLifetime(coordinator) {}
    }

    @Test("Ein bearbeiteter Tabellenblock bewahrt Spaltenausrichtung")
    @MainActor
    func tableAlignment() async throws {
        let (workspace, coordinator, web, window) = try await editor("| Links | Rechts |\n| :--- | ---: |\n| A | B |\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("document.querySelector('td').textContent='Neu';fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content.contains("Neu") == true })
        let html = MarkdownRichText.htmlFragment(markdown: workspace.activeTab!.content)
        #expect(html.contains("align=\"left\""))
        #expect(html.contains("align=\"right\""))
        withExtendedLifetime(coordinator) {}
    }

    @Test("Tabellenaktionen erhalten Formatierung und lassen sich einzeln rückgängig machen", arguments: [
        "rowBefore", "rowAfter", "deleteRow", "rowUp", "rowDown", "columnBefore", "columnAfter",
        "deleteColumn", "columnLeft", "columnRight", "alignDefault", "alignLeft", "alignCenter", "alignRight"
    ])
    @MainActor
    func tableActions(_ command: String) async throws {
        let middle = command == "alignCenter" ? ":---" : ":---:"
        let source = "Davor\n\n| A | B | C |\n| :--- | \(middle) | ---: |\n| **eins** | `zwei` | $x$ |\n| vier | fünf | sechs |\n| sieben | acht | neun |\n\nDanach\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let result = try await web.callAsyncJavaScript("""
            const cell=document.querySelector('table').rows[2].cells[1],r=document.createRange();
            r.selectNodeContents(cell);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);
            return fastraVisual.tableCommand(command);
            """, arguments: ["command": command], in: nil, contentWorld: .page) as? [String: Any]
        #expect(result?["ok"] as? Bool == true)
        try #require(await waitUntil { workspace.activeTab?.content != source })
        let changed = try #require(workspace.activeTab?.content)
        #expect(changed.hasPrefix("Davor\n\n") && changed.hasSuffix("Danach\n"))
        #expect(changed.contains("**eins**") && changed.contains("$x$"))
        if command != "deleteColumn" { #expect(changed.contains("`zwei`")) }
        let dimensions = try await web.evaluateJavaScript("[document.querySelector('table').rows.length,document.querySelector('table').rows[0].cells.length]") as? [Int]
        #expect(dimensions == [command.hasPrefix("rowB") || command == "rowAfter" ? 5 : command == "deleteRow" ? 3 : 4,
                               command.hasPrefix("columnB") || command == "columnAfter" ? 4 : command == "deleteColumn" ? 2 : 3])
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
        _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == changed })
        withExtendedLifetime(coordinator) {}
    }

    @Test("TSV erweitert Tabellen, schützt Klartext und verwirft zu große Eingaben", arguments: ["A\tB\r\nC\t\r\n", "=1+1\t<b>kein HTML</b>\n😀|Pipe\\\t**klar**", "\t\n\t", "  A  B  \tC\n \t  D  "])
    @MainActor
    func tableTSV(_ text: String) async throws {
        let source = "Vorher\n\n| Kopf |\n| --- |\n| Alt |\n\nNachher\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let result = try await web.callAsyncJavaScript("""
            const cell=document.querySelector('td'),r=document.createRange();r.selectNodeContents(cell);r.collapse(true);
            getSelection().removeAllRanges();getSelection().addRange(r);return fastraVisual.tableCommand('pasteTSV',text);
            """, arguments: ["text": text], in: nil, contentWorld: .page) as? [String: Any]
        #expect(result?["ok"] as? Bool == true)
        try #require(await waitUntil { workspace.activeTab?.content != source })
        #expect(try await web.evaluateJavaScript("Array.from(document.querySelector('table').rows).map(r=>Array.from(r.cells,c=>c.textContent))") as? [[String]] == [["Kopf", ""], text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[0].components(separatedBy: "\t"), text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[1].components(separatedBy: "\t")])
        let saved = try #require(workspace.activeTab?.content)
        #expect(saved.hasPrefix("Vorher\n\n") && saved.hasSuffix("Nachher\n"))
        let oversized = try await web.evaluateJavaScript("fastraVisual.tableCommand('pasteTSV','x\\n'.repeat(1001))") as? [String: Any]
        #expect(oversized?["reason"] as? String == "size")
        #expect(workspace.activeTab?.content == saved)
        let stale = try await web.evaluateJavaScript("fastraVisual.tableCommand('deleteRow','','expired')") as? [String: Any]
        #expect(stale?["reason"] as? String == "stale")
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
        coordinator.load(saved, documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "tsv-reopen")
        try #require(await waitUntil { coordinator.ready })
        let reopened = try await web.evaluateJavaScript("Array.from(document.querySelector('table').rows).slice(1).map(r=>Array.from(r.cells,c=>c.textContent))") as? [[String]]
        let expected = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).prefix(2).map { $0.components(separatedBy: "\t") }
        #expect(reopened == expected)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Auch vollständig leere Tabellen bleiben als Markdown-Struktur erhalten")
    @MainActor
    func tableEmptyStructure() async throws {
        let source = "| | |\n| --- | --- |\n| | |\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("{const c=document.querySelector('td'),r=document.createRange();r.selectNodeContents(c);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);fastraVisual.tableCommand('rowAfter');}")
        try #require(await waitUntil { workspace.activeTab?.content != source })
        let saved = try #require(workspace.activeTab?.content)
        #expect(saved.contains("| --- | --- |"))
        #expect(try await web.evaluateJavaScript("document.querySelector('table').rows.length") as? Int == 3)
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
        coordinator.load(saved, documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "empty-table")
        try #require(await waitUntil { coordinator.ready })
        #expect(try await web.evaluateJavaScript("document.querySelector('table').rows.length") as? Int == 3)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Tabellenbefehle schützen Zellenauswahl, Kopfzeile, letzte Spalte und HTML")
    @MainActor
    func tableGuards() async throws {
        let source = "| Kopf |\n| --- |\n| Inhalt |\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let reasons = try await web.evaluateJavaScript("""
            (()=>{const table=document.querySelector('table'),s=getSelection(),r=document.createRange();
            function select(a,b=a){r.setStart(a,0);r.setEnd(b,b.childNodes.length);s.removeAllRanges();s.addRange(r);}
            select(table.rows[0].cells[0]);const header=fastraVisual.tableCommand('deleteRow').reason;
            const last=fastraVisual.tableCommand('deleteColumn').reason;
            select(table.rows[0].cells[0],table.rows[1].cells[0]);const multi=fastraVisual.tableCommand('rowAfter').reason;
            select(table.rows[1].cells[0]);table.removeAttribute('data-md-table');const html=fastraVisual.tableCommand('rowAfter').reason;
            table.dataset.mdTable='gfm';return [header,last,multi,html];})()
            """) as? [String]
        #expect(reasons == ["edge", "edge", "selection", "html"])
        #expect(workspace.activeTab?.content == source)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Tab navigiert zwischen Zellen und fügt am Ende eine Datenzeile ein")
    @MainActor
    func tableKeyboard() async throws {
        let source = "| H1 | H2 |\n| --- | --- |\n| A | B |\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("{const c=document.querySelector('table').rows[1].cells[1],r=document.createRange();r.selectNodeContents(c);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);document.getElementById('fastra-visual').dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));}")
        try #require(await waitUntil { workspace.activeTab?.content != source })
        #expect(try await web.evaluateJavaScript("fastraVisual.tableContext().row") as? Int == 2)
        #expect(try await web.evaluateJavaScript("fastraVisual.tableContext().column") as? Int == 0)
        _ = try await web.evaluateJavaScript("document.getElementById('fastra-visual').dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',shiftKey:true,bubbles:true,cancelable:true}));")
        #expect(try await web.evaluateJavaScript("fastraVisual.tableContext().row") as? Int == 1)
        #expect(try await web.evaluateJavaScript("fastraVisual.tableContext().column") as? Int == 1)
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
        withExtendedLifetime(coordinator) {}
    }

    @Test("Tab am Zeilen- oder Zellenlimit meldet den Größenfehler sichtbar", arguments: [false, true])
    @MainActor
    func tableKeyboardLimits(_ rowLimit: Bool) async throws {
        let source = "| Kopf |\n| --- |\n| Inhalt |\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let rows = rowLimit ? 1000 : 100, columns = rowLimit ? 1 : 100
        let prevented = try await web.callAsyncJavaScript("""
            const table=document.querySelector('table');
            table.innerHTML='<thead><tr>'+('<th>H</th>'.repeat(columns))+'</tr></thead><tbody>'+
                ('<tr>'+('<td>x</td>'.repeat(columns))+'</tr>').repeat(rows-1)+'</tbody>';
            const cell=table.rows[rows-1].cells[columns-1],r=document.createRange();r.selectNodeContents(cell);r.collapse(true);
            getSelection().removeAllRanges();getSelection().addRange(r);
            const event=new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true});
            document.getElementById('fastra-visual').dispatchEvent(event);return event.defaultPrevented;
            """, arguments: ["rows": rows, "columns": columns], in: nil, contentWorld: .page) as? Bool
        #expect(prevented == true)
        try #require(await waitUntil { workspace.markdownTable.error != nil })
        #expect(workspace.markdownTable.error == L10n.string("Die Tabelle darf höchstens 1.000 Zeilen, 100 Spalten und 10.000 Zellen enthalten; eingefügter Text höchstens 1 MiB."))
        #expect(workspace.activeTab?.content == source)
        #expect(try await web.evaluateJavaScript("document.querySelector('table').rows.length") as? Int == rows)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Plattenabläufe schützen noch nicht zurückgemeldete WYSIWYG-Eingaben anderer Fenster")
    @MainActor
    func serialRunnerIntegrationWorkflowPendingVisualInput() async throws {
        let root = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("input.md"), source = "Original\n"
        try Data(source.utf8).write(to: url)
        let (other, coordinator, web, window) = try await editor(source, documentURL: url)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        other.tabs[0].recordSavedContentBaseline()
        _ = try await web.evaluateJavaScript("document.querySelector('p').textContent='Pending edit';")
        #expect(other.tabs[0].content == source && !other.tabs[0].hasUnsavedChanges)
        let owner = Workspace(); owner.fileTreeMutationWorkspaceProvider = { [other] }
        let (success, held) = await owner.synchronizeTextWorkflowDiskDocuments()
        defer { held.forEach { $0.finish() } }
        #expect(success && other.tabs[0].content.contains("Pending edit") && other.tabs[0].hasUnsavedChanges)
        let mutation = try owner.beginTextWorkflowDiskMutation(urls: [url])
        defer { owner.finishTextWorkflowDiskMutation(mutation, changedURLs: [], session: nil) }
        let result = await Task.detached { Result { try mutation.preflight(in: owner) } }.value
        if case .success = result { Issue.record("Nicht zurückgemeldete WYSIWYG-Eingabe wurde überschreibbar") }
        #expect(try Data(contentsOf: url) == Data(source.utf8))
        withExtendedLifetime(coordinator) {}
    }

    @Test("Diagramm in einem bearbeiteten Zitat bleibt Markdown und renderbar")
    @MainActor
    func nestedDiagram() async throws {
        let source = "> Absatz\n>\n> ```mermaid\n> graph TD; A-->B\n> ```\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("document.querySelector('blockquote p').textContent='Neu';fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content.contains("Neu") == true })
        #expect(workspace.activeTab?.content.contains("```mermaid") == true)
        #expect(workspace.activeTab?.content.contains("graph TD; A-->B") == true)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Andere Tabs schließen fragt auch bei noch ausstehender visueller Eingabe nach")
    @MainActor
    func closeOthersSynchronizes() async throws {
        let (workspace, coordinator, web, window) = try await editor("Original\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let original = workspace.activeTabID!
        let other = EditorTab(title: "other.txt", path: "")
        workspace.tabs.append(other)
        var asked = false
        workspace.confirmCloseHandler = { _ in asked = true; return .cancel }
        _ = try await web.evaluateJavaScript("document.querySelector('#fastra-visual p').textContent='Noch nicht übernommen';")
        workspace.closeOtherTabs(keeping: other.id)
        try #require(await waitUntil { asked })
        #expect(workspace.tabs.contains { $0.id == original && $0.content.contains("Noch nicht übernommen") })
        #expect(workspace.tabs.count == 2)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Komposition bleibt bis zum Abschluss editierbar und entwertet weitere Eingaben nicht")
    @MainActor
    func compositionSynchronization() async throws {
        let (workspace, coordinator, web, window) = try await editor("Original\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            const root=document.getElementById('fastra-visual');root.dispatchEvent(new Event('compositionstart'));
            root.querySelector('p').textContent='Zwischenstand';
            """)
        var synchronized: Bool?
        coordinator.synchronize { synchronized = $0 }
        try #require(await waitUntil { synchronized != nil })
        #expect(synchronized == false)
        #expect(workspace.activeTab?.content == "Original\n")
        _ = try await web.evaluateJavaScript("""
            document.querySelector('#fastra-visual p').textContent='完成';
            document.getElementById('fastra-visual').dispatchEvent(new Event('compositionend'));
            """)
        try #require(await waitUntil { workspace.activeTab?.content.contains("完成") == true })
        _ = try await web.evaluateJavaScript("document.querySelector('#fastra-visual p').textContent+=' weiter';fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content.contains("完成 weiter") == true })
    }

    @Test("Textauswahlen bewahren ihre umgebenden Markdown-Stile beim Kopieren und Einfügen", arguments: [
        ["**Anfang Ziél😀 Ende**", "strong", "strong"],
        ["*Anfang Ziél😀 Ende*", "em", "em"],
        ["~~Anfang Ziél😀 Ende~~", "del", "del"],
        ["==Anfang Ziél😀 Ende==", "mark", "mark"],
        ["`Anfang Ziél😀 Ende`", "code", "code"],
        ["[Anfang Ziél😀 Ende](https://example.com/ziel)", "a", "a[href='https://example.com/ziel']"],
        ["***Anfang Ziél😀 Ende***", "em", "em strong, strong em"],
        ["**Anfang *Ziél😀* Ende**", "em", "strong em, em strong"],
        ["## Anfang Ziél😀 Ende", "h2", "h2"],
        ["> Anfang Ziél😀 Ende", "p", "blockquote"],
        ["- Anfang Ziél😀 Ende", "li", "ul li"],
        ["7. Anfang Ziél😀 Ende", "li", "ol[start='7'] li"],
        ["7. Vorher\n8. Anfang Ziél😀 Ende\n9. Nachher", "li:nth-child(2)", "ol[start='8'] li"],
        ["- Außen\n    - Anfang Ziél😀 Ende", "li li", "ul li ul li"],
        ["- [x] Anfang Ziél😀 Ende", "li", "ul li input:checked"],
        ["- [ ] Anfang Ziél😀 Ende", "li", "ul li input:not(:checked)"],
        ["| Kopf |\n| --- |\n| **Anfang Ziél😀 Ende** |", "td strong", "strong"],
        ["```swift\n// Anfang Ziél😀 Ende\n```", "code", "pre code.language-swift"],
        ["<u>Anfang Ziél😀 Ende</u>", "u", "u"],
        ["Anfang <sub>Ziél😀</sub> Ende", "sub", "sub"],
        ["Anfang <sup>Ziél😀</sup> Ende", "sup", "sup"],
        ["Anfang <kbd>Ziél😀</kbd> Ende", "kbd", "kbd"],
        ["Anfang <ins>Ziél😀</ins> Ende", "ins", "ins"],
        ["Anfang <small>Ziél😀</small> Ende", "small", "small"],
        ["Anfang <samp>Ziél😀</samp> Ende", "samp", "samp"],
        ["Anfang <var>Ziél😀</var> Ende", "var", "var"],
        ["Anfang <q>Ziél😀</q> Ende", "q", "q"],
        ["Anfang <cite>Ziél😀</cite> Ende", "cite", "cite"],
        ["Anfang <abbr title=\"Erklärung\">Ziél😀</abbr> Ende", "abbr", "abbr[title='Erklärung']"],
        ["Anfang <dfn>Ziél😀</dfn> Ende", "dfn", "dfn"]
    ])
    @MainActor
    func copyPasteSelectionStyles(_ fixture: [String]) async throws {
        let source = fixture[0] + "\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        _ = try await web.callAsyncJavaScript("""
            const walker=document.createTreeWalker(document.querySelector('#fastra-visual '+selector),NodeFilter.SHOW_TEXT);
            let text;while(walker.nextNode()){if(walker.currentNode.data.includes('Ziél😀')){text=walker.currentNode;break;}}
            const range=document.createRange(),start=text.data.indexOf('Ziél😀');
            range.setStart(text,start);range.setEnd(text,start+'Ziél😀'.length);
            getSelection().removeAllRanges();getSelection().addRange(range);
            document.getElementById('fastra-visual').dispatchEvent(new Event('copy',{bubbles:true,cancelable:true}));
            """, arguments: ["selector": fixture[1]], in: nil, contentWorld: .page)
        try #require(await waitUntil { coordinator.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType) != nil })
        let payload = try #require(coordinator.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType))
        let copied = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: String])["markdown"] ?? ""
        #expect(workspace.activeTab?.content == source)
        #expect(coordinator.pasteboard.string(forType: .string) == "Ziél😀")
        let html = try #require(coordinator.pasteboard.string(forType: .html))
        #expect(try await web.callAsyncJavaScript("return !!new DOMParser().parseFromString(html,'text/html').querySelector(selector);",
            arguments: ["html": html, "selector": fixture[2]], in: nil, contentWorld: .page) as? Bool == true)
        let rtf = try #require(coordinator.pasteboard.data(forType: .rtf))
        let attributed = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let offset = (attributed.string as NSString).range(of: "Ziél😀").location
        try #require(offset != NSNotFound)
        let font = attributed.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
        if fixture[2] == "strong" { #expect(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true) }
        if fixture[2] == "em" { #expect(font.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == true) }
        if fixture[2] == "u" { #expect((attributed.attribute(.underlineStyle, at: offset, effectiveRange: nil) as? Int ?? 0) != 0) }
        if fixture[2] == "del" { #expect((attributed.attribute(.strikethroughStyle, at: offset, effectiveRange: nil) as? Int ?? 0) != 0) }
        if fixture[2] == "mark" { #expect(attributed.attribute(.backgroundColor, at: offset, effectiveRange: nil) != nil) }
        let (target, receiver, targetWeb, targetWindow) = try await editor("Ziel\n")
        defer { targetWeb.configuration.userContentController.removeAllScriptMessageHandlers(); targetWindow.close(); withExtendedLifetime(receiver) {} }
        receiver.pasteboard = coordinator.pasteboard
        _ = try await targetWeb.evaluateJavaScript("{const r=document.createRange();r.selectNodeContents(document.getElementById('fastra-visual'));getSelection().removeAllRanges();getSelection().addRange(r);}")
        #expect(receiver.pasteImages())
        try #require(await waitUntil { target.activeTab?.content != "Ziel\n" })
        let matched = try await targetWeb.callAsyncJavaScript("return !!document.querySelector('#fastra-visual '+selector);",
            arguments: ["selector": fixture[2]], in: nil, contentWorld: .page) as? Bool
        #expect(matched == true, Comment(rawValue: "Quelle: " + source + " Kopie: " + copied + " Ziel: " + target.activeTab!.content))
        #expect(!target.activeTab!.content.contains("Anfang"))
        #expect(!target.activeTab!.content.contains("Ende"))
    }

    @Test("Blockübergreifende Teilauswahl behält Listennummer und Aufgabenstatus", arguments: [false, true])
    @MainActor
    func copyPartialListAcrossBlocks(_ task: Bool) async throws {
        let source = (task ? "- [ ] Auslassen\n- [x] Anfang **Ziél😀** Ende\n- [ ] Danach" : "7. Auslassen\n8. Anfang **Ziél😀** Ende\n9. Danach") + "\n\nSchluss\n"
        let (_, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        _ = try await web.evaluateJavaScript("""
            {const root=document.getElementById('fastra-visual'),r=document.createRange();
            r.setStart(root.querySelector('li:nth-child(2) strong').firstChild,0);
            r.setEnd(root.lastElementChild.querySelector('p').firstChild,7);
            getSelection().removeAllRanges();getSelection().addRange(r);root.dispatchEvent(new Event('copy',{bubbles:true,cancelable:true}));}
            """)
        try #require(await waitUntil { coordinator.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType) != nil })
        let data = try #require(coordinator.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType))
        let copied = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])["markdown"] ?? ""
        #expect(copied.hasPrefix(task ? "- [x] " : "8. ") && copied.contains("**Ziél😀**"), Comment(rawValue: copied))
        #expect(!copied.contains("Auslassen"))
        #expect(!copied.contains("Anfang"))
        #expect(copied.contains("Schluss"))
    }

    @Test("Gemischte Clipboard-Inhalte behalten alle Auszeichnungen nach Einfügen, Undo und erneutem Öffnen",
          arguments: [[false, false], [true, false], [false, true], [true, true]], [false, true])
    @MainActor
    func copyPasteDocumentStyles(_ scenario: [Bool], _ documentBacked: Bool) async throws {
        let cut = scenario[0], htmlOnly = scenario[1]
        let source = """
        ## **Titel** mit *Kursiv*

        **Fett** *Kursiv* ***Beides*** ~~Gestrichen~~ ==Markiert== `Code`
        [Verweis](https://example.com/ziel "Titel") <u>Unterstrichen</u> <sub>Tief</sub> <sup>Hoch</sup> <kbd>Taste</kbd>

        > **Zitat** mit *Stil*

        7. **Sieben**
        8. *Acht*
            - ==Verschachtelt==

        - [x] **Erledigt**
        - [ ] *Offen*

        | Links | Rechts |
        | :--- | ---: |
        | **Fett** | <u>Unterstrichen</u> |

        ```swift
        // Code mit Leerzeichen und 😀
        let value = 7
        ```
        """ + "\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        let snapshot = """
            Array.from(document.querySelectorAll('#fastra-visual h2,#fastra-visual strong,#fastra-visual em,#fastra-visual del,#fastra-visual mark,#fastra-visual a,#fastra-visual u,#fastra-visual sub,#fastra-visual sup,#fastra-visual kbd,#fastra-visual blockquote,#fastra-visual ol,#fastra-visual ul,#fastra-visual li,#fastra-visual input,#fastra-visual table,#fastra-visual th,#fastra-visual td,#fastra-visual code'),n=>[n.tagName,n.textContent.trim(),n.getAttribute('href'),n.getAttribute('title'),n.getAttribute('align'),n.getAttribute('start'),n.tagName==='INPUT'?n.checked:null,n.tagName==='CODE'?Array.from(n.classList).find(c=>c.startsWith('language-')) || '':null])
            """
        let expected = try #require(try await web.evaluateJavaScript("JSON.stringify(" + snapshot + ")") as? String)
        _ = try await web.evaluateJavaScript("{const root=document.getElementById('fastra-visual'),r=document.createRange();r.selectNodeContents(root);getSelection().removeAllRanges();getSelection().addRange(r);root.dispatchEvent(new Event('\(cut ? "cut" : "copy")',{bubbles:true,cancelable:true}));}")
        try #require(await waitUntil { coordinator.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType) != nil })
        if cut {
            try #require(await waitUntil { workspace.activeTab?.content != source })
            _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
            try #require(await waitUntil { workspace.activeTab?.content == source })
        }
        let directory = testTemporaryDirectory().appendingPathComponent("visual-paste-\(UUID().uuidString)")
        let targetFile = documentBacked ? directory.appendingPathComponent("ziel.md") : nil
        defer { if documentBacked { try? FileManager.default.removeItem(at: directory) } }
        let originalBytes = Data("Ziel\n".utf8)
        if let targetFile {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try originalBytes.write(to: targetFile)
        }
        let (target, receiver, targetWeb, targetWindow) = try await editor("Ziel\n", documentURL: targetFile)
        defer { targetWeb.configuration.userContentController.removeAllScriptMessageHandlers(); targetWindow.close(); withExtendedLifetime(receiver) {} }
        if let targetFile { target.tabs[0].diskSnapshot = try FileSnapshot.readSnapshotOnly(from: targetFile) }
        receiver.pasteboard = coordinator.pasteboard
        _ = try await targetWeb.evaluateJavaScript("{const r=document.createRange();r.selectNodeContents(document.getElementById('fastra-visual'));getSelection().removeAllRanges();getSelection().addRange(r);}")
        if htmlOnly {
            _ = try await targetWeb.callAsyncJavaScript("""
                const event=new Event('paste',{bubbles:true,cancelable:true});
                Object.defineProperty(event,'clipboardData',{value:{files:[],getData:type=>type==='text/html'?html:type==='text/plain'?plain:''}});
                document.getElementById('fastra-visual').dispatchEvent(event);
                """, arguments: ["html": coordinator.pasteboard.string(forType: .html) ?? "", "plain": coordinator.pasteboard.string(forType: .string) ?? ""], in: nil, contentWorld: .page)
        } else { #expect(receiver.pasteImages()) }
        try #require(await waitUntil { target.activeTab?.content != "Ziel\n" })
        let pasted = target.activeTab!.content
        #expect(try await targetWeb.evaluateJavaScript("JSON.stringify(" + snapshot + ")") as? String == expected, Comment(rawValue: pasted))
        _ = try await targetWeb.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { target.activeTab?.content == "Ziel\n" })
        _ = try await targetWeb.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
        try #require(await waitUntil { target.activeTab?.content == pasted })
        var reloadError: String?
        target.saveSafetyWarningHandler = { title, text in
            if reloadError == nil { reloadError = title + ": " + text }
        }
        let previousDocument = await visualDiagnostic(targetWeb, script: visualDiagnosticSnapshot)
        let previousGeneration = receiver.generation
        targetWeb.configuration.userContentController.addUserScript(WKUserScript(
            source: visualPhaseProbe("start"), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        receiver.load(pasted, documentURL: targetFile, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "reload")
        // WebKits erneuter Start braucht dieselbe Frist wie das erste Öffnen.
        let reloaded = await waitUntil(timeout: 12) { receiver.ready }
        if !reloaded {
            print("MARKDOWN_RELOAD_DIAGNOSTIC cut=\(cut) htmlOnly=\(htmlOnly) loading=\(targetWeb.isLoading) progress=\(targetWeb.estimatedProgress) generation=\(receiver.generation) ownerPresent=\(receiver.workspace != nil) activeTabMatches=\(receiver.tabID == target.activeTabID) sourceMatches=\(receiver.markdown == pasted) generationBefore=\(previousGeneration) historyPerforming=\(target.activeTab?.undoHistory.isPerformingAction == true) warning=\(reloadError ?? "none")")
            print("MARKDOWN_RELOAD_PHASE_DIAGNOSTIC before=\(previousDocument) after=\(await visualDiagnostic(targetWeb, script: visualDiagnosticSnapshot))")
        }
        try #require(reloaded)
        #expect(try await targetWeb.evaluateJavaScript("JSON.stringify(" + snapshot + ")") as? String == expected, Comment(rawValue: pasted))

        guard let targetFile else { return }
        try #require(target.activeTab?.isDirty == true)
        try #require(try Data(contentsOf: targetFile) == originalBytes)
        var saveError: String?
        target.saveSafetyWarningHandler = { saveError = $0 + ": " + $1 }
        target.saveActiveTab()
        try #require(await waitUntil { saveError != nil || target.activeTab?.isDirty == false })
        try #require(saveError == nil, Comment(rawValue: saveError ?? ""))
        let id = try #require(target.activeTabID)
        target.tabs.append(EditorTab(title: "anchor.txt", path: "", content: "Anker"))
        var closeConfirmationRequested = false
        target.confirmCloseHandler = { _ in closeConfirmationRequested = true; return .cancel }
        target.closeTab(id: id)
        try #require(await waitUntil(timeout: 12) { !target.tabs.contains { $0.id == id } || closeConfirmationRequested })
        try #require(!closeConfirmationRequested)

        let saved = try Data(contentsOf: targetFile)
        try #require(saved == Data(pasted.utf8))
        let (freshWorkspace, freshCoordinator, freshWeb, freshWindow) = try await reopenEditor(
            at: targetFile, savedBytes: saved
        )
        defer { freshWeb.configuration.userContentController.removeAllScriptMessageHandlers(); freshWindow.close(); withExtendedLifetime((freshWorkspace, freshCoordinator)) {} }
        #expect(try await freshWeb.evaluateJavaScript("JSON.stringify(" + snapshot + ")") as? String == expected, Comment(rawValue: pasted))
    }

    @Test("Ordnerumzüge erhalten benachbarte Bildquellen, Rich-Text-Kopien und WebKit-Undo")
    @MainActor
    func relocatedParentImageClipboard() async throws {
        let root = testTemporaryDirectory().appendingPathComponent("visual-relocation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("A")
        let file = original.appendingPathComponent("docs/doc.md")
        for directory in [file.deletingLastPathComponent(), original.appendingPathComponent("images")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII="))
        try bytes.write(to: original.appendingPathComponent("images/p #.png"))
        let source = "Text\n\n![Bild](../images/p%20%23.png)\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let (workspace, coordinator, web, window) = try await editor(source, documentURL: file)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        _ = try await web.evaluateJavaScript("""
            (() => {
            window.originalImage=document.querySelector('img');
            const p=document.querySelector('p'),r=document.createRange();r.selectNodeContents(p);r.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(r);
            document.execCommand('insertText',false,'X');fastraVisual.flush();
            })();
            """)
        try #require(await waitUntil { workspace.activeTab?.content != source })
        var previous = file
        for name in ["B", "C"] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.moveItem(at: previous.deletingLastPathComponent().deletingLastPathComponent(), to: directory)
            let moved = directory.appendingPathComponent("docs/doc.md")
            workspace.tabs[0].url = moved
            coordinator.relocateDocument(from: previous, to: moved)
            previous = moved
            #expect(try await web.evaluateJavaScript("originalImage===document.querySelector('img')") as? Bool == true)
            _ = try await web.evaluateJavaScript("""
                (() => {
                const root=document.getElementById('fastra-visual'),r=document.createRange();r.selectNodeContents(root);
                getSelection().removeAllRanges();getSelection().addRange(r);
                root.dispatchEvent(new Event('copy',{bubbles:true,cancelable:true}));
                })();
                """)
            try #require(await waitUntil { coordinator.pasteboard.data(forType: .rtfd) != nil })
            #expect(coordinator.pasteboard.string(forType: .html)?.contains("data:image/png;base64," + bytes.base64EncodedString()) == true)
            let rtfd = try #require(coordinator.pasteboard.data(forType: .rtfd))
            let rich = try #require(NSAttributedString(rtfd: rtfd, documentAttributes: nil))
            var attachments = [Data]()
            rich.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
                if let data = (value as? NSTextAttachment)?.fileWrapper?.regularFileContents { attachments.append(data) }
            }
            #expect(attachments == [bytes])
            coordinator.pasteboard.clearContents()
        }
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
        #expect(try String(contentsOf: previous, encoding: .utf8) == source)
    }

    @Test("Quellaliasse desselben Bildes bleiben nach einem Ordnerumzug unabhängig kopierbar")
    @MainActor
    func relocatedImageSourceAliasesClipboard() async throws {
        let root = testTemporaryDirectory().appendingPathComponent("visual-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("A/docs")
        let relocated = root.appendingPathComponent("B/renamed")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relocated.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII="))
        try bytes.write(to: original.appendingPathComponent("img.png"))
        // Der dritte Alias liegt im selben Absatz und prüft zusätzlich den Renderloop.
        let source = "![a](img.png)\n\n![b](../docs/img.png) ![c](./img.png)\n"
        let file = original.appendingPathComponent("doc.md")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let (workspace, coordinator, web, window) = try await editor(source, documentURL: file)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        try FileManager.default.moveItem(at: original, to: relocated)
        let moved = relocated.appendingPathComponent("doc.md")
        workspace.tabs[0].url = moved
        coordinator.relocateDocument(from: file, to: moved)
        for alt in ["a", "c"] {
            coordinator.pasteboard.clearContents()
            _ = try await web.callAsyncJavaScript("""
                const root=document.getElementById('fastra-visual'),range=document.createRange();
                range.selectNode(document.querySelector('img[alt="'+alt+'"]'));
                getSelection().removeAllRanges();getSelection().addRange(range);
                root.dispatchEvent(new Event('copy',{bubbles:true,cancelable:true}));
                """, arguments: ["alt": alt], in: nil, contentWorld: .page)
            try #require(await waitUntil { coordinator.pasteboard.data(forType: .rtfd) != nil })
            #expect(coordinator.pasteboard.string(forType: .html)?.contains("data:image/png;base64," + bytes.base64EncodedString()) == true)
            let rtfd = try #require(coordinator.pasteboard.data(forType: .rtfd))
            let rich = try #require(NSAttributedString(rtfd: rtfd, documentAttributes: nil))
            var attachments = [Data]()
            rich.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
                if let data = (value as? NSTextAttachment)?.fileWrapper?.regularFileContents { attachments.append(data) }
            }
            #expect(attachments == [bytes])
        }
        #expect(workspace.activeTab?.content == source)
    }

    @Test("Kopieren und Einfügen bewahrt Bilder, Formeln und Kommentare in einer zweiten Datei")
    @MainActor
    func copyPasteRichMarkdown() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("fastra-visual-paste-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first/test.md"), secondURL = directory.appendingPathComponent("second/test.md")
        for url in [firstURL, secondURL] { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: firstURL.deletingLastPathComponent().appendingPathComponent("images"), withIntermediateDirectories: true)
        let image = firstURL.deletingLastPathComponent().appendingPathComponent("images/long.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII=")!.write(to: image)
        let source = "<u>**Bild** ![Alt](images/long.png) $x$ <!-- erhalten --></u>\n"
        let (_, first, firstWeb, firstWindow) = try await editor(source, documentURL: firstURL)
        defer { firstWeb.configuration.userContentController.removeAllScriptMessageHandlers(); firstWindow.close() }
        _ = try await firstWeb.evaluateJavaScript("""
            const root=document.getElementById('fastra-visual'),r=document.createRange();r.selectNodeContents(root);
            getSelection().removeAllRanges();getSelection().addRange(r);root.dispatchEvent(new Event('copy',{bubbles:true,cancelable:true}));
            """)
        try #require(await waitUntil { first.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType) != nil })
        try #require(await waitUntil { first.pasteboard.data(forType: .rtfd) != nil })
        #expect(first.pasteboard.string(forType: .html)?.contains("data:image/png;base64,") == true)
        #expect(first.pasteboard.string(forType: .html)?.contains("fastra-preview:") == false)
        let (secondWorkspace, second, secondWeb, secondWindow) = try await editor("Ziel\n", documentURL: secondURL)
        defer { secondWeb.configuration.userContentController.removeAllScriptMessageHandlers(); secondWindow.close() }
        second.pasteboard = first.pasteboard
        _ = try await secondWeb.evaluateJavaScript("""
            const p=document.querySelector('#fastra-visual p'),r=document.createRange();r.selectNodeContents(p);r.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(r);
            """)
        #expect(second.pasteImages())
        let pasted = await waitUntil { secondWorkspace.activeTab?.content.contains("images/1.png") == true }
        try #require(pasted)
        #expect(secondWorkspace.activeTab?.content.contains("$x$") == true)
        #expect(secondWorkspace.activeTab?.content.contains("<!-- erhalten -->") == true)
        #expect(secondWorkspace.activeTab?.content.contains("<u>") == true)
        #expect(secondWorkspace.activeTab?.content.contains("data-md-") == false)
        #expect(secondWorkspace.activeTab?.content.contains("fastra-preview:") == false)
        #expect(try Data(contentsOf: secondURL.deletingLastPathComponent().appendingPathComponent("images/1.png")) == Data(contentsOf: image))
    }

    @Test("Suchsprünge warten auf WebKit und zeigen den exakten Quellbereich", arguments: [false, true])
    @MainActor
    func delayedMatchNavigation(_ anotherTab: Bool) async throws {
        let source = "Original\n\nneedle\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let originalID = workspace.activeTabID
        if anotherTab { workspace.tabs.append(EditorTab(title: "other.txt", path: "", content: source)) }
        workspace.scope = anotherTab ? .open : .file
        workspace.findPattern = "needle"
        workspace.showSearchDialog = true
        try #require(await waitUntil {
            workspace.navMatches.count == (anotherTab ? 2 : 1) && !workspace.bufferSearching
        })
        let target = workspace.tabs.last!
        let match = BufferSearch.find(in: source, options: SearchOptions(find: "needle", replace: "", isRegex: false)).matches[0]
        #expect(!NotificationCenter.default.postMatchJump(match, for: workspace))
        _ = try await web.evaluateJavaScript("""
            const prepare=fastraVisual.prepareAction;
            fastraVisual.prepareAction=(...args)=>new Promise(resolve=>{window.releasePrepare=()=>resolve(prepare(...args));});
            void 0;
            """)
        var posted: Bool?
        workspace.navigateToMatch(match, tabID: target.id, requiring: .document(target.documentID),
                                  generation: workspace.beginMatchJump()) { posted = $0 }
        // Die Promise bleibt über beliebig viele Main-Queue-Ticks offen.
        #expect(try await web.evaluateJavaScript("typeof window.releasePrepare") as? String == "function")
        #expect(posted == nil)
        #expect(workspace.pendingEditorJump == nil)
        #expect(workspace.activeTabID == originalID)
        _ = try await web.evaluateJavaScript("window.releasePrepare();")
        try #require(await waitUntil { posted != nil })
        #expect(posted == true)
        #expect(workspace.activeTabID == target.id)
        #expect(!workspace.activeMarkdownIsVisual)
        #expect(workspace.pendingEditorJump?.range == match.range)
        #expect(workspace.pendingEditorJump?.documentID == target.documentID)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Ein veralteter WebKit-Suchsprung aktiviert keinen anderen Tab")
    @MainActor
    func staleDelayedMatchNavigation() async throws {
        let (workspace, coordinator, web, window) = try await editor("Original\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let originalID = workspace.activeTabID
        let target = EditorTab(title: "other.txt", path: "", content: "needle")
        workspace.tabs.append(target)
        let match = BufferSearch.find(in: target.content, options: SearchOptions(find: "needle", replace: "", isRegex: false)).matches[0]
        _ = try await web.evaluateJavaScript("""
            const prepare=fastraVisual.prepareAction;
            fastraVisual.prepareAction=(...args)=>new Promise(resolve=>{window.releasePrepare=()=>resolve(prepare(...args));});
            void 0;
            """)
        var posted: Bool?
        workspace.navigateToMatch(match, tabID: target.id, requiring: .document(target.documentID),
                                  generation: workspace.beginMatchJump()) { posted = $0 }
        #expect(try await web.evaluateJavaScript("typeof window.releasePrepare") as? String == "function")
        _ = workspace.beginMatchJump()
        _ = try await web.evaluateJavaScript("window.releasePrepare();")
        try #require(await waitUntil { posted != nil })
        #expect(posted == false)
        #expect(workspace.activeTabID == originalID)
        #expect(workspace.activeMarkdownIsVisual)
        #expect(workspace.pendingEditorJump == nil)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Abgewiesene Synchronisierung beendet Datei-Aufträge und erlaubt denselben Treffer erneut", arguments: [false, true])
    @MainActor
    func cancelledFileLoadCanRetry(_ folderMatch: Bool) async throws {
        let root = testTemporaryDirectory().appendingPathComponent("visual-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("target.txt").canonicalFileURL
        try "needle".write(to: file, atomically: true, encoding: .utf8)
        let snapshot = try FileSnapshot.read(from: file).snapshot
        let (workspace, coordinator, web, window) = try await editor("Original\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("document.getElementById('fastra-visual').dispatchEvent(new Event('compositionstart'));")
        var outcomes: [FileLoadOutcome] = []
        func load() {
            if folderMatch {
                workspace.loadFolderMatchFile(atCanonicalURL: file, expectedDiskSnapshot: snapshot,
                                              jumpGeneration: workspace.beginMatchJump()) { outcomes.append($0) }
            } else {
                workspace.loadFile(atCanonicalURL: file) { outcomes.append($0) }
            }
        }
        load()
        try #require(await waitUntil { !outcomes.isEmpty })
        #expect(outcomes == [.cancelled])
        #expect(workspace.activeTab?.url == nil)
        _ = try await web.evaluateJavaScript("document.getElementById('fastra-visual').dispatchEvent(new Event('compositionend'));")
        load()
        try #require(await waitUntil { outcomes.count == 2 })
        #expect(outcomes.last?.isOpened == true)
        #expect(workspace.activeTab?.url == file)
        #expect(workspace.activeTab?.content == "needle")
        withExtendedLifetime(coordinator) {}
    }

    @Test("Weitersuchen nach Ersetzen wartet auf den verzögerten visuellen Tab")
    @MainActor
    func delayedReplaceNavigation() async throws {
        let (workspace, coordinator, web, window) = try await editor("Kein Suchwort\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let originalID = workspace.activeTabID!
        let first = EditorTab(title: "first.txt", path: "", content: "needle first")
        let second = EditorTab(title: "second.txt", path: "", content: "needle second")
        workspace.tabs.append(contentsOf: [first, second])
        workspace.scope = .open
        workspace.useRegex = false
        workspace.findPattern = "needle"
        workspace.replacePattern = "replaced"
        func refreshResults() {
            let result = OpenTabsSearch.find(tabs: workspace.tabs.map {
                OpenTabsSearch.TabInput(id: $0.id, title: $0.title, content: $0.content)
            }, options: workspace.currentSearchOptions)
            workspace.openResults = result.perTab
            workspace.openTotalMatches = result.totalMatches
            publishPreparedSearchResults(workspace)
        }
        refreshResults()
        workspace.activeMatchIndex = 0
        try #require(workspace.canReplaceActiveSearchMatch)
        workspace.performWithSynchronizedVisualMarkdown {
            workspace.replaceActiveMatch()
            workspace.selectTab(id: originalID)
        }
        #expect(workspace.tabs[1].content == "replaced first")
        refreshResults()
        _ = try await web.evaluateJavaScript("""
            const prepare=fastraVisual.prepareAction;
            fastraVisual.prepareAction=(...args)=>new Promise(resolve=>{window.releasePrepare=()=>resolve(prepare(...args));});
            void 0;
            """)
        workspace.finishPendingOpenReplaceNavigation(for: workspace.currentSearchOptions)
        #expect(try await web.evaluateJavaScript("typeof window.releasePrepare") as? String == "function")
        #expect(workspace.activeTabID == originalID)
        #expect(workspace.pendingEditorJump == nil)
        _ = try await web.evaluateJavaScript("window.releasePrepare();")
        try #require(await waitUntil { workspace.activeTabID == second.id && workspace.pendingEditorJump != nil })
        #expect(workspace.pendingEditorJump?.documentID == second.documentID)
        #expect(workspace.pendingEditorJump?.range == NSRange(location: 0, length: 6))
        #expect(workspace.activeMatchIndex == 0)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Formatieren über mehrere Absätze speichert gültige einzelne Markierungen")
    @MainActor
    func multipleParagraphs() async throws {
        let (workspace, coordinator, web, window) = try await editor("Erster Absatz\n\nZweiter Absatz\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            const root=document.getElementById('fastra-visual'),r=document.createRange();r.selectNodeContents(root);
            getSelection().removeAllRanges();getSelection().addRange(r);fastraVisual.command('highlight');
            """)
        try #require(await waitUntil { workspace.activeTab?.isDirty == true })
        let html = MarkdownRichText.htmlFragment(markdown: workspace.activeTab!.content)
        #expect(html.contains("<mark>Erster Absatz</mark>"))
        #expect(html.contains("<mark>Zweiter Absatz</mark>"))
        withExtendedLifetime(coordinator) {}
    }

    @Test("Speichern unter übernimmt noch nicht zugestellte Eingaben und sperrt die alte Dokumentbasis")
    @MainActor
    func saveAsPendingInput() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("fastra-visual-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("original.md"), targetURL = directory.appendingPathComponent("new.md")
        try "Original\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let (workspace, coordinator, web, window) = try await editor("Original\n", documentURL: sourceURL)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("document.querySelector('#fastra-visual p').textContent='Letzte Eingabe';")
        var saved: Bool?
        workspace.saveTabAs(id: workspace.activeTabID!, to: targetURL, expectedTargetState: .absent,
                            isMarkdown: true) { saved = $0 }
        try #require(await waitUntil { saved != nil })
        #expect(saved == true)
        #expect(try String(contentsOf: targetURL, encoding: .utf8).contains("Letzte Eingabe"))
        #expect(!coordinator.ready)
        let editable = try await web.evaluateJavaScript("document.getElementById('fastra-visual').contentEditable")
        #expect(editable as? String == "false")
        var reloadError: String?
        workspace.saveSafetyWarningHandler = { title, text in reloadError = title + ": " + text }
        coordinator.load(workspace.activeTab!.content, documentURL: targetURL, fontName: PreviewFonts.systemName,
                         fontSize: 14, darkMode: false, style: "new")
        coordinator.load("Neuer Stand\n", documentURL: targetURL, fontName: PreviewFonts.systemName,
                         fontSize: 14, darkMode: false, style: "newest")
        // Der zweite WebKit-Start braucht dieselbe Frist wie der erste.
        let reloaded = await waitUntil(timeout: 12) { coordinator.ready || reloadError != nil }
        try #require(reloaded && coordinator.ready,
                     "WebKit-Neuladen: \(reloadError ?? "keine Fehlermeldung"), loading=\(web.isLoading)")
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == "Neuer Stand\n")
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').contentEditable") as? String == "true")
    }

    @Test("Normaler Absatz entfernt auch verschachtelte Formatierungen")
    @MainActor
    func plainParagraph() async throws {
        let (workspace, coordinator, web, window) = try await editor("## ==**Formatiert**==\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            const n=document.querySelector('h2'),r=document.createRange();r.selectNodeContents(n);
            getSelection().removeAllRanges();getSelection().addRange(r);fastraVisual.command('plainParagraph');
            """)
        try #require(await waitUntil { workspace.activeTab?.isDirty == true })
        let html = MarkdownRichText.htmlFragment(markdown: workspace.activeTab!.content)
        #expect(!html.contains("<mark>"))
        #expect(!html.contains("<strong>"))
        #expect(!html.contains("<h2"))
        #expect(html.contains("Formatiert"))
        withExtendedLifetime(coordinator) {}
    }

    @Test("Abgebrochenes Schließen erhält Eingaben; Verwerfen und Abbau erzeugen keine Konfliktwarnung")
    @MainActor
    func discardAndDismantle() async throws {
        let (workspace, coordinator, web, window) = try await editor("Original\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        var warnings: [String] = []
        workspace.saveSafetyWarningHandler = { title, _ in warnings.append(title) }
        let id = workspace.activeTabID!
        workspace.confirmCloseHandler = { _ in .cancel }
        _ = try await web.evaluateJavaScript("document.querySelector('p').textContent='Nicht gespeichert';")
        workspace.closeTab(id: id)
        try #require(await waitUntil { workspace.activeTab?.isDirty == true })
        try #require(await waitUntil { workspace.activeTab?.id == id })
        _ = try await web.evaluateJavaScript("document.querySelector('p').textContent+=' weiter';fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content.contains("weiter") == true })
        workspace.confirmCloseHandler = { _ in .dontSave }
        workspace.closeTab(id: id)
        try #require(await waitUntil { !workspace.tabs.contains { $0.id == id } })
        MarkdownVisualWebView.dismantleNSView(web, coordinator: coordinator)
        // Eine folgende JS-Antwort gibt auch dem alten Abbau-Callback Zeit.
        _ = try await web.evaluateJavaScript("document.querySelector('p')?.textContent")
        #expect(warnings.isEmpty)
        #expect(!coordinator.ready)
        #expect(workspace.visualMarkdownEditor == nil)
    }

    @Test("Echte gleichzeitige Dokumentänderung bleibt vor dem Schließen geschützt")
    @MainActor
    func sourceConflictStillWarns() async throws {
        let (workspace, coordinator, web, window) = try await editor("Original\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        var warnings = 0
        workspace.saveSafetyWarningHandler = { _, _ in warnings += 1 }
        _ = try await web.evaluateJavaScript("document.querySelector('p').textContent='Sichtbare Eingabe';")
        workspace.tabs[0].content = "Andere Änderung\n"
        var result: Bool?
        coordinator.synchronize { result = $0 }
        try #require(await waitUntil { result != nil })
        #expect(result == false)
        #expect(warnings == 1)
        #expect(workspace.tabs[0].content == "Andere Änderung\n")
    }

    @Test("Tab fügt sichtbare Einrückung ein und überlebt Undo, Speichern und erneutes Öffnen", arguments: ["Text\n", ""])
    @MainActor
    func tabInParagraph(_ original: String) async throws {
        let (workspace, coordinator, web, window) = try await editor(original)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            const p=document.querySelector('p'),r=document.createRange();r.selectNodeContents(p);r.collapse(true);
            getSelection().removeAllRanges();getSelection().addRange(r);
            p.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));
            """)
        try #require(await waitUntil { workspace.activeTab?.isDirty == true })
        let source = try #require(workspace.activeTab?.content)
        let expected = "\u{00a0}\u{00a0}\u{00a0}\u{00a0}" + original.trimmingCharacters(in: .newlines)
        #expect(MarkdownRichText.htmlFragment(markdown: source).contains(expected))
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == original })
        _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
        coordinator.load(source, documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "reload")
        try #require(await waitUntil { coordinator.ready })
        #expect(try await web.evaluateJavaScript("document.querySelector('p').textContent") as? String == expected)
    }

    @Test("Tab und Umschalt-Tab verschachteln echte Listen mit rückgängig machbaren Schritten", arguments: ["- Eins\n- Zwei\n- Drei\n", "1. Eins\n2. Zwei\n3. Drei\n", "- [ ] Eins\n- [x] Zwei\n- [ ] Drei\n"])
    @MainActor
    func nestedLists(_ source: String) async throws {
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            const item=document.querySelectorAll('li')[1],r=document.createRange();r.selectNodeContents(item);r.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(r);
            item.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));
            """)
        try #require(await waitUntil { workspace.activeTab?.isDirty == true })
        let nested = try #require(workspace.activeTab?.content)
        let html = MarkdownRichText.htmlFragment(markdown: nested)
        #expect(html.components(separatedBy: "<ul").count + html.components(separatedBy: "<ol").count == 4, Comment(rawValue: nested + html))
        #expect(html.components(separatedBy: "<li").count == 4)
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        let undone = await waitUntil { workspace.activeTab?.content == source }
        if !undone {
            let dom = try await web.evaluateJavaScript("document.getElementById('fastra-visual').innerHTML")
            Issue.record(Comment(rawValue: "Undo: " + workspace.activeTab!.content + String(describing: dom)))
        }
        try #require(undone)
        _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == nested })
        _ = try await web.evaluateJavaScript("""
            {const item=Array.from(document.querySelectorAll('li')).find(n=>n.textContent.trim()==='Zwei'),r=document.createRange();r.selectNodeContents(item);r.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(r);}
            document.getElementById('fastra-visual').dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',shiftKey:true,bubbles:true,cancelable:true}));
            """)
        try #require(await waitUntil { workspace.activeTab?.content != nested })
        let flat = MarkdownRichText.htmlFragment(markdown: workspace.activeTab!.content)
        #expect(flat.components(separatedBy: "<ul").count + flat.components(separatedBy: "<ol").count == 3)
        if source.contains("[x]") { #expect(workspace.activeTab?.content.contains("[x]") == true) }
        withExtendedLifetime(coordinator) {}
    }

    @Test("Protokolllisten behalten einzelne Gleichheitszeichen beim Kopieren und Bearbeiten")
    @MainActor
    func protocolEqualsStayLiteral() async throws {
        let source = "- Weitere Funktionen =\n    - Kopierte Feldinhalte = OK\n    - Export als CSV =\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.stopLoading(); web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            {const root=document.getElementById('fastra-visual'),r=document.createRange();r.selectNodeContents(root);
            getSelection().removeAllRanges();getSelection().addRange(r);root.dispatchEvent(new Event('copy',{bubbles:true,cancelable:true}));}
            """)
        try #require(await waitUntil { coordinator.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType) != nil })
        let data = try #require(coordinator.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType))
        let package = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        let copied = try #require(package["markdown"])
        #expect(!copied.contains(#"\="#), Comment(rawValue: copied))
        #expect(copied.contains("Funktionen ="))
        #expect(copied.contains("Feldinhalte = OK"))
        _ = try await web.evaluateJavaScript("""
            {const item=document.querySelectorAll('li')[2],r=document.createRange();r.selectNodeContents(item);r.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(r);document.execCommand('insertText',false,' OK');fastraVisual.flush();}
            """)
        try #require(await waitUntil { workspace.activeTab?.content.contains("CSV = OK") == true })
        #expect(workspace.activeTab?.content.contains(#"\="#) == false)
        #expect(MarkdownRichText.htmlFragment(markdown: workspace.activeTab!.content).components(separatedBy: "<li").count == 4)
    }

    @Test("Wörtliche Textmarker-Kürzel bleiben beim Bearbeiten geschützt", arguments: ["==wörtlich==", "===wörtlich==="])
    @MainActor
    func literalHighlightDelimitersStayProtected(_ text: String) async throws {
        let (workspace, coordinator, web, window) = try await editor("Anfang\n")
        defer { web.stopLoading(); web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        _ = try await web.callAsyncJavaScript("""
            const p=document.querySelector('#fastra-visual p'),r=document.createRange();r.selectNodeContents(p);
            getSelection().removeAllRanges();getSelection().addRange(r);
            document.execCommand('insertText',false,text);fastraVisual.flush();
            """, arguments: ["text": text], in: nil, contentWorld: .page)
        try #require(await waitUntil { workspace.activeTab?.content != "Anfang\n" })
        let rendered = MarkdownRichText.htmlFragment(markdown: workspace.activeTab!.content)
        #expect(rendered.contains(text), Comment(rawValue: rendered))
        #expect(!rendered.contains("<mark>"))
    }

    @Test("Leere Listenpunkte bleiben beim Kopieren und Einfügen im selben Dokument erhalten")
    @MainActor
    func copyEmptyLists() async throws {
        let source = "# A\n\n- \n\n# B\n\n1. \n\n# C\n\n- [ ] \n\nEinfügepunkt\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            const root=document.getElementById('fastra-visual'),r=document.createRange();r.selectNodeContents(root);
            getSelection().removeAllRanges();getSelection().addRange(r);root.dispatchEvent(new Event('copy',{bubbles:true,cancelable:true}));
            """)
        try #require(await waitUntil { coordinator.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType) != nil })
        let data = try #require(coordinator.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType))
        let package = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        let copied = try #require(package["markdown"])
        #expect(MarkdownRichText.htmlFragment(markdown: copied).components(separatedBy: "<li").count == 4, Comment(rawValue: copied))
        // Der Clipboard-Inhalt wird vor der WebKit-Bestätigung veröffentlicht.
        // Wie bei einer echten Eingabe erst die Kopiersperre abwarten.
        let copyCompleted = try await web.callAsyncJavaScript("""
            for(let i=0;i<200;i++) {
                if(document.getElementById('fastra-visual').isContentEditable)return true;
                await new Promise(resolve=>setTimeout(resolve,10));
            }
            return false;
            """, arguments: [:], in: nil, contentWorld: .page)
        try #require(copyCompleted as? Bool == true)
        // Ein tatsächlicher Absatz hält das Ziel außerhalb des letzten leeren
        // Listenpunkts; ein Range am Wurzelende ist keine solche Einfügestelle.
        _ = try await web.evaluateJavaScript("""
            {const root=document.getElementById('fastra-visual'),p=Array.from(root.querySelectorAll('p')).find(p=>p.textContent==='Einfügepunkt' && !p.closest('li'));
            if(!p)throw new Error('Einfügeabsatz fehlt');root.focus();
            const r=document.createRange();r.selectNodeContents(p);r.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(r);}
            """)
        #expect(coordinator.pasteImages())
        // Die erste Normalisierung kann den Quelltext bereits vor dem
        // asynchronen Paste ändern. Erst alle sechs Listenpunkte belegen ihn.
        let inserted = await waitUntil {
            guard let content = workspace.activeTab?.content else { return false }
            return MarkdownRichText.htmlFragment(markdown: content).components(separatedBy: "<li").count == 7
        }
        #expect(inserted, Comment(rawValue: workspace.activeTab?.content ?? "Kein Dokument"))
    }

    @Test("Aufgabenliste lässt sich erstellen, ankreuzen und mit Undo wiederherstellen")
    @MainActor
    func taskLists() async throws {
        let source = "Erster Schritt\n\nZweiter Schritt\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            const root=document.getElementById('fastra-visual'),r=document.createRange();r.selectNodeContents(root);
            getSelection().removeAllRanges();getSelection().addRange(r);fastraVisual.command('taskList');
            """)
        try #require(await waitUntil { workspace.activeTab?.content.contains("[ ]") == true })
        let unchecked = workspace.activeTab!.content
        #expect(unchecked.components(separatedBy: "[ ]").count == 3)
        _ = try await web.evaluateJavaScript("document.querySelector('input[type=checkbox]').click();")
        try #require(await waitUntil { workspace.activeTab?.content.contains("[x]") == true })
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == unchecked })
        _ = try await web.evaluateJavaScript("document.querySelector('input[type=checkbox]').click();")
        try #require(await waitUntil { workspace.activeTab?.content.contains("[x]") == true })
        let beforeReturn = workspace.activeTab!.content
        _ = try await web.evaluateJavaScript("""
            {const item=document.querySelectorAll('li')[1],r=document.createRange();r.selectNodeContents(item);r.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(r);document.execCommand('insertParagraph');fastraVisual.flush();}
            """)
        try #require(await waitUntil { workspace.activeTab?.content.components(separatedBy: "[ ]").count == 3 })
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('li').length") as? Int == 3)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('input[type=checkbox]').length") as? Int == 3)
        let undone = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();fastraVisual.markdown();") as? String
        // Return und Kästchen sind native Bearbeitungsschritte wie beim
        // Erstellen einer neuen Aufgabenliste; beide müssen zurückgehen.
        if undone != beforeReturn {
            _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        }
        try #require(await waitUntil { workspace.activeTab?.content == beforeReturn })
        withExtendedLifetime(coordinator) {}
    }

    @Test("Aufgabenformatierung neben einer eingerückten Liste erhält die gesamte Undo-Folge")
    @MainActor
    func taskListUndoSequence() async throws {
        let source = "# Testprotokoll\n\nErgebnis: bestanden 😀\n\n- Erster Schritt\n- Zweiter Schritt\n\n| Prüfung | Ergebnis |\n| :--- | ---: |\n| Bild und Text | bestanden |\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            {const item=document.querySelectorAll('li')[1],r=document.createRange();r.selectNodeContents(item);r.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(r);item.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));}
            """)
        try #require(await waitUntil { workspace.activeTab?.isDirty == true })
        let nested = workspace.activeTab!.content
        _ = try await web.evaluateJavaScript("""
            {const p=document.querySelector('p'),r=document.createRange();r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r);}
            """)
        coordinator.format(.taskList)
        try #require(await waitUntil { workspace.activeTab?.content.contains("[ ]") == true })
        _ = try await web.evaluateJavaScript("document.querySelector('input[type=checkbox]').click();")
        try #require(await waitUntil { workspace.activeTab?.content.contains("[x]") == true })
        var steps = [String]()
        for _ in 0..<3 {
            steps.append(try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();fastraVisual.markdown();") as? String ?? "nil")
            if steps.last == nested { break }
        }
        #expect(steps.last == nested, Comment(rawValue: steps.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")))
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
        withExtendedLifetime(coordinator) {}
    }

    @Test("Aufgabenformatierung erhält Zwischenabsätze und verändert nur ausgewählte Kindpunkte")
    @MainActor
    func taskSelectionBoundaries() async throws {
        let source = "- A\n\nZwischenabsatz\n\n- B\n    - Kind\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            {const root=document.getElementById('fastra-visual'),r=document.createRange();r.selectNodeContents(root);
            getSelection().removeAllRanges();getSelection().addRange(r);fastraVisual.command('taskList');}
            """)
        try #require(await waitUntil { workspace.activeTab?.isDirty == true })
        #expect(workspace.activeTab?.content.contains("Zwischenabsatz") == true)
        #expect(workspace.activeTab?.content.components(separatedBy: "[ ]").count == 4)
        #expect(try await web.evaluateJavaScript("document.querySelector('#fastra-visual > div > p').textContent") as? String == "Zwischenabsatz")
        let allTasks = workspace.activeTab!.content
        for cycle in 0..<3 {
            _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
            let undone = await waitUntil { workspace.activeTab?.content == source }
            if !undone {
                let dom = try await web.evaluateJavaScript("document.getElementById('fastra-visual').innerHTML")
                Issue.record(Comment(rawValue: "Undo \(cycle): " + workspace.activeTab!.content + String(describing: dom)))
            }
            try #require(undone)
            _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
            let redone = await waitUntil { workspace.activeTab?.content == allTasks }
            if !redone {
                let dom = try await web.evaluateJavaScript("document.getElementById('fastra-visual').innerHTML")
                Issue.record(Comment(rawValue: "Redo \(cycle): expected=" + allTasks + " actual=" + workspace.activeTab!.content + String(describing: dom)))
            }
            try #require(redone)
        }
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
        _ = try await web.evaluateJavaScript("""
            {const child=document.querySelector('li li'),r=document.createRange();r.selectNodeContents(child);
            getSelection().removeAllRanges();getSelection().addRange(r);fastraVisual.command('taskList');}
            """)
        try #require(await waitUntil { workspace.activeTab?.isDirty == true })
        #expect(workspace.activeTab?.content.components(separatedBy: "[ ]").count == 2)
        #expect(workspace.activeTab?.content.contains("Zwischenabsatz") == true)
        _ = try await web.evaluateJavaScript("{const root=document.getElementById('fastra-visual'),r=document.createRange();r.selectNodeContents(root);getSelection().removeAllRanges();getSelection().addRange(r);root.dispatchEvent(new Event('copy',{bubbles:true,cancelable:true}));}")
        try #require(await waitUntil { coordinator.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType) != nil })
        let copied = try #require(coordinator.pasteboard.string(forType: .html))
        #expect(!copied.contains("md-edit-boundary") && !copied.contains("\u{200b}"))
        let dom = try await web.evaluateJavaScript("document.getElementById('fastra-visual').innerHTML")
        #expect(MarkdownRichText.htmlFragment(markdown: workspace.activeTab!.content).components(separatedBy: "<li").count == 4, Comment(rawValue: workspace.activeTab!.content + String(describing: dom)))
        withExtendedLifetime(coordinator) {}
    }


    @Test("Mehrfaches Tab erhält mehrere Ebenen, Unterpunkte und mehrstellige Nummern")
    @MainActor
    func multipleListLevels() async throws {
        let source = "9. A\n10. B\n    - Kind B\n11. C\n12. D\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            {const item=Array.from(document.querySelectorAll('li')).find(n=>n.textContent.trim()==='C'),r=document.createRange();r.selectNodeContents(item);r.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(r);item.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));}
            """)
        try #require(await waitUntil { workspace.activeTab?.isDirty == true })
        let first = workspace.activeTab!.content
        let firstHTML = MarkdownRichText.htmlFragment(markdown: first)
        #expect(firstHTML.components(separatedBy: "<li").count == 6)
        #expect(firstHTML.contains("start=\"9\""))
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('li li').length") as? Int == 2)
        _ = try await web.evaluateJavaScript("document.getElementById('fastra-visual').dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));")
        // C ist der erste Punkt seiner neuen geordneten Unterliste und hat
        // dort keinen Vorgänger: ein weiterer Tab darf nichts beschädigen.
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == first)
        _ = try await web.evaluateJavaScript("document.getElementById('fastra-visual').dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',shiftKey:true,bubbles:true,cancelable:true}));")
        try #require(await waitUntil { workspace.activeTab?.content != first })
        #expect(MarkdownRichText.htmlFragment(markdown: workspace.activeTab!.content).components(separatedBy: "<li").count == 6)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Tab im Codeblock bleibt ein wörtlicher Tabulator")
    @MainActor
    func tabInCode() async throws {
        let (workspace, coordinator, web, window) = try await editor("```text\nCode\n```\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            {const code=document.querySelector('pre code'),r=document.createRange();r.selectNodeContents(code);r.collapse(true);
            getSelection().removeAllRanges();getSelection().addRange(r);code.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));}
            """)
        try #require(await waitUntil { workspace.activeTab?.isDirty == true })
        #expect(workspace.activeTab?.content.contains("\tCode") == true)
        withExtendedLifetime(coordinator) {}
    }


    @Test("Bild am Anfang eines Listenpunkts bleibt vor dessen Text", arguments: ["li", "ul", "[data-md-block]", "pasteEvent"])
    @MainActor
    func regressionImageAtListStart(_ selector: String) async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("visual-image-start-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("source.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: image)
        let source = "- Erster Punkt\n- Zweiter Punkt\n"
        let (workspace, coordinator, web, window) = try await editor(source, documentURL: directory.appendingPathComponent("test.md"))
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let domSelector = selector == "pasteEvent" ? "li" : selector
        _ = try await web.evaluateJavaScript("""
            const item=document.querySelector('#fastra-visual \(domSelector)'),r=document.createRange();
            r.selectNodeContents(item);r.collapse(true);
            getSelection().removeAllRanges();getSelection().addRange(r);
            """)
        if selector == "pasteEvent" {
            coordinator.pasteboard.setData(try Data(contentsOf: image), forType: .png)
            _ = try await web.evaluateJavaScript("""
                const event=new Event('paste',{bubbles:true,cancelable:true});
                Object.defineProperty(event,'clipboardData',{value:{files:[{}],getData:()=>''}});
                document.getElementById('fastra-visual').dispatchEvent(event);
                const end=document.createRange();end.selectNodeContents(document.querySelector('li'));end.collapse(false);
                getSelection().removeAllRanges();getSelection().addRange(end);
                """)
        } else { coordinator.insertImages([image]) }
        try #require(await waitUntil { workspace.activeTab?.content.contains("images/1.png") == true })
        let result = try await web.evaluateJavaScript("""
            const root=document.getElementById('fastra-visual'),img=root.querySelector('img');
            const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);let text;
            while(walker.nextNode())if(walker.currentNode.textContent.includes('Erster Punkt')){text=walker.currentNode;break;}
            JSON.stringify({before:!!(img.compareDocumentPosition(text)&Node.DOCUMENT_POSITION_FOLLOWING),html:root.innerHTML});
            """) as? String
        let data = try #require(result?.data(using: .utf8))
        let state = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(state["before"] as? Bool == true, Comment(rawValue: result ?? "DOM fehlt"))
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("images/1.png").path))
        _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content.contains("images/1.png") == true })
        #expect(try Data(contentsOf: directory.appendingPathComponent("images/1.png")) == Data(contentsOf: image))
    }

    @Test("Clipboard-Liste in sichtbarer Leerzeile überlappt den Folgeabsatz nicht")
    @MainActor
    func regressionPasteIntoBlankLine() async throws {
        let (workspace, coordinator, web, window) = try await editor("# Kopf\n\n  \n\nNachher\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let state = try await web.evaluateJavaScript("""
            const blank=document.querySelector('.fastra-visible-blank-line'),r=document.createRange();
            r.selectNodeContents(blank);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);
            const event=new Event('paste',{bubbles:true,cancelable:true});
            Object.defineProperty(event,'clipboardData',{value:{files:[],getData:type=>type==='text/html'?'<ul><li>Neu A<ul><li>Neu B</li><li>Neu C</li></ul></li><li>Neu D</li></ul>':''}});
            document.getElementById('fastra-visual').dispatchEvent(event);
            const root=document.getElementById('fastra-visual'),nodes=Array.from(root.querySelectorAll('li'));
            const next=Array.from(root.querySelectorAll('p')).find(p=>p.textContent==='Nachher');
            JSON.stringify({clear:next.getBoundingClientRect().top>=Math.max(...nodes.map(n=>n.getBoundingClientRect().bottom)),html:root.innerHTML});
            """) as? String
        let data = try #require(state?.data(using: .utf8))
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(result["clear"] as? Bool == true, Comment(rawValue: state ?? "DOM fehlt"))
        try #require(await waitUntil { workspace.activeTab?.content.contains("Neu D") == true })
        withExtendedLifetime(coordinator) {}
    }

    @Test("Neue leere Absätze bleiben nach Speichern und Neuaufbau sichtbar")
    @MainActor
    func regressionNewBlankParagraph() async throws {
        let (workspace, coordinator, web, window) = try await editor("# Kopf\n\n- Punkt\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            const h=document.querySelector('#fastra-visual h1'),r=document.createRange();r.selectNodeContents(h);r.collapse(false);
            getSelection().removeAllRanges();getSelection().addRange(r);
            document.execCommand('insertParagraph');document.execCommand('insertParagraph');fastraVisual.flush();
            """)
        try #require(await waitUntil { workspace.activeTab?.isDirty == true })
        let saved = try #require(workspace.activeTab?.content)
        #expect(saved.contains("  \n"), Comment(rawValue: saved))
        coordinator.load(saved, documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "reload")
        try #require(await waitUntil { coordinator.ready })
        #expect((try await web.evaluateJavaScript("document.querySelectorAll('.fastra-visible-blank-line').length") as? Int ?? 0) >= 1)
    }

    @Test("Mehrere harte Umbrüche im leeren Absatz behalten Höhe und Blockstruktur", arguments: [false, true], ["plain", "quote", "list"])
    @MainActor
    func emptyParagraphBreaks(_ paste: Bool, _ context: String) async throws {
        let middle = context == "quote" ? "> A\n>   \n> B" : context == "list" ? "- A\n  \n- B" : "  "
        let (workspace, coordinator, web, window) = try await editor("# Kopf\n\n\(middle)\n\nDanach\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let before = try await web.evaluateJavaScript("""
            const blank=document.querySelector('.fastra-visible-blank-line'),r=document.createRange();
            r.selectNodeContents(blank);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);
            if(\(paste ? "true" : "false")){
              const event=new Event('paste',{bubbles:true,cancelable:true});
              Object.defineProperty(event,'clipboardData',{value:{files:[],getData:type=>type==='text/html'?'<p><br><br><br></p>':''}});
              document.getElementById('fastra-visual').dispatchEvent(event);
            }else{fastraVisual.command('hardBreak');fastraVisual.command('hardBreak');}
            const next=Array.from(document.querySelectorAll('p')).find(p=>p.textContent==='Danach');
            JSON.stringify({gap:next.getBoundingClientRect().top-document.querySelector('h1').getBoundingClientRect().bottom,markdown:fastraVisual.markdown(),html:document.getElementById('fastra-visual').innerHTML});
            """) as? String
        let data = try #require(before?.data(using: .utf8))
        let state = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let source = try #require(state["markdown"] as? String)
        let height = try #require(state["gap"] as? Double)
        coordinator.load(source, documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "reload")
        try #require(await waitUntil { coordinator.ready })
        let after = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('p')).find(p=>p.textContent==='Danach').getBoundingClientRect().top-document.querySelector('h1').getBoundingClientRect().bottom") as? Double
        #expect((after ?? 0) >= height - 0.5, Comment(rawValue: String(describing: state)))
        if context == "quote" {
            #expect(try await web.evaluateJavaScript("document.querySelectorAll('blockquote').length") as? Int == 1)
        } else if context == "list" {
            #expect(try await web.evaluateJavaScript("document.querySelectorAll('li').length") as? Int == 2)
        }
        withExtendedLifetime(workspace) {}
    }

    @Test("Visuelle Listen bewahren sichtbare Leerzeilen innerhalb des cmark-Blocks")
    func regressionVisibleListGaps() {
        let document = MarkdownVisualDocument.render("- A\n  \n- B\n", documentURL: nil)
        #expect(document.fragment.html.contains("fastra-visible-blank-line"))
    }

    @Test("Geladenes Bild per Klick löschen, speichern und Undo stellt die Datei wieder her")
    @MainActor
    func loadedImageClickDeleteSaveUndo() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("visual-loaded-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let doc = directory.appendingPathComponent("test.md")
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII=")!
        let image = try MarkdownImageStore.storePastedData(.init(data: bytes, fileExtension: "png"), documentURL: doc)
        let source = "![Bild](images/1.png)\n"
        try source.write(to: doc, atomically: true, encoding: .utf8)
        let (workspace, coordinator, web, window) = try await editor(source, documentURL: doc)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        workspace.tabs[0].diskSnapshot = try FileSnapshot.readSnapshotOnly(from: doc)
        _ = try await web.evaluateJavaScript("document.querySelector('img').click();fastraVisual.command('deleteImage');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content.contains("images/1.png") == false })
        #expect(FileManager.default.fileExists(atPath: image.fileURL.path))
        workspace.saveActiveTab()
        try #require(await waitUntil { !FileManager.default.fileExists(atPath: image.fileURL.path) })
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content.contains("images/1.png") == true })
        #expect(try Data(contentsOf: image.fileURL) == bytes)
    }

    @Test("Bild löschen, weiterarbeiten und Undo stellt die Bilddatei wieder her")
    @MainActor
    func deletedImageSurvivesFurtherEdits() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("visual-image-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII=")!
        let image = directory.appendingPathComponent("source.png")
        try bytes.write(to: image)
        let (workspace, coordinator, web, window) = try await editor("Text\n", documentURL: directory.appendingPathComponent("test.md"))
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);")
        coordinator.insertImages([image])
        try #require(await waitUntil { workspace.activeTab?.content.contains("images/1.png") == true })
        _ = try await web.evaluateJavaScript("{const r=document.createRange();r.selectNode(document.querySelector('img'));getSelection().removeAllRanges();getSelection().addRange(r);document.execCommand('delete');fastraVisual.flush();}")
        try #require(await waitUntil { workspace.activeTab?.content.contains("images/1.png") == false })
        _ = try await web.evaluateJavaScript("document.execCommand('insertText',false,'weiter');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content.contains("weiter") == true })
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content.contains("weiter") == false })
        // WebKit darf Delete und anschließendes Tippen zu einem Undo bündeln.
        if workspace.activeTab?.content.contains("images/1.png") == false {
            _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        }
        try #require(await waitUntil { workspace.activeTab?.content.contains("images/1.png") == true })
        #expect(try Data(contentsOf: directory.appendingPathComponent("images/1.png")) == bytes)
    }

    @Test("Zwei Dokumente im selben Ordner besitzen unabhängige Bildkopien und Undo-Schritte")
    @MainActor
    func copyBetweenDocumentsOwnsFile() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("visual-shared-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII=")!
        let image = directory.appendingPathComponent("source.png")
        try bytes.write(to: image)
        let (firstWorkspace, first, firstWeb, firstWindow) = try await editor("Quelle\n", documentURL: directory.appendingPathComponent("first.md"))
        defer { firstWeb.configuration.userContentController.removeAllScriptMessageHandlers(); firstWindow.close() }
        _ = try await firstWeb.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);")
        first.insertImages([image])
        try #require(await waitUntil { firstWorkspace.activeTab?.content.contains("images/1.png") == true })
        _ = try await firstWeb.evaluateJavaScript("{const root=document.getElementById('fastra-visual'),r=document.createRange();r.selectNodeContents(root);getSelection().removeAllRanges();getSelection().addRange(r);root.dispatchEvent(new Event('copy',{bubbles:true,cancelable:true}));}")
        try #require(await waitUntil { first.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType) != nil })
        let (secondWorkspace, second, secondWeb, secondWindow) = try await editor("Ziel\n", documentURL: directory.appendingPathComponent("second.md"))
        defer { secondWeb.configuration.userContentController.removeAllScriptMessageHandlers(); secondWindow.close() }
        second.pasteboard = first.pasteboard
        _ = try await secondWeb.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);")
        #expect(second.pasteImages())
        try #require(await waitUntil { secondWorkspace.activeTab?.content.contains("images/2.png") == true })
        _ = try await firstWeb.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { firstWorkspace.activeTab?.content == "Quelle\n" })
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("images/1.png").path))
        #expect(try Data(contentsOf: directory.appendingPathComponent("images/2.png")) == bytes)
        _ = try await secondWeb.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { secondWorkspace.activeTab?.content == "Ziel\n" })
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("images/2.png").path))
    }

    @Test("Ausschneiden sichert Bildbytes vor Undo und über das Schließen der Quelle hinaus", arguments: [false, true])
    @MainActor
    func cutImageOwnsBytes(_ closeSource: Bool) async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("visual-cut-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII=")!
        let image = directory.appendingPathComponent("source.png")
        try bytes.write(to: image)
        let (firstWorkspace, first, firstWeb, firstWindow) = try await editor("Quelle\n", documentURL: directory.appendingPathComponent("first.md"))
        defer { firstWeb.configuration.userContentController.removeAllScriptMessageHandlers(); firstWindow.close() }
        _ = try await firstWeb.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);")
        first.insertImages([image])
        try #require(await waitUntil { firstWorkspace.activeTab?.content.contains("images/1.png") == true })
        _ = try await firstWeb.evaluateJavaScript("{const r=document.createRange();r.selectNode(document.querySelector('img'));getSelection().removeAllRanges();getSelection().addRange(r);document.getElementById('fastra-visual').dispatchEvent(new Event('cut',{bubbles:true,cancelable:true}));}")
        try #require(await waitUntil { firstWorkspace.activeTab?.content.contains("images/1.png") == false })
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("images/1.png").path))
        if closeSource {
            // Ein Neuladen verwirft dieselben Undo-Dateien wie das Schließen.
            first.load("", documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "closed")
            firstWeb.stopLoading(); firstWindow.close()
            let (workspace, coordinator, web, window) = try await editor("Ziel\n", documentURL: directory.appendingPathComponent("second.md"))
            defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
            coordinator.pasteboard = first.pasteboard
            #expect(coordinator.pasteImages())
            try #require(await waitUntil { workspace.activeTab?.content.contains("images/1.png") == true })
            #expect(try Data(contentsOf: directory.appendingPathComponent("images/1.png")) == bytes)
        } else {
            #expect(first.pasteImages())
            try #require(await waitUntil { firstWorkspace.activeTab?.content.contains("images/2.png") == true })
            #expect(try Data(contentsOf: directory.appendingPathComponent("images/2.png")) == bytes)
        }
    }

    @Test("Bearbeiteter Text erhält wörtliche Entities und HTML", arguments: ["Wörtlich &amp;copy; und &lt;b&gt;Text&lt;/b&gt;\n", "1\\) Text\n"])
    @MainActor
    func literalTextAfterEdit(_ source: String) async throws {
        let (_, coordinator, web, window) = try await editor(source)
        defer { web.stopLoading(); web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let original = try await web.evaluateJavaScript("document.querySelector('#fastra-visual').textContent") as? String
        _ = try await web.evaluateJavaScript("{const p=document.querySelector('#fastra-visual p'),r=document.createRange();r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);document.execCommand('insertText',false,'!');fastraVisual.flush();}")
        let markdown = try #require(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String)
        let html = MarkdownRichText.htmlFragment(markdown: markdown)
        #expect(!html.contains("<b>") && !html.contains("<ol"))
        #expect(html.contains(source.hasPrefix("1") ? "1) Text!" : "&amp;copy; und &lt;b&gt;Text&lt;/b&gt;!"), Comment(rawValue: markdown + html))
        #expect(original != nil)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Ausschneiden transportiert Formeln und Undo stellt Original wieder her")
    @MainActor
    func cutFormula() async throws {
        let source = "Text $x+1$ danach\n\n```mermaid\ngraph TD; A-->B\n```\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.stopLoading(); web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("{const root=document.getElementById('fastra-visual'),r=document.createRange();r.selectNodeContents(root);getSelection().removeAllRanges();getSelection().addRange(r);root.dispatchEvent(new Event('cut',{bubbles:true,cancelable:true}));fastraVisual.flush();}")
        try #require(await waitUntil { coordinator.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType) != nil })
        let payload = try #require(coordinator.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType))
        let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: String])
        #expect(object["markdown"]?.contains("$x+1$") == true)
        #expect(object["markdown"]?.contains("graph TD; A-->B") == true)
        #expect(await waitUntil { workspace.activeTab?.content.contains("x+1") == false })
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        let restored = await waitUntil { workspace.activeTab?.content == source }
        if !restored {
            let dom = try await web.evaluateJavaScript("document.getElementById('fastra-visual').innerHTML")
            Issue.record(Comment(rawValue: "Cut Undo: " + (workspace.activeTab?.content ?? "nil") + " DOM=" + String(describing: dom)))
        }
        #expect(restored)
    }

    @Test("Verbundene Tabellenzellen behalten Zeilen- und Spaltenzuordnung")
    @MainActor
    func spanningTable() async throws {
        let (_, coordinator, web, window) = try await editor("Start\n")
        defer { web.stopLoading(); web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("{const p=document.querySelector('#fastra-visual p'),r=document.createRange();r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r);const e=new Event('paste',{bubbles:true,cancelable:true});Object.defineProperty(e,'clipboardData',{value:{files:[],getData:t=>t==='text/html'?'<table><tr><td rowspan=\"2\">A</td><td>B</td></tr><tr><td>C</td></tr></table>':''}});p.dispatchEvent(e);fastraVisual.flush();}")
        let markdown = try #require(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String)
        #expect(markdown.contains("rowspan=\"2\""), Comment(rawValue: markdown))
        #expect(MarkdownRichText.htmlFragment(markdown: markdown).contains("rowspan=\"2\""))
        withExtendedLifetime(coordinator) {}
    }

    @Test("Spanntabelle erhält beim Kopieren Inline-Kommentar und Formelquelle")
    @MainActor
    func spanningTableAtoms() async throws {
        let source = "Vorher <table><tr><td colspan=\"2\">A <!-- merken --> $x<y$ B</td></tr></table>\n"
        let (_, coordinator, web, window) = try await editor(source)
        defer { web.stopLoading(); web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("{const root=document.getElementById('fastra-visual'),r=document.createRange();r.selectNodeContents(root);getSelection().removeAllRanges();getSelection().addRange(r);root.dispatchEvent(new Event('copy',{bubbles:true,cancelable:true}));}")
        try #require(await waitUntil { coordinator.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType) != nil })
        let data = try #require(coordinator.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        let copied = try #require(object["markdown"])
        #expect(copied.contains("<!-- merken -->"), Comment(rawValue: copied))
        #expect(copied.contains("$x<y$"), Comment(rawValue: copied))
        #expect(copied.contains("colspan=\"2\""))
        #expect(!copied.contains("⋯"))
    }

    @Test("Textbaustein ersetzt ein visuelles Bookmark sicher und erhält fremde Blöcke sowie Undo")
    @MainActor func snippetBookmarkInsertion() async throws {
        let source = "# Kopf\n\nOLD\n\nUnberührt  _Original_ 😀\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer { WorkspaceWindowRegistry.unregister(window); web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        _ = try await web.evaluateJavaScript("""
            const p=Array.from(document.querySelectorAll('p')).find(p=>p.textContent==='OLD'),r=document.createRange();
            r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r);
            document.dispatchEvent(new Event('selectionchange'));void 0;
            """)
        let target: TextSnippetInsertionTarget = try await withCheckedThrowingContinuation { done in
            TextSnippetInsertionTarget.capture(in: workspace) { done.resume(with: $0) }
        }
        defer { target.release() }
        let replacement = try TextSnippetTemplate("{{Name}}\n\n{{Name}}").render(values: ["Name": "Hallo 😀\nzweite Zeile"])
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in target.insert(replacement) { done.resume(with: $0) } }
        let changed = try #require(workspace.activeTab?.content)
        #expect(!changed.contains("OLD"))
        #expect(changed.components(separatedBy: "Hallo 😀").count == 3)
        #expect(changed.hasPrefix("# Kopf\n\n"))
        #expect(changed.hasSuffix("Unberührt  _Original_ 😀\n"), Comment(rawValue: changed))
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        #expect(await waitUntil { workspace.activeTab?.content.utf8.elementsEqual(source.utf8) == true })
    }

    @Test("Textbausteine führen HTML nicht aus und können nach Freigabe des Bookmarks nicht schreiben")
    @MainActor func snippetSafeHTMLAndCancellation() async throws {
        let source = "# Kopf\n\nOLD\n\nUnverändert\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer { WorkspaceWindowRegistry.unregister(window); web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        _ = try await web.evaluateJavaScript("const p=Array.from(document.querySelectorAll('p')).find(p=>p.textContent==='OLD'),r=document.createRange();r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r);document.dispatchEvent(new Event('selectionchange'));void 0;")
        let target: TextSnippetInsertionTarget = try await withCheckedThrowingContinuation { done in TextSnippetInsertionTarget.capture(in: workspace) { done.resume(with: $0) } }
        defer { target.release() }
        let value = "<script>window.snippetAttack=1</script>\n\n<img src=\"bad\" onerror=\"window.snippetAttack=2\">\n\n[link](javascript:window.snippetAttack=3)"
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in target.insert(value) { done.resume(with: $0) } }
        #expect(try await web.evaluateJavaScript("window.snippetAttack===undefined") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#fastra-visual script,#fastra-visual [onerror],#fastra-visual a[href^=\\\"javascript:\\\"]').length") as? Int == 0)
        #expect(workspace.activeTab?.content.hasPrefix("# Kopf\n\n") == true)
        #expect(workspace.activeTab?.content.hasSuffix("Unverändert\n") == true)
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        let restored = await waitUntil { workspace.activeTab?.content == source }
        if !restored {
            let dom = try await web.evaluateJavaScript("document.getElementById('fastra-visual').innerHTML")
            Issue.record(Comment(rawValue: "Textbaustein-Undo: " + (workspace.activeTab?.content ?? "nil") + "\nDOM=" + String(describing: dom)))
        }
        try #require(restored)
        _ = try await web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content.contains("window.snippetAttack=1") == true })
        #expect(try await web.evaluateJavaScript("window.snippetAttack===undefined") as? Bool == true)
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == source })
        let cancelled: TextSnippetInsertionTarget = try await withCheckedThrowingContinuation { done in TextSnippetInsertionTarget.capture(in: workspace) { done.resume(with: $0) } }
        cancelled.release()
        let result: Result<Void, Error> = await withCheckedContinuation { done in cancelled.insert("FALSCH") { done.resume(returning: $0) } }
        if case .success = result { Issue.record("Freigegebenes Bookmark wurde beschrieben") }
        #expect(workspace.activeTab?.content == source)
    }

    @Test("Visuelles Textbausteinziel verwirft Dokumentwechsel und gibt abgebrochene Bookmarks frei")
    @MainActor func snippetBookmarkStaleDocument() async throws {
        let source = "Unverändert\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer { WorkspaceWindowRegistry.unregister(window); web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        let target: TextSnippetInsertionTarget = try await withCheckedThrowingContinuation { done in
            TextSnippetInsertionTarget.capture(in: workspace) { done.resume(with: $0) }
        }
        workspace.tabs = [EditorTab(title: "Anderes.txt", path: "", content: "Fremd")]
        workspace.activeTabID = workspace.tabs[0].id
        #expect(!target.isCurrent)
        let result: Result<Void, Error> = await withCheckedContinuation { done in target.insert("FALSCH") { done.resume(returning: $0) } }
        if case .success = result { Issue.record("Fremdes Dokument wurde getroffen") }
        target.release()
        #expect(workspace.activeTab?.content == "Fremd")
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
    }

    @Test("Ein bereits gestarteter visueller Baustein darf keinen wiederverwendeten Dokumentplatz beschreiben")
    @MainActor func snippetInFlightReusedDocument() async throws {
        let source = "Unverändert\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer { WorkspaceWindowRegistry.unregister(window); web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        let target: TextSnippetInsertionTarget = try await withCheckedThrowingContinuation { done in
            TextSnippetInsertionTarget.capture(in: workspace) { done.resume(with: $0) }
        }
        defer { target.release() }
        var result: Result<Void, Error>?
        target.insert("FALSCH") { result = $0 }
        let old = try #require(workspace.activeTab)
        var replacement = EditorTab(id: old.id, title: old.title, path: old.path, content: source)
        replacement.markdownVisualOverride = true
        workspace.tabs = [replacement]
        try #require(await waitUntil { result != nil })
        if case .success = result { Issue.record("Laufende visuelle Einfügung traf ein anderes Dokument im selben Tabplatz") }
        #expect(workspace.activeTab?.documentID == replacement.documentID)
        #expect(workspace.activeTab?.content.utf8.elementsEqual(source.utf8) == true)
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
    }


    @Test("Diagnose: bestehender Disk-Batchhalter überlebt globale Modusaktion", arguments: [false, true])
    @MainActor
    func batchHoldSurvivesModeChangeDiagnostic(_ claimed: Bool) async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("batch-hold-diagnostic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = directory.appendingPathComponent("note.md")
        try "Text\n".write(to: document, atomically: true, encoding: .utf8)
        let (workspace, coordinator, web, window) = try await editor("Text\n", documentURL: document)
        var heldEditors: [MarkdownVisualCoordinator.ActionHold] = []
        var mutation: Workspace.TextWorkflowDiskMutation?
        defer {
            if let mutation { workspace.finishTextWorkflowDiskMutation(mutation, changedURLs: [], session: nil) }
            heldEditors.forEach { $0.finish() }
            web.configuration.userContentController.removeAllScriptMessageHandlers()
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
        workspace.tabs[0].diskSnapshot = try FileSnapshot.readSnapshotOnly(from: document)
        workspace.tabs[0].isDirty = false
        var warnings = 0
        workspace.saveSafetyWarningHandler = { _, _ in warnings += 1 }
        AppDefaults.store.set(true, forKey: MarkdownEditingMode.defaultsKey)
        let prepared = await workspace.synchronizeTextWorkflowDiskDocuments()
        heldEditors = prepared.1
        try #require(prepared.0 && heldEditors.count == 1 && heldEditors.first?.isCurrent(for: coordinator) == true)
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        if claimed {
            let claim = try workspace.beginTextWorkflowDiskMutation(urls: [document])
            mutation = claim
            let preflight = await Task.detached { Result { try claim.preflight(in: workspace) } }.value
            try preflight.get()
            #expect(!workspace.textEditingIsAllowed(for: workspace.tabs[0]))
        }
        _ = try await web.evaluateJavaScript("window.__batchActionEnds=0;window.__originalBatchActionEnd=fastraVisual.completeAction;fastraVisual.completeAction=function(...args){const result=window.__originalBatchActionEnd.apply(this,args);window.__batchActionEnds+=1;return result;};true;")
        MarkdownEditingMode.setDefault(false)
        let expectedEnds = 1
        var ends = 0, reading = false
        let completed = await waitUntil {
            if ends >= expectedEnds { return true }
            if !reading {
                reading = true
                web.evaluateJavaScript("window.__batchActionEnds") { value, _ in ends = value as? Int ?? 0; reading = false }
            }
            return false
        }
        try #require(completed)
        let held = workspace.textWorkflowDiskEditorsAreHeld(heldEditors)
        let editable = try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool
        #expect(held)
        #expect(warnings == (claimed ? 1 : 0))
        #expect(AppDefaults.store.bool(forKey: MarkdownEditingMode.defaultsKey) == claimed)
        #expect(workspace.activeTab?.content == "Text\n" && !workspace.tabs[0].hasUnsavedChanges)
        #expect(try Data(contentsOf: document) == Data("Text\n".utf8))
        if claimed { #expect(!workspace.textEditingIsAllowed(for: workspace.tabs[0])) }
        print("BATCH_HOLD_DIAGNOSTIC claimed=\(claimed) nativeHeld=\(held) editable=\(String(describing: editable)) observedEnds=\(ends) warnings=\(warnings) fileUnchanged=true")
        #expect(editable == false)
        if let activeMutation = mutation {
            workspace.finishTextWorkflowDiskMutation(activeMutation, changedURLs: [], session: nil)
            mutation = nil
        }
        heldEditors.forEach { $0.finish() }
        #expect(heldEditors.allSatisfy { !$0.isActive && !$0.isCurrent(for: coordinator) })
        #expect(!workspace.textWorkflowDiskEditorsAreHeld(heldEditors))
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
    }


    @MainActor
    private func actionHold(_ coordinator: MarkdownVisualCoordinator) async throws -> MarkdownVisualCoordinator.ActionHold {
        var response: (Bool, MarkdownVisualCoordinator.ActionHold?)?
        coordinator.synchronize(holdingInput: true) { response = ($0, $1) }
        try #require(await waitUntil { response != nil })
        try #require(response?.0 == true)
        return try #require(response?.1)
    }

    @Test("Konkrete Holds gleicher Revision schützen jeden verbleibenden Besitzer", arguments: [false, true])
    @MainActor
    func actionHoldsKeepEveryOwner(_ reverse: Bool) async throws {
        let source = "Text\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let hadUndo = web.undoManager?.canUndo
        _ = try await web.evaluateJavaScript("window.__actionSnapshots=[];window.__actionPrepare=fastraVisual.prepareAction;fastraVisual.prepareAction=function(...args){const state=window.__actionPrepare.apply(this,args);window.__actionSnapshots.push(state);return state;};true;")
        let a = try await actionHold(coordinator), b = try await actionHold(coordinator), c = try await actionHold(coordinator)
        #expect(try await web.evaluateJavaScript("window.__actionSnapshots.length===3 && new Set(window.__actionSnapshots.map(s=>s.actionID)).size===3 && new Set(window.__actionSnapshots.map(s=>s.revision)).size===1 && new Set(window.__actionSnapshots.map(s=>s.session)).size===1") as? Bool == true)
        _ = try await web.evaluateJavaScript("const held=window.__actionSnapshots[0];window.__duplicatePrepare=window.__actionPrepare(held.session,held.actionID);fastraVisual.completeAction(held.session,'unknown');true;")
        #expect(try await web.evaluateJavaScript("window.__duplicatePrepare===null") as? Bool == true)
        defer { [a, b, c].forEach { $0.finish() } }
        #expect([a, b, c].allSatisfy { $0.isCurrent(for: coordinator) })
        b.finish(); b.finish()
        _ = try await web.evaluateJavaScript("const ended=window.__actionSnapshots[1];fastraVisual.completeAction(ended.session,ended.actionID);true;")
        #expect(!b.isActive && !b.isCurrent(for: coordinator))
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        let first = reverse ? c : a, last = reverse ? a : c
        first.finish()
        #expect(last.isCurrent(for: coordinator))
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        last.finish(); last.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        #expect(workspace.activeTab?.content == source && coordinator.markdown == source)
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
        #expect(!workspace.tabs[0].hasUnsavedChanges && web.undoManager?.canUndo == hadUndo)
    }

    @Test("Relocate entwertet Batchabdeckung, erhält aber eigene Freigabe", arguments: [false, true])
    @MainActor
    func actionHoldRelocation(_ younger: Bool) async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("visual-hold-relocate-\(UUID().uuidString)")
        let original = directory.appendingPathComponent("note.md"), moved = directory.appendingPathComponent("renamed.md")
        let (workspace, coordinator, web, window) = try await editor("Text\n", documentURL: original)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let a = try await actionHold(coordinator)
        defer { a.finish() }
        workspace.tabs[0].url = moved
        coordinator.relocateDocument(from: original, to: moved)
        #expect(!a.isCurrent(for: coordinator) && a.isActive)
        #expect(!workspace.textWorkflowDiskEditorsAreHeld([a]))
        let b = younger ? try await actionHold(coordinator) : nil
        defer { b?.finish() }
        a.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == !younger)
        b?.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        #expect(workspace.activeTab?.content == "Text\n" && coordinator.documentURL == moved)
    }

    @Test("Invalidierte Holds enden nativ, während alter DOM bis Load gesperrt bleibt", arguments: [false, true])
    @MainActor
    func actionHoldInvalidation(_ reverse: Bool) async throws {
        let (workspace, coordinator, web, window) = try await editor("Text\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let a = try await actionHold(coordinator), b = try await actionHold(coordinator)
        defer { a.finish(); b.finish() }
        coordinator.discardForTermination()
        #expect(!coordinator.ready && !a.isCurrent(for: coordinator) && !b.isCurrent(for: coordinator))
        (reverse ? b : a).finish(); (reverse ? a : b).finish()
        a.finish(); b.finish()
        #expect(!a.isActive && !b.isActive)
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        let rendering = DispatchSemaphore(value: 0), resumeRendering = DispatchSemaphore(value: 0)
        defer { resumeRendering.signal() }
        MarkdownRichText.renderQueue.async { rendering.signal(); resumeRendering.wait() }
        try #require(await waitUntil { rendering.wait(timeout: .now()) == .success })
        coordinator.load("Text\n", documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "reload")
        #expect(!coordinator.ready)
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        resumeRendering.signal()
        try #require(await waitUntil(timeout: 12) { coordinator.ready })
        a.finish(); b.finish()
        #expect(!workspace.textWorkflowDiskEditorsAreHeld([a, b]))
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        #expect(workspace.activeTab?.content == "Text\n")
    }

    @Test("Diagnose: alte Basisablehnung erhält neue Relocationsperre", arguments: [false, true])
    @MainActor
    func baseRejectionKeepsRelocatedActionFencedDiagnostic(_ viaWorkspace: Bool) async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("base-rejection-diagnostic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("note.md")
        let relocated = directory.appendingPathComponent("renamed.md")
        let (workspace, coordinator, web, window) = try await editor("Text\n", documentURL: original)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        var oldCompletions: [Bool] = [], newCompletions: [Bool] = []
        var newHold: MarkdownVisualCoordinator.ActionHold?
        var warnings = 0
        let oldGeneration = coordinator.generation
        workspace.tabs[0].content = "Andere Modellbasis\n"
        workspace.saveSafetyWarningHandler = { _, _ in
            warnings += 1
            guard warnings == 1 else { return }
            workspace.tabs[0].content = coordinator.markdown
            workspace.tabs[0].url = relocated
            coordinator.relocateDocument(from: original, to: relocated)
            coordinator.synchronize(holdingInput: true) { succeeded, hold in newCompletions.append(succeeded); newHold = hold }
        }
        if viaWorkspace {
            let queued = workspace.synchronizeVisualMarkdownBefore({ oldCompletions.append(true) }, onFailure: { oldCompletions.append(false) })
            #expect(queued)
        } else {
            coordinator.synchronize { oldCompletions.append($0) }
        }
        try #require(await waitUntil { !oldCompletions.isEmpty && !newCompletions.isEmpty })
        #expect(oldCompletions == [false] && newCompletions == [true])
        #expect(warnings == 1 && coordinator.generation > oldGeneration)
        #expect(workspace.activeTab?.content == "Text\n" && workspace.activeTab?.url == relocated)
        #expect(coordinator.documentURL == relocated)
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == "Text\n")
        let editable = try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool
        print("BASE_REJECTION_DIAGNOSTIC viaWorkspace=\(viaWorkspace) old=\(oldCompletions) new=\(newCompletions) warnings=\(warnings) oldGeneration=\(oldGeneration) generation=\(coordinator.generation) editable=\(String(describing: editable))")
        #expect(editable == false)
        newHold?.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        #expect(oldCompletions == [false] && newCompletions == [true])
    }


    @Test("Diagnose: Basisablehnung ohne Folgeaktion beendet die eigene Sperre", arguments: [false, true])
    @MainActor
    func baseRejectionWithoutNewActionDiagnostic(_ viaWorkspace: Bool) async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("base-rejection-no-new-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("note.md"), relocated = directory.appendingPathComponent("renamed.md")
        let (workspace, coordinator, web, window) = try await editor("Text\n", documentURL: original)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        var completions: [Bool] = [], warnings = 0
        let oldGeneration = coordinator.generation
        workspace.tabs[0].content = "Andere Modellbasis\n"
        workspace.saveSafetyWarningHandler = { _, _ in
            warnings += 1
            guard warnings == 1 else { return }
            workspace.tabs[0].content = coordinator.markdown
            workspace.tabs[0].url = relocated
            coordinator.relocateDocument(from: original, to: relocated)
        }
        if viaWorkspace {
            let queued = workspace.synchronizeVisualMarkdownBefore({ completions.append(true) }, onFailure: { completions.append(false) })
            #expect(queued)
        } else {
            coordinator.synchronize { completions.append($0) }
        }
        try #require(await waitUntil { !completions.isEmpty })
        #expect(completions == [false] && warnings == 1 && coordinator.generation > oldGeneration)
        #expect(workspace.activeTab?.content == "Text\n" && workspace.activeTab?.url == relocated)
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == "Text\n")
        let editable = try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool
        print("BASE_REJECTION_NO_NEW_ACTION viaWorkspace=\(viaWorkspace) completions=\(completions) warnings=\(warnings) oldGeneration=\(oldGeneration) generation=\(coordinator.generation) editable=\(String(describing: editable))")
        #expect(editable == true)
    }


    @MainActor
    private func waitForVisualJavaScript(_ expression: String, in web: WKWebView) async -> Bool {
        var observed = false, reading = false
        return await waitUntil {
            if observed { return true }
            if !reading {
                reading = true
                web.evaluateJavaScript(expression) { value, _ in observed = value as? Bool == true; reading = false }
            }
            return false
        }
    }

    @Test("Fehlgeschlagene Vorbereitung räumt nur ihren möglicherweise erworbenen Token auf", arguments: ["composing", "transport", "ack", "session", "revision", "workspace"], [false, true])
    @MainActor
    func actionHoldPreparationFailure(_ fault: String, _ overlapping: Bool) async throws {
        let source = "Text\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let survivor = overlapping ? try await actionHold(coordinator) : nil
        defer { survivor?.finish(); coordinator.workspace = workspace }
        var warnings = 0, results: [Bool] = []
        workspace.saveSafetyWarningHandler = { _, _ in warnings += 1 }
        _ = try await web.callAsyncJavaScript("""
            window.__prepareBeforeFault=fastraVisual.prepareAction;
            if(fault==='composing')document.getElementById('fastra-visual').dispatchEvent(new CompositionEvent('compositionstart'));
            else fastraVisual.prepareAction=function(...args){
              const state=window.__prepareBeforeFault.apply(this,args);
              if(fault==='transport')throw new Error('controlled transport failure after preparation');
              if(fault==='ack')delete state.actionID;
              if(fault==='session')state.session='foreign-session';
              if(fault==='revision')state.revision=-1;
              return state;
            };
            return true;
            """, arguments: ["fault": fault], in: nil, contentWorld: .page)
        if fault == "workspace" { coordinator.workspace = nil }
        coordinator.synchronize(holdingInput: true) { succeeded, hold in
            results.append(succeeded)
            #expect(hold == nil)
        }
        try #require(await waitUntil { !results.isEmpty })
        coordinator.workspace = workspace
        _ = try await web.evaluateJavaScript("fastraVisual.prepareAction=window.__prepareBeforeFault;if(document.getElementById('fastra-visual'))document.getElementById('fastra-visual').dispatchEvent(new CompositionEvent('compositionend'));true;")
        #expect(results == [false] && warnings == (fault == "composing" ? 1 : 0))
        #expect((survivor?.isCurrent(for: coordinator) ?? false) == overlapping)
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == !overlapping)
        survivor?.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        let subsequent = try await actionHold(coordinator)
        subsequent.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        #expect(results == [false] && workspace.activeTab?.content == source && coordinator.markdown == source)
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
    }

    @Test("JS hält einen bereits erworbenen Token vor seiner nativen Callbackzustellung")
    @MainActor
    func actionHoldBridgePendingResponse() async throws {
        let (workspace, coordinator, web, window) = try await editor("Text\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let a = try await actionHold(coordinator)
        defer { a.finish() }
        _ = try await web.evaluateJavaScript("window.__originalPrepare=fastraVisual.prepareAction;fastraVisual.prepareAction=function(...args){const state=window.__originalPrepare.apply(this,args);window.__preparedPending=true;return new Promise(resolve=>{window.__deliverPreparation=()=>resolve(state);});};true;")
        var b: MarkdownVisualCoordinator.ActionHold?, results: [Bool] = []
        coordinator.synchronize(holdingInput: true) { results.append($0); b = $1 }
        defer { b?.finish() }
        try #require(await waitForVisualJavaScript("window.__preparedPending===true", in: web))
        #expect(results.isEmpty)
        a.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        _ = try await web.evaluateJavaScript("fastraVisual.prepareAction=window.__originalPrepare;window.__deliverPreparation();true;")
        try #require(await waitUntil { !results.isEmpty })
        #expect(results == [true] && b?.isCurrent(for: coordinator) == true)
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        b?.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        #expect(workspace.activeTab?.content == "Text\n")
    }

    @Test("Bereits abgeschickte Freigabe wirkt nur auf ihren Token vor neuer Vorbereitung")
    @MainActor
    func actionHoldBridgeReleaseBeforePrepare() async throws {
        let (_, coordinator, web, window) = try await editor("Text\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let a = try await actionHold(coordinator)
        a.finish()
        let b = try await actionHold(coordinator)
        defer { b.finish() }
        a.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        b.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
    }

    @Test("Legacy- und native Aktionssperren enden unabhängig und Fehlformen bleiben wirkungslos", arguments: [false, true])
    @MainActor
    func actionHoldLegacyIsolation(_ legacyFirst: Bool) async throws {
        let (workspace, coordinator, web, window) = try await editor("Text\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let snapshot = try #require(try await web.evaluateJavaScript("fastraVisual.prepareAction()") as? [String: Any])
        #expect(snapshot["actionID"] == nil && snapshot["session"] == nil && snapshot["markdown"] as? String == "Text\n")
        let session = try #require(try await web.evaluateJavaScript("fastraVisual.outlineSnapshot().session") as? String)
        let a = try await actionHold(coordinator), b = try await actionHold(coordinator)
        defer { a.finish(); b.finish() }
        let rejected = try await web.callAsyncJavaScript("""
            const before=fastraVisual.markdown();
            const rejected=[fastraVisual.prepareAction(session),fastraVisual.prepareAction(session,null),fastraVisual.prepareAction('foreign-session','foreign-token')];
            fastraVisual.completeAction(session,null);fastraVisual.completeAction(session,'unknown');
            fastraVisual.completeAction(session,'unknown','extra');fastraVisual.completeAction();
            return rejected.every(value=>value===null) && fastraVisual.markdown()===before;
            """, arguments: ["session": session], in: nil, contentWorld: .page) as? Bool
        #expect(rejected == true)
        if legacyFirst { _ = try await web.callAsyncJavaScript("fastraVisual.completeAction(session);", arguments: ["session": session], in: nil, contentWorld: .page) }
        a.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        b.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == legacyFirst)
        if !legacyFirst { _ = try await web.callAsyncJavaScript("fastraVisual.completeAction(session);", arguments: ["session": session], in: nil, contentWorld: .page) }
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        #expect(workspace.activeTab?.content == "Text\n")
    }

    @Test("Visueller Editor nimmt Eingaben erst nach der Markdown-Aufbereitung an", arguments: [false, true])
    @MainActor
    func inputWaitsForVisualEnhancement(_ timesOut: Bool) async throws {
        let source = "Zweimal  leer\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        web.configuration.userContentController.addUserScript(WKUserScript(source: """
            const originalHasAttribute=Element.prototype.hasAttribute;
            Element.prototype.hasAttribute=function(name){
                if(this===document.documentElement && name==='data-fastra-enhanced' && !window.releaseEnhancement)return false;
                return originalHasAttribute.call(this,name);
            };
            const originalNow=Date.now;
            Date.now=function(){return originalNow()+(window.expireEnhancement?6000:0);};
            const originalStart=fastraVisual.start;
            fastraVisual.start=function(configuration){
                const result=originalStart.call(this,configuration);
                window.waitingForEnhancement=true;
                return result;
            };
            window.typeIntoVisualParagraph=function(text){
                const root=document.getElementById('fastra-visual'),paragraph=root.querySelector('p'),range=document.createRange();
                root.focus();range.selectNodeContents(paragraph);range.collapse(false);
                getSelection().removeAllRanges();getSelection().addRange(range);
                return document.execCommand('insertText',false,text);
            };
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        var startWarnings = 0
        workspace.saveSafetyWarningHandler = { _, _ in startWarnings += 1 }
        coordinator.load(source, documentURL: nil, fontName: PreviewFonts.systemName,
                         fontSize: 14, darkMode: false, style: "delayed-enhancement")
        try #require(await waitForVisualJavaScript("window.waitingForEnhancement===true", in: web))
        #expect(!coordinator.ready)
        #expect(try await web.evaluateJavaScript("typeIntoVisualParagraph(' Zu früh')") as? Bool == false)
        if timesOut {
            _ = try await web.evaluateJavaScript("window.expireEnhancement=true;true;")
            try #require(await waitUntil { startWarnings == 1 })
            _ = try await web.evaluateJavaScript("window.releaseEnhancement=true;true;")
            #expect(!coordinator.ready)
            #expect(try await web.evaluateJavaScript("typeIntoVisualParagraph(' Zu früh')") as? Bool == false)
            #expect(workspace.activeTab?.content == source)
            return
        }
        _ = try await web.evaluateJavaScript("window.releaseEnhancement=true;true;")
        try #require(await waitUntil { coordinator.ready })
        #expect(try await web.evaluateJavaScript("document.querySelector('#fastra-visual p').textContent") as? String == "Zweimal  leer")
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
        #expect(workspace.activeTab?.content == source)
        #expect(try await web.evaluateJavaScript("typeIntoVisualParagraph(' Jetzt')") as? Bool == true)
        try #require(await waitUntil { workspace.activeTab?.content.contains("Jetzt") == true })
    }

    @Test("Same-Session-Start schützt beide Tokens vor und über frühe und späte Yields", arguments: [false, true], [false, true])
    @MainActor
    func actionHoldsAcrossSameSessionStart(_ reverse: Bool, _ releaseEarly: Bool) async throws {
        let source = "Text\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let a = try await actionHold(coordinator), b = try await actionHold(coordinator)
        defer { a.finish(); b.finish() }
        let first = reverse ? b : a, last = reverse ? a : b
        let session = try #require(try await web.evaluateJavaScript("fastraVisual.outlineSnapshot().session") as? String)
        let document = MarkdownVisualDocument.render(source, documentURL: nil)
        let blocks = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document.blocks))
        let configuration: [String: Any] = ["blocks": blocks, "markdown": source, "session": session,
            "opaqueSources": document.opaqueSources, "viewport": ["x": 0, "y": 0]]
        let immediatelyFenced = try await web.callAsyncJavaScript("""
            const previous=document.getElementById('fastra-visual'),replacement=previous.cloneNode(true);
            replacement.contentEditable='true';previous.replaceWith(replacement);
            window.__editableAssignments=[];
            const descriptor=Object.getOwnPropertyDescriptor(HTMLElement.prototype,'contentEditable');
            Object.defineProperty(replacement,'contentEditable',{get(){return descriptor.get.call(this);},set(value){window.__editableAssignments.push(value);descriptor.set.call(this,value);}});
            document.documentElement.removeAttribute('data-fastra-enhanced');
            window.__startFinished=false;window.__startValue=null;
            window.__originalTimeout=window.setTimeout;window.__holdEarly=true;window.__holdLate=true;
            window.setTimeout=function(callback,delay,...args){
              if(delay===10 && window.__holdEarly){window.__earlyYield=true;window.__resumeEarly=()=>window.__originalTimeout(callback,0,...args);return 0;}
              if(delay===16 && window.__holdLate){window.__lateYield=true;window.__resumeLate=()=>window.__originalTimeout(callback,0,...args);return 0;}
              return window.__originalTimeout(callback,delay,...args);
            };
            window.__starting=fastraVisual.start(configuration).then(value=>{window.__startValue=value;window.__startFinished=true;});
            return !replacement.isContentEditable && window.__earlyYield===true;
            """, arguments: ["configuration": configuration], in: nil, contentWorld: .page) as? Bool
        #expect(immediatelyFenced == true && a.isCurrent(for: coordinator) && b.isCurrent(for: coordinator))
        if releaseEarly { first.finish() }
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        _ = try await web.evaluateJavaScript("window.__holdEarly=false;document.documentElement.setAttribute('data-fastra-enhanced','');window.__resumeEarly();true;")
        try #require(await waitForVisualJavaScript("window.__lateYield===true", in: web))
        if !releaseEarly { first.finish() }
        #expect(last.isCurrent(for: coordinator))
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        _ = try await web.evaluateJavaScript("window.__holdLate=false;window.setTimeout=window.__originalTimeout;window.__resumeLate();true;")
        try #require(await waitForVisualJavaScript("window.__startFinished===true", in: web))
        #expect(try await web.evaluateJavaScript("window.__startValue===true && !window.__editableAssignments.includes('true')") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        first.finish(); last.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        #expect(workspace.activeTab?.content == source && !workspace.tabs[0].hasUnsavedChanges)
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
    }

    @Test("Neue Session übernimmt keine alten Tokens und weist alte Vorbereitungsargumente ab", arguments: [false, true])
    @MainActor
    func actionHoldNewSession(_ younger: Bool) async throws {
        let source = "Text\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let a = try await actionHold(coordinator)
        defer { a.finish() }
        let oldSession = try #require(try await web.evaluateJavaScript("fastraVisual.outlineSnapshot().session") as? String)
        coordinator.load(source, documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "new-session")
        try #require(await waitUntil(timeout: 12) { coordinator.ready })
        #expect(!a.isCurrent(for: coordinator) && a.isActive)
        #expect(!workspace.textWorkflowDiskEditorsAreHeld([a]))
        let b = younger ? try await actionHold(coordinator) : nil
        defer { b?.finish() }
        let rejected = try await web.callAsyncJavaScript("""
            const before=fastraVisual.markdown(),editable=document.getElementById('fastra-visual').isContentEditable;
            const response=fastraVisual.prepareAction(oldSession,'delayed-old-prepare');
            fastraVisual.completeAction(oldSession,'delayed-old-prepare');
            return response===null && fastraVisual.markdown()===before && document.getElementById('fastra-visual').isContentEditable===editable;
            """, arguments: ["oldSession": oldSession], in: nil, contentWorld: .page) as? Bool
        #expect(rejected == true)
        a.finish(); a.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == !younger)
        b?.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        #expect(workspace.activeTab?.content == source)
    }

    @Test("Workspacewrapper hält seine synchrone Aktion und gibt reentrante Halter nicht frei")
    @MainActor
    func actionHoldWorkspaceReentrance() async throws {
        let (workspace, coordinator, web, window) = try await editor("Text\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        var bodyCalls = 0, failures = 0, nestedQueued: Bool?, responses: [Bool] = []
        var b: MarkdownVisualCoordinator.ActionHold?
        defer { b?.finish() }
        let queued = workspace.synchronizeVisualMarkdownBefore({
            bodyCalls += 1
            nestedQueued = workspace.synchronizeVisualMarkdownBefore { bodyCalls += 100 }
            coordinator.synchronize(holdingInput: true) { responses.append($0); b = $1 }
        }, onFailure: { failures += 1 })
        try #require(queued)
        try #require(await waitUntil { !responses.isEmpty })
        #expect(bodyCalls == 1 && failures == 0 && nestedQueued == false && responses == [true])
        #expect(b?.isCurrent(for: coordinator) == true)
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        b?.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
    }

    @Test("Bookmark hält seinen eigenen Token bis zur zweiten echten Browserantwort", arguments: [false, true])
    @MainActor
    func actionHoldBookmarkCallback(_ stale: Bool) async throws {
        let source = "Text\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("window.__originalBookmark=fastraVisual.bookmark;fastraVisual.bookmark=function(){const value=window.__originalBookmark();window.__bookmarkWaiting=true;return new Promise(resolve=>{window.__deliverBookmark=()=>resolve(value);});};true;")
        var response: Result<MarkdownVisualCoordinator.InsertionBookmark, Error>?
        coordinator.captureInsertionBookmark { response = $0 }
        try #require(await waitForVisualJavaScript("window.__bookmarkWaiting===true", in: web))
        #expect(response == nil)
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        let b = try await actionHold(coordinator)
        defer { b.finish() }
        if stale { coordinator.generation &+= 1 }
        _ = try await web.evaluateJavaScript("fastraVisual.bookmark=window.__originalBookmark;window.__deliverBookmark();true;")
        try #require(await waitUntil { response != nil })
        switch response {
        case .success(let bookmark):
            #expect(!stale && coordinator.ownsInsertionBookmark(bookmark))
        case .failure:
            #expect(stale)
        case nil:
            Issue.record("Bookmarkantwort fehlt")
        }
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        b.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        #expect(workspace.activeTab?.content == source)
    }

    @Test("Batch wartet alle Antworten und behält erfolgreiche Holds auch bei Teilfehler", arguments: [false, true])
    @MainActor
    func actionHoldBatchPartialResponse(_ rejectMiddle: Bool) async throws {
        let (firstWorkspace, first, firstWeb, firstWindow) = try await editor("First\n")
        let (middleWorkspace, middle, middleWeb, middleWindow) = try await editor("Middle\n")
        let (lastWorkspace, last, lastWeb, lastWindow) = try await editor("Last\n")
        defer {
            for (web, window) in [(firstWeb, firstWindow), (middleWeb, middleWindow), (lastWeb, lastWindow)] {
                web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close()
            }
        }
        let survivor = try await actionHold(first)
        defer { survivor.finish() }
        let owner = Workspace()
        owner.fileTreeMutationWorkspaceProvider = { [firstWorkspace, middleWorkspace, lastWorkspace] }
        var warnings = 0
        middleWorkspace.saveSafetyWarningHandler = { _, _ in warnings += 1 }
        middleWorkspace.tabs[0].isLoading = rejectMiddle
        _ = try await lastWeb.evaluateJavaScript("window.__originalPrepare=fastraVisual.prepareAction;fastraVisual.prepareAction=function(...args){const value=window.__originalPrepare.apply(this,args);window.__batchWaiting=true;return new Promise(resolve=>{window.__deliverBatch=()=>resolve(value);});};true;")
        var response: (Bool, [MarkdownVisualCoordinator.ActionHold])?
        let task = Task { @MainActor in response = await owner.synchronizeTextWorkflowDiskDocuments() }
        try #require(await waitForVisualJavaScript("window.__batchWaiting===true", in: lastWeb))
        #expect(response == nil)
        task.cancel()
        #expect(try await firstWeb.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        _ = try await lastWeb.evaluateJavaScript("fastraVisual.prepareAction=window.__originalPrepare;window.__deliverBatch();true;")
        await task.value
        let result = try #require(response)
        defer { result.1.forEach { $0.finish() } }
        #expect(result.0 == !rejectMiddle && warnings == (rejectMiddle ? 1 : 0))
        #expect(result.1.count == (rejectMiddle ? 2 : 3))
        #expect(owner.textWorkflowDiskEditorsAreHeld(result.1) == !rejectMiddle)
        #expect(result.1.contains { $0.isCurrent(for: first) } && result.1.contains { $0.isCurrent(for: last) })
        result.1.forEach { $0.finish() }
        #expect(survivor.isCurrent(for: first))
        #expect(try await firstWeb.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        #expect(try await middleWeb.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        #expect(try await lastWeb.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        survivor.finish()
        #expect(try await firstWeb.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        middleWorkspace.tabs[0].isLoading = false
        #expect(firstWorkspace.activeTab?.content == "First\n" && middleWorkspace.activeTab?.content == "Middle\n" && lastWorkspace.activeTab?.content == "Last\n")
        withExtendedLifetime(middle) {}
    }

    @Test("Textworkflow hält eigene Berechtigungen über Startfehler, Abbruch und Apply/Undo", arguments: ["cancel", "syncFailure", "launchFailure", "applyUndo"])
    @MainActor
    func actionHoldWorkflowLifecycle(_ outcome: String) async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("workflow-visual-hold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("note.md"), original = "text\n"
        try Data(original.utf8).write(to: url)
        let (workspace, coordinator, web, window) = try await editor(original, documentURL: url)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        workspace.tabs[0].diskSnapshot = try FileSnapshot.readSnapshotOnly(from: url)
        workspace.tabs[0].recordSavedContentBaseline()
        workspace.fileTreeMutationWorkspaceProvider = { [] }
        workspace.folderApplyBackupRoot = directory.appendingPathComponent("journal")
        let domain = "fastra-test-visual-workflow-" + UUID().uuidString
        let defaults = testSuiteDefaults(named: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let tab = try #require(workspace.activeTab)
        let workflow = TextWorkflowSession(snapshot: .init(tabID: tab.id, documentID: tab.documentID, url: url,
            revision: tab.contentRevision, source: original, selection: NSRange(location: 0, length: 0), windowID: ObjectIdentifier(window)),
            workspace: workspace, store: TextWorkflowStore(defaults: defaults))
        workflow.definition = TextWorkflow(name: "Upper", steps: [.init(kind: .uppercase)])
        try #require(workflow.save())
        let blocker = Workspace(defaults: defaults)
        blocker.fileTreeMutationWorkspaceProvider = { [] }
        var blockingMutation: Workspace.TextWorkflowDiskMutation?
        var reservationError: Error?
        defer {
            workspace.fileTreeMutationWorkspaceProvider = { [] }
            if let blockingMutation { blocker.finishTextWorkflowDiskMutation(blockingMutation, changedURLs: [], session: nil) }
        }
        workspace.textWorkflowSession = workflow
        defer { workflow.close() }
        workflow.scope = .folder; workflow.folderURLs = [url]
        workflow.calculate()
        try #require(await waitUntil { workflow.canApply })
        let survivor = try await actionHold(coordinator)
        defer { survivor.finish() }
        _ = try await web.evaluateJavaScript("window.__originalPrepare=fastraVisual.prepareAction;fastraVisual.prepareAction=function(...args){const state=window.__originalPrepare.apply(this,args);window.__workflowWaiting=true;return new Promise(resolve=>{window.__deliverWorkflow=()=>resolve(state);});};true;")
        try #require(workflow.apply())
        try #require(await waitForVisualJavaScript("window.__workflowWaiting===true", in: web))
        #expect(workflow.isBusy && workflow.isDiskOperation && workspace.textEditingIsAllowed(for: workspace.tabs[0]))
        if outcome == "cancel" { workflow.cancel() }
        if outcome == "launchFailure" {
            // Die erste Editorliste ist schon eingefroren und ihre echte
            // JS-Vorbereitung wartet. Der nächste bestehende Provideraufruf
            // gehört zur Abdeckungsprüfung vor dem Claim. Erst dann reserviert
            // eine andere Operation das Ziel nach der Snapshotübernahme.
            workspace.fileTreeMutationWorkspaceProvider = {
                if blockingMutation == nil {
                    do { blockingMutation = try blocker.beginTextWorkflowDiskMutation(urls: [url]) }
                    catch { reservationError = error }
                }
                return []
            }
        }
        if outcome == "syncFailure" { workspace.tabs[0].isLoading = true; workspace.saveSafetyWarningHandler = { _, _ in } }
        #expect(workflow.isBusy)
        #expect(try Data(contentsOf: url) == Data(original.utf8))
        _ = try await web.evaluateJavaScript("fastraVisual.prepareAction=window.__originalPrepare;window.__deliverWorkflow();true;")
        try #require(await waitUntil { !workflow.isBusy })
        workspace.tabs[0].isLoading = false
        if outcome == "launchFailure" {
            #expect(reservationError == nil && blockingMutation != nil && workspace.fileMutationIsInFlight(for: url))
            #expect(workflow.error?.contains(TextWorkflowFailure.busy) == true)
            workspace.fileTreeMutationWorkspaceProvider = { [] }
            if let blockingMutation { blocker.finishTextWorkflowDiskMutation(blockingMutation, changedURLs: [], session: nil) }
            blockingMutation = nil
        }
        #expect(!workflow.isDiskOperation && workspace.textEditingIsAllowed(for: workspace.tabs[0]))
        #expect(survivor.isActive)
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        if outcome == "applyUndo" {
            try #require(await waitUntil { workspace.activeTab?.content == "TEXT\n" })
            #expect(try Data(contentsOf: url) == Data("TEXT\n".utf8))
            #expect(workflow.diskAppliedSession != nil && !workspace.tabs[0].hasUnsavedChanges)
            coordinator.load("TEXT\n", documentURL: url, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "post-apply")
            try #require(await waitUntil(timeout: 12) { coordinator.ready })
            #expect(!survivor.isCurrent(for: coordinator))
            let undoSurvivor = try await actionHold(coordinator)
            defer { undoSurvivor.finish() }
            workflow.restoreDisk()
            try #require(await waitUntil { !workflow.isBusy && workspace.activeTab?.content == original })
            #expect(workflow.diskAppliedSession == nil && workspace.lastApplySession == nil)
            #expect(try Data(contentsOf: url) == Data(original.utf8))
            #expect(workspace.textEditingIsAllowed(for: workspace.tabs[0]))
            survivor.finish()
            #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
            undoSurvivor.finish()
        } else {
            #expect(workflow.error != nil && workflow.diskAppliedSession == nil)
            #expect(try Data(contentsOf: url) == Data(original.utf8))
            #expect(workspace.activeTab?.content == original)
        }
        survivor.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
    }

    @Test("Native Aktionsfreigabe und verspäteter Clipboardabschluss bleiben getrennt", arguments: [false, true])
    @MainActor
    func actionHoldClipboardIsolation(_ actionFirst: Bool) async throws {
        let source = "Unverändert\n"
        let (_, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            window.webkit.messageHandlers.markdownCopy.postMessage=payload=>{window.clipboardRequest=payload;};
            const root=document.getElementById('fastra-visual'),range=document.createRange();range.selectNodeContents(root);
            getSelection().removeAllRanges();getSelection().addRange(range);
            root.dispatchEvent(new Event('cut',{bubbles:true,cancelable:true}));
            """)
        let hold = try await actionHold(coordinator)
        defer { hold.finish() }
        if actionFirst { hold.finish() }
        _ = try await web.evaluateJavaScript("fastraVisual.completeClipboard(window.clipboardRequest.bookmark,true,true)")
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == actionFirst)
        hold.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
    }

    @Test("Native Freigabe erhält den unabhängigen Bildfence bis zu dessen echtem Abschluss")
    @MainActor
    func actionHoldImageFenceIsolation() async throws {
        try await withVisualImageReferences { fixture in
            fixture.insert("a.png")
            try #require(await waitUntil { fixture.workspace.activeTab?.content.contains("images/1.png") == true })
            let before = try #require(fixture.workspace.activeTab?.content)
            let hold = try await actionHold(fixture.coordinator)
            defer { hold.finish() }
            let tap = MarkdownVisualMessageTap(fixture.coordinator)
            tap.forwardsChanges = false
            fixture.web.configuration.userContentController.removeScriptMessageHandler(forName: "visualMarkdown")
            fixture.web.configuration.userContentController.add(tap, name: "visualMarkdown")
            fixture.messageTap = tap
            _ = try await fixture.web.evaluateJavaScript("document.querySelector('#fastra-visual img').remove();fastraVisual.flush();")
            hold.finish()
            #expect(try await fixture.web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
            #expect(fixture.workspace.activeTab?.content == before)
            #expect(try Data(contentsOf: fixture.first) == fixture.bytes)
            _ = try await fixture.web.evaluateJavaScript("const state=fastraVisual.outlineSnapshot();fastraVisual.completeImageAction(state.session,state.revision);true;")
            #expect(try await fixture.web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
            // Der künstlich nicht zugestellte Eingabestand bleibt beim normalen
            // Fixtureabschluss für die echte Bild-/Dateirücknahme zuständig.
            tap.forwardsChanges = true
        }
    }

    @Test("Native Tokenfreigabe räumt den manuellen Source-Replacement-Fehlerfence nicht auf")
    @MainActor
    func actionHoldManualSourceFenceIsolation() async throws {
        let source = "Text\n", replacement = "Replacement\n"
        let (workspace, coordinator, web, window) = try await editor(source)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let tap = MarkdownVisualMessageTap(coordinator)
        tap.forwardsChanges = false
        web.configuration.userContentController.removeScriptMessageHandler(forName: "visualMarkdown")
        web.configuration.userContentController.add(tap, name: "visualMarkdown")
        let session = try #require(try await web.evaluateJavaScript("fastraVisual.outlineSnapshot().session") as? String)
        let document = MarkdownVisualDocument.render(source, documentURL: nil)
        let configuration: [String: Any] = ["blocks": try JSONSerialization.jsonObject(with: JSONEncoder().encode(document.blocks)),
            "markdown": source, "session": session, "opaqueSources": document.opaqueSources, "sourceReplacements": true]
        let changed = MarkdownVisualDocument.render(replacement, documentURL: nil)
        let replacementConfiguration: [String: Any] = ["blocks": try JSONSerialization.jsonObject(with: JSONEncoder().encode(changed.blocks)),
            "markdown": replacement, "opaqueSources": changed.opaqueSources]
        let result = try await web.callAsyncJavaScript("""
            const unsupported=await fastraVisual.replaceSource(source,html,replacementConfiguration,'disabled');
            await fastraVisual.start(configuration);
            const originalCommand=document.execCommand;
            document.execCommand=function(command,...args){
              if(command==='insertHTML'){document.getElementById('fastra-visual').innerHTML='<p>Broken</p>';return true;}
              if(command==='undo')return false;
              return originalCommand.call(this,command,...args);
            };
            let failed;
            try{failed=await fastraVisual.replaceSource(source,html,replacementConfiguration,'failure');}
            finally{document.execCommand=originalCommand;}
            const acquired=fastraVisual.prepareAction(configuration.session,'manual-fence-token');
            fastraVisual.completeAction(configuration.session,'manual-fence-token');
            return {unsupported,failed,ack:acquired.actionID,editable:document.getElementById('fastra-visual').isContentEditable,markdown:fastraVisual.markdown()};
            """, arguments: ["source": source, "html": changed.fragment.html,
                              "configuration": configuration, "replacementConfiguration": replacementConfiguration],
            in: nil, contentWorld: .page) as? [String: Any]
        let observed = try #require(result)
        #expect(observed["unsupported"] as? String == "unsupported" && observed["failed"] as? String == "insert")
        #expect(observed["ack"] as? String == "manual-fence-token" && observed["editable"] as? Bool == false)
        #expect(observed["markdown"] as? String != source && workspace.activeTab?.content == source)
        withExtendedLifetime(coordinator) {}
    }

    @Test("Neue bereite Editoren und bereits beendete Holds sind keine Batchabdeckung")
    @MainActor
    func actionHoldBatchNewEditor() async throws {
        let (workspace, coordinator, web, window) = try await editor("First\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        var included: [Workspace] = []
        workspace.fileTreeMutationWorkspaceProvider = { included }
        let (success, holds) = await workspace.synchronizeTextWorkflowDiskDocuments()
        defer { holds.forEach { $0.finish() } }
        try #require(success && holds.count == 1 && workspace.textWorkflowDiskEditorsAreHeld(holds))
        let (addedWorkspace, added, addedWeb, addedWindow) = try await editor("Added\n")
        defer { addedWeb.configuration.userContentController.removeAllScriptMessageHandlers(); addedWindow.close() }
        included = [addedWorkspace]
        #expect(!workspace.textWorkflowDiskEditorsAreHeld(holds))
        included = []
        #expect(workspace.textWorkflowDiskEditorsAreHeld(holds))
        holds.forEach { $0.finish() }
        #expect(!workspace.textWorkflowDiskEditorsAreHeld(holds))
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        withExtendedLifetime((coordinator, added)) {}
    }

    @Test("Echte Enginearbeit hält Claim und konkrete Handles bis zum Mainfinale", arguments: [false, true])
    @MainActor
    func actionHoldDiskFinalizerLifetime(_ partial: Bool) async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("visual-hold-disk-finalizer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("a.md"), second = directory.appendingPathComponent("b.md")
        for url in [first, second] { try Data("text\n".utf8).write(to: url) }
        let (workspace, coordinator, web, window) = try await editor("text\n", documentURL: first)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        workspace.tabs[0].diskSnapshot = try FileSnapshot.readSnapshotOnly(from: first)
        workspace.tabs[0].recordSavedContentBaseline()
        workspace.fileTreeMutationWorkspaceProvider = { [] }
        let tab = try #require(workspace.activeTab)
        let domain = "fastra-test-visual-finalizer-" + UUID().uuidString
        let defaults = testSuiteDefaults(named: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let workflow = TextWorkflowSession(snapshot: .init(tabID: tab.id, documentID: tab.documentID, url: first,
            revision: tab.contentRevision, source: tab.content, selection: NSRange(location: 0, length: 0), windowID: ObjectIdentifier(window)),
            workspace: workspace, store: TextWorkflowStore(defaults: defaults))
        workspace.textWorkflowSession = workflow
        defer { workflow.close() }
        let definition = TextWorkflow(name: "Upper", steps: [.init(kind: .uppercase)])
        let plan = try await Task.detached { try TextWorkflowFilePlan.build(definition, inputs: [.init(url: first), .init(url: second)]) }.value
        let (success, holds) = await workspace.synchronizeTextWorkflowDiskDocuments()
        defer { holds.forEach { $0.finish() } }
        try #require(success && holds.count == 1 && workspace.textWorkflowDiskEditorsAreHeld(holds))
        let mutation = try workspace.beginTextWorkflowDiskMutation(urls: [first, second])
        let paused = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let firstTarget = first.canonicalFileURL, secondTarget = second.canonicalFileURL
        let backupRoot = directory.appendingPathComponent("journal")
        let worker = Task.detached { [holds] in
            defer { withExtendedLifetime(holds) {} }
            return Result<ApplySession, Error> {
                try mutation.preflight(in: workspace)
                return try ApplyEngine.execute(workflowPlan: plan, backupRoot: backupRoot,
                    shouldCancel: { Task.isCancelled }, beforePreflight: {
                        if !partial { paused.signal(); resume.wait() }
                    }, beforeAtomicReplace: { url in
                        if partial && url == secondTarget {
                            paused.signal(); resume.wait()
                            if Task.isCancelled { throw ApplyError.cancelled }
                        }
                    })
            }
        }
        var finalized = false
        do {
            try #require(await waitUntil { paused.wait(timeout: .now()) == .success })
            #expect(!workspace.textEditingIsAllowed(for: workspace.tabs[0]) && holds.allSatisfy(\.isActive))
            #expect(try Data(contentsOf: first) == Data((partial ? "TEXT\n" : "text\n").utf8))
            #expect(try Data(contentsOf: second) == Data("text\n".utf8))
            worker.cancel()
            #expect(!workspace.textEditingIsAllowed(for: workspace.tabs[0]) && holds.allSatisfy(\.isActive))
            if partial {
                coordinator.load("text\n", documentURL: first, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "worker-new-session")
                try #require(await waitUntil(timeout: 12) { coordinator.ready })
                #expect(!workspace.textWorkflowDiskEditorsAreHeld(holds))
                #expect(holds.allSatisfy(\.isActive) && !workspace.textEditingIsAllowed(for: workspace.tabs[0]))
                #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
            }
            resume.signal()
            let result = await worker.value
            #expect(holds.allSatisfy(\.isActive) && !workspace.textEditingIsAllowed(for: workspace.tabs[0]))
            var partialSession: ApplySession?
            switch result {
            case .failure(ApplyError.writeFailed(let session, _)):
                partialSession = session
                #expect(partial && session.entries.contains { $0.originalPath == firstTarget.path })
            case .failure(ApplyError.cancelled):
                #expect(!partial)
            case .failure(let error):
                Issue.record(Comment(rawValue: "Unerwartetes Engineergebnis: \(error)"))
            case .success:
                Issue.record("Abgebrochene Engine wurde als erfolgreich gemeldet")
            }
            workflow.finishDiskOperation(result, undo: nil, in: workspace, mutation: mutation, heldEditors: holds)
            finalized = true
            #expect(holds.allSatisfy { !$0.isActive } && !workspace.fileMutationIsInFlight(for: first) && !workspace.fileMutationIsInFlight(for: second))
            #expect(workflow.error != nil && workflow.diskAppliedSession == partialSession && workspace.lastApplySession == partialSession)
            #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
            if partial { try #require(await waitUntil { workspace.activeTab?.content == "TEXT\n" && workspace.textEditingIsAllowed(for: workspace.tabs[0]) }) }
            else { #expect(workspace.activeTab?.content == "text\n") }
            #expect(try Data(contentsOf: first) == Data((partial ? "TEXT\n" : "text\n").utf8))
            #expect(try Data(contentsOf: second) == Data("text\n".utf8))
        } catch {
            worker.cancel(); resume.signal()
            let result = await worker.value
            if !finalized { workflow.finishDiskOperation(result, undo: nil, in: workspace, mutation: mutation, heldEditors: holds) }
            throw error
        }
    }

    @Test("Nicht bereite oder fremde Dokumente liefern keine vorgetäuschte Berechtigung")
    @MainActor
    func actionHoldUnavailableDocument() async throws {
        let absent = MarkdownVisualCoordinator()
        var noView: [(Bool, MarkdownVisualCoordinator.ActionHold?)] = []
        absent.synchronize(holdingInput: true) { noView.append(($0, $1)) }
        #expect(noView.count == 1 && noView[0].0 && noView[0].1 == nil)
        let (workspace, coordinator, web, window) = try await editor("Text\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let old = try #require(workspace.activeTab)
        workspace.tabs = [EditorTab(id: old.id, title: old.title, path: old.path, content: old.content)]
        var denied: [(Bool, MarkdownVisualCoordinator.ActionHold?)] = []
        coordinator.synchronize(holdingInput: true) { denied.append(($0, $1)) }
        #expect(denied.count == 1 && !denied[0].0 && denied[0].1 == nil)
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        #expect(workspace.activeTab?.content == "Text\n")
    }

    @Test("Verschwundener Workspace endet einmal und hinterlässt keinen eigenen DOMfence")
    @MainActor
    func actionHoldReleasedWorkspace() async throws {
        var successes = 0, failures = 0
        weak var released: Workspace?
        func begin() async throws -> (MarkdownVisualCoordinator, MarkdownVisualWKWebView, NSWindow) {
            let (workspace, coordinator, web, window) = try await editor("Text\n")
            released = workspace
            (window as? MarkdownVisualFixtureWindow)?.retainedWorkspace = nil
            try #require(workspace.synchronizeVisualMarkdownBefore({ successes += 1 }, onFailure: { failures += 1 }))
            return (coordinator, web, window)
        }
        let (coordinator, web, window) = try await begin()
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        try #require(await waitUntil { failures == 1 })
        #expect(released == nil && coordinator.workspace == nil && successes == 0 && failures == 1)
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == "Text\n")
    }

    @Test("Echter Bildverlaufsverlust beendet nur seinen Reset-Hold", arguments: [false, true])
    @MainActor
    func actionHoldImageHistoryReset(_ rejected: Bool) async throws {
        try await withVisualImageReferences { fixture in
            fixture.insert("a.png")
            try #require(await waitUntil { fixture.workspace.activeTab?.content.contains("images/1.png") == true })
            _ = try await fixture.web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
            try #require(await waitUntil { fixture.workspace.activeTab?.content == "Text\n" })
            try #require(await fixture.drain())
            try #require(MarkdownImageUndoBuffer.shared.byteCount > 0)
            let survivor = try await actionHold(fixture.coordinator)
            defer { survivor.finish(); fixture.workspace.tabs[0].isLoading = false }
            let generation = fixture.coordinator.generation
            let rendering = DispatchSemaphore(value: 0), resumeRendering = DispatchSemaphore(value: 0)
            defer { resumeRendering.signal() }
            if !rejected {
                MarkdownRichText.renderQueue.async { rendering.signal(); resumeRendering.wait() }
                try #require(await waitUntil { rendering.wait(timeout: .now()) == .success })
            }
            fixture.workspace.tabs[0].isLoading = rejected
            // Eine Reservierung ohne fill belegt nur Kapazität, keine großen
            // Daten. Sie verdrängt den echten kleinen Undo-Eintrag samt Callback.
            let reservation = try #require(MarkdownImageUndoBuffer.shared.reserve(
                bytes: MarkdownImageUndoBuffer.shared.byteLimit, invalidated: {}))
            let invalidations = MarkdownImageUndoBuffer.shared.takeInvalidations()
            MarkdownImageUndoBuffer.shared.remove(reservation)
            try #require(invalidations.count == 1)
            invalidations.forEach { $0() }
            if rejected {
                try #require(await waitUntil { fixture.warnings.count == 1 })
                #expect(fixture.coordinator.ready && fixture.coordinator.generation == generation)
                #expect(survivor.isCurrent(for: fixture.coordinator))
            } else {
                try #require(await waitUntil { !fixture.coordinator.ready && fixture.coordinator.generation > generation })
                #expect(!survivor.isCurrent(for: fixture.coordinator) && survivor.isActive)
            }
            #expect(try await fixture.web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
            survivor.finish()
            #expect(try await fixture.web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == rejected)
            if !rejected {
                resumeRendering.signal()
                try #require(await waitUntil(timeout: 12) { fixture.coordinator.ready })
                #expect(fixture.warnings.isEmpty)
            }
            #expect(try await fixture.web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
            #expect(fixture.workspace.activeTab?.content == "Text\n")
            #expect(!FileManager.default.fileExists(atPath: fixture.first.path))
            #expect(MarkdownImageUndoBuffer.shared.byteCount == 0)
            fixture.workspace.tabs[0].isLoading = false
        }
    }

    @Test("Echter Quit-Synchronisierungsabbruch erhält einen fremden Langhalter")
    @MainActor
    func actionHoldQuitSynchronizationRejection() async throws {
        let (workspace, coordinator, web, window) = try await editor("Text\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); workspace.tabs[0].isLoading = false }
        let survivor = try await actionHold(coordinator)
        defer { survivor.finish() }
        workspace.tabs[0].isLoading = true
        var warnings = 0
        workspace.saveSafetyWarningHandler = { _, _ in warnings += 1 }
        _ = try await web.evaluateJavaScript("window.__quitActionEnds=0;window.__quitActionEnd=fastraVisual.completeAction;fastraVisual.completeAction=function(...args){window.__quitActionEnd.apply(this,args);window.__quitActionEnds+=1;};true;")
        let delegate = AppDelegate()
        let closing = MarkdownImageUndo.applicationIsClosing
        defer { MarkdownImageUndo.applicationIsClosing = closing }
        for attempt in 1...2 {
            #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
            try #require(await waitForVisualJavaScript("window.__quitActionEnds>=\(attempt)", in: web))
            #expect(warnings == attempt && survivor.isCurrent(for: coordinator))
            #expect(!MarkdownImageUndo.applicationIsClosing)
            #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        }
        survivor.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        #expect(workspace.activeTab?.content == "Text\n")
    }

    @Test("Echte Modusgruppe hält frühe Editoren bis zur letzten Antwort", arguments: [false, true])
    @MainActor
    func actionHoldEditingModeGroup(_ rejectMiddle: Bool) async throws {
        let (firstWorkspace, first, firstWeb, firstWindow) = try await editor("First\n")
        let (middleWorkspace, middle, middleWeb, middleWindow) = try await editor("Middle\n")
        let (lastWorkspace, last, lastWeb, lastWindow) = try await editor("Last\n")
        defer {
            middleWorkspace.tabs[0].isLoading = false
            for (web, window) in [(firstWeb, firstWindow), (middleWeb, middleWindow), (lastWeb, lastWindow)] {
                web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close()
            }
        }
        AppDefaults.store.set(true, forKey: MarkdownEditingMode.defaultsKey)
        let survivor = try await actionHold(first)
        defer { survivor.finish() }
        var warnings = 0
        middleWorkspace.saveSafetyWarningHandler = { _, _ in warnings += 1 }
        middleWorkspace.tabs[0].isLoading = rejectMiddle
        _ = try await firstWeb.evaluateJavaScript("window.__modeEnds=0;window.__modeEnd=fastraVisual.completeAction;fastraVisual.completeAction=function(...args){window.__modeEnd.apply(this,args);window.__modeEnds+=1;};true;")
        _ = try await lastWeb.evaluateJavaScript("window.__modePrepare=fastraVisual.prepareAction;fastraVisual.prepareAction=function(...args){const value=window.__modePrepare.apply(this,args);window.__modeWaiting=true;return new Promise(resolve=>{window.__deliverMode=()=>resolve(value);});};true;")
        MarkdownEditingMode.setDefault(false)
        try #require(await waitForVisualJavaScript("window.__modeWaiting===true", in: lastWeb))
        #expect(AppDefaults.store.bool(forKey: MarkdownEditingMode.defaultsKey))
        survivor.finish()
        #expect(try await firstWeb.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        _ = try await lastWeb.evaluateJavaScript("fastraVisual.prepareAction=window.__modePrepare;window.__deliverMode();true;")
        try #require(await waitForVisualJavaScript("window.__modeEnds===2", in: firstWeb))
        #expect(AppDefaults.store.bool(forKey: MarkdownEditingMode.defaultsKey) == rejectMiddle)
        #expect(warnings == (rejectMiddle ? 1 : 0))
        for web in [firstWeb, middleWeb, lastWeb] {
            #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        }
        #expect(firstWorkspace.activeTab?.content == "First\n" && middleWorkspace.activeTab?.content == "Middle\n" && lastWorkspace.activeTab?.content == "Last\n")
        withExtendedLifetime((middle, last)) {}
    }

    @Test("Echter Viewabbau lässt alten Hold ohne Autorität über einen neuen DOM enden")
    @MainActor
    func actionHoldDismantledDOM() async throws {
        let (oldWorkspace, oldCoordinator, oldWeb, oldWindow) = try await editor("Old\n")
        defer { oldWeb.configuration.userContentController.removeAllScriptMessageHandlers(); oldWindow.close() }
        let a = try await actionHold(oldCoordinator)
        defer { a.finish() }
        MarkdownVisualWebView.dismantleNSView(oldWeb, coordinator: oldCoordinator)
        #expect(!oldCoordinator.ready && oldWorkspace.visualMarkdownEditor == nil)
        #expect(a.isActive && !a.isCurrent(for: oldCoordinator))
        let (workspace, coordinator, web, window) = try await editor("New\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        let b = try await actionHold(coordinator)
        defer { b.finish() }
        a.finish(); a.finish()
        #expect(!a.isActive && b.isCurrent(for: coordinator))
        #expect(try await oldWeb.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        b.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        #expect(workspace.activeTab?.content == "New\n" && oldWorkspace.activeTab?.content == "Old\n")
    }

    @Test("Erster echter Bookmark-Capturecallback lehnt verlagertes Ziel ab und erhält B")
    @MainActor
    func actionHoldBookmarkFirstCallbackStale() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("visual-first-bookmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.md"), relocated = directory.appendingPathComponent("relocated.md")
        let source = "Text\n"
        try Data(source.utf8).write(to: original)
        let (workspace, coordinator, web, window) = try await editor(source, documentURL: original)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            window.__capturePrepare=fastraVisual.prepareAction;window.__captureBookmark=fastraVisual.bookmark;
            window.__bookmarkCalls=0;
            fastraVisual.bookmark=function(...args){window.__bookmarkCalls++;return window.__captureBookmark.apply(this,args);};
            fastraVisual.prepareAction=function(...args){const snapshot=window.__capturePrepare.apply(this,args);window.__firstCaptureWaiting=true;
              return new Promise(resolve=>{window.__deliverFirstCapture=()=>resolve(snapshot);});};true;
            """)
        var responses: [Result<MarkdownVisualCoordinator.InsertionBookmark, Error>] = []
        coordinator.captureInsertionBookmark { responses.append($0) }
        try #require(await waitForVisualJavaScript("window.__firstCaptureWaiting===true", in: web))
        #expect(responses.isEmpty)
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        try FileManager.default.moveItem(at: original, to: relocated)
        workspace.tabs[0].url = relocated
        coordinator.relocateDocument(from: original, to: relocated)
        _ = try await web.evaluateJavaScript("fastraVisual.prepareAction=window.__capturePrepare;true;")
        let b = try await actionHold(coordinator)
        defer { b.finish() }
        _ = try await web.evaluateJavaScript("window.__deliverFirstCapture();true;")
        try #require(await waitUntil { !responses.isEmpty })
        #expect(responses.count == 1)
        if case .failure(TextSnippetError.staleTarget) = responses[0] {} else {
            Issue.record("Staler erster Capturecallback lieferte keinen Zielkonflikt")
        }
        #expect(try await web.evaluateJavaScript("window.__bookmarkCalls") as? Int == 0)
        #expect(b.isCurrent(for: coordinator))
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        #expect(workspace.activeTab?.content == source && workspace.activeTab?.url == relocated)
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
        #expect(try Data(contentsOf: relocated) == Data(source.utf8))
        b.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)
        #expect(responses.count == 1)
    }

    @Test("Same-Session-Start auf demselben Root erhält vorhandenes WebKit-Undo und Redo")
    @MainActor
    func actionHoldSameRootStartKeepsUndo() async throws {
        let original = "Text\n", edited = "Text edit\n"
        let (workspace, coordinator, web, window) = try await editor(original)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        let inserted = try await web.evaluateJavaScript("""
            const root=document.getElementById('fastra-visual'),range=document.createRange();
            range.selectNodeContents(root.querySelector('p'));range.collapse(false);root.focus();
            getSelection().removeAllRanges();getSelection().addRange(range);
            const inserted=document.execCommand('insertText',false,' edit');fastraVisual.flush();inserted;
            """) as? Bool
        try #require(inserted == true)
        try #require(await waitUntil { workspace.activeTab?.content == edited })
        try #require(try await web.evaluateJavaScript("document.queryCommandEnabled('undo')") as? Bool == true)
        let revision = workspace.tabs[0].contentRevision
        let a = try await actionHold(coordinator), b = try await actionHold(coordinator)
        defer { a.finish(); b.finish() }
        let session = try #require(try await web.evaluateJavaScript("fastraVisual.outlineSnapshot().session") as? String)
        let document = MarkdownVisualDocument.render(edited, documentURL: nil)
        let configuration: [String: Any] = ["blocks": try JSONSerialization.jsonObject(with: JSONEncoder().encode(document.blocks)),
            "markdown": edited, "session": session, "opaqueSources": document.opaqueSources]
        let started = try await web.callAsyncJavaScript("""
            window.__sameUndoRoot=document.getElementById('fastra-visual');
            const started=await fastraVisual.start(configuration);
            return started && window.__sameUndoRoot===document.getElementById('fastra-visual');
            """, arguments: ["configuration": configuration], in: nil, contentWorld: .page) as? Bool
        #expect(started == true && a.isCurrent(for: coordinator) && b.isCurrent(for: coordinator))
        #expect(workspace.activeTab?.content == edited && workspace.tabs[0].contentRevision == revision)
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == edited)
        a.finish()
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == false)
        b.finish()
        try #require(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable && document.queryCommandEnabled('undo')") as? Bool == true)
        let undone = try await web.evaluateJavaScript("const undone=document.execCommand('undo');fastraVisual.flush();undone;") as? Bool
        #expect(undone == true)
        try #require(await waitUntil { workspace.activeTab?.content == original })
        #expect(coordinator.markdown == original)
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == original)
        let redone = try await web.evaluateJavaScript("const redone=document.execCommand('redo');fastraVisual.flush();redone;") as? Bool
        #expect(redone == true)
        try #require(await waitUntil { workspace.activeTab?.content == edited })
        #expect(coordinator.markdown == edited)
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == edited)
    }

}


extension MarkdownVisualTests {
    @Test("Seitenleisten-Umbenennung wartet auf visuelles Bild-Undo", arguments: ["md", "markdown", "mkd", "mkdn", "mdwn", "mdown"])
    @MainActor
    func sidebarRenameDuringImageUndo(_ fileExtension: String) async throws {
        let manager = FileManager.default
        let directory = testTemporaryDirectory().appendingPathComponent("visual-tree-\(UUID().uuidString)")
        for name in ["A", "B"] {
            try manager.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        defer { try? manager.removeItem(at: directory) }
        let old = directory.canonicalFileURL.appendingPathComponent("A/note.\(fileExtension)")
        let destination = old.deletingLastPathComponent().appendingPathComponent("renamed.\(fileExtension)")
        let original = Data("Text\n".utf8)
        try original.write(to: old)
        let workspace = Workspace()
        var opened: Bool?
        workspace.loadFile(at: old) { opened = $0 }
        try #require(await waitUntil { opened != nil } && opened == true)
        let index = try #require(workspace.tabs.firstIndex { $0.id == workspace.activeTabID })
        workspace.tabs[index].markdownVisualOverride = true
        let host = NSHostingView(rootView: EditorView().environmentObject(workspace))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer { window.close() }
        try #require(await waitUntil { workspace.visualMarkdownEditor?.ready == true })
        let coordinator = try #require(workspace.visualMarkdownEditor)
        let web = try #require(coordinator.web as? MarkdownVisualWKWebView)
        coordinator.pasteboard = NSPasteboard.withUniqueName()
        let fixture = try VisualImageReferenceFixture(directory: directory, editor: (workspace, coordinator, web, window))
        defer { fixture.schedule.releaseAll() }
        let tabID = workspace.activeTab?.id, documentID = workspace.activeTab?.documentID
        let initialSession = try await web.evaluateJavaScript("fastraVisual.outlineSnapshot().session") as? String
        var completed: Bool?
        let inserted = try await fixture.beginUndo(viaSynchronize: false) { completed = $0 }
        var renamed: Result<URL, Error>?
        workspace.renameFileTreeItem(at: old, to: "renamed.\(fileExtension)") { renamed = $0 }
        #expect(renamed == nil)
        #expect(workspace.activeTab?.url?.path == old.path)
        #expect(manager.fileExists(atPath: old.path) && !manager.fileExists(atPath: destination.path))
        await Task.yield()
        fixture.schedule.setEnabled(false)
        fixture.schedule.release(0)
        try #require(await waitUntil { completed != nil && renamed != nil && workspace.visualMarkdownEditor?.ready == true })
        try #require(await fixture.drain())
        let moved = try #require(renamed).get()
        #expect(completed == true)
        let current = try #require(workspace.visualMarkdownEditor)
        let currentWeb = try #require(current.web)
        let browserContent = try await currentWeb.evaluateJavaScript("fastraVisual.markdown()") as? String
        let endSession = try await currentWeb.evaluateJavaScript("fastraVisual.outlineSnapshot().session") as? String
        let editable = try await currentWeb.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool
        let model = try #require(workspace.activeTab?.content)
        #expect(workspace.activeTab?.id == tabID && workspace.activeTab?.documentID == documentID)
        #expect(current.documentURL?.path == moved.path && editable == true && browserContent == model)
        #expect(!manager.fileExists(atPath: old.path) && (try? Data(contentsOf: moved)) == original)
        #expect(initialSession == endSession && current === coordinator)
        #expect(model == "Text\n" && browserContent == "Text\n")
        #expect(!manager.fileExists(atPath: fixture.first.path) && fixture.warnings.isEmpty)
        _ = try await currentWeb.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content == inserted })
        try #require(await fixture.drain())
        #expect(try Data(contentsOf: fixture.first) == fixture.bytes)
        #expect(fixture.warnings.isEmpty)
    }
}

extension MarkdownVisualTests {
    @Test("Seitenleisten-Umbenennung synchronisiert betroffene Fenster und lässt Nachbartabs frei")
    @MainActor
    func sidebarRenameAcrossWindows() async throws {
        try await withVisualImageReferences { fixture in
            let source = try #require(fixture.workspace.activeTab?.url)
            let destination = source.deletingLastPathComponent().appendingPathComponent("renamed.md")
            let (second, secondEditor, secondWeb, secondWindow) = try await editor("Text\n", documentURL: source)
            defer { secondWeb.configuration.userContentController.removeAllScriptMessageHandlers(); secondWindow.close() }
            let (neighbor, _, neighborWeb, neighborWindow) = try await editor("Nachbar\n", documentURL: fixture.other.tabs[0].url)
            defer { neighborWeb.configuration.userContentController.removeAllScriptMessageHandlers(); neighborWindow.close() }
            let neighborTab = neighbor.activeTab
            _ = try await neighborWeb.evaluateJavaScript("window.__renameNeighborPreparations=0;fastraVisual.prepareAction=function(){window.__renameNeighborPreparations++;throw new Error('unrelated editor must not be synchronized');};true;")
            let localNeighbor = fixture.other.tabs[0]
            fixture.workspace.tabs.append(localNeighbor)
            let initiator = Workspace()
            initiator.fileTreeMutationWorkspaceProvider = { [fixture.workspace, second, neighbor] }
            let firstSession = try await fixture.web.evaluateJavaScript("fastraVisual.outlineSnapshot().session") as? String
            let secondSession = try await secondWeb.evaluateJavaScript("fastraVisual.outlineSnapshot().session") as? String
            let firstID = fixture.workspace.activeTab?.documentID, secondID = second.activeTab?.documentID
            var undone: Bool?, renamed: Result<URL, Error>?
            let inserted = try await fixture.beginUndo(viaSynchronize: false) { undone = $0 }
            initiator.renameFileTreeItem(at: source, to: "renamed.md") { renamed = $0 }
            #expect(renamed == nil && fixture.workspace.activeTab?.url == source && second.activeTab?.url == source)
            #expect(!initiator.fileMutationIsInFlight(for: source))
            await Task.yield()
            fixture.schedule.setEnabled(false); fixture.schedule.release(0)
            try #require(await waitUntil { renamed != nil && undone != nil })
            #expect(try #require(renamed).get() == destination)
            #expect(undone == true && fixture.warnings.isEmpty)
            #expect(fixture.workspace.activeTab?.url?.canonicalFileURL == destination.canonicalFileURL && second.activeTab?.url?.canonicalFileURL == destination.canonicalFileURL)
            #expect(fixture.workspace.activeTab?.documentID == firstID && second.activeTab?.documentID == secondID)
            #expect(fixture.coordinator.documentURL?.canonicalFileURL == destination.canonicalFileURL && secondEditor.documentURL?.canonicalFileURL == destination.canonicalFileURL)
            #expect(try await fixture.web.evaluateJavaScript("fastraVisual.outlineSnapshot().session") as? String == firstSession)
            #expect(try await secondWeb.evaluateJavaScript("fastraVisual.outlineSnapshot().session") as? String == secondSession)
            #expect(try await neighborWeb.evaluateJavaScript("window.__renameNeighborPreparations") as? Int == 0)
            #expect(neighbor.activeTab == neighborTab)
            #expect(fixture.workspace.tabs.first { $0.id == localNeighbor.id } == localNeighbor)
            _ = try await fixture.web.evaluateJavaScript("document.execCommand('redo');fastraVisual.flush();")
            try #require(await waitUntil { fixture.workspace.activeTab?.content == inserted })
            try #require(await fixture.drain())
            #expect(try Data(contentsOf: fixture.first) == fixture.bytes)
            #expect(try Data(contentsOf: destination) == Data("Text\n".utf8))
            #expect(fixture.warnings.isEmpty)
        }
    }

    @Test("Seitenleisten-Umbenennung erhält fremde Quelle und Ziele nach dem Warten", arguments: ["source", "sourceSameBytes", "target", "danglingTarget", "targetTab", "document", "activeTab", "targetLock"])
    @MainActor
    func sidebarRenameConflictsDuringImageUndo(_ conflict: String) async throws {
        try await withVisualImageReferences { fixture in
            let workspace = fixture.workspace
            let source = try #require(workspace.activeTab?.url)
            let destination = source.deletingLastPathComponent().appendingPathComponent("renamed.md")
            let displaced = source.deletingLastPathComponent().appendingPathComponent("displaced.md")
            let original = try Data(contentsOf: source), foreign = Data("Fremde Daten\n".utf8)
            let originalDocumentID = workspace.tabs[0].documentID
            let originalActiveTabID = workspace.activeTabID
            var targetLock: Workspace.FileTreeMoveOperation?
            defer { if let targetLock { workspace.finishFileTreeMove(targetLock) } }
            var undone: Bool?, renamed: Result<URL, Error>?
            var renameCompletions = 0
            _ = try await fixture.beginUndo(viaSynchronize: false) { undone = $0 }
            if conflict == "targetLock" {
                _ = try await fixture.web.evaluateJavaScript("window.__renamePrepared=0;window.__renameHolds=new Set();window.__renamePrepare=fastraVisual.prepareAction;window.__renameComplete=fastraVisual.completeAction;fastraVisual.prepareAction=function(...args){const result=window.__renamePrepare.apply(this,args);window.__renamePrepared++;window.__renameHolds.add(args[1]);return result;};fastraVisual.completeAction=function(...args){window.__renameComplete.apply(this,args);window.__renameHolds.delete(args[1]);};true;")
            }
            workspace.renameFileTreeItem(at: source, to: "renamed.md") { renameCompletions += 1; renamed = $0 }
            #expect(renamed == nil && FileManager.default.fileExists(atPath: source.path))
            #expect(!workspace.fileMutationIsInFlight(for: source))
            switch conflict {
            case "source", "sourceSameBytes":
                try FileManager.default.moveItem(at: source, to: displaced)
                try (conflict == "sourceSameBytes" ? original : foreign).write(to: source)
                #expect(FileIdentity(url: source) != FileIdentity(url: displaced))
            case "target": try foreign.write(to: destination)
            case "danglingTarget": try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: "unavailable.md")
            case "targetTab":
                let owner = Workspace()
                owner.tabs = [EditorTab(title: "renamed.md", path: destination.deletingLastPathComponent().path, url: destination, content: "Fremder Tab\n")]
                workspace.fileTreeMutationWorkspaceProvider = { [owner] }
            case "activeTab":
                workspace.tabs.append(fixture.other.tabs[0])
                workspace.activeTabID = fixture.other.tabs[0].id
            case "targetLock":
                targetLock = try #require(workspace.beginFileTreeMove(from: destination, to: displaced))
            default: workspace.tabs[0].documentID = UUID()
            }
            await Task.yield()
            fixture.schedule.setEnabled(false); fixture.schedule.release(0)
            if conflict == "targetLock" {
                try #require(await waitForVisualJavaScript("window.__renamePrepared>=2 && window.__renameHolds.size===0", in: fixture.web))
                if case .failure(let error) = renamed { #expect(error is CancellationError) }
                else { Issue.record("Die Pfadsperre muss mit CancellationError abschließen") }
                #expect(undone == true && fixture.warnings.isEmpty)
            } else { try #require(await waitUntil { renamed != nil && undone != nil }) }
            #expect(renameCompletions == 1)
            if case .success = renamed { Issue.record("Konflikt wurde trotzdem umbenannt") }
            #expect(workspace.tabs[0].url == source)
            #expect(try Data(contentsOf: source) == (conflict == "source" ? foreign : original))
            if conflict.hasPrefix("source") { #expect(try Data(contentsOf: displaced) == original) }
            if conflict == "target" { #expect(try Data(contentsOf: destination) == foreign) }
            else if conflict == "danglingTarget" {
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == "unavailable.md")
            } else { #expect(!FileManager.default.fileExists(atPath: destination.path)) }
            #expect(!workspace.fileMutationIsInFlight(for: source))
            if conflict == "document" { workspace.tabs[0].documentID = originalDocumentID }
            workspace.activeTabID = originalActiveTabID
        }
    }

    @Test("Unbeteiligtes visuelles Bild-Undo verzögert den direkten Umbenennungsweg nicht")
    @MainActor
    func sidebarRenameWithoutAffectedVisualEditor() async throws {
        try await withVisualImageReferences { fixture in
            let source = try #require(fixture.other.activeTab?.url ?? fixture.other.tabs.first?.url)
            var undone: Bool?, renamed: Result<URL, Error>?
            _ = try await fixture.beginUndo(viaSynchronize: false) { undone = $0 }
            fixture.workspace.renameFileTreeItem(at: source, to: "renamed.md") { renamed = $0 }
            let destination = try #require(renamed).get()
            #expect(destination.lastPathComponent == "renamed.md" && undone == nil)
            #expect(try Data(contentsOf: destination) == Data("Version 0".utf8))
            #expect(fixture.workspace.activeTab?.url?.lastPathComponent == "note.md")
            fixture.schedule.setEnabled(false); fixture.schedule.release(0)
            try #require(await waitUntil { undone != nil })
            #expect(undone == true && fixture.warnings.isEmpty)
        }
    }
}

extension MarkdownVisualTests {
    @Test("Direkte Seitenleisten-Umbenennung schließt vorhandene Sperren genau einmal ab", arguments: ["registry", "hex"])
    @MainActor
    func sidebarRenameBlockedDirectCompletion(_ blocker: String) throws {
        let directory = testTemporaryDirectory().appendingPathComponent("sidebar-rename-blocked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("note.bin")
        let destination = directory.appendingPathComponent("renamed.bin")
        let bytes = Data([0x00, 0x01, 0x02, 0x03])
        try bytes.write(to: source)
        let workspace = Workspace()
        var tab = EditorTab(title: "note.bin", path: directory.path, url: source, displayMode: .hex)
        var operation: Workspace.FileTreeMoveOperation?
        defer { if let operation { workspace.finishFileTreeMove(operation) } }
        if blocker == "hex" {
            tab.hexEditSession.editRow("00 FE 02 03", data: bytes, baseOffset: 0, row: 0)
            let pendingSave = tab.hexEditSession.beginSave()
            _ = try #require(pendingSave)
        } else { operation = try #require(workspace.beginFileTreeMove(from: source, to: destination)) }
        workspace.tabs = [tab]; workspace.activeTabID = tab.id
        var conflicts = 0
        workspace.fileTreeMoveConflictHandler = { _ in conflicts += 1 }
        var outcomes: [Result<URL, Error>] = []
        workspace.renameFileTreeItem(at: source, to: "renamed.bin") { outcomes.append($0) }
        #expect(outcomes.count == 1 && conflicts == (blocker == "hex" ? 1 : 0))
        if case .failure(let error) = outcomes.first { #expect(error is CancellationError) }
        else { Issue.record("Vorhandene Sperre muss als abgebrochener Abschluss gemeldet werden") }
        #expect(try Data(contentsOf: source) == bytes)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(workspace.activeTab?.url == source)
    }
}


extension MarkdownVisualTests {
    @Test("Markdown-Endungswechsel bleibt beim direkten Seitenleistenweg")
    @MainActor
    func sidebarRenameExtensionChangeStaysDirect() async throws {
        try await withVisualImageReferences { fixture in
            let source = try #require(fixture.workspace.activeTab?.url)
            _ = try await fixture.web.evaluateJavaScript("window.__renamePrepareOriginal=fastraVisual.prepareAction;window.__renamePreparations=0;fastraVisual.prepareAction=function(...args){window.__renamePreparations++;return window.__renamePrepareOriginal.apply(this,args);};true;")
            var renamed: Result<URL, Error>?
            fixture.workspace.renameFileTreeItem(at: source, to: "renamed.markdown") { renamed = $0 }
            let destination = try #require(renamed).get()
            #expect(destination.lastPathComponent == "renamed.markdown")
            #expect(try await fixture.web.evaluateJavaScript("window.__renamePreparations") as? Int == 0)
            #expect(try Data(contentsOf: destination) == Data("Text\n".utf8))
            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(fixture.workspace.activeTab?.url?.canonicalFileURL == destination.canonicalFileURL)
            _ = try await fixture.web.evaluateJavaScript("fastraVisual.prepareAction=window.__renamePrepareOriginal;true;")
        }
    }

    @Test("Überschrift auf weich umgebrochener Zeile trennt sauber, sodass nachfolgendes Fett keine Zeilen verliert")
    @MainActor
    func headingSplitThenBoldPreservesFollowingLinesAndSaves() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("visual-split-bold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("protocol.md")
        try "".write(to: file, atomically: true, encoding: .utf8)
        let (workspace, coordinator, web, window) = try await editor("", documentURL: file)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        workspace.tabs[0].diskSnapshot = try FileSnapshot.readSnapshotOnly(from: file)
        var saveWarnings: [MarkdownVisualCoordinator.SaveCheck] = []
        workspace.markdownSaveWarningHandler = { saveWarnings.append($0) }

        _ = try await web.evaluateJavaScript("""
            (() => {
              const root = document.getElementById('fastra-visual');
              root.focus();
              const r = document.createRange();
              r.selectNodeContents(root.firstChild); r.collapse(true);
              getSelection().removeAllRanges(); getSelection().addRange(r);
              document.execCommand('insertText', false, 'Fehler');
              fastraVisual.command('hardBreak');
              document.execCommand('insertText', false, 'Fehler 1');
              fastraVisual.command('hardBreak');
              document.execCommand('insertText', false, '—');
              fastraVisual.command('hardBreak');
              document.execCommand('insertText', false, 'Bild 1a');
              document.execCommand('insertParagraph');
              document.execCommand('insertParagraph');
              document.execCommand('insertText', false, 'Fehler 2');
              function sel(t) {
                const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT); let n;
                while ((n = w.nextNode())) {
                  const i = n.data.indexOf(t);
                  if (i >= 0) {
                    const range = document.createRange();
                    range.setStart(n, i); range.setEnd(n, i + t.length);
                    getSelection().removeAllRanges(); getSelection().addRange(range);
                    return true;
                  }
                }
                return false;
              }
              sel('Fehler');
              fastraVisual.command('heading2');
              sel('Fehler 1');
              fastraVisual.command('bold');
              return true;
            })()
            """)

        let liveHTML = try #require(try await web.evaluateJavaScript("document.getElementById('fastra-visual').innerHTML") as? String)
        #expect(try await web.evaluateJavaScript("document.querySelector('#fastra-visual h2')?.textContent") as? String == "Fehler", Comment(rawValue: liveHTML))
        #expect(try await web.evaluateJavaScript("document.querySelector('#fastra-visual strong')?.textContent") as? String == "Fehler 1", Comment(rawValue: liveHTML))
        let visibleText = try #require(try await web.evaluateJavaScript("(() => { const c = document.getElementById('fastra-visual').cloneNode(true); c.querySelectorAll('[data-md-edit-boundary]').forEach(n => n.remove()); return c.textContent.replace(/[\\s\\u200b]+/g, ''); })()") as? String)
        #expect(visibleText == "FehlerFehler1—Bild1aFehler2", Comment(rawValue: liveHTML))

        // Undo macht genau den Fettdruck rückgängig, ohne Zeilen zu entfernen oder alles zu markieren.
        _ = try await web.evaluateJavaScript("document.execCommand('undo'); fastraVisual.flush();")
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#fastra-visual strong').length") as? Int == 0)
        let afterUndoText = try #require(try await web.evaluateJavaScript("(() => { const c = document.getElementById('fastra-visual').cloneNode(true); c.querySelectorAll('[data-md-edit-boundary]').forEach(n => n.remove()); return c.textContent.replace(/[\\s\\u200b]+/g, ''); })()") as? String)
        #expect(afterUndoText == "FehlerFehler1—Bild1aFehler2")

        // Erneut fett formatieren und regulär speichern + wiederöffnen.
        _ = try await web.evaluateJavaScript("""
            (() => {
              const root = document.getElementById('fastra-visual');
              const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT); let n;
              while ((n = w.nextNode())) {
                const i = n.data.indexOf('Fehler 1');
                if (i >= 0) {
                  const range = document.createRange();
                  range.setStart(n, i); range.setEnd(n, i + 'Fehler 1'.length);
                  getSelection().removeAllRanges(); getSelection().addRange(range);
                  fastraVisual.command('bold');
                  break;
                }
              }
            })()
            """)
        try #require(await waitUntil { workspace.activeTab?.content.contains("**Fehler 1**") == true })
        workspace.saveActiveTab()
        try #require(await waitUntil { !saveWarnings.isEmpty || workspace.activeTab?.isDirty == false })
        #expect(saveWarnings.isEmpty)
        let saved = try Data(contentsOf: file)
        let (_, freshCoordinator, freshWeb, freshWindow) = try await reopenEditor(at: file, savedBytes: saved)
        defer { freshWeb.configuration.userContentController.removeAllScriptMessageHandlers(); freshWindow.close(); withExtendedLifetime(freshCoordinator) {} }
        #expect(try await freshWeb.evaluateJavaScript("document.querySelector('#fastra-visual h2')?.textContent") as? String == "Fehler")
        #expect(try await freshWeb.evaluateJavaScript("document.querySelector('#fastra-visual strong')?.textContent") as? String == "Fehler 1")
        #expect(try await freshWeb.evaluateJavaScript("document.getElementById('fastra-visual').innerText.includes('Bild 1a')") as? Bool == true)
    }

    @Test("Block- und Inline-Formatierungen verhindern illegale Verschachtelung und Grenzverlust")
    @MainActor
    func blockAndInlineFormattingPreventIllegalNestingAndBoundaryLoss() async throws {
        let (_, coordinator, web, window) = try await editor("")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        let report = try #require(try await web.evaluateJavaScript("""
            (() => {
              const root = document.getElementById('fastra-visual');
              root.focus();
              const r0 = document.createRange(); r0.selectNodeContents(root.firstChild); r0.collapse(true);
              getSelection().removeAllRanges(); getSelection().addRange(r0);
              for (const line of ['Alpha', 'Beta', 'Gamma', 'Delta']) {
                document.execCommand('insertText', false, line);
                if (line !== 'Delta') document.execCommand('insertParagraph');
              }
              function sel(t) {
                const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT); let n;
                while ((n = w.nextNode())) {
                  const i = n.data.indexOf(t);
                  if (i >= 0) {
                    const range = document.createRange();
                    range.setStart(n, i); range.setEnd(n, i + t.length);
                    getSelection().removeAllRanges(); getSelection().addRange(range);
                    return true;
                  }
                }
                return false;
              }
              // 1. Liste im neuen Dokument: kein <p><ul>...</ul></p>
              sel('Alpha'); fastraVisual.command('bulletList');
              const illegalPList = !!root.querySelector('p ul, p ol');

              // 2. Überschrift auf Listeneintrag: kein <h1><ul>...</ul></h1>
              sel('Alpha'); fastraVisual.command('heading1');
              const illegalHList = !!root.querySelector('h1 ul, h2 ul, ul h1');

              // 3. Inline-Format über bestehende Edit-Boundary hinweg + Triple-Click bis Offset 0 des Folgeblocks
              sel('Beta'); fastraVisual.command('bold');
              const ps = Array.from(root.querySelectorAll('p:not([data-md-edit-boundary])'));
              const triple = document.createRange();
              triple.setStart(ps[0].firstChild, 0);
              triple.setEnd(ps[1], 0);
              getSelection().removeAllRanges(); getSelection().addRange(triple);
              fastraVisual.command('italic');

              // 4. WebKit-Inline-Style-Span in toMarkdown + leeres <p></p>
              const livePs = Array.from(root.querySelectorAll('p:not([data-md-edit-boundary])'));
              const targetP = livePs.at(-1);
              const span = document.createElement('span');
              span.style.fontWeight = 'bold';
              span.textContent = 'Styled';
              const emptyP = document.createElement('p');
              targetP.append(span);
              root.append(emptyP);
              fastraVisual.flush();
              const md = fastraVisual.markdown();
              const badBoundary = Array.from(root.querySelectorAll('[data-md-edit-boundary]'))
                .some(b => b.textContent !== '\\u200b' || b.childNodes.length !== 1 || b.firstChild.nodeType !== 3);
              return JSON.stringify({
                illegalPList, illegalHList, badBoundary,
                hasStyledBold: md.includes('**Styled**'),
                emptyRemoved: !/(?:^|\\n)  (?:\\n|$)/.test(md),
                text: root.cloneNode(true).textContent.replace(/[\\s\\u200b]+/g, '')
              });
            })()
            """) as? String)
        let data = try #require(report.data(using: .utf8))
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(parsed["illegalPList"] as? Bool == false, Comment(rawValue: report))
        #expect(parsed["illegalHList"] as? Bool == false, Comment(rawValue: report))
        #expect(parsed["badBoundary"] as? Bool == false, Comment(rawValue: report))
        #expect(parsed["hasStyledBold"] as? Bool == true, Comment(rawValue: report))
        #expect(parsed["emptyRemoved"] as? Bool == true, Comment(rawValue: report))
    }

    @Test("Deterministische Abfolge von 60 WYSIWYG-Bearbeitungen bewahrt Text, DOM-Grenzen und Speicherparität",
          arguments: [false, true])
    @MainActor
    func randomizedVisualFormatRoundtripInvariants(_ startFromMarkdown: Bool) async throws {
        let initial = startFromMarkdown
            ? "## Fehler\n\nFehler 1  \n—  \nBild 1a\n\n  \n\nFehler 2\n"
            : ""
        let (workspace, coordinator, web, window) = try await editor(initial)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }

        if !startFromMarkdown {
            _ = try await web.evaluateJavaScript("""
                (() => {
                  const root = document.getElementById('fastra-visual');
                  root.focus();
                  const r = document.createRange(); r.selectNodeContents(root.firstChild); r.collapse(true);
                  getSelection().removeAllRanges(); getSelection().addRange(r);
                  document.execCommand('insertText', false, 'Fehler');
                  fastraVisual.command('hardBreak');
                  document.execCommand('insertText', false, 'Fehler 1');
                  fastraVisual.command('hardBreak');
                  document.execCommand('insertText', false, '—');
                  document.execCommand('insertParagraph');
                  document.execCommand('insertParagraph');
                  document.execCommand('insertText', false, 'Bild 1a');
                  document.execCommand('insertParagraph');
                  document.execCommand('insertText', false, 'Fehler 2');
                })()
                """)
        }

        let initialText = try #require(try await web.evaluateJavaScript(
            "(() => { const c = document.getElementById('fastra-visual').cloneNode(true); c.querySelectorAll('[data-md-edit-boundary]').forEach(n => n.remove()); return c.textContent.replace(/[\\s\\u200b]+/g, ''); })()"
        ) as? String)
        let cmds = ["bold", "italic", "highlight", "heading1", "heading2", "heading3", "plainParagraph", "bulletList", "orderedList", "quote"]
        var seed: UInt32 = startFromMarkdown ? 4242 : 1337
        func next(_ n: Int) -> Int {
            seed = seed &* 1664525 &+ 1013904223
            return Int(seed % UInt32(n))
        }

        for step in 0..<60 {
            let cmd = cmds[next(cmds.count)]
            let selMode = next(4)
            let idxSeed = next(1000)
            let stepResult = try #require(try await web.evaluateJavaScript("""
                (() => {
                  const root = document.getElementById('fastra-visual');
                  const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
                  const texts = []; let n;
                  while ((n = w.nextNode())) {
                    if (!n.parentElement?.closest('[data-md-edit-boundary]') && n.data.replace(/\\u200b/g, '').length > 0) texts.push(n);
                  }
                  if (!texts.length) return JSON.stringify({ok:false, reason:'no-texts'});
                  const a = texts[\(idxSeed) % texts.length];
                  const r = document.createRange();
                  if (\(selMode) === 0) { r.setStart(a, 0); r.setEnd(a, a.length); }
                  else if (\(selMode) === 1 && a.parentElement) { r.selectNodeContents(a.parentElement); }
                  else if (\(selMode) === 2 && a.parentElement?.nextElementSibling) { r.setStart(a, 0); r.setEnd(a.parentElement.nextElementSibling, 0); }
                  else { r.setStart(a, 0); r.setEnd(a, Math.max(1, Math.min(a.length, 3))); }
                  getSelection().removeAllRanges(); getSelection().addRange(r);
                  fastraVisual.command('\(cmd)');
                  const clone = root.cloneNode(true);
                  clone.querySelectorAll('[data-md-edit-boundary]').forEach(b => b.remove());
                  const text = clone.textContent.replace(/[\\s\\u200b]+/g, '');
                  const badBoundary = Array.from(root.querySelectorAll('[data-md-edit-boundary]')).some(b => b.childNodes.length !== 1 || b.firstChild.nodeType !== 3 || b.textContent !== '\\u200b');
                  const illegalNesting = !!root.querySelector('p ul, p ol, h1 ul, h2 ul, h3 ul');
                  const state = fastraVisual.prepareAction();
                  fastraVisual.completeAction(state.session || undefined);
                  return JSON.stringify({ok:true, text, badBoundary, illegalNesting, markdown: state.markdown, revision: state.revision});
                })()
                """) as? String)
            let parsed = try #require(try JSONSerialization.jsonObject(with: Data(stepResult.utf8)) as? [String: Any])
            #expect(parsed["ok"] as? Bool == true, Comment(rawValue: "Step \(step): \(stepResult)"))
            #expect(parsed["text"] as? String == initialText, Comment(rawValue: "Step \(step) \(cmd): \(stepResult)"))
            #expect(parsed["badBoundary"] as? Bool == false, Comment(rawValue: "Step \(step) \(cmd)"))
            #expect(parsed["illegalNesting"] as? Bool == false, Comment(rawValue: "Step \(step) \(cmd)"))
            let md = try #require(parsed["markdown"] as? String)
            let rev = try #require(parsed["revision"] as? Int)
            let renderedHTML = MarkdownVisualDocument.render(md, documentURL: nil).fragment.html
            let sessionValue = try #require(try await web.evaluateJavaScript("fastraVisual.diagnosticReport(false).session") as? String)
            let appearance = try await web.callAsyncJavaScript(
                "return window.fastraVisual.inspectAppearance(session, revision, html);",
                arguments: ["session": sessionValue, "revision": rev, "html": renderedHTML],
                in: nil, contentWorld: .page
            ) as? [String: Any]
            #expect(appearance?["outcome"] as? String == "ok", Comment(rawValue: "Step \(step) \(cmd): \(String(describing: appearance)) | md=\(md)"))
            if step % 5 == 4 {
                _ = try await web.evaluateJavaScript("document.execCommand('undo'); fastraVisual.flush();")
            }
        }
        _ = workspace
    }

    @Test("Live-Prüfung erkennt Abweichungen ohne Eingabesperre und liefert anonymisiertes sowie vollständiges Protokoll")
    @MainActor
    func liveAppearanceCheckAndDiagnosticExport() async throws {
        let secret = "SECRET_DIAGNOSTIC_TOKEN_XYZ"
        let (workspace, coordinator, web, window) = try await editor("Hallo \(secret)\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
        coordinator.liveCheckDelay = 0.05

        // Zunächst saubere Live-Prüfung nach dem Öffnen.
        coordinator.scheduleLiveAppearanceCheck()
        try #require(await waitUntil(timeout: 5) { workspace.markdownVisualDiagnostics.lastCheckPassed == true })
        #expect(workspace.markdownVisualDiagnostics.activeWarning == nil)

        // Simulierte Verlust-Serialisierung löst die 50ms-Live-Prüfung aus, ohne die Eingabe zu sperren.
        _ = try await web.evaluateJavaScript("""
            (() => {
              const p = document.querySelector('#fastra-visual p'), r = document.createRange();
              r.selectNodeContents(p); getSelection().removeAllRanges(); getSelection().addRange(r);
              fastraVisual.command('highlight');
              const orig = fastraVisual.inspectAppearance;
              fastraVisual.inspectAppearance = (s, rev, html) => ({outcome:'format', diff:{test:true}, revision:rev, anomalies:[]});
              window.__origInspect = orig;
              document.execCommand('insertText', false, '!');
              fastraVisual.flush();
            })()
            """)
        try #require(await waitUntil(timeout: 5) { workspace.markdownVisualDiagnostics.activeWarning != nil })
        #expect(workspace.markdownVisualDiagnostics.showsBanner == true)
        #expect(try await web.evaluateJavaScript("document.getElementById('fastra-visual').isContentEditable") as? Bool == true)

        // Anonymisiertes Protokoll darf keinen Dokumentinhalt enthalten; vollständiges Protokoll enthält ihn.
        var redacted: String?
        var full: String?
        workspace.markdownVisualDiagnostics.resolveReport(includeContent: false, from: workspace) { redacted = $0 }
        workspace.markdownVisualDiagnostics.resolveReport(includeContent: true, from: workspace) { full = $0 }
        try #require(await waitUntil { redacted != nil && full != nil })
        #expect(redacted?.contains(secret) == false)
        #expect(redacted?.contains("domSkeleton") == true)
        #expect(full?.contains(secret) == true)

        // Nach Korrektur (Original-Prüfung wiederhergestellt) räumt die nächste Live-Prüfung die Warnung auf.
        _ = try await web.evaluateJavaScript("""
            (() => {
              if (window.__origInspect) fastraVisual.inspectAppearance = window.__origInspect;
              document.execCommand('insertText', false, '?');
              fastraVisual.flush();
            })()
            """)
        try #require(await waitUntil(timeout: 5) {
            workspace.markdownVisualDiagnostics.lastCheckPassed == true
                && workspace.markdownVisualDiagnostics.activeWarning == nil
        })
    }

    @Test("Vereinheitlichte Umbrüche erzeugen sauberes HTML-freies Markdown im Fließtext und bewahren Struktur-BRs")
    @MainActor
    func unifiedHardBreaksProduceHtmlFreeMarkdown() async throws {
        // 1. 1× Shift-Return am Absatzende -> zwei Leerzeichen als sichtbare Leerzeile ohne <br>
        do {
            let (workspace, coordinator, web, window) = try await editor("Alpha\n")
            defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
            let md = try #require(try await web.evaluateJavaScript("""
                (() => {
                  const root = document.getElementById('fastra-visual'), p = root.querySelector('p'), r = document.createRange();
                  r.setStart(p.firstChild, 5); r.collapse(true); root.focus();
                  getSelection().removeAllRanges(); getSelection().addRange(r);
                  root.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', shiftKey:true, bubbles:true, cancelable:true}));
                  fastraVisual.flush();
                  return fastraVisual.markdown();
                })()
                """) as? String)
            #expect(!md.contains("<br"), Comment(rawValue: md))
            #expect(md.contains("Alpha\n\n  "), Comment(rawValue: md))
            let renderedHTML = MarkdownVisualDocument.render(md, documentURL: nil).fragment.html
            let sessionValue = try #require(try await web.evaluateJavaScript("fastraVisual.diagnosticReport(false).session") as? String)
            let rev = try #require(try await web.evaluateJavaScript("fastraVisual.diagnosticReport(false).revision") as? Int)
            let check = try await web.callAsyncJavaScript(
                "return window.fastraVisual.inspectAppearance(session, revision, html);",
                arguments: ["session": sessionValue, "revision": rev, "html": renderedHTML],
                in: nil, contentWorld: .page
            ) as? [String: Any]
            #expect(check?["outcome"] as? String == "ok", Comment(rawValue: String(describing: check)))
            _ = workspace
        }

        // 2. 2× Shift-Return in Absatz & Zitat -> saubere Leerzeile ohne <br>, Undo + Speichern + Wiederöffnen
        for source in ["AlphaBeta\n", "> AlphaBeta\n"] {
            let directory = testTemporaryDirectory().appendingPathComponent("visual-unified-break-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("fixture.md")
            try source.write(to: file, atomically: true, encoding: .utf8)
            let (workspace, coordinator, web, window) = try await editor(source, documentURL: file)
            defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
            workspace.tabs[0].diskSnapshot = try FileSnapshot.readSnapshotOnly(from: file)
            var warnings: [MarkdownVisualCoordinator.SaveCheck] = []
            workspace.markdownSaveWarningHandler = { warnings.append($0) }

            _ = try await web.evaluateJavaScript("""
                (() => {
                  const root = document.getElementById('fastra-visual'), w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
                  let n; while ((n = w.nextNode())) { if (n.data.includes('AlphaBeta')) break; }
                  const r = document.createRange();
                  r.setStart(n, n.data.indexOf('AlphaBeta') + 5); r.collapse(true); root.focus();
                  getSelection().removeAllRanges(); getSelection().addRange(r);
                  root.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', shiftKey:true, bubbles:true, cancelable:true}));
                  root.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', shiftKey:true, bubbles:true, cancelable:true}));
                  fastraVisual.flush();
                })()
                """)
            let md = try #require(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String)
            #expect(!md.contains("<br"), Comment(rawValue: md))
            #expect(md.contains("Alpha") && md.contains("Beta"), Comment(rawValue: md))
            if source.hasPrefix("> ") {
                #expect(md.contains(">   "), Comment(rawValue: md))
            } else {
                #expect(md.contains("Alpha\n\n  \n\nBeta"), Comment(rawValue: md))
            }

            // Ein Undo stellt den einzelnen harten Umbruch vor der Leerzeile sauber her.
            _ = try await web.evaluateJavaScript("document.execCommand('undo'); fastraVisual.flush();")
            let afterUndo = try #require(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String)
            #expect(!afterUndo.contains("<br"), Comment(rawValue: afterUndo))
            #expect(afterUndo.contains("Alpha  \n") && afterUndo.contains("Beta"), Comment(rawValue: afterUndo))

            // Redo + echtes Speichern + Wiederöffnen
            _ = try await web.evaluateJavaScript("document.execCommand('redo'); fastraVisual.flush();")
            try #require(await waitUntil { workspace.activeTab?.isDirty == true })
            workspace.saveActiveTab()
            try #require(await waitUntil { !warnings.isEmpty || workspace.activeTab?.isDirty == false })
            #expect(warnings.isEmpty, Comment(rawValue: String(describing: warnings)))
            let saved = try Data(contentsOf: file)
            let savedText = String(decoding: saved, as: UTF8.self)
            #expect(!savedText.contains("<br"), Comment(rawValue: savedText))
            let (_, freshCoordinator, freshWeb, freshWindow) = try await reopenEditor(at: file, savedBytes: saved)
            defer { freshWeb.configuration.userContentController.removeAllScriptMessageHandlers(); freshWindow.close(); withExtendedLifetime(freshCoordinator) {} }
            #expect(try await freshWeb.evaluateJavaScript("document.querySelectorAll('#fastra-visual .fastra-visible-blank-line').length") as? Int == 1)
            if source.hasPrefix("> ") {
                #expect(try await freshWeb.evaluateJavaScript("document.querySelectorAll('#fastra-visual blockquote').length") as? Int == 1)
            }
        }

        // 3. Überschrift & Tabellenzelle behalten <br>; bestehendes <br><br> im Absatz bleibt erhalten.
        do {
            let (workspace, coordinator, web, window) = try await editor("# KopfZeile\n\nAlt<br><br>Neu\n\n| Spalte |\n| --- |\n| EinsZwei |\n")
            defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
            let md = try #require(try await web.evaluateJavaScript("""
                (() => {
                  const root = document.getElementById('fastra-visual');
                  function breakAt(token, offset) {
                    const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT); let n;
                    while ((n = w.nextNode())) {
                      const idx = n.data.indexOf(token);
                      if (idx >= 0) {
                        const r = document.createRange();
                        r.setStart(n, idx + offset); r.collapse(true); root.focus();
                        getSelection().removeAllRanges(); getSelection().addRange(r);
                        root.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', shiftKey:true, bubbles:true, cancelable:true}));
                        return true;
                      }
                    }
                    return false;
                  }
                  breakAt('KopfZeile', 4);
                  breakAt('EinsZwei', 4);
                  fastraVisual.flush();
                  return fastraVisual.markdown();
                })()
                """) as? String)
            #expect(md.contains("# Kopf<br>Zeile"), Comment(rawValue: md))
            #expect(md.contains("Alt<br><br>Neu"), Comment(rawValue: md))
            #expect(md.contains("| Eins<br>Zwei |"), Comment(rawValue: md))
            _ = workspace
        }

        // 4. Bestehendes A<br><br>|B sowie Inline-Grenzen (A<br><strong>|B</strong> + leeres <em>)
        do {
            let (workspace, coordinator, web, window) = try await editor("A<br><br>B\n")
            defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
            let md = try #require(try await web.evaluateJavaScript("""
                (() => {
                  const root = document.getElementById('fastra-visual'), p = root.querySelector('p');
                  const r = document.createRange();
                  const brs = p.querySelectorAll('br');
                  r.setStartAfter(brs[1]); r.collapse(true); root.focus();
                  getSelection().removeAllRanges(); getSelection().addRange(r);
                  root.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', shiftKey:true, bubbles:true, cancelable:true}));
                  fastraVisual.flush();
                  return fastraVisual.markdown();
                })()
                """) as? String)
            #expect(!md.contains("<br"), Comment(rawValue: md))
            let blankCount = md.components(separatedBy: "\n").filter { $0 == "  " }.count
            #expect(blankCount == 2, Comment(rawValue: md))
            _ = workspace
        }

        do {
            let (workspace, coordinator, web, window) = try await editor("Alpha\n")
            defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close(); withExtendedLifetime(coordinator) {} }
            let md = try #require(try await web.evaluateJavaScript("""
                (() => {
                  const root = document.getElementById('fastra-visual'), p = root.querySelector('p');
                  p.innerHTML = 'A<br><strong>B</strong>';
                  const strong = p.querySelector('strong'), r = document.createRange();
                  r.setStart(strong.firstChild, 0); r.collapse(true); root.focus();
                  getSelection().removeAllRanges(); getSelection().addRange(r);
                  root.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', shiftKey:true, bubbles:true, cancelable:true}));
                  const trailing = root.querySelector('p:not([data-md-edit-boundary])');
                  if (trailing && trailing.textContent === 'A') {
                    const extra = document.createElement('p');
                    extra.innerHTML = 'X<br><br><em></em>';
                    root.append(extra);
                  }
                  fastraVisual.flush();
                  return fastraVisual.markdown();
                })()
                """) as? String)
            #expect(!md.contains("<br"), Comment(rawValue: md))
            #expect(md.contains("A\n\n  \n\n**B**") || md.contains("A\n\n  \n\nB"), Comment(rawValue: md))
            _ = workspace
        }
    }
}
