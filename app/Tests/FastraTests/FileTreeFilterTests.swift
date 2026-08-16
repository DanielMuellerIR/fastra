// FileTreeFilterTests.swift
//
// Unit-Tests des Dateinamens-Filters der Projekt-Seitenleiste (Etappe 3
// Wunschpaket 2026-07c): Teilstring-Matching (case-insensitiv, Umlaute),
// versteckte Dateien, Eltern-Aufklappung, Zähler und sichtbare Kappung.

import Testing
import Foundation
@testable import Fastra

// MARK: - Matching

@Test("Teilstring case-insensitiv; kein Fuzzy-Matching")
func filterMatching() {
    #expect(FileTreeFilter.matches(name: "Workspace.swift", query: "space"))
    #expect(FileTreeFilter.matches(name: "Workspace.swift", query: "WORK"))
    #expect(FileTreeFilter.matches(name: "readme.md", query: "ReadMe"))
    // Kein Fuzzy: verstreute Buchstaben zählen nicht.
    #expect(!FileTreeFilter.matches(name: "Workspace.swift", query: "wksp"))
    #expect(!FileTreeFilter.matches(name: "a-b-c.txt", query: "abc"))
}

@Test("Umlaute: „ä“ findet „Ä“ und umgekehrt")
func filterMatchingUmlauts() {
    #expect(FileTreeFilter.matches(name: "Übersicht.md", query: "über"))
    // Unicode-Case-Faltung setzt „ß“ mit „SS“ gleich — erwünscht:
    // „STRASSE“ findet „Straße“.
    #expect(FileTreeFilter.matches(name: "größen-tabelle.csv", query: "GRÖSSEN"))
    #expect(FileTreeFilter.matches(name: "Ärzte.txt", query: "ärz"))
}

@Test("Leerer Suchtext passt auf alles")
func filterMatchingEmptyQuery() {
    #expect(FileTreeFilter.matches(name: "irgendwas", query: ""))
}

// MARK: - Scan

private final class FilterCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var cancellationObserved = false

    func markStarted() {
        lock.withLock { started = true }
    }

    func markCancellationObserved() {
        lock.withLock { cancellationObserved = true }
    }

    var hasStarted: Bool {
        lock.withLock { started }
    }

    var hasObservedCancellation: Bool {
        lock.withLock { cancellationObserved }
    }
}

@Test("Ein abgelöster Filter-Scan übernimmt den Abbruch des Aufrufers")
func detachedFilterScanCancellation() async {
    let probe = FilterCancellationProbe()
    let scan = Task {
        await FileTreeFilter.runCancellableScan {
            probe.markStarted()
            // Der Körper muss so lange leben, bis das `cancel()` des Tests
            // ihn erreicht — und das kann in der vollen parallelen Suite
            // beliebig verzögert sein. Mit einer festen kurzen Schleife
            // (500 × 1 ms) lief er unter Last schon vor dem Abbruch aus,
            // und die Beobachtung fehlte (reproduziert 2026-08-16).
            // Funktioniert die Weitergabe, endet der Scan in Millisekunden;
            // die Frist begrenzt nur den roten Pfad.
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if Task.isCancelled {
                    probe.markCancellationObserved()
                    return nil
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            return nil
        }
    }

    // Auch der Start des detachten Scans kann unter Last anstehen; die Frist
    // ist wieder nur eine Hänge-Erkennung.
    #expect(await waitUntil(timeout: 30) { probe.hasStarted })
    scan.cancel()
    _ = await scan.value
    #expect(probe.hasObservedCancellation)
}

private func makeFixtureTree() throws -> URL {
    // Kanonische Form (`/private/var/…`) — dieselbe Pfadform, die auch
    // `contentsOfDirectory` für die echten Baumknoten liefert.
    let root = FileManager.default.temporaryDirectory
        .canonicalFileURL
        .appendingPathComponent("fastra-treefilter-\(UUID().uuidString)")
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("sub/tief"),
                           withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("leer"),
                           withIntermediateDirectories: true)
    try "1".write(to: root.appendingPathComponent("eins.txt"),
                  atomically: true, encoding: .utf8)
    try "2".write(to: root.appendingPathComponent("zwei.md"),
                  atomically: true, encoding: .utf8)
    try "3".write(to: root.appendingPathComponent("sub/drei.txt"),
                  atomically: true, encoding: .utf8)
    try "4".write(to: root.appendingPathComponent("sub/tief/vier-treffer.txt"),
                  atomically: true, encoding: .utf8)
    try "5".write(to: root.appendingPathComponent(".versteckt-treffer.txt"),
                  atomically: true, encoding: .utf8)
    return root
}

