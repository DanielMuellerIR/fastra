// SelectableMatchText.swift
//
// Der Treffer-Detail-Bereich der Suchmaske zeigt GENAU EINEN Treffer
// (Suchmasken-Konzept §3). Hier markiert der Nutzer eine Teil-Selektion
// und definiert daraus eine Capture Group — dafür brauchen wir die
// ECHTE Selektion (NSRange) aus der View zurück. SwiftUIs `Text` mit
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
    /// Der exakte Match-Text (nur der Treffer, kein Kontext).
    let matchText: String
    /// Beiträge bestehender Gruppen im Match-Text: (Gruppennummer, Range).
    /// Ranges in UTF-16 — direkt aus `NSRegularExpression.range(at:)`.
    let groupRanges: [(number: Int, range: NSRange)]
    /// Aktuelle Nutzer-Selektion (UTF-16 im Match-Text) — fließt zurück
    /// an den Dialog, der daraus per „Gruppe definieren" eine Capture
    /// Group baut.
    @Binding var selection: NSRange

    typealias NSViewType = NSTextView

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        // Kein Umbruch nötig — Treffer sind kurz; bei Überlänge bricht
        // NSTextView von selbst um (View wächst mit dem SwiftUI-Layout).
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        // Höhe an den Inhalt koppeln, damit SwiftUI das Layout bestimmt.
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.setContentHuggingPriority(.required, for: .vertical)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.parent = self
        // Inhalt + Attribute komplett neu setzen — der Text ist read-only
        // und kurz, ein Voll-Rebuild ist hier unkritisch (kein Tipp-Cursor,
        // der springen könnte).
        if textView.string != matchText {
            textView.string = matchText
        }
        applyGroupHighlights(to: textView)
    }

    /// Färbt die Beiträge bestehender Gruppen im Match-Text ein —
    /// gleiche Farbreihe wie die Pills (`Theme.groupColors`).
    private func applyGroupHighlights(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        // Basis: dunkle Ink-Farbe, kein Hintergrund.
        storage.addAttribute(.foregroundColor,
                             value: NSColor(srgbRed: 0x1A/255.0, green: 0x18/255.0,
                                            blue: 0x10/255.0, alpha: 1),
                             range: fullRange)
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
