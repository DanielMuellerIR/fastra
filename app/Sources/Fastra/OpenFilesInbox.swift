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

    /// Hängt neue URLs hinten an (Reihenfolge bleibt erhalten).
    mutating func enqueue(_ urls: [URL]) {
        pending.append(contentsOf: urls)
    }

    /// Gibt alle gepufferten URLs zurück UND leert den Puffer. Der Aufrufer
    /// lädt die zurückgegebenen URLs; ein zweiter `drain()` liefert leer.
    mutating func drain() -> [URL] {
        let out = pending
        pending = []
        return out
    }
}
