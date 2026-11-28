import AppKit
import SwiftUI
import WebKit
import Testing
@testable import Fastra

private final class LongSessionFixtureWindow: NSWindow {
    var retainedWorkspace: Workspace?
    var retainedCoordinator: MarkdownVisualCoordinator?

    override func close() {
        super.close()
        retainedWorkspace = nil
        retainedCoordinator = nil
    }
}

@Suite("Markdown-WYSIWYG-Langzeit", .serialized)
struct MarkdownVisualLongSessionTests {

    @MainActor
    private func openVisualEditor(
        _ source: String,
        documentURL: URL? = nil,
        workspace existingWorkspace: Workspace? = nil
    ) async throws -> (Workspace, MarkdownVisualCoordinator, MarkdownVisualWKWebView, NSWindow, [String], [MarkdownVisualCoordinator.SaveCheck]) {
        let workspace = existingWorkspace ?? Workspace(defaults: testSuiteDefaults(named: "fastra-long-wysiwyg-\(UUID().uuidString)"))
        let tab: EditorTab
        if existingWorkspace != nil, let existing = workspace.tabs.first(where: { $0.id == workspace.activeTabID }) {
            tab = existing
        } else {
            var created = EditorTab(title: documentURL?.lastPathComponent ?? "Unbenannt.md", path: documentURL?.deletingLastPathComponent().path ?? "", content: source)
            created.url = documentURL
            created.markdownVisualOverride = true
            workspace.tabs = [created]
            workspace.activeTabID = created.id
            tab = created
        }

        let coordinator = MarkdownVisualCoordinator()
        coordinator.pasteboard = NSPasteboard.withUniqueName()
        coordinator.workspace = workspace
        coordinator.tabID = tab.id
        workspace.visualMarkdownEditor = coordinator
        let web = MarkdownVisualWebView.makeWebView(coordinator: coordinator)
        web.frame = NSRect(x: 0, y: 0, width: 820, height: 640)
        let window = LongSessionFixtureWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.retainedWorkspace = workspace
        window.retainedCoordinator = coordinator
        window.isReleasedWhenClosed = false
        window.contentView = web
        WorkspaceWindowRegistry.register(workspace, for: window)

        var safetyErrors: [String] = []
        var saveWarnings: [MarkdownVisualCoordinator.SaveCheck] = []
        workspace.saveSafetyWarningHandler = { title, text in
            safetyErrors.append("\(title): \(text)")
        }
        workspace.markdownSaveWarningHandler = { check, _ in
            saveWarnings.append(check)
            return false
        }
        coordinator.load(
            tab.content,
            documentURL: tab.url,
            fontName: PreviewFonts.systemName,
            fontSize: 14,
            darkMode: false,
            style: "\(PreviewFonts.systemName)|14.0|false|\(tab.url?.path ?? "")"
        )
        let ready = await waitUntil(timeout: 12) { coordinator.ready || !safetyErrors.isEmpty }
        if !(ready && coordinator.ready) {
            web.configuration.userContentController.removeAllScriptMessageHandlers()
            window.close()
        }
        try #require(ready && coordinator.ready, "WYSIWYG-Editor wurde nicht bereit: \(safetyErrors)")
        return (workspace, coordinator, web, window, safetyErrors, saveWarnings)
    }

    @MainActor
    private func reopenSavedFile(at file: URL, expectedBytes: Data) async throws -> (Workspace, MarkdownVisualCoordinator, MarkdownVisualWKWebView, NSWindow) {
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra-long-reopen-\(UUID().uuidString)"))
        var loadResult: Bool?
        workspace.loadFile(at: file) { loadResult = $0 }
        try #require(await waitUntil { loadResult != nil })
        try #require(loadResult == true)
        let index = try #require(workspace.tabs.firstIndex { $0.id == workspace.activeTabID })
        try #require(Data(workspace.tabs[index].content.utf8) == expectedBytes)
        workspace.tabs[index].markdownVisualOverride = true
        let (ws, coord, web, win, _, _) = try await openVisualEditor(
            workspace.tabs[index].content,
            documentURL: file,
            workspace: workspace
        )
        return (ws, coord, web, win)
    }

