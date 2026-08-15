//
// PatternLibrary.swift
//
// Vom Nutzer gespeicherte Suchvorlagen. Die eingebauten Vorlagen bleiben
// unveränderlich; eigene Vorlagen leben getrennt und können als kleine,
// portable JSON-Datei exportiert oder wieder importiert werden.

import AppKit
import Foundation

@MainActor
final class PatternLibrary: ObservableObject {
    static let defaultsKey = "patterns.userLibrary.v1"

    @Published private(set) var templates: [PatternTemplate]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        templates = Self.load(from: defaults)
    }

    func save(_ template: PatternTemplate) throws {
        guard !template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PatternLibraryError.emptyName
        }
        guard Self.isAllowedUserID(template.id) else {
            throw PatternLibraryError.invalidID
        }
        _ = try template.compile()
        // Jedes Suchfenster hält eine eigene Library-Instanz. Vor einer
        // Mutation deshalb den gemeinsamen Stand neu laden, damit ein später
        // schreibendes Fenster keine Änderungen eines anderen überschreibt.
        var next = Self.load(from: defaults).filter { $0.id != template.id }
        next.append(template)
        templates = Self.validated(next)
        persist()
    }

    func delete(id: String) {
        templates = Self.load(from: defaults).filter { $0.id != id }
        persist()
    }

    /// Fügt eine Exportdatei zusammen, ohne gleichnamige IDs doppelt zu halten.
    @discardableResult
    func `import`(data: Data) throws -> Int {
        guard data.count <= PatternLibraryImportFile.maximumBytes else {
            throw PatternLibraryError.importTooLarge
        }
        let incoming = try JSONDecoder().decode([PatternTemplate].self, from: data)
        templates = Self.load(from: defaults)
        var importedIDs = Set<String>()
        for template in incoming {
            guard !template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard Self.isAllowedUserID(template.id) else { continue }
            guard (try? template.compile()) != nil else { continue }
            templates.removeAll { $0.id == template.id }
            templates.append(template)
            importedIDs.insert(template.id)
        }
        templates = Self.validated(templates)
        persist()
        return importedIDs.count
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(templates)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> [PatternTemplate] {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode([PatternTemplate].self, from: data) else {
            return []
        }
        // Beschädigte, doppelte und mitgelieferte IDs werden nicht still als
        // eigene Vorlagen übernommen.
        return validated(saved)
    }

    private static let builtInIDs = Set(BuiltInPatterns.all.map(\.id))

    private static func isAllowedUserID(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !builtInIDs.contains(id)
    }

    private static func validated(_ values: [PatternTemplate]) -> [PatternTemplate] {
        var ids = Set<String>()
        return values.filter { template in
            guard ids.insert(template.id).inserted,
                  isAllowedUserID(template.id),
                  !template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (try? template.compile()) != nil else { return false }
            return true
        }
    }
}

enum PatternLibraryError: LocalizedError, Sendable {
    case emptyName
    case invalidID
    case importTooLarge

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return L10n.string("Eine Vorlage braucht einen Namen.")
        case .invalidID:
            return L10n.string("Diese Vorlagen-ID ist leer oder bereits mitgeliefert.")
        case .importTooLarge:
            return L10n.string("Die Vorlagendatei ist größer als 1 MB.")
        }
    }
}

/// Liest höchstens die für eine kleine Vorlagenbibliothek sinnvolle Menge.
/// Dadurch lädt eine versehentlich ausgewählte große Datei weder den
/// Main-Thread noch den Speicher unkontrolliert voll.
enum PatternLibraryImportFile {
    static let maximumBytes = 1_048_576

    static func read(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw PatternLibraryError.importTooLarge
        }
        return data
    }
}

/// Leitet für ein kurzes Beispielpaar eine Platzhalter-Transformation ab.
/// Wir verwenden die längste gemeinsame Zeichenfolge als Capture; dadurch
/// wird `ring, The` → `The ring` zu `*, The` → `The *`.
enum ExampleTransformation {
    struct Inference: Equatable {
        let findPattern: String
        let replacePattern: String
    }

    static func infer(source: String, destination: String) -> Inference? {
        guard !source.isEmpty, !destination.isEmpty, source != destination,
              !source.contains("*"), !destination.contains("*") else { return nil }
        let sourceChars = Array(source)
        let destinationChars = Array(destination)
        // Beispiele sind absichtlich kurz. Die Begrenzung verhindert, dass ein
        // versehentlich eingefügter Roman die UI mit einer O(n*m)-Matrix blockiert.
        guard sourceChars.count <= 512, destinationChars.count <= 512 else { return nil }

        var bestLength = 0
        var bestSourceEnd = 0
        var matrix = Array(repeating: Array(repeating: 0, count: destinationChars.count + 1),
                           count: sourceChars.count + 1)
        for i in sourceChars.indices {
            for j in destinationChars.indices where sourceChars[i] == destinationChars[j] {
                let length = matrix[i][j] + 1
                matrix[i + 1][j + 1] = length
                if length > bestLength {
                    bestLength = length
                    bestSourceEnd = i + 1
                }
            }
        }
        guard bestLength > 0 else { return nil }
        let capture = String(sourceChars[(bestSourceEnd - bestLength)..<bestSourceEnd])
        guard let sourceRange = source.range(of: capture),
              let destinationRange = destination.range(of: capture) else { return nil }
        let sourceBefore = String(source[..<sourceRange.lowerBound])
        let sourceAfter = String(source[sourceRange.upperBound...])
        let destinationBefore = String(destination[..<destinationRange.lowerBound])
        let destinationAfter = String(destination[destinationRange.upperBound...])
        // Der gemeinsame Teil wird bewusst als * erfasst. Unveränderte Teile
        // bleiben Literal, damit das abgeleitete Muster nicht zu breit greift.
        return Inference(findPattern: sourceBefore + "*" + sourceAfter,
                         replacePattern: destinationBefore + "*" + destinationAfter)
    }
}
