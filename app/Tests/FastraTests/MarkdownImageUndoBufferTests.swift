import AppKit
import CodeEditTextView
import Foundation
import Testing
@testable import Fastra

private let imageUndoPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII=")!

@Suite
struct MarkdownImageUndoBufferTests {
    @Test("Ein Bild über dem Budget verschwindet samt Undo-Verlauf statt eine Sicherungsdatei anzulegen")
    @MainActor
    func imageUndoDropsHistoryWhenBudgetCannotFit() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let doc = directory.appendingPathComponent("test.md")
        try Data().write(to: doc)
        let image = try MarkdownImageStore.storePastedData(.init(data: imageUndoPNG, fileExtension: "png"), documentURL: doc)
        let buffer = MarkdownImageUndoBuffer(byteLimit: imageUndoPNG.count - 1)
        let view = TextView(string: "")
        view.replaceCharacters(in: NSRange(location: 0, length: 0), with: image.link)
        MarkdownImageUndo.register(textView: view, insertion: image.link, storedImages: [image], documentURL: doc, buffer: buffer)
        let manager = try #require(view.undoManager as? CEUndoManager)
        manager.undo()
        try #require(await waitUntil { !manager.isUndoing })
        #expect(view.string.isEmpty)
        #expect(!manager.canUndo && !manager.canRedo)
        #expect(buffer.byteCount == 0)
        #expect(!FileManager.default.fileExists(atPath: image.fileURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["test.md"])
    }

    @Test("Eine neu hinzugekommene offene Bildreferenz verhindert das Entfernen nach dem Hintergrundscan")
    @MainActor
    func changedOpenDocumentProtectsImage() async throws {
        let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try MarkdownImageStore.storePastedData(.init(data: imageUndoPNG, fileExtension: "png"),
                                                          documentURL: directory.appendingPathComponent("first.md"))
        let other = Workspace()
        var tab = EditorTab(title: "second.md", path: directory.path, content: "")
        tab.url = directory.appendingPathComponent("second.md")
        other.tabs = [tab]
        let snapshot = MarkdownImageUndo.openDocumentContents()
        let gate = MarkdownImageUndo.removalGate(for: snapshot)
        let effect = MarkdownImageUndoSideEffect(images: [image])
        other.tabs[0].content = image.link
        let removed = await Task.detached { effect.undo(gate: gate) }.value
        #expect(!removed)
        #expect(try Data(contentsOf: image.fileURL) == imageUndoPNG)
    }

    @Test("Das appweite Bildbudget verdrängt ganze ältere Transaktionen ohne Dateienreste")
    func oldestTransactionIsEvicted() throws {
        let root = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let buffer = MarkdownImageUndoBuffer(byteLimit: imageUndoPNG.count * 2)
        var lost: [Int] = []
        var effects: [MarkdownImageUndoSideEffect] = []
        for number in 0..<3 {
            let directory = root.appendingPathComponent(String(number))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let image = try MarkdownImageStore.storePastedData(.init(data: imageUndoPNG, fileExtension: "png"),
                                                              documentURL: directory.appendingPathComponent("test.md"))
            let effect = MarkdownImageUndoSideEffect(images: [image], buffer: buffer, historyLost: { lost.append(number) })
            effects.append(effect)
            #expect(effect.undo())
            #expect(!FileManager.default.fileExists(atPath: image.fileURL.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            #expect(buffer.byteCount <= buffer.byteLimit)
        }
        #expect(lost.isEmpty)
        buffer.takeInvalidations().forEach { $0() }
        #expect(lost == [0])
        #expect(!effects[0].redo())
        #expect(effects[1].redo())
        #expect(effects[2].redo())
        #expect(buffer.byteCount == 0)
    }

    @Test("Eine Mehrbildgruppe über dem Limit wird ohne Teilbackup entfernt")
    func oversizedGroupLosesUndo() throws {
        let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let doc = directory.appendingPathComponent("test.md")
        let images = try (0..<2).map { _ in
            try MarkdownImageStore.storePastedData(.init(data: imageUndoPNG, fileExtension: "png"), documentURL: doc)
        }
        let buffer = MarkdownImageUndoBuffer(byteLimit: imageUndoPNG.count)
        var lost = false
        let effect = MarkdownImageUndoSideEffect(images: images, buffer: buffer, historyLost: { lost = true })
        #expect(effect.undo())
        #expect(buffer.byteCount == 0)
        #expect(!effect.redo())
        #expect(images.allSatisfy { !FileManager.default.fileExists(atPath: $0.fileURL.path) })
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        buffer.takeInvalidations().forEach { $0() }
        #expect(lost)
    }

    @Test("Reservierungen und ausgeliehene Bildbytes bleiben innerhalb des Limits")
    func inFlightBytesCountAgainstLimit() throws {
        let buffer = MarkdownImageUndoBuffer(byteLimit: 8)
        let first = try #require(buffer.reserve(bytes: 8, invalidated: {}))
        #expect(buffer.reserve(bytes: 1, invalidated: {}) == nil)
        #expect(buffer.fill(first, with: [Data(repeating: 1, count: 8)]))
        buffer.withData(first) { bytes in
            #expect(bytes[0].count == 8)
            #expect(buffer.reserve(bytes: 1, invalidated: {}) == nil)
            #expect(buffer.byteCount == 8)
        }
        let second = try #require(buffer.reserve(bytes: 8, invalidated: {}))
        #expect(!buffer.contains(first))
        #expect(buffer.byteCount == 8)
        buffer.remove(second)
        #expect(buffer.byteCount == 0)
        #expect(MarkdownImageUndoBuffer.shared.byteLimit == 512 * 1024 * 1024)
    }

    @Test("Verwerfen während eines asynchronen Undo hängt keine ungültige Redo-Gruppe wieder ein")
    @MainActor
    func clearingDuringAsyncUndo() throws {
        let view = TextView(string: "")
        view.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Bild")
        let manager = try #require(view.undoManager as? CEUndoManager)
        var finish: (() -> Void)?
        manager.fastraRegisterSideEffectForLatestUndo(undo: {}, redo: {},
            undoAsync: { _, completion in finish = completion }, discard: {})
        manager.undo()
        #expect(view.string.isEmpty)
        #expect(manager.isUndoing)
        manager.clearStack()
        let complete = try #require(finish)
        complete()
        #expect(!manager.isUndoing)
        #expect(!manager.canUndo && !manager.canRedo)
        #expect(view.isEditable)
    }

    @Test("Abgebrochene Redo-Vorbereitung wird vor Freigabe des Editors zurückgenommen")
    @MainActor
    func clearingDuringAsyncRedo() throws {
        let view = TextView(string: "")
        view.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Bild")
        let manager = try #require(view.undoManager as? CEUndoManager)
        var finish: ((Bool) -> Void)?
        var rollback: (() -> Void)?
        manager.fastraRegisterSideEffectForLatestUndo(undo: {}, redo: {},
            prepareRedoAsync: { finish = $0 }, cancelRedoAsync: { rollback = $0 }, discard: {})
        manager.undo()
        manager.redo()
        #expect(manager.isRedoing && !view.isEditable)
        manager.clearStack()
        let complete = try #require(finish)
        complete(true)
        #expect(manager.isRedoing && !view.isEditable)
        let cancel = try #require(rollback)
        cancel()
        #expect(view.string.isEmpty && view.isEditable)
        #expect(!manager.canUndo && !manager.canRedo)
    }
}
