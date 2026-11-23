import Darwin
import Foundation

/// Zusätzliche Barrieren für die bestehende Foundation-Ablage. Die Prüfungen
/// bestätigen Inhalt und Namensbindung. Nur selbst angelegte, registrierte
/// Artefakte dürfen nach erneuter Identitäts- und Inhaltsprüfung entfernt werden.
final class ApplyPersistenceBarriers {
    struct Failure: LocalizedError {
        let primary: Error
        let closeErrors: [Error]

        var errorDescription: String? {
            ([primary] + closeErrors).map { error in
                if error is FileSnapshotReadError {
                    return L10n.string("Die Sicherung wurde verändert oder ist keine reguläre Datei.")
                }
                return error.localizedDescription
            }.joined(separator: "\n")
        }
    }

    private struct Directory {
        let url: URL
        let descriptor: Int32
        let identity: FileIdentity
        let parentIndex: Int?
    }

    private var directories: [Directory] = []
    private let missingComponents: [String]
    private var filesIndex: Int?
    private var sessionIndex: Int?
    private var stagedIndex: Int?
    private var removedDirectories: Set<Int> = []

    private struct Artifact {
        let directoryIndex: Int
        let name: String
        let snapshot: FileSnapshot
        let birthtime: timespec
    }
    private var artifacts: [Artifact] = []
    private var backupVersions: [String: stat] = [:]

