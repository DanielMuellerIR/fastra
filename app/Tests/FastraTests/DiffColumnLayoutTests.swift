import XCTest
@testable import Fastra

/// Spaltenbreite der zweispaltigen Diff-Ansicht (Daniel-Befund 2026-07-30:
/// die Spalten liefen ineinander). Beide Seiten teilen sich die sichtbare
/// Fläche und wachsen nie mit dem Inhalt mit. Seit dem Splitter (2026-09-09)
/// bestimmt zusätzlich ein gezogenes Verhältnis, wie die Fläche aufgeteilt
/// wird — die Summe beider Spalten plus Trenner bleibt dabei konstant.
final class DiffColumnLayoutTests: XCTestCase {

    private func content(_ available: CGFloat) -> CGFloat {
        DiffColumnLayout.contentWidth(availableWidth: available)
    }

    func testDefaultRatioSplitsTheVisibleWidthInHalf() {
        // 1201 pt sichtbar minus 1 pt Trenner → zwei Spalten à 600 pt.
        let width = content(1201)
        XCTAssertEqual(
            DiffColumnLayout.leadingWidth(contentWidth: width,
                                          ratio: DiffColumnLayout.defaultRatio),
            600
        )
        XCTAssertEqual(
            DiffColumnLayout.trailingWidth(contentWidth: width,
                                           ratio: DiffColumnLayout.defaultRatio),
            600
        )
    }

    func testBothColumnsPlusDividerFillTheVisibleWidth() {
        // Auch bei einer ungeraden Breite darf rechts kein Streifen frei
        // bleiben — sonst endete der Zeilenhintergrund vor dem Rand.
        for available: CGFloat in [1600, 1601, 1234.5, 2000] {
            for ratio: CGFloat in [0, 0.25, 0.5, 0.77, 1] {
                let width = content(available)
                let left = DiffColumnLayout.leadingWidth(contentWidth: width,
                                                         ratio: ratio)
                let right = DiffColumnLayout.trailingWidth(contentWidth: width,
                                                           ratio: ratio)
                XCTAssertEqual(left + right + DiffColumnLayout.dividerWidth,
                               width, accuracy: 0.0001,
                               "available=\(available) ratio=\(ratio)")
            }
        }
    }

    func testNarrowWindowFallsBackToMinimumWidth() {
        // Schmales Fenster: Die Spalten quetschen sich nicht unter die
        // Untergrenze, die Fläche wird stattdessen horizontal scrollbar.
        let width = content(400)
        XCTAssertEqual(width, DiffColumnLayout.minimumColumnWidth * 2
                       + DiffColumnLayout.dividerWidth)
        XCTAssertGreaterThan(width, 400)
        XCTAssertEqual(
            DiffColumnLayout.leadingWidth(contentWidth: width,
                                          ratio: DiffColumnLayout.defaultRatio),
            DiffColumnLayout.minimumColumnWidth
        )
    }

    func testZeroWidthDoesNotProduceNegativeColumns() {
        // Erster Layout-Durchlauf: Die Geometrie kann noch 0 melden.
        let width = content(0)
        XCTAssertGreaterThan(width, 0)
        XCTAssertGreaterThanOrEqual(
            DiffColumnLayout.leadingWidth(contentWidth: width, ratio: 0), 0
        )
    }

    func testColumnWidthIgnoresContentLength() {
        // Kern des behobenen Fehlers von 2026-07-30: Die Spaltenbreite hängt
        // allein an der Fensterbreite und am gezogenen Verhältnis. Wüchse sie
        // mit dem Inhalt, schöbe eine lange Zeile die zweite Spalte aus dem
        // Bild.
        XCTAssertEqual(
            DiffColumnLayout.leadingWidth(contentWidth: content(2000), ratio: 0.5),
            (2000 - DiffColumnLayout.dividerWidth) / 2
        )
    }

    func testRatioMovesTheBoundaryByTheDraggedDistance() {
        // Was der Splitter beim Ziehen rechnet: aus einer absoluten Position
        // ein Verhältnis, aus dem Verhältnis wieder dieselbe Position.
        let width = content(1601)
        let start = DiffColumnLayout.leadingWidth(contentWidth: width, ratio: 0.5)
        let dragged = DiffColumnLayout.ratio(forLeadingWidth: start + 120,
                                             contentWidth: width)
        XCTAssertEqual(
            DiffColumnLayout.leadingWidth(contentWidth: width, ratio: dragged),
            start + 120, accuracy: 0.0001
        )
    }

    func testNeitherPaneCanBeDraggedAway() {
        // Eine Seite darf beliebig schmal werden, aber nie verschwinden —
        // sonst wäre der Trenner nicht mehr zu greifen.
        let width = content(1601)
        for ratio: CGFloat in [-5, 0, 0.001, 0.999, 1, 12] {
            let left = DiffColumnLayout.leadingWidth(contentWidth: width, ratio: ratio)
            let right = DiffColumnLayout.trailingWidth(contentWidth: width, ratio: ratio)
            XCTAssertGreaterThanOrEqual(left, DiffColumnLayout.minimumPaneWidth,
                                        "ratio=\(ratio)")
            XCTAssertGreaterThanOrEqual(right, DiffColumnLayout.minimumPaneWidth,
                                        "ratio=\(ratio)")
        }
    }

