import AppKit
import SwiftUI

/// Native, auswählbare Textansicht für Git-Vorversionen gelöschter Dateien.
/// Ein eigener AppKit-Pfad ist hier absichtlich passender als der normale
/// CodeEdit-Editor: CodeEdit nimmt einer `isEditable == false`-Ansicht den
/// Tastaturfokus und kann einen Schreibversuch deshalb nicht am Cursor erklären.
struct ReadOnlySourceView: NSViewRepresentable {
    let content: String
    let reason: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = ReadOnlySnapshotTextView()
        textView.reason = reason
        textView.string = content
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.setAccessibilityIdentifier("gitDeletedReadOnlyEditor")
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ReadOnlySnapshotTextView else { return }
        textView.reason = reason
        guard textView.string != content else { return }
        let oldSelection = textView.selectedRange()
        textView.string = content
        let limit = (content as NSString).length
        textView.setSelectedRange(NSRange(location: min(oldSelection.location, limit),
                                          length: 0))
    }
}

/// `NSTextView` verhindert die Änderung selbst. Diese Unterklasse ergänzt die
/// fehlende direkte Erklärung und lässt Navigation, Auswahl, Suche und Kopieren
/// unverändert durch.
final class ReadOnlySnapshotTextView: NSTextView {
    var reason = ""
    private var noticePopover: NSPopover?
    private var closeNoticeWork: DispatchWorkItem?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.control)
            || Self.navigationKeyCodes.contains(event.keyCode) {
            super.keyDown(with: event)
            return
        }
        showReadOnlyNotice()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if command && (key == "v" || key == "x") {
            showReadOnlyNotice()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) { showReadOnlyNotice() }
    override func cut(_ sender: Any?) { showReadOnlyNotice() }
    override func deleteBackward(_ sender: Any?) { showReadOnlyNotice() }
    override func deleteForward(_ sender: Any?) { showReadOnlyNotice() }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        showReadOnlyNotice()
    }

    private func showReadOnlyNotice() {
        closeNoticeWork?.cancel()
        noticePopover?.close()

        let label = NSTextField(wrappingLabelWithString: reason)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 360
        let controller = NSViewController()
        controller.view = NSView()
        controller.view.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -8),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = controller
        popover.show(relativeTo: caretAnchorRect(), of: self, preferredEdge: .maxY)
        noticePopover = popover

        let work = DispatchWorkItem { [weak self, weak popover] in
            popover?.close()
            if self?.noticePopover === popover { self?.noticePopover = nil }
        }
        closeNoticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    private func caretAnchorRect() -> NSRect {
        let length = (string as NSString).length
        let location = min(selectedRange().location, length)
        let screenRect = firstRect(forCharacterRange: NSRange(location: location, length: 0),
                                   actualRange: nil)
        guard let window else {
            return NSRect(x: textContainerInset.width, y: textContainerInset.height,
                          width: 1, height: font?.pointSize ?? 13)
        }
        let local = convert(window.convertFromScreen(screenRect), from: nil)
        return NSRect(x: local.minX, y: local.minY,
                      width: max(1, local.width),
                      height: max(font?.pointSize ?? 13, local.height))
    }

    private static let navigationKeyCodes: Set<UInt16> = [
        53, // Escape
        115, 116, 117, 119, 121, // Home, Page Up, Forward Delete, End, Page Down
        123, 124, 125, 126,      // Pfeiltasten
    ]
}
