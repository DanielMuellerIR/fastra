import re
import sys

lifecycle_path, layout_path, core_path = sys.argv[1:]
lifecycle = open(lifecycle_path).read()
layout = open(layout_path).read()
core = open(core_path).read()
match = re.search(
    r"override public func viewWillMove\(toWindow newWindow: NSWindow\?\) \{(.*?)\n    \}",
    lifecycle,
    re.S,
)
if (match is None
        or "Fastra-Patch: Fensterwechsel nicht mit provisorischer Geometrie layouten" not in match.group(1)
        or "hasCompletedLayoutInCurrentWindow = false" not in match.group(1)
        or "layoutManager.layoutLines()" in match.group(1)):
    raise SystemExit(
        f"{lifecycle_path}: Fenster-Layout-Patch hat NICHT vollstaendig gegriffen"
    )
viewport = re.search(
    r"public func updatedViewport\(_ newRect: CGRect\) \{(.*?)\n    \}",
    layout,
    re.S,
)
if (viewport is None
        or "Fastra-Patch: erstes Fensterlayout nicht synchron vorwegnehmen" not in viewport.group(1)
        or "if !updateFrameIfNeeded(), hasCompletedLayoutInCurrentWindow" not in viewport.group(1)):
    raise SystemExit(
        f"{layout_path}: Viewport-Layout-Patch hat NICHT vollstaendig gegriffen"
    )
if ("Fastra-Patch: erstes Fensterlayout explizit verfolgen" not in core
        or "var hasCompletedLayoutInCurrentWindow: Bool = false" not in core
        or "Fastra-Patch: regulären Fenster-Layoutlauf merken" not in layout
        or "hasCompletedLayoutInCurrentWindow = window != nil" not in layout):
    raise SystemExit(
        f"{core_path}: Fenster-Layout-Zustand hat NICHT vollstaendig gegriffen"
    )
