#!/usr/bin/env python3
"""Bild-I/O außerhalb des Main-Threads abschließen und verworfene Gruppen abweisen."""
from pathlib import Path
import sys

path = Path(sys.argv[1]) / 'Sources/CodeEditTextView/Utils/CEUndoManager.swift'
source = path.read_text()
marker = '// Fastra-Patch: asynchrone Bilddateiaktionen'

def replace(old, new):
    global source
    if source.count(old) != 1:
        raise SystemExit('Bild-Undo: Anker fehlt oder ist mehrdeutig')
    source = source.replace(old, new)

if marker not in source:
    replace('    private let undoAction: () -> Void', '''    private let undoAsyncAction: ((String, @escaping () -> Void) -> Void)?
    private let prepareRedoAsyncAction: ((@escaping (Bool) -> Void) -> Void)?
    private let cancelRedoAsyncAction: (@escaping () -> Void) -> Void
    private let documentSavedAction: (String, URL) -> Void
    private let undoAction: () -> Void''')
    replace('         discard: @escaping () -> Void) {', '''         undoAsync: ((String, @escaping () -> Void) -> Void)?,
         prepareRedoAsync: ((@escaping (Bool) -> Void) -> Void)?,
         cancelRedoAsync: @escaping (@escaping () -> Void) -> Void,
         documentSaved: @escaping (String, URL) -> Void,
         discard: @escaping () -> Void) {''')
    replace('        undoAction = undo', '''        undoAsyncAction = undoAsync
        prepareRedoAsyncAction = prepareRedoAsync
        cancelRedoAsyncAction = cancelRedoAsync
        documentSavedAction = documentSaved
        undoAction = undo''')
    replace('    func performUndo() {', '''    func performUndoAsync(_ text: String, completion: @escaping () -> Void) {
        if let undoAsyncAction, !wasDiscarded { undoAsyncAction(text, completion) }
        else { performUndo(); completion() }
    }
    func prepareRedoAsync(completion: @escaping (Bool) -> Void) {
        guard !wasDiscarded else { completion(false); return }
        if let prepareRedoAsyncAction { prepareRedoAsyncAction(completion) }
        else { completion(true) }
    }
    func cancelRedoAsync(completion: @escaping () -> Void) {
        cancelPreparedRedo()
        cancelRedoAsyncAction(completion)
    }
    func documentSaved(_ text: String, at url: URL) {
        if !wasDiscarded { documentSavedAction(text, url) }
    }
    func performUndo() {''')
    replace('    private var _isUndoing: Bool = false', '''    // Fastra-Patch: asynchrone Bilddateiaktionen
    private var fastraHistoryEpoch: UInt64 = 0
    private var _isUndoing: Bool = false''')
    replace('override public var canUndo: Bool { !undoStack.isEmpty }', 'override public var canUndo: Bool { !isUndoing && !isRedoing && !undoStack.isEmpty }')
    replace('override public var canRedo: Bool { !redoStack.isEmpty }', 'override public var canRedo: Bool { !isUndoing && !isRedoing && !redoStack.isEmpty }')
    replace('''    override public func undo() {
        guard !isDisabled, let textView else {''', '''    override public func undo() {
        guard !isDisabled, !isUndoing, !isRedoing, let textView else {''')
    replace('''        _isUndoing = true
        NotificationCenter''', '''        let epoch = fastraHistoryEpoch
        let wasEditable = textView.isEditable
        let hadFocus = textView.isFirstResponder
        if !item.fastraSideEffects.isEmpty { textView.isEditable = false }
        _isUndoing = true
        NotificationCenter''')
    replace('''        item.fastraSideEffects.forEach { $0.performUndo() }

        NotificationCenter.default.post(name: .NSUndoManagerDidUndoChange, object: self)
        redoStack.append(item)
        _isUndoing = false''', '''        func finish(_ index: Int) {
            if index < item.fastraSideEffects.count {
                var completed = false
                item.fastraSideEffects[index].performUndoAsync(textView.string) {
                    guard !completed else { return }
                    completed = true
                    finish(index + 1)
                }
                return
            }
            if fastraHistoryEpoch == epoch { redoStack.append(item) }
            else { item.fastraSideEffects.forEach { $0.discard() } }
            _isUndoing = false
            if !item.fastraSideEffects.isEmpty {
                textView.isEditable = wasEditable
                if hadFocus, textView.window?.firstResponder === textView { textView.window?.makeFirstResponder(textView) }
            }
            NotificationCenter.default.post(name: .NSUndoManagerDidUndoChange, object: self)
        }
        finish(0)''')
    start = source.index('    override public func redo() {')
    end = source.index('    /// We often undo/redo', start)
    old = source[start:end]
    body_start = old.index('        NotificationCenter.default.post(name: .NSUndoManagerWillRedoChange')
    body_end = old.index('        NotificationCenter.default.post(name: .NSUndoManagerDidRedoChange')
    body = old[body_start:body_end]
    new = '''    override public func redo() {
        guard !isDisabled, !isUndoing, !isRedoing, let textView else { return }
        guard let candidate = redoStack.last else { NSSound.beep(); return }
        let epoch = fastraHistoryEpoch
        let before = textView.string
        let wasEditable = textView.isEditable
        let hadFocus = textView.isFirstResponder
        if !candidate.fastraSideEffects.isEmpty { textView.isEditable = false }
        _isRedoing = true
        var prepared: [FastraUndoSideEffect] = []
        func unlock() {
            self._isRedoing = false
            if !candidate.fastraSideEffects.isEmpty {
                textView.isEditable = wasEditable
                if hadFocus, textView.window?.firstResponder === textView { textView.window?.makeFirstResponder(textView) }
            }
        }
        func cancel(_ index: Int) {
            guard index >= 0 else { unlock(); return }
            prepared[index].cancelRedoAsync { cancel(index - 1) }
        }
        func prepare(_ index: Int) {
            guard self.fastraHistoryEpoch == epoch, self.textView === textView,
                  textView.string.utf8.elementsEqual(before.utf8), !self.redoStack.isEmpty else {
                cancel(prepared.count - 1)
                return
            }
            if index < candidate.fastraSideEffects.count {
                let effect = candidate.fastraSideEffects[index]
                guard effect.prepareRedo() else { cancel(prepared.count - 1); return }
                var completed = false
                effect.prepareRedoAsync { success in
                    guard !completed else { return }
                    completed = true
                    if success { prepared.append(effect); prepare(index + 1) }
                    else { cancel(prepared.count - 1) }
                }
                return
            }
            let item = self.redoStack.removeLast()
''' + body + '''            if self.fastraHistoryEpoch == epoch { self.undoStack.append(item) }
            else { item.fastraSideEffects.forEach { $0.discard() } }
            unlock()
            NotificationCenter.default.post(name: .NSUndoManagerDidRedoChange, object: self)
        }
        prepare(0)
    }

'''
    replace(old, new)
    replace('''        cancelPreparedRedo: @escaping () -> Void = {},
        discard:''', '''        cancelPreparedRedo: @escaping () -> Void = {},
        undoAsync: ((String, @escaping () -> Void) -> Void)? = nil,
        prepareRedoAsync: ((@escaping (Bool) -> Void) -> Void)? = nil,
        cancelRedoAsync: @escaping (@escaping () -> Void) -> Void = { $0() },
        documentSaved: @escaping (String, URL) -> Void = { _, _ in },
        discard:''')
    replace('cancelPreparedRedo: cancelPreparedRedo, discard: discard)', 'cancelPreparedRedo: cancelPreparedRedo, undoAsync: undoAsync, prepareRedoAsync: prepareRedoAsync, cancelRedoAsync: cancelRedoAsync, documentSaved: documentSaved, discard: discard)')
    replace('''    public func clearStack() {
        (undoStack''', '''    public func clearStack() {
        fastraHistoryEpoch &+= 1
        (undoStack''')
    replace('    // MARK: - Mutations', '''    public func fastraDocumentSaved(_ text: String, at url: URL) {
        (undoStack + redoStack).flatMap(\\.fastraSideEffects).forEach { $0.documentSaved(text, at: url) }
    }

    // MARK: - Mutations''')
    replace('        let newMutation = Mutation(', '        fastraHistoryEpoch &+= 1\n        let newMutation = Mutation(')

