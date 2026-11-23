import sys

path = sys.argv[1]
src = open(path).read()

old_group = '''    private struct UndoGroup {
        var mutations: [Mutation]
    }'''
new_group = '''    private struct UndoGroup {
        var mutations: [Mutation]
        // Fastra-Patch: Auswahlzustand grosser Textoperationen. Optional,
        // damit CodeEdits Standardverhalten fuer alle anderen Edits bleibt.
        var fastraSelectionsBefore: [NSRange]?
        var fastraSelectionsAfter: [NSRange]?
    }'''
if old_group not in src:
    raise SystemExit(
        f"{path}: UndoGroup hat sich geaendert — Patch 4q pruefen"
    )
src = src.replace(old_group, new_group, 1)

old_undo = '''        updateSelectionsForMutations(mutations: item.mutations.map { $0.mutation })
        textView.scrollSelectionToVisible()'''
new_undo = '''        if let selections = item.fastraSelectionsBefore {
            textView.selectionManager.setSelectedRanges(selections)
            // Fastra-Patch: Layout nach grosser Textoperation synchron am
            // wiederhergestellten Auswahlanker aufbauen.
            textView.layoutManager.setNeedsLayout()
            textView.layoutManager.layoutLines()
            textView.needsDisplay = true
        } else {
            updateSelectionsForMutations(mutations: item.mutations.map { $0.mutation })
        }
        textView.scrollSelectionToVisible()'''
if old_undo not in src:
    raise SystemExit(
        f"{path}: Undo-Auswahlpfad hat sich geaendert — Patch 4q pruefen"
    )
src = src.replace(old_undo, new_undo, 1)

old_redo = '''        updateSelectionsForMutations(mutations: item.mutations.map { $0.inverse })
        textView.scrollSelectionToVisible()'''
new_redo = '''        if let selections = item.fastraSelectionsAfter {
            textView.selectionManager.setSelectedRanges(selections)
            // Fastra-Patch: Layout nach grosser Textoperation synchron am
            // wiederhergestellten Auswahlanker aufbauen.
            textView.layoutManager.setNeedsLayout()
            textView.layoutManager.layoutLines()
            textView.needsDisplay = true
        } else {
            updateSelectionsForMutations(mutations: item.mutations.map { $0.inverse })
        }
        textView.scrollSelectionToVisible()'''
if old_redo not in src:
    raise SystemExit(
        f"{path}: Redo-Auswahlpfad hat sich geaendert — Patch 4q pruefen"
    )
src = src.replace(old_redo, new_redo, 1)

old_group_init = '''            undoStack.append(UndoGroup(mutations: [newMutation]))
            shouldBreakNextGroup = false'''
new_group_init = '''            undoStack.append(UndoGroup(
                mutations: [newMutation],
                fastraSelectionsBefore: nil,
                fastraSelectionsAfter: nil
            ))
            shouldBreakNextGroup = false'''
if old_group_init not in src:
    raise SystemExit(
        f"{path}: UndoGroup-Initialisierung hat sich geaendert — Patch 4q pruefen"
    )
src = src.replace(old_group_init, new_group_init, 1)

anchor = '''    /// Clears the undo/redo stacks.
    public func clearStack() {'''
method = '''    /// Fastra-Patch: Auswahlzustand grosser Textoperationen opt-in
    /// hinterlegen. So stellt Undo den Cursor vor der Transformation und Redo
    /// die Auswahl danach wieder her, statt die komplette Mutationsrange zu
    /// markieren.
    public func fastraSetSelectionSnapshotsForLatestUndo(
        before: [NSRange],
        after: [NSRange]
    ) {
        guard !isUndoing, !isRedoing, !undoStack.isEmpty else { return }
        undoStack[undoStack.count - 1].fastraSelectionsBefore = before
        undoStack[undoStack.count - 1].fastraSelectionsAfter = after
    }

    /// Clears the undo/redo stacks.
    public func clearStack() {'''
if anchor not in src:
    raise SystemExit(
        f"{path}: clearStack-Anker hat sich geaendert — Patch 4q pruefen"
    )
src = src.replace(anchor, method, 1)

open(path, "w").write(src)
