import Testing
@testable import Fastra

/// Prüft die Quellzeilen-Zuordnung der Markdown-Vorschau: Jeder Block im
/// gerenderten HTML muss die Zeile kennen, aus der er im Editor stammt.
/// Ohne diese Zuordnung landet ein Klick in der Vorschau an der falschen Stelle.
@Suite("Markdown-Quellzeilen")
struct MarkdownSourceLineTests {

    /// Quellzeile, die für eine Textstelle im HTML gilt.
    ///
    /// Gesucht wird das zuletzt davor geöffnete Zeilenattribut. Ein Tag
    /// zurückzugehen reicht nicht: Bei `<pre data-srcline><code>` steht das
    /// Attribut zwei Ebenen über dem Text.
    private func line(of needle: String, in html: String) -> Int? {
        guard let hit = html.range(of: needle) else { return nil }
        let marker = "\(MarkdownSourceMarkers.attribute)=\""
        guard let attribute = html.range(of: marker, options: .backwards,
                                         range: html.startIndex..<hit.lowerBound)
        else { return nil }
        let rest = html[attribute.upperBound...]
        guard let end = rest.range(of: "\"") else { return nil }
        return Int(rest[rest.startIndex..<end.lowerBound])
    }

    @Test("Blöcke tragen ihre Quellzeile")
    func blocksCarrySourceLines() {
        let html = MarkdownRichText.htmlFragment(markdown: """
        # Titel

        Erster Absatz.

        - Punkt eins
        - Punkt zwei
        """)

        #expect(line(of: "Titel", in: html) == 1)
        #expect(line(of: "Erster Absatz.", in: html) == 3)
        #expect(line(of: "Punkt eins", in: html) == 5)
        #expect(line(of: "Punkt zwei", in: html) == 6)
    }

    @Test("Tabellenzeilen sind einzeln adressierbar")
    func tableRowsCarryOwnLines() {
        let html = MarkdownRichText.htmlFragment(markdown: """
        | A | B |
        | --- | --- |
        | Eins | Zwei |
        | Drei | Vier |
        """)

        #expect(line(of: "Eins", in: html) == 3)
        #expect(line(of: "Drei", in: html) == 4)
    }

    /// cmark meldet für einen Fenced-Block die Zeile der Backticks. Ein Klick
    /// auf die erste Codezeile darf im Editor aber nicht auf der ``` -Zeile
    /// landen, deshalb wird auf die Inhaltszeile korrigiert.
    @Test("Fenced-Codeblock zeigt auf seine erste Codezeile, nicht auf die Fence")
    func fencedCodeSkipsItsFence() {
        let html = MarkdownRichText.htmlFragment(markdown: """
        Vorher.

        ```swift
        let a = 1
        ```
        """)

        #expect(line(of: "let a = 1", in: html) == 4)
    }

    /// Ein eingerückter Codeblock hat keine Fence-Zeile — hier wäre eine
    /// pauschale Korrektur um eine Zeile falsch.
    @Test("Eingerückter Codeblock zeigt auf seine erste Zeile")
    func indentedCodeStartsAtItsOwnLine() {
        let html = MarkdownRichText.htmlFragment(markdown: """
        Vorher.

            let a = 1
            let b = 2
        """)

        #expect(line(of: "let a = 1", in: html) == 3)
    }

    /// Der mehrzeilige `$$`-Block schrumpft beim Vorbereiten auf ein
    /// einzeiliges Token. Ohne Umrechnung würde alles darunter im Editor zu
    /// weit oben landen.
    @Test("Zeilen nach einer Blockformel bleiben richtig zugeordnet")
    func blockMathDoesNotShiftFollowingLines() {
        let html = MarkdownRichText.htmlFragment(markdown: """
        Davor.

        $$
        x = 1
        $$

        Danach.
        """)

        #expect(line(of: "Davor.", in: html) == 1)
        #expect(line(of: "Danach.", in: html) == 7)
    }

    @Test("Mehrere Blockformeln summieren ihren Versatz")
    func repeatedBlockMathAccumulatesOffset() {
        let html = MarkdownRichText.htmlFragment(markdown: """
        $$
        a = 1
        $$

        Mitte.

        $$
        b = 2
        $$

        Ende.
        """)

        #expect(line(of: "Mitte.", in: html) == 5)
        #expect(line(of: "Ende.", in: html) == 11)
    }

    /// Eine Blockformel muss ein eigener Block bleiben. Der Renderer hängt
    /// inzwischen ein Attribut an den Absatz — würde die Ersetzung weiterhin
    /// wörtlich `<p>` erwarten, fiele die Formel still auf den Inline-Pfad.
    @Test("Blockformel bleibt ein eigener Block")
    func blockMathStaysABlock() {
        let html = MarkdownRichText.htmlFragment(markdown: """
        $$
        x = 1
        $$
        """)

        #expect(html.contains("<div class=\"math-block\""))
        #expect(!html.contains("<p><span class=\"math-inline\""))
    }

    /// Code-Fences schrumpfen beim Vorbereiten zwar ebenfalls, werden aber
    /// wieder eingesetzt — sie dürfen die Zählung deshalb nicht verschieben.
    @Test("Codeblöcke verschieben die Zeilen darunter nicht")
    func codeFencesDoNotShiftFollowingLines() {
        let html = MarkdownRichText.htmlFragment(markdown: """
        Davor.

        ```
        eine
        zwei
        drei
        ```

        Danach.
        """)

        #expect(line(of: "Danach.", in: html) == 9)
    }

    /// Innerhalb eines Absatzes löst das Vorschau-JS die Zeile über die
    /// Zeilenumbrüche im gerenderten Text auf. Die müssen dafür erhalten sein.
    @Test("Weiche Umbrüche bleiben als Newline im Absatz erhalten")
    func softBreaksSurviveAsNewlines() {
        let html = MarkdownRichText.htmlFragment(markdown: """
        Zeile eins
        Zeile zwei
        Zeile drei
        """)

        #expect(line(of: "Zeile eins", in: html) == 1)
        // Genau zwei Umbrüche zwischen den drei Quellzeilen.
        let paragraph = html.components(separatedBy: "\n")
        #expect(paragraph.count >= 3)
        #expect(html.contains("Zeile eins\nZeile zwei\nZeile drei"))
    }

    /// Die Marken sind Fastra-Interna. Beim Kopieren entfernt sie das
    /// Vorschau-JS; hier wird geprüft, dass es dafür überhaupt einen Handler
    /// gibt und er denselben Attributnamen verwendet.
    @Test("Kopier-Handler räumt die Zeilenmarken weg")
    func clipboardHandlerStripsMarkers() {
        let document = MarkdownRichText.htmlDocument(
            markdown: "# Titel",
            fontName: PreviewFonts.systemName,
            fontSize: 14,
            darkMode: false
        )

        #expect(document.contains(
            "removeAttribute('\(MarkdownSourceMarkers.attribute)')"
        ))
    }

    /// Der Klick-Handler muss dem nativen Teil Zeile und Spalte melden.
    @Test("Klick-Handler meldet die Position an die App")
    func clickHandlerReportsPosition() {
        let document = MarkdownRichText.htmlDocument(
            markdown: "# Titel",
            fontName: PreviewFonts.systemName,
            fontSize: 14,
            darkMode: false
        )

        #expect(document.contains("markdownJump.postMessage(position)"))
        // Links dürfen weiterhin im Browser öffnen statt zu springen.
        #expect(document.contains("closest('a')"))
        // Eine gezogene Auswahl ist kein Positionsklick.
        #expect(document.contains("isCollapsed"))
    }
}
