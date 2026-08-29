// OpenTabsSearchTests.swift
//
// Sichert den Such-Scope „Geöffnet" ab (BBEdit „Open text documents",
// Handbuch 16.0.1 Kap. 7 S. 184): pure Multi-Tab-Suche, Gesamt-Cap,
// „Alle ersetzen" über alle Tabs und die Workspace-Verdrahtung
// (navMatches mit Tab-Ziel, Apply markiert dirty).

import Testing
import Foundation
import AppKit
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

@Test("Ohne offene Tabs bleibt auch ein ungültiges Pattern ein leeres Ergebnis")
func find_invalidPatternWithoutInputsStaysEmpty() {
    let r = OpenTabsSearch.find(
        tabs: [], options: SearchOptions(find: "(", replace: "")
    )
    #expect(r == .empty)
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
    let defaults = testSuiteDefaults(named: suite)
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
    ws.findPattern = plainFoo.find
    ws.replacePattern = plainFoo.replace
    ws.useRegex = plainFoo.isRegex
    ws.caseSensitive = plainFoo.caseSensitive
    // Ergebnis manuell setzen (der SearchRunner läuft async — hier zählt
    // nur das Mapping openResults → navMatches).
    let r = OpenTabsSearch.find(
        tabs: ws.tabs.map { OpenTabsSearch.TabInput(id: $0.id, title: $0.title,
                                                    content: $0.content) },
        options: plainFoo)
    ws.openResults = r.perTab
    ws.openTotalMatches = r.totalMatches
    ws.visibleBufferResultsOptions = plainFoo
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
    ws.openResults = OpenTabsSearch.find(
        tabs: ws.tabs.map {
            OpenTabsSearch.TabInput(id: $0.id, title: $0.title,
                                    content: $0.content)
        }, options: ws.currentSearchOptions
    ).perTab
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

@Test("Alle ersetzen sperrt Treffer jenseits der sichtbaren Geöffnet-Vorschau")
func workspace_applyAllInOpenTabsRejectsCappedPreview() {
    let original = Array(repeating: "foo", count: BufferSearch.defaultMaxMatches + 1)
        .joined(separator: " ")
    let ws = makeWorkspace(tabs: [("viele.txt", original)])
    ws.findPattern = "foo"
    ws.replacePattern = "X"
    ws.useRegex = false
    ws.caseSensitive = true
    let result = OpenTabsSearch.find(
        tabs: [OpenTabsSearch.TabInput(
            id: ws.tabs[0].id, title: ws.tabs[0].title, content: original
        )],
        options: ws.currentSearchOptions,
        maxTotal: BufferSearch.defaultMaxMatches
    )
    #expect(result.wasCapped)
    ws.openResults = result.perTab
    ws.openTotalMatches = result.totalMatches
    ws.openResultsWereCapped = result.wasCapped
    ws.visibleBufferResultsOptions = ws.currentSearchOptions

    #expect(!ws.canApplyAllInOpenTabs)
    #expect(ws.applyAllInOpenTabs() == 0)
    #expect(ws.tabs[0].content == original,
            "Der nicht sichtbare 2.001. Treffer darf nicht ohne Vorschau ersetzt werden")
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
    ws.visibleBufferResultsOptions = ws.currentSearchOptions
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
    let result = OpenTabsSearch.find(
        tabs: ws.tabs.map {
            OpenTabsSearch.TabInput(id: $0.id, title: $0.title,
                                    content: $0.content)
        }, options: ws.currentSearchOptions
    )
    ws.openResults = result.perTab
    ws.openTotalMatches = result.totalMatches
    ws.openResultsWereCapped = result.wasCapped
    ws.visibleBufferResultsOptions = ws.currentSearchOptions
    #expect(ws.canApplyAllInOpenTabs,
            "Der Test braucht vor der Eingabeänderung eine echte freigegebene Vorschau")

    // Muster geändert, Neulauf noch nicht gelaufen → die sichtbare
    // Trefferzahl gehört zum alten Muster und gibt nichts frei.
    ws.findPattern = "bar"
    #expect(ws.applyAllInOpenTabs() == 0)
    #expect(ws.tabs[0].content == "foo bar")
}

@Test("Geöffnet-Ersetzen sperrt eine teilweise schreibgeschützte Trefferbasis")
func workspace_openReplaceRejectsReadOnlyMatches() {
    let ws = makeWorkspace(tabs: [("edit.txt", "foo"), ("HEAD:gone.txt", "foo")])
    ws.tabs[1].readOnlyReason = "Git-Vorversion"
    ws.tabs[1].gitSnapshotRequest = GitFileSnapshotRequest(
        repositoryPath: "/tmp/repo", path: "gone.txt", source: .head
    )
    ws.findPattern = "foo"
    ws.replacePattern = "X"
    ws.useRegex = false
    ws.caseSensitive = true
    let result = OpenTabsSearch.find(
        tabs: ws.tabs.map {
            OpenTabsSearch.TabInput(id: $0.id, title: $0.title,
                                    content: $0.content)
        }, options: ws.currentSearchOptions
    )
    ws.openResults = result.perTab
    ws.openTotalMatches = result.totalMatches
    ws.visibleBufferResultsOptions = ws.currentSearchOptions

    #expect(ws.openResultsContainReadOnlyTabs)
    #expect(!ws.canApplyAllInOpenTabs)
    #expect(ws.applyAllInOpenTabs() == 0)
    #expect(ws.tabs[0].content == "foo")
    #expect(!ws.tabs[0].isDirty)
    #expect(ws.tabs[1].content == "foo")
    #expect(!ws.tabs[1].isDirty)
}

