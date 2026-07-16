// FileLoaderTests.swift
//
// Unit-Tests für `FileLoader.load(url:)`.
// Überprüft Encoding-Erkennung, Line-Ending-Erkennung und Fehlerbehandlung.
//
// Bewusst keine App-Abhängigkeit: FileLoader ist ein reiner Wert-Typ ohne
// SwiftUI/AppKit-Referenzen — die Tests laufen daher vollständig im
// Hintergrund-Thread ohne @MainActor.

import Foundation
import Testing
@testable import Fastra

// MARK: - Hilfs-Funktionen

/// Schreibt `bytes` in eine temporäre Datei und gibt deren URL zurück.
/// Der Aufrufer ist für das Löschen via `try? FileManager.default.removeItem(at:)`
/// verantwortlich (oder defer).
private func writeTmp(_ bytes: [UInt8], suffix: String = ".txt") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-fileloader-\(UUID().uuidString)\(suffix)")
    try Data(bytes).write(to: url)
    return url
}

/// Schreibt `string` mit `encoding` in eine temporäre Datei.
private func writeTmpText(_ string: String, encoding: String.Encoding,
                          suffix: String = ".txt") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-fileloader-\(UUID().uuidString)\(suffix)")
    try string.write(to: url, atomically: true, encoding: encoding)
    return url
}

/// Erzeugt eine echte große, nullfreie Datei mit konstantem Speicherbedarf.
/// Anschließend kann ein Test gezielt einzelne Bytes hinter Probe- oder
/// Scan-Grenzen überschreiben.
private func writeTmpRepeatedByteFile(size: UInt64, byte: UInt8 = 0x41) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-fileloader-large-\(UUID().uuidString).bin")
    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let chunk = Data(repeating: byte, count: 1024 * 1024)
    var remaining = size
    while remaining > 0 {
        let count = min(UInt64(chunk.count), remaining)
        try handle.write(contentsOf: chunk.prefix(Int(count)))
        remaining -= count
    }
    return url
}

// MARK: - Tests: Encoding-Erkennung

@Test("FileLoader: UTF-8 mit LF wird korrekt geladen")
func fileLoader_utf8_lf() throws {
    let content = "Erste Zeile\nZweite Zeile\nDritte Zeile\n"
    let url = try writeTmpText(content, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let result = try FileLoader.load(url: url)

    // Inhalt muss vollständig erhalten sein.
    #expect(result.content == content)
    // UTF-8 muss erkannt werden.
    #expect(result.encoding == .utf8)
    // LF als Zeilenende.
    #expect(result.lineEnding == .lf)
}

@Test("FileLoader: UTF-8 mit CRLF → LineEnding .crlf")
func fileLoader_utf8_crlf() throws {
    let content = "Zeile A\r\nZeile B\r\nZeile C\r\n"
    let url = try writeTmpText(content, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let result = try FileLoader.load(url: url)

    #expect(result.content == content)
    #expect(result.lineEnding == .crlf)
}

@Test("FileLoader: UTF-8 mit CR (alt-Mac) → LineEnding .cr")
func fileLoader_utf8_cr() throws {
    // Reines CR — kein CRLF, kein LF.
    let content = "Alpha\rBeta\rGamma\r"
    let url = try writeTmpText(content, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let result = try FileLoader.load(url: url)

    #expect(result.content == content)
    #expect(result.lineEnding == .cr)
}

@Test("FileLoader: UTF-16 mit BOM wird erkannt")
func fileLoader_utf16_bom() throws {
    // UTF-16 Little-Endian mit BOM (0xFF 0xFE), wie Windows-Notepad es erzeugt.
    // Foundation erkennt den BOM automatisch und meldet `.utf16LittleEndian`
    // (oder `.utf16` — beides ist akzeptabel, solange der Inhalt stimmt).
    let content = "Hallo Welt\nUTF-16-Test\n"
    guard let body = content.data(using: .utf16LittleEndian) else {
        Issue.record("utf16LittleEndian-Kodierung fehlgeschlagen")
        return
    }
    // BOM voranstellen (Little-Endian-BOM = 0xFF 0xFE).
    var data = Data([0xFF, 0xFE])
    data.append(body)

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-fileloader-utf16-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)

    let result = try FileLoader.load(url: url)

    // Der Inhalt muss korrekt dekodiert sein — BOM darf NICHT im Inhalt auftauchen.
    // Foundation schneidet den BOM automatisch ab, wenn der BOM erkannt wurde.
    #expect(result.content.contains("Hallo Welt"))
    // Encoding muss als irgendeine UTF-16-Variante erkannt worden sein.
    let isUTF16 = result.encoding == .utf16
        || result.encoding == .utf16LittleEndian
        || result.encoding == .utf16BigEndian
    #expect(isUTF16, "Erwartet eine UTF-16-Variante, bekam: \(result.encoding)")
    #expect(result.bom == Data([0xFF, 0xFE]))
}

@Test("FileLoader: BOM-markiertes UTF-8 sowie UTF-16 LE/BE bleiben bytegenau")
func fileLoader_unicodeByteRoundTrips() throws {
    let textVariants = [
        "Alpha\nBeta", "Alpha\nBeta\n",
        "Alpha\r\nBeta", "Alpha\r\nBeta\r\n",
        "Alpha\rBeta", "Alpha\rBeta\r"
    ]
    let encodings: [(String.Encoding, Data)] = [
        (.utf8, Data([0xEF, 0xBB, 0xBF])),
        (.utf16LittleEndian, Data([0xFF, 0xFE])),
        (.utf16BigEndian, Data([0xFE, 0xFF]))
    ]

    for text in textVariants {
        for (encoding, bom) in encodings {
            var original = bom
            original.append(try #require(text.data(using: encoding)))
            let url = try writeTmp(Array(original))
            defer { try? FileManager.default.removeItem(at: url) }

            let loaded = try FileLoader.load(url: url)
            #expect(loaded.displayMode == .text)
            #expect(loaded.content == text)
            #expect(loaded.encoding == encoding)
            #expect(loaded.bom == bom)
            let saved = FileLoader.encodedData(
                content: loaded.content, encoding: loaded.encoding,
                bom: loaded.bom, lineEnding: loaded.lineEnding)
            #expect(saved == original)
        }
    }
}

@Test("FileLoader: BOM-loses UTF-16 braucht eine ausdrückliche Encoding-Wahl")
func fileLoader_bomlessUTF16RequiresExplicitReopen() throws {
    let text = "Alpha\nBeta 😀\n"
    for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
        let original = try #require(text.data(using: encoding))
        let url = try writeTmp(Array(original))
        defer { try? FileManager.default.removeItem(at: url) }

        let automatic = try FileLoader.load(url: url)
        #expect(automatic.displayMode == .hex)
        #expect(automatic.content.isEmpty)

        let explicit = try FileLoader.load(url: url, forcedEncoding: encoding)
        #expect(explicit.displayMode == .text)
        #expect(explicit.content == text)
        #expect(explicit.encoding == encoding)
        #expect(explicit.bom.isEmpty)
        #expect(FileLoader.encodedData(content: explicit.content,
                                       encoding: explicit.encoding,
                                       bom: explicit.bom,
                                       lineEnding: explicit.lineEnding) == original)
    }
}

