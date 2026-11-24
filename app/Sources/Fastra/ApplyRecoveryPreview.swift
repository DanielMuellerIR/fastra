import Darwin
import Foundation

/// Rein lesende Freigabebasis. Prozessprüfung, Pfadreservierung und ungesicherte
/// Tabs bleiben Aufgabe des Aufrufers; eine Vorschau allein erlaubt kein Undo.
struct ApplyRecoveryPreview {
    struct Limits {
        var sessions = 100
        var directoryEntries = 10_000
        var totalBackupBytes = 1024 * 1024 * 1024
        var totalTargetBytes = 1024 * 1024 * 1024
        var diffBytes = 4 * 1024 * 1024
        var diffDisplayBytes = 8 * 1024 * 1024
    }

    enum Failure: Error, Equatable {
        case limit
        case invalidPath(URL)
        case outsideSelectedRoots(URL)
        case changed(URL)
        case invalidResource(URL)
        case targetConflict(URL)
        case cleanupConflict(URL)
        case duplicateTarget(URL)
        case wrongClaim
        case noDifference
        case undecodable(URL)
        case incompleteDiff
        case system(URL, Int32)
    }

    struct DirectoryMetadata: Equatable {
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

        fileprivate func matches(_ observed: ApplyRecoverySessionReader.DirectoryObservation) -> Bool {
            identity == observed.identity && owner == observed.owner && mode == observed.mode
                && birthSeconds == observed.birthSeconds && birthNanoseconds == observed.birthNanoseconds
        }
    }

    struct Candidate: Identifiable {
        let backupRoot: URL
        let sessionName: String
        let root: DirectoryMetadata
        let directory: DirectoryMetadata
        var id: String { sessionName }
        var birthSeconds: Int64 { directory.birthSeconds }
        var birthNanoseconds: Int64 { directory.birthNanoseconds }

        /// Metadaten sind keine Freigabe. Erst die bewusste Auswahl liest das
        /// Manifest und alle noch benötigten Sicherungen am selben Ordner.
        func open() throws -> ApplyRecoverySessionReader.Observation {
            try validateReference()
            let observed = try ApplyRecoverySessionReader.read(sessionNamed: sessionName, in: backupRoot)
            guard root.matches(observed.root), directory.matches(observed.directory) else {
                throw Failure.changed(backupRoot.appendingPathComponent(sessionName))
            }
            try validateReference()
            return observed
        }

        private func validateReference() throws {
            let descriptor = try openDirectory(backupRoot)
            defer { close(descriptor) }
            var rootInfo = stat(), sessionInfo = stat()
            guard fstat(descriptor, &rootInfo) == 0,
                  fstatat(descriptor, sessionName, &sessionInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw system(backupRoot.appendingPathComponent(sessionName))
            }
            guard DirectoryMetadata(rootInfo) == root, DirectoryMetadata(sessionInfo) == directory else {
                throw Failure.changed(backupRoot.appendingPathComponent(sessionName))
            }
        }
    }

    struct Listing {
        let candidates: [Candidate]
        /// Mehr historische Kandidaten als sichtbare Plätze.
        let reachedLimit: Bool
        /// Der begrenzte Scan sah nur einen Teil der Ablage. Die Kandidaten
        /// sind dann die neuesten beobachteten, nicht garantiert alle neuesten.
        let scanWasLimited: Bool
    }

    enum TargetState: Equatable {
        case restore
        case originalAlreadyPresent
        case previouslyRestored
    }

    struct Target: Identifiable, Equatable {
        let url: URL
        let journalState: UndoEntry.State
        let state: TargetState
        let current: FileSnapshot?
        let backup: FileSnapshot?
        var id: String { url.path }
    }

    struct Difference {
        let target: Target
        let document: FileDiffDocument
        let hasAnnotations: Bool
        let currentBOM: Data
        let originalBOM: Data
    }

    let observation: ApplyRecoverySessionReader.Observation
    let selectedRoots: [URL]
    let targets: [Target]
    /// Nur tatsächlich beobachtete Ressourcen, einschließlich eigener Claims.
    let remainingCleanupURLs: [URL]
    private let limits: Limits
    private let bindings: [URL: Binding]

