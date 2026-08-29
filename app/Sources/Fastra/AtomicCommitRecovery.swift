// AtomicCommitRecovery.swift
//
// Dauerhafte Zuordnung für den kurzen Zeitraum eines atomaren Dateitauschs.
// Ohne diesen Eintrag blieben nach einem Prozessabbruch zwar beide Dateien
// erhalten, aber nur ein zufälliger Temp-Name verriet die verdrängte Fassung.

import Darwin
import Foundation

enum AtomicCommitRecovery {
    /// Der Journal-Eintrag speichert bewusst nur Hash, Größe und Identität.
    /// Dateiinhalte gehören weder ins Application-Support-Verzeichnis noch in
    /// Fehlermeldungen; die beiden echten Dateien bleiben an ihren Pfaden.
    fileprivate struct ContentSignature: Codable, Equatable, Sendable {
        let sha256: String
        let byteCount: Int

        init(_ snapshot: FileSnapshot) {
            sha256 = snapshot.sha256
            byteCount = snapshot.byteCount
        }
    }

    fileprivate struct Record: Codable, Sendable {
        let schemaVersion: Int
        let id: UUID
        let ownerProcessID: Int32
        let ownerProcessStartToken: UInt64
        let createdAt: Date
        let targetPath: String
        let preparedPath: String
        let cleanupName: String
        let targetIdentity: FileIdentity
        let preparedIdentity: FileIdentity
        let expectedContent: ContentSignature
        let replacementContent: ContentSignature
    }

    struct Handle: Sendable {
        fileprivate let record: Record

        var cleanupName: String { record.cleanupName }
    }

    struct Inspection: Equatable, Sendable {
        enum State: Equatable, Sendable {
            /// Beide Namen stehen noch wie vor `RENAME_SWAP`.
            case beforeExchange
            /// Die beiden ursprünglichen Dateiobjekte haben ihre Namen getauscht.
            case afterExchange
            /// Mindestens ein erreichbarer Name zeigt nicht mehr auf die
            /// im Journal gebundene Inode.
            case changed
            /// Der eigentliche Zielpfad fehlt. Die zweite Fassung kann noch
            /// erreichbar sein; falls auch sie fehlt, bleibt wenigstens das
            /// Journal als Hinweis erhalten.
            case missingTarget
            /// Der Eintrag ist beschädigt oder stammt aus einem unbekannten
            /// Schema. Er bleibt zur Diagnose unangetastet.
            case invalidJournal
        }

        let state: State
        let targetURL: URL?
        /// Tatsächlich erreichbarer zweiter Pfad. Nach einem Abbruch mitten
        /// im Aufräumen kann das der private Cleanup- statt des Temp-Namens sein.
        let preparedURL: URL?
        /// Nur im bereits fremd veränderten Fall können Temp- und
        /// Cleanup-Name zugleich existieren.
        let additionalURL: URL?
        let journalURL: URL
    }

    struct Store: Sendable {
        let directoryURL: URL
        private let processStartToken: @Sendable (pid_t) -> UInt64?

        init(
            directoryURL: URL,
            processStartToken: @escaping @Sendable (pid_t) -> UInt64? = {
                ProcessGroupOperations.live.startToken($0)
            }
        ) {
            // Bestehende Präfix-Symlinks (auf macOS insbesondere `/var` →
            // `/private/var`) werden einmalig aufgelöst. Die danach einzeln
            // geprüften bzw. angelegten Komponenten dürfen selbst keine
            // Symlinks mehr sein.
            self.directoryURL = directoryURL.resolvingSymlinksInPath()
                .standardizedFileURL
            self.processStartToken = processStartToken
        }

        static var standard: Store {
            let fileManager = FileManager.default
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support",
                                        isDirectory: true)
            return Store(directoryURL: appSupport.appendingPathComponent(
                "Fastra/atomic-commit-recovery", isDirectory: true))
        }

