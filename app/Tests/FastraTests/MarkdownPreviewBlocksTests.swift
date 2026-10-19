import AppKit
import WebKit
import Testing
@testable import Fastra

@Suite("Blockweise Markdown-Vorschau", .serialized)
@MainActor
struct MarkdownPreviewBlocksTests {
    @Test("Einfügen und Verschieben erhalten DOM, Auswahl, Codeknopf und aktuelle Quellzeilen")
    func identityAndSelection() async throws {
        let source = "# Titel\n\nAlpha unverändert.\n\nBeta unverändert.\n\n```swift\nlet value = 1\n```\n"
        let fixture = try await Fixture(source)
        defer { fixture.close() }
        _ = try await fixture.web.evaluateJavaScript("""
            window.alpha=document.querySelectorAll('p')[0];window.beta=document.querySelectorAll('p')[1];
            window.code=document.querySelector('pre');window.copyButton=document.querySelector('.fastra-code-copy');
            getSelection().setBaseAndExtent(alpha.firstChild,2,beta.firstChild,4);
            window.selected=getSelection().toString();
            """)
        let edited = "# Neuer Vorspann\n\n# Titel\n\nBeta unverändert.\n\nAlpha unverändert.\n\n```swift\nlet value = 1\n```\n"
        _ = try await fixture.update(edited)
        #expect(try await fixture.web.evaluateJavaScript("document.querySelectorAll('p')[0]===beta && document.querySelectorAll('p')[1]===alpha && document.querySelector('pre')===code && document.querySelector('.fastra-code-copy')===copyButton") as? Bool == true)
        #expect(try await fixture.web.evaluateJavaScript("getSelection().anchorNode===alpha.firstChild && getSelection().anchorOffset===2 && getSelection().focusNode===beta.firstChild && getSelection().focusOffset===4") as? Bool == true)
        #expect(try await fixture.web.evaluateJavaScript("document.querySelector('pre').getAttribute('data-srcline')") as? String == "10")
        #expect(try await fixture.web.evaluateJavaScript("document.querySelectorAll('.fastra-code-copy').length") as? Int == 1)
    }

    @Test("Referenzänderungen aktualisieren alle abhängigen Blöcke; Formeln und Diagramme bleiben sonst erhalten")
    func dependenciesAndEnhancements() async throws {
        let source = "# Titel\n\n[Erster][ziel]\n\n[Zweiter][ziel]\n\n$$x^2$$\n\n```mermaid\ngraph TD; A-->B;\n```\n\n[ziel]: lokal-alt.md\n"
        let fixture = try await Fixture(source)
        defer { fixture.close() }
        _ = try await fixture.web.evaluateJavaScript("window.math=document.querySelector('math');window.diagram=document.querySelector('.mermaid-render');window.heading=document.querySelector('h1');void 0;")
        let edited = "Ein neuer Absatz.\n\n" + source.replacingOccurrences(of: "lokal-alt.md", with: "lokal-neu.md")
        _ = try await fixture.update(edited)
        #expect(try await fixture.web.evaluateJavaScript("Array.from(document.querySelectorAll('a'),node=>node.getAttribute('href'))") as? [String] == ["lokal-neu.md", "lokal-neu.md"])
        #expect(try await fixture.web.evaluateJavaScript("document.querySelector('math')===math && document.querySelector('.mermaid-render')===diagram && document.querySelector('h1')===heading") as? Bool == true)
        #expect(try await fixture.web.evaluateJavaScript("document.querySelector('.mermaid-render').getAttribute('data-srcline')") as? String == "12")
        #expect(try await fixture.web.evaluateJavaScript("document.querySelector('.mermaid-render svg') !== null") as? Bool == true)
    }

    @Test("Verschobene Listen- und Tabellenblöcke erhalten sämtliche verschachtelten Quellpositionen")
    func nestedPositions() async throws {
        let source = "# Anfang\n\n- Eins\n  - Zwei\n\n| A | B |\n| --- | --- |\n| X | Y |\n\nAbsatz.\n"
        let fixture = try await Fixture(source)
        defer { fixture.close() }
        _ = try await fixture.web.evaluateJavaScript("window.list=document.querySelector('ul');window.table=document.querySelector('table');void 0;")
        let edited = "Vorspann\n\n" + source
        _ = try await fixture.update(edited)
        #expect(try await fixture.web.evaluateJavaScript("list===document.querySelector('ul') && table===document.querySelector('table')") as? Bool == true)
        let expected = MarkdownRichText.htmlFragment(markdown: edited)
        let positions = try await fixture.web.callAsyncJavaScript("const t=document.createElement('template');t.innerHTML=html;return Array.from(t.content.querySelectorAll('[data-srcline]'),node=>node.getAttribute('data-srcline'));", arguments: ["html": expected], in: nil, contentWorld: .page) as? [String]
        #expect(try await fixture.web.evaluateJavaScript("Array.from(document.querySelectorAll('[data-srcline]'),node=>node.getAttribute('data-srcline'))") as? [String] == positions)
    }

