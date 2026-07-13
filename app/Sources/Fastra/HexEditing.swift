//
// HexEditing.swift
//
// Sicherheitskern des optionalen Hex-Schreibmodus. Änderungen werden nicht
// direkt in die Datei geschrieben, sondern erst als Offsets gesammelt,
// sichtbar vorgeprüft und dann in einem atomaren Schritt gespeichert.

import Foundation

struct HexByteChange: Equatable, Identifiable {
    let offset: UInt64
    let oldValue: UInt8
    let newValue: UInt8
    var id: UInt64 { offset }

    var description: String {
        String(format: "%012llX   %02X → %02X", offset, oldValue, newValue)
    }
}

enum HexEditing {
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

    /// Schreibt ausschließlich die beabsichtigten Offsets, erst nachdem die
    /// komplette Originaldatei erneut gelesen wurde. Ein fehlerhafter Offset
    /// bricht vor dem Schreiben ab; `.atomic` verhindert halbfertige Dateien.
    func save(to url: URL) throws {
        let original = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let replacement = Dictionary(uniqueKeysWithValues: changes.map { ($0.key, $0.value.newValue) })
        guard let data = HexEditing.applying(replacement, to: original) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
        // `Data.write(.atomic)` ersetzt die Datei. Die Zugriffsrechte des
        // Originals werden danach bewusst wiederhergestellt, damit ein
        // Hex-Speichern nicht unbemerkt die Freigabe der Datei verändert.
        if let permissions = attributes[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        changes = [:]
    }

    func discard() { changes = [:]; invalidRowMessage = nil }
}
