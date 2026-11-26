import Darwin
import Foundation

/// Liest genau eine vorhandene Sitzung. Eine Beobachtung bestätigt die Ablage,
/// aber weder die Herkunft des Journals noch Schreib- oder Löschrechte an den
/// darin genannten Zielen und Aufräumpfaden. Diese bleiben ungeprüfte Referenzen.
enum ApplyRecoverySessionReader {
    static let maximumManifestBytes = 4 * 1024 * 1024
    static let maximumBackupBytes: UInt64 = 1024 * 1024 * 1024
    static let maximumEntries = 10_000

    enum Resource: Equatable {
        case root, session, files, manifest
        case backup(String)
    }

    enum InvalidReason: Equatable {
        case name, fileType, owner, writableByOthers, extendedACL, hardLink
        case malformedManifest, sessionReference, backupReference, targetReference
        case cleanupReference, snapshot, backupContent
    }

    enum UnsupportedReason: Equatable {
        case schema(Int), legacyEntry, missingAppliedBasis, cleanupWithoutBinding, emptySession
        case manifestLimit, entryLimit, backupLimit
    }

    enum Failure: Error, Equatable {
        case invalid(Resource, InvalidReason)
        case missing(Resource)
        case changed(Resource)
        case unsupported(UnsupportedReason)
        case system(Resource, Int32)
    }

    struct DirectoryObservation: Equatable {
        let identity: FileIdentity
        let owner: uid_t
        let mode: mode_t
        let birthSeconds: Int64
        let birthNanoseconds: Int64

        fileprivate init(_ info: stat) {
            identity = FileIdentity(stat: info)
            owner = info.st_uid
            mode = info.st_mode
            birthSeconds = Int64(info.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
        }
    }

    struct FileObservation: Equatable {
        let snapshot: FileSnapshot
        let owner: uid_t
        let mode: mode_t
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
        let birthSeconds: Int64
        let birthNanoseconds: Int64

