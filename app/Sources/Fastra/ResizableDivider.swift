import AppKit
import SwiftUI

/// Ruhiger, gut greifbarer Splitter für zwei nebeneinanderliegende Bereiche.
///
/// Die sichtbare Linie bleibt einen Punkt dünn. Die Maus trifft jedoch eine
/// mittig um die Linie liegende 11-Punkt-Fläche. Das ist wichtig: Liegt die
/// unsichtbare Trefferfläche nur links oder rechts vom Strich, fühlt sich der
/// Splitter von der jeweils anderen Seite weiterhin wie ein 1-Pixel-Ziel an.
struct ResizableDivider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var direction: Double = 1
    let surface: Color
    let help: String

    /// Ausgangswert des laufenden Ziehvorgangs. `DragGesture.translation` ist
    /// bereits die Gesamtstrecke seit dem Mausklick; sie darf deshalb niemals
    /// wieder auf den schon veränderten Zwischenwert addiert werden.
    @State private var dragStart: Double?

    private let hitWidth: CGFloat = 11

    var body: some View {
        ZStack {
            // Die breite Trefferfläche ist absichtlich opak und trägt den Ton
            // des Nachbarbereichs. Eine transparente Fläche ließe im Dark Mode
            // den Fenstergrund als auffälliges helles Band durchscheinen.
            surface
            Rectangle()
                .fill(Theme.strokeStrong)
                .frame(width: 1)
        }
        .frame(width: hitWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .highPriorityGesture(
            // Entscheidend gegen das Zappeln: global statt lokal messen. Im
            // lokalen Koordinatenraum bewegt sich der Bezugspunkt zusammen mit
            // dem Splitter; daraus entsteht eine sichtbare Rückkopplung.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { gesture in
                    let start = dragStart ?? value
                    if dragStart == nil { dragStart = value }
                    value = SplitterSizing.width(
                        start: start,
                        translation: Double(gesture.translation.width),
                        direction: direction,
                        minimum: range.lowerBound,
                        maximum: range.upperBound
                    )
                }
                .onEnded { _ in dragStart = nil }
        )
        // `set()` bei jeder Bewegung ist robuster als ein einmaliges push/pop:
        // angrenzende ScrollViews erneuern ihre Cursor-Rects und überschreiben
        // einen nur beim Eintritt gesetzten Resize-Cursor sonst sofort wieder.
        .onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.resizeLeftRight.set()
            case .ended:  NSCursor.arrow.set()
            }
        }
        .help(help)
    }
}
