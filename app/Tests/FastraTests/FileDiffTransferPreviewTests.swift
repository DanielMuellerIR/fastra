import Foundation
import Testing
@testable import Fastra

@Suite("Dateibasis und genaue Übernahmevorschau")
struct FileDiffTransferPreviewTests {
    @Test("Kopierte Terminatoren und Unicode-Zeichen erscheinen in der genauen Vorschau")
    func exactPreview() throws {
        let left = "one\r\nold\r\nend\r\n", right = "one\n🙂 new\nend\n"
        let request = FileDiffRequest(left: .text(left, name: "left"), right: .text(right, name: "right"), options: FileDiffOptions())
        let document = Workspace.computeFileDiffDocument(request: request)
        let preview = try FileDiffTransferPreview.prepare(tabID: UUID(), requestID: request.id, direction: .toLeft,
            blockID: 0, targetName: "left", document: document)
        #expect(preview.change.output == "one\r\n🙂 new\nend\r\n")
        #expect(preview.hasAnnotations)
        let rows = try #require(preview.document.result?.rows)
        #expect(rows.contains { $0.before?.contains("CRLF") == true && $0.after?.contains("LF") == true })
        #expect(rows.contains { $0.after?.contains("1F642") == true })
    }

    @Test("Nach der Vorschau geänderte oder gewachsene Dateien geben keinen Apply-Auftrag frei", arguments: [false, true])
    func changedFile(_ grows: Bool) throws {
        let root = testTemporaryDirectory().appendingPathComponent("fastra-diff-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.txt")
        let bytes = try #require(FileLoader.encodedData(content: "new\n", encoding: .utf16LittleEndian,
            bom: Data([0xff, 0xfe]), lineEnding: .lf))
        try bytes.write(to: file)
        let request = FileDiffRequest(left: .text("old\n", name: "target"), right: .file(file), options: FileDiffOptions())
        let document = Workspace.computeFileDiffDocument(request: request)
        #expect(document.rightSource?.snapshot != nil)
        let preview = try FileDiffTransferPreview.prepare(tabID: UUID(), requestID: request.id, direction: .toLeft,
            blockID: 0, targetName: "target", document: document)
        #expect(preview.change.output == "new\n")
        _ = try preview.validateForApply()
        if grows {
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: FileLoader.largeFileThreshold + 1)
            try handle.close()
        } else {
            try Data(repeating: 0x41, count: bytes.count).write(to: file)
        }
        #expect(throws: FileDiffTransfer.Failure.stale) { try preview.validateForApply() }
    }

    @Test("Schreibgeschützte externe Quellen dürfen gelesen, aber nicht verändert werden")
    func readOnlyFile() throws {
        let root = testTemporaryDirectory().appendingPathComponent("fastra-diff-readonly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("source.txt"), bytes = Data("new\n".utf8)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: root)
        }
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        let request = FileDiffRequest(left: .text("old\n", name: "target"), right: .file(file), options: FileDiffOptions())
        let preview = try FileDiffTransferPreview.prepare(tabID: UUID(), requestID: request.id, direction: .toLeft,
            blockID: 0, targetName: "target", document: Workspace.computeFileDiffDocument(request: request))
        _ = try preview.validateForApply()
        #expect(preview.change.output == "new\n")
        #expect(try Data(contentsOf: file) == bytes)
    }
}
