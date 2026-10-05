import Foundation
import Darwin

/// Transportversion und Laufzeitgrenzen sind unabhängig von der App-Version.
public enum ControlProtocol {
    public static let version = 1
    public static let maximumMessageBytes = 65_536
    public static let maximumSnapshotBytes = 262_144
    public static let requestTimeout: TimeInterval = 10
    public static let jobTimeout: TimeInterval = 30
    public static let retentionSeconds: TimeInterval = 300
    public static let maximumJobs = 128
    public static let maximumSessions = 16
    public static let operations = ["capabilities", "objects", "snapshot", "explanation", "status", "cancel", "navigate", "close"]
    public static func endpoint(bundleIdentifier: String) -> String {
        "\(bundleIdentifier).control.v1.\(getuid())"
    }
    public static var capabilities: ControlCapabilities { ControlCapabilities() }
}

public struct ControlCapabilities: Codable, Equatable {
    public var protocolVersion = ControlProtocol.version
    public var operations = ControlProtocol.operations
    public var sourceKinds = ["fileSnapshot"]
    public var coordinates = "zero-based UTF-16; start inclusive, end exclusive; grapheme boundaries required"
    public var readOnly = true
    public var maximumSnapshotBytes = ControlProtocol.maximumSnapshotBytes
    public var maximumMessageBytes = ControlProtocol.maximumMessageBytes
    public var requestTimeoutSeconds = ControlProtocol.requestTimeout
    public var jobTimeoutSeconds = ControlProtocol.jobTimeout
    public var retentionSeconds = ControlProtocol.retentionSeconds
    public var maximumJobs = ControlProtocol.maximumJobs
    public var explanationSchemaVersion: Int? = 1
    public var maximumExplanationSteps: Int? = 5
    public var maximumExplanationTotalSourceBytes: Int? = 1_048_576
    public var explanationEncodings: [String]? = ["utf8"]
    public var maximumSessions = ControlProtocol.maximumSessions
    public var runtimeID: UUID?
    public var productVersion: String?
    public init() {}
}

public struct ControlFailure: Error, Codable, Equatable {
    public let code: String
    public let message: String
    public let appleScriptNumber: Int
    public init(_ code: String, _ message: String, _ appleScriptNumber: Int = -2700) {
        self.code = code; self.message = message; self.appleScriptNumber = appleScriptNumber
    }
    public static let invalidRequest = Self("invalidRequest", "The control request is invalid.", -1700)
    public static let unsupported = Self("unsupported", "This control operation or protocol is not supported.", -1708)
    public static let invalidID = Self("invalidID", "The runtime object no longer exists or belongs to another app run.", -1728)
    public static let stale = Self("stale", "The expected source or document binding does not match.")
    public static let invalidRange = Self("invalidRange", "The selection must be within the text and on complete character boundaries.")
    public static let source = Self("sourceUnavailable", "The source is unavailable or is not supported bounded text.")
    public static let capacity = Self("capacity", "The control session or job limit has been reached.")
    public static let expired = Self("expired", "The control request or job deadline has elapsed.")
    public static let interrupted = Self("interrupted", "The selection changed while navigation was pending.")
    public static let delivery = Self("delivery", "Fastra did not confirm the control request before the deadline.")
}

public struct ControlRequest: Codable, Equatable {
    public var version: Int
    public var id: UUID
    public var deadline: TimeInterval
    public var operation: String
    public var runtimeID: UUID?
    public var path: String?
    public var sha256: String?
    public var location: Int?
    public var length: Int?
    public var sessionID: UUID?
    public var documentID: UUID?
    public var jobID: UUID?

    public init(operation: String, id: UUID = UUID(), now: Date = Date(),
                path: String? = nil, sha256: String? = nil,
                location: Int? = nil, length: Int? = nil,
                sessionID: UUID? = nil, documentID: UUID? = nil, jobID: UUID? = nil, runtimeID: UUID? = nil) {
        version = ControlProtocol.version; self.id = id
        deadline = now.timeIntervalSince1970 + ControlProtocol.requestTimeout
        self.operation = operation; self.path = path; self.sha256 = sha256
        self.runtimeID = runtimeID
        self.location = location; self.length = length
        self.sessionID = sessionID; self.documentID = documentID; self.jobID = jobID
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= ControlProtocol.maximumMessageBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !object.values.contains(where: { $0 is NSNull }),
              Set(object.keys).isSubset(of: ["version", "id", "deadline", "operation", "runtimeID", "path", "sha256", "location", "length", "sessionID", "documentID", "jobID"]),
              let request = try? JSONDecoder().decode(Self.self, from: data) else {
            throw ControlFailure.invalidRequest
        }
        return request
    }

