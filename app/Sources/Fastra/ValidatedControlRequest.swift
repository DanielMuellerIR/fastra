import FastraControlProtocol
import Foundation

/// Die Wire-Felder bleiben optional. Hinter der Vertragsprüfung besitzen
/// alle Operationen ihre erforderlichen Werte unveränderlich.
struct ValidatedControlSnapshotRequest {
    let id: UUID
    let path: String
    let sha256: String
    let selection: ControlSelection

    fileprivate init(_ request: ControlRequest) throws {
        guard request.operation == "snapshot", let path = request.path, let sha256 = request.sha256,
              let location = request.location, let length = request.length else { throw ControlFailure.invalidRequest }
        id = request.id; self.path = path; self.sha256 = sha256
        selection = ControlSelection(location: location, length: length)
    }
}

struct ValidatedControlSourceSnapshotRequest {
    let id: UUID
    let path: String
    let sha256: String
    let selection: ControlSelection
    let provenance: ControlSourceProvenance
    let textEncoding: String?

    fileprivate init(_ request: ControlRequest) throws {
        guard request.operation == "sourceSnapshot", let path = request.path, let sha256 = request.sha256,
              let location = request.location, let length = request.length,
              let provenance = request.provenance else { throw ControlFailure.invalidRequest }
        id = request.id; self.path = path; self.sha256 = sha256
        selection = ControlSelection(location: location, length: length)
        self.provenance = provenance; textEncoding = request.textEncoding
    }
}

struct ValidatedControlNavigationRequest {
    let id: UUID
    let sessionID: UUID
    let documentID: UUID
    let sha256: String
    let selection: ControlSelection

    fileprivate init(_ request: ControlRequest) throws {
        guard request.operation == "navigate", let sessionID = request.sessionID, let documentID = request.documentID,
              let sha256 = request.sha256, let location = request.location, let length = request.length else {
            throw ControlFailure.invalidRequest
        }
        id = request.id; self.sessionID = sessionID; self.documentID = documentID; self.sha256 = sha256
        selection = ControlSelection(location: location, length: length)
    }
}

/// Einzige Umwandlung vom optionalen Wire-Format in ausführbare Operationen.
/// Runtime-ID und Wiederholung prüft der Controller weiterhin davor.
enum ValidatedControlOperation {
    case capabilities
    case objects
    case snapshot(ValidatedControlSnapshotRequest)
    case sourceSnapshot(ValidatedControlSourceSnapshotRequest)
    case explanation(requestID: UUID, path: String)
    case navigate(ValidatedControlNavigationRequest)
    case status(jobID: UUID)
    case cancel(jobID: UUID)
    case close(sessionID: UUID)

    init(_ request: ControlRequest, allowExpired: Bool = false) throws {
        try request.validate(allowExpired: allowExpired)
        switch request.operation {
        case "capabilities": self = .capabilities
        case "objects": self = .objects
        case "snapshot": self = .snapshot(try ValidatedControlSnapshotRequest(request))
        case "sourceSnapshot": self = .sourceSnapshot(try ValidatedControlSourceSnapshotRequest(request))
        case "explanation":
            guard let path = request.path else { throw ControlFailure.invalidRequest }
            self = .explanation(requestID: request.id, path: path)
        case "navigate": self = .navigate(try ValidatedControlNavigationRequest(request))
        case "status":
            guard let jobID = request.jobID else { throw ControlFailure.invalidRequest }
            self = .status(jobID: jobID)
        case "cancel":
            guard let jobID = request.jobID else { throw ControlFailure.invalidRequest }
            self = .cancel(jobID: jobID)
        case "close":
            guard let sessionID = request.sessionID else { throw ControlFailure.invalidRequest }
            self = .close(sessionID: sessionID)
        default: throw ControlFailure.unsupported
        }
    }
}
