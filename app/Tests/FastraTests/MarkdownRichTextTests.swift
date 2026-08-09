import AppKit
import Testing
@testable import Fastra

@Suite("Markdown-Rich-Text")
struct MarkdownRichTextTests {
    @Test("Zwei ASCII-Leerzeichen als eigene Zeile erzeugen eine sichtbare Leerzeile")
    func twoSpacesBecomeVisibleBlankLine() {
        let fragment = MarkdownRichText.htmlFragment(markdown: "Alpha\n  \nOmega")

        #expect(fragment.contains("class=\"fastra-visible-blank-line\""))
        #expect(fragment.contains("data-srcline=\"2\""))
    }

    @Test("Nur mindestens zwei reine ASCII-Leerzeichen aktivieren den Dialekt")
    func blankLineThresholdAndCharacterAreExact() {
        for unchanged in ["Alpha\n\nOmega", "Alpha\n \nOmega", "Alpha\n\t\nOmega",
                          "Alpha\n\u{00A0}\nOmega"] {
            #expect(visibleBlankCount(in: unchanged) == 0)
        }
        for extended in ["Alpha\n  \nOmega", "Alpha\n   \nOmega", "Alpha\n    \nOmega"] {
            #expect(visibleBlankCount(in: extended) == 1)
        }
    }

    @Test("Harte CommonMark-Umbrüche mit Leerzeichen und Backslash bleiben unverändert")
    func ordinaryHardBreaksStayUnchanged() {
        let fragment = MarkdownRichText.htmlFragment(markdown: "Alpha  \nBeta\nGamma\\\nDelta")

        #expect(occurrences(of: "<br />", in: fragment) == 2)
        #expect(!fragment.contains(MarkdownVisibleBlankLines.cssClass))
    }

    @Test("Fenced und eingerückte Codeblöcke bleiben unangetastet")
    func literalBlocksKeepSpaceOnlyLines() {
        let markdown = "```text\nfenced\n  \nblock\n```\n\n"
            + "    indented\n      \n    block"
        let fragment = MarkdownRichText.htmlFragment(markdown: markdown)

        #expect(occurrences(of: "<pre", in: fragment) == 2)
        #expect(!fragment.contains(MarkdownVisibleBlankLines.cssClass))
    }

    @Test("Listen und Blockzitate behalten ihre GFM-Blockstruktur")
    func listsAndQuotesDoNotSplitAroundVisibleBlankLines() {
        let list = MarkdownRichText.htmlFragment(markdown: "- Eins\n  \n- Zwei")
        let quote = MarkdownRichText.htmlFragment(markdown: "> Eins\n  \n> Zwei")

        #expect(occurrences(of: "<ul", in: list) == 1)
        #expect(occurrences(of: "<li", in: list) == 2)
        #expect(occurrences(of: MarkdownVisibleBlankLines.cssClass, in: list) == 1)
        // Schon CommonMark trennt diese beiden Zitate; die Erweiterung darf
        // daraus weder weniger noch zusätzliche Zitatblöcke machen.
        #expect(occurrences(of: "<blockquote", in: quote) == 2)
        #expect(occurrences(of: MarkdownVisibleBlankLines.cssClass, in: quote) == 1)
    }

    @Test("Nachlaufende Leerraumzeilen einer Liste bleiben sichtbare Dokumentzeilen")
    func trailingListWhitespaceLinesStayVisible() {
        let blanks = Array(repeating: "  ", count: 6).joined(separator: "\n")
        let markdown = "***Getestet:***\n\n-\n-\n-\n-\n-\n-\n\(blanks)\n***Frage:***"
        let fragment = MarkdownRichText.htmlFragment(markdown: markdown)

        #expect(occurrences(of: "<ul", in: fragment) == 1)
        #expect(occurrences(of: "<li", in: fragment) == 6)
        #expect(occurrences(of: MarkdownVisibleBlankLines.cssClass, in: fragment) == 6)
        for line in 9...14 {
            #expect(fragment.contains("data-srcline=\"\(line)\""))
        }
        // Die Leerzeilen gehören semantisch hinter die Liste, nicht in den
        // letzten leeren Eintrag: Dort würde WebKit einen Bullet anzeigen.
        let listEnd = fragment.range(of: "</ul>")?.upperBound
        let firstBlank = fragment.range(of: MarkdownVisibleBlankLines.cssClass)?.lowerBound
        #expect(listEnd != nil && firstBlank != nil && listEnd! < firstBlank!)
    }

