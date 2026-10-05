#!/usr/bin/env python3
"""Revisionssicheres Syntax-Folding und native Offenlegungsdreiecke."""
import pathlib
import sys

root = pathlib.Path(sys.argv[1]) / 'Sources/CodeEditSourceEditor'
text_root = pathlib.Path(sys.argv[2]) / 'Sources/CodeEditTextView'
templates = pathlib.Path(__file__).parent
pending = {}

def read(path):
    return pending.get(path, path.read_text())

def replace(path, old, new, count=1):
    source = read(path)
    if new not in source:
        if source.count(old) != count:
            raise SystemExit(f'{path.name}: Folding-Anker fehlt oder ist mehrdeutig')
        source = source.replace(old, new)
    if source.count(new) != count:
        raise SystemExit(f'{path.name}: Folding-Patch unvollständig')
    pending[path] = source

def template(relative, name, original_anchor):
    path = root / relative
    new = (templates / name).read_text()
    source = read(path)
    if source != new and original_anchor not in source and '// Fastra:' not in source:
        raise SystemExit(f'{path.name}: Folding-Quelle passt nicht zum gepinnten Stand')
    pending[path] = new

template('LineFolding/Model/LineFoldCalculator.swift', 'folding-calculator.swift', 'actor LineFoldCalculator')
template('LineFolding/Model/LineFoldStorage.swift', 'folding-storage.swift', 'private var foldRanges:')
template('LineFolding/View/LineFoldRibbonView+Draw.swift', 'folding-draw.swift', 'extension LineFoldRibbonView {')

provider = root / 'LineFolding/LineFoldProviders/LineFoldProvider.swift'
replace(provider, '@MainActor\npublic protocol LineFoldProvider:', '''// Fastra: reine UTF-16-Bereiche aus einem unveraenderlichen Dokument.
public struct SourceFoldRegion: Sendable, Equatable {
    public let range: NSRange
    public let depth: Int
    public var isCollapsed: Bool
    public init(range: NSRange, depth: Int, isCollapsed: Bool = false) {
        self.range = range; self.depth = depth; self.isCollapsed = isCollapsed
    }
}

@MainActor
public protocol SnapshotLineFoldProvider: LineFoldProvider {
    func foldRegions(in text: String) async -> [SourceFoldRegion]
}

@MainActor
public protocol LineFoldProvider:''')

editor = root / 'SourceEditor/SourceEditor.swift'
replace(editor, '        highlightProviders: [any HighlightProviding]? = nil,',
        '        highlightProviders: [any HighlightProviding]? = nil,\n        foldProvider: LineFoldProvider? = nil,', 2)
replace(editor, '        self.highlightProviders = highlightProviders',
        '        self.highlightProviders = highlightProviders\n        self.foldProvider = foldProvider', 2)
replace(editor, '    var undoManager: CEUndoManager?',
        '    var foldProvider: LineFoldProvider?\n    var undoManager: CEUndoManager?')
replace(editor, '            highlightProviders: context.coordinator.highlightProviders,',
        '            highlightProviders: context.coordinator.highlightProviders,\n            foldProvider: foldProvider,')
replace(editor, '        context.coordinator.updateHighlightProviders(highlightProviders)',
        '        controller.setFastraFoldProvider(foldProvider)\n        context.coordinator.updateHighlightProviders(highlightProviders)')

controller = root / 'Controller/TextViewController.swift'
replace(controller, '    var foldProvider: LineFoldProvider', '''    public private(set) var foldingRevision: UInt64 = 0
    func invalidateFastraFolds() { foldingRevision &+= 1 }
    var foldProvider: LineFoldProvider''')
extra = root / 'Controller/TextViewController+FastraFolding.swift'
pending[extra] = (templates / 'folding-controller.swift').read_text()

model = root / 'LineFolding/Model/LineFoldModel.swift'
replace(model, 'class LineFoldModel: NSObject', '@MainActor\nclass LineFoldModel: NSObject')
replace(model, 'AsyncStream<Void>.makeStream()', 'AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))')
if '                self.foldCache = newFolds\n                foldView?.needsDisplay = true' in read(model):
    replace(model, '                self.foldCache = newFolds\n                foldView?.needsDisplay = true',
            '                self.foldCache = newFolds\n                self.controller?.reconcileFastraCollapseState()\n                foldView?.needsDisplay = true')
replace(model, '''        cacheListenTask = Task { @MainActor [weak foldView] in
            for await newFolds in await calculator.valueStream {
                foldCache = newFolds
                foldView?.needsDisplay = true
            }
        }''', '''        let values = calculator.valueStream
        cacheListenTask = Task { @MainActor [weak self, weak foldView] in
            for await newFolds in values {
                guard let self, !Task.isCancelled else { break }
                guard newFolds.revision == self.controller?.foldingRevision else { continue }
                self.foldCache = newFolds
                self.controller?.reconcileFastraCollapseState()
                foldView?.needsDisplay = true
            }
        }''')
