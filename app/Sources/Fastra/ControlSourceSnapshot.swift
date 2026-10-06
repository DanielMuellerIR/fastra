import CryptoKit
import Darwin
import FastraControlProtocol
import Foundation

extension ControlSourceGeneration {
    init(_ value: stat) {
        self.init(device: UInt64(value.st_dev), inode: UInt64(value.st_ino), size: UInt64(max(0, value.st_size)),
                  modificationSeconds: Int64(value.st_mtimespec.tv_sec), modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                  changeSeconds: Int64(value.st_ctimespec.tv_sec), changeNanoseconds: Int64(value.st_ctimespec.tv_nsec))
    }
}

/// Besitzt nur die selbst angelegte, eindeutig markierte Sitzungskopie.
/// Das Sender-Verzeichnis und seine Lebensdauer bleiben davon unabhängig.
final class ControlSourceSnapshot {
    let loaded: FileLoader.LoadedFile
    let provenance: ControlSourceProvenance
    let fileURL: URL
    private let directory: URL
    private let lock = NSLock()
    private var removed = false
    private static let prefix = "FastraSourceSnapshot-v1-"
    private struct Marker: Codable {
        let schema: Int
        let ownerPID: Int32
        let identifier: UUID
    }

    private init(loaded: FileLoader.LoadedFile, provenance: ControlSourceProvenance, fileURL: URL, directory: URL) {
        self.loaded = loaded; self.provenance = provenance; self.fileURL = fileURL; self.directory = directory
    }
    deinit { remove() }

    func remove() {
        lock.lock()
        defer { lock.unlock() }
        guard !removed else { return }
        removed = true
        try? FileManager.default.removeItem(at: directory)
    }

    static func generation(at url: URL) throws -> ControlSourceGeneration {
        let opened = try FileSnapshot.openRegularFile(at: url)
        defer { close(opened.descriptor) }
        return ControlSourceGeneration(opened.stat)
    }

    /// Ein Hash bindet den äußeren Bytebestand. Die Zuordnung zu einem
    /// Mitglied bleibt eine Senderangabe: Fastra entpackt das Archiv nicht neu.
    private static func verifyOuter(_ provenance: ControlSourceProvenance) throws {
        try Task.checkCancellation()
        let url = URL(fileURLWithPath: provenance.hitIdentity.filesystemPath)
        let opened = try FileSnapshot.openRegularFile(at: url)
        defer { close(opened.descriptor) }
        guard ControlSourceGeneration(opened.stat) == provenance.sourceGeneration else { throw ControlFailure.stale }
        if let expected = provenance.outerSHA256 {
            guard opened.stat.st_size >= 0, opened.stat.st_size <= ControlProtocol.maximumOuterArchiveBytes else {
                throw ControlFailure.source
            }
            let handle = FileHandle(fileDescriptor: opened.descriptor, closeOnDealloc: false)
            var hasher = SHA256()
            var bytes = 0
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: 262_144) ?? Data()
                if chunk.isEmpty { break }
                bytes += chunk.count
                guard bytes <= ControlProtocol.maximumOuterArchiveBytes else { throw ControlFailure.source }
                hasher.update(data: chunk)
            }
            var after = stat()
            guard fstat(opened.descriptor, &after) == 0,
                  FileSnapshot.describesSameOpenedVersion(opened.stat, after),
                  hasher.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw ControlFailure.stale }
        }
    }

    static func adopt(_ request: ControlRequest, temporaryRoot: URL = FileManager.default.temporaryDirectory) throws -> ControlSourceSnapshot {
        // Der Controller hat die Annahmefrist bereits geprüft. Wartende
        // Jobs behalten danach ihre eigene Ausführungsfrist.
        try request.validate(allowExpired: true)
        guard let provenance = request.provenance, let path = request.path else { throw ControlFailure.invalidRequest }
        let identifier = UUID()
        let directory = temporaryRoot.appendingPathComponent(prefix + identifier.uuidString, isDirectory: true)
        var createdDirectory = false
        do {
            try verifyOuter(provenance)
            let raw = try FileSnapshot.read(from: URL(fileURLWithPath: path), byteLimit: UInt64(ControlProtocol.maximumSnapshotBytes))
            guard raw.snapshot.sha256 == request.sha256 else { throw ControlFailure.stale }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            createdDirectory = true
            let marker = Marker(schema: 1, ownerPID: getpid(), identifier: identifier)
            try JSONEncoder().encode(marker).write(to: directory.appendingPathComponent("owner.json"), options: .atomic)
            let destination = directory.appendingPathComponent("source.snapshot")
            try raw.data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
            let loaded = try FileLoader.load(url: destination, largeFileThreshold: UInt64(ControlProtocol.maximumSnapshotBytes),
                                            isCancelled: { Task.isCancelled })
            guard loaded.displayMode == .text, loaded.diskSnapshot?.sha256 == request.sha256 else { throw ControlFailure.source }
            try ControlSelection(location: request.location!, length: request.length!).validate(in: loaded.content)
            try verifyOuter(provenance)
            try Task.checkCancellation()
            return ControlSourceSnapshot(loaded: loaded, provenance: provenance, fileURL: destination, directory: directory)
        } catch {
            // Ein fremder vorhandener Pfad wird nie übernommen oder gelöscht.
            if createdDirectory {
                try? FileManager.default.removeItem(at: directory)
            }
            if error is ControlFailure || error is CancellationError { throw error }
            throw ControlFailure.source
        }
    }

    /// Nach einem Prozessabbruch nur eigene markierte Wurzeln mit bereits
    /// beendetem Besitzer entfernen; lebende Instanzen bleiben unangetastet.
    static func pruneAbandoned(in root: URL = FileManager.default.temporaryDirectory) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for directory in entries where directory.lastPathComponent.hasPrefix(prefix) {
            var info = stat()
            guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
                  let identifier = UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) else { continue }
            let markerURL = directory.appendingPathComponent("owner.json")
            guard lstat(markerURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
                  let raw = try? FileSnapshot.read(from: markerURL, byteLimit: 4096),
                  let marker = try? JSONDecoder().decode(Marker.self, from: raw.data), marker.schema == 1,
                  marker.identifier == identifier, marker.ownerPID > 0,
                  kill(marker.ownerPID, 0) == -1, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
