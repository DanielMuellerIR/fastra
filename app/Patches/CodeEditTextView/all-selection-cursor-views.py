import sys

selmgr_path = sys.argv[1]
selmgr_src = open(selmgr_path).read()

old_update = '''            if textSelection.range.isEmpty {
                didUpdate = didUpdate || repositionCursorSelection(textSelection: textSelection)'''
new_update = '''            if textSelection.range.isEmpty {
                // Fastra-Patch: jede Selektion repositionieren. Kurzschluss-|| würde nach
                // der ersten erzeugten View weitere Cursor einer Rechteckänderung überspringen.
                didUpdate = repositionCursorSelection(textSelection: textSelection) || didUpdate'''
if old_update not in selmgr_src:
    raise SystemExit(
        f"{selmgr_path}: updateSelectionViews hat sich geaendert — Patch 4z17 pruefen"
    )
selmgr_src = selmgr_src.replace(old_update, new_update, 1)

open(selmgr_path, "w").write(selmgr_src)
