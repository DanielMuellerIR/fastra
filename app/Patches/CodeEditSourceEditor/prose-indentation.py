import sys

path = sys.argv[1]
src = open(path).read()
old = '''        switch language.id {
        case .python:
            return TextualIndenter(patterns: TextualIndenter.pythonPatterns)'''
new = '''        switch language.id {
        case .plainText, .markdown:
            // Fastra-Patch: Markdown verwendet keine Code-Klammermuster;
            // dasselbe gilt fuer echten Fliesstext.
            // Eine leere unmittelbare Vorzeile ist zudem ein bewusster
            // Einrueckungs-Reset und darf nicht uebersprungen werden.
            return TextualIndenter(patterns: [], referenceLinePredicate: { _, _ in true })
        case .python:
            return TextualIndenter(patterns: TextualIndenter.pythonPatterns)'''
if old not in src:
    raise SystemExit(f"{path}: Indenter-Switch hat sich geaendert — Patch 4z2 pruefen")
open(path, "w").write(src.replace(old, new, 1))
