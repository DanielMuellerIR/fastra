import AppKit
import Combine
import CodeEditSourceEditor
import CodeEditTextView

/// Korrigiert die anfängliche Umbruchbreite jedes neu erzeugten Editors.
///
/// CodeEditSourceEditor berechnet in `viewWillAppear` zuerst die Text-Inserts
/// und layoutet erst danach die Minimap. Deren Breite ist beim ersten Schritt
/// daher noch 0; lange Zeilen laufen bis zum ersten manuellen Resize unter die
/// Minimap. Der Coordinator erhält den konkreten Controller jedes Tabs und
/// synchronisiert den rechten Text-Inset nach dem endgültigen Auto-Layout.
@MainActor
final class MinimapLayoutCoordinator: ObservableObject, @preconcurrency TextViewCoordinator {
    func prepareCoordinator(controller: TextViewController) { }

    func controllerDidAppear(controller: TextViewController) {
        scheduleSynchronization(for: controller, attempt: 0)
    }

    func destroy() { }

    private func scheduleSynchronization(for controller: TextViewController,
                                         attempt: Int) {
        let delay = attempt == 0 ? 0 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak controller] in
            guard let controller else { return }
            let ready = self.synchronize(controller: controller)
            if !ready, attempt < 5 {
                self.scheduleSynchronization(for: controller, attempt: attempt + 1)
            }
        }
    }

    /// Gibt `false` zurück, solange Auto Layout der sichtbaren Minimap noch
    /// keine Breite gegeben hat; der Aufrufer versucht es dann kurz darauf neu.
    @discardableResult
    func synchronize(controller: TextViewController) -> Bool {
        controller.view.layoutSubtreeIfNeeded()
        guard let minimap = firstMinimap(in: controller.view) else { return false }
        minimap.layoutSubtreeIfNeeded()

        let trailing = MinimapLayout.trailingInset(
            isHidden: minimap.isHidden,
            frameWidth: minimap.frame.width
        )
        guard minimap.isHidden || trailing > 0 else { return false }

        let current = controller.textView.textInsets
        controller.textView.textInsets = HorizontalEdgeInsets(
            left: current.left,
            right: trailing
        )
        controller.textView.layoutManager.setNeedsLayout()
        controller.textView.updateFrameIfNeeded()
        controller.scrollView.tile()
        return true
    }

    private func firstMinimap(in view: NSView) -> MinimapView? {
        if let minimap = view as? MinimapView { return minimap }
        for child in view.subviews {
            if let minimap = firstMinimap(in: child) { return minimap }
        }
        return nil
    }
}

/// Kleine pure Rechenregel für die testbare Inset-Entscheidung.
enum MinimapLayout {
    static func trailingInset(isHidden: Bool, frameWidth: CGFloat) -> CGFloat {
        isHidden ? 0 : max(0, frameWidth)
    }
}
