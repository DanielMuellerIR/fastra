// TestSuiteDefaults.swift
//
// Zentrale Anlage leerer Test-Preferences-Suiten. Ein einmaliger atexit-Hook
// entfernt eigene Test-Domains sowie ausreichend alte Reste abgestürzter
// Läufe. Verbleibende Domains werden als Warnung gemeldet.

import Foundation
import Testing
@testable import Fastra

/// Aufrufbarer Rumpf des atexit-Hooks mit austauschbaren Abhängigkeiten.
/// Der Test verwendet eine Attrappen-Registry und erfasst Warnungen, ohne
/// Suiten parallel laufender Tests aus der echten Registry zu entfernen.
func runTestDefaultsExitCleanup(
    purgeRegistered: () -> [String] = { TestDefaultsPurge.purgeRegistered() },
    purgeStale: () -> Void = { _ = TestDefaultsPurge.purgeStale() },
    warn: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
) {
    let remaining = purgeRegistered()
    if !remaining.isEmpty {
        warn("WARNUNG: Test-Preferences-Domains blieben übrig: "
            + remaining.joined(separator: ", ") + "\n")
    }
    // Zusätzlich die Reste früherer, abgestürzter Läufe (älter als eine
    // Stunde — aktive Suiten paralleler Prozesse bleiben unberührt). Das läuft
    // auch dann, wenn oben schon etwas übrig blieb.
    purgeStale()
}

/// Einmalige atexit-Registrierung; ausgelöst beim ersten Suite-Aufbau.
/// Entfernt wird Registry-genau (nur die eigenen Suiten dieses Prozesses) —
/// ein parallel laufender zweiter Testprozess behält seine aktiven Suiten.
private let installTestDefaultsPurge: Void = {
    atexit { runTestDefaultsExitCleanup() }
}()

/// Legt eine frische, leere Test-Suite an und merkt sie zum Abräumen am
/// Prozessende vor. Der Name sollte unter einem der Präfixe aus
/// `TestDefaultsPurge.prefixes` liegen und eine UUID enthalten — dann räumt
/// der Stale-Aufräumer auch die Reste eines abgestürzten Laufs weg.
func testSuiteDefaults(named name: String) -> UserDefaults {
    _ = installTestDefaultsPurge
    if !TestDefaultsPurge.isTestDomain(name) {
        // Ganz anderer Fehler als ein misslungener Registry-Schreibvorgang:
        // Die Suite ist dann überhaupt nicht angemeldet, auch nicht
        // prozessintern, und ihre Plist überlebt den Lauf. Die alte, für beide
        // Fälle gleiche Meldung schickte die Diagnose zum äußeren Runner, wo
        // nichts kaputt ist.
        let message = "Suite-Name '\(name)' trägt kein Test-Präfix — sie wird "
            + "von keinem Aufräumer erfasst"
        Issue.record(Comment(rawValue: message))
    } else if !TestDefaultsPurge.register(name) {
        Issue.record("Test-Preferences-Suite ließ sich nicht beim äußeren Runner anmelden")
    }
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}
