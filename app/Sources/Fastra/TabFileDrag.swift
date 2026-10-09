import AppKit
import SwiftUI

enum TabFileDrag {
    static func fileURL(for tab: EditorTab) -> URL? {
        guard !tab.isLoading, !tab.externalFileUnavailable,
              tab.gitKind == nil, tab.gitSnapshotRequest == nil,
              tab.fileDiffRequest == nil,
              let url = tab.url, url.isFileURL else { return nil }
        return url
    }

    static func hint(for tab: EditorTab) -> String {
        guard fileURL(for: tab) != nil else { return "" }
        return tab.hasUnsavedChanges
            ? L10n.string("Datei ziehen — verwendet die gespeicherte Fassung ohne die ungespeicherten Änderungen.")
            : L10n.string("Datei vom Tab in den Finder oder eine andere App ziehen.")
    }
}

struct TabFileDragModifier: ViewModifier {
    let url: URL?
    let closeAreaWidth: CGFloat
    let help: String
    let onSelect: () -> Void
    let onExtendSelection: () -> Void
    let onPathMenu: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if let url {
            content.overlay {
                TabFileDragSurface(url: url, help: help) { flags in
                    if flags.contains(.command) { onPathMenu() }
                    else if flags.contains(.shift) { onExtendSelection() }
                    else { onSelect() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, closeAreaWidth)
            }
        } else {
            content
        }
    }
}

private struct TabFileDragSurface: NSViewRepresentable {
    let url: URL
    let help: String
    let onClick: (NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> TabFileDragView {
        let view = TabFileDragView(url: url, onClick: onClick)
        view.toolTip = help
        return view
    }

    func updateNSView(_ view: TabFileDragView, context: Context) {
        view.url = url
        view.onClick = onClick
        view.toolTip = help
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TabFileDragView,
                     context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

/// Die Fläche bildet den sichtbaren Dateiteil des Tabs ab. SwiftUIs nativer
/// Button bleibt für Darstellung, Tastatur und Bedienungshilfen erhalten.
private final class TabFileDragView: NSView, NSDraggingSource {
    var url: URL
    var onClick: (NSEvent.ModifierFlags) -> Void
    private var press: (point: NSPoint, url: URL)?
    var onDragStart: (() -> Void)?

    init(url: URL, onClick: @escaping (NSEvent.ModifierFlags) -> Void) {
        self.url = url
        self.onClick = onClick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wurde nicht implementiert") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { TabFileDragRouting.shared.register(self) }
    }

    override func mouseDown(with event: NSEvent) {
        diagnose("mouseDown")
        press = (event.locationInWindow, url)
    }

    override func mouseDragged(with event: NSEvent) {
        diagnose("mouseDragged")
        guard let press,
              hypot(event.locationInWindow.x - press.point.x,
                    event.locationInWindow.y - press.point.y) >= 4 else { return }
        self.press = nil
        onDragStart?()
        let item = NSDraggingItem(pasteboardWriter: press.url as NSURL)
        let point = convert(event.locationInWindow, from: nil)
        let icon = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        item.setDraggingFrame(NSRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24),
                              contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
        diagnose("session started")
    }

    override func mouseUp(with event: NSEvent) {
        diagnose("mouseUp")
        guard press != nil else { return }
        press = nil
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick(event.modifierFlags)
        }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    private func diagnose(_ event: String) {
        guard SelfTest.requestedTest == "tabfiledrag" else { return }
        FileHandle.standardError.write(Data("TABDRAG \(event)\n".utf8))
    }
}

/// AppKit trifft in der SwiftUI-Leiste den darunterliegenden Button auch
/// über einer nativen Overlay-View. Ein gemeinsamer Monitor übernimmt daher
/// nur Mausfolgen im sichtbaren Dateiteil; Schließen und leere Flächen bleiben
/// beim normalen Routing. Weitere Drag-Ereignisse gehören sofort wieder AppKit.
@MainActor
private final class TabFileDragRouting {
    static let shared = TabFileDragRouting()
    private let surfaces = NSHashTable<TabFileDragView>.weakObjects()
    private weak var pressed: TabFileDragView?
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
            [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.route(event)
            }
        }
    }

    func register(_ view: TabFileDragView) {
        surfaces.add(view)
        view.onDragStart = { [weak self] in self?.pressed = nil }
    }

    private func route(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            pressed = surfaces.allObjects.first { view in
                guard view.window === event.window, !view.isHiddenOrHasHiddenAncestor else { return false }
                let point = view.convert(event.locationInWindow, from: nil)
                // Seit macOS 14 kann visibleRect über die eigenen bounds
                // reichen. Sonst fängt ein Tab auch Klicks auf andere Tabs ab.
                return view.bounds.contains(point) && view.visibleRect.contains(point)
            }
            guard let view = pressed else { return event }
            event.window?.makeKeyAndOrderFront(nil)
            view.mouseDown(with: event)
            return nil
        case .leftMouseDragged:
            guard let view = pressed else { return event }
            view.mouseDragged(with: event)
            return nil
        case .leftMouseUp:
            guard let view = pressed else { return event }
            pressed = nil
            view.mouseUp(with: event)
            return nil
        default: return event
        }
    }
}
