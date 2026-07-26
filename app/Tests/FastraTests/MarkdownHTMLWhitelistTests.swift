// MarkdownHTMLWhitelistTests.swift
//
// Die Positivliste ist eine Sicherheitsgrenze. Diese Tests prüfen sie deshalb
// nicht an ihrer Implementierung, sondern am beobachtbaren Ergebnis der
// vollständigen Vorschau-Pipeline: Was landet wirklich im HTML, das WebKit
// bekommt? Zusätzlich die Klassen, an denen echte Sanitizer scheitern —
// Parser-Unterschiede, Attribut-Vektoren und der Weg in die Zwischenablage.

import Foundation
import Testing
@testable import Fastra

/// Vollständige Pipeline wie in der Vorschau, ohne WebKit.
private func render(_ markdown: String) -> String {
    MarkdownRichText.htmlFragment(markdown: markdown)
}

@Suite("HTML-Positivliste: was durchkommt")
struct MarkdownHTMLWhitelistAllowedTests {

    @Test("Der README-Aufbau mit zentriertem Bild wird gerendert")
    func centeredImageSurvives() {
        let html = render("""
        <p align="center">
          <img src="bild.png" width="128" alt="Symbol">
        </p>
        """)
        #expect(html.contains("<p align=\"center\">"))
        #expect(html.contains("width=\"128\""))
        #expect(html.contains("alt=\"Symbol\""))
        #expect(!html.contains("raw HTML omitted"))
    }

    @Test("Gängige README-Bausteine bleiben erhalten")
    func commonBuildingBlocksSurvive() {
        let html = render("""
        <details>
        <summary>Mehr</summary>

        Normaler **Markdown**-Text dazwischen.

        </details>
        """)
        #expect(html.contains("<details>"))
        #expect(html.contains("<summary>"))
        #expect(html.contains("</details>"))
        // Markdown zwischen den HTML-Blöcken wird weiterhin normal formatiert.
        #expect(html.contains("<strong>Markdown</strong>"))
    }

    @Test("Ein Kommentar verschwindet, der Rest des Fragments bleibt")
    func commentsAreDroppedNotPassedThrough() {
        let html = render("<p align=\"left\"><!-- Notiz -->Text</p>")
        #expect(html.contains("<p align=\"left\">"))
        #expect(html.contains("Text"))
        #expect(!html.contains("Notiz"))
    }
}

@Suite("HTML-Positivliste: was verworfen wird")
struct MarkdownHTMLWhitelistRejectedTests {

    @Test("Skript-Elemente kommen nie durch")
    func scriptIsRejected() {
        for markdown in [
            "<script>alert(1)</script>",
            "<p><script>alert(1)</script></p>",
            "Text <script src=\"x.js\"></script> mehr",
        ] {
            let html = render(markdown)
            #expect(!html.contains("<script"), "durchgelassen: \(markdown)")
            #expect(!html.contains("alert(1)"), "durchgelassen: \(markdown)")
        }
    }

    @Test("Inline-Skript verliert die Tags, sein Inhalt bleibt sichtbarer Text")
    func inlineScriptLeavesOnlyText() {
        // cmark trennt inline `<script>`, den Text und `</script>` in drei
        // Knoten. Die beiden HTML-Knoten fallen weg, der Text bleibt stehen —
        // als Text, nicht als Code. Das ist die bewusste Zusage, damit nichts
        // stillschweigend verschwindet.
        let html = render("Text <script>alert('x')</script> Ende")
        #expect(!html.contains("<script"))
        #expect(!html.contains("</script"))
        #expect(html.contains("alert('x')"))
    }

    @Test("Ereignis-Attribute sind der eigentliche Skriptvektor und fallen weg")
    func eventHandlerAttributesAreRejected() {
        // Genau hiermit ist die QuickLook-Erweiterung 2026-07-26 durchgefallen:
        // Ihre Tag-Blacklist kennt `<script>`, aber `onerror` ist ein Attribut.
        for markdown in [
            "<img src=\"x\" onerror=\"alert(1)\">",
            "<p onclick=\"alert(1)\">Text</p>",
            "<a href=\"#\" onmouseover=\"alert(1)\">Link</a>",
            "<img src=\"x\" ONERROR=\"alert(1)\">",
        ] {
            let html = render(markdown)
            #expect(!html.lowercased().contains("onerror"), "durchgelassen: \(markdown)")
            #expect(!html.lowercased().contains("onclick"), "durchgelassen: \(markdown)")
            #expect(!html.lowercased().contains("onmouseover"), "durchgelassen: \(markdown)")
            #expect(!html.contains("alert(1)"), "durchgelassen: \(markdown)")
        }
    }

