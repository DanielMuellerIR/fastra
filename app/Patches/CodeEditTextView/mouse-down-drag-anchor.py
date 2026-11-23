import sys

path = sys.argv[1]
src = open(path).read()
old = '''        switch event.clickCount {
        case 1:
            handleSingleClick(event: event, offset: offset)'''
new = '''        // Fastra-Patch: Drag-Anker am Maus-Down verankern. Upstream setzt
        // ihn erst beim ersten Drag-Ereignis; bei schnellen Bewegungen liegt
        // das bereits weit vom Klickpunkt entfernt (unterhalb des Fensters
        // nach dem Clamping sogar am Dokumentende), und die Auswahl beginnt
        // an der falschen Stelle.
        let anchorInView = self.convert(event.locationInWindow, from: nil)
        mouseDragAnchor = CGPoint(
            x: max(layoutManager.edgeInsets.left, min(anchorInView.x, frame.width)),
            y: max(0.0, min(anchorInView.y, frame.height))
        )

        switch event.clickCount {
        case 1:
            handleSingleClick(event: event, offset: offset)'''
if old not in src:
    raise SystemExit(
        f"{path}: mouseDown hat sich geaendert — Patch 4v pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
