import AppKit
import SwiftUI
import CoreText
import CodeEditTextView
@testable import CodeEditSourceEditor
import Testing
@testable import Fastra

@Suite struct SplitEditorTests {
    @Test("Gemeinsamer Text erhält die unabhängige Auswahl der zweiten Ansicht nach Präfix-Edit")
    @MainActor func sharedStoragePreservesOtherSelection() throws {
        let first = TextView(string: "one\ntwo\nthree\n")
        let second = TextView(string: "")
        second.setTextStorage(first.textStorage)
        first.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        second.selectionManager.setSelectedRange(NSRange(location: 8, length: 5))
        let manager = try #require(first.undoManager as? CEUndoManager)
        second.setUndoManager(manager)
        first.replaceCharacters(in: NSRange(location: 0, length: 0), with: "prefix\n")
        #expect(first.textStorage === second.textStorage)
        #expect(second.string == "prefix\none\ntwo\nthree\n")
        #expect(second.selectedRange() == NSRange(location: 15, length: 5))
        manager.undo()
        #expect(first.string == "one\ntwo\nthree\n")
        #expect(second.selectedRange() == NSRange(location: 8, length: 5))
    }
    @Test("Abwechselnde Eingaben und Undo/Redo verwenden die bediente Ansicht")
    @MainActor func sharedUndoUsesActiveView() throws {
        let first = TextView(string: "one\ntwo\nthree\n")
        let second = TextView(string: "")
        second.setTextStorage(first.textStorage)
        let manager = try #require(first.undoManager as? CEUndoManager)
        second.setUndoManager(manager)
        first.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        second.selectionManager.setSelectedRange(NSRange(location: 8, length: 5))
        first.replaceCharacters(in: NSRange(location: 0, length: 0), with: "A")
        manager.endUndoGrouping()
        second.replaceCharacters(in: NSRange(location: second.textStorage.length, length: 0), with: "B")
        manager.endUndoGrouping()
        _ = first.becomeFirstResponder()
        manager.undo()
        #expect(first.string == "Aone\ntwo\nthree\n")
        _ = second.becomeFirstResponder()
        manager.undo()
        #expect(second.string == "one\ntwo\nthree\n")
        manager.redo()
        #expect(first.string == "Aone\ntwo\nthree\n")
        _ = first.becomeFirstResponder()
        manager.redo()
        #expect(second.string == "Aone\ntwo\nthree\nB")
        #expect([first, second].allSatisfy { $0.selectedRange().location <= $0.textStorage.length })
    }

