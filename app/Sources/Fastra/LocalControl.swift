import AppKit
import FastraControlProtocol
import FastraDiffProtocol

/// Die vollständig geladene Quelle und ihr Bytehash stammen aus demselben
/// geöffneten Dateiobjekt. Kein zweiter Read kann eine andere Datei einmischen.
enum ControlSnapshotLoader {
    static func load(_ request: ControlRequest) throws -> FileLoader.LoadedFile {
        guard let path = request.path, let expected = request.sha256 else { throw ControlFailure.invalidRequest }
        let loaded: FileLoader.LoadedFile
        do {
            loaded = try FileLoader.load(url: URL(fileURLWithPath: path),
                largeFileThreshold: UInt64(ControlProtocol.maximumSnapshotBytes),
                isCancelled: { Task.isCancelled })
        } catch { throw Task.isCancelled ? CancellationError() : ControlFailure.source }
        guard loaded.displayMode == .text, let snapshot = loaded.diskSnapshot,
              loaded.fileSize <= ControlProtocol.maximumSnapshotBytes else { throw ControlFailure.source }
        guard snapshot.sha256 == expected else { throw ControlFailure.stale }
        try ControlSelection(location: request.location!, length: request.length!).validate(in: loaded.content)
        return loaded
    }
}

/// CLI-Port und AppleEvents rufen exakt diesen MainActor-Vertrag auf. IDs
/// bezeichnen Laufzeitobjekte; nie Vorderfenster, Titel oder Listenpositionen.
@MainActor
final class LocalControlController {
    static let shared = LocalControlController()
    let runtimeID = UUID()
    private let windowIDs = NSMapTable<NSWindow, NSUUID>.weakToStrongObjects()
    private var sessions: [UUID: ControlSnapshotWindow] = [:]
    private var jobs: [UUID: JobEntry] = [:]
    private var accepted: [UUID: (request: ControlRequest, jobID: UUID?, expires: Date)] = [:]
    private var cleanupAccepted: [UUID: (request: ControlRequest, jobID: UUID?, expires: Date)] = [:]
    private let load: (ControlRequest) async throws -> FileLoader.LoadedFile
    private let showWindows: Bool
    private let loadExplanation: (String) async throws -> CodeExplanationPackage

    private final class JobEntry {
        var value: ControlJob
        let created = Date()
        var task: Task<Void, Never>?
        init(_ value: ControlJob) { self.value = value }
        deinit { task?.cancel() }
    }

    init(showWindows: Bool = true,
         loadExplanation: @escaping (String) async throws -> CodeExplanationPackage = { path in
             let task = Task.detached(priority: .userInitiated) { try CodeExplanationPackage.load(path: path) }
             return try await withTaskCancellationHandler(operation: { try await task.value },
                                                          onCancel: { task.cancel() })
         },
         load: @escaping (ControlRequest) async throws -> FileLoader.LoadedFile = { request in
             let task = Task.detached(priority: .userInitiated) { try ControlSnapshotLoader.load(request) }
             return try await withTaskCancellationHandler(operation: { try await task.value },
                                                          onCancel: { task.cancel() })
         }) {
        self.showWindows = showWindows; self.load = load; self.loadExplanation = loadExplanation
    }

