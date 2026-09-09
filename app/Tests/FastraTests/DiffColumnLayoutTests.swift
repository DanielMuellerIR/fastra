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
