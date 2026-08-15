import AppKit
import SwiftUI

/// Konfiguriert nur das native Settings-Fenster. `Settings` ignoriert bei
/// wiederhergestellten Fenstern SwiftUI-Idealgrößen häufig; deshalb setzen wir
/// die erste sichtbare Größe und erlauben danach normales manuelles Resizing.
struct SettingsWindowConfiguration: NSViewRepresentable {
    static let windowIdentifier = NSUserInterfaceItemIdentifier(
        "Fastra.SettingsWindow"
    )

    static func isSettingsWindow(_ candidate: NSWindow?) -> Bool {
        candidate?.identifier == windowIdentifier
    }

    let preferredContentSize: NSSize
    let minimumContentSize: NSSize

    func makeNSView(context: Context) -> SettingsWindowProbe {
        let view = SettingsWindowProbe()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: SettingsWindowProbe, context: Context) {
        apply(to: nsView)
    }

    /// Hält auch ein bereits geöffnetes Einstellungsfenster auf dem aktuellen
    /// Skalierungswert. Die bevorzugte Größe gilt weiterhin nur beim ersten
    /// Öffnen, damit ein späteres SwiftUI-Update manuelles Resizing nicht
    /// rückgängig macht.
    func apply(to view: SettingsWindowProbe) {
        let sizing = SettingsWindowSizing(
            preferredContentSize: preferredContentSize,
            minimumContentSize: minimumContentSize
        )
        view.configure = { window in
            window.identifier = Self.windowIdentifier
            window.styleMask.insert(.resizable)
            sizing.apply(to: window, resizeToPreferred: true)
        }
        view.updateSizing(sizing)
    }
}

/// Kleine Schnittstelle, damit die Fenstergrößenregel ohne ein echtes
/// AppKit-Fenster und dessen prozessweite Zustände getestet werden kann.
protocol SettingsWindowSizingTarget: AnyObject {
    var fastraCurrentContentSize: NSSize { get }
    func fastraSetContentSize(_ size: NSSize)
    func fastraSetMinimumContentSize(_ size: NSSize)
}

struct SettingsWindowSizing {
    let preferredContentSize: NSSize
    let minimumContentSize: NSSize

    func apply(
        to target: SettingsWindowSizingTarget,
        resizeToPreferred: Bool
    ) {
        target.fastraSetMinimumContentSize(minimumContentSize)
        if resizeToPreferred,
           target.fastraCurrentContentSize.height < preferredContentSize.height {
            target.fastraSetContentSize(preferredContentSize)
        }
    }
}

extension NSWindow: SettingsWindowSizingTarget {
    var fastraCurrentContentSize: NSSize {
        contentView?.bounds.size ?? .zero
    }

    func fastraSetContentSize(_ size: NSSize) {
        setContentSize(size)
    }

    func fastraSetMinimumContentSize(_ size: NSSize) {
        contentMinSize = size
    }
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

    func updateSizing(_ sizing: SettingsWindowSizing) {
        guard let window else { return }
        sizing.apply(to: window, resizeToPreferred: false)
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
