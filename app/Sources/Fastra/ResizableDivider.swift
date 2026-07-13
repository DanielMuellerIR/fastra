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
        // Die AppKit-Fläche konsumiert den Maus-Down ausdrücklich selbst.
        // Das ist bei unserem vollflächig verschiebbaren Fenster entscheidend:
        // Eine reine SwiftUI-DragGesture lässt AppKit gleichzeitig das Fenster
        // ziehen, statt ausschließlich die Seitenleiste zu skalieren.
        .overlay {
            SplitterDragSurface(value: $value, range: range, direction: direction)
        }
        .help(help)
    }
}

/// AppKit-Unterbau der Splitter-Geste. `mouseDownCanMoveWindow == false` trennt
/// den Splitter verlässlich von `NSWindow.isMovableByWindowBackground`.
struct SplitterDragSurface: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let direction: Double

    func makeNSView(context: Context) -> SplitterDragView {
        SplitterDragView(value: value, range: range, direction: direction) {
            self.value = $0
        }
    }

    func updateNSView(_ view: SplitterDragView, context: Context) {
        view.value = value
        view.range = range
        view.direction = direction
        view.onChange = { self.value = $0 }
    }
}

/// Eigene NSView, damit AppKit einen Splitter-Klick nie als Fenster-Drag deutet.
final class SplitterDragView: NSView {
    var value: Double
    var range: ClosedRange<Double>
    var direction: Double
    var onChange: (Double) -> Void

    private var dragStartValue: Double?
    private var dragStartX: CGFloat?

    init(value: Double,
         range: ClosedRange<Double>,
         direction: Double,
         onChange: @escaping (Double) -> Void) {
        self.value = value
        self.range = range
        self.direction = direction
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wurde nicht implementiert") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartValue = value
        dragStartX = screenX(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartValue, let dragStartX else { return }
        let next = SplitterSizing.width(
            start: dragStartValue,
            translation: Double(screenX(for: event) - dragStartX),
            direction: direction,
            minimum: range.lowerBound,
            maximum: range.upperBound
        )
        value = next
        onChange(next)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartValue = nil
        dragStartX = nil
    }

    private func screenX(for event: NSEvent) -> CGFloat {
        window?.convertPoint(toScreen: event.locationInWindow).x ?? event.locationInWindow.x
    }
}
