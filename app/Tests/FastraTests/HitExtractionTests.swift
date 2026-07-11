// HitExtractionTests.swift
//
// Sichert BBEdits „Extract" ab (Handbuch 16.0.1, S. 168/193): Treffer in
// ein neues Dokument, optional durchs Ersetzungsmuster transformiert.
// Getestet werden die pure Inhalts-Logik (HitExtraction) und der
// Workspace-Pfad (neuer Tab, aktiv, dirty, ungekappt).

import Testing
import Foundation
@testable import Fastra

// MARK: - Pure Inhalts-Logik

@Test("Roh-Extraktion: ein Treffer pro Zeile, End-Newline")
func content_rawMatches() {
    let r = BufferSearch.find(in: "foo bar foo",
                              options: SearchOptions(find: "foo", replace: "",
                                                     isRegex: false, caseSensitive: true))
    let out = HitExtraction.content(matches: r.matches, useReplacement: false)
    #expect(out == "foo\nfoo\n")
}

@Test("Transformierte Extraktion nutzt replacedText ($1-Backref)")
func content_transformedMatches() {
    let r = BufferSearch.find(in: "_TAG_alpha _TAG_beta",
                              options: SearchOptions(find: "_TAG_(\\w+)", replace: "$1"))
    let out = HitExtraction.content(matches: r.matches, useReplacement: true)
    #expect(out == "alpha\nbeta\n")
}

@Test("Leere Trefferliste liefert leeren String")
func content_emptyMatches() {
    #expect(HitExtraction.content(matches: [], useReplacement: false) == "")
}

@Test("Case-Operatoren wirken auch bei der Extraktion")
func content_caseOperators() {
    let r = BufferSearch.find(in: "Müller, Daniel",
                              options: SearchOptions(find: "(\\w+), (\\w+)",
                                                     replace: "\\U$2\\E $1"))
    let out = HitExtraction.content(matches: r.matches, useReplacement: true)
    #expect(out == "DANIEL Müller\n")
}

// MARK: - Workspace-Verdrahtung

private func makeWorkspace(content: String, find: String, replace: String = "",
                           isRegex: Bool = true) -> Workspace {
    // Isolierte UserDefaults-Suite: `extractHitsToNewTab` schreibt Such-
    // Historie — die darf nicht in die echten Defaults des Nutzers leaken
    // (gleiches Muster wie TabCloseConfirmationTests).
    let suite = "fastra-extract-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let ws = Workspace(defaults: defaults)
    // Definierter Ausgangszustand: genau ein Tab mit bekanntem Inhalt.
    ws.tabs = [EditorTab(title: "test.txt", path: "—", content: content)]
    ws.activeTabID = ws.tabs[0].id
    ws.findPattern = find
    ws.replacePattern = replace
    ws.useRegex = isRegex
    return ws
}

@Test("extractHitsToNewTab erzeugt neuen aktiven, dirty Tab mit dem Extrakt")
func workspace_extractCreatesActiveDirtyTab() {
    let ws = makeWorkspace(content: "foo 1\nbar 2\nfoo 3\n", find: "foo \\d")
    let before = ws.tabs.count
    #expect(ws.extractHitsToNewTab() == true)
    #expect(ws.tabs.count == before + 1)
    let newTab = ws.tabs.last!
    #expect(ws.activeTabID == newTab.id)
    #expect(newTab.isDirty == true)
    #expect(newTab.content == "foo 1\nfoo 3\n")
}

@Test("Gefülltes Ersetzen-Feld extrahiert transformiert")
func workspace_extractUsesReplacement() {
    let ws = makeWorkspace(content: "Nachname, Vorname\n",
                           find: "(\\w+), (\\w+)", replace: "$2 $1")
    #expect(ws.extractHitsToNewTab() == true)
    #expect(ws.tabs.last?.content == "Vorname Nachname\n")
}

@Test("0 Treffer → kein neuer Tab, Rückgabe false")
func workspace_extractNoMatchesNoTab() {
    let ws = makeWorkspace(content: "nichts hier\n", find: "zzz")
    let before = ws.tabs.count
    #expect(ws.extractHitsToNewTab() == false)
    #expect(ws.tabs.count == before)
}

@Test("Extract ist UNGEKAPPT: mehr Treffer als der Live-Listen-Cap")
func workspace_extractIgnoresListCap() {
    // 2500 Treffer > defaultMaxMatches (2000) — Extract muss alle liefern.
    let content = String(repeating: "x\n", count: 2500)
    let ws = makeWorkspace(content: content, find: "x", isRegex: false)
    #expect(ws.extractHitsToNewTab() == true)
    let lines = ws.tabs.last!.content.split(separator: "\n", omittingEmptySubsequences: false)
    // 2500 Treffer-Zeilen + 1 leeres Element hinter dem End-Newline.
    #expect(lines.count == 2501)
}
