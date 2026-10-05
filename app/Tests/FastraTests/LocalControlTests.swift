import AppKit
import Foundation
import Testing
import FastraControlProtocol
@testable import Fastra

@Suite("Lokale Steuerung: Vertrag und eingefrorene Quellen")
struct LocalControlContractTests {
    @Test("Capabilities vor dem Player bleiben lesbar")
    func olderCapabilities() throws {
        let data = try JSONEncoder().encode(ControlProtocol.capabilities)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["explanationSchemaVersion", "maximumExplanationSteps", "maximumExplanationTotalSourceBytes", "explanationEncodings"] {
            object.removeValue(forKey: key)
        }
        object["operations"] = ["capabilities", "objects", "snapshot", "status", "cancel", "navigate", "close"]
        let older = try JSONDecoder().decode(ControlCapabilities.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.explanationSchemaVersion == nil && !older.operations.contains("explanation"))
    }
    @Test("Unbekannte Felder und Operationen werden abgewiesen")
    func strictRequests() throws {
        let request = ControlRequest(operation: "capabilities")
        let data = try JSONEncoder().encode(request)
        #expect(try ControlRequest.decode(data) == request)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["extra"] = true
        #expect(throws: ControlFailure.invalidRequest) { try ControlRequest.decode(JSONSerialization.data(withJSONObject: json)) }
        #expect(throws: ControlFailure.unsupported) { try ControlRequest(operation: "write").validate() }
        #expect(throws: ControlFailure.invalidRequest) { try ControlRequest(operation: "capabilities", path: "/tmp/x").validate() }
    }

    @Test("Fristen, Hash und Überlauf sind Vertragsfehler")
    func requestLimits() throws {
        var request = ControlRequest(operation: "snapshot", path: "/tmp/x", sha256: String(repeating: "a", count: 64),
                                     location: 0, length: 0)
        try request.validate()
        request.length = Int.max; request.location = 1
        #expect(throws: ControlFailure.invalidRange) { try request.validate() }
        request.location = 0; request.length = 0; request.sha256 = "a"
        #expect(throws: ControlFailure.invalidRequest) { try request.validate() }
        request.sha256 = String(repeating: "a", count: 64); request.deadline = 0
        #expect(throws: ControlFailure.expired) { try request.validate() }
    }

    @Test("UTF16-Auswahl respektiert Emoji, Grapheme, CRLF und EOF")
    func graphemeRanges() throws {
        let text = "a\r\n😀e\u{301}\n"
        for location in [0, 1, 3, 5, 7, 8] {
            try ControlSelection(location: location, length: 0).validate(in: text)
        }
        for location in [2, 4, 6, 9] {
            #expect(throws: ControlFailure.invalidRange) {
                try ControlSelection(location: location, length: 0).validate(in: text)
            }
        }
        try ControlSelection(location: 3, length: 4).validate(in: text)
        #expect(throws: ControlFailure.invalidRange) {
            try ControlSelection(location: 3, length: 3).validate(in: text)
        }
        try ControlSelection(location: 0, length: 0).validate(in: "")
    }

    @Test("Loader bindet Originalbytes einschließlich UTF16-BOM")
    func byteBinding() throws {
        let root = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.txt")
        let bytes = Data([0xff, 0xfe]) + Data("one\r\n😀\n".utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
        try bytes.write(to: url)
        let request = ControlRequest(operation: "snapshot", path: url.path,
                                     sha256: FileSnapshot.sha256Hex(bytes), location: 5, length: 2)
        let loaded = try ControlSnapshotLoader.load(request)
        #expect(loaded.content == "one\r\n😀\n")
        #expect(loaded.bom == Data([0xff, 0xfe]))
        #expect(loaded.diskSnapshot?.sha256 == request.sha256)
        var stale = request; stale.sha256 = String(repeating: "0", count: 64)
        #expect(throws: ControlFailure.stale) { try ControlSnapshotLoader.load(stale) }
    }

    @Test("Loader lehnt Binärdaten, Verzeichnisse, FIFO und große Quellen ab")
    func sourceLimits() throws {
        let root = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample")
        func rejected(_ path: String) {
            let request = ControlRequest(operation: "snapshot", path: path,
                                         sha256: String(repeating: "0", count: 64), location: 0, length: 0)
            #expect(throws: ControlFailure.source) { try ControlSnapshotLoader.load(request) }
        }
        try Data([0, 1, 2]).write(to: url)
        rejected(url.path); rejected(root.path)
        try Data(repeating: 65, count: ControlProtocol.maximumSnapshotBytes + 1).write(to: url)
        rejected(url.path)
        let fifo = root.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        rejected(fifo.path)
    }
}