    var session: ApplySession { observation.session }
    var hasFileWrites: Bool { targets.contains { $0.state == .restore } }

    /// Die Schranke kommt vom historischen Prozessabgleich. Das Manifestdatum
    /// ist dafür ungeeignet; ausschlaggebend ist die gebundene Verzeichnisgeburt.
    static func list(in backupRoot: URL, createdBefore: Date, limits: Limits = Limits(),
                     isCancelled: () -> Bool = { false }) throws -> Listing {
        try requireLimits(limits)
        let directory: Int32
        do { directory = try openDirectory(backupRoot) }
        catch Failure.system(_, let code) where code == ENOENT {
            return Listing(candidates: [], reachedLimit: false, scanWasLimited: false)
        }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0 else { throw system(backupRoot) }
        guard info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw Failure.invalidResource(backupRoot)
        }
        let root = DirectoryMetadata(info)
        let scan = try scanChildren(directory, at: backupRoot, limit: limits.directoryEntries,
                                    isCancelled: isCancelled)
        let sessionNames = scan.names.filter { $0.hasPrefix("session-") }
        var candidates: [Candidate] = []
        for name in sessionNames {
            if isCancelled() { throw CancellationError() }
            var child = stat()
            guard fstatat(directory, name, &child, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw Failure.changed(backupRoot.appendingPathComponent(name))
            }
            guard historical(seconds: child.st_birthtimespec.tv_sec,
                             nanoseconds: child.st_birthtimespec.tv_nsec, before: createdBefore) else { continue }
            candidates.append(Candidate(backupRoot: backupRoot, sessionName: name, root: root,
                                        directory: DirectoryMetadata(child)))
        }
        let named = try openDirectory(backupRoot)
        defer { close(named) }
        var after = stat()
        guard fstat(named, &after) == 0, DirectoryMetadata(after) == root else {
            throw Failure.changed(backupRoot)
        }
        candidates.sort {
            if $0.birthSeconds != $1.birthSeconds { return $0.birthSeconds > $1.birthSeconds }
            if $0.birthNanoseconds != $1.birthNanoseconds { return $0.birthNanoseconds > $1.birthNanoseconds }
            return $0.sessionName > $1.sessionName
        }
        return Listing(candidates: Array(candidates.prefix(limits.sessions)),
                       reachedLimit: candidates.count > limits.sessions, scanWasLimited: scan.limited)
    }

    static func build(observation: ApplyRecoverySessionReader.Observation, selectedRoots: [URL],
                      limits: Limits = Limits(), isCancelled: @escaping () -> Bool = { false }) throws -> Self {
        try requireLimits(limits)
        guard !selectedRoots.isEmpty, selectedRoots.count <= ApplyRecoverySessionReader.maximumEntries else {
            throw Failure.limit
        }
        _ = try ApplyRecoverySessionReader.read(sessionNamed: observation.sessionName,
            in: observation.backupRoot, matching: observation)
        let collector = Collector(maximumBytes: limits.totalTargetBytes, isCancelled: isCancelled)
        let backupRoot = try collector.observe(observation.backupRoot)
        guard backupRoot.object?.identity == observation.root.identity else {
            throw Failure.changed(observation.backupRoot)
        }
        var roots: [URL: Bool] = [:]
        for root in selectedRoots {
            let binding = try collector.observe(root, hashContents: false)
            guard let object = binding.object else { throw Failure.invalidResource(root) }
            roots[root] = object.isDirectory
        }
        func covered(_ url: URL) -> Bool {
            roots.contains { root, directory in
                directory ? descendant(url, of: root) : url == root
            }
        }
        var targets: [Target] = []
        var seenPaths = Set<URL>(), seenIdentities = Set<FileIdentity>()
        var targetBytes = 0, backupBytes = 0
        for entry in observation.session.entries {
            if isCancelled() { throw CancellationError() }
            let url = URL(fileURLWithPath: entry.originalPath)
            guard covered(url) else { throw Failure.outsideSelectedRoots(url) }
            guard seenPaths.insert(url).inserted else { throw Failure.duplicateTarget(url) }
            // Erledigte Einträge dürfen auch nach Umbenennen oder Entfernen des
            // Dokuments weiter erledigt bleiben. Sie begründen keinen Write.
            let binding = try collector.observe(url, allowMissing: entry.state == .restored,
                                                hashContents: entry.state != .restored,
                                                byteLimit: limits.totalTargetBytes - targetBytes)
            guard binding.object?.isDirectory != true else { throw Failure.targetConflict(url) }
            let current = binding.object?.snapshot
            if let identity = current?.identity, !seenIdentities.insert(identity).inserted {
                throw Failure.duplicateTarget(url)
            }
            targetBytes += current?.byteCount ?? 0
            if entry.state == .restored {
                targets.append(Target(url: url, journalState: entry.state, state: .previouslyRestored,
                                      current: current, backup: nil))
                continue
            }
            guard let current, let backup = observation.backups[entry.backupRelativePath]?.snapshot else {
                throw Failure.targetConflict(url)
            }
            guard backup.byteCount <= limits.totalBackupBytes - backupBytes else { throw Failure.limit }
            backupBytes += backup.byteCount
            let state: TargetState
            if current.hasSameContent(as: backup) {
                state = .originalAlreadyPresent
            } else {
                guard current == entry.appliedSnapshot,
                      entry.state != .pending || (current.identity != nil
                        && entry.pendingFile?.snapshot == current && entry.pendingFile?.isValid == true) else {
                    throw Failure.targetConflict(url)
                }
                guard access(url.path, W_OK) == 0,
                      access(url.deletingLastPathComponent().path, W_OK) == 0 else {
                    throw Failure.targetConflict(url)
                }
                state = .restore
            }
            targets.append(Target(url: url, journalState: entry.state, state: state,
                                  current: current, backup: backup))
        }
        var cleanup: [ApplyPendingFile] = []
        var singleFileWork: [URL: ApplyPendingFile.CleanupDirectory] = [:]
        for entry in observation.session.entries {
            guard let pending = entry.pendingFile else { continue }
            let target = URL(fileURLWithPath: entry.originalPath)
            let siblingAllowed = roots[target] == false
                && pending.cleanupDirectory?.url.deletingLastPathComponent() == target.deletingLastPathComponent()
            try authorize(pending, covered: covered, siblingAllowed: siblingAllowed)
            if siblingAllowed, let work = pending.cleanupDirectory {
                singleFileWork[work.url] = work
            }
            cleanup.append(pending)
        }
        for pending in observation.session.retainedPendingFiles {
            let siblingAllowed = pending.cleanupDirectory.map { singleFileWork[$0.url] == $0 } ?? false
            try authorize(pending, covered: covered, siblingAllowed: siblingAllowed)
            cleanup.append(pending)
        }
        var groupedCleanup: [URL: [ApplyPendingFile]] = [:]
        for pending in cleanup {
            guard let work = pending.cleanupDirectory else { throw Failure.cleanupConflict(pending.url) }
            groupedCleanup[work.url, default: []].append(pending)
        }
        var remaining = Set<URL>()
        var inspected = Set<URL>()
        for pending in cleanup {
            if isCancelled() { throw CancellationError() }
            guard let work = pending.cleanupDirectory else { throw Failure.cleanupConflict(pending.url) }
            guard inspected.insert(work.url).inserted else { continue }
            let related = groupedCleanup[work.url] ?? []
            guard related.allSatisfy({ $0.cleanupDirectory == work }) else {
                throw Failure.cleanupConflict(work.url)
            }
            let workBinding = try collector.observe(work.url, allowMissing: true)
            if let object = workBinding.object {
                guard object.isDirectory, object.identity == work.identity else {
                    throw Failure.cleanupConflict(work.url)
                }
                let descriptor = try work.openBound()
                defer { close(descriptor) }
                let names = try children(descriptor, at: work.url, limit: 3)
                guard names.allSatisfy({ ["anchor", "anchor.claim", "prepared.claim"].contains($0) }) else {
                    throw Failure.cleanupConflict(work.url)
                }
                remaining.insert(work.url)
                for name in ["anchor", "anchor.claim", "prepared.claim"] {
                    let url = work.url.appendingPathComponent(name)
                    let binding = try collector.observe(url, allowMissing: true)
                    if let object = binding.object {
                        guard let snapshot = object.snapshot else { throw Failure.cleanupConflict(url) }
                        guard related.contains(where: { $0.snapshot == snapshot }) else {
                            throw Failure.cleanupConflict(url)
                        }
                        remaining.insert(url)
                    }
                }
                guard try children(descriptor, at: work.url, limit: 3) == names else {
                    throw Failure.changed(work.url)
                }
            }
            // Der öffentliche Temp-Name darf fehlen, auch wenn sein eigener
            // Anker noch existiert. Ein später neu besetzter Name ist dagegen
            // eine Änderung der Vorschau und niemals neue Löschberechtigung.
            let prepared = try collector.observe(work.preparedURL, allowMissing: true)
            if let object = prepared.object {
                guard let snapshot = object.snapshot else { throw Failure.cleanupConflict(work.preparedURL) }
                guard workBinding.object != nil,
                      related.contains(where: { $0.snapshot == snapshot }) else {
                    throw Failure.cleanupConflict(work.preparedURL)
                }
                remaining.insert(work.preparedURL)
            }
        }
        try collector.revalidate()
        _ = try ApplyRecoverySessionReader.read(sessionNamed: observation.sessionName,
            in: observation.backupRoot, matching: observation)
        return Self(observation: observation, selectedRoots: selectedRoots, targets: targets,
                    remainingCleanupURLs: remaining.sorted { $0.path < $1.path },
                    limits: limits, bindings: collector.bindings)
    }

    /// Der Claim muss über diese Prüfung und den nachfolgenden Undo-Aufruf
    /// hinweg gehalten werden. Diese Methode verändert weder Claim noch Journal.
    func validate(holding claim: ApplyRecoveryDirectoryClaim,
                  isCancelled: @escaping () -> Bool = { false }) throws {
        guard claim.rootURL == observation.backupRoot, claim.sessionName == observation.sessionName,
              claim.rootIdentity == observation.root.identity,
              claim.sessionIdentity == observation.directory.identity else { throw Failure.wrongClaim }
        try claim.validateBinding()
        let current = try Self.build(observation: observation, selectedRoots: selectedRoots,
                                     limits: limits, isCancelled: isCancelled)
        guard current.targets == targets, current.bindings == bindings,
              current.remainingCleanupURLs == remainingCleanupURLs else {
            throw Failure.changed(session.sessionDirectory)
        }
        try claim.validateBinding()
    }

    /// Lazy pro Datei: Ein später berechneter Diff bleibt an die bei Auswahl
    /// beobachteten Bytes gebunden. Größen-/Diffgrenzen liefern keinen Teildiff.
    func diff(forTargetAt index: Int, isCancelled: @escaping () -> Bool = { false }) throws -> Difference {
        guard targets.indices.contains(index) else { throw Failure.noDifference }
        let target = targets[index]
        guard target.state != .previouslyRestored, let expected = target.current,
              let backup = target.backup else { throw Failure.noDifference }
        guard expected.byteCount <= limits.diffBytes, backup.byteCount <= limits.diffBytes else {
            throw Failure.limit
        }
        let entry = session.entries[index]
        try validateDifferenceBindings(at: index, isCancelled: isCancelled)
        let current = try readBytes(target.url, expected: expected, isCancelled: isCancelled)
        let backupURL = session.sessionDirectory.appendingPathComponent(entry.backupRelativePath)
        let original = try readBytes(backupURL, expected: backup, isCancelled: isCancelled)
        let (currentBOM, currentEncoding) = ApplyEngine.detectBOM(in: current)
        let (originalBOM, originalEncoding) = ApplyEngine.detectBOM(in: original)
        let storedEncoding = entry.encodingRawValue.map { String.Encoding(rawValue: $0) }
        func decode(_ bytes: Data, bom: Data, encoding: String.Encoding?, at url: URL) throws -> String {
            let payload = Data(bytes.dropFirst(bom.count))
            if let encoding = encoding ?? storedEncoding {
                guard let text = ApplyEngine.decode(payload: payload, encoding: encoding) else {
                    throw Failure.undecodable(url)
                }
                return text
            }
            guard let (text, _) = ApplyEngine.decode(payload: payload, bomEncoding: nil) else {
                throw Failure.undecodable(url)
            }
            return text
        }
        let before = try decode(current, bom: currentBOM, encoding: currentEncoding, at: target.url)
        let after = try decode(original, bom: originalBOM, encoding: originalEncoding, at: backupURL)
        let result: TextWorkflowDiff.Result
        do {
            result = try TextWorkflowDiff.build(before: before, after: after,
                maximumDisplayBytes: limits.diffDisplayBytes,
                maximumTotalDisplayBytes: limits.diffDisplayBytes, isCancelled: isCancelled)
        } catch TextWorkflowError.sizeLimit { throw Failure.limit }
        guard result.document.result != nil else { throw Failure.incompleteDiff }
        try validateDifferenceBindings(at: index, isCancelled: isCancelled)
        return Difference(target: target, document: result.document, hasAnnotations: result.hasAnnotations,
                          currentBOM: currentBOM, originalBOM: originalBOM)
    }

    private func validateDifferenceBindings(at index: Int, isCancelled: @escaping () -> Bool) throws {
        let target = targets[index]
        let entry = session.entries[index]
        let maximumBytes = (target.current?.byteCount ?? 0) + (target.backup?.byteCount ?? 0)
            + observation.manifest.snapshot.byteCount
        let collector = Collector(maximumBytes: maximumBytes, isCancelled: isCancelled)
        for url in [observation.backupRoot, target.url] {
            guard let expected = bindings[url] else { throw Failure.changed(url) }
            guard try collector.observe(url) == expected else { throw Failure.changed(url) }
        }
        func directory(_ url: URL, _ expected: ApplyRecoverySessionReader.DirectoryObservation) throws {
            guard let object = try collector.observe(url).object,
                  object.isDirectory, object.identity == expected.identity,
                  object.owner == expected.owner, object.mode == expected.mode,
                  object.version == [expected.birthSeconds, expected.birthNanoseconds] else {
                throw Failure.changed(url)
            }
        }
        func file(_ url: URL, _ expected: ApplyRecoverySessionReader.FileObservation) throws {
            guard let object = try collector.observe(url, byteLimit: expected.snapshot.byteCount).object,
                  object.snapshot == expected.snapshot, object.owner == expected.owner, object.mode == expected.mode,
                  object.version == [Int64(expected.snapshot.byteCount), expected.modificationSeconds,
                    expected.modificationNanoseconds, expected.changeSeconds, expected.changeNanoseconds,
                    expected.birthSeconds, expected.birthNanoseconds] else { throw Failure.changed(url) }
        }
        try directory(session.sessionDirectory, observation.directory)
        if let files = observation.files {
            try directory(session.sessionDirectory.appendingPathComponent("files"), files)
        }
        try file(session.sessionDirectory.appendingPathComponent("manifest.json"), observation.manifest)
        guard let expected = observation.backups[entry.backupRelativePath] else { throw Failure.incompleteDiff }
        try file(session.sessionDirectory.appendingPathComponent(entry.backupRelativePath), expected)
        try collector.revalidate()
    }

    private static func authorize(_ pending: ApplyPendingFile, covered: (URL) -> Bool,
                                  siblingAllowed: Bool) throws {
        guard let work = pending.cleanupDirectory else { throw Failure.cleanupConflict(pending.url) }
        for url in [work.url, work.preparedURL, pending.url] {
            guard covered(url) || siblingAllowed else { throw Failure.outsideSelectedRoots(url) }
        }
    }

    private static func historical<T: BinaryInteger, U: BinaryInteger>(seconds: T, nanoseconds: U,
                                                                      before: Date) -> Bool {
        Double(seconds) + Double(nanoseconds) / 1_000_000_000 < before.timeIntervalSince1970
    }

    private static func requireLimits(_ limits: Limits) throws {
        guard limits.sessions > 0, limits.directoryEntries > 0, limits.totalBackupBytes > 0,
              limits.totalTargetBytes > 0, limits.diffBytes > 0, limits.diffDisplayBytes > 0 else {
            throw Failure.limit
        }
    }

    private static func descendant(_ url: URL, of root: URL) -> Bool {
        let path = url.pathComponents, base = root.pathComponents
        return path.count > base.count && path.starts(with: base)
    }

    private struct Object: Equatable {
        let identity: FileIdentity
        let isDirectory: Bool
        let owner: uid_t
        let mode: mode_t
        let snapshot: FileSnapshot?
        // Verzeichnisse dürfen durch andere eigene Dateien normale mtime-
        // Änderungen erhalten. Datei-Versionen bleiben vollständig gebunden.
        let version: [Int64]

        var metadataOnly: Self {
            Self(identity: identity, isDirectory: isDirectory, owner: owner,
                 mode: mode, snapshot: nil, version: version)
        }
    }

    private struct Binding: Equatable {
        let ancestors: [FileIdentity]
        let object: Object?
        var metadataOnly: Self { Self(ancestors: ancestors, object: object?.metadataOnly) }
    }

    private final class Collector {
        var bindings: [URL: Binding] = [:]
        let isCancelled: () -> Bool
        private var remainingBytes: Int
        init(maximumBytes: Int, isCancelled: @escaping () -> Bool) {
            remainingBytes = maximumBytes
            self.isCancelled = isCancelled
        }

        func observe(_ url: URL, allowMissing: Bool = false, hashContents: Bool = true,
                     byteLimit: Int = Int(FileSnapshot.maximumReadBytes)) throws -> Binding {
            if isCancelled() { throw CancellationError() }
            let expected = bindings[url]
            let alreadyHashed = expected?.object?.snapshot != nil
            let available = alreadyHashed ? byteLimit : min(byteLimit, remainingBytes)
            let result = try Self.inspect(url, allowMissing: allowMissing, byteLimit: available,
                                          hashContents: hashContents || alreadyHashed, isCancelled: isCancelled)
            if let expected, result != expected,
               alreadyHashed || result.metadataOnly != expected.metadataOnly { throw Failure.changed(url) }
            if !alreadyHashed { remainingBytes -= result.object?.snapshot?.byteCount ?? 0 }
            bindings[url] = result
            return result
        }

        func revalidate() throws {
            for (url, expected) in bindings {
                let result = try Self.inspect(url, allowMissing: expected.object == nil,
                    byteLimit: expected.object?.snapshot?.byteCount ?? 0,
                    hashContents: expected.object?.snapshot != nil, isCancelled: isCancelled)
                guard result == expected else { throw Failure.changed(url) }
            }
        }

        private static func inspect(_ url: URL, allowMissing: Bool, byteLimit: Int, hashContents: Bool,
                                    isCancelled: () -> Bool) throws -> Binding {
            try requirePath(url)
            let components = url.pathComponents.dropFirst()
            var descriptors: [Int32] = []
            defer { for descriptor in descriptors.reversed() { close(descriptor) } }
            let rootFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard rootFD >= 0 else { throw system(url) }
            descriptors.append(rootFD)
            var ancestors: [FileIdentity] = []
            for name in components.dropLast() {
                let descriptor = openat(descriptors[descriptors.count - 1], name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else {
                    if allowMissing && errno == ENOENT {
                        try validateAncestors(url, expected: ancestors)
                        return Binding(ancestors: ancestors, object: nil)
                    }
                    throw system(url)
                }
                descriptors.append(descriptor)
                var info = stat()
                guard fstat(descriptor, &info) == 0 else { throw system(url) }
                ancestors.append(FileIdentity(stat: info))
            }
            let parent = descriptors[descriptors.count - 1]
            let name = url.lastPathComponent
            var info = stat()
            if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if allowMissing && errno == ENOENT {
                    try validateAncestors(url, expected: ancestors)
                    return Binding(ancestors: ancestors, object: nil)
                }
                throw system(url)
            }
            let directory = info.st_mode & S_IFMT == S_IFDIR
            guard directory || info.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidResource(url) }
            let descriptor = openat(parent, name,
                ApplyFileSystem.childFileReadFlags | (directory ? O_DIRECTORY : 0))
            guard descriptor >= 0 else { throw system(url) }
            descriptors.append(descriptor)
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  FileSnapshot.describesSameOpenedVersion(info, opened), info.st_mode == opened.st_mode else {
                throw Failure.changed(url)
            }
            let snapshot: FileSnapshot?
            if directory || !hashContents { snapshot = nil }
            else {
                guard byteLimit >= 0, opened.st_size <= byteLimit else { throw Failure.limit }
                do {
                    snapshot = try FileSnapshot.readSnapshotOnly(descriptor: descriptor, fileStat: opened,
                        byteLimit: UInt64(min(byteLimit, Int(FileSnapshot.maximumReadBytes))), isCancelled: isCancelled)
                } catch FileSnapshotReadError.tooLarge {
                    throw Failure.limit
                } catch FileSnapshotReadError.changedDuringRead {
                    throw Failure.changed(url)
                }
            }
            var named = stat()
            guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  FileSnapshot.describesSameOpenedVersion(opened, named), opened.st_mode == named.st_mode else {
                throw Failure.changed(url)
            }
            try validateAncestors(url, expected: ancestors)
            let birth = [Int64(opened.st_birthtimespec.tv_sec), Int64(opened.st_birthtimespec.tv_nsec)]
            let version = directory ? birth : [Int64(opened.st_size),
                Int64(opened.st_mtimespec.tv_sec), Int64(opened.st_mtimespec.tv_nsec),
                Int64(opened.st_ctimespec.tv_sec), Int64(opened.st_ctimespec.tv_nsec),
                Int64(opened.st_birthtimespec.tv_sec), Int64(opened.st_birthtimespec.tv_nsec)]
            return Binding(ancestors: ancestors, object: Object(identity: FileIdentity(stat: opened),
                isDirectory: directory, owner: opened.st_uid, mode: opened.st_mode,
                snapshot: snapshot, version: version))
        }

        private static func validateAncestors(_ url: URL, expected: [FileIdentity]) throws {
            var path = URL(fileURLWithPath: "/", isDirectory: true)
            for (name, identity) in zip(url.pathComponents.dropFirst().dropLast(), expected) {
                path.appendPathComponent(name, isDirectory: true)
                let descriptor = try openDirectory(path)
                defer { close(descriptor) }
                var info = stat()
                guard fstat(descriptor, &info) == 0, FileIdentity(stat: info) == identity else {
                    throw Failure.changed(path)
                }
            }
        }
    }

    private static func requirePath(_ url: URL) throws {
        guard url.isFileURL, url.host == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/"), url.path != "/", url.path.utf8.count < Int(PATH_MAX),
              !url.path.utf8.contains(0),
              url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else { throw Failure.invalidPath(url) }
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        try requirePath(url)
        let descriptor = open(url.path, ApplyFileSystem.rootDirectoryReadFlags)
        guard descriptor >= 0 else { throw system(url) }
        return descriptor
    }

    private static func children(_ descriptor: Int32, at url: URL, limit: Int) throws -> [String] {
        let result = try scanChildren(descriptor, at: url, limit: limit)
        guard !result.limited else { throw Failure.limit }
        return result.names
    }

    private static func scanChildren(_ descriptor: Int32, at url: URL, limit: Int,
                                     isCancelled: () -> Bool = { false }) throws -> (names: [String], limited: Bool) {
        do {
            let result = try ApplyFileSystem.scanChildren(descriptor, limit: limit, isCancelled: isCancelled)
            return (result.names.sorted(), result.limited)
        } catch let error as POSIXError {
            throw Failure.system(url, error.code.rawValue)
        }
    }

    private func readBytes(_ url: URL, expected: FileSnapshot,
                           isCancelled: () -> Bool) throws -> Data {
        if isCancelled() { throw CancellationError() }
        let descriptor = open(url.path, ApplyFileSystem.fileReadFlags | O_NOFOLLOW_ANY)
        guard descriptor >= 0 else { throw Self.system(url) }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size == expected.byteCount, FileIdentity(stat: before) == expected.identity else {
            throw Failure.changed(url)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var bytes = Data()
        while true {
            if isCancelled() { throw CancellationError() }
            let chunk = try handle.read(upToCount: min(64 * 1024, expected.byteCount - bytes.count + 1)) ?? Data()
            if chunk.isEmpty { break }
            bytes.append(chunk)
            guard bytes.count <= expected.byteCount else { throw Failure.changed(url) }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, FileSnapshot.describesSameOpenedVersion(before, after),
              expected == FileSnapshot(data: bytes, identity: FileIdentity(stat: after)) else {
            throw Failure.changed(url)
        }
        return bytes
    }

    private static func system(_ url: URL) -> Failure { .system(url, errno) }
}
