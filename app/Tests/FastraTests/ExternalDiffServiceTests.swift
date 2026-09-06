// ExternalDiffServiceTests.swift
// Annahmelogik des Diff-Endpunkts headless: ohne Bundle, ohne Fenster, ohne
// Helferprozess. Der GUI-Selbsttest `externaldiff` deckt den echten Weg über
// LaunchServices ab; hier geht es um Feldmenge, Idempotenz, Frist und den
// bereits vergebenen Portnamen.

import Foundation
import Testing
import FastraDiffProtocol
@testable import Fastra

@Suite("External diff service", .serialized)
struct ExternalDiffServiceTests {
    /// Zwei echte Dateien: `validate()` öffnet die Pfade.
    private func makeRequest(deadlineIn seconds: TimeInterval = DiffProtocol.timeout) throws -> DiffWireRequest {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-diff-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let left = directory.appendingPathComponent("links.txt")
        let right = directory.appendingPathComponent("rechts.txt")
        try "a\n".write(to: left, atomically: true, encoding: .utf8)
        try "b\n".write(to: right, atomically: true, encoding: .utf8)
        let invocation = try #require(try DiffInvocation.parse(
            ["--", left.path, right.path], directory: directory))
        var request = DiffWireRequest(invocation)
        request.deadline = Date().timeIntervalSince1970 + seconds
        return request
    }

    private func reply(_ data: Data) throws -> Int32 {
        try JSONDecoder().decode(DiffWireReply.self, from: data).code
    }

    /// Ein Aufrufer, der Main frei lässt — wie der IPC-Worker der App.
    private func handleOffMain(_ service: ExternalDiffService, _ data: Data) async -> Data {
        await Task.detached { service.handle(data) }.value
    }

    @Test("Die Strikt-Prüfung leitet ihre Feldmenge aus dem Protokoll ab")
    func wireKeysMatchEncoding() throws {
        let request = try makeRequest()
        let object = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(Set(object.keys) == DiffWireRequest.wireKeys)
        #expect(DiffWireRequest.wireKeys.count == 9)
    }

    @Test("Annahme: einmal öffnen, gleiche ID idempotent, gleiche ID mit anderem Inhalt abgewiesen")
    func acceptance() async throws {
        final class Opened: @unchecked Sendable { var requests: [DiffWireRequest] = [] }
        let opened = Opened()
        let service = ExternalDiffService(endpoint: nil) { opened.requests.append($0) }
        let request = try makeRequest()
        let data = try JSONEncoder().encode(request)

        #expect(try reply(await handleOffMain(service, data)) == 0)
        #expect(try reply(await handleOffMain(service, data)) == 0, "Wiederholung derselben Anfrage")
        #expect(opened.requests == [request], "genau ein Fenster")

        var changed = request
        changed.leftLabel = "anders"
        #expect(try reply(await handleOffMain(service, JSONEncoder().encode(changed))) == DiffFailure.delivery.code)
        #expect(opened.requests.count == 1)

        // Unbekanntes Feld → wie eine unbekannte CLI-Option.
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["extra"] = true
        let extended = try JSONSerialization.data(withJSONObject: object)
        #expect(try reply(await handleOffMain(service, extended)) == DiffFailure.unsupported.code)
        #expect(opened.requests.count == 1)
    }

    @Test("Verstreicht die Frist, während Main belegt ist, entsteht kein Fenster")
    func deadlinePassesWhileMainIsBusy() async throws {
        final class Opened: @unchecked Sendable { var count = 0 }
        let opened = Opened()
        let service = ExternalDiffService(endpoint: nil) { _ in opened.count += 1 }
        let request = try makeRequest(deadlineIn: 0.15)
        let data = try JSONEncoder().encode(request)
        // Main ist länger belegt, als die Frist reicht — der Helfer hat dann
        // längst aufgegeben.
        let mainBlocked = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            mainBlocked.signal()
            Thread.sleep(forTimeInterval: 0.5)
        }
        mainBlocked.wait()
        #expect(try reply(await handleOffMain(service, data)) == DiffFailure.delivery.code)
        #expect(opened.count == 0)
        // Ein späterer Retry derselben ID ist nicht „bekannt", sondern
        // scheitert regulär an der Frist.
        #expect(try reply(await handleOffMain(service, data)) == DiffFailure.delivery.code)
        #expect(opened.count == 0)
    }

    @Test("Vergebener Portname: kein portloses Server-Objekt, späterer Start übernimmt")
    func occupiedEndpointRetries() {
        let name = "fastra-test-service.\(UUID().uuidString)"
        var other: DiffMessageServer? = DiffMessageServer(name: name) { _ in Data() }
        #expect(other?.isListening == true)
        let service = ExternalDiffService(endpoint: name) { _ in }
        service.start()
        #expect(!service.isListening, "zweite Instanz darf den Namen nicht bekommen")
        other = nil
        service.start()
        #expect(service.isListening, "nach dem Ende der anderen Instanz gehört der Port dieser")
        service.start()
        #expect(service.isListening, "idempotent")
    }
}