    @Test("Eingefügte HTTP-Adresse und formatierter Link bestehen die WYSIWYG-Speicherprüfung")
    @MainActor
    func pastedPlainURLAndFormattedLinkSave() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("wysiwyg-link-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Links.md")
        let source = "[a **b** c][ref]\n\n[ref]: <./other%20document.md?q=one&amp;b=&#169;>\n\nAdresse:\n"
        let urlText = "_www.example.com 1https://example.com _https://example.com ftp://example.com http://example.com/path?a=one_two&named=&copy;&decimal=&#169;&hex=&#x1F680;&amp;"
        let pastedTarget = "https://example.com/{user}/a[0]|b?named=&copy;&decimal=&#169;&hex=&#x1F680;&amp;"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let (workspace, coordinator, web, window, _, _) = try await openVisualEditor(source, documentURL: file)
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        workspace.tabs[0].diskSnapshot = try FileSnapshot.readSnapshotOnly(from: file)
        var warning: MarkdownVisualCoordinator.SaveCheck?
        workspace.markdownSaveWarningHandler = { check, _ in
            warning = check
            return false
        }
        _ = try await web.callAsyncJavaScript("""
            const root = document.querySelector('#fastra-visual');
            const range = document.createRange();
            range.selectNodeContents(root.lastElementChild);
            range.collapse(false);
            getSelection().removeAllRanges();
            getSelection().addRange(range);
            const clipboardData = new DataTransfer();
            clipboardData.setData('text/plain', ' ' + urlText);
            root.dispatchEvent(new ClipboardEvent('paste', { clipboardData, bubbles: true, cancelable: true }));
            fastraVisual.command('insertParagraph');
            const link = document.createElement('a');
            link.setAttribute('href', pastedTarget);
            link.setAttribute('title', '&lt; &copy; &#169; &#x1F680;');
            link.innerHTML = 'd <strong>e</strong> f';
            const richData = new DataTransfer();
            richData.setData('text/html', link.outerHTML);
            root.dispatchEvent(new ClipboardEvent('paste', { clipboardData: richData, bubbles: true, cancelable: true }));
            """, arguments: ["urlText": urlText, "pastedTarget": pastedTarget], in: nil, in: .page)
        try #require(await waitUntil { workspace.activeTab?.isDirty == true })
        workspace.saveActiveTab()
        try #require(await waitUntil { workspace.activeTab?.isDirty == false || warning != nil })
        #expect(warning == nil)
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved.contains("[a **b** c][ref]"))
        let rendered = MarkdownVisualDocument.render(saved, documentURL: file).fragment.html
        #expect(rendered.contains("Adresse: " + urlText.replacingOccurrences(of: "&", with: "&amp;")))
        #expect(rendered.contains("<a href=\"./other%20document.md?q=one&amp;b=%C2%A9\">a <strong>b</strong> c</a>"))
        #expect(rendered.contains("href=\"" + pastedTarget.replacingOccurrences(of: "{user}/a[0]|b", with: "%7Buser%7D/a%5B0%5D%7Cb").replacingOccurrences(of: "&", with: "&amp;") + "\""))
        #expect(rendered.contains("title=\"&amp;lt; &amp;copy; &amp;#169; &amp;#x1F680;\""))
        withExtendedLifetime(coordinator) {}
    }

    @Test("Trotzdem speichern darf nur einen synchronisierten Markdown-Stand schreiben")
    @MainActor
    func saveAnywayRequiresCheckedCandidate() throws {
        let directory = testTemporaryDirectory().appendingPathComponent("wysiwyg-save-anyway-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Weiter.md")
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra-save-anyway-\(UUID().uuidString)"))
        let tab = EditorTab(title: "Weiter.md", path: directory.path, content: "Aktuelle Änderungen\n")
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        workspace.beginVisualSaveCheck(tabID: tab.id, holdID: "pending")
        workspace.markdownSaveWarningHandler = { check, canSave in
            #expect(check == .unavailable)
            #expect(!canSave)
            return true
        }
        #expect(!workspace.write(tab: tab, to: file, expectedTargetState: .absent))
        #expect(!FileManager.default.fileExists(atPath: file.path))

        workspace.endVisualSaveCheck(tabID: tab.id, holdID: "pending")
        workspace.recordVisualSaveCheck(tabID: tab.id, documentID: tab.documentID,
                                        contentRevision: tab.contentRevision,
                                        candidate: tab.textForSaving(tab.content), outcome: .text)
        workspace.markdownSaveWarningHandler = { check, canSave in
            #expect(check == .text)
            #expect(canSave)
            return false
        }
        #expect(!workspace.write(tab: tab, to: file, expectedTargetState: .absent))
        #expect(!FileManager.default.fileExists(atPath: file.path))

        workspace.saveSafetyWarningHandler = { _, _ in }
        workspace.markdownSaveWarningHandler = { _, canSave in
            #expect(canSave)
            workspace.activeTabContent.wrappedValue = "Neuerer Stand\n"
            return true
        }
        #expect(!workspace.write(tab: tab, to: file, expectedTargetState: .absent))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let current = try #require(workspace.activeTab)
        workspace.recordVisualSaveCheck(tabID: current.id, documentID: current.documentID,
                                        contentRevision: current.contentRevision,
                                        candidate: current.textForSaving(current.content), outcome: .text)
        workspace.markdownSaveWarningHandler = { check, canSave in
            #expect(check == .text)
            #expect(canSave)
            return true
        }
        #expect(workspace.write(tab: current, to: file, expectedTargetState: .absent))
        #expect(try String(contentsOf: file, encoding: .utf8) == current.content)
    }

    @Test("Undo lädt ein relatives Bild nach dem ersten Speichern aus dem Zielordner")
    @MainActor
    func firstSaveResolvesImageRestoredByUndo() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("wysiwyg-undo-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Bild.md")
        let image = directory.appendingPathComponent("sample.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)

        let (workspace, coordinator, web, window, _, _) = try await openVisualEditor("Text ![Bild](sample.png)\n")
        defer { web.configuration.userContentController.removeAllScriptMessageHandlers(); window.close() }
        _ = try await web.evaluateJavaScript("""
            const image = document.querySelector('#fastra-visual img');
            const range = document.createRange();
            range.selectNode(image);
            getSelection().removeAllRanges();
            getSelection().addRange(range);
            fastraVisual.command('delete');
            """)
        try #require(await waitUntil { workspace.activeTab?.content.contains("sample.png") == false })
        let tabID = try #require(workspace.activeTabID)
        var saved: Bool?
        workspace.saveTabAs(id: tabID, to: file, expectedTargetState: .absent, isMarkdown: true) { saved = $0 }
        try #require(await waitUntil(timeout: 10) { saved != nil })
        try #require(saved == true)
        coordinator.performHistoryUndo()
        try #require(await waitUntil { workspace.activeTab?.content.contains("sample.png") == true })
        let deadline = Date().addingTimeInterval(4)
        var width: Int?
        repeat {
            width = try await web.evaluateJavaScript("document.querySelector('#fastra-visual img')?.naturalWidth ?? 0") as? Int
            if width == 10 { break }
            try await Task.sleep(for: .milliseconds(25))
        } while Date() < deadline
        let resolvedSource = try await web.evaluateJavaScript("document.querySelector('#fastra-visual img')?.getAttribute('src')") as? String
        #expect(width == 10, "src=\(resolvedSource ?? "nil"), assets=\(coordinator.assets.imageURLSnapshot().count)")
    }

    @Test("Neue unbenannte Protokoll-Datei behält alle Leerzeilen und Undo über erstes Speichern, Weiterarbeiten und Wiederöffnen")
    @MainActor
    func untitledProtocolSaveAndContinueEditingPreservesBlankLinesAndUndo() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("wysiwyg-untitled-protocol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Protokoll.md")

        let (workspace, coordinator, web, window, _, _) = try await openVisualEditor("", documentURL: nil)
        defer {
            web.configuration.userContentController.removeAllScriptMessageHandlers()
            window.close()
            withExtendedLifetime((workspace, coordinator)) {}
        }

        var safetyErrors: [String] = []
        var saveWarnings: [MarkdownVisualCoordinator.SaveCheck] = []
        workspace.saveSafetyWarningHandler = { title, text in safetyErrors.append("\(title): \(text)") }
        workspace.markdownSaveWarningHandler = { check, _ in
            saveWarnings.append(check)
            return false
        }

        // Realistisches längeres Protokoll im frischen ungesicherten Tab aufbauen
        _ = try await web.evaluateJavaScript("""
            (() => {
              const root = document.getElementById('fastra-visual');
              root.focus();
              const sel = getSelection();
              const collapseEnd = el => {
                const r = document.createRange();
                r.selectNodeContents(el);
                r.collapse(false);
                sel.removeAllRanges();
                sel.addRange(r);
              };
              const collapseStart = el => {
                const r = document.createRange();
                r.selectNodeContents(el);
                r.collapse(true);
                sel.removeAllRanges();
                sel.addRange(r);
              };

              fastraVisual.command('insertText', 'Platzhalter für Systeminformationen');
              fastraVisual.command('insertParagraph');
              fastraVisual.command('insertParagraph'); // sichtbare Leerzeile 1

              fastraVisual.command('insertText', 'Getestet');
              fastraVisual.command('hardBreak');
              fastraVisual.command('insertText', '– Erste Prüfung');
              fastraVisual.command('hardBreak');
              fastraVisual.command('insertText', '– Zweite Prüfung');
              fastraVisual.command('insertParagraph');
              fastraVisual.command('insertParagraph'); // sichtbare Leerzeile 2

              fastraVisual.command('insertText', 'Fragen');
              fastraVisual.command('heading2');
              fastraVisual.command('insertParagraph');
              fastraVisual.command('insertText', 'Frage 1');
              fastraVisual.command('hardBreak');
              fastraVisual.command('insertText', '– ');
              fastraVisual.command('hardBreak');
              fastraVisual.command('insertText', 'Bild F1a');
              fastraVisual.command('insertParagraph');
              fastraVisual.command('insertText', 'Frage 2');

              // Enter am Absatzanfang von "Frage 2" -> erzeugt Leerzeile 3
              const pFrage2 = Array.from(root.querySelectorAll('p')).find(p => p.textContent === 'Frage 2');
              collapseStart(pFrage2.firstChild);
              fastraVisual.command('insertParagraph');

              collapseEnd(pFrage2);
              fastraVisual.command('hardBreak');
              fastraVisual.command('insertText', '– Bild F2a');
              fastraVisual.command('insertParagraph');
              fastraVisual.command('insertParagraph'); // sichtbare Leerzeile 4

              fastraVisual.command('insertText', 'Fehler');
              fastraVisual.command('heading2');
              fastraVisual.command('insertParagraph');
              fastraVisual.command('insertText', 'Fehler 1');
              fastraVisual.command('insertParagraph');
              fastraVisual.command('insertText', 'Fehler 2');
              fastraVisual.command('insertParagraph'); // nachlaufende Leerzeile 5

              // In Leerzeile tippen und sofort wieder löschen
              const blanks = root.querySelectorAll('.fastra-visible-blank-line');
              if (blanks.length > 0) {
                collapseStart(blanks[0]);
                fastraVisual.command('insertText', 'Kurz');
                const kurzP = Array.from(root.querySelectorAll('p')).find(p => p.textContent === 'Kurz');
                const r = document.createRange();
                r.selectNodeContents(kurzP);
                sel.removeAllRanges();
                sel.addRange(r);
                fastraVisual.command('delete');
                fastraVisual.undo();
                fastraVisual.undo();
              }

              fastraVisual.flush();
              return fastraVisual.markdown();
            })()
            """)

        try #require(await waitUntil { workspace.activeTab?.isDirty == true && workspace.activeTab?.content.contains("Fehler 2") == true })
        let beforeFirstSave = try #require(workspace.activeTab?.content)
        let expectedBlankCount = beforeFirstSave
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { $0.count >= 2 && $0.allSatisfy { $0 == " " } }
            .count
        #expect(expectedBlankCount >= 5, Comment(rawValue: "Erwartet >=5 sichtbare Leerzeilen:\n\(beforeFirstSave)"))

        // Erstes Speichern (unbenannter Tab -> neue Datei auf Platte)
        let tabID = try #require(workspace.activeTabID)
        var firstSaveSucceeded: Bool?
        workspace.saveTabAs(id: tabID, to: file, expectedTargetState: .absent, isMarkdown: true) { firstSaveSucceeded = $0 }
        try #require(await waitUntil(timeout: 10) { firstSaveSucceeded != nil })
        try #require(firstSaveSucceeded == true)
        try #require(safetyErrors.isEmpty, Comment(rawValue: safetyErrors.joined(separator: "; ")))
        try #require(saveWarnings.isEmpty)
        try #require(try String(contentsOf: file, encoding: .utf8) == beforeFirstSave)

        // Undo-Verlauf muss nach dem ersten Speichern erhalten bleiben!
        try #require(coordinator.ready)
        try #require(coordinator.historyState.canUndo)
        coordinator.performHistoryUndo()
        try #require(await waitUntil { workspace.activeTab?.content != beforeFirstSave })
        coordinator.performHistoryRedo()
        try #require(await waitUntil { workspace.activeTab?.content == beforeFirstSave })

        // Weiterarbeiten: Plain-Text-Paste mit Leerzeilen, Markierung, dann zweites Speichern
        _ = try await web.evaluateJavaScript("""
            (() => {
              const root = document.getElementById('fastra-visual');
              const last = root.lastElementChild;
              const r = document.createRange();
              r.selectNodeContents(last);
              r.collapse(false);
              getSelection().removeAllRanges();
              getSelection().addRange(r);
              const bm = fastraVisual.bookmarkClipboard();
              fastraVisual.insertClipboardText(bm, 'Fehler 3\\n\\n  \\nAbschlussbemerkung');
              const endP = Array.from(root.querySelectorAll('p')).find(p => p.textContent === 'Abschlussbemerkung');
              const r2 = document.createRange();
              r2.selectNodeContents(endP);
              getSelection().removeAllRanges();
              getSelection().addRange(r2);
              fastraVisual.command('highlight');
              fastraVisual.flush();
            })()
            """)
        try #require(await waitUntil { workspace.activeTab?.content.contains("==Abschlussbemerkung==") == true })
        let beforeSecondSave = try #require(workspace.activeTab?.content)
        let secondBlankCount = beforeSecondSave
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { $0.count >= 2 && $0.allSatisfy { $0 == " " } }
            .count
        #expect(secondBlankCount >= expectedBlankCount + 1, Comment(rawValue: beforeSecondSave))

        workspace.saveActiveTab()
        try #require(await waitUntil(timeout: 10) { !saveWarnings.isEmpty || workspace.activeTab?.isDirty == false })
        try #require(saveWarnings.isEmpty)
        let savedData = try Data(contentsOf: file)
        #expect(String(decoding: savedData, as: UTF8.self) == beforeSecondSave)

        // Tab schließen und frisch von Platte öffnen -> alle Leerzeilen & Formate müssen übereinstimmen
        workspace.closeTab(id: tabID)
        try #require(await waitUntil { !workspace.tabs.contains { $0.id == tabID } })
        let (reopenWs, reopenCoord, freshWeb, freshWin) = try await reopenSavedFile(at: file, expectedBytes: savedData)
        defer {
            freshWeb.configuration.userContentController.removeAllScriptMessageHandlers()
            freshWin.close()
            withExtendedLifetime((reopenWs, reopenCoord)) {}
        }
        let reopenedBlanks = try await freshWeb.evaluateJavaScript("document.querySelectorAll('#fastra-visual .fastra-visible-blank-line').length") as? Int
        #expect(reopenedBlanks == secondBlankCount, Comment(rawValue: beforeSecondSave))
        #expect(try await freshWeb.evaluateJavaScript("document.querySelector('mark')?.textContent") as? String == "Abschlussbemerkung")
        #expect(try await freshWeb.evaluateJavaScript("document.querySelectorAll('#fastra-visual h2').length") as? Int == 2)
    }

    @Test("Lange Arbeitssitzung über 4 Speicherrunden mit Listen, Zitaten, Tabelle, Paste, Undo und Referenzen")
    @MainActor
    func longMultiSaveDocumentSessionWithPasteUndoAndFormatting() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("wysiwyg-long-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Handbuch.md")

        let initialSource = """
        # Projekthandbuch

          

        Erster Absatz mit **Fettdruck**, *Kursiv* und ==Marker==.

        [ref]: https://one.example

        Wichtiger Absatz vor zweiter Definition.

        [ref]: https://two.example

        [Verweis][ref]

          

        ## Aufgabenliste

        4. Schritt vier
        5. Schritt fünf
        6. Schritt sechs
        7. Schritt sieben

        - Punkt A
        - Punkt B

        Nachlaufabsatz

          

        | Spalte 1 | Spalte 2 |
        | --- | --- |
        | Wert A | Wert B |

        ```swift
        let x = 1
        ```

        """
        try initialSource.write(to: file, atomically: true, encoding: .utf8)

        for round in 1...4 {
            let currentSource = try String(contentsOf: file, encoding: .utf8)
            let (workspace, coordinator, web, window, _, _) = try await openVisualEditor(currentSource, documentURL: file)
            defer {
                web.configuration.userContentController.removeAllScriptMessageHandlers()
                window.close()
                withExtendedLifetime((workspace, coordinator)) {}
            }
            workspace.tabs[0].diskSnapshot = try FileSnapshot.readSnapshotOnly(from: file)
            var saveWarnings: [MarkdownVisualCoordinator.SaveCheck] = []
            workspace.markdownSaveWarningHandler = { check, _ in
                saveWarnings.append(check)
                return false
            }

            let roundResult = try await web.evaluateJavaScript("""
                (() => {
                  const root = document.getElementById('fastra-visual');
                  const sel = getSelection();
                  root.focus();

                  if (\(round) === 1) {
                    // Mehrfachauswahl in geordneter Liste (Schritt fünf + Schritt sechs) zu H2
                    const items = Array.from(root.querySelectorAll('ol li'));
                    const r = document.createRange();
                    r.setStart(items[1], 0);
                    r.setEnd(items[2], items[2].childNodes.length);
                    sel.removeAllRanges();
                    sel.addRange(r);
                    fastraVisual.command('heading2');
                    // Absatz mit erster Definition in Zitat einbetten -> Reihenfolge der Definitionen muss stabil bleiben
                    const refP = Array.from(root.querySelectorAll('p')).find(p => p.textContent.includes('Wichtiger Absatz'));
                    const r2 = document.createRange();
                    r2.selectNodeContents(refP);
                    sel.removeAllRanges();
                    sel.addRange(r2);
                    fastraVisual.command('quote');
                  } else if (\(round) === 2) {
                    // Gemischte Auswahl über Liste + Folgeabsatz -> Bullet-Liste -> Undo -> erneut auswählen -> Task-Liste (3 Tasks)
                    const selectMixed = () => {
                      const ul = root.querySelector('ul');
                      const after = Array.from(root.querySelectorAll('p')).find(p => p.textContent === 'Nachlaufabsatz');
                      const r = document.createRange();
                      r.setStart(ul.querySelector('li'), 0);
                      r.setEnd(after, after.childNodes.length);
                      sel.removeAllRanges();
                      sel.addRange(r);
                    };
                    selectMixed();
                    fastraVisual.command('bulletList');
                    fastraVisual.undo();
                    selectMixed();
                    fastraVisual.command('orderedList');
                    fastraVisual.command('taskList');
                  } else if (\(round) === 3) {
                    // Plain-Text-Paste mit Leerzeilen + Shift-Enter vor Umbruch + Undo/Redo
                    const p0 = root.querySelector('p');
                    const r = document.createRange();
                    r.selectNodeContents(p0);
                    r.collapse(false);
                    sel.removeAllRanges();
                    sel.addRange(r);
                    const bm = fastraVisual.bookmarkClipboard();
                    fastraVisual.insertClipboardText(bm, '\\n\\nZwischentext\\n\\n  \\nDanach');
                    const insertedP = Array.from(root.querySelectorAll('p')).find(p => p.textContent.includes('Zwischentext'));
                    const r2 = document.createRange();
                    r2.setStart(insertedP.firstChild, 8);
                    r2.collapse(true);
                    sel.removeAllRanges();
                    sel.addRange(r2);
                    fastraVisual.command('hardBreak');
                    fastraVisual.undo();
                    fastraVisual.redo();
                  } else {
                    // Codeblock um Text erweitern + Leerzeile am Dokumentende anhängen
                    const code = root.querySelector('pre code');
                    const r = document.createRange();
                    r.selectNodeContents(code);
                    r.collapse(false);
                    sel.removeAllRanges();
                    sel.addRange(r);
                    fastraVisual.command('insertText', '\\nlet y = 2');
                    const last = root.lastElementChild;
                    const r2 = document.createRange();
                    r2.selectNodeContents(last);
                    r2.collapse(false);
                    sel.removeAllRanges();
                    sel.addRange(r2);
                    fastraVisual.command('insertParagraph');
                    fastraVisual.command('insertText', 'Runde 4 abgeschlossen');
                  }
                  fastraVisual.flush();
                  const diag = fastraVisual.diagnosticReport(false);
                  return JSON.stringify({ anomalies: diag.anomalies, markdown: fastraVisual.markdown() });
                })()
                """) as? String

            let data = try #require(roundResult?.data(using: .utf8))
            let parsed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let anomalies = try #require(parsed["anomalies"] as? [[String: Any]])
            #expect(anomalies.isEmpty, Comment(rawValue: "Runde \(round) Anomalien: \(roundResult ?? "")"))
            let expected = try #require(parsed["markdown"] as? String)
            try #require(await waitUntil { workspace.activeTab?.content == expected && workspace.activeTab?.isDirty == true })

            workspace.saveActiveTab()
            try #require(await waitUntil(timeout: 10) { !saveWarnings.isEmpty || workspace.activeTab?.isDirty == false })
            try #require(saveWarnings.isEmpty, Comment(rawValue: "Runde \(round) SaveCheck: \(saveWarnings)"))
            let saved = try String(contentsOf: file, encoding: .utf8)
            #expect(saved == expected)

            // Referenzdefinitionen dürfen in keiner Runde vertauscht werden
            let oneIdx = try #require(saved.range(of: "https://one.example")?.lowerBound)
            let twoIdx = try #require(saved.range(of: "https://two.example")?.lowerBound)
            #expect(oneIdx < twoIdx, Comment(rawValue: saved))

            let tabID = try #require(workspace.activeTabID)
            workspace.closeTab(id: tabID)
            try #require(await waitUntil { !workspace.tabs.contains { $0.id == tabID } })
        }

        let finalBytes = try Data(contentsOf: file)
        let (finalWs, finalCoord, finalWeb, finalWin) = try await reopenSavedFile(at: file, expectedBytes: finalBytes)
        defer {
            finalWeb.configuration.userContentController.removeAllScriptMessageHandlers()
            finalWin.close()
            withExtendedLifetime((finalWs, finalCoord)) {}
        }
        let finalText = String(decoding: finalBytes, as: UTF8.self)
        #expect(finalText.contains("## Schritt fünf"), Comment(rawValue: finalText))
        #expect(finalText.contains("## Schritt sechs"), Comment(rawValue: finalText))
        #expect(finalText.contains("7. Schritt sieben"), Comment(rawValue: finalText))
        #expect(finalText.contains("Runde 4 abgeschlossen"), Comment(rawValue: finalText))
        let taskCount = try await finalWeb.evaluateJavaScript("document.querySelectorAll('#fastra-visual li[data-task]').length") as? Int ?? 0
        #expect(taskCount >= 3, Comment(rawValue: finalText))
    }

    @Test("Schnelles Tippen während aktiver Live-Prüfung löst kein kurz aufblitzendes Fehlwarnbanner aus")
    @MainActor
    func rapidTypingDuringLiveCheckDoesNotFlashFalseWarningBanner() async throws {
        let (workspace, coordinator, web, window, _, _) = try await openVisualEditor("Start\n")
        defer {
            web.configuration.userContentController.removeAllScriptMessageHandlers()
            window.close()
            withExtendedLifetime((workspace, coordinator)) {}
        }
        coordinator.liveCheckDelay = 0.01

        for step in 1...12 {
            _ = try await web.evaluateJavaScript("""
                (() => {
                  const p = document.querySelector('#fastra-visual p');
                  const r = document.createRange();
                  r.selectNodeContents(p);
                  r.collapse(false);
                  getSelection().removeAllRanges();
                  getSelection().addRange(r);
                  document.execCommand('insertText', false, ' \(step)');
                })()
                """)
            try await Task.sleep(for: .milliseconds(15))
            #expect(workspace.markdownVisualDiagnostics.activeWarning == nil,
                    Comment(rawValue: "Falsches Banner bei Schritt \(step): \(String(describing: workspace.markdownVisualDiagnostics.activeWarning))"))
            #expect(!workspace.markdownVisualDiagnostics.showsBanner)
        }
        _ = try await web.evaluateJavaScript("fastraVisual.flush();")
        try #require(await waitUntil { workspace.activeTab?.content.contains("12") == true })
        try #require(await waitUntil { workspace.markdownVisualDiagnostics.lastCheckPassed == true })
        #expect(workspace.markdownVisualDiagnostics.activeWarning == nil)
    }

    @Test("Codeblock-Paste ohne Bild, schnelles Cut-Save-Rennen und Hintergrundtab-Speicherprüfung greifen zuverlässig")
    @MainActor
    func swiftBridgeRegressionsCodeBlockPasteCutSaveAndBackgroundSave() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent("wysiwyg-bridge-regressions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileA = directory.appendingPathComponent("a.md")
        let fileB = directory.appendingPathComponent("b.md")
        try "Eins Zwei\n\n```\ncode\n```\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "Beta\n".write(to: fileB, atomically: true, encoding: .utf8)

        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra-bridge-regressions-\(UUID().uuidString)"))
        var tabA = EditorTab(title: "a.md", path: directory.path, content: "Eins Zwei\n\n```\ncode\n```\n")
        tabA.url = fileA
        tabA.diskSnapshot = try FileSnapshot.readSnapshotOnly(from: fileA)
        tabA.markdownVisualOverride = true
        var tabB = EditorTab(title: "b.md", path: directory.path, content: "Beta\n")
        tabB.url = fileB
        tabB.diskSnapshot = try FileSnapshot.readSnapshotOnly(from: fileB)
        tabB.markdownVisualOverride = false
        workspace.tabs = [tabA, tabB]
        workspace.activeTabID = tabA.id

        let (_, coordinator, web, window, _, _) = try await openVisualEditor(tabA.content, documentURL: fileA, workspace: workspace)
        defer {
            web.configuration.userContentController.removeAllScriptMessageHandlers()
            window.close()
            withExtendedLifetime((workspace, coordinator)) {}
        }
        var saveWarnings: [MarkdownVisualCoordinator.SaveCheck] = []
        workspace.markdownSaveWarningHandler = { check, _ in
            saveWarnings.append(check)
            return false
        }

        // 1. Kopieren + Einfügen in Codeblock über Fastras privates Clipboard-Format
        _ = try await web.evaluateJavaScript("""
            (() => {
              const p = document.querySelector('#fastra-visual p');
              const r = document.createRange();
              r.setStart(p.firstChild, 0);
              r.setEnd(p.firstChild, 4);
              getSelection().removeAllRanges();
              getSelection().addRange(r);
              document.getElementById('fastra-visual').dispatchEvent(new Event('copy', { bubbles: true, cancelable: true }));
            })()
            """)
        try #require(await waitUntil { coordinator.pasteboard.data(forType: MarkdownVisualCoordinator.clipboardType) != nil })
        var fenceReleased = false
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.getElementById('fastra-visual')?.contentEditable") as? String) == "true" {
                fenceReleased = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(fenceReleased)
        _ = try await web.evaluateJavaScript("""
            (() => {
              const code = document.querySelector('#fastra-visual pre code');
              const r = document.createRange();
              r.selectNodeContents(code);
              r.collapse(false);
              getSelection().removeAllRanges();
              getSelection().addRange(r);
            })()
            """)
        #expect(coordinator.pasteImages())
        try #require(await waitUntil { workspace.activeTab?.content.contains("code\nEins") == true })
        #expect(try await web.evaluateJavaScript("document.querySelector('#fastra-visual pre code')?.textContent.includes('Eins')") as? Bool == true)

        // 2. Schnelles Cut -> sofortiges Save wartet auf Cut-Abschluss statt Text stehen zu lassen
        _ = try await web.evaluateJavaScript("""
            (() => {
              const p = document.querySelector('#fastra-visual p');
              const r = document.createRange();
              r.setStart(p.firstChild, 5);
              r.setEnd(p.firstChild, 9);
              getSelection().removeAllRanges();
              getSelection().addRange(r);
              document.getElementById('fastra-visual').dispatchEvent(new Event('cut', { bubbles: true, cancelable: true }));
            })()
            """)
        workspace.saveActiveTab()
        try #require(await waitUntil(timeout: 10) { workspace.activeTab?.isDirty == false })
        let savedAfterCut = try String(contentsOf: fileA, encoding: .utf8)
        #expect(!savedAfterCut.contains("Zwei"), Comment(rawValue: savedAfterCut))

        // 3. Tabwechsel auf dirty Tab prüft & speichert Befund für Hintergrund-Save
        _ = try await web.evaluateJavaScript("""
            (() => {
              const p = document.querySelector('#fastra-visual p');
              const r = document.createRange();
              r.selectNodeContents(p);
              r.collapse(false);
              getSelection().removeAllRanges();
              getSelection().addRange(r);
              fastraVisual.command('insertText', ' geändert');
              fastraVisual.flush();
            })()
            """)
        try #require(await waitUntil { workspace.activeTab?.isDirty == true })
        workspace.selectTab(id: tabB.id)
        try #require(await waitUntil { workspace.activeTabID == tabB.id })
        // In SwiftUI wird beim Wechsel zu einem Quelltext-Tab der visuelle Editor abgebaut,
        // bevor später ein Hintergrund-Speichern auf dem verlassenen Tab stattfindet.
        workspace.visualMarkdownEditor = nil
        // Simuliere einen auf Tab A erkannten Formatfehler und prüfe Hintergrund-Save auf Tab A
        let currentA = try #require(workspace.tabs.first { $0.id == tabA.id })
        workspace.recordVisualSaveCheck(
            tabID: currentA.id,
            documentID: currentA.documentID,
            contentRevision: currentA.contentRevision,
            candidate: currentA.textForSaving(currentA.content),
            outcome: .format,
            redactedDiagnostic: "bg-check"
        )
        workspace.saveTab(id: tabA.id)
        try #require(await waitUntil { !saveWarnings.isEmpty })
        #expect(saveWarnings == [.format])
        #expect(workspace.tabs.first { $0.id == tabA.id }?.isDirty == true)
    }
}
