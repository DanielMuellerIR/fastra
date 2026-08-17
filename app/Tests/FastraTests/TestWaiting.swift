// TestWaiting.swift
//
// Signalfreundliches Warten für async-Tests. Bewusst mit echten
// Schlafpausen statt `Task.yield()`: Eine Yield-Schleife dreht frei und
// kann unter Fremdlast genau die Main-Actor-Arbeit verhungern lassen, auf
// die sie wartet — der wahrscheinlichste Kandidat für sporadische Hänger
// (Roadmap „Bekannte Fehler", umgestellt im Review-Nachgang 2026-08-02).
//
// Die Frist misst bewusst NICHT die Wanduhrzeit, sondern nur die Zeit, in der
// diese Schleife wirklich an die Reihe kam. Grund, gemessen am 2026-08-17 im
// vollen parallelen Lauf: swift-testing führt alle Tests im selben Prozess
// nebenläufig aus, und sämtliche `@MainActor`-Tests teilen sich denselben
// einen Main-Actor. Ein einzelner schwerer Nachbar — etwa der Aufbau eines
// 4,36-MB-Editors — belegt ihn sekundenlang am Stück. Die 10-ms-Pause dieser
// Schleife wurde dabei einmal 6,98 s lang nicht bedient: Die komplette
// 5-Sekunden-Frist verstrich, ohne dass der Test auch nur ein einziges Mal
// nachsehen konnte, und er meldete einen Fehler, den es nicht gab. Losgelöste
// Hintergrundaufgaben liefen in derselben Messung binnen einer Millisekunde an
// — der Engpass war also allein der Main-Actor. Eine solche Pause gehört einem
// fremden Main-Actor-Halter und wird deshalb nur mit dem regulären
// Pausenanteil verrechnet. Ein echt hängendes Verhalten verbraucht die Frist
// dagegen unverändert, weil seine Durchläufe ganz normal laufen.

import Foundation

/// Wartet, bis `condition` wahr wird oder die Frist reißt.
/// Rückgabe: `true`, wenn die Bedingung eingetreten ist.
@MainActor
@discardableResult
func waitUntil(timeout seconds: TimeInterval = 5,
               _ condition: () -> Bool) async -> Bool {
    // 10 ms echte Pause: gibt den Main-Actor frei, statt ihn zu belegen.
    let pause: TimeInterval = 0.01
    // Höchstwert, den ein einzelner Durchlauf von der Frist abziehen darf.
    // Die Zugabe deckt normale Streuung ab; alles darüber ist Fremdlast.
    let maximumCountedGap = pause + 0.05
    let started = Date()
    // Harte Wanduhr-Grenze: Ein dauerhaft blockierter Main-Actor darf den
    // Testlauf nicht endlos aufhalten, auch wenn die Frist nie voll wird.
    let latestEnd = started.addingTimeInterval(seconds + 20)
    var observed: TimeInterval = 0
    var lastPoll = started
    while !condition() {
        let now = Date()
        observed += min(now.timeIntervalSince(lastPoll), maximumCountedGap)
        lastPoll = now
        guard observed < seconds, now < latestEnd else { return false }
        try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
    }
    return true
}
