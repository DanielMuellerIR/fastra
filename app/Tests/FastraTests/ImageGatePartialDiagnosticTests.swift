import Foundation
import Testing
@testable import Fastra

@Suite
struct ImageGatePartialDiagnosticTests {
    @Test("Mehrbild-Teilfehler bleibt nach Gateablehnung und positivem Schutz sichtbar")
    func previousPartialFailureAfterRejectedGate() throws {
        let directory = testTemporaryDirectory().appendingPathComponent("image-gate-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = directory.appendingPathComponent("note.md")
        try Data().write(to: document)
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII=")!
        let first = try MarkdownImageStore.storePastedData(.init(data: bytes, fileExtension: "png"), documentURL: document)
        let second = try MarkdownImageStore.storePastedData(.init(data: bytes, fileExtension: "png"), documentURL: document)
        let effect = MarkdownImageUndoSideEffect(images: [first, second],
            removalHooks: .init(beforeUnlink: { index in if index == 1 { throw POSIXError(.EIO) } }))
        defer {
            effect.discard()
            try? FileManager.default.removeItem(at: directory)
        }
        // Echter erster Dateifortschritt: erstes Bild entfernt, zweites nach EIO zurückgestellt.
        effect.discard(unusedBy: [])
        let eio = POSIXError(.EIO).localizedDescription
        let initial = try #require(effect.removalFailureDescription)
        try #require(initial.contains(eio))
        try #require(!FileManager.default.fileExists(atPath: first.fileURL.path))
        try #require(try Data(contentsOf: second.fileURL) == bytes)
        print("IMAGE_GATE_PARTIAL phase=first eio=1 removed_first=1 retained_second=1")

        // Nächste Entnahme wird vor Claims abgewiesen. Der letzte Resultwert wird ersetzt.
        effect.discard(unusedBy: [], gate: { _ in false })
        let afterGate = try #require(effect.removalFailureDescription)
        try #require(afterGate.contains(POSIXError(.ECANCELED).localizedDescription))
        print("IMAGE_GATE_PARTIAL phase=after_gate eio=\(afterGate.contains(eio) ? 1 : 0)")
        // Ein neuer gültiger Bildverweis macht weitere Entnahme unnötig.
        effect.discard(unusedBy: [second.fileURL.canonicalFileURL])
        let final = try #require(effect.removalFailureDescription)
        #expect(final.contains(eio), "Früherer echter EIO wurde vor dem positiven Referenzschutz überschrieben.")
        #expect(final.contains(first.fileURL.path), "Der frühere entfernte Bildpfad ging im neuesten Gatebefund verloren.")
        #expect(!FileManager.default.fileExists(atPath: first.fileURL.path))
        #expect(try Data(contentsOf: second.fileURL) == bytes)
        print("IMAGE_GATE_PARTIAL phase=protected eio=\(final.contains(eio) ? 1 : 0) final=\(final)")
    }
}
