import Combine
import Foundation
import Testing
@testable import Fastra

private final class HexReloadCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite("Lebenszyklus ungespeicherter Hex-Änderungen")
struct HexEditLifecycleTests {
    @MainActor
    private func makeWorkspace() -> Workspace {
        let suite = "fastra-hex-lifecycle-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        defaults.removePersistentDomain(forName: suite)
        return Workspace(defaults: defaults)
    }

    private func editedSession(old: UInt8 = 0x01, new: UInt8 = 0xFE)
        -> HexEditSession {
        var session = HexEditSession()
        session.editRow(
            String(format: "00 %02X 02 03", new),
            data: Data([0x00, old, 0x02, 0x03]), baseOffset: 0, row: 0
        )
        return session
    }

    @Test("Tab trägt Byteänderungen über Ansichts- und Tabwechsel")
    @MainActor func tabOwnsChangesAcrossViewAndTabSwitches() {
        let workspace = makeWorkspace()
        let file = URL(fileURLWithPath: "/tmp/hex-lifecycle.bin")
        var edited = EditorTab(
            title: file.lastPathComponent, path: file.deletingLastPathComponent().path,
            url: file, content: "", displayMode: .hex, isPreview: true,
            viewMode: .hex
        )
        let other = EditorTab(title: "other.txt", path: "/tmp")
        workspace.tabs = [edited, other]
        workspace.activeTabID = edited.id

        let binding = workspace.hexEditSessionBinding(for: edited.id)
        var edits = binding.wrappedValue
        edits.editRow(
            "00 FE 02 03", data: Data([0x00, 0x01, 0x02, 0x03]),
            baseOffset: 0, row: 0
        )
        binding.wrappedValue = edits
        edited = workspace.tabs[0]
        #expect(edited.hexEditSession.hasChanges)
        #expect(!edited.isPreview, "Eine Hex-Eingabe muss den Vorschau-Tab dauerhaft machen")

        workspace.selectTab(id: other.id)
        workspace.selectTab(id: edited.id)
        #expect(workspace.activeTab?.hexEditSession.preview.first?.newValue == 0xFE)

        workspace.setViewMode(.text)
        #expect(workspace.activeViewMode == .hex,
                "Offene Byteänderungen müssen in ihrer prüfbaren Ansicht bleiben")
        #expect(workspace.availableViewModes == [.hex])
    }

    @Test("Hex-Änderung besitzt dokumentgebundenes Undo und Redo")
    func undoRedoSurvivesValueCopies() throws {
        var session = editedSession()
        #expect(session.canUndo)
        session.undo()
        #expect(!session.hasChanges)
        #expect(session.canRedo)
        var copied = session
        copied.redo()
        #expect(copied.preview.first?.newValue == 0xFE)
        let pendingOperation = copied.beginSave()
        let operation = try #require(pendingOperation)
        let saved = copied.markSaved(operation)
        #expect(saved)
        #expect(!copied.hasChanges)
        #expect(!copied.canUndo)
        #expect(!copied.canRedo)
    }

    @Test("Laufender Save sperrt Änderungen über die View-Lebensdauer hinaus")
    func saveInFlightBlocksMutationsAndKeepsFailures() throws {
        var session = editedSession()
        let pendingOperation = session.beginSave()
        let operation = try #require(pendingOperation)
        let planned = session.preview

        session.editRow("00 AA 02 03", data: Data([0, 1, 2, 3]), baseOffset: 0, row: 0)
        session.undo()
        session.discard()
        #expect(session.preview == planned)
        #expect(session.isSaving)

        session.markSaveFailed(operation, message: "Testfehler")
        #expect(!session.isSaving)
        #expect(session.hasChanges)
        #expect(session.saveErrorMessage == "Testfehler")
        session.clearSaveError()
        #expect(session.saveErrorMessage == nil)
    }

    @Test("Textänderung verwirft veraltetes Hex-Undo und -Redo")
    @MainActor func textMutationStartsANewHexHistoryBranch() {
        let workspace = makeWorkspace()
        var tab = EditorTab(
            title: "branch.txt", path: "/tmp", content: "alt",
            displayMode: .text, viewMode: .hex
        )
        tab.hexEditSession = editedSession()
        tab.hexEditSession.undo()
        let staleSession = tab.hexEditSession
        #expect(staleSession.canRedo)
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id

        workspace.activeTabContent.wrappedValue = "neuer und längerer Text"

        #expect(workspace.tabs[0].isDirty)
        #expect(!workspace.tabs[0].hexEditSession.canUndo)
        #expect(!workspace.tabs[0].hexEditSession.canRedo)

        // Ein schon vor der Textänderung aufgebauter SwiftUI-Schreibwert darf
        // den alten Offset-Zweig auch nach einem späteren Text-Save nicht
        // zurück in den Tab schreiben.
        var delayedRedo = staleSession
        delayedRedo.redo()
        workspace.hexEditSessionBinding(for: tab.id).wrappedValue = delayedRedo
        #expect(!workspace.tabs[0].hexEditSession.hasChanges)

        var lineEndingTab = EditorTab(
            title: "line-endings.txt", path: "/tmp", content: "a\r\nb\r\n",
            lineEnding: .crlf, displayMode: .text
        )
        lineEndingTab.hexEditSession = editedSession()
        lineEndingTab.hexEditSession.undo()
        workspace.tabs = [lineEndingTab]
        workspace.activeTabID = lineEndingTab.id
        #expect(workspace.tabs[0].hexEditSession.canRedo)

        workspace.setActiveLineEnding(.lf)

        #expect(!workspace.tabs[0].hexEditSession.canUndo)
        #expect(!workspace.tabs[0].hexEditSession.canRedo)

        let loadingTab = EditorTab(
            title: "loading.bin", path: "/tmp",
            url: URL(fileURLWithPath: "/tmp/loading.bin"), displayMode: .hex
        )
        workspace.tabs = [loadingTab]
        workspace.activeTabID = loadingTab.id
        var staleDuringReload = workspace.hexEditSessionBinding(
            for: loadingTab.id
        ).wrappedValue
        workspace.tabs[0].isLoading = true
        staleDuringReload.editRow(
            "FE 01 02 03", data: Data([0x00, 0x01, 0x02, 0x03]),
            baseOffset: 0, row: 0
        )
        workspace.hexEditSessionBinding(
            for: loadingTab.id
        ).wrappedValue = staleDuringReload
        #expect(!workspace.tabs[0].hexEditSession.hasChanges)
    }

    @Test("Ungültige Zeile erklärt den Fehler und verändert keine Bytes")
    func invalidRowKeepsChangesUntouched() {
        var session = editedSession()
        let before = session.preview
        session.editRow("GG", data: Data([0x00]), baseOffset: 0, row: 0)
        #expect(session.preview == before)
        #expect(session.invalidRowMessage != nil)
    }

    @Test("Schließen mit Hex-Änderung führt zur Vorschau statt zum Verlust")
    @MainActor func closeRoutesToPreview() {
        let workspace = makeWorkspace()
        let keep = EditorTab(title: "keep.txt", path: "/tmp")
        var edited = EditorTab(
            title: "edited.bin", path: "/tmp",
            url: URL(fileURLWithPath: "/tmp/edited.bin"),
            displayMode: .hex
        )
        edited.hexEditSession = editedSession()
        workspace.tabs = [keep, edited]
        workspace.activeTabID = keep.id
        workspace.confirmHexCloseHandler = { _ in .save }

        workspace.closeTab(id: edited.id)

        #expect(workspace.tabs.map(\.id) == [keep.id, edited.id])
        #expect(workspace.activeTabID == edited.id)
        #expect(workspace.activeViewMode == .hex)
        #expect(workspace.hexSavePreviewRequestTabID == edited.id)
        #expect(workspace.hasTabsRequiringSaveBeforeClosing)
    }

    @Test("Bewusstes Nicht-Sichern verwirft Hex-Änderungen beim Schließen")
    @MainActor func closeCanExplicitlyDiscard() {
        let workspace = makeWorkspace()
        let keep = EditorTab(title: "keep.txt", path: "/tmp")
        var edited = EditorTab(title: "edited.bin", path: "/tmp", displayMode: .hex)
        edited.hexEditSession = editedSession()
        workspace.tabs = [keep, edited]
        workspace.activeTabID = edited.id
        workspace.confirmHexCloseHandler = { _ in .dontSave }

        workspace.closeTab(id: edited.id)

        #expect(workspace.tabs.map(\.id) == [keep.id])
        #expect(workspace.activeTabID == keep.id)
    }

    @Test("Beenden bleibt für offene Hex-Vorschau gesperrt")
    @MainActor func quitRoutesHexChangesToPreview() {
        let workspace = makeWorkspace()
        let keep = EditorTab(title: "keep.txt", path: "/tmp")
        var edited = EditorTab(title: "edited.bin", path: "/tmp", displayMode: .hex)
        edited.hexEditSession = editedSession()
        workspace.tabs = [keep, edited]
        workspace.activeTabID = keep.id
        workspace.confirmHexCloseHandler = { _ in .save }

        #expect(!workspace.confirmCloseAllDirtyForQuit())
        #expect(workspace.tabs.first { $0.id == edited.id }?.hexEditSession.hasChanges == true)
        #expect(workspace.hexSavePreviewRequestTabID == edited.id)
        #expect(workspace.activeTabID == edited.id,
                "Die Vorschau eines Hintergrund-Tabs muss beim Beenden sichtbar werden")
    }

    @Test("Fenster- und Mehrfachschließen zeigen den betroffenen Hex-Tab")
    @MainActor func multiCloseRoutesToAffectedHexTab() {
        for closeAttempt in [
            { (workspace: Workspace, _: UUID) in workspace.prepareToCloseWindow() },
            { (workspace: Workspace, keepID: UUID) in
                workspace.closeOtherTabs(keeping: keepID)
                return workspace.tabs.count == 1
            },
        ] {
            let workspace = makeWorkspace()
            let keep = EditorTab(title: "keep.txt", path: "/tmp")
            var edited = EditorTab(title: "edited.bin", path: "/tmp", displayMode: .hex)
            edited.hexEditSession = editedSession()
            workspace.tabs = [keep, edited]
            workspace.activeTabID = keep.id
            workspace.confirmHexCloseHandler = { _ in .save }

            #expect(!closeAttempt(workspace, keep.id))
            #expect(workspace.activeTabID == edited.id)
            #expect(workspace.hexSavePreviewRequestTabID == edited.id)
            #expect(workspace.tabs.count == 2)
        }
    }

    @Test("Laufender Hex-Save blockiert Schließen und Neuladen")
    @MainActor func activeSaveCannotBeDiscardedOrReloaded() throws {
        let workspace = makeWorkspace()
        let keep = EditorTab(title: "keep.txt", path: "/tmp")
        var edited = EditorTab(
            title: "edited.bin", path: "/tmp",
            url: URL(fileURLWithPath: "/tmp/edited.bin"), displayMode: .hex
        )
        edited.hexEditSession = editedSession()
        var savingSession = edited.hexEditSession
        let pendingOperation = savingSession.beginSave()
        _ = try #require(pendingOperation)
        edited.hexEditSession = savingSession
        workspace.tabs = [keep, edited]
        workspace.activeTabID = keep.id
        var closePrompted = false
        workspace.confirmHexCloseHandler = { _ in
            closePrompted = true
            return .dontSave
        }
        let reloads = HexReloadCallCounter()
        workspace.reloadFileLoader = { _ in
            reloads.increment()
            throw CancellationError()
        }
        let reopens = HexReloadCallCounter()
        workspace.reopenFileLoader = { _, _ in
            reopens.increment()
            throw CancellationError()
        }

        workspace.closeTab(id: edited.id)
        workspace.reloadTabFromDisk(id: edited.id)
        workspace.reopenActiveTab(withEncoding: .utf8)

        #expect(!closePrompted)
        #expect(workspace.tabs.contains { $0.id == edited.id })
        #expect(workspace.activeTabID == edited.id)
        #expect(reloads.value == 0)
        #expect(reopens.value == 0)
        #expect(workspace.tabs.first { $0.id == edited.id }?
            .hexEditSession.isSaving == true)
    }

    @Test("Projektwechsel und Vorschau-Reuse behandeln Hex-Änderungen als Arbeit")
    @MainActor func projectTransitionKeepsHexWork() {
        let root = URL(fileURLWithPath: "/tmp/new-project", isDirectory: true)
        var edited = EditorTab(
            title: "outside.bin", path: "/tmp",
            url: URL(fileURLWithPath: "/tmp/outside.bin"),
            displayMode: .hex, isPreview: true
        )
        edited.hexEditSession = editedSession()

        let remaining = Workspace.tabsAfterOpeningProject([edited], root: root)

        #expect(remaining.map(\.id) == [edited.id])
        #expect(remaining[0].hasUnsavedChanges)
    }

    @Test("Papierkorb sperrt offene und währenddessen neue Hex-Änderungen")
    @MainActor func trashOperationProtectsHexChanges() throws {
        let workspace = makeWorkspace()
        let secondWindowWorkspace = makeWorkspace()
        let directory = URL(fileURLWithPath: "/tmp/hex-trash", isDirectory: true)
        let file = directory.appendingPathComponent("edited.bin")
        let outside = URL(fileURLWithPath: "/tmp/outside.bin")
        var edited = EditorTab(
            title: file.lastPathComponent, path: directory.path, url: file,
            displayMode: .hex
        )
        edited.hexEditSession = editedSession()
        workspace.tabs = [EditorTab(title: "first.txt", path: "/tmp")]
        secondWindowWorkspace.tabs = [edited]
        secondWindowWorkspace.activeTabID = edited.id
        workspace.fileTreeMutationWorkspaceProvider = {
            [weak workspace, weak secondWindowWorkspace] in
            [workspace, secondWindowWorkspace].compactMap { $0 }
        }
        var blockedTitles: [String] = []
        workspace.fileTreeTrashConflictHandler = { blockedTitles = $0 }

        #expect(workspace.beginFileTreeTrash(directory) == nil)
        #expect(blockedTitles == [edited.title])
        #expect(secondWindowWorkspace.hexSavePreviewRequestTabID == edited.id)

        secondWindowWorkspace.tabs[0].hexEditSession.discard()
        let operation = try #require(workspace.beginFileTreeTrash(directory))
        #expect(workspace.fileTreeTrashIsInFlight(for: file))
        #expect(secondWindowWorkspace.fileTreeTrashIsInFlight(for: file))
        #expect(!workspace.fileTreeTrashIsInFlight(for: outside))
        workspace.finishFileTreeTrash(operation)
        #expect(!workspace.fileTreeTrashIsInFlight(for: file))
        #expect(!secondWindowWorkspace.fileTreeTrashIsInFlight(for: file))

        // Umbenennen darf dagegen stattfinden, muss aber jeden geöffneten
        // Dokument-Tab auf den neuen Pfad umhängen — auch im zweiten Fenster.
        secondWindowWorkspace.tabs[0].hexEditSession = editedSession()
        let renamed = directory.appendingPathComponent("renamed.bin")
        workspace.handleFileTreeMove(from: file, to: renamed)
        #expect(secondWindowWorkspace.tabs[0].url == renamed.canonicalFileURL)
        #expect(secondWindowWorkspace.tabs[0].hexEditSession.hasChanges)
    }

    @Test("Später registriertes Fenster übernimmt laufende Papierkorb-Sperre")
    @MainActor func trashOperationIncludesLateWorkspace() throws {
        let workspace = makeWorkspace()
        let lateWorkspace = makeWorkspace()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-late-trash-\(UUID().uuidString)",
                                    isDirectory: true)
        let file = directory.appendingPathComponent("late.bin")
        var provided = [workspace]
        workspace.fileTreeMutationWorkspaceProvider = { provided }

        let operation = try #require(workspace.beginFileTreeTrash(directory))
        let lateTab = EditorTab(
            title: file.lastPathComponent, path: directory.path, url: file,
            displayMode: .hex
        )
        let chunkedTab = EditorTab(
            title: "large.txt", path: directory.path,
            url: directory.appendingPathComponent("large.txt"),
            displayMode: .chunkedText
        )
        lateWorkspace.tabs = [lateTab, chunkedTab]
        lateWorkspace.activeTabID = lateTab.id
        provided.append(lateWorkspace)

        #expect(lateWorkspace.fileTreeTrashIsInFlight(for: file))
        var attempted = lateWorkspace.hexEditSessionBinding(for: lateTab.id).wrappedValue
        attempted.editRow(
            "FE 01 02 03", data: Data([0x00, 0x01, 0x02, 0x03]),
            baseOffset: 0, row: 0
        )
        lateWorkspace.hexEditSessionBinding(for: lateTab.id).wrappedValue = attempted
        #expect(!lateWorkspace.tabs[0].hexEditSession.hasChanges)

        workspace.handleFileTreeTrash(directory, operation: operation)
        #expect(!lateWorkspace.tabs.contains { $0.id == lateTab.id })
        #expect(!lateWorkspace.tabs.contains { $0.id == chunkedTab.id })
        #expect(lateWorkspace.tabs.count == 1)
        #expect(lateWorkspace.tabs[0].isPristineScratch)
        workspace.finishFileTreeTrash(operation)
        #expect(!lateWorkspace.fileTreeTrashIsInFlight(for: file))
    }

    @Test("Papierkorb entfernt einen noch ladenden Platzhalter")
    @MainActor func trashRemovesLoadingPlaceholder() {
        let workspace = makeWorkspace()
        let file = URL(fileURLWithPath: "/tmp/loading-while-trashed.txt")
        let loadingTab = EditorTab(
            title: file.lastPathComponent, path: "/tmp", url: file,
            content: "", displayMode: .text, isLoading: true
        )
        workspace.tabs = [loadingTab]
        workspace.activeTabID = loadingTab.id

        workspace.handleFileTreeTrash(file)

        #expect(!workspace.tabs.contains { $0.id == loadingTab.id })
        #expect(workspace.tabs.count == 1)
        #expect(workspace.tabs[0].isPristineScratch)
    }

    @Test("Umbenennen teilt die appweite Dateioperations-Sperre")
    @MainActor func moveOperationSharesPathLock() throws {
        let workspace = makeWorkspace()
        let secondWindowWorkspace = makeWorkspace()
        let lateWorkspace = makeWorkspace()
        let directory = URL(fileURLWithPath: "/tmp/hex-move", isDirectory: true)
        let source = directory.appendingPathComponent("source.bin")
        let destination = directory.appendingPathComponent("destination.bin")
        var tab = EditorTab(
            title: source.lastPathComponent, path: directory.path, url: source,
            displayMode: .hex
        )
        tab.hexEditSession = editedSession()
        let pendingSaveCandidate = tab.hexEditSession.beginSave()
        let pendingSave = try #require(pendingSaveCandidate)
        secondWindowWorkspace.tabs = [tab]
        secondWindowWorkspace.activeTabID = tab.id
        var provided = [workspace, secondWindowWorkspace]
        workspace.fileTreeMutationWorkspaceProvider = { provided }
        var conflicts: [String] = []
        workspace.fileTreeMoveConflictHandler = { conflicts = $0 }

        #expect(workspace.beginFileTreeMove(from: source, to: destination) == nil)
        #expect(conflicts == [tab.title])

        secondWindowWorkspace.tabs[0].hexEditSession.markSaveFailed(
            pendingSave, message: "absichtlich abgebrochen"
        )
        secondWindowWorkspace.discardHexChanges(HexEditActionContext(tab: tab))
        let operation = try #require(workspace.beginFileTreeMove(
            from: source, to: destination
        ))
        lateWorkspace.tabs = [EditorTab(
            title: source.lastPathComponent, path: directory.path, url: source,
            displayMode: .hex
        )]
        provided.append(lateWorkspace)

        #expect(workspace.fileMutationIsInFlight(for: source))
        #expect(secondWindowWorkspace.fileMutationIsInFlight(for: destination))
        #expect(lateWorkspace.fileMutationIsInFlight(for: source))
        var unexpectedTrashConflict: [String] = []
        workspace.fileTreeTrashConflictHandler = {
            unexpectedTrashConflict = $0
        }
        #expect(workspace.beginFileTreeTrash(directory) == nil)
        #expect(unexpectedTrashConflict.isEmpty,
                "Die Pfadsperre, nicht eine verbliebene Hex-Änderung, muss blockieren")

        workspace.handleFileTreeMove(
            from: source, to: destination, operation: operation
        )
        #expect(secondWindowWorkspace.tabs[0].url == destination.canonicalFileURL)
        #expect(lateWorkspace.tabs[0].url == destination.canonicalFileURL)
        workspace.finishFileTreeMove(operation)
        #expect(!workspace.fileMutationIsInFlight(for: source))
        #expect(!lateWorkspace.fileMutationIsInFlight(for: destination))
    }

    @Test("Verschwundene Datei schützt Volltext trotz offener Hex-Änderung")
    @MainActor func missingFileProtectsTextIndependentlyOfHexChanges() {
        let workspace = makeWorkspace()
        let file = URL(fileURLWithPath: "/tmp/missing-with-hex.txt")
        var tab = EditorTab(
            title: file.lastPathComponent, path: file.deletingLastPathComponent().path,
            url: file, content: "letzte vollständige Fassung\n",
            displayMode: .text,
            diskSnapshot: FileSnapshot(
                data: Data("letzte vollständige Fassung\n".utf8), identity: nil
            )
        )
        tab.hexEditSession = editedSession()
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id

        workspace.tabs[0].protectContentAfterExternalFileBecameUnavailable()
        workspace.discardHexChanges(HexEditActionContext(tab: tab))
        workspace.setViewMode(.text)

        #expect(workspace.tabs[0].isDirty)
        #expect(workspace.tabs[0].hasUnsavedChanges)
        #expect(workspace.tabs[0].content == "letzte vollständige Fassung\n")
        #expect(workspace.activeViewMode == .text)
    }

    @Test("Hex-Verwerfen lädt den zuvor bestätigten externen Stand")
    @MainActor func discardReloadsAcceptedExternalState() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-hex-discard-external-\(UUID().uuidString).txt")
            .canonicalFileURL
        try Data("alter Stand\n".utf8).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let oldSnapshot = try FileSnapshot.read(from: file).snapshot
        let workspace = makeWorkspace()
        var tab = EditorTab(
            title: file.lastPathComponent, path: file.deletingLastPathComponent().path,
            url: file, content: "alter Stand\n", displayMode: .text,
            fileSize: UInt64(oldSnapshot.byteCount), diskSnapshot: oldSnapshot,
            viewMode: .hex
        )
        tab.hexEditSession = editedSession()
        try Data("bestätigter externer Stand\n".utf8).write(to: file, options: .atomic)
        let acceptedSnapshot = try FileSnapshot.read(from: file).snapshot
        tab.recordExternalFileObservation(snapshot: acceptedSnapshot, observation: nil)
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id

        workspace.discardHexChanges(HexEditActionContext(tab: tab))

        #expect(await waitUntil {
            !workspace.tabs[0].isLoading
                && workspace.tabs[0].content == "bestätigter externer Stand\n"
        })
        #expect(workspace.tabs[0].diskSnapshot?.hasSameContent(
            as: acceptedSnapshot
        ) == true)
        #expect(!workspace.tabs[0].hasUnsavedChanges)
    }

    @Test("Snapshotloser Hex-Tab lädt den bestätigten Fremdstand")
    @MainActor func snapshotlessHexTabReloadsAcceptedExternalState() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-hex-snapshotless-\(UUID().uuidString).bin")
            .canonicalFileURL
        try Data([0x10, 0x20, 0x30, 0x40]).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let workspace = makeWorkspace()
        var tab = EditorTab(
            title: file.lastPathComponent,
            path: file.deletingLastPathComponent().path,
            url: file, displayMode: .hex, diskSnapshot: nil, viewMode: .hex
        )
        tab.hexEditSession = editedSession()
        tab.recordExternalFileObservation(
            snapshot: nil, observation: nil, contentChangeAccepted: true
        )
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        let calls = HexReloadCallCounter()
        workspace.reloadFileLoader = { url in
            calls.increment()
            return try FileLoader.load(url: url)
        }

        workspace.discardHexChanges(HexEditActionContext(tab: tab))

        #expect(await waitUntil {
            calls.value == 1 && !workspace.tabs[0].isLoading
        })
        #expect(workspace.tabs[0].externalContentGeneration
                == workspace.tabs[0].displayedExternalContentGeneration)
        #expect(!workspace.tabs[0].hasUnsavedChanges)
    }

    @Test("Hex-Eingabe bis zum Original lädt den bestätigten Fremdstand")
    @MainActor func editingBackToOriginalReloadsAcceptedExternalState() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-hex-edit-original-\(UUID().uuidString).txt")
            .canonicalFileURL
        try Data("alter Stand\n".utf8).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let oldSnapshot = try FileSnapshot.read(from: file).snapshot
        let workspace = makeWorkspace()
        var tab = EditorTab(
            title: file.lastPathComponent,
            path: file.deletingLastPathComponent().path,
            url: file, content: "alter Stand\n", displayMode: .text,
            fileSize: UInt64(oldSnapshot.byteCount), diskSnapshot: oldSnapshot,
            viewMode: .hex
        )
        tab.hexEditSession = editedSession()
        try Data("bestätigter Fremdstand\n".utf8).write(to: file, options: .atomic)
        let acceptedSnapshot = try FileSnapshot.read(from: file).snapshot
        tab.recordExternalFileObservation(snapshot: acceptedSnapshot, observation: nil)
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id

        workspace.editHexRow(
            HexEditActionContext(tab: tab),
            text: "00 01 02 03", data: Data([0x00, 0x01, 0x02, 0x03]),
            baseOffset: 0, row: 0
        )

        #expect(await waitUntil {
            !workspace.tabs[0].isLoading
                && workspace.tabs[0].content == "bestätigter Fremdstand\n"
        })
        #expect(!workspace.tabs[0].hasUnsavedChanges)
        #expect(workspace.tabs[0].diskSnapshot?.hasSameContent(
            as: acceptedSnapshot
        ) == true)
    }

    @Test("Verwerfen und Save-Rückmeldungen weisen alte Binding-Kopien ab")
    @MainActor func finalizedBranchesRejectStaleBindingValues() throws {
        let workspace = makeWorkspace()
        var discardedTab = EditorTab(
            title: "discard.bin", path: "/tmp", displayMode: .hex
        )
        discardedTab.hexEditSession = editedSession()
        workspace.tabs = [discardedTab]
        workspace.activeTabID = discardedTab.id
        let staleDiscard = workspace.hexEditSessionBinding(
            for: discardedTab.id
        ).wrappedValue

        workspace.discardHexChanges(HexEditActionContext(tab: discardedTab))
        workspace.hexEditSessionBinding(
            for: discardedTab.id
        ).wrappedValue = staleDiscard
        #expect(!workspace.tabs[0].hexEditSession.hasChanges)

        var savedTab = EditorTab(
            title: "saved.bin", path: "/tmp",
            url: URL(fileURLWithPath: "/tmp/saved.bin"), displayMode: .hex
        )
        savedTab.hexEditSession = editedSession()
        workspace.tabs = [savedTab]
        workspace.activeTabID = savedTab.id
        let staleSave = workspace.hexEditSessionBinding(for: savedTab.id).wrappedValue
        let operationCandidate = workspace.beginHexSave(
            HexEditActionContext(tab: savedTab)
        )
        let operation = try #require(operationCandidate)
        #expect(workspace.finishHexSave(operation, for: savedTab.id))
        workspace.hexEditSessionBinding(for: savedTab.id).wrappedValue = staleSave
        #expect(!workspace.tabs[0].hexEditSession.hasChanges)

        var failedTab = EditorTab(
            title: "failed.bin", path: "/tmp",
            url: URL(fileURLWithPath: "/tmp/failed.bin"), displayMode: .hex
        )
        failedTab.hexEditSession = editedSession()
        workspace.tabs = [failedTab]
        workspace.activeTabID = failedTab.id
        let staleBeforeFailure = workspace.hexEditSessionBinding(
            for: failedTab.id
        ).wrappedValue
        workspace.editHexRow(
            HexEditActionContext(tab: failedTab),
            text: "00 FE FC 03",
            data: Data([0x00, 0x01, 0x02, 0x03]), baseOffset: 0, row: 0
        )
        let failedPreview = workspace.tabs[0].hexEditSession.preview
        let failedOperationCandidate = workspace.beginHexSave(
            HexEditActionContext(tab: failedTab)
        )
        let failedOperation = try #require(failedOperationCandidate)
        workspace.failHexSave(
            failedOperation, for: failedTab.id, message: "Testfehler"
        )
        workspace.hexEditSessionBinding(
            for: failedTab.id
        ).wrappedValue = staleBeforeFailure
        #expect(workspace.tabs[0].hexEditSession.preview == failedPreview)
    }

    @Test("Save-Fehler löst Sperre trotz extern gerettetem Text")
    @MainActor func saveFailureUnlocksExternallyProtectedText() throws {
        let workspace = makeWorkspace()
        let file = URL(fileURLWithPath: "/tmp/hex-save-missing.txt")
        var tab = EditorTab(
            title: file.lastPathComponent, path: "/tmp", url: file,
            content: "letzte Textkopie\n", displayMode: .text,
            diskSnapshot: FileSnapshot(
                data: Data("letzte Textkopie\n".utf8), identity: nil
            ), viewMode: .hex
        )
        tab.hexEditSession = editedSession()
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        let operationCandidate = workspace.beginHexSave(
            HexEditActionContext(tab: tab)
        )
        let operation = try #require(operationCandidate)
        workspace.tabs[0].protectContentAfterExternalFileBecameUnavailable()

        workspace.failHexSave(operation, for: tab.id, message: "Datei fehlt")

        #expect(!workspace.tabs[0].hexEditSession.isSaving)
        #expect(workspace.tabs[0].hexEditSession.hasChanges)
        #expect(workspace.tabs[0].hexEditSession.saveErrorMessage == "Datei fehlt")
        #expect(workspace.tabs[0].isDirty)
        workspace.discardHexChanges(HexEditActionContext(tab: tab))
        #expect(workspace.tabs[0].isDirty)
        #expect(!workspace.tabs[0].hexEditSession.hasChanges)
    }

    @Test("Hex-Save reserviert den Pfad appweit")
    @MainActor func hexSaveUsesProcessWidePathLock() throws {
        let first = makeWorkspace()
        let second = makeWorkspace()
        let file = URL(fileURLWithPath: "/tmp/shared-hex-save.bin")
        var firstTab = EditorTab(
            title: file.lastPathComponent, path: "/tmp", url: file,
            displayMode: .hex
        )
        var secondTab = EditorTab(
            title: file.lastPathComponent, path: "/tmp", url: file,
            displayMode: .hex
        )
        firstTab.hexEditSession = editedSession()
        secondTab.hexEditSession = editedSession(old: 0x02, new: 0xFD)
        first.tabs = [firstTab]
        first.activeTabID = firstTab.id
        second.tabs = [secondTab]
        second.activeTabID = secondTab.id
        first.fileTreeMutationWorkspaceProvider = { [first, second] }
        second.fileTreeMutationWorkspaceProvider = { [first, second] }

        let firstOperationCandidate = first.beginHexSave(
            HexEditActionContext(tab: firstTab)
        )
        let firstOperation = try #require(firstOperationCandidate)
        #expect(first.fileMutationIsInFlight(for: file))
        #expect(second.fileMutationIsInFlight(for: file))
        #expect(second.beginHexSave(HexEditActionContext(tab: secondTab)) == nil)

        first.failHexSave(firstOperation, for: firstTab.id, message: "Testende")
        #expect(!first.fileMutationIsInFlight(for: file))
        let secondOperationCandidate = second.beginHexSave(
            HexEditActionContext(tab: secondTab)
        )
        let secondOperation = try #require(secondOperationCandidate)
        second.failHexSave(secondOperation, for: secondTab.id, message: "Testende")
        #expect(!second.fileMutationIsInFlight(for: file))
    }

    @Test("Hex-Verwerfen bewahrt einen dirty Volltext trotz neuem Fremdstand")
    @MainActor func discardKeepsProtectedDirtyTextAgainstAcceptedExternalState() {
        let workspace = makeWorkspace()
        let file = URL(fileURLWithPath: "/tmp/protected-reappeared.txt")
        let oldSnapshot = FileSnapshot(
            data: Data("geretteter Text\n".utf8), identity: nil
        )
        let externalSnapshot = FileSnapshot(
            data: Data("neu auf Platte\n".utf8), identity: nil
        )
        var tab = EditorTab(
            title: file.lastPathComponent, path: "/tmp", url: file,
            content: "geretteter Text\n", displayMode: .text,
            isDirty: true, diskSnapshot: oldSnapshot, viewMode: .hex
        )
        tab.hexEditSession = editedSession()
        tab.recordExternalFileObservation(snapshot: externalSnapshot, observation: nil)
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id

        workspace.discardHexChanges(HexEditActionContext(tab: tab))

        #expect(workspace.tabs[0].content == "geretteter Text\n")
        #expect(workspace.tabs[0].isDirty)
        #expect(!workspace.tabs[0].isLoading)
        #expect(workspace.tabs[0].externalContentSnapshot == externalSnapshot)
    }

    @Test("Viele Hex-Zeilen wachsen über direkte Dokumentaktionen")
    @MainActor func manyHexRowsUseDirectDocumentMutation() {
        let workspace = makeWorkspace()
        let file = URL(fileURLWithPath: "/tmp/many-hex-rows.bin")
        let tab = EditorTab(
            title: file.lastPathComponent, path: "/tmp", url: file,
            displayMode: .hex
        )
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        // Bildet die während eines SwiftUI-Renderdurchlaufs gehaltene
        // `EditorTab`-Wertkopie nach. Sie teilt nur den dokumentgebundenen
        // Session-Speicher und erzwingt deshalb keine Dictionary-Vollkopie.
        let uiSnapshot = workspace.tabs[0]
        let rowData = Data(repeating: 0, count: 16)
        let editedRow = "FE 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"
        let actionContext = HexEditActionContext(tab: tab)

        for row in 0..<10_000 {
            workspace.editHexRow(
                actionContext,
                text: editedRow, data: rowData,
                baseOffset: UInt64(row * 16), row: 0
            )
        }

        #expect(workspace.tabs[0].hexEditSession.preview.count == 10_000)
        #expect(workspace.tabs[0].hexEditSession.canUndo)
        #expect(workspace.tabs[0].hexEditSession.changeRevision == 10_000)
        #expect(uiSnapshot.hexEditSession.preview.count == 10_000)
    }

    @Test("Verzögerte Hex-Aktion trifft keinen wiederverwendeten Vorschau-Tab")
    @MainActor func staleActionDoesNotHitReusedPreviewSlot() {
        let workspace = makeWorkspace()
        let oldDocumentID = UUID()
        let reusedTabID = UUID()
        let replacementDocumentID = UUID()
        let file = URL(fileURLWithPath: "/tmp/reused-preview.bin")
        let replacement = EditorTab(
            id: reusedTabID, title: file.lastPathComponent, path: "/tmp",
            url: file, displayMode: .hex, isPreview: true,
            documentID: replacementDocumentID
        )
        workspace.tabs = [replacement]
        workspace.activeTabID = reusedTabID

        let staleContext = HexEditActionContext(
            tabID: reusedTabID, documentID: oldDocumentID,
            editingLineageID: replacement.hexEditSession.editingLineageID,
            fileURL: file
        )
        workspace.editHexRow(
            staleContext,
            text: "FE 01 02 03", data: Data([0x00, 0x01, 0x02, 0x03]),
            baseOffset: 0, row: 0
        )

        #expect(workspace.tabs[0].documentID == replacementDocumentID)
        #expect(!workspace.tabs[0].hexEditSession.hasChanges)
        #expect(workspace.tabs[0].isPreview)
        #expect(workspace.beginHexSave(staleContext) == nil)
    }

    @Test("Verzögerte Hex-Zeile trifft keine neu geladene Dateibasis")
    @MainActor func staleRowActionDoesNotHitReloadedDocument() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-hex-stale-row-\(UUID().uuidString).bin")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let oldSnapshot = try FileSnapshot.read(from: file).snapshot
        let workspace = makeWorkspace()
        let tab = EditorTab(
            title: file.lastPathComponent,
            path: file.deletingLastPathComponent().path,
            url: file, displayMode: .hex,
            fileSize: UInt64(oldSnapshot.byteCount), diskSnapshot: oldSnapshot,
            viewMode: .hex
        )
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        let staleContext = HexEditActionContext(tab: tab)

        try Data([0x10, 0x11, 0x12, 0x13]).write(to: file, options: .atomic)
        workspace.reloadTabFromDisk(id: tab.id)
        #expect(await waitUntil {
            !workspace.tabs[0].isLoading
                && workspace.tabs[0].diskSnapshot != oldSnapshot
        })

        workspace.editHexRow(
            staleContext,
            text: "FE 01 02 03", data: Data([0x00, 0x01, 0x02, 0x03]),
            baseOffset: 0, row: 0
        )

        #expect(!workspace.tabs[0].hexEditSession.hasChanges)
        #expect(workspace.tabs[0].hexEditSession.editingLineageID
            != staleContext.editingLineageID)
    }

    @Test("Eine Hex-Zeile veröffentlicht genau eine Workspace-Änderung")
    @MainActor func rowEditPublishesWorkspaceOnce() {
        let workspace = makeWorkspace()
        let tab = EditorTab(
            title: "publish.bin", path: "/tmp",
            url: URL(fileURLWithPath: "/tmp/publish.bin"), displayMode: .hex,
            isPreview: true
        )
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        var publicationCount = 0
        let observation = workspace.objectWillChange.sink {
            publicationCount += 1
        }

        workspace.editHexRow(
            HexEditActionContext(tab: tab),
            text: "FE 01 02 03", data: Data([0x00, 0x01, 0x02, 0x03]),
            baseOffset: 0, row: 0
        )

        #expect(publicationCount == 1)
        withExtendedLifetime(observation) {}
    }

    @Test("Alte Hex-Aktionen verändern keinen neuen Bearbeitungszweig")
    @MainActor func staleActionsDoNotMutateNewEditingBranch() {
        let workspace = makeWorkspace()
        let file = URL(fileURLWithPath: "/tmp/stale-hex-actions.bin")
        var tab = EditorTab(
            title: file.lastPathComponent, path: "/tmp", url: file,
            displayMode: .hex, viewMode: .hex
        )
        tab.hexEditSession = editedSession()
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        let staleContext = HexEditActionContext(tab: tab)

        workspace.discardHexChanges(staleContext)
        let currentContext = HexEditActionContext(tab: workspace.tabs[0])
        workspace.editHexRow(
            currentContext,
            text: "00 FD 02 03", data: Data([0x00, 0x01, 0x02, 0x03]),
            baseOffset: 0, row: 0
        )
        let currentPreview = workspace.tabs[0].hexEditSession.preview

        workspace.discardHexChanges(staleContext)
        workspace.undoHexChange(staleContext)

        #expect(workspace.tabs[0].hexEditSession.preview == currentPreview)
        #expect(workspace.beginHexSave(staleContext) == nil)
    }

    @Test("Geteilter Hex-Speicher verändert den Tab-Hash nicht")
    func sharedHexStorageKeepsStableTabHash() {
        let file = URL(fileURLWithPath: "/tmp/stable-tab-hash.bin")
        let tab = EditorTab(
            title: file.lastPathComponent, path: "/tmp", url: file,
            displayMode: .hex
        )
        var copiedTab = tab
        let originalHash = tab.hashValue
        let storedTabs: Set<EditorTab> = [tab]

        copiedTab.hexEditSession.editRow(
            "00 FE 02 03", data: Data([0x00, 0x01, 0x02, 0x03]),
            baseOffset: 0, row: 0
        )

        #expect(tab.hashValue == originalHash)
        #expect(copiedTab.hashValue == originalHash)
        #expect(storedTabs.contains(copiedTab))
    }

    @Test("Hex-Save entwertet betroffene Ordner-Suchvorschau")
    @MainActor func hexWriteInvalidatesFolderPreview() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-hex-search-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("result.txt")
        try Data("foo\n".utf8).write(to: file, options: .atomic)
        let workspace = makeWorkspace()
        let options = SearchOptions(
            find: "foo", replace: "bar", isRegex: false, caseSensitive: true
        )
        workspace.scope = .folder
        workspace.findPattern = "foo"
        workspace.replacePattern = "bar"
        workspace.useRegex = false
        workspace.caseSensitive = true
        workspace.folderResults = [
            FolderSearch.searchOneFile(at: file, options: options)
        ]
        workspace.folderNeedsSearch = false
        workspace.fileTreeMutationWorkspaceProvider = { [workspace] }

        workspace.handleHexWrite(at: file)

        #expect(workspace.folderResults.isEmpty)
        #expect(workspace.folderNeedsSearch)
        #expect(!workspace.applyAllInFolder())
    }

    @Test("Hex-Undo bis leer lädt den zuvor bestätigten externen Stand")
    @MainActor func undoToEmptyReloadsAcceptedExternalState() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-hex-undo-external-\(UUID().uuidString).txt")
            .canonicalFileURL
        try Data("vorher\n".utf8).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let oldSnapshot = try FileSnapshot.read(from: file).snapshot
        let workspace = makeWorkspace()
        var tab = EditorTab(
            title: file.lastPathComponent, path: file.deletingLastPathComponent().path,
            url: file, content: "vorher\n", displayMode: .text,
            fileSize: UInt64(oldSnapshot.byteCount), diskSnapshot: oldSnapshot,
            viewMode: .hex
        )
        tab.hexEditSession = editedSession()
        try Data("nachher und länger\n".utf8).write(to: file, options: .atomic)
        let acceptedSnapshot = try FileSnapshot.read(from: file).snapshot
        tab.recordExternalFileObservation(snapshot: acceptedSnapshot, observation: nil)
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id

        workspace.undoHexChange(HexEditActionContext(tab: tab))

        #expect(await waitUntil {
            !workspace.tabs[0].isLoading
                && workspace.tabs[0].content == "nachher und länger\n"
        })
        #expect(!workspace.tabs[0].hasUnsavedChanges)
    }

    @Test("Ordner-Apply und Rückgängig schützen Hex-Tabs in allen Fenstern")
    @MainActor func folderApplyAndUndoProtectAllWorkspaces() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-hex-folder-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("target.txt")
        try Data("foo sichtbar\n".utf8).write(to: file, options: .atomic)

        let workspace = makeWorkspace()
        let otherWorkspace = makeWorkspace()
        let snapshot = try FileSnapshot.read(from: file).snapshot
        var otherTab = EditorTab(
            title: file.lastPathComponent, path: directory.path, url: file,
            content: "foo sichtbar\n", displayMode: .text,
            diskSnapshot: snapshot
        )
        otherTab.hexEditSession = editedSession()
        otherWorkspace.tabs = [otherTab]
        otherWorkspace.activeTabID = otherTab.id
        workspace.fileTreeMutationWorkspaceProvider = {
            [workspace, otherWorkspace]
        }
        var blockedTitles: [String] = []
        workspace.folderApplyConflictHandler = { blockedTitles = $0 }

        let options = SearchOptions(
            find: "foo", replace: "bar", isRegex: false, caseSensitive: true
        )
        workspace.scope = .folder
        workspace.findPattern = "foo"
        workspace.replacePattern = "bar"
        workspace.useRegex = false
        workspace.caseSensitive = true
        workspace.folderResults = [
            FolderSearch.searchOneFile(at: file, options: options)
        ]
        workspace.folderSearching = false
        workspace.folderNeedsSearch = false
        workspace.folderApplyBackupRoot = directory.appendingPathComponent(
            "undo", isDirectory: true
        )

        #expect(!workspace.applyAllInFolder())
        #expect(blockedTitles == [file.lastPathComponent])
        #expect(try Data(contentsOf: file) == Data("foo sichtbar\n".utf8))

        otherWorkspace.tabs[0].hexEditSession.discard()
        #expect(workspace.applyAllInFolder())
        #expect(otherWorkspace.fileMutationIsInFlight(for: file))
        #expect(!workspace.prepareToCloseWindow())
        #expect(!workspace.confirmCloseAllDirtyForQuit())
        otherWorkspace.activeTabContent.wrappedValue = "lokaler Rennstand\n"
        otherWorkspace.saveActiveTab()
        #expect(otherWorkspace.tabs[0].content == "foo sichtbar\n")
        var attempted = otherWorkspace.hexEditSessionBinding(
            for: otherTab.id
        ).wrappedValue
        attempted.editRow(
            "FE 6F 6F 20", data: Data("foo ".utf8), baseOffset: 0, row: 0
        )
        otherWorkspace.hexEditSessionBinding(for: otherTab.id).wrappedValue = attempted
        #expect(!otherWorkspace.tabs[0].hexEditSession.hasChanges)

        #expect(await waitUntil { !workspace.folderApplying })
        #expect(await waitUntil {
            !otherWorkspace.tabs[0].isLoading
                && otherWorkspace.tabs[0].content == "bar sichtbar\n"
        })
        #expect(!otherWorkspace.fileMutationIsInFlight(for: file))

        otherWorkspace.tabs[0].hexEditSession = editedSession()
        #expect(!workspace.undoLastFolderApply())
        #expect(try Data(contentsOf: file) == Data("bar sichtbar\n".utf8))

        otherWorkspace.tabs[0].hexEditSession.discard()
        #expect(workspace.undoLastFolderApply())
        #expect(try Data(contentsOf: file) == Data("foo sichtbar\n".utf8))
        #expect(await waitUntil {
            !otherWorkspace.tabs[0].isLoading
                && otherWorkspace.tabs[0].content == "foo sichtbar\n"
        })
    }

    @Test("Hex-Save lädt saubere Tabs derselben Datei in allen Fenstern neu")
    @MainActor func hexWriteReloadsAllWorkspaces() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-hex-multiwindow-\(UUID().uuidString).txt")
        try Data("alter Stand\n".utf8).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let snapshot = try FileSnapshot.read(from: file).snapshot
        let first = makeWorkspace()
        let second = makeWorkspace()
        let firstTab = EditorTab(
            title: file.lastPathComponent, path: file.deletingLastPathComponent().path,
            url: file, content: "alter Stand\n", displayMode: .text,
            fileSize: UInt64(snapshot.byteCount), diskSnapshot: snapshot
        )
        let secondTab = EditorTab(
            title: file.lastPathComponent, path: file.deletingLastPathComponent().path,
            url: file, content: "alter Stand\n", displayMode: .text,
            fileSize: UInt64(snapshot.byteCount), diskSnapshot: snapshot
        )
        first.tabs = [firstTab]
        first.activeTabID = firstTab.id
        second.tabs = [secondTab]
        second.activeTabID = secondTab.id
        first.fileTreeMutationWorkspaceProvider = { [first, second] }

        try Data("neuer Stand in beiden Fenstern\n".utf8)
            .write(to: file, options: .atomic)
        first.handleHexWrite(at: file)

        #expect(await waitUntil {
            !first.tabs[0].isLoading && !second.tabs[0].isLoading
                && first.tabs[0].content == "neuer Stand in beiden Fenstern\n"
                && second.tabs[0].content == "neuer Stand in beiden Fenstern\n"
        })
    }

    @Test("Text-Save aktualisiert Hex-Größe und verwirft alte Byte-Historie")
    @MainActor func textSaveRefreshesHexDiskState() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-text-save-size-\(UUID().uuidString).txt")
        try Data("a\r\n".utf8).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let snapshot = try FileSnapshot.read(from: file).snapshot
        let workspace = makeWorkspace()
        var tab = EditorTab(
            title: file.lastPathComponent, path: file.deletingLastPathComponent().path,
            url: file, content: "deutlich längerer Stand\n", lineEnding: .lf,
            displayMode: .text, fileSize: UInt64(snapshot.byteCount),
            isDirty: true, diskSnapshot: snapshot, viewMode: .hex
        )
        tab.hexEditSession = editedSession()
        tab.hexEditSession.undo()
        #expect(tab.hexEditSession.canRedo)
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id

        #expect(workspace.write(tab: workspace.tabs[0], to: file))

        let written = try Data(contentsOf: file)
        #expect(workspace.tabs[0].fileSize == UInt64(written.count))
        #expect(workspace.tabs[0].diskSnapshot?.byteCount == written.count)
        #expect(!workspace.tabs[0].hexEditSession.canRedo)
    }

    @Test("Automatischer Reload überspringt Tabs mit Hex-Änderungen")
    @MainActor func automaticReloadDoesNotDiscardHexChanges() async {
        let workspace = makeWorkspace()
        let file = URL(fileURLWithPath: "/tmp/hex-reload.bin")
        var edited = EditorTab(
            title: file.lastPathComponent, path: "/tmp", url: file,
            displayMode: .hex
        )
        edited.hexEditSession = editedSession()
        workspace.tabs = [edited]
        workspace.activeTabID = edited.id
        let calls = HexReloadCallCounter()
        workspace.reloadFileLoader = { _ in
            calls.increment()
            throw CancellationError()
        }

        workspace.reloadOpenTabs(for: [file])
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(calls.value == 0)
        #expect(workspace.tabs[0].hexEditSession.hasChanges)
    }

    @Test("Fremdänderung fragt bei Hex-Arbeit nach und explizites Neuladen verwirft sie")
    @MainActor func externalChangeProtectsHexChangesUntilConfirmedReload() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-hex-external-\(UUID().uuidString).bin")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let workspace = makeWorkspace()
        var loaded = false
        workspace.loadFile(at: url) { _ in loaded = true }
        #expect(await waitUntil { loaded })
        let index = try #require(
            workspace.tabs.firstIndex { $0.url == url.canonicalFileURL }
        )
        workspace.tabs[index].hexEditSession = editedSession()

        var promptCount = 0
        workspace.externalReloadConfirmHandler = { _ in
            promptCount += 1
            return false
        }
        try Data([0x00, 0xAA, 0x02, 0x03]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: url.path
        )
        workspace.checkExternalChanges()

        #expect(await waitUntil { promptCount == 1 })
        #expect(workspace.tabs[index].hexEditSession.hasChanges,
                "Behalten darf die geplanten Byteänderungen nicht verwerfen")

        workspace.externalReloadConfirmHandler = { _ in
            promptCount += 1
            return true
        }
        workspace.reloadActiveTabFromDisk()

        #expect(await waitUntil {
            !workspace.tabs[index].isLoading
                && !workspace.tabs[index].hexEditSession.hasChanges
        })
        #expect(promptCount == 2)
    }

    @Test("Speichern öffnet die Hex-Vorschau, Speichern unter erklärt seine Grenze")
    @MainActor func saveCommandsStayUnambiguous() {
        let workspace = makeWorkspace()
        let file = URL(fileURLWithPath: "/tmp/hex-save-command.bin")
        var edited = EditorTab(
            title: file.lastPathComponent, path: "/tmp", url: file,
            displayMode: .hex
        )
        edited.hexEditSession = editedSession()
        workspace.tabs = [edited]
        workspace.activeTabID = edited.id

        workspace.saveActiveTab()
        #expect(workspace.hexSavePreviewRequestTabID == edited.id)
        workspace.consumeHexSavePreviewRequest(for: edited.id)

        var warningTitle: String?
        workspace.saveSafetyWarningHandler = { title, _ in warningTitle = title }
        workspace.saveActiveTabAs()
        #expect(workspace.hexSavePreviewRequestTabID == nil)
        #expect(warningTitle == L10n.string("Speichern unter nicht verfügbar"))
        #expect(workspace.tabs[0].hexEditSession.hasChanges)
    }
}
