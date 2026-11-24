import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Fastra

@Suite("Textablauf-Sitzung: Generation, Speicher und Plattenintegration", .serialized)
struct TextWorkflowSessionTests {
    @Test("Reservierte Ziele werden vor einem neuen Read abgewiesen; unbeteiligte Dateien bleiben lesbar")
    @MainActor func serialRunnerIntegrationOpeningFence() async throws {
        try await fixture { ws, _, _, root in
            let target = root.appendingPathComponent("target.txt"), other = root.appendingPathComponent("other.txt")
            try Data("target".utf8).write(to: target); try Data("other".utf8).write(to: other)
            let mutation = try ws.beginTextWorkflowDiskMutation(urls: [target.canonicalFileURL])
            var blocked: FileLoadOutcome?
            ws.loadFile(atCanonicalURL: target.canonicalFileURL, outcome: { blocked = $0 })
            #expect(blocked == .busyLoading && !ws.tabs.contains { $0.url == target.canonicalFileURL })
            var opened: FileLoadOutcome?
            ws.loadFile(atCanonicalURL: other.canonicalFileURL, outcome: { opened = $0 })
            #expect(await waitUntil { opened != nil })
            #expect(opened == .opened && ws.activeTab?.content == "other")
            ws.finishTextWorkflowDiskMutation(mutation, changedURLs: [], session: nil)
            opened = nil
            ws.loadFile(atCanonicalURL: target.canonicalFileURL, outcome: { opened = $0 })
            #expect(await waitUntil { opened != nil })
            #expect(opened == .opened && ws.activeTab?.content == "target")
        }
    }
    @Test("Die Pfadreservierung sperrt den echten Editor vor dem Hintergrund-Preflight")
    @MainActor func serialRunnerIntegrationNativeEditorFence() async throws {
        try await fixture { ws, window, _, root in
            let url = root.appendingPathComponent("one.txt")
            try Data("one".utf8).write(to: url)
            ws.tabs[0].url = url
            let host = NSHostingView(rootView: EditorView().environmentObject(ws))
            window.contentView = host; window.alphaValue = 0; window.orderBack(nil)
            #expect(await waitUntil { CommandTargeting.editorTextView(for: ws)?.isEditable == true })
            let editor = try #require(CommandTargeting.editorTextView(for: ws))
            let mutation = try ws.beginTextWorkflowDiskMutation(urls: [url])
            #expect(!editor.isEditable)
            editor.insertText("X", replacementRange: NSRange(location: 0, length: 0))
            #expect(editor.string == "one" && ws.tabs[0].content == "one")
            ws.finishTextWorkflowDiskMutation(mutation, changedURLs: [], session: nil)
            #expect(await waitUntil { CommandTargeting.editorTextView(for: ws)?.isEditable == true })
        }
    }
    @MainActor private func fixture(_ body: (Workspace, NSWindow, UserDefaults, URL) async throws -> Void) async throws {
        let domain = "fastra-test-workflow-session-" + UUID().uuidString
        let defaults = testSuiteDefaults(named: domain)
        let root = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ws = Workspace(defaults: defaults)
        ws.fileTreeMutationWorkspaceProvider = { [] }
        ws.tabs = [EditorTab(title: "one.txt", path: "", content: "one"), EditorTab(title: "two.txt", path: "", content: "TWO")]
        for index in ws.tabs.indices { ws.tabs[index].recordSavedContentBaseline() }
        ws.activeTabID = ws.tabs[0].id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        WorkspaceWindowRegistry.register(ws, for: window)
        defer {
            ws.textWorkflowSession?.close()
            WorkspaceWindowRegistry.unregister(window); window.close()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        try await body(ws, window, defaults, root)
    }

    @MainActor private func session(_ ws: Workspace, _ window: NSWindow, _ defaults: UserDefaults) throws -> TextWorkflowSession {
        let tab = try #require(ws.activeTab)
        let value = TextWorkflowSession(snapshot: .init(tabID: tab.id, documentID: tab.documentID, url: tab.url,
            revision: tab.contentRevision, source: tab.content, selection: NSRange(location: 0, length: 0), windowID: ObjectIdentifier(window)),
            workspace: ws, store: TextWorkflowStore(defaults: defaults))
        if value.saved.isEmpty {
            value.definition = TextWorkflow(name: "Upper", steps: [.init(kind: .uppercase)])
            #expect(value.save())
        }
        ws.textWorkflowSession = value
        return value
    }

    @MainActor private func applyDocument(in ws: Workspace, window: NSWindow, defaults: UserDefaults) async throws -> TextWorkflowSession {
        window.contentView = NSHostingView(rootView: EditorView().environmentObject(ws))
        window.alphaValue = 0; window.orderBack(nil)
        #expect(await waitUntil { CommandTargeting.editorTextView(for: ws)?.string == "one" })
        let value = try session(ws, window, defaults)
        value.calculate()
        #expect(await waitUntil { value.canApply })
        #expect(value.apply())
        #expect(ws.activeTab?.content == "ONE" && ws.textWorkflowSession == nil)
        return value
    }

    @Test("Die Apply-Rückkehr findet den neu montierten Editor samt Dokumentverlauf")
    @MainActor func serialRunnerIntegrationApplyFocusTargetAfterRemount() async throws {
        try await fixture { ws, window, defaults, _ in
            let value = try await applyDocument(in: ws, window: window, defaults: defaults)
            let previous = try #require(value.editorFocusTargetAfterDismissal()?.editor)
            let history = try #require(previous.undoManager)
            #expect(ws.activeTab?.contentRevision != value.snapshot.revision)
            window.contentView = NSHostingView(rootView: EditorView().environmentObject(ws))
            #expect(await waitUntil {
                guard let target = value.editorFocusTargetAfterDismissal() else { return false }
                return target.editor !== previous && target.editor.string == "ONE"
            })
            let target = try #require(value.editorFocusTargetAfterDismissal())
            #expect(target.window === window && target.editor.undoManager === history)
            history.undo()
            #expect(await waitUntil { ws.activeTab?.content == "one" && target.editor.string == "one" })
            history.redo()
            #expect(await waitUntil { ws.activeTab?.content == "ONE" && target.editor.string == "ONE" })
        }
    }

    @Test("Eine verspätete Apply-Rückkehr bleibt beim Ursprung und wird ohne Key-Fenster verworfen")
    @MainActor func serialRunnerIntegrationApplyFocusTargetGuards() async throws {
        try await fixture { ws, window, defaults, _ in
            let value = try await applyDocument(in: ws, window: window, defaults: defaults)
            #expect(value.editorFocusTargetAfterDismissal() != nil)
            ws.activeTabID = ws.tabs[1].id
            #expect(value.editorFocusTargetAfterDismissal() == nil)
            ws.activeTabID = ws.tabs[0].id
            let documentID = ws.tabs[0].documentID
            ws.tabs[0].documentID = UUID()
            #expect(value.editorFocusTargetAfterDismissal() == nil)
            ws.tabs[0].documentID = documentID
            #expect(value.editorFocusTargetAfterDismissal() != nil)
            #expect(!window.isKeyWindow)
            let otherWindow = NSWindow()
            #expect(!value.finishEditorFocusAfterSheetEnd(in: otherWindow))
            value.cancelEditorFocusIfKeyWindowChanged(to: window)
            #expect(value.editorFocusTargetAfterDismissal() != nil)
            #expect(value.finishEditorFocusAfterSheetEnd(in: window))
            #expect(value.editorFocusTargetAfterDismissal() == nil)
            #expect(!window.isKeyWindow)
        }
    }

    @Test("Ein anderes Schlüsselfenster verbraucht die ausstehende Apply-Fokusrückgabe")
    @MainActor func serialRunnerIntegrationApplyFocusDoesNotSurviveWindowSwitch() async throws {
        try await fixture { ws, window, defaults, _ in
            let value = try await applyDocument(in: ws, window: window, defaults: defaults)
            #expect(value.editorFocusTargetAfterDismissal() != nil)
            value.cancelEditorFocusIfKeyWindowChanged(to: NSWindow())
            value.cancelEditorFocusIfKeyWindowChanged(to: window)
            #expect(value.editorFocusTargetAfterDismissal() == nil)
        }
    }

    @Test("Eine geöffnete und sofort geschlossene Folgesitzung lässt den alten Fokusauftrag nicht wiederaufleben")
    @MainActor func serialRunnerIntegrationApplyFocusDoesNotSurviveReplacement() async throws {
        try await fixture { ws, window, defaults, _ in
            let value = try await applyDocument(in: ws, window: window, defaults: defaults)
            #expect(value.editorFocusTargetAfterDismissal() != nil)
            let next = try session(ws, window, defaults)
            #expect(!next.finishEditorFocusAfterSheetEnd(in: window))
            next.close()
            #expect(value.editorFocusTargetAfterDismissal() == nil)
        }
    }

    @Test("Abbruch und Bereichswechsel verhindern verspätete Vorschauen")
    @MainActor func generation() async throws {
        try await fixture { ws, window, defaults, _ in
            let value = try session(ws, window, defaults)
            value.scope = .openDocuments
            value.calculate(); value.abortCalculation()
            #expect(!value.isBusy && value.batch == nil && !value.canApply)
            value.calculate(); value.scope = .document
            try await Task.sleep(for: .milliseconds(100))
            #expect(value.batch == nil && value.preview == nil && !value.canApply)
            value.scope = .openDocuments; value.calculate()
            #expect(await waitUntil { value.canApply })
            #expect(value.batch?.entries.count == 2)
        }
    }

    @Test("Gemeinsame Rücknahme überlebt das Schließen des Dialogs und bleibt geschützt")
    @MainActor func memoryRestoreAfterReopen() async throws {
        try await fixture { ws, window, defaults, _ in
            let value = try session(ws, window, defaults)
            value.scope = .openDocuments; value.calculate()
            #expect(await waitUntil { value.canApply })
            #expect(value.apply())
            #expect(ws.tabs.map(\.content) == ["ONE", "TWO"])
            value.close()
            let reopened = try session(ws, window, defaults)
            #expect(reopened.canRestoreDocuments)
            reopened.restoreDocuments()
            #expect(ws.tabs.map(\.content) == ["one", "TWO"])
            reopened.restoreDocuments()
            ws.tabs[1].documentID = UUID()
            #expect(!reopened.canRestoreDocuments)
            reopened.restoreDocuments()
            #expect(reopened.error != nil && ws.tabs.map(\.content) == ["ONE", "TWO"])
        }
    }

    @Test("Plattenvorschau schützt externe Änderungen einer vorher wirkungslosen Eingabe")
    @MainActor func serialRunnerIntegrationStaleDisk() async throws {
        try await fixture { ws, window, defaults, root in
            let one = root.appendingPathComponent("one.txt"), two = root.appendingPathComponent("two.txt")
            try Data("one".utf8).write(to: one); try Data("TWO".utf8).write(to: two)
            let value = try session(ws, window, defaults)
            value.scope = .folder; value.folderURLs = [root]
            ws.folderApplyBackupRoot = root.appendingPathComponent("journal")
            value.calculate()
            #expect(await waitUntil { value.canApply })
            #expect(value.batch?.entries.count == 2)
            try Data("external".utf8).write(to: two)
            #expect(value.apply())
            #expect(await waitUntil { !value.isBusy })
            #expect(value.error != nil && value.diskAppliedSession == nil && !value.canApply)
            #expect(try Data(contentsOf: one) == Data("one".utf8))
            #expect(try Data(contentsOf: two) == Data("external".utf8))
            #expect(ws.textEditingIsAllowed(for: ws.tabs[0]))
        }
    }

    @Test("Viele nachträgliche Konflikte lassen die Dialogaktionen bei Mindestgröße erreichbar")
    @MainActor func serialRunnerIntegrationLongConflictLayout() async throws {
        try await fixture { ws, window, defaults, root in
            ws.tabs = try (0..<40).map { index in
                let name = "\(index)-" + String(repeating: "a", count: 180) + ".txt"
                let url = root.appendingPathComponent(name).canonicalFileURL
                try Data("one".utf8).write(to: url)
                var tab = EditorTab(title: name, path: url.path, url: url, content: "one")
                tab.recordSavedContentBaseline()
                return tab
            }
            ws.activeTabID = ws.tabs[0].id
            let value = try session(ws, window, defaults)
            value.scope = .folder; value.folderURLs = [root]
            value.calculate()
            #expect(await waitUntil { value.canApply })
            for index in ws.tabs.indices { ws.tabs[index].content = "dirty"; ws.tabs[index].isDirty = true }
            #expect(value.apply())
            #expect(await waitUntil { !value.isBusy && value.error != nil })
            #expect(value.error?.contains(ws.tabs.last!.title) == true)
            let host = NSHostingView(rootView: TextWorkflowSheet(session: value))
            window.contentView = host
            window.setContentSize(NSSize(width: 900, height: 760))
            window.alphaValue = 0; window.orderBack(nil)
            func marker(_ id: String, in view: NSView) -> NSView? {
                if view.accessibilityIdentifier() == id { return view }
                for child in view.subviews { if let found = marker(id, in: child) { return found } }
                return nil
            }
            #expect(await waitUntil { marker("textWorkflowClose", in: host) != nil })
            #expect(await waitUntil {
                guard let scroll = marker("textWorkflowErrorContent", in: host)?.enclosingScrollView,
                      let document = scroll.documentView else { return false }
                return scroll.contentView.bounds.height > 20 && scroll.contentView.bounds.height <= 96
                    && document.bounds.height > scroll.contentView.bounds.height + 20
            })
            host.layoutSubtreeIfNeeded()
            let errorMarker = try #require(marker("textWorkflowErrorContent", in: host))
            let scroll = try #require(errorMarker.enclosingScrollView)
            let document = try #require(scroll.documentView)
            let beforeScroll = scroll.contentView.bounds.origin
            let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
            scroll.contentView.scroll(to: NSPoint(x: beforeScroll.x, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            #expect(abs(scroll.contentView.bounds.minY - beforeScroll.y) > 10)
            #expect(abs(scroll.contentView.bounds.minY - bottom) < 1)
            let viewport = NSRect(x: 0, y: 0, width: 900, height: 760)
            for id in ["textWorkflowName", "textWorkflowPreview", "textWorkflowClose", "textWorkflowApply"] {
                let control = try #require(marker(id, in: host))
                #expect(viewport.contains(control.convert(NSPoint.zero, to: host)), "\(id) außerhalb der Mindestansicht")
            }
            for tab in ws.tabs { #expect(try Data(contentsOf: tab.url!) == Data("one".utf8)) }
        }
    }

    @Test("Projektwurzel mit aufgelöster Schreibweise bleibt über Datei-Set Punkt vollständig verwendbar")
    @MainActor func serialRunnerIntegrationProjectRootSpelling() async throws {
        try await fixture { ws, window, defaults, root in
            let file = root.appendingPathComponent("one.txt")
            try Data("one".utf8).write(to: file)
            let standardPath = root.standardizedFileURL.path
            #expect(standardPath.hasPrefix("/tmp/"))
            ws.projectURL = URL(fileURLWithPath: "/private" + standardPath, isDirectory: true)
            #expect(FileManager.default.fileExists(atPath: ws.projectURL!.path))
            #expect(ws.projectURL?.path != ws.projectURL?.standardizedFileURL.path)
            let value = try session(ws, window, defaults)
            value.scope = .project
            let source = try value.fileSource()
            #expect(source.roots == [ws.projectURL!.standardizedFileURL])
            value.calculate()
            #expect(await waitUntil { value.canApply || value.error != nil })
            #expect(value.batch?.entries.count == 1 && value.canApply && value.error == nil)
            #expect(try Data(contentsOf: file) == Data("one".utf8))
        }
    }

    @Test("Platten-Apply und Rücknahme laden saubere Dokumente in allen Fenstern neu")
    @MainActor func serialRunnerIntegrationReloadAndUndo() async throws {
        try await fixture { ws, window, defaults, root in
            let input = root.appendingPathComponent("input.txt")
            try Data("one\r\n".utf8).write(to: input)
            let original = try FileSnapshot.read(from: input).snapshot
            let tab = EditorTab(title: "input.txt", path: input.path, url: input, content: "one\r\n", diskSnapshot: original)
            ws.tabs = [tab]; ws.tabs[0].recordSavedContentBaseline(); ws.activeTabID = tab.id
            let other = Workspace(defaults: defaults)
            other.tabs = [EditorTab(title: "input.txt", path: input.path, url: input, content: "one\r\n", diskSnapshot: original)]
            other.tabs[0].recordSavedContentBaseline(); other.activeTabID = other.tabs[0].id
            ws.fileTreeMutationWorkspaceProvider = { [other] }
            let value = try session(ws, window, defaults)
            value.scope = .folder; value.folderURLs = [input]
            ws.folderApplyBackupRoot = root.appendingPathComponent("journal")
            value.calculate(); #expect(await waitUntil { value.canApply })
            #expect(value.apply())
            #expect(await waitUntil { !value.isBusy && ws.tabs[0].content == "ONE\r\n" && other.tabs[0].content == "ONE\r\n" })
            #expect(try Data(contentsOf: input) == Data("ONE\r\n".utf8))
            #expect(!ws.tabs[0].hasUnsavedChanges && !other.tabs[0].hasUnsavedChanges)
            value.restoreDisk()
            #expect(await waitUntil { !value.isBusy && ws.tabs[0].content == "one\r\n" && other.tabs[0].content == "one\r\n" })
            #expect(value.diskAppliedSession == nil && ws.lastApplySession == nil)
            #expect(try Data(contentsOf: input) == Data("one\r\n".utf8))
        }
    }

    @Test("Die Rücknahme eines älteren Ablaufs erhält eine neuere unabhängige Plattensitzung")
    @MainActor func serialRunnerIntegrationKeepNewerSession() async throws {
        try await fixture { ws, window, defaults, root in
            let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt")
            try Data("first".utf8).write(to: first); try Data("second".utf8).write(to: second)
            ws.folderApplyBackupRoot = root.appendingPathComponent("journal")
            let value = try session(ws, window, defaults)
            value.scope = .folder; value.folderURLs = [first]; value.calculate()
            #expect(await waitUntil { value.canApply })
            #expect(value.apply()); #expect(await waitUntil { !value.isBusy && value.diskAppliedSession != nil })
            let workflow = value.definition, backupRoot = ws.folderApplyBackupRoot
            let newer = try await Task.detached {
                let plan = try TextWorkflowFilePlan.build(workflow, inputs: [.init(url: second)])
                return try ApplyEngine.execute(workflowPlan: plan, backupRoot: backupRoot)
            }.value
            ws.lastApplySession = newer
            value.restoreDisk(); #expect(await waitUntil { !value.isBusy })
            #expect(value.diskAppliedSession == nil && ws.lastApplySession?.sessionDirectory == newer.sessionDirectory)
            #expect(try Data(contentsOf: first) == Data("first".utf8))
            #expect(try Data(contentsOf: second) == Data("SECOND".utf8))
        }
    }
    @Test("Cleanup-only bleibt im Textablauf und im Workspace bis zur echten Wiederholung erhalten")
    @MainActor func serialRunnerIntegrationCleanupOnlyRetry() async throws {
        try await fixture { ws, window, defaults, root in
            let targets = root.appendingPathComponent("targets", isDirectory: true)
            try FileManager.default.createDirectory(at: targets, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: targets.path) }
            let original = targets.appendingPathComponent("original.txt")
            try Data("original".utf8).write(to: original)
            let originalSnapshot = try FileSnapshot.readSnapshotOnly(from: original)
            let pending = try ApplyPendingFile.prepare(Data("partial".utf8),
                at: targets.appendingPathComponent("own-partial.tmp"))
            let directory = root.appendingPathComponent("session")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let partial = ApplySession(timestamp: Date(), sessionDirectory: directory,
                                       entries: [], retainedPendingFiles: [pending])
            try ApplyEngine.writeManifest(partial)
            let value = try session(ws, window, defaults)
            value.scope = .folder
            let mutation = try ws.beginTextWorkflowDiskMutation(urls: [original])
            value.finishDiskOperation(.failure(ApplyError.writeFailed(partial: partial, message: "prepare rejected")),
                undo: nil, in: ws, mutation: mutation, heldEditors: [])
            #expect(value.diskAppliedSession == partial && ws.lastApplySession == partial)
            #expect(value.error == TextWorkflowFailure.message(ApplyError.writeFailed(partial: partial, message: "prepare rejected")))
            #expect(!partial.undoResourceURLs().isEmpty)
            #expect(!partial.undoResourceURLs().contains(original))

            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: targets.path)
            value.restoreDisk()
            #expect(await waitUntil { !value.isBusy })
            #expect(value.error != nil && value.diskAppliedSession == partial && ws.lastApplySession == partial)
            #expect(try FileSnapshot.readSnapshotOnly(from: original) == originalSnapshot)
            #expect(try FileSnapshot.readSnapshotOnly(from: pending.url) == pending.snapshot)

            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: targets.path)
            value.restoreDisk()
            #expect(await waitUntil { !value.isBusy })
            #expect(value.error == nil && value.diskAppliedSession == nil && ws.lastApplySession == nil)
            #expect(value.status == L10n.string("Die eigenen temporären Dateien wurden aufgeräumt. Die Zieldateien blieben unverändert."))
            #expect(try FileSnapshot.readSnapshotOnly(from: original) == originalSnapshot)
            for url in pending.cleanupResourceURLs { #expect(!FileManager.default.fileExists(atPath: url.path)) }
        }
    }

    @Test("Cleanup-only reserviert echte Ressourcen; Ordner-Retry und ältere Textsitzung behalten den Besitzer")
    @MainActor func serialRunnerIntegrationCleanupOnlyReservationAndOwnership() async throws {
        try await fixture { ws, window, defaults, root in
            let pending = try ApplyPendingFile.prepare(Data("partial".utf8), at: root.appendingPathComponent("own-partial.tmp"))
            let directory = root.appendingPathComponent("session")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let partial = ApplySession(timestamp: Date(), sessionDirectory: directory, entries: [], retainedPendingFiles: [pending])
            try ApplyEngine.writeManifest(partial)
            ws.lastApplySession = partial
            let mutation = try ws.beginTextWorkflowDiskMutation(urls: partial.undoResourceURLs())
            var conflict: String?
            ws.folderPreviewConflictHandler = { conflict = $0 }
            #expect(!(await ws.undoLastFolderApply()) && conflict != nil)
            #expect(try FileSnapshot.readSnapshotOnly(from: pending.url) == pending.snapshot)
            ws.finishTextWorkflowDiskMutation(mutation, changedURLs: [], session: nil)
            #expect(await ws.undoLastFolderApply() && ws.lastApplySession == nil)
            for url in pending.cleanupResourceURLs { #expect(!FileManager.default.fileExists(atPath: url.path)) }

            let value = try session(ws, window, defaults)
            value.scope = .folder
            let reserved = try ws.beginTextWorkflowDiskMutation(urls: [root])
            value.finishDiskOperation(.failure(ApplyError.writeFailed(partial: partial, message: "prepare rejected")),
                undo: nil, in: ws, mutation: reserved, heldEditors: [])
            let newer = ApplySession(timestamp: Date(), sessionDirectory: root.appendingPathComponent("newer"), entries: [])
            ws.lastApplySession = newer
            let rawFailure = NSError(domain: "CleanupManifest", code: 1,
                                     userInfo: [NSLocalizedDescriptionKey: "manifest rejected"])
            let reservedAgain = try ws.beginTextWorkflowDiskMutation(urls: partial.undoResourceURLs())
            value.finishDiskOperation(.failure(rawFailure), undo: partial, in: ws,
                                     mutation: reservedAgain, heldEditors: [])
            #expect(value.diskAppliedSession == partial && ws.lastApplySession == newer)
            #expect(value.error?.contains("manifest rejected") == true)
            value.restoreDisk()
            #expect(await waitUntil { !value.isBusy })
            #expect(value.diskAppliedSession == nil && ws.lastApplySession == newer)
        }
    }

}
