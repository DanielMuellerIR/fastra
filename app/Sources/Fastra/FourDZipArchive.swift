// FourDZipArchive.swift
//
// Minimaler ZIP-Leser für 4D-Komponentenarchive (`.4DZ`). Fastra braucht aus
// so einem Archiv nur wenige kleine Textdateien (Methodenquellen und
// Metadaten-JSON) — dafür wird das Archiv NICHT vollständig entpackt,
// sondern nur das zentrale Verzeichnis gelesen und der jeweils angefragte
// Eintrag einzeln dekomprimiert.
//
// Bewusste, ehrliche Grenzen: verschlüsselte Archive, ZIP64 (Dateien über
// 4 GB bzw. entsprechende Marker) und andere Kompressionsmethoden als
// „stored" (0) und „deflate" (8) werden abgelehnt (`nil`), niemals halb
// gelesen. Ein Größenlimit pro Eintrag schützt vor unkontrolliertem
// Speicherverbrauch durch beschädigte oder bösartige Archive.

import Foundation
import Compression

enum FourDZipArchive {

    /// Ein Eintrag des zentralen Verzeichnisses. `path` nutzt `/` als
    /// Trenner, wie im ZIP-Format vorgeschrieben.
    struct Entry: Equatable {
        let path: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int

        var isDirectory: Bool { path.hasSuffix("/") }
    }

    /// ZIP-Signaturen (little endian im Dateiformat).
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let centralDirectorySignature: UInt32 = 0x0201_4B50
    private static let localHeaderSignature: UInt32 = 0x0403_4B50

    /// Liest das zentrale Verzeichnis. `nil` bei jedem Formatproblem —
    /// lieber gar keine Auskunft als eine unvollständige.
    static func entries(of url: URL) -> [Entry]? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let fileSize = try? file.seekToEnd(), fileSize >= 22 else {
            return nil
        }

        // Der „End of Central Directory"-Record steht am Dateiende, davor
        // darf ein Archivkommentar (max. 64 KB) liegen. Rückwärts suchen.
        let tailLength = Int(min(fileSize, 22 + 65_536))
        guard let tail = read(file, offset: fileSize - UInt64(tailLength),
                              count: tailLength) else { return nil }
        var eocdOffset = -1
        var index = tailLength - 22
        while index >= 0 {
            if readUInt32(tail, at: index) == endOfCentralDirectorySignature {
                eocdOffset = index
                break
            }
            index -= 1
        }
        guard eocdOffset >= 0 else { return nil }

        let entryCount = Int(readUInt16(tail, at: eocdOffset + 10))
        let directorySize = Int(readUInt32(tail, at: eocdOffset + 12))
        let directoryOffset = readUInt32(tail, at: eocdOffset + 16)
        // 0xFFFFFFFF bzw. 0xFFFF sind ZIP64-Marker — nicht unterstützt.
        guard directoryOffset != 0xFFFF_FFFF, entryCount != 0xFFFF,
              UInt64(directoryOffset) + UInt64(directorySize) <= fileSize else {
            return nil
        }
        // Das Feld ist 32 Bit breit — ein beschädigtes oder bösartiges Archiv
        // könnte bis ~4 GiB Verzeichnis deklarieren, die unten am Stück in
        // den Speicher gelesen würden. Reale 4DZ-Verzeichnisse liegen im
        // niedrigen Megabyte-Bereich (max. 65.534 Einträge à ~46 Bytes plus
        // Namen); 32 MiB sind eine großzügige, ehrliche Obergrenze.
        guard directorySize <= 32 * 1024 * 1024 else { return nil }
        guard let directory = read(file, offset: UInt64(directoryOffset),
                                   count: directorySize) else { return nil }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var cursor = 0
        for _ in 0..<entryCount {
            guard cursor + 46 <= directory.count,
                  readUInt32(directory, at: cursor) == centralDirectorySignature else {
                return nil
            }
            let method = readUInt16(directory, at: cursor + 10)
            let compressed = readUInt32(directory, at: cursor + 20)
            let uncompressed = readUInt32(directory, at: cursor + 24)
            let nameLength = Int(readUInt16(directory, at: cursor + 28))
            let extraLength = Int(readUInt16(directory, at: cursor + 30))
            let commentLength = Int(readUInt16(directory, at: cursor + 32))
            let headerOffset = readUInt32(directory, at: cursor + 42)
            guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF,
                  headerOffset != 0xFFFF_FFFF,
                  cursor + 46 + nameLength <= directory.count else {
                return nil
            }
            let nameData = directory.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            // ZIP-Namen sind UTF-8 oder CP437; 4D schreibt UTF-8. Nicht
            // dekodierbare Namen überspringen statt zu raten.
            if let path = String(data: nameData, encoding: .utf8) {
                entries.append(Entry(
                    path: path,
                    compressionMethod: method,
                    compressedSize: Int(compressed),
                    uncompressedSize: Int(uncompressed),
                    localHeaderOffset: Int(headerOffset)
                ))
            }
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Liest und dekomprimiert genau einen Eintrag. Überschreitet die
    /// entpackte Größe `maximumSize`, wird ehrlich `nil` geliefert.
    static func data(of entry: Entry, in url: URL,
                     maximumSize: Int = 1_048_576) -> Data? {
        guard !entry.isDirectory,
              entry.uncompressedSize <= maximumSize,
              entry.compressedSize <= maximumSize else { return nil }
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }

        // Der lokale Header wiederholt Name und Extra-Feld mit EIGENEN
        // Längen (die vom zentralen Verzeichnis abweichen dürfen).
        guard let header = read(file, offset: UInt64(entry.localHeaderOffset),
                                count: 30),
              readUInt32(header, at: 0) == localHeaderSignature else {
            return nil
        }
        let nameLength = Int(readUInt16(header, at: 26))
        let extraLength = Int(readUInt16(header, at: 28))
        let dataOffset = UInt64(entry.localHeaderOffset + 30 + nameLength + extraLength)
        guard let compressed = read(file, offset: dataOffset,
                                    count: entry.compressedSize) else {
            return nil
        }

        switch entry.compressionMethod {
        case 0:     // stored — unkomprimiert abgelegt
            guard compressed.count == entry.uncompressedSize else { return nil }
            return compressed
        case 8:     // deflate
            return inflate(compressed, uncompressedSize: entry.uncompressedSize)
        default:
            return nil
        }
    }

    /// Rohes DEFLATE dekomprimieren. `COMPRESSION_ZLIB` des Compression-
    /// Frameworks ist — anders als der Name andeutet — genau der rohe
    /// DEFLATE-Strom ohne zlib-Header, wie ihn ZIP verwendet.
    private static func inflate(_ compressed: Data, uncompressedSize: Int) -> Data? {
        guard uncompressedSize > 0 else { return Data() }
        var result = Data(count: uncompressedSize)
        let written = result.withUnsafeMutableBytes { destination -> Int in
            compressed.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase, uncompressedSize,
                    sourceBase, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == uncompressedSize else { return nil }
        return result
    }

    // MARK: - Kleinkram

    private static func read(_ file: FileHandle, offset: UInt64,
                             count: Int) -> Data? {
        guard count >= 0 else { return nil }
        do {
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: count),
                  data.count == count else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// Little-endian-Werte byteweise lesen — `load(as:)` würde auf
    /// unausgerichteten Offsets crashen.
    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset])
            | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(readUInt16(data, at: offset))
            | UInt32(readUInt16(data, at: offset + 2)) << 16
    }
}
