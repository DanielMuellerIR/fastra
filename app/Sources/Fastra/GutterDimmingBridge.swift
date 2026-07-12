import SwiftUI
import AppKit

enum GutterDimming {
    static func opacity(windowIsKey: Bool) -> CGFloat {
        windowIsKey ? 1 : 0.42
    }

    static func apply(in root: NSView, windowIsKey: Bool) {
        let name = String(describing: type(of: root))
        if name == "GutterView" || name.hasSuffix(".GutterView") {
            root.alphaValue = opacity(windowIsKey: windowIsKey)
        }
        for child in root.subviews {
            apply(in: child, windowIsKey: windowIsKey)
        }
    }
}

/// Zero-Size-AppKit-Brücke: beobachtet den Key-Status des Dokumentfensters und
/// dimmt ausschließlich CodeEditSourceEditors Gutter-Subview. So bleibt Text
/// vollständig lesbar, während Zeilennummern im hinteren Fenster zurücktreten.
struct GutterDimmingBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> GutterObserverView {
        GutterObserverView()
    }

    func updateNSView(_ nsView: GutterObserverView, context: Context) {
        nsView.updateGutter()
    }
}

final class GutterObserverView: NSView {
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: window,
                                                queue: .main) { [weak self] _ in
                self?.updateGutter()
            })
        }
        // SourceEditor baut den Gutter einen Runloop-Tick nach seiner SwiftUI-
        // Hülle. Der verzögerte Pass erfasst auch diesen initialen Aufbau.
        DispatchQueue.main.async { [weak self] in self?.updateGutter() }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func updateGutter() {
        guard let window, let root = window.contentView else { return }
        GutterDimming.apply(in: root, windowIsKey: window.isKeyWindow)
    }
}
