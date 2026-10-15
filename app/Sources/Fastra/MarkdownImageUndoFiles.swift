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
    private var ticket: UUID?

    init(images: [MarkdownImageStore.StoredImage],
         buffer: MarkdownImageUndoBuffer = .shared,
         invalidated: @escaping () -> Void = {}) {
        self.images = images
        self.buffer = buffer
        self.invalidated = invalidated
        identities = images.map(\.identity)
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
        var metadataBudget = 1024 * 1024
        var metadata: [Data] = []
        var snapshots: [MarkdownImageStore.StoredFileIdentity] = []
        for (index, image) in images.enumerated() {
            guard let captured = captureMetadata(image, expected: identities[index], in: fd, byteLimit: metadataBudget),
                  captured.data.count <= metadataBudget, captured.data.count <= Int.max - total else { return false }
            metadataBudget -= captured.data.count
            metadata.append(captured.data)
            snapshots.append(captured.identity)
            total += captured.data.count
        }
        let reservation = buffer.reserve(bytes: total, invalidated: invalidated)
        var data: [Data] = []
        for (index, image) in images.enumerated() {
            guard identity(named: image.fileURL.lastPathComponent, in: fd) == snapshots[index],
                  let bytes = verifiedContent(image, expected: snapshots[index], in: fd,
                                              collect: reservation != nil) else {
                if let reservation { buffer.remove(reservation) }
                return false
            }
            // Jedes Bild belegt im gemeinsamen Budget ein Byte-/Metadatenpaar.
            if reservation != nil { data.append(contentsOf: [bytes, metadata[index]]) }
        }
        if let reservation, !buffer.fill(reservation, with: data) {
            buffer.remove(reservation)
            return false
        }
        guard removeVerifiedFiles(in: fd, requireComplete: false, metadataSnapshots: snapshots, gate: gate) else {
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
                guard let metadata = try? PropertyListDecoder().decode(Metadata.self, from: data[index * 2 + 1]) else {
                    removePublished(published, in: fd)
                    return false
                }
                let temporary = ".fastra-image-restore-\(UUID().uuidString).tmp"
                let output = openat(fd, temporary, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
                guard output >= 0 else { removePublished(published, in: fd); return false }
                let modificationTime = timespec(tv_sec: Int(identities[index].modificationSeconds),
                                                tv_nsec: Int(identities[index].modificationNanoseconds))
                let wrote = write(data[index * 2], to: output)
                    && metadata.restore(to: output, modificationTime: modificationTime)
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

    private struct Metadata: Codable {
        let mode: UInt16
        let owner: UInt32
        let group: UInt32
        let accessControl: Data
        let attributes: [String: Data]

        func restore(to fd: Int32, modificationTime: timespec) -> Bool {
            var info = stat()
            guard fstat(fd, &info) == 0 else { return false }
            if info.st_uid != owner || info.st_gid != group {
                guard fchown(fd, uid_t(owner), gid_t(group)) == 0 else { return false }
            }
            for (name, value) in attributes {
                guard value.withUnsafeBytes({ fsetxattr(fd, name, $0.baseAddress, $0.count, 0, 0) }) == 0 else { return false }
            }
            // Eigentümerwechsel und umask können Modusbits ändern. Die ACL kommt
            // zuletzt, weil sie selbst Metadatenänderungen verbieten darf.
            let times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), modificationTime]
            guard fchmod(fd, mode_t(mode)) == 0,
                  times.withUnsafeBufferPointer({ futimens(fd, $0.baseAddress) }) == 0,
                  let acl = accessControl.withUnsafeBytes({ acl_copy_int($0.baseAddress) }) else { return false }
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0,
                  fstat(fd, &info) == 0 else { return false }
            return info.st_uid == owner && info.st_gid == group && info.st_mode & 0o7777 == mode
        }

        func canRestore(in directory: Int32, modificationTime: timespec) -> Bool {
            let name = ".fastra-image-metadata-\(UUID().uuidString).tmp"
            let fd = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
            guard fd >= 0 else { return false }
            defer { Darwin.close(fd) }
            // Vor der Rechteprobe vom Verzeichnis trennen: Selbst eine ACL mit
            // Löschsperre hinterlässt so keine unzugängliche Nachbardatei.
            guard unlinkat(directory, name, 0) == 0 else { return false }
            return restore(to: fd, modificationTime: modificationTime)
        }
    }

    private func captureMetadata(_ image: MarkdownImageStore.StoredImage,
                                 expected: MarkdownImageStore.StoredFileIdentity,
                                 in directory: Int32, byteLimit: Int) -> (data: Data, identity: MarkdownImageStore.StoredFileIdentity)? {
        let name = image.fileURL.lastPathComponent
        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              let snapshot = identity(named: name, in: directory), sameFile(expected, snapshot),
              UInt64(before.st_dev) == snapshot.device, UInt64(before.st_ino) == snapshot.inode else { return nil }
        // Metadaten bleiben ebenso begrenzt wie Bildbytes. Nicht sicher lesbare
        // Attribute verhindern das Entfernen, statt ein unvollständiges Undo zu sichern.
        let limit = byteLimit
        var acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED)
        if acl == nil && errno == ENOENT { acl = acl_init(0) }
        guard let acl else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let aclSize = acl_size(acl)
        guard aclSize > 0, aclSize <= limit else { return nil }
        var accessControl = Data(count: aclSize)
        guard accessControl.withUnsafeMutableBytes({ acl_copy_ext($0.baseAddress, acl, $0.count) }) == aclSize else { return nil }
        let count = flistxattr(fd, nil, 0, 0)
        guard count >= 0, count <= limit - aclSize else { return nil }
        var names = [CChar](repeating: 0, count: count)
        guard names.withUnsafeMutableBufferPointer({ flistxattr(fd, $0.baseAddress, $0.count, 0) }) == count else { return nil }
        var attributes: [String: Data] = [:]
        var total = count + aclSize
        for bytes in names.split(separator: 0) {
            let key = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let size = fgetxattr(fd, key, nil, 0, 0, 0)
            guard size >= 0, size <= limit - total else { return nil }
            var value = Data(count: size)
            guard value.withUnsafeMutableBytes({ fgetxattr(fd, key, $0.baseAddress, $0.count, 0, 0) }) == size else { return nil }
            attributes[key] = value
            total += size
        }
        var after = stat()
        let metadata = Metadata(mode: UInt16(before.st_mode & 0o7777), owner: before.st_uid,
                                group: before.st_gid, accessControl: accessControl, attributes: attributes)
        guard fstat(fd, &after) == 0, FileSnapshot.describesSameOpenedVersion(before, after),
              identity(named: name, in: directory) == snapshot,
              let data = try? PropertyListEncoder().encode(metadata), data.count <= byteLimit,
              metadata.canRestore(in: directory, modificationTime: before.st_mtimespec) else { return nil }
        return (data, snapshot)
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

    private func removeVerifiedFiles(in directory: Int32, requireComplete: Bool,
                                     metadataSnapshots: [MarkdownImageStore.StoredFileIdentity]? = nil, gate: (() -> Bool) -> Bool) -> Bool {
        var verified: [MarkdownImageStore.StoredFileIdentity] = []
        for (index, image) in images.enumerated() {
            let name = image.fileURL.lastPathComponent
            guard let observed = identity(named: name, in: directory), sameFile(identities[index], observed),
                  metadataSnapshots.map({ $0[index] == observed }) ?? true,
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
