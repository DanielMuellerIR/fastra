import sys

path = sys.argv[1]
src = open(path).read()
old = '''    fileprivate func updateAfterMove() {
        unmarkTextIfNeeded()
        scrollSelectionToVisible()
    }'''
new = '''    fileprivate func updateAfterMove() {
        unmarkTextIfNeeded()
        scrollSelectionToVisible()
        // Fastra-Patch: verzoegerter Scroll-Abgleich fuer Auswahlen. In langen
        // Soft-Wrap-Dokumenten kann der erste Aufruf noch mit geschaetzten
        // Zeilenhoehen arbeiten. Nach dem aktuellen Runloop ist der neue
        // Bereich ausgelegt; dann die aktive Kante nochmals sichtbar machen.
        guard selectionManager.textSelections.contains(where: {
            !$0.range.isEmpty
        }) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.scrollSelectionToVisible()
        }
    }'''
if old not in src:
    raise SystemExit(
        f"{path}: Bewegungs-Abgleich hat sich geaendert — Patch 4r pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
