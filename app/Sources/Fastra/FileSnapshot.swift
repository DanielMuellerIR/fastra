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

    static func read(from url: URL) throws -> (data: Data, snapshot: FileSnapshot) {
        // Bytes und Dateiidentität müssen zum selben geöffneten Dateiobjekt
        // gehören. Ein separates Data(contentsOf:) plus spätere Pfadabfrage
        // könnte bei einem atomaren Fremd-Replace zwei verschiedene Inodes
        // zu einem scheinbar gültigen Snapshot vermischen.
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
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