    func testRatioStaysUsableWhenTheAreaIsThinnerThanTheDivider() {
        // Randfall des ersten Layout-Durchlaufs: Ist für die Spalten nichts
        // übrig, gibt es kein sinnvolles Verhältnis — dann muss die
        // Werksteilung herauskommen, keine Division durch null.
        for width: CGFloat in [0, DiffColumnLayout.dividerWidth] {
            XCTAssertEqual(
                DiffColumnLayout.ratio(forLeadingWidth: 300, contentWidth: width),
                DiffColumnLayout.defaultRatio, accuracy: 0.0001,
                "contentWidth=\(width)"
            )
        }
    }

    func testAccessibilityPercentReportsTheVisibleSplit() {
        // Der Vorlesewert muss die SICHTBARE Spalte beschreiben. `ratio` ist
        // nur auf 0…1 geklemmt; die Mindestbreite setzt erst `leadingWidth`
        // durch, ein Zug bis an den Anschlag speichert also 0.
        let width = content(1601)
        let usable = DiffColumnLayout.usableWidth(contentWidth: width)
        let clampedPercent = Int((DiffColumnLayout.minimumPaneWidth / usable * 100).rounded())
        XCTAssertEqual(
            DiffColumnLayout.visibleLeadingPercent(contentWidth: width, ratio: 0),
            clampedPercent
        )
        XCTAssertGreaterThan(clampedPercent, 0)
        XCTAssertEqual(
            DiffColumnLayout.visibleLeadingPercent(contentWidth: width, ratio: 1),
            100 - clampedPercent
        )
        XCTAssertEqual(
            DiffColumnLayout.visibleLeadingPercent(
                contentWidth: width, ratio: DiffColumnLayout.defaultRatio),
            50
        )
    }

    func testPersistedRatioSurvivesMissingAndBrokenDefaults() {
        // Der gemerkte Wert kommt aus den Defaults und kann fehlen oder Unsinn
        // enthalten. Beides darf die Ansicht nicht kippen.
        let suite = "fastra-test-diffratio-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = DiffColumnLayout.splitRatioDefaultsKey
        let width = content(1601)

        // Nichts gespeichert: `double(forKey:)` liefert 0 — die Spalte bleibt
        // trotzdem greifbar breit.
        XCTAssertGreaterThanOrEqual(
            DiffColumnLayout.leadingWidth(contentWidth: width,
                                          ratio: CGFloat(defaults.double(forKey: key))),
            DiffColumnLayout.minimumPaneWidth
        )
        for broken in ["nonsens", "-3", "17"] {
            defaults.set(broken, forKey: key)
            let stored = CGFloat(defaults.double(forKey: key))
            let left = DiffColumnLayout.leadingWidth(contentWidth: width, ratio: stored)
            let right = DiffColumnLayout.trailingWidth(contentWidth: width, ratio: stored)
            XCTAssertGreaterThanOrEqual(left, DiffColumnLayout.minimumPaneWidth, broken)
            XCTAssertGreaterThanOrEqual(right, DiffColumnLayout.minimumPaneWidth, broken)
        }
    }

    func testVoiceOverStepLeavesTheClampedZoneImmediately() {
        // Der Befund: Ein Zug bis an den Anschlag merkt sich 0, sichtbar
        // bleiben 96 pt. Vom Rohwert aus gerechnet bewegten die ersten beiden
        // Schritte „mehr Platz links" nichts.
        let width = content(1601)
        let usable = DiffColumnLayout.usableWidth(contentWidth: width)
        let lower = DiffColumnLayout.minimumPaneWidth / usable

        let up = DiffColumnLayout.adjustedRatio(contentWidth: width, ratio: 0, by: 0.05)
        XCTAssertEqual(up, lower + 0.05, accuracy: 0.0001)
        XCTAssertGreaterThan(
            DiffColumnLayout.leadingWidth(contentWidth: width, ratio: up),
            DiffColumnLayout.minimumPaneWidth
        )

        // Am unteren Anschlag bleibt es beim Anschlag — keine unsichtbare
        // Wanderung ins Nichts.
        XCTAssertEqual(
            DiffColumnLayout.adjustedRatio(contentWidth: width, ratio: 0, by: -0.05),
            lower, accuracy: 0.0001
        )
        XCTAssertEqual(
            DiffColumnLayout.adjustedRatio(contentWidth: width, ratio: 1, by: 0.05),
            1 - lower, accuracy: 0.0001
        )
        // Aus der Mitte heraus ist der Schritt genau der Schritt.
        XCTAssertEqual(
            DiffColumnLayout.adjustedRatio(contentWidth: width, ratio: 0.5, by: 0.05),
            0.55, accuracy: 0.0001
        )
    }

    func testSplitterSitsOnTheBoundary() {
        let width = content(1601)
        let ratio: CGFloat = 0.3
        XCTAssertEqual(
            DiffColumnLayout.splitterCenterX(contentWidth: width, ratio: ratio),
            DiffColumnLayout.leadingWidth(contentWidth: width, ratio: ratio)
                + DiffColumnLayout.dividerWidth / 2,
            accuracy: 0.0001
        )
    }
}
