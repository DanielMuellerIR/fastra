import sys

path = sys.argv[1]
src = open(path).read()
old = '''        var lastFrame: CGRect = .zero
        while let boundingRect = getSelection()?.boundingRect, lastFrame != boundingRect {
            lastFrame = boundingRect'''
new = '''        var lastFrame: CGRect = .zero
        while let selection = getSelection(),
              let activeRect = layoutManager.rectForOffset(offsetNotPivot(selection)),
              lastFrame != activeRect {
            // Fastra-Patch: bewegte Auswahlkante statt Gesamtauswahl. Deren
            // sichtbarer Ausschnitt verankert sonst die Oberkante und laesst
            // Shift+Pfeil unten aus dem Viewport laufen.
            lastFrame = activeRect'''
if old not in src:
    raise SystemExit(
        f"{path}: Scroll-Auswahlpfad hat sich geaendert — Patch 4r pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
