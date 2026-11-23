import Foundation
import Testing
@testable import Fastra

// Schließen-Rückfrage bei ungespeicherten Änderungen nach BBEdit-Verhalten:
// Unveränderte Dokumente schließen sofort, dirty Dokumente fragen nach
// Sichern / Nicht sichern / Abbrechen.
// `Workspace.confirmCloseHandler` macht Routing, Tab-Aktivierung und Sichern
// vor dem Schließen fensterlos prüfbar. Den echten NSAlert prüft die GUI-Abnahme.

private func makeWorkspace() -> Workspace {
    let suite = "fastra-close-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    defaults.removePersistentDomain(forName: suite)
    return Workspace(defaults: defaults)
}

@Test("Sauberer Tab schließt ohne Rückfrage")
@MainActor
func close_cleanTabNoPrompt() {
    let ws = makeWorkspace()
    var asked = false
    ws.confirmCloseHandler = { _ in asked = true; return .cancel }
    let a = EditorTab(title: "a.txt", path: "/tmp", content: "x", isDirty: false)
    let b = EditorTab(title: "b.txt", path: "/tmp", content: "y", isDirty: false)
    ws.tabs = [a, b]
    ws.activeTabID = a.id
    ws.closeTab(id: a.id)
    #expect(asked == false)                  // sauberer Tab → keine Rückfrage
    #expect(ws.tabs.map(\.id) == [b.id])     // a ist weg
    #expect(ws.activeTabID == b.id)          // aktiver Tab nachgezogen
}

@Test("Dirty-Tab: Abbrechen lässt den Tab offen")
@MainActor
func close_dirtyCancelKeeps() {
    let ws = makeWorkspace()
    ws.confirmCloseHandler = { _ in .cancel }
    let a = EditorTab(title: "a.txt", path: "/tmp", content: "ungesichert", isDirty: true)
    ws.tabs = [a]
    ws.activeTabID = a.id
    ws.closeTab(id: a.id)
    #expect(ws.tabs.map(\.id) == [a.id])     // Abbrechen → Tab bleibt
}

@Test("Nicht-aktiven Dirty-Tab schließen: Abbrechen stellt den aktiven Tab wieder her")
@MainActor
func close_inactiveDirtyCancelRestoresActive() {
    let ws = makeWorkspace()
    ws.confirmCloseHandler = { _ in .cancel }
    let active = EditorTab(title: "active.txt", path: "/tmp", isDirty: false)
    let other = EditorTab(title: "other.txt", path: "/tmp",
                          content: "ungesichert", isDirty: true)
    ws.tabs = [active, other]
    ws.activeTabID = active.id

    ws.closeTab(id: other.id)

    #expect(ws.tabs.map(\.id) == [active.id, other.id])
    #expect(ws.activeTabID == active.id)
}

@Test("Dirty-Tab: Nicht sichern schließt und verwirft")
@MainActor
func close_dirtyDontSaveCloses() {
    let ws = makeWorkspace()
    ws.confirmCloseHandler = { _ in .dontSave }
    let a = EditorTab(title: "a.txt", path: "/tmp", content: "ungesichert", isDirty: true)
    let b = EditorTab(title: "b.txt", path: "/tmp", isDirty: false)
    ws.tabs = [a, b]
    ws.activeTabID = a.id
    ws.closeTab(id: a.id)
    #expect(ws.tabs.map(\.id) == [b.id])     // verworfen + geschlossen
    #expect(ws.activeTabID == b.id)
}

@Test("Dirty-Tab: Sichern schreibt auf die Platte und schließt dann")
@MainActor
func close_dirtySaveWritesAndCloses() throws {
    let ws = makeWorkspace()
    ws.confirmCloseHandler = { _ in .save }
    ws.closeWindowHandler = {}
    let url = testTemporaryDirectory()
        .appendingPathComponent("fastra-close-\(UUID().uuidString).txt")
    try "alt".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let a = EditorTab(title: url.lastPathComponent,
                      path: url.deletingLastPathComponent().path,
                      url: url, content: "neu gesichert", isDirty: true,
                      diskSnapshot: FileSnapshot(data: Data("alt".utf8), at: url))
    ws.tabs = [a]
    ws.activeTabID = a.id
    ws.closeTab(id: a.id)
    // Nach Fensterschluss im Willkommens-Zustand parken, damit eine später
    // wieder angezeigte Szene einen gültigen Tab besitzt.
    #expect(ws.tabs.map(\.isPristineScratch) == [true])
    let onDisk = try String(contentsOf: url, encoding: .utf8)
    #expect(onDisk == "neu gesichert")                       // vorher gesichert
}

