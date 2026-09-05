// DiffTabState.swift
//
// Zusammengehörige Felder eines Vergleichs-Tabs als kleine Typen
// (Folgeauftrag „EditorTab-Felder bündeln", 2026-09-05, kleinste Etappe).
//
// Vorher trug `EditorTab` für den Datei-Vergleich drei lose Optionale
// (`fileDiffRequest`, `fileDiffDocument`, `fileDiffLoadGeneration`) und für
// den Git-Diff zwei (`gitDiffRequest`, `gitDiffDocument`). Ein Dokument ohne
// Auftrag oder eine Generation ohne Auftrag war damit als Zustand
// darstellbar, auch wenn ihn nie jemand herstellen sollte. Hier hängt das
// Dokument AM Auftrag: Ohne Auftrag gibt es beim Kompilieren keinen Platz für
// ein Dokument. Workspace und Ansichten lesen weiter `fileDiffRequest`,
// `fileDiffDocument`, `gitDiffRequest` und `gitDiffDocument` — als
// berechnete Nur-Lese-Eigenschaften auf `EditorTab`.

import Foundation

/// Zustand eines Datei-Vergleichs-Tabs: Auftrag, sein (noch fehlendes)
/// Ergebnis und die Generation, die verspätete Ergebnisse entwertet.
struct FileDiffTabState: Hashable {
    let request: FileDiffRequest
    /// `nil` = Berechnung läuft noch (Ansicht zeigt einen Spinner).
    var document: FileDiffDocument?
    /// Jede Neuberechnung desselben Tabs erhöht diesen Wert. Nur die
    /// Completion derselben Generation darf den Tab noch verändern.
    private(set) var loadGeneration: UInt64

    init(request: FileDiffRequest) {
        self.request = request
        self.document = nil
        self.loadGeneration = 0
    }

    private init(request: FileDiffRequest, loadGeneration: UInt64) {
        self.request = request
        self.document = nil
        self.loadGeneration = loadGeneration
    }

    /// Derselbe Tab rechnet mit einem neuen Auftrag frisch: Ergebnis weg,
    /// Generation hoch — genau die drei Schritte, die vorher einzeln an
    /// drei Feldern passierten.
    func restarted(with request: FileDiffRequest) -> FileDiffTabState {
        FileDiffTabState(request: request, loadGeneration: loadGeneration &+ 1)
    }
}

/// Zustand eines strukturierten Git-Diff-Tabs: Auftrag plus (noch fehlendes)
/// Dokument. Der Unified-Fallback für Verlauf/Commit-Metadaten hat keinen
/// Auftrag — und damit auch keinen Platz für ein Dokument.
struct GitDiffTabState: Hashable {
    let request: GitDiffRequest
    /// `nil` = Laden läuft noch.
    var document: GitDiffDocument?

    init(request: GitDiffRequest, document: GitDiffDocument? = nil) {
        self.request = request
        self.document = document
    }
}
