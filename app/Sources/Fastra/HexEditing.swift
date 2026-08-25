//
// HexEditing.swift
//
// Sicherheitskern des optionalen Hex-Schreibmodus. Änderungen werden nicht
// direkt in die Datei geschrieben, sondern erst als Offsets gesammelt,
// sichtbar vorgeprüft und dann in einem atomaren Schritt gespeichert.

import CryptoKit
import Darwin
import Foundation

struct HexByteChange: Equatable, Identifiable, Sendable {
    let offset: UInt64
    let oldValue: UInt8
    let newValue: UInt8
    var id: UInt64 { offset }

    var description: String {
        String(format: "%012llX   %02X → %02X", offset, oldValue, newValue)
    }
}

enum HexEditing {
    enum SaveError: LocalizedError, Equatable {
        case fileChanged

        var errorDescription: String? {
            switch self {
            case .fileChanged:
                return L10n.string("Die Datei wurde während des Speicherns erneut geändert. Der Plattenstand blieb erhalten.")
            }
        }
    }

    /// Ein fester Abschnitt hält den Speicherbedarf auch bei sehr großen
    /// Binärdateien begrenzt. Die Zieldatei selbst wird erst ersetzt, nachdem
    /// jeder sichtbare Altwert erneut geprüft und die Kopie synchronisiert ist.
    static let saveChunkSize = 1024 * 1024

    /// Akzeptiert exakt die sichtbaren Byte-Tokens einer Hex-Zeile. Keine
    /// stillen Korrekturen: ein Tippfehler darf niemals andere Bytes erzeugen.
    static func parseRow(_ text: String, expectedBytes: Int) -> [UInt8]? {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard tokens.count == expectedBytes else { return nil }
        guard tokens.allSatisfy({ $0.count == 2 }) else { return nil }
        let bytes = tokens.compactMap { UInt8($0, radix: 16) }
        return bytes.count == expectedBytes ? bytes : nil
    }

    static func applying(_ changes: [UInt64: UInt8], to original: Data) -> Data? {
        var result = original
        for (offset, value) in changes {
            guard offset < result.count else { return nil }
            result[Int(offset)] = value
        }
        return result
    }

