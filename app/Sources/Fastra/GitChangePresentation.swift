import Foundation

/// Darstellung der geänderten Dateien. Der gespeicherte Rohwert ist bewusst
/// stabil, damit eine spätere Umbenennung der deutschen UI-Texte keine
/// Nutzereinstellung verliert.
enum GitChangesLayoutMode: String, CaseIterable {
    case flat
    case tree
}

/// Quelle einer gelöschten Datei. Im Working Tree liegt die letzte Fassung
/// noch im Index; bei einer bereits bereitgestellten Löschung liegt sie in
/// HEAD. Genau diese Trennung entspricht den beiden Abschnitten der Liste.
enum GitFileSnapshotSource: Hashable {
    case index
    case head
}

/// Sicher adressierter, read-only Git-Blob. `git cat-file` erhält alle Werte
/// als einzelne argv-Elemente; ein Dateiname wird niemals von einer Shell
/// ausgewertet.
struct GitFileSnapshotRequest: Hashable {
    let repositoryPath: String
    let path: String
    let source: GitFileSnapshotSource

    var arguments: [String] {
        let object = source == .head ? "HEAD:\(path)" : ":\(path)"
        return ["cat-file", "blob", object]
    }
}

/// Ein Ordner der hierarchischen Änderungen-Ansicht. Der Baum enthält nur
/// Ordner, die wenigstens eine geänderte Datei besitzen; leere Zwischenknoten
/// können deshalb weder entstehen noch sichtbar hängen bleiben.
struct GitChangeTreeFolder: Identifiable {
    let path: String
    let name: String
    let folders: [GitChangeTreeFolder]
    let files: [GitChange]

    var id: String { path }
}

/// Eine bereits auf den Aufklappzustand reduzierte Zeile. Das flache Ergebnis
/// lässt sich in einem `LazyVStack` zeichnen; auch mehrere hundert Änderungen
/// erzeugen damit nur die gerade sichtbaren SwiftUI-Zeilen.
enum GitChangeTreeVisibleItem: Identifiable {
    case folder(GitChangeTreeFolder, depth: Int)
    case summarizedFolder(GitChange, depth: Int)
    case file(GitChange, depth: Int)

    var id: String {
        switch self {
        case .folder(let folder, _): return "folder:\(folder.path)"
        case .summarizedFolder(let change, _):
            return "summary-folder:\(change.rawPath.base64EncodedString())"
        case .file(let change, _):
            return "file:\(change.rawPath.base64EncodedString())"
        }
    }
}

enum GitChangeTreeBuilder {
    /// Veränderlicher Aufbauknoten; er verlässt diese Fabrik nie. Die
    /// veröffentlichte Baumstruktur darüber bleibt ein normaler Werttyp.
    private final class BuilderFolder {
        let path: String
        let name: String
        var folders: [String: BuilderFolder] = [:]
        var files: [GitChange] = []

        init(path: String, name: String) {
            self.path = path
            self.name = name
        }
    }

    static func build(_ changes: [GitChange]) -> GitChangeTreeFolder {
        let root = BuilderFolder(path: "", name: "")
        for change in changes {
            // Nicht als UTF-8 darstellbare Pfade bleiben bedienungssicher als
            // eine einzelne Wurzelzeile sichtbar. Dateiaktionen sind für sie
            // bereits durch `GitChange.actionPath == nil` gesperrt.
            guard let path = change.actionPath else {
                root.files.append(change)
                continue
            }
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard components.count > 1 else {
                root.files.append(change)
                continue
            }
            var parent = root
            var accumulated: [String] = []
            for component in components.dropLast() {
                accumulated.append(component)
                let folderPath = accumulated.joined(separator: "/")
                if let existing = parent.folders[component] {
                    parent = existing
                } else {
                    let folder = BuilderFolder(path: folderPath, name: component)
                    parent.folders[component] = folder
                    parent = folder
                }
            }
            parent.files.append(change)
        }
        return freeze(root)
    }

    static func visibleItems(in tree: GitChangeTreeFolder,
                             expanded: Set<String>) -> [GitChangeTreeVisibleItem] {
        var result: [GitChangeTreeVisibleItem] = []
        appendChildren(of: tree, depth: 0, expanded: expanded, to: &result)
        return result
    }

    private static func appendChildren(of folder: GitChangeTreeFolder, depth: Int,
                                       expanded: Set<String>,
                                       to result: inout [GitChangeTreeVisibleItem]) {
        for child in folder.folders {
            result.append(.folder(child, depth: depth))
            if expanded.contains(child.path) {
                appendChildren(of: child, depth: depth + 1,
                               expanded: expanded, to: &result)
            }
        }
        result.append(contentsOf: folder.files.map {
            $0.path.hasSuffix("/")
                ? .summarizedFolder($0, depth: depth)
                : .file($0, depth: depth)
        })
    }

    private static func freeze(_ source: BuilderFolder) -> GitChangeTreeFolder {
        let folders = source.folders.values
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(freeze)
        let files = source.files.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return GitChangeTreeFolder(path: source.path, name: source.name,
                                   folders: folders, files: files)
    }
}
