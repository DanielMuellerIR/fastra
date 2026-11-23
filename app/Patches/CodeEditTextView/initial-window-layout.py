import sys

lifecycle_path, layout_path, core_path = sys.argv[1:]
lifecycle = open(lifecycle_path).read()
layout = open(layout_path).read()
core = open(core_path).read()

old_core = '''    var hasCompletedLayoutInCurrentWindow: Bool = false
    var isFirstResponder: Bool = false'''
new_core = '''    var hasCompletedLayoutInCurrentWindow: Bool = false
    var hasScheduledInitialLayoutInCurrentWindow: Bool = false
    var initialLayoutWindowGeneration: Int = 0
    var isFirstResponder: Bool = false'''
if "var hasScheduledInitialLayoutInCurrentWindow" not in core:
    if old_core not in core:
        raise SystemExit(
            f"{core_path}: Fenster-Layoutzustand hat sich geaendert — "
            "Patch 4z10 pruefen"
        )
    core = core.replace(old_core, new_core, 1)

old_lifecycle = '''        hasCompletedLayoutInCurrentWindow = false
        // Fastra-Patch: Fensterwechsel nicht mit provisorischer Geometrie layouten.'''
new_lifecycle = '''        hasCompletedLayoutInCurrentWindow = false
        hasScheduledInitialLayoutInCurrentWindow = false
        initialLayoutWindowGeneration &+= 1
        // Fastra-Patch: Fensterwechsel nicht mit provisorischer Geometrie layouten.'''
if "initialLayoutWindowGeneration &+= 1" not in lifecycle:
    if old_lifecycle not in lifecycle:
        raise SystemExit(
            f"{lifecycle_path}: Fensterwechsel-Zustand hat sich geaendert — "
            "Patch 4z10 pruefen"
        )
    lifecycle = lifecycle.replace(old_lifecycle, new_lifecycle, 1)

old_layout = '''    override public func layout() {
        super.layout()
        layoutManager.layoutLines()
        // Fastra-Patch: regulären Fenster-Layoutlauf merken.
        hasCompletedLayoutInCurrentWindow = window != nil
        selectionManager.updateSelectionViews(skipTimerReset: true)
    }'''
new_layout = '''    override public func layout() {
        super.layout()

        if window != nil, !hasCompletedLayoutInCurrentWindow {
            if !hasScheduledInitialLayoutInCurrentWindow {
                hasScheduledInitialLayoutInCurrentWindow = true
                let generation = initialLayoutWindowGeneration
                // Fastra-Patch: initiales Fensterlayout kurz bündeln.
                // SwiftUI setzt Text, Attribute und Insets in mehreren dicht
                // aufeinanderfolgenden Aktualisierungen. Erst danach einmal
                // umbrechen, statt dieselbe Megazeile mehrfach zu berechnen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self,
                          self.window != nil,
                          self.initialLayoutWindowGeneration == generation,
                          !self.hasCompletedLayoutInCurrentWindow else { return }
                    self.layoutManager.layoutLines()
                    self.hasCompletedLayoutInCurrentWindow = true
                    self.hasScheduledInitialLayoutInCurrentWindow = false
                    self.selectionManager.updateSelectionViews(skipTimerReset: true)
                    self.needsDisplay = true
                }
            }
            return
        }

        layoutManager.layoutLines()
        // Fastra-Patch: regulären Fenster-Layoutlauf merken.
        hasCompletedLayoutInCurrentWindow = window != nil
        selectionManager.updateSelectionViews(skipTimerReset: true)
    }'''
if "Fastra-Patch: initiales Fensterlayout kurz bündeln" not in layout:
    if old_layout not in layout:
        raise SystemExit(
            f"{layout_path}: Startlayout hat sich geaendert — Patch 4z10 pruefen"
        )
    layout = layout.replace(old_layout, new_layout, 1)

open(lifecycle_path, "w").write(lifecycle)
open(layout_path, "w").write(layout)
open(core_path, "w").write(core)
