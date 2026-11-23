import sys

path = sys.argv[1]
src = open(path).read()
old = '''        let scrollView = controller.scrollView
        if let scrollPosition = state.scrollPosition, scrollPosition != scrollView?.contentView.bounds.origin {'''
new = '''        let scrollView = controller.scrollView
        // Fastra-Patch: Scroll-Reconcile deaktiviert. `state.scrollPosition`
        // ist wegen des Runloop-versetzten Rueckschreibers praktisch immer
        // einen Schritt alt; der Vergleich unten drehte deshalb frische
        // Tipp-Scrolls zurueck (Cursor verschwand unter dem Fensterrand).
        // Fastra steuert Scrollen ausschliesslich selbst.
        if false, let scrollPosition = state.scrollPosition, scrollPosition != scrollView?.contentView.bounds.origin {'''
if old not in src:
    raise SystemExit(
        f"{path}: Scroll-Reconcile-Struktur hat sich geaendert — Patch 4x pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
