import Foundation
import Testing
@testable import Fastra

@Suite("Sicherer Hex-Schreibmodus")
struct HexEditingTests {
    @Test("Eine Hex-Zeile akzeptiert nur vollständige Bytepaare")
    func rowValidation() {
        #expect(HexEditing.parseRow("0A FF 10", expectedBytes: 3) == [0x0A, 0xFF, 0x10])
        #expect(HexEditing.parseRow("A FF", expectedBytes: 2) == nil)
        #expect(HexEditing.parseRow("00 FF", expectedBytes: 3) == nil)
    }

    @Test("Änderungen berühren nur explizite Offsets")
    func appliesOnlyExplicitChanges() {
        let original = Data([0, 1, 2, 3])
        #expect(HexEditing.applying([1: 0xAA, 3: 0xBB], to: original) == Data([0, 0xAA, 2, 0xBB]))
        #expect(HexEditing.applying([4: 0xAA], to: original) == nil)
    }

    @Test("Session speichert atomar und leert die sichtbare Änderungsliste")
    @MainActor func sessionSave() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0, 1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = HexEditSession()
        session.editRow("00 FE 02 03", data: Data([0, 1, 2, 3]), baseOffset: 0, row: 0)
        #expect(session.preview == [HexByteChange(offset: 1, oldValue: 1, newValue: 0xFE)])
        try HexEditing.save(session.preview, to: url)
        session.markSaved()
        #expect(try Data(contentsOf: url) == Data([0, 0xFE, 2, 3]))
        #expect(session.hasChanges == false)
    }

    @Test("Ungültige Offsets lassen die Originaldatei unverändert")
    @MainActor func sessionRefusesOutOfBoundsSave() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = Data([0, 1, 2, 3])
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = HexEditSession()
        // Die sichtbare Seite kann bei zwischenzeitlich verkleinerter Datei
        // veraltet sein. Der endgültige Save liest deshalb erneut und lehnt
        // den Offset ab, statt einen Teilzustand zu schreiben.
        session.editRow("FF", data: Data([0]), baseOffset: 99, row: 0)
        #expect(throws: (any Error).self) { try HexEditing.save(session.preview, to: url) }
        #expect(try Data(contentsOf: url) == original)
        #expect(session.hasChanges)
    }

    @Test("Zwischen Vorschau und Speichern geänderte Bytes bleiben unangetastet")
    @MainActor func sessionRefusesChangedPreviewByte() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0, 1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = HexEditSession()
        session.editRow("00 FE 02 03", data: Data([0, 1, 2, 3]), baseOffset: 0, row: 0)

        // Ein anderes Programm ändert genau das Byte, das die sichtbare
        // Vorschau noch mit dem alten Wert 01 zeigt.
        let external = Data([0, 9, 2, 3])
        try external.write(to: url)

        #expect(throws: HexEditing.SaveError.self) {
            try HexEditing.save(session.preview, to: url)
        }
        #expect(try Data(contentsOf: url) == external)
        #expect(session.hasChanges)
    }

    @Test("Speichern erhält die Zugriffsrechte der Datei")
    @MainActor func sessionPreservesPermissions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0, 1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let session = HexEditSession()
        session.editRow("00 FE", data: Data([0, 1]), baseOffset: 0, row: 0)
        try HexEditing.save(session.preview, to: url)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o640)
    }

    @Test("applied(to:) überlagert genau die Änderungen des geladenen Abschnitts")
    @MainActor func appliedOverlay() {
        let session = HexEditSession()
        let data = Data([0x00, 0x11, 0x22, 0x33])
        // Byte 0 des Abschnitts bei Basisadresse 0x10 ändern.
        session.editRow("FF 11 22 33", data: data, baseOffset: 0x10, row: 0)
        // `applied` ist die EINE Bytequelle für schreibgeschützte Anzeige und
        // Drucksnapshot: Beide müssen dieselben effektiven Bytes zeigen
        // (Reviewfund 2026-08-18).
        #expect(session.applied(to: data, baseOffset: 0x10)
                == Data([0xFF, 0x11, 0x22, 0x33]))
        // Ein anderer Abschnitt (andere Basisadresse) bleibt unberührt.
        #expect(session.applied(to: data, baseOffset: 0x40) == data)
    }

    @Test("Große Hex-Datei wird über Abschnittsgrenzen bytegenau geändert")
    func saveStreamsAcrossChunkBoundaries() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let size = HexEditing.saveChunkSize * 2 + 17
        let original = Data(repeating: 0x41, count: size)
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let offsets = [0, HexEditing.saveChunkSize - 1,
                       HexEditing.saveChunkSize, size - 1]
        let changes = offsets.map {
            HexByteChange(offset: UInt64($0), oldValue: 0x41, newValue: 0x5A)
        }

        try HexEditing.save(changes, to: url)

        let saved = try Data(contentsOf: url)
        #expect(saved.count == original.count)
        #expect(offsets.allSatisfy { saved[$0] == 0x5A })
        #expect(saved.enumerated().allSatisfy { index, byte in
            offsets.contains(index) ? byte == 0x5A : byte == 0x41
        })
    }
}
