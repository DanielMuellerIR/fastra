// MainWindowSizingTests.swift
//
// Startgröße neuer Fenster (Daniel-Wunsch 2026-08-06): Ein neues Fenster
// soll den Bildschirm in der Höhe wirklich nutzen; kleiner ziehen darf der
// Nutzer danach jederzeit. Die Rechnung bleibt hier pur und damit ohne
// echten Bildschirm prüfbar.

import AppKit
import CoreGraphics
import Testing
@testable import Fastra

@Suite("Fenster-Startgröße")
struct MainWindowSizingTests {

    /// Nutzbarer Bereich eines 15-Zoll-MacBook-Pro-Bildschirms (Punkte,
    /// abzüglich Menüleiste) — der Fall aus dem Befund.
    private let notebook = CGRect(x: 0, y: 0, width: 1512, height: 945)

    @Test("Neues Fenster nutzt mindestens 80 % der nutzbaren Bildschirmhöhe")
    func newWindowUsesMostOfTheScreenHeight() {
        let size = MainWindowSizing.newWindowSize(inVisibleScreen: notebook.size)
        #expect(size.height >= notebook.height * 0.8)
        #expect(size.height <= notebook.height)
        // Die alte feste Starthöhe war der eigentliche Befund.
        #expect(size.height > MainWindowSizing.defaultHeight)
    }

    @Test("Auf einem kleinen Bildschirm bleibt das Fenster vollständig sichtbar")
    func smallScreenKeepsWindowOnScreen() {
        let small = CGSize(width: 1280, height: 700)
        let size = MainWindowSizing.newWindowSize(inVisibleScreen: small)
        #expect(size.height <= small.height)
        #expect(size.width <= small.width)
    }

    @Test("Startrahmen liegt mittig im nutzbaren Bereich")
    func newWindowFrameIsCentered() {
        let frame = MainWindowSizing.newWindowFrame(inVisibleScreen: notebook)
        #expect(abs(frame.midX - notebook.midX) < 0.5)
        #expect(abs(frame.midY - notebook.midY) < 0.5)
        #expect(notebook.contains(frame))
    }

    @Test("Zu flach gespeicherter Rahmen wächst und behält seine Oberkante")
    func normalizationGrowsFlatFrameKeepingItsTop() {
        // AppKit: y wächst nach oben, `maxY` ist die Oberkante.
        let saved = CGRect(x: 120, y: 500, width: 1100, height: 400)
        let normalized = MainWindowSizing.heightNormalizedFrame(saved,
                                                                inVisibleScreen: notebook)
        #expect(normalized.height > saved.height)
        #expect(normalized.width == saved.width)
        #expect(normalized.origin.x == saved.origin.x)
        #expect(normalized.maxY <= notebook.maxY)
        #expect(normalized.minY >= notebook.minY)
    }

    @Test("Ein bereits hohes Fenster bleibt unangetastet")
    func normalizationLeavesTallFrameAlone() {
        let tall = CGRect(x: 10, y: 20, width: 900, height: 900)
        #expect(MainWindowSizing.heightNormalizedFrame(tall, inVisibleScreen: notebook)
                == tall)
    }

    /// Die einmalige Korrektur läuft erst, wenn die Sitzungswiederherstellung
    /// ALLE Dokumente geladen hat. Bis dahin stehen die Fenster längst
    /// sichtbar da: Zieht der Nutzer eines davon bewusst kleiner, darf die
    /// Korrektur es danach nicht wieder aufziehen (Review 2026-08-06).
    @Test("Ein selbst gezogenes Fenster ist von der einmaligen Korrektur ausgenommen")
    @MainActor
    func userResizedWindowIsExcluded() {
        MainWindowHeightNormalization.resetUserResizesForTesting()
        defer { MainWindowHeightNormalization.resetUserResizesForTesting() }

        let untouched = NSWindow()
        let dragged = NSWindow()
        #expect(!MainWindowHeightNormalization.isExcludedFromNormalization(dragged))

        MainWindowHeightNormalization.noteUserResize(of: dragged)

        #expect(MainWindowHeightNormalization.isExcludedFromNormalization(dragged))
        // Nur das wirklich gezogene Fenster ist ausgenommen.
        #expect(!MainWindowHeightNormalization.isExcludedFromNormalization(untouched))
    }
}
