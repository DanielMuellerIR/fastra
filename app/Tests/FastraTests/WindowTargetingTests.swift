// WindowTargetingTests.swift
//
// Zielwahl für globale Befehle (Fehlerbericht aus dem Arbeitsbetrieb,
// 2026-08-07): Bei zwei offenen Dokumentfenstern formatierte ⌘B im
// HINTERGRUNDFENSTER. Ursache war eine Fenstersuche über `NSApp.windows` —
// eine ungeordnete Menge, aus der „das erste sichtbare" ein zufälliges
// Fenster ist.
//
// Die Regeln liegen deshalb pur in `WindowTargeting` und werden hier
// festgenagelt. Ein Fenster-Selbsttest kann eine Regression zeigen, aber
// nicht alle Kombinationen durchspielen — und er braucht eine UI-Sitzung.

import Foundation
import Testing
@testable import Fastra

@Suite("Zielwahl für Fensterbefehle")
struct WindowTargetingTests {

    private typealias Candidate = WindowTargeting.Candidate

    private func document(key: Bool = false) -> Candidate {
        Candidate(isDocumentWindow: true, isKey: key)
    }

    private func panel(key: Bool = false) -> Candidate {
        Candidate(isDocumentWindow: false, isKey: key)
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

    /// Der eigentliche Befund: Das bediente Fenster gewinnt — auch wenn es in
    /// der Liste NICHT vorne steht. Genau hier griff der alte Code daneben.
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
    /// Dokumentfenster. Ein Menübefehl muss trotzdem wirken — auf dem
    /// vordersten Dokument dahinter.
    @Test("Hält ein Panel die Tastatur, gilt das vorderste Dokumentfenster")
    func panelKeepsKeyboardButIsNoTarget() {
        let candidates = [panel(key: true), document(), document()]
        #expect(WindowTargeting.targetIndex(in: candidates) == 1)
    }

    @Test("Panels sind nie selbst das Ziel")
    func panelsAreNeverTargets() {
        #expect(WindowTargeting.targetIndex(in: [panel(key: true)]) == nil)
        #expect(WindowTargeting.targetIndex(in: [panel(), panel(key: true)]) == nil)
    }

    /// Zwei Dokumentfenster, dazwischen ein Panel mit dem Tastaturfokus: Das
    /// Ziel ist das vorderste DOKUMENT, nicht das Panel und nicht das hintere
    /// Dokument.
    @Test("Panel zwischen zwei Dokumenten ändert das Ziel nicht")
    func panelBetweenDocuments() {
        let candidates = [document(), panel(key: true), document()]
        #expect(WindowTargeting.targetIndex(in: candidates) == 0)
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

/// Ein frisch geöffneter Editor hat KEINE Auswahl; `selectedRange()` liefert
/// dann `{NSNotFound, 0}`. Reicht ein Aufrufer das ungeprüft an
/// `replaceCharacters` weiter, bricht die Anwendung im Undo-Verwalter mit
/// „Range invalid for string" ab — real auslösbar, indem man ein Bild in ein
/// gerade geöffnetes Markdown-Dokument zieht (Dauertest, 2026-08-08).
///
/// Geprüft wird die reine Klemm-Rechnung; der Editor selbst braucht ein
/// Fenster und ist im Dauertest abgedeckt.
@Suite("Auswahl ohne Klick")
struct SafeSelectionTests {

    /// Ruft den PRODUKTIVEN Code auf, keine Nachbildung — sonst prüfte der
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
