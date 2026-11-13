#!/usr/bin/env python3
"""Miniatur-Highlighting folgt sichtbaren Fragmenten statt vollständigen Megazeilen."""
from pathlib import Path
import sys

root = Path(sys.argv[1]) / 'Sources/CodeEditSourceEditor'
previous_inline_post = '        layoutManager?.layoutLines()\n        // Neue Fragment-Views existieren erst nach dem Layout. Ohne diese\n        // Rückmeldung blieben ihre bereits sichtbaren Zeichen ungefärbt.\n        if let minimap = superview?.superview?.superview as? MinimapView {\n            NotificationCenter.default.post(name: MinimapView.fastraVisibleRangesDidChange, object: minimap)\n        }\n    }'
replacements = [
    ('Minimap/MinimapView+TextSelectionManagerDelegate.swift', '''    public var visibleTextRange: NSRange? {
        let minY = max(visibleRect.minY, 0)
        let maxY = min(visibleRect.maxY, layoutManager?.estimatedHeight() ?? 3.0)
        guard let minYLine = layoutManager?.textLineForPosition(minY),
              let maxYLine = layoutManager?.textLineForPosition(maxY) else {
            return nil
        }
        return NSRange(start: minYLine.range.location, end: maxYLine.range.max)
    }''', Path(__file__).with_suffix('.swift').read_text().rstrip()),
    ('Highlighting/VisibleRangeProvider.swift', '''        if !(minimapView?.isHidden ?? true), let minimapVisibleRange = minimapView?.visibleTextRange {
            ranges.append(minimapVisibleRange)
        }''', '''        if let minimapView, !minimapView.isHiddenOrHasHiddenAncestor {
            ranges.append(contentsOf: minimapView.visibleTextRanges)
        }'''),
    ('Highlighting/VisibleRangeProvider.swift', '''        self.minimapView = minimapView

        installScrollObserversIfNeeded()''', '''        self.minimapView = minimapView
        if let minimapView {
            NotificationCenter.default.addObserver(
                self, selector: #selector(visibleTextChanged),
                name: MinimapView.fastraVisibleRangesDidChange, object: minimapView
            )
        }

        installScrollObserversIfNeeded()'''),
    ('Minimap/MinimapContentView.swift', '''    weak var selectionManager: TextSelectionManager?''', '''    weak var selectionManager: TextSelectionManager?
    private var fastraVisibleRangesNotificationPending = false'''),
    ('Minimap/MinimapContentView.swift', '''        layoutManager?.layoutLines()
    }''', '''        layoutManager?.layoutLines()
        scheduleFastraVisibleRangesDidChange()
    }

    private func scheduleFastraVisibleRangesDidChange() {
        guard !fastraVisibleRangesNotificationPending else { return }
        fastraVisibleRangesNotificationPending = true
        // Farbantworten können synchron Attribute ändern und den aktuellen
        // Layoutstand verwerfen. Erst nach layout() darf diese Rückmeldung
        // erneut Layout anfordern; mehrere Anforderungen teilen einen UI-Turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fastraVisibleRangesNotificationPending = false
            guard !self.isHiddenOrHasHiddenAncestor,
                  let minimap = self.superview?.superview?.superview as? MinimapView else { return }
            NotificationCenter.default.post(name: MinimapView.fastraVisibleRangesDidChange, object: minimap)
        }
    }''')
]
changed = False
for relative, old, new in replacements:
    path = root / relative
    source = path.read_text()
    if new not in source:
        if relative == 'Minimap/MinimapView+TextSelectionManagerDelegate.swift' and source.count(old) == 0:
            # Nur bekannte Vorfassungen ersetzen; unbekannte lokale
            # Änderungen innerhalb des Blocks bleiben ein harter Fehler.
            start = '    public static let fastraVisibleRangesDidChange = Notification.Name('
            end = '    public func setNeedsDisplay() {'
            if source.count(start) != 1 or source.count(end) != 1:
                raise SystemExit('Minimap-Sichtbereiche: V1-Migrationsgrenzen fehlen oder sind mehrdeutig')
            lower, upper = source.index(start), source.index(end)
            candidate = source[lower:upper].rstrip()
            guarded = """            // CoreText darf logische Indizes bei Bidi visuell umordnen.
            // Nur verifizierte Festbreitenzellen sind monoton; der allgemeine
            // Pfad behält wie bisher das vollständige Fragment als Farbgrundlage.
            if textView.wrapLines || !fragment.fastraHasFixedCells {
                return NSRange(location: start, length: count)
            }"""
            original = """            if textView.wrapLines { return NSRange(location: start, length: count) }"""
            prior_guard = """            guard let view = view as? LineFragmentView, let fragment = view.lineFragment,
                  view.frame.intersects(viewport),"""
            hidden_guard = """            guard let view = view as? LineFragmentView, !view.isHiddenOrHasHiddenAncestor,
                  let fragment = view.lineFragment, view.frame.intersects(viewport),"""
            previous = new.replace(
                '            if !fragment.fastraHasFixedCells {',
                '            if textView.wrapLines || !fragment.fastraHasFixedCells {'
            ).replace(
                '''            // Auch kurz nach einem Umbruchwechsel kann ein altes Fragment
            // noch die gesamte Datei darstellen. Seine Geometrie entscheidet,
            // unabhaengig vom bereits umgeschalteten Einstellungswert.''',
                '            // Ohne Umbruch kann ein Fragment die gesamte Datei darstellen.'
            )
            v2 = previous.replace(hidden_guard, prior_guard)
            v1 = v2.replace(guarded, original)
            v1_uncached = v1.replace(
                """        let ranges = visibleTextRanges
        guard let first = ranges.first, let last = ranges.last else { return nil }""",
                """        guard let first = visibleTextRanges.first, let last = visibleTextRanges.last else { return nil }"""
            )
            if candidate not in (previous, v2, v1, v1_uncached):
                raise SystemExit('Minimap-Sichtbereiche: unbekannte V1-Fassung; keine fremden Änderungen überschrieben')
            old = candidate
        if relative == 'Minimap/MinimapContentView.swift' and 'scheduleFastraVisibleRangesDidChange()' in new:
            if source.count(old) == 0 and source.count(previous_inline_post) == 1:
                old = previous_inline_post
        if source.count(old) != 1:
            raise SystemExit(f'Minimap-Sichtbereiche: Anker fehlt oder ist mehrdeutig: {relative}')
        path.chmod(path.stat().st_mode | 0o200)
        path.write_text(source.replace(old, new, 1))
        changed = True
    if path.read_text().count(new) != 1:
        raise SystemExit(f'Minimap-Sichtbereiche: Selbstprüfung fehlgeschlagen: {relative}')
print('changed' if changed else 'unchanged')