        fileprivate init(snapshot: FileSnapshot, info: stat) {
            self.snapshot = snapshot
            owner = info.st_uid
            mode = info.st_mode
            modificationSeconds = Int64(info.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changeSeconds = Int64(info.st_ctimespec.tv_sec)
            changeNanoseconds = Int64(info.st_ctimespec.tv_nsec)
            birthSeconds = Int64(info.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
        }
    }

    struct Observation: Equatable {
        let backupRoot: URL
        let sessionName: String
        let session: ApplySession
        let root: DirectoryObservation
        let directory: DirectoryObservation
        let files: DirectoryObservation?
        let manifest: FileObservation
        let backups: [String: FileObservation]
    }

    /// `backupRoot` ist der vom Aufrufer bewusst aufgelöste feste Speicherort,
    /// niemals ein aus dem Manifest übernommener Pfad. `matching` verlangt bei
    /// einer späteren Bestätigung dieselbe vollständig neu gelesene Beobachtung.
    static func read(sessionNamed name: String, in backupRoot: URL,
                     matching expected: Observation? = nil,
                     beforeFinalValidation: (() throws -> Void)? = nil) throws -> Observation {
        guard component(name), name.hasPrefix("session-") else {
            throw Failure.invalid(.session, .name)
        }
        guard absoluteFileURL(backupRoot) else { throw Failure.invalid(.root, .name) }
        let reader = BoundReader(root: backupRoot)
        do {
            let result = try reader.read(name: name, beforeFinalValidation: beforeFinalValidation)
            if let expected, result != expected { throw Failure.changed(.session) }
            try reader.finish()
            return result
        } catch {
            try reader.finish()
            throw error
        }
    }

    private struct BoundDirectory {
        let descriptor: Int32
        let resource: Resource
        let observation: DirectoryObservation
        let name: String
        let parent: Int?
    }

    private struct BoundFile {
        let descriptor: Int32
        let resource: Resource
        let name: String
        let parent: Int
        let version: stat
    }

    private struct ReadBackup {
        let resource: Resource
        let name: String
        let parent: Int
        let version: stat
    }

    private final class BoundReader {
        let root: URL
        var directories: [BoundDirectory] = []
        var files: [BoundFile] = []
        var backups: [ReadBackup] = []

        init(root: URL) { self.root = root }
        deinit {
            for file in files.reversed() { close(file.descriptor) }
            for directory in directories.reversed() { close(directory.descriptor) }
        }

        func read(name: String, beforeFinalValidation: (() throws -> Void)?) throws -> Observation {
            let rootIndex = try bindDirectory(name: nil, parent: nil, resource: .root)
            let sessionIndex = try bindDirectory(name: name, parent: rootIndex, resource: .session)
            let manifest = try bindFile(name: "manifest.json", parent: sessionIndex, resource: .manifest)
            guard manifest.version.st_size >= 0,
                  manifest.version.st_size <= maximumManifestBytes else {
                throw Failure.unsupported(.manifestLimit)
            }
            let bytes = try readManifest(manifest)
            let session: ApplySession
            do { session = try JSONDecoder().decode(ApplySession.self, from: bytes) }
            catch { throw Failure.invalid(.manifest, .malformedManifest) }
            try validate(session, name: name)
            guard session.sessionDirectory.path == root.appendingPathComponent(name).path else {
                throw Failure.invalid(.manifest, .sessionReference)
            }
            let manifestObservation = FileObservation(
                snapshot: FileSnapshot(data: bytes, identity: FileIdentity(stat: manifest.version)),
                info: manifest.version)
            var backupObservations: [String: FileObservation] = [:]
            var filesObservation: DirectoryObservation?
            // Wie beim Undo braucht bereits persistierter Teilfortschritt seine
            // alten Sicherungsbytes nicht mehr. Die Referenzen bleiben validiert.
            let openEntries = session.entries.filter { $0.state != .restored }
            if !openEntries.isEmpty {
                let filesIndex = try bindDirectory(name: "files", parent: sessionIndex, resource: .files)
                filesObservation = directories[filesIndex].observation
                var total: UInt64 = 0
                for entry in openEntries {
                    let relative = entry.backupRelativePath
                    let file = try bindFile(name: String(relative.dropFirst("files/".count)),
                                            parent: filesIndex, resource: .backup(relative))
                    let count = UInt64(max(0, file.version.st_size))
                    guard file.version.st_size >= 0, count <= FileSnapshot.maximumReadBytes,
                          count <= maximumBackupBytes - total else {
                        throw Failure.unsupported(.backupLimit)
                    }
                    total += count
                    let snapshot: FileSnapshot
                    do {
                        snapshot = try FileSnapshot.readSnapshotOnly(descriptor: file.descriptor,
                            fileStat: file.version, byteLimit: count)
                    } catch { throw mappedReadError(error, resource: file.resource) }
                    guard snapshot.sha256 == entry.originalSHA256 else {
                        throw Failure.invalid(file.resource, .backupContent)
                    }
                    backupObservations[relative] = FileObservation(snapshot: snapshot, info: file.version)
                    backups.append(ReadBackup(resource: file.resource, name: file.name,
                                              parent: file.parent, version: file.version))
                    // Nur die aktuelle Sicherung offen halten. Große Sitzungen
                    // dürfen nicht am prozessweiten Deskriptorlimit scheitern.
                    files.removeAll { $0.descriptor == file.descriptor }
                    guard close(file.descriptor) == 0 else { throw Failure.system(file.resource, errno) }
                }
            }
            try beforeFinalValidation?()
            try revalidate()
            return Observation(backupRoot: root, sessionName: name, session: session,
                root: directories[rootIndex].observation, directory: directories[sessionIndex].observation,
                files: filesObservation, manifest: manifestObservation, backups: backupObservations)
        }

        func bindDirectory(name: String?, parent: Int?, resource: Resource) throws -> Int {
            let descriptor: Int32
            var info = stat()
            if let parent, let name {
                descriptor = openat(directories[parent].descriptor, name, ApplyFileSystem.childDirectoryReadFlags)
                guard descriptor >= 0 else { throw openFailure(resource) }
                guard fstat(descriptor, &info) == 0 else {
                    let failure = Failure.system(resource, errno)
                    close(descriptor)
                    throw failure
                }
            } else {
                do {
                    let opened = try ApplyFileSystem.openRootDirectory(at: root)
                    descriptor = opened.descriptor
                    info = opened.info
                } catch let error as POSIXError {
                    errno = error.code.rawValue
                    throw openFailure(resource)
                }
            }
            directories.append(BoundDirectory(descriptor: descriptor, resource: resource,
                observation: DirectoryObservation(info), name: name ?? root.path, parent: parent))
            try validateAccess(descriptor, info: info, type: S_IFDIR, resource: resource)
            try revalidate(includeFiles: false)
            return directories.count - 1
        }

        func bindFile(name: String, parent: Int, resource: Resource) throws -> BoundFile {
            let descriptor = openat(directories[parent].descriptor, name,
                ApplyFileSystem.childFileReadFlags)
            guard descriptor >= 0 else { throw openFailure(resource) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                let failure = Failure.system(resource, errno)
                close(descriptor)
                throw failure
            }
            let file = BoundFile(descriptor: descriptor, resource: resource,
                                 name: name, parent: parent, version: info)
            files.append(file)
            try validateAccess(descriptor, info: info, type: S_IFREG, resource: resource)
            guard info.st_nlink == 1 else { throw Failure.invalid(resource, .hardLink) }
            try revalidate(includeFiles: false)
            return file
        }

        func readManifest(_ file: BoundFile) throws -> Data {
            let handle = FileHandle(fileDescriptor: file.descriptor, closeOnDealloc: false)
            var bytes = Data()
            do {
                while true {
                    let chunk = try handle.read(upToCount: min(64 * 1024, maximumManifestBytes - bytes.count + 1)) ?? Data()
                    if chunk.isEmpty { break }
                    bytes.append(chunk)
                    guard bytes.count <= maximumManifestBytes else { throw Failure.unsupported(.manifestLimit) }
                }
            } catch let error as Failure { throw error }
            catch { throw mappedReadError(error, resource: .manifest) }
            try revalidate()
            return bytes
        }

        func revalidate(includeFiles: Bool = true) throws {
            for directory in directories {
                var opened = stat()
                var named = stat()
                guard fstat(directory.descriptor, &opened) == 0 else {
                    throw Failure.system(directory.resource, errno)
                }
                let status: Int32
                if let parent = directory.parent {
                    status = fstatat(directories[parent].descriptor, directory.name, &named, AT_SYMLINK_NOFOLLOW)
                } else {
                    let reopened: (descriptor: Int32, info: stat)
                    do { reopened = try ApplyFileSystem.openRootDirectory(at: root) }
                    catch let error as POSIXError {
                        switch error.code {
                        case .ENOENT, .ENOTDIR, .ELOOP:
                            throw Failure.changed(directory.resource)
                        default:
                            throw Failure.system(directory.resource, error.code.rawValue)
                        }
                    }
                    named = reopened.info
                    guard close(reopened.descriptor) == 0 else { throw Failure.system(directory.resource, errno) }
                    status = 0
                }
                guard status == 0,
                      DirectoryObservation(opened) == directory.observation,
                      DirectoryObservation(named) == directory.observation else {
                    throw Failure.changed(directory.resource)
                }
                try validateAccess(directory.descriptor, info: opened, type: S_IFDIR, resource: directory.resource)
            }
            guard includeFiles else { return }
            for file in files {
                var opened = stat()
                var named = stat()
                guard fstat(file.descriptor, &opened) == 0 else { throw Failure.system(file.resource, errno) }
                guard fstatat(directories[file.parent].descriptor, file.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      FileSnapshot.describesSameOpenedVersion(file.version, opened),
                      FileSnapshot.describesSameOpenedVersion(opened, named),
                      opened.st_mode == named.st_mode, opened.st_nlink == 1 else {
                    throw Failure.changed(file.resource)
                }
                try validateAccess(file.descriptor, info: opened, type: S_IFREG, resource: file.resource)
            }
            for backup in backups {
                var named = stat()
                guard fstatat(directories[backup.parent].descriptor, backup.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      FileSnapshot.describesSameOpenedVersion(backup.version, named),
                      backup.version.st_birthtimespec.tv_sec == named.st_birthtimespec.tv_sec,
                      backup.version.st_birthtimespec.tv_nsec == named.st_birthtimespec.tv_nsec,
                      backup.version.st_mode == named.st_mode, backup.version.st_uid == named.st_uid,
                      named.st_nlink == 1 else {
                    throw Failure.changed(backup.resource)
                }
            }
        }

        func finish() throws {
            let closing = files.reversed().map { ($0.descriptor, $0.resource) }
                + directories.reversed().map { ($0.descriptor, $0.resource) }
            files.removeAll()
            directories.removeAll()
            var failure: Failure?
            for (descriptor, resource) in closing {
                if close(descriptor) != 0, failure == nil { failure = .system(resource, errno) }
            }
            if let failure { throw failure }
        }
    }

    static func hasValidCleanupReferences(_ session: ApplySession) -> Bool {
        for entry in session.entries {
            if let pending = entry.pendingFile {
                let target = URL(fileURLWithPath: entry.originalPath)
                guard isValidCleanupReference(pending, expectedTarget: target) else { return false }
            }
        }
        for pending in session.retainedPendingFiles {
            guard isValidCleanupReference(pending, expectedTarget: nil) else { return false }
        }
        return true
    }

    private static func isValidCleanupReference(_ pending: ApplyPendingFile, expectedTarget: URL?) -> Bool {
        guard valid(pending.snapshot), pending.snapshot.identity != nil,
              let work = pending.cleanupDirectory,
              absoluteFileURL(pending.url), absoluteFileURL(work.url), absoluteFileURL(work.preparedURL),
              work.url.lastPathComponent.hasPrefix(".fastra-pending-work-"),
              UUID(uuidString: String(work.url.lastPathComponent.dropFirst(".fastra-pending-work-".count))) != nil,
              ApplyFileSystem.isApplyTemporaryFilename(work.preparedURL.lastPathComponent,
                                                       targetName: expectedTarget?.lastPathComponent),
              work.url.deletingLastPathComponent() == work.preparedURL.deletingLastPathComponent(),
              (pending.url == work.preparedURL || pending.url == work.url.appendingPathComponent("anchor")) else {
            return false
        }
        if let expectedTarget {
            return work.preparedURL.deletingLastPathComponent() == expectedTarget.deletingLastPathComponent()
        }
        return true
    }

    private static func validate(_ session: ApplySession, name: String) throws {
        guard session.schemaVersion == 2 else {
            throw Failure.unsupported(.schema(session.schemaVersion))
        }
        guard session.hasRecoveryWork else { throw Failure.unsupported(.emptySession) }
        guard session.entries.count <= maximumEntries,
              session.retainedPendingFiles.count <= maximumEntries else { throw Failure.unsupported(.entryLimit) }
        guard absoluteFileURL(session.sessionDirectory),
              session.sessionDirectory.lastPathComponent == name else {
            throw Failure.invalid(.manifest, .sessionReference)
        }
        var references = Set<String>()
        for entry in session.entries {
            guard absolutePath(entry.originalPath) else { throw Failure.invalid(.manifest, .targetReference) }
            let parts = entry.backupRelativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "files", component(String(parts[1])),
                  references.insert(entry.backupRelativePath).inserted else {
                throw Failure.invalid(.manifest, .backupReference)
            }
            guard hash(entry.originalSHA256), entry.bom.count <= 4 else {
                throw Failure.invalid(.manifest, .snapshot)
            }
            guard entry.state != .legacy else { throw Failure.unsupported(.legacyEntry) }
            guard let applied = entry.appliedSnapshot, valid(applied) else {
                throw Failure.unsupported(.missingAppliedBasis)
            }
            if let pending = entry.pendingFile, let work = pending.cleanupDirectory {
                let target = URL(fileURLWithPath: entry.originalPath)
                guard work.preparedURL.deletingLastPathComponent() == target.deletingLastPathComponent(),
                      ApplyFileSystem.isApplyTemporaryFilename(work.preparedURL.lastPathComponent,
                                                               targetName: target.lastPathComponent) else {
                    throw Failure.invalid(.manifest, .cleanupReference)
                }
            }
        }
        for pending in session.retainedPendingFiles + session.entries.compactMap(\.pendingFile) {
            guard valid(pending.snapshot), pending.snapshot.identity != nil else {
                throw Failure.invalid(.manifest, .snapshot)
            }
            guard let work = pending.cleanupDirectory else { throw Failure.unsupported(.cleanupWithoutBinding) }
            guard absoluteFileURL(pending.url), absoluteFileURL(work.url), absoluteFileURL(work.preparedURL),
                  work.url.lastPathComponent.hasPrefix(".fastra-pending-work-"),
                  UUID(uuidString: String(work.url.lastPathComponent.dropFirst(".fastra-pending-work-".count))) != nil,
                  ApplyFileSystem.isApplyTemporaryFilename(work.preparedURL.lastPathComponent),
                  work.url.deletingLastPathComponent() == work.preparedURL.deletingLastPathComponent(),
                  (pending.url == work.preparedURL || pending.url == work.url.appendingPathComponent("anchor")) else {
                throw Failure.invalid(.manifest, .cleanupReference)
            }
        }
    }

    private static func validateAccess(_ descriptor: Int32, info: stat, type: mode_t,
                                       resource: Resource) throws {
        guard info.st_mode & S_IFMT == type else { throw Failure.invalid(resource, .fileType) }
        guard info.st_uid == getuid() else { throw Failure.invalid(resource, .owner) }
        guard info.st_mode & 0o022 == 0 else { throw Failure.invalid(resource, .writableByOthers) }
        let mutatingACL: Bool
        do { mutatingACL = try ApplyFileSystem.hasMutatingExtendedACL(descriptor) }
        catch let error as POSIXError { throw Failure.system(resource, error.code.rawValue) }
        guard !mutatingACL else { throw Failure.invalid(resource, .extendedACL) }
    }

    private static func component(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
            && !value.utf8.contains(0) && value.utf8.count <= Int(MAXNAMLEN)
    }

    private static func absolutePath(_ path: String) -> Bool {
        // MAXNAMLEN ist keine UTF-8-Bytegrenze für beliebige macOS-Zielnamen.
        // Diese Referenzen werden erst in der Vorschau am Dateisystem gebunden.
        path.hasPrefix("/") && path.utf8.count < Int(PATH_MAX) && !path.utf8.contains(0)
            && path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    private static func absoluteFileURL(_ url: URL) -> Bool {
        url.isFileURL && url.host == nil && url.query == nil && url.fragment == nil && absolutePath(url.path)
    }

    private static func valid(_ snapshot: FileSnapshot) -> Bool {
        snapshot.byteCount >= 0 && UInt64(snapshot.byteCount) <= FileSnapshot.maximumReadBytes && hash(snapshot.sha256)
    }

    private static func hash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func openFailure(_ resource: Resource) -> Failure {
        switch errno {
        case ENOENT: return .missing(resource)
        case ELOOP, ENOTDIR: return .invalid(resource, .fileType)
        default: return .system(resource, errno)
        }
    }

    private static func mappedReadError(_ error: Error, resource: Resource) -> Failure {
        if let failure = error as? Failure { return failure }
        if error as? FileSnapshotReadError == .changedDuringRead { return .changed(resource) }
        if let readError = error as? FileSnapshotReadError, case .tooLarge = readError {
            return .changed(resource)
        }
        return .system(resource, (error as NSError).code == 0 ? EIO : Int32(clamping: (error as NSError).code))
    }
}
