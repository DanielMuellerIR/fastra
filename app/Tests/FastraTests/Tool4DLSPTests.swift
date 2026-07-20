// Tool4DLSPTests.swift
//
// Die Tests verwenden keinen echten 4D-Server. Der Mock verbindet sich wie
// tool4d als TCP-Client mit Fastras Listener, beantwortet aber LSP wie ein
// Server. Damit bleiben Framing und der vollständige Lebenszyklus stabil
// testbar, auch wenn tool4d auf einem Test-Mac nicht installiert ist.

import Foundation
import Network
import Testing
@testable import Fastra

@Test("JSON-RPC-Framing akzeptiert zerstückelte und gebündelte Nachrichten")
func tool4dFraming_handlesChunks() throws {
    let first = try Tool4DJSONRPCFraming.frame(["jsonrpc": "2.0", "id": 1])
    let second = try Tool4DJSONRPCFraming.frame(["jsonrpc": "2.0", "method": "initialized"])
    var decoder = Tool4DJSONRPCFraming.Decoder()
    #expect(try decoder.append(first.prefix(11)).isEmpty)
    var remainder = Data(first.dropFirst(11))
    remainder.append(second)
    let messages = try decoder.append(remainder)
    #expect(messages.count == 2)
    let firstObject = try JSONSerialization.jsonObject(with: messages[0]) as? [String: Any]
    let secondObject = try JSONSerialization.jsonObject(with: messages[1]) as? [String: Any]
    #expect(firstObject?["id"] as? Int == 1)
    #expect(secondObject?["method"] as? String == "initialized")
}

@Test("JSON-RPC-Framing lehnt fehlende Länge verständlich ab")
func tool4dFraming_rejectsMissingLength() {
    var decoder = Tool4DJSONRPCFraming.Decoder()
    #expect(throws: Tool4DJSONRPCFraming.FramingError.missingContentLength) {
        try decoder.append(Data("X-Test: 1\r\n\r\n{}".utf8))
    }
}

@Test("tool4d startet ausschließlich mit dem lokalen LSP-Port")
func tool4dNativeProcess_usesOnlyLSPPort() {
    #expect(Tool4DNativeProcess.arguments(forPort: 4242) == ["--lsp=4242"])
}

@Test("tool4d-LSP kanonisiert die Dokument-URI wie den Workspace")
func tool4dLSP_canonicalizesTemporaryDirectoryAlias() throws {
    // Auf macOS zeigt `/tmp` auf `/private/tmp`. Ohne diese Normalisierung
    // konnte tool4d 21.1 die Methode trotz passendem Workspace nicht finden
    // und antwortete mit `result: null`.
    let alias = URL(fileURLWithPath: "/tmp/fastra-tool4d-uri-regression-\(UUID().uuidString).4dm")
    defer { try? FileManager.default.removeItem(at: alias) }
    try Data("// URI-Fixture\n".utf8).write(to: alias)
    #expect(Tool4DLSPValidation.canonicalDocumentURI(for: alias)
        == alias.canonicalFileURL.absoluteURL.absoluteString)
    #expect(alias.canonicalFileURL.path.hasPrefix("/private/tmp/"))
}

@Test("Beenden erzwingt nach der Gnadenfrist das Reapen eines hängenden Prozesses")
func tool4dNativeProcess_forceStopsHungChild() async throws {
    let script = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-tool4d-stop-\(UUID().uuidString).sh")
    defer { try? FileManager.default.removeItem(at: script) }
    // Der reale Kindprozess sperrt TERM und stoppt sich erst danach selbst.
    // `waitpid(..., WUNTRACED)` bestätigt unten diesen Zustand ohne Zeitfrist;
    // der injizierte Sofort-Scheduler muss dann exakt den SIGKILL-Pfad nehmen.
    let fixture = """
    #!/bin/sh
    trap '' TERM
    kill -STOP $$
    exec /bin/sleep 30
    """
    try Data(fixture.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

    let process = Tool4DNativeProcess(scheduleForceStop: { $0.perform() })
    let termination = Tool4DTerminationRecorder()
    try process.launch(executable: script, port: 1) { status in termination.record(status) }
    let processID = try #require(process.processIdentifier)
    var stoppedStatus: Int32 = 0
    #expect(waitpid(processID, &stoppedStatus, WUNTRACED) == processID)
    // Darwin exportiert WIFSTOPPED nicht nach Swift. 0x7f in den unteren
    // Statusbits ist dessen POSIX-Bedingung für einen bestätigten Stop.
    #expect(stoppedStatus & 0x7f == 0x7f)
    process.stop()
    let terminationStatus = await termination.wait()
    #expect(terminationStatus == 9)
}

@Test("tool4d-LSP: initialize, Dokument-Lebenszyklus und Diagnostics")
func tool4dLSP_lifecycleAndDiagnostics() async {
    let mock = Tool4DMockProcess(mode: .pullDiagnostic)
    let validation = Tool4DLSPValidation(process: mock)
    let result = await runValidation(validation, timeout: 1)

    guard case .success(let diagnostics) = result else {
        Issue.record("Mock-Server lieferte kein erfolgreiches Ergebnis: \(result)")
        return
    }
    #expect(diagnostics == [Tool4DDiagnostic(line: 3, column: 5,
                                               message: "Unerwartetes Ende", severity: 1)])
    let methods = mock.receivedMethods
    #expect(methods.contains("initialize"))
    #expect(methods.contains("initialized"))
    #expect(methods.contains("textDocument/didOpen"))
    #expect(methods.contains("textDocument/didChange"))
    #expect(methods.contains("textDocument/diagnostic"))
    #expect(methods.contains("textDocument/didClose"))
    #expect(methods.contains("shutdown"))
    #expect(methods.contains("exit"))
    #expect(mock.wasStopped)
    guard let didClose = methods.firstIndex(of: "textDocument/didClose"),
          let shutdown = methods.firstIndex(of: "shutdown"),
          let exit = methods.firstIndex(of: "exit") else {
        Issue.record("Der Mock sah keinen vollständigen LSP-Abschluss: \(methods)")
        return
    }
    #expect(didClose < shutdown && shutdown < exit)
    let initialize = mock.initializeParameters
    #expect(initialize?["rootUri"] as? String == "file:///mock")
    #expect((initialize?["workspaceFolders"] as? [[String: Any]])?.first?["uri"] as? String
        == "file:///mock")
    let options = initialize?["initializationOptions"] as? [String: Any]
    #expect((options?["diagnostics"] as? [String: Any])?["enable"] as? Bool == true)
    #expect((options?["diagnostics"] as? [String: Any])?["scope"] as? String == "Document")
    #expect((options?["dependencies"] as? [String: Any])?["enable"] as? Bool == true)
}

