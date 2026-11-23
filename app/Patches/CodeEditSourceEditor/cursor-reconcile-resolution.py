import sys, re

path = sys.argv[1]
src = open(path).read()
old = ('        if let cursorPositions = state.cursorPositions, '
       'cursorPositions != controller.cursorPositions {'
       '  // Fastra-Patch: upstream verglich state.cursorPositions mit sich selbst (immer false) -> externer Sprung wirkte nie')
new = ('        if let cursorPositions = state.cursorPositions,\n'
       '           cursorPositions.compactMap({ controller.resolveCursorPosition($0) }) != controller.cursorPositions {'
       '  // Fastra-Patch: Vergleich ueber resolveCursorPosition -- ein angewandter Sprung (nur Zeile/Spalte, range == .notFound) gilt sonst nie als gleich; der Zweig feuerte dann bei jeder SwiftUI-Neubewertung erneut und zog die aktive Ansicht nach (Dauertest-Wurzel 2026-08-07/09)')
if old not in src:
    raise SystemExit(f"{path}: 4c-Vergleichszeile nicht gefunden — Patch 4c-2 pruefen")
src = src.replace(old, new, 1)
# Doppelten Kommentar aus einer frueheren Migration einmalig deduplizieren.
dup = ('            // Fastra-Patch: Scrollen nur im Key-Window -- ein Hintergrundfenster darf bei SwiftUI-Neubewertungen nie ungefragt scrollen (Dauertest-Befund 2026-08-09)\n'
       '            // Fastra-Patch: Scrollen nur im Key-Window -- ein Hintergrundfenster darf bei SwiftUI-Neubewertungen nie ungefragt scrollen (Dauertest-Befund 2026-08-09)\n')
single = ('            // Fastra-Patch: Scrollen nur im Key-Window -- ein Hintergrundfenster darf bei SwiftUI-Neubewertungen nie ungefragt scrollen (Dauertest-Befund 2026-08-09)\n')
src = src.replace(dup, single)
open(path, "w").write(src)
