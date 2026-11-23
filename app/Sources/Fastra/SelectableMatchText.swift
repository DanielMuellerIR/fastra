// SelectableMatchText.swift
//
// Der Treffer-Detail-Bereich der Suchmaske zeigt genau einen Treffer
// (Suchmasken-Konzept §3). Hier markiert der Nutzer eine Teil-Selektion
// und definiert daraus eine Capture Group — dafür brauchen wir die
// echte Selektion (NSRange) aus der View zurück. SwiftUIs `Text` mit
// `.textSelection(.enabled)` kann das nicht (keine programmatische
// Selektions-API), deshalb eine kleine AppKit-Brücke:
//
//   - read-only NSTextView (nicht editierbar, aber selektierbar)
//   - Selektion fließt über ein Binding nach SwiftUI zurück
//   - Beiträge bestehender Capture Groups werden farbig hinterlegt
//     (gleiche Farbreihe wie die Gruppen-Pills — Wiedererkennung)

import SwiftUI
import AppKit

/// Read-only, selektierbarer Match-Text mit Gruppen-Hinterlegung.
struct SelectableMatchText: NSViewRepresentable {
    @Environment(\.uiScale) private var uiScale
    /// Der exakte Match-Text (nur der Treffer, kein Kontext).
    let matchText: String
    /// Beiträge bestehender Gruppen im Match-Text: (Gruppennummer, Range).
    /// Ranges in UTF-16 — direkt aus `NSRegularExpression.range(at:)`.
    let groupRanges: [(number: Int, range: NSRange)]
    /// Aktuelle Nutzer-Selektion (UTF-16 im Match-Text) — fließt zurück
    /// an den Dialog, der daraus per „Gruppe definieren" eine Capture
    /// Group baut.
    @Binding var selection: NSRange

    typealias NSViewType = NSScrollView

    /// Der Textkasten ist eine Zeile hoch (`FloatingSearchDialog.detailTextHeight`).
    /// Eine NSScrollView ohne sichtbare Balken hält lange und mehrzeilige Treffer
    /// vollständig per Trackpad erreichbar und verhindert Zeichnung über Nachbarn.
    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .fastraMonospaced(size: 13, scale: uiScale)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        // Kein Umbruch: Die Zeile läuft nach rechts weiter und scrollt.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        textView.font = .fastraMonospaced(size: 13, scale: uiScale)
        // Inhalt + Attribute komplett neu setzen — der Text ist read-only
        // und kurz, ein Voll-Rebuild ist hier unkritisch (kein Tipp-Cursor,
        // der springen könnte).
        if textView.string != matchText {
            textView.string = matchText
            // Neuer Treffer → wieder an den Anfang scrollen.
            scrollView.contentView.scroll(to: .zero)
        }
        applyGroupHighlights(to: textView)
    }

    /// Färbt die Beiträge bestehender Gruppen im Match-Text ein —
    /// gleiche Farbreihe wie die Pills (`Theme.groupColors`).
    private func applyGroupHighlights(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)
        storage.removeAttribute(.backgroundColor, range: fullRange)
        for (number, range) in groupRanges {
            // Defensive Range-Prüfung — ein Treffer kann sich geändert
            // haben, während die Gruppen-Ranges noch vom alten stammen.
            guard range.location != NSNotFound,
                  range.location + range.length <= fullRange.length,
                  range.length > 0 else { continue }
            // abs(): Swift-`%` kann bei number 0 (sollte nie — Gruppen sind
            // 1-basiert) negativ werden → Array-Crash. Defensive Klammer.
            let colorIndex = abs(number - 1) % Theme.groupColors.count
            let nsColor = NSColor(Theme.groupColors[colorIndex])
                .withAlphaComponent(0.35)
            storage.addAttribute(.backgroundColor, value: nsColor, range: range)
        }
        storage.endEditing()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SelectableMatchText
        init(parent: SelectableMatchText) { self.parent = parent }

        /// Selektion → Binding. Läuft bei jeder Selektionsänderung
        /// (Maus-Ziehen, Shift+Pfeile, Doppelklick).
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let newSelection = tv.selectedRange()
            if parent.selection != newSelection {
                // Asynchron — Binding-Schreiben mitten im AppKit-Event-
                // Handling kann sonst „Modifying state during view update"
                // auslösen.
                DispatchQueue.main.async { [weak self] in
                    self?.parent.selection = newSelection
                }
            }
        }
    }
}