    @Test("Lokale Änderungen vor dem sichtbaren Absatz erhalten dessen Bildschirmposition")
    func scrollAnchor() async throws {
        let source = (0..<160).map { "Absatz \($0): " + String(repeating: "Lesbarer Text. ", count: 8) }.joined(separator: "\n\n")
        let fixture = try await Fixture(source)
        defer { fixture.close() }
        _ = try await fixture.web.evaluateJavaScript("window.anchor=document.querySelectorAll('p')[90];anchor.scrollIntoView();window.anchorTop=anchor.getBoundingClientRect().top;")
        try #require(try await fixture.web.evaluateJavaScript("scrollY > 0") as? Bool == true)
        _ = try await fixture.update("# Neu\n\nEin zusätzlicher Absatz.\n\n" + source)
        #expect(try await fixture.web.evaluateJavaScript("anchor.isConnected && Math.abs(anchor.getBoundingClientRect().top-anchorTop)<1") as? Bool == true)
    }

    @Test("Entfernen, lokale Bearbeitung und leere Vorschau behalten weder alte Blöcke noch Diagramme")
    func deletionAndLocalEdit() async throws {
        let fixture = try await Fixture("# A\n\nAbsatz B\n\nAbsatz C\n")
        defer { fixture.close() }
        _ = try await fixture.web.evaluateJavaScript("window.before=fastraPreviewBlocks.identities().filter(x=>x.tag==='P').map(x=>x.id);")
        _ = try await fixture.update("# A\n\nAbsatz geändert\n\nAbsatz C\n")
        #expect(try await fixture.web.evaluateJavaScript("fastraPreviewBlocks.identities().filter(x=>x.tag==='P').map(x=>x.id).every((id,index)=>id===before[index])") as? Bool == true)
        _ = try await fixture.update("Absatz C\n")
        #expect(try await fixture.web.evaluateJavaScript("document.querySelectorAll('h1').length===0 && document.querySelectorAll('p').length===1") as? Bool == true)
        _ = try await fixture.update("")
        #expect(try await fixture.web.evaluateJavaScript("fastraPreviewBlocks.identities().length===0 && document.querySelectorAll('p').length===0") as? Bool == true)
    }

    @Test("Eine Auswahl des gesamten Vorschau-Dokuments behält seine Dokumentgrenzen")
    func wholeDocumentSelection() async throws {
        let fixture = try await Fixture("# A\n\nAbsatz B\n")
        defer { fixture.close() }
        _ = try await fixture.web.evaluateJavaScript("getSelection().selectAllChildren(document.body);")
        _ = try await fixture.update("# Neu\n\n# A\n\nAbsatz B\n\nZusatz C\n")
        #expect(try await fixture.web.evaluateJavaScript("getSelection().toString().includes('Neu') && getSelection().toString().includes('Zusatz C')") as? Bool == true)
    }

    @Test("Ausgewählter unveränderter Text bleibt nach einer Bearbeitung im selben Absatz mit Formel ausgewählt")
    func selectionWithinChangedBlock() async throws {
        let fixture = try await Fixture("Vorher $x^2$ weiterhin ausgewählt.\n")
        defer { fixture.close() }
        _ = try await fixture.web.evaluateJavaScript("""
            {const walker=document.createTreeWalker(document.querySelector('p'),NodeFilter.SHOW_TEXT);
            let text;while(text=walker.nextNode()){const start=text.data.indexOf('ausgewählt');
            if(start>=0){getSelection().setBaseAndExtent(text,start,text,start+'ausgewählt'.length);break;}}}
            """)
        #expect(try await fixture.web.evaluateJavaScript("getSelection().toString()") as? String == "ausgewählt")
        _ = try await fixture.update("Ein neuer Vorspann $x^2$ weiterhin ausgewählt.\n")
        #expect(try await fixture.web.evaluateJavaScript("getSelection().toString()") as? String == "ausgewählt")
    }