@Suite("Lokale Steuerung: Jobs und reale schreibgeschützte Auswahl", .serialized)
@MainActor
struct LocalControlJobTests {
    private func fixture(_ text: String = "one\n😀 two\n") throws -> (URL, ControlRequest) {
        let url = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        let bytes = Data(text.utf8)
        try bytes.write(to: url)
        return (url, ControlRequest(operation: "snapshot", path: url.path,
                                  sha256: FileSnapshot.sha256Hex(bytes), location: 4, length: 2))
    }
    private func wait(_ controller: LocalControlController, _ id: UUID) async throws -> ControlJob {
        for _ in 0..<100 {
            let value = try #require(controller.execute(ControlRequest(operation: "status", jobID: id)).job)
            if value.isTerminal { return value }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ControlFailure.expired
    }

    @Test("accepted ist nicht ready; fertige Auswahl, Duplikat und geschlossenes Ziel")
    func lifecycle() async throws {
        _ = NSApplication.shared
        let (url, originalRequest) = try fixture()
        var request = originalRequest
        request.deadline = Date().timeIntervalSince1970 + 0.05
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = LocalControlController(showWindows: false)
        #expect(throws: ControlFailure.invalidID) {
            try controller.execute(ControlRequest(operation: "capabilities", runtimeID: UUID()))
        }
        #expect(try controller.execute(ControlRequest(operation: "capabilities", runtimeID: controller.runtimeID)).runtimeID == controller.runtimeID)
        let accepted = try #require(controller.execute(request).job)
        #expect(accepted.state == "accepted")
        #expect(try controller.execute(request).job?.id == accepted.id)
        var conflict = request; conflict.length = 0
        #expect(throws: ControlFailure.invalidRequest) { try controller.execute(conflict) }
        let job = try await wait(controller, accepted.id)
        #expect(job.state == "ready")
        #expect(job.sha256 == request.sha256)
        #expect(job.selection == ControlSelection(location: 4, length: 2))
        // Die Bestätigung kann nach Ablauf der Annahmefrist verloren gehen;
        // derselbe Auftrag bleibt innerhalb der Retention trotzdem abfragbar.
        #expect(try controller.execute(request).job?.id == accepted.id)
        try Data("changed on disk".utf8).write(to: url)
        let nav = ControlRequest(operation: "navigate", sha256: request.sha256, location: 0, length: 3,
                                 sessionID: job.sessionID, documentID: job.documentID)
        let navigated = try await wait(controller, #require(controller.execute(nav).job?.id))
        #expect(navigated.state == "ready")
        #expect(navigated.selection == ControlSelection(location: 0, length: 3))
        var stale = nav; stale.id = UUID(); stale.sha256 = String(repeating: "0", count: 64)
        stale.deadline = Date().timeIntervalSince1970 + ControlProtocol.requestTimeout
        #expect(throws: ControlFailure.stale) { try controller.execute(stale) }
        _ = try controller.execute(ControlRequest(operation: "close", sessionID: job.sessionID))
        var closed = nav; closed.id = UUID()
        closed.deadline = Date().timeIntervalSince1970 + ControlProtocol.requestTimeout
        #expect(throws: ControlFailure.invalidID) { try controller.execute(closed) }
    }

    @Test("Abbruch vor verspätetem Laden stellt keinen Inhalt bereit")
    func cancelledLoad() async throws {
        _ = NSApplication.shared
        let (url, request) = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try ControlSnapshotLoader.load(request)
        let controller = LocalControlController(showWindows: false, load: { _ in
            // Absichtlich unkooperative Completion: Auch ohne Task-Abbruch
            // muss die Generation ein nachträgliches Installieren verhindern.
            try? await Task.sleep(nanoseconds: 80_000_000)
            return loaded
        })
        let job = try #require(controller.execute(request).job)
        await Task.yield()
        #expect(try controller.execute(ControlRequest(operation: "status", jobID: job.id)).job?.state == "loading")
        _ = try controller.execute(ControlRequest(operation: "cancel", jobID: job.id))
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(try controller.execute(ControlRequest(operation: "status", jobID: job.id)).job?.state == "cancelled")
        let document = controller.objects().first { $0.id == job.documentID }
        #expect(document?.sha256 == nil)
        _ = try controller.execute(ControlRequest(operation: "close", sessionID: job.sessionID))
    }


    @Test("Eigene Auswahl und geschlossener Ladevorgang entwerten spätere Antworten")
    func manualSelectionAndClose() async throws {
        _ = NSApplication.shared
        let (url, request) = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = LocalControlController(showWindows: false)
        let accepted = try #require(controller.execute(request).job)
        defer { _ = try? controller.execute(ControlRequest(operation: "close", sessionID: accepted.sessionID)) }
        let ready = try await wait(controller, accepted.id)
        #expect(ready.state == "ready")
        let nav = ControlRequest(operation: "navigate", sha256: request.sha256, location: 0, length: 3,
                                 sessionID: ready.sessionID, documentID: ready.documentID)
        let pending = try #require(controller.execute(nav).job)
        await Task.yield()
        let window = try #require(controller.snapshotWindowsForTesting.first)
        window.textView.setSelectedRange(NSRange(location: 1, length: 0))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(try controller.execute(ControlRequest(operation: "status", jobID: pending.id)).job?.state == "cancelled")
        #expect(window.textView.selectedRange() == NSRange(location: 1, length: 0))

        let loaded = try ControlSnapshotLoader.load(request)
        let closing = LocalControlController(showWindows: false, load: { _ in
            try? await Task.sleep(nanoseconds: 80_000_000)
            return loaded
        })
        let loading = try #require(closing.execute(request).job)
        await Task.yield()
        _ = try closing.execute(ControlRequest(operation: "close", sessionID: loading.sessionID))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(try closing.execute(ControlRequest(operation: "status", jobID: loading.id)).job?.state == "cancelled")
        #expect(!closing.objects().contains { $0.id == loading.windowID || $0.id == loading.documentID })
    }

    @Test("Neuere Navigation gewinnt gegenüber einem noch nicht bereiten Vorgänger")
    func supersededNavigation() async throws {
        _ = NSApplication.shared
        let (url, request) = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = LocalControlController(showWindows: false)
        let accepted = try #require(controller.execute(request).job)
        defer { _ = try? controller.execute(ControlRequest(operation: "close", sessionID: accepted.sessionID)) }
        let ready = try await wait(controller, accepted.id)
        let first = try #require(controller.execute(ControlRequest(operation: "navigate", sha256: request.sha256,
                          location: 0, length: 3, sessionID: ready.sessionID, documentID: ready.documentID)).job)
        await Task.yield()
        let second = try #require(controller.execute(ControlRequest(operation: "navigate", sha256: request.sha256,
                           location: 4, length: 2, sessionID: ready.sessionID, documentID: ready.documentID)).job)
        let final = try await wait(controller, second.id)
        #expect(final.state == "ready")
        #expect(final.selection == ControlSelection(location: 4, length: 2))
        #expect(try controller.execute(ControlRequest(operation: "status", jobID: first.id)).job?.state == "cancelled")
    }
    @Test("Suchfenster erzeugt keine zweite Dokumentidentität")
    func inventoryExcludesSearchWindow() throws {
        _ = NSApplication.shared
        let suite = "fastra-test-control-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        let normal = NSWindow(); normal.identifier = NSUserInterfaceItemIdentifier("Fastra.DocumentWindow")
        let search = NSWindow(); search.identifier = SearchWindow.identifier
        WorkspaceWindowRegistry.register(workspace, for: normal)
        WorkspaceWindowRegistry.register(workspace, for: search)
        defer { WorkspaceWindowRegistry.unregister(normal); WorkspaceWindowRegistry.unregister(search) }
        let objects = LocalControlController(showWindows: false).objects()
        #expect(objects.filter { $0.id == workspace.tabs[0].documentID }.count == 1)
    }
}

