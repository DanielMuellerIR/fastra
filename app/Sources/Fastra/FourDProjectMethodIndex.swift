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
        var names = Set<String>()
        let root = projectURL.canonicalFileURL

        for relativePath in candidateRelativePaths {
            let directory = root.appendingPathComponent(relativePath, isDirectory: true)
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for file in files where file.pathExtension.lowercased() == "4dm" {
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile != false else { continue }
                names.insert(file.deletingPathExtension().lastPathComponent.lowercased())
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