    @Test("Ein fokussierter Codeknopf folgt seinem bearbeiteten Block")
    func focusAfterCodeEdit() async throws {
        let fixture = try await Fixture("Vorher.\n\n```swift\nlet value = 1\n```\n")
        defer { fixture.close() }
        _ = try await fixture.web.evaluateJavaScript("document.querySelector('.fastra-code-copy').focus();")
        _ = try await fixture.update("Vorher.\n\n```swift\nlet value = 2\n```\n")
        #expect(try await fixture.web.evaluateJavaScript("document.activeElement===document.querySelector('.fastra-code-copy') && document.querySelector('code').textContent.includes('2')") as? Bool == true)
    }

    @Test("Ein fremder vollständiger DOM-Neuaufbau entwertet die alten Blockobjekte")
    func invalidatedBody() async throws {
        let fixture = try await Fixture("# Alt\n\nAbsatz\n")
        defer { fixture.close() }
        _ = try await fixture.web.evaluateJavaScript("document.body.innerHTML='<p>Zwischenstand</p>';void 0;")
        _ = try await fixture.update("# Neu\n\nKorrekte Quelle\n")
        #expect(try await fixture.web.evaluateJavaScript("document.querySelector('h1').textContent==='Neu' && document.querySelector('p').textContent==='Korrekte Quelle'") as? Bool == true)
        _ = try await fixture.update("# Neu\n\nNächste Quelle\n")
        #expect(try await fixture.web.evaluateJavaScript("document.querySelector('p').textContent==='Nächste Quelle'") as? Bool == true)
    }

    @Test("Späte Diagrammantworten stellen weder alte Inhalte noch einen alten Scrollstand wieder her")
    func lateDiagramWork() async throws {
        let fixture = try await Fixture("# Start\n\nAbsatz\n")
        defer { fixture.close() }
        _ = try await fixture.web.evaluateJavaScript("window.releases=[];mermaid.run=({nodes})=>new Promise(resolve=>releases.push(()=>{nodes[0].innerHTML='<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>';resolve();}));void 0;")
        for (name, source) in [("first", "```mermaid\ngraph TD; A-->B;\n```\n"), ("second", "```mermaid\ngraph TD; B-->C;\n```\n")] {
            let html = MarkdownRichText.htmlFragment(markdown: source)
            _ = try await fixture.web.callAsyncJavaScript("window[name]=fastraPreviewBlocks.update(html);return true;", arguments: ["name": name, "html": html], in: nil, contentWorld: .page)
        }
        _ = try await fixture.update("# Endstand\n\nNur dieser Text bleibt.\n")
        _ = try await fixture.web.callAsyncJavaScript("releases.forEach(release=>release());await Promise.all([first,second]);return true;", arguments: [:], in: nil, contentWorld: .page)
        #expect(try await fixture.web.evaluateJavaScript("document.querySelectorAll('.mermaid-render,pre').length===0 && document.querySelector('h1').textContent==='Endstand' && diagramSources.size===0") as? Bool == true)
    }

