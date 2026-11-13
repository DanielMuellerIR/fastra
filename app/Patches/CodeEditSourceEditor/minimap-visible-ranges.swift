    public static let fastraVisibleRangesDidChange = Notification.Name(
        "CodeEditSourceEditor.minimapVisibleRangesDidChange"
    )

    // Logische Megazeilen sind keine sichtbaren Bereiche. Ausschließlich die
    // tatsächlich montierten Miniaturfragmente treiben das Highlighting.
    public var visibleTextRanges: [NSRange] {
        guard !isHiddenOrHasHiddenAncestor, let textView else { return [] }
        let documentEnd = textView.textStorage.length
        let viewport = contentView.visibleRect
        return contentView.subviews.compactMap { view -> NSRange? in
            guard let view = view as? LineFragmentView, !view.isHiddenOrHasHiddenAncestor,
                  let fragment = view.lineFragment, view.frame.intersects(viewport), fragment.documentRange.location != NSNotFound,
                  fragment.documentRange.location >= 0, fragment.documentRange.length > 0,
                  fragment.documentRange.location < documentEnd else { return nil }
            let start = fragment.documentRange.location
            let count = min(fragment.documentRange.length, documentEnd - start)
            // CoreText darf logische Indizes bei Bidi visuell umordnen.
            // Nur verifizierte Festbreitenzellen sind monoton; der allgemeine
            // Pfad behält wie bisher das vollständige Fragment als Farbgrundlage.
            if !fragment.fastraHasFixedCells {
                return NSRange(location: start, length: count)
            }

            // Auch kurz nach einem Umbruchwechsel kann ein altes Fragment
            // noch die gesamte Datei darstellen. Seine Geometrie entscheidet,
            // unabhaengig vom bereits umgeschalteten Einstellungswert.
            // Die gezeichnete Miniaturposition begrenzt seine sichtbaren Zeichen;
            // verifizierte ASCII-Fragmente beantworten diese Abfrage ohne Glyphen.
            let clipped = view.frame.intersection(viewport)
            func boundary(at x: CGFloat) -> Int {
                var lower = 0, upper = count
                while lower < upper {
                    let middle = lower + (upper - lower) / 2
                    if lineRenderer.characterXPosition(in: fragment, for: middle) < x {
                        lower = middle + 1
                    } else { upper = middle }
                }
                return lower
            }
            let lower = max(boundary(at: clipped.minX - view.frame.minX) - 1, 0)
            let upper = min(boundary(at: clipped.maxX - view.frame.minX) + 1, count)
            guard lower < upper else { return nil }
            let visible = NSRange(location: start + lower, length: upper - lower)
            return (textView.textStorage.string as NSString).rangeOfComposedCharacterSequences(for: visible)
        }.sorted { $0.location < $1.location }
    }

    public var visibleTextRange: NSRange? {
        let ranges = visibleTextRanges
        guard let first = ranges.first, let last = ranges.last else { return nil }
        return NSRange(location: first.location, length: last.upperBound - first.location)
    }
