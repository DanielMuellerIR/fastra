import AppKit
import CodeEditTextView
import Darwin
import Foundation
import Testing
@testable import Fastra

private let publicationBytes = Data("image bytes\n".utf8)

@Suite("Bild-Publish: Dauerhaftigkeit und gebundenes Eigentum")
struct MarkdownImagePublicationTests {
    private func fixture() throws -> URL {
        let directory = testTemporaryDirectory().appendingPathComponent("image-publish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func store(_ directory: URL, copy: Bool,
                       hooks: MarkdownImagePublication.Hooks = .init(),
                       reserve: Bool = false) throws -> MarkdownImageStore.StoredImage {
        let document = directory.appendingPathComponent("note.md")
        if copy {
            let source = directory.appendingPathComponent("source.png")
            if !FileManager.default.fileExists(atPath: source.path) { try publicationBytes.write(to: source) }
            return try MarkdownImageStore.storeImageFile(source, documentURL: document,
                reserveForTransaction: reserve, hooks: .init(publication: hooks))
        }
        return try MarkdownImageStore.storePastedData(.init(data: publicationBytes, fileExtension: "png"),
            documentURL: document, reserveForTransaction: reserve, hooks: .init(publication: hooks))
    }

    @Test("Paste und Kopie bestätigen Datei, images und Dokumentordner in dieser Reihenfolge",
          arguments: [false, true], [false, true])
    func successfulPublish(copy: Bool, existingDirectory: Bool) throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        if existingDirectory {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("images"), withIntermediateDirectories: false)
        }
        var events: [String] = []
        let image = try store(directory, copy: copy, hooks: .init(beforeSync: { point in
            events.append(String(describing: point))
        }, afterRename: { _ in events.append("rename") }), reserve: true)
        defer { MarkdownImageStore.releaseReservations([image]) }
        #expect(events == ["file", "rename", "imagesDirectory", "documentDirectory"])
        #expect(image.imagesDirectoryCreated == !existingDirectory)
        #expect(try Data(contentsOf: image.fileURL) == publicationBytes)
        #expect(MarkdownImageStore.isReserved(image.fileURL))
        #expect(try MarkdownImageStore.captureExisting(image.fileURL).identity == image.identity)
    }

    @Test("Abschlussfehler erhalten nur vollständige eigene Kopien, keine Reservation, und bleiben wiederholbar",
          arguments: [false, true], ["file", "rename", "imagesDirectory", "documentDirectory"])
    func publishFaults(copy: Bool, point: String) throws {
        for existingDirectory in [false, true] {
            let directory = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            let images = directory.appendingPathComponent("images")
            if existingDirectory { try FileManager.default.createDirectory(at: images, withIntermediateDirectories: false) }
            let hooks = MarkdownImagePublication.Hooks(beforeSync: { syncPoint in
                if String(describing: syncPoint) == point { throw POSIXError(.ENOSPC) }
            }, afterRename: { _ in if point == "rename" { throw POSIXError(.EIO) } })
            do {
                _ = try store(directory, copy: copy, hooks: hooks, reserve: true)
                Issue.record("Fehler wurde als erfolgreiche Bildablage gemeldet")
            } catch {
                if point != "file" {
                    let failure = try #require(error as? MarkdownImagePublication.Failure)
                    #expect(failure.remainingEntries.count == 1)
                    let allRemainingOwned = failure.remainingEntries.allSatisfy(\.owned)
                    #expect(allRemainingOwned)
                    #expect(!failure.rollbackSyncFailed)
                }
            }
            #expect(!MarkdownImageStore.isReserved(images.appendingPathComponent("1.png")))
            if FileManager.default.fileExists(atPath: images.path) {
                let names = try FileManager.default.contentsOfDirectory(atPath: images.path)
                #expect(names == (point == "file" ? [] : ["1.png"]))
                if point != "file" { #expect(try Data(contentsOf: images.appendingPathComponent("1.png")) == publicationBytes) }
            }
            let retry = try store(directory, copy: copy)
            #expect(retry.fileURL.lastPathComponent == (point == "file" ? "1.png" : "2.png"))
            #expect(try Data(contentsOf: retry.fileURL) == publicationBytes)
            if copy { #expect(try Data(contentsOf: directory.appendingPathComponent("source.png")) == publicationBytes) }
        }
    }

    @Test("Ein Fremdersatz vor der Rückbauinspektion wird niemals gelöscht", arguments: [false, true])
    func foreignReplacementDuringRollback(copy: Bool) throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("images/1.png")
        let savedOwn = directory.appendingPathComponent("moved-own.png")
        let foreign = Data("foreign bytes".utf8)
        var mutationError: Error?
        let hooks = MarkdownImagePublication.Hooks(afterRename: { _ in throw POSIXError(.EIO) }, beforeRollback: { url in
            do {
                try FileManager.default.moveItem(at: url, to: savedOwn)
                try foreign.write(to: url, options: .withoutOverwriting)
            } catch { mutationError = error }
        })
        do {
            _ = try store(directory, copy: copy, hooks: hooks)
            Issue.record("Publish-Fehler fehlte")
        } catch {
            let failure = try #require(error as? MarkdownImagePublication.Failure)
            #expect(failure.remainingEntries.contains { $0.owned && $0.url.resolvingSymlinksInPath() == savedOwn.resolvingSymlinksInPath() })
            #expect(failure.localizedDescription.contains(savedOwn.path))
        }
        #expect(mutationError == nil)
        #expect(try Data(contentsOf: target) == foreign)
        #expect(try Data(contentsOf: savedOwn) == publicationBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["1.png"])
    }

    @Test("Austausch nach letzter Rückbauprobe löscht weder fremde Datei noch eigene Kopie", arguments: [false, true])
    func foreignReplacementAfterLastInspection(copy: Bool) throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("images/1.png")
        let moved = directory.appendingPathComponent("own-after-inspection.png")
        let foreign = Data("must survive final window".utf8)
        var mutationError: Error?
        do {
            _ = try store(directory, copy: copy, hooks: .init(afterRename: { _ in throw POSIXError(.EIO) },
                afterRollbackInspection: { url in
                    do {
                        try FileManager.default.moveItem(at: url, to: moved)
                        try foreign.write(to: url, options: .withoutOverwriting)
                    } catch { mutationError = error }
                }))
            Issue.record("Publish-Fehler fehlte")
        } catch {
            let failure = try #require(error as? MarkdownImagePublication.Failure)
            #expect(failure.remainingEntries.contains { $0.owned && $0.url.resolvingSymlinksInPath() == moved.resolvingSymlinksInPath() })
        }
        #expect(mutationError == nil)
        #expect(try Data(contentsOf: target) == foreign)
        #expect(try Data(contentsOf: moved) == publicationBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["1.png"])
    }

    @Test("Gleichlange Fremdänderung mit restaurierter mtime wird nie mit altem Hash bestätigt",
          arguments: [false, true], [false, true])
    func inPlaceChangeAfterRename(copy: Bool, beforeIdentity: Bool) throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let changed = Data("other bytes\n".utf8)
        try #require(changed.count == publicationBytes.count)
        let mutate: (URL) throws -> Void = { url in
            let fd = open(url.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
            try #require(fd >= 0)
            defer { Darwin.close(fd) }
            var original = stat()
            try #require(fstat(fd, &original) == 0)
            try changed.withUnsafeBytes { try POSIXBufferWriter.writeAll($0, to: fd) }
            let times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), original.st_mtimespec]
            try #require(times.withUnsafeBufferPointer { futimens(fd, $0.baseAddress) } == 0)
        }
        var hooks = MarkdownImagePublication.Hooks()
        if beforeIdentity { hooks.afterRenameBeforeIdentity = mutate }
        else { hooks.afterRename = mutate }
        do {
            _ = try store(directory, copy: copy, hooks: hooks)
            Issue.record("Geänderte Bytes wurden mit dem alten Hash bestätigt")
        } catch {
            let failure = try #require(error as? MarkdownImagePublication.Failure)
            #expect(failure.remainingEntries.count == 1)
            #expect(failure.remainingEntries.first?.owned == true)
        }
        let target = directory.appendingPathComponent("images/1.png")
        #expect(try Data(contentsOf: target) == changed)
        let captured = try MarkdownImageStore.captureExisting(target)
        #expect(captured.contentSHA256 != FileSnapshot(data: publicationBytes, identity: nil).sha256)
    }

    @Test("Retry erfüllt offene Syncpflicht am verschobenen alten images-Ordner")
    func retrySynchronizesOriginalDirectory() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try store(directory, copy: false)
        let buffer = MarkdownImageUndoBuffer(byteLimit: 1_000_000)
        let files = MarkdownImageUndoFiles(images: [image], buffer: buffer)
        try #require(files.removeForUndo())
        let budget = buffer.byteCount
        let images = image.fileURL.deletingLastPathComponent()
        let old = directory.appendingPathComponent("old-images")
        var firstSyncPaths: [String] = []
        #expect(!files.restoreFromMemory(hooks: .init(afterRename: { _ in
            try FileManager.default.moveItem(at: images, to: old)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: false)
        }, beforeRetainedDirectorySync: { path in
            firstSyncPaths.append(path.resolvingSymlinksInPath().path)
            throw POSIXError(.EIO)
        })))
        #expect(files.lastRestoreFailure?.rollbackSyncFailed == true)
        #expect(firstSyncPaths == [old.resolvingSymlinksInPath().path])
        #expect(try Data(contentsOf: old.appendingPathComponent("1.png")) == publicationBytes)
        #expect(buffer.byteCount == budget)
        var retrySyncPaths: [String] = []
        try #require(files.restoreFromMemory(hooks: .init(beforeRetainedDirectorySync: { path in
            retrySyncPaths.append(path.resolvingSymlinksInPath().path)
        })))
        #expect(retrySyncPaths == [old.resolvingSymlinksInPath().path])
        #expect(try Data(contentsOf: old.appendingPathComponent("1.png")) == publicationBytes)
        #expect(try Data(contentsOf: image.fileURL) == publicationBytes)
        #expect(buffer.byteCount == 0)
    }

    @Test("Natives Redo meldet erhaltene Bildkopie und Syncfehler, Text und RAM bleiben bis Retry erhalten")
    @MainActor
    func nativeRedoForwardsFailureDetailsSerialRunnerIntegration() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try store(directory, copy: false)
        let buffer = MarkdownImageUndoBuffer(byteLimit: 1_000_000)
        let view = TextView(string: "")
        view.replaceCharacters(in: NSRange(location: 0, length: 0), with: image.link)
        let manager = try #require(view.undoManager as? CEUndoManager)
        var faultEnabled = true
        var warnings: [(String, String)] = []
        MarkdownImageUndo.register(textView: view, insertion: image.link, storedImages: [image], buffer: buffer,
            restoreHooks: .init(beforeSync: { point in
                if faultEnabled && (point == .imagesDirectory || point == .rollbackImagesDirectory) { throw POSIXError(.EIO) }
            }), redoWarningHandler: { warnings.append(($0, $1)) })
        manager.undo()
        try #require(await waitUntil { !manager.isUndoing })
        try #require(view.string.isEmpty)
        let budget = buffer.byteCount
        try #require(budget > 0)
        manager.redo()
        try #require(await waitUntil { !manager.isRedoing })
        #expect(view.string.isEmpty)
        #expect(manager.canRedo)
        #expect(buffer.byteCount == budget)
        #expect(warnings.count == 1)
        #expect(warnings.first?.0 == L10n.string("Bild konnte nicht wiederhergestellt werden"))
        #expect(warnings.first?.1.contains(image.fileURL.path) == true)
        #expect(warnings.first?.1.contains(L10n.string("Die Bereinigung der Bildablage konnte nicht vollständig synchronisiert werden.")) == true)
        #expect(try Data(contentsOf: image.fileURL) == publicationBytes)
        faultEnabled = false
        manager.redo()
        try #require(await waitUntil { !manager.isRedoing })
        #expect(view.string == image.link)
        #expect(buffer.byteCount == 0)
        #expect(warnings.count == 1)
    }

    @Test("Eine gescheiterte zweite Ablage verändert die erste bestätigte Kopie und Reservation nicht")
    func secondStoreFailurePreservesFirst() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try store(directory, copy: false, reserve: true)
        defer { MarkdownImageStore.releaseReservations([first]) }
        #expect(throws: MarkdownImagePublication.Failure.self) {
            _ = try store(directory, copy: true, hooks: .init(afterRename: { _ in throw POSIXError(.ENOSPC) }), reserve: true)
        }
        #expect(try MarkdownImageStore.captureExisting(first.fileURL).identity == first.identity)
        #expect(try Data(contentsOf: first.fileURL) == publicationBytes)
        #expect(MarkdownImageStore.isReserved(first.fileURL))
        #expect(!MarkdownImageStore.isReserved(first.fileURL.deletingLastPathComponent().appendingPathComponent("2.png")))
        let retry = try store(directory, copy: true)
        #expect(retry.fileURL.lastPathComponent == "3.png")
        #expect(try Data(contentsOf: retry.fileURL) == publicationBytes)
        #expect(try Data(contentsOf: first.fileURL.deletingLastPathComponent().appendingPathComponent("2.png")) == publicationBytes)
    }

    @Test("Fehler der Rückbau-Synchronisierung bleibt als solcher sichtbar")
    func rollbackSyncFailure() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try store(directory, copy: false, hooks: .init(beforeSync: { point in
                if point == .rollbackImagesDirectory { throw POSIXError(.EIO) }
            }, afterRename: { _ in throw POSIXError(.ENOSPC) }))
            Issue.record("Publish-Fehler fehlte")
        } catch {
            let failure = try #require(error as? MarkdownImagePublication.Failure)
            #expect(failure.remainingEntries.count == 1)
            #expect(failure.remainingEntries.first?.owned == true)
            #expect(failure.rollbackSyncFailed)
        }
    }

    @Test("Zweites Bild scheitert beim Redo: vollständige eigene Kopien und RAM-Ticket bleiben für Retry",
          arguments: ["file", "rename", "imagesDirectory", "documentDirectory"], [false, true])
    func redoSecondImageFault(point: String, recreateDirectory: Bool) throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try store(directory, copy: false)
        let second = try store(directory, copy: true)
        let buffer = MarkdownImageUndoBuffer(byteLimit: 1_000_000)
        let files = MarkdownImageUndoFiles(images: [first, second], buffer: buffer)
        MarkdownImageStore.reserveForUndo([first, second])
        defer { MarkdownImageStore.releaseReservations([first, second]) }
        try #require(files.removeForUndo())
        let bytes = buffer.byteCount
        try #require(bytes > 0)
        if recreateDirectory { try FileManager.default.removeItem(at: first.fileURL.deletingLastPathComponent()) }
        var fileCount = 0
        var renameCount = 0
        #expect(!files.restoreFromMemory(hooks: .init(beforeSync: { syncPoint in
            if syncPoint == .file { fileCount += 1 }
            if String(describing: syncPoint) == point, point != "file" || fileCount == 2 { throw POSIXError(.EIO) }
        }, afterRename: { _ in
            renameCount += 1
            if point == "rename", renameCount == 2 { throw POSIXError(.EIO) }
        })))
        #expect(files.lastRestoreFailure?.remainingEntries.count == (point == "file" ? 1 : 2))
        #expect(files.lastRestoreFailure?.remainingEntries.allSatisfy(\.owned) == true)
        #expect(buffer.byteCount == bytes)
        #expect(try Data(contentsOf: first.fileURL) == publicationBytes)
        if point == "file" { #expect(!FileManager.default.fileExists(atPath: second.fileURL.path)) }
        else { #expect(try Data(contentsOf: second.fileURL) == publicationBytes) }
        #expect(MarkdownImageStore.isReserved(first.fileURL) && MarkdownImageStore.isReserved(second.fileURL))
        try #require(files.restoreFromMemory())
        #expect(buffer.byteCount == 0)
        #expect(files.lastRestoreFailure == nil)
        #expect(try Data(contentsOf: first.fileURL) == publicationBytes)
        #expect(try Data(contentsOf: second.fileURL) == publicationBytes)
        try #require(files.removeForUndo())
        try #require(files.restoreFromMemory())
    }

    @Test("Geschlossener Rückbau erhält eigenen Rest, Metadaten und RAM-Ticket bis zum Retry")
    func redoRetainsOwnedResidue() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try store(directory, copy: false)
        let attribute = Data("preserved metadata".utf8)
        let attributeName = "com.example.fastra-publish-test"
        try #require(attribute.withUnsafeBytes { setxattr(original.fileURL.path, attributeName, $0.baseAddress, $0.count, 0, 0) } == 0)
        try #require(chmod(original.fileURL.path, 0o640) == 0)
        let image = try MarkdownImageStore.captureExisting(original.fileURL)
        let buffer = MarkdownImageUndoBuffer(byteLimit: 1_000_000)
        let files = MarkdownImageUndoFiles(images: [image], buffer: buffer)
        try #require(files.removeForUndo())
        let budget = buffer.byteCount
        let images = image.fileURL.deletingLastPathComponent()
        defer { _ = chmod(images.path, 0o700) }
        let restored = files.restoreFromMemory(hooks: .init(afterRename: { _ in throw POSIXError(.ENOSPC) }, beforeRollback: { _ in
            #expect(chmod(images.path, 0o500) == 0)
        }))
        #expect(!restored)
        let failure = try #require(files.lastRestoreFailure)
        #expect(failure.remainingEntries.count == 1)
        #expect(failure.remainingEntries.first?.owned == true)
        #expect(failure.localizedDescription.contains(image.fileURL.path))
        #expect(try Data(contentsOf: image.fileURL) == publicationBytes)
        #expect(buffer.byteCount == budget)
        try #require(chmod(images.path, 0o700) == 0)
        try #require(files.restoreFromMemory())
        #expect(try Data(contentsOf: image.fileURL) == publicationBytes)
        #expect(buffer.byteCount == 0)
        var actual = Data(count: attribute.count)
        #expect(actual.withUnsafeMutableBytes { getxattr(image.fileURL.path, attributeName, $0.baseAddress, $0.count, 0, 0) } == attribute.count)
        #expect(actual == attribute)
        var info = stat()
        try #require(lstat(image.fileURL.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o640)
        try #require(files.removeForUndo())
        try #require(files.restoreFromMemory())
    }

    @Test("Ein während Redo ausgetauschter images-Ordner bleibt unangetastet")
    func redoImagesDirectoryReplacement() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try store(directory, copy: false)
        let buffer = MarkdownImageUndoBuffer(byteLimit: 1_000_000)
        let files = MarkdownImageUndoFiles(images: [image], buffer: buffer)
        try #require(files.removeForUndo())
        let budget = buffer.byteCount
        let images = image.fileURL.deletingLastPathComponent()
        let old = directory.appendingPathComponent("old-images")
        let foreign = Data("foreign".utf8)
        #expect(!files.restoreFromMemory(hooks: .init(afterRename: { _ in
            try FileManager.default.moveItem(at: images, to: old)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: false)
            try foreign.write(to: images.appendingPathComponent("keep.png"))
        })))
        #expect(try FileManager.default.contentsOfDirectory(atPath: old.path) == ["1.png"])
        #expect(try Data(contentsOf: old.appendingPathComponent("1.png")) == publicationBytes)
        #expect(try Data(contentsOf: images.appendingPathComponent("keep.png")) == foreign)
        #expect(buffer.byteCount == budget)
        try #require(files.restoreFromMemory())
        #expect(try Data(contentsOf: image.fileURL) == publicationBytes)
        #expect(try Data(contentsOf: images.appendingPathComponent("keep.png")) == foreign)
        #expect(buffer.byteCount == 0)
    }

    @Test("Auch ein leerer fremder images-Ersatz überlebt Ablagefehler und Undo", arguments: [false, true])
    func emptyForeignDirectoryIsPreserved(duringUndo: Bool) throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = directory.appendingPathComponent("images")
        let held = directory.appendingPathComponent("held-images")
        var replacementInode: ino_t?
        func replaceDirectory() throws {
            try FileManager.default.moveItem(at: images, to: held)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: false)
            var info = stat()
            try #require(lstat(images.path, &info) == 0)
            replacementInode = info.st_ino
        }
        if duringUndo {
            let image = try store(directory, copy: false)
            let files = MarkdownImageUndoFiles(images: [image], buffer: MarkdownImageUndoBuffer(byteLimit: 1_000_000))
            var replacementError: Error?
            try #require(files.removeForUndo(gate: { remove in
                do { try replaceDirectory() } catch { replacementError = error; return false }
                return remove()
            }))
            #expect(replacementError == nil)
        } else {
            #expect(throws: MarkdownImagePublication.Failure.self) {
                _ = try store(directory, copy: false, hooks: .init(afterRename: { _ in try replaceDirectory() }))
            }
        }
        var observed = stat()
        try #require(lstat(images.path, &observed) == 0)
        #expect(observed.st_ino == replacementInode)
        #expect(try FileManager.default.contentsOfDirectory(atPath: images.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: held.path) == (duringUndo ? [] : ["1.png"]))
        if !duringUndo { #expect(try Data(contentsOf: held.appendingPathComponent("1.png")) == publicationBytes) }
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["images", "held-images"])
    }

    @Test("Redo-Fremdersatz erhält Fremdbytes, Ticket und wiederholbaren Namen")
    func redoForeignReplacement() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try store(directory, copy: false)
        let buffer = MarkdownImageUndoBuffer(byteLimit: 1_000_000)
        let files = MarkdownImageUndoFiles(images: [image], buffer: buffer)
        try #require(files.removeForUndo())
        let budget = buffer.byteCount
        let foreign = Data("replacement".utf8)
        var mutationError: Error?
        #expect(!files.restoreFromMemory(hooks: .init(afterRename: { _ in throw POSIXError(.EIO) }, beforeRollback: { url in
            do {
                try FileManager.default.removeItem(at: url)
                try foreign.write(to: url, options: .withoutOverwriting)
            } catch { mutationError = error }
        })))
        #expect(mutationError == nil)
        #expect(try Data(contentsOf: image.fileURL) == foreign)
        #expect(buffer.byteCount == budget)
        #expect(!files.restoreFromMemory())
        #expect(try Data(contentsOf: image.fileURL) == foreign)
        #expect(buffer.byteCount == budget)
        try FileManager.default.removeItem(at: image.fileURL)
        try #require(files.restoreFromMemory())
        #expect(try Data(contentsOf: image.fileURL) == publicationBytes)
        #expect(buffer.byteCount == 0)
    }
}

