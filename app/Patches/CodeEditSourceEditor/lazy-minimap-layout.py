#!/usr/bin/env python3
"""Begrenzt Minimap-Arbeit auf sichtbare Spalten und lineare Rangemetadaten."""
from pathlib import Path
import sys
base=Path(sys.argv[1])/'Sources/CodeEditSourceEditor/Minimap'
paths={name:base/name for name in ['MinimapLineRenderer.swift','MinimapLineFragmentView.swift','MinimapView.swift']}
sources={name:path.read_text() for name,path in paths.items()}
marker='Fastra-Patch: Minimap-Glyphen und Rangearbeit begrenzen'
# Ein frueherer Aufruf des alten Einrueckungspatches konnte seine
# Skalierung erneut hinter den neuen Block setzen. Nur diese exakt bekannte
# Doppelung wird vor der regulaeren Selbstpruefung entfernt.
renderer = sources['MinimapLineRenderer.swift']
legacy_scale = """            // Die Nutzlast bleibt in Editorpunkten; nur Miniatur-Ursprung und
            // Ausdehnung werden skaliert. So stimmen Tabs und Graphemgrenzen.
            fragmentPosition.data.xOffset *= fastraHorizontalScale
            fragmentPosition.data.width *= fastraHorizontalScale
"""
if marker in renderer and 'fragmentPosition.data.xOffset *= scale' in renderer and legacy_scale in renderer:
 if renderer.count(legacy_scale) != 1: raise SystemExit('Mehrdeutiger alter Minimap-Skalierungsblock')
 sources['MinimapLineRenderer.swift'] = renderer.replace(legacy_scale, '', 1)

def once(name,old,new):
 if sources[name].count(old)!=1: raise SystemExit(f'{paths[name]}: Minimap-Anker fehlt oder ist mehrdeutig')
 sources[name]=sources[name].replace(old,new,1)

