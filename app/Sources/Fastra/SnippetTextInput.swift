import AppKit
import SwiftUI

struct SnippetTextInput: NSViewRepresentable {
    @Binding var text: String
    let identifier: String
    let label: String
    let byteLimit: Int
    var editable = true
    var tabMovesFocus = false
    var onLimit: () -> Void = {}
    @Environment(\.isEnabled) private var enabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        let view = NSTextView(frame: .zero)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.delegate = context.coordinator
        scroll.documentView = view
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        view.isEditable = editable && enabled
        view.isSelectable = true
        view.backgroundColor = .textBackgroundColor
        view.textColor = .textColor
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        guard !view.string.utf8.elementsEqual(text.utf8) else { return }
        let oldSelection = view.selectedRange()
        context.coordinator.updating = true
        view.string = text
        view.setSelectedRange(SelectionClamping.clamp(oldSelection, textLength: (text as NSString).length))
        context.coordinator.updating = false
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SnippetTextInput
        var updating = false
        init(_ parent: SnippetTextInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            guard let replacementString else { return true }
            let old = textView.string as NSString
            guard affectedCharRange.location != NSNotFound,
                  affectedCharRange.location <= old.length,
                  affectedCharRange.length <= old.length - affectedCharRange.location else { return false }
            let remainingBytes = textView.string.utf8.count - old.substring(with: affectedCharRange).utf8.count
            guard remainingBytes <= parent.byteLimit,
                  replacementString.utf8.count <= parent.byteLimit - remainingBytes else {
                parent.onLimit(); return false
            }
            return true
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard parent.tabMovesFocus else { return false }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                textView.window?.selectNextKeyView(textView); return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                textView.window?.selectPreviousKeyView(textView); return true
            }
            return false
        }
    }
}
