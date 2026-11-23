import sys

path = sys.argv[1]
src = open(path).read()
old = '''        guard let visibleRect = rect ?? delegate?.visibleRect,
              !isInTransaction,
              let textStorage else {
            return []
        }'''
new = '''        // Fastra-Patch: toter Transaktionsschutz durch Laengenvergleich ersetzt.
        // `isInTransaction` ist immer false (transactionCounter wird nirgends
        // erhoeht). Weicht die Laenge des Zeilen-Storage vom echten Text ab
        // (Undo-Klammer, reentranter Scroll-Callback), layouten wir nicht
        // gegen den inkonsistenten Zwischenstand — der naechste Durchlauf
        // laeuft mit nachgezogenem lineStorage.
        guard let visibleRect = rect ?? delegate?.visibleRect,
              !isInTransaction,
              let textStorage,
              lineStorage.length == textStorage.length else {
            return []
        }'''
if old not in src:
    raise SystemExit(
        f"{path}: layoutLines-Guard hat sich geaendert — Patch 4z1 pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
