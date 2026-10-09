    public func handleIndent(inwards: Bool = false) {
        let before = textView.selectionManager.textSelections.map(\.range)
        var indexes = Set<Int>()
        for range in before {
            if let lines = getOverlappingLines(for: range) { indexes.formUnion(lines) }
        }
        let indentation = configuration.behavior.indentOption.stringValue
        var edits: [(range: NSRange, text: String)] = []
        for index in indexes.sorted() {
            guard let line = textView.layoutManager.textLineForIndex(index),
                  let content = textView.textStorage.substring(from: line.range) else { continue }
            let count = configuration.behavior.indentOption == .tab
                ? (content.first == "\t" ? 1 : 0)
                : countLeadingSpacesUpTo(line: content, maxCount: indentation.utf16.count)
            if inwards && count == 0 { continue }
            edits.append((NSRange(location: line.range.lowerBound, length: inwards ? count : 0),
                          inwards ? "" : indentation))
        }
        guard !edits.isEmpty else { return }
        // Originalpositionen gegen die tatsächlich entfernten Zeichen abbilden;
        // kurze Einrückungen dürfen weder negative Cursor noch doppelte Edits ergeben.
        func position(_ original: Int) -> Int {
            var delta = 0
            for edit in edits {
                if original < edit.range.location { break }
                if original < NSMaxRange(edit.range) { return edit.range.location + delta }
                delta += edit.text.utf16.count - edit.range.length
            }
            return original + delta
        }
        let after = before.map { range -> NSRange in
            let start = position(range.location), end = position(NSMaxRange(range))
            return NSRange(location: start, length: max(0, end - start))
        }
        textView.undoManager?.beginUndoGrouping()
        for edit in edits.reversed() {
            textView.replaceCharacters(in: edit.range, with: edit.text, skipUpdateSelection: true)
        }
        textView.selectionManager.setSelectedRanges(after)
        textView.undoManager?.endUndoGrouping()
        (textView.undoManager as? CEUndoManager)?.fastraSetSelectionSnapshotsForLatestUndo(before: before, after: after)
    }
