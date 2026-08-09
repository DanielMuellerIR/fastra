// DirtyBaselineTests.swift
//
// Der Punkt im Tab folgt dem Vergleich mit dem gespeicherten Stand:
// Er erscheint bei der ersten echten Abweichung und verschwindet wieder,
// wenn Änderungen (z. B. per Rückgängig) den Inhalt exakt auf den
// gespeicherten Stand zurückführen — wie in VS Code und BBEdit.

import Foundation
import Testing
@testable import Fastra

private func makeWorkspace() -> (Workspace, String) {
    let suiteName = "fastra-dirty-tests-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suiteName)
    return (Workspace(defaults: defaults), suiteName)
}

@MainActor
@Test("Tippen setzt den Punkt, exakte Rücknahme entfernt ihn wieder")
func dirtyClearsWhenContentReturnsToBaseline() {
    let (ws, suite) = makeWorkspace()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    var tab = EditorTab(
        title: "notizen.md", path: "/tmp/notizen.md",
        url: URL(fileURLWithPath: "/tmp/notizen.md"),
        content: "Zeile 1\nZeile 2\n"
    )
    tab.recordSavedContentBaseline()
    ws.tabs = [tab]
    ws.activeTabID = tab.id

    // Zwei Leerzeilen anhängen — wie im gemeldeten Beispiel.
    ws.activeTabContent.wrappedValue = "Zeile 1\nZeile 2\n\n\n"
    #expect(ws.tabs[0].isDirty)

    // Exakt zurück auf den gespeicherten Stand (z. B. per Rückgängig).
    ws.activeTabContent.wrappedValue = "Zeile 1\nZeile 2\n"
    #expect(!ws.tabs[0].isDirty)
}

@MainActor
@Test("Rücknahme auf einen ANDEREN Stand lässt den Punkt stehen")
func dirtyStaysWhenContentDiffersFromBaseline() {
    let (ws, suite) = makeWorkspace()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    var tab = EditorTab(
        title: "a.txt", path: "/tmp/a.txt",
        url: URL(fileURLWithPath: "/tmp/a.txt"),
        content: "Original"
    )
    tab.recordSavedContentBaseline()
    ws.tabs = [tab]
    ws.activeTabID = tab.id

    ws.activeTabContent.wrappedValue = "Original plus"
    ws.activeTabContent.wrappedValue = "Origina"
    #expect(ws.tabs[0].isDirty)
}

@MainActor
@Test("Gleich lange, andere Inhalte bleiben dirty (Hash entscheidet)")
func dirtyStaysForSameLengthDifferentContent() {
    let (ws, suite) = makeWorkspace()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    var tab = EditorTab(
        title: "b.txt", path: "/tmp/b.txt",
        url: URL(fileURLWithPath: "/tmp/b.txt"),
        content: "abcd"
    )
    tab.recordSavedContentBaseline()
    ws.tabs = [tab]
    ws.activeTabID = tab.id

    ws.activeTabContent.wrappedValue = "abce"   // gleiche UTF-8-Länge
    #expect(ws.tabs[0].isDirty)
}

@MainActor
@Test("Nach dem Speichern gilt der neue Stand als Basis")
func baselineMovesToSavedState() throws {
    let (ws, suite) = makeWorkspace()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-dirty-\(UUID().uuidString).txt")
    try "Start\n".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    var tab = EditorTab(
        title: url.lastPathComponent, path: url.path, url: url,
        content: "Start\n"
    )
    tab.diskSnapshot = FileSnapshot(data: Data("Start\n".utf8), at: url)
    tab.recordSavedContentBaseline()
    ws.tabs = [tab]
    ws.activeTabID = tab.id

    ws.activeTabContent.wrappedValue = "Start\nMehr\n"
    #expect(ws.tabs[0].isDirty)
    #expect(ws.write(tab: ws.tabs[0], to: url))
    #expect(!ws.tabs[0].isDirty)

    // Rückgängig hinter den Speicherpunkt: alter Inhalt ist jetzt WIEDER
    // eine Abweichung von der (neuen) Basis.
    ws.activeTabContent.wrappedValue = "Start\n"
    #expect(ws.tabs[0].isDirty)

    // Und wieder vor: exakt der gespeicherte Stand → Punkt verschwindet.
    ws.activeTabContent.wrappedValue = "Start\nMehr\n"
    #expect(!ws.tabs[0].isDirty)
}

@MainActor
@Test("Zeilenende hin- und zurückschalten macht den Tab wieder sauber")
func lineEndingRoundTripClearsDirty() {
    let (ws, suite) = makeWorkspace()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    var tab = EditorTab(
        title: "c.txt", path: "/tmp/c.txt",
        url: URL(fileURLWithPath: "/tmp/c.txt"),
        content: "x\ny\n", lineEnding: .lf
    )
    tab.recordSavedContentBaseline()
    ws.tabs = [tab]
    ws.activeTabID = tab.id

    ws.setActiveLineEnding(.crlf)
    #expect(ws.tabs[0].isDirty)
    ws.setActiveLineEnding(.lf)
    #expect(!ws.tabs[0].isDirty)
}

@MainActor
@Test("Ohne gültige Basis (Papierkorb-Rettung) bleibt der Punkt bestehen")
func invalidatedBaselineKeepsDirty() {
    let (ws, suite) = makeWorkspace()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    var tab = EditorTab(
        title: "d.txt", path: "/tmp/d.txt",
        url: URL(fileURLWithPath: "/tmp/d.txt"),
        content: "Inhalt"
    )
    tab.recordSavedContentBaseline()
    tab.invalidateSavedContentBaseline()
    tab.isDirty = true
    ws.tabs = [tab]
    ws.activeTabID = tab.id

    ws.activeTabContent.wrappedValue = "Inhalt X"
    ws.activeTabContent.wrappedValue = "Inhalt"
    #expect(ws.tabs[0].isDirty)
}

@MainActor
@Test("Neuer leerer Entwurf: Tippen und vollständiges Löschen räumt den Punkt ab")
func untitledDraftClearsWhenEmptiedAgain() {
    let (ws, suite) = makeWorkspace()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let tab = EditorTab(title: "Ohne Titel", path: "noch nicht gespeichert")
    ws.tabs = [tab]
    ws.activeTabID = tab.id

    ws.activeTabContent.wrappedValue = "Entwurfstext"
    #expect(ws.tabs[0].isDirty)
    ws.activeTabContent.wrappedValue = ""
    #expect(!ws.tabs[0].isDirty)
}