    /// Überträgt eine Hex-Vorschau abschnittsweise in eine temporäre
    /// Nachbardatei und ersetzt das Original erst nach vollständiger Prüfung.
    /// Ändert ein anderes Programm zwischen Vorschau und Speichern auch nur
    /// einen geplanten Offset, bleibt die vorhandene Datei unangetastet.
    static func save(_ changes: [HexByteChange], to url: URL,
                     beforeAtomicReplace: ((URL) throws -> Void)? = nil) throws {
        guard !changes.isEmpty else { return }
        let planned = changes.sorted { $0.offset < $1.offset }
        for pair in zip(planned, planned.dropFirst()) {
            guard pair.0.offset < pair.1.offset else { throw SaveError.fileChanged }
        }

        let opened = try FileSnapshot.openRegularFile(at: url)
        defer { Darwin.close(opened.descriptor) }
        guard opened.stat.st_size >= 0, let last = planned.last,
              last.offset < UInt64(opened.stat.st_size) else {
            throw SaveError.fileChanged
        }

        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".fastra-hex-\(UUID().uuidString).tmp")
        let permissions = mode_t(opened.stat.st_mode & 0o777)
        let temporaryDescriptor = Darwin.open(
            temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
        guard temporaryDescriptor >= 0 else { throw currentPOSIXError() }
        var temporaryExists = true
        var temporaryIsOpen = true
        defer {
            if temporaryIsOpen { Darwin.close(temporaryDescriptor) }
            if temporaryExists { try? FileManager.default.removeItem(at: temporaryURL) }
        }
        // Die Prozess-Umask darf die Rechte der bestehenden Datei nicht still
        // einschränken. Das Verhalten entspricht dem bisherigen atomaren Save.
        guard fchmod(temporaryDescriptor, permissions) == 0 else {
            throw currentPOSIXError()
        }

        let input = FileHandle(fileDescriptor: opened.descriptor, closeOnDealloc: false)
        let expectedSize = UInt64(opened.stat.st_size)
        var originalHasher = SHA256()
        var replacementHasher = SHA256()
        var copied: UInt64 = 0
        var changeIndex = 0
        while copied < expectedSize {
            let requested = Int(min(UInt64(saveChunkSize), expectedSize - copied))
            guard var chunk = try input.read(upToCount: requested), !chunk.isEmpty else {
                throw SaveError.fileChanged
            }
            originalHasher.update(data: chunk)
            let chunkEnd = copied + UInt64(chunk.count)
            while changeIndex < planned.count, planned[changeIndex].offset < chunkEnd {
                let change = planned[changeIndex]
                guard change.offset >= copied else { throw SaveError.fileChanged }
                let index = chunk.index(chunk.startIndex,
                                        offsetBy: Int(change.offset - copied))
                guard chunk[index] == change.oldValue else { throw SaveError.fileChanged }
                chunk[index] = change.newValue
                changeIndex += 1
            }
            replacementHasher.update(data: chunk)
            try writeAll(chunk, to: temporaryDescriptor)
            copied = chunkEnd
        }
        guard copied == expectedSize, changeIndex == planned.count else {
            throw SaveError.fileChanged
        }

        var after = stat()
        guard fstat(opened.descriptor, &after) == 0 else { throw currentPOSIXError() }
        guard sameFileVersion(opened.stat, after) else { throw SaveError.fileChanged }
        let expectedSnapshot = FileSnapshot(
            sha256: digestHex(originalHasher.finalize()),
            byteCount: Int(copied),
            identity: FileIdentity(stat: after))
        let replacementSnapshot = FileSnapshot(
            sha256: digestHex(replacementHasher.finalize()),
            byteCount: Int(copied), identity: nil)
        guard fsync(temporaryDescriptor) == 0 else { throw currentPOSIXError() }
        guard Darwin.close(temporaryDescriptor) == 0 else { throw currentPOSIXError() }
        temporaryIsOpen = false

        var coordinationError: NSError?
        var writeError: Error?
        var preserveTemporaryForRecovery = false
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: [],
                               error: &coordinationError) { coordinatedURL in
            do {
                guard coordinatedURL.standardizedFileURL.path
                        == url.standardizedFileURL.path else {
                    throw SaveError.fileChanged
                }
                do {
                    _ = try AtomicFileCommit.replaceExisting(
                        at: coordinatedURL,
                        withPreparedFile: temporaryURL,
                        expecting: expectedSnapshot,
                        replacementContent: replacementSnapshot,
                        verifiedTargetStat: after,
                        beforeSwap: beforeAtomicReplace)
                    temporaryExists = false
                } catch let failure as AtomicFileCommit.Failure {
                    preserveTemporaryForRecovery =
                        failure.mustPreservePreparedPath
                    if preserveTemporaryForRecovery { temporaryExists = false }
                    switch failure {
                    case .conflictUnchanged, .conflictRolledBack:
                        throw SaveError.fileChanged
                    case .unsupportedAtomicSwap, .recoveryRequired:
                        throw failure
                    }
                }
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private static func sameFileVersion(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func digestHex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    descriptor, base.advanced(by: written), rawBuffer.count - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                guard result > 0 else { throw POSIXError(.EIO) }
                written += result
            }
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

@MainActor
final class HexEditSession: ObservableObject {
    @Published private(set) var changes: [UInt64: HexByteChange] = [:]
    @Published private(set) var invalidRowMessage: String?

    var hasChanges: Bool { !changes.isEmpty }
    var preview: [HexByteChange] { changes.values.sorted { $0.offset < $1.offset } }

    func textForRow(data: Data, baseOffset: UInt64, row: Int) -> String {
        let start = row * 16
        let end = min(start + 16, data.count)
        guard start < end else { return "" }
        return (start..<end).map { index in
            let offset = baseOffset + UInt64(index)
            return String(format: "%02X", changes[offset]?.newValue ?? data[index])
        }.joined(separator: " ")
    }

    func editRow(_ text: String, data: Data, baseOffset: UInt64, row: Int) {
        let start = row * 16
        let end = min(start + 16, data.count)
        guard start < end, let bytes = HexEditing.parseRow(text, expectedBytes: end - start) else {
            invalidRowMessage = "Eine Hex-Zeile braucht genau zwei hexadezimale Ziffern pro Byte."
            return
        }
        invalidRowMessage = nil
        for (relative, value) in bytes.enumerated() {
            let index = start + relative
            let offset = baseOffset + UInt64(index)
            if value == data[index] { changes.removeValue(forKey: offset) }
            else { changes[offset] = HexByteChange(offset: offset, oldValue: data[index], newValue: value) }
        }
    }

    /// Der Seiteninhalt mit allen noch nicht gespeicherten Änderungen — die
    /// EINE Bytequelle für Anzeige UND Drucksnapshot. Vorher las die
    /// schreibgeschützte Hex-Zeile die rohen Bytes, der Ausdruck aber die
    /// geänderten: Auf dem Papier standen Bytes, die auf dem Bildschirm nicht
    /// zu sehen waren (Reviewfund 2026-08-18).
    func applied(to data: Data, baseOffset: UInt64) -> Data {
        var page = data
        for (offset, change) in changes {
            let index = Int(offset) - Int(baseOffset)
            guard index >= 0, index < page.count else { continue }
            page[page.startIndex + index] = change.newValue
        }
        return page
    }

    /// Erst nach erfolgreichem Hintergrund-Save verschwindet die sichtbare
    /// Vorschau. Bei einem Konflikt bleiben alle geplanten Änderungen erhalten.
    func markSaved() {
        changes = [:]
    }

    func discard() { changes = [:]; invalidRowMessage = nil }
}
