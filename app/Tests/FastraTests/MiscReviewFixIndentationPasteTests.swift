// MiscReviewFixIndentationPasteTests.swift
//
// Regressionstest zu Fund G3 des Code-Reviews vom 2026-08-10.
//
// „Einfügen und Einrückung angleichen" rückte doppelt ein: `targetContext`
// meldete die volle Zielspalte, `matchedText` stellte sie der ersten Zeile
// voran — und der Editor ersetzte nur die Nullauswahl am Cursor, sodass die
// bereits vorhandene Einrückung davor stehen blieb. Auf einer automatisch
// eingerückten Leerzeile saß der Block dadurch eine Ebene zu tief.
//
// Die Tests bilden den Editor-Pfad rein rechnerisch nach (kein Fenster nötig):
// Kontext bestimmen, Text angleichen, den von `targetContext` gemeldeten
// Bereich ersetzen — genau so, wie es
// `EditorContextMenu.pasteMatchingIndentationInActiveEditor` tut.

import Foundation
import Testing
@testable import Fastra

private let spaces4 = IndentationProfile(usesTabs: false, indentWidth: 4, tabWidth: 4)
private let tabs4 = IndentationProfile(usesTabs: true, indentWidth: 4, tabWidth: 4)

/// Fensterloser Nachbau des Einfügens mit Angleichung.
/// `selectionLength` bildet eine vorhandene Auswahl ab (0 = reiner Cursor).
private func pasteMatchingIndentation(into document: String,
                                      at location: Int,
                                      clipboard: String,
                                      profile: IndentationProfile,
                                      selectionLength: Int = 0) -> String {
    let context = IndentationMatchingPaste.targetContext(
        documentText: document, insertionLocation: location, profile: profile)
    let matched = IndentationMatchingPaste.matchedText(
        clipboard: clipboard,
        targetColumns: context.columns,
        indentFirstLine: context.prefixIsWhitespaceOnly,
        lineEnding: .lf,
        profile: profile)
    let text = NSMutableString(string: document)
    let replaced = NSRange(
        location: context.replacementStart,
        length: location - context.replacementStart + selectionLength)
    text.replaceCharacters(in: replaced, with: matched)
    return text as String
}

@Test("targetContext meldet den Zeilenanfang, wenn vor dem Cursor nur Einrückung steht")
func miscReviewFix_targetContextReportsIndentPrefixStart() {
    // „def f():\n    x = 1\n    " — Cursor am Ende der automatisch
    // eingerückten Leerzeile (Offset 23).
    let document = "def f():\n    x = 1\n    "
    let context = IndentationMatchingPaste.targetContext(
        documentText: document, insertionLocation: 23, profile: spaces4)
    #expect(context.columns == 4)
    #expect(context.prefixIsWhitespaceOnly)
    #expect(context.replacementStart == 19,
            "Die vier vorhandenen Leerzeichen gehören in den ersetzten Bereich")
}

@Test("targetContext lässt den Bereich unangetastet, wenn echter Text vorausgeht")
func miscReviewFix_targetContextKeepsRangeMidLine() {
    let document = "  code hier"
    let context = IndentationMatchingPaste.targetContext(
        documentText: document, insertionLocation: 6, profile: spaces4)
    #expect(!context.prefixIsWhitespaceOnly)
    #expect(context.replacementStart == 6,
            "Mitten in einer Zeile darf nichts vor dem Cursor verschwinden")
}

@Test("Einfügen auf automatisch eingerückter Leerzeile rückt nicht doppelt ein")
func miscReviewFix_pasteOnAutoIndentedBlankLine() {
    let document = "def f():\n    x = 1\n    "
    let result = pasteMatchingIndentation(
        into: document, at: 23, clipboard: "if a:\n    b()", profile: spaces4)
    #expect(result == "def f():\n    x = 1\n    if a:\n        b()")
    #expect(!result.contains("        if a:"),
            "Der Block darf nicht eine Ebene zu tief sitzen")
}

@Test("Einfügen hinter der Einrückung einer Textzeile verdoppelt sie nicht")
func miscReviewFix_pasteAfterIndentOfTextLine() {
    // Cursor zwischen Einrückung und Text: „    |foo".
    let result = pasteMatchingIndentation(
        into: "    foo", at: 4, clipboard: "X", profile: spaces4)
    #expect(result == "    Xfoo")
}

@Test("Einfügen am Anfang einer leeren Zeile bleibt unverändert")
func miscReviewFix_pasteAtStartOfBlankLineUnchanged() {
    // Ohne Whitespace vor dem Cursor gibt es nichts zu ersetzen — das ist der
    // bisher schon korrekte Fall und darf sich nicht ändern.
    let result = pasteMatchingIndentation(
        into: "    voll\n\n", at: 9, clipboard: "X", profile: spaces4)
    #expect(result == "    voll\n    X\n")
}

@Test("Einfügen mit Angleichung im Tab-Profil ersetzt den vorhandenen Tab")
func miscReviewFix_pasteOnAutoIndentedBlankLineWithTabs() {
    let document = "\tfoo\n\t"
    let result = pasteMatchingIndentation(
        into: document, at: 6, clipboard: "bar", profile: tabs4)
    #expect(result == "\tfoo\n\tbar")
}

@Test("Eine Auswahl hinter der Einrückung wird samt Einrückung ersetzt")
func miscReviewFix_pasteReplacesSelectionAndIndent() {
    // „    foo" — „foo" ist ausgewählt, davor steht die Einrückung.
    let result = pasteMatchingIndentation(
        into: "    foo", at: 4, clipboard: "neu", profile: spaces4,
        selectionLength: 3)
    #expect(result == "    neu")
}
