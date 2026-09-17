// TestSuiteDefaults.swift
//
// Zentrale Anlage von Test-Preferences-Suiten. Jede über diesen Helfer
// angelegte Suite ist beim Start garantiert leer, und am Prozessende räumt
// ein einmalig registrierter atexit-Hook ALLE Test-Domains wieder ab —
// einschließlich der Reste früherer (auch abgestürzter) Läufe. Übrig
// bleibende Test-Domains werden als Warnung gemeldet (Roadmap 2026-07-28:
// 3713 liegengebliebene Test-Plists brachten cfprefsd aus dem Tritt).

import Foundation
import Testing
@testable import Fastra

/// Der Rumpf des atexit-Hooks als gewöhnlich aufrufbare Funktion. Ein
/// atexit-Handler läuft ausschließlich beim echten Prozessende und ließ sich
/// im laufenden Testprozess deshalb überhaupt nicht prüfen. Die drei
/// Abhängigkeiten sind darum austauschbar: Der Test übergibt eine
/// Attrappen-Registry und fängt die Warnung ab, statt das echte
/// `purgeRegistered()` mitten im parallelen Lauf alle Suiten abräumen zu
/// lassen (Review-Hinweis 2026-09-17).
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
/// Entfernt wird REGISTRY-genau (nur die eigenen Suiten dieses Prozesses) —
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
        // Die Suite ist dann ÜBERHAUPT nicht angemeldet, auch nicht
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
