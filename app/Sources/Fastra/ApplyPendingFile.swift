import Darwin
import Foundation

/// Ein eigener Hardlink hält die für pending belegte Inode am Leben, auch
/// wenn Commit-Rollback oder ein fremder Replace ihren bisherigen Namen lösen.
/// Claim-Namen liegen ausschließlich im gebundenen privaten Arbeitsordner.
struct ApplyPendingFile: Codable, Equatable {
    struct PreparationFailure: Error, LocalizedError {
        let cause: Error
        let cleanupCause: Error?
        let remainingURLs: [URL]
        let pendingFile: ApplyPendingFile?

        var errorDescription: String? {
            var message = cause.localizedDescription
            if let cleanupCause {
                message += "\n" + L10n.format("Zusätzlicher Fehler beim Sichern oder Aufräumen: %@",
                                               cleanupCause.localizedDescription)
            }
            if !remainingURLs.isEmpty {
                message += "\n" + L10n.format("Erhaltene Pfade:\n%@",
                                               remainingURLs.map(\.path).joined(separator: "\n"))
            }
            return message
        }
    }

    struct CleanupDirectory: Codable, Equatable {
        let url: URL
        let identity: FileIdentity
        let preparedURL: URL

        static func create(nextTo source: URL) throws -> CleanupDirectory {
            let parent = source.deletingLastPathComponent()
            let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard parentFD >= 0 else { throw ApplyFileSystem.posixError() }
            defer { close(parentFD) }
            let name = ".fastra-pending-work-\(UUID().uuidString)"
            guard mkdirat(parentFD, name, mode_t(0o700)) == 0 else { throw ApplyFileSystem.posixError() }
            let workURL = parent.appendingPathComponent(name, isDirectory: true)
            do {
                let descriptor = openat(parentFD, name,
                                        ApplyFileSystem.childDirectoryReadFlags)
                guard descriptor >= 0 else { throw ApplyFileSystem.posixError() }
                defer { close(descriptor) }
                var info = stat()
                guard fstat(descriptor, &info) == 0 else { throw ApplyFileSystem.posixError() }
                let result = CleanupDirectory(url: workURL,
                                              identity: FileIdentity(stat: info), preparedURL: source)
                guard info.st_uid == getuid(), info.st_mode & mode_t(0o777) == mode_t(0o700) else {
                    throw POSIXError(.EACCES)
                }
                // mkdir erbt unter macOS auch Allow-ACLs. Nur den eigenen neuen
                // Ordner am gebundenen FD bereinigen; Modusbits allein sind nicht privat.
                try removeExtendedACL(from: descriptor)
                guard fsync(descriptor) == 0, fsync(parentFD) == 0 else { throw ApplyFileSystem.posixError() }
                return result
            } catch {
                // Ohne bestätigte Privatheit existiert nur ein Diagnosepfad,
                // kein Auftrag, der den Ordner später entfernen dürfte.
                throw PreparationFailure(cause: error, cleanupCause: nil,
                                         remainingURLs: [workURL], pendingFile: nil)
            }
        }

        func openBound() throws -> Int32 {
            let descriptor = open(url.path, ApplyFileSystem.childDirectoryReadFlags)
            guard descriptor >= 0 else { throw ApplyFileSystem.posixError() }
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  FileIdentity(stat: info) == identity,
                  info.st_uid == getuid(), info.st_mode & mode_t(0o777) == mode_t(0o700) else {
                close(descriptor)
                throw AtomicFileCommit.Failure.recoveryRequired(target: url, displaced: url)
            }
            do {
                guard try Self.hasNoExtendedACL(descriptor) else {
                    throw AtomicFileCommit.Failure.recoveryRequired(target: url, displaced: url)
                }
            } catch {
                close(descriptor)
                throw error
            }
            return descriptor
        }

        private static func removeExtendedACL(from descriptor: Int32) throws {
            guard let empty = acl_init(0) else { throw ApplyFileSystem.posixError() }
            defer { acl_free(UnsafeMutableRawPointer(empty)) }
            guard acl_set_fd_np(descriptor, empty, ACL_TYPE_EXTENDED) == 0 else { throw ApplyFileSystem.posixError() }
            guard try hasNoExtendedACL(descriptor) else { throw POSIXError(.EACCES) }
        }

        private static func hasNoExtendedACL(_ descriptor: Int32) throws -> Bool {
            try !ApplyFileSystem.hasExtendedACL(descriptor) { _ in true }
        }

