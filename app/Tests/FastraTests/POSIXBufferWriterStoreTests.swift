import Foundation
import Testing
@testable import Fastra

@Test("Eine Bildkopie unter 64 KiB schreibt nur die tatsächlich gelesenen Bytes")
func imageCopyWritesOnlyReadPrefix() throws {
    let directory = testTemporaryDirectory().appendingPathComponent(
        "fastra-image-copy-prefix-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.png")
    let documentURL = directory.appendingPathComponent("document.md")
    let source = Data((0..<257).map { UInt8($0 % 251) })
    try source.write(to: sourceURL)

    let stored = try MarkdownImageStore.storeImageFile(sourceURL, documentURL: documentURL)

    #expect(try Data(contentsOf: stored.fileURL) == source)
    #expect(stored.identity.size == Int64(source.count))
    #expect(try Data(contentsOf: sourceURL) == source)
}
