import sys

lifecycle_path, layout_path, core_path = sys.argv[1:]
lifecycle = open(lifecycle_path).read()
layout = open(layout_path).read()
core = open(core_path).read()
lifecycle_marker = (
    "Fastra-Patch: Fensterwechsel nicht mit provisorischer Geometrie layouten"
)
old_lifecycle = '''    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        layoutManager.layoutLines()
    }'''
new_lifecycle = '''    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        hasCompletedLayoutInCurrentWindow = false
        // Fastra-Patch: Fensterwechsel nicht mit provisorischer Geometrie layouten.
        // AppKit ruft `layout()` nach dem Einhängen mit der endgültigen
        // Viewportbreite auf. Der synchrone Upstream-Aufruf hier würde eine
        // Megazeile vorher vollständig und unmittelbar danach erneut umbrechen.
    }'''
if lifecycle_marker not in lifecycle:
    if old_lifecycle not in lifecycle:
        raise SystemExit(
            f"{lifecycle_path}: Fenster-Lebenszyklus hat sich geaendert — "
            "Patch 4z9 pruefen"
        )
    lifecycle = lifecycle.replace(old_lifecycle, new_lifecycle, 1)
elif "hasCompletedLayoutInCurrentWindow = false" not in lifecycle:
    old_super = '''        super.viewWillMove(toWindow: newWindow)
        // Fastra-Patch: Fensterwechsel nicht mit provisorischer Geometrie layouten.'''
    new_super = '''        super.viewWillMove(toWindow: newWindow)
        hasCompletedLayoutInCurrentWindow = false
        // Fastra-Patch: Fensterwechsel nicht mit provisorischer Geometrie layouten.'''
    if old_super not in lifecycle:
        raise SystemExit(
            f"{lifecycle_path}: bestehender Fenster-Patch hat sich geaendert"
        )
    lifecycle = lifecycle.replace(old_super, new_super, 1)

core_marker = "Fastra-Patch: erstes Fensterlayout explizit verfolgen"
old_core = '''    var isFirstResponder: Bool = false'''
new_core = '''    // Fastra-Patch: erstes Fensterlayout explizit verfolgen.
    // AppKits `needsLayout` ist während früher Viewport-Benachrichtigungen
    // bereits wieder false und kann den Startzustand deshalb nicht abbilden.
    var hasCompletedLayoutInCurrentWindow: Bool = false
    var isFirstResponder: Bool = false'''
if core_marker not in core:
    if old_core not in core:
        raise SystemExit(
            f"{core_path}: private TextView-Eigenschaften haben sich geaendert — "
            "Patch 4z9 pruefen"
        )
    core = core.replace(old_core, new_core, 1)

layout_marker = "Fastra-Patch: regulären Fenster-Layoutlauf merken"
old_layout = '''        super.layout()
        layoutManager.layoutLines()
        selectionManager.updateSelectionViews(skipTimerReset: true)'''
new_layout = '''        super.layout()
        layoutManager.layoutLines()
        // Fastra-Patch: regulären Fenster-Layoutlauf merken.
        hasCompletedLayoutInCurrentWindow = window != nil
        selectionManager.updateSelectionViews(skipTimerReset: true)'''
if layout_marker not in layout:
    if old_layout not in layout:
        raise SystemExit(
            f"{layout_path}: regulärer Layoutlauf hat sich geaendert — "
            "Patch 4z9 pruefen"
        )
    layout = layout.replace(old_layout, new_layout, 1)

viewport_marker = "Fastra-Patch: erstes Fensterlayout nicht synchron vorwegnehmen"
old_viewport = '''    public func updatedViewport(_ newRect: CGRect) {
        if !updateFrameIfNeeded() {
            layoutManager.layoutLines()
        }
        inputContext?.invalidateCharacterCoordinates()
    }'''
previous_viewport = '''    public func updatedViewport(_ newRect: CGRect) {
        if !updateFrameIfNeeded(), !needsLayout {
            // Fastra-Patch: bereits geplantes AppKit-Layout nicht synchron vorwegnehmen.
            // Beim Einhängen ist `needsLayout` schon gesetzt; `layout()` folgt
            // im selben Anzeigezyklus mit der endgültigen Viewportbreite.
            // Normales Scrollen ohne ausstehenden Lauf bleibt unmittelbar.
            layoutManager.layoutLines()
        }
        inputContext?.invalidateCharacterCoordinates()
    }'''
new_viewport = '''    public func updatedViewport(_ newRect: CGRect) {
        if !updateFrameIfNeeded(), hasCompletedLayoutInCurrentWindow {
            // Fastra-Patch: erstes Fensterlayout nicht synchron vorwegnehmen.
            // AppKit ruft `layout()` nach dem Einhängen mit der endgültigen
            // Viewportbreite auf. Danach bleibt normales Scrollen unmittelbar.
            layoutManager.layoutLines()
        }
        inputContext?.invalidateCharacterCoordinates()
    }'''
if viewport_marker not in layout:
    if previous_viewport in layout:
        layout = layout.replace(previous_viewport, new_viewport, 1)
    elif old_viewport in layout:
        layout = layout.replace(old_viewport, new_viewport, 1)
    else:
        raise SystemExit(
            f"{layout_path}: Viewport-Aktualisierung hat sich geaendert — "
            "Patch 4z9 pruefen"
        )

open(lifecycle_path, "w").write(lifecycle)
open(layout_path, "w").write(layout)
open(core_path, "w").write(core)
