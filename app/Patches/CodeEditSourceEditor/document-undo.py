#!/usr/bin/env python3
"""Dokumentverlauf nach der Speicherinitialisierung anbinden und Modell-Edits sichern."""
from pathlib import Path
import sys

changed = False

def patch(path, old, new):
    global changed
    source = path.read_text()
    if new not in source:
        if source.count(old) != 1:
            raise SystemExit(f'Dokument-Undo: Anker fehlt oder ist mehrdeutig: {path.name}')
        source = source.replace(old, new)
        path.chmod(path.stat().st_mode | 0o200)
        path.write_text(source)
        changed = True
    if path.read_text().count(new) != 1:
        raise SystemExit(f'Dokument-Undo: Selbstprüfung fehlgeschlagen: {path.name}')

editor = Path(sys.argv[1]) / 'Sources/CodeEditSourceEditor/SourceEditor/SourceEditor.swift'
patch(editor, '            undoManager: undoManager,', '''            // setText löscht den Verlauf; den Dokumentmanager erst danach anbinden.
            undoManager: nil,''')
patch(editor, '        if !(state.cursorPositions?.isEmpty ?? true) {', '''        if let undoManager {
            controller.textView.setUndoManager(undoManager)
        }
        if !(state.cursorPositions?.isEmpty ?? true) {''')

manager = Path(sys.argv[2]) / 'Sources/CodeEditTextView/Utils/CEUndoManager.swift'
replacement = '''    /// Modelländerung an einem eventuell nicht montierten Dokument. Die alte
    /// Ansicht darf den neuen Verlauf bis zum erneuten Anbinden nicht ausführen.
    public func fastraRegisterDocumentReplacement(from before: String, to after: String) {
        guard !before.utf8.elementsEqual(after.utf8) else { return }
        fastraHistoryEpoch &+= 1
        textView = nil
        endUndoGrouping()
        let oldLength = (before as NSString).length
        let newLength = (after as NSString).length
        undoStack.append(UndoGroup(
            mutations: [Mutation(
                mutation: TextMutation(string: after, range: NSRange(location: 0, length: oldLength), limit: oldLength),
                inverse: TextMutation(string: before, range: NSRange(location: 0, length: newLength), limit: newLength))],
            fastraSelectionsBefore: [NSRange(location: 0, length: 0)],
            fastraSelectionsAfter: [NSRange(location: 0, length: 0)],
            fastraSideEffects: []))
        shouldBreakNextGroup = true
        redoStack.flatMap(\\.fastraSideEffects).forEach { $0.discard() }
        redoStack.removeAll()
    }

    // MARK: - Grouping'''
previous = replacement.replace('        fastraHistoryEpoch &+= 1\n', '')
legacy = previous.replace('!before.utf8.elementsEqual(after.utf8)', 'before != after')
source = manager.read_text()
anchor = previous if previous in source else legacy if legacy in source else '    // MARK: - Grouping'
patch(manager, anchor, replacement)
print('changed' if changed else 'unchanged')
