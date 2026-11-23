import Darwin
import Foundation

/// Ausschließlich die Dateiseite einer neuen Bildkopie. Der offene FD bindet
/// Eigentum schon vor Rename; ein späterer Fehler verliert diese Bindung nicht.
/// Kein persistentes Undo, kein Journal und kein Aufräumen in deinit.
final class MarkdownImagePublication {
    enum SyncPoint: Equatable { case file, imagesDirectory, documentDirectory, rollbackImagesDirectory, rollbackDocumentDirectory }
    struct Hooks {
        var beforeSync: ((SyncPoint) throws -> Void)?
        var afterRename: ((URL) throws -> Void)?
        var beforeRollback: ((URL) -> Void)?
        var afterRollbackInspection: ((URL) -> Void)?
        var beforeRetainedDirectorySync: ((URL) throws -> Void)?
        var afterRenameBeforeIdentity: ((URL) throws -> Void)?
    }

    struct RemainingEntry {
        let url: URL
        let identity: MarkdownImageStore.StoredFileIdentity?
        let owned: Bool
    }

    struct Failure: LocalizedError {
        let underlying: Error
        // Hält auch bei nicht möglichem Rückbau FDs und Eigentumsbeleg am Leben.
        let publications: [MarkdownImagePublication]
        let remainingEntries: [RemainingEntry]
        let rollbackSyncFailed: Bool

        var errorDescription: String? {
            var messages = [underlying.localizedDescription]
            for entry in remainingEntries {
                messages.append(L10n.format("Die eigene Bildkopie „%@“ blieb erhalten. Die Einfügung wurde nicht abgeschlossen.", entry.url.path))
            }
            if rollbackSyncFailed {
                messages.append(L10n.string("Die Bereinigung der Bildablage konnte nicht vollständig synchronisiert werden."))
            }
            return messages.joined(separator: "\n")
        }
    }

    private let directory: Int32
    private let file: Int32
    private let initial: stat
    private let expectedSHA256: String
    private var directoryNeedsSync = false
    let name: String
    private var published = false
    private var publishedVersion: stat?

