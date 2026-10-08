import AppKit
import WebKit
import Testing
@testable import Fastra

@Suite("Markdown-WYSIWYG", .serialized)
struct MarkdownVisualTests {
    static let samples = [
        "", "Text 😀", "# Titel\n\n**Fett** und *kursiv* mit ==Marker==.\n",
        "[Link][ziel]\n\n[ziel]: https://example.com \"Titel\"\n\n<!-- Kommentar -->\n",
        "| A | B |\n| - | - |\n| 😀 | **ja** |\n\n- [x] Fertig\n- [ ] Offen\n",
        "```swift\nlet code = \"```\"\n```\n\n$$\nx + y\n$$\n\nText $a$ danach\n",
        "<details><summary>Mehr</summary>Inhalt</details>\n\n![Fehlt](images/missing.png)\n",
        "**offen\n\n#\n\n[defekt](\n\n  \nEnde",
        "# CR\r\rAbsatz\r", "# CRLF\r\n\r\nText 😀\r\n"
    ]

    @Test("Blockzerlegung bewahrt jeden Originalbuchstaben", arguments: samples)
    func blocksPreserveSource(_ source: String) {
        let document = MarkdownVisualDocument.render(source, documentURL: nil)
        #expect(document.blocks.map(\.source).joined() == source)
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
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
        try #require(ready && coordinator.ready, "Editor wurde nicht bereit")
        return (workspace, coordinator, web, window)
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
        let source = "**Bild** ![Alt](images/long.png) $x$ <!-- erhalten -->\n"
        let (_, first, firstWeb, firstWindow) = try await editor(source, documentURL: firstURL)
        defer { firstWeb.configuration.userContentController.removeAllScriptMessageHandlers(); firstWindow.close() }
        _ = try await firstWeb.evaluateJavaScript("""
            const root=document.getElementById('fastra-visual'),r=document.createRange();r.selectNodeContents(root);
            getSelection().removeAllRanges();getSelection().addRange(r);root.dispatchEvent(new Event('copy',{bubbles:true,cancelable:true}));
            """)
        try #require(await waitUntil { first.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType) != nil })
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
        #expect(try Data(contentsOf: secondURL.deletingLastPathComponent().appendingPathComponent("images/1.png")) == Data(contentsOf: image))
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
        coordinator.load(workspace.activeTab!.content, documentURL: targetURL, fontName: PreviewFonts.systemName,
                         fontSize: 14, darkMode: false, style: "new")
        coordinator.load("Neuer Stand\n", documentURL: targetURL, fontName: PreviewFonts.systemName,
                         fontSize: 14, darkMode: false, style: "newest")
        try #require(await waitUntil { coordinator.ready })
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

}