        /// Schreibt und synchronisiert die Zuordnung, bevor der erste
        /// Namenstausch stattfinden darf. Scheitert das Journal, scheitert der
        /// Commit noch bei unverändertem Ziel.
        @discardableResult
        func begin(
            targetURL: URL,
            preparedURL: URL,
            targetStat: stat,
            preparedStat: stat,
            expectedContent: FileSnapshot,
            replacementContent: FileSnapshot
        ) throws -> Handle {
            let target = targetURL.standardizedFileURL
            let prepared = preparedURL.standardizedFileURL
            guard target.path.hasPrefix("/"), prepared.path.hasPrefix("/"),
                  target.deletingLastPathComponent().path
                    == prepared.deletingLastPathComponent().path,
                  target.lastPathComponent != prepared.lastPathComponent,
                  validChildName(target.lastPathComponent),
                  validChildName(prepared.lastPathComponent),
                  isRegular(targetStat), isRegular(preparedStat),
                  targetStat.st_size >= 0, preparedStat.st_size >= 0,
                  targetStat.st_dev == preparedStat.st_dev,
                  targetStat.st_ino != preparedStat.st_ino,
                  expectedContent.identity == FileIdentity(stat: targetStat),
                  expectedContent.byteCount == Int(targetStat.st_size),
                  replacementContent.byteCount == Int(preparedStat.st_size) else {
                throw POSIXError(.EINVAL)
            }
            guard let ownerProcessStartToken = processStartToken(getpid()) else {
                // Ohne Startzeit wäre eine später wiedervergebene PID nicht
                // vom ursprünglichen Journal-Besitzer unterscheidbar.
                throw POSIXError(.ESRCH)
            }

            try ensureDirectory()
            let id = UUID()
            let record = Record(
                schemaVersion: 1,
                id: id,
                ownerProcessID: getpid(),
                ownerProcessStartToken: ownerProcessStartToken,
                createdAt: Date(),
                targetPath: target.path,
                preparedPath: prepared.path,
                cleanupName: ".fastra-recovery-\(id.uuidString.lowercased()).tmp",
                targetIdentity: FileIdentity(stat: targetStat),
                preparedIdentity: FileIdentity(stat: preparedStat),
                expectedContent: ContentSignature(expectedContent),
                replacementContent: ContentSignature(replacementContent)
            )
            let data = try JSONEncoder.recoveryEncoder.encode(record)
            let name = journalName(for: id)
            let writingName = name + ".writing"
            let directoryFD = try openDirectory()
            defer { Darwin.close(directoryFD) }
            let journalFD = openat(
                directoryFD, writingName,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600))
            guard journalFD >= 0 else { throw currentPOSIXError() }
            var journalIsOpen = true
            var keepJournal = false
            defer {
                if journalIsOpen { Darwin.close(journalFD) }
                if !keepJournal {
                    _ = unlinkat(directoryFD, writingName, 0)
                    _ = unlinkat(directoryFD, name, 0)
                }
            }
            try writeAll(data, to: journalFD)
            try synchronizeFile(journalFD)
            guard Darwin.close(journalFD) == 0 else {
                journalIsOpen = false
                throw currentPOSIXError()
            }
            journalIsOpen = false
            // Erst die vollständig synchronisierte Datei unter `.json`
            // veröffentlichen. Ein paralleler App-Start kann dadurch nie einen
            // halben JSON-Stream als beschädigtes Recovery-Journal melden.
            let publishFlags = UInt32(RENAME_EXCL)
                | UInt32(RENAME_NOFOLLOW_ANY)
                | UInt32(RENAME_RESOLVE_BENEATH)
            guard renameatx_np(directoryFD, writingName,
                               directoryFD, name, publishFlags) == 0 else {
                throw currentPOSIXError()
            }
            guard fsync(directoryFD) == 0 else { throw currentPOSIXError() }
            keepJournal = true
            return Handle(record: record)
        }

        /// Entfernt nur den zu diesem Handle gehörenden UUID-Eintrag und
        /// synchronisiert auch die Verzeichnisänderung.
        func finish(_ handle: Handle) throws {
            let directoryFD: Int32
            do {
                directoryFD = try openDirectory()
            } catch let error as POSIXError where error.code == .ENOENT {
                return
            }
            defer { Darwin.close(directoryFD) }
            let result = unlinkat(directoryFD, journalName(for: handle.record.id), 0)
            guard result == 0 || errno == ENOENT else { throw currentPOSIXError() }
            guard fsync(directoryFD) == 0 else { throw currentPOSIXError() }
        }

        /// Liest die Journale eines früheren Prozesses. Ein Eintrag ohne
        /// zweiten erreichbaren Pfad wird nur entfernt, wenn Zielidentität und
        /// Inhaltsprüfsumme einen bereits abgeschlossenen Cleanup belegen.
        /// Fehlt das Ziel oder liegt dort ein fremder Stand, bleibt das Journal
        /// als letzter Hinweis erhalten. Sobald zwei Fassungen existieren,
        /// nimmt Fastra keine inhaltliche Entscheidung für den Nutzer vor.
        func inspectPending(includeActiveProcesses: Bool = true) throws -> [Inspection] {
            var directoryInfo = stat()
            guard lstat(directoryURL.path, &directoryInfo) == 0 else {
                if errno == ENOENT { return [] }
                throw currentPOSIXError()
            }
            guard isDirectory(directoryInfo) else { throw POSIXError(.ENOTDIR) }
            let names = try FileManager.default.contentsOfDirectory(
                atPath: directoryURL.path)
                .filter { $0.hasSuffix(".json") }
                .sorted()
            let directoryFD = try openDirectory()
            defer { Darwin.close(directoryFD) }
            var inspections: [Inspection] = []

            for name in names {
                let journalURL = directoryURL.appendingPathComponent(name)
                let data: Data
                do {
                    data = try readJournal(named: name, directoryFD: directoryFD)
                } catch let error as POSIXError where error.code == .ENOENT {
                    // Der noch laufende Besitzer kann sein vollständig
                    // abgeschlossenes Journal zwischen Auflistung und Öffnen
                    // entfernen. Das ist weder ein Absturzrest noch ein
                    // beschädigter Eintrag.
                    continue
                } catch {
                    inspections.append(Inspection(
                        state: .invalidJournal, targetURL: nil,
                        preparedURL: nil, additionalURL: nil,
                        journalURL: journalURL))
                    continue
                }
                guard let record = try? JSONDecoder.recoveryDecoder.decode(
                        Record.self, from: data),
                      record.schemaVersion == 1,
                      name == journalName(for: record.id),
                      let paths = validatedPaths(record) else {
                    inspections.append(Inspection(
                        state: .invalidJournal, targetURL: nil,
                        preparedURL: nil, additionalURL: nil,
                        journalURL: journalURL))
                    continue
                }
                if !includeActiveProcesses,
                   processStartToken(record.ownerProcessID)
                    == record.ownerProcessStartToken {
                    // Ein zweiter App-Prozess oder ein extrem schneller Save
                    // im gerade gestarteten Prozess darf nicht als Absturzrest
                    // erscheinen. Dessen Besitzer entfernt den Eintrag selbst.
                    continue
                }

                let targetObservation = pathObservation(at: paths.target)
                let preparedObservation = pathObservation(at: paths.prepared)
                let cleanupObservation = pathObservation(at: paths.cleanup)
                let existingSecondary: (URL, FileIdentity)?
                switch (preparedObservation, cleanupObservation) {
                case (.regular, .regular),
                     (.other, _), (_, .other):
                    // Zwei zweite Pfade können nur durch eine Fremdänderung
                    // oder einen beschädigten Ablauf entstanden sein. Auch
                    // Symlinks, Ordner und andere Dateitypen bleiben erhalten;
                    // sie dürfen nicht wie ein fehlender Pfad behandelt werden.
                    inspections.append(Inspection(
                        state: .changed, targetURL: paths.target,
                        preparedURL: secondaryURL(
                            preparedObservation, prepared: paths.prepared,
                            cleanupObservation, cleanup: paths.cleanup),
                        additionalURL: preparedObservation.isMissing
                            || cleanupObservation.isMissing ? nil : paths.cleanup,
                        journalURL: journalURL))
                    continue
                case (.regular(let preparedIdentity), .missing):
                    existingSecondary = (paths.prepared, preparedIdentity)
                case (.missing, .regular(let cleanupIdentity)):
                    existingSecondary = (paths.cleanup, cleanupIdentity)
                case (.missing, .missing):
                    existingSecondary = nil
                }

                guard let secondary = existingSecondary else {
                    // Nur eine der beiden im Journal gebundenen Inodes am Ziel
                    // belegt einen bereits abgeschlossenen Cleanup. Fehlt das
                    // Ziel ebenfalls oder liegt dort inzwischen ein fremdes
                    // Objekt, ist das Journal der letzte belastbare Hinweis und
                    // bleibt erhalten.
                    if case .regular(let targetIdentity) = targetObservation,
                       (targetIdentity == record.targetIdentity
                        && contentMatches(
                            at: paths.target,
                            identity: record.targetIdentity,
                            signature: record.expectedContent)
                        || targetIdentity == record.preparedIdentity
                        && contentMatches(
                            at: paths.target,
                            identity: record.preparedIdentity,
                            signature: record.replacementContent)) {
                        // Vor dem Entfernen des Journals wird die Abwesenheit
                        // des zweiten Namens im ZIELVERZEICHNIS dauerhaft
                        // gemacht. Sonst könnte ein späterer Stromausfall den
                        // Cleanup-Namen ohne seine Zuordnung wieder zeigen.
                        try synchronizeParentDirectory(of: paths.target)
                        try finish(Handle(record: record))
                    } else {
                        inspections.append(Inspection(
                            state: targetObservation.isMissing
                                ? .missingTarget : .changed,
                            targetURL: paths.target,
                            preparedURL: nil, additionalURL: nil,
                            journalURL: journalURL))
                    }
                    continue
                }
                guard case .regular(let targetIdentity) = targetObservation else {
                    inspections.append(Inspection(
                        state: targetObservation.isMissing ? .missingTarget : .changed,
                        targetURL: paths.target,
                        preparedURL: secondary.0, additionalURL: nil,
                        journalURL: journalURL))
                    continue
                }

                let state: Inspection.State
                if targetIdentity == record.targetIdentity,
                   secondary.1 == record.preparedIdentity,
                   contentMatches(
                    at: paths.target,
                    identity: record.targetIdentity,
                    signature: record.expectedContent),
                   contentMatches(
                    at: secondary.0,
                    identity: record.preparedIdentity,
                    signature: record.replacementContent) {
                    state = .beforeExchange
                } else if targetIdentity == record.preparedIdentity,
                          secondary.1 == record.targetIdentity,
                          contentMatches(
                            at: paths.target,
                            identity: record.preparedIdentity,
                            signature: record.replacementContent),
                          contentMatches(
                            at: secondary.0,
                            identity: record.targetIdentity,
                            signature: record.expectedContent) {
                    state = .afterExchange
                } else {
                    state = .changed
                }
                inspections.append(Inspection(
                    state: state, targetURL: paths.target,
                    preparedURL: secondary.0, additionalURL: nil,
                    journalURL: journalURL))
            }
            return inspections
        }

        private func ensureDirectory() throws {
            guard directoryURL.path.hasPrefix("/"),
                  directoryURL.path != "/",
                  validChildName(directoryURL.lastPathComponent) else {
                throw POSIXError(.EINVAL)
            }
            try ensureDirectoryExists(directoryURL)
            let descriptor = try openDirectory()
            defer { Darwin.close(descriptor) }
            // Journale enthalten lokale Pfade. Andere lokale Accounts brauchen
            // darauf keinen Lesezugriff.
            guard fchmod(descriptor, mode_t(0o700)) == 0,
                  fsync(descriptor) == 0 else {
                throw currentPOSIXError()
            }
        }

        /// Legt fehlende Verzeichnisse einzeln an. Nach jedem `mkdirat` wird
        /// der Elternordner synchronisiert; dadurch bleibt auch der allererste
        /// Recovery-Ordner nach einem Stromausfall erreichbar. Vorhandene
        /// Symlinks oder andere Dateitypen werden nie verfolgt.
        private func ensureDirectoryExists(_ url: URL) throws {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard isDirectory(info) else { throw POSIXError(.ENOTDIR) }
                return
            }
            guard errno == ENOENT, url.path != "/" else {
                throw currentPOSIXError()
            }
            let parent = url.deletingLastPathComponent()
            let name = url.lastPathComponent
            guard validChildName(name), parent.path != url.path else {
                throw POSIXError(.EINVAL)
            }
            try ensureDirectoryExists(parent)
            let parentFD = Darwin.open(
                parent.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard parentFD >= 0 else { throw currentPOSIXError() }
            defer { Darwin.close(parentFD) }
            if mkdirat(parentFD, name, mode_t(0o700)) != 0, errno != EEXIST {
                throw currentPOSIXError()
            }
            let childFD = openat(
                parentFD, name,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard childFD >= 0 else { throw currentPOSIXError() }
            Darwin.close(childFD)
            guard fsync(parentFD) == 0 else { throw currentPOSIXError() }
        }

        private func openDirectory() throws -> Int32 {
            let descriptor = Darwin.open(
                directoryURL.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw currentPOSIXError() }
            return descriptor
        }

        private func synchronizeParentDirectory(of target: URL) throws {
            let parent = target.deletingLastPathComponent()
            let descriptor = Darwin.open(
                parent.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw currentPOSIXError() }
            defer { Darwin.close(descriptor) }
            guard fsync(descriptor) == 0 else { throw currentPOSIXError() }
        }

        private func readJournal(named name: String,
                                 directoryFD: Int32) throws -> Data {
            guard validChildName(name) else { throw POSIXError(.EINVAL) }
            let descriptor = openat(
                directoryFD, name,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw currentPOSIXError() }
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw currentPOSIXError() }
            guard isRegular(info), info.st_size >= 0, info.st_size <= 64 * 1024 else {
                throw POSIXError(.EFBIG)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            let data = try handle.readToEnd() ?? Data()
            guard data.count == Int(info.st_size) else { throw POSIXError(.EIO) }
            return data
        }

        private func validatedPaths(_ record: Record)
            -> (target: URL, prepared: URL, cleanup: URL)? {
            let target = URL(fileURLWithPath: record.targetPath).standardizedFileURL
            let prepared = URL(fileURLWithPath: record.preparedPath).standardizedFileURL
            guard record.targetPath.hasPrefix("/"),
                  record.preparedPath.hasPrefix("/"),
                  target.path == record.targetPath,
                  prepared.path == record.preparedPath,
                  target.deletingLastPathComponent().path
                    == prepared.deletingLastPathComponent().path,
                  validChildName(target.lastPathComponent),
                  validChildName(prepared.lastPathComponent),
                  validChildName(record.cleanupName),
                  record.cleanupName.hasPrefix(".fastra-recovery-"),
                  validContentSignature(record.expectedContent),
                  validContentSignature(record.replacementContent),
                  target.lastPathComponent != prepared.lastPathComponent,
                  target.lastPathComponent != record.cleanupName,
                  prepared.lastPathComponent != record.cleanupName else {
                return nil
            }
            return (target, prepared,
                    target.deletingLastPathComponent()
                        .appendingPathComponent(record.cleanupName))
        }

        /// Prüft über einen `O_NOFOLLOW`-Deskriptor, dass Identität und Bytes
        /// weiterhin gemeinsam zum Journal passen. So gilt auch ein
        /// gleich großer In-place-Write nach dem Absturz als fremder Stand.
        private func contentMatches(
            at url: URL,
            identity: FileIdentity,
            signature: ContentSignature
        ) -> Bool {
            let descriptor = Darwin.open(
                url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { return false }
            defer { Darwin.close(descriptor) }
            var before = stat()
            guard fstat(descriptor, &before) == 0,
                  isRegular(before), before.st_size >= 0,
                  FileIdentity(stat: before) == identity,
                  Int(before.st_size) == signature.byteCount,
                  let snapshot = try? FileSnapshot.readSnapshotOnly(
                    descriptor: descriptor,
                    fileStat: before,
                    byteLimit: UInt64(signature.byteCount)) else {
                return false
            }
            return snapshot.sha256 == signature.sha256
                && snapshot.byteCount == signature.byteCount
                && snapshot.identity == identity
        }
    }

    private enum PathObservation {
        case missing
        case regular(FileIdentity)
        case other

        var isMissing: Bool {
            if case .missing = self { return true }
            return false
        }
    }

    private static func pathObservation(at url: URL) -> PathObservation {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return errno == ENOENT ? .missing : .other
        }
        guard isRegular(info) else { return .other }
        return .regular(FileIdentity(stat: info))
    }

    private static func secondaryURL(
        _ preparedObservation: PathObservation, prepared: URL,
        _ cleanupObservation: PathObservation, cleanup: URL
    ) -> URL? {
        if !preparedObservation.isMissing { return prepared }
        if !cleanupObservation.isMissing { return cleanup }
        return nil
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor, baseAddress.advanced(by: offset),
                    bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw currentPOSIXError() }
                offset += count
            }
        }
    }

    private static func synchronizeFile(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL || code == ENOTTY else {
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard fsync(descriptor) == 0 else { throw currentPOSIXError() }
    }

    private static func journalName(for id: UUID) -> String {
        id.uuidString.lowercased() + ".json"
    }

    private static func isRegular(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func isDirectory(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func validChildName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func validContentSignature(_ signature: ContentSignature) -> Bool {
        signature.byteCount >= 0
            && signature.sha256.utf8.count == 64
            && signature.sha256.utf8.allSatisfy { byte in
                switch byte {
                case 48...57, 97...102: return true
                default: return false
                }
            }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private extension JSONEncoder {
    static var recoveryEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var recoveryDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
