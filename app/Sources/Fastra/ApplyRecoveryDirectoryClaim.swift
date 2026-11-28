import CRemoveFile
import Darwin
import Foundation

/// Koordiniert bestätigte Wiederherstellung und Altersbereinigung über die
/// vorhandene Verzeichnisdatei. Der Anspruch beweist keine Journalherkunft.
/// Ein Caller besitzt die Instanz exklusiv und beendet seinen Scope mit finish().
final class ApplyRecoveryDirectoryClaim {
    enum Rejection: Error, Equatable {
        case invalidPath
        case unprotectedDirectory
        case changedDirectory
        case closed
    }

    struct CloseFailure: Error {
        let primary: Error?
        let closeErrors: [Error]
    }

    let rootURL: URL
    let sessionName: String
    let rootIdentity: FileIdentity
    let sessionIdentity: FileIdentity

    private var rootDescriptor: Int32?
    private var sessionDescriptor: Int32?

    /// Der Root wird wie beim Erzeuger vorher bewusst aliasaufgelöst. Weder
    /// hier noch bei späterer Bestätigung werden Verknüpfungen verfolgt.
    init(root: URL, sessionName: String,
         expectedRootIdentity: FileIdentity? = nil,
         expectedSessionIdentity: FileIdentity? = nil) throws {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.utf8.contains(0),
              sessionName.hasPrefix("session-"), sessionName != "session-",
              !sessionName.contains("/"), !sessionName.utf8.contains(0) else {
            throw Rejection.invalidPath
        }
        // standardizedFileURL würde /private/var und /private/tmp wieder auf
        // die Symlinknamen /var und /tmp verkürzen und No-follow verletzen.
        rootURL = root
        self.sessionName = sessionName
        let rootOpened = try ApplyFileSystem.openRootDirectory(at: rootURL)
        let rootFD = rootOpened.descriptor
        var sessionFD: Int32?
        do {
            try Self.requireProtectedDirectory(rootOpened.info)
            guard try !ApplyFileSystem.hasMutatingExtendedACL(rootFD) else {
                throw Rejection.unprotectedDirectory
            }
            let rootInfo = rootOpened.info
            let actualRootIdentity = FileIdentity(stat: rootInfo)
            if let expectedRootIdentity, expectedRootIdentity != actualRootIdentity {
                throw Rejection.changedDirectory
            }
            let descriptor = openat(rootFD, sessionName, ApplyFileSystem.childDirectoryReadFlags)
            guard descriptor >= 0 else { throw ApplyFileSystem.posixError() }
            sessionFD = descriptor
            let sessionInfo = try Self.protectedDirectory(descriptor)
            let actualSessionIdentity = FileIdentity(stat: sessionInfo)
            if let expectedSessionIdentity, expectedSessionIdentity != actualSessionIdentity {
                throw Rejection.changedDirectory
            }
            // Kein Warten und kein eigenes Lockfile: getrennte FDs und Prozesse
            // konkurrieren um genau diese geöffnete Verzeichnisdatei.
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ApplyFileSystem.posixError() }
            rootIdentity = actualRootIdentity
            sessionIdentity = actualSessionIdentity
        } catch {
            let errors = Self.closeDescriptors(sessionFD.map { [$0, rootFD] } ?? [rootFD])
            if !errors.isEmpty { throw CloseFailure(primary: error, closeErrors: errors) }
            throw error
        }
        rootDescriptor = rootFD
        sessionDescriptor = sessionFD
        do { try validateBinding() }
        catch { try finish(after: error) }
    }

    deinit { try? finish() }

    /// Nach jeder Unterbrechung erneut aufrufen. Ein neuer gleichnamiger
    /// Ordner wird nie Teil des bereits bestehenden Anspruchs.
    func validateBinding() throws {
        guard let rootDescriptor, let sessionDescriptor else { throw Rejection.closed }
        let openedRoot = try Self.protectedDirectory(rootDescriptor)
        let openedSession = try Self.protectedDirectory(sessionDescriptor)
        guard FileIdentity(stat: openedRoot) == rootIdentity,
              FileIdentity(stat: openedSession) == sessionIdentity else {
            throw Rejection.changedDirectory
        }
        // Erneutes No-follow-Öffnen erkennt auch einen nachträglich eingefügten
        // Elternsymlink. lstat allein würde solche Zwischenkomponenten folgen.
        let namedRoot = try ApplyFileSystem.openRootDirectory(at: rootURL).descriptor
        var failure: Error?
        do {
            let info = try Self.protectedDirectory(namedRoot)
            var namedSession = stat()
            guard fstatat(rootDescriptor, sessionName, &namedSession, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ApplyFileSystem.posixError()
            }
            try Self.requireProtectedDirectory(namedSession)
            guard FileIdentity(stat: info) == rootIdentity,
                  FileIdentity(stat: namedSession) == sessionIdentity else {
                throw Rejection.changedDirectory
            }
        } catch { failure = error }
        let errors = Self.closeDescriptors([namedRoot])
        if !errors.isEmpty { throw CloseFailure(primary: failure, closeErrors: errors) }
        if let failure { throw failure }
    }

    func isOlder(than cutoff: Date) throws -> Bool {
        try validateBinding()
        guard let sessionDescriptor else { throw Rejection.closed }
        let time = try Self.protectedDirectory(sessionDescriptor).st_mtimespec
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000 < cutoff.timeIntervalSince1970
    }

    func readManifestForCleanup() throws -> (data: Data, version: stat)? {
        guard let sessionDescriptor else { throw Rejection.closed }
        let descriptor = openat(sessionDescriptor, "manifest.json", ApplyFileSystem.childFileReadFlags)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw ApplyFileSystem.posixError()
        }
        defer { close(descriptor) }
        var version = stat()
        guard fstat(descriptor, &version) == 0 else { throw ApplyFileSystem.posixError() }
        guard version.st_mode & S_IFMT == S_IFREG else { throw FileSnapshotReadError.notRegularFile }
        let result = try FileSnapshot.read(descriptor: descriptor, fileStat: version,
            byteLimit: UInt64(ApplyRecoverySessionReader.maximumManifestBytes), isCancelled: { false })
        try validateCleanupManifest(version)
        return (result.data, version)
    }

    private func validateCleanupManifest(_ expected: stat?) throws {
        guard let sessionDescriptor else { throw Rejection.closed }
        var named = stat()
        guard fstatat(sessionDescriptor, "manifest.json", &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT, expected == nil { return }
            throw ApplyFileSystem.posixError()
        }
        guard let expected, FileSnapshot.describesSameOpenedVersion(expected, named),
              named.st_mode & S_IFMT == S_IFREG else { throw Rejection.changedDirectory }
    }

    func removeExpiredDirectory(olderThan cutoff: Date, expectedManifest: stat?) throws {
        guard try isOlder(than: cutoff) else { return }
        try validateCleanupManifest(expectedManifest)
        guard let rootDescriptor else { throw Rejection.closed }
        let claimedName = ".cleanup-\(UUID().uuidString)"
        let flags = ApplyFileSystem.exclusiveRenameFlags
        guard renameatx_np(rootDescriptor, sessionName, rootDescriptor, claimedName, flags) == 0 else {
            throw ApplyFileSystem.posixError()
        }
        do {
            var named = stat()
            guard fstatat(rootDescriptor, claimedName, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  FileIdentity(stat: named) == sessionIdentity, named.st_mode & S_IFMT == S_IFDIR else {
                throw Rejection.changedDirectory
            }
            try validateCleanupManifest(expectedManifest)
            // Rekursiv nur unter dem exklusiven Claim am bereits gebundenen Root.
            guard removefileat(rootDescriptor, claimedName, nil, UInt32(REMOVEFILE_RECURSIVE)) == 0 else {
                throw ApplyFileSystem.posixError()
            }
        } catch {
            _ = renameatx_np(rootDescriptor, claimedName, rootDescriptor, sessionName, flags)
            throw error
        }
    }

    /// Close gibt flock frei. Nummern vor dem Schließen abgeben, damit weder
    /// Fehlerpfad noch deinit einen inzwischen neu vergebenen FD schließen.
    func finish() throws {
        let descriptors = [sessionDescriptor, rootDescriptor].compactMap { $0 }
        sessionDescriptor = nil
        rootDescriptor = nil
        let errors = Self.closeDescriptors(descriptors)
        if !errors.isEmpty { throw CloseFailure(primary: nil, closeErrors: errors) }
    }

    func finish(after primary: Error) throws -> Never {
        do { try finish() }
        catch let failure as CloseFailure {
            throw CloseFailure(primary: primary, closeErrors: failure.closeErrors)
        }
        throw primary
    }

    private static func protectedDirectory(_ descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ApplyFileSystem.posixError() }
        try requireProtectedDirectory(info)
        guard try !ApplyFileSystem.hasMutatingExtendedACL(descriptor) else {
            throw Rejection.unprotectedDirectory
        }
        return info
    }

    private static func requireProtectedDirectory(_ info: stat) throws {
        // Foundation legte ältere Root-/Session-Ordner regulär mit 0755 an.
        // Fremde Leserechte allein machen diese bestehenden Journale nicht ungültig.
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o700 == 0o700,
              info.st_mode & 0o022 == 0 else { throw Rejection.unprotectedDirectory }
    }

    private static func closeDescriptors(_ descriptors: [Int32]) -> [Error] {
        var errors: [Error] = []
        for descriptor in descriptors {
            if close(descriptor) != 0 { errors.append(ApplyFileSystem.posixError()) }
        }
        return errors
    }
}
