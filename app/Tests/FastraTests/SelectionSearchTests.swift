// SelectionSearchTests.swift
//
// Tests für „Nur in Auswahl" (K3) und „Auswahl als Suchbegriff" (K5):
//   • BufferSearch.find / replaceAll mit searchRange (reine Engine).
//   • Workspace-Hilfslogik (selectionIsMultiline, setSearchInSelectionOnly,
//     captureSelectionForSearch, useSelectionForFind).

import Foundation
import Testing
@testable import Fastra

private func plain(_ find: String, _ replace: String = "X") -> SearchOptions {
    SearchOptions(find: find, replace: replace, isRegex: false)
}

// MARK: - BufferSearch mit searchRange (K3)

@Test("find(searchRange:) findet nur Treffer innerhalb der Range")
func find_restrictedToRange() {
    let text = "foo bar foo"          // „foo" an Offset 0 und 8
    // Range deckt nur „r foo" ab (Offset 6, Länge 5) → nur der zweite Treffer.
    let r = BufferSearch.find(in: text, options: plain("foo"),
                              searchRange: NSRange(location: 6, length: 5))
    #expect(r.totalMatches == 1)
    #expect(r.matches.count == 1)
    #expect(r.matches.first?.range.location == 8)
}

@Test("find(searchRange:) lässt Zeile/Spalte ABSOLUT zum ganzen Text")
func find_rangeKeepsAbsoluteLineNumbers() {
    let text = "aaa\nfoo\nfoo"        // „foo" in Zeile 2 (Offset 4) und Zeile 3 (Offset 8)
    let r = BufferSearch.find(in: text, options: plain("foo"),
                              searchRange: NSRange(location: 8, length: 3))
    #expect(r.matches.count == 1)
    // Trotz Range-Beschränkung: Zeilennummer bezieht sich auf den Gesamttext.
    #expect(r.matches.first?.line == 3)
    #expect(r.matches.first?.column == 1)
}

@Test("find ohne searchRange findet weiterhin alle Treffer (Baseline)")
func find_withoutRangeUnchanged() {
    let r = BufferSearch.find(in: "foo bar foo", options: plain("foo"))
    #expect(r.totalMatches == 2)
}

@Test("replaceAll(searchRange:) ersetzt nur innerhalb der Range")
func replaceAll_restrictedToRange() {
    let text = "foo bar foo"
    // Range „bar foo" (Offset 4, Länge 7) → nur der zweite „foo" wird ersetzt.
    let out = BufferSearch.replaceAll(in: text, options: plain("foo", "X"),
                                      searchRange: NSRange(location: 4, length: 7))
    #expect(out == "foo bar X")
}

@Test("replaceAll ohne Range ersetzt überall (Baseline)")
func replaceAll_withoutRangeAll() {
    let out = BufferSearch.replaceAll(in: "foo bar foo", options: plain("foo", "X"))
    #expect(out == "X bar X")
}

// MARK: - Workspace-Hilfslogik

@Test("selectionIsMultiline erkennt Zeilenumbruch in der Selektion")
func selectionIsMultiline_detectsNewline() {
    let text = "abc\ndef"
    // „c\nd" (Offset 2, Länge 3) umspannt den Umbruch.
    #expect(Workspace.selectionIsMultiline(text: text, range: NSRange(location: 2, length: 3)))
    // „abc" (Offset 0, Länge 3) liegt komplett in Zeile 1.
    #expect(!Workspace.selectionIsMultiline(text: text, range: NSRange(location: 0, length: 3)))
    // Leere Selektion → nie mehrzeilig.
    #expect(!Workspace.selectionIsMultiline(text: text, range: NSRange(location: 0, length: 0)))
}

@MainActor
private func makeWorkspace(content: String) -> Workspace {
    let suite = "fastra.tests.selws.\(UUID().uuidString)"
    let ws = Workspace(defaults: UserDefaults(suiteName: suite)!)
    ws.tabs = [EditorTab(title: "t", path: "-", content: content)]
    ws.activeTabID = ws.tabs[0].id
    return ws
}

@Test("setSearchInSelectionOnly friert die aktuelle Selektion ein")
@MainActor
func setSelectionOnly_freezesRange() {
    let ws = makeWorkspace(content: "hello world")
    ws.selectionRange = NSRange(location: 0, length: 5)
    ws.setSearchInSelectionOnly(true)
    #expect(ws.searchInSelectionOnly)
    #expect(ws.activeSearchRange == NSRange(location: 0, length: 5))

    // Selektion wandert (z.B. Treffer-Sprung) — der eingefrorene Such-Bereich
    // bleibt unverändert (kein Zusammenschrumpfen).
    ws.selectionRange = NSRange(location: 6, length: 5)
    #expect(ws.activeSearchRange == NSRange(location: 0, length: 5))

    ws.setSearchInSelectionOnly(false)
    #expect(!ws.searchInSelectionOnly)
    #expect(ws.activeSearchRange == nil)
}

@Test("setSearchInSelectionOnly(true) ohne Selektion bleibt aus")
@MainActor
func setSelectionOnly_noSelectionStaysOff() {
    let ws = makeWorkspace(content: "hello")
    ws.selectionRange = nil
    ws.setSearchInSelectionOnly(true)
    #expect(!ws.searchInSelectionOnly)
    #expect(ws.activeSearchRange == nil)
}

