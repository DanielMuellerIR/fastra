import AppKit
import Testing
@testable import Fastra

@Suite("Markdown-Rich-Text")
struct MarkdownRichTextTests {
    @Test("GFM wird mit Codex-naher Hell- und Dunkelpalette gerendert")
    func htmlDocumentContainsFormattingAndPalette() {
        let markdown = """
        # Titel

        Text mit **Fettung**, ~~Streichung~~ und `Code`.

        | Spalte A | Spalte B |
        | --- | --- |
        | Eins | Zwei |
        """
        let light = MarkdownRichText.htmlDocument(
            markdown: markdown,
            fontName: PreviewFonts.systemName,
            fontSize: 14,
            darkMode: false
        )
        let dark = MarkdownRichText.htmlDocument(
            markdown: markdown,
            fontName: PreviewFonts.systemName,
            fontSize: 14,
            darkMode: true
        )

        #expect(light.contains("<h1>Titel</h1>"))
        #expect(light.contains("<strong>Fettung</strong>"))
        #expect(light.contains("<del>Streichung</del>"))
        #expect(light.contains("<table>"))
        #expect(light.contains("#FFFFFF"))
        #expect(dark.contains("#171717"))
    }

    @Test("Remote-Bilder lösen beim Anzeigen keinen Netzverkehr aus")
    func remoteImagesAreNeutralized() {
        let fragment = MarkdownRichText.htmlFragment(
            markdown: "![Beschreibung](https://example.com/bild.png)"
        )

        #expect(fragment.contains("<img"))
        #expect(fragment.contains("src=\"\""))
        #expect(!fragment.contains("src=\"https://"))
    }

    @Test("Lokale Bilder werden relativ zur Markdown-Datei sicher aufgelöst")
    func localImagesUseOpaquePreviewURLs() {
        let documentURL = URL(fileURLWithPath: "/tmp/Fastra Handbuch/README.md")
        let fragment = MarkdownRichText.renderedFragment(
            markdown: "![Fenster](screenshots/editor%20light.png)",
            documentURL: documentURL
        )

        #expect(fragment.html.contains("src=\"fastra-preview://image/image-0\""))
        #expect(fragment.imageURLs["image-0"]?.path ==
                "/tmp/Fastra Handbuch/screenshots/editor light.png")
        #expect(!fragment.html.contains("/tmp/Fastra"))
    }

    @Test("Nichtlokale und nicht unterstützte Bildquellen bleiben gesperrt",
          arguments: [
            "//example.com/bild.png",
            "file:///tmp/bild.png",
            "/tmp/bild.png",
            "javascript:alert(1)",
            "grafik.svg"
          ])
    func unsupportedImageSourcesStayBlocked(source: String) {
        let fragment = MarkdownRichText.renderedFragment(
            markdown: "![Bild](\(source))",
            documentURL: URL(fileURLWithPath: "/tmp/README.md")
        )

        #expect(fragment.imageURLs.isEmpty)
        #expect(!fragment.html.contains("fastra-preview://image/"))
    }

    @Test("Inline- und Blockformeln werden zu lokalen KaTeX-Zielen")
    func formulasBecomeSafeRenderTargets() {
        let fragment = MarkdownRichText.htmlFragment(markdown: """
        Inline $x^2 + y^2$.

        $$
        a = \\sqrt{b^2 + c^2}
        $$
        """)

        #expect(fragment.contains("class=\"math-inline\""))
        #expect(fragment.contains("data-tex=\"x^2 + y^2\""))
        #expect(fragment.contains("class=\"math-block\""))
        #expect(fragment.contains(#"data-tex="a = \sqrt{b^2 + c^2}""#))
        #expect(!fragment.contains("<p><div class=\"math-block\""))
    }

    @Test("Währungen und Dollarzeichen in Code werden nicht als Formel behandelt")
    func currencyAndCodeStayLiteral() {
        let fragment = MarkdownRichText.htmlFragment(markdown: """
        Das kostet $5 und $10 zusammen. Nutze `echo $HOME`.

        ```bash
        echo $PATH
        ```
        """)

        #expect(!fragment.contains("data-tex"))
        #expect(fragment.contains("echo $HOME"))
        #expect(fragment.contains("echo $PATH"))
    }

    @Test("Mermaid-Fences und lokale Renderbibliotheken sind verdrahtet")
    func mermaidAndOfflineLibrariesAreWired() {
        let document = MarkdownRichText.htmlDocument(
            markdown: """
            ```mermaid
            flowchart LR
              A --> B
            ```
            """,
            fontName: PreviewFonts.systemName,
            fontSize: 14,
            darkMode: false
        )

        #expect(document.contains("language-mermaid"))
        #expect(document.contains("fastra-preview://resource/katex.js"))
        #expect(document.contains("fastra-preview://resource/highlight.js"))
        #expect(document.contains("fastra-preview://resource/mermaid.js"))
        #expect(document.contains("securityLevel: 'strict'"))
        #expect(document.contains("htmlLabels: false"))
        #expect(document.contains("default-src 'none'"))
        #expect(document.contains("connect-src 'none'"))
        #expect(document.contains("max-width: 100%"))
    }

    @Test("Gebündelte Markdown-Bibliotheken sind im Ressourcenbundle auffindbar")
    func bundledRenderLibrariesExist() {
        #expect(MarkdownPreviewAssets.resource(named: "katex.js") != nil)
        #expect(MarkdownPreviewAssets.resource(named: "highlight.js") != nil)
        #expect(MarkdownPreviewAssets.resource(named: "highlight.css") != nil)
        #expect(MarkdownPreviewAssets.resource(named: "mermaid.js") != nil)
    }

    @Test("Copy-Handler liefert Klartext und formatiertes HTML")
    func clipboardScriptOffersPlainAndRichRepresentations() {
        let document = MarkdownRichText.htmlDocument(
            markdown: "Text mit **Fettung**",
            fontName: PreviewFonts.systemName,
            fontSize: 14,
            darkMode: false
        )

        #expect(document.contains("selection.toString()"))
        #expect(document.contains("setData('text/plain'"))
        #expect(document.contains("setData('text/html'"))
        #expect(document.contains("markdownCopy.postMessage"))
        #expect(document.contains("<strong>Fettung</strong>"))
    }

    @Test("Native Zwischenablage enthält RTF für Pages")
    @MainActor
    func nativePasteboardContainsRTF() throws {
        let pasteboard = NSPasteboard(name: .init("fastra.test.markdown-rich-copy"))
        let didWrite = MarkdownPasteboard.write(
            plain: "Titel\nFett",
            htmlFragment: "<h1>Titel</h1><p><strong>Fett</strong></p>",
            to: pasteboard
        )

        #expect(didWrite)
        #expect(pasteboard.string(forType: .string) == "Titel\nFett")
        #expect(pasteboard.data(forType: .html) != nil)
        #expect(pasteboard.data(forType: .rtf) != nil)
    }
}
