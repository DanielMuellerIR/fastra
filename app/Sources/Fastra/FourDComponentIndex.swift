// FourDComponentIndex.swift
//
// Index der Komponentenmethoden eines 4D-Projekts (Daniel-Auftrag
// 2026-07-24). Komponenten liegen unter `<Projekt>/Components/` (4D schreibt
// den Ordner auch klein als `components`) und treten in drei Formen auf:
//
// 1. Entpackte `.4dbase`-Ordner mit `Project/Sources/Methods/*.4dm` —
//    interpretierte Komponenten, die Quelldateien liegen direkt auf der Platte.
// 2. Gebaute `.4dbase`-Bundles mit `Contents/<Name>.4DZ` — das 4DZ ist ein
//    gewöhnliches ZIP. Enthält es `.4dm`-Quellen, werden sie einzeln aus dem
//    Archiv gelesen; kompilierte Komponenten enthalten stattdessen nur
//    `Project/DerivedData/methodAttributes.json` als Methodenkatalog.
// 3. Nackte `<Name>.4DZ`-Archive direkt im Komponentenordner.
//
// Nur GETEILTE Methoden (`shared`) sind aus dem Hostprojekt aufrufbar:
// interpretiert steht das in der `//%attributes`-Kopfzeile der `.4dm`-Datei,
// kompiliert in `methodAttributes.json`. Nicht geteilte Methoden werden
// deshalb bewusst nicht angeboten. Für kompilierte Methoden ohne Quelltext
// kann `Contents/Documentation/Methods/<Name>.md` als Signaturquelle dienen —
// 4D legt dort den Kommentarkopf samt Deklarationszeilen ab. Fehlt auch die,
// bleibt ehrlich nur der Methodenname (keine erfundenen Parameter).

import Foundation

/// Woher die Signatur einer Komponentenmethode gelesen werden kann.
enum FourDComponentMethodSource: Equatable {
    /// Entpackte `.4dm`-Quelldatei auf der Platte.
    case sourceFile(URL)
    /// `.4dm`-Quelle als Eintrag in einem `.4DZ`-Archiv.
    case zipEntry(archive: URL, path: String)
    /// Vom Entwickler exportierte Methodendokumentation (Markdown).
    case documentation(URL)
    /// Nur der Name ist bekannt.
    case nameOnly
}

/// Eine aus dem Hostprojekt aufrufbare Komponentenmethode.
struct FourDComponentMethod: Equatable {
    let displayName: String
    /// Name der Komponente (Bundle-Name ohne Endung) — für die Anzeige.
    let componentName: String
    let source: FourDComponentMethodSource
}

enum FourDComponentIndex {

    /// Größenlimit pro gelesener Datei/ZIP-Eintrag: Methodenquellen und
    /// Metadaten sind klein; alles darüber ist verdächtig und wird ignoriert.
    static let maximumEntryBytes = 1_048_576

    /// Alle geteilten Komponentenmethoden, Schlüssel kleingeschrieben (wie
    /// beim Projektmethoden-Index). Kollidieren zwei Komponenten, gewinnt
    /// die alphabetisch erste — deterministisch und ehrlich dokumentierbar.
    static func methods(in projectURL: URL,
                        fileManager: FileManager = .default) -> [String: FourDComponentMethod] {
        var result: [String: FourDComponentMethod] = [:]
        for bundle in componentBundles(in: projectURL, fileManager: fileManager) {
            for method in methods(ofComponentAt: bundle, fileManager: fileManager) {
                let key = method.displayName.lowercased()
                if result[key] == nil { result[key] = method }
            }
        }
        return result
    }

    /// Komponenten-Container unter `Components`/`components`, alphabetisch.
    /// Auf case-insensitiven Dateisystemen liefern beide Namen denselben
    /// Ordner — der Pfadvergleich verhindert doppelte Ergebnisse.
    private static func componentBundles(in projectURL: URL,
                                         fileManager: FileManager) -> [URL] {
        var directories: [URL] = []
        var seenDirectories = Set<String>()
        for name in ["Components", "components"] {
            let directory = projectURL.appendingPathComponent(name, isDirectory: true)
                .canonicalFileURL
            guard seenDirectories.insert(directory.path).inserted else { continue }
            directories.append(directory)
        }
        var bundles: [URL] = []
        for directory in directories {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for item in contents {
                let ext = item.pathExtension.lowercased()
                if ext == "4dbase" || ext == "4dz" { bundles.append(item) }
            }
        }
        return bundles.sorted {
            $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased()
        }
    }

