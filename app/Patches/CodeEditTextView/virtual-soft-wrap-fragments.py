import sys

layout_path, view_path, provider_path = sys.argv[1:]
layout = open(layout_path).read()
view = open(view_path).read()
provider = open(provider_path).read()

def replace_once(source, old, new, path, label):
    if old not in source:
        raise SystemExit(
            f"{path}: {label} hat sich geaendert — Patch 4z5 pruefen"
        )
    return source.replace(old, new, 1)

if "Fastra-Patch: Das Fragmentmodell bleibt vollständig" not in layout:
    old_decision = '''            if forceLayout || linePositionNeedsLayout || wasNotVisible || lineNotEntirelyLaidOut {
                fullLineLayout()
            } else {
                if didLayoutChange || yContentAdjustment > 0 {
                    // Layout happened and this line needs to be moved but not necessarily re-added
                    let needsFullLayout = updateLineViewPositions(linePosition)
                    if needsFullLayout {
                        fullLineLayout()
                        continue
                    }
                }

                // Make sure the used fragment views aren't dequeued.
                usedFragmentIDs.formUnion(linePosition.data.lineFragments.map(\\.data.id))
            }'''
    new_decision = '''            let visibleFragmentsMissing = lineHasMissingFragmentView(
                linePosition,
                yRange: minY..<maxY
            )

            if forceLayout || linePositionNeedsLayout || wasNotVisible
                || lineNotEntirelyLaidOut || visibleFragmentsMissing {
                fullLineLayout()
            } else {
                if didLayoutChange || yContentAdjustment > 0 {
                    // Layout happened and this line needs to be moved but not necessarily re-added
                    let needsFullLayout = updateLineViewPositions(
                        linePosition,
                        yRange: minY..<maxY
                    )
                    if needsFullLayout {
                        fullLineLayout()
                        continue
                    }
                }

                // Fastra-Patch: Nur Fragment-Views im aktuellen Viewport
                // behalten. Eine einzelne umgebrochene Megazeile kann
                // zehntausende Fragmente besitzen, sichtbar sind aber nur
                // wenige davon.
                markVisibleFragmentViewsUsed(
                    linePosition,
                    yRange: minY..<maxY,
                    usedFragmentIDs: &usedFragmentIDs
                )
            }'''
    layout = replace_once(
        layout, old_decision, new_decision, layout_path,
        "Viewport-Entscheidung"
    )

    old_prepare = '''        let line = position.data
        if let renderDelegate {
            renderDelegate.prepareForDisplay(
                textLine: line,
                displayData: lineDisplayData,
                range: position.range,
                stringRef: textStorage,
                markedRanges: markedTextManager.markedRanges(in: position.range),
                attachments: attachments.getAttachmentsStartingIn(position.range)
            )
        } else {
            line.prepareForDisplay(
                displayData: lineDisplayData,
                range: position.range,
                stringRef: textStorage,
                markedRanges: markedTextManager.markedRanges(in: position.range),
                attachments: attachments.getAttachmentsStartingIn(position.range)
            )
        }'''
    new_prepare = '''        let line = position.data
        if line.needsLayout(maxWidth: layoutData.maxWidth) {
            if let renderDelegate {
                renderDelegate.prepareForDisplay(
                    textLine: line,
                    displayData: lineDisplayData,
                    range: position.range,
                    stringRef: textStorage,
                    markedRanges: markedTextManager.markedRanges(in: position.range),
                    attachments: attachments.getAttachmentsStartingIn(position.range)
                )
            } else {
                line.prepareForDisplay(
                    displayData: lineDisplayData,
                    range: position.range,
                    stringRef: textStorage,
                    markedRanges: markedTextManager.markedRanges(in: position.range),
                    attachments: attachments.getAttachmentsStartingIn(position.range)
                )
            }
        }'''
    layout = replace_once(
        layout, old_prepare, new_prepare, layout_path,
        "Typeset-Wiederverwendung"
    )

    old_fragment_loop = '''        var height: CGFloat = 0
        var width: CGFloat = 0
        let relativeMinY = max(layoutData.minY - position.yPos, 0)
        let relativeMaxY = max(layoutData.maxY - position.yPos, relativeMinY)

//        for lineFragmentPosition in line.lineFragments.linesStartingAt(
//            relativeMinY,
//            until: relativeMaxY
//        ) {
        for lineFragmentPosition in line.lineFragments {
            let lineFragment = lineFragmentPosition.data
            lineFragment.documentRange = lineFragmentPosition.range.translate(location: position.range.location)

            layoutFragmentView(
                inLine: position,
                for: lineFragmentPosition,
                at: position.yPos + lineFragmentPosition.yPos
            )

            width = max(width, lineFragment.width)
            height += lineFragment.scaledHeight
            laidOutFragmentIDs.insert(lineFragment.id)
        }

        return CGSize(width: width, height: height)'''
    new_fragment_loop = '''        var width: CGFloat = 0
        let relativeMinY = max(layoutData.minY - position.yPos, 0)
        let relativeMaxY = max(layoutData.maxY - position.yPos, relativeMinY)

        // Fastra-Patch: Das Fragmentmodell bleibt vollständig, damit Scrollen,
        // Treffergeometrie und Cursorpositionen exakt bleiben. AppKit-Views
        // entstehen dagegen nur für den sichtbaren Bereich samt Layoutpuffer.
        for lineFragmentPosition in line.lineFragments.linesStartingAt(
            relativeMinY,
            until: relativeMaxY
        ) {
            let lineFragment = lineFragmentPosition.data
            lineFragment.documentRange = lineFragmentPosition.range.translate(location: position.range.location)

            layoutFragmentView(
                inLine: position,
                for: lineFragmentPosition,
                at: position.yPos + lineFragmentPosition.yPos
            )

            width = max(width, lineFragment.width)
            laidOutFragmentIDs.insert(lineFragment.id)
        }

        return CGSize(width: width, height: line.lineFragments.height)'''
    layout = replace_once(
        layout, old_fragment_loop, new_fragment_loop, layout_path,
        "Fragment-View-Schleife"
    )

    old_update = '''    private func updateLineViewPositions(_ position: TextLineStorage<TextLine>.TextLinePosition) -> Bool {
        let line = position.data
        for lineFragmentPosition in line.lineFragments {
            guard let view = viewReuseQueue.getView(forKey: lineFragmentPosition.data.id) else {
                return true
            }
            lineFragmentPosition.data.documentRange = lineFragmentPosition.range.translate(
                location: position.range.location
            )
            view.frame.origin = CGPoint(x: edgeInsets.left, y: position.yPos + lineFragmentPosition.yPos)
        }
        return false
    }'''
    new_update = '''    private func lineHasMissingFragmentView(
        _ position: TextLineStorage<TextLine>.TextLinePosition,
        yRange: Range<CGFloat>
    ) -> Bool {
        let relativeMinY = max(yRange.lowerBound - position.yPos, 0)
        let relativeMaxY = max(yRange.upperBound - position.yPos, relativeMinY)
        for fragment in position.data.lineFragments.linesStartingAt(
            relativeMinY,
            until: relativeMaxY
        ) where viewReuseQueue.getView(forKey: fragment.data.id) == nil {
            return true
        }
        return false
    }

    private func markVisibleFragmentViewsUsed(
        _ position: TextLineStorage<TextLine>.TextLinePosition,
        yRange: Range<CGFloat>,
        usedFragmentIDs: inout Set<LineFragment.ID>
    ) {
        let relativeMinY = max(yRange.lowerBound - position.yPos, 0)
        let relativeMaxY = max(yRange.upperBound - position.yPos, relativeMinY)
        for fragment in position.data.lineFragments.linesStartingAt(
            relativeMinY,
            until: relativeMaxY
        ) {
            usedFragmentIDs.insert(fragment.data.id)
        }
    }

    private func updateLineViewPositions(
        _ position: TextLineStorage<TextLine>.TextLinePosition,
        yRange: Range<CGFloat>
    ) -> Bool {
        let line = position.data
        let relativeMinY = max(yRange.lowerBound - position.yPos, 0)
        let relativeMaxY = max(yRange.upperBound - position.yPos, relativeMinY)
        for lineFragmentPosition in line.lineFragments.linesStartingAt(
            relativeMinY,
            until: relativeMaxY
        ) {
            guard let view = viewReuseQueue.getView(forKey: lineFragmentPosition.data.id) else {
                return true
            }
            lineFragmentPosition.data.documentRange = lineFragmentPosition.range.translate(
                location: position.range.location
            )
            view.frame.origin = CGPoint(x: edgeInsets.left, y: position.yPos + lineFragmentPosition.yPos)
        }
        return false
    }'''
    layout = replace_once(
        layout, old_update, new_update, layout_path,
        "Fragment-View-Aktualisierung"
    )

