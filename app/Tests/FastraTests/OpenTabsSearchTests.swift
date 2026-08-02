// OpenTabsSearchTests.swift
//
// Sichert den Such-Scope „Geöffnet" ab (BBEdit „Open text documents",
// Handbuch 16.0.1 Kap. 7 S. 184): pure Multi-Tab-Suche, Gesamt-Cap,
// „Alle ersetzen" über alle Tabs und die Workspace-Verdrahtung
// (navMatches mit Tab-Ziel, Apply markiert dirty).

import Testing
import Foundation
@testable import Fastra

// MARK: - Hilfen

private func tab(_ title: String, _ content: String) -> OpenTabsSearch.TabInput {
    OpenTabsSearch.TabInput(id: UUID(), title: title, content: content)
}

private let plainFoo = SearchOptions(find: "foo", replace: "X",
                                     isRegex: false, caseSensitive: true)

// MARK: - Pure Suche

@Test("Findet Treffer über mehrere Tabs, Tabs ohne Treffer fehlen im Ergebnis")
func find_acrossTabs() {
    let tabs = [tab("a.txt", "foo bar\nfoo"), tab("b.txt", "nichts"),
                tab("c.txt", "foo")]
    let r = OpenTabsSearch.find(tabs: tabs, options: plainFoo)
    #expect(r.totalMatches == 3)
    #expect(r.perTab.count == 2)
    #expect(r.perTab.map(\.title) == ["a.txt", "c.txt"])
    #expect(r.invalidPatternMessage == nil)
}

@Test("Zeile/Spalte der Treffer sind tab-lokal (relativ zum jeweiligen Inhalt)")
func find_lineColumnPerTab() {
    let tabs = [tab("a.txt", "x\nfoo"), tab("b.txt", "foo")]
    let r = OpenTabsSearch.find(tabs: tabs, options: plainFoo)
    #expect(r.perTab[0].matches.first?.line == 2)
    #expect(r.perTab[1].matches.first?.line == 1)
}

@Test("Leeres Pattern liefert leeres Ergebnis")
func find_emptyPattern() {
    let r = OpenTabsSearch.find(tabs: [tab("a.txt", "foo")],
                                options: SearchOptions(find: "", replace: ""))
    #expect(r == .empty)
}

@Test("Ungültige RegEx liefert die Fehlermeldung, keine Treffer")
func find_invalidPattern() {
    let r = OpenTabsSearch.find(tabs: [tab("a.txt", "foo")],
                                options: SearchOptions(find: "(", replace: ""))
    #expect(r.invalidPatternMessage != nil)
    #expect(r.perTab.isEmpty)
}

@Test("Gesamt-Cap gilt über alle Tabs, gezählt wird trotzdem alles")
func find_totalCapAcrossTabs() {
    // 3 Tabs à 4 Treffer, Cap 6 → 6 materialisiert, 12 gezählt, capped.
    let tabs = (1...3).map { tab("t\($0).txt", "foo foo foo foo") }
    let r = OpenTabsSearch.find(tabs: tabs, options: plainFoo, maxTotal: 6)
    #expect(r.totalMatches == 12)
    #expect(r.perTab.reduce(0) { $0 + $1.matches.count } == 6)
    #expect(r.wasCapped == true)
}

// MARK: - Alle ersetzen (pur)

@Test("replaceAll liefert neue Inhalte NUR für geänderte Tabs")
func replaceAll_onlyChangedTabs() {
    let a = tab("a.txt", "foo bar")
    let b = tab("b.txt", "nichts")
    let changed = OpenTabsSearch.replaceAll(tabs: [a, b], options: plainFoo)
    #expect(changed.count == 1)
    #expect(changed[a.id] == "X bar")
}

@Test("replaceAll mit Backrefs über mehrere Tabs")
func replaceAll_backrefs() {
    let a = tab("a.txt", "Müller, Daniel")
    let b = tab("b.txt", "Lang, Marie")
    let opts = SearchOptions(find: "(\\w+), (\\w+)", replace: "$2 $1")
    let changed = OpenTabsSearch.replaceAll(tabs: [a, b], options: opts)
    #expect(changed[a.id] == "Daniel Müller")
    #expect(changed[b.id] == "Marie Lang")
}

