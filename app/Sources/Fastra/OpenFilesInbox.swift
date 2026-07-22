// OpenFilesInbox.swift
//
// Kleiner, puffernder Eingangskorb für Datei-URLs, die per Finder-Doppelklick
// oder `open -a Fastra <datei>` über `application(_:open:)` hereinkommen.
//
// Warum überhaupt puffern? Beim KALTEN Start (App ist noch nicht offen, der
// Nutzer öffnet eine Datei aus dem Finder) ruft AppKit `application(_:open:)`
// auf, BEVOR die SwiftUI-Szene ihren `Workspace` (`@StateObject`) erzeugt hat
// — `Workspace.shared` ist dann noch `nil`. Die URLs würden verpuffen. Also
// sammeln wir sie hier und liefern sie aus, sobald der Workspace bereit ist
// (`Workspace.init` ruft den Flush an). Im WARMEN Fall (App läuft schon) ist
// der Workspace längst da → sofortige Auslieferung.
//
// Pure Logik (kein AppKit) → unit-testbar.

import Foundation

struct OpenFilesInbox {
    /// Noch nicht ausgelieferte URLs, in Ankunfts-Reihenfolge.
    private(set) var pending: [URL] = []
    /// `Workspace.shared` existiert im SwiftUI-Kaltstart früher als das
    /// zugehörige Fenster. Deshalb ist erst das Ende von
    /// `applicationDidFinishLaunching` die belastbare Grenze zwischen Kalt-
    /// und Warmstart — nicht die bloße Existenz eines Workspace.
    private(set) var launchDidFinish = false

    /// Nimmt externe Open-URLs entgegen. Während des Kaltstarts bleiben sie im
    /// Puffer; danach liefert die Funktion sie dem Aufrufer zur sofortigen
    /// Verarbeitung zurück. So können Sitzungsrestore und Finder-Öffnen nicht
    /// gleichzeitig um noch unfertige Fenster konkurrieren.
    mutating func receive(_ urls: [URL]) -> [URL] {
        guard !launchDidFinish else { return urls }
        pending.append(contentsOf: urls)
        return []
    }

    /// Schließt die Kaltstartphase genau einmal ab. Gepufferte URLs bleiben bis
    /// zum `drain()` erhalten, weil das SwiftUI-Fenster unter Umständen erst im
    /// nächsten Main-Runloop in der Fenster-Registry steht.
    mutating func finishLaunching() {
        launchDidFinish = true
    }

    /// Gibt alle gepufferten URLs zurück UND leert den Puffer. Der Aufrufer
    /// lädt die zurückgegebenen URLs; ein zweiter `drain()` liefert leer.
    mutating func drain() -> [URL] {
        let out = pending
        pending = []
        return out
    }
}
