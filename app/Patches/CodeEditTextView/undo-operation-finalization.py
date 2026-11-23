import sys

path = sys.argv[1]
src = open(path).read()

def replace_once(old, new, label):
    global src
    if old not in src:
        raise SystemExit(f"{path}: {label} hat sich geaendert — Patch 4q pruefen")
    src = src.replace(old, new, 1)

replace_once(
    '''import AppKit
import TextStory
''',
    '''import AppKit
import TextStory

/// Eine kleine, an eine konkrete Undo-Gruppe gebundene Fastra-Nebenwirkung.
/// `discard` laeuft hoechstens einmal, auch wenn Stack-Cleanup und `deinit`
/// denselben verworfenen Redo-Zweig erreichen.
public final class FastraUndoSideEffect {
    private let undoAction: () -> Void
    private let redoAction: () -> Void
    private let discardAction: () -> Void
    private var wasDiscarded = false

    init(undo: @escaping () -> Void,
         redo: @escaping () -> Void,
         discard: @escaping () -> Void) {
        undoAction = undo
        redoAction = redo
        discardAction = discard
    }

    func performUndo() { if !wasDiscarded { undoAction() } }
    func performRedo() { if !wasDiscarded { redoAction() } }
    func discard() {
        guard !wasDiscarded else { return }
        wasDiscarded = true
        discardAction()
    }

    deinit { discard() }
}
''',
    "Import-Anker"
)
replace_once(
    '''        var fastraSelectionsBefore: [NSRange]?
        var fastraSelectionsAfter: [NSRange]?
    }''',
    '''        var fastraSelectionsBefore: [NSRange]?
        var fastraSelectionsAfter: [NSRange]?
        // Fastra-Patch: dateibezogene Nebenwirkungen gehoeren direkt zur
        // konkreten Undo-Gruppe statt zu globalen Undo-Benachrichtigungen.
        var fastraSideEffects: [FastraUndoSideEffect]
    }''',
    "UndoGroup"
)
replace_once(
    '''        textView.scrollSelectionToVisible()

        NotificationCenter.default.post(name: .NSUndoManagerDidUndoChange, object: self)''',
    '''        textView.scrollSelectionToVisible()
        item.fastraSideEffects.forEach { $0.performUndo() }

        NotificationCenter.default.post(name: .NSUndoManagerDidUndoChange, object: self)''',
    "Undo-Abschluss"
)
replace_once(
    '''        textView.scrollSelectionToVisible()

        NotificationCenter.default.post(name: .NSUndoManagerDidRedoChange, object: self)''',
    '''        textView.scrollSelectionToVisible()
        item.fastraSideEffects.forEach { $0.performRedo() }

        NotificationCenter.default.post(name: .NSUndoManagerDidRedoChange, object: self)''',
    "Redo-Abschluss"
)
replace_once(
    '''    /// Clears the undo/redo stacks.
    public func clearStack() {
        undoStack.removeAll()
        redoStack.removeAll()
    }''',
    '''    /// Haengt eine Fastra-Nebenwirkung an exakt die zuletzt registrierte
    /// Textaenderung. Ein neuer Edit nach Undo verwirft den Redo-Zweig.
    @discardableResult
    public func fastraRegisterSideEffectForLatestUndo(
        undo: @escaping () -> Void,
        redo: @escaping () -> Void,
        discard: @escaping () -> Void
    ) -> Bool {
        guard !isUndoing, !isRedoing, !undoStack.isEmpty else { return false }
        undoStack[undoStack.count - 1].fastraSideEffects.append(
            FastraUndoSideEffect(undo: undo, redo: redo, discard: discard)
        )
        return true
    }

    /// Clears the undo/redo stacks.
    public func clearStack() {
        (undoStack + redoStack).flatMap(\\.fastraSideEffects)
            .forEach { $0.discard() }
        undoStack.removeAll()
        redoStack.removeAll()
    }''',
    "clearStack"
)
replace_once(
    '''                fastraSelectionsBefore: nil,
                fastraSelectionsAfter: nil
            ))''',
    '''                fastraSelectionsBefore: nil,
                fastraSelectionsAfter: nil,
                fastraSideEffects: []
            ))''',
    "UndoGroup-Initialisierung"
)
replace_once(
    '''        redoStack.removeAll()
    }

    // MARK: - Grouping''',
    '''        redoStack.flatMap(\\.fastraSideEffects).forEach { $0.discard() }
        redoStack.removeAll()
    }

    // MARK: - Grouping''',
    "Redo-Verwerfen"
)
open(path, "w").write(src)
