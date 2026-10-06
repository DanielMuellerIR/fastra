import Foundation

/// Die Generation bezeichnet den äußeren Quellstand, nicht den Temp-Pfad.
public struct ControlSourceGeneration: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let changeSeconds: Int64
    public let changeNanoseconds: Int64
    public init(device: UInt64, inode: UInt64, size: UInt64, modificationSeconds: Int64,
                modificationNanoseconds: Int64, changeSeconds: Int64, changeNanoseconds: Int64) {
        self.device = device; self.inode = inode; self.size = size
        self.modificationSeconds = modificationSeconds; self.modificationNanoseconds = modificationNanoseconds
        self.changeSeconds = changeSeconds; self.changeNanoseconds = changeNanoseconds
    }
}

public struct ControlHitIdentity: Codable, Equatable, Sendable {
    public let filesystemPath: String
    public let archiveMembers: [String]
    public let archiveMemberBytes: [String]
    public init(filesystemPath: String, archiveMembers: [String], archiveMemberBytes: [String]) {
        self.filesystemPath = filesystemPath; self.archiveMembers = archiveMembers
        self.archiveMemberBytes = archiveMemberBytes
    }
}

public struct ControlSourceProvenance: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let runID: UUID
    public let kind: String
    public let hitIdentity: ControlHitIdentity
    public let sourceGeneration: ControlSourceGeneration
    public let archiveBinding: String
    public let outerSHA256: String?
    public let positionBinding: String
    public let searchEvidence: String?
    public init(runID: UUID, kind: String, hitIdentity: ControlHitIdentity,
                sourceGeneration: ControlSourceGeneration, archiveBinding: String,
                outerSHA256: String? = nil, positionBinding: String, searchEvidence: String? = nil) {
        schemaVersion = 1; self.runID = runID; self.kind = kind; self.hitIdentity = hitIdentity
        self.sourceGeneration = sourceGeneration; self.archiveBinding = archiveBinding
        self.outerSHA256 = outerSHA256; self.positionBinding = positionBinding; self.searchEvidence = searchEvidence
    }

    static func validateJSON(_ value: Any) throws {
        func object(_ value: Any, required: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
            guard let object = value as? [String: Any], !object.values.contains(where: { $0 is NSNull }),
                  required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: required.union(optional)) else {
                throw ControlFailure.invalidRequest
            }
            return object
        }
        let root = try object(value, required: ["schemaVersion", "runID", "kind", "hitIdentity", "sourceGeneration", "archiveBinding", "positionBinding"],
                              optional: ["outerSHA256", "searchEvidence"])
        _ = try object(root["hitIdentity"]!, required: ["filesystemPath", "archiveMembers", "archiveMemberBytes"])
        _ = try object(root["sourceGeneration"]!, required: ["device", "inode", "size", "modificationSeconds", "modificationNanoseconds", "changeSeconds", "changeNanoseconds"])
    }

    public func validate(path: String, location: Int, length: Int) throws {
        let identity = hitIdentity
        guard schemaVersion == 1, ["original", "archiveMaterialization"].contains(kind),
              identity.filesystemPath.hasPrefix("/"), !identity.filesystemPath.contains("\0"),
              identity.filesystemPath.utf8.count <= 16_384,
              identity.archiveMembers.count <= 32, identity.archiveMembers.count == identity.archiveMemberBytes.count,
              identity.archiveMembers.allSatisfy({ !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 4096 }),
              identity.archiveMemberBytes.allSatisfy({ value in
                  guard let bytes = Data(base64Encoded: value), !bytes.isEmpty, bytes.count <= 4096 else { return false }
                  return bytes.base64EncodedString() == value && !bytes.contains(0)
              }), sourceGeneration.modificationNanoseconds >= 0, sourceGeneration.modificationNanoseconds < 1_000_000_000,
              sourceGeneration.changeNanoseconds >= 0, sourceGeneration.changeNanoseconds < 1_000_000_000,
              ["exactUTF16", "unboundHit"].contains(positionBinding),
              positionBinding != "unboundHit" || (location == 0 && length == 0),
              searchEvidence.map({ $0.utf8.count <= 4096 && !$0.contains("\0") }) ?? true else {
            throw ControlFailure.invalidRequest
        }
        for (name, encoded) in zip(identity.archiveMembers, identity.archiveMemberBytes) {
            let bytes = Data(base64Encoded: encoded)!
            if let decoded = String(data: bytes, encoding: .utf8), !decoded.utf8.elementsEqual(name.utf8) {
                throw ControlFailure.invalidRequest
            }
        }
        if kind == "original" {
            guard identity.archiveMembers.isEmpty, archiveBinding == "notApplicable", outerSHA256 == nil,
                  URL(fileURLWithPath: path).standardizedFileURL == URL(fileURLWithPath: identity.filesystemPath).standardizedFileURL else {
                throw ControlFailure.invalidRequest
            }
        } else {
            guard !identity.archiveMembers.isEmpty, ["sha256", "generation"].contains(archiveBinding) else {
                throw ControlFailure.invalidRequest
            }
            if archiveBinding == "sha256" {
                guard let hash = outerSHA256, hash.count == 64,
                      hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw ControlFailure.invalidRequest
                }
            } else if outerSHA256 != nil { throw ControlFailure.invalidRequest }
        }
    }
}