    func execute(_ request: ControlRequest) throws -> ControlReply {
        prune()
        if let expected = request.runtimeID, expected != runtimeID { throw ControlFailure.invalidID }
        let mutates = ["snapshot", "sourceSnapshot", "explanation", "navigate", "close", "cancel"].contains(request.operation)
        let cleansUp = ["close", "cancel"].contains(request.operation)
        if mutates, let old = accepted[request.id] ?? cleanupAccepted[request.id] {
            guard old.request == request else { throw ControlFailure.invalidRequest }
            return ControlReply(runtimeID: runtimeID, job: old.jobID.flatMap { jobs[$0]?.value })
        }
        try request.validate()
        if mutates && !cleansUp, accepted.count >= ControlProtocol.maximumJobs * 2 { throw ControlFailure.capacity }
        let reply: ControlReply
        switch request.operation {
        case "capabilities":
            var capabilities = ControlProtocol.capabilities
            capabilities.runtimeID = runtimeID; capabilities.productVersion = AppInfo.version
            reply = ControlReply(runtimeID: runtimeID, capabilities: capabilities)
        case "objects":
            reply = ControlReply(runtimeID: runtimeID, objects: objects(), jobs: jobValues)
        case "snapshot": reply = try snapshot(request)
        case "sourceSnapshot": reply = try sourceSnapshot(request)
        case "explanation": reply = try explanation(request)
        case "navigate": reply = try navigate(request)
        case "status":
            guard let entry = jobs[request.jobID!] else { throw ControlFailure.invalidID }
            reply = ControlReply(runtimeID: runtimeID, job: entry.value)
        case "cancel":
            guard let entry = jobs[request.jobID!] else { throw ControlFailure.invalidID }
            cancel(entry)
            reply = ControlReply(runtimeID: runtimeID, job: entry.value)
        case "close":
            guard let session = sessions[request.sessionID!] else { throw ControlFailure.invalidID }
            session.window.close()
            remove(session.sessionID)
            reply = ControlReply(runtimeID: runtimeID)
        default: throw ControlFailure.unsupported
        }
        if mutates {
            let record = (request, reply.job?.id, Date(timeIntervalSinceNow: ControlProtocol.retentionSeconds))
            if cleansUp {
                // Aufräumen braucht unabhängig von neuen Arbeitsaufträgen Platz.
                // Nur seine eigene begrenzte Wiederholungshistorie wird verdrängt.
                if cleanupAccepted.count >= ControlProtocol.maximumJobs * 2,
                   let oldest = cleanupAccepted.min(by: { $0.value.expires < $1.value.expires })?.key {
                    cleanupAccepted.removeValue(forKey: oldest)
                }
                cleanupAccepted[request.id] = record
            } else { accepted[request.id] = record }
        }
        return reply
    }