if "Fastra-Patch: Geometrieabfragen koennen" not in view:
    view = replace_once(
        view,
        "        return layoutManager.visibleLines().map { line in",
        "        return layoutManager.visibleLines().compactMap { line in",
        view_path,
        "sichtbare Zeilen"
    )
    old_range = '''                let start = min(first, last)
                let end = max(first, last)
                return NSRange(
                    start: start,
                    end: min(end + 1, documentRange.max)
                )'''
    new_range = '''                // Fastra-Patch: Geometrieabfragen koennen waehrend einer
                // synchronen Frame-/Inset-Aktualisierung kurz einen Offset
                // aus dem vorherigen Layout liefern. Vor jeder NSRange- und
                // spaeteren IndexSet-Bildung deshalb auf das echte Dokument
                // klemmen und nie `NSNotFound + 1` berechnen.
                let documentEnd = textStorage.length
                let start = min(max(min(first, last), 0), documentEnd)
                let end = min(max(max(first, last), start), documentEnd)
                let exclusiveEnd = end < documentEnd ? end + 1 : end
                return NSRange(
                    start: start,
                    end: exclusiveEnd
                )'''
    view = replace_once(
        view, old_range, new_range, view_path,
        "Viewport-Range-Klemmung"
    )
    old_fallback = '''            return NSRange(
                location: line.range.location,
                length: min(line.range.length, 16 * 1024)
            )'''
    new_fallback = '''            let location = min(max(line.range.location, 0), textStorage.length)
            let available = textStorage.length - location
            return NSRange(location: location,
                           length: min(max(line.range.length, 0),
                                       min(available, 16 * 1024)))'''
    view = replace_once(
        view, old_fallback, new_fallback, view_path,
        "Viewport-Fallback-Klemmung"
    )

