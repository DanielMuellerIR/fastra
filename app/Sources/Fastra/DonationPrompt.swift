// DonationPrompt.swift
//
// Unaufdringlicher Spendenaufruf für Fastra (Donationware-Modell).
//
// Aufbau:
//  • `DonationPrompt` — purer Logik-Enum (testbar, kein UI/AppKit).
//    Entscheidet wann der Banner sichtbar sein soll und verwaltet
//    den UserDefaults-Zustand.
//  • `DonationBannerView` — schmale Banner-View, die der Hauptthread
//    am unteren Fensterrand einblendet.
//
// Konzept: KEIN Modal, KEIN Nag-Screen.
// Der Banner erscheint erst ab dem 10. Start; nach einem Dismiss
// erst wieder nach 90 Tagen. So bleibt die App nutzbar ohne Druck.

import AppKit
import SwiftUI

// MARK: - Logik

/// Reine, zustandslose Logik für den Spenden-Banner.
/// Alle Funktionen sind ohne AppKit/SwiftUI testbar.
enum DonationPrompt {

    // MARK: Konstanten

    /// HAUPTSCHALTER (Daniel, 2026-07-10): Spendenaufruf vorerst AUS —
    /// ob der Button in der Release-Version bleibt, entscheidet Daniel
    /// kurz vor Release. Zum Reaktivieren auf `true` setzen; Logik,
    /// Banner-View, Zähler und Tests bleiben vollständig funktionsfähig
    /// (der Start-Zähler läuft auch bei AUS weiter, damit der Banner nach
    /// einem Einschalten sofort die echte Historie kennt). Geprüft wird
    /// der Schalter an der Anzeige-Stelle (ContentView), damit die pure
    /// Regel-Logik in `shouldShow` testbar bleibt.
    static let isEnabled = false

    /// URL zur Spenden-Seite.
    /// PLATZHALTER — wird vor dem Release durch die echte URL ersetzt.
    static let donationURL = URL(string: "https://example.org/fastra-donate")!

    /// Anzahl Starts, ab der der Banner erstmals erscheinen darf.
    static let minimumLaunchCount = 10

    /// Anzahl Tage Ruhe nach einem Dismiss.
    static let dismissCooldownDays = 90

    // MARK: UserDefaults-Keys

    /// Präfix für alle Fastra-Donation-Keys in UserDefaults.
    private static let keyLaunchCount  = "fastra.donation.launchCount"
    private static let keyDismissedAt  = "fastra.donation.dismissedAt"

    // MARK: Puren Logik-Entscheid

    /// Gibt zurück, ob der Banner jetzt angezeigt werden soll.
    ///
    /// Regeln:
    /// 1. Erst ab dem `minimumLaunchCount`-ten Start.
    /// 2. Nach einem Dismiss mindestens `dismissCooldownDays` Tage Pause.
    /// 3. Sonst: ja.
    ///
    /// - Parameters:
    ///   - launchCount:   Anzahl bisheriger App-Starts (nach Hochzählen
    ///                    für den aktuellen Start).
    ///   - dismissedAt:   Zeitstempel des letzten Dismiss (nil = nie).
    ///   - now:           Aktueller Zeitpunkt (injizierbar für Tests).
    static func shouldShow(
        launchCount: Int,
        dismissedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        // Regel 1: zu wenig Starts.
        guard launchCount >= minimumLaunchCount else { return false }

        // Regel 2: Cooldown nach Dismiss. `<=` bewusst: Bei EXAKT 90 Tagen
        // gilt der Cooldown noch (konservative Grenze — lieber einen Tick
        // länger still als einen Tick zu früh aufdringlich).
        if let dismissed = dismissedAt {
            let secondsCooldown = TimeInterval(dismissCooldownDays * 24 * 60 * 60)
            if now.timeIntervalSince(dismissed) <= secondsCooldown {
                return false
            }
        }

        return true
    }

    // MARK: UserDefaults-Wrapper

    /// Aktuellen Zustand aus UserDefaults lesen.
    ///
    /// - Parameter defaults: Injizierbar; Default ist `.standard`.
    static func currentState(
        defaults: UserDefaults = .standard
    ) -> (launchCount: Int, dismissedAt: Date?) {
        let count = defaults.integer(forKey: keyLaunchCount)
        // `double(forKey:)` liefert 0.0, wenn der Key fehlt → nil.
        let ts = defaults.double(forKey: keyDismissedAt)
        let dismissed: Date? = ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        return (launchCount: count, dismissedAt: dismissed)
    }

    /// Start-Zähler um 1 erhöhen und zurückschreiben.
    ///
    /// - Parameter defaults: Injizierbar; Default ist `.standard`.
    /// - Returns: Neuer Stand (nach Hochzählen).
    @discardableResult
    static func recordLaunch(defaults: UserDefaults = .standard) -> Int {
        let newCount = defaults.integer(forKey: keyLaunchCount) + 1
        defaults.set(newCount, forKey: keyLaunchCount)
        return newCount
    }

    /// Dismiss-Zeitstempel auf `Date()` setzen.
    ///
    /// - Parameter defaults: Injizierbar; Default ist `.standard`.
    static func recordDismiss(defaults: UserDefaults = .standard) {
        defaults.set(Date().timeIntervalSince1970, forKey: keyDismissedAt)
    }
}

// MARK: - Banner-View

/// Schmaler Spenden-Banner für den unteren Rand des Hauptfensters.
///
/// Verwendung:
/// ```swift
/// if showDonationBanner {
///     DonationBannerView {
///         showDonationBanner = false
///         DonationPrompt.recordDismiss()
///     }
/// }
/// ```
struct DonationBannerView: View {

    /// Callback, der beim Tippen auf „Später" aufgerufen wird.
    /// Der Aufrufer ist verantwortlich für `DonationPrompt.recordDismiss()`.
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {

            // --- Informationstext ---
            Text("Fastra ist Donationware — wenn es dir hilft, freut sich der Entwickler über eine Spende.")
                .font(Theme.uiSmall)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            // --- Spenden-Button ---
            Button("Spenden…") {
                // URL im Standard-Browser öffnen.
                NSWorkspace.shared.open(DonationPrompt.donationURL)
            }
            .font(Theme.uiSmall)
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)

            // --- Später-Button ---
            Button("Später") {
                onDismiss()
            }
            .font(Theme.uiSmall)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.surfaceSand)
        // Dezente Trennlinie nach oben.
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Theme.stroke),
            alignment: .top
        )
    }
}