@Test("Letzter Tab ohne Fenster-Handler fällt auf den Startzustand statt Null-Tab zurück")
@MainActor
func close_lastWithoutWindowHandlerReturnsToWelcome() {
    let ws = makeWorkspace()
    let tab = EditorTab(title: "sauber.txt", path: "/tmp", content: "x")
    ws.tabs = [tab]
    ws.activeTabID = tab.id

    ws.closeActiveTab()

    #expect(ws.tabs.count == 1)
    #expect(ws.tabs[0].isPristineScratch)
    #expect(ws.activeTabID == ws.tabs[0].id)
}

@Test("closeActiveTab nutzt denselben Rückfrage-Pfad")
@MainActor
func close_activeDelegates() {
    let ws = makeWorkspace()
    ws.confirmCloseHandler = { _ in .cancel }
    let a = EditorTab(title: "a.txt", path: "/tmp", content: "x", isDirty: true)
    ws.tabs = [a]
    ws.activeTabID = a.id
    ws.closeActiveTab()
    #expect(ws.tabs.count == 1)              // Abbrechen → bleibt offen
}

@Test("Letzter sauberer Tab schließt das Fenster statt einen Null-Tab-Rahmen zu lassen")
@MainActor
func close_lastCleanTabClosesWindow() {
    let ws = makeWorkspace()
    var windowCloseCount = 0
    var asked = false
    ws.closeWindowHandler = { windowCloseCount += 1 }
    ws.confirmCloseHandler = { _ in asked = true; return .cancel }
    let tab = EditorTab(title: "Ohne Titel", path: "noch nicht gespeichert")
    ws.tabs = [tab]
    ws.activeTabID = tab.id

    ws.closeActiveTab()

    #expect(asked == false)
    #expect(windowCloseCount == 1)
    // Geschlossener Workspace bleibt im Willkommens-Zustand für eine später
    // wieder angezeigte Szene.
    #expect(ws.tabs.map(\.isPristineScratch) == [true])
    #expect(ws.activeTabID == ws.tabs.first?.id)
}

@Test("Letzter leerer unbenannter Dirty-Tab schließt ohne Rückfrage")
@MainActor
func close_lastEmptyUntitledDirtyClosesWithoutPrompt() {
    let ws = makeWorkspace()
    var windowCloseCount = 0
    var asked = false
    ws.closeWindowHandler = { windowCloseCount += 1 }
    ws.confirmCloseHandler = { _ in asked = true; return .cancel }
    let tab = EditorTab(title: "Ohne Titel", path: "noch nicht gespeichert",
                        content: "", isDirty: true)
    ws.tabs = [tab]
    ws.activeTabID = tab.id

    ws.closeActiveTab()

    #expect(asked == false)
    #expect(windowCloseCount == 1)
    // Geschlossen; Workspace im Willkommens-Zustand.
    #expect(ws.tabs.map(\.isPristineScratch) == [true])
}

@Test("Letzter unbenannter Tab mit Inhalt fragt; Abbrechen hält Fenster und Tab offen")
@MainActor
func close_lastUntitledWithContentCancelKeepsWindow() {
    let ws = makeWorkspace()
    var windowCloseCount = 0
    var asked = false
    ws.closeWindowHandler = { windowCloseCount += 1 }
    ws.confirmCloseHandler = { _ in asked = true; return .cancel }
    let tab = EditorTab(title: "Ohne Titel", path: "noch nicht gespeichert",
                        content: "ungesichert", isDirty: true)
    ws.tabs = [tab]
    ws.activeTabID = tab.id

    ws.closeActiveTab()

    #expect(asked == true)
    #expect(windowCloseCount == 0)
    #expect(ws.tabs.map(\.id) == [tab.id])
    #expect(ws.activeTabID == tab.id)
}

