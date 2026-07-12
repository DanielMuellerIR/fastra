import Foundation

/// Ein Knoten im Dateibaum der Projekt-Seitenleiste. Identität über den
/// vollen Pfad — stabil über Neuladungen hinweg (eine UUID wäre bei jedem
/// Verzeichnis-Listing „neu" und würde den Aufklapp-Zustand zerstören).
struct FileTreeNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// Baut die Ebenen des Projekt-Dateibaums. Bewusst EINE Ebene pro Aufruf
/// (lazy): geladen wird erst beim Aufklappen eines Ordners — ein kompletter
/// rekursiver Scan großer Repos beim Projekt-Öffnen wäre Verschwendung.
enum FileTree {
    /// Listet die direkten Kinder eines Ordners, sortiert wie im Finder:
    /// Ordner zuerst, innerhalb der Gruppen alphabetisch (localizedStandard,
    /// also „2" vor „10"). Versteckte Einträge (Punkt-Dateien, `.git` & Co.)
    /// werden übersprungen. Fehler (kein Ordner, keine Rechte) → leere Liste.
    static func children(of url: URL,
                         fileManager: FileManager = .default) -> [FileTreeNode] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let nodes = entries.map { entryURL -> FileTreeNode in
            let isDir = (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            return FileTreeNode(url: entryURL, isDirectory: isDir)
        }

        return sorted(nodes)
    }

    /// Finder-Sortierung: Ordner vor Dateien, dann Name (localizedStandard).
    /// Pure Funktion → unit-testbar ohne Dateisystem.
    static func sorted(_ nodes: [FileTreeNode]) -> [FileTreeNode] {
        nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
