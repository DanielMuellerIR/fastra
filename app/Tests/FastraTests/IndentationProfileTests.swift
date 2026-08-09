// IndentationProfileTests.swift
//
// Etappe 4 des Soft-Wrap-Pakets: Einrückungsprofile pro Format und der
// UI-freie Kern von „Einfügen und Einrückung angleichen".

import Foundation
import Testing
@testable import Fastra

// MARK: - Profil-Store

@Test("Werkstandard der Einrückung: Leerzeichen, Breite 4, Tabbreite 4")
func indentationFactoryDefaults() {
    let store = SoftWrapProfileStore(
        defaults: testSuiteDefaults(named: "fastra-softwrap-\(UUID().uuidString)"))
    let profile = store.indentationProfile(for: .plainText)
    #expect(profile == .factory)
    #expect(!profile.usesTabs)
    #expect(profile.indentWidth == 4)
    #expect(profile.tabWidth == 4)
}

@Test("Einrückungsprofil wird pro Format gespeichert, validiert und zurückgesetzt")
func indentationProfilePersistsPerFormat() {
    let suite = "fastra-softwrap-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    let store = SoftWrapProfileStore(defaults: defaults)

    store.setIndentUsesTabs(true, for: .grammar(.markdown))
    store.setTabWidth(8, for: .grammar(.markdown))
    store.setIndentWidth(2, for: .plainText)

    #expect(store.indentationProfile(for: .grammar(.markdown)).usesTabs)
    #expect(store.indentationProfile(for: .grammar(.markdown)).tabWidth == 8)
    #expect(!store.indentationProfile(for: .plainText).usesTabs)
    #expect(store.indentationProfile(for: .plainText).indentWidth == 2)

    // Neu geladener Store (gleiche Defaults) sieht dieselben Werte.
    let reloaded = SoftWrapProfileStore(defaults: defaults)
    #expect(reloaded.indentationProfile(for: .grammar(.markdown)).usesTabs)
    #expect(reloaded.indentationProfile(for: .grammar(.markdown)).tabWidth == 8)

    // Ungültige Breite fällt auf den Werkstandard zurück.
    store.setIndentWidth(99, for: .plainText)
    #expect(store.indentationProfile(for: .plainText).indentWidth == 4)

    // Format-Reset räumt auch die Einrückung ab.
    store.resetToFactoryDefault(for: .grammar(.markdown))
    #expect(store.indentationProfile(for: .grammar(.markdown)) == .factory)
    #expect(!store.hasOverride(for: .grammar(.markdown)))
}

@Test("Bestehende v2-Payload ohne Einrückungsfelder lädt unverändert")
func payloadWithoutIndentFieldsStillLoads() throws {
    let suite = "fastra-softwrap-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    // Payload der Etappen 1-3 (ohne Einrückungsfelder) direkt hinterlegen.
    let legacyJSON = #"{"version":2,"formats":{"markdown":{"softWrapEnabled":true}}}"#
    defaults.set(Data(legacyJSON.utf8), forKey: SoftWrapProfileStore.Keys.profiles)
    let store = SoftWrapProfileStore(defaults: defaults)
    #expect(store.isEnabled(for: .grammar(.markdown)))
    #expect(store.indentationProfile(for: .grammar(.markdown)) == .factory)
}

// MARK: - Profil-Helfer

@Test("whitespace(forColumns:) drückt Spalten in Profil-Einheiten aus")
func profileWhitespaceExpression() {
    let spaces = IndentationProfile(usesTabs: false, indentWidth: 4, tabWidth: 4)
    #expect(spaces.whitespace(forColumns: 6) == "      ")
    let tabs = IndentationProfile(usesTabs: true, indentWidth: 4, tabWidth: 4)
    #expect(tabs.whitespace(forColumns: 6) == "\t  ")
    #expect(tabs.whitespace(forColumns: 8) == "\t\t")
    #expect(tabs.whitespace(forColumns: 0) == "")
}

@Test("visualColumns rechnet Tabs tabstopp-bewusst")
func profileVisualColumns() {
    let profile = IndentationProfile(usesTabs: false, indentWidth: 4, tabWidth: 4)
    #expect(profile.visualColumns(ofLeadingWhitespace: Substring("\t")) == 4)
    #expect(profile.visualColumns(ofLeadingWhitespace: Substring("  \t")) == 4)
    #expect(profile.visualColumns(ofLeadingWhitespace: Substring("\t  ")) == 6)
    #expect(profile.visualColumns(ofLeadingWhitespace: Substring("")) == 0)
}

// MARK: - Einfügen und Einrückung angleichen (Tabellen-Tests)

private let spaces4 = IndentationProfile(usesTabs: false, indentWidth: 4, tabWidth: 4)
private let tabs4 = IndentationProfile(usesTabs: true, indentWidth: 4, tabWidth: 4)

@Test("Verschachtelter Block landet auf der Ziel-Einrückung, relativ erhalten")
func pasteMatchNestedBlock() {
    let clipboard = "    if x {\n        y()\n    }\n"
    let matched = IndentationMatchingPaste.matchedText(
        clipboard: clipboard, targetColumns: 8, indentFirstLine: true,
        lineEnding: .lf, profile: spaces4)
    #expect(matched == "        if x {\n            y()\n        }\n")
}