    static func resolvingRootAliases(_ root: URL) throws -> URL {
        var existing = root.standardizedFileURL
        var missing: [String] = []
        var info = stat()
        // Foundation löst bei einem fehlenden Gesamtpfad vorhandene Aliase
        // nicht zuverlässig auf. Deshalb nur den vorhandenen Teil auflösen.
        while lstat(existing.path, &info) != 0 {
            guard errno == ENOENT, existing.path != "/" else {
                throw Failure(primary: Self.posixError(), closeErrors: [])
            }
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard let resolved = realpath(existing.path, nil) else {
            throw Failure(primary: Self.posixError(), closeErrors: [])
        }
        defer { free(resolved) }
        let anchor = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        return missing.reduce(anchor) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
    }

    /// Der konfigurierte Root wurde vom Caller einmal bewusst aufgelöst.
    /// Nur unterhalb des vorhandenen Ankers gilt der neue No-follow-Vertrag.
    init(beforeCreating sessionDirectory: URL) throws {
        var anchor = sessionDirectory
        var missing: [String] = []
        while true {
            var info = stat()
            if lstat(anchor.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else {
                    throw Failure(primary: POSIXError(.ENOTDIR), closeErrors: [])
                }
                break
            }
            guard errno == ENOENT, anchor.path != "/" else {
                throw Failure(primary: Self.posixError(), closeErrors: [])
            }
            missing.insert(anchor.lastPathComponent, at: 0)
            anchor.deleteLastPathComponent()
        }
        missingComponents = missing
        let descriptor = open(anchor.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw Failure(primary: Self.posixError(), closeErrors: [])
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let primary = Self.posixError()
            let closeErrors = close(descriptor) == 0 ? [] : [Self.posixError()]
            throw Failure(primary: primary, closeErrors: closeErrors)
        }
        directories = [Directory(url: anchor, descriptor: descriptor,
            identity: FileIdentity(stat: info), parentIndex: nil)]
        do { try validateDirectories() }
        catch { try finish(after: Failure(primary: error, closeErrors: [])) }
    }

    deinit {
        // Nur Absicherung für einen vor der eigentlichen Barriere verlassenen
        // Pfad. Alle Erfolgs- und Fehlergrenzen werten finish ausdrücklich aus.
        for directory in directories.reversed() { close(directory.descriptor) }
    }

    /// Gemeinsame Eltern dürfen parallel entstanden sein. Session und ihre
    /// beiden Arbeitsordner müssen dagegen nachweislich aus diesem Aufruf stammen.
    func createAndBindDirectories() throws {
        guard !missingComponents.isEmpty else { throw POSIXError(.EEXIST) }
        for (index, component) in missingComponents.enumerated() {
            try validateDirectories()
            let parent = directories.count - 1
            if mkdirat(directories[parent].descriptor, component, mode_t(0o700)) != 0 {
                guard errno == EEXIST, index < missingComponents.count - 1 else { throw Self.posixError() }
            }
            try appendDirectory(component, parent: parent)
        }
        let sessionIndex = directories.count - 1
        self.sessionIndex = sessionIndex
        for name in ["files", "staged"] {
            try validateDirectories()
            guard mkdirat(directories[sessionIndex].descriptor, name, mode_t(0o700)) == 0 else { throw Self.posixError() }
            try appendDirectory(name, parent: sessionIndex)
            if name == "files" { filesIndex = directories.count - 1 }
            else { stagedIndex = directories.count - 1 }
        }
        try validateDirectories()
    }

    private func appendDirectory(_ name: String, parent: Int) throws {
        try validateDirectories()
        let parentDirectory = directories[parent]
        let descriptor = openat(parentDirectory.descriptor, name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posixError() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let primary = Self.posixError()
            let closeErrors = close(descriptor) == 0 ? [] : [Self.posixError()]
            throw Failure(primary: primary, closeErrors: closeErrors)
        }
        directories.append(Directory(url: parentDirectory.url.appendingPathComponent(name),
            descriptor: descriptor, identity: FileIdentity(stat: info), parentIndex: parent))
        try validateDirectories()
    }

    func synchronizeBackup(named name: String, expected: FileSnapshot) throws {
        guard let filesIndex else {
            throw POSIXError(.ENOENT)
        }
        backupVersions[name] = try synchronizeFile(named: name, in: directories[filesIndex], expected: expected)
    }

    func synchronizeDirectories() throws {
        try validateDirectories()
        for directory in directories.reversed() {
            try FileDurability.synchronizeDirectory(directory.descriptor)
            try validateDirectories()
        }
    }

    @discardableResult
    private func synchronizeFile(named name: String, in directory: Directory,
                                 expected: FileSnapshot, synchronizeParent: Bool = false,
                                 synchronize: Bool = true, requiringIdentity: Bool = false) throws -> stat {
        try validateDirectories()
        let descriptor = openat(directory.descriptor, name,
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posixError() }
        var failure: Error?
        var before = stat()
        do {
            guard fstat(descriptor, &before) == 0 else { throw Self.posixError() }
            guard (before.st_mode & S_IFMT) == S_IFREG else {
                throw FileSnapshotReadError.notRegularFile
            }
            guard before.st_size >= 0, before.st_size == expected.byteCount else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let snapshot = try FileSnapshot.readSnapshotOnly(descriptor: descriptor,
                fileStat: before, byteLimit: UInt64(expected.byteCount))
            guard snapshot.hasSameContent(as: expected) else { throw CocoaError(.fileReadCorruptFile) }
            if requiringIdentity {
                guard expected.identity != nil, snapshot.identity == expected.identity else {
                    throw FileSnapshotReadError.changedDuringRead
                }
            }
            if synchronize { try FileDurability.synchronizeFile(descriptor) }
            try validateFile(descriptor, named: name, in: directory, version: before)
            if synchronizeParent {
                try FileDurability.synchronizeDirectory(directory.descriptor)
                try validateFile(descriptor, named: name, in: directory, version: before)
            }
            try validateDirectories()
        } catch { failure = error }
        let closeError: Error? = close(descriptor) == 0 ? nil : Self.posixError()
        if let failure {
            throw Failure(primary: failure, closeErrors: closeError.map { [$0] } ?? [])
        }
        if let closeError { throw Failure(primary: closeError, closeErrors: []) }
        return before
    }

    private func validateFile(_ descriptor: Int32, named name: String,
                              in directory: Directory, version: stat) throws {
        var current = stat()
        var named = stat()
        guard fstat(descriptor, &current) == 0,
              fstatat(directory.descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Self.posixError()
        }
        guard (named.st_mode & S_IFMT) == S_IFREG,
              FileSnapshot.describesSameOpenedVersion(version, current),
              FileSnapshot.describesSameOpenedVersion(current, named) else {
            throw FileSnapshotReadError.changedDuringRead
        }
    }

    var isFinished: Bool { directories.isEmpty }

    func validateRecoveryDirectories(requiringBackups: Bool = true) throws {
        try validateDirectories(includingStaged: false, includingFiles: requiringBackups)
    }

    func validateDirectories(includingStaged: Bool = true, includingFiles: Bool = true) throws {
        for (index, directory) in directories.enumerated()
            where !removedDirectories.contains(index) && (includingStaged || index != stagedIndex)
                && (includingFiles || index != filesIndex) {
            var opened = stat()
            var named = stat()
            guard fstat(directory.descriptor, &opened) == 0 else { throw Self.posixError() }
            let result: Int32
            if let parent = directory.parentIndex {
                result = fstatat(directories[parent].descriptor, directory.url.lastPathComponent,
                                 &named, AT_SYMLINK_NOFOLLOW)
            } else {
                result = lstat(directory.url.path, &named)
            }
            guard result == 0 else { throw Self.posixError() }
            guard (opened.st_mode & S_IFMT) == S_IFDIR,
                  (named.st_mode & S_IFMT) == S_IFDIR,
                  FileIdentity(stat: opened) == directory.identity,
                  FileIdentity(stat: named) == directory.identity else {
                throw FileSnapshotReadError.changedDuringRead
            }
        }
    }

    /// Jeden FD genau einmal schließen. Nach Closefehlern ist seine Nummer
    /// nicht mehr unser Eigentum; ein erneuter Close wäre nicht sicher.
    private func closeDirectories() -> [Error] {
        let closing = directories.reversed().map(\.descriptor)
        directories.removeAll()
        var closeErrors: [Error] = []
        for descriptor in closing {
            if close(descriptor) != 0 { closeErrors.append(Self.posixError()) }
        }
        return closeErrors
    }

    func finish() throws {
        let closeErrors = closeDirectories()
        if let first = closeErrors.first {
            throw Failure(primary: first, closeErrors: Array(closeErrors.dropFirst()))
        }
    }

    func finish(after primary: Error) throws -> Never {
        let closeErrors = closeDirectories()
        if closeErrors.isEmpty { throw primary }
        throw Failure(primary: primary, closeErrors: closeErrors)
    }

    /// Neue Dateien werden relativ zum ursprünglichen Ordner angelegt. Ein
    /// gleichnamiger Ersatzordner erhält weder Originale noch Ersatzbytes.
    func prepare(_ data: Data, named name: String, staged: Bool) throws {
        guard let index = staged ? stagedIndex : filesIndex else { throw POSIXError(.ENOENT) }
        try create(data, named: name, in: index)
    }

    private func create(_ data: Data, named name: String, in index: Int) throws {
        try validateDirectories()
        let directory = directories[index]
        let descriptor = openat(directory.descriptor, name,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw Self.posixError() }
        var failure: Error?
        do {
            try data.withUnsafeBytes { try POSIXBufferWriter.writeAll($0, to: descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw Self.posixError() }
            artifacts.append(Artifact(directoryIndex: index, name: name,
                snapshot: FileSnapshot(data: data, identity: FileIdentity(stat: info)), birthtime: info.st_birthtimespec))
            try validateFile(descriptor, named: name, in: directory, version: info)
            try validateDirectories()
        } catch { failure = error }
        let closeErrors = close(descriptor) == 0 ? [] : [Self.posixError()]
        if let failure { throw Failure(primary: failure, closeErrors: closeErrors) }
        if let first = closeErrors.first { throw Failure(primary: first, closeErrors: []) }
    }

    func validateBackup(named name: String, expected: FileSnapshot,
                        requiringIdentity: Bool = false) throws {
        guard let filesIndex else { throw POSIXError(.ENOENT) }
        try validateDirectories()
        let directory = directories[filesIndex]
        var named = stat()
        guard fstatat(directory.descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.posixError() }
        if let verified = backupVersions[name], named.st_mode & S_IFMT == S_IFREG,
           !requiringIdentity || (expected.identity != nil && FileIdentity(stat: named) == expected.identity),
           FileSnapshot.describesSameOpenedVersion(verified, named),
           verified.st_birthtimespec.tv_sec == named.st_birthtimespec.tv_sec,
           verified.st_birthtimespec.tv_nsec == named.st_birthtimespec.tv_nsec {
            // Ein bereits gehashter, unveränderter Dateistand braucht an den
            // kurzen Swapgrenzen keinen weiteren vollständigen Lesedurchlauf.
            try validateDirectories()
            return
        }
        backupVersions[name] = try synchronizeFile(named: name, in: directory, expected: expected,
                                                  synchronize: false, requiringIdentity: requiringIdentity)
    }

    func readStaged(named name: String, expected: FileSnapshot) throws -> Data {
        guard let stagedIndex else { throw POSIXError(.ENOENT) }
        try validateDirectories()
        let directory = directories[stagedIndex]
        let descriptor = openat(directory.descriptor, name,
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posixError() }
        var failure: Error?
        var bytes = Data()
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw Self.posixError() }
            guard info.st_mode & S_IFMT == S_IFREG else { throw FileSnapshotReadError.notRegularFile }
            guard info.st_size == expected.byteCount else { throw CocoaError(.fileReadCorruptFile) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            while true {
                let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                bytes.append(chunk)
                guard bytes.count <= expected.byteCount else { throw CocoaError(.fileReadCorruptFile) }
            }
            guard FileSnapshot(data: bytes, identity: nil).hasSameContent(as: expected) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try validateFile(descriptor, named: name, in: directory, version: info)
            try validateDirectories()
        } catch { failure = error }
        let closeErrors = close(descriptor) == 0 ? [] : [Self.posixError()]
        if let failure { throw Failure(primary: failure, closeErrors: closeErrors) }
        if let first = closeErrors.first { throw Failure(primary: first, closeErrors: []) }
        return bytes
    }

    @discardableResult
    func writeManifest(_ data: Data, allowingExistingManifest: Bool = false,
                       expectedPreviousManifest: FileSnapshot? = nil,
                       validateBinding: (() throws -> Void)? = nil) throws -> FileSnapshot {
        guard let sessionIndex else { throw POSIXError(.ENOENT) }
        let directory = directories[sessionIndex]
        let temporary = ".manifest-\(UUID().uuidString)"
        func validatePreviousManifest() throws {
            if let expectedPreviousManifest {
                try synchronizeFile(named: "manifest.json", in: directory,
                    expected: expectedPreviousManifest, synchronize: false, requiringIdentity: true)
            } else if let previous = artifacts.first(where: { $0.directoryIndex == sessionIndex && $0.name == "manifest.json" }) {
                try synchronizeFile(named: "manifest.json", in: directory,
                    expected: previous.snapshot, synchronize: false)
            } else if !allowingExistingManifest {
                var info = stat()
                if fstatat(directory.descriptor, "manifest.json", &info, AT_SYMLINK_NOFOLLOW) == 0 {
                    throw FileSnapshotReadError.changedDuringRead
                }
                guard errno == ENOENT else { throw Self.posixError() }
            }
        }
        do {
            try validateBinding?()
            try validatePreviousManifest()
            try create(data, named: temporary, in: sessionIndex)
            try synchronizeFile(named: temporary, in: directory,
                expected: FileSnapshot(data: data, identity: nil))
            try validateDirectories()
            try validateBinding?()
            try validatePreviousManifest()
            guard renameat(directory.descriptor, temporary, directory.descriptor, "manifest.json") == 0 else {
                throw Self.posixError()
            }
            let written = artifacts.removeLast()
            artifacts.removeAll { $0.directoryIndex == sessionIndex && $0.name == "manifest.json" }
            artifacts.append(Artifact(directoryIndex: sessionIndex, name: "manifest.json", snapshot: written.snapshot, birthtime: written.birthtime))
            try synchronizeFile(named: "manifest.json", in: directory,
                expected: written.snapshot, synchronizeParent: true,
                requiringIdentity: expectedPreviousManifest != nil)
            try validateDirectories()
            try validateBinding?()
            return written.snapshot
        } catch { throw Failure(primary: error, closeErrors: []) }
    }

    /// Testwriter ersetzen die Veröffentlichung. Nur ein bestätigter Write
    /// gehört danach zur eigenen Cleanup-Liste; ein Throw erteilt keine Vollmacht.
    func acknowledgeManifest(_ data: Data) throws {
        guard let sessionIndex else { throw POSIXError(.ENOENT) }
        try validateDirectories()
        let directory = directories[sessionIndex]
        let descriptor = openat(directory.descriptor, "manifest.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return }
            throw Self.posixError()
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Self.posixError() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw FileSnapshotReadError.notRegularFile }
        let snapshot = try FileSnapshot.readSnapshotOnly(descriptor: descriptor, fileStat: info,
            byteLimit: UInt64(data.count))
        guard snapshot.hasSameContent(as: FileSnapshot(data: data, identity: nil)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        artifacts.removeAll { $0.directoryIndex == sessionIndex && $0.name == "manifest.json" }
        artifacts.append(Artifact(directoryIndex: sessionIndex, name: "manifest.json", snapshot: snapshot, birthtime: info.st_birthtimespec))
        try validateDirectories()
    }

    /// Kein rekursives Entfernen am öffentlichen Namen. Erst den konkreten
    /// Eintrag beanspruchen, dann seine Identität und Bytes bestätigen.
    func cleanup(keepingSession: Bool, afterClaim: ((URL) throws -> Void)? = nil) throws {
        try validateDirectories()
        guard let stagedIndex, let filesIndex, let sessionIndex else { throw POSIXError(.ENOENT) }
        for artifact in artifacts where artifact.directoryIndex == stagedIndex { try remove(artifact, afterClaim: afterClaim) }
        try removeDirectory(stagedIndex)
        if keepingSession { return }
        for artifact in artifacts where artifact.directoryIndex == filesIndex { try remove(artifact, afterClaim: afterClaim) }
        try removeDirectory(filesIndex)
        for artifact in artifacts where artifact.directoryIndex == sessionIndex { try remove(artifact, afterClaim: afterClaim) }
        try removeDirectory(sessionIndex)
    }

    private func remove(_ artifact: Artifact, afterClaim: ((URL) throws -> Void)?) throws {
        let directory = directories[artifact.directoryIndex]
        let claim = ".cleanup-\(UUID().uuidString)"
        let flags = UInt32(RENAME_EXCL) | UInt32(RENAME_NOFOLLOW_ANY) | UInt32(RENAME_RESOLVE_BENEATH)
        guard renameatx_np(directory.descriptor, artifact.name, directory.descriptor, claim, flags) == 0 else {
            if errno == ENOENT { return }
            throw Self.posixError()
        }
        if let afterClaim {
            let currentDirectory = reachablePath(of: directory).map { URL(fileURLWithPath: $0) } ?? directory.url
            try afterClaim(currentDirectory.appendingPathComponent(claim))
        }
        let descriptor = openat(directory.descriptor, claim, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        var verified = false
        if descriptor >= 0 {
            var info = stat()
            if fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
               FileIdentity(stat: info) == artifact.snapshot.identity,
               info.st_birthtimespec.tv_sec == artifact.birthtime.tv_sec,
               info.st_birthtimespec.tv_nsec == artifact.birthtime.tv_nsec {
                verified = (try? FileSnapshot.readSnapshotOnly(descriptor: descriptor, fileStat: info,
                    byteLimit: UInt64(artifact.snapshot.byteCount))) == artifact.snapshot
            }
            close(descriptor)
        }
        guard verified else {
            // Ein exklusiver Rückweg überschreibt auch bei einem weiteren
            // Fremd-Write nichts. Bleibt der Claim, nennt die Fehlerdiagnose den Ordner.
            _ = renameatx_np(directory.descriptor, claim, directory.descriptor, artifact.name, flags)
            throw FileSnapshotReadError.changedDuringRead
        }
        guard unlinkat(directory.descriptor, claim, 0) == 0 else { throw Self.posixError() }
        try FileDurability.synchronizeDirectory(directory.descriptor)
    }

    private func removeDirectory(_ index: Int) throws {
        let directory = directories[index]
        guard let parent = directory.parentIndex else { throw POSIXError(.EINVAL) }
        let parentFD = directories[parent].descriptor
        let claim = ".cleanup-\(UUID().uuidString)"
        let flags = UInt32(RENAME_EXCL) | UInt32(RENAME_NOFOLLOW_ANY) | UInt32(RENAME_RESOLVE_BENEATH)
        guard renameatx_np(parentFD, directory.url.lastPathComponent, parentFD, claim, flags) == 0 else {
            throw Self.posixError()
        }
        var info = stat()
        guard fstatat(parentFD, claim, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFDIR, FileIdentity(stat: info) == directory.identity else {
            _ = renameatx_np(parentFD, claim, parentFD, directory.url.lastPathComponent, flags)
            throw FileSnapshotReadError.changedDuringRead
        }
        guard unlinkat(parentFD, claim, AT_REMOVEDIR) == 0 else {
            let failure = Self.posixError()
            _ = renameatx_np(parentFD, claim, parentFD, directory.url.lastPathComponent, flags)
            throw failure
        }
        removedDirectories.insert(index)
        try FileDurability.synchronizeDirectory(parentFD)
    }

    /// F_GETPATH ist nur eine aktuelle Beobachtung, keine Zusage gegen spätere
    /// Umbenennungen. Der gelieferte Name wird erneut auf dieselbe Inode geprüft.
    private func reachablePath(of directory: Directory) -> String? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(directory.descriptor, F_GETPATH, &path) == 0 else { return nil }
        let name = String(cString: path)
        var info = stat()
        guard lstat(name, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              FileIdentity(stat: info) == directory.identity else { return nil }
        return name
    }

    func reachableDirectoryPaths() -> [String] {
        [sessionIndex, filesIndex, stagedIndex].compactMap { index in
            guard let index, !removedDirectories.contains(index) else { return nil }
            return reachablePath(of: directories[index])
        }
    }

    func reachableBackupPaths() -> [String] {
        guard let filesIndex, !removedDirectories.contains(filesIndex) else { return [] }
        let directory = directories[filesIndex]
        guard let path = reachablePath(of: directory) else { return [] }
        return artifacts.filter { $0.directoryIndex == filesIndex }.compactMap { artifact in
            let descriptor = openat(directory.descriptor, artifact.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  let snapshot = try? FileSnapshot.readSnapshotOnly(descriptor: descriptor, fileStat: info,
                    byteLimit: UInt64(artifact.snapshot.byteCount)),
                  snapshot.hasSameContent(as: artifact.snapshot),
                  (try? validateFile(descriptor, named: artifact.name, in: directory, version: info)) != nil,
                  reachablePath(of: directory) == path else { return nil }
            return URL(fileURLWithPath: path).appendingPathComponent(artifact.name).path
        }
    }

    /// Ein bestätigter historischer Stand nutzt dieselben Directory- und
    /// Manifestbarrieren wie Apply; nur die erwarteten Identitäten kommen
    /// zusätzlich aus der zuvor gelesenen Vorschau.
    final class RecoveryValidation {
        private let claim: ApplyRecoveryDirectoryClaim
        private let binding: ApplyPersistenceBarriers
        private var manifest: FileSnapshot
        private let backups: [String: FileSnapshot]

        init(session: ApplySession, holding claim: ApplyRecoveryDirectoryClaim,
             expectedManifest: FileSnapshot, expectedBackups: [String: FileSnapshot]) throws {
            try claim.validateBinding()
            let directory = claim.rootURL.appendingPathComponent(claim.sessionName, isDirectory: true)
            let neededBackups = Set(session.entries.filter { $0.state != .restored }.map(\.backupRelativePath))
            guard session.sessionDirectory.standardizedFileURL.path == directory.standardizedFileURL.path,
                  expectedManifest.identity != nil, expectedManifest.byteCount >= 0,
                  UInt64(expectedManifest.byteCount) <= FileSnapshot.maximumReadBytes,
                  Set(expectedBackups.keys) == neededBackups,
                  expectedBackups.allSatisfy({ path, snapshot in
                      let components = path.components(separatedBy: "/")
                      return components.count == 2 && components[0] == "files"
                          && !components[1].isEmpty && components[1] != "." && components[1] != ".."
                          && !path.utf8.contains(0) && snapshot.identity != nil && snapshot.byteCount >= 0
                  }) else { throw FileSnapshotReadError.changedDuringRead }
            self.claim = claim
            manifest = expectedManifest
            backups = expectedBackups
            binding = try ApplyPersistenceBarriers(beforeCreating: claim.rootURL)
            do {
                guard binding.missingComponents.isEmpty,
                      binding.directories[0].identity == claim.rootIdentity else {
                    throw FileSnapshotReadError.changedDuringRead
                }
                try binding.appendDirectory(claim.sessionName, parent: 0)
                let sessionIndex = binding.directories.count - 1
                binding.sessionIndex = sessionIndex
                guard binding.directories[sessionIndex].identity == claim.sessionIdentity else {
                    throw FileSnapshotReadError.changedDuringRead
                }
                if !backups.isEmpty {
                    try binding.appendDirectory("files", parent: sessionIndex)
                    binding.filesIndex = binding.directories.count - 1
                }
                try validate()
                let read = try FileSnapshot.read(from: directory.appendingPathComponent("manifest.json"),
                                                byteLimit: UInt64(expectedManifest.byteCount))
                guard read.snapshot == expectedManifest,
                      try JSONDecoder().decode(ApplySession.self, from: read.data) == session else {
                    throw FileSnapshotReadError.changedDuringRead
                }
                try validate()
            } catch { try binding.finish(after: error) }
        }

        private func validateResources() throws {
            try claim.validateBinding()
            for (path, expected) in backups {
                try binding.validateBackup(named: URL(fileURLWithPath: path).lastPathComponent,
                                           expected: expected, requiringIdentity: true)
            }
            try claim.validateBinding()
        }

        func validate() throws {
            try validateResources()
            guard let index = binding.sessionIndex else { throw POSIXError(.ENOENT) }
            try binding.synchronizeFile(named: "manifest.json", in: binding.directories[index],
                expected: manifest, synchronize: false, requiringIdentity: true)
            try validateResources()
        }

        func validateBackup(_ path: String, readSnapshot: FileSnapshot? = nil) throws {
            guard let expected = backups[path], readSnapshot == nil || readSnapshot == expected else {
                throw FileSnapshotReadError.changedDuringRead
            }
            try validate()
        }

        func writeManifest(_ data: Data) throws {
            try validate()
            manifest = try binding.writeManifest(data, expectedPreviousManifest: manifest,
                validateBinding: { try self.validateResources() })
            try validate()
        }

        func finish() throws { try binding.finish() }
        func finish(after error: Error) throws -> Never { try binding.finish(after: error) }
    }

    static func writeManifest(_ data: Data, in sessionDirectory: URL) throws {
        let parent = try resolvingRootAliases(sessionDirectory.deletingLastPathComponent())
        let binding = try ApplyPersistenceBarriers(beforeCreating: parent)
        do {
            guard binding.missingComponents.isEmpty else { throw POSIXError(.ENOENT) }
            try binding.appendDirectory(sessionDirectory.lastPathComponent, parent: 0)
            binding.sessionIndex = binding.directories.count - 1
            try binding.writeManifest(data, allowingExistingManifest: true)
            try binding.finish()
        } catch { try binding.finish(after: Failure(primary: error, closeErrors: [])) }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
