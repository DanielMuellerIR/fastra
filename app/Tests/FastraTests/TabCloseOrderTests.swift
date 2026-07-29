import Foundation
import Testing
@testable import Fastra

// Tests für die Reihenfolge beim Schließen von Tabs (Daniel-Befund 2026-07-29):
// Nach ⌘W soll der ZULETZT BENUTZTE verbleibende Tab aktiv werden — nicht der
// erste Tab der Leiste. Vorher passierte genau das: echtes Dokument geöffnet,
// mehrere leere Tabs per ⌘T angelegt, zweimal ⌘W gedrückt — und das echte
// Dokument war zu, weil das erste ⌘W den Fokus auf `tabs.first` (das Dokument)
// zurückwarf statt auf den vorletzten leeren Tab.

private func makeWorkspace() -> Workspace {
    let suite = "fastra-close-order-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return Workspace(defaults: defaults)
}

@Test("⌘T-Tabs schließen in umgekehrter Anlege-Reihenfolge, das Dokument bleibt")
func closeOrder_newTabsCloseBeforeRealDocument() {
    let ws = makeWorkspace()
    let real = EditorTab(title: "echt.txt", path: "/tmp", content: "Inhalt", isDirty: false)
    ws.tabs = [real]
    ws.activeTabID = real.id

    // Drei leere Tabs wie mit ⌘T anlegen — der jüngste ist danach aktiv.
    ws.openNewTab()
    ws.openNewTab()
    ws.openNewTab()
    #expect(ws.tabs.count == 4)

    // Zweimal ⌘W: Es müssen die beiden jüngsten leeren Tabs verschwinden.
    ws.closeActiveTab()
    ws.closeActiveTab()
    #expect(ws.tabs.count == 2)
    #expect(ws.tabs.contains(where: { $0.id == real.id }))   // Dokument lebt
    // Aktiv ist der verbliebene leere Tab (der als Erstes angelegte), nicht
    // das Dokument — das dritte ⌘W darf erst IHN schließen.
    #expect(ws.activeTabID == ws.tabs[1].id)
    ws.closeActiveTab()
    #expect(ws.tabs.map(\.id) == [real.id])
    #expect(ws.activeTabID == real.id)
}

@Test("Nach ⌘W wird der zuletzt benutzte Tab aktiv, nicht der Leisten-Nachbar")
func closeOrder_returnsToMostRecentlyUsedTab() {
    let ws = makeWorkspace()
    let a = EditorTab(title: "a.txt", path: "/tmp", content: "a", isDirty: false)
    let b = EditorTab(title: "b.txt", path: "/tmp", content: "b", isDirty: false)
    let c = EditorTab(title: "c.txt", path: "/tmp", content: "c", isDirty: false)
    ws.tabs = [a, b, c]

    // Benutzungsreihenfolge: b → a → c. Wer c schließt, soll bei a landen
    // (zuletzt benutzt), nicht bei b (Leisten-Nachbar wäre hier egal, aber
    // `tabs.first` wäre a nur zufällig — deshalb b zuerst aktivieren).
    ws.activeTabID = b.id
    ws.activeTabID = a.id
    ws.activeTabID = c.id
    ws.closeActiveTab()
    #expect(ws.activeTabID == a.id)
    ws.closeActiveTab()
    #expect(ws.activeTabID == b.id)
}

@Test("Ohne Benutzungs-Historie fällt ⌘W auf den Nachbar-Tab zurück")
func closeOrder_fallsBackToNeighbourWithoutHistory() {
    let ws = makeWorkspace()
    let a = EditorTab(title: "a.txt", path: "/tmp", content: "a", isDirty: false)
    let b = EditorTab(title: "b.txt", path: "/tmp", content: "b", isDirty: false)
    let c = EditorTab(title: "c.txt", path: "/tmp", content: "c", isDirty: false)
    ws.tabs = [a, b, c]
    // Nur der mittlere Tab war je aktiv — nach seinem Schließen gibt die
    // Merkliste nichts her, also übernimmt der rechte Nachbar.
    ws.activeTabID = b.id
    ws.closeActiveTab()
    #expect(ws.activeTabID == c.id)
}

@Test("Geschlossene Tabs verschwinden aus der Benutzungs-Historie")
func closeOrder_closedTabsLeaveHistory() {
    let ws = makeWorkspace()
    let a = EditorTab(title: "a.txt", path: "/tmp", content: "a", isDirty: false)
    let b = EditorTab(title: "b.txt", path: "/tmp", content: "b", isDirty: false)
    let c = EditorTab(title: "c.txt", path: "/tmp", content: "c", isDirty: false)
    ws.tabs = [a, b, c]
    ws.activeTabID = a.id
    ws.activeTabID = b.id
    // Benutzt wurden a, dann b. Nach dem Schließen von b folgt a — und der
    // Eintrag von b muss aus der Merkliste verschwinden, damit keine Leiche
    // einer geschlossenen ID spätere Auswahlen verfälscht.
    ws.closeTab(id: b.id)
    #expect(ws.activeTabID == a.id)
    ws.activeTabID = c.id
    ws.closeActiveTab()
    #expect(ws.activeTabID == a.id)
}