@Test("Letzter unbenannter Tab mit Inhalt: Nicht sichern schließt das Fenster")
@MainActor
func close_lastUntitledWithContentDontSaveClosesWindow() {
    let ws = makeWorkspace()
    var windowCloseCount = 0
    ws.closeWindowHandler = { windowCloseCount += 1 }
    ws.confirmCloseHandler = { _ in .dontSave }
    let tab = EditorTab(title: "Ohne Titel", path: "noch nicht gespeichert",
                        content: "ungesichert", isDirty: true)
    ws.tabs = [tab]
    ws.activeTabID = tab.id

    ws.closeActiveTab()

    #expect(windowCloseCount == 1)
    // Geschlossen; Workspace im Willkommens-Zustand.
    #expect(ws.tabs.map(\.isPristineScratch) == [true])
    #expect(ws.activeTabID == ws.tabs.first?.id)
}

@Test("closeOtherTabs fragt pro Dirty-Tab; Abbrechen bricht die ganze Aktion ab")
@MainActor
func close_othersCancelAborts() {
    let ws = makeWorkspace()
    ws.confirmCloseHandler = { _ in .cancel }
    let keep = EditorTab(title: "keep.txt", path: "/tmp", isDirty: false)
    let dirty = EditorTab(title: "dirty.txt", path: "/tmp", content: "x", isDirty: true)
    ws.tabs = [keep, dirty]
    ws.activeTabID = keep.id
    ws.closeOtherTabs(keeping: keep.id)
    #expect(ws.tabs.count == 2)             // nichts geschlossen
    #expect(ws.activeTabID == keep.id)      // ursprünglicher Tab bleibt sichtbar
}

@Test("closeOtherTabs mit Nicht sichern schließt die anderen, behält den Ziel-Tab")
@MainActor
func close_othersDontSave() {
    let ws = makeWorkspace()
    ws.confirmCloseHandler = { _ in .dontSave }
    let keep = EditorTab(title: "keep.txt", path: "/tmp", isDirty: false)
    let dirty = EditorTab(title: "dirty.txt", path: "/tmp", content: "x", isDirty: true)
    let clean = EditorTab(title: "clean.txt", path: "/tmp", isDirty: false)
    ws.tabs = [keep, dirty, clean]
    ws.activeTabID = dirty.id
    ws.closeOtherTabs(keeping: keep.id)
    #expect(ws.tabs.map(\.id) == [keep.id])
    #expect(ws.activeTabID == keep.id)
}

// MARK: - Beenden (⌘Q) — confirmCloseAllDirtyForQuit

@Test("Beenden ohne Dirty-Tabs: keine Rückfrage, darf beenden")
@MainActor
func quit_allCleanTerminates() {
    let ws = makeWorkspace()
    var asked = false
    ws.confirmCloseHandler = { _ in asked = true; return .cancel }
    ws.tabs = [EditorTab(title: "a.txt", path: "/tmp", content: "x", isDirty: false),
               EditorTab(title: "b.txt", path: "/tmp", isDirty: false)]
    #expect(ws.confirmCloseAllDirtyForQuit() == true)
    #expect(asked == false)                  // saubere Tabs → keine Rückfrage
}

@Test("Beenden mit Dirty-Tab + Abbrechen: Beenden wird verweigert")
@MainActor
func quit_dirtyCancelBlocks() {
    let ws = makeWorkspace()
    ws.confirmCloseHandler = { _ in .cancel }
    ws.tabs = [EditorTab(title: "a.txt", path: "/tmp", content: "x", isDirty: true)]
    #expect(ws.confirmCloseAllDirtyForQuit() == false)   // Abbrechen → nicht beenden
}

@Test("Beenden mit Dirty-Tab + Nicht sichern: darf beenden (verwirft)")
@MainActor
func quit_dirtyDontSaveTerminates() {
    let ws = makeWorkspace()
    ws.confirmCloseHandler = { _ in .dontSave }
    ws.tabs = [EditorTab(title: "a.txt", path: "/tmp", content: "x", isDirty: true),
               EditorTab(title: "b.txt", path: "/tmp", content: "y", isDirty: true)]
    #expect(ws.confirmCloseAllDirtyForQuit() == true)
}

