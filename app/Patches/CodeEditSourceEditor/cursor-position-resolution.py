import pathlib, sys

path = pathlib.Path(sys.argv[1])
source = path.read_text()
old = '''            if position.end != nil {
                range = NSRange(
                    location: linePosition.range.location + position.start.column,
                    length: linePosition.range.max
                )
            } else {
                range = NSRange(location: linePosition.range.location + position.start.column, length: 0)
            }'''
new = '''            // Fastra-Patch: Zeile/Spalte als exakte UTF-16-Auswahl aufloesen.
            let startOffset = linePosition.range.location + position.start.column - 1
            var endOffset = startOffset
            if let end = position.end {
                guard end.line > 0, end.column > 0,
                      let endLine = textView.layoutManager.textLineForIndex(end.line - 1) else {
                    return nil
                }
                endOffset = endLine.range.location + end.column - 1
            }
            guard startOffset >= 0, endOffset >= startOffset,
                  endOffset <= textView.textStorage.length else { return nil }
            range = NSRange(location: startOffset, length: endOffset - startOffset)'''
if old in source:
    source = source.replace(old, new, 1)
    path.write_text(source)
if source.count(new) != 1 or old in source:
    raise SystemExit(f"{path}: Patch 4c-3 hat nicht gegriffen — Cursor-Aufloesung pruefen")
