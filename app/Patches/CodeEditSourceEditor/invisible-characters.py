#!/usr/bin/env python3
"""Zeichenmarkierungen bei Themen-, Schrift- und Optionswechseln aktualisieren."""
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) / "Sources/CodeEditSourceEditor/SourceEditorConfiguration/SourceEditorConfiguration.swift"
source = path.read_text()
anchor = "        peripherals.didSetOnController(controller: controller, oldConfig: oldConfig?.peripherals)"
replacement = anchor + """
        // Fastra: Der Zeichen-Coordinator erhielt bisher nur die drei Schalter,
        // nicht aber geänderte Farben, Schrift oder Einrückung.
        let coordinator = controller.invisibleCharactersCoordinator
        var redrawInvisibles = false
        if oldConfig?.appearance.theme != appearance.theme {
            coordinator.theme = appearance.theme
            redrawInvisibles = true
        }
        if oldConfig?.appearance.font != appearance.font {
            coordinator.font = appearance.font
            redrawInvisibles = true
        }
        if oldConfig?.behavior.indentOption != behavior.indentOption {
            coordinator.indentOption = behavior.indentOption
            redrawInvisibles = true
        }
        if oldConfig?.peripherals.invisibleCharactersConfiguration != peripherals.invisibleCharactersConfiguration
            || oldConfig?.peripherals.warningCharacters != peripherals.warningCharacters {
            redrawInvisibles = true
        }
        if redrawInvisibles {
            coordinator.needsCacheClear = true
            if let textView = controller.textView {
                func redraw(_ view: NSView) {
                    view.needsDisplay = true
                    view.subviews.forEach(redraw)
                }
                redraw(textView)
            }
        }"""
if replacement not in source:
    if source.count(anchor) != 1:
        raise SystemExit("SourceEditorConfiguration: Zeichen-Patch-Anker fehlt oder ist mehrdeutig")
    updated = source.replace(anchor, replacement)
else:
    updated = source
if updated.count(replacement) != 1:
    raise SystemExit("SourceEditorConfiguration: Zeichen-Patch unvollständig")
if updated != source:
    path.write_text(updated)
    if path.read_text().count(replacement) != 1:
        raise SystemExit("SourceEditorConfiguration: Zeichen-Patch wurde nicht gespeichert")
    print("changed")
else:
    print("unchanged")
