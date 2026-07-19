//
//  TextView+ColumnSelection.swift
//  Fastra-Patch für CodeEditTextView
//
//  BBEdit-Referenzmatrix (16.0.2, 2026-07-19):
//  - Ein bestehendes Rechteck bleibt bei Soft Wrap auf logischen Textzeilen;
//    umbrochene Fortsetzungen werden bewusst nicht zusätzlich markiert.
//  - Copy liefert die Teilbereiche zeilenweise ohne Padding.
//  - Eine Clipboard-Zeile und normale Texteingabe füllen alle Rechteckzeilen;
//    mehrere Clipboard-Zeilen werden zeilenweise verteilt.
//  - BBEdits Select Down/Paste Column folgen bei bereits aktivem Wrap teils
//    sichtbaren Fragmenten. Fastra folgt hier seiner stärkeren Produktregel:
//    Ein Umbruchfragment ist niemals eine zusätzliche Rechteckzeile.
//

import AppKit
import ObjectiveC

/// Öffentliche, unveränderliche Sicht auf eine aktive Rechteckauswahl.
/// Die App und die Selbsttests müssen nicht auf den internen Zustandskasten
/// zugreifen, können aber Bereiche und logische Zeilen unabhängig prüfen.
public struct FastraColumnSelectionSnapshot: Equatable {
    public let ranges: [NSRange]
    public let lineIndices: [Int]
    public let lowerColumn: Int
    public let upperColumn: Int
}

private struct FastraColumnRow {
    let lineIndex: Int
    let range: NSRange
}

private final class FastraColumnSelectionState: NSObject {
    let anchorLine: Int
    let headLine: Int
    let anchorColumn: Int
    let headColumn: Int
    let rows: [FastraColumnRow]

    init(
        anchorLine: Int,
        headLine: Int,
        anchorColumn: Int,
        headColumn: Int,
        rows: [FastraColumnRow]
    ) {
        self.anchorLine = anchorLine
        self.headLine = headLine
        self.anchorColumn = anchorColumn
        self.headColumn = headColumn
        self.rows = rows
    }
}

private struct FastraLogicalLine {
    let contentRange: NSRange
    let fullRange: NSRange
}

private enum FastraColumnEdge {
    case leading
    case trailing
}

private struct FastraColumnChange {
    let range: NSRange
    let replacement: String
}

nonisolated(unsafe) private var fastraColumnSelectionStateKey: UInt8 = 0
nonisolated(unsafe) private var fastraColumnTabWidthKey: UInt8 = 0
nonisolated(unsafe) private var fastraColumnIndentationKey: UInt8 = 0

