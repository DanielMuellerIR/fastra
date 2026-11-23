import sys

path = sys.argv[1]
src = open(path).read()
old = '''            if lastFrame != .zero {
                scrollView.contentView.scrollToVisible(lastFrame)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }'''
new = '''            if lastFrame != .zero {
                // Fastra-Patch: Pixelreserve fuer die aktive Auswahlkante.
                // AppKit rundet den Scrollursprung auf Geraetepixel; ohne
                // Reserve kann ein Bruchteil eines Punkts unsichtbar bleiben.
                let scrollTarget = lastFrame.insetBy(dx: 0, dy: -1)
                scrollView.contentView.scrollToVisible(scrollTarget)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }'''
if old not in src:
    raise SystemExit(
        f"{path}: Pixelreserve fuer Scroll-Auswahl hat sich geaendert — Patch 4r pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
