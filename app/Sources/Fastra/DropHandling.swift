// DropHandling.swift
//
// Reine (UI-freie) Entscheidungs-Logik fürs Datei-Drag&Drop in den Editor.
// Nach dem Muster von KeyRouting: die Entscheidung „welche gedroppten URLs
// dürfen in einen Tab geladen werden" liegt als pure Funktion hier und ist
// in `DropHandlingTests` abgedeckt. Das eigentliche Laden (`loadFile`) und
// das SwiftUI-`onDrop` bleiben dünner Glue in `EditorView`.

import Foundation

enum DropHandling {
    /// Filtert eine Liste gedroppter URLs auf das, was sich sinnvoll in
    /// einen Editor-Tab laden lässt: existierende, reguläre Dateien.
    ///
    /// - Verzeichnisse werden verworfen (Ordner-Suche läuft über die Maske,
    ///   nicht über Drop in den Editor).
    /// - Nicht-existierende Pfade werden verworfen.
    /// - Duplikate werden entfernt, die ursprüngliche Reihenfolge bleibt.
    ///
    /// Bewusst KEIN Textdatei-Filter: `loadFile` versucht jede Datei zu
    /// öffnen und gibt bei echtem Binärmüll ein akustisches Signal — der
    /// Nutzer entscheidet, was er droppt. (Eine Binär-Heuristik wie beim
    /// Ordner-Scan wäre hier eher bevormundend.)
    static func loadableFiles(from urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            let standardized = url.standardizedFileURL
            guard !seen.contains(standardized) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: standardized.path, isDirectory: &isDir),
                  !isDir.boolValue else { continue }
            seen.insert(standardized)
            out.append(url)
        }
        return out
    }
}