    @Test("Keine Selbstgestaltung: style, class und id fallen weg")
    func stylingAttributesAreRejected() {
        // `style` erlaubte Überlagerung und CSS-Nachladen, `id` und `name`
        // erlaubten DOM-Clobbering gegen Fastras eigene Vorschau-Skripte.
        for markdown in [
            "<div style=\"position:fixed;top:0\">Overlay</div>",
            "<div style=\"background:url(https://example.com/x)\">x</div>",
            "<a id=\"katex\">x</a>",
            "<img src=\"a.png\" name=\"mermaid\">",
            "<p class=\"fastra-visible-blank-line\">x</p>",
        ] {
            let html = render(markdown)
            #expect(!html.contains("style="), "durchgelassen: \(markdown)")
            #expect(!html.contains("id="), "durchgelassen: \(markdown)")
            #expect(!html.contains("name="), "durchgelassen: \(markdown)")
            #expect(!html.contains("class="), "durchgelassen: \(markdown)")
        }
    }

    @Test("Elemente, die die Parsingregeln umschalten, sind gesperrt")
    func parsingContextSwitchersAreRejected() {
        // `<svg>` und `<math>` wechseln in Foreign Content und sind über
        // `foreignObject` bzw. `annotation-xml` ein Wiedereinstieg in HTML —
        // die klassische Quelle für Mutation-XSS.
        for markdown in [
            "<svg><image href=\"https://example.com/x\"/></svg>",
            "<svg><foreignObject><p>x</p></foreignObject></svg>",
            "<math><annotation-xml encoding=\"text/html\"><p>x</p></annotation-xml></math>",
            "<iframe src=\"https://example.com\"></iframe>",
            "<object data=\"https://example.com\"></object>",
            "<style>body{background:url(https://example.com/x)}</style>",
            "<template><p>x</p></template>",
            "<noscript><p>x</p></noscript>",
        ] {
            let html = render(markdown)
            for tag in ["<svg", "<math", "<iframe", "<object", "<style", "<template", "<noscript"] {
                #expect(!html.contains(tag), "\(tag) durchgelassen bei: \(markdown)")
            }
            #expect(!html.contains("example.com"), "URL durchgelassen: \(markdown)")
        }
    }

    @Test("Unsichere Link-Schemata werden geleert — auch in Markdown-Syntax")
    func unsafeLinkSchemesAreEmptied() {
        // Der sichere cmark-Modus hat das früher erledigt. Seit die Vorschau
        // mit UNSAFE rendert, muss der Baum-Sanitizer es tun.
        for markdown in [
            "[klick](javascript:alert(1))",
            "[klick](vbscript:alert(1))",
            "[klick](file:///etc/passwd)",
            "<a href=\"javascript:alert(1)\">klick</a>",
            "<a href=\"data:text/html,<b>x</b>\">klick</a>",
        ] {
            let html = render(markdown)
            #expect(!html.contains("javascript:"), "durchgelassen: \(markdown)")
            #expect(!html.contains("vbscript:"), "durchgelassen: \(markdown)")
            #expect(!html.contains("file:"), "durchgelassen: \(markdown)")
            #expect(!html.contains("data:text/html"), "durchgelassen: \(markdown)")
        }
    }

    @Test("Ungequotete Attributwerte gelten als nicht verstanden")
    func unquotedAttributesAreRejected() {
        // HTML erlaubt sie, diese Grammatik nicht. Ungequotete Werte sind eine
        // der Stellen, an denen Filter und Renderer auseinanderlaufen.
        let html = render("<p align=center>Text</p>")
        #expect(!html.contains("<p align"))
    }