@Test("Kopieren lässt die Zwischenablage bei veralteter Trefferbasis unverändert")
func workspace_copyHitsRefusesStalePreview() {
    let ws = makeWorkspace(tabs: [("a.txt", "foo")])
    ws.findPattern = "foo"
    ws.useRegex = false
    ws.caseSensitive = true
    let result = OpenTabsSearch.find(
        tabs: ws.tabs.map {
            OpenTabsSearch.TabInput(id: $0.id, title: $0.title,
                                    content: $0.content)
        }, options: ws.currentSearchOptions
    )
    ws.openResults = result.perTab
    ws.openTotalMatches = result.totalMatches
    ws.visibleBufferResultsOptions = ws.currentSearchOptions

    let pasteboard = NSPasteboard(name: .init("fastra.test.copy-stale.\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString("behalten", forType: .string)
    ws.findPattern = "bar"

    #expect(ws.navMatches.isEmpty)
    ws.copyHitsToClipboard(pasteboard)
    #expect(pasteboard.string(forType: .string) == "behalten")
}

@Test("Einzel-Ersetzen im Geöffnet-Scope ändert den gewählten Ziel-Tab")
func workspace_replaceActiveOpenMatchTargetsItsTab() {
    let ws = makeWorkspace(tabs: [("a.txt", "foo eins"), ("b.txt", "foo zwei")])
    ws.findPattern = "foo"
    ws.replacePattern = "X"
    ws.useRegex = false
    ws.caseSensitive = true
    let result = OpenTabsSearch.find(
        tabs: ws.tabs.map {
            OpenTabsSearch.TabInput(id: $0.id, title: $0.title,
                                    content: $0.content)
        }, options: ws.currentSearchOptions
    )
    ws.openResults = result.perTab
    ws.openTotalMatches = result.totalMatches
    ws.visibleBufferResultsOptions = ws.currentSearchOptions
    ws.activeMatchIndex = 1
    let targetTabID = ws.tabs[1].id
    let oldReloadNonce = ws.editorReloadNonce

    #expect(ws.canReplaceActiveSearchMatch)
    ws.replaceActiveMatch()

    #expect(ws.tabs[0].content == "foo eins")
    #expect(!ws.tabs[0].isDirty)
    #expect(ws.tabs[1].content == "X zwei")
    #expect(ws.tabs[1].isDirty)
    #expect(ws.activeTabID == targetTabID)
    #expect(ws.editorReloadNonce == oldReloadNonce + 1)
}

@Test("Einzel-Ersetzen im Geöffnet-Scope lehnt einen read-only Ziel-Tab ab")
func workspace_replaceActiveOpenMatchRejectsReadOnlyTarget() {
    let ws = makeWorkspace(tabs: [("edit.txt", "foo"), ("HEAD:gone.txt", "foo")])
    ws.tabs[1].readOnlyReason = "Git-Vorversion"
    ws.tabs[1].gitSnapshotRequest = GitFileSnapshotRequest(
        repositoryPath: "/tmp/repo", path: "gone.txt", source: .head
    )
    ws.findPattern = "foo"
    ws.replacePattern = "X"
    ws.useRegex = false
    ws.caseSensitive = true
    let result = OpenTabsSearch.find(
        tabs: ws.tabs.map {
            OpenTabsSearch.TabInput(id: $0.id, title: $0.title,
                                    content: $0.content)
        }, options: ws.currentSearchOptions
    )
    ws.openResults = result.perTab
    ws.openTotalMatches = result.totalMatches
    ws.visibleBufferResultsOptions = ws.currentSearchOptions
    ws.activeMatchIndex = 1

    #expect(!ws.canReplaceActiveSearchMatch)
    ws.replaceActiveMatch()
    #expect(ws.tabs[1].content == "foo")
    #expect(!ws.tabs[1].isDirty)
}

@Test("Geöffnet-Einzel-Ersetzen sucht asynchron weiter")
@MainActor
func workspace_replaceActiveOpenMatchFindsAgain() async throws {
    let ws = makeWorkspace(tabs: [("a.txt", "MARKER eins"),
                                  ("b.txt", "MARKER zwei")])
    ws.showSearchDialog = true
    ws.useRegex = false
    ws.caseSensitive = true
    ws.findPattern = "MARKER"
    ws.replacePattern = "ERSETZT"

    // Die Frist ist eine Hänge-Erkennung, keine Laufzeitbehauptung: Im ruhigen
    // Lauf liefert der Runner in Millisekunden. In der vollen parallelen Suite
    // konkurrieren der 120-ms-Debounce (Main-Queue) und der detachte Suchtask
    // aber mit der Arbeit aller anderen Tests; 5 Sekunden rissen dabei
    // lastabhängig (2026-08-16 mehrfach reproduziert), obwohl der Lauf danach
    // korrekt konvergierte. 30 Sekunden machen echtes Steckenbleiben weiter
    // sicher rot, ohne unter Last falsch zu alarmieren.
    #expect(await waitUntil(timeout: 30) {
        ws.openTotalMatches == 2 && !ws.bufferSearching
            && ws.visibleBufferResultsOptions == ws.currentSearchOptions
    }, "Der erste Geöffnet-Lauf hat nicht geliefert")
    #expect(ws.openTotalMatches == 2)

    ws.activeMatchIndex = 1
    ws.replaceActiveMatch()
    #expect(ws.tabs[1].content == "ERSETZT zwei")

    #expect(await waitUntil(timeout: 30) {
        ws.openTotalMatches == 1 && !ws.bufferSearching
            && ws.visibleBufferResultsOptions == ws.currentSearchOptions
    }, "Der Neulauf nach Einzel-Ersetzen fehlt")
    #expect(ws.openTotalMatches == 1)
    #expect(ws.activeMatchIndex == 0)
    #expect(ws.activeTabID == ws.tabs[0].id,
            "Nach dem letzten Treffer muss der verbleibende Treffer aktiv sein")
}