    /// Methoden einer einzelnen Komponente (`.4dbase`-Ordner oder `.4DZ`).
    private static func methods(ofComponentAt bundle: URL,
                                fileManager: FileManager) -> [FourDComponentMethod] {
        let componentName = bundle.deletingPathExtension().lastPathComponent

        if bundle.pathExtension.lowercased() == "4dz" {
            return methodsFromArchive(bundle, componentName: componentName,
                                      documentationDirectory: nil,
                                      fileManager: fileManager)
        }

        // Dokumentation liegt bei gebauten Bundles unter `Contents/`, bei
        // entpackten Komponenten direkt im `.4dbase`-Ordner.
        let documentationDirectory = firstExistingDirectory(
            [bundle.appendingPathComponent("Contents/Documentation/Methods"),
             bundle.appendingPathComponent("Documentation/Methods")],
            fileManager: fileManager
        )

        // Form 1: entpackte Quelldateien.
        let sourceDirectories = [
            bundle.appendingPathComponent("Project/Sources/Methods"),
            bundle.appendingPathComponent("Sources/Methods"),
        ]
        var fromFiles: [FourDComponentMethod] = []
        for directory in sourceDirectories {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension.lowercased() == "4dm" {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?
                    .fileSize ?? 0
                guard size <= maximumEntryBytes,
                      let source = try? String(contentsOf: file, encoding: .utf8),
                      isSharedMethodSource(source) else { continue }
                fromFiles.append(FourDComponentMethod(
                    displayName: file.deletingPathExtension().lastPathComponent,
                    componentName: componentName,
                    source: .sourceFile(file)
                ))
            }
        }
        if !fromFiles.isEmpty { return fromFiles }

        // Form 2: 4DZ im gebauten Bundle.
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        guard let items = try? fileManager.contentsOfDirectory(
            at: contents, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ), let archive = items.first(where: {
            $0.pathExtension.lowercased() == "4dz"
        }) else { return [] }
        return methodsFromArchive(archive, componentName: componentName,
                                  documentationDirectory: documentationDirectory,
                                  fileManager: fileManager)
    }

    /// Methoden aus einem `.4DZ`-Archiv: bevorzugt echte `.4dm`-Einträge,
    /// sonst der Katalog kompilierter Methoden.
    private static func methodsFromArchive(
        _ archive: URL,
        componentName: String,
        documentationDirectory: URL?,
        fileManager: FileManager
    ) -> [FourDComponentMethod] {
        guard let entries = FourDZipArchive.entries(of: archive) else { return [] }

        let methodPrefix = "Project/Sources/Methods/"
        let sourceEntries = entries.filter {
            !$0.isDirectory
                && $0.path.hasPrefix(methodPrefix)
                && $0.path.lowercased().hasSuffix(".4dm")
                // Nur Dateien DIREKT im Methodenordner, keine Unterordner.
                && !$0.path.dropFirst(methodPrefix.count).contains("/")
        }
        if !sourceEntries.isEmpty {
            return sourceEntries.compactMap { entry in
                guard let data = FourDZipArchive.data(
                    of: entry, in: archive, maximumSize: maximumEntryBytes
                ), let source = decodeText(data),
                    isSharedMethodSource(source) else { return nil }
                let fileName = String(entry.path.dropFirst(methodPrefix.count))
                let name = (fileName as NSString).deletingPathExtension
                return FourDComponentMethod(
                    displayName: name,
                    componentName: componentName,
                    source: .zipEntry(archive: archive, path: entry.path)
                )
            }
        }

        // Kompilierte Komponente: Katalog der Methodenattribute.
        guard let catalogEntry = entries.first(where: {
            $0.path == "Project/DerivedData/methodAttributes.json"
        }), let data = FourDZipArchive.data(
            of: catalogEntry, in: archive, maximumSize: maximumEntryBytes
        ), let json = try? JSONSerialization.jsonObject(with: data),
            let rootObject = json as? [String: Any],
            let methods = rootObject["methods"] as? [String: Any] else {
            return []
        }
        return methods.compactMap { name, value in
            guard let info = value as? [String: Any],
                  let attributes = info["attributes"] as? [String: Any],
                  attributes["shared"] as? Bool == true else { return nil }
            let documentation = documentationDirectory?
                .appendingPathComponent("\(name).md")
            let hasDocumentation = documentation.map {
                fileManager.fileExists(atPath: $0.path)
            } ?? false
            return FourDComponentMethod(
                displayName: name,
                componentName: componentName,
                source: hasDocumentation && documentation != nil
                    ? .documentation(documentation!) : .nameOnly
            )
        }
    }

    /// `//%attributes = {"shared":true,…}` in der ersten Zeile entscheidet,
    /// ob eine interpretierte Methode aus dem Hostprojekt sichtbar ist.
    /// Ohne Attributzeile oder ohne `shared` ist sie es nicht.
    static func isSharedMethodSource(_ source: String) -> Bool {
        // Zeilenenden normalisieren: 4D-Exporte nutzen `\n`, die Doku-Dateien
        // und ältere Werkzeuge auch `\r` bzw. `\r\n`.
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard let firstLine = normalized
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespaces),
            firstLine.hasPrefix("//%attributes") else { return false }
        guard let equals = firstLine.firstIndex(of: "=") else { return false }
        let jsonPart = firstLine[firstLine.index(after: equals)...]
            .trimmingCharacters(in: .whitespaces)
        guard let data = jsonPart.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { return false }
        return object["shared"] as? Bool == true
    }

    /// UTF-8 mit optionalem BOM — so schreibt 4D seine Textdateien.
    static func decodeText(_ data: Data) -> String? {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            data = data.dropFirst(3)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func firstExistingDirectory(_ candidates: [URL],
                                               fileManager: FileManager) -> URL? {
        candidates.first {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }
}
