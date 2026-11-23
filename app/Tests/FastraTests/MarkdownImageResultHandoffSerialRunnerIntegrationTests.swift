import AppKit
import CodeEditTextView
import Darwin
import Foundation
import Testing
@testable import Fastra

private let handoffPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII=")!

@MainActor
private final class HandoffObservations {
    var warnings: [String] = []
    var warningsAtMarker: [String]?
    var pendingFinished = false
}

private final class HandoffSchedule: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseA = DispatchSemaphore(value: 0)
    private let releaseB = DispatchSemaphore(value: 0)
    private let arrivedB = DispatchSemaphore(value: 0)
    private var arrivals = 0
    private var timeouts = 0
    private var claims = 0
    private let followingJobSucceeds: Bool
    private let marker: @MainActor @Sendable () -> Void

    init(followingJobSucceeds: Bool, marker: @escaping @MainActor @Sendable () -> Void) {
        self.followingJobSucceeds = followingJobSucceeds
        self.marker = marker
    }

    var counts: (arrivals: Int, timeouts: Int, claims: Int) {
        lock.withLock { (arrivals, timeouts, claims) }
    }

    func allowA() { releaseA.signal() }
    func allowB() { releaseB.signal() }
    func releaseAll() { releaseA.signal(); releaseB.signal() }

    /// Nur diese begrenzte Testbarriere hält Main kurz an.
    /// A wirft vor seinem Gate; B signalisiert vor seinem Gate und hält dann.
    func awaitBFromMain() -> Bool {
        arrivedB.wait(timeout: .now() + 2) == .success
    }

    var hooks: MarkdownImageRemoval.Hooks {
        .init(afterPreparingDirectory: { [self] _ in
            let number = lock.withLock { arrivals += 1; return arrivals }
            if number == 1 {
                guard releaseA.wait(timeout: .now() + 10) == .success else {
                    lock.withLock { timeouts += 1 }
                    throw POSIXError(.ETIMEDOUT)
                }
                // Kein Claim, kein Main-Gate: A hinterlässt ausschließlich EIO.
                throw POSIXError(.EIO)
            }
            if number == 2 {
                // removePermanently hat lastRemovalResult bereits nil gesetzt.
                // A hat seinen Reporter vor Beginn dieses I/O-Jobs eingereiht.
                arrivedB.signal()
                DispatchQueue.main.async { [marker] in marker() }
                guard releaseB.wait(timeout: .now() + 10) == .success else {
                    lock.withLock { timeouts += 1 }
                    throw POSIXError(.ETIMEDOUT)
                }
                if !followingJobSucceeds { throw POSIXError(.EACCES) }
                return
            }
            throw POSIXError(.EBUSY)
        }, beforeClaim: { [self] _ in lock.withLock { claims += 1 } })
    }
}

