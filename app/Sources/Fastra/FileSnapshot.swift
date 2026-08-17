// FileSnapshot.swift
//
// Gemeinsame Vergleichsbasis für alle schreibenden Dateipfade. Ein reines
// Änderungsdatum reicht nicht: Dateisysteme haben unterschiedliche
// Zeitauflösungen, und ein atomarer Fremd-Write kann den Pfad auf ein neues
// Dateiobjekt zeigen lassen. Deshalb vergleichen Apply, Undo und Speichern
// sowohl die exakten Bytes als auch – soweit verfügbar – Volume und Inode.

import CryptoKit
import Darwin
import Foundation

struct FileIdentity: Codable, Equatable, Hashable, Sendable {
    let volumeNumber: UInt64
    let fileNumber: UInt64

    init?(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let volume = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        volumeNumber = volume.uint64Value
        fileNumber = file.uint64Value
    }

    init(stat: stat) {
        volumeNumber = UInt64(stat.st_dev)
        fileNumber = UInt64(stat.st_ino)
    }
}

enum FileSnapshotReadError: Error {
    case changedDuringRead
    /// Der Pfad ist keine reguläre Datei, sondern z. B. eine FIFO (benannte
    /// Pipe), ein Socket, eine Gerätedatei oder ein Verzeichnis. Solche
    /// Objekte werden nach dem Öffnen am Deskriptor erkannt und nie gelesen.
    case notRegularFile
    /// Die Datei überschreitet die Sicherheitsgrenze für vollständige Reads.
    case tooLarge(byteCount: UInt64)
}

struct FileSnapshot: Codable, Equatable, Hashable, Sendable {
    let sha256: String
    let byteCount: Int
    let identity: FileIdentity?

    init(data: Data, at url: URL) {
        sha256 = Self.sha256Hex(data)
        byteCount = data.count
        identity = FileIdentity(url: url)
    }

    init(data: Data, identity: FileIdentity?) {
        sha256 = Self.sha256Hex(data)
        byteCount = data.count
        self.identity = identity
    }

    /// Für den streamenden Reader unten: Hash und Größe sind dort schon
    /// fertig berechnet, ohne dass die Bytes je gesammelt vorlagen.
    private init(sha256: String, byteCount: Int, identity: FileIdentity?) {
        self.sha256 = sha256
        self.byteCount = byteCount
        self.identity = identity
    }

    /// Obergrenze für vollständige Snapshot-Reads. Sie schützt Ordnersuche,
    /// Apply und Undo davor, eine unerwartet riesige Datei komplett in den
    /// Speicher zu ziehen: 256 MiB liegen weit über der 32-MiB-Grenze
    /// editierbarer Dateien und über realen Textdateien, aber unter dem
    /// Bereich, in dem die anschließende String-Dekodierung (bis zu 4× der
    /// Bytezahl) den Prozess unbenutzbar macht.
    static let maximumReadBytes: UInt64 = 256 * 1024 * 1024

    /// Öffnet `url` als reguläre Datei, ohne je zu blockieren, und liefert
    /// Deskriptor plus `fstat`-Ergebnis. `O_NONBLOCK` ist die FIFO-Sicherung:
    /// Ein `open` auf eine benannte Pipe ohne Schreiber würde sonst unbegrenzt
    /// hängen. Für reguläre Dateien ist das Flag wirkungslos. Die Typprüfung
    /// passiert am bereits geöffneten Deskriptor — zwischen Prüfung und Lesen
    /// kann der Pfad also nicht mehr auf ein anderes Objekt umgebogen werden.
    static func openRegularFile(at url: URL) throws -> (descriptor: Int32, stat: stat) {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw FileSnapshotReadError.notRegularFile
        }
        return (descriptor, info)
    }

    static func read(from url: URL,
                     byteLimit: UInt64 = maximumReadBytes) throws
        -> (data: Data, snapshot: FileSnapshot) {
        // Bytes und Dateiidentität müssen zum selben geöffneten Dateiobjekt
        // gehören. Ein separates Data(contentsOf:) plus spätere Pfadabfrage
        // könnte bei einem atomaren Fremd-Replace zwei verschiedene Inodes
        // zu einem scheinbar gültigen Snapshot vermischen.
        let (descriptor, before) = try openRegularFile(at: url)
        defer { close(descriptor) }

        guard before.st_size >= 0, UInt64(before.st_size) <= byteLimit else {
            throw FileSnapshotReadError.tooLarge(byteCount: UInt64(max(0, before.st_size)))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        // Chunkweise lesen statt readToEnd(): So greift die Grenze auch dann,
        // wenn die Datei WÄHREND des Lesens wächst — der Speicher ist sonst
        // schon verbraucht, bevor die Änderungs-Prüfung unten anspringt.
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            guard UInt64(data.count) <= byteLimit else {
                throw FileSnapshotReadError.tooLarge(byteCount: UInt64(data.count))
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw FileSnapshotReadError.changedDuringRead
        }
        return (data, FileSnapshot(data: data, identity: FileIdentity(stat: after)))
    }

    /// Wie `read`, aber OHNE die Bytes zu behalten: Der SHA-256 wird
    /// chunkweise gefüttert, im Speicher liegt nie mehr als ein 4-MiB-Block.
    /// Das ist der richtige Weg für reine Vergleichs-Snapshots — etwa die
    /// Fremdänderungs-Prüfung, die den Inhalt selbst gar nicht braucht.
    /// Vorher-/Nachher-`fstat` sichern wie bei `read` zu, dass Hash und
    /// Identität zu genau einem unveränderten Dateistand gehören.
    static func readSnapshotOnly(from url: URL,
                                 byteLimit: UInt64 = maximumReadBytes) throws
        -> FileSnapshot {
        let (descriptor, before) = try openRegularFile(at: url)
        defer { close(descriptor) }

        guard before.st_size >= 0, UInt64(before.st_size) <= byteLimit else {
            throw FileSnapshotReadError.tooLarge(byteCount: UInt64(max(0, before.st_size)))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var hasher = SHA256()
        var totalBytes: UInt64 = 0
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            totalBytes += UInt64(chunk.count)
            // Grenze auch hier während des Lesens prüfen: Die Datei kann
            // unter dem Reader wachsen, und der Hash wäre sonst beliebig teuer.
            guard totalBytes <= byteLimit else {
                throw FileSnapshotReadError.tooLarge(byteCount: totalBytes)
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw FileSnapshotReadError.changedDuringRead
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FileSnapshot(sha256: digest, byteCount: Int(totalBytes),
                            identity: FileIdentity(stat: after))
    }

    /// Der Hash schützt den Inhalt; die Identität erkennt zusätzlich einen
    /// Austausch des Dateiobjekts mit zufällig identischen Bytes.
    func matches(data: Data, at url: URL) -> Bool {
        self == FileSnapshot(data: data, at: url)
    }

    /// Für Crash-Recovery reicht der erwartete Inhalt: die neue Inode kann
    /// vor dem Replace noch nicht bekannt sein. Reguläre Konfliktprüfungen
    /// vergleichen weiterhin den vollständigen Snapshot samt Identität.
    func matchesContent(of data: Data) -> Bool {
        byteCount == data.count && sha256 == Self.sha256Hex(data)
    }

    func hasSameContent(as other: FileSnapshot) -> Bool {
        byteCount == other.byteCount && sha256 == other.sha256
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