@Test("Gemischte Tabs/Leerzeichen werden visuell gemessen und neu ausgedrückt")
func pasteMatchMixedWhitespace() {
    // "\t" (4 Spalten) und "    " (4 Spalten) sind dieselbe Basis; die
    // zweite Zeile liegt eine Stufe tiefer (8 Spalten).
    let clipboard = "\ta\n    \tb"
    let matched = IndentationMatchingPaste.matchedText(
        clipboard: clipboard, targetColumns: 4, indentFirstLine: true,
        lineEnding: .lf, profile: spaces4)
    #expect(matched == "    a\n        b")
}

@Test("Tab-Profil erzeugt Tabs plus Rest-Leerzeichen")
func pasteMatchTabProfile() {
    let clipboard = "a\n  b\n"
    let matched = IndentationMatchingPaste.matchedText(
        clipboard: clipboard, targetColumns: 8, indentFirstLine: true,
        lineEnding: .lf, profile: tabs4)
    #expect(matched == "\t\ta\n\t\t  b\n")
}

@Test("Leerzeilen bleiben leer, ohne erfundene Einrückung")
func pasteMatchKeepsBlankLines() {
    let clipboard = "  a\n\n   \n  b\n"
    let matched = IndentationMatchingPaste.matchedText(
        clipboard: clipboard, targetColumns: 4, indentFirstLine: true,
        lineEnding: .lf, profile: spaces4)
    #expect(matched == "    a\n\n\n    b\n")
}

@Test("CRLF-Dokument: alle erzeugten Umbrüche folgen der Dokument-Konvention")
func pasteMatchUsesDocumentLineEnding() {
    let clipboard = "a\nb\r\nc"
    let matched = IndentationMatchingPaste.matchedText(
        clipboard: clipboard, targetColumns: 0, indentFirstLine: true,
        lineEnding: .crlf, profile: spaces4)
    #expect(matched == "a\r\nb\r\nc")
}

@Test("Ohne abschließenden Clipboard-Umbruch endet auch das Ergebnis ohne")
func pasteMatchPreservesMissingTrailingNewline() {
    let with = IndentationMatchingPaste.matchedText(
        clipboard: "a\n", targetColumns: 0, indentFirstLine: true,
        lineEnding: .lf, profile: spaces4)
    #expect(with == "a\n")
    let without = IndentationMatchingPaste.matchedText(
        clipboard: "a", targetColumns: 0, indentFirstLine: true,
        lineEnding: .lf, profile: spaces4)
    #expect(without == "a")
}

@Test("Mitten in einer Zeile bleibt die erste Clipboard-Zeile ohne Zusatz-Einrückung")
func pasteMatchMidLineKeepsFirstLine() {
    let clipboard = "    x\n        y"
    let matched = IndentationMatchingPaste.matchedText(
        clipboard: clipboard, targetColumns: 8, indentFirstLine: false,
        lineEnding: .lf, profile: spaces4)
    #expect(matched == "x\n            y")
}

@Test("Unicode im Inhalt bleibt unangetastet")
func pasteMatchKeepsUnicode() {
    let clipboard = "  🎶 Noten\n    ⏸️ Pause"
    let matched = IndentationMatchingPaste.matchedText(
        clipboard: clipboard, targetColumns: 2, indentFirstLine: true,
        lineEnding: .lf, profile: spaces4)
    #expect(matched == "  🎶 Noten\n    ⏸️ Pause")
}

@Test("targetContext: leere Zielzeile erbt die zuletzt nicht leere Zeile")
func targetContextBlankLineInheritsPrevious() {
    let document = "    voll\n\n"
    // Einfügestelle am Anfang der leeren Zeile (Offset 9).
    let context = IndentationMatchingPaste.targetContext(
        documentText: document, insertionLocation: 9, profile: spaces4)
    #expect(context.columns == 4)
    #expect(context.prefixIsWhitespaceOnly)
}

@Test("targetContext: mitten in einer Zeile ist der Präfix nicht nur Whitespace")
func targetContextMidLine() {
    let document = "  code hier"
    let context = IndentationMatchingPaste.targetContext(
        documentText: document, insertionLocation: 6, profile: spaces4)
    #expect(context.columns == 2)
    #expect(!context.prefixIsWhitespaceOnly)
}

// MARK: - Shift mit Profil

@Test("shiftRight/shiftLeft folgen dem Einrückungsprofil")
func shiftFollowsProfile() throws {
    let spaces2 = IndentationProfile(usesTabs: false, indentWidth: 2, tabWidth: 4)
    let text = "eins\nzwei\n"
    let all = NSRange(location: 0, length: (text as NSString).length)

    let right = try #require(TextOperations.shiftRight(
        in: text, selection: all, profile: spaces2))
    #expect(right.newText == "  eins\n  zwei\n")

    let leftBack = try #require(TextOperations.shiftLeft(
        in: right.newText, selection: NSRange(location: 0,
                                              length: (right.newText as NSString).length),
        profile: spaces2))
    #expect(leftBack.newText == text)

    let tabRight = try #require(TextOperations.shiftRight(
        in: text, selection: all, profile: tabs4))
    #expect(tabRight.newText == "\teins\n\tzwei\n")
}
