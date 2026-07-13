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
        #expect(document.contains("<strong>Fettung</strong>"))
    }
}