@Test("Datei-Ersetzen meldet in read-only Git-Vorversion keinen Erfolg")
func workspace_fileReplaceRejectsReadOnlySnapshot() {
    let ws = makeWorkspace(tabs: [("HEAD:gone.txt", "foo")])
    ws.scope = .file
    ws.tabs[0].readOnlyReason = "Git-Vorversion"
    ws.tabs[0].gitSnapshotRequest = GitFileSnapshotRequest(
        repositoryPath: "/tmp/repo", path: "gone.txt", source: .head
    )
    ws.findPattern = "foo"
    ws.replacePattern = "X"
    ws.useRegex = false
    ws.caseSensitive = true
    let result = BufferSearch.find(in: "foo", options: ws.currentSearchOptions)
    ws.bufferMatches = result.matches
    ws.bufferTotalMatches = result.totalMatches
    ws.visibleBufferResultsOptions = ws.currentSearchOptions
    let oldReloadNonce = ws.editorReloadNonce

    #expect(!ws.canApplyAllInActiveBuffer)
    #expect(!ws.canReplaceActiveSearchMatch)
    #expect(!ws.applyAllInActiveBuffer())
    ws.replaceActiveMatch()
    #expect(ws.tabs[0].content == "foo")
    #expect(!ws.tabs[0].isDirty)
    #expect(ws.editorReloadNonce == oldReloadNonce)
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
    ws.showSearchDialog = true
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
    // 30 s Frist = Hänge-Erkennung unter voller Parallellast (siehe Test oben).
    #expect(await waitUntil(timeout: 30) {
        ws.openTotalMatches == 1 && !ws.bufferSearching
            && ws.visibleBufferResultsOptions == ws.currentSearchOptions
    }, "Der Such-Runner hat nicht geliefert")
    #expect(ws.visibleBufferResultsOptions == ws.currentSearchOptions,
            "Der Geöffnet-Lauf hat seine Vorschau nicht als aktuell ausgewiesen")

    #expect(ws.applyAllInOpenTabs() == 1)
    #expect(ws.tabs[0].content == "ERSETZT eins")
}

@Test("Der Such-Runner gibt Alle ersetzen im Datei-Scope wieder frei")
@MainActor
func workspace_runnerRestoresFileScopeApplyGate() async throws {
    let ws = makeWorkspace(tabs: [("a.txt", "MARKER eins")])
    ws.showSearchDialog = true
    ws.scope = .file
    ws.useRegex = false
    ws.caseSensitive = true
    ws.findPattern = "MARKER"
    ws.replacePattern = "ERSETZT"

    // Gleiche vollständige Bedingung wie im Geöffnet-Fall (siehe dort);
    // 30 s Frist = Hänge-Erkennung unter voller Parallellast (siehe oben).
    #expect(await waitUntil(timeout: 30) {
        ws.bufferTotalMatches == 1 && !ws.bufferSearching
            && ws.visibleBufferResultsOptions == ws.currentSearchOptions
    }, "Der Such-Runner hat nicht geliefert")
    #expect(ws.visibleBufferResultsOptions == ws.currentSearchOptions,
            "Der Datei-Lauf hat seine Vorschau nicht als aktuell ausgewiesen")

    ws.applyAllInActiveBuffer()
    #expect(ws.tabs[0].content == "ERSETZT eins")
}