        func finish(snapshot: FileSnapshot?) throws {
            let descriptor: Int32
            do { descriptor = try openBound() }
            catch let error as POSIXError where error.code == .ENOENT { return }
            defer { close(descriptor) }
            let (remaining, limited) = try ApplyFileSystem.scanChildren(descriptor, limit: 3)
            guard !limited else {
                throw AtomicFileCommit.Failure.recoveryRequired(target: url, displaced: url)
            }
            if !remaining.isEmpty {
                // Ein anderer eigener Auftrag desselben Bereichs darf bis zu
                // seinem späteren Cleanup weiterleben, auch als Crash-Claim.
                let knownNames = Set(["anchor", "anchor.claim", "prepared.claim"])
                guard let snapshot else {
                    throw AtomicFileCommit.Failure.recoveryRequired(target: url, displaced: url)
                }
                for name in remaining {
                    guard knownNames.contains(name),
                          (try? readSnapshot(in: descriptor, name: name, expected: snapshot)) == snapshot else {
                        throw AtomicFileCommit.Failure.recoveryRequired(target: url,
                            displaced: url.appendingPathComponent(name))
                    }
                }
                return
            }
            if try ApplyPendingFile.lstatExists(preparedURL) {
                // Anker und Nachbar teilen diesen Arbeitsbereich. Der
                // Temp-Auftrag prüft seinen öffentlichen Namen selbst.
                return
            }
            let parentFD = open(url.deletingLastPathComponent().path,
                                O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard parentFD >= 0 else { throw ApplyFileSystem.posixError() }
            defer { close(parentFD) }
            var current = stat()
            guard fstatat(parentFD, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  FileIdentity(stat: current) == identity else {
                throw AtomicFileCommit.Failure.recoveryRequired(target: url, displaced: url)
            }
            // rmdir entfernt ausschließlich einen leeren Ordner. Das ist kein
            // rekursiver Cleanup fremder Inhalte und keine Same-UID-Abwehr.
            guard unlinkat(parentFD, url.lastPathComponent, AT_REMOVEDIR) == 0,
                  fsync(parentFD) == 0 else { throw ApplyFileSystem.posixError() }
        }
    }

    let url: URL
    let snapshot: FileSnapshot
    let cleanupDirectory: CleanupDirectory?

    init(url: URL, snapshot: FileSnapshot, cleanupDirectory: CleanupDirectory? = nil) {
        self.url = url
        self.snapshot = snapshot
        self.cleanupDirectory = cleanupDirectory
    }

    var cleanupClaimURL: URL? {
        guard let work = cleanupDirectory else { return nil }
        let isAnchor = url.standardizedFileURL == work.url.appendingPathComponent("anchor").standardizedFileURL
        return work.url.appendingPathComponent(isAnchor ? "anchor.claim" : "prepared.claim")
    }

    static func prepare(_ bytes: Data, at url: URL) throws -> ApplyPendingFile {
        let work = try CleanupDirectory.create(nextTo: url)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                              mode_t(0o600))
        guard descriptor >= 0 else {
            let failure = ApplyFileSystem.posixError()
            do {
                try work.finish(snapshot: nil)
                if (try? lstatExists(work.url)) != false {
                    throw PreparationFailure(cause: failure, cleanupCause: nil,
                                             remainingURLs: [work.url], pendingFile: nil)
                }
            } catch let detail as PreparationFailure { throw detail }
            catch {
                throw PreparationFailure(cause: failure, cleanupCause: error,
                    remainingURLs: remainingURLs(source: url, work: work), pendingFile: nil)
            }
            throw failure
        }
        defer { close(descriptor) }
        do {
            try bytes.withUnsafeBytes { try POSIXBufferWriter.writeAll($0, to: descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw ApplyFileSystem.posixError() }
            return ApplyPendingFile(url: url,
                snapshot: FileSnapshot(data: bytes, identity: FileIdentity(stat: info)), cleanupDirectory: work)
        } catch {
            let failure = error
            let partial: FileSnapshot
            do {
                var info = stat()
                guard fstat(descriptor, &info) == 0 else { throw ApplyFileSystem.posixError() }
                partial = try FileSnapshot.readSnapshotOnly(descriptor: descriptor, fileStat: info)
            } catch {
                throw PreparationFailure(cause: failure, cleanupCause: error,
                    remainingURLs: remainingURLs(source: url, work: work), pendingFile: nil)
            }
            let pending = ApplyPendingFile(url: url, snapshot: partial, cleanupDirectory: work)
            do { try pending.remove() }
            catch {
                throw PreparationFailure(cause: failure, cleanupCause: error,
                    remainingURLs: remainingURLs(source: url, work: work), pendingFile: pending)
            }
            throw failure
        }
    }

    var cleanupResourceURLs: [URL] {
        [url] + (cleanupDirectory.map { [$0.url] } ?? [])
    }

    private static func remainingURLs(source: URL, work: CleanupDirectory) -> [URL] {
        // Ein fehlgeschlagenes Rename belegt keinen Claim. Nur beobachtete
        // Claims nennen; bei unlesbaren Quell-/Ordnerpfaden konservativ erhalten.
        var paths = [source, work.url].filter { (try? lstatExists($0)) != false }
        let claim = work.url.appendingPathComponent("prepared.claim")
        if (try? lstatExists(claim)) == true { paths.append(claim) }
        return paths
    }

    static func retain(preparedURL: URL, descriptor: Int32,
                       snapshot: FileSnapshot, cleanupDirectory: CleanupDirectory? = nil,
                       onCreate: ((ApplyPendingFile) -> Void)? = nil) throws -> ApplyPendingFile {
        let work = try cleanupDirectory ?? CleanupDirectory.create(nextTo: preparedURL)
        let workFD = try work.openBound()
        defer { close(workFD) }
        let anchor = work.url.appendingPathComponent("anchor")
        let file = ApplyPendingFile(url: anchor, snapshot: snapshot, cleanupDirectory: work)
        // Der Zielname gehört zum gebundenen privaten Ordner. Die Quelle wird
        // danach nochmals gegen den vom Standardcommitter gehaltenen FD geprüft.
        guard linkat(AT_FDCWD, preparedURL.path, workFD, "anchor", 0) == 0 else { throw ApplyFileSystem.posixError() }
        onCreate?(file)
        var bound = stat()
        guard fstat(descriptor, &bound) == 0,
              FileIdentity(stat: bound) == snapshot.identity, file.isValid else {
            throw AtomicFileCommit.Failure.recoveryRequired(target: preparedURL, displaced: anchor)
        }
        return file
    }

    func synchronize() throws {
        guard let work = cleanupDirectory else { throw recoveryFailure() }
        let descriptor = try work.openBound()
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw ApplyFileSystem.posixError() }
    }

