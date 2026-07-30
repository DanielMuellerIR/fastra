import XCTest
@testable import Fastra

/// Spaltenbreite der zweispaltigen Diff-Ansicht (Daniel-Befund 2026-07-30:
/// die Spalten liefen ineinander). Beide Seiten müssen gleich breit sein und
/// sich die sichtbare Fläche teilen — nie mit dem Inhalt mitwachsen.
final class DiffColumnLayoutTests: XCTestCase {

    func testColumnIsHalfOfAvailableWidth() {
        // 1201 pt sichtbar minus 1 pt Trenner → zwei Spalten à 600 pt.
        XCTAssertEqual(DiffColumnLayout.columnWidth(availableWidth: 1201), 600)
    }

    func testBothColumnsPlusDividerFillTheVisibleWidth() {
        let available: CGFloat = 1600
        let column = DiffColumnLayout.columnWidth(availableWidth: available)
        XCTAssertEqual(DiffColumnLayout.rowWidth(columnWidth: column), available)
    }

    func testNarrowWindowFallsBackToMinimumWidth() {
        // Schmales Fenster: Die Spalten quetschen sich nicht unter die
        // Untergrenze, die Fläche wird stattdessen horizontal scrollbar.
        let column = DiffColumnLayout.columnWidth(availableWidth: 400)
        XCTAssertEqual(column, DiffColumnLayout.minimumColumnWidth)
        XCTAssertGreaterThan(DiffColumnLayout.rowWidth(columnWidth: column), 400)
    }

    func testZeroWidthDoesNotProduceNegativeColumns() {
        // Erster Layout-Durchlauf: Die Geometrie kann noch 0 melden.
        XCTAssertEqual(DiffColumnLayout.columnWidth(availableWidth: 0),
                       DiffColumnLayout.minimumColumnWidth)
    }

    func testColumnWidthIgnoresContentLength() {
        // Kern des behobenen Fehlers: Die Spaltenbreite hängt allein an der
        // Fensterbreite. Wüchse sie mit dem Inhalt, schöbe eine lange Zeile
        // die zweite Spalte aus dem Bild.
        let wide = DiffColumnLayout.columnWidth(availableWidth: 2000)
        XCTAssertEqual(wide, DiffColumnLayout.columnWidth(availableWidth: 2000))
        XCTAssertEqual(wide, (2000 - 1) / 2)
    }
}
