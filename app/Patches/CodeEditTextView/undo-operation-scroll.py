import sys

path = sys.argv[1]
src = open(path).read()
old_undo = '''        if let selections = item.fastraSelectionsBefore {
            textView.selectionManager.setSelectedRanges(selections)
        } else {
            updateSelectionsForMutations(mutations: item.mutations.map { $0.mutation })
        }'''
new_undo = '''        if let selections = item.fastraSelectionsBefore {
            textView.selectionManager.setSelectedRanges(selections)
            // Fastra-Patch: Layout nach grosser Textoperation synchron am
            // wiederhergestellten Auswahlanker aufbauen.
            textView.layoutManager.setNeedsLayout()
            textView.layoutManager.layoutLines()
            textView.needsDisplay = true
        } else {
            updateSelectionsForMutations(mutations: item.mutations.map { $0.mutation })
        }'''
old_redo = '''        if let selections = item.fastraSelectionsAfter {
            textView.selectionManager.setSelectedRanges(selections)
        } else {
            updateSelectionsForMutations(mutations: item.mutations.map { $0.inverse })
        }'''
new_redo = '''        if let selections = item.fastraSelectionsAfter {
            textView.selectionManager.setSelectedRanges(selections)
            // Fastra-Patch: Layout nach grosser Textoperation synchron am
            // wiederhergestellten Auswahlanker aufbauen.
            textView.layoutManager.setNeedsLayout()
            textView.layoutManager.layoutLines()
            textView.needsDisplay = true
        } else {
            updateSelectionsForMutations(mutations: item.mutations.map { $0.inverse })
        }'''
if old_undo not in src or old_redo not in src:
    raise SystemExit(
        f"{path}: bestehender 4q-Auswahlpfad hat sich geaendert"
    )
src = src.replace(old_undo, new_undo, 1)
src = src.replace(old_redo, new_redo, 1)
open(path, "w").write(src)
