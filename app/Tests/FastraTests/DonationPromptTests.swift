import Foundation
import Testing
@testable import Fastra

// Tests für die Spenden-Banner-Logik in `DonationPrompt`.
//
// Alle Tests nutzen eine eigene UserDefaults-Suite (eindeutiger Name
// pro Test) statt `.standard` — sonst beeinflussen sich Tests oder
// echte App-Daten gegenseitig.
//
// Muster folgt FirstLaunchTests.swift.

/// Frische, isolierte UserDefaults-Suite für genau einen Test.
/// Der Aufrufer räumt sie via `removePersistentDomain` wieder ab.
private func makeFreshDefaults() -> (UserDefaults, suiteName: String) {
    let suiteName = "fastra-test-donation-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
}

// MARK: - shouldShow-Logik

@Test("shouldShow: unter 10 Starts → false")
func shouldShow_unterMinimum_nein() {
    // Erst ab Start 10 darf der Banner erscheinen.
    for count in 0 ..< DonationPrompt.minimumLaunchCount {
        #expect(
            DonationPrompt.shouldShow(launchCount: count, dismissedAt: nil) == false,
            "Bei launchCount=\(count) soll shouldShow false sein"
        )
    }
}

@Test("shouldShow: ab 10 Starts ohne Dismiss → true")
func shouldShow_abMinimum_nein() {
    #expect(
        DonationPrompt.shouldShow(
            launchCount: DonationPrompt.minimumLaunchCount,
            dismissedAt: nil
        ) == true
    )
    // Auch deutlich mehr Starts.
    #expect(
        DonationPrompt.shouldShow(launchCount: 100, dismissedAt: nil) == true
    )
}

@Test("shouldShow: frisch dismissed (1 Sekunde alt) → false")
func shouldShow_frischDismissed_nein() {
    let now = Date()
    // Dismiss gerade eben (1 Sekunde vor now).
    let dismissed = now.addingTimeInterval(-1)
    #expect(
        DonationPrompt.shouldShow(launchCount: 50, dismissedAt: dismissed, now: now) == false
    )
}

@Test("shouldShow: nach 91 Tagen wieder → true")
func shouldShow_nach91Tagen_ja() {
    let now = Date()
    // Dismiss war genau 91 Tage vor now.
    let dismissed = now.addingTimeInterval(-91 * 24 * 60 * 60)
    #expect(
        DonationPrompt.shouldShow(launchCount: 50, dismissedAt: dismissed, now: now) == true
    )
}

@Test("shouldShow: Grenzfall exakt 90 Tage → false (Cooldown noch aktiv)")
func shouldShow_grenzfall90Tage_nein() {
    let now = Date()
    // Exakt 90 Tage sind noch NICHT abgelaufen — erst nach 90*24*60*60
    // Sekunden PLUS mindestens einer weiteren Sekunde würde der Cooldown enden.
    let dismissed = now.addingTimeInterval(-90 * 24 * 60 * 60)
    // Zeitintervall ist exakt cooldownDays Sekunden → noch nicht abgelaufen.
    #expect(
        DonationPrompt.shouldShow(launchCount: 50, dismissedAt: dismissed, now: now) == false
    )
}

// MARK: - UserDefaults-Roundtrip

@Test("UserDefaults-Roundtrip: recordLaunch + recordDismiss + currentState")
func userDefaults_roundtrip() {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    // Frischer Zustand: keine Daten.
    let initial = DonationPrompt.currentState(defaults: defaults)
    #expect(initial.launchCount == 0)
    #expect(initial.dismissedAt == nil)

    // Start hochzählen.
    let afterFirst = DonationPrompt.recordLaunch(defaults: defaults)
    #expect(afterFirst == 1)
    #expect(DonationPrompt.currentState(defaults: defaults).launchCount == 1)

    // Mehrmals zählen.
    for _ in 2 ... 12 {
        DonationPrompt.recordLaunch(defaults: defaults)
    }
    #expect(DonationPrompt.currentState(defaults: defaults).launchCount == 12)

    // Dismiss aufzeichnen — Zeitstempel muss ungefähr jetzt sein
    // (Toleranz nach oben: 2 s Testlaufzeit).
    //
    // Toleranz nach UNTEN (war Flaky, ~1 von 4 Läufen): `Date` rechnet
    // intern seit 2001; `timeIntervalSince1970` addiert die Epochen-
    // Differenz und rundet dabei auf Double-Granularität (~120 ns bei
    // dieser Größenordnung). Das gespeicherte Datum kann dadurch eine
    // Rundungsstufe VOR `beforeDismiss` liegen (gemessen: exakt
    // -1.19e-07 s in ~25 % von 50.000 Iterationen). 1 ms Schlupf fängt
    // das ab, ohne echte Fehler (falsche Einheit, 0-Wert) zu maskieren.
    let beforeDismiss = Date()
    DonationPrompt.recordDismiss(defaults: defaults)
    let afterDismiss = DonationPrompt.currentState(defaults: defaults)
    #expect(afterDismiss.dismissedAt != nil)
    let delta = afterDismiss.dismissedAt!.timeIntervalSince(beforeDismiss)
    #expect(delta > -0.001 && delta < 2)
}