if not all(marker in source for source in sources.values()):
 if any(marker in source for source in sources.values()): raise SystemExit('Minimap-Patch nur teilweise vorhanden')
 once('MinimapLineRenderer.swift','    weak var textView: TextView?',
      '    weak var textView: TextView?\n    // '+marker+'.\n    weak var minimapView: MinimapView?')
 once('MinimapLineRenderer.swift', '''        let maxWidth: CGFloat = if let textView, textView.wrapLines {
            textView.layoutManager.maxLineLayoutWidth
        } else {
            .infinity
        }''','''        // Die Cache-Signatur muss exakt der des eigenen Layoutmanagers
        // entsprechen; infinity und greatestFiniteMagnitude sind ungleich.
        let maxWidth = displayData.maxWidth''')
 once('MinimapLineRenderer.swift', '''        // Make all fragments 2px tall
        textLine.lineFragments.forEach { fragmentPosition in
            let remainingHeight = fragmentPosition.height - 3.0
            if remainingHeight != 0 {
                textLine.lineFragments.update(
                    atOffset: fragmentPosition.range.location,
                    delta: 0,
                    deltaHeight: -remainingHeight
                )
            }''', '''        // Ein Skalierungswert und ein Hoehenabgleich im vorhandenen Baum
        // vermeiden neue Knoten fuer dieselben Soft-Wrap-Zeilen.
        let scale = fastraHorizontalScale
        textLine.lineFragments.fastraUpdateHeights { fragment in''')
 once('MinimapLineRenderer.swift', '''            // Die Nutzlast bleibt in Editorpunkten; nur Miniatur-Ursprung und
            // Ausdehnung werden skaliert. So stimmen Tabs und Graphemgrenzen.
            fragmentPosition.data.xOffset *= fastraHorizontalScale
            fragmentPosition.data.width *= fastraHorizontalScale
            fragmentPosition.data.height = 2.0
            fragmentPosition.data.scaledHeight = 3.0
        }''', '''            // Die Nutzlast bleibt in Editorpunkten; nur Miniatur-Ursprung und
            // Ausdehnung werden skaliert. So stimmen Tabs und Graphemgrenzen.
            fragment.xOffset *= scale
            fragment.width *= scale
            fragment.height = 2.0
            fragment.scaledHeight = 3.0
            return 3.0
        }''')
 once('MinimapLineRenderer.swift', '        MinimapLineFragmentView(textView: textView)',
      '        MinimapLineFragmentView(textView: textView, minimapView: minimapView)')
 once('MinimapView.swift', '        setUpLayoutManager(textView: textView)',
      '        // '+marker+'.\n        lineRenderer.minimapView = self\n        setUpLayoutManager(textView: textView)')
 once('MinimapLineFragmentView.swift', '''    private weak var textView: TextView?
    private var drawingRuns: [Run] = []

    init(textView: TextView?) {
        self.textView = textView''', '''    private weak var textView: TextView?
    // Fastra-Patch: Minimap-Glyphen und Rangearbeit begrenzen.
    private weak var minimapView: MinimapView?
    private var drawingRuns: [Run] = []
    private var fastraHorizontalScale: CGFloat = 1

    init(textView: TextView?, minimapView: MinimapView? = nil) {
        self.textView = textView
        self.minimapView = minimapView''')
 old='''        // Create the drawing runs using attribute information
        var position = fragmentRange.location

        for contentRun in newFragment.contents {
            switch contentRun.data {
            case .text:
                addDrawingRunsUntil(
                    max: position + contentRun.length,
                    position: &position,
                    textStorage: textStorage,
                    fragmentRange: fragmentRange
                )
            case .attachment(let attachment):
                position += attachment.range.length
                appendDrawingRun(
                    color: .clear,
                    range: NSRange(location: position, length: contentRun.length),
                    fragmentRange: fragmentRange
                )
            }
        }'''
 new='''        drawingRuns.removeAll(keepingCapacity: true)
        if let textView {
            let space = NSAttributedString(string: " ", attributes: textView.typingAttributes)
            let cell = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(space), nil, nil, nil))
            fastraHorizontalScale = 1.5 / max(cell, 1)
        }
        // Die Minimap hat keinen horizontalen Scroller. Rechts abgeschnittene
        // Zeichen brauchen weder Glyphen noch einen Whitespace-Scan. Beim
        // ersten Aufbau kann der View noch unattached sein; der Editor ist
        // dann eine konservative obere Schranke fuer die Miniaturbreite.
        let viewportWidth = minimapView?.scrollView.contentSize.width ?? 0
        let drawingWidth = viewportWidth > 0 ? viewportWidth : max(textView?.bounds.width ?? 1, 1)
        let editorWidth = max(drawingWidth - 8 - newFragment.xOffset, 0) / fastraHorizontalScale
        var position = fragmentRange.location
        var x: CGFloat = 0
        for contentRun in newFragment.contents {
            guard !newFragment.fastraHasFixedCells || x < editorWidth else { break }
            let runStart = position
            if contentRun.fastraIsText {
                var count = contentRun.length
                if contentRun.fastraHasFixedCells && x + contentRun.width > editorWidth,
                   case .text(let line) = contentRun.data {
                    let lineRange = CTLineGetStringRange(line)
                    let index = CTLineGetStringIndexForPosition(line, CGPoint(x: editorWidth - x, y: 0))
                    count = min(count, max(0, index - lineRange.location + 1))
                }
                addDrawingRunsUntil(
                    max: min(runStart + count, textStorage.length), position: &position,
                    textStorage: textStorage, fragmentRange: fragmentRange
                )
            } else if case .attachment = contentRun.data {
                appendDrawingRun(color: .clear,
                    range: NSRange(location: position, length: contentRun.length),
                    fragmentRange: fragmentRange)
            }
            position = runStart + contentRun.length
            x += contentRun.width
        }'''
 once('MinimapLineFragmentView.swift',old,new)
 once('MinimapLineFragmentView.swift', '''        let space = NSAttributedString(string: " ", attributes: textView.typingAttributes)
        let cell = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(space), nil, nil, nil))
        let scale = 1.5 / max(cell, 1)
        func miniatureX''', '''        let scale = fastraHorizontalScale
        func miniatureX''')
