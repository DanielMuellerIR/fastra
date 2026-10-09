import AppKit
import Testing
@testable import Fastra

@Suite("Markdown-Bilder in der Zwischenablage", .serialized)
struct MarkdownClipboardImageReviewTests {
    private func fixture() throws -> (URL, Data, String) {
        let root = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aU1cAAAAASUVORK5CYII=")!
        let file = root.appendingPathComponent("image.png")
        try data.write(to: file)
        return (file, data, "<p>A<img src=\"fastra-preview://image/test\" alt=\"Bild\">B</p>")
    }

    @Test("HTML enthält eigene Bytes und RTFD ein echtes Bildattachment")
    @MainActor
    func transport() async throws {
        let (file, bytes, html) = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let type = NSPasteboard.PasteboardType("application/x-test-markdown")
        MarkdownPasteboard.write(plain: "AB", htmlFragment: html, to: pb, imageURLs: ["test": file], additionalData: [type: Data("markdown".utf8)])
        try #require(await waitUntil { pb.data(forType: .rtfd) != nil })
        let output = try #require(pb.string(forType: .html))
        #expect(output.contains("data:image/png;base64," + bytes.base64EncodedString()))
        #expect(!output.contains("fastra-preview:"))
        #expect(pb.data(forType: type) == Data("markdown".utf8))
        let rtfd = try #require(pb.data(forType: .rtfd))
        let value = try NSAttributedString(data: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        var found: Data?
        value.enumerateAttribute(.attachment, in: NSRange(location: 0, length: value.length)) { attachment, _, _ in
            if let attachment = attachment as? NSTextAttachment { found = attachment.fileWrapper?.regularFileContents }
        }
        #expect(found == bytes)
    }

    @Test("Bildquelle im Alt-Text wird übersprungen")
    func quotedSourceInAlt() throws {
        let (file, bytes, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let html = "<img alt=\"Beispiel src='fake.png'\" src=\"fastra-preview://image/test\">"
        let transport = MarkdownClipboardImages.prepare(html, imageURLs: ["test": file], loadImages: true)
        #expect(transport.attachments.count == 1)
        #expect(transport.html.contains("data:image/png;base64," + bytes.base64EncodedString()))
        #expect(transport.html.contains("Beispiel src='fake.png'"))
    }

    @Test("Hintergrundexport überschreibt keine neue Zwischenablage")
    @MainActor
    func changedClipboard() async throws {
        let (file, _, html) = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        MarkdownPasteboard.write(plain: "AB", htmlFragment: html, to: pb, imageURLs: ["test": file])
        pb.clearContents(); pb.setString("Neu", forType: .string)
        try await Task.sleep(for: .milliseconds(500))
        #expect(pb.string(forType: .string) == "Neu")
        #expect(pb.data(forType: .rtfd) == nil)
    }

    @Test("Unbekannte und zu große Bilddateien verlassen die App nicht")
    func boundedImages() throws {
        let (file, _, html) = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let missing = MarkdownClipboardImages.prepare(html, imageURLs: [:], loadImages: true)
        #expect(missing.attachments.isEmpty && !missing.html.contains("fastra-preview:"))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(MarkdownPreviewAssets.maximumImageBytes + 1))
        try handle.close()
        let huge = MarkdownClipboardImages.prepare(html, imageURLs: ["test": file], loadImages: true)
        #expect(huge.attachments.isEmpty && !huge.html.contains("data:"))
    }
}