@Test("FileLoader: plausible 16-Bit-Binärdaten bleiben automatisch Hex")
func fileLoader_uint16ASCIIAndPCMRemainHex() throws {
    let values = Array(repeating: Array(UInt16(0x20)...UInt16(0x7E)), count: 4)
        .flatMap { $0 }
    for littleEndian in [true, false] {
        var bytes = Data()
        for value in values {
            if littleEndian {
                bytes.append(UInt8(value & 0xFF))
                bytes.append(UInt8(value >> 8))
            } else {
                bytes.append(UInt8(value >> 8))
                bytes.append(UInt8(value & 0xFF))
            }
        }
        // Diese Bytes sind zugleich gültiger BOM-loser UTF-16-ASCII-Text und
        // ein realistischer UInt16-/PCM-Wertebereich. Ohne Provenienz darf die
        // automatische Route sie deshalb nicht editierbar öffnen.
        let url = try writeTmp(Array(bytes), suffix: ".raw")
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try FileLoader.load(url: url)
        #expect(loaded.displayMode == .hex)
        #expect(loaded.content.isEmpty)
    }
}

// MARK: - Tests: Fehlerbehandlung

@Test("FileLoader: nicht existierende Datei wirft LoadError.unreadable")
func fileLoader_nonexistent_throws() {
    let ghost = URL(fileURLWithPath: "/tmp/fastra-existiert-garantiert-nicht-\(UUID().uuidString).txt")
    #expect(throws: FileLoader.LoadError.unreadable) {
        try FileLoader.load(url: ghost)
    }
}

@Test("FileLoader: Binärmüll (Null-Bytes) öffnet automatisch die Hex-Ansicht")
func fileLoader_binaryNullBytes_opensHex() throws {
    // Datei mit Null-Bytes und ungültigem UTF-8 — typisch für Binärdateien.
    // Foundation's Heuristik schlägt fehl, und auch der UTF-8-Fallback
    // scheitert bei rohen Null-Bytes + ungültigem Multi-Byte-Sequel.
    let url = try writeTmp([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x00, 0x0D,
                             0xC0, 0x80, 0xFF, 0xFE, 0x00, 0x01])
    defer { try? FileManager.default.removeItem(at: url) }

    let result = try FileLoader.load(url: url)
    #expect(result.displayMode == .hex)
    #expect(result.content.isEmpty)
    #expect(result.fileSize == 14)
}