// Appweite I/O-Halte laufen ausschließlich in der seriellen Runnerphase.
@Suite
struct MarkdownImageResultHandoffSerialRunnerIntegrationTests {
    @Test("Save-EIO bleibt vor folgendem Discard als eigener Befund erhalten", arguments: [false, true])
    @MainActor
    func savedImageFailureHandoff(followingJobSucceeds: Bool) async throws {
        let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var mayRemoveDirectory = true
        defer { if mayRemoveDirectory { try? FileManager.default.removeItem(at: directory) } }
        let document = directory.appendingPathComponent("note.md")
        try Data().write(to: document)
        let image = try MarkdownImageStore.storePastedData(
            .init(data: handoffPNG, fileExtension: "png"), documentURL: document)
        let suiteName = "fastra-test-image-handoff-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let owner = Workspace(defaults: defaults)
        var tab = EditorTab(title: "note.md", path: directory.path, content: "")
        tab.url = document
        owner.tabs = [tab]
        owner.activeTabID = tab.id
        let history = tab.undoHistory
        let manager = history.manager(for: "")
        let view = TextView(string: "")
        view.setUndoManager(manager)
        view.replaceCharacters(in: NSRange(location: 0, length: 0), with: image.link)
        history.didEditInSource(view.string)
        owner.tabs[0].content = view.string
        try image.link.write(to: document, atomically: true, encoding: .utf8)
        let buffer = MarkdownImageUndoBuffer(byteLimit: 2 * 1024 * 1024)
        let observed = HandoffObservations()
        let schedule = HandoffSchedule(followingJobSucceeds: followingJobSucceeds) {
            observed.warningsAtMarker = observed.warnings
        }
        defer { schedule.releaseAll() }
        MarkdownImageUndo.register(textView: view, insertion: image.link, storedImages: [image],
            documentURL: document, workspace: owner, buffer: buffer, removalHooks: schedule.hooks,
            redoWarningHandler: { _, message in observed.warnings.append(message) })
        mayRemoveDirectory = false

        func cleanUp() async {
            schedule.releaseAll()
            guard await waitUntil({ !manager.isUndoing && !manager.isRedoing }) else {
                Issue.record("Bild-Cleanup: Manager nicht idle; Dateien bleiben in der Sandbox.")
                manager.fastraWhenIdle { [manager] in manager.clearStack() }
                return
            }
            manager.clearStack()
            var drained = false
            MarkdownImageUndoSideEffect.pendingIO.notify(queue: .main) { drained = true }
            guard await waitUntil({ drained }) else {
                Issue.record("Bild-Cleanup: pendingIO nicht abgeschlossen; Dateien bleiben in der Sandbox.")
                return
            }
            mayRemoveDirectory = true
        }

        do {
            manager.undo()
            try #require(await waitUntil { !manager.isUndoing })
            try #require(schedule.counts.arrivals == 0,
                         "Vorbedingung fehlt: gespeicherter Link muss Undo ohne Removalhook schützen.")
            try #require(view.string.isEmpty && view.isEditable && manager.canRedo)
            try #require(observed.warnings.isEmpty)
            #expect(try Data(contentsOf: image.fileURL) == handoffPNG)
            owner.tabs[0].content = view.string
            history.didEditInSource(view.string)
            // Der echte gespeicherte Text enthält nun ebenfalls keinen Verweis.
            try Data().write(to: document)
            manager.fastraDocumentSaved(view.string, at: document)
            try #require(await waitUntil { schedule.counts.arrivals == 1 })
            try #require(!history.isPerformingAction && manager.canRedo)
            manager.clearStack()
            MarkdownImageUndoSideEffect.pendingIO.notify(queue: .main) { observed.pendingFinished = true }

            // A braucht nach Freigabe kein Main: der Hook wirft EIO vor gate().
            // B braucht bis angekommenB ebenfalls kein Main: Referenzsnapshot
            // entstand schon beim Anstellen, sein Hook steht vor gate().
            // Auf zwei Sekunden begrenzte Mainbarriere zur Reihenfolgesicherung.
            try #require(Thread.isMainThread, "Testbarriere verlangt den echten Main-Thread.")
            schedule.allowA()
            let bArrived = schedule.awaitBFromMain()
            try #require(bArrived,
                         "PROBE UNENTSCHIEDEN: B erreichte die vor-Gate-Barriere nicht binnen 2 s. Kein Handoffbefund.")
            try #require(await waitUntil { observed.warningsAtMarker != nil })
            let beforeB = try #require(observed.warningsAtMarker)
            let eio = POSIXError(.EIO).localizedDescription
            let eacces = POSIXError(.EACCES).localizedDescription
            let aWasReported = beforeB.contains { $0.contains(eio) }
            print("IMAGE_RESULT_HANDOFF phase=before_B_failure a_EIO_reported=\(aWasReported ? 1 : 0) warnings=\(beforeB.count) holds=\(schedule.counts.arrivals) main_barrier=bounded_2s")
            #expect(aWasReported,
                    "A scheiterte mit EIO; sein Main-Reporter verlor den Befund vor dem noch angehaltenen B-Abschluss.")
            #expect(!beforeB.contains { $0.contains(eacces) })
            #expect(!observed.pendingFinished && schedule.counts.claims == 0)
            #expect(try Data(contentsOf: image.fileURL) == handoffPNG)
            #expect(try Data(contentsOf: document).isEmpty)
            #expect(view.string.isEmpty && view.isEditable && !manager.canRedo && !manager.canUndo)
            #expect(buffer.byteCount == 0)

            schedule.allowB()
            try #require(await waitUntil { observed.pendingFinished })
            print("IMAGE_RESULT_HANDOFF_MESSAGES following_success=\(followingJobSucceeds) before_B=\(beforeB) after_B=\(observed.warnings)")
            let bWarnings = observed.warnings.filter { $0.contains(eacces) }.count
            #expect(bWarnings == (followingJobSucceeds ? 0 : 1))
            #expect(observed.warnings.filter { $0.contains(eio) }.count == (followingJobSucceeds ? 1 : 2))
            let aMessage = try #require(beforeB.first)
            #expect(beforeB.count == 1 && aMessage.utf8.elementsEqual(eio.utf8))
            let aAfterB = try #require(observed.warnings.first)
            #expect(aAfterB.utf8.elementsEqual(aMessage.utf8))
            if !followingJobSucceeds {
                let bMessage = try #require(observed.warnings.last)
                #expect(bMessage.utf8.elementsEqual([eio, eacces].joined(separator: "\n").utf8))
            }
            #expect(observed.warnings.count == (followingJobSucceeds ? 1 : 2))
            #expect(schedule.counts.arrivals == 2 && schedule.counts.timeouts == 0)
            #expect(schedule.counts.claims == (followingJobSucceeds ? 1 : 0))
            let expectedImageState = followingJobSucceeds
                ? !FileManager.default.fileExists(atPath: image.fileURL.path)
                : try Data(contentsOf: image.fileURL) == handoffPNG
            let historyEmpty = !manager.canRedo && !manager.canUndo
            #expect(expectedImageState)
            #expect(try Data(contentsOf: document).isEmpty)
            #expect(view.string.isEmpty && view.isEditable && historyEmpty)
            #expect(buffer.byteCount == 0)
            print("IMAGE_RESULT_HANDOFF phase=after_B following_success=\(followingJobSucceeds ? 1 : 0) b_warnings=\(bWarnings) expected_image_state=\(expectedImageState ? 1 : 0) history_empty=\(historyEmpty ? 1 : 0) pendingIO_finished=\(observed.pendingFinished ? 1 : 0)")
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }

    @Test("Mehrbild-Teilfehler und Restorefehler bleiben nach erfolgreichem Redo als Vorgangsbefund erhalten")
    @MainActor
    func partialRemovalAndRestoreKeepTheirDetails() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString).canonicalFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var mayRemoveDirectory = true
        defer { if mayRemoveDirectory { try? FileManager.default.removeItem(at: directory) } }
        let document = directory.appendingPathComponent("note.md")
        let images = try (0..<2).map { _ in
            try MarkdownImageStore.storePastedData(.init(data: handoffPNG, fileExtension: "png"), documentURL: document)
        }
        let buffer = MarkdownImageUndoBuffer(byteLimit: 2 * 1024 * 1024)
        let lock = NSLock()
        var claims = 0
        let effect = MarkdownImageUndoSideEffect(images: images, buffer: buffer,
            removalHooks: .init(beforeClaim: { _ in lock.withLock { claims += 1 } },
                beforeUnlink: { index in if index == 1 { throw POSIXError(.EIO) } }))
        mayRemoveDirectory = false

        func cleanUp() async {
            var drained = false
            MarkdownImageUndoSideEffect.pendingIO.notify(queue: .main) { drained = true }
            guard await waitUntil({ drained }) else {
                Issue.record("Bildaktion nicht abgeschlossen; Fixture bleibt in der Sandbox.")
                return
            }
            effect.discard()
            mayRemoveDirectory = true
        }

        do {
            var removal: MarkdownImageUndoSideEffect.WorkResult?
            MarkdownImageUndoSideEffect.perform({
                MarkdownImageUndoSideEffect.WorkResult.capture(effect.undo(), effects: [effect])
            }, buffer: buffer) { removal = $0 }
            try #require(await waitUntil { removal != nil })
            let removed = try #require(removal)
            #expect(removed.success && lock.withLock { claims } == 2)
            #expect(!FileManager.default.fileExists(atPath: images[0].fileURL.path))
            #expect(try Data(contentsOf: images[1].fileURL) == handoffPNG)
            #expect(buffer.byteCount > 0)
            let removalMessage = try #require(removed.removalFailures.first)
            #expect(removed.removalFailures.count == 1)
            let imageDirectory = images[0].fileURL.deletingLastPathComponent().resolvingSymlinksInPath()
            let realDirectory = try #require(realpath(imageDirectory.path, nil))
            defer { free(realDirectory) }
            let directoryPath = String(cString: realDirectory)
            let firstPath = directoryPath + "/" + images[0].fileURL.lastPathComponent
            let secondPath = directoryPath + "/" + images[1].fileURL.lastPathComponent
            let lines = removalMessage.components(separatedBy: "\n")
            #expect(lines.contains(POSIXError(.EIO).localizedDescription))
            #expect(lines.contains(L10n.format("Die Bilddatei „%@“ wurde entfernt.", firstPath)))
            #expect(lines.contains(L10n.format("Die Bilddatei „%@“ wurde zurückgestellt.", secondPath)))
            let remaining = try FileManager.default.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".fastra-image-delete-") }
            for entry in remaining {
                #expect(lines.contains(L10n.format("Bei der Bildbereinigung blieb „%@“ erhalten.", entry.path)))
            }

            var restore: MarkdownImageUndoSideEffect.WorkResult?
            MarkdownImageUndoSideEffect.perform({
                let success = effect.redo(hooks: .init(afterRename: { _ in throw POSIXError(.EACCES) }))
                return MarkdownImageUndoSideEffect.WorkResult.capture(success, effects: [effect])
            }, buffer: buffer) { restore = $0 }
            try #require(await waitUntil { restore != nil })
            let failedRestore = try #require(restore)
            #expect(!failedRestore.success && buffer.byteCount > 0)
            let restoreMessage = try #require(failedRestore.restoreFailures.first)
            #expect(restoreMessage.contains(POSIXError(.EACCES).localizedDescription))
            #expect(restoreMessage.contains(firstPath))
            for image in images { #expect(try Data(contentsOf: image.fileURL) == handoffPNG) }

            var retry: MarkdownImageUndoSideEffect.WorkResult?
            MarkdownImageUndoSideEffect.perform({
                MarkdownImageUndoSideEffect.WorkResult.capture(effect.redo(), effects: [effect])
            }, buffer: buffer) { retry = $0 }
            try #require(await waitUntil { retry != nil })
            let succeeded = try #require(retry)
            #expect(succeeded.success && succeeded.removalFailures.isEmpty && succeeded.restoreFailures.isEmpty)
            #expect(buffer.byteCount == 0)
            for image in images { #expect(try Data(contentsOf: image.fileURL) == handoffPNG) }
            #expect(removed.removalFailures == [removalMessage])
            #expect(failedRestore.restoreFailures == [restoreMessage])
            #expect(!removed.removalFailures[0].contains(POSIXError(.EACCES).localizedDescription))
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }
}
