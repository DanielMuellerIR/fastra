import Foundation

enum TextWorkflowArchive {
    struct Envelope: Codable { var schemaVersion = 1; let workflows: [TextWorkflow] }
    static let maximumBytes = 1024 * 1024
    static let maximumCount = 50

    static func encode(_ workflows: [TextWorkflow]) throws -> Data {
        try validate(workflows)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(workflows: workflows))
        guard data.count <= maximumBytes else { throw TextWorkflowError.sizeLimit }
        return data
    }

    static func decode(_ data: Data) throws -> [TextWorkflow] {
        guard data.count <= maximumBytes else { throw TextWorkflowError.sizeLimit }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.schemaVersion == 1 else { throw TextWorkflowError.invalidArchive }
            try validate(envelope.workflows)
            return envelope.workflows
        } catch let error as TextWorkflowError { throw error }
        catch { throw TextWorkflowError.invalidArchive }
    }

    private static func validate(_ workflows: [TextWorkflow]) throws {
        guard workflows.count <= maximumCount, Set(workflows.map(\.id)).count == workflows.count else { throw TextWorkflowError.invalidArchive }
        for workflow in workflows { try TextWorkflowEngine.validate(workflow) }
    }
}

@MainActor
final class TextWorkflowStore {
    static let key = "fastra.textWorkflows.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = SelfTest.workspaceDefaults()) { self.defaults = defaults }

    func load() throws -> [TextWorkflow] {
        guard let value = defaults.object(forKey: Self.key) else { return [] }
        guard let data = value as? Data else { throw TextWorkflowError.invalidArchive }
        return try TextWorkflowArchive.decode(data)
    }

    @discardableResult
    func save(_ definition: TextWorkflow, expectedRevision: UUID?) throws -> TextWorkflow {
        var workflows = try load(), saved = definition
        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workflows.contains(where: { $0.id != saved.id && $0.name.localizedCaseInsensitiveCompare(saved.name) == .orderedSame }) else { throw TextWorkflowError.duplicateName }
        saved.revision = UUID()
        if let index = workflows.firstIndex(where: { $0.id == saved.id }) {
            guard workflows[index].revision == expectedRevision else { throw TextWorkflowError.staleDefinition }
            workflows[index] = saved
        } else {
            guard expectedRevision == nil else { throw TextWorkflowError.staleDefinition }
            workflows.append(saved)
        }
        // Erst nach vollständiger Validierung schreiben. Ein beschädigter
        // Store wird weder als leere Liste behandelt noch überschrieben.
        defaults.set(try TextWorkflowArchive.encode(workflows), forKey: Self.key)
        return saved
    }

    func remove(id: UUID, expectedRevision: UUID) throws {
        var workflows = try load()
        guard let index = workflows.firstIndex(where: { $0.id == id }), workflows[index].revision == expectedRevision else { throw TextWorkflowError.staleDefinition }
        workflows.remove(at: index)
        defaults.set(try TextWorkflowArchive.encode(workflows), forKey: Self.key)
    }

    @discardableResult
    func importDefinitions(_ data: Data) throws -> [TextWorkflow] {
        var incoming = try TextWorkflowArchive.decode(data)
        let existing = try load()
        guard incoming.count <= TextWorkflowArchive.maximumCount - existing.count else { throw TextWorkflowError.sizeLimit }
        for index in incoming.indices {
            incoming[index].id = UUID(); incoming[index].revision = UUID()
            incoming[index].steps = incoming[index].steps.map { step in var copy = step; copy.id = UUID(); return copy }
            let name = incoming[index].name
            var suffix = 2
            while (existing + Array(incoming[..<index])).contains(where: { $0.name.localizedCaseInsensitiveCompare(incoming[index].name) == .orderedSame }) {
                incoming[index].name = name + " (\(suffix))"; suffix += 1
            }
        }
        defaults.set(try TextWorkflowArchive.encode(existing + incoming), forKey: Self.key)
        return incoming
    }
}