// MARK: - Workspace-Verdrahtung

private func makeWorkspace(tabs tabContents: [(String, String)]) -> Workspace {
    // Isolierte Defaults-Suite (recordSearchHistory darf nicht in die
    // echten Nutzer-Defaults leaken) — Muster wie TabCloseConfirmationTests.
    let suite = "fastra-openscope-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let ws = Workspace(defaults: defaults)
    ws.tabs = tabContents.map { EditorTab(title: $0.0, path: "—", content: $0.1) }
    ws.activeTabID = ws.tabs[0].id
    ws.scope = .open
    return ws
}

@Test("navMatches trägt im Geöffnet-Scope die Ziel-Tab-ID")
func workspace_navMatchesCarryTabID() {
    let ws = makeWorkspace(tabs: [("a.txt", "foo"), ("b.txt", "foo")])
    // Ergebnis manuell setzen (der SearchRunner läuft async — hier zählt
    // nur das Mapping openResults → navMatches).
    let r = OpenTabsSearch.find(
        tabs: ws.tabs.map { OpenTabsSearch.TabInput(id: $0.id, title: $0.title,
                                                    content: $0.content) },
        options: plainFoo)
    ws.openResults = r.perTab
    ws.openTotalMatches = r.totalMatches
    let nav = ws.navMatches
    #expect(nav.count == 2)
    #expect(nav[0].tabID == ws.tabs[0].id)
    #expect(nav[1].tabID == ws.tabs[1].id)
    #expect(nav.allSatisfy { $0.url == nil })
}

@Test("applyAllInOpenTabs ersetzt in allen Tabs und markiert sie dirty")
func workspace_applyAllInOpenTabs() {
    let ws = makeWorkspace(tabs: [("a.txt", "foo bar"), ("b.txt", "kein Treffer"),
                                  ("c.txt", "foo")])
    ws.findPattern = "foo"
    ws.replacePattern = "X"
    ws.useRegex = false
    ws.caseSensitive = true
    // Guard-Futter: der Apply-Pfad prüft den Treffer-Stand des Runners UND
    // ob dieser Stand zu den aktuellen Suchoptionen gehört.
    ws.openTotalMatches = 2
    ws.visibleBufferResultsOptions = ws.currentSearchOptions
    let changedCount = ws.applyAllInOpenTabs()
    #expect(changedCount == 2)
    #expect(ws.tabs[0].content == "X bar")
    #expect(ws.tabs[0].isDirty == true)
    #expect(ws.tabs[1].content == "kein Treffer")
    #expect(ws.tabs[1].isDirty == false)
    #expect(ws.tabs[2].content == "X")
    #expect(ws.tabs[2].isDirty == true)
}

@Test("applyAllInOpenTabs ohne Treffer-Stand tut nichts")
func workspace_applyAllGuard() {
    let ws = makeWorkspace(tabs: [("a.txt", "foo")])
    ws.findPattern = "foo"
    ws.replacePattern = "X"
    // openTotalMatches bleibt 0 → Guard greift.
    #expect(ws.applyAllInOpenTabs() == 0)
    #expect(ws.tabs[0].content == "foo")
}

@Test("Extract im Geöffnet-Scope sammelt Treffer aus allen Tabs")
func workspace_extractInOpenScope() {
    let ws = makeWorkspace(tabs: [("a.txt", "foo eins"), ("b.txt", "foo zwei")])
    ws.findPattern = "foo \\w+"
    ws.replacePattern = ""   // Demo-Voreinstellung leeren → Roh-Extraktion
    ws.useRegex = true
    let r = OpenTabsSearch.find(
        tabs: ws.tabs.map { OpenTabsSearch.TabInput(id: $0.id, title: $0.title,
                                                    content: $0.content) },
        options: ws.currentSearchOptions)
    ws.openResults = r.perTab
    ws.openTotalMatches = r.totalMatches
    #expect(ws.extractHitsToNewTab() == true)
    #expect(ws.tabs.last?.content == "foo eins\nfoo zwei\n")
}