# Bestehende V1-Checkouts auf dieselbe Bidi-Grenze wie frische bringen.
mini = sources['MinimapLineFragmentView.swift']
mini = mini.replace('            guard x < editorWidth else { break }',
                    '            guard !newFragment.fastraHasFixedCells || x < editorWidth else { break }')
mini = mini.replace('                if x + contentRun.width > editorWidth,',
                    '                if contentRun.fastraHasFixedCells && x + contentRun.width > editorWidth,')
sources['MinimapLineFragmentView.swift'] = mini
# V2 behaelt die bereits erzeugten Baumknoten; nur die Hoehenmetadaten
# und die Miniaturgeometrie aendern sich. Auch V1-Checkouts werden migriert.
old_batch = '''        var fragments: [TextLineStorage<LineFragment>.BuildItem] = []
        fragments.reserveCapacity(textLine.lineFragments.count)
        textLine.lineFragments.forEach { fragmentPosition in
            // Die Nutzlast bleibt in Editorpunkten; nur Miniatur-Ursprung und
            // Ausdehnung werden skaliert. So stimmen Tabs und Graphemgrenzen.
            fragmentPosition.data.xOffset *= scale
            fragmentPosition.data.width *= scale
            fragmentPosition.data.height = 2.0
            fragmentPosition.data.scaledHeight = 3.0
            fragments.append(.init(data: fragmentPosition.data,
                                   length: fragmentPosition.range.length, height: 3.0))
        }
        textLine.lineFragments.build(from: fragments, estimatedLineHeight: 3.0)'''
new_batch = '''        textLine.lineFragments.fastraUpdateHeights { fragment in
            // Die Nutzlast bleibt in Editorpunkten; nur Miniatur-Ursprung und
            // Ausdehnung werden skaliert. So stimmen Tabs und Graphemgrenzen.
            fragment.xOffset *= scale
            fragment.width *= scale
            fragment.height = 2.0
            fragment.scaledHeight = 3.0
            return 3.0
        }'''
if new_batch not in sources['MinimapLineRenderer.swift']:
 once('MinimapLineRenderer.swift', old_batch, new_batch)
sources['MinimapLineRenderer.swift'] = sources['MinimapLineRenderer.swift'].replace(
 '''        // Ein Skalierungswert und ein linearer Baumaufbau statt zweier
        // CTLines und einer O(log n)-Hoehenkorrektur je Soft-Wrap-Zeile.''',
 '''        // Ein Skalierungswert und ein Hoehenabgleich im vorhandenen Baum
        // vermeiden neue Knoten fuer dieselben Soft-Wrap-Zeilen.''')
required={
 'MinimapLineRenderer.swift':['let maxWidth = displayData.maxWidth','let scale = fastraHorizontalScale',new_batch,'minimapView: minimapView'],
 'MinimapLineFragmentView.swift':['if contentRun.fastraIsText','guard !newFragment.fastraHasFixedCells || x < editorWidth', 'if contentRun.fastraHasFixedCells && x + contentRun.width > editorWidth','CTLineGetStringIndexForPosition','drawingRuns.removeAll(keepingCapacity: true)','let scale = fastraHorizontalScale'],
 'MinimapView.swift':['lineRenderer.minimapView = self']}
for name,text in sources.items():
 if marker not in text or any(s not in text for s in required[name]): raise SystemExit(f'{paths[name]}: Minimap-Selbstpruefung fehlgeschlagen')
 if name=='MinimapLineRenderer.swift' and ('*= fastraHorizontalScale' in text or 'textLine.lineFragments.update(' in text or 'textLine.lineFragments.build(' in text or '            .infinity' in text): raise SystemExit('Unbegrenzte Minimap-Rangearbeit ist geblieben')
changed=False
for name,text in sources.items():
 if paths[name].read_text()!=text: paths[name].write_text(text);changed=True
print('changed' if changed else 'unchanged')