    init(file: Int32, directory: Int32, name: String, expectedSHA256: String) throws {
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw POSIXError(.EIO)
        }
        let directoryCopy = fcntl(directory, F_DUPFD_CLOEXEC, 0)
        guard directoryCopy >= 0 else { throw Self.posixError() }
        let fileCopy = fcntl(file, F_DUPFD_CLOEXEC, 0)
        guard fileCopy >= 0 else {
            let error = Self.posixError()
            Darwin.close(directoryCopy)
            throw error
        }
        self.directory = directoryCopy
        self.file = fileCopy
        self.name = name
        initial = info
        self.expectedSHA256 = expectedSHA256
    }

    deinit { Darwin.close(file); Darwin.close(directory) }

    var url: URL {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if fcntl(directory, F_GETPATH, &path) == 0 {
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
                .appendingPathComponent(name)
        }
        return URL(fileURLWithPath: "/").appendingPathComponent(name)
    }

    func publish(temporaryName: String) throws {
        guard renameatx_np(directory, temporaryName, directory, name, UInt32(RENAME_EXCL)) == 0 else {
            throw Self.posixError()
        }
        published = true
        directoryNeedsSync = true
    }

    func capturePublishedIdentity() throws {
        var info = stat()
        guard fstat(file, &info) == 0 else { throw Self.posixError() }
        publishedVersion = info
    }

    func identity() throws -> MarkdownImageStore.StoredFileIdentity {
        var info = stat()
        guard let expected = publishedVersion,
              fstat(file, &info) == 0, info.st_size >= 0, Self.sameVersion(initial, info),
              Self.sameExactVersion(expected, info) else { throw POSIXError(.ESTALE) }
        // Die erwarteten Bytes stammen vor Publish. Auch eine gleichlange Änderung
        // mit restaurierter mtime vor der ersten Post-Rename-Probe darf nicht passen.
        let snapshot = try FileSnapshot.readSnapshotOnly(descriptor: file, fileStat: info, byteLimit: UInt64(info.st_size))
        guard snapshot.sha256 == expectedSHA256,
              let named = namedStat(name), Self.sameExactVersion(info, named) else { throw POSIXError(.ESTALE) }
        return Self.identity(info)
    }

    func belongsToDirectory(_ descriptor: Int32) -> Bool {
        var original = stat()
        var current = stat()
        return fstat(directory, &original) == 0 && fstat(descriptor, &current) == 0
            && original.st_dev == current.st_dev && original.st_ino == current.st_ino
    }

    func synchronizeRetainedFile(hooks: Hooks) throws {
        _ = try identity()
        try Self.syncFile(file, hooks: hooks)
        _ = try identity()
    }

    /// macOS bietet kein inodebedingtes unlink. Auch ein UUID-Claim im gemeinsam
    /// beschreibbaren Ordner wäre nach seiner letzten Probe austauschbar. Deshalb
    /// nach Publish geschlossen erhalten: keine Rename-/Unlink-Aktion, Restzustand
    /// am offenen FD melden und beim Redo-Retry nur exakt eigene Dateien verwenden.
    func rollback(hooks: Hooks) -> [RemainingEntry] {
        guard published else { return [] }
        hooks.beforeRollback?(url)
        _ = try? identity()
        hooks.afterRollbackInspection?(url)
        return retainedOpenedFile()
    }

    private func synchronizeRetainedDirectory(hooks: Hooks) throws {
        guard directoryNeedsSync else { return }
        try hooks.beforeRetainedDirectorySync?(url.deletingLastPathComponent())
        try hooks.beforeSync?(.rollbackImagesDirectory)
        try FileDurability.synchronizeDirectory(directory)
        directoryNeedsSync = false
    }

    private func retainedOpenedFile() -> [RemainingEntry] {
        var info = stat()
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(file, &info) == 0, info.st_nlink > 0,
              fcntl(file, F_GETPATH, &path) == 0 else { return [] }
        let fileURL = URL(fileURLWithPath: String(cString: path))
        // Wurde die eigene Kopie anderswohin verschoben, bleibt sie erhalten.
        return [RemainingEntry(url: fileURL, identity: Self.identity(info), owned: true)]
    }

    private func namedStat(_ name: String) -> stat? {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return info
    }

    static func syncFile(_ fd: Int32, hooks: Hooks) throws {
        try hooks.beforeSync?(.file)
        try FileDurability.synchronizeFile(fd)
    }

    static func syncDirectories(images: Int32, parent: Int32, hooks: Hooks) throws {
        try hooks.beforeSync?(.imagesDirectory)
        try FileDurability.synchronizeDirectory(images)
        // Immer: auch ein nach fehlgeschlagenem Publish noch vorhandener images-
        // Ordner kann aus einem zuvor nicht synchronisierten mkdir stammen.
        try hooks.beforeSync?(.documentDirectory)
        try FileDurability.synchronizeDirectory(parent)
    }

    static func completePendingBarriers(_ publications: [MarkdownImagePublication],
                                       parent: Int32, hooks: Hooks) throws {
        // Jede Pflicht bleibt am damaligen Ordner-FD. Ein inzwischen neuer images-
        // Ordner darf die offene Barriere eines verschobenen Ordners nicht ersetzen.
        var firstError: Error?
        for publication in publications {
            do { try publication.synchronizeRetainedDirectory(hooks: hooks) }
            catch { if firstError == nil { firstError = error } }
        }
        do {
            try hooks.beforeSync?(.rollbackDocumentDirectory)
            try FileDurability.synchronizeDirectory(parent)
        } catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
    }

    static func failure(_ error: Error, publications: [MarkdownImagePublication],
                        images: Int32, parent: Int32, hooks: Hooks) -> Failure {
        let remaining = publications.reversed().flatMap { $0.rollback(hooks: hooks) }
        var syncFailed = false
        do { try completePendingBarriers(publications, parent: parent, hooks: hooks) }
        catch { syncFailed = true }
        // Auch ein neu angelegter Ordner ohne publizierte Datei bleibt als
        // eigener Verzeichniseintrag erhalten und wird best effort synchronisiert.
        do {
            try hooks.beforeSync?(.rollbackImagesDirectory)
            try FileDurability.synchronizeDirectory(images)
        } catch { syncFailed = true }
        return Failure(underlying: error, publications: publications,
                       remainingEntries: remaining, rollbackSyncFailed: syncFailed)
    }

    private static func sameExactVersion(_ lhs: stat, _ rhs: stat) -> Bool {
        sameVersion(lhs, rhs)
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func sameVersion(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode && lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private static func identity(_ info: stat) -> MarkdownImageStore.StoredFileIdentity {
        .init(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
              modificationSeconds: Int64(info.st_mtimespec.tv_sec), modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
              statusChangeSeconds: Int64(info.st_ctimespec.tv_sec), statusChangeNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
