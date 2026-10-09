#!/usr/bin/env python3
"""Datei-Nebenwirkungen vor dem Wiederherstellen ihrer Textverweise prüfen."""
from pathlib import Path
import sys

path = Path(sys.argv[1]) / 'Sources/CodeEditTextView/Utils/CEUndoManager.swift'
s = path.read_text()

def replace(old, new):
    global s
    if new not in s:
        if s.count(old) != 1:
            raise SystemExit('CEUndoManager: Redo-Anker fehlt oder ist mehrdeutig')
        s = s.replace(old, new)
    if s.count(new) != 1:
        raise SystemExit('CEUndoManager: Redo-Patch unvollständig')

replace('    private let redoAction: () -> Void',
        '    private let redoAction: () -> Void\n    private let prepareRedoAction: () -> Bool')
replace('    private let discardAction: () -> Void',
        '    private let cancelPreparedRedoAction: () -> Void\n    private let discardAction: () -> Void')
replace('''    init(undo: @escaping () -> Void,
         redo: @escaping () -> Void,
         discard: @escaping () -> Void) {''', '''    init(undo: @escaping () -> Void,
         redo: @escaping () -> Void,
         prepareRedo: @escaping () -> Bool,
         cancelPreparedRedo: @escaping () -> Void,
         discard: @escaping () -> Void) {''')
replace('        discardAction = discard', '''        prepareRedoAction = prepareRedo
        cancelPreparedRedoAction = cancelPreparedRedo
        discardAction = discard''')
replace('    func performRedo() {', '''    func prepareRedo() -> Bool { !wasDiscarded && prepareRedoAction() }
    func cancelPreparedRedo() { cancelPreparedRedoAction() }
    func performRedo() {''')
replace('''        redo: @escaping () -> Void,
        discard:''', '''        redo: @escaping () -> Void,
        prepareRedo: @escaping () -> Bool = { true },
        cancelPreparedRedo: @escaping () -> Void = {},
        discard:''')
replace('FastraUndoSideEffect(undo: undo, redo: redo, discard: discard)',
        'FastraUndoSideEffect(undo: undo, redo: redo, prepareRedo: prepareRedo, cancelPreparedRedo: cancelPreparedRedo, discard: discard)')
replace('''        guard let item = redoStack.popLast() else {
            NSSound.beep()
            return
        }

        _isRedoing = true''', '''        guard let candidate = redoStack.last else { NSSound.beep(); return }
        var prepared: [FastraUndoSideEffect] = []
        for effect in candidate.fastraSideEffects {
            guard effect.prepareRedo() else {
                prepared.reversed().forEach { $0.cancelPreparedRedo() }
                return
            }
            prepared.append(effect)
        }
        let item = redoStack.removeLast()

        _isRedoing = true''')
if path.read_text() != s:
    path.chmod(path.stat().st_mode | 0o200)
    path.write_text(s)
    print('changed')
else:
    print('unchanged')