replace(model, '        foldCache.storageUpdated(editedRange:',
        '        controller?.invalidateFastraFolds()\n        clearEmphasis()\n        foldView?.needsDisplay = true\n        foldCache.storageUpdated(editedRange:')
replace(model, 'guard let deepestFold = foldCache.folds(in: lineRange.intRange).max(by:',
        'guard let deepestFold = foldCache.folds(in: lineRange.intRange)\n            .filter({ lineRange.contains($0.range.lowerBound) }).max(by:')
discarded_original = """        foldCache.toggleCollapse(forFold: fold)
        foldView?.needsDisplay = true
        textChangedStreamContinuation.yield()"""
discarded_previous = """        foldView?.needsDisplay = true
        // Der Attachment-Manager entfernt den Platzhalter erst nach diesem Callback.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.textChangedStreamContinuation.yield()
        }"""
discarded_final = """        foldView?.needsDisplay = true
        // IDs koennen nach einem Parse wiederverwendet sein; der aktuelle Bereich ist massgeblich.
        foldCache.markExpanded(range: fold.range)
        // Der Attachment-Manager entfernt den Platzhalter erst nach diesem Callback.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.textChangedStreamContinuation.yield()
        }"""
replace(model, discarded_previous if discarded_previous in read(model) else discarded_original, discarded_final)
replace(model, '    func getFolds(in range: Range<Int>)', '''    deinit {
        cacheListenTask?.cancel()
        textChangedStreamContinuation.finish()
    }

    func refreshFastraFolds() { textChangedStreamContinuation.yield() }

    func getFolds(in range: Range<Int>)''')

ribbon = root / 'LineFolding/View/LineFoldRibbonView.swift'
replace(ribbon, 'static let width: CGFloat = 7.0', 'static let width: CGFloat = 14.0')
start = '        if let attachment = findAttachmentFor(fold: fold, firstLineRange: firstLineInFold.range) {'
end = '        mouseMoved(with: event)'
source = read(ribbon)
new = '''        model?.controller?.setFastraFold(range: NSRange(fold.range), collapsed: !fold.isCollapsed,
                                       includeChildren: event.modifierFlags.contains(.option))
        mouseMoved(with: event)'''
if new not in source:
    if source.count(start) != 1 or source.count(end) != 1:
        raise SystemExit('LineFoldRibbonView: Klick-Anker fehlt')
    a, b = source.index(start), source.index(end) + len(end)
    pending[ribbon] = source[:a] + new + source[b:]
else:
    pending[ribbon] = source

manager = text_root / 'TextLayoutManager/TextAttachments/TextAttachmentManager.swift'
replace(manager, '''        layoutManager?.setNeedsLayout()

        delegate?.textAttachmentDidAdd''', '''        // Der Header braucht neue Fragmente, sonst fehlt der sichtbare Platzhalter.
        layoutManager?.invalidateLayoutForRange(range)
        layoutManager?.setNeedsLayout()

        delegate?.textAttachmentDidAdd''')
old_length = '''                let length = max(0, min(attachment.range.length + delta,
                    (layoutManager?.lineStorage.length ?? 0) - replacedRange.location))'''
if old_length in read(manager):
    replace(manager, old_length, '''                let end = min(layoutManager?.lineStorage.length ?? 0,
                              max(replacedRange.location, attachment.range.upperBound + delta))
                let length = end - replacedRange.location''')
replace(manager, '''    package func textUpdated(atOffset: Int, delta: Int) {
        for (idx, attachment) in orderedAttachments.enumerated().reversed() {
            if attachment.range.contains(atOffset) {
                orderedAttachments.remove(at: idx)
            } else if attachment.range.location > atOffset {
                orderedAttachments[idx].range.location += delta
            }
        }
    }''', '''    package func textUpdated(replacedRange: NSRange, delta: Int) {
        for (idx, attachment) in orderedAttachments.enumerated().reversed() {
            if attachment.range.contains(replacedRange.location)
                || NSIntersectionRange(attachment.range, replacedRange).length > 0 {
                orderedAttachments.remove(at: idx)
                // Alte versteckte Zeilen ebenfalls freigeben, auch wenn die
                // Loeschung vor dem Anfang des Platzhalters begonnen hat.
                let end = min(layoutManager?.lineStorage.length ?? 0,
                              max(replacedRange.location, attachment.range.upperBound + delta))
                let length = end - replacedRange.location
                restoreFastraLineHeights(in: NSRange(location: replacedRange.location, length: length))
                layoutManager?.invalidateLayoutForRange(NSRange(location: replacedRange.location, length: length))
                delegate?.textAttachmentDidRemove(attachment.attachment, for: attachment.range)
            } else if attachment.range.location >= replacedRange.upperBound {
                orderedAttachments[idx].range.location += delta
            }
        }
    }''')