@Test("tool4d-LSP: hängende Shutdown-Antwort räumt nach kurzer Frist auf")
func tool4dLSP_cleansUpWhenShutdownHangs() async {
    let mock = Tool4DMockProcess(mode: .ignoreShutdown)
    let validation = Tool4DLSPValidation(process: mock)
    let result = await runValidation(validation, timeout: 1)
    guard case .success = result else {
        Issue.record("Das Diagnoseergebnis darf beim Shutdown-Timeout nicht verloren gehen: \(result)")
        return
    }
    let methods = mock.receivedMethods
    #expect(methods.contains("shutdown"))
    #expect(methods.contains("exit"))
    #expect(mock.wasStopped)
}

@Test("tool4d-LSP: Publish-Diagnostics bleiben ein Fallback")
func tool4dLSP_acceptsPublishDiagnosticsFallback() async {
    let mock = Tool4DMockProcess(mode: .notificationDiagnostic)
    let validation = Tool4DLSPValidation(process: mock)
    let result = await runValidation(validation, timeout: 1)
    guard case .success(let diagnostics) = result else {
        Issue.record("Fallback-Nachricht wurde nicht verarbeitet: \(result)")
        return
    }
    #expect(diagnostics.count == 1)
}

@Test("tool4d-LSP: unverständliches Framing wird als Protokollfehler gemeldet")
func tool4dLSP_reportsProtocolError() async {
    let mock = Tool4DMockProcess(mode: .malformedResponse)
    let validation = Tool4DLSPValidation(process: mock)
    let result = await runValidation(validation, timeout: 1)
    guard case .failure(.protocolError) = result else {
        Issue.record("Erwartet: Protokollfehler, erhalten: \(result)")
        return
    }
}

@Test("tool4d-LSP: ausbleibende Diagnostics laufen kontrolliert in ein Timeout")
func tool4dLSP_reportsDiagnosticsTimeout() async {
    let mock = Tool4DMockProcess(mode: .noDiagnostics)
    let validation = Tool4DLSPValidation(process: mock)
    let result = await runValidation(validation, timeout: 0.05)
    #expect(result == .failure(.diagnosticsTimeout))
    #expect(mock.wasStopped)
}

@Test("tool4d-LSP: ein null-Pull-Ergebnis ist kein bestandener Check")
func tool4dLSP_rejectsMissingDiagnosticResult() async {
    let mock = Tool4DMockProcess(mode: .nullDiagnosticResult)
    let validation = Tool4DLSPValidation(process: mock)
    let result = await runValidation(validation, timeout: 1)
    #expect(result == .failure(.noDiagnosticResult))
}

@Test("tool4d-LSP: Prozessabbruch wird an die Prüfung weitergegeben")
func tool4dLSP_reportsProcessAbort() async {
    let mock = Tool4DMockProcess(mode: .abortImmediately)
    let validation = Tool4DLSPValidation(process: mock)
    let result = await runValidation(validation, timeout: 1)
    #expect(result == .failure(.processExited(9)))
}

@Test("4D-Projektdatei wird nur im unmittelbaren Projektordner gesucht")
func tool4dProjectLocator_findsExportedProject() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-tool4d-project-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let file = project.appendingPathComponent("Beispiel.4DProject")
    try Data("{}".utf8).write(to: file)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Project/Sources/Methods"), withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(
        to: root.appendingPathComponent("Project/Sources/Methods/Falsch.4DProject")
    )
    #expect(Tool4DProjectLocator.projectFile(in: root)?.canonicalFileURL
        == file.canonicalFileURL)
}

