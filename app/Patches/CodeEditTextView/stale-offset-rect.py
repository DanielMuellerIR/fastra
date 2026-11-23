import sys

path = sys.argv[1]
src = open(path).read()
old = '''        let realRange = if textStorage?.length == 0 {
            NSRange(location: offset, length: 0)
        } else if let string = textStorage?.string as? NSString {
            string.rangeOfComposedCharacterSequence(at: offset)
        } else {
            NSRange(location: offset, length: 0)
        }'''
new = '''        // Fastra-Patch: Offset gegen den ECHTEN Storage clampen.
        // Nach Undo/Redo kann Zeilen-Storage noch länger sein als der Text.
        // Scrollabfragen alter Cursorpositionen müssen vor
        // `rangeOfComposedCharacterSequence` gegen das aktuelle Textende begrenzt werden.
        let realRange = if textStorage?.length == 0 {
            NSRange(location: offset, length: 0)
        } else if let string = textStorage?.string as? NSString,
                  offset < string.length {
            string.rangeOfComposedCharacterSequence(at: offset)
        } else {
            NSRange(location: offset, length: 0)
        }'''
if old not in src:
    raise SystemExit(
        f"{path}: rectForOffset-Struktur hat sich geaendert — Patch 4w pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