    var isValid: Bool {
        guard snapshot.identity != nil, let work = cleanupDirectory,
              let descriptor = try? work.openBound() else { return false }
        defer { close(descriptor) }
        return (try? Self.readSnapshot(in: descriptor, name: url.lastPathComponent,
                                      expected: snapshot)) == snapshot
    }

    /// Erst nach erfolgreicher Manifestfortschreibung aufrufen. Der öffentliche
    /// Quellname wird in den eigenen, gebundenen 0700-Ordner beansprucht; Unlink
    /// findet ausschließlich dort statt. Erkannte Fremdstände bleiben erhalten.
    func remove(afterClaim: ((URL) throws -> Void)? = nil) throws {
        guard let work = cleanupDirectory, let claimURL = cleanupClaimURL else { throw recoveryFailure() }
        let workFD: Int32
        do { workFD = try work.openBound() }
        catch let error as POSIXError where error.code == .ENOENT {
            // Bereits erledigter Auftrag. Ein neu besetzter Quellname wird
            // ohne den eigenen Arbeitsbereich keinesfalls angefasst.
            guard try Self.lstatExists(url) == false else { throw recoveryFailure() }
            return
        }
        defer { close(workFD) }
        let sourceFD = open(url.deletingLastPathComponent().path,
                            ApplyFileSystem.childDirectoryReadFlags)
        guard sourceFD >= 0 else { throw ApplyFileSystem.posixError() }
        defer { close(sourceFD) }
        let claim = claimURL.lastPathComponent
        let flags = ApplyFileSystem.exclusiveRenameFlags
        // Vorhandene Claims gehören zu einem unterbrochenen Aufruf. Kein
        // erneutes Rename darf sie überschreiben oder einen Fremdstand löschen.
        let resumingClaim = try Self.childExists(in: workFD, name: claim)
        if !resumingClaim {
            if try !Self.childExists(in: sourceFD, name: url.lastPathComponent) {
                try work.finish(snapshot: snapshot)
                return
            }
            guard renameatx_np(sourceFD, url.lastPathComponent, workFD, claim, flags) == 0 else {
                throw ApplyFileSystem.posixError()
            }
        }
        try afterClaim?(claimURL)
        guard (try? Self.readSnapshot(in: workFD, name: claim, expected: snapshot)) == snapshot else {
            // Bei Resume bleibt der erkannte Fremdstand ebenfalls erhalten;
            // die Rückstellung ist exklusiv und kann nichts überschreiben.
            let restored = !resumingClaim && renameatx_np(workFD, claim, sourceFD,
                                                         url.lastPathComponent, flags) == 0
            throw recoveryFailure(displaced: restored ? url : claimURL)
        }
        guard unlinkat(workFD, claim, 0) == 0, fsync(workFD) == 0,
              fsync(sourceFD) == 0 else { throw ApplyFileSystem.posixError() }
        try work.finish(snapshot: snapshot)
    }

    private func recoveryFailure(displaced: URL? = nil) -> AtomicFileCommit.Failure {
        .recoveryRequired(target: url, displaced: displaced ?? cleanupDirectory?.url ?? url)
    }

    private static func readSnapshot(in directoryFD: Int32, name: String,
                                     expected: FileSnapshot) throws -> FileSnapshot {
        let descriptor = openat(directoryFD, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ApplyFileSystem.posixError() }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              FileIdentity(stat: info) == expected.identity else { throw POSIXError(.EINVAL) }
        return try FileSnapshot.readSnapshotOnly(descriptor: descriptor, fileStat: info,
                                                byteLimit: UInt64(max(0, expected.byteCount)))
    }

    private static func childExists(in directoryFD: Int32, name: String) throws -> Bool {
        var info = stat()
        if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw ApplyFileSystem.posixError()
    }

    private static func lstatExists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw ApplyFileSystem.posixError()
    }
}
