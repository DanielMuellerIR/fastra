import Foundation
import Darwin
import FastraControlProtocol

struct CodeExplanationManifest: Codable, Equatable {
    struct Source: Codable, Equatable {
        let id: UUID
        let path: String
        let sha256: String
        let encoding: String
    }
    struct Step: Codable, Equatable {
        let id: UUID
        let title: String
        let text: String
        let sourceID: UUID
        let location: Int
        let length: Int
    }
    let schemaVersion: Int
    let id: UUID
    let title: String
    let question: String
    let language: String
    let createdAt: String
    let projectID: UUID
    let projectName: String
    let sources: [Source]
    let steps: [Step]
    let codeFontSize: Double
    let explanationFontSize: Double
}

struct CodeExplanationPackage {
    let manifest: CodeExplanationManifest
    let loadedSources: [UUID: FileLoader.LoadedFile]
    static let maximumBytes = 1024 * 1024

    static func load(path: String) throws -> Self {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw ControlFailure.invalidRequest }
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        // Der Root selbst darf kein Symlink sein. Alle weiteren Komponenten
        // bleiben relativ an genau diesem geöffneten Ordner gebunden.
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw ControlFailure.source }
        defer { close(root) }
        let descriptor = try openFile(url.lastPathComponent, root: root)
        let data: Data
        do {
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_size <= 65_536 else { throw ControlFailure.source }
            data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: 65_537) ?? Data()
        }
        guard data.count <= 65_536 else { throw ControlFailure.invalidRequest }
        try validateKeys(data)
        guard let manifest = try? JSONDecoder().decode(CodeExplanationManifest.self, from: data) else {
            throw ControlFailure.invalidRequest
        }
        guard manifest.schemaVersion == 1, ["de", "en"].contains(manifest.language),
              ISO8601DateFormatter().date(from: manifest.createdAt) != nil,
              !manifest.title.isEmpty, manifest.title.count <= 200,
              !manifest.question.isEmpty, manifest.question.count <= 2000,
              !manifest.projectName.isEmpty, manifest.projectName.count <= 200,
              (8...32).contains(manifest.codeFontSize), (8...32).contains(manifest.explanationFontSize),
              (1...5).contains(manifest.sources.count), (2...5).contains(manifest.steps.count),
              Set(manifest.sources.map(\.id)).count == manifest.sources.count,
              Set(manifest.steps.map(\.id)).count == manifest.steps.count else { throw ControlFailure.invalidRequest }
        var sources: [UUID: FileLoader.LoadedFile] = [:]
        var total: UInt64 = 0
        for source in manifest.sources {
            guard !Task.isCancelled else { throw CancellationError() }
            guard source.encoding == "utf8", source.sha256.count == 64,
                  source.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ControlFailure.invalidRequest
            }
            let fd = try openFile(source.path, root: root)
            defer { close(fd) }
            let loaded: FileLoader.LoadedFile
            do {
                loaded = try FileLoader.load(descriptor: fd, forcedEncoding: .utf8,
                    largeFileThreshold: UInt64(ControlProtocol.maximumSnapshotBytes),
                    isCancelled: { Task.isCancelled })
            } catch { throw Task.isCancelled ? CancellationError() : ControlFailure.source }
            guard loaded.displayMode == .text, let hash = loaded.diskSnapshot?.sha256,
                  loaded.fileSize <= ControlProtocol.maximumSnapshotBytes else { throw ControlFailure.source }
            // Der explizite Encoding-Pfad erlaubt im Editor auch fremde BOMs
            // und Nullbytes. Pakete verlangen dagegen echte UTF-8-Textquellen.
            guard loaded.encoding == .utf8,
                  loaded.bom.isEmpty || loaded.bom == Data([0xEF, 0xBB, 0xBF]),
                  !loaded.content.utf8.contains(0) else { throw ControlFailure.source }
            guard hash == source.sha256 else { throw ControlFailure.stale }
            total += loaded.fileSize
            guard total <= maximumBytes else { throw ControlFailure.capacity }
            sources[source.id] = loaded
        }
        for step in manifest.steps {
            guard !step.title.isEmpty, step.title.count <= 200, !step.text.isEmpty, step.text.count <= 4096,
                  let source = sources[step.sourceID] else { throw ControlFailure.invalidRequest }
            try ControlSelection(location: step.location, length: step.length).validate(in: source.content)
        }
        return Self(manifest: manifest, loadedSources: sources)
    }

    private static func openFile(_ relative: String, root: Int32) throws -> Int32 {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relative.hasPrefix("/"), !relative.contains("\0"),
              !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ControlFailure.invalidRequest
        }
        var directory = dup(root)
        guard directory >= 0 else { throw ControlFailure.source }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ControlFailure.source }
            close(directory); directory = next
        }
        let fd = openat(directory, components.last!, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ControlFailure.source }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(fd); throw ControlFailure.source
        }
        return fd
    }

    private static func validateKeys(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "id", "title", "question", "language", "createdAt",
                                   "projectID", "projectName", "sources", "steps", "codeFontSize", "explanationFontSize"],
              let sources = object["sources"] as? [[String: Any]],
              let steps = object["steps"] as? [[String: Any]],
              sources.allSatisfy({ Set($0.keys) == ["id", "path", "sha256", "encoding"] }),
              steps.allSatisfy({ Set($0.keys) == ["id", "title", "text", "sourceID", "location", "length"] }) else {
            throw ControlFailure.invalidRequest
        }
    }
}
