// SearchRunnerTests.swift
//
// Sichert die pure Entscheidungs-Logik des `SearchRunner` ab — die Teile,
// die OHNE Combine/Async testbar sind. Hintergrund: Der Ordner-Scope darf
// NICHT live mit jedem Tastendruck suchen (Suchmasken-Konzept Abschnitt C),
// sonst friert die App bei großen Ordnern ein. Diese Regel lebt in der
// statischen `runsLive(for:)`-Funktion und wird hier festgenagelt, damit
// ein versehentliches „Ordner doch wieder live" als roter Test auffällt.

import Testing
import Foundation
@testable import Fastra

@Test("Nur die aktuelle Buffer-Laufgeneration darf Ergebnisse publizieren")
func bufferCompletionRequiresCurrentGeneration() {
    #expect(SearchRunner.completionBelongsToCurrentRun(8, currentRunID: 8))
    #expect(!SearchRunner.completionBelongsToCurrentRun(7, currentRunID: 8))
}

@Test("Projektfilter-Wechsel invalidiert Treffer, Navigation und Apply sofort")
@MainActor
func projectFilterChangeInvalidatesVisiblePreviewImmediately() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("fastra-runner-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let suiteName = "fastra-runner-defaults-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let workspace = Workspace(defaults: defaults)
    workspace.openProject(at: root)
    workspace.scope = .project
    workspace.findPattern = "NADEL"

    // Initiale Combine-Läufe vollständig ablaufen lassen. Erst danach wird
    // eine bewusst alte, sichtbare Vorschau eingesetzt.
    try await Task.sleep(for: .milliseconds(550))
    let options = workspace.currentSearchOptions
    let match = try #require(BufferSearch.find(
        in: "NADEL", options: options
    ).matches.first)
    workspace.folderResults = [FolderSearch.PerFileResult(
        url: root.appendingPathComponent("alt.txt"),
        matches: [match],
        totalMatches: 1,
        skipped: nil,
        snapshot: nil,
        searchOptions: options
    )]
    workspace.folderTotalMatches = 1
    workspace.folderResultsWereCapped = true
    var previewConflictWasShown = false
    workspace.folderPreviewConflictHandler = { _ in
        previewConflictWasShown = true
    }

    var config = workspace.projectSearchConfiguration
    config.fileTypeFilter = config.fileTypeFilter == .all ? .knownText : .all
    workspace.projectSearchConfiguration = config

    // Diese Aussagen gelten synchron beim Inputwechsel, noch vor dem
    // 120-ms- und 300-ms-Debounce. Alte Treffer dürfen in diesem Fenster
    // weder sichtbar noch navigierbar/anwendbar bleiben.
    #expect(workspace.folderResults.isEmpty)
    #expect(workspace.folderTotalMatches == 0)
    #expect(!workspace.folderResultsWereCapped)
    #expect(workspace.navMatches.isEmpty)
    #expect(workspace.folderSearching)
    #expect(!workspace.applyAllInFolder())
    #expect(!previewConflictWasShown)
}

// MARK: - runsLive: welcher Scope sucht beim Tippen sofort?

@Test("Datei-Scope sucht live")
func runsLive_fileIsLive() {
    #expect(SearchRunner.runsLive(for: .file) == true)
}

@Test("Geöffnet-Scope sucht live")
func runsLive_openIsLive() {
    #expect(SearchRunner.runsLive(for: .open) == true)
}

@Test("Ordner-Scope sucht NICHT bedingungslos live (gesteuert über Mindestlänge)")
func runsLive_folderIsNotLive() {
    #expect(SearchRunner.runsLive(for: .folder) == false)
}

// MARK: - shouldRunFolderLive: Mindestlänge-Schwelle für Live-Ordner-Suche

@Test("Ordner-Live: leeres/kurzes Pattern (<3 Zeichen) sucht NICHT live")
func folderLive_shortPatternNotLive() {
    #expect(SearchRunner.shouldRunFolderLive(for: "") == false)
    #expect(SearchRunner.shouldRunFolderLive(for: "ab") == false)
}

@Test("Ordner-Live: ab 3 Zeichen sucht live")
func folderLive_atThresholdIsLive() {
    #expect(SearchRunner.shouldRunFolderLive(for: "abc") == true)
    #expect(SearchRunner.shouldRunFolderLive(for: "Daniel") == true)
}

@Test("Ordner-Live: führender/abschließender Whitespace zählt nicht zur Länge")
func folderLive_whitespaceTrimmed() {
    #expect(SearchRunner.shouldRunFolderLive(for: "  a  ") == false)
    #expect(SearchRunner.shouldRunFolderLive(for: "  abc  ") == true)
}

// MARK: - validationError: roter Fehlerstreifen-Text

@Test("Leeres Pattern gilt als gültig (kein Fehler)")
func validationError_emptyIsNil() {
    let opts = SearchOptions(find: "", replace: "x")
    #expect(SearchRunner.validationError(for: opts) == nil)
}

@Test("Gültiges Pattern liefert keinen Fehler")
func validationError_validIsNil() {
    let opts = SearchOptions(find: "[a-z]+\\d*", replace: "x", isRegex: true)
    #expect(SearchRunner.validationError(for: opts) == nil)
}

@Test("Ungültiges Pattern liefert eine Fehlermeldung")
func validationError_invalidReturnsMessage() {
    // Unbalancierte Zeichenklasse — NSRegularExpression lehnt das ab.
    let opts = SearchOptions(find: "[unbalanced", replace: "x", isRegex: true)
    #expect(SearchRunner.validationError(for: opts) != nil)
}

@Test("Plain-Text-Modus: Sonderzeichen sind nie ein Pattern-Fehler")
func validationError_plainTextNeverInvalid() {
    // „[" ist als RegEx kaputt, im Plain-Modus aber nur ein Zeichen.
    let opts = SearchOptions(find: "[unbalanced", replace: "x", isRegex: false)
    #expect(SearchRunner.validationError(for: opts) == nil)
}
