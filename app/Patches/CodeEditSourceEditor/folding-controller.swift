import AppKit
import CodeEditTextView

extension TextViewController {
    public func setFastraFoldProvider(_ provider: LineFoldProvider?) {
        guard let provider, foldProvider !== provider else { return }
        guard gutterView != nil, textView != nil else {
            foldProvider = provider
            invalidateFastraFolds()
            return
        }
        unfoldAllFastraFolds()
        if let old = gutterView.foldingRibbon.model { textView.removeStorageDelegate(old) }
        invalidateFastraFolds()
        foldProvider = provider
        gutterView.foldingRibbon.model = LineFoldModel(controller: self, foldView: gutterView.foldingRibbon)
    }

    public var fastraFoldRegions: [SourceFoldRegion] {
        guard let gutterView, let textView else { return [] }
        return (gutterView.foldingRibbon.model?.getFolds(in: 0..<textView.textStorage.length) ?? []).map {
            SourceFoldRegion(range: NSRange($0.range), depth: $0.depth, isCollapsed: $0.isCollapsed)
        }
    }

    public func setFastraFold(range: NSRange, collapsed: Bool, includeChildren: Bool = false) {
        guard let gutterView, let textView else { return }
        guard let model = gutterView.foldingRibbon.model else { return }
        let folds = model.getFolds(in: range.intRange).filter {
            NSRange($0.range) == range || (includeChildren && range.intRange.contains($0.range))
        }
        // Kinder zuerst, damit ein nachfolgender Eltern-Platzhalter sie nur verdeckt.
        for fold in folds.sorted(by: { $0.depth > $1.depth }) where fold.isCollapsed != collapsed {
            if collapsed {
                textView.layoutManager.attachments.add(
                    LineFoldPlaceholder(delegate: model, fold: fold, charWidth: font.charWidth),
                    for: NSRange(fold.range))
            } else {
                textView.layoutManager.attachments.remove(atOffset: fold.range.lowerBound)
            }
            model.foldCache.toggleCollapse(forFold: fold)
        }
        textView.needsLayout = true
        gutterView.needsDisplay = true
        gutterView.foldingRibbon.needsDisplay = true
    }

    public func unfoldFastraFolds(containing target: NSRange) {
        guard let gutterView, let textView else { return }
        let attachments = textView.layoutManager.attachments.getAttachmentsOverlapping(textView.documentRange)
        for box in attachments where box.attachment is LineFoldPlaceholder {
            // Eine Auswahl des ganzen Dokuments (Copy/Save) ist kein Sprung in
            // versteckten Text. Nur die Auswahlgrenzen muessen sichtbar werden.
            let hidden = box.range.location..<box.range.upperBound
            if hidden.contains(target.location) || (target.length > 0 && hidden.contains(target.upperBound - 1)) {
                textView.layoutManager.attachments.remove(atOffset: box.range.location)
            }
        }
        reconcileFastraCollapseState()
        gutterView.foldingRibbon.model?.refreshFastraFolds()
        textView.needsLayout = true
        gutterView.foldingRibbon.needsDisplay = true
    }

    public func unfoldAllFastraFolds() {
        guard let gutterView, let textView else { return }
        for box in textView.layoutManager.attachments.getAttachmentsOverlapping(textView.documentRange)
            where box.attachment is LineFoldPlaceholder {
            textView.layoutManager.attachments.remove(atOffset: box.range.location)
        }
        reconcileFastraCollapseState()
        gutterView.foldingRibbon.model?.refreshFastraFolds()
        textView.needsLayout = true
        gutterView.foldingRibbon.needsDisplay = true
    }

    func reconcileFastraCollapseState() {
        guard let gutterView, let textView else { return }
        let collapsed = textView.layoutManager.attachments.getAttachmentsOverlapping(textView.documentRange)
            .compactMap { box -> LineFoldStorage.DepthStartPair? in
                guard let placeholder = box.attachment as? LineFoldPlaceholder else { return nil }
                return .init(depth: placeholder.fold.depth, start: box.range.location)
            }
        gutterView.foldingRibbon.model?.foldCache.reconcileCollapsed(Set(collapsed))
    }
}
