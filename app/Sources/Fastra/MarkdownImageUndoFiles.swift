import Darwin
import Foundation

/// Der gebundene Dokumentordner überlebt Finder-Umbenennungen. Die einzigen
/// Nachbardateien sind kurzlebige Claims für sicheres Entfernen/Veröffentlichen;
/// Bildbytes für Undo liegen ausschließlich im begrenzten Speicherpuffer.
final class MarkdownImageUndoFiles: @unchecked Sendable {
    private let images: [MarkdownImageStore.StoredImage]
    private let documentFD: Int32
    private let buffer: MarkdownImageUndoBuffer
    private let invalidated: () -> Void
    private var identities: [MarkdownImageStore.StoredFileIdentity]
    private var modes: [mode_t]
    private var ticket: UUID?

    init(images: [MarkdownImageStore.StoredImage],
         buffer: MarkdownImageUndoBuffer = .shared,
         invalidated: @escaping () -> Void = {}) {
        self.images = images
        self.buffer = buffer
        self.invalidated = invalidated
        identities = images.map(\.identity)
        modes = Array(repeating: mode_t(0o644), count: images.count)
        documentFD = images.first.map {
            open($0.fileURL.deletingLastPathComponent().deletingLastPathComponent().path,
                 O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        } ?? -1
    }

    deinit {
        discardMemory()
        if documentFD >= 0 { Darwin.close(documentFD) }
    }

    var documentDirectoryURL: URL? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard documentFD >= 0, fcntl(documentFD, F_GETPATH, &path) == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: path))
    }

    var currentURLs: Set<URL> {
        guard let directory = documentDirectoryURL?.appendingPathComponent("images") else {
            return Set(images.map(\.fileURL))
        }
        return Set(images.map { directory.appendingPathComponent($0.fileURL.lastPathComponent).canonicalFileURL })
    }

    func removeForUndo(gate: (() -> Bool) -> Bool = { $0() }) -> Bool {
        guard ticket == nil, let fd = openImages() else { return false }
        defer { Darwin.close(fd) }
        var total = 0
        for image in images {
            guard image.identity.size >= 0, image.identity.size <= Int64(Int.max - total) else { return false }
            total += Int(image.identity.size)
        }
        let reservation = buffer.reserve(bytes: total, invalidated: invalidated)
        var data: [Data] = []
        for (index, image) in images.enumerated() {
            guard let bytes = verifiedContent(image, expected: identities[index], in: fd,
                                              collect: reservation != nil) else {
                if let reservation { buffer.remove(reservation) }
                return false
            }
            if reservation != nil { data.append(bytes) }
            var info = stat()
            if fstatat(fd, image.fileURL.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                modes[index] = info.st_mode & mode_t(0o777)
            }
        }
        if let reservation, !buffer.fill(reservation, with: data) {
            buffer.remove(reservation)
            return false
        }
        guard removeVerifiedFiles(in: fd, requireComplete: false, gate: gate) else {
            if let reservation { buffer.remove(reservation) }
            return false
        }
        ticket = reservation
        if reservation == nil { buffer.invalidate(invalidated) }
        if images.contains(where: \.imagesDirectoryCreated) {
            _ = unlinkat(documentFD, "images", AT_REMOVEDIR)
        }
        return true
    }

    func restoreFromMemory() -> Bool {
        guard let ticket else { return false }
        let restored = buffer.withData(ticket) { data -> Bool in
            guard mkdirat(documentFD, "images", mode_t(0o755)) == 0 || errno == EEXIST,
                  let fd = openImages() else { return false }
            defer { Darwin.close(fd) }
            var published: [(String, MarkdownImageStore.StoredFileIdentity)] = []
            for (index, image) in images.enumerated() {
                let name = image.fileURL.lastPathComponent
                if let existing = identity(named: name, in: fd), sameFile(identities[index], existing),
                   verifiedContent(image, expected: existing, in: fd, collect: false) != nil { continue }
                let temporary = ".fastra-image-restore-\(UUID().uuidString).tmp"
                let output = openat(fd, temporary, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, modes[index])
                guard output >= 0 else { removePublished(published, in: fd); return false }
                let times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                             timespec(tv_sec: Int(identities[index].modificationSeconds), tv_nsec: Int(identities[index].modificationNanoseconds))]
                let wrote = write(data[index], to: output)
                    && times.withUnsafeBufferPointer { futimens(output, $0.baseAddress) == 0 }
                    && fsync(output) == 0
                Darwin.close(output)
                guard wrote, renameatx_np(fd, temporary, fd, name, UInt32(RENAME_EXCL)) == 0,
                      let identity = identity(named: name, in: fd) else {
                    _ = unlinkat(fd, temporary, 0)
                    removePublished(published, in: fd)
                    return false
                }
                identities[index] = identity
                published.append((name, identity))
            }
            return true
        } ?? false
        if restored { buffer.remove(ticket); self.ticket = nil }
        return restored
    }

    func discardMemory() {
        if let ticket { buffer.remove(ticket); self.ticket = nil }
    }

    /// Aufräumen und abgebrochene Einfügungen benötigen keine Undo-Kopie.
    func removePermanently(gate: (() -> Bool) -> Bool = { $0() }) -> Bool {
        guard let fd = openImages() else { return false }
        defer { Darwin.close(fd) }
        guard removeVerifiedFiles(in: fd, requireComplete: true, gate: gate) else { return false }
        if images.contains(where: \.imagesDirectoryCreated) { _ = unlinkat(documentFD, "images", AT_REMOVEDIR) }
        return true
    }

    private func openImages() -> Int32? {
        guard documentFD >= 0 else { return nil }
        let fd = openat(documentFD, "images", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        return fd >= 0 ? fd : nil
    }

    private func verifiedContent(_ image: MarkdownImageStore.StoredImage,
                                 expected: MarkdownImageStore.StoredFileIdentity,
                                 in directory: Int32, collect: Bool, named name: String? = nil) -> Data? {
        let name = name ?? image.fileURL.lastPathComponent
        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              UInt64(before.st_dev) == expected.device, UInt64(before.st_ino) == expected.inode,
              Int64(before.st_size) == expected.size, before.st_size >= 0,
              let observed = identity(named: name, in: directory),
              sameFile(expected, observed) else { return nil }
        if collect {
            var data = Data(count: Int(before.st_size))
            let read = data.withUnsafeMutableBytes { bytes -> Bool in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
            var after = stat()
            guard read, fstat(fd, &after) == 0, FileSnapshot.describesSameOpenedVersion(before, after),
                  FileSnapshot(data: data, identity: nil).sha256 == image.contentSHA256 else { return nil }
            return data
        }
        guard let snapshot = try? FileSnapshot.readSnapshotOnly(descriptor: fd, fileStat: before,
                                                                byteLimit: UInt64(image.identity.size)),
              snapshot.sha256 == image.contentSHA256 else { return nil }
        return Data()
    }

    private func removeVerifiedFiles(in directory: Int32, requireComplete: Bool, gate: (() -> Bool) -> Bool) -> Bool {
        var verified: [MarkdownImageStore.StoredFileIdentity] = []
        for (index, image) in images.enumerated() {
            let name = image.fileURL.lastPathComponent
            guard let observed = identity(named: name, in: directory), sameFile(identities[index], observed),
                  verifiedContent(image, expected: observed, in: directory, collect: false) != nil,
                  identity(named: name, in: directory) == observed else { return false }
            verified.append(observed)
        }
        // Nur die kurzen Metadatenoperationen laufen unter der Dokumentbarriere.
        // Lesen und Hashen bleiben davor auf der I/O-Queue.
        return gate {
            var claims: [(String, String)] = []
            func rollback() {
                for (name, claim) in claims.reversed() { _ = renameatx_np(directory, claim, directory, name, UInt32(RENAME_EXCL)) }
            }
            for (index, image) in images.enumerated() {
                let name = image.fileURL.lastPathComponent
                let observed = verified[index]
                guard identity(named: name, in: directory) == observed else { rollback(); return false }
                let claim = ".fastra-image-delete-\(UUID().uuidString).tmp"
                guard renameatx_np(directory, name, directory, claim, UInt32(RENAME_EXCL)) == 0 else { rollback(); return false }
                claims.append((name, claim))
                guard let claimed = identity(named: claim, in: directory), sameFile(observed, claimed) else { rollback(); return false }
            }
            var removed = 0
            for (_, claim) in claims {
                if unlinkat(directory, claim, 0) == 0 { removed += 1 }
            }
            if removed != claims.count { rollback() }
            return requireComplete ? removed == claims.count : removed > 0
        }
    }

    private func removePublished(_ published: [(String, MarkdownImageStore.StoredFileIdentity)], in directory: Int32) {
        for (name, expected) in published {
            guard identity(named: name, in: directory) == expected else { continue }
            let claim = ".fastra-image-delete-\(UUID().uuidString).tmp"
            guard renameatx_np(directory, name, directory, claim, UInt32(RENAME_EXCL)) == 0 else { continue }
            if let moved = identity(named: claim, in: directory), sameFile(expected, moved) { _ = unlinkat(directory, claim, 0) }
            else { _ = renameatx_np(directory, claim, directory, name, UInt32(RENAME_EXCL)) }
        }
    }

    private func sameFile(_ a: MarkdownImageStore.StoredFileIdentity, _ b: MarkdownImageStore.StoredFileIdentity) -> Bool {
        a.device == b.device && a.inode == b.inode && a.size == b.size
            && a.modificationSeconds == b.modificationSeconds && a.modificationNanoseconds == b.modificationNanoseconds
    }

    private func identity(named name: String, in directory: Int32) -> MarkdownImageStore.StoredFileIdentity? {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return MarkdownImageStore.StoredFileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec), modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(info.st_ctimespec.tv_sec), statusChangeNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }

    private func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}
