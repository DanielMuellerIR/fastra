import sys

path = sys.argv[1]
src = open(path).read()
old = '''            let endOfDocument = intersectionRange.max == layoutManager.lineStorage.length
            let emptyLine = linePosition.range.isEmpty

            // If the selection is at the end of the line, or contains the end of the fragment, and is not the end
            // of the document, we select the entire line to the right of the selection point.
            // true, !true = false, false
            // true, !true = false, true
            if endOfLine && !(endOfDocument && !emptyLine) {'''
new = '''            let endOfDocument = intersectionRange.max == layoutManager.lineStorage.length
            let emptyLine = linePosition.range.isEmpty
            let lineEndsWithLineEnding = textStorage
                .flatMap { $0.substring(from: linePosition.range) }
                .flatMap(LineEnding.init(line:)) != nil

            // Fastra-Patch: finalen Zeilenumbruch bis zum rechten Rand markieren.
            // `rectForOffset(documentEnd)` liegt dann schon links in der leeren
            // EOF-Zeile und würde für die letzte Textzeile Breite 0 ergeben.
            if endOfLine && (!endOfDocument || emptyLine || lineEndsWithLineEnding) {'''
if old not in src:
    raise SystemExit(
        f"{path}: Quelltext hat sich geaendert — Patch 4p pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
