// QuitConfirmationVisibilityTests.swift
//
// Eine Rückfrage muss zeigen, worum es geht (Fehlerbericht aus dem
// Arbeitsbetrieb, 2026-08-07): Beim Neustart nach einem Update erschien
// „Wollen Sie die Datei ‚Ohne Titel' sichern?" — zu einem Dokument, das in
// keinem Fenster und keinem Tab zu finden war. Ohne Gegenstand ist die Frage
// nicht beantwortbar: Wer „Nicht sichern" wählt, verwirft etwas Unbekanntes.
//
// Geprüft wird der Teil, der ohne Fenster prüfbar ist: Der Tab, über den
// gefragt wird, ist beim Fragen der AKTIVE. Dass zusätzlich das Fenster nach
// vorn kommt und verwaiste Workspaces gar nicht erst fragen, liegt in
// `AppDelegate.applicationShouldTerminate` und im Fenster-Selbsttest.

import Foundation
import Testing
@testable import Fastra

private func makeWorkspace() -> Workspace {
    let suite = "fastra-quitvisible-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return Workspace(defaults: defaults)
}

@Suite("Sichtbarkeit der Schließen-Rückfrage")
struct QuitConfirmationVisibilityTests {

    /// Der Kern des Befunds: Gefragt wird über den zweiten Tab, während der
    /// erste aktiv ist. Beim Erscheinen des Dialogs muss der GEFRAGTE Tab
    /// vorne liegen.
    @Test("Beim Beenden ist der gefragte Tab der aktive")
    func quitActivatesTheTabInQuestion() {
        let ws = makeWorkspace()
        let clean = EditorTab(title: "sauber.txt", path: "/tmp", content: "x", isDirty: false)
        let dirty = EditorTab(title: "wichtig.txt", path: "/tmp", content: "ungesichert", isDirty: true)
        ws.tabs = [clean, dirty]
        ws.activeTabID = clean.id

        var titleWhenAsked: String?
        var activeWhenAsked: UUID?
        ws.confirmCloseHandler = { title in
            titleWhenAsked = title
            activeWhenAsked = ws.activeTabID
            return .dontSave
        }

        _ = ws.confirmCloseAllDirtyForQuit()

        #expect(titleWhenAsked == "wichtig.txt")
        #expect(activeWhenAsked == dirty.id,
                "Der Dialog nannte einen Tab, der beim Fragen nicht sichtbar war.")
    }

    /// Dieselbe Zusage für das Schließen eines Fensters — derselbe Pfad,
    /// dieselbe Rückfrage.
    @Test("Beim Fensterschließen ist der gefragte Tab der aktive")
    func closingWindowActivatesTheTabInQuestion() {
        let ws = makeWorkspace()
        let clean = EditorTab(title: "sauber.txt", path: "/tmp", content: "x", isDirty: false)
        let dirty = EditorTab(title: "wichtig.txt", path: "/tmp", content: "ungesichert", isDirty: true)
        ws.tabs = [clean, dirty]
        ws.activeTabID = clean.id

        var activeWhenAsked: UUID?
        ws.confirmCloseHandler = { _ in
            activeWhenAsked = ws.activeTabID
            return .dontSave
        }

        _ = ws.prepareToCloseWindow()

        #expect(activeWhenAsked == dirty.id)
    }

    /// Ein unbenanntes, leeres Dokument hat nichts zu verlieren und darf
    /// niemanden aufhalten — genau der „Ohne Titel"-Fall aus dem Bericht.
    @Test("Leeres unbenanntes Dokument löst keine Rückfrage aus")
    func emptyUntitledNeverAsks() {
        let ws = makeWorkspace()
        var asked = false
        ws.confirmCloseHandler = { _ in asked = true; return .cancel }
        // Unbenannt, ohne Inhalt, aber als geändert markiert: entsteht durch
        // Tippen und wieder Löschen.
        let scratch = EditorTab(title: "Ohne Titel", path: "", content: "", isDirty: true)
        ws.tabs = [scratch]
        ws.activeTabID = scratch.id

        #expect(ws.confirmCloseAllDirtyForQuit() == true)
        #expect(asked == false)
    }

    /// Nach einem Abbruch darf der sichtbare Zustand nicht verschoben
    /// zurückbleiben: Das kurze Aktivieren für die Rückfrage ist Mittel zum
    /// Zweck, kein Nebeneffekt, den der Nutzer behält.
    @Test("Abbrechen stellt den ursprünglich aktiven Tab wieder her")
    func cancelRestoresPreviouslyActiveTab() {
        let ws = makeWorkspace()
        let clean = EditorTab(title: "sauber.txt", path: "/tmp", content: "x", isDirty: false)
        let dirty = EditorTab(title: "wichtig.txt", path: "/tmp", content: "ungesichert", isDirty: true)
        ws.tabs = [clean, dirty]
        ws.activeTabID = clean.id
        ws.confirmCloseHandler = { _ in .cancel }

        #expect(ws.confirmCloseAllDirtyForQuit() == false)
        #expect(ws.activeTabID == clean.id)
    }
}