    @Test("Tabellen, Bilder und Formeln bleiben neben sichtbaren Leerzeilen intakt")
    func gfmAndRichBlocksStayIntact() {
        let markdown = "| A | B |\n| - | - |\n| 1 | 2 |\n  \n"
            + "![Bild](bild.png)\n  \n$$\nx + y\n  \nz\n$$\n  \nEnde"
        let fragment = MarkdownRichText.htmlFragment(markdown: markdown)

        #expect(fragment.contains("<table"))
        #expect(fragment.contains("<img"))
        #expect(fragment.contains("class=\"math-block\""))
        // Die Leerzeichenzeile innerhalb der Formel bleibt TeX-Inhalt. Nur
        // die drei Zeilen zwischen den gerenderten Blöcken werden sichtbar.
        #expect(occurrences(of: MarkdownVisibleBlankLines.cssClass, in: fragment) == 3)
        #expect(fragment.contains("data-srcline=\"12\""))
    }

    @Test("Dateigrenzen und aufeinanderfolgende Leerzeichenzeilen bleiben zeilengenau")
    func boundariesAndConsecutiveLinesRemainLineAccurate() {
        let fragment = MarkdownRichText.htmlFragment(markdown: "  \n   \nText\n  ")

        #expect(occurrences(of: MarkdownVisibleBlankLines.cssClass, in: fragment) == 3)
        #expect(fragment.contains("data-srcline=\"1\""))
        #expect(fragment.contains("data-srcline=\"2\""))
        #expect(fragment.contains("data-srcline=\"4\""))
    }

    @Test("Copy-Bereinigung entfernt interne Leerzeilen-Metadaten")
    func copyScriptSanitizesVisibleBlankLines() {
        let document = MarkdownRichText.htmlDocument(
            markdown: "Alpha\n  \nOmega",
            fontName: PreviewFonts.systemName,
            fontSize: 14,
            darkMode: false
        )

        #expect(document.contains("element.replaceWith(document.createElement('br'))"))
        #expect(document.contains("removeAttribute('data-srcline')"))
    }

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

