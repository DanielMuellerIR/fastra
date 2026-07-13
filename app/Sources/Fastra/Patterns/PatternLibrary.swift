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
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let saved = try? JSONDecoder().decode([PatternTemplate].self, from: data) else {
            templates = []
            return
        }
        // Beschädigte oder doppelte Daten werden nicht still übernommen.
        templates = Self.validated(saved)
    }

    func save(_ template: PatternTemplate) throws {
        guard !template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PatternLibraryError.emptyName
        }
        _ = try template.compile()
        var next = templates.filter { $0.id != template.id }
        next.append(template)
        templates = Self.validated(next)
        persist()
    }

    func delete(id: String) {
        templates.removeAll { $0.id == id }
        persist()
    }

    /// Fügt eine Exportdatei zusammen, ohne gleichnamige IDs doppelt zu halten.
    @discardableResult
    func `import`(data: Data) throws -> Int {
        let incoming = try JSONDecoder().decode([PatternTemplate].self, from: data)
        for template in incoming {
            guard !template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard (try? template.compile()) != nil else { continue }
            templates.removeAll { $0.id == template.id }
            templates.append(template)
        }
        templates = Self.validated(templates)
        persist()
        return incoming.count
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

    private static func validated(_ values: [PatternTemplate]) -> [PatternTemplate] {
        var ids = Set<String>()
        return values.filter { template in
            guard ids.insert(template.id).inserted,
                  !template.id.isEmpty,
                  !template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (try? template.compile()) != nil else { return false }
            return true
        }
    }
}

enum PatternLibraryError: LocalizedError {
    case emptyName

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Eine Vorlage braucht einen Namen."
        }
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
        guard !source.isEmpty, !destination.isEmpty, source != destination else { return nil }
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
