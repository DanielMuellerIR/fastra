// HelpContentTests.swift
//
// Tests für die Fastra-Hilfe (Etappe 4 Wunschpaket 2026-07b): Bundle-Laden
// beider Sprachen, Anker-Slugs, Überschriften-IDs im gerenderten HTML und
// der Anti-Drift zwischen `HelpSection` und den Markdown-Dateien.

import Foundation
import Testing
@testable import Fastra

// MARK: - Laden aus dem Bundle

@Test("Hilfe lädt aus dem Bundle — Deutsch und Englisch, mit H1")
func help_loadsBothLanguages() {
    for code in ["de", "en"] {
        let markdown = HelpContent.markdown(languageCode: code)
        #expect(markdown != nil, "hilfe.\(code).md fehlt im Bundle")
        #expect(markdown?.hasPrefix("# ") == true,
                "hilfe.\(code).md beginnt nicht mit einer H1")
    }
}

@Test("Sprachwahl: en-Präferenz → englische Hilfe, sonst deutsch")
func help_languageSelection() {
    #expect(HelpContent.languageCode(preferred: ["en"]) == "en")
    #expect(HelpContent.languageCode(preferred: ["en-GB", "de"]) == "en")
    #expect(HelpContent.languageCode(preferred: ["de", "en"]) == "de")
    #expect(HelpContent.languageCode(preferred: []) == "de")
}

// MARK: - Anker

@Test("anchor: Umlaute/Sonderzeichen → stabile Bindestrich-Slugs")
func help_anchorSlugs() {
    #expect(HelpContent.anchor(forHeading: "Suchen und Ersetzen") == "suchen-und-ersetzen")
    #expect(HelpContent.anchor(forHeading: "Ansichten: Text, Vorschau, Hex")
            == "ansichten-text-vorschau-hex")
    #expect(HelpContent.anchor(forHeading: "4D-Unterstützung") == "4d-unterstützung")
    #expect(HelpContent.anchor(forHeading: "  Git  ") == "git")
}

@Test("addingHeadingAnchors: h2 bekommt id, Attribute und Inhalt bleiben")
func help_addsHeadingIDs() {
    let html = "<h2 data-sourcepos=\"3:1\">Suchen und Ersetzen</h2><p>x</p>"
    let anchored = HelpContent.addingHeadingAnchors(to: html)
    #expect(anchored.contains(
        "<h2 data-sourcepos=\"3:1\" id=\"suchen-und-ersetzen\">Suchen und Ersetzen</h2>"))
    #expect(anchored.contains("<p>x</p>"))
}

@Test("addingHeadingAnchors: Inline-Markup in der Überschrift stört den Slug nicht")
func help_headingIDIgnoresInlineMarkup() {
    let html = "<h3><code>git</code> Basics</h3>"
    #expect(HelpContent.addingHeadingAnchors(to: html).contains("id=\"git-basics\""))
}

// MARK: - Anti-Drift: HelpSection ↔ Markdown-Dateien

@Test("Jede HelpSection-Überschrift existiert wörtlich in beiden Hilfe-Dateien")
func help_sectionsExistInBothLanguages() throws {
    for code in ["de", "en"] {
        let markdown = try #require(HelpContent.markdown(languageCode: code))
        for section in HelpSection.allCases {
            let heading = "## " + section.heading(languageCode: code)
            #expect(markdown.contains(heading),
                    "\(heading) fehlt in hilfe.\(code).md — Enum und Hilfetext driften")
        }
    }
}

@Test("Gerenderte Hilfe enthält für jede HelpSection ein Anker-Ziel")
func help_renderedAnchorsExist() throws {
    for code in ["de", "en"] {
        let markdown = try #require(HelpContent.markdown(languageCode: code))
        let html = HelpContent.addingHeadingAnchors(
            to: MarkdownRichText.htmlFragment(markdown: markdown)
        )
        for section in HelpSection.allCases {
            let anchor = "id=\"\(section.anchor(languageCode: code))\""
            #expect(html.contains(anchor),
                    "Anker \(anchor) fehlt im gerenderten HTML (\(code))")
        }
    }
}