# Auch bereits gepatchte lokale Checkouts kontrolliert auf den aktuellen Stand bringen.
def ensure(old, new):
    if new not in source:
        replace(old, new)

if '        if !item.fastraSideEffects.isEmpty { textView.isEditable = false }\n        _isUndoing = true' in source:
    replace('        if !item.fastraSideEffects.isEmpty { textView.isEditable = false }\n        _isUndoing = true', '        _isUndoing = true')
ensure('        func finish(_ index: Int) {', '        if !item.fastraSideEffects.isEmpty { textView.isEditable = false }\n        func finish(_ index: Int) {')
ensure('            let item = self.redoStack.removeLast()\n', '            let item = self.redoStack.removeLast()\n            textView.isEditable = wasEditable\n')
ensure('    private var fastraHistoryEpoch: UInt64 = 0', '    private var fastraHistoryEpoch: UInt64 = 0\n    private var fastraIdleActions: [() -> Void] = []')
ensure('    public func fastraDocumentSaved(_ text: String, at url: URL) {', '    public func fastraWhenIdle(_ action: @escaping () -> Void) {\n        if isUndoing || isRedoing { fastraIdleActions.append(action) }\n        else { action() }\n    }\n\n    private func fastraNotifyIdle() {\n        let actions = fastraIdleActions\n        fastraIdleActions.removeAll()\n        actions.forEach { $0() }\n    }\n\n    public func fastraDocumentSaved(_ text: String, at url: URL) {')
ensure('            NotificationCenter.default.post(name: .NSUndoManagerDidUndoChange, object: self)\n        }', '            NotificationCenter.default.post(name: .NSUndoManagerDidUndoChange, object: self)\n            fastraNotifyIdle()\n        }')
ensure('        func cancel(_ index: Int) {\n            guard index >= 0 else { unlock(); return }', '        func cancel(_ index: Int) {\n            guard index >= 0 else { unlock(); self.fastraNotifyIdle(); return }')
ensure('            NotificationCenter.default.post(name: .NSUndoManagerDidRedoChange, object: self)\n        }', '            NotificationCenter.default.post(name: .NSUndoManagerDidRedoChange, object: self)\n            self.fastraNotifyIdle()\n        }')

checks = [marker, 'func performUndoAsync(', 'func prepareRedoAsync(', 'func cancelRedoAsync(',
          'public func fastraDocumentSaved(',
          'if fastraHistoryEpoch == epoch { redoStack.append(item) }', 'finish(0)', 'prepare(0)']
if not all(source.count(check) == 1 for check in checks) or source.count('self.fastraHistoryEpoch == epoch') != 2:
    raise SystemExit('Bild-Undo: Selbstprüfung fehlgeschlagen')
if source != path.read_text():
    path.chmod(path.stat().st_mode | 0o200)
    path.write_text(source)
    print('changed')
else:
    print('unchanged')