if "Fastra-Patch: Nur echte Dokumentindizes" not in provider:
    old_lazy = '''        var result = IndexSet()
        for range in textView?.visibleTextRanges ?? [] {
            result.insert(integersIn: range.location..<range.max)
        }
        return result'''
    new_lazy = '''        Self.makeVisibleSet(
            from: textView?.visibleTextRanges ?? [],
            documentRange: documentRange
        )'''
    provider = replace_once(
        provider, old_lazy, new_lazy, provider_path,
        "VisibleSet-Initialisierung"
    )
    old_update = '''        guard let textView else { return }
        var visibleSet = IndexSet()
        for range in textView.visibleTextRanges {
            visibleSet.insert(integersIn: range.location..<range.max)
        }
        if !(minimapView?.isHidden ?? true), let minimapVisibleRange = minimapView?.visibleTextRange {
            visibleSet.formUnion(IndexSet(integersIn: minimapVisibleRange))
        }
        self.visibleSet = visibleSet
        delegate?.visibleSetDidUpdate(visibleSet)
    }

    deinit {'''
    new_update = '''        guard let textView else { return }
        var ranges = textView.visibleTextRanges
        if !(minimapView?.isHidden ?? true), let minimapVisibleRange = minimapView?.visibleTextRange {
            ranges.append(minimapVisibleRange)
        }
        let visibleSet = Self.makeVisibleSet(
            from: ranges,
            documentRange: textView.documentRange
        )
        self.visibleSet = visibleSet
        delegate?.visibleSetDidUpdate(visibleSet)
    }

    /// Fastra-Patch: Nur echte Dokumentindizes an `IndexSet` weitergeben.
    /// AppKit kann Frame- und Bounds-Benachrichtigungen mitten in einer
    /// Layoutaenderung senden; dann gehoert eine gemeldete Range mitunter noch
    /// zur vorherigen Framegroesse. `IndexSet` trappt bei solchen Bereichen,
    /// statt sie selbst zu klemmen.
    private static func makeVisibleSet(
        from ranges: [NSRange],
        documentRange: NSRange
    ) -> IndexSet {
        guard documentRange.location != NSNotFound,
              documentRange.location >= 0,
              documentRange.length >= 0 else { return IndexSet() }
        let (documentEnd, documentOverflow) = documentRange.location
            .addingReportingOverflow(documentRange.length)
        guard !documentOverflow else { return IndexSet() }

        var result = IndexSet()
        for range in ranges where range.location != NSNotFound
            && range.location >= 0 && range.length >= 0 {
            let (rangeEnd, rangeOverflow) = range.location
                .addingReportingOverflow(range.length)
            guard !rangeOverflow else { continue }
            let lower = max(range.location, documentRange.location)
            let upper = min(rangeEnd, documentEnd)
            if lower < upper {
                result.insert(integersIn: lower..<upper)
            }
        }
        return result
    }

    deinit {'''
    provider = replace_once(
        provider, old_update, new_update, provider_path,
        "VisibleSet-Aktualisierung"
    )

open(layout_path, "w").write(layout)
open(view_path, "w").write(view)
open(provider_path, "w").write(provider)
