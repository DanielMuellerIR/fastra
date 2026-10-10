import Foundation
import Darwin
import Testing
@testable import Fastra

@Suite("Markdown-Speichern-unter")
struct MarkdownSaveAsTests {
    private func fixture() throws -> (URL, URL, URL) {
        let root = testTemporaryDirectory().appendingPathComponent("fastra-save-images-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source/protocol.md")
        let target = root.appendingPathComponent("target/copy.md")
        for directory in [source.deletingLastPathComponent(), target.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("images"), withIntermediateDirectories: true)
        }
        return (root, source, target)
    }

    @Test("Nur benutzte Bilder mitkopieren; Codebeispiele und fremde Protokolle auslassen")
    func copyOnlyUsedImages() throws {
        let (root, source, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["first.png", "unused.png", "other.png"] {
            try Data(name.utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("images/\(name)"))
        }
        let content = "# 😀 Protokoll\n\n![Ergebnis][bild]\n\n[bild]: images/first.png \"Ergebnis\"\n[unbenutzt]: images/unused.png\n\n```md\n![anderes](images/other.png)\n```\n"
        let prepared = try MarkdownSaveAs.prepare(content: content, sourceURL: source, targetURL: target)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().appendingPathComponent("images").path) == ["1.png"])
        #expect(try Data(contentsOf: target.deletingLastPathComponent().appendingPathComponent("images/1.png")) == Data("first.png".utf8))
        #expect(prepared.content.contains("![Ergebnis](images/1.png \"Ergebnis\")"))
        #expect(prepared.content.contains("![anderes](images/other.png)"))
        #expect(prepared.content.contains("[unbenutzt]: images/unused.png"))
        #expect(prepared.createdImages.count == 1)
    }

    @Test("Kollisionen am Ziel bewahren fremde Dateien und passen jede Referenz an", arguments: ["\n", "\r\n", "\r"])
    func collision(_ eol: String) throws {
        let (root, source, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("original".utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("images/a%23.png"))
        let existing = target.deletingLastPathComponent().appendingPathComponent("images/1.png")
        try Data("foreign".utf8).write(to: existing)
        let markdown = "# 😀\(eol)\(eol)![A](images/a%2523.png)\(eol)\(eol)![B](images/a%2523.png)\(eol)"
        let prepared = try MarkdownSaveAs.prepare(content: markdown, sourceURL: source, targetURL: target)
        #expect(prepared.content.contains("![A](images/2.png)"))
        #expect(prepared.content.contains("![B](images/2.png)"))
        #expect(prepared.createdImages.count == 1)
        #expect(try Data(contentsOf: existing) == Data("foreign".utf8))
        prepared.rollback()
        #expect(!FileManager.default.fileExists(atPath: target.deletingLastPathComponent().appendingPathComponent("images/2.png").path))
        #expect(FileManager.default.fileExists(atPath: existing.path))
    }

    @Test("Formelgrenzen erhalten sichtbare Bilder bei allen Zeilenenden", arguments: ["\n", "\r\n", "\r"])
    func formulaLineEndings(_ eol: String) throws {
        let (root, source, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("image".utf8)
        try bytes.write(to: source.deletingLastPathComponent().appendingPathComponent("images/1.png"))
        let content = "one $a\(eol)![A](images/1.png)\(eol)b$ end"
        #expect(MarkdownVisualDocument.render(content, documentURL: source).fragment.imageURLs.count == 1)
        let prepared = try MarkdownSaveAs.prepare(content: content, sourceURL: source, targetURL: target)
        defer { prepared.rollback() }
        #expect(prepared.createdImages.count == 1)
        #expect(prepared.content == content)
        #expect(try Data(contentsOf: target.deletingLastPathComponent().appendingPathComponent("images/1.png")) == bytes)
        let images = try MarkdownSaveAs.clipboardImages(content: content, sourceURL: source)
        try FileManager.default.removeItem(at: source.deletingLastPathComponent().appendingPathComponent("images/1.png"))
        let pasted = try MarkdownSaveAs.prepare(content: content, sourceURL: source, targetURL: target, copyImagesInSameDirectory: true, imageData: images)
        defer { pasted.rollback() }
        #expect(pasted.createdImages.count == 1)
        #expect(pasted.content == content.replacingOccurrences(of: "images/1.png", with: "images/2.png"))
    }

    @Test("Formelbereiche bilden CRLF und Unicode auf Originalpositionen ab", arguments: ["\n", "\r\n", "\r"])
    func formulaOriginalOffsets(_ eol: String) {
        let formula = "$$\(eol)x\(eol)$$"
        let content = "😀\(eol)\(eol)" + formula + "\(eol)\(eol)Ende"
        let ranges = MarkdownMath.formulaRanges(in: content)
        #expect(ranges.count == 1)
        #expect(ranges.map { (content as NSString).substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines) } == [formula])
        #expect(MarkdownMath.formulaRanges(in: "```\(eol)" + formula + "\(eol)```").isEmpty)
    }

    @Test("Eine benannte Pipe wird ohne Schreiber unmittelbar abgelehnt")
    func namedPipeImage() throws {
        let (root, source, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipe = source.deletingLastPathComponent().appendingPathComponent("images/fifo.png")
        try #require(mkfifo(pipe.path, 0o600) == 0)
        #expect(throws: MarkdownImageStore.StoreError.unreadableImage) {
            try MarkdownSaveAs.prepare(content: "![A](images/fifo.png)", sourceURL: source, targetURL: target)
        }
    }

    @Test("Fehlendes benötigtes Bild bricht ohne liegengebliebene Kopien ab")
    func missingImageRollsBack() throws {
        let (root, source, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one".utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("images/one.png"))
        #expect(throws: (any Error).self) {
            try MarkdownSaveAs.prepare(content: "![1](images/one.png)\n\n![2](images/missing.png)", sourceURL: source, targetURL: target)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().appendingPathComponent("images").path).isEmpty)
    }
    @Test("Bildspalten bleiben neben Formeln und in verschachtelten Alt-Texten korrekt", arguments: [
        "Vorher $x$ ![Bild](images/a.png) danach",
        "![outer ![inner](images/veryverylonginnername.png)](images/a.png)",
        "![Formel $x$](images/a.png)"
    ])
    func parserPositions(_ content: String) throws {
        let (root, source, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one".utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("images/a.png"))
        let prepared = try MarkdownSaveAs.prepare(content: content, sourceURL: source, targetURL: target)
        #expect(prepared.content.hasSuffix(content.hasSuffix("danach") ? " danach" : ")"))
        #expect(prepared.content.contains("images/1.png"))
        #expect(prepared.createdImages.count == 1)
        if content.hasPrefix("Vorher") { #expect(prepared.content == "Vorher $x$ ![Bild](images/1.png) danach") }
        prepared.commit()
    }

    @Test("HTML-Bildspalten erhalten echte Zeilenenden; Kommentare sind keine Bilder", arguments: ["\n", "\r\n", "\r"])
    func htmlImages(_ eol: String) throws {
        let (root, source, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one".utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("images/a.png"))
        let content = "<div>\(eol)<img src=\"images/a.png\">\(eol)<!-- src=\"images/missing.png\" -->\(eol)</div>\(eol)"
        let prepared = try MarkdownSaveAs.prepare(content: content, sourceURL: source, targetURL: target)
        #expect(prepared.content == content.replacingOccurrences(of: "images/a.png", with: "images/1.png"))
        prepared.commit()
    }

    @Test("Eine abgebrochene Vorbereitung löscht kein Bild einer zweiten Speicherung")
    func simultaneousPreparations() throws {
        let (root, source, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one".utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("images/a.png"))
        let first = try MarkdownSaveAs.prepare(content: "![A](images/a.png)", sourceURL: source, targetURL: target)
        let second = try MarkdownSaveAs.prepare(content: "![B](images/a.png)", sourceURL: source, targetURL: target)
        second.commit()
        first.rollback()
        let file = try #require(second.createdImages.first?.fileURL)
        #expect(try Data(contentsOf: file) == Data("one".utf8))
    }

    @Test("Unicode-Zeilentrenner verschieben keine Bildreferenz", arguments: ["\n", "\r\n", "\r"])
    func unicodeSeparators(_ eol: String) throws {
        let (root, source, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one".utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("images/a.png"))
        let content = "prefix\u{2028}😀\u{2029}\u{0085}![A](images/a.png) suffix\(eol)\(eol)Ende\(eol)"
        let prepared = try MarkdownSaveAs.prepare(content: content, sourceURL: source, targetURL: target)
        defer { prepared.rollback() }
        #expect(prepared.content == content.replacingOccurrences(of: "images/a.png", with: "images/1.png"))
        #expect(prepared.createdImages.count == 1)
    }

    @Test("HTML-Bilder in Formeln bleiben unverändert", arguments: [false, true])
    func formulaImages(_ exists: Bool) throws {
        let (root, source, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        if exists {
            try Data("formula".utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("images/formula.png"))
        }
        try Data("real".utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("images/real.png"))
        for content in [
            "$x + <img src=\"images/formula.png\">$",
            "$$\nx + <img src=\"images/formula.png\">\n$$",
            "<div>\n$x + <img src=\"images/formula.png\">$\n<img src=\"images/real.png\">\n</div>\n",
            "<div>\n$$\nx + <img src=\"images/formula.png\">\n$$\n<img src=\"images/real.png\">\n</div>\n"
        ] {
            let prepared = try MarkdownSaveAs.prepare(content: content, sourceURL: source, targetURL: target)
            #expect(prepared.content == content.replacingOccurrences(of: "images/real.png", with: "images/1.png"))
            #expect(prepared.createdImages.count == (content.contains("images/real.png") ? 1 : 0))
            prepared.rollback()
        }
    }

    @Test("Bildtitel und Alt-Text dürfen dem internen Platzhalter gleichen", arguments: [
        "FASTRA_IMAGE_DESTINATION_TOKEN", "&#70;ASTRA_IMAGE_DESTINATION_TOKEN",
        "FASTRA_IMAGE_DESTINATION_TOKEN_"
    ])
    func destinationTokenInTitle(_ title: String) throws {
        let (root, source, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one".utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("images/a.png"))
        let content = "![FASTRA_IMAGE_DESTINATION_TOKEN](images/a.png \"\(title)\")"
        let prepared = try MarkdownSaveAs.prepare(content: content, sourceURL: source, targetURL: target)
        defer { prepared.rollback() }
        let expectedTitle = title.replacingOccurrences(of: "&#70;", with: "F")
        #expect(prepared.content.contains("(images/1.png \"\(expectedTitle)\")"))
        #expect(MarkdownRichText.htmlFragment(markdown: prepared.content).contains("alt=\"FASTRA_IMAGE_DESTINATION_TOKEN\""))
    }

    @Test("Nach einem echten Dateicommit bleiben Bilder trotz neuer Tabänderung erhalten")
    @MainActor
    func changedAfterCommit() async throws {
        let (root, source, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = "![A](images/a.png)"
        try content.write(to: source, atomically: true, encoding: .utf8)
        try "old".write(to: target, atomically: true, encoding: .utf8)
        try Data("one".utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("images/a.png"))
        let ws = Workspace()
        var tab = EditorTab(title: "protocol.md", path: source.path, content: content)
        tab.url = source
        ws.tabs = [tab]; ws.activeTabID = tab.id
        ws.saveSafetyWarningHandler = { _, _ in }
        ws.saveBeforeAtomicReplaceHandler = { _ in ws.activeTabContent.wrappedValue += " neu" }
        var completed: Bool?
        ws.saveTabAs(id: tab.id, to: target, expectedTargetState: .present(try FileSnapshot.read(from: target).snapshot),
                     isMarkdown: true) { completed = $0 }
        try #require(await waitUntil { completed != nil })
        #expect(completed == false)
        #expect(try String(contentsOf: target, encoding: .utf8).contains("images/1.png"))
        #expect(FileManager.default.fileExists(atPath: target.deletingLastPathComponent().appendingPathComponent("images/1.png").path))
        #expect(ws.activeTab?.content.hasSuffix(" neu") == true)
        #expect(ws.activeTab?.isDirty == true)
    }

}
