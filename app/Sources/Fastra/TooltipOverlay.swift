import SwiftUI
import AppKit

// SwiftUIs `.help` zeigt auf DEAKTIVIERTEN Bedienelementen keinen Tooltip an.
// Gerade dort ist er aber am wichtigsten: Ein ausgegrauter Bild-Knopf erklärt
// sich sonst gar nicht (Daniel-Wunsch 2026-09-01). AppKit-Tooltips kennen die
// Einschränkung nicht — diese unsichtbare Overlay-NSView trägt den Text als
// klassischen `toolTip` und reicht alle Klicks unverändert durch.
private struct TooltipHostView: NSViewRepresentable {
    let text: String

    /// `hitTest → nil`: Die View fängt keine Klicks ab. Tooltips funktionieren
    /// trotzdem, weil AppKit sie über geometrische Tracking-Bereiche des
    /// Fensters zeigt, nicht über die Klick-Zustellung.
    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView(frame: .zero)
        view.toolTip = text
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text
    }
}

extension View {
    /// Tooltip, der — anders als `.help` — auch im deaktivierten Zustand
    /// erscheint (z. B. Pull/Fetch, solange ein Git-Vorgang läuft). Für nie
    /// deaktivierte Bedienelemente bleibt `.help` weiterhin passend.
    func fastraHelp(_ text: String) -> some View {
        overlay(TooltipHostView(text: text))
    }
}
