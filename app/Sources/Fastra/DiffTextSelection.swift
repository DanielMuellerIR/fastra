import AppKit
import SwiftUI

/// Eine Diff-Spalte ist trotz ausgerichteter Anzeigezeilen ein zusammenhängender
/// Text. Leere Gegenseiten und Zeilennummern gehören nicht in die Zwischenablage.
struct DiffSelectionColumn: Equatable {
    struct Line: Equatable {
        let id: String
        let range: NSRange
    }
    let text: String
    let lines: [Line]
    private let rangesByID: [String: NSRange]

    init(items: [DiffDisplayItem], before: Bool) {
        var text = ""
        var lines: [Line] = []
        var offset = 0
        for item in items {
            guard case .row(let row) = item,
                  let value = before ? row.before : row.after else { continue }
            if !lines.isEmpty { text += "\n"; offset += 1 }
            let range = NSRange(location: offset, length: value.utf16.count)
            text += value
            offset += range.length
            lines.append(Line(id: row.id, range: range))
        }
        self.text = text
        self.lines = lines
        self.rangesByID = Dictionary(lines.map { ($0.id, $0.range) }, uniquingKeysWith: { first, _ in first })
    }

    func range(for id: String) -> NSRange? { rangesByID[id] }

    func substring(in range: NSRange) -> String {
        let length = text.utf16.count
        guard range.location != NSNotFound, range.location <= length,
              range.length <= length - range.location else { return "" }
        return (text as NSString).substring(with: range)
    }
}

@MainActor
final class DiffTextSelection: NSObject, ObservableObject, NSTextViewDelegate {
    private var before = DiffSelectionColumn(items: [], before: true)
    private var after = DiffSelectionColumn(items: [], before: false)
    private let views = NSHashTable<DiffSelectionTextView>.weakObjects()
    private var side = true
    private var anchor = NSRange(location: 0, length: 0)
    private var hasAnchor = false
    private(set) var range = NSRange(location: 0, length: 0)
    private var granularity: NSSelectionGranularity = .selectByCharacter
    private var dragOrigin: DiffSelectionTextView?
    private var applyingSelection = false

    func update(items: [DiffDisplayItem]) {
        let newBefore = DiffSelectionColumn(items: items, before: true)
        let newAfter = DiffSelectionColumn(items: items, before: false)
        guard before != newBefore || after != newAfter else { return }
        before = newBefore
        after = newAfter
        end()
        hasAnchor = false
        range = NSRange(location: 0, length: 0)
        refresh()
    }

    func register(_ view: DiffSelectionTextView) {
        views.add(view)
        refresh(view)
    }

    func unregister(_ view: DiffSelectionTextView) { views.remove(view) }
    func contains(_ view: DiffSelectionTextView) -> Bool {
        column(view.before).range(for: view.rowID) != nil
    }

    private func column(_ before: Bool) -> DiffSelectionColumn { before ? self.before : after }

    func begin(_ event: NSEvent, in view: DiffSelectionTextView) {
        guard let line = column(view.before).range(for: view.rowID) else { return }
        view.window?.makeFirstResponder(view)
        let sameSide = side == view.before
        side = view.before
        dragOrigin = view
        let offset = min(view.characterIndexForInsertion(at: view.convert(event.locationInWindow, from: nil)), line.length)
        granularity = event.clickCount >= 3 ? .selectByParagraph
            : event.clickCount == 2 ? .selectByWord : .selectByCharacter
        let local = view.selectionRange(forProposedRange: NSRange(location: offset, length: 0),
                                        granularity: granularity)
        let start = min(local.location, line.length)
        let end = min(NSMaxRange(local), line.length)
        if sameSide, hasAnchor, event.modifierFlags.contains(.shift) {
            extend(to: line.location + offset, selectedUnit: nil)
        } else {
            anchor = NSRange(location: line.location + start, length: end - start)
            range = anchor
            hasAnchor = true
            refresh()
        }
    }

    func drag(_ event: NSEvent) {
        guard let origin = dragOrigin, let window = origin.window else { return }
        let candidates = views.allObjects.filter {
            $0.before == side && $0.window === window && !$0.isHidden
                && column(side).range(for: $0.rowID) != nil
                && !$0.visibleRect.intersection($0.bounds).isEmpty
        }
        // Der Drag bleibt in seiner Ausgangsspalte, auch wenn die Maus die
        // Trennlinie überschreitet. Trefferprüfung nutzt echte AppKit-Geometrie.
        let point = event.locationInWindow
        guard let view = candidates.min(by: {
            distance(point, to: $0) < distance(point, to: $1)
        }), let line = column(side).range(for: view.rowID) else { return }
        let localPoint = view.convert(point, from: nil)
        let offset: Int
        if localPoint.y < 0 { offset = 0 }
        else if localPoint.y > view.bounds.height { offset = line.length }
        else { offset = min(view.characterIndexForInsertion(at: localPoint), line.length) }
        let unit = view.selectionRange(forProposedRange: NSRange(location: offset, length: 0),
                                       granularity: granularity)
        let lower = min(unit.location, line.length)
        let upper = min(NSMaxRange(unit), line.length)
        extend(to: line.location + offset,
               selectedUnit: NSRange(location: line.location + lower, length: upper - lower))
    }

