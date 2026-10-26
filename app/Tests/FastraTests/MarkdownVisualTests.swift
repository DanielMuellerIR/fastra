import AppKit
import SwiftUI
import WebKit
import PDFKit
import Testing
@testable import Fastra

// Im Produkt besitzt das Dokumentfenster seinen Workspace. Der Coordinator
// hält ihn bewusst schwach; dieselbe Lebensdauer braucht die Renderer-Fixture.
private final class MarkdownVisualFixtureWindow: NSWindow {
    var retainedWorkspace: Workspace?

    override func close() {
        super.close()
        retainedWorkspace = nil
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
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved == workspace.activeTab?.content)
        let id = try #require(workspace.activeTabID)
        workspace.tabs.append(EditorTab(title: "anchor.txt", path: "", content: "Anker"))
        var closeConfirmationRequested = false
        workspace.confirmCloseHandler = { _ in closeConfirmationRequested = true; return .cancel }
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
        if !closed || Date().timeIntervalSince(closeStarted) >= 5 {
            print("FORMAT_CLOSE_DIAGNOSTIC \(closeDiagnostic)")
        }
        try #require(closed && !closeConfirmationRequested, Comment(rawValue: closeDiagnostic))
        web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close()
        let (reopenedWorkspace, reopened, fresh, freshWindow) = try await editor(try String(contentsOf: file, encoding: .utf8), documentURL: file)
        defer { fresh.configuration.userContentController.removeAllScriptMessageHandlers(); freshWindow.close(); withExtendedLifetime((reopenedWorkspace, reopened)) {} }
        reopened.updateStyle(fontName: PreviewFonts.systemName, fontSize: 14, darkMode: dark, style: "reopened")
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
        workspace.saveTabAs(id: workspace.activeTabID!, to: target, expectedTargetState: .absent, isMarkdown: true) { saved = $0 }
        try #require(await waitUntil { saved != nil })
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

    @MainActor
    private func editor(_ source: String, documentURL: URL? = nil) async throws -> (Workspace, MarkdownVisualCoordinator, MarkdownVisualWKWebView, NSWindow) {
        let workspace = Workspace()
        var tab = EditorTab(title: "fixture.md", path: "", content: source)
        tab.url = documentURL
        tab.markdownVisualOverride = true
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        let coordinator = MarkdownVisualCoordinator()
        coordinator.pasteboard = NSPasteboard.withUniqueName()
        coordinator.workspace = workspace
        coordinator.tabID = tab.id
        workspace.visualMarkdownEditor = coordinator
        let web = MarkdownVisualWebView.makeWebView(coordinator: coordinator)
        web.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        let window = MarkdownVisualFixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.retainedWorkspace = workspace
        window.isReleasedWhenClosed = false
        window.contentView = web
        var error: String?
        workspace.saveSafetyWarningHandler = { title, text in error = title + text }
        coordinator.load(source, documentURL: documentURL, fontName: PreviewFonts.systemName,
                         fontSize: 14, darkMode: false, style: "test")
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
            [{},{shiftKey:true,metaKey:true},{shiftKey:true,altKey:true},{shiftKey:true,ctrlKey:true},{shiftKey:true,isComposing:true}]
            .every(flags=>document.getElementById('fastra-visual').dispatchEvent(new KeyboardEvent('keydown',
              {key:'Enter',bubbles:true,cancelable:true,...flags})))
            """) as? Bool
        #expect(allowed == true)
        #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
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
        defer { held.forEach { $0.completeAction() } }
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

    @Test("Gemischte Clipboard-Inhalte behalten alle Auszeichnungen nach Einfügen, Undo und erneutem Öffnen", arguments: [[false, false], [true, false], [false, true], [true, true]])
    @MainActor
    func copyPasteDocumentStyles(_ scenario: [Bool]) async throws {
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
        let (target, receiver, targetWeb, targetWindow) = try await editor("Ziel\n")
        defer { targetWeb.configuration.userContentController.removeAllScriptMessageHandlers(); targetWindow.close(); withExtendedLifetime(receiver) {} }
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
        receiver.load(pasted, documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "reload")
        // WebKits erneuter Start braucht dieselbe Frist wie das erste Öffnen.
        let reloaded = await waitUntil(timeout: 12) { receiver.ready }
        if !reloaded {
            print("MARKDOWN_RELOAD_DIAGNOSTIC cut=\(cut) htmlOnly=\(htmlOnly) loading=\(targetWeb.isLoading) progress=\(targetWeb.estimatedProgress) generation=\(receiver.generation) ownerPresent=\(receiver.workspace != nil) activeTabMatches=\(receiver.tabID == target.activeTabID) sourceMatches=\(receiver.markdown == pasted)")
        }
        try #require(reloaded)
        #expect(try await targetWeb.evaluateJavaScript("JSON.stringify(" + snapshot + ")") as? String == expected, Comment(rawValue: pasted))
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
            fastraVisual.prepareAction=()=>new Promise(resolve=>{window.releasePrepare=()=>resolve(prepare());});
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
            fastraVisual.prepareAction=()=>new Promise(resolve=>{window.releasePrepare=()=>resolve(prepare());});
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
            workspace.visibleBufferResultsOptions = workspace.currentSearchOptions
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
            fastraVisual.prepareAction=()=>new Promise(resolve=>{window.releasePrepare=()=>resolve(prepare());});
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
        let source = "# A\n\n- \n\n# B\n\n1. \n\n# C\n\n- [ ] \n"
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
        _ = try await web.evaluateJavaScript("{const r=document.createRange();r.selectNodeContents(document.getElementById('fastra-visual'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);}")
        #expect(coordinator.pasteImages())
        try #require(await waitUntil { workspace.activeTab?.content != source })
        #expect(MarkdownRichText.htmlFragment(markdown: workspace.activeTab!.content).components(separatedBy: "<li").count == 7)
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


}
