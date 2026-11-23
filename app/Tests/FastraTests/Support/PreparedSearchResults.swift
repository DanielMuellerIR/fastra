import Foundation
@testable import Fastra

/// Fensterlose Fixtures benennen ihr Ziel ausdrücklich; Produktläufe benötigen
/// weiterhin ein registriertes Dokumentfenster.
@MainActor
func bindSearchResultWindowForTesting(_ workspace: Workspace) {
    workspace.bindSearchResultsToTestWindow(UUID())
}

/// Veröffentlicht die fachlich vorbereiteten Ergebnisdaten über denselben
/// Begin-/Commit-Eingang wie der Runner. Caps, Fehler und fehlende Snapshots
/// bleiben dabei echte unvollständige Ergebnisse und erlauben kein Apply.
@MainActor
func publishPreparedSearchResults(_ workspace: Workspace, error: String? = nil) {
    if CommandTargeting.registeredWindow(for: workspace) == nil {
        bindSearchResultWindowForTesting(workspace)
    }
    guard let token = workspace.beginSearchResultRun() else { return }
    let publication: SearchResultPublication
    switch workspace.scope {
    case .file:
        publication = .buffer(.init(matches: workspace.bufferMatches,
            totalMatches: workspace.bufferTotalMatches, wasCapped: workspace.bufferResultsWereCapped,
            invalidPatternMessage: error))
    case .open:
        publication = .open(.init(perTab: workspace.openResults,
            totalMatches: workspace.openTotalMatches, wasCapped: workspace.openResultsWereCapped,
            invalidPatternMessage: error))
    case .folder, .project:
        let files = workspace.folderResults
        let selection = FolderSearch.SourceSelection(roots: files.map(\.url), filter: .all,
                                                      exclusions: [], projectRoot: nil)
        let textFiles = files.reduce(into: [URL: FileSnapshot]()) { snapshots, file in
            if file.skipped == nil { snapshots[file.url.canonicalFileURL] = file.snapshot }
        }
        let scannedBytes = files.compactMap(\.snapshot).reduce(UInt64(0)) { $0 + UInt64($1.byteCount) }
        let basis = FolderSearch.SourceBasis(selection: selection, textFiles: textFiles, scannedBytes: scannedBytes)
        publication = .folder(.init(perFile: files, invalidPatternMessage: error,
            wasCapped: workspace.folderResultsWereCapped, sourceBasis: basis))
    }
    _ = SearchRunner.publish(publication, for: token, in: workspace)
}
