// Fastra-Erweiterung des gepinnten CodeEditTextView-Checkouts.
// Wird von build.sh reproduzierbar in den Checkout kopiert.

import AppKit
import ObjectiveC

private final class FastraExternalDropState: NSObject {
    let acceptedTypes: [NSPasteboard.PasteboardType]
    let canHandle: (NSPasteboard) -> Bool
    let perform: (NSPasteboard, Int) -> Bool
    var insertionOffset: Int?
    var lastWindowPoint: NSPoint?
    var timer: Timer?

    init(acceptedTypes: [NSPasteboard.PasteboardType],
         canHandle: @escaping (NSPasteboard) -> Bool,
         perform: @escaping (NSPasteboard, Int) -> Bool) {
        self.acceptedTypes = acceptedTypes
        self.canHandle = canHandle
        self.perform = perform
    }

    deinit { timer?.invalidate() }
}

private var fastraExternalDropStateKey: UInt8 = 0

extension TextView {
    private static let fastraBaseDraggedTypes: [NSPasteboard.PasteboardType] = [
        .string, .fileContents, .html, .multipleTextSelection, .tabularText, .rtf,
    ]

    private var fastraExternalDropState: FastraExternalDropState? {
        get { objc_getAssociatedObject(self, &fastraExternalDropStateKey) as? FastraExternalDropState }
        set {
            objc_setAssociatedObject(self, &fastraExternalDropStateKey, newValue,
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Aktiviert einen anwendungsspezifischen externen Drop. CodeEdits
    /// normale Text-Drag-Semantik bleibt für nicht akzeptierte Pasteboards
    /// vollständig erhalten.
    public func fastraConfigureExternalDrop(
        acceptedTypes: [NSPasteboard.PasteboardType],
        canHandle: @escaping (NSPasteboard) -> Bool,
        perform: @escaping (NSPasteboard, Int) -> Bool
    ) {
        fastraCleanUpExternalDrop()
        fastraExternalDropState = FastraExternalDropState(
            acceptedTypes: acceptedTypes, canHandle: canHandle, perform: perform
        )
        unregisterDraggedTypes()
        registerForDraggedTypes(Self.fastraBaseDraggedTypes + acceptedTypes)
    }

    public func fastraClearExternalDrop() {
        fastraCleanUpExternalDrop()
        fastraExternalDropState = nil
        unregisterDraggedTypes()
        registerForDraggedTypes(Self.fastraBaseDraggedTypes)
    }

    /// Beobachtbare Regressionseigenschaften für den echten Editor-Selbsttest.
    public var fastraExternalDropInsertionOffset: Int? {
        fastraExternalDropState?.insertionOffset
    }

    public var fastraShowsExternalDropCursor: Bool {
        fastraExternalDropState?.insertionOffset != nil && draggingCursorView != nil
    }

    /// Rückgabe `nil`: CodeEdits gewöhnlichen Text-Drag weiterverwenden.
    func fastraExternalDraggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation? {
        guard let state = fastraExternalDropState,
              state.canHandle(sender.draggingPasteboard) else {
            if fastraExternalDropState?.insertionOffset != nil { fastraCleanUpExternalDrop() }
            return nil
        }
        state.lastWindowPoint = sender.draggingLocation
        fastraUpdateExternalDropCursor(windowPoint: sender.draggingLocation)
        if state.timer == nil {
            let timer = Timer(timeInterval: 0.022, repeats: true) {
                [weak self] _ in self?.fastraExternalAutoscrollStep()
            }
            // Während AppKit einen Drag verfolgt, läuft der RunLoop nicht
            // zwingend im Default-Modus. `.common` hält den stationären
            // Rand-Autoscroll deshalb auch ohne weitere Mausbewegung aktiv.
            RunLoop.main.add(timer, forMode: .common)
            state.timer = timer
        }
        return .copy
    }

    /// Rückgabe `nil`: Dieser Pasteboard-Inhalt gehört CodeEdits Standardpfad.
    func fastraPerformExternalDrop(_ sender: any NSDraggingInfo) -> Bool? {
        guard let state = fastraExternalDropState,
              state.canHandle(sender.draggingPasteboard) else { return nil }
        fastraUpdateExternalDropCursor(windowPoint: sender.draggingLocation)
        guard let offset = state.insertionOffset else {
            fastraCleanUpExternalDrop()
            return false
        }
        selectionManager.setSelectedRange(NSRange(location: offset, length: 0))
        let handled = state.perform(sender.draggingPasteboard, offset)
        fastraCleanUpExternalDrop()
        return handled
    }

    func fastraCleanUpExternalDrop() {
        fastraExternalDropState?.timer?.invalidate()
        fastraExternalDropState?.timer = nil
        fastraExternalDropState?.insertionOffset = nil
        fastraExternalDropState?.lastWindowPoint = nil
        draggingCursorView?.removeFromSuperview()
        draggingCursorView = nil
    }

    private func fastraUpdateExternalDropCursor(windowPoint: NSPoint) {
        guard let state = fastraExternalDropState else { return }
        let point = convert(windowPoint, from: nil)
        let visible = visibleRect
        let clamped = NSPoint(
            x: min(max(point.x, visible.minX + 1), max(visible.minX + 1, visible.maxX - 1)),
            y: min(max(point.y, visible.minY + 1), max(visible.minY + 1, visible.maxY - 1))
        )
        let fallbackOffset: Int = {
            guard let range = visibleTextRange else {
                return point.y < visible.midY ? 0 : textStorage.length
            }
            return point.y < visible.midY ? range.location : range.max
        }()
        let offset = min(max(layoutManager.textOffsetAtPoint(clamped) ?? fallbackOffset, 0),
                         textStorage.length)
        guard let cursorPosition = layoutManager.rectForOffset(offset) else { return }

        let cursor: NSView
        if let draggingCursorView {
            cursor = draggingCursorView
        } else if useSystemCursor, #available(macOS 15, *) {
            let indicator = NSTextInsertionIndicator()
            indicator.displayMode = .visible
            cursor = indicator
            addSubview(indicator)
        } else {
            let indicator = CursorView(color: selectionManager.insertionPointColor)
            cursor = indicator
            addSubview(indicator)
        }
        draggingCursorView = cursor
        cursor.frame = NSRect(x: cursorPosition.minX, y: cursorPosition.minY,
                              width: max(cursorPosition.width, 1),
                              height: cursorPosition.height)
        state.insertionOffset = offset
    }

    private func fastraExternalAutoscrollStep() {
        guard let state = fastraExternalDropState,
              let windowPoint = state.lastWindowPoint,
              let scrollView else { return }
        let point = convert(windowPoint, from: nil)
        let visible = visibleRect
        let threshold: CGFloat = 32
        let delta: CGFloat
        if point.y < visible.minY + threshold {
            delta = -max(3, (visible.minY + threshold - point.y) * 0.35)
        } else if point.y > visible.maxY - threshold {
            delta = max(3, (point.y - (visible.maxY - threshold)) * 0.35)
        } else {
            return
        }
        let clip = scrollView.contentView
        let documentHeight = max(layoutManager.estimatedHeight(), frame.height)
        let targetY = min(max(clip.bounds.minY + delta, 0),
                          max(documentHeight - clip.bounds.height, 0))
        guard abs(targetY - clip.bounds.minY) > 0.1 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: targetY))
        scrollView.reflectScrolledClipView(clip)
        layoutManager.layoutLines()
        fastraUpdateExternalDropCursor(windowPoint: windowPoint)
    }
}