@Test("captureSelectionForSearch: an bei mehrzeiliger, aus bei einzeiliger Auswahl")
@MainActor
func capture_autoEnablesForMultiline() {
    let ws = makeWorkspace(content: "abc\ndef\nghi")
    // Mehrzeilig (umspannt zwei Umbrüche) → an.
    ws.selectionRange = NSRange(location: 0, length: 9)
    ws.captureSelectionForSearch()
    #expect(ws.searchInSelectionOnly)

    // Einzeilige Auswahl → wieder aus.
    ws.selectionRange = NSRange(location: 0, length: 3)
    ws.captureSelectionForSearch()
    #expect(!ws.searchInSelectionOnly)
}

@Test("useSelectionForFind übernimmt den selektierten Text als Suchbegriff")
@MainActor
func useSelectionForFind_setsPattern() {
    let ws = makeWorkspace(content: "hello world")
    ws.findPattern = "alt"
    ws.selectionRange = NSRange(location: 6, length: 5)   // „world"
    ws.useSelectionForFind()
    #expect(ws.findPattern == "world")
}

@Test("useSelectionForFind ohne Selektion lässt das Pattern unverändert")
@MainActor
func useSelectionForFind_noSelectionNoOp() {
    let ws = makeWorkspace(content: "hello")
    ws.findPattern = "alt"
    ws.selectionRange = nil
    ws.useSelectionForFind()
    #expect(ws.findPattern == "alt")
}

// MARK: - „Nur in Auswahl": eingefrorene Range mitführen beim Ersetzen (K3)
//
// Regression: Einzel- und Voll-Ersetzen änderten die Textlänge, ließen aber
// `searchSelectionRange` stehen. Danach traf die nachfolgende Suche Bereiche
// außerhalb der ursprünglichen Auswahl (bei kürzerem Ersatz) bzw. verfehlte
// das Auswahl-Ende (bei längerem). Die Range muss um die Längenänderung
// mitwandern — Location bleibt (der Treffer liegt innerhalb der Auswahl),
// nur das Ende verschiebt sich.

@Test("replaceActiveMatch führt die eingefrorene Such-Selektion bei Längenänderung mit (K3)")
@MainActor
func replaceActiveMatch_adjustsFrozenSelectionRange() {
    let ws = makeWorkspace(content: "foo foo foo")   // „foo" bei Offset 0, 4, 8
    ws.scope = .file
    ws.useRegex = false
    ws.findPattern = "foo"
    ws.replacePattern = "XXXXX"                       // 5 statt 3 Zeichen → delta +2

    // „Nur in Auswahl" über die ersten zwei „foo" (Offset 0, Länge 7).
    ws.selectionRange = NSRange(location: 0, length: 7)
    ws.setSearchInSelectionOnly(true)
    #expect(ws.activeSearchRange == NSRange(location: 0, length: 7))

    // Trefferliste innerhalb der Auswahl materialisieren (wie der Such-Runner).
    let r = BufferSearch.find(in: ws.activeTabContent.wrappedValue,
                              options: ws.currentSearchOptions,
                              searchRange: ws.activeSearchRange)
    ws.bufferMatches = r.matches
    ws.bufferTotalMatches = r.totalMatches
    #expect(ws.bufferMatches.count == 2)
    ws.activeMatchIndex = 0

    // Ersten Treffer ersetzen: „foo foo foo" → „XXXXX foo foo" (delta +2).
    ws.replaceActiveMatch()

    // Eingefrorene Selektion deckt jetzt das längere Ende ab: Location 0, Länge 9.
    #expect(ws.activeSearchRange == NSRange(location: 0, length: 9))
    // Der verbliebene Treffer in der Auswahl ist das zweite „foo" (jetzt Offset 6);
    // das dritte „foo" (jetzt Offset 10) liegt außerhalb und darf NICHT erscheinen.
    #expect(ws.bufferMatches.count == 1)
    #expect(ws.bufferMatches.first?.range.location == 6)
}

@Test("applyAllInActiveBuffer führt die eingefrorene Such-Selektion mit (K3)")
@MainActor
func applyAllInSelection_adjustsFrozenSelectionRange() {
    let ws = makeWorkspace(content: "foo foo foo")
    ws.scope = .file
    ws.useRegex = false
    ws.findPattern = "foo"
    ws.replacePattern = "XXXXX"

    ws.selectionRange = NSRange(location: 0, length: 7)   // erste zwei „foo"
    ws.setSearchInSelectionOnly(true)
    let r = BufferSearch.find(in: ws.activeTabContent.wrappedValue,
                              options: ws.currentSearchOptions,
                              searchRange: ws.activeSearchRange)
    ws.bufferMatches = r.matches
    ws.bufferTotalMatches = r.totalMatches

    // Beide Treffer in der Auswahl ersetzen: „XXXXX XXXXX foo" (delta +4).
    ws.applyAllInActiveBuffer()
    #expect(ws.activeTabContent.wrappedValue == "XXXXX XXXXX foo")
    // Auswahl wandert von Länge 7 auf 7 + 4 = 11 mit (deckt „XXXXX XXXXX").
    #expect(ws.activeSearchRange == NSRange(location: 0, length: 11))
}