@Suite("macOS-Datei-Synchronisierungsvertrag")
struct FileDurabilityTests {
    @Test("Nur nicht unterstütztes Fullsync erlaubt fsync", arguments: [ENOTSUP, EINVAL, ENOTTY, EIO, ENOSPC, EINTR])
    func fullSyncPolicy(code: Int32) throws {
        var fallbackCalls = 0
        do {
            try FileDurability.synchronizeFile(123, fullSync: { fd in
                #expect(fd == 123)
                errno = code
                return -1
            }, sync: { fd in
                #expect(fd == 123)
                fallbackCalls += 1
                return 0
            })
            #expect([ENOTSUP, EINVAL, ENOTTY].contains(code))
        } catch let error as POSIXError { #expect(error.code.rawValue == code) }
        #expect(fallbackCalls == ([ENOTSUP, EINVAL, ENOTTY].contains(code) ? 1 : 0))
    }

    @Test("Fullsync-Erfolg überspringt fsync; Rückfallfehler bleibt erhalten")
    func syncSuccessAndFailure() throws {
        try FileDurability.synchronizeFile(123, fullSync: { _ in 0 }, sync: { _ in
            Issue.record("fsync nach erfolgreichem Fullsync")
            return 0
        })
        do {
            try FileDurability.synchronizeFile(123, fullSync: { _ in errno = ENOTSUP; return -1 },
                sync: { _ in errno = ENOSPC; return -1 })
            Issue.record("fsync-Fehler fehlte")
        } catch let error as POSIXError { #expect(error.code == .ENOSPC) }
    }
}

/// Eigene Testhost-Prozesse verwenden denselben Produktkern. Die Marker sind
/// Prüfbelege, keine Produkt-Journale. Das ist kein Bundle-/GUI-Neustart und
/// erst recht keine Simulation eines physischen Stromausfalls.
@Suite("Bild-Publish: echter Prozessabbruch")
struct MarkdownImagePublicationProcessTests {
    @Test("SIGKILL vor Rückgabe, nach Rückgabe und während Redo erhält nur vollständige Bilddateien",
          arguments: ["paste-rename", "copy-rename", "paste-return", "redo-first-rename"])
    func publicationSurvivesProcessExit(stage: String) throws {
        let directory = testTemporaryDirectory().appendingPathComponent("image-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("saved document before insertion".utf8).write(to: directory.appendingPathComponent("note.md"))
        try publicationBytes.write(to: directory.appendingPathComponent("source.png"))
        let executable = try #require(CommandLine.arguments.first)
        var arguments = ["--testing-library", "swift-testing", "--filter", "imagePublicationCrashChild"]
        // Xcodes SwiftPM-Host lädt die Tests als Bundle. Ohne dessen vorhandenen
        // Pfad beendet sich der Helfer erfolgreich, ohne einen Test auszuführen.
        if let bundleIndex = CommandLine.arguments.firstIndex(of: "--test-bundle-path") {
            try #require(CommandLine.arguments.indices.contains(bundleIndex + 1))
            arguments.insert(contentsOf: ["--test-bundle-path", CommandLine.arguments[bundleIndex + 1]], at: 0)
        }
        let environment = ["FASTRA_IMAGE_CRASH_ROOT": directory.path, "FASTRA_IMAGE_CRASH_STAGE": stage]
        let killed = try runTestProcess(executable, arguments: arguments, environment: environment, timeout: 30)
        try #require(killed.status == SIGKILL, "Testkind erreichte die Abbruchstelle nicht: \(killed.output)")
        #expect(try String(contentsOf: directory.appendingPathComponent("reached.txt"), encoding: .utf8) == stage)
        let restarted = try runTestProcess(executable, arguments: arguments,
            environment: environment.merging(["FASTRA_IMAGE_CRASH_INSPECT": "1"]) { _, new in new }, timeout: 30)
        try #require(restarted.status == 0, "Neuer Testhost konnte den Stand nicht bestätigen: \(restarted.output)")
        #expect(try String(contentsOf: directory.appendingPathComponent("inspected.txt"), encoding: .utf8) == stage)
        #expect(try String(contentsOf: directory.appendingPathComponent("note.md"), encoding: .utf8) == "saved document before insertion")
        #expect(try Data(contentsOf: directory.appendingPathComponent("source.png")) == publicationBytes)
    }
}

@Test("Gezieltes Testkind für Bild-Publish und unabhängige Prozessinspektion",
      .enabled(if: ProcessInfo.processInfo.environment["FASTRA_IMAGE_CRASH_ROOT"] != nil))
func imagePublicationCrashChild() throws {
    let environment = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(environment["FASTRA_IMAGE_CRASH_ROOT"]))
    let stage = try #require(environment["FASTRA_IMAGE_CRASH_STAGE"])
    let document = root.appendingPathComponent("note.md")
    let images = root.appendingPathComponent("images")
    if environment["FASTRA_IMAGE_CRASH_INSPECT"] == "1" {
        // Ein frischer Prozess besitzt weder frühere FDs noch Undo-Tickets.
        let names = try FileManager.default.contentsOfDirectory(atPath: images.path)
        try #require(names == ["1.png"])
        let existing = try MarkdownImageStore.captureExisting(images.appendingPathComponent("1.png"))
        try #require(existing.contentSHA256 == FileSnapshot(data: publicationBytes, identity: nil).sha256)
        try #require(try Data(contentsOf: existing.fileURL) == publicationBytes)
        let next = try MarkdownImageStore.storePastedData(.init(data: publicationBytes, fileExtension: "png"), documentURL: document)
        try #require(next.fileURL.lastPathComponent == "2.png")
        try #require(try Data(contentsOf: existing.fileURL) == publicationBytes)
        try stage.write(to: root.appendingPathComponent("inspected.txt"), atomically: true, encoding: .utf8)
        return
    }
    func crash() throws -> Never {
        try stage.write(to: root.appendingPathComponent("reached.txt"), atomically: true, encoding: .utf8)
        guard Darwin.kill(getpid(), SIGKILL) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Der Elternprozess begrenzt das Kind. Ein sofortiger regulärer Exit
        // könnte der noch ausstehenden Signalzustellung zuvorkommen.
        while true { Darwin.pause() }
    }
    let hooks = MarkdownImagePublication.Hooks(afterRename: { _ in
        if stage.hasSuffix("-rename") { try crash() }
    })
    if stage == "redo-first-rename" {
        let first = try MarkdownImageStore.storePastedData(.init(data: publicationBytes, fileExtension: "png"), documentURL: document)
        let second = try MarkdownImageStore.storePastedData(.init(data: publicationBytes, fileExtension: "png"), documentURL: document)
        let buffer = MarkdownImageUndoBuffer(byteLimit: 1_000_000)
        let files = MarkdownImageUndoFiles(images: [first, second], buffer: buffer)
        try #require(files.removeForUndo())
        _ = files.restoreFromMemory(hooks: .init(afterRename: { _ in try crash() }))
        Issue.record("Redo erreichte den Abbruchpunkt nicht")
    } else if stage == "copy-rename" {
        _ = try MarkdownImageStore.storeImageFile(root.appendingPathComponent("source.png"), documentURL: document,
            hooks: .init(publication: hooks))
    } else {
        _ = try MarkdownImageStore.storePastedData(.init(data: publicationBytes, fileExtension: "png"), documentURL: document,
            hooks: .init(publication: hooks))
        if stage == "paste-return" { try crash() }
    }
    Issue.record("Testkind wurde nicht beendet")
}
