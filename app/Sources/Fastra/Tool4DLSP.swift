// Tool4DLSP.swift
//
// Schlanker LSP-Client für ein vom Nutzer installiertes tool4d. Fastra
// bündelt, lädt und installiert tool4d nie. Die ungewöhnliche TCP-Richtung
// ist praktisch mit tool4d 21.1 geprüft: Fastra lauscht lokal, tool4d
// verbindet sich als TCP-Client; auf Protokollebene bleibt Fastra der
// JSON-RPC-/LSP-Client und tool4d der Server.

import Foundation
import Network
import Darwin

/// JSON-RPC-Header mit `Content-Length`, wie ihn LSP über einen Byte-Stream
/// verwendet. Der Decoder ist absichtlich unabhängig vom Netzwerk, damit
/// zerstückelte TCP-Pakete und mehrere Nachrichten pro Paket testbar bleiben.
enum Tool4DJSONRPCFraming {
    static let maximumBodyLength = 4 * 1024 * 1024

    static func frame(_ object: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object)
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        return framed
    }

    enum FramingError: LocalizedError, Equatable {
        case missingContentLength
        case invalidContentLength
        case bodyTooLarge

        var errorDescription: String? {
            switch self {
            case .missingContentLength:
                return "Der Language-Server sendete einen JSON-RPC-Header ohne Content-Length."
            case .invalidContentLength:
                return "Der Language-Server sendete eine ungültige JSON-RPC-Nachrichtenlänge."
            case .bodyTooLarge:
                return "Der Language-Server sendete eine unerwartet große Diagnose-Nachricht."
            }
        }
    }

    struct Decoder {
        private static let headerEnd = Data([13, 10, 13, 10])
        private var buffer = Data()

        mutating func append(_ data: Data) throws -> [Data] {
            buffer.append(data)
            var messages: [Data] = []
            while let headerRange = buffer.range(of: Self.headerEnd) {
                let headerData = buffer.prefix(upTo: headerRange.lowerBound)
                guard let header = String(data: headerData, encoding: .utf8) else {
                    throw FramingError.invalidContentLength
                }
                var length: Int?
                for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
                    let parts = line.split(separator: ":", maxSplits: 1,
                                           omittingEmptySubsequences: false)
                    guard parts.count == 2,
                          parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased() == "content-length" else { continue }
                    length = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                }
                guard let length else { throw FramingError.missingContentLength }
                guard length >= 0 else { throw FramingError.invalidContentLength }
                guard length <= Tool4DJSONRPCFraming.maximumBodyLength else {
                    throw FramingError.bodyTooLarge
                }

                let bodyStart = headerRange.upperBound
                guard buffer.count - bodyStart >= length else { break }
                let bodyEnd = bodyStart + length
                messages.append(buffer.subdata(in: bodyStart..<bodyEnd))
                buffer.removeSubrange(0..<bodyEnd)
            }
            return messages
        }
    }
}

/// Eine LSP-Diagnose, in Fastras 1-basiertem Zeilen-/Spaltenformat. Die
/// Umrechnung passiert zentral, damit der UI-Sprung nicht versehentlich die
/// 0-basierten LSP-Werte verwendet.
struct Tool4DDiagnostic: Equatable {
    let line: Int
    let column: Int
    let message: String
    let severity: Int?

    static func parseAll(_ raw: Any) -> [Tool4DDiagnostic] {
        guard let values = raw as? [[String: Any]] else { return [] }
        return values.compactMap { value in
            let range = value["range"] as? [String: Any]
            let start = range?["start"] as? [String: Any]
            let line = (start?["line"] as? Int ?? 0) + 1
            let column = (start?["character"] as? Int ?? 0) + 1
            let message = value["message"] as? String
                ?? L10n.string("tool4d hat eine Diagnose ohne Meldung geliefert.")
            return Tool4DDiagnostic(line: max(1, line), column: max(1, column),
                                   message: message, severity: value["severity"] as? Int)
        }
    }
}

/// Trennt die Prozesssteuerung vom Protokoll. Der echte Prozess ist klein,
/// die Tests ersetzen ihn durch einen Mock, der sich wie tool4d beim lokalen
/// Listener verbindet. So prüfen die Tests den realen TCP-/LSP-Lebenszyklus
/// ohne eine Installation oder eine produktive 4D-Datei zu benötigen.
protocol Tool4DLSPProcess: AnyObject {
    func launch(executable: URL, port: UInt16,
                terminated: @escaping (Int32) -> Void) throws
    func stop()
}

