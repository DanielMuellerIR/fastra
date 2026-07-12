// AboutWindow.swift
//
// Zeigt den „Über Fastra"-Dialog. Das Fenster ist klein, nicht
// skalierbar und zentriert. Beim zweiten Aufruf wird es nur nach
// vorne geholt statt neu erzeugt.
//
// Muster angelehnt an SearchPanelController, aber vereinfacht:
// kein Frame-Autosave, Schließen per rotem Punkt = wirklich schließen
// (kein Ausblenden; das Fenster ist jederzeit neu öffenbar).

import AppKit
import SwiftUI

// MARK: - Fenster-Controller

/// Einstiegspunkt: `AboutWindow.show()` öffnet (oder holt nach vorn)
/// den Über-Dialog.
enum AboutWindow {

    /// Schwache Referenz auf das laufende Fenster — `nil`, wenn es noch
    /// nie erzeugt oder inzwischen geschlossen wurde.
    private static weak var window: NSWindow?

    /// Über-Fenster öffnen. Beim ersten Aufruf wird es erzeugt; bei
    /// weiteren Aufrufen wird es nur nach vorn geholt.
    @MainActor
    static func show() {
        if let existing = window {
            // Fenster existiert noch — nach vorne bringen.
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: false)
            return
        }

        // Fenstergröße: ca. 320 × 420 pt, passend für Icon + Texte.
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
            styleMask: [.titled, .closable],   // bewusst KEIN .resizable
            backing: .buffered,
            defer: false
        )
        w.title = L10n.string("Über Fastra")
        w.titlebarAppearsTransparent = false
        w.isMovableByWindowBackground = true
        // Fenster wirklich freigeben, wenn es geschlossen wird —
        // `isReleasedWhenClosed` ist bei programmatisch erzeugten
        // NSWindows standardmäßig `true`, also explizit bestätigen.
        w.isReleasedWhenClosed = false   // wir halten die weak-Ref; ARC kümmert sich
        // codereview-ok: weak window → ARC gibt das Fenster nach Close frei, weak-Ref wird nil, nächster show() baut korrekt neu; kein Leak (2026-07-01)

        // SwiftUI-Inhalt einhängen.
        let host = NSHostingController(rootView: AboutView().fastraScalingRoot())
        w.contentViewController = host
        // Fenstergröße darf nicht geändert werden.
        w.contentMinSize = NSSize(width: 320, height: 420)
        w.contentMaxSize = NSSize(width: 320, height: 420)

        // Zentrieren (Systemkonvention für Info-Dialoge).
        w.center()

        // Keine eigene Appearance setzen — das Fenster erbt von
        // NSApp.appearance und folgt damit der Erscheinungsbild-
        // Einstellung (hell/dunkel/automatisch, siehe AppearanceSetting).

        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }
}

// MARK: - SwiftUI-Inhalt

/// Inhalt des Über-Dialogs: Icon, Name, Version, Tagline, Copyright.
private struct AboutView: View {

    /// Versionsnummer aus dem App-Bundle — zur Laufzeit gelesen,
    /// nicht hartkodiert (CFBundleShortVersionString).
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"
    }

    /// App-Icon des laufenden Prozesses.
    private var appIcon: NSImage {
        NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }

    var body: some View {
        VStack(spacing: 0) {

            // --- App-Icon ---
            // Großes Icon wie in Apples eigenen „Über"-Dialogen.
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .frame(width: 128, height: 128)
                .padding(.top, 32)

            // --- Name ---
            Text("Fastra")
                .fastraFont(size: 22, weight: .semibold, design: .default)
                .foregroundColor(Theme.textPrimary)
                .padding(.top, 16)

            // --- Version ---
            Text(verbatim: L10n.format("Version %@", appVersion))
                .fastraFont(.ui)
                .foregroundColor(Theme.textSecondary)
                .padding(.top, 4)

            // --- Tagline ---
            Text("Suchen & Ersetzen — einfach mit *,\nmächtig mit RegEx. Nativ für den Mac.")
                .fastraFont(.ui)
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
                .padding(.horizontal, 24)

            // --- Motto (dezent in Sekundärfarbe) ---
            Text("facillime ad astra")
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .padding(.top, 8)

            Spacer()

            // --- Copyright ---
            Text("© 2026 Daniel Müller")
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .padding(.bottom, 20)
        }
        // Hintergrundfarbe aus Theme — konsistent mit dem Rest der App.
        .frame(width: 320, height: 420)
        .background(Theme.surfaceBase)
    }
}
