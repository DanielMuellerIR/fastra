// ProjectStoreTests.swift
//
// Tests für „Zuletzt benutzte Projekte" (Projekt- & Git-Ausbau, Etappe 1) —
// reine Listen-Logik, JSON-Persistenz mit isolierter Suite und die
// Git-Repository-Erkennung über temporäre Ordner.

import Foundation
import Testing
@testable import Fastra

private func makeDefaults() -> UserDefaults {
    let suite = "fastra.tests.projects.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}

/// Legt einen frischen Temp-Ordner an und räumt ihn nach dem Test-Body ab.
private func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-projecttests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

// MARK: - Listen-Logik

@Test("Leere UserDefaults → leere Projekt-Liste")
func projects_emptyByDefault() {
    #expect(ProjectStore.load(from: makeDefaults()).isEmpty)
}

@Test("prepending: neues Projekt landet oben, Pfad tilde-abgekürzt")
func projects_prependsOnTopTildeAbbreviated() {
    let home = NSHomeDirectory()
    let result = ProjectStore.prepending("\(home)/git/fastra", to: [])
    #expect(result.count == 1)
    #expect(result.first?.path == "~/git/fastra")
    #expect(result.first?.name == "fastra")
}

@Test("prepending: vorhandenes Projekt wandert nach oben statt zu duplizieren")
func projects_movesExistingToTop() {
    let existing = [ProjectEntry(path: "~/git/a"), ProjectEntry(path: "~/git/b")]
    let result = ProjectStore.prepending("\(NSHomeDirectory())/git/b", to: existing)
    #expect(result.map(\.path) == ["~/git/b", "~/git/a"])
}

@Test("prepending: Liste wird auf max gekürzt (älteste fallen raus)")
func projects_capsAtMax() {
    let existing = (0..<12).map { ProjectEntry(path: "/p/repo\($0)") }
    let result = ProjectStore.prepending("/p/new", to: existing, max: 12)
    #expect(result.count == 12)
    #expect(result.first?.path == "/p/new")
    #expect(!result.map(\.path).contains("/p/repo11"))
}

@Test("save → load Roundtrip erhält Reihenfolge und Pfade")
func projects_roundtrip() {
    let d = makeDefaults()
    let entries = [ProjectEntry(path: "~/git/a"), ProjectEntry(path: "~/git/b")]
    ProjectStore.save(entries, to: d)
    #expect(ProjectStore.load(from: d).map(\.path) == ["~/git/a", "~/git/b"])
}

@Test("ProjectEntry: url expandiert Tilde, name ist letzter Pfadteil")
func projects_entryURLAndName() {
    let entry = ProjectEntry(path: "~/git/fastra")
    #expect(entry.url.path == "\(NSHomeDirectory())/git/fastra")
    #expect(entry.name == "fastra")
}

// MARK: - Git-Repository-Erkennung

@Test("repositoryRoot: Datei tief im Repo → Wurzelordner mit .git")
func repoRoot_findsRootFromNestedFile() throws {
    try withTempDir { dir in
        let repo = dir.appendingPathComponent("repo")
        let nested = repo.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("main.swift")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let root = ProjectStore.repositoryRoot(for: file)
        #expect(root?.path == repo.path)
    }
}

@Test("repositoryRoot: .git darf eine DATEI sein (git worktree)")
func repoRoot_acceptsGitFile() throws {
    try withTempDir { dir in
        let repo = dir.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "gitdir: /woanders/.git/worktrees/wt"
            .write(to: repo.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let root = ProjectStore.repositoryRoot(for: repo)
        #expect(root?.path == repo.path)
    }
}

@Test("repositoryRoot: ohne .git bis zur Wurzel → nil")
func repoRoot_nilWithoutGit() throws {
    try withTempDir { dir in
        let plain = dir.appendingPathComponent("plain/sub")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        // Temp-Verzeichnisse liegen außerhalb jedes Repos — aufwärts
        // darf nichts gefunden werden.
        #expect(ProjectStore.repositoryRoot(for: plain) == nil)
    }
}

@Test("repositoryRoot: nicht existierender Pfad → nil")
func repoRoot_nilForMissingPath() {
    let missing = URL(fileURLWithPath: "/definitiv/nicht/vorhanden/\(UUID().uuidString)")
    #expect(ProjectStore.repositoryRoot(for: missing) == nil)
}

// MARK: - URL-Kanonisierung

@Test("canonicalFileURL: konstruierte URL == Verzeichnis-Listing-Form (/var-Alias)")
func canonical_matchesDirectoryListing() throws {
    try withTempDir { dir in
        let file = dir.appendingPathComponent("x.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        // Verzeichnis-Listings liefern die aufgelöste `/private/…`-Form;
        // die kanonisierte konstruierte URL muss ihr exakt gleichen —
        // darauf bauen Tab-Dedup und die Aktiv-Markierung im Projektbaum.
        let listed = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ).first
        #expect(file.canonicalFileURL == listed?.canonicalFileURL)
        #expect(file.canonicalFileURL.path == listed?.path)
    }
}

@Test("canonicalFileURL: nicht existierender Pfad bleibt unverändert")
func canonical_missingPathUnchanged() {
    let missing = URL(fileURLWithPath: "/definitiv/nicht/da/\(UUID().uuidString)")
    #expect(missing.canonicalFileURL == missing)
}

@Test("Projekt-Suchkonfiguration bleibt pro Projekt getrennt erhalten")
func projectSearchStore_roundtripPerProject() throws {
    let suiteName = "fastra-project-search-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let first = URL(fileURLWithPath: "/tmp/projekt-a")
    let second = URL(fileURLWithPath: "/tmp/projekt-b")
    var config = ProjectSearchConfiguration.fresh()
    let sources = ProjectFileSet(name: "Quellen", paths: ["Sources", "Package.swift"])
    config.fileSets.append(sources)
    config.activeSetID = sources.id
    config.excludePatternsText = "build, *.generated.swift"

    ProjectSearchStore.save(config, for: first, defaults: defaults)
    #expect(ProjectSearchStore.load(for: first, defaults: defaults) == config)
    #expect(ProjectSearchStore.load(for: second, defaults: defaults) != config)
}

@Test("Projekt-Suchkonfiguration repariert eine ungültige aktive Auswahl")
func projectSearchStore_normalizesInvalidSelection() throws {
    let suiteName = "fastra-project-search-invalid-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = URL(fileURLWithPath: "/tmp/projekt")
    let only = ProjectFileSet(name: "Quellen", paths: ["Sources"])
    let config = ProjectSearchConfiguration(fileSets: [only], activeSetID: UUID(),
                                            fileTypeFilter: .knownText,
                                            excludePatternsText: "")
    ProjectSearchStore.save(config, for: root, defaults: defaults)
    let loaded = ProjectSearchStore.load(for: root, defaults: defaults)
    #expect(loaded.activeSetID == only.id)
}