@Suite("Snapshot-Caret am Dateiende", .serialized)
@MainActor
struct LocalControlEOFTests {
    enum Fixture: String, CaseIterable {
        case empty, finalWord, finalNewline, lateFinalWord
        var text: String {
            switch self {
            case .empty: return ""
            case .finalWord: return "last"
            case .finalNewline: return "last\n"
            case .lateFinalWord: return String(repeating: "long line 😀\n", count: 2000) + "last"
            }
        }
    }
    @Test("Echte Caret-Geometrie für leeren Text und EOF mit/ohne Umbruch", arguments: Fixture.allCases)
    func eof(_ fixture: Fixture) async throws {
        let text = fixture.text
        _ = NSApplication.shared
        let url = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        let bytes = Data(text.utf8)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = LocalControlController(showWindows: false)
        let request = ControlRequest(operation: "snapshot", path: url.path,
                                     sha256: FileSnapshot.sha256Hex(bytes), location: text.utf16.count, length: 0)
        let job = try #require(controller.execute(request).job)
        defer { _ = try? controller.execute(ControlRequest(operation: "close", sessionID: job.sessionID)) }
        for _ in 0..<100 {
            let report = try #require(controller.execute(ControlRequest(operation: "status", jobID: job.id)).job)
            if report.isTerminal {
                #expect(report.state == "ready")
                #expect(report.selection == ControlSelection(location: text.utf16.count, length: 0))
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("EOF-Auftrag erreichte keinen Endzustand")
    }
}