    var jobValues: [ControlJob] {
        prune()
        return jobs.values.map(\.value).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Der isolierte Testhost untersucht seine realen Fenster ohne neue Wire-Operation.
    var snapshotWindowsForTesting: [ControlSnapshotWindow] { Array(sessions.values) }

    func objects() -> [ControlObject] {
        prune()
        let ordinary = WorkspaceWindowRegistry.registeredWindows().filter {
            !SearchWindow.isSearchWindow($0) && !HelpWindow.isHelpWindow($0)
        }.flatMap { window -> [ControlObject] in
            let id: UUID
            if let existing = windowIDs.object(forKey: window) { id = existing as UUID }
            else { id = UUID(); windowIDs.setObject(id as NSUUID, forKey: window) }
            let documents = WorkspaceWindowRegistry.workspace(for: window)?.tabs.map {
                ControlObject(id: $0.documentID, kind: "document", name: $0.title, windowID: id)
            } ?? []
            return [ControlObject(id: id, kind: "window", name: window.title)] + documents
        }
        let snapshots = sessions.values.flatMap { session -> [ControlObject] in
            let range = session.textView.selectedRange()
            let selection = ControlSelection(location: range.location, length: range.length)
            let hash = session.loaded?.diskSnapshot?.sha256
            return [
                ControlObject(id: session.windowID, kind: "window", name: session.window.title,
                              documentID: session.documentID, sessionID: session.sessionID),
                ControlObject(id: session.documentID, kind: "document", name: session.window.title,
                              windowID: session.windowID, sessionID: session.sessionID,
                              sha256: hash, selection: selection, provenance: session.sourceSnapshot?.provenance),
                ControlObject(id: session.sessionID, kind: "session", name: session.window.title,
                              windowID: session.windowID, documentID: session.documentID, sha256: hash,
                              provenance: session.sourceSnapshot?.provenance),
            ]
        }
        return (ordinary + snapshots).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func newSession(name: String) throws -> ControlSnapshotWindow {
        guard sessions.count < ControlProtocol.maximumSessions,
              jobs.count < ControlProtocol.maximumJobs,
              accepted.count < ControlProtocol.maximumJobs * 2 else { throw ControlFailure.capacity }
        let session = ControlSnapshotWindow(sessionID: UUID(), windowID: UUID(), documentID: UUID(),
                                            name: name)
        sessions[session.sessionID] = session
        let sessionID = session.sessionID
        session.onClose = { [weak self] in self?.remove(sessionID) }
        session.onUserSelection = { [weak self, weak session] in
            guard let self, let session else { return }
            session.explanationPlayer?.pause()
            self.interruptPending(in: session)
        }
        if showWindows { session.show() }
        return session
    }

    private func snapshot(_ request: ControlRequest) throws -> ControlReply {
        let session = try newSession(name: URL(fileURLWithPath: request.path!).lastPathComponent)
        let entry = createJob(request, session: session)
        let generation = session.generation
        entry.task = Task { [weak self, weak session, weak entry] in
            guard let self, let session, let entry else { return }
            guard self.isCurrent(entry, session: session, generation: generation) else { return }
            entry.value.state = "loading"
            do {
                let loaded = try await self.load(request)
                guard self.isCurrent(entry, session: session, generation: generation) else { return }
                session.install(loaded)
                entry.value.sha256 = loaded.diskSnapshot?.sha256
                entry.value.textSHA256 = FileSnapshot.sha256Hex(Data(loaded.content.utf8))
                entry.value.byteCount = loaded.diskSnapshot?.byteCount
                entry.value.encoding = loaded.encoding.rawValue
                entry.value.bomBytes = loaded.bom.count
                await self.present(entry, session: session, generation: generation, request: request)
            } catch {
                guard self.isCurrent(entry, session: session, generation: generation) else { return }
                self.fail(entry, error as? ControlFailure ?? (Task.isCancelled ? .interrupted : .source))
            }
        }
        return ControlReply(runtimeID: runtimeID, job: entry.value)
    }

    private func sourceSnapshot(_ request: ControlRequest) throws -> ControlReply {
        let provenance = request.provenance!
        let name = provenance.hitIdentity.archiveMembers.last
            ?? URL(fileURLWithPath: provenance.hitIdentity.filesystemPath).lastPathComponent
        let session = try newSession(name: name)
        let entry = createJob(request, session: session)
        entry.value.provenance = provenance
        entry.value.adopted = false
        let generation = session.generation
        entry.task = Task { [weak self, weak session, weak entry] in
            guard let self, let session, let entry,
                  self.isCurrent(entry, session: session, generation: generation) else { return }
            entry.value.state = "loading"
            do {
                let task = Task.detached(priority: .userInitiated) { try ControlSourceSnapshot.adopt(request) }
                let snapshot = try await withTaskCancellationHandler(operation: { try await task.value },
                                                                     onCancel: { task.cancel() })
                guard self.isCurrent(entry, session: session, generation: generation) else { return }
                session.sourceSnapshot = snapshot
                session.install(snapshot.loaded, sourceName: name)
                session.showProvenance(provenance)
                entry.value.sha256 = snapshot.loaded.diskSnapshot?.sha256
                entry.value.textSHA256 = FileSnapshot.sha256Hex(Data(snapshot.loaded.content.utf8))
                entry.value.byteCount = snapshot.loaded.diskSnapshot?.byteCount
                entry.value.encoding = snapshot.loaded.encoding.rawValue
                entry.value.bomBytes = snapshot.loaded.bom.count
                await self.present(entry, session: session, generation: generation, request: request)
                if entry.value.state == "ready" { entry.value.adopted = true }
            } catch {
                guard self.isCurrent(entry, session: session, generation: generation) else { return }
                self.fail(entry, error as? ControlFailure ?? (Task.isCancelled ? .interrupted : .source))
            }
        }
        return ControlReply(runtimeID: runtimeID, job: entry.value)
    }

    private func explanation(_ request: ControlRequest) throws -> ControlReply {
        let session = try newSession(name: URL(fileURLWithPath: request.path!).lastPathComponent)
        let entry = createJob(request, session: session)
        let generation = session.generation
        entry.task = Task { [weak self, weak session, weak entry] in
            guard let self, let session, let entry,
                  self.isCurrent(entry, session: session, generation: generation) else { return }
            entry.value.state = "loading"
            do {
                let package = try await self.loadExplanation(request.path!)
                guard self.isCurrent(entry, session: session, generation: generation) else { return }
                let first = package.manifest.steps[0]
                guard let loaded = package.loadedSources[first.sourceID],
                      let source = package.manifest.sources.first(where: { $0.id == first.sourceID }) else {
                    throw ControlFailure.source
                }
                session.install(loaded, sourceName: source.path)
                let player = CodeExplanationPlayer(package: package, session: session, controller: self)
                session.attach(player)
                player.watch(entry.value.id, index: 0)
                entry.value.sha256 = loaded.diskSnapshot?.sha256
                entry.value.textSHA256 = FileSnapshot.sha256Hex(Data(loaded.content.utf8))
                entry.value.byteCount = loaded.diskSnapshot?.byteCount
                entry.value.encoding = loaded.encoding.rawValue
                entry.value.bomBytes = loaded.bom.count
                let target = ControlRequest(operation: "navigate", sha256: loaded.diskSnapshot?.sha256,
                    location: first.location, length: first.length,
                    sessionID: session.sessionID, documentID: session.documentID)
                await self.present(entry, session: session, generation: generation, request: target)
            } catch {
                guard self.isCurrent(entry, session: session, generation: generation) else { return }
                self.fail(entry, error as? ControlFailure ?? (Task.isCancelled ? .interrupted : .source))
            }
        }
        return ControlReply(runtimeID: runtimeID, job: entry.value)
    }

    private func navigate(_ request: ControlRequest) throws -> ControlReply {
        guard let session = sessions[request.sessionID!], session.documentID == request.documentID,
              let loaded = session.loaded else { throw ControlFailure.invalidID }
        guard loaded.diskSnapshot?.sha256 == request.sha256 else { throw ControlFailure.stale }
        try ControlSelection(location: request.location!, length: request.length!).validate(in: loaded.content)
        guard jobs.count < ControlProtocol.maximumJobs,
              accepted.count < ControlProtocol.maximumJobs * 2 else { throw ControlFailure.capacity }
        session.explanationPlayer?.pause()
        interruptPending(in: session)
        let entry = createJob(request, session: session)
        entry.value.sha256 = loaded.diskSnapshot?.sha256
        entry.value.textSHA256 = FileSnapshot.sha256Hex(Data(loaded.content.utf8))
        let generation = session.generation
        entry.task = Task { [weak self, weak session, weak entry] in
            guard let self, let session, let entry else { return }
            await self.present(entry, session: session, generation: generation, request: request)
        }
        return ControlReply(runtimeID: runtimeID, job: entry.value)
    }

    func installExplanationSource(_ loaded: FileLoader.LoadedFile, documentID: UUID,
                                  in session: ControlSnapshotWindow, sourceName: String? = nil) throws {
        guard sessions[session.sessionID] === session else { throw ControlFailure.invalidID }
        // Auch fremde Navigation entwerten, bevor die sichtbare Quelle wechselt.
        // Das gilt unabhängig davon, ob der nächste Auftrag noch Kapazität hat.
        interruptPending(in: session)
        session.install(loaded, documentID: documentID, sourceName: sourceName)
    }

    private func createJob(_ request: ControlRequest, session: ControlSnapshotWindow) -> JobEntry {
        let entry = JobEntry(ControlJob(id: UUID(), requestID: request.id, sessionID: session.sessionID,
                                        windowID: session.windowID, documentID: session.documentID))
        jobs[entry.value.id] = entry
        return entry
    }

    private func present(_ entry: JobEntry, session: ControlSnapshotWindow,
                         generation: Int, request: ControlRequest) async {
        guard isCurrent(entry, session: session, generation: generation) else { return }
        guard entry.value.documentID == session.documentID,
              entry.value.sha256 == session.loaded?.diskSnapshot?.sha256 else { fail(entry, .stale); return }
        entry.value.state = "presenting"
        let selection = ControlSelection(location: request.location!, length: request.length!)
        session.select(selection)
        // Nicht das Setzen bestätigen: Die echte Textansicht nach nachfolgenden
        // Layoutdurchläufen erneut beobachten, ohne ihre Auswahl zu korrigieren.
        for _ in 0..<3 {
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
            guard isCurrent(entry, session: session, generation: generation) else { return }
            guard entry.value.documentID == session.documentID,
                  entry.value.sha256 == session.loaded?.diskSnapshot?.sha256 else { fail(entry, .stale); return }
            guard session.confirms(selection) else { fail(entry, .interrupted); return }
        }
        entry.value.selection = ControlSelection(location: session.textView.selectedRange().location,
                                                  length: session.textView.selectedRange().length)
        entry.value.state = "ready"
        session.showReady()
        entry.task = nil
    }

    private func isCurrent(_ entry: JobEntry, session: ControlSnapshotWindow, generation: Int) -> Bool {
        guard !Task.isCancelled, !entry.value.isTerminal,
              sessions[session.sessionID] === session, session.generation == generation else { return false }
        guard Date().timeIntervalSince(entry.created) < ControlProtocol.jobTimeout else {
            fail(entry, .expired); return false
        }
        return true
    }

    private func fail(_ entry: JobEntry, _ failure: ControlFailure) {
        entry.value.state = "failed"; entry.value.error = failure
        entry.task?.cancel(); entry.task = nil
        discardUnconfirmedSource(entry)
        sessions[entry.value.sessionID]?.showFailure(failure)
    }

    private func cancel(_ entry: JobEntry) {
        guard !entry.value.isTerminal else { return }
        entry.value.state = "cancelled"
        entry.task?.cancel(); entry.task = nil
        discardUnconfirmedSource(entry)
        if let session = sessions[entry.value.sessionID] { session.generation += 1 }
        sessions[entry.value.sessionID]?.showFailure()
    }

    private func interruptPending(in session: ControlSnapshotWindow) {
        session.generation += 1
        for entry in jobs.values where entry.value.sessionID == session.sessionID && !entry.value.isTerminal {
            cancel(entry)
        }
    }

    private func remove(_ sessionID: UUID) {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        session.explanationPlayer?.closed()
        session.sourceSnapshot?.remove()
        session.sourceSnapshot = nil
        interruptPending(in: session)
        session.onClose = nil; session.onUserSelection = nil
    }

    private func prune() {
        let now = Date()
        for entry in jobs.values where !entry.value.isTerminal
            && now.timeIntervalSince(entry.created) >= ControlProtocol.jobTimeout {
            fail(entry, .expired)
        }
        jobs = jobs.filter { now.timeIntervalSince($0.value.created) < ControlProtocol.retentionSeconds }
        accepted = accepted.filter { $0.value.expires > now }
        cleanupAccepted = cleanupAccepted.filter { $0.value.expires > now }
    }

    private func discardUnconfirmedSource(_ entry: JobEntry) {
        guard entry.value.provenance != nil, entry.value.adopted != true,
              let session = sessions[entry.value.sessionID] else { return }
        session.sourceSnapshot?.remove()
        session.sourceSnapshot = nil
    }

    func closeAllSessions() {
        for session in Array(sessions.values) { session.window.close(); remove(session.sessionID) }
    }

    func handle(_ data: Data) -> Data {
        let reply: ControlReply
        do { reply = try execute(ControlRequest.decode(data)) }
        catch { reply = ControlReply(runtimeID: runtimeID, error: error as? ControlFailure ?? .invalidRequest) }
        return (try? JSONEncoder().encode(reply)) ?? Data()
    }
}

/// Der Mach-Worker synchronisiert nur kurze Annahmen. AppleEvents gehen
/// direkt auf den MainActor und betreten diesen sync-Pfad niemals erneut.
final class LocalControlService {
    static let shared = LocalControlService()
    private var server: DiffMessageServer?
    func start() {
        guard server == nil, let identifier = Bundle.main.bundleIdentifier else { return }
        DispatchQueue.global(qos: .utility).async { ControlSourceSnapshot.pruneAbandoned() }
        let candidate = DiffMessageServer(name: ControlProtocol.endpoint(bundleIdentifier: identifier)) { data in
            DispatchQueue.main.sync { MainActor.assumeIsolated { LocalControlController.shared.handle(data) } }
        }
        if candidate.isListening { server = candidate }
    }
}