private func runValidation(_ validation: Tool4DLSPValidation,
                           timeout: TimeInterval) async
    -> Result<[Tool4DDiagnostic], Tool4DLSPValidation.ValidationError> {
    await withCheckedContinuation { continuation in
        validation.start(
            executable: URL(fileURLWithPath: "/mock/tool4d"),
            workspaceRoot: URL(fileURLWithPath: "/mock"),
            documentURL: URL(fileURLWithPath: "/mock/Project/Sources/Methods/Example.4dm"),
            text: "// Fixture\nALERT(\"x\")", timeout: timeout
        ) { result in
            continuation.resume(returning: result)
        }
    }
}

/// Der Termination-Handler des echten `Process` läuft auf einem anderen
/// Thread. Das kleine Schloss hält den Test ohne Datenrennen deterministisch.
private final class Tool4DTerminationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func record(_ status: Int32) {
        let waiter = lock.withLock { () -> CheckedContinuation<Int32, Never>? in
            storedStatus = status
            defer { continuation = nil }
            return continuation
        }
        waiter?.resume(returning: status)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { waiter in
            let ready = lock.withLock { () -> Int32? in
                if let storedStatus { return storedStatus }
                continuation = waiter
                return nil
            }
            if let ready {
                waiter.resume(returning: ready)
            }
        }
    }
}

/// Minimaler Gegenpart zum tool4d-Prozess. Der Mock benutzt dieselbe
/// umgekehrte TCP-Richtung wie tool4d 21.1: Er verbindet sich mit Fastras
/// Listener, statt selbst zu lauschen.
private final class Tool4DMockProcess: Tool4DLSPProcess {
    enum Mode {
        case pullDiagnostic
        case notificationDiagnostic
        case noDiagnostics
        case nullDiagnosticResult
        case ignoreShutdown
        case malformedResponse
        case abortImmediately
    }

    private let mode: Mode
    private let queue = DispatchQueue(label: "io.github.fastra.tool4d-lsp-mock")
    private var connection: NWConnection?
    private var decoder = Tool4DJSONRPCFraming.Decoder()
    private var methods: [String] = []
    private var initializeParams: [String: Any]?
    private var stopped = false
    private var termination: ((Int32) -> Void)?

    init(mode: Mode) {
        self.mode = mode
    }

    var receivedMethods: [String] { queue.sync { methods } }
    var initializeParameters: [String: Any]? { queue.sync { initializeParams } }
    var wasStopped: Bool { queue.sync { stopped } }

    func launch(executable: URL, port: UInt16,
                terminated: @escaping (Int32) -> Void) throws {
        queue.async {
            self.termination = terminated
            if self.mode == .abortImmediately {
                terminated(9)
                return
            }
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                terminated(9)
                return
            }
            let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard case .ready = state else { return }
                self?.queue.async { self?.receiveNext() }
            }
            connection.start(queue: self.queue)
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.connection?.cancel()
        }
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, complete, error in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                if let data, let messages = try? self.decoder.append(data) {
                    for message in messages { self.handle(message) }
                }
                if !complete, error == nil { self.receiveNext() }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else { return }
        methods.append(method)
        if method == "initialize" {
            initializeParams = object["params"] as? [String: Any]
        }
        if mode == .malformedResponse, method == "initialize" {
            connection?.send(content: Data("Content-Length: nope\r\n\r\n{}".utf8),
                             completion: .contentProcessed { _ in })
            return
        }
        if method == "initialize", let id = object["id"] as? Int {
            send(["jsonrpc": "2.0", "id": id, "result": ["capabilities": [:]]])
        }
        if method == "textDocument/didChange", mode == .notificationDiagnostic {
            send([
                "jsonrpc": "2.0",
                "method": "textDocument/publishDiagnostics",
                "params": [
                    "uri": "file:///mock/Project/Sources/Methods/Example.4dm",
                    "diagnostics": [[
                        "range": ["start": ["line": 2, "character": 4]],
                        "message": "Unerwartetes Ende",
                        "severity": 1,
                    ]],
                ],
            ])
        }
        if method == "textDocument/diagnostic", let id = object["id"] as? Int {
            switch mode {
            case .pullDiagnostic, .ignoreShutdown:
                send([
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": [
                        "kind": "full",
                        "items": [[
                            "range": ["start": ["line": 2, "character": 4]],
                            "message": "Unerwartetes Ende",
                            "severity": 1,
                        ]],
                    ],
                ])
            case .nullDiagnosticResult:
                send(["jsonrpc": "2.0", "id": id, "result": NSNull()])
            default:
                break
            }
        }
        if method == "shutdown", let id = object["id"] as? Int, mode != .ignoreShutdown {
            send(["jsonrpc": "2.0", "id": id, "result": NSNull()])
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? Tool4DJSONRPCFraming.frame(object) else { return }
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }
}
