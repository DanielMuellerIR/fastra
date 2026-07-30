import XCTest
@testable import Fastra

/// Mehrfachauswahl der Änderungen-Liste (Daniel-Wunsch 2026-07-30): Klick,
/// Cmd-Klick-Umschalten, Shift-Klick-Bereich und das Austragen verschwundener
/// Zeilen — plus die Aufteilung des Verwerfen-Plans in untracked/getrackt.
final class GitChangesSelectionTests: XCTestCase {

    private func row(_ path: String,
                     _ section: GitChangeSection = .unstaged) -> GitChangeRowID {
        GitChangeRowID(section: section, rawPath: Data(path.utf8))
    }

    // MARK: Klick-Grundverhalten

    func testPlainClickSelectsExactlyOneRow() {
        var selection = GitChangesSelection()
        selection.click(row("a.txt"))
        selection.click(row("b.txt"))
        XCTAssertEqual(selection.selected, [row("b.txt")])
        XCTAssertEqual(selection.anchor, row("b.txt"))
    }

    func testCommandClickTogglesRows() {
        var selection = GitChangesSelection()
        selection.click(row("a.txt"))
        selection.commandClick(row("b.txt"))
        XCTAssertEqual(selection.selected, [row("a.txt"), row("b.txt")])
        // Nochmal Cmd-Klick auf b → wieder abgewählt, a bleibt.
        selection.commandClick(row("b.txt"))
        XCTAssertEqual(selection.selected, [row("a.txt")])
        XCTAssertEqual(selection.anchor, row("b.txt"))
    }

    // MARK: Shift-Bereich

    func testShiftClickSelectsRangeFromAnchor() {
        let rows = ["a", "b", "c", "d"].map { row($0) }
        var selection = GitChangesSelection()
        selection.click(rows[0])
        selection.shiftClick(rows[2], orderedRows: rows)
        XCTAssertEqual(selection.selected, [rows[0], rows[1], rows[2]])
        // Anker bleibt auf a: neuer Shift-Klick spannt vom selben Punkt auf.
        selection.shiftClick(rows[1], orderedRows: rows)
        XCTAssertEqual(selection.selected, [rows[0], rows[1]])
    }

    func testShiftClickUpwardsSelectsReversedRange() {
        let rows = ["a", "b", "c"].map { row($0) }
        var selection = GitChangesSelection()
        selection.click(rows[2])
        selection.shiftClick(rows[0], orderedRows: rows)
        XCTAssertEqual(selection.selected, Set(rows))
    }

    func testShiftClickWithoutAnchorActsLikePlainClick() {
        let rows = ["a", "b"].map { row($0) }
        var selection = GitChangesSelection()
        selection.shiftClick(rows[1], orderedRows: rows)
        XCTAssertEqual(selection.selected, [rows[1]])
        XCTAssertEqual(selection.anchor, rows[1])
    }

    func testShiftRangeSpansBothSections() {
        // Bereich über die Abschnittsgrenze hinweg: bereitgestellt + offen.
        let rows = [row("a", .staged), row("b", .staged), row("b", .unstaged)]
        var selection = GitChangesSelection()
        selection.click(rows[0])
        selection.shiftClick(rows[2], orderedRows: rows)
        XCTAssertEqual(selection.selected, Set(rows))
    }

    // MARK: Refresh-Bereinigung

    func testPruneDropsVanishedRowsAndStaleAnchor() {
        let rows = ["a", "b", "c"].map { row($0) }
        var selection = GitChangesSelection()
        selection.click(rows[0])
        selection.shiftClick(rows[2], orderedRows: rows)
        // Nach einem Refresh existiert nur noch b (a committet, c verworfen).
        selection.prune(existing: [rows[1]])
        XCTAssertEqual(selection.selected, [rows[1]])
        XCTAssertNil(selection.anchor)
    }

    // MARK: Verwerfen-Plan

    private func change(_ path: String, unstaged: GitFileState?,
                        staged: GitFileState? = nil) -> GitChange {
        GitChange(path: path, staged: staged, unstaged: unstaged)
    }

    func testDiscardPlanSplitsUntrackedFromTracked() {
        let plan = GitDiscardPlan(changes: [
            change("mod.txt", unstaged: .modified),
            change("new.txt", unstaged: .untracked),
            change("gone.txt", unstaged: .deleted),
        ])
        XCTAssertEqual(plan.untrackedPaths, ["new.txt"])
        XCTAssertEqual(plan.trackedPaths, ["mod.txt", "gone.txt"])
        XCTAssertEqual(plan.totalCount, 3)
    }

    func testDiscardPlanIgnoresStagedOnlyAndNonUTF8Rows() {
        // Nur-gestagete Zeilen haben nichts zu verwerfen; Nicht-UTF8-Pfade
        // können nicht an `Process.arguments` übergeben werden.
        let invalid = GitChange(rawPath: Data([0x66, 0xFF, 0x6F]),
                                staged: nil, unstaged: .modified)
        let plan = GitDiscardPlan(changes: [
            change("staged.txt", unstaged: nil, staged: .modified),
            invalid,
        ])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.untrackedPaths.isEmpty)
        XCTAssertTrue(plan.trackedPaths.isEmpty)
    }
}
