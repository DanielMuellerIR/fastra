// TestCorpus.swift
//
// Fester Test-Korpus für die Apply-Sicherheitstests (v0.6). Erzeugt eine
// reproduzierbare Sammlung von Dateien in einem temporären Verzeichnis:
// verschiedene Encodings, Line-Endings und ein paar Binärdateien dazwischen.
//
// Dieser Korpus ist die Grundlage für das harte Apply-Gate (siehe AGENTS.md):
// Byte-Vergleich Input↔Erwartet, „außerhalb des Scope unverändert", atomare
// Writes, Binär-Übersprung, bit-exaktes Undo. Die Apply-Logik selbst kommt
// erst, wenn diese Tests stehen.

import Foundation

/// Beschreibt eine erzeugte Korpus-Datei und ihre erwarteten Eigenschaften.
struct CorpusFile {
    let url: URL
    let isBinary: Bool
    /// Erwartetes Encoding (nur für Textdateien sinnvoll).
    let encoding: String.Encoding?
    /// Roh-Bytes, wie auf die Platte geschrieben — für Byte-Vergleiche.
    let bytes: Data
}

/// Erzeugt und räumt einen Test-Korpus auf. Eine Instanz = ein temporäres
/// Verzeichnis; `cleanup()` (oder deinit) löscht es wieder.
final class TestCorpus {
    let root: URL
    private(set) var files: [CorpusFile] = []

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-corpus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try build()
    }

    deinit { cleanup() }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Alle Textdateien (für Such-/Replace-Tests).
    var textFiles: [CorpusFile] { files.filter { !$0.isBinary } }
    /// Alle Binärdateien (müssen übersprungen werden).
    var binaryFiles: [CorpusFile] { files.filter { $0.isBinary } }

    private func build() throws {
        // 1. UTF-8, LF
        try addText("utf8-lf.txt",
                    content: "Zeile A\nZeile B\nkunde@example.com\n",
                    encoding: .utf8)
        // 2. UTF-8, CRLF
        try addText("utf8-crlf.txt",
                    content: "Eins\r\nZwei\r\nDrei\r\n",
                    encoding: .utf8)
        // 3. UTF-8, CR (alt-Mac)
        try addText("utf8-cr.txt",
                    content: "alpha\rbeta\rgamma\r",
                    encoding: .utf8)
        // 4. Latin-1 (ISO-8859-1) mit Umlauten
        try addText("latin1.txt",
                    content: "Grüße aus München - Café\n",
                    encoding: .isoLatin1)
        // 5. UTF-16 LE mit BOM (enthält Null-Bytes → fordert die
        //    Encoding-Erkennung VOR der Binär-Heuristik)
        try addText("utf16le.txt",
                    content: "Hallo Welt\nasdf\n",
                    encoding: .utf16LittleEndian, prependBOM: [0xFF, 0xFE])
        // 6. Windows-1252
        try addText("win1252.txt",
                    content: "Anführungszeichen „test“\n",
                    encoding: .windowsCP1252)
        // 7. Leere Datei
        try addRaw("empty.txt", bytes: Data(), isBinary: false, encoding: .utf8)
        // 8. Großzeilig / viele Treffer (für Replace-Mengentests)
        try addText("many.txt",
                    content: String(repeating: "foo bar foo\n", count: 50),
                    encoding: .utf8)
        // 9. Binär: PNG-Header + Null-Bytes
        try addRaw("image.bin",
                   bytes: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                                0x00, 0x00, 0x00, 0x0D]),
                   isBinary: true, encoding: nil)
        // 10. Binär: Null-Byte mitten im sonst lesbaren Text
        try addRaw("mixed.bin",
                   bytes: Data("text\u{0000}mehr text".utf8),
                   isBinary: true, encoding: nil)
    }

    private func addText(_ name: String, content: String, encoding: String.Encoding,
                         prependBOM bom: [UInt8] = []) throws {
        guard let body = content.data(using: encoding) else {
            throw CorpusError.encodingFailed(name)
        }
        var data = Data(bom)
        data.append(body)
        try addRaw(name, bytes: data, isBinary: false, encoding: encoding)
    }

    private func addRaw(_ name: String, bytes: Data, isBinary: Bool, encoding: String.Encoding?) throws {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        files.append(CorpusFile(url: url, isBinary: isBinary, encoding: encoding, bytes: bytes))
    }

    enum CorpusError: Error { case encodingFailed(String) }
}
