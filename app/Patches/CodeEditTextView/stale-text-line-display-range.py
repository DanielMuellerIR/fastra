import sys

path = sys.argv[1]
src = open(path).read()
old = '''        let string = stringRef.attributedSubstring(from: range)
        let maxWidth = typesetter.typeset(
            string,
            documentRange: range,'''
new = '''        // Fastra-Patch: Zeilen-Range gegen das aktuelle Textende clampen.
        // Reentrantes Layout während Undo kann noch mit längerem lineStorage arbeiten.
        // Die Range gegen den aktuellen Text klemmen. Hinter dem Textende ohne
        // Typeset zurückkehren; `setNeedsLayout()` entfernt alte Fragmente und
        // fordert Layout mit aktualisiertem lineStorage an.
        let clampedLocation = min(range.location, stringRef.length)
        let clampedRange = NSRange(
            location: clampedLocation,
            length: min(range.length, stringRef.length - clampedLocation)
        )
        if clampedRange != range && clampedRange.length == 0 {
            setNeedsLayout()
            return
        }
        let string = stringRef.attributedSubstring(from: clampedRange)
        let maxWidth = typesetter.typeset(
            string,
            documentRange: clampedRange,'''
if old not in src:
    raise SystemExit(
        f"{path}: prepareForDisplay-Struktur hat sich geaendert — Patch 4z pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
