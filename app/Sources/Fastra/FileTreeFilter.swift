// FileTreeFilter.swift
//
// Dateinamens-Filter der Projekt-Seitenleiste (Etappe 3 Wunschpaket
// 2026-07c). BEWUSST ein reiner DATEINAMENS-Filter: case-insensitiver
// Teilstring, kein Fuzzy-Matching, keine zweite Volltextsuche — Inhalte
// durchsucht weiterhin der Suchdialog mit Ordner-Scope.
//
// Der Scan läuft rekursiv über den Projektordner (der Baum selbst lädt
// lazy nur aufgeklappte Ebenen) und gehört auf einen Hintergrund-Task:
// große Bäume und langsame Volumes dürfen den Main-Thread nie blockieren.

import Foundation

/// Ergebnis eines Filter-Scans. Der gespeicherte Aufklappzustand des Baums
/// bleibt UNBERÜHRT — während des Filterns gelten `expandedDirectories`,
/// danach zeigt der Baum wieder seinen alten Zustand.
struct FileTreeFilterResult: Equatable {
    let query: String
    /// Pfade der passenden DATEIEN (nur die bleiben sichtbar).
    let matchingFiles: Set<String>
    /// Ordner auf dem Weg zu Treffern — im gefilterten Baum sichtbar und
    /// zwangsweise aufgeklappt.
    let expandedDirectories: Set<String>
    /// Anzahl passender Dateien (das „N" in „N von M Dateien").
    let matchCount: Int
    /// Anzahl aller geprüften Dateien (das „M").
    let totalFileCount: Int
    /// `true` = Scan an der Sicherheitsgrenze gekappt — steht SICHTBAR in
    /// der Ansicht (keine stillen Obergrenzen, Produktregel).
    let truncated: Bool
}

enum FileTreeFilter {
    /// Sicherheitsgrenze gegen ausufernde Scans (Netz-Volumes, Riesen-Repos).
    /// Eine Kappung wird in der Seitenleiste ausgewiesen.
    static let maximumScannedFiles = 50_000

    /// Case-insensitiver Teilstring-Vergleich (deckt auch Umlaute ab:
    /// „ä" findet „Ä"). Bewusst KEIN Fuzzy-Matching in dieser Ausbaustufe.
    static func matches(name: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return name.range(of: query, options: .caseInsensitive) != nil
    }

    /// Rekursiver Scan unter `rootURL`. Läuft ABSICHTLICH über dieselbe
    /// `FileTree.children`-Basis wie der sichtbare Baum: gleiche Regeln
    /// (versteckte Einträge übersprungen) und vor allem DIESELBE Pfadform.
    /// Ein `FileManager.enumerator` löst Symlinks im Pfad auf (`/var` →
    /// `/private/var`) — seine Pfade passten dann nie zu den Baumknoten,
    /// und der Filter bliebe still leer (real über Tests in einem
    /// Temp-Ordner gefunden). Bricht kooperativ ab, wenn der umgebende
    /// Task gecancelt wurde (Tipp-Debounce) — dann `nil`.
    static func scan(rootURL: URL, query: String,
                     limit: Int = maximumScannedFiles,
                     fileManager: FileManager = .default) -> FileTreeFilterResult? {
        var matching: Set<String> = []
        var expanded: Set<String> = []
        var total = 0
        var truncated = false
        // `contentsOfDirectory` liefert KANONISCHE Pfade (`/var` →
        // `/private/var`) — die Baumknoten tragen also diese Form. Die
        // Wurzel muss dieselbe Form haben, sonst passte die Eltern-Kette
        // der Treffer nie zu den Knoten-IDs des Baums. Achtung:
        // `resolvingSymlinksInPath()` wäre FALSCH — es entfernt
        // dokumentiertermaßen gerade das `/private`-Präfix.
        let root = rootURL.canonicalFileURL
        let rootPath = root.path
        // Schutz gegen Symlink-Zyklen (Ordner-Link auf einen Vorfahren):
        // jeden kanonisch aufgelösten Ordner nur einmal betreten.
        var visitedResolved: Set<String> = [rootPath]
        var pending: [URL] = [root]

        while let directory = pending.popLast() {
            if Task.isCancelled { return nil }
            for node in FileTree.children(of: directory, fileManager: fileManager) {
                if node.isDirectory {
                    let resolved = node.url.canonicalFileURL.path
                    if visitedResolved.insert(resolved).inserted {
                        pending.append(node.url)
                    }
                    continue
                }
                if total >= limit {
                    truncated = true
                    break
                }
                total += 1
                guard matches(name: node.name, query: query) else { continue }
                matching.insert(node.url.path)
                // Alle Elternordner bis zur Projektwurzel öffnen. Sobald ein
                // Ordner schon markiert ist, sind es seine Eltern auch.
                var parent = node.url.deletingLastPathComponent()
                while parent.path.hasPrefix(rootPath) {
                    if !expanded.insert(parent.path).inserted { break }
                    if parent.path == rootPath { break }
                    parent = parent.deletingLastPathComponent()
                }
            }
            if truncated { break }
        }
        return FileTreeFilterResult(
            query: query,
            matchingFiles: matching,
            expandedDirectories: expanded,
            matchCount: matching.count,
            totalFileCount: total,
            truncated: truncated
        )
    }

    /// Sichtbarkeit eines Baumknotens unter aktivem Filter: Dateien nur bei
    /// Treffer, Ordner nur auf dem Weg zu Treffern. Pure → unit-testbar.
    static func isVisible(node: FileTreeNode, result: FileTreeFilterResult) -> Bool {
        node.isDirectory
            ? result.expandedDirectories.contains(node.url.path)
            : result.matchingFiles.contains(node.url.path)
    }
}
