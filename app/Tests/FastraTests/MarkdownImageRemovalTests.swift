import Darwin
import Foundation
import Testing
@testable import Fastra

@Suite
struct MarkdownImageRemovalTests {
    private func fixture(_ body: (URL, [MarkdownImageStore.StoredImage]) throws -> Void) throws {
        let temporary = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = temporary.canonicalFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let images = try (0..<2).map { index in
            try MarkdownImageStore.storePastedData(.init(data: Data("image-\(index)".utf8), fileExtension: "png"),
                                                   documentURL: root.appendingPathComponent("note.md"))
        }
        try body(root, images)
    }

    private func inode(_ url: URL) throws -> UInt64 {
        var info = stat()
        try #require(lstat(url.path, &info) == 0)
        return UInt64(info.st_ino)
    }

    @Test("Mehrere Bilder werden privat entfernt und aus dem RAM wiederhergestellt")
    func multipleImagesUndoRedo() throws {
        try fixture { (_: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let buffer = MarkdownImageUndoBuffer(byteLimit: 1024 * 1024)
            let files = MarkdownImageUndoFiles(images: images, buffer: buffer)
            #expect(files.removeForUndo())
            #expect(files.lastRemovalResult?.complete == true)
            #expect(files.lastRemovalResult?.removed.count == 2)
            #expect(buffer.byteCount > 0)
            #expect(images.allSatisfy { !FileManager.default.fileExists(atPath: $0.fileURL.path) })
            #expect(files.restoreFromMemory())
            #expect(buffer.byteCount == 0)
            for (index, image) in images.enumerated() {
                #expect(try Data(contentsOf: image.fileURL) == Data("image-\(index)".utf8))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: images[0].fileURL.deletingLastPathComponent().path).count == 2)
        }
    }

    @Test("Fremdersatz vor Claim bleibt samt Identität unangetastet")
    func foreignBeforeClaim() throws {
        try fixture { (root: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let buffer = MarkdownImageUndoBuffer(byteLimit: 1024 * 1024)
            let files = MarkdownImageUndoFiles(images: images, buffer: buffer)
            let backup = root.appendingPathComponent("own.png")
            var foreignInode: UInt64 = 0
            let outcome = !files.removeForUndo(hooks: .init(beforeClaim: { url in
                try FileManager.default.moveItem(at: url, to: backup)
                try Data("foreign".utf8).write(to: url)
                foreignInode = try inode(url)
            }))
            #expect(outcome)
            #expect(try inode(images[0].fileURL) == foreignInode)
            #expect(try Data(contentsOf: images[0].fileURL) == Data("foreign".utf8))
            #expect(try inode(backup) == images[0].identity.inode)
            #expect(try Data(contentsOf: backup) == Data("image-0".utf8))
            #expect(files.lastRemovalResult?.removed.isEmpty == true)
            #expect(buffer.byteCount == 0)
        }
    }

    @Test("Fremder Claim wird exklusiv zurückgestellt, die verschobene eigene Kopie bleibt benannt")
    func foreignAfterClaim() throws {
        try fixture { (root: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let buffer = MarkdownImageUndoBuffer(byteLimit: 1024 * 1024)
            let files = MarkdownImageUndoFiles(images: images, buffer: buffer)
            let backup = root.appendingPathComponent("own.png")
            var foreignInode: UInt64 = 0
            let outcome = files.removeForUndo(hooks: .init(afterClaim: { _, claim in
                guard !FileManager.default.fileExists(atPath: backup.path) else { return }
                try FileManager.default.moveItem(at: claim, to: backup)
                try Data("foreign".utf8).write(to: claim)
                foreignInode = try inode(claim)
            }))
            #expect(outcome)
            #expect(try inode(images[0].fileURL) == foreignInode)
            #expect(try Data(contentsOf: images[0].fileURL) == Data("foreign".utf8))
            #expect(try inode(backup) == images[0].identity.inode)
            #expect(try Data(contentsOf: backup) == Data("image-0".utf8))
            #expect(files.lastRemovalResult?.remainingEntries.contains(where: { $0.url == backup && $0.owned }) == true)
            #expect(files.lastRemovalResult?.removed.isEmpty == true)
            #expect(buffer.byteCount > 0)
            #expect(!files.restoreFromMemory())
            #expect(buffer.byteCount > 0)
            try FileManager.default.removeItem(at: images[0].fileURL)
            #expect(files.restoreFromMemory())
            #expect(buffer.byteCount == 0)
            #expect(try Data(contentsOf: backup) == Data("image-0".utf8))
        }
    }

    @Test("Gezielter Claim-Austausch an der früheren Löschlücke erhält eigene und fremde Bytes")
    func claimReplacementAfterInspection() throws {
        try fixture { (root: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let files = MarkdownImageUndoFiles(images: images)
            let backup = root.appendingPathComponent("own-after-inspection.png")
            var foreignInode: UInt64 = 0
            let outcome = files.removeForUndo(hooks: .init(afterInspection: { _, claim in
                try FileManager.default.moveItem(at: claim, to: backup)
                try Data("foreign".utf8).write(to: claim)
                foreignInode = try inode(claim)
            }))
            #expect(outcome)
            #expect(files.lastRemovalResult?.removed.isEmpty == true)
            #expect(try inode(images[0].fileURL) == foreignInode)
            #expect(try Data(contentsOf: images[0].fileURL) == Data("foreign".utf8))
            #expect(try inode(backup) == images[0].identity.inode)
            #expect(try Data(contentsOf: backup) == Data("image-0".utf8))
            #expect(files.lastRemovalResult?.remainingEntries.contains(where: { $0.url == backup && $0.owned }) == true)
        }
    }

    @Test("Öffentlicher Fremdname nach letzter Claim-Prüfung wird nicht gelöscht")
    func publicReplacementAfterInspection() throws {
        try fixture { (_: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let files = MarkdownImageUndoFiles(images: images)
            var replacements: [String: UInt64] = [:]
            let outcome = files.removeForUndo(hooks: .init(afterInspection: { original, _ in
                try Data("foreign".utf8).write(to: original)
                replacements[original.lastPathComponent] = try inode(original)
            }))
            #expect(outcome)
            #expect(files.lastRemovalResult?.complete == true)
            #expect(files.lastRemovalResult?.removed.count == 2)
            for image in images {
                #expect(try inode(image.fileURL) == replacements[image.fileURL.lastPathComponent])
                #expect(try Data(contentsOf: image.fileURL) == Data("foreign".utf8))
            }
            #expect(!files.restoreFromMemory())
        }
    }

    @Test("Ausgetauschter Arbeitsordnername erhält fremden Ordner und stellt eigene Claims zurück")
    func workingDirectoryNameReplacement() throws {
        try fixture { (root: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let files = MarkdownImageUndoFiles(images: images)
            let retained = root.appendingPathComponent("retained-work")
            var replacement: URL?
            var foreignInode: UInt64 = 0
            let outcome = files.removeForUndo(hooks: .init(afterInspection: { _, claim in
                let directory = claim.deletingLastPathComponent()
                replacement = directory
                try FileManager.default.moveItem(at: directory, to: retained)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let foreign = directory.appendingPathComponent("foreign")
                try Data("foreign".utf8).write(to: foreign)
                foreignInode = try inode(foreign)
            }))
            #expect(outcome)
            let foreign = try #require(replacement).appendingPathComponent("foreign")
            #expect(try inode(foreign) == foreignInode)
            #expect(try Data(contentsOf: foreign) == Data("foreign".utf8))
            for (index, image) in images.enumerated() {
                #expect(try inode(image.fileURL) == image.identity.inode)
                #expect(try Data(contentsOf: image.fileURL) == Data("image-\(index)".utf8))
            }
            #expect(files.lastRemovalResult?.remainingEntries.contains(where: { $0.url.standardizedFileURL.path == retained.standardizedFileURL.path }) == true)
            #expect(try FileManager.default.contentsOfDirectory(atPath: retained.path).isEmpty)
            #expect(files.restoreFromMemory())
        }
    }

    @Test("Eine nach Vorbereitung hinzugefügte ACL verhindert jeden Claim")
    func accessControlChangeStopsRemoval() throws {
        try fixture { (_: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let buffer = MarkdownImageUndoBuffer(byteLimit: 1024 * 1024)
            let files = MarkdownImageUndoFiles(images: images, buffer: buffer)
            let outcome = !files.removeForUndo(hooks: .init(afterPreparingDirectory: { directory in
                var info = stat()
                try #require(lstat(directory.path, &info) == 0)
                #expect(info.st_mode & 0o7777 == 0o700)
                let acl = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow:write\n"))
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                try #require(acl_set_file(directory.path, ACL_TYPE_EXTENDED, acl) == 0)
            }))
            #expect(outcome)
            #expect(buffer.byteCount == 0)
            #expect(files.lastRemovalResult?.removed.isEmpty == true)
            for image in images { #expect(try inode(image.fileURL) == image.identity.inode) }
        }
    }

    @Test("Geerbte Zugriffsrechte werden vor der Entnahme aus dem privaten Ordner entfernt")
    func inheritedAccessControlIsRemoved() throws {
        try fixture { (_: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let directory = images[0].fileURL.deletingLastPathComponent()
            let acl = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow,directory_inherit:write\n"))
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            try #require(acl_set_file(directory.path, ACL_TYPE_EXTENDED, acl) == 0)
            let files = MarkdownImageUndoFiles(images: images)
            var checked = false
            let outcome = files.removePermanently(hooks: .init(afterPreparingDirectory: { privateDirectory in
                if let actual = acl_get_file(privateDirectory.path, ACL_TYPE_EXTENDED) {
                    defer { acl_free(UnsafeMutableRawPointer(actual)) }
                    var entry: acl_entry_t?
                    #expect(acl_get_entry(actual, ACL_FIRST_ENTRY.rawValue, &entry) == -1)
                    #expect(errno == EINVAL)
                } else {
                    #expect(errno == ENOENT)
                }
                checked = true
            }))
            #expect(outcome)
            #expect(checked)
            #expect(files.lastRemovalResult?.removed.count == 2)
        }
    }

    @Test("Zweiter Löschfehler erhält entfernte Bilder im RAM und den unentfernten Originalstand")
    func secondUnlinkFailureRetainsMemory() throws {
        try fixture { (_: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let buffer = MarkdownImageUndoBuffer(byteLimit: 1024 * 1024)
            let files = MarkdownImageUndoFiles(images: images, buffer: buffer)
            let outcome = files.removeForUndo(hooks: .init(beforeUnlink: { index in
                if index == 1 { throw POSIXError(.EIO) }
            }))
            #expect(outcome)
            #expect(files.lastRemovalResult?.removed.map(\.lastPathComponent) == [images[0].fileURL.lastPathComponent])
            #expect(files.lastRemovalResult?.restored.map(\.lastPathComponent) == [images[1].fileURL.lastPathComponent])
            #expect(files.lastRemovalResult?.causes.contains(where: { ($0 as? POSIXError)?.code == .EIO }) == true)
            #expect(!FileManager.default.fileExists(atPath: images[0].fileURL.path))
            #expect(try inode(images[1].fileURL) == images[1].identity.inode)
            #expect(try Data(contentsOf: images[1].fileURL) == Data("image-1".utf8))
            #expect(buffer.byteCount > 0)
            #expect(files.restoreFromMemory())
            #expect(buffer.byteCount == 0)
            #expect(try Data(contentsOf: images[0].fileURL) == Data("image-0".utf8))
            #expect(try inode(images[1].fileURL) == images[1].identity.inode)
        }
    }

    @Test("Fehlgeschlagene exklusive Rückstellung erhält Claim und RAM bis zum Retry")
    func failedExclusiveRestorationRetry() throws {
        try fixture { (_: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let buffer = MarkdownImageUndoBuffer(byteLimit: 1024 * 1024)
            let files = MarkdownImageUndoFiles(images: images, buffer: buffer)
            var foreignInode: UInt64 = 0
            let outcome = files.removeForUndo(hooks: .init(beforeUnlink: { index in
                if index == 1 {
                    try Data("foreign".utf8).write(to: images[1].fileURL)
                    foreignInode = try inode(images[1].fileURL)
                    throw POSIXError(.EIO)
                }
            }))
            #expect(outcome)
            let entry = try #require(files.lastRemovalResult?.remainingEntries.first(where: { $0.owned }))
            #expect(try inode(entry.url) == images[1].identity.inode)
            #expect(try Data(contentsOf: entry.url) == Data("image-1".utf8))
            #expect(try inode(images[1].fileURL) == foreignInode)
            #expect(!files.restoreFromMemory())
            #expect(buffer.byteCount > 0)
            #expect(try Data(contentsOf: images[1].fileURL) == Data("foreign".utf8))
            try FileManager.default.removeItem(at: images[1].fileURL)
            #expect(files.restoreFromMemory())
            #expect(buffer.byteCount == 0)
            #expect(try inode(images[1].fileURL) == images[1].identity.inode)
            #expect(try Data(contentsOf: images[0].fileURL) == Data("image-0".utf8))
            #expect(!FileManager.default.fileExists(atPath: entry.url.path))
        }
    }

    @Test("Dauerhafte Bereinigung meldet Teilfortschritt und wiederholt nur verbliebene Bilder")
    func permanentRemovalRetriesRemainingImages() throws {
        try fixture { (_: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let files = MarkdownImageUndoFiles(images: images)
            let outcome = !files.removePermanently(hooks: .init(beforeUnlink: { index in
                if index == 1 { throw POSIXError(.ENOSPC) }
            }))
            #expect(outcome)
            #expect(files.lastRemovalResult?.removed.map(\.lastPathComponent) == [images[0].fileURL.lastPathComponent])
            #expect(files.lastRemovalResult?.restored.map(\.lastPathComponent) == [images[1].fileURL.lastPathComponent])
            #expect(files.removePermanently())
            #expect(files.lastRemovalResult?.removed.map(\.lastPathComponent) == [images[1].fileURL.lastPathComponent])
            #expect(images.allSatisfy { !FileManager.default.fileExists(atPath: $0.fileURL.path) })
        }
    }
}
