import Foundation
import Testing
import FastraDiffProtocol
import Darwin

@Suite("External diff protocol")
struct ExternalDiffProtocolTests {
    private let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)

    @Test("Trenner, Unicode, Leerzeichen und führende Bindestriche bleiben erhalten")
    func paths() throws {
        let args = ["--read-only", "--focus-diff", "--left-label", "ä linke Seite",
                    "--right-label", "--", "--", "-ä links.txt", "右 rechts.txt"]
        let parsed = try #require(try DiffInvocation.parse(args, directory: directory))
        #expect(parsed.leftPath == "/tmp/-ä links.txt")
        #expect(parsed.rightPath == "/tmp/右 rechts.txt")
        #expect(parsed.leftLabel == "ä linke Seite")
        #expect(parsed.rightLabel == "--")
        #expect(parsed.readOnly && parsed.focusDiff)
        let defaults = try #require(try DiffInvocation.parse(["--", "-a", "b"], directory: directory))
        #expect(defaults.leftLabel == "-a")
        #expect(defaults.rightLabel == "b")
    }

    @Test("Fähigkeitsabfrage ist ein eigener, fensterloser Aufruf")
    func capabilities() throws {
        #expect(try DiffInvocation.parse(["--capabilities", "--json"], directory: directory) == nil)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(DiffProtocol.capabilities.utf8)) as? [String: Any])
        #expect(object["protocol"] as? Int == 1)
        for key in ["fileDiff", "readOnly", "focusDiff", "labels", "existingInstanceIpc"] {
            #expect(object[key] as? Bool == true)
        }
    }

    @Test("Argumentfehler und unbekannte Protokolloptionen haben getrennte Codes")
    func failures() {
        for args in [[], ["a", "b"], ["--", "a"], ["--", "a", "b", "c"],
                     ["--left-label"], ["--read-only", "--read-only", "--", "a", "b"],
                     ["--", "", "b"], ["--", "a\0b", "c"]] {
            #expect(throws: DiffFailure.arguments) { try DiffInvocation.parse(args, directory: directory) }
        }
        for args in [["--merge", "--", "a", "b"], ["--protocol", "2"], ["--json"]] {
            #expect(throws: DiffFailure.unsupported) { try DiffInvocation.parse(args, directory: directory) }
        }
        #expect(Set([DiffFailure.arguments.code, DiffFailure.file.code, DiffFailure.unsupported.code,
                     DiffFailure.launch.code, DiffFailure.delivery.code]).count == 5)
        for failure in [DiffFailure.arguments, .file, .unsupported, .launch, .delivery] {
            #expect(!failure.diagnostic.isEmpty && !failure.diagnostic.contains("\n"))
        }
    }

    @Test("Dateiprüfung liest reguläre Dateien, folgt Links und weist FIFO sowie fehlende Rechte ab")
    func files() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ä text.txt")
        try Data("one\ntwo\n".utf8).write(to: file)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        func request(_ left: URL) throws -> DiffWireRequest {
            DiffWireRequest(try #require(try DiffInvocation.parse(["--", left.path, file.path], directory: root)))
        }
        try request(file).validate()
        try request(link).validate()
        #expect(throws: DiffFailure.file) { try request(root.appendingPathComponent("missing")).validate() }
        #expect(throws: DiffFailure.file) { try request(root).validate() }
        let fifo = root.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: DiffFailure.file) { try request(fifo).validate() }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        if getuid() != 0 {
            #expect(throws: DiffFailure.file) { try request(file).validate() }
        }
    }

    @Test("Protokollversion, Deadline und Wire-Roundtrip")
    func wire() throws {
        let invocation = try #require(try DiffInvocation.parse(["--", "a", "b"], directory: directory))
        var request = DiffWireRequest(invocation)
        #expect(try JSONDecoder().decode(DiffWireRequest.self, from: JSONEncoder().encode(request)) == request)
        request.version = 2
        #expect(throws: DiffFailure.unsupported) { try request.validate() }
        request.version = 1
        request.deadline = 0
        #expect(throws: DiffFailure.delivery) { try request.validate() }
    }

    @Test("Lokaler Mach-Port bestätigt echte Nachrichten und fehlt nach dem Abbau")
    func transport() throws {
        let name = "fastra-test.\(UUID().uuidString)"
        var server: DiffMessageServer? = DiffMessageServer(name: name) { data in
            try! JSONEncoder().encode(DiffWireReply(code: data == Data("test".utf8) ? 0 : 4))
        }
        #expect(server?.isListening == true)
        #expect(DiffMessageClient.send(Data("test".utf8), to: name, timeout: 1)?.code == 0)
        #expect(DiffMessageClient.send(Data("other".utf8), to: name, timeout: 1)?.code == 4)
        server = nil
        #expect(DiffMessageClient.send(Data(), to: name, timeout: 0.1) == nil)
    }
}