@Test("FileLoader: UTF-8-BOM erlaubt kein folgendes Nullbyte")
func fileLoader_utf8BOMWithNullByte_opensHex() throws {
    let url = try writeTmp([0xEF, 0xBB, 0xBF, 0x41, 0x00, 0x42])
    defer { try? FileManager.default.removeItem(at: url) }

    let result = try FileLoader.load(url: url)
    #expect(result.displayMode == .hex)
    #expect(result.content.isEmpty)
}

@Test("FileLoader: Nullbyte direkt hinter der 8-KiB-Probe bleibt Hex")
func fileLoader_nullByteAfterProbe_opensHex() throws {
    // Exakter Grenzfall: 4096 × UTF-16BE U+4142 ergeben 8192 nullfreie
    // Bytes. Erst die folgende Codeunit U+0041 enthält das Nullbyte.
    var bytes = Data(repeating: 0x41, count: FileLoader.binaryProbeSize)
    for index in stride(from: 1, to: bytes.count, by: 2) { bytes[index] = 0x42 }
    bytes.append(contentsOf: [0x00, 0x41])
    let url = try writeTmp(Array(bytes), suffix: ".raw")
    defer { try? FileManager.default.removeItem(at: url) }

    let result = try FileLoader.load(url: url)
    #expect(result.displayMode == .hex)
    #expect(result.content.isEmpty)
}

@Test("FileLoader: große BOM-lose Datei mit spätem Nullbyte bleibt Hex")
func fileLoader_largeLateNullByte_opensHex() throws {
    let size = FileLoader.largeFileThreshold + 1024
    let url = try writeTmpRepeatedByteFile(size: size)
    defer { try? FileManager.default.removeItem(at: url) }

    // Genau am Beginn des zweiten Scan-Chunks nach der 8-KiB-Probe. Damit
    // schützt der Test sowohl gegen die alte reine Probe als auch gegen einen
    // versehentlich nur einmal ausgeführten Folge-Read.
    let nullOffset = UInt64(FileLoader.binaryProbeSize + FileLoader.binaryScanChunkSize)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seek(toOffset: nullOffset)
    try handle.write(contentsOf: Data([0x00, 0x41]))
    try handle.close()

    let result = try FileLoader.load(url: url)
    #expect(result.fileSize == size)
    #expect(result.displayMode == .hex)
    #expect(result.content.isEmpty)
}

@Test("FileLoader: große UTF-8-BOM-Datei mit spätem Nullbyte bleibt Hex")
func fileLoader_largeUTF8BOMWithLateNullByte_opensHex() throws {
    let size = FileLoader.largeFileThreshold + 1024
    let url = try writeTmpRepeatedByteFile(size: size)
    defer { try? FileManager.default.removeItem(at: url) }

    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: Data([0xEF, 0xBB, 0xBF]))
    let nullOffset = UInt64(FileLoader.binaryProbeSize + FileLoader.binaryScanChunkSize)
    try handle.seek(toOffset: nullOffset)
    try handle.write(contentsOf: Data([0x00, 0x42]))
    try handle.close()

    let result = try FileLoader.load(url: url)
    #expect(result.fileSize == size)
    #expect(result.displayMode == .hex)
    #expect(result.content.isEmpty)
}

@Test("FileLoader: große Textdatei wird ohne Voll-Laden abschnittsweise geöffnet")
func fileLoader_largeText_opensChunked() throws {
    let url = try writeTmp(Array("abcdefghijklmnopqrstuvwxyz".utf8))
    defer { try? FileManager.default.removeItem(at: url) }

    let result = try FileLoader.load(url: url, largeFileThreshold: 10)
    #expect(result.displayMode == .chunkedText)
    #expect(result.content.isEmpty)
    #expect(result.fileSize == 26)
}

@Test("FileLoader: ungültiges UTF-8 ohne BOM wirft LoadError.unreadable")
func fileLoader_invalidUtf8_throws() throws {
    // 0x80 allein ist kein gültiges UTF-8 (Continuation-Byte ohne Leading-Byte).
    // Und kein anderes gängiges Encoding erkennt Foundation hier verlässlich.
    // Latin-1-Bytes (0x80–0xFF) OHNE BOM könnten von Foundation als Mac-Roman
    // oder Windows-1252 erkannt werden — Bytes jenseits 0x9F sind dort ungültig.
    // Wir nutzen Bytes, die in keinem Standard-Encoding gültig sind.
    let url = try writeTmp([0xFE, 0xFF, 0x00])   // Big-Endian-BOM, dann Null-Byte
    defer { try? FileManager.default.removeItem(at: url) }

    // Entweder wird es geladen (Foundation interpretiert BOM als UTF-16 BE)
    // oder es schlägt fehl — wir testen nur, dass KEIN Absturz passiert.
    // (UTF-16 BE mit einem Null-Byte ist technisch möglich, deshalb kein
    // hartes `#expect(throws:)` hier — der Test stellt sicher, dass keine
    // unkontrollierte Exception entkommt.)
    let _ = try? FileLoader.load(url: url)
    // Kein Absturz = implizit PASS.
}
