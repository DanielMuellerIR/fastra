import Darwin
import Foundation

/// Nur die kurzlebige Entnahme von Markdown-Bildern. Kein Journal: Nach einem
/// Prozessabbruch bleiben private Reste erhalten, ohne automatische Wiederaufnahme.
final class MarkdownImageRemoval {
    struct Hooks {
        var afterPreparingDirectory: ((URL) throws -> Void)?
        var beforeClaim: ((URL) throws -> Void)?
        var afterClaim: ((URL, URL) throws -> Void)?
        // Der bisher öffentliche Claim war genau hier austauschbar. Die Naht
        // prüft öffentliche Namenswechsel; sie verspricht keine Isolation vor
        // einem gezielt eingreifenden Prozess mit denselben Benutzerrechten.
        var afterInspection: ((URL, URL) throws -> Void)?
        var beforeUnlink: ((Int) throws -> Void)?
    }

    enum GateDecision {
        case committed(Bool)
        case referencesChanged
        case disallowed
        case legacy(Bool)

        var allowed: Bool {
            switch self {
            case .committed(let value), .legacy(let value): return value
            case .referencesChanged, .disallowed: return false
            }
        }
    }

    typealias DetailedGate = (() -> Bool) -> GateDecision

    static func legacyGate(_ gate: @escaping (() -> Bool) -> Bool) -> DetailedGate {
        { .legacy(gate($0)) }
    }

    struct RemainingEntry {
        let url: URL
        let identity: MarkdownImageStore.StoredFileIdentity?
        let owned: Bool
        var operationID: String? = nil
    }

    struct Result: LocalizedError {
        var removed: [URL] = []
        var restored: [URL] = []
        var remainingEntries: [RemainingEntry] = []
        var causes: [Error] = []
        var complete = false
        private(set) var referenceRejectionID: UUID?
        var isPureReferenceRejection: Bool { referenceRejectionID != nil }
        var resolvedOperations: Set<String> = []
        var resolvedDirectoryCauseIndices: Set<Int> = []

        fileprivate mutating func markPureReferenceRejection() {
            referenceRejectionID = UUID()
        }

        /// Das Rohresultat bleibt für Bool, RAM und direkte Caller unverändert.
        /// Nur bereits belegte eigene Auflösungsschritte verändern den Bericht.
        var unresolvedForReporting: Self {
            var result = self
            result.causes = causes.enumerated().filter { !resolvedDirectoryCauseIndices.contains($0.offset) }.map(\.element)
            result.remainingEntries.removeAll { entry in
                entry.operationID.map { resolvedOperations.contains($0) } ?? false
            }
            return result
        }

        var isReportableFailure: Bool { !complete || !causes.isEmpty || !remainingEntries.isEmpty }

        var errorDescription: String? { reportLines().joined(separator: "\n") }

        func reportLines(previous: Bool = false) -> [String] {
            var lines = causes.map(\.localizedDescription)
            for path in removed {
                lines.append(L10n.format("Die Bilddatei „%@“ wurde entfernt.", path.path))
            }
            for path in restored {
                lines.append(L10n.format("Die Bilddatei „%@“ wurde zurückgestellt.", path.path))
            }
            for entry in remainingEntries {
                lines.append(previous
                    ? L10n.format("Bei einer früheren Bildbereinigung blieb „%@“ erhalten.", entry.url.path)
                    : L10n.format("Bei der Bildbereinigung blieb „%@“ erhalten.", entry.url.path))
            }
            return lines
        }
    }

    private final class Claim {
        let original: String
        let temporary = UUID().uuidString
        let image: MarkdownImageStore.StoredImage
        let expected: MarkdownImageStore.StoredFileIdentity
        let file: Int32

        init(image: MarkdownImageStore.StoredImage, expected: MarkdownImageStore.StoredFileIdentity, directory: Int32) throws {
            original = image.fileURL.lastPathComponent
            self.image = image
            self.expected = expected
            file = openat(directory, original, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            guard file >= 0 else { throw MarkdownImageRemoval.posixError() }
        }

        deinit { if file >= 0 { Darwin.close(file) } }
    }

    private let images: Int32
    private let directory: Int32
    private let directoryName: String
    private let directoryIdentity: stat
    private var claims: [Claim] = []

