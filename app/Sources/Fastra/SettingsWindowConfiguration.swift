import AppKit
import SwiftUI

/// Konfiguriert nur das native Settings-Fenster. `Settings` ignoriert bei
/// wiederhergestellten Fenstern SwiftUI-Idealgrößen häufig; deshalb setzen wir
/// die erste sichtbare Größe und erlauben danach normales manuelles Resizing.
struct SettingsWindowConfiguration: NSViewRepresentable {
    let preferredContentSize: NSSize
    let minimumContentSize: NSSize

    func makeNSView(context: Context) -> SettingsWindowProbe {
        let view = SettingsWindowProbe()
        view.configure = { window in
            window.styleMask.insert(.resizable)
            window.minSize = minimumContentSize
            if window.contentView?.bounds.height ?? 0 < preferredContentSize.height {
                window.setContentSize(preferredContentSize)
            }
        }
        return view
    }

    func updateNSView(_ nsView: SettingsWindowProbe, context: Context) { }
}

final class SettingsWindowProbe: NSView {
    var configure: ((NSWindow) -> Void)?
    private var didConfigure = false
    private var closeKeyMonitor: Any?

    deinit {
        if let closeKeyMonitor { NSEvent.removeMonitor(closeKeyMonitor) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didConfigure, let window else { return }
        didConfigure = true
        // Der nächste Main-Runloop hat die endgültige Settings-Content-View.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.configure?(window)
            self.installCloseShortcut(for: window)
        }
    }

    /// SwiftUIs Settings-Scene reicht ⌘W nicht zuverlässig an den eigenen
    /// NSWindow-Responder weiter. Der Monitor gilt ausschließlich, solange
    /// genau dieses Einstellungsfenster Key-Window ist.
    private func installCloseShortcut(for window: NSWindow) {
        guard closeKeyMonitor == nil else { return }
        closeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard window?.isKeyWindow == true,
                  modifiers == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "w" else { return event }
            window?.performClose(nil)
            return nil
        }
    }
}