@Test("Alle ersetzen im Geöffnet-Scope hält dieselbe Vorschau-Grenze")
func workspace_applyAllInOpenTabs_refusesStalePreview() {
    let ws = makeWorkspace(tabs: [("a.txt", "foo bar")])
    ws.findPattern = "foo"
    ws.replacePattern = "X"
    ws.useRegex = false
    ws.caseSensitive = true
    ws.openTotalMatches = 1
    ws.visibleBufferResultsOptions = ws.currentSearchOptions

    // Muster geändert, Neulauf noch nicht gelaufen → die sichtbare
    // Trefferzahl gehört zum alten Muster und gibt nichts frei.
    ws.findPattern = "bar"
    #expect(ws.applyAllInOpenTabs() == 0)
    #expect(ws.tabs[0].content == "foo bar")
}

// Der Selbsttest `openscope` fiel am 2026-08-02 auf eine Lücke herein, die
// kein Test mit von Hand gesetztem Zustand sehen konnte: Die Freigabe für
// „Alle ersetzen" wurde zwar bei jeder Eingabeänderung entzogen, vom
// Geöffnet-Lauf des Such-Runners aber nie wieder erteilt. Dieser Test geht
// deshalb bewusst über den ECHTEN Runner samt Verzögerung.
@Test("Der Such-Runner gibt Alle ersetzen im Geöffnet-Scope wieder frei")
@MainActor
func workspace_runnerRestoresOpenScopeApplyGate() async throws {
    let ws = makeWorkspace(tabs: [("a.txt", "MARKER eins"), ("b.txt", "ohne Treffer")])
    ws.useRegex = false
    ws.caseSensitive = true
    ws.findPattern = "MARKER"
    ws.replacePattern = "ERSETZT"

    // Warten, bis der Lauf fertig ist UND seine Treffer als zu den aktuellen
    // Eingaben gehörig ausgewiesen hat. Genau dieses Ausweisen fehlte im
    // Geöffnet-Lauf: Ohne es läuft die Schleife in ihre Frist und die Prüfung
    // darunter schlägt fehl.
    //
    // Warum die Bedingung so vollständig sein muss: Jede einzelne Zuweisung
    // oben stößt einen verzögerten Lauf an. Liegen zwei Zuweisungen unter Last
    // mehr als 120 ms auseinander, gibt es ZWEI Läufe — und die Trefferzahl des
    // ersten steht schon da, während der zweite noch aussteht.
    let deadline = Date().addingTimeInterval(5)
    while !(ws.openTotalMatches == 1 && !ws.bufferSearching
            && ws.visibleBufferResultsOptions == ws.currentSearchOptions),
          Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(ws.openTotalMatches == 1, "Der Such-Runner hat nicht geliefert")
    #expect(ws.visibleBufferResultsOptions == ws.currentSearchOptions,
            "Der Geöffnet-Lauf hat seine Vorschau nicht als aktuell ausgewiesen")

    #expect(ws.applyAllInOpenTabs() == 1)
    #expect(ws.tabs[0].content == "ERSETZT eins")
}

@Test("Der Such-Runner gibt Alle ersetzen im Datei-Scope wieder frei")
@MainActor
func workspace_runnerRestoresFileScopeApplyGate() async throws {
    let ws = makeWorkspace(tabs: [("a.txt", "MARKER eins")])
    ws.scope = .file
    ws.useRegex = false
    ws.caseSensitive = true
    ws.findPattern = "MARKER"
    ws.replacePattern = "ERSETZT"

    // Gleiche vollständige Bedingung wie im Geöffnet-Fall (siehe dort).
    let deadline = Date().addingTimeInterval(5)
    while !(ws.bufferTotalMatches == 1 && !ws.bufferSearching
            && ws.visibleBufferResultsOptions == ws.currentSearchOptions),
          Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(ws.bufferTotalMatches == 1, "Der Such-Runner hat nicht geliefert")
    #expect(ws.visibleBufferResultsOptions == ws.currentSearchOptions,
            "Der Datei-Lauf hat seine Vorschau nicht als aktuell ausgewiesen")

    ws.applyAllInActiveBuffer()
    #expect(ws.tabs[0].content == "ERSETZT eins")
}
