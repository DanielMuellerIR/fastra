import AppKit
import WebKit
import Testing
@testable import Fastra

@Suite("Markdown-Lesespalte und Codekopie", .serialized)
@MainActor
struct MarkdownPresentationTests {
    private let code = "let text = \"ä🙂 <&>\"\n  \n"
    private var source: String {
        let headings = (0..<10).map { "Spalte \($0)" }.joined(separator: " | ")
        let separators = Array(repeating: "---", count: 10).joined(separator: " | ")
        let cells = Array(repeating: String(repeating: "W", count: 40), count: 10).joined(separator: " | ")
        return "# Lesespalte\n\n" + String(repeating: "Langer Absatz mit lesbarem Text. ", count: 24)
            + "\n\n| \(headings) |\n| \(separators) |\n| \(cells) |\n\n```swift\n\(code)```\n"
    }

    @Test("Breite Tabellen verlassen die Lesespalte; Kopieren verändert weder Quelle noch Undo", arguments: [false, true])
    func layoutAndCopy(_ visual: Bool) async throws {
        let fixture = try await Fixture(source: source, visual: visual)
        defer { fixture.close() }
        let web = fixture.web
        let metrics = try #require(try await web.evaluateJavaScript("""
            (() => { const p=document.querySelector('p'),t=document.querySelector('table'),c=document.querySelector('code');
              return [p.getBoundingClientRect().width,t.getBoundingClientRect().width,t.scrollWidth,t.clientWidth,
                document.documentElement.scrollWidth,innerWidth,
                document.getElementById('fastra-visual')?.contains(document.querySelector('.fastra-code-copy')) ? 1 : 0,
                document.querySelector('h1').getBoundingClientRect().left,p.getBoundingClientRect().left]; })()
            """) as? [Double])
        #expect(metrics[0] < 800)
        #expect(metrics[1] > metrics[0] + 100)
        #expect(metrics[2] > metrics[3] + 100)
        #expect(metrics[4] <= metrics[5] + 1)
        #expect(metrics[6] == 0)
        #expect(abs(metrics[7] - metrics[8]) <= 1)
        _ = try await web.evaluateJavaScript("document.querySelector('.fastra-code-copy').click();")
        try #require(await waitUntil { fixture.pasteboard.string(forType: .string) == code })
        #expect(fixture.pasteboard.types?.contains(.string) == true)
        #expect(fixture.pasteboard.types?.allSatisfy { $0 == .string || $0.rawValue == "NSStringPboardType" } == true)
        if visual {
            fixture.coordinator?.updateStyle(fontName: PreviewFonts.systemName, fontSize: 16, darkMode: true, style: "dark")
            var aligned = false
            for _ in 0..<120 {
                aligned = (try await web.evaluateJavaScript("(() => {const p=document.querySelector('pre').getBoundingClientRect(),b=document.querySelector('.fastra-code-copy').getBoundingClientRect();return Math.abs(b.top-p.top-8)<1;})()")) as? Bool == true
                if aligned { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(aligned, "Schriftgrößenwechsel muss den Knopf am Codeblock halten")
            #expect(try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.fastra-code-copy')).backgroundColor") as? String == "rgb(51, 51, 51)")
            #expect(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String == source)
            _ = try await web.evaluateJavaScript("""
                const p=document.querySelector('p'),r=document.createRange();r.selectNodeContents(p);r.collapse(false);
                getSelection().removeAllRanges();getSelection().addRange(r);document.execCommand('insertText',false,'Z');fastraVisual.flush();
                """)
            try #require(await waitUntil { fixture.workspace?.activeTab?.content != source })
            _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
            try #require(await waitUntil { fixture.workspace?.activeTab?.content.utf8.elementsEqual(source.utf8) == true })
        }
    }

    @Test("Live-Vorschau baut Knöpfe nach Body-Tausch für den neuen Code erneut auf")
    func previewReplacement() async throws {
        let fixture = try await Fixture(source: source, visual: false)
        defer { fixture.close() }
        let replacement = MarkdownRichText.htmlFragment(markdown: "```text\nErster Block\n```\n\n```text\nNeuer Code 🙂\n```\n")
        let _: Any = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            fixture.web.callAsyncJavaScript("document.body.innerHTML=html; await fastraEnhanceMarkdown(document.body);",
                                           arguments: ["html": replacement], in: nil, in: .page) { continuation.resume(with: $0) }
        }
        try await fixture.ready()
        _ = try await fixture.web.evaluateJavaScript("document.querySelectorAll('.fastra-code-copy')[1].click();")
        try #require(await waitUntil { fixture.pasteboard.string(forType: .string) == "Neuer Code 🙂\n" })
        #expect(try await fixture.web.evaluateJavaScript("document.querySelectorAll('.fastra-code-copy').length") as? Int == 2)
    }

    @Test("Vorschau behält nach wiederholtem Body-Tausch nur aktuelle Diagrammquellen")
    func previewDiagramCache() async throws {
        let fixture = try await Fixture(source: source, visual: false)
        defer { fixture.close() }
        let result: Any = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            fixture.web.callAsyncJavaScript("""
                window.mermaid={initialize(){},run:async({nodes})=>nodes.forEach(n=>n.innerHTML='<svg><text>rendered</text></svg>'),
                  render:async(id,source)=>({svg:'<svg><text>'+source+'</text></svg>'})};
                for(let i=0;i<12;i++) {
                  document.body.innerHTML='<pre><code class="language-mermaid">graph LR\\nA--&gt;B'+i+'</code></pre>';
                  await fastraEnhanceMarkdown(document.body);
                }
                await fastraUpdateMarkdownTheme(document.body,true);
                return [diagramSources.size,document.querySelectorAll('.mermaid-render').length,
                  document.body.textContent.includes('B11')?1:0];
                """, arguments: [:], in: nil, in: .page) { continuation.resume(with: $0) }
        }
        let metrics = try #require(result as? [Int])
        #expect(metrics[0] == metrics[1])
        #expect(metrics[2] == 1, "Themewechsel verwendet die aktuelle Diagrammquelle")
    }


    @Test("Verdeckte Referenzen bleiben bei Blockänderung, Löschung und Undo exakt erhalten", arguments: ["\n", "\r\n", "\r"])
    func hiddenReferencesAndUndo(_ eol: String) async throws {
        let definitions = ["[alpha]: https://example.com/alpha", "[beta]: https://example.com/beta", "[gamma]: https://example.com/gamma", "[omega]: https://example.com/omega", "[end]: https://example.com/end"]
        let source = "\(definitions[0])\(eol)\(eol)# Titel\(eol)\(eol)Unverändert e\u{301} 🙂\(eol)\(eol)"
            + "\(definitions[1])\(eol)\(definitions[2])\(eol)\(eol)Bearbeiten [alpha] und [beta].\(eol)\(eol)"
            + "\(definitions[3])\(eol)\(eol)```text\(eol)Code\(eol)```\(eol)\(eol)\(definitions[4])\(eol)"
        let fixture = try await Fixture(source: source, visual: true)
        defer { fixture.close() }
        let web = fixture.web
        #expect((try await web.evaluateJavaScript("fastraVisual.markdown()") as? String)?.utf8.elementsEqual(source.utf8) == true)
        _ = try await web.evaluateJavaScript("""
            (()=>{const p=Array.from(document.querySelectorAll('#fastra-visual p')).find(p=>p.textContent.startsWith('Bearbeiten')),r=document.createRange();
              r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);
              document.execCommand('insertText',false,'X');fastraVisual.flush();})()
            """)
        try #require(await waitUntil { fixture.workspace?.activeTab?.content != source })
        let changed = try #require(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String)
        for definition in definitions { #expect(changed.components(separatedBy: definition).count == 2) }
        #expect(changed.contains("Unverändert e\u{301} 🙂" + eol + eol))
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { fixture.workspace?.activeTab?.content.utf8.elementsEqual(source.utf8) == true })
        _ = try await web.evaluateJavaScript("""
            (()=>{const p=Array.from(document.querySelectorAll('#fastra-visual p')).find(p=>p.textContent.startsWith('Bearbeiten')),r=document.createRange();
              r.selectNode(p);getSelection().removeAllRanges();getSelection().addRange(r);
              document.execCommand('delete');fastraVisual.flush();})()
            """)
        try #require(await waitUntil { fixture.workspace?.activeTab?.content != source })
        let removed = try #require(try await web.evaluateJavaScript("fastraVisual.markdown()") as? String)
        #expect(!removed.contains("Bearbeiten"))
        for definition in definitions { #expect(removed.components(separatedBy: definition).count == 2) }
        #expect(removed.contains("Unverändert e\u{301} 🙂" + eol + eol))
        _ = try await web.evaluateJavaScript("document.execCommand('undo');fastraVisual.flush();")
        try #require(await waitUntil { fixture.workspace?.activeTab?.content.utf8.elementsEqual(source.utf8) == true })
    }

    @MainActor
    private final class CopyHandler: NSObject, WKScriptMessageHandler {
        let pasteboard = NSPasteboard.withUniqueName()
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let payload = message.body as? [String: Any] else { return }
            MarkdownPresentation.copyCode(payload, in: message.webView, pasteboard: pasteboard)
        }
    }

    @MainActor
    private final class Fixture {
        let web: WKWebView
        let window: NSWindow
        let pasteboard: NSPasteboard
        var workspace: Workspace?
        var coordinator: MarkdownVisualCoordinator?
        private var handler: CopyHandler?

        init(source: String, visual: Bool) async throws {
            if visual {
                let workspace = Workspace(), coordinator = MarkdownVisualCoordinator()
                let tab = EditorTab(title: "fixture.md", path: "", content: source)
                workspace.tabs = [tab]; workspace.activeTabID = tab.id
                coordinator.workspace = workspace; coordinator.tabID = tab.id
                coordinator.pasteboard = .withUniqueName()
                workspace.visualMarkdownEditor = coordinator
                self.workspace = workspace; self.coordinator = coordinator
                pasteboard = coordinator.pasteboard
                web = MarkdownVisualWebView.makeWebView(coordinator: coordinator)
            } else {
                let handler = CopyHandler(), config = WKWebViewConfiguration()
                config.websiteDataStore = .nonPersistent()
                config.setURLSchemeHandler(MarkdownPreviewSchemeHandler(), forURLScheme: MarkdownPreviewAssets.scheme)
                config.userContentController.add(handler, name: "markdownCodeCopy")
                self.handler = handler; pasteboard = handler.pasteboard
                web = WKWebView(frame: .zero, configuration: config)
            }
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; web.frame = window.contentView!.bounds
            window.contentView = web
            if let coordinator {
                coordinator.load(source, documentURL: nil, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false, style: "test")
            } else {
                web.loadHTMLString(MarkdownRichText.htmlDocument(markdown: source, fontName: PreviewFonts.systemName, fontSize: 14, darkMode: false), baseURL: nil)
            }
            try await ready()
            if let coordinator { try #require(await waitUntil { coordinator.ready }) }
        }

        func ready() async throws {
            for _ in 0..<120 {
                if (try? await web.evaluateJavaScript("document.querySelectorAll('.fastra-code-copy').length > 0")) as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            let state = try? await web.evaluateJavaScript("JSON.stringify({presentation:typeof window.fastraMarkdownPresentation,labels:window.fastraMarkdownCopyLabels,pre:document.querySelectorAll('pre').length,controls:document.querySelectorAll('#fastra-code-controls').length,ready:document.readyState,scripts:Array.from(document.scripts,s=>s.src)})")
            Issue.record(Comment(rawValue: "Codeknopf wurde nicht bereit: " + String(describing: state)))
            throw CocoaError(.coderInvalidValue)
        }
        func close() {
            web.configuration.userContentController.removeAllScriptMessageHandlers()
            window.close(); pasteboard.releaseGlobally()
        }
    }
}
