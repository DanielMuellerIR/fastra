// FourDProjectMethodIndex.swift
//
// Kleiner Index für Projektmethoden einer exportierten 4D-Anwendung. Er liest
// bewusst nur die beiden bekannten Methodenordner, niemals den ganzen
// Projektbaum: Das Ergebnis dient ausschließlich dem Syntax-Highlighting.

import Foundation

enum FourDProjectMethodIndex {

    /// 4D legt Methoden je nach Exportform in einem dieser beiden Ordner ab.
    /// Die Reihenfolge ist nur für reproduzierbare Tests relevant.
    static let candidateRelativePaths = [
        "Project/Sources/Methods",
        "Sources/Methods",
    ]

    /// Liefert kleingeschriebene Dateinamen ohne `.4dm`-Endung. Dadurch
    /// bleibt der Vergleich mit 4D-Methoden wie in der Sprache selbst
    /// unabhängig von Groß-/Kleinschreibung.
    static func methodNames(in projectURL: URL,
                            fileManager: FileManager = .default) -> Set<String> {
        Set(methodDisplayNames(in: projectURL, fileManager: fileManager).keys)
    }

    /// Wie `methodNames`, behält aber zusätzlich die Original-Schreibweise
    /// des Dateinamens (klein → Anzeige). Die braucht die Vervollständigung,
    /// damit ein Vorschlag exakt so eingefügt wird, wie die Methode heißt.
    static func methodDisplayNames(in projectURL: URL,
                                   fileManager: FileManager = .default) -> [String: String] {
        var names: [String: String] = [:]
        let root = projectURL.canonicalFileURL

        for relativePath in candidateRelativePaths {
            let directory = root.appendingPathComponent(relativePath, isDirectory: true)
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for file in files where file.pathExtension.lowercased() == "4dm" {
                // Am symlink-aufgelösten Pfad prüfen: `isRegularFile`
                // beschreibt sonst den Link selbst, und eine völlig legitime
                // verlinkte Methodendatei fiele aus dem Index
                // (Review 2026-08-02).
                let values = try? file.resolvingSymlinksInPath()
                    .resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile != false else { continue }
                let display = file.deletingPathExtension().lastPathComponent
                names[display.lowercased()] = display
            }
        }
        return names
    }

    /// Asynchrone Scans dürfen nur ihr ursprüngliches Projekt aktualisieren.
    /// Diese reine Entscheidung hält das Rennen beim schnellen Projektwechsel
    /// direkt testbar und unabhängig von SwiftUI.
    static func shouldApply(resultFor root: URL, generation: UInt64,
                            currentRoot: URL?, currentGeneration: UInt64) -> Bool {
        generation == currentGeneration
            && currentRoot?.canonicalFileURL == root.canonicalFileURL
    }
}
