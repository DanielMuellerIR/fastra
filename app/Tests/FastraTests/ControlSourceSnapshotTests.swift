import AppKit
import FastraControlProtocol
import Foundation
import Testing
@testable import Fastra

struct ControlSourceSnapshotTests {
    private func fixture() throws -> (URL, URL, URL, ControlRequest) {
        let root = testTemporaryDirectory().appendingPathComponent("source-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outer = root.appendingPathComponent("Archiv #1.zip")
        let leaf = root.appendingPathComponent("sender.txt")
        try Data("outer archive fixture".utf8).write(to: outer)
        let bytes = Data("eins\n🇩🇪 zwei\n".utf8)
        try bytes.write(to: leaf)
        let provenance = ControlSourceProvenance(runID: UUID(), kind: "archiveMaterialization",
            hitIdentity: ControlHitIdentity(filesystemPath: outer.path, archiveMembers: ["Innen.zip", "notizen.txt"],
                archiveMemberBytes: ["Innen.zip", "notizen.txt"].map { Data($0.utf8).base64EncodedString() }),
            sourceGeneration: try ControlSourceSnapshot.generation(at: outer), archiveBinding: "sha256",
            outerSHA256: FileSnapshot.sha256Hex(try Data(contentsOf: outer)), positionBinding: "exactUTF16", searchEvidence: "🇩🇪")
        return (root, outer, leaf, ControlRequest(operation: "sourceSnapshot", path: leaf.path,
                sha256: FileSnapshot.sha256Hex(bytes), location: 5, length: 4, provenance: provenance))
    }

    @Test("Explizite Decoder erhalten Rohbytes, Text und UTF16-Auswahl")
    func explicitDecoders() throws {
        let (root, _, leaf, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "vor\r\nJahresbericht für Köln\r\n"
        for (name, encoding) in [("utf-8", String.Encoding.utf8), ("utf-16-le", .utf16LittleEndian),
                                 ("utf-16-be", .utf16BigEndian), ("windows-1252", .windowsCP1252),
                                 ("iso-8859-1", .isoLatin1), ("mac-roman", .macOSRoman)] {
            let bytes = try #require(text.data(using: encoding))
            try bytes.write(to: leaf)
            var request = original
            request.textEncoding = name
            request.sha256 = FileSnapshot.sha256Hex(bytes)
            request.location = 5; request.length = 22
            #expect(try ControlRequest.decode(JSONEncoder().encode(request)) == request)
            let snapshot = try ControlSourceSnapshot.adopt(request, temporaryRoot: root)
            defer { snapshot.remove() }
            #expect(snapshot.loaded.content.utf8.elementsEqual(text.utf8))
            #expect(snapshot.loaded.encoding == encoding)
            #expect(snapshot.loaded.diskSnapshot?.sha256 == request.sha256)
            #expect(try Data(contentsOf: snapshot.fileURL) == bytes)
            try ControlSelection(location: 5, length: 22).validate(in: snapshot.loaded.content)
        }
    }

    @Test("Explizites UTF16 erhält zweite BOM, Emoji, NFD und CRLF bytegenau")
    func explicitUTF16BOM() throws {
        let (root, _, leaf, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "\u{feff}😀 e\u{301}\r\nJahresbericht\r\n"
        for (name, encoding, bom) in [("utf-16-le", String.Encoding.utf16LittleEndian, Data([0xff, 0xfe])),
                                      ("utf-16-be", .utf16BigEndian, Data([0xfe, 0xff]))] {
            let bytes = bom + (try #require(text.data(using: encoding)))
            try bytes.write(to: leaf)
            var request = original; request.textEncoding = name
            request.sha256 = FileSnapshot.sha256Hex(bytes)
            request.location = 8; request.length = 13
            let snapshot = try ControlSourceSnapshot.adopt(request, temporaryRoot: root)
            defer { snapshot.remove() }
            #expect(snapshot.loaded.content.utf8.elementsEqual(text.utf8))
            #expect(snapshot.loaded.bom == bom)
            #expect(snapshot.loaded.diskSnapshot?.sha256 == request.sha256)
            #expect(try Data(contentsOf: snapshot.fileURL) == bytes)
        }
    }

    @Test("Unbekannte Decoder, falsche Operation und BOM-Widerspruch mutieren nichts")
    func invalidDecoderRequests() throws {
        let (root, _, leaf, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["auto", "utf-7", "UTF-8", "cp1252", ""] {
            var request = original; request.textEncoding = name
            #expect(throws: ControlFailure.invalidRequest) { try request.validate() }
        }
        var other = ControlRequest(operation: "capabilities"); other.textEncoding = "utf-8"
        #expect(throws: ControlFailure.invalidRequest) { try other.validate() }
        let bytes = Data([0xff, 0xfe, 0x41, 0])
        try bytes.write(to: leaf)
        var request = original; request.sha256 = FileSnapshot.sha256Hex(bytes)
        request.textEncoding = "utf-16-be"
        #expect(throws: ControlFailure.source) { try ControlSourceSnapshot.adopt(request, temporaryRoot: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ControlProtocol.capabilities)) as? [String: Any])
        old.removeValue(forKey: "sourceSnapshotTextEncodings")
        let decoded = try JSONDecoder().decode(ControlCapabilities.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.sourceSnapshotTextEncodings == nil)
        #expect(ControlProtocol.capabilities.sourceSnapshotTextEncodings == ControlProtocol.sourceSnapshotTextEncodings)
    }

    @Test("Eigene Rohbyte-Kopie überlebt entfernte Senderdatei und wird gezielt entfernt")
    func adoptionAndCleanup() throws {
        let (root, _, leaf, request) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try ControlSourceSnapshot.adopt(request, temporaryRoot: root)
        let ownFile = snapshot.fileURL
        #expect(ownFile != leaf)
        #expect(try FileSnapshot.read(from: ownFile).snapshot.sha256 == request.sha256)
        try FileManager.default.removeItem(at: leaf)
        #expect(snapshot.loaded.content == "eins\n🇩🇪 zwei\n")
        #expect(FileManager.default.fileExists(atPath: ownFile.path))
        ControlSourceSnapshot.pruneAbandoned(in: root)
        #expect(FileManager.default.fileExists(atPath: ownFile.path))
        snapshot.remove(); snapshot.remove()
        #expect(!FileManager.default.fileExists(atPath: ownFile.deletingLastPathComponent().path))
    }

    @Test("Falscher Blatt- und Archivhash sowie getauschte Quellengeneration werden abgewiesen")
    func staleSources() throws {
        let (root, outer, _, request) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var wrongLeaf = request; wrongLeaf.sha256 = String(repeating: "0", count: 64)
        #expect(throws: ControlFailure.stale) { try ControlSourceSnapshot.adopt(wrongLeaf, temporaryRoot: root) }
        let source = request.provenance!
        var wrongOuter = request
        wrongOuter.provenance = ControlSourceProvenance(runID: source.runID, kind: source.kind, hitIdentity: source.hitIdentity,
            sourceGeneration: source.sourceGeneration, archiveBinding: "sha256", outerSHA256: String(repeating: "0", count: 64), positionBinding: "exactUTF16")
        #expect(throws: ControlFailure.stale) { try ControlSourceSnapshot.adopt(wrongOuter, temporaryRoot: root) }
        try Data("replaced outer archive".utf8).write(to: outer, options: .atomic)
        #expect(throws: ControlFailure.stale) { try ControlSourceSnapshot.adopt(request, temporaryRoot: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }

    @Test("Geschachtelte unbekannte oder null-Felder und falsch gebundene Positionen sind ungültig")
    func strictSchema() throws {
        let (root, _, _, request) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = try JSONEncoder().encode(request)
        #expect(try ControlRequest.decode(raw) == request)
        for field in ["extra", "sourceGeneration", "hitIdentity"] {
            var object = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            var provenance = try #require(object["provenance"] as? [String: Any])
            if field == "extra" { provenance[field] = true }
            else {
                var nested = try #require(provenance[field] as? [String: Any]); nested["extra"] = NSNull(); provenance[field] = nested
            }
            object["provenance"] = provenance
            #expect(throws: ControlFailure.invalidRequest) { try ControlRequest.decode(JSONSerialization.data(withJSONObject: object)) }
        }
        let source = request.provenance!
        var unbound = request
        unbound.provenance = ControlSourceProvenance(runID: source.runID, kind: source.kind, hitIdentity: source.hitIdentity,
            sourceGeneration: source.sourceGeneration, archiveBinding: "generation", positionBinding: "unboundHit")
        #expect(throws: ControlFailure.invalidRequest) { try unbound.validate() }
        unbound.location = 0; unbound.length = 0
        try unbound.validate()
    }

    @Test("Gleiche Ersatznamen behalten unterschiedliche Byteidentität; widersprüchliche UTF8-Namen scheitern")
    @MainActor func identityAndVisibleLimits() throws {
        let (root, _, _, request) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = request.provenance!
        func provenance(_ byte: UInt8) -> ControlSourceProvenance {
            ControlSourceProvenance(runID: source.runID, kind: source.kind,
                hitIdentity: ControlHitIdentity(filesystemPath: source.hitIdentity.filesystemPath,
                    archiveMembers: ["�.txt"], archiveMemberBytes: [Data([byte] + Array(".txt".utf8)).base64EncodedString()]),
                sourceGeneration: source.sourceGeneration, archiveBinding: "generation", positionBinding: "unboundHit")
        }
        let first = provenance(0xff), second = provenance(0xfe)
        try first.validate(path: request.path!, location: 0, length: 0)
        try second.validate(path: request.path!, location: 0, length: 0)
        #expect(first.hitIdentity != second.hitIdentity)
        #expect(ControlSnapshotWindow.provenanceDescription(first) != ControlSnapshotWindow.provenanceDescription(second))
        #expect(ControlSnapshotWindow.provenanceDescription(first).contains(L10n.string("Schwächere Herkunftsbindung: Nur die Archivgeneration ist geprüft, nicht der äußere Inhaltsstand.")))
        let invalid = ControlSourceProvenance(runID: source.runID, kind: source.kind,
            hitIdentity: ControlHitIdentity(filesystemPath: source.hitIdentity.filesystemPath,
                archiveMembers: ["anderer Name"], archiveMemberBytes: [Data("original.txt".utf8).base64EncodedString()]),
            sourceGeneration: source.sourceGeneration, archiveBinding: "generation", positionBinding: "unboundHit")
        #expect(throws: ControlFailure.invalidRequest) { try invalid.validate(path: request.path!, location: 0, length: 0) }
    }

    @Test("Archivhash-Prüfung bleibt begrenzt, expliziter Generation-Bezug bleibt nutzbar")
    func boundedOuterVerification() throws {
        let (root, outer, _, request) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let handle = try FileHandle(forWritingTo: outer)
        try handle.truncate(atOffset: UInt64(ControlProtocol.maximumOuterArchiveBytes + 1)); try handle.close()
        let source = request.provenance!
        let generation = try ControlSourceSnapshot.generation(at: outer)
        var value = request
        value.provenance = ControlSourceProvenance(runID: source.runID, kind: source.kind, hitIdentity: source.hitIdentity,
            sourceGeneration: generation, archiveBinding: "sha256", outerSHA256: source.outerSHA256, positionBinding: "exactUTF16")
        #expect(throws: ControlFailure.source) { try ControlSourceSnapshot.adopt(value, temporaryRoot: root) }
        value.provenance = ControlSourceProvenance(runID: source.runID, kind: source.kind, hitIdentity: source.hitIdentity,
            sourceGeneration: generation, archiveBinding: "generation", positionBinding: "exactUTF16")
        let adopted = try ControlSourceSnapshot.adopt(value, temporaryRoot: root)
        adopted.remove()
    }

    @Test("Verwaiste eigene Wurzel wird bereinigt; fremde Ordner und Symlinks bleiben erhalten")
    func scopedPruning() throws {
        let root = testTemporaryDirectory().appendingPathComponent("prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = UUID()
        let own = root.appendingPathComponent("FastraSourceSnapshot-v1-\(identifier)")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: false)
        try JSONSerialization.data(withJSONObject: ["schema": 1, "ownerPID": Int32.max, "identifier": identifier.uuidString])
            .write(to: own.appendingPathComponent("owner.json"))
        let foreign = root.appendingPathComponent("FastraSourceSnapshot-v1-\(UUID())")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("FastraSourceSnapshot-v1-\(UUID())")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
        ControlSourceSnapshot.pruneAbandoned(in: root)
        #expect(!FileManager.default.fileExists(atPath: own.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == foreign.path)
    }

    @Test("Job bestätigt eigene Übernahme erst nach echter Auswahl; Schließen entfernt nur seine Kopie")
    @MainActor func readyAndClose() async throws {
        _ = NSApplication.shared
        let (root, _, leaf, request) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = LocalControlController(showWindows: false)
        defer { controller.closeAllSessions() }
        let accepted = try #require(controller.execute(request).job)
        #expect(accepted.state == "accepted" && accepted.adopted == false)
        #expect(await waitUntil { controller.jobValues.first(where: { $0.id == accepted.id })?.isTerminal == true })
        let job = try #require(controller.jobValues.first(where: { $0.id == accepted.id }))
        #expect(job.state == "ready" && job.adopted == true && job.provenance == request.provenance)
        let window = try #require(controller.snapshotWindowsForTesting.first)
        let owned = try #require(window.sourceSnapshot?.fileURL)
        #expect(window.confirms(ControlSelection(location: 5, length: 4)))
        #expect(!window.textView.isEditable)
        try FileManager.default.removeItem(at: leaf)
        #expect(window.textView.string == "eins\n🇩🇪 zwei\n")
        #expect(try FileSnapshot.read(from: owned).snapshot.sha256 == request.sha256)
        #expect(try controller.execute(request).job?.id == job.id)
        _ = try controller.execute(ControlRequest(operation: "close", sessionID: job.sessionID))
        #expect(!FileManager.default.fileExists(atPath: owned.path))
    }

    @Test("Sofortiger Abbruch lässt keinen späteren Snapshot installieren")
    @MainActor func cancelledJob() async throws {
        _ = NSApplication.shared
        let (root, _, leaf, request) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = LocalControlController(showWindows: false)
        defer { controller.closeAllSessions() }
        let job = try #require(controller.execute(request).job)
        _ = try controller.execute(ControlRequest(operation: "cancel", jobID: job.id))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(controller.jobValues.first?.state == "cancelled")
        #expect(controller.snapshotWindowsForTesting.first?.sourceSnapshot == nil)
        #expect(controller.snapshotWindowsForTesting.first?.loaded == nil)
        #expect(FileManager.default.fileExists(atPath: leaf.path))
    }

    @Test("Fehlerhafte Graphemposition räumt die bereits angelegte Kopie wieder auf")
    func invalidGraphemeCleanup() throws {
        let (root, _, _, request) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var invalid = request; invalid.location = 6; invalid.length = 1
        #expect(throws: ControlFailure.invalidRange) { try ControlSourceSnapshot.adopt(invalid, temporaryRoot: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }

    @Test("Bereits angenommene Übergabe bleibt nach Ablauf ihrer Annahmefrist ausführbar")
    func acceptedDeadline() throws {
        let (root, _, _, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var request = original
        request.deadline = Date().timeIntervalSince1970 - 1
        let snapshot = try ControlSourceSnapshot.adopt(request, temporaryRoot: root)
        #expect(snapshot.loaded.diskSnapshot?.sha256 == request.sha256)
        snapshot.remove()
    }
}