    private func distance(_ point: NSPoint, to view: NSView) -> CGFloat {
        // NSTextView.visibleRect kann ohne eigenes Clipping über bounds
        // hinausreichen. Sonst erscheinen mehrere Zeilen als gleicher Treffer.
        let rect = view.convert(view.visibleRect.intersection(view.bounds), to: nil)
        return max(rect.minY - point.y, point.y - rect.maxY, 0)
    }

    private func extend(to offset: Int, selectedUnit: NSRange?) {
        let unit = selectedUnit ?? NSRange(location: offset, length: 0)
        let lower = min(anchor.location, unit.location)
        let upper = max(NSMaxRange(anchor), NSMaxRange(unit))
        range = NSRange(location: lower, length: upper - lower)
        refresh()
    }

    func end() { dragOrigin = nil }

    func copy() {
        guard range.length > 0 else { return }
        let value = column(side).substring(in: range)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func selectAll(in view: DiffSelectionTextView) {
        side = view.before
        anchor = NSRange(location: 0, length: 0)
        hasAnchor = true
        range = NSRange(location: 0, length: column(side).text.utf16.count)
        refresh()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !applyingSelection, let view = notification.object as? DiffSelectionTextView,
              view.window?.firstResponder === view,
              let line = column(view.before).range(for: view.rowID) else { return }
        let local = view.selectedRange()
        guard local.location <= line.length, local.length <= line.length - local.location else { return }
        side = view.before
        range = NSRange(location: line.location + local.location, length: local.length)
        anchor = range
        hasAnchor = true
        refresh()
    }

    private func refresh() { views.allObjects.forEach(refresh) }

    private func refresh(_ view: DiffSelectionTextView) {
        applyingSelection = true
        defer { applyingSelection = false }
        guard view.before == side, let line = column(side).range(for: view.rowID) else {
            view.setSelectedRange(NSRange(location: 0, length: 0))
            return
        }
        let lower = max(range.location, line.location)
        let upper = min(NSMaxRange(range), NSMaxRange(line))
        view.setSelectedRange(NSRange(location: min(max(0, lower - line.location), line.length),
                                      length: max(0, upper - lower)))
        view.needsDisplay = true
    }
}

@MainActor
final class DiffSelectionTextView: NSTextView {
    weak var selection: DiffTextSelection?
    var rowID = ""
    var before = true
    private var dragTimer: Timer?
    private var dragEvent: NSEvent?
    private var resignObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let window {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                    object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopDragging() }
            }
        }
    }

    private func stopDragging() {
        selection?.end()
        dragEvent = nil
        dragTimer?.invalidate()
        dragTimer = nil
    }

    override func mouseDown(with event: NSEvent) {
        selection?.begin(event, in: self)
        dragEvent = event
        dragTimer?.invalidate()
        dragTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let event = self.dragEvent else { return }
                if self.autoscroll(with: event) { self.selection?.drag(event) }
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        dragEvent = event
        selection?.drag(event)
        _ = autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        selection?.drag(event)
        stopDragging()
    }

    override func copy(_ sender: Any?) { selection?.copy() }
    override func selectAll(_ sender: Any?) { selection?.selectAll(in: self) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return (selection?.range.length ?? 0) > 0 }
        return super.validateUserInterfaceItem(item)
    }

    deinit {
        dragTimer?.invalidate()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}

struct DiffSelectableText: NSViewRepresentable {
    @Environment(\.uiScale) private var uiScale
    let text: String
    let highlight: Range<Int>?
    let color: Color
    let highlightColor: Color
    let before: Bool
    let rowID: String
    let wraps: Bool
    let selection: DiffTextSelection

    func makeNSView(context: Context) -> DiffSelectionTextView {
        let view = DiffSelectionTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return view
    }

    func updateNSView(_ view: DiffSelectionTextView, context: Context) {
        view.delegate = nil
        let font = NSFont.fastraMonospaced(size: 11, scale: uiScale)
        view.font = font
        let value = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor(color)
        ])
        if let highlight {
            let chars = Array(text)
            let lower = min(max(0, highlight.lowerBound), chars.count)
            let upper = min(max(lower, highlight.upperBound), chars.count)
            let range = NSRange(location: String(chars[..<lower]).utf16.count,
                                length: String(chars[lower..<upper]).utf16.count)
            value.addAttributes([.foregroundColor: NSColor(highlightColor),
                                 .font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)],
                                range: range)
        }
        if view.textStorage != value { view.textStorage?.setAttributedString(value) }
        view.selection = selection
        view.rowID = rowID
        view.before = before
        view.textContainer?.widthTracksTextView = wraps
        view.textContainer?.containerSize = NSSize(width: wraps ? max(1, view.bounds.width) : .greatestFiniteMagnitude,
                                                  height: .greatestFiniteMagnitude)
        selection.register(view)
        view.delegate = selection
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: DiffSelectionTextView,
                      context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 100)
        view.textContainer?.containerSize.width = wraps ? width : .greatestFiniteMagnitude
        guard let manager = view.layoutManager, let container = view.textContainer else { return nil }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return CGSize(width: wraps ? width : (proposal.width ?? max(1, ceil(used.width))),
                      height: max(ceil(used.height), ceil(manager.defaultLineHeight(for: view.font ?? .systemFont(ofSize: 11)))))
    }

    static func dismantleNSView(_ view: DiffSelectionTextView, coordinator: ()) {
        view.selection?.unregister(view)
    }
}
