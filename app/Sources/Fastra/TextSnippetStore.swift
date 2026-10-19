import Foundation

struct TextSnippetDefinition: Codable, Identifiable, Equatable {
    var id = UUID()
    var revision = UUID()
    var name: String
    var template: String
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision
            && lhs.name.utf8.elementsEqual(rhs.name.utf8)
            && lhs.template.utf8.elementsEqual(rhs.template.utf8)
    }
    static let maximumNameCharacters = 80

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= Self.maximumNameCharacters,
              name.rangeOfCharacter(from: .controlCharacters) == nil, !template.isEmpty else {
            throw TextSnippetError.invalidDefinition
        }
        _ = try TextSnippetTemplate(template)
    }
}

enum TextSnippetArchive {
    struct Envelope: Codable { var schemaVersion = 1; let snippets: [TextSnippetDefinition] }
    static let maximumBytes = 1024 * 1024
    static let maximumCount = 50

    static func encode(_ definitions: [TextSnippetDefinition]) throws -> Data {
        try validate(definitions)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(snippets: definitions))
        guard data.count <= maximumBytes else { throw TextSnippetError.sizeLimit }
        return data
    }

    static func decode(_ data: Data) throws -> [TextSnippetDefinition] {
        guard data.count <= maximumBytes else { throw TextSnippetError.sizeLimit }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.schemaVersion == 1 else { throw TextSnippetError.invalidArchive }
            try validate(envelope.snippets)
            return envelope.snippets
        } catch let error as TextSnippetError { throw error }
        catch { throw TextSnippetError.invalidArchive }
    }

    private static func validate(_ definitions: [TextSnippetDefinition]) throws {
        guard definitions.count <= maximumCount else { throw TextSnippetError.collectionLimit }
        guard Set(definitions.map(\.id)).count == definitions.count else { throw TextSnippetError.invalidArchive }
        for definition in definitions { try definition.validate() }
    }
}

@MainActor
final class TextSnippetStore {
    static let key = "fastra.textSnippets.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = SelfTest.workspaceDefaults()) { self.defaults = defaults }

    func load() throws -> [TextSnippetDefinition] {
        guard let object = defaults.object(forKey: Self.key) else { return [] }
        guard let data = object as? Data else { throw TextSnippetError.invalidArchive }
        return try TextSnippetArchive.decode(data)
    }

    @discardableResult
    func save(_ definition: TextSnippetDefinition, expectedRevision: UUID?) throws -> TextSnippetDefinition {
        var definitions = try load(), saved = definition
        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try saved.validate()
        guard !definitions.contains(where: { $0.id != saved.id && Self.sameName($0.name, saved.name) }) else { throw TextSnippetError.duplicateName }
        saved.revision = UUID()
        if let index = definitions.firstIndex(where: { $0.id == saved.id }) {
            guard definitions[index].revision == expectedRevision else { throw TextSnippetError.staleDefinition }
            definitions[index] = saved
        } else {
            guard expectedRevision == nil else { throw TextSnippetError.staleDefinition }
            definitions.append(saved)
        }
        // Alle Fenster lesen vor jeder Änderung neu. Ein kaputter Store
        // wird weder geleert noch durch einen neuen Entwurf überschrieben.
        defaults.set(try TextSnippetArchive.encode(definitions), forKey: Self.key)
        return saved
    }

    func remove(id: UUID, expectedRevision: UUID) throws {
        var definitions = try load()
        guard let index = definitions.firstIndex(where: { $0.id == id }),
              definitions[index].revision == expectedRevision else { throw TextSnippetError.staleDefinition }
        definitions.remove(at: index)
        defaults.set(try TextSnippetArchive.encode(definitions), forKey: Self.key)
    }

    struct PreparedImport {
        fileprivate let existing: [TextSnippetDefinition]
        let incoming: [TextSnippetDefinition]
    }

    func prepareImport(_ data: Data) throws -> PreparedImport {
        var incoming = try TextSnippetArchive.decode(data)
        let existing = try load()
        guard incoming.count <= TextSnippetArchive.maximumCount - existing.count else { throw TextSnippetError.collectionLimit }
        var names = existing.map(\.name)
        for index in incoming.indices {
            incoming[index].id = UUID(); incoming[index].revision = UUID()
            incoming[index].name = Self.availableName(incoming[index].name, excluding: names)
            names.append(incoming[index].name)
        }
        _ = try TextSnippetArchive.encode(existing + incoming)
        return PreparedImport(existing: existing, incoming: incoming)
    }

    func previewImport(_ data: Data) throws -> [TextSnippetDefinition] { try prepareImport(data).incoming }

    @discardableResult
    func importPrepared(_ prepared: PreparedImport) throws -> [TextSnippetDefinition] {
        // Der modale Dialog lässt den RunLoop weiterlaufen. Seine Bestätigung
        // gilt ausschließlich für die zuvor vollständig angezeigte Sammlung.
        guard try load() == prepared.existing else { throw TextSnippetError.staleCollection }
        defaults.set(try TextSnippetArchive.encode(prepared.existing + prepared.incoming), forKey: Self.key)
        return prepared.incoming
    }

    @discardableResult
    func importDefinitions(_ data: Data) throws -> [TextSnippetDefinition] {
        try importPrepared(prepareImport(data))
    }

    static func availableName(_ name: String, excluding existing: [String]) -> String {
        let base = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(TextSnippetDefinition.maximumNameCharacters))
        var candidate = base, suffix = 2
        while existing.contains(where: { sameName($0, candidate) }) {
            let ending = " (\(suffix))"
            candidate = String(base.prefix(TextSnippetDefinition.maximumNameCharacters - ending.count)) + ending
            suffix += 1
        }
        return candidate
    }

    private static func sameName(_ first: String, _ second: String) -> Bool {
        first.localizedCaseInsensitiveCompare(second) == .orderedSame
    }
}