final class Tool4DNativeProcess: Tool4DLSPProcess {
    private var process: Process?
    private var forceStopWorkItem: DispatchWorkItem?

    /// tool4d startet den LSP ausschließlich über den lokalen Port. Die
    /// Projektbindung geschieht erst im LSP-`initialize` durch Workspace- und
    /// Dokument-URI; zusätzliche Startparameter könnten ein Projekt öffnen.
    static func arguments(forPort port: UInt16) -> [String] {
        ["--lsp=\(port)"]
    }

    func launch(executable: URL, port: UInt16,
                terminated: @escaping (Int32) -> Void) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(forPort: port)
        // Der LSP läuft über TCP, nicht über stdout. Beide Streams gehen in
        // den Null-Sink, damit ein gesprächiger Server nie am ungelegenen
        // Pipe-Puffer hängen bleibt. Der Exit-Status bleibt als verständliche
        // Fehlermeldung für den Nutzer erhalten.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            self?.forceStopWorkItem?.cancel()
            self?.forceStopWorkItem = nil
            self?.process = nil
            terminated(process.terminationStatus)
        }
        self.process = process
        try process.run()
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        // `terminate()` ist kooperativ. Sollte tool4d beim Herunterfahren
        // hängen, beendet SIGKILL den Kindprozess nach einer kurzen Gnaden-
        // frist; Foundation ruft danach den Termination-Handler zum Reapen.
        let processID = process.processIdentifier
        let forceStop = DispatchWorkItem { [weak process] in
            // Nach `terminate()` kann Foundation `isRunning` schon auf
            // `false` setzen, obwohl ein Kindprozess TERM noch ignoriert.
            // Der gespeicherte PID bleibt bis zum Reapen eindeutig; `kill`
            // liefert für einen inzwischen beendeten Prozess nur ESRCH.
            guard process != nil else { return }
            kill(processID, SIGKILL)
        }
        forceStopWorkItem = forceStop
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5,
                                                        execute: forceStop)
    }
}

/// Sucht die zu einem geöffneten Fastra-Projekt gehörende `.4DProject`-Datei
/// ohne Rekursion. Die exportierte 4D-Struktur hat sie direkt im `Project`-
/// Ordner; der enge Scan verhindert, dass ein großer Projektbaum beim Klick
/// auf „Dokument prüfen“ synchron durchlaufen wird.
enum Tool4DProjectLocator {
    static func projectFile(in workspaceRoot: URL,
                            fileManager: FileManager = .default) -> URL? {
        let root = workspaceRoot.canonicalFileURL
        let candidates = [root.appendingPathComponent("Project", isDirectory: true), root]
        for directory in candidates {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            if let project = files.sorted(by: {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }).first(where: { $0.pathExtension.lowercased() == "4dproject" }) {
                return project
            }
        }
        return nil
    }
}

