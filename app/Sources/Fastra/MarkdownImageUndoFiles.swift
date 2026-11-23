import Darwin
import Foundation

/// Der gebundene Dokumentordner überlebt Finder-Umbenennungen. Die Entnahme
/// verwendet private Arbeitsordner; Bildbytes für Undo liegen ausschließlich
/// im begrenzten Speicherpuffer.
final class MarkdownImageUndoFiles: @unchecked Sendable {
    private let images: [MarkdownImageStore.StoredImage]
    private let documentFD: Int32
    private let buffer: MarkdownImageUndoBuffer
    private let invalidated: () -> Void
    private var identities: [MarkdownImageStore.StoredFileIdentity]
    private var ticket: UUID?
    private var pendingPublications: [MarkdownImagePublication] = []
    private var removal: MarkdownImageRemoval?
    private var permanentlyRemoved: Set<String> = []
    private(set) var lastRemovalResult: MarkdownImageRemoval.Result?
    private var retainedRemovalFailure: MarkdownImageRemoval.Result?
    private var metadataProbeCreationError: Error?
    private(set) var lastRestoreFailure: MarkdownImagePublication.Failure?
    private(set) var lastPresenceFailure: Error?

    private struct ImagePresenceFailure: LocalizedError {
        let url: URL
        let cause: POSIXError?

        var errorDescription: String? {
            guard let cause else {
                return L10n.format("Der benötigte Bildpfad „%@“ ist keine reguläre Datei.", url.path)
            }
            if cause.code == .ENOENT {
                return L10n.format("Die benötigte Bilddatei „%@“ fehlt. Stelle sie am ursprünglichen Pfad wieder bereit und versuche Wiederholen erneut.", url.path)
            }
            return L10n.format("Die benötigte Bilddatei „%@“ konnte nicht geprüft werden: %@", url.path, cause.localizedDescription)
        }
    }

