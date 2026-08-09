// TestSuiteDefaults.swift
//
// Zentrale Anlage von Test-Preferences-Suiten. Jede über diesen Helfer
// angelegte Suite ist beim Start garantiert leer, und am Prozessende räumt
// ein einmalig registrierter atexit-Hook ALLE Test-Domains wieder ab —
// einschließlich der Reste früherer (auch abgestürzter) Läufe. Übrig
// bleibende Test-Domains werden als Warnung gemeldet (Roadmap 2026-07-28:
// 3713 liegengebliebene Test-Plists brachten cfprefsd aus dem Tritt).

import Foundation
@testable import Fastra

/// Einmalige atexit-Registrierung; ausgelöst beim ersten Suite-Aufbau.
/// Entfernt wird REGISTRY-genau (nur die eigenen Suiten dieses Prozesses) —
/// ein parallel laufender zweiter Testprozess behält seine aktiven Suiten.
private let installTestDefaultsPurge: Void = {
    atexit {
        let remaining = TestDefaultsPurge.purgeRegistered()
        if !remaining.isEmpty {
            FileHandle.standardError.write(Data(
                ("WARNUNG: Test-Preferences-Domains blieben übrig: "
                    + remaining.joined(separator: ", ") + "\n").utf8))
        }
        // Zusätzlich die Reste früherer, abgestürzter Läufe (älter als eine
        // Stunde — aktive Suiten paralleler Prozesse bleiben unberührt).
        TestDefaultsPurge.purgeStale()
    }
}()

/// Legt eine frische, leere Test-Suite an und merkt sie zum Abräumen am
/// Prozessende vor. Der Name sollte unter einem der Präfixe aus
/// `TestDefaultsPurge.prefixes` liegen und eine UUID enthalten — dann räumt
/// der Stale-Aufräumer auch die Reste eines abgestürzten Laufs weg.
func testSuiteDefaults(named name: String) -> UserDefaults {
    _ = installTestDefaultsPurge
    TestDefaultsPurge.register(name)
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}