/// Ein einzelner, abbrechbarer tool4d-LSP-Lauf. Der Objekt-Lebenszyklus ist
/// absichtlich kurz: nach `didClose` folgen `shutdown`/`exit`, dann werden
/// Socket, Listener und Kindprozess beendet. So kann kein Hintergrundserver
/// bei Projektwechsel, erneutem Prüfen oder App-Ende zurückbleiben.
final class Tool4DLSPValidation {
    enum ValidationError: LocalizedError, Equatable {
        case listenerUnavailable
        case connectionTimeout
        case diagnosticsTimeout
        case noDiagnosticResult
        case processExited(Int32)
        case protocolError(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .listenerUnavailable:
                return L10n.string("Der lokale Diagnosekanal für tool4d konnte nicht geöffnet werden.")
            case .connectionTimeout:
                return L10n.string("tool4d hat sich nicht mit dem lokalen Diagnosekanal verbunden.")
            case .diagnosticsTimeout:
                return L10n.string("tool4d hat innerhalb der Wartezeit keine Diagnosen geliefert.")
            case .noDiagnosticResult:
                return L10n.string("tool4d konnte für dieses Dokument kein Diagnoseergebnis liefern. Prüfe, ob die Methode zum geöffneten 4D-Projekt gehört.")
            case .processExited:
                return L10n.string("tool4d wurde beendet, bevor die Dokumentprüfung abgeschlossen war.")
            case .protocolError(let detail):
                return L10n.format("tool4d sendete eine unverständliche LSP-Antwort: %@", detail)
            case .cancelled:
                return L10n.string("Die tool4d-Prüfung wurde abgebrochen.")
            }
        }
    }

    typealias Completion = (Result<[Tool4DDiagnostic], ValidationError>) -> Void

    private let queue = DispatchQueue(label: "io.github.fastra.tool4d-lsp")
    private let callbackQueue: DispatchQueue
    private let process: Tool4DLSPProcess
    private var listener: NWListener?
    private var connection: NWConnection?
    private var decoder = Tool4DJSONRPCFraming.Decoder()
    private var nextRequestID = 1
    private var pendingRequests: [Int: ([String: Any]) -> Void] = [:]
    private var completion: Completion?
    private var documentURI = ""
    private var workspaceURI = ""
    private var workspaceName = ""
    /// Fachliches Ergebnis und Netzwerk-Aufräumen sind getrennte Zustände:
    /// Während `isFinishing` darf noch die Shutdown-Antwort eintreffen.
    private var isFinishing = false
    private var completionDelivered = false
    private var finalResult: Result<[Tool4DDiagnostic], ValidationError>?
    private var diagnosticsTimer: DispatchWorkItem?
    private var connectionTimer: DispatchWorkItem?
    private var shutdownTimer: DispatchWorkItem?

    init(process: Tool4DLSPProcess = Tool4DNativeProcess(),
         callbackQueue: DispatchQueue = .main) {
        self.process = process
        self.callbackQueue = callbackQueue
    }

    func start(executable: URL, workspaceRoot: URL, documentURL: URL,
               text: String, timeout: TimeInterval = 8,
               completion: @escaping Completion) {
        queue.async { [weak self] in
            guard let self else { return }
            self.completion = completion
            // macOS stellt `/tmp` als Alias für `/private/tmp` bereit. tool4d
            // ordnet Methoden strikt per URI dem Workspace zu; beide Seiten
            // müssen deshalb dieselbe kanonische Datei-URI sehen, sonst kann
            // ein vorhandenes Dokument fälschlich `result: null` erhalten.
            self.documentURI = Self.canonicalDocumentURI(for: documentURL)
            let root = workspaceRoot.canonicalFileURL
            self.workspaceURI = root.absoluteURL.absoluteString
            self.workspaceName = root.lastPathComponent
            self.openListener(executable: executable,
                              text: text, timeout: timeout)
        }
    }

    /// Zentraler, reiner URI-Pfad für die Alias-Regressionsprüfung. Der
    /// Workspace wird bereits kanonisiert; das Dokument braucht dieselbe
    /// Behandlung, weil es auch über `/tmp` oder einen Symlink geöffnet sein
    /// kann.
    static func canonicalDocumentURI(for documentURL: URL) -> String {
        documentURL.canonicalFileURL.absoluteURL.absoluteString
    }

    func cancel() {
        queue.async { [weak self] in self?.finish(.failure(.cancelled)) }
    }

    private func openListener(executable: URL, text: String,
                              timeout: TimeInterval) {
        do {
            let parameters = NWParameters.tcp
            // Der Listener ist niemals im LAN sichtbar: tool4d und Fastra
            // sprechen ausschließlich über die IPv4-Loopback-Adresse.
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(IPv4Address.loopback), port: .any
            )
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                self?.queue.async {
                    guard let self, !self.completionDelivered else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port else {
                            self.finish(.failure(.listenerUnavailable))
                            return
                        }
                        do {
                            try self.process.launch(executable: executable, port: port.rawValue) {
                                [weak self] status in
                                self?.queue.async {
                                    guard let self, !self.completionDelivered else { return }
                                    if self.isFinishing {
                                        self.completeCleanup()
                                    } else {
                                        self.finish(.failure(.processExited(status)))
                                    }
                                }
                            }
                            let timer = DispatchWorkItem { [weak self] in
                                self?.finish(.failure(.connectionTimeout))
                            }
                            self.connectionTimer = timer
                            self.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                        } catch {
                            self.finish(.failure(.processExited(-1)))
                        }
                    case .failed:
                        self.finish(.failure(.listenerUnavailable))
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async { self?.accept(connection, text: text, timeout: timeout) }
            }
            listener.start(queue: queue)
        } catch {
            finish(.failure(.listenerUnavailable))
        }
    }

    private func accept(_ connection: NWConnection, text: String, timeout: TimeInterval) {
        guard self.connection == nil, !completionDelivered else {
            connection.cancel()
            return
        }
        connectionTimer?.cancel()
        connectionTimer = nil
        self.connection = connection
        // tool4d verbindet sich ein; weitere eingehende Verbindungen braucht
        // dieser kurze Einzel-Dokument-Lauf nicht mehr.
        listener?.cancel()
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                guard let self, !self.completionDelivered else { return }
                switch state {
                case .ready:
                    self.receiveNext()
                    self.initialize(text: text, timeout: timeout)
                case .failed:
                    self.finish(.failure(.connectionTimeout))
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func initialize(text: String, timeout: TimeInterval) {
        sendRequest(method: "initialize", params: [
            "processId": ProcessInfo.processInfo.processIdentifier,
            // `workspaceRoot` ist Fastras geöffneter Ordner oberhalb von
            // `Project/`. Das entspricht der Workspace-URI des offiziellen
            // 4D-Clients; die konkrete Methode bleibt über ihre Datei-URI
            // darunter eindeutig zugeordnet.
            "rootUri": workspaceURI,
            "workspaceFolders": [["uri": workspaceURI, "name": workspaceName]],
            "capabilities": ["textDocument": [
                "publishDiagnostics": ["relatedInformation": true],
                // tool4d 21.1 meldet einen Pull-Diagnoseanbieter. Dieses
                // Capability-Feld teilt dem Server mit, dass Fastra den
                // standardisierten `textDocument/diagnostic`-Abruf versteht.
                "diagnostic": ["dynamicRegistration": false],
            ]],
            // Der offizielle 4D-Editor aktiviert für den Server ebenfalls
            // Abhängigkeiten. So bleiben Diagnosen zwischen Methoden eines
            // Projekts vollständig, ohne eigene Projektanalyse in Fastra.
            "initializationOptions": [
                "diagnostics": ["enable": true, "scope": "Document"],
                "dependencies": ["enable": true],
            ],
        ]) { [weak self] response in
            guard let self, response["error"] == nil else {
                self?.finish(.failure(.protocolError("initialize")))
                return
            }
            self.sendNotification(method: "initialized", params: [:])
            self.sendNotification(method: "textDocument/didOpen", params: [
                "textDocument": ["uri": self.documentURI, "languageId": "4d", "version": 1,
                                 "text": text],
            ])
            // `didChange` gehört zum normalen Dokument-Lebenszyklus. Wir
            // senden den sichtbaren Text mit einer höheren Version, damit
            // tool4d bei bereits geöffneten Methoden sicher den aktuellen
            // ungespeicherten Editorstand diagnostiziert.
            self.sendNotification(method: "textDocument/didChange", params: [
                "textDocument": ["uri": self.documentURI, "version": 2],
                "contentChanges": [["text": text]],
            ])
            let timer = DispatchWorkItem { [weak self] in
                self?.finish(.failure(.diagnosticsTimeout))
            }
            self.diagnosticsTimer = timer
            self.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
            self.requestDocumentDiagnostics()
        }
    }

    private func requestDocumentDiagnostics() {
        // tool4d 21.1 liefert Diagnosen per Pull-Protokoll. Ältere Server
        // dürfen weiterhin `publishDiagnostics` senden; diesen Fallback
        // verarbeitet `handleMessage` unten unverändert.
        sendRequest(method: "textDocument/diagnostic", params: [
            "textDocument": ["uri": documentURI],
            "previousResultId": NSNull(),
        ]) { [weak self] response in
            guard let self else { return }
            if let error = response["error"] as? [String: Any] {
                let detail = error["message"] as? String ?? "textDocument/diagnostic"
                self.finish(.failure(.protocolError(detail)))
                return
            }
            guard let result = response["result"] else {
                self.finish(.failure(.protocolError("textDocument/diagnostic")))
                return
            }
            // Ein JSON-`null` ist keine Diagnose ohne Fehler, sondern die
            // Aussage des Servers, dass er dieses Dokument keinem 4D-Projekt
            // zuordnen konnte. Fastra darf daraus keinen grünen Check machen.
            guard !(result is NSNull) else {
                self.finish(.failure(.noDiagnosticResult))
                return
            }
            guard let report = result as? [String: Any], report["items"] != nil else {
                self.finish(.failure(.protocolError("textDocument/diagnostic")))
                return
            }
            self.diagnosticsTimer?.cancel()
            self.diagnosticsTimer = nil
            self.finish(.success(Tool4DDiagnostic.parseAll(report["items"] as Any)))
        }
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, complete, error in
            guard let self else { return }
            self.queue.async {
                guard !self.completionDelivered else { return }
                do {
                    if let data {
                        for body in try self.decoder.append(data) {
                            try self.handleMessage(body)
                        }
                    }
                } catch {
                    self.finish(.failure(.protocolError(error.localizedDescription)))
                    return
                }
                if error != nil || complete {
                    if self.isFinishing {
                        self.completeCleanup()
                    } else {
                        self.finish(.failure(.connectionTimeout))
                    }
                } else {
                    self.receiveNext()
                }
            }
        }
    }

    private func handleMessage(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError.protocolError("JSON")
        }
        if let id = object["id"] as? Int, let handler = pendingRequests.removeValue(forKey: id) {
            handler(object)
            return
        }
        guard object["method"] as? String == "textDocument/publishDiagnostics",
              let params = object["params"] as? [String: Any],
              params["uri"] as? String == documentURI else { return }
        diagnosticsTimer?.cancel()
        diagnosticsTimer = nil
        finish(.success(Tool4DDiagnostic.parseAll(params["diagnostics"] as Any)))
    }

    private func sendRequest(method: String, params: Any,
                             response: @escaping ([String: Any]) -> Void) {
        let id = nextRequestID
        nextRequestID += 1
        pendingRequests[id] = response
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func sendNotification(method: String, params: Any) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ object: [String: Any]) {
        do {
            let data = try Tool4DJSONRPCFraming.frame(object)
            connection?.send(content: data, completion: .contentProcessed { [weak self] error in
                guard error != nil else { return }
                self?.queue.async {
                    guard let self else { return }
                    if self.isFinishing {
                        self.completeCleanup()
                    } else {
                        self.finish(.failure(.connectionTimeout))
                    }
                }
            })
        } catch {
            finish(.failure(.protocolError(error.localizedDescription)))
        }
    }

    private func finish(_ result: Result<[Tool4DDiagnostic], ValidationError>) {
        guard !isFinishing, !completionDelivered else { return }
        isFinishing = true
        finalResult = result
        diagnosticsTimer?.cancel()
        connectionTimer?.cancel()
        guard connection != nil else {
            completeCleanup()
            return
        }
        sendNotification(method: "textDocument/didClose", params: [
            "textDocument": ["uri": documentURI],
        ])
        // LSP-Shutdown ist ein Request/Response-Schritt. Erst seine Antwort
        // erlaubt `exit`; ein kurzer eigener Timeout schützt vor Hängern.
        sendRequest(method: "shutdown", params: NSNull()) { [weak self] _ in
            guard let self, self.isFinishing, !self.completionDelivered else { return }
            self.shutdownTimer?.cancel()
            self.shutdownTimer = nil
            self.sendNotification(method: "exit", params: NSNull())
            self.completeCleanup()
        }
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.isFinishing, !self.completionDelivered else { return }
            self.sendNotification(method: "exit", params: NSNull())
            self.completeCleanup()
        }
        shutdownTimer = timer
        queue.asyncAfter(deadline: .now() + 0.3, execute: timer)
    }

    private func completeCleanup() {
        guard !completionDelivered, let result = finalResult else { return }
        completionDelivered = true
        shutdownTimer?.cancel()
        diagnosticsTimer?.cancel()
        connectionTimer?.cancel()
        let completion = completion
        self.completion = nil
        // Das `exit` erhält einen Queue-Durchlauf, bevor Socket und Prozess
        // geschlossen werden. `Tool4DNativeProcess.stop()` erzwingt danach
        // bei Bedarf selbst den sicheren SIGKILL-Fallback.
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.connection?.cancel()
            self.listener?.cancel()
            self.process.stop()
            if let completion {
                self.callbackQueue.async { completion(result) }
            }
        }
    }
}
