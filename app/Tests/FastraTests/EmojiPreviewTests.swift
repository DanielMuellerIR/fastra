// EmojiPreviewTests.swift
//
// Emojis (UTF-16-Surrogatpaare) dürfen auf dem Weg durch die Markdown-
// Vorschau-Pipeline nicht zerbrechen: kein U+FFFD, jedes Emoji unversehrt
// im erzeugten HTML.

import Foundation
import Testing
@testable import Fastra

@Test("Preview-HTML lässt Emojis am Zeilen- und Dateiende intakt")
func previewHTMLKeepsEmojisIntact() {
    // Konstellation aus dem Fehlerbericht: drei Emojis in Anführungszeichen
    // nahe dem Dateiende, letzte Zeile ohne abschließenden Zeilenumbruch.
    let markdown = """
    - Erste lange Zeile mit etwas Text
    - Zweite Zeile
    - Idee: "PAIN POINT: Dieser Weg wird kein leichter sein 🎶🤮🎶" - zu daneben?
    """
    let html = MarkdownRichText.htmlFragment(markdown: markdown)
    #expect(!html.contains("\u{FFFD}"))
    #expect(html.components(separatedBy: "🎶").count - 1 == 2)
    #expect(html.components(separatedBy: "🤮").count - 1 == 1)
}

@Test("Preview-HTML: Emoji direkt am Dateiende ohne Newline bleibt ganz")
func previewHTMLKeepsTrailingEmojiIntact() {
    let markdown = "Schluss 🎶"
    let html = MarkdownRichText.htmlFragment(markdown: markdown)
    #expect(!html.contains("\u{FFFD}"))
    #expect(html.contains("🎶"))
}