extension TextView {
    /// Effektive Tabbreite des SourceEditors. CodeEditSourceEditor setzt sie
    /// bei der Erstkonfiguration und bei jedem Profilwechsel.
    public var fastraColumnSelectionTabWidth: Int {
        get {
            max(
                (objc_getAssociatedObject(self, &fastraColumnTabWidthKey) as? NSNumber)?.intValue ?? 4,
                1
            )
        }
        set {
            objc_setAssociatedObject(
                self,
                &fastraColumnTabWidthKey,
                NSNumber(value: max(newValue, 1)),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Aktive Einrückungseinheit. Paste Column nutzt bei Tab-Profilen ganze
    /// Tabstopps und ergänzt nur den unvermeidlichen Rest mit Leerzeichen.
    public var fastraColumnIndentationUnit: String {
        get {
            guard let value = objc_getAssociatedObject(
                self,
                &fastraColumnIndentationKey
            ) as? NSString else {
                return "    "
            }
            return value as String
        }
        set {
            objc_setAssociatedObject(
                self,
                &fastraColumnIndentationKey,
                newValue as NSString,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Liefert nur dann einen Zustand, wenn die echten Editorbereiche noch
    /// exakt zu ihm passen. Normale Klicks, Sprünge und Multi-Cursor-Aktionen
    /// invalidieren einen alten Rechteckzustand dadurch automatisch.
    public var fastraColumnSelectionSnapshot: FastraColumnSelectionSnapshot? {
        guard let state = fastraValidColumnSelectionState() else { return nil }
        return FastraColumnSelectionSnapshot(
            ranges: state.rows.map(\.range),
            lineIndices: state.rows.map(\.lineIndex),
            lowerColumn: min(state.anchorColumn, state.headColumn),
            upperColumn: max(state.anchorColumn, state.headColumn)
        )
    }

    /// Setzt ein Rechteck zwischen zwei Punkten. Die Punkte bestimmen zuerst
    /// ihre logische Textzeile und die echte Spalte innerhalb dieser Zeile.
    /// Danach entsteht pro logischer Zeile genau ein Bereich - unabhängig von
    /// der Zahl ihrer sichtbaren Soft-Wrap-Fragmente.
    public func selectColumns(betweenPointA pointA: CGPoint, pointB: CGPoint) {
        guard let first = fastraLineAndColumn(at: pointA),
              let second = fastraLineAndColumn(at: pointB) else {
            return
        }
        fastraSetColumnSelection(
            anchorLine: first.line,
            headLine: second.line,
            anchorColumn: first.column,
            headColumn: second.column
        )
    }

    /// Entspricht BBEdits „Select Up/Down“, verwendet aber bewusst logische
    /// Textzeilen. Ohne bestehenden Rechteckzustand darf die Ausgangsauswahl
    /// nicht über eine Zeilengrenze reichen.
    @discardableResult
    public func fastraSelectColumn(upwards: Bool) -> Bool {
        let delta = upwards ? -1 : 1
        let lines = fastraLogicalLines()
        guard !lines.isEmpty else { return false }

        if let state = fastraValidColumnSelectionState() {
            let newHead = state.headLine + delta
            guard lines.indices.contains(newHead) else { return false }
            fastraSetColumnSelection(
                anchorLine: state.anchorLine,
                headLine: newHead,
                anchorColumn: state.anchorColumn,
                headColumn: state.headColumn
            )
            scrollSelectionToVisible()
            return true
        }

        guard selectionManager.textSelections.count == 1,
              let selection = selectionManager.textSelections.first?.range,
              let lineIndex = fastraLineIndex(containing: selection, in: lines) else {
            return false
        }
        let newHead = lineIndex + delta
        guard lines.indices.contains(newHead) else { return false }
        let line = lines[lineIndex]
        let startColumn = fastraVisualColumn(
            at: selection.location,
            in: line
        )
        let endColumn = fastraVisualColumn(
            at: NSMaxRange(selection),
            in: line
        )
        fastraSetColumnSelection(
            anchorLine: lineIndex,
            headLine: newHead,
            anchorColumn: startColumn,
            headColumn: endColumn
        )
        scrollSelectionToVisible()
        return true
    }

    /// Rechteck-Copy als ein normaler zeilenweiser Textwert. Fremde Programme
    /// sehen dadurch sinnvollen Text; eine Leerzeile bleibt als leere Zeile
    /// erhalten. Wie BBEdit endet ein mehrzeiliges Rechteck mit einem Trenner.
    @discardableResult
    public func fastraCopyColumnSelection() -> Bool {
        guard let state = fastraValidColumnSelectionState() else { return false }
        let values = state.rows.map { row in
            (string as NSString).substring(with: row.range)
        }
        let separator = layoutManager.detectedLineEnding.rawValue
        var output = values.joined(separator: separator)
        if values.count > 1 {
            output += separator
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([output as NSString])
        return true
    }

    /// Normales Paste auf ein Rechteck. Eine Zeile füllt alle Teilbereiche.
    /// Bei mehreren Zeilen gilt eine bewusste Mismatch-Regel:
    /// Clipboard-Überschuss wird unter dem Rechteck fortgesetzt; verbleibende
    /// Auswahlzeilen werden geleert. So geht weder Clipboard-Text verloren,
    /// noch wird er still wiederholt.
    @discardableResult
    public func fastraPasteIntoColumnSelection(_ value: String) -> Bool {
        guard fastraValidColumnSelectionState() != nil else { return false }
        fastraApplyColumnRows(fastraClipboardLines(value), requiresSelection: true)
        return true
    }

    /// Delete/Backspace/Cut dürfen bei einer zu kurzen Rechteckzeile nicht
    /// Upstreams normalen „Zeichen am Cursor löschen"-Pfad auslösen. Leere
    /// Teilbereiche bleiben leer; nur tatsächlich markierter Text verschwindet.
    @discardableResult
    public func fastraDeleteColumnSelection() -> Bool {
        guard fastraValidColumnSelectionState() != nil else { return false }
        fastraApplyColumnRows([""], requiresSelection: true)
        return true
    }

    /// Sichtbarer Befehl „Paste Column“. Ohne Rechteck beginnt er am primären
    /// Cursor; mit Rechteck an dessen linker Kante. Kurze Zielzeilen werden
    /// tabstopp-bewusst bis zur Zielspalte aufgefüllt.
    @objc public func fastraPasteColumn(_ sender: Any?) {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            NSSound.beep()
            return
        }
        fastraApplyColumnRows(fastraClipboardLines(value), requiresSelection: false)
    }

    /// Wendet verschieden lange, aber einzeilige Ersetzungen auf alle
    /// Rechteckbereiche in genau einer Undo-Gruppe an. Das nutzt Fastra für
    /// zeichenbezogene Texttransformationen wie Groß-/Kleinschreibung.
    @discardableResult
    public func fastraReplaceColumnSelections(with replacements: [String]) -> Bool {
        guard let state = fastraValidColumnSelectionState(),
              replacements.count == state.rows.count,
              replacements.allSatisfy({
                  !$0.contains("\n") && !$0.contains("\r")
              }) else {
            return false
        }

        let nsText = string as NSString
        let originals = state.rows.map { nsText.substring(with: $0.range) }
        guard originals != replacements else { return false }

        let changes = zip(state.rows, replacements).compactMap {
            pair -> FastraColumnChange? in
            let (row, replacement) = pair
            let original = nsText.substring(with: row.range)
            guard original != replacement else { return nil }
            return FastraColumnChange(range: row.range, replacement: replacement)
        }

        var delta = 0
        var newRows: [FastraColumnRow] = []
        for (row, replacement) in zip(state.rows, replacements) {
            let replacementLength = (replacement as NSString).length
            newRows.append(FastraColumnRow(
                lineIndex: row.lineIndex,
                range: NSRange(
                    location: row.range.location + delta,
                    length: replacementLength
                )
            ))
            delta += replacementLength - row.range.length
        }

        fastraApplyChanges(changes)
        selectionManager.setSelectedRanges(newRows.map(\.range))

        let lowerColumn = min(state.anchorColumn, state.headColumn)
        let widest = replacements.map {
            fastraVisualWidth(of: $0, startingAt: lowerColumn)
        }.max() ?? 0
        fastraColumnSelectionState = FastraColumnSelectionState(
            anchorLine: state.anchorLine,
            headLine: state.headLine,
            anchorColumn: lowerColumn,
            headColumn: lowerColumn + widest,
            rows: newRows
        )
        scrollSelectionToVisible()
        return true
    }
}

private extension TextView {
    var fastraColumnSelectionState: FastraColumnSelectionState? {
        get {
            objc_getAssociatedObject(
                self,
                &fastraColumnSelectionStateKey
            ) as? FastraColumnSelectionState
        }
        set {
            objc_setAssociatedObject(
                self,
                &fastraColumnSelectionStateKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    func fastraValidColumnSelectionState() -> FastraColumnSelectionState? {
        guard let state = fastraColumnSelectionState else { return nil }
        let current = selectionManager.textSelections.map(\.range)
        guard current == state.rows.map(\.range) else {
            fastraColumnSelectionState = nil
            return nil
        }
        return state
    }

    func fastraLogicalLines() -> [FastraLogicalLine] {
        let text = string as NSString
        guard text.length > 0 else {
            return [FastraLogicalLine(
                contentRange: NSRange(location: 0, length: 0),
                fullRange: NSRange(location: 0, length: 0)
            )]
        }

        var result: [FastraLogicalLine] = []
        var location = 0
        while location < text.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            text.getLineStart(
                &start,
                end: &end,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            result.append(FastraLogicalLine(
                contentRange: NSRange(
                    location: start,
                    length: max(contentsEnd - start, 0)
                ),
                fullRange: NSRange(
                    location: start,
                    length: max(end - start, 0)
                )
            ))
            guard end > location else { break }
            location = end
        }

        if let last = result.last,
           NSMaxRange(last.fullRange) == text.length,
           NSMaxRange(last.contentRange) < text.length {
            result.append(FastraLogicalLine(
                contentRange: NSRange(location: text.length, length: 0),
                fullRange: NSRange(location: text.length, length: 0)
            ))
        }
        return result
    }

    func fastraLineIndex(
        containing range: NSRange,
        in lines: [FastraLogicalLine]
    ) -> Int? {
        lines.firstIndex {
            range.location >= $0.contentRange.location
                && NSMaxRange(range) <= NSMaxRange($0.contentRange)
        }
    }

    func fastraLineAndColumn(at point: CGPoint) -> (line: Int, column: Int)? {
        guard let position = layoutManager.textLineForPosition(max(point.y, 0)) else {
            return nil
        }
        let lines = fastraLogicalLines()
        guard lines.indices.contains(position.index) else { return nil }
        let line = lines[position.index]

        let relativeY = max(point.y - position.yPos, 0)
        guard let fragment = position.data.lineFragments.getLine(
            atPosition: relativeY
        ) else {
            let offset = layoutManager.textOffsetAtPoint(point)
                ?? line.contentRange.location
            return (
                position.index,
                fastraVisualColumn(at: offset, in: line)
            )
        }

        let fragmentOffset = min(
            line.contentRange.location + fragment.range.location,
            NSMaxRange(line.contentRange)
        )
        let fragmentColumn = fastraVisualColumn(
            at: fragmentOffset,
            in: line
        )
        let width = max(
            (" " as NSString).size(withAttributes: [
                .font: font,
                .kern: kern,
            ]).width,
            1
        )
        let localColumn = max(
            Int(floor((point.x - layoutManager.edgeInsets.left) / width)),
            0
        )
        return (position.index, fragmentColumn + localColumn)
    }

    func fastraVisualColumn(at offset: Int, in line: FastraLogicalLine) -> Int {
        let bounded = min(
            max(offset, line.contentRange.location),
            NSMaxRange(line.contentRange)
        )
        let prefixRange = NSRange(
            location: line.contentRange.location,
            length: bounded - line.contentRange.location
        )
        return fastraVisualWidth(
            of: (string as NSString).substring(with: prefixRange),
            startingAt: 0
        )
    }

    func fastraVisualWidth(of value: String, startingAt start: Int) -> Int {
        var column = start
        for character in value {
            if character == "\t" {
                column += fastraColumnSelectionTabWidth
                    - (column % fastraColumnSelectionTabWidth)
            } else {
                // `Character` ist bereits ein vollständiges Graphem. Damit
                // zählen Emoji und kombinierende Sequenzen genau einmal.
                column += 1
            }
        }
        return column - start
    }

    func fastraOffset(
        forColumn target: Int,
        in line: FastraLogicalLine,
        edge: FastraColumnEdge
    ) -> Int {
        let content = (string as NSString).substring(with: line.contentRange)
        var column = 0
        var utf16Offset = 0

        for character in content {
            if target <= column {
                return line.contentRange.location + utf16Offset
            }
            let characterLength = String(character).utf16.count
            let nextColumn: Int
            if character == "\t" {
                nextColumn = column + fastraColumnSelectionTabWidth
                    - (column % fastraColumnSelectionTabWidth)
            } else {
                nextColumn = column + 1
            }

            if target < nextColumn {
                return line.contentRange.location + utf16Offset
                    + (edge == .trailing ? characterLength : 0)
            }
            utf16Offset += characterLength
            column = nextColumn
        }
        return NSMaxRange(line.contentRange)
    }

    func fastraRange(
        in line: FastraLogicalLine,
        lowerColumn: Int,
        upperColumn: Int
    ) -> NSRange {
        let start = fastraOffset(
            forColumn: lowerColumn,
            in: line,
            edge: .leading
        )
        let end = fastraOffset(
            forColumn: upperColumn,
            in: line,
            edge: .trailing
        )
        return NSRange(location: start, length: max(end - start, 0))
    }

    func fastraSetColumnSelection(
        anchorLine: Int,
        headLine: Int,
        anchorColumn: Int,
        headColumn: Int
    ) {
        let lines = fastraLogicalLines()
        guard lines.indices.contains(anchorLine),
              lines.indices.contains(headLine) else {
            return
        }

        let lowerLine = min(anchorLine, headLine)
        let upperLine = max(anchorLine, headLine)
        let lowerColumn = min(anchorColumn, headColumn)
        let upperColumn = max(anchorColumn, headColumn)
        let rows = (lowerLine...upperLine).map { lineIndex in
            FastraColumnRow(
                lineIndex: lineIndex,
                range: fastraRange(
                    in: lines[lineIndex],
                    lowerColumn: lowerColumn,
                    upperColumn: upperColumn
                )
            )
        }

        selectionManager.setSelectedRanges(rows.map(\.range))
        fastraColumnSelectionState = FastraColumnSelectionState(
            anchorLine: anchorLine,
            headLine: headLine,
            anchorColumn: anchorColumn,
            headColumn: headColumn,
            rows: rows
        )
        setNeedsDisplay()
    }

    func fastraClipboardLines(_ value: String) -> [String] {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        // Ein einzelner abschließender Trenner bezeichnet wie in BBEdit das
        // Ende der letzten Clipboard-Zeile, nicht noch eine zusätzliche Zeile.
        if lines.count > 1, lines.last == "" {
            lines.removeLast()
        }
        return lines.isEmpty ? [""] : lines
    }

    func fastraPadding(from currentColumn: Int, to targetColumn: Int) -> String {
        guard currentColumn < targetColumn else { return "" }
        var result = ""
        var column = currentColumn
        if fastraColumnIndentationUnit == "\t" {
            while column < targetColumn {
                let next = column + fastraColumnSelectionTabWidth
                    - (column % fastraColumnSelectionTabWidth)
                guard next <= targetColumn else { break }
                result.append("\t")
                column = next
            }
        }
        if column < targetColumn {
            result += String(repeating: " ", count: targetColumn - column)
        }
        return result
    }

    func fastraApplyColumnRows(
        _ clipboardLines: [String],
        requiresSelection: Bool
    ) {
        let activeState = fastraValidColumnSelectionState()
        guard !requiresSelection || activeState != nil else { return }
        let logicalLines = fastraLogicalLines()
        guard !logicalLines.isEmpty else { return }

        let startLine: Int
        let lowerColumn: Int
        let selectedRows: [Int: NSRange]
        if let activeState {
            startLine = activeState.rows.first?.lineIndex ?? 0
            lowerColumn = min(
                activeState.anchorColumn,
                activeState.headColumn
            )
            selectedRows = Dictionary(
                uniqueKeysWithValues: activeState.rows.map {
                    ($0.lineIndex, $0.range)
                }
            )
        } else {
            let cursor = selectionManager.textSelections.first?.range.location ?? 0
            let lineIndex = logicalLines.firstIndex {
                cursor >= $0.contentRange.location
                    && cursor <= NSMaxRange($0.contentRange)
            } ?? 0
            startLine = lineIndex
            lowerColumn = fastraVisualColumn(
                at: cursor,
                in: logicalLines[lineIndex]
            )
            selectedRows = [:]
        }

        let selectionCount = activeState?.rows.count ?? 0
        let operationCount: Int
        if activeState != nil, clipboardLines.count == 1 {
            operationCount = selectionCount
        } else if activeState != nil {
            operationCount = max(selectionCount, clipboardLines.count)
        } else {
            operationCount = clipboardLines.count
        }

        var changes: [FastraColumnChange] = []
        var cursorColumns: [(line: Int, column: Int)] = []
        var appendedRows: [(line: Int, value: String, cursorColumn: Int)] = []

        for index in 0..<operationCount {
            let lineIndex = startLine + index
            let replacement: String?
            if clipboardLines.count == 1 {
                replacement = clipboardLines[0]
            } else {
                replacement = clipboardLines.indices.contains(index)
                    ? clipboardLines[index]
                    : nil
            }

            guard logicalLines.indices.contains(lineIndex) else {
                if let replacement {
                    appendedRows.append((
                        line: lineIndex,
                        value: replacement,
                        cursorColumn: lowerColumn + fastraVisualWidth(
                            of: replacement,
                            startingAt: lowerColumn
                        )
                    ))
                }
                continue
            }

            let line = logicalLines[lineIndex]
            let range = selectedRows[lineIndex] ?? NSRange(
                location: fastraOffset(
                    forColumn: lowerColumn,
                    in: line,
                    edge: .leading
                ),
                length: 0
            )
            let actualColumn = fastraVisualColumn(
                at: range.location,
                in: line
            )
            // Nur Paste Column füllt bis zur Zielspalte auf. Normales Paste
            // und Löschen verhalten sich auf kurzen Zeilen wie Tippen: am
            // echten Zeilenende, ohne unsichtbaren Leerraum einzuschieben.
            let padding = replacement == nil || requiresSelection
                ? ""
                : fastraPadding(
                    from: actualColumn,
                    to: lowerColumn
                )
            let inserted = padding + (replacement ?? "")
            changes.append(FastraColumnChange(
                range: range,
                replacement: inserted
            ))
            let resultingColumn = replacement.map {
                lowerColumn + fastraVisualWidth(
                    of: $0,
                    startingAt: lowerColumn
                )
            } ?? min(
                lowerColumn,
                fastraVisualColumn(
                    at: NSMaxRange(line.contentRange),
                    in: line
                )
            )
            cursorColumns.append((lineIndex, resultingColumn))
        }

        if !appendedRows.isEmpty {
            let separator = layoutManager.detectedLineEnding.rawValue
            var appended = ""
            for row in appendedRows {
                appended += separator
                appended += fastraPadding(from: 0, to: lowerColumn)
                appended += row.value
                cursorColumns.append((row.line, row.cursorColumn))
            }
            changes.append(FastraColumnChange(
                range: NSRange(location: (string as NSString).length, length: 0),
                replacement: appended
            ))
        }

        guard changes.contains(where: {
            $0.range.length > 0 || !$0.replacement.isEmpty
        }) else {
            return
        }

        fastraApplyChanges(changes)
        fastraColumnSelectionState = nil

        let updatedLines = fastraLogicalLines()
        let cursors = cursorColumns.compactMap { item -> NSRange? in
            guard updatedLines.indices.contains(item.line) else { return nil }
            let offset = fastraOffset(
                forColumn: item.column,
                in: updatedLines[item.line],
                edge: .leading
            )
            return NSRange(location: offset, length: 0)
        }
        if !cursors.isEmpty {
            selectionManager.setSelectedRanges(cursors)
        }
        scrollSelectionToVisible()
    }

    func fastraApplyChanges(_ changes: [FastraColumnChange]) {
        let startsGrouping = !(_undoManager?.isGrouping ?? false)
        if startsGrouping {
            _undoManager?.beginUndoGrouping()
        }
        for change in changes.sorted(by: {
            $0.range.location > $1.range.location
        }) {
            replaceCharacters(
                in: change.range,
                with: change.replacement,
                skipUpdateSelection: true
            )
        }
        if startsGrouping {
            _undoManager?.endUndoGrouping()
        }
    }
}
