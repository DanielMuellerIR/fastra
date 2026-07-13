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
        try session.save(to: url)
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
        #expect(throws: (any Error).self) { try session.save(to: url) }
        #expect(try Data(contentsOf: url) == original)
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
        try session.save(to: url)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o640)
    }
}
