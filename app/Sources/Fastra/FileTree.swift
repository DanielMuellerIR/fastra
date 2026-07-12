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

// MARK: - Persistenter Aufklappzustand

enum FileTreeExpansionStore {
    private static let keyPrefix = "fileTree.expanded."

    /// Der kanonische Projektpfad ist als Defaults-Schlüssel eindeutig. Die
    /// Prozentkodierung verhindert, dass Sonderzeichen im Pfad den Schlüssel
    /// schwer lesbar oder mehrdeutig machen.
    static func key(for rootURL: URL) -> String {
        let path = rootURL.standardizedFileURL.path
        let encoded = Data(path.utf8).base64EncodedString()
        return keyPrefix + encoded
    }

    static func load(for rootURL: URL, defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key(for: rootURL)) ?? [])
    }

    static func save(_ paths: Set<String>, for rootURL: URL,
                     defaults: UserDefaults = .standard) {
        defaults.set(paths.sorted(), forKey: key(for: rootURL))
    }
}

// MARK: - Dateiaktionen des Kontextmenüs

enum FileTreeOperationError: LocalizedError {
    case invalidName
    case alreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return L10n.string("Der Name darf nicht leer sein und weder „/“ noch nur Punkte enthalten.")
        case .alreadyExists(let name):
            return L10n.format("„%@“ existiert in diesem Ordner bereits.", name)
        }
    }
}

enum FileTreeOperations {
    static func destination(named rawName: String, in directory: URL,
                            fileManager: FileManager = .default) throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw FileTreeOperationError.invalidName
        }
        let destination = directory.appendingPathComponent(name)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw FileTreeOperationError.alreadyExists(name)
        }
        return destination
    }

    @discardableResult
    static func create(named name: String, in directory: URL, isDirectory: Bool,
                       fileManager: FileManager = .default) throws -> URL {
        let destination = try destination(named: name, in: directory,
                                          fileManager: fileManager)
        if isDirectory {
            try fileManager.createDirectory(at: destination,
                                            withIntermediateDirectories: false)
        } else {
            guard fileManager.createFile(atPath: destination.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        return destination
    }

    @discardableResult
    static func rename(_ source: URL, to newName: String,
                       fileManager: FileManager = .default) throws -> URL {
        let destination = try destination(named: newName,
                                          in: source.deletingLastPathComponent(),
                                          fileManager: fileManager)
        try fileManager.moveItem(at: source, to: destination)
        return destination
    }
}
