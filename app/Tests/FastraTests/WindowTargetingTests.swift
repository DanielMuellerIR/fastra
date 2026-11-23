// WindowTargetingTests.swift
//
// Reine Zielwahl für Dokumentbefehle prüfen. `NSApp.windows` ist unsortiert;
// die Funktion erhält Kandidaten in expliziter Reihenfolge. Fensterlose Tests
// decken Kombinationen unabhängig von einer UI-Sitzung ab.

import AppKit
import Foundation
import Testing
@testable import Fastra

@Test("Einstellungsfenster wird für Datei > Schließen eindeutig erkannt")
@MainActor
func settingsWindowIsClassifiedForCloseMenu() {
    let window = NSWindow()
    #expect(!SettingsWindowConfiguration.isSettingsWindow(window))
    window.identifier = SettingsWindowConfiguration.windowIdentifier
    #expect(SettingsWindowConfiguration.isSettingsWindow(window))
}

@Test("Finder-Öffnen holt das Dokument statt seiner Suchmaske nach vorn")
@MainActor
func finderOpenRaisesDocumentWindowNotSearchWindow() {
    let suiteName = "fastra-test-finder-window-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let workspace = Workspace(defaults: defaults)
    let documentWindow = NSWindow()
    documentWindow.identifier = NSUserInterfaceItemIdentifier("Fastra.DocumentWindow")
    let searchWindow = NSWindow()
    searchWindow.identifier = SearchWindow.identifier

    WorkspaceWindowRegistry.register(workspace, for: documentWindow)
    WorkspaceWindowRegistry.register(workspace, for: searchWindow)
    defer {
        WorkspaceWindowRegistry.unregister(documentWindow)
        WorkspaceWindowRegistry.unregister(searchWindow)
    }

    // Die Suchmaske darf in AppKits Vordergrundordnung vor dem zugehörigen
    // Dokument stehen. Der Finder-Pfad muss trotzdem das Dokument wählen.
    let target = DocumentWindowController.windowForRaising(
        workspace,
        orderedWindows: [searchWindow, documentWindow],
        registeredWindows: [documentWindow, searchWindow]
    )
    #expect(target === documentWindow)
}

@Suite("Zielwahl für Fensterbefehle")
struct WindowTargetingTests {

    private typealias Candidate = WindowTargeting.Candidate
    private let ownerA = NSObject()
    private let ownerB = NSObject()

    private func document(key: Bool = false, owner: NSObject? = nil) -> Candidate {
        Candidate(isDocumentWindow: true, isKey: key,
                  documentOwnerID: ObjectIdentifier(owner ?? ownerA))
    }

    private func searchPanel(key: Bool = false) -> Candidate {
        Candidate(isDocumentWindow: false, isKey: key,
                  allowsDocumentFallback: true,
                  documentOwnerID: ObjectIdentifier(ownerA))
    }

    private func unknownWindow(key: Bool = false) -> Candidate {
        Candidate(isDocumentWindow: false, isKey: key)
    }

    @Test("Externes Vergleichsfenster sperrt den Dokumentrückfall auch bei inaktiver App")
    func externalDiffBlocksInactiveFallback() {
        let comparison = Candidate(isDocumentWindow: false, isKey: false,
                                   blocksInactiveDocumentFallback: true)
        #expect(WindowTargeting.targetIndex(in: [comparison, document()]) == nil)
        #expect(WindowTargeting.targetIndex(in: [document(), comparison]) == 0)
        #expect(WindowTargeting.targetIndex(in: [comparison, document(key: true)]) == 1)
    }

    @Test("Ohne Fenster gibt es kein Ziel")
    func noWindowsNoTarget() {
        #expect(WindowTargeting.targetIndex(in: []) == nil)
    }

    @Test("Ein einzelnes Dokumentfenster ist immer das Ziel")
    func singleDocumentWindow() {
        #expect(WindowTargeting.targetIndex(in: [document()]) == 0)
        #expect(WindowTargeting.targetIndex(in: [document(key: true)]) == 0)
    }

    /// Das bediente Fenster gewinnt auch dann, wenn es nicht vorne in der
    /// übergebenen Liste steht.
    @Test("Das bediente Fenster gewinnt, auch wenn es hinten steht")
    func keyWindowWinsEvenWhenNotFirst() {
        let candidates = [document(), document(), document(key: true)]
        #expect(WindowTargeting.targetIndex(in: candidates) == 2)
    }

    @Test("Bei zwei Dokumentfenstern entscheidet die Tastatur, nicht die Reihenfolge")
    func twoDocumentWindowsPickTheKeyedOne() {
        #expect(WindowTargeting.targetIndex(in: [document(key: true), document()]) == 0)
        #expect(WindowTargeting.targetIndex(in: [document(), document(key: true)]) == 1)
    }

    /// Die schwebende Suchmaske hält den Tastaturfokus, ist aber kein
    /// Dokumentfenster. Ein Menübefehl wirkt auf ihren registrierten Besitzer.
    @Test("Die Suchmaske delegiert an ihr Dokument")
    func panelKeepsKeyboardButIsNoTarget() {
        let candidates = [searchPanel(key: true), document(), document()]
        #expect(WindowTargeting.targetIndex(in: candidates) == 1)
    }