replace(manager, '        layoutManager?.invalidateLayoutForRange(attachment.range)\n',
        '        restoreFastraLineHeights(in: attachment.range)\n        layoutManager?.invalidateLayoutForRange(attachment.range)\n')
replace(manager, '                layoutManager?.invalidateLayoutForRange(NSRange(location: replacedRange.location, length: length))',
        '                restoreFastraLineHeights(in: NSRange(location: replacedRange.location, length: length))\n                layoutManager?.invalidateLayoutForRange(NSRange(location: replacedRange.location, length: length))')
restore_helper = '''    // Nullhoehen sind im Y-Iterator unsichtbar. Nach dem Entfernen muss eine
    // geschaetzte Hoehe sie wieder erreichbar machen, ausser ein erhaltenes
    // verschachteltes Attachment verdeckt die Zeile weiterhin.
    private func restoreFastraLineHeights(in range: NSRange) {
        guard let layoutManager else { return }
        let inclusive = NSRange(location: range.location,
            length: max(0, min(layoutManager.lineStorage.length - range.location, range.length + 1)))
        for line in layoutManager.lineStorage.linesInRange(inclusive) where line.height == 0 {
            let stillHidden = orderedAttachments.contains {
                $0.range.location < line.range.location && $0.range.upperBound >= line.range.location
            }
            if !stillHidden {
                layoutManager.lineStorage.update(atOffset: line.range.location, delta: 0,
                                                 deltaHeight: layoutManager.estimateLineHeight())
            }
        }
        layoutManager.setNeedsLayout()
    }

'''
restore_anchor = '    /// Set up the attachment manager to listen to selection updates,'
source = read(manager)
restore_marker = '    // Nullhoehen sind im Y-Iterator unsichtbar.'
if source.count(restore_anchor) != 1:
    raise SystemExit('TextAttachmentManager: Zeilenhoehen-Anker fehlt')
if restore_marker in source:
    begin, end = source.index(restore_marker), source.index(restore_anchor)
    if begin >= end or 'private func restoreFastraLineHeights(in range: NSRange)' not in source[begin:end]:
        raise SystemExit('TextAttachmentManager: Zeilenhoehen-Helfer nicht eindeutig')
    pending[manager] = source[:begin] + restore_helper + source[end:]
else:
    pending[manager] = source.replace(restore_anchor, restore_helper + restore_anchor)
if read(manager).count(restore_helper) != 1:
    raise SystemExit('TextAttachmentManager: Zeilenhoehen-Helfer unvollstaendig')
edits = text_root / 'TextLayoutManager/TextLayoutManager+Edits.swift'
replace(edits, 'attachments.textUpdated(atOffset: editedRange.location, delta: delta)',
        'attachments.textUpdated(replacedRange: replacedStringRange, delta: delta)')

iterator = text_root / 'TextLayoutManager/TextLayoutManager+Iterator.swift'
replace(iterator, 'let lastAttachment = attachments.last else {',
        'let lastAttachment = attachments.max(by: { $0.range.upperBound < $1.range.upperBound }) else {')

cursor = root / 'Controller/TextViewController+Cursor.swift'
replace(cursor, '        textView.selectionManager.setSelectedRanges(newSelectedRanges)',
        '        for range in newSelectedRanges { unfoldFastraFolds(containing: range) }\n        textView.selectionManager.setSelectedRanges(newSelectedRanges)')

placeholder = root / 'LineFolding/Placeholder/LineFoldPlaceholder.swift'
replace(placeholder, '    let fold: FoldRange', '    var fold: FoldRange')
replace(placeholder, '        return .discard', '        return .discardSelectingRange')
action = text_root / 'TextLayoutManager/TextAttachments/TextAttachment.swift'
replace(action, '    case discard\n', '    case discard\n    /// Fastra: Nach dem Oeffnen bleibt der zuvor verdeckte Bereich ausgewaehlt.\n    case discardSelectingRange\n')
mouse = text_root / 'TextView/TextView+Mouse.swift'
replace(mouse, '        case let .replace(text):', '''        case .discardSelectingRange:
            layoutManager.attachments.remove(atOffset: attachment.range.location)
            selectionManager.setSelectedRange(attachment.range)
        case let .replace(text):''')

changed = False
for path, content in pending.items():
    if not path.exists() or path.read_text() != content:
        if path.exists(): path.chmod(path.stat().st_mode | 0o200)
        path.write_text(content)
        changed = True
    if path.read_text() != content:
        raise SystemExit(f'{path.name}: Folding-Selbstprüfung fehlgeschlagen')
print('changed' if changed else 'unchanged')