    public func validate(now: Date = Date(), allowExpired: Bool = false) throws {
        guard version == ControlProtocol.version, ControlProtocol.operations.contains(operation) else {
            throw ControlFailure.unsupported
        }
        guard deadline.isFinite, deadline > 0,
              (allowExpired || deadline > now.timeIntervalSince1970),
              deadline <= now.timeIntervalSince1970 + ControlProtocol.requestTimeout + 1 else {
            throw ControlFailure.expired
        }
        var present = Set<String>()
        if path != nil { present.insert("path") }
        if sha256 != nil { present.insert("sha256") }
        if location != nil { present.insert("location") }
        if length != nil { present.insert("length") }
        if sessionID != nil { present.insert("sessionID") }
        if documentID != nil { present.insert("documentID") }
        if jobID != nil { present.insert("jobID") }
        let expected: Set<String>
        switch operation {
        case "snapshot": expected = ["path", "sha256", "location", "length"]
        case "explanation": expected = ["path"]
        case "navigate": expected = ["sessionID", "documentID", "sha256", "location", "length"]
        case "status", "cancel": expected = ["jobID"]
        case "close": expected = ["sessionID"]
        default: expected = []
        }
        guard present == expected else { throw ControlFailure.invalidRequest }
        if let path {
            guard path.hasPrefix("/"), !path.contains("\0") else { throw ControlFailure.invalidRequest }
        }
        if let sha256 {
            guard sha256.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ControlFailure.invalidRequest
            }
        }
        if let location, let length {
            guard location >= 0, length >= 0, length <= Int.max - location else {
                throw ControlFailure.invalidRange
            }
        }
    }
}

public struct ControlSelection: Codable, Equatable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
    public var range: NSRange { NSRange(location: location, length: length) }
    public func validate(in text: String) throws {
        let count = text.utf16.count
        guard location >= 0, length >= 0, location <= count, length <= count - location else {
            throw ControlFailure.invalidRange
        }
        // String-Indizes können innerhalb eines Graphems liegen; deshalb alle
        // Character-Grenzen ausdrücklich prüfen, auch CRLF und Emoji-ZWJ.
        guard let range = Range(self.range, in: text) else { throw ControlFailure.invalidRange }
        var startIsBoundary = range.lowerBound == text.endIndex
        var endIsBoundary = range.upperBound == text.endIndex
        // Keine Offset-Tabelle für den ganzen Snapshot erzeugen. Ein linearer
        // Character-Durchlauf braucht konstanten zusätzlichen Speicher.
        for index in text.indices {
            if index == range.lowerBound { startIsBoundary = true }
            if index == range.upperBound { endIsBoundary = true }
            if startIsBoundary && endIsBoundary { break }
        }
        guard startIsBoundary, endIsBoundary else {
            throw ControlFailure.invalidRange
        }
    }
}

public struct ControlObject: Codable, Equatable {
    public var id: UUID
    public var kind: String
    public var name: String
    public var windowID: UUID?
    public var documentID: UUID?
    public var sessionID: UUID?
    public var sha256: String?
    public var selection: ControlSelection?
    public init(id: UUID, kind: String, name: String, windowID: UUID? = nil,
                documentID: UUID? = nil, sessionID: UUID? = nil, sha256: String? = nil,
                selection: ControlSelection? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.windowID = windowID
        self.documentID = documentID; self.sessionID = sessionID; self.sha256 = sha256
        self.selection = selection
    }
}

public struct ControlJob: Codable, Equatable {
    public var id: UUID
    public var requestID: UUID
    public var state: String
    public var sessionID: UUID
    public var windowID: UUID
    public var documentID: UUID
    public var sha256: String?
    public var textSHA256: String?
    public var byteCount: Int?
    public var encoding: UInt?
    public var bomBytes: Int?
    public var selection: ControlSelection?
    public var error: ControlFailure?
    public init(id: UUID, requestID: UUID, sessionID: UUID, windowID: UUID, documentID: UUID) {
        self.id = id; self.requestID = requestID; self.sessionID = sessionID
        self.windowID = windowID; self.documentID = documentID; state = "accepted"
    }
    public var isTerminal: Bool { ["ready", "failed", "cancelled"].contains(state) }
}

public struct ControlReply: Codable {
    public var protocolVersion = ControlProtocol.version
    public var runtimeID: UUID?
    public var capabilities: ControlCapabilities?
    public var objects: [ControlObject]?
    public var jobs: [ControlJob]?
    public var job: ControlJob?
    public var error: ControlFailure?
    public init(runtimeID: UUID? = nil, capabilities: ControlCapabilities? = nil,
                objects: [ControlObject]? = nil, jobs: [ControlJob]? = nil,
                job: ControlJob? = nil, error: ControlFailure? = nil) {
        self.runtimeID = runtimeID; self.capabilities = capabilities; self.objects = objects
        self.jobs = jobs; self.job = job; self.error = error
    }
}