    var removalFailureDescription: String? {
        var previous = retainedRemovalFailure
        let latest = lastRemovalResult?.unresolvedForReporting
        if let latest, latest.isReportableFailure {
            previous?.remainingEntries.removeAll { entry in latest.remainingEntries.contains { $0.url == entry.url } }
        }
        var lines = previous?.reportLines(previous: true) ?? []
        if let latest, latest.isReportableFailure { lines += latest.reportLines() }
        if let metadataProbeCreationError { lines.append(metadataProbeCreationError.localizedDescription) }
        var seen: Set<String> = []
        lines = lines.flatMap { $0.split(separator: "\n").map(String.init) }
            .filter { seen.insert($0).inserted }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    func captureRemovalFailureDescription() -> String? {
        // Die fehlgeschlagene Anlage betrifft nur das Ergebnis dieses Versuchs.
        defer { metadataProbeCreationError = nil }
        return removalFailureDescription
    }

    /// Nur ein später belegter Referenzschutz erledigt die jüngste reine
    /// Gateablehnung. Echte Befunde und sämtliche Dateizustände bleiben erhalten.
    func forgetProtectedReferenceRejection() {
        if lastRemovalResult?.isPureReferenceRejection == true { lastRemovalResult = nil }
    }

    private func replaceRemovalResult(_ result: MarkdownImageRemoval.Result?) {
        if let previous = lastRemovalResult, previous.isReportableFailure, !previous.isPureReferenceRejection {
            let previous = previous.unresolvedForReporting
            var retained = retainedRemovalFailure ?? .init()
            var causes = Set(retained.causes.map(\.localizedDescription))
            retained.causes += previous.causes.filter { causes.insert($0.localizedDescription).inserted }
            var removed = Set(retained.removed)
            retained.removed += previous.removed.filter { removed.insert($0).inserted }
            var restored = Set(retained.restored)
            retained.restored += previous.restored.filter { restored.insert($0).inserted }
            for entry in previous.remainingEntries where !retained.remainingEntries.contains(where: {
                $0.url == entry.url && $0.operationID == entry.operationID
            }) { retained.remainingEntries.append(entry) }
            retainedRemovalFailure = retained
        }
        lastRemovalResult = result
        if let result, !result.resolvedOperations.isEmpty {
            retainedRemovalFailure?.remainingEntries.removeAll { entry in
                entry.operationID.map { result.resolvedOperations.contains($0) } ?? false
            }
        }
    }

    private func beginRemovalAttempt() {
        // Eine fehlgeschlagene Anlage der Metadatenprobe hinterlässt keine Datei.
        metadataProbeCreationError = nil
        // Ohne neues Dateiergebnis ist der Versuchsbeginn kein positiver Schutz.
        if lastRemovalResult?.isPureReferenceRejection != true { replaceRemovalResult(nil) }
    }

    private func acknowledgeResolvedRemovalFailure() {
        // Erfolg an den aktuellen Bildern belegt keinen alten abgetrennten Pfad.
        if retainedRemovalFailure?.remainingEntries.isEmpty == true { retainedRemovalFailure = nil }
    }

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

    func checkOnDiskImages() -> Bool {
        lastPresenceFailure = nil
        let directory = documentDirectoryURL?.appendingPathComponent("images")
        let fd = openat(documentFD, "images", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            let cause = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            if let image = images.first {
                let url = directory?.appendingPathComponent(image.fileURL.lastPathComponent) ?? image.fileURL
                lastPresenceFailure = ImagePresenceFailure(url: url, cause: cause)
            }
            return false
        }
        defer { Darwin.close(fd) }
        for image in images {
            let name = image.fileURL.lastPathComponent
            let url = directory?.appendingPathComponent(name) ?? image.fileURL
            var info = stat()
            guard fstatat(fd, name, &info, 0) == 0 else {
                lastPresenceFailure = ImagePresenceFailure(url: url,
                    cause: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                return false
            }
            guard info.st_mode & S_IFMT == S_IFREG else {
                lastPresenceFailure = ImagePresenceFailure(url: url, cause: nil)
                return false
            }
            guard imagesStillMatches(fd) else {
                lastPresenceFailure = ImagePresenceFailure(url: url, cause: POSIXError(.ESTALE))
                return false
            }
        }
        // Externe Bildaktualisierungen am selben Pfad bleiben zulässig.
        // Die früher gespeicherte Identität und der Inhalt sind hier kein Veto.
        return true
    }

    func removeForUndo(gate: (() -> Bool) -> Bool = { $0() },
                       hooks: MarkdownImageRemoval.Hooks = .init()) -> Bool {
        withoutActuallyEscaping(gate) { gate in
            removeForUndo(gate: MarkdownImageRemoval.legacyGate(gate), hooks: hooks)
        }
    }

    func removeForUndo(gate: MarkdownImageRemoval.DetailedGate,
                       hooks: MarkdownImageRemoval.Hooks = .init()) -> Bool {
        guard ticket == nil else { return false }
        beginRemovalAttempt()
        guard let fd = openImages() else {
            replaceRemovalResult(.init(causes: [POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)]))
            return false
        }
        defer { Darwin.close(fd) }
        var total = 0
        for image in images {
            guard image.identity.size >= 0, image.identity.size <= Int64(Int.max - total) else { return false }
            total += Int(image.identity.size)
        }
        var metadataBudget = 1024 * 1024
        var metadata: [Data] = []
        var snapshots: [MarkdownImageStore.StoredFileIdentity] = []
        do {
            for (index, image) in images.enumerated() {
                guard let captured = try captureMetadata(image, expected: identities[index], in: fd, byteLimit: metadataBudget),
                      captured.data.count <= metadataBudget, captured.data.count <= Int.max - total else { return false }
                metadataBudget -= captured.data.count
                metadata.append(captured.data)
                snapshots.append(captured.identity)
                total += captured.data.count
            }
        } catch {
            metadataProbeCreationError = error
            return false
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
        let result = removeVerifiedFiles(in: fd, metadataSnapshots: snapshots, hooks: hooks, gate: gate)
        replaceRemovalResult(result)
        // Auch bei Teilfortschritt müssen entfernte Bytes und nicht rückgestellte
        // Claims für Redo erhalten bleiben. Ein bloßes false darf sie nicht vergessen.
        guard !result.removed.isEmpty || !result.remainingEntries.isEmpty else {
            if let reservation { buffer.remove(reservation) }
            return false
        }
        ticket = reservation
        if reservation == nil { buffer.invalidate(invalidated) }
        // Leere Ordner bleiben bestehen: rmdir könnte einen fremden Ersatz
        // treffen. Die Löschoperationen selbst bleiben ohne Durability-Zusage.
        return true
    }

    func restoreFromMemory(hooks: MarkdownImagePublication.Hooks = .init()) -> Bool {
        lastPresenceFailure = nil
        guard let ticket else { return false }
        if let removal, removal.hasClaims {
            let result = removal.restoreClaims()
            replaceRemovalResult(result)
            guard result.complete else { return false }
            self.removal = nil
        }
        let restored = buffer.withData(ticket) { data -> Bool in
            let created = mkdirat(documentFD, "images", mode_t(0o755)) == 0
            guard created || errno == EEXIST, let fd = openImages() else { return false }
            defer { Darwin.close(fd) }
            var published = pendingPublications
            var restoredIdentities = identities
            do {
                // Barrieren zuerst am jeweils damaligen Ordner abschließen.
                if !pendingPublications.isEmpty {
                    try MarkdownImagePublication.completePendingBarriers(pendingPublications, parent: documentFD, hooks: hooks)
                }
                for (index, image) in images.enumerated() {
                    let name = image.fileURL.lastPathComponent
                    if let retained = pendingPublications.first(where: { $0.name == name && $0.belongsToDirectory(fd) && (try? $0.identity()) != nil }) {
                        // Fehler dürfen eine vollständige eigene Kopie erhalten.
                        // Nur ihre exakte Version samt Bytes darf der Retry übernehmen.
                        try retained.synchronizeRetainedFile(hooks: hooks)
                        restoredIdentities[index] = try retained.identity()
                        continue
                    }
                    if let existing = identity(named: name, in: fd), sameFile(identities[index], existing),
                       verifiedContent(image, expected: existing, in: fd, collect: false) != nil {
                        restoredIdentities[index] = existing
                        continue
                    }
                    let metadata = try PropertyListDecoder().decode(Metadata.self, from: data[index * 2 + 1])
                    let temporary = ".fastra-image-restore-\(UUID().uuidString).tmp"
                    let output = openat(fd, temporary, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
                    guard output >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    var temporaryExists = true
                    defer {
                        Darwin.close(output)
                        if temporaryExists { _ = unlinkat(fd, temporary, 0) }
                    }
                    let modificationTime = timespec(tv_sec: Int(identities[index].modificationSeconds),
                                                    tv_nsec: Int(identities[index].modificationNanoseconds))
                    guard write(data[index * 2], to: output),
                          metadata.restore(to: output, modificationTime: modificationTime) else { throw POSIXError(.EIO) }
                    try MarkdownImagePublication.syncFile(output, hooks: hooks)
                    let publication = try MarkdownImagePublication(file: output, directory: fd, name: name, expectedSHA256: image.contentSHA256)
                    try publication.publish(temporaryName: temporary)
                    temporaryExists = false
                    // Vor jedem neuen Fehler nach Rename muss das Eigentum bekannt sein.
                    published.append(publication)
                    try hooks.afterRenameBeforeIdentity?(publication.url)
                    try publication.capturePublishedIdentity()
                    try hooks.afterRename?(publication.url)
                    restoredIdentities[index] = try publication.identity()
                }
                guard imagesStillMatches(fd) else { throw POSIXError(.ESTALE) }
                try MarkdownImagePublication.syncDirectories(images: fd, parent: documentFD, hooks: hooks)
                guard imagesStillMatches(fd) else { throw POSIXError(.ESTALE) }
                // Nach dem Sync darf keine inzwischen fremde Datei bestätigt werden.
                for (index, image) in images.enumerated() {
                    guard identity(named: image.fileURL.lastPathComponent, in: fd) == restoredIdentities[index] else {
                        throw POSIXError(.ESTALE)
                    }
                }
                identities = restoredIdentities
                pendingPublications = []
                lastRestoreFailure = nil
                return true
            } catch {
                let failure = MarkdownImagePublication.failure(error, publications: published,
                    images: fd, parent: documentFD, hooks: hooks)
                pendingPublications = published
                lastRestoreFailure = failure
                // Eigene vollständige Kopien bleiben sichtbar erhalten. RAM-Ticket,
                // Reservierungen und Text-Redo bleiben unverändert für den Retry.
                return false
            }
        } ?? false
        if restored {
            buffer.remove(ticket)
            self.ticket = nil
            replaceRemovalResult(nil)
            acknowledgeResolvedRemovalFailure()
        }
        return restored
    }

    private func imagesStillMatches(_ fd: Int32) -> Bool {
        var opened = stat()
        var named = stat()
        return fstat(fd, &opened) == 0
            && fstatat(documentFD, "images", &named, AT_SYMLINK_NOFOLLOW) == 0
            && named.st_mode & S_IFMT == S_IFDIR
            && opened.st_dev == named.st_dev && opened.st_ino == named.st_ino
    }

    func discardMemory() {
        if let ticket { buffer.remove(ticket); self.ticket = nil }
        // Verwerfen löscht keine nach einem Fehler erhaltene Datei.
        pendingPublications = []
        lastRestoreFailure = nil
        lastPresenceFailure = nil
    }

    /// Aufräumen und abgebrochene Einfügungen benötigen keine Undo-Kopie.
    func removePermanently(gate: (() -> Bool) -> Bool = { $0() },
                           hooks: MarkdownImageRemoval.Hooks = .init()) -> Bool {
        withoutActuallyEscaping(gate) { gate in
            removePermanently(gate: MarkdownImageRemoval.legacyGate(gate), hooks: hooks)
        }
    }

    func removePermanently(gate: MarkdownImageRemoval.DetailedGate,
                           hooks: MarkdownImageRemoval.Hooks = .init()) -> Bool {
        beginRemovalAttempt()
        guard let fd = openImages() else {
            replaceRemovalResult(.init(causes: [POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)]))
            return false
        }
        defer { Darwin.close(fd) }
        if let removal, removal.hasClaims {
            let result = removal.restoreClaims()
            replaceRemovalResult(result)
            guard result.complete else { return false }
            self.removal = nil
        }
        let result = removeVerifiedFiles(in: fd, hooks: hooks, gate: gate)
        replaceRemovalResult(result)
        permanentlyRemoved.formUnion(result.removed.map(\.lastPathComponent))
        if result.complete, images.allSatisfy({ permanentlyRemoved.contains($0.fileURL.lastPathComponent) }) {
            acknowledgeResolvedRemovalFailure()
        }
        return result.complete
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

        func canRestore(in directory: Int32, modificationTime: timespec) throws -> Bool {
            let name = ".fastra-image-metadata-\(UUID().uuidString).tmp"
            let fd = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(fd) }
            // Vor der Rechteprobe vom Verzeichnis trennen: Selbst eine ACL mit
            // Löschsperre hinterlässt so keine unzugängliche Nachbardatei.
            guard unlinkat(directory, name, 0) == 0 else { return false }
            return restore(to: fd, modificationTime: modificationTime)
        }
    }

    private func captureMetadata(_ image: MarkdownImageStore.StoredImage,
                                 expected: MarkdownImageStore.StoredFileIdentity,
                                 in directory: Int32, byteLimit: Int) throws -> (data: Data, identity: MarkdownImageStore.StoredFileIdentity)? {
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
              try metadata.canRestore(in: directory, modificationTime: before.st_mtimespec) else { return nil }
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

    private func removeVerifiedFiles(in directory: Int32,
                                     metadataSnapshots: [MarkdownImageStore.StoredFileIdentity]? = nil,
                                     hooks: MarkdownImageRemoval.Hooks, gate: MarkdownImageRemoval.DetailedGate) -> MarkdownImageRemoval.Result {
        var verified: [(MarkdownImageStore.StoredImage, MarkdownImageStore.StoredFileIdentity)] = []
        for (index, image) in images.enumerated() {
            let name = image.fileURL.lastPathComponent
            if permanentlyRemoved.contains(name) { continue }
            guard let observed = identity(named: name, in: directory), sameFile(identities[index], observed),
                  metadataSnapshots.map({ $0[index] == observed }) ?? true,
                  verifiedContent(image, expected: observed, in: directory, collect: false) != nil,
                  identity(named: name, in: directory) == observed else {
                return .init(causes: [POSIXError(.ESTALE)])
            }
            verified.append((image, observed))
        }
        do {
            let operation = try MarkdownImageRemoval(images: directory)
            removal = operation
            let result = operation.remove(verified, hooks: hooks, gate: gate)
            if !operation.hasClaims { removal = nil }
            return result
        } catch let result as MarkdownImageRemoval.Result { return result }
        catch { return .init(causes: [error]) }
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
        do {
            try data.withUnsafeBytes { bytes in
                try POSIXBufferWriter.writeAll(bytes, to: fd)
            }
            return true
        } catch {
            return false
        }
    }

    var referenceRejectionID: UUID? { lastRemovalResult?.referenceRejectionID }

    /// Der angenommene visuelle Terminalabschluss ersetzt nur seinen eigenen
    /// reinen Gatebefund. Ein inzwischen neuerer Befund bleibt unverändert.
    func retireReferenceRejection(_ id: UUID) {
        if lastRemovalResult?.referenceRejectionID == id { lastRemovalResult = nil }
    }
}