    @Test("Die Suchmaske A überspringt ein vorderes Dokument B")
    func searchOwnerWinsOverDocumentOrder() {
        let candidates = [searchPanel(key: true), document(owner: ownerB), document()]
        #expect(WindowTargeting.targetIndex(in: candidates) == 2)
        #expect(WindowTargeting.targetIndex(in: [document(owner: ownerB),
            searchPanel(key: true), document()]) == 2)
    }

    @Test("Fehlendes Suchdokument und unbekannter Besitzer sperren fremde Dokumente")
    func missingSearchOwnerBlocksFallback() {
        #expect(WindowTargeting.targetIndex(in: [searchPanel(key: true),
            document(owner: ownerB)]) == nil)
        let unboundSearch = Candidate(isDocumentWindow: false, isKey: true,
                                      allowsDocumentFallback: true)
        #expect(WindowTargeting.targetIndex(in: [unboundSearch, document()]) == nil)
    }

    @Test("Panels sind nie selbst das Ziel")
    func panelsAreNeverTargets() {
        #expect(WindowTargeting.targetIndex(in: [searchPanel(key: true)]) == nil)
        #expect(WindowTargeting.targetIndex(in: [searchPanel(), searchPanel(key: true)]) == nil)
    }

    /// Zwei Dokumentfenster, dazwischen ein Panel mit dem Tastaturfokus: Das
    /// Beide Dokumentkandidaten gehören hier demselben Besitzer; nur die
    /// Suchmaske selbst bleibt als Dokumentziel ausgeschlossen.
    @Test("Panel zwischen Dokumentkandidaten ist nie selbst das Ziel")
    func panelBetweenDocuments() {
        let candidates = [document(), searchPanel(key: true), document()]
        #expect(WindowTargeting.targetIndex(in: candidates) == 0)
    }

    @Test("Unbekanntes Key-Window darf kein Hintergrunddokument treffen")
    func unknownKeyWindowBlocksDocumentFallback() {
        let candidates = [unknownWindow(key: true), document(), document()]
        #expect(WindowTargeting.targetIndex(in: candidates) == nil)
    }

    /// Regressionsschutz gegen die alte Implementierung: Sie nahm schlicht das
    /// erste Fenster der Liste. Dieser Fall unterscheidet beide Verhalten —
    /// alt hätte 0 geliefert, richtig ist 1.
    @Test("Erstes Fenster der Liste ist NICHT automatisch das Ziel")
    func firstWindowIsNotAutomaticallyTheTarget() {
        let candidates = [document(), document(key: true)]
        let index = WindowTargeting.targetIndex(in: candidates)
        #expect(index == 1)
        #expect(index != 0, "Das alte Verhalten nahm das erste Fenster — genau der Fehler.")
    }
}

// MARK: - Auswahl ohne Klick

/// Ein Editor ohne Auswahl kann `{NSNotFound, 0}` liefern. Vor
/// `replaceCharacters` muss die Range begrenzt werden, sonst kann die
/// Undo-Verwaltung abbrechen. Hier wird die reine Klemmrechnung geprüft;
/// der echte Editor ist im Dauertest abgedeckt.
@Suite("Auswahl ohne Klick")
struct SafeSelectionTests {

    /// Ruft den produktiven Code auf, keine Nachbildung — sonst prüfte der
    /// Test nur sich selbst.
    private func clamp(_ range: NSRange, textLength: Int) -> NSRange {
        SelectionClamping.clamp(range, textLength: textLength)
    }

    @Test("Keine Auswahl wird zum Dokumentanfang")
    func notFoundBecomesStart() {
        let result = clamp(NSRange(location: NSNotFound, length: 0), textLength: 0)
        #expect(result == NSRange(location: 0, length: 0))
    }

    @Test("Keine Auswahl in einem gefüllten Dokument wird ebenfalls zum Anfang")
    func notFoundInFilledDocument() {
        let result = clamp(NSRange(location: NSNotFound, length: 0), textLength: 500)
        #expect(result == NSRange(location: 0, length: 0))
    }

    @Test("Eine Auswahl über das Dokumentende hinaus wird geklemmt")
    func rangeBeyondEndIsClamped() {
        let result = clamp(NSRange(location: 90, length: 50), textLength: 100)
        #expect(result == NSRange(location: 90, length: 10))
    }

    @Test("Eine gültige Auswahl bleibt unverändert")
    func validRangeUntouched() {
        let range = NSRange(location: 10, length: 20)
        #expect(clamp(range, textLength: 100) == range)
    }

    @Test("Position hinter dem Dokumentende rutscht ans Ende")
    func locationBeyondEnd() {
        let result = clamp(NSRange(location: 250, length: 0), textLength: 100)
        #expect(result == NSRange(location: 100, length: 0))
    }
}

@Test("Hilfsfenster aktualisieren Befehle ohne den letzten Dokumentkontext zu verlieren")
@MainActor
func auxiliaryWindowRefreshPreservesDocumentContext() {
    let defaults = testSuiteDefaults(named: "fastra-test-command-context-\(UUID().uuidString)")
    let workspace = Workspace(defaults: defaults)
    let context = ActiveDocumentContext()
    context.activate(workspace)
    let previousRevision = context.revision
    context.commandTargetDidChange()
    #expect(context.workspace === workspace)
    #expect(context.revision == previousRevision &+ 1)
}