    @Test("Ein einziger Fehler verwirft das ganze Fragment")
    func oneBadTagDropsTheWholeFragment() {
        // Kein Reparieren: Ein halb entferntes Fragment ergäbe einen
        // unbalancierten Baum, der anders geparst wird als geprüft.
        let html = render("<div><p>harmlos</p><script>alert(1)</script></div>")
        #expect(!html.contains("<div>"))
        #expect(!html.contains("alert(1)"))
    }

    @Test("Zahlenattribute nehmen nur Zahlen")
    func numericAttributesAreValidated() {
        #expect(!render("<img src=\"a.png\" width=\"999999999\">").contains("width="))
        #expect(!render("<td colspan=\"abc\">x</td>").contains("colspan="))
        #expect(render("<img src=\"a.png\" width=\"64\">").contains("width=\"64\""))
    }
}

@Suite("HTML-Positivliste: Struktur und Bildpfade")
struct MarkdownHTMLWhitelistStructureTests {

    @Test("Ein nicht geschlossenes Element wird am Dokumentende geschlossen")
    func unclosedElementsAreClosed() {
        // Sonst schachtelte ein offenes `<div>` den Rest des Dokuments ein.
        var stack: [String] = []
        let opened = MarkdownHTMLWhitelist.scan("<div>", openElements: &stack)
        #expect(opened == "<div>")
        #expect(stack == ["div"])

        var sanitizer = MarkdownHTMLWhitelist.Sanitizer()
        _ = sanitizer.sanitize("<div><p>")
        #expect(sanitizer.closingTail() == "</p></div>")
    }

    @Test("Ein Schluss-Tag ohne passendes Öffnen wird verworfen")
    func strayClosingTagIsRejected() {
        var stack: [String] = []
        #expect(MarkdownHTMLWhitelist.scan("</div>", openElements: &stack) == nil)
    }

    @Test("Ein verworfenes Fragment bringt die folgenden nicht aus dem Tritt")
    func rejectedFragmentDoesNotCorruptTheStack() {
        var sanitizer = MarkdownHTMLWhitelist.Sanitizer()
        #expect(sanitizer.sanitize("<div>") == "<div>")
        #expect(sanitizer.sanitize("<script>x</script>") == "")
        #expect(sanitizer.sanitize("</div>") == "</div>")
        #expect(sanitizer.closingTail().isEmpty)
    }

    @Test("Ein lokales Bild aus rohem HTML bekommt ein internes Token")
    func localImageFromRawHTMLIsTokenized() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-whitelist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("icon.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        let document = directory.appendingPathComponent("README.md")

        let fragment = MarkdownRichText.renderedFragment(
            markdown: "<p align=\"center\"><img src=\"icon.png\" alt=\"x\"></p>",
            documentURL: document
        )
        #expect(fragment.html.contains("fastra-preview://image/"))
        #expect(fragment.imageURLs.values.contains(image.standardizedFileURL))
        // Kein echter Pfad im HTML — das war schon vorher die Zusage.
        #expect(!fragment.html.contains(directory.path))
    }

    @Test("Ein entferntes Bild aus rohem HTML löst keinen Netzabruf aus")
    func remoteImageFromRawHTMLIsNeutralized() {
        let html = render("<img src=\"https://example.com/beacon.png\" alt=\"x\">")
        #expect(!html.contains("example.com"))
        #expect(html.contains("src=\"\""))
    }
}

@Suite("HTML-Positivliste: Weg in die Zwischenablage")
struct MarkdownHTMLWhitelistPasteboardTests {

    @Test("Kopiertes HTML trägt keine fremden Quellen in andere Programme")
    func clipboardCarriesNoForeignSources() {
        // Die Zwischenablage verlässt Fastras CSP: Was hier landet, rendert
        // Mail oder Pages unter deren eigener, viel großzügigerer Politik.
        let html = render("""
        <img src="https://example.com/beacon.png" onerror="alert(1)">
        <a href="javascript:alert(1)">klick</a>
        """)
        #expect(!html.contains("example.com"))
        #expect(!html.contains("javascript:"))
        #expect(!html.lowercased().contains("onerror"))
    }
}
