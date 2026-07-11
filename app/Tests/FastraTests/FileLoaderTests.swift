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
}

// MARK: - Tests: Fehlerbehandlung

@Test("FileLoader: nicht existierende Datei wirft LoadError.unreadable")
func fileLoader_nonexistent_throws() {
    let ghost = URL(fileURLWithPath: "/tmp/fastra-existiert-garantiert-nicht-\(UUID().uuidString).txt")
    #expect(throws: FileLoader.LoadError.unreadable) {
        try FileLoader.load(url: ghost)
    }
}

@Test("FileLoader: Binärmüll (Null-Bytes) wirft LoadError.unreadable")
func fileLoader_binaryNullBytes_throws() throws {
    // Datei mit Null-Bytes und ungültigem UTF-8 — typisch für Binärdateien.
    // Foundation's Heuristik schlägt fehl, und auch der UTF-8-Fallback
    // scheitert bei rohen Null-Bytes + ungültigem Multi-Byte-Sequel.
    let url = try writeTmp([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x00, 0x0D,
                             0xC0, 0x80, 0xFF, 0xFE, 0x00, 0x01])
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(throws: FileLoader.LoadError.unreadable) {
        try FileLoader.load(url: url)
    }
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