    init(images: Int32) throws {
        let parent = fcntl(images, F_DUPFD_CLOEXEC, 0)
        guard parent >= 0 else { throw Self.posixError() }
        let name = ".fastra-image-delete-\(UUID().uuidString)"
        guard mkdirat(parent, name, mode_t(0o700)) == 0 else {
            let error = Self.posixError(); Darwin.close(parent); throw error
        }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            let error = Self.posixError()
            let retained = Self.url(of: parent, fallback: "images").appendingPathComponent(name)
            Darwin.close(parent)
            throw Result(remainingEntries: [.init(url: retained, identity: nil, owned: false)], causes: [error])
        }
        self.images = parent
        directory = fd
        directoryName = name
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = Self.posixError()
            let retained = Self.url(of: fd, fallback: name)
            Darwin.close(fd); Darwin.close(parent)
            throw Result(remainingEntries: [.init(url: retained, identity: nil, owned: false)], causes: [error])
        }
        directoryIdentity = info
        do {
            // Geerbte ACLs können trotz 0700 fremden Zugriff gewähren. Vor dem
            // ersten Claim entfernen und am offenen Ordner erneut prüfen.
            guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR,
                  let acl = acl_init(0) else { throw POSIXError(.EACCES) }
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0, fchmod(fd, mode_t(0o700)) == 0 else {
                throw Self.posixError()
            }
            try checkDirectory()
        } catch {
            // Nur den gebundenen eigenen Namen entfernen; niemals einen Ersatz.
            var result = Result(causes: [error])
            finishDirectory(in: &result)
            // Alle Eigenschaften sind initialisiert; der fehlschlagende
            // Initializer ruft deinit auf und schließt die FDs genau einmal.
            throw result
        }
    }

    deinit {
        if claims.isEmpty { removeEmptyDirectory() }
        Darwin.close(directory)
        Darwin.close(images)
    }

    var hasClaims: Bool { !claims.isEmpty }
    var url: URL { Self.url(of: directory, fallback: directoryName) }

    func remove(_ candidates: [(MarkdownImageStore.StoredImage, MarkdownImageStore.StoredFileIdentity)],
                hooks: Hooks, gate: DetailedGate) -> Result {
        var result = Result()
        var enteredCommit = false
        var referenceRejection = false
        guard claims.isEmpty else { return restoreClaims() }
        do {
            try hooks.afterPreparingDirectory?(url)
            try checkDirectory()
            let decision = gate {
                enteredCommit = true
                do {
                    for (image, expected) in candidates {
                        let original = image.fileURL.lastPathComponent
                        let originalURL = Self.url(of: images, fallback: "images").appendingPathComponent(original)
                        try hooks.beforeClaim?(originalURL)
                        try checkDirectory()
                        // Vor Entnahme müssen auch die exakten Metadaten passen.
                        guard Self.identity(named: original, in: images) == expected else { throw POSIXError(.ESTALE) }
                        let claim = try Claim(image: image, expected: expected, directory: images)
                        guard renameatx_np(images, original, directory, claim.temporary, UInt32(RENAME_EXCL)) == 0 else {
                            throw Self.posixError()
                        }
                        claims.append(claim)
                        let claimedURL = url.appendingPathComponent(claim.temporary)
                        try hooks.afterClaim?(originalURL, claimedURL)
                    }
                    return true
                } catch {
                    result.causes.append(error)
                    return false
                }
            }
            let allowed = decision.allowed
            if allowed {
                // Die Dokumentbarriere beansprucht nur Namen. Hashen bleibt auf
                // der I/O-Queue, nachdem die Entnahme atomar abgeschlossen ist.
                for (index, claim) in claims.enumerated() {
                    try checkDirectory()
                    try verify(claim)
                    try hooks.afterInspection?(Self.url(of: images, fallback: "images").appendingPathComponent(claim.original),
                                           url.appendingPathComponent(claim.temporary))
                    try hooks.beforeUnlink?(index)
                    try checkDirectory()
                    try verify(claim)
                    // Der Claim liegt seit der Prüfung im privaten Namespace.
                    // Gleichberechtigte gezielte Prozesse sind keine Sperrgrenze.
                    guard unlinkat(directory, claim.temporary, 0) == 0 else { throw Self.posixError() }
                    result.removed.append(Self.url(of: images, fallback: "images").appendingPathComponent(claim.original))
                }
                claims.removeAll()
                result.complete = true
            }
            if !allowed && result.causes.isEmpty {
                result.causes.append(POSIXError(.ECANCELED))
                if case .referencesChanged = decision { referenceRejection = true }
            }
        } catch { result.causes.append(error) }
        // Bereits entfernte Claims nicht zurückstellen. Die übrigen Namen werden
        // ausschließlich exklusiv zurückgestellt, auch wenn sie inzwischen fremd sind.
        let removedNames = Set(result.removed.map(\.lastPathComponent))
        claims.removeAll { removedNames.contains($0.original) }
        if !claims.isEmpty {
            let rollback = restoreClaims()
            result.restored = rollback.restored
            result.remainingEntries = rollback.remainingEntries
            let causeOffset = result.causes.count
            result.causes.append(contentsOf: rollback.causes)
            result.resolvedDirectoryCauseIndices.formUnion(rollback.resolvedDirectoryCauseIndices.map { $0 + causeOffset })
            result.resolvedOperations.formUnion(rollback.resolvedOperations)
        }
        if claims.isEmpty { finishDirectory(in: &result) }
        // Erst der erfolgreiche Ordnerabschluss belegt eine reine Ablehnung:
        // Hookfehler, betretene Bodies und zurückgebliebene Reste zählen nie dazu.
        if referenceRejection && !enteredCommit
            && result.causes.count == 1 && result.removed.isEmpty && result.restored.isEmpty
            && result.remainingEntries.isEmpty && claims.isEmpty
            && result.resolvedOperations.contains(directoryName) {
            result.markPureReferenceRejection()
        }
        return result
    }

    func restoreClaims() -> Result {
        var result = Result()
        var pending: [Claim] = []
        for claim in claims.reversed() {
            // Selbst wenn der öffentliche Arbeitsordnername ausgetauscht wurde,
            // bleibt die Quelle am ursprünglichen FD gebunden.
            if renameatx_np(directory, claim.temporary, images, claim.original, UInt32(RENAME_EXCL)) == 0 {
                result.restored.append(Self.url(of: images, fallback: "images").appendingPathComponent(claim.original))
            } else {
                result.causes.append(Self.posixError())
                pending.append(claim)
                let actual = Self.identity(named: claim.temporary, in: directory)
                result.remainingEntries.append(RemainingEntry(url: url.appendingPathComponent(claim.temporary),
                    identity: actual, owned: actual.map { Self.sameFile($0, claim.expected) && (try? verify(claim)) != nil } ?? false,
                    operationID: directoryName))
            }
            // Ein nach Claim verschobenes eigenes Bild bleibt über seinen FD
            // auffindbar, auch wenn am Claim inzwischen fremde Bytes liegen.
            var opened = stat()
            if fstat(claim.file, &opened) == 0, opened.st_nlink > 0 {
                let retained = Self.url(of: claim.file, fallback: claim.original)
                let original = Self.url(of: images, fallback: "images").appendingPathComponent(claim.original)
                if retained != original && !result.remainingEntries.contains(where: { $0.url == retained }) {
                    result.remainingEntries.append(.init(url: retained, identity: Self.identity(opened), owned: true))
                }
            }
        }
        claims = pending.reversed()
        result.complete = claims.isEmpty
        if claims.isEmpty { finishDirectory(in: &result) }
        return result
    }

    private func verify(_ claim: Claim) throws {
        let fd = claim.file
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let actual = Self.identity(named: claim.temporary, in: directory), Self.sameFile(actual, claim.expected),
              UInt64(info.st_dev) == actual.device, UInt64(info.st_ino) == actual.inode,
              info.st_size >= 0 else { throw POSIXError(.ESTALE) }
        let snapshot = try FileSnapshot.readSnapshotOnly(descriptor: fd, fileStat: info,
                                                         byteLimit: UInt64(claim.expected.size))
        guard snapshot.sha256 == claim.image.contentSHA256,
              Self.identity(named: claim.temporary, in: directory) == actual else { throw POSIXError(.ESTALE) }
    }

    private func checkDirectory() throws {
        var info = stat()
        var named = stat()
        guard fstat(directory, &info) == 0,
              fstatat(images, directoryName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_dev == directoryIdentity.st_dev, info.st_ino == directoryIdentity.st_ino,
              info.st_dev == named.st_dev, info.st_ino == named.st_ino,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else {
            throw POSIXError(.EACCES)
        }
        var acl = acl_get_fd_np(directory, ACL_TYPE_EXTENDED)
        if acl == nil && errno == ENOENT { acl = acl_init(0) }
        guard let acl else { throw Self.posixError() }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == -1, errno == EINVAL else { throw POSIXError(.EACCES) }
    }

    private func finishDirectory(in result: inout Result) {
        if removeEmptyDirectory() {
            result.resolvedOperations.insert(directoryName)
            return
        }
        // Der zweite Abschluss kann einen schon entfernten offenen Ordner nicht
        // erneut erkennen. Herkunft merken, ohne Rohresultat oder RAM zu ändern.
        if result.resolvedOperations.contains(directoryName) {
            result.resolvedDirectoryCauseIndices.insert(result.causes.count)
        }
        result.remainingEntries.append(.init(url: url, identity: nil, owned: true, operationID: directoryName))
        result.causes.append(POSIXError(.ESTALE))
        result.complete = false
    }

    @discardableResult
    private func removeEmptyDirectory() -> Bool {
        var named = stat()
        if fstatat(images, directoryName, &named, AT_SYMLINK_NOFOLLOW) == 0,
           named.st_dev == directoryIdentity.st_dev, named.st_ino == directoryIdentity.st_ino {
            if unlinkat(images, directoryName, AT_REMOVEDIR) == 0 { return true }
        }
        var info = stat()
        return fstat(directory, &info) == 0 && info.st_nlink == 0
    }

    private static func identity(named name: String, in directory: Int32) -> MarkdownImageStore.StoredFileIdentity? {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return identity(info)
    }

    private static func identity(_ info: stat) -> MarkdownImageStore.StoredFileIdentity {
        .init(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec), modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(info.st_ctimespec.tv_sec), statusChangeNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }

    private static func sameFile(_ a: MarkdownImageStore.StoredFileIdentity, _ b: MarkdownImageStore.StoredFileIdentity) -> Bool {
        a.device == b.device && a.inode == b.inode && a.size == b.size
            && a.modificationSeconds == b.modificationSeconds && a.modificationNanoseconds == b.modificationNanoseconds
    }

    private static func url(of fd: Int32, fallback: String) -> URL {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &path) == 0 else { return URL(fileURLWithPath: "/").appendingPathComponent(fallback) }
        return URL(fileURLWithPath: String(cString: path))
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
