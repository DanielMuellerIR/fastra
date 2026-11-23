import sys

update_path, replace_path, selmgr_path = sys.argv[1:4]
update_src = open(update_path).read()
replace_src = open(replace_path).read()
selmgr_src = open(selmgr_path).read()

# a) Wurzel: Anker nach jedem Edit verwerfen.
old_update = '''            } else {
                textSelection.range.length = 0
            }
        }

        // Clean up duplicate selection ranges'''
new_update = '''            } else {
                textSelection.range.length = 0
            }
            // Fastra-Patch: veralteten Auswahl-Anker verwerfen. Der Anker einer früheren
            // Shift-Auswahl gilt nach einem Edit nicht mehr; die nächste Shift-Bewegung
            // beginnt am aktuellen Cursor.
            textSelection.pivot = nil
        }

        // Clean up duplicate selection ranges'''
if old_update not in update_src:
    raise SystemExit(
        f"{update_path}: didReplaceCharacters hat sich geaendert — Patch 4z14a pruefen"
    )
update_src = update_src.replace(old_update, new_update, 1)

# b) Absturzschutz an der Mutationsgrenze.
old_valid = '''        func valid(range: NSRange, string: String) -> Bool {
            (!range.isEmpty || !string.isEmpty) &&
            (delegate?.textView(self, shouldReplaceContentsIn: range, with: string) ?? true)
        }'''
new_valid = '''        func valid(range: NSRange, string: String) -> Bool {
            // Fastra-Patch: korrupten Bereich nicht mutieren. Negative oder außerhalb
            // des Dokuments liegende Ranges nicht an den Undo-Manager weiterreichen.
            // Übrige Bereiche derselben Mehrfachmutation bleiben ausführbar.
            guard range.location >= 0, range.length >= 0,
                  range.location <= textStorage.length,
                  range.max <= textStorage.length else {
                return false
            }
            return (!range.isEmpty || !string.isEmpty) &&
            (delegate?.textView(self, shouldReplaceContentsIn: range, with: string) ?? true)
        }'''
if old_valid not in replace_src:
    raise SystemExit(
        f"{replace_path}: valid(range:string:) hat sich geaendert — Patch 4z14b pruefen"
    )
replace_src = replace_src.replace(old_valid, new_valid, 1)

# c1) setSelectedRange: negative Laenge in den 4t-2-Waechter aufnehmen.
old_single = '''        guard range.location != NSNotFound,
              (0...fastraLimit).contains(range.location),
              (0...fastraLimit).contains(range.max) else {'''
new_single = '''        guard range.location != NSNotFound,
              // Fastra-Patch: negative Laenge abweisen — location und max
              // können dabei beide innerhalb des Dokuments liegen.
              range.length >= 0,
              (0...fastraLimit).contains(range.location),
              (0...fastraLimit).contains(range.max) else {'''
if old_single not in selmgr_src:
    raise SystemExit(
        f"{selmgr_path}: setSelectedRange-Waechter (4t-2) fehlt — Patch 4z14c pruefen"
    )
selmgr_src = selmgr_src.replace(old_single, new_single, 1)

# c2) setSelectedRanges: negative Laenge im Filter abweisen.
old_filter = '''            .filter {
                (0...(textStorage?.length ?? 0)).contains($0.location)
                && (0...(textStorage?.length ?? 0)).contains($0.max)
            }'''
new_filter = '''            .filter {
                // Fastra-Patch: negative Laenge abweisen (Crash 2026-08-24).
                $0.length >= 0
                && (0...(textStorage?.length ?? 0)).contains($0.location)
                && (0...(textStorage?.length ?? 0)).contains($0.max)
            }'''
if old_filter not in selmgr_src:
    raise SystemExit(
        f"{selmgr_path}: setSelectedRanges-Filter hat sich geaendert — Patch 4z14c pruefen"
    )
selmgr_src = selmgr_src.replace(old_filter, new_filter, 1)

# Erst nach allen Validierungen schreiben, damit kein halb gepatchter
# Checkout zurueckbleiben kann.
open(update_path, "w").write(update_src)
open(replace_path, "w").write(replace_src)
open(selmgr_path, "w").write(selmgr_src)
