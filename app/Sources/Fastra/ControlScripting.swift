import AppKit
import FastraControlProtocol

/// Keine Cocoa-Standardbefehle oder schreibbaren Dokumenteigenschaften exportieren.
@objc(FastraControlScriptCommand)
final class ControlScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            do {
                let request: ControlRequest
                switch commandDescription.commandName {
                case "control capabilities": request = ControlRequest(operation: "capabilities")
                case "control inventory": request = ControlRequest(operation: "objects")
                default:
                    guard let json = directParameter as? String else { throw ControlFailure.invalidRequest }
                    request = try ControlRequest.decode(Data(json.utf8))
                }
                let reply = try LocalControlController.shared.execute(request)
                return String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
            } catch {
                let failure = error as? ControlFailure ?? .invalidRequest
                scriptErrorNumber = failure.appleScriptNumber
                scriptErrorString = failure.message
                return nil
            }
        }
    }
}

/// Scripting-Objekte enthalten nur IDs. Jede Property wird neu vom Controller
/// aufgelöst; ein altes Objekt hält kein geschlossenes Fenster am Leben.
@objc(FastraControlScriptObject)
class ControlScriptObject: NSObject {
    let objectID: UUID
    let collectionKey: String
    init(_ id: UUID, key: String) { objectID = id; collectionKey = key; super.init() }
    @objc dynamic var controlID: String { objectID.uuidString }
    @objc dynamic var details: String {
        MainActor.assumeIsolated {
            let data: Data?
            if collectionKey == "controlJobs" {
                data = LocalControlController.shared.jobValues.first(where: { $0.id == objectID })
                    .flatMap { try? JSONEncoder().encode($0) }
            } else {
                data = LocalControlController.shared.objects().first(where: { $0.id == objectID })
                    .flatMap { try? JSONEncoder().encode($0) }
            }
            return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }
    }
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let description = NSApplication.shared.classDescription as? NSScriptClassDescription else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: nil,
                                   key: collectionKey, uniqueID: controlID)
    }
}
@objc(FastraControlScriptWindow)
final class ControlScriptWindow: ControlScriptObject {}
@objc(FastraControlScriptDocument)
final class ControlScriptDocument: ControlScriptObject {}
@objc(FastraControlScriptSession)
final class ControlScriptSession: ControlScriptObject {}
@objc(FastraControlScriptJob)
final class ControlScriptJob: ControlScriptObject {}

extension NSApplication {
    @objc dynamic var controlWindows: [ControlScriptWindow] {
        MainActor.assumeIsolated {
            LocalControlController.shared.objects().filter { $0.kind == "window" }
                .map { ControlScriptWindow($0.id, key: "controlWindows") }
        }
    }
    @objc dynamic var controlDocuments: [ControlScriptDocument] {
        MainActor.assumeIsolated {
            LocalControlController.shared.objects().filter { $0.kind == "document" }
                .map { ControlScriptDocument($0.id, key: "controlDocuments") }
        }
    }
    @objc dynamic var controlSessions: [ControlScriptSession] {
        MainActor.assumeIsolated {
            LocalControlController.shared.objects().filter { $0.kind == "session" }
                .map { ControlScriptSession($0.id, key: "controlSessions") }
        }
    }
    @objc dynamic var controlJobs: [ControlScriptJob] {
        MainActor.assumeIsolated {
            LocalControlController.shared.jobValues.map { ControlScriptJob($0.id, key: "controlJobs") }
        }
    }
}

extension NSApplication {
    @objc(valueInControlWindowsWithUniqueID:)
    func controlWindow(uniqueID: String) -> ControlScriptWindow? {
        controlWindows.first { $0.controlID == uniqueID }
    }
    @objc(valueInControlDocumentsWithUniqueID:)
    func controlDocument(uniqueID: String) -> ControlScriptDocument? {
        controlDocuments.first { $0.controlID == uniqueID }
    }
    @objc(valueInControlSessionsWithUniqueID:)
    func controlSession(uniqueID: String) -> ControlScriptSession? {
        controlSessions.first { $0.controlID == uniqueID }
    }
    @objc(valueInControlJobsWithUniqueID:)
    func controlJob(uniqueID: String) -> ControlScriptJob? {
        controlJobs.first { $0.controlID == uniqueID }
    }
}