@Test("Scan: Treffer mit Eltern-Kette, versteckte Dateien bleiben außen vor")
func scanBasics() throws {
    let root = try makeFixtureTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let result = FileTreeFilter.scan(rootURL: root, query: "treffer")
    guard let result else {
        Issue.record("Scan lieferte nil ohne Abbruch")
        return
    }
    // Nur die sichtbare Treffer-Datei zählt — die versteckte nicht.
    #expect(result.matchCount == 1)
    #expect(result.matchingFiles
            == [root.appendingPathComponent("sub/tief/vier-treffer.txt").path])
    // Eltern-Kette bis zur Wurzel ist aufgeklappt; „leer" nicht.
    #expect(result.expandedDirectories.contains(root.appendingPathComponent("sub").path))
    #expect(result.expandedDirectories.contains(root.appendingPathComponent("sub/tief").path))
    #expect(!result.expandedDirectories.contains(root.appendingPathComponent("leer").path))
    // M zählt alle sichtbaren Dateien (4 — ohne die versteckte).
    #expect(result.totalFileCount == 4)
    #expect(!result.truncated)
}

@Test("Scan ohne Treffer: Zähler stimmt, nichts aufgeklappt")
func scanNoMatches() throws {
    let root = try makeFixtureTree()
    defer { try? FileManager.default.removeItem(at: root) }
    guard let result = FileTreeFilter.scan(rootURL: root, query: "gibtsnicht") else {
        Issue.record("Scan lieferte nil ohne Abbruch")
        return
    }
    #expect(result.matchCount == 0)
    #expect(result.expandedDirectories.isEmpty)
    #expect(result.totalFileCount == 4)
}

@Test("Kappung ist sichtbar: truncated-Flag ab der Grenze")
func scanTruncation() throws {
    let root = try makeFixtureTree()
    defer { try? FileManager.default.removeItem(at: root) }
    guard let result = FileTreeFilter.scan(rootURL: root, query: "e", limit: 2) else {
        Issue.record("Scan lieferte nil ohne Abbruch")
        return
    }
    #expect(result.truncated)
    #expect(result.totalFileCount == 2)
}

@Test("isVisible: Dateien nur bei Treffer, Ordner nur auf dem Treffer-Pfad")
func nodeVisibility() throws {
    let root = try makeFixtureTree()
    defer { try? FileManager.default.removeItem(at: root) }
    guard let result = FileTreeFilter.scan(rootURL: root, query: "treffer") else {
        Issue.record("Scan lieferte nil ohne Abbruch")
        return
    }
    let sub = FileTreeNode(url: root.appendingPathComponent("sub"), isDirectory: true)
    let leer = FileTreeNode(url: root.appendingPathComponent("leer"), isDirectory: true)
    let match = FileTreeNode(url: root.appendingPathComponent("sub/tief/vier-treffer.txt"),
                             isDirectory: false)
    let miss = FileTreeNode(url: root.appendingPathComponent("eins.txt"),
                            isDirectory: false)
    #expect(FileTreeFilter.isVisible(node: sub, result: result))
    #expect(!FileTreeFilter.isVisible(node: leer, result: result))
    #expect(FileTreeFilter.isVisible(node: match, result: result))
    #expect(!FileTreeFilter.isVisible(node: miss, result: result))
}