    @Test("Geänderte Bildreferenzen ersetzen das Bild und erhalten unabhängige Blöcke")
    func localImageReference() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII="))
        try bytes.write(to: directory.appendingPathComponent("a.png"))
        try bytes.write(to: directory.appendingPathComponent("b.png"))
        let source = "# Titel\n\n![Bild][foto]\n\n[foto]: a.png\n"
        let fixture = try await Fixture(source, documentURL: directory.appendingPathComponent("Dokument.md"))
        defer { fixture.close() }
        _ = try await fixture.web.evaluateJavaScript("window.image=document.querySelector('img');window.heading=document.querySelector('h1');void 0;")
        _ = try await fixture.update(source.replacingOccurrences(of: "a.png", with: "b.png"))
        #expect(try await fixture.web.evaluateJavaScript("document.querySelector('img')!==image && document.querySelector('h1')===heading && document.querySelector('img').src!==image.src") as? Bool == true)
    }

    @Test("Ein unverändertes laufendes Diagramm wird beim Bearbeiten eines anderen Blocks nicht neu gestartet")
    func inFlightDiagramIdentity() async throws {
        let fixture = try await Fixture("# Start\n\nAbsatz\n")
        defer { fixture.close() }
        _ = try await fixture.web.evaluateJavaScript("window.releases=[];mermaid.run=({nodes})=>new Promise(resolve=>releases.push(()=>{nodes[0].innerHTML='<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>';resolve();}));void 0;")
        let source = "Absatz\n\n```mermaid\ngraph TD; A-->B;\n```\n"
        _ = try await fixture.web.callAsyncJavaScript("window.first=fastraPreviewBlocks.update(html);window.pendingDiagram=document.querySelector('.mermaid-render');return true;", arguments: ["html": MarkdownRichText.htmlFragment(markdown: source)], in: nil, contentWorld: .page)
        _ = try await fixture.web.callAsyncJavaScript("window.second=fastraPreviewBlocks.update(html);return true;", arguments: ["html": MarkdownRichText.htmlFragment(markdown: "# Neu\n\n" + source)], in: nil, contentWorld: .page)
        let retained = try await fixture.web.evaluateJavaScript("releases.length===1 && pendingDiagram===document.querySelector('.mermaid-render') && pendingDiagram.getAttribute('data-srcline')==='6'") as? Bool
        _ = try await fixture.web.callAsyncJavaScript("releases.forEach(release=>release());await Promise.all([first,second]);return true;", arguments: [:], in: nil, contentWorld: .page)
        #expect(retained == true)
        #expect(try await fixture.web.evaluateJavaScript("pendingDiagram===document.querySelector('.mermaid-render') && pendingDiagram.querySelector('svg')!==null && document.querySelectorAll('pre').length===0") as? Bool == true)
    }

    @Test("Parserportionen erhalten mehrbyteige Zeichen und CRLF an der Bytegrenze")
    func parserChunkBoundaries() {
        let text = String(repeating: "a", count: 65_535) + "ä🙂\r\n終\n"
        let fragment = MarkdownRichText.renderedFragment(markdown: text, documentURL: nil)
        #expect(fragment.html.contains("ä🙂\n終"))
        #expect(!fragment.html.contains("\u{fffd}"))
        #expect(fragment.html.contains("data-srcline=\"1\""))
    }

    @Test("Abbruch verwirft auch eine bereits an Main zugestellte Renderantwort")
    func renderCancellation() async throws {
        let coalescer = MarkdownRenderCoalescer()
        var responses = [String]()
        coalescer.render(markdown: "Alt", documentURL: nil) { responses.append($0.html) }
        coalescer.cancel()
        coalescer.render(markdown: "Neu", documentURL: nil) { responses.append($0.html) }
        try #require(await waitUntil { !responses.isEmpty })
        #expect(responses.count == 1)
        #expect(responses[0].contains("Neu"))
        let cancelled = MarkdownRichText.renderQueue.sync {
            MarkdownRichText.renderFragmentOnQueue(markdown: String(repeating: "Alt\n", count: 100_000), documentURL: nil, isCancelled: { true })
        }
        #expect(cancelled.html.isEmpty)
    }

    @MainActor
    private final class Fixture {
        let web: WKWebView
        let window: NSWindow
        let assets: MarkdownPreviewSchemeHandler
        let documentURL: URL?
        init(_ source: String, documentURL: URL? = nil) async throws {
            _ = NSApplication.shared
            self.documentURL = documentURL
            assets = MarkdownPreviewSchemeHandler()
            let fragment = MarkdownRichText.renderedFragment(markdown: source, documentURL: documentURL)
            assets.setImageURLs(fragment.imageURLs)
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.setURLSchemeHandler(assets, forURLScheme: MarkdownPreviewAssets.scheme)
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 850, height: 500), configuration: configuration)
            window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = web
            web.loadHTMLString(MarkdownRichText.htmlDocument(fragment: fragment, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false), baseURL: nil)
            var ready = false
            for _ in 0..<240 {
                ready = (try? await web.evaluateJavaScript("document.documentElement.getAttribute('data-fastra-enhanced')==='1' && !!window.fastraPreviewBlocks && !!document.querySelector('#fastra-code-controls') && (!document.querySelector('pre > code:not(.language-mermaid)') || !!document.querySelector('.fastra-code-copy'))")) as? Bool == true
                if ready { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            try #require(ready, "Gebündelte Vorschau wurde nicht bereit")
        }
        func update(_ source: String) async throws -> Any? {
            let fragment = MarkdownRichText.renderedFragment(markdown: source, documentURL: documentURL)
            assets.setImageURLs(fragment.imageURLs)
            return try await web.callAsyncJavaScript("return await fastraPreviewBlocks.update(html);", arguments: ["html": fragment.html], in: nil, contentWorld: .page)
        }
        func close() { web.stopLoading(); window.close() }
    }
}
