// DiffTabState.swift
//
// Zusammengehörige Felder eines Vergleichs-Tabs. Dokument und
// Ladegeneration gehören zum Auftrag; ohne Auftrag ist kein Dokument
// speicherbar. `EditorTab` stellt `fileDiffRequest`, `fileDiffDocument`,
// `gitDiffRequest` und `gitDiffDocument` als berechnete Nur-Lese-Eigenschaften
// bereit.

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
    var pendingTransferID: UUID?
    var transferError: String?

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