@Test("Beenden mit Dirty-Tab + Sichern: schreibt auf die Platte, darf beenden")
@MainActor
func quit_dirtySaveWritesAndTerminates() throws {
    let ws = makeWorkspace()
    ws.confirmCloseHandler = { _ in .save }
    let url = testTemporaryDirectory()
        .appendingPathComponent("fastra-quit-\(UUID().uuidString).txt")
    try "alt".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    ws.tabs = [EditorTab(title: url.lastPathComponent,
                         path: url.deletingLastPathComponent().path,
                         url: url, content: "beim Beenden gesichert", isDirty: true,
                         diskSnapshot: FileSnapshot(data: Data("alt".utf8), at: url))]
    ws.activeTabID = ws.tabs.first?.id
    #expect(ws.confirmCloseAllDirtyForQuit() == true)
    #expect(try String(contentsOf: url, encoding: .utf8) == "beim Beenden gesichert")
}

@Test("Beenden: eine Abbrechen-Antwort blockt, auch wenn andere sauber sind")
@MainActor
func quit_oneCancelAmongCleanBlocks() {
    let ws = makeWorkspace()
    ws.confirmCloseHandler = { _ in .cancel }
    ws.tabs = [EditorTab(title: "clean.txt", path: "/tmp", isDirty: false),
               EditorTab(title: "dirty.txt", path: "/tmp", content: "x", isDirty: true)]
    #expect(ws.confirmCloseAllDirtyForQuit() == false)
}

// `confirmCloseAllDirtyForQuit` muss den ursprünglich aktiven Tab wieder
// herstellen. Sichern kann ihn zwischenzeitlich wechseln; nach späterem
// Abbrechen des Beendens darf nicht der zuletzt gesicherte Tab aktiv bleiben.
@Test("Beenden abgebrochen nach Sichern: ursprünglich aktiver Tab bleibt aktiv")
@MainActor
func quit_cancelAfterSaveRestoresActive() throws {
    let ws = makeWorkspace()
    // Pro Tab unterschiedlich antworten: den ersten Dirty-Tab sichern (setzt
    // intern activeTabID um), den zweiten abbrechen (löst den Befund aus).
    ws.confirmCloseHandler = { title in title == "save.txt" ? .save : .cancel }
    let url = testTemporaryDirectory()
        .appendingPathComponent("fastra-quit-restore-\(UUID().uuidString).txt")
    try "alt".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    // Reihenfolge: aktiver sauberer Tab zuerst, dann der zu sichernde, dann der
    // abzubrechende — so wird activeTabID auf "save.txt" umgesetzt, bevor "cancel.txt"
    // den Abbruch auslöst.
    let active = EditorTab(title: "active.txt", path: "/tmp", isDirty: false)
    let toSave = EditorTab(title: "save.txt",
                           path: url.deletingLastPathComponent().path,
                           url: url, content: "gesichert", isDirty: true,
                           diskSnapshot: FileSnapshot(data: Data("alt".utf8), at: url))
    let toCancel = EditorTab(title: "cancel.txt", path: "/tmp", content: "x", isDirty: true)
    ws.tabs = [active, toSave, toCancel]
    ws.activeTabID = active.id
    #expect(ws.confirmCloseAllDirtyForQuit() == false)   // Abbrechen → nicht beenden
    #expect(ws.activeTabID == active.id)                 // ursprünglich aktiver Tab bleibt aktiv
}

@Test("Nicht-aktiven Dirty-Tab schließen lässt den aktiven Tab aktiv")
@MainActor
func close_inactiveKeepsActive() {
    let ws = makeWorkspace()
    ws.confirmCloseHandler = { _ in .dontSave }
    let active = EditorTab(title: "active.txt", path: "/tmp", isDirty: false)
    let other  = EditorTab(title: "other.txt", path: "/tmp", content: "x", isDirty: true)
    ws.tabs = [active, other]
    ws.activeTabID = active.id
    ws.closeTab(id: other.id)               // einen nicht-aktiven Tab schließen
    #expect(ws.tabs.map(\.id) == [active.id])
    #expect(ws.activeTabID == active.id)    // aktiver Tab unverändert
}