    @Test("Beide Controller schreiben über denselben Dokument- und Undo-Zustand")
    @MainActor func sharedStorageUsesWorkspaceMutationPath() throws {
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra.tests.split.\(UUID())"))
        workspace.tabs = [EditorTab(title: "test.txt", path: "-", content: "one\ntwo\nthree\n")]
        workspace.activeTabID = workspace.tabs[0].id
        let tab = try #require(workspace.activeTab)
        let storage = tab.undoHistory.textStorage(for: tab.content)
        let first = TextViewController(string: "", language: .default,
            configuration: .init(appearance: .init(theme: EditorView.fastraTheme, font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false, tabWidth: 4)), cursorPositions: [])
        let second = TextViewController(string: "", language: .default,
            configuration: .init(appearance: .init(theme: EditorView.fastraTheme, font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false, tabWidth: 4)), cursorPositions: [])
        first.loadView(); second.loadView()
        let a = SourcePaneCoordinator(workspace: workspace, pane: .primary)
        let b = SourcePaneCoordinator(workspace: workspace, pane: .secondary)
        for (controller, coordinator) in [(first, a), (second, b)] {
            controller.textView.setTextStorage(storage)
            controller.textView.setUndoManager(tab.undoHistory.manager(for: tab.content))
            coordinator.prepareCoordinator(controller: controller)
        }
        first.textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "A")
        #expect(workspace.activeTab?.content == "Aone\ntwo\nthree\n")
        #expect(workspace.activeTab?.isDirty == true)
        #expect(tab.undoHistory.textStorage(for: workspace.activeTab!.content) === storage)
        let manager = try #require(first.textView.undoManager as? CEUndoManager)
        manager.endUndoGrouping()
        second.textView.replaceCharacters(in: NSRange(location: 0, length: 1), with: "B")
        manager.endUndoGrouping()
        #expect(workspace.activeTab?.content == "Bone\ntwo\nthree\n")
        manager.undo()
        #expect(workspace.activeTab?.content == "Aone\ntwo\nthree\n")
        manager.undo()
        #expect(workspace.activeTab?.content == "one\ntwo\nthree\n")
        #expect(first.textView.textStorage === second.textView.textStorage)
        a.destroy(); b.destroy()
    }

    @Test("Teilung bleibt je Fenster getrennt und wahrt Abschnitts-/Read-only-Grenzen")
    @MainActor func splitEligibilityAndWindowIsolation() throws {
        let first = Workspace(defaults: testSuiteDefaults(named: "fastra.tests.split.a.\(UUID())"))
        let second = Workspace(defaults: testSuiteDefaults(named: "fastra.tests.split.b.\(UUID())"))
        for workspace in [first, second] {
            workspace.tabs = [EditorTab(title: "test.txt", path: "-", content: "text")]
            workspace.activeTabID = workspace.tabs[0].id
        }
        #expect(first.canSplitSourceEditor)
        first.toggleSourceSplit()
        #expect(first.sourceSplitEnabled)
        #expect(!second.sourceSplitEnabled)
        first.tabs[0].displayMode = .chunkedText
        #expect(!first.canSplitSourceEditor)
        first.tabs[0].displayMode = .text
        first.tabs[0].readOnlyReason = "test"
        #expect(!first.canSplitSourceEditor)
        #expect(second.canSplitSourceEditor)
    }

    @Test("Faltbereiche beider Ansichten werden nach gemeinsamer Quelländerung neu analysiert")
    @MainActor func sharedStorageRefreshesBothFoldModels() async throws {
        let source = "If (True)\nALERT(\"one\")\nEnd if\n"
        let changed = source + "If (False)\nALERT(\"two\")\nEnd if\n"
        let storage = TextView.fastraMakeTextStorage(source)
        func make() -> TextViewController {
            let controller = TextViewController(string: "", language: .default,
                configuration: .init(appearance: .init(theme: EditorView.fastraTheme,
                    font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false, tabWidth: 4)),
                cursorPositions: [], foldProvider: CodeFoldProvider(language: .default, isFourD: true))
            controller.loadView()
            controller.textView.setTextStorage(storage)
            return controller
        }
        let first = make(), second = make()
        try #require(await waitUntil { first.fastraFoldRegions.count == 1 && second.fastraFoldRegions.count == 1 })
        first.textView.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: String(changed.dropFirst(source.count)))
        #expect(await waitUntil { first.fastraFoldRegions.count == 2 })
        #expect(await waitUntil { second.fastraFoldRegions.count == 2 })
        #expect(first.textView.textStorage === second.textView.textStorage)
    }

    @Test("Normales Speichern erhält gemischte Zeilenenden und UTF-16-BOM exakt")
    @MainActor func sharedSourceSavePreservesMixedLineEndings() throws {
        let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Mixed.txt")
        let source = "one\r\ntwo\nthree\rfour 😀\r\n"
        let bytes = Data([0xff, 0xfe]) + source.data(using: .utf16LittleEndian)!
        try bytes.write(to: file)
        let loaded = try FileLoader.load(url: file)
        var tab = EditorTab(title: file.lastPathComponent, path: directory.path, content: loaded.content,
                            encoding: loaded.encoding, bom: loaded.bom, lineEnding: loaded.lineEnding)
        tab.url = file; tab.diskSnapshot = try FileSnapshot.readSnapshotOnly(from: file)
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra.tests.mixed.save.\(UUID())"))
        workspace.tabs = [tab]; workspace.activeTabID = tab.id
        try #require(workspace.write(tab: workspace.tabs[0], to: file))
        #expect(try Data(contentsOf: file) == bytes)
        #expect(workspace.activeTab?.content == source)
        workspace.setActiveLineEnding(.lf)
        try #require(workspace.write(tab: workspace.tabs[0], to: file))
        let converted = LineEnding.lf.converting(source)
        #expect(try Data(contentsOf: file) == Data([0xff, 0xfe]) + converted.data(using: .utf16LittleEndian)!)
        #expect(workspace.activeTab?.content == converted)
        #expect(workspace.activeTab?.pendingLineEndingConversion == nil)
        workspace.activeTabContent.wrappedValue += "tail\n"
        try #require(workspace.write(tab: workspace.tabs[0], to: file))
        #expect(try Data(contentsOf: file) == Data([0xff, 0xfe]) + (converted + "tail\n").data(using: .utf16LittleEndian)!)
    }

    @Test("Unabhängiges Scrollen färbt auch den zweiten gemeinsamen Quellausschnitt")
    @MainActor func sharedStorageHighlightsBothViewports() async throws {
        let source = (1...240).map { "// Comment \($0) 😀\n" }.joined()
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra.tests.split.highlight.\(UUID())"))
        workspace.tabs = [EditorTab(title: "test.4dm", path: "-", content: source)]
        workspace.activeTabID = workspace.tabs[0].id
        let storage = workspace.activeTab!.undoHistory.textStorage(for: source)
        let coordinators = [SourcePaneCoordinator(workspace: workspace, pane: .primary),
                            SourcePaneCoordinator(workspace: workspace, pane: .secondary)]
        let controllers = coordinators.map { coordinator in
            TextViewController(string: "", language: .default,
                configuration: .init(appearance: .init(theme: EditorView.fastraTheme,
                    font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false, tabWidth: 4)),
                cursorPositions: [], highlightProviders: [FourDHighlightProvider()], coordinators: [coordinator])
        }
        let windows = controllers.map { controller in
            controller.textView.setTextStorage(storage)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            controller.view.layoutSubtreeIfNeeded()
            controller.textView.layoutManager.layoutLines()
            return window
        }
        defer { windows.forEach { $0.close() } }
        let expected = try #require(controllers[0].attributesFor(.comment)[.foregroundColor] as? NSColor)
        func hasColor(_ offset: Int) -> Bool {
            guard let color = storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor else { return false }
            return color.usingColorSpace(.sRGB) == expected.usingColorSpace(.sRGB)
        }
        #expect(await waitUntil { hasColor(0) })
        let lowerOffset = (source as NSString).range(of: "// Comment 100").location
        try #require(lowerOffset != NSNotFound)
        let second = controllers[1].textView!
        let rect = try #require(second.layoutManager.rectForOffset(lowerOffset))
        _ = second.scrollToVisible(rect)
        second.layoutManager.layoutLines()
        try #require(await waitUntil { second.visibleTextRanges.contains(where: { NSLocationInRange(lowerOffset, $0) }) })
        #expect(await waitUntil { hasColor(lowerOffset) })
        #expect(hasColor(0))
        #expect(controllers[0].textView.string == source && second.string == source)
    }

    @Test("Echte SwiftUI-Teilung färbt beide getrennten sichtbaren Quellbereiche")
    @MainActor func splitHostHighlightsBothViewports() async throws {
        let source = "Function example()\r\nIf (True)\r\n" + (1...240).map {
            "// Line \($0) 😀" + ["\r\n", "\n", "\r"][($0 - 1) % 3]
        }.joined() + "End if\r\n"
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra.tests.split.host.highlight.\(UUID())"))
        var tab = EditorTab(title: "Example.4dm", path: "-", content: source)
        tab.url = testTemporaryDirectory().appendingPathComponent("Example.4dm")
        workspace.tabs = [tab]; workspace.activeTabID = tab.id; workspace.sourceSplitEnabled = true
        try #require(EditorView.customLanguage(for: workspace.activeTab)?.id == CustomLanguageRegistry.fourD.id)
        let configuration = SourceEditorConfiguration(appearance: .init(theme: CustomLanguageRegistry.fourD.lightTheme,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false, tabWidth: 4))
        let host = NSHostingController(rootView: SourceSplitEditor(workspace: workspace, language: .default, configuration: configuration))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = host
        defer { window.close() }
        host.view.layoutSubtreeIfNeeded()
        try #require(await waitUntil { workspace.sourcePanes.view(for: .secondary, documentID: tab.documentID) != nil })
        let first = try #require(workspace.sourcePanes.view(for: .primary, documentID: tab.documentID))
        let second = try #require(workspace.sourcePanes.view(for: .secondary, documentID: tab.documentID))
        let offset = (source as NSString).range(of: "// Line 100").location
        let rect = try #require(second.layoutManager.rectForOffset(offset))
        _ = second.scrollToVisible(rect)
        second.layoutManager.layoutLines()
        try #require(await waitUntil { second.visibleTextRanges.contains(where: { NSLocationInRange(offset, $0) }) })
        let expected = CustomLanguageRegistry.fourD.lightTheme.comments.color.usingColorSpace(.sRGB)
        func hasColor(_ index: Int) -> Bool {
            let color = first.textStorage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
            return color?.usingColorSpace(.sRGB) == expected
        }
        let top = (source as NSString).range(of: "// Line 1 ").location
        #expect(await waitUntil { hasColor(top) })
        #expect(await waitUntil { hasColor(offset) })
        func drawnColor(_ view: TextView, offset: Int) -> NSColor? {
            view.layoutManager.layoutLines()
            for fragmentView in view.subviews.compactMap({ $0 as? LineFragmentView }) {
                guard let fragment = fragmentView.lineFragment,
                      NSLocationInRange(offset, fragment.documentRange) else { continue }
                for content in fragment.contents {
                    guard case .text(let line) = content.data else { continue }
                    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                        let attributes = CTRunGetAttributes(run) as NSDictionary
                        if let color = attributes[NSAttributedString.Key.foregroundColor.rawValue] as? NSColor {
                            return color.usingColorSpace(.sRGB)
                        }
                        if let raw = attributes[kCTForegroundColorAttributeName as String],
                           CFGetTypeID(raw as CFTypeRef) == CGColor.typeID {
                            return NSColor(cgColor: raw as! CGColor)?.usingColorSpace(.sRGB)
                        }
                    }
                }
            }
            return nil
        }
        #expect(await waitUntil { drawnColor(second, offset: offset) == expected })
        var darkConfiguration = configuration
        darkConfiguration.appearance.theme = CustomLanguageRegistry.fourD.darkTheme
        host.rootView = SourceSplitEditor(workspace: workspace, language: .default, configuration: darkConfiguration)
        host.view.layoutSubtreeIfNeeded()
        let darkColor = CustomLanguageRegistry.fourD.darkTheme.comments.color.usingColorSpace(.sRGB)
        #expect(await waitUntil { drawnColor(second, offset: offset) == darkColor })
        host.rootView = SourceSplitEditor(workspace: workspace, language: .default, configuration: configuration)
        host.view.layoutSubtreeIfNeeded()
        #expect(await waitUntil { drawnColor(second, offset: offset) == expected })
        #expect(first.textStorage === second.textStorage)
    }

    @Test("Sprung im aktiven unteren Ausschnitt aktualisiert die sichtbare Cursorzeile")
    @MainActor func splitRangeJumpUpdatesFooter() async throws {
        let source = (1...240).map { "Line \($0) 😀\r\n" }.joined()
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra.tests.split.footer.\(UUID())"))
        let tab = EditorTab(title: "Example.txt", path: "-", content: source)
        workspace.tabs = [tab]; workspace.activeTabID = tab.id; workspace.sourceSplitEnabled = true
        let configuration = SourceEditorConfiguration(appearance: .init(theme: EditorView.fastraTheme,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false, tabWidth: 4))
        let host = NSHostingController(rootView: SourceSplitEditor(workspace: workspace, language: .default, configuration: configuration))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = host
        defer { window.close() }
        host.view.layoutSubtreeIfNeeded()
        try #require(await waitUntil { workspace.sourcePanes.view(for: .secondary, documentID: tab.documentID) != nil })
        let first = try #require(workspace.sourcePanes.view(for: .primary, documentID: tab.documentID))
        let second = try #require(workspace.sourcePanes.view(for: .secondary, documentID: tab.documentID))
        #expect(window.makeFirstResponder(second))
        try #require(await waitUntil { workspace.sourcePanes.activePane == .secondary })
        second.selectionManager.setSelectedRange((source as NSString).range(of: "Line 100"))
        try #require(await waitUntil { workspace.cursorLine == 100 })
        let upperSelection = first.selectedRange()
        let target = (source as NSString).range(of: "Line 200")
        NotificationCenter.default.post(name: .fastraJumpToRange, object: workspace,
                                        userInfo: ["range": NSValue(range: target)])
        try #require(await waitUntil { second.selectedRange() == target })
        #expect(first.selectedRange() == upperSelection)
        #expect(await waitUntil { workspace.cursorLine == 200 })
        #expect(workspace.activeTab?.content == source)
    }

    @Test("Minimaps der echten Teilung folgen dem gemeinsamen Textspeicher")
    @MainActor func splitHostMinimapsFollowSharedStorage() async throws {
        let source = "    " + String(repeating: "Wort 😀 ", count: 100) + "\nzweite Zeile\n"
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra.tests.split.minimap.\(UUID())"))
        let tab = EditorTab(title: "Example.txt", path: "-", content: source)
        workspace.tabs = [tab]; workspace.activeTabID = tab.id; workspace.sourceSplitEnabled = true
        let configuration = SourceEditorConfiguration(appearance: .init(theme: EditorView.fastraTheme,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: true, tabWidth: 4),
            peripherals: .init(showMinimap: true))
        let host = NSHostingController(rootView: SourceSplitEditor(workspace: workspace, language: .default, configuration: configuration))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = host
        defer { window.close() }
        host.view.layoutSubtreeIfNeeded()
        try #require(await waitUntil { workspace.sourcePanes.view(for: .secondary, documentID: tab.documentID) != nil })
        for pane in [SourcePaneID.primary, .secondary] {
            let view = try #require(workspace.sourcePanes.view(for: pane, documentID: tab.documentID))
            var responder: NSResponder? = view
            while responder != nil && !(responder is TextViewController) { responder = responder?.nextResponder }
            let controller = try #require(responder as? TextViewController)
            let mini = try #require(controller.minimapView)
            controller.view.layoutSubtreeIfNeeded()
            view.layoutManager.layoutLines(); mini.synchronizeFastraFragmentGeometry()
            let manager = try #require(mini.layoutManager)
            manager.layoutLines()
            let editorLine = try #require(view.layoutManager.textLineForIndex(0))
            let miniLine = try #require(manager.textLineForIndex(0))
            #expect(editorLine.range == miniLine.range, "Minimap hängt an einer anderen Textbasis: \(pane)")
            #expect(editorLine.data.lineFragments.map(\.range) == miniLine.data.lineFragments.map(\.range))
        }
    }

}
