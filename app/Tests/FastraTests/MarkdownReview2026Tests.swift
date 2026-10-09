import Foundation
import Testing
@testable import Fastra

@Suite("Markdown: Texttreue im Review 2026-10-09")
struct MarkdownReview2026Tests {
    @Test("HTML-Attribute lösen Entities genau einmal und vor der URL-Prüfung auf")
    func entities() {
        var sanitizer = MarkdownHTMLWhitelist.Sanitizer()
        #expect(sanitizer.sanitize("<img src=\"a&amp;b.png\" alt=\"A &amp; B&#x21;\">") == "<img src=\"a&amp;b.png\" alt=\"A &amp; B!\">")
        var unsafe = MarkdownHTMLWhitelist.Sanitizer()
        #expect(!unsafe.sanitize("<a href=\"javascript&#58;alert(1)\">X</a>").contains("href"))
        #expect(MarkdownHTMLEntities.decode("&copy; &#x1f600; &amp;copy;") == "© 😀 &copy;")
    }

    @Test("Wörtliche interne Token werden nicht als Formel oder Code ersetzt")
    func tokens() {
        let html = MarkdownRichText.htmlFragment(markdown: "FASTRAMATH0TOKEN $x$ FASTRACODESPAN0TOKEN `x`\n")
        #expect(html.contains("FASTRAMATH0TOKEN"))
        #expect(html.contains("FASTRACODESPAN0TOKEN"))
        #expect(html.components(separatedBy: "data-tex=").count == 2)
        #expect(html.components(separatedBy: "<code>").count == 2)
    }

    @Test("Speichern unter erkennt src nur als echtes Attribut, auch hinter > im Alt-Text")
    func sourceAttribute() throws {
        let root = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/a.md"), target = root.appendingPathComponent("target/b.md")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent().appendingPathComponent("images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("real".utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("images/a&b.png"))
        let content = "<img alt='Beispiel > src=\"images/missing.png\"' src=\"images/a&amp;b.png\">\n"
        let prepared = try MarkdownSaveAs.prepare(content: content, sourceURL: source, targetURL: target)
        #expect(prepared.createdImages.count == 1)
        #expect(prepared.content.contains("src=\"images/missing.png\""))
        #expect(prepared.content.contains("src=\"images/1.png\""))
        #expect(try Data(contentsOf: target.deletingLastPathComponent().appendingPathComponent("images/1.png")) == Data("real".utf8))
    }
}