        // Blocktags tragen inzwischen die Quellzeile (`data-srcline`), deshalb
        // wird der Öffnungs-Tag ohne Attributliste geprüft.
        #expect(light.contains(">Titel</h1>"))
        #expect(light.contains("<strong>Fettung</strong>"))
        #expect(light.contains("<del>Streichung</del>"))
        #expect(light.contains("<table"))
        #expect(light.contains("#FFFFFF"))
        #expect(dark.contains("#171717"))
    }

    @Test("Fastra-Textmarker rendert semantisches mark mit verschachteltem Markdown")
    func highlightRendersSemanticMark() {
        let fragment = MarkdownRichText.htmlFragment(
            markdown: "Normal, ==markiert und **fett**==, normal."
        )

        #expect(fragment.contains("<mark>markiert und <strong>fett</strong></mark>"))
        #expect(!fragment.contains("==markiert"))
    }

    @Test("Textmarker respektiert Escapes, Code und ungültige Delimiter")
    func highlightLeavesLiteralContextsAlone() {
        let fragment = MarkdownRichText.htmlFragment(markdown: #"""
        \==wörtlich== und `==Code==` und == nicht markiert == und ===lang===.

        ```text
        ==Blockcode==
        ```
        """#)

        #expect(!fragment.contains("<mark>"))
        #expect(fragment.contains("==wörtlich=="))
        #expect(fragment.contains("==Code=="))
        #expect(fragment.contains("==Blockcode=="))
    }

    @Test("Textmarker darf einen Softbreak im selben Absatz enthalten")
    func highlightMayContainSoftBreak() {
        let fragment = MarkdownRichText.htmlFragment(markdown: "==erste\nzweite==")

        #expect(fragment.contains("<mark>erste\nzweite</mark>"))
    }

    @Test("Textmarker ändert die sichere HTML-Grenze nicht")
    func highlightDoesNotEnableRawHTML() {
        let fragment = MarkdownRichText.htmlFragment(
            markdown: "==sicher== <script>alert('x')</script>"
        )

        #expect(fragment.contains("<mark>sicher</mark>"))
        // Seit der HTML-Positivliste (v1.52) steht hier nicht mehr
        // „raw HTML omitted": Die verworfenen Tags verschwinden ersatzlos.
        // Der Inhalt DAZWISCHEN bleibt als gewöhnlicher Text stehen — cmark
        // gibt ihn als eigenen Textknoten aus. Entscheidend ist, dass kein
        // `script`-Element entsteht; sichtbarer Text führt nichts aus.
        #expect(!fragment.contains("<script"))
        #expect(!fragment.contains("</script"))
        #expect(fragment.contains("alert('x')"))
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
    func localImagesUseOpaquePreviewURLs() throws {
        let documentURL = URL(fileURLWithPath: "/tmp/Fastra Handbuch/README.md")
        let fragment = MarkdownRichText.renderedFragment(
            markdown: "![Fenster](screenshots/editor%20light.png)",
            documentURL: documentURL
        )

        let token = try #require(fragment.imageURLs.keys.first)
        #expect(fragment.html.contains("src=\"fastra-preview://image/\(token)\""))
        #expect(fragment.imageURLs[token]?.path ==
                "/tmp/Fastra Handbuch/screenshots/editor light.png")
        #expect(!fragment.html.contains("/tmp/Fastra"))
    }

    @Test("Prozentcodierte reservierte Zeichen bleiben Teil des Bilddateinamens")
    func encodedReservedCharactersStayInLocalImageFilename() throws {
        let documentURL = URL(fileURLWithPath: "/tmp/Testprotokoll/Bericht.md")
        let fragment = MarkdownRichText.renderedFragment(
            markdown: "![Bild](images/1__%23%24%21%40%25%21%23__Pasted%20Graphic%205.png)",
            documentURL: documentURL
        )

        let token = try #require(fragment.imageURLs.keys.first)
        #expect(fragment.html.contains("src=\"fastra-preview://image/\(token)\""))
        #expect(fragment.imageURLs[token]?.path ==
                "/tmp/Testprotokoll/images/1__#$!@%!#__Pasted Graphic 5.png")
    }

    // Regression zum Daniel-Befund 2026-08-06: Nach dem Austausch eines
    // Bildes zeigte die Vorschau das vorherige. Die Vorschau-Adresse hieß für
    // das erste Bild jedes Laufs „image-0"; WebKit lieferte darunter seine
    // zwischengespeicherte Fassung. Zwei verschiedene Dateien dürfen deshalb
    // nie dieselbe Adresse bekommen.
    @Test("Ausgetauschtes Bild bekommt eine andere Vorschau-Adresse")
    func replacedImageGetsFreshPreviewURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastraImageToken-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let documentURL = directory.appendingPathComponent("Protokoll.md")
        let old = directory.appendingPathComponent("alt.png")
        let new = directory.appendingPathComponent("neu.png")
        try Data(repeating: 0xA0, count: 64).write(to: old)
        try Data(repeating: 0xB0, count: 128).write(to: new)

        let before = MarkdownRichText.renderedFragment(
            markdown: "![Bild](alt.png)", documentURL: documentURL
        )
        let after = MarkdownRichText.renderedFragment(
            markdown: "![Bild](neu.png)", documentURL: documentURL
        )

        let oldToken = try #require(before.imageURLs.keys.first)
        let newToken = try #require(after.imageURLs.keys.first)
        #expect(oldToken != newToken)
        #expect(before.imageURLs[oldToken]?.lastPathComponent == "alt.png")
        #expect(after.imageURLs[newToken]?.lastPathComponent == "neu.png")
    }

    @Test("Gleicher Dateiname mit neuem Inhalt gilt als anderes Bild")
    func rewrittenImageFileGetsFreshPreviewURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastraImageToken-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let documentURL = directory.appendingPathComponent("Protokoll.md")
        let image = directory.appendingPathComponent("bild.png")
        try Data(repeating: 0xA0, count: 64).write(to: image)
        let before = MarkdownImages.imageToken(for: image)

        try Data(repeating: 0xB0, count: 4096).write(to: image)
        #expect(MarkdownImages.imageToken(for: image) != before)
    }

    @Test("Gleiche Größe und zurückgestelltes Änderungsdatum gelten trotzdem als neues Bild")
    func replacedImageWithPreservedTimestampGetsFreshPreviewURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastraImageToken-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = directory.appendingPathComponent("bild.png")
        try Data(repeating: 0xA0, count: 512).write(to: image)
        var original = stat()
        #expect(stat(image.path, &original) == 0)
        let before = MarkdownImages.imageToken(for: image)

        // Anderer Inhalt, GLEICHE Größe, Änderungsdatum exakt
        // wiederhergestellt — so hinterlässt ein Sync-Werkzeug eine Datei,
        // das Zeitstempel erhält. Vorher bekam sie dieselbe interne Adresse,
        // und WebKit lieferte das alte Bild aus seinem Cache
        // (Review 2026-08-06).
        try Data(repeating: 0xB0, count: 512).write(to: image)
        // `utimensat` statt `setAttributes`: nur so ist der Zeitstempel bis
        // auf die Nanosekunde derselbe — ein Date-Umweg rundet.
        var times = [original.st_atimespec, original.st_mtimespec]
        #expect(utimensat(AT_FDCWD, image.path, &times, 0) == 0)

        // Erst belegen, dass Größe und Änderungsdatum wirklich gleich sind —
        // sonst prüfte der Test etwas anderes als den beschriebenen Fall.
        var replaced = stat()
        #expect(stat(image.path, &replaced) == 0)
        #expect(replaced.st_size == original.st_size)
        #expect(replaced.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec)
        #expect(replaced.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec)

        #expect(MarkdownImages.imageToken(for: image) != before)
    }

    @Test("Unverändertes Bild behält seine Adresse (kein Neuladen beim Tippen)")
    func unchangedImageKeepsPreviewURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastraImageToken-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let documentURL = directory.appendingPathComponent("Protokoll.md")
        let image = directory.appendingPathComponent("bild.png")
        try Data(repeating: 0xA0, count: 64).write(to: image)

        let first = MarkdownRichText.renderedFragment(
            markdown: "![Bild](bild.png)", documentURL: documentURL
        )
        let second = MarkdownRichText.renderedFragment(
            markdown: "![Bild](bild.png)\n\nNoch ein Satz.", documentURL: documentURL
        )
        #expect(first.imageURLs.keys.first == second.imageURLs.keys.first)
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

    @Test("Native RTF-Zwischenablage behält den Textmarker-Hintergrund")
    @MainActor
    func nativePasteboardKeepsHighlightBackground() throws {
        let pasteboard = NSPasteboard(name: .init("fastra.test.markdown-mark-copy"))
        let didWrite = MarkdownPasteboard.write(
            plain: "Markiert",
            htmlFragment: "<mark style=\"background-color:#FFEE9A;color:#363636\">Markiert</mark>",
            to: pasteboard
        )

        let rtf = try #require(pasteboard.data(forType: .rtf))
        let attributed = try NSAttributedString(
            data: rtf,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
        let background = attributed.attribute(.backgroundColor, at: 0,
                                              effectiveRange: nil) as? NSColor
        #expect(didWrite)
        #expect(background != nil)
    }

    private func visibleBlankCount(in markdown: String) -> Int {
        occurrences(of: MarkdownVisibleBlankLines.cssClass,
                    in: MarkdownRichText.htmlFragment(markdown: markdown))
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    @Test("Offene HTML-Elemente schließen erst am Dokumentende")
    func openElementsCloseAtDocumentEnd() throws {
        // Ein nie geschlossenes <details> soll den nachfolgenden Absatz
        // einschachteln — das erzwungene </details> kommt deshalb ganz ans
        // Dokumentende, nicht an den letzten HTML-Knoten mitten im Text
        // (Review 2026-08-02).
        let fragment = MarkdownRichText.htmlFragment(
            markdown: "<details>\n\nAbsatz im Element.\n"
        )
        let open = try #require(fragment.range(of: "<details>"))
        let close = try #require(fragment.range(of: "</details>"))
        let paragraph = try #require(fragment.range(of: "Absatz im Element."))
        #expect(open.lowerBound < paragraph.lowerBound)
        #expect(paragraph.upperBound <= close.lowerBound)
    }
}
