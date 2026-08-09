// TestWaiting.swift
//
// Signalfreundliches Warten für async-Tests. Bewusst mit echten
// Schlafpausen statt `Task.yield()`: Eine Yield-Schleife dreht frei und
// kann unter Fremdlast genau die Main-Actor-Arbeit verhungern lassen, auf
// die sie wartet — der wahrscheinlichste Kandidat für sporadische Hänger
// (Roadmap „Bekannte Fehler", umgestellt im Review-Nachgang 2026-08-02).

import Foundation

/// Wartet, bis `condition` wahr wird oder die Frist reißt.
/// Rückgabe: `true`, wenn die Bedingung eingetreten ist.
@MainActor
@discardableResult
func waitUntil(timeout seconds: TimeInterval = 5,
               _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        guard Date() < deadline else { return false }
        // 10 ms echte Pause: gibt den Main-Actor frei, statt ihn zu belegen.
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}
