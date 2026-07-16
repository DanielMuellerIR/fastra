import Foundation
import Testing
@testable import Fastra

private final class ControlledGitExecutor: GitCommandExecuting {
    final class Cancellation: GitCancelling {
        private(set) var isCancelled = false
        func cancel() { isCancelled = true }
    }

    struct Call {
        let arguments: [String]
        let directory: URL
        let policy: GitExecutionPolicy
        let cancellation: Cancellation
        let completion: (GitExecutionOutcome) -> Void
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return calls.count
    }

    var startedArguments: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return calls.map(\.arguments)
    }

    @discardableResult
    func execute(arguments: [String], in directory: URL,
                 outputLimit: GitOutputLimit, policy: GitExecutionPolicy,
                 completion: @escaping (GitExecutionOutcome) -> Void)
        -> GitCancelling {
        let cancellation = Cancellation()
        lock.lock()
        calls.append(Call(arguments: arguments, directory: directory,
                          policy: policy, cancellation: cancellation,
                          completion: completion))
        lock.unlock()
        return cancellation
    }

    func complete(_ index: Int, with outcome: GitExecutionOutcome) {
        lock.lock()
        let completion = calls[index].completion
        lock.unlock()
        completion(outcome)
    }

    func isCancelled(_ index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return calls[index].cancellation.isCancelled
    }
}

private final class LockedValues<Value> {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        lock.lock(); defer { lock.unlock() }
        values.append(value)
    }

    func snapshot() -> [Value] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

private func success(_ stdout: Data = Data()) -> GitExecutionOutcome {
    .completed(GitResult(exitCode: 0, stdoutData: stdout, stderrData: Data()))
}

private func repository(_ name: String = UUID().uuidString) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("Fastra-GitOperations-\(name)")
}

private func porcelainSnapshot(oid: String) -> Data {
    var data = Data()
    for record in ["# branch.oid \(oid)", "# branch.head main",
                   "# branch.upstream origin/main", "# branch.ab +1 -2"] {
        data.append(Data(record.utf8))
        data.append(0)
    }
    return data
}

private func graphSnapshot(hash: String) -> Data {
    var data = Data("\u{1e}\(hash)\u{1f}\u{1f}Daniel\u{1f}2026-07-15\u{1f}1\u{1f}HEAD -> main\u{1f}Test".utf8)
    data.append(0)
    return data
}

@Suite("Git-Operationskoordination")
struct GitOperationsCoordinatorTests {
    @Test("Identische Fetches desselben Repositories werden dedupliziert")
    func deduplicatesFetch() {
        let executor = ControlledGitExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let request = GitOperationRequest(repository: repository("dedup"), kind: .fetch,
                                          arguments: ["fetch", "origin"])
        var completions = 0
        coordinator.perform(request) { _ in completions += 1 }
        coordinator.perform(request) { _ in completions += 1 }
        #expect(executor.count == 1)
        executor.complete(0, with: success())
        #expect(completions == 2)
        #expect(coordinator.state(for: request.repository) == .idle)
    }

    @Test("Vorgänge desselben Repositories laufen seriell")
    func serializesSameRepository() {
        let executor = ControlledGitExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let repo = repository("serial")
        coordinator.perform(GitOperationRequest(repository: repo, kind: .fetch,
                                                arguments: ["fetch"])) { _ in }
        coordinator.perform(GitOperationRequest(repository: repo, kind: .pull,
                                                arguments: ["pull"])) { _ in }
        #expect(executor.count == 1)
        executor.complete(0, with: success())
        #expect(executor.count == 2)
        #expect(executor.startedArguments[1] == ["pull"])
        executor.complete(1, with: success())
        #expect(coordinator.state(for: repo) == .idle)
    }

    @Test("Unabhängige Repositories dürfen parallel laufen")
    func parallelRepositories() {
        let executor = ControlledGitExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        coordinator.perform(GitOperationRequest(repository: repository("a"), kind: .fetch,
                                                arguments: ["fetch"])) { _ in }
        coordinator.perform(GitOperationRequest(repository: repository("b"), kind: .fetch,
                                                arguments: ["fetch"])) { _ in }
        #expect(executor.count == 2)
    }

    @Test("Stornierte Warteschlangen-Lease startet ihren Prozess nicht")
    func cancelsQueuedLease() {
        let executor = ControlledGitExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let repo = repository("cancel-queued")
        coordinator.perform(GitOperationRequest(repository: repo, kind: .pull,
                                                arguments: ["pull"])) { _ in }
        var queuedOutcome: GitExecutionOutcome?
        let lease = coordinator.perform(GitOperationRequest(repository: repo,
                                                             kind: .push,
                                                             arguments: ["push"])) {
            queuedOutcome = $0
        }
        lease.cancel()
        #expect(queuedOutcome == .cancelled)
        executor.complete(0, with: success())
        #expect(executor.count == 1)
        #expect(coordinator.state(for: repo) == .idle)
    }

    @Test("Timeout gibt den Repository-Slot für den nächsten Vorgang frei")
    func timeoutReleasesQueue() {
        let executor = ControlledGitExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let repo = repository("timeout")
        coordinator.perform(GitOperationRequest(repository: repo, kind: .pull,
                                                arguments: ["pull"])) { _ in }
        coordinator.perform(GitOperationRequest(repository: repo, kind: .push,
                                                arguments: ["push"])) { _ in }
        executor.complete(0, with: .timedOut)
        #expect(executor.count == 2)
        executor.complete(1, with: success())
        #expect(coordinator.state(for: repo) == .idle)
    }

    @Test("Stornierte laufende Lease bricht den Prozess ab und gibt danach den Slot frei")
    func cancelsRunningLease() {
        let executor = ControlledGitExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let repo = repository("cancel-running")
        var outcome: GitExecutionOutcome?
        let lease = coordinator.perform(GitOperationRequest(repository: repo, kind: .pull,
                                                             arguments: ["pull"])) {
            outcome = $0
        }
        lease.cancel()
        #expect(outcome == .cancelled)
        #expect(executor.isCancelled(0))
        executor.complete(0, with: .cancelled)
        #expect(coordinator.state(for: repo) == .idle)
    }
}

@Suite("Appweiter Git-Repository-Store")
struct GitRepositoryStoreTests {
    private func makeStore() -> (ControlledGitExecutor, GitRepositoryStore) {
        let executor = ControlledGitExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        return (executor, GitRepositoryStore(executor: executor, coordinator: coordinator))
    }

    private func completeFull(_ executor: ControlledGitExecutor, offset: Int,
                              oid: String) {
        executor.complete(offset, with: success(porcelainSnapshot(oid: oid)))
        executor.complete(offset + 1, with: success(Data()))
        executor.complete(offset + 2, with: success(Data("main\t*\n".utf8)))
        executor.complete(offset + 3, with: success(graphSnapshot(hash: oid)))
    }

    @Test("Snapshot bündelt Status, Upstream, HEAD, Branches und Graph")
    func combinedSnapshot() async {
        let (executor, store) = makeStore()
        let repo = repository("snapshot")
        var observation: GitRepositoryObservation?
        let snapshot: GitRepositorySnapshot = await withCheckedContinuation { continuation in
            observation = store.observe(repository: repo) { continuation.resume(returning: $0) }
            store.refresh(repository: repo, scope: .full)
            completeFull(executor, offset: 0, oid: "abc123")
        }
        _ = observation
        #expect(snapshot.headOID == "abc123")
        #expect(snapshot.upstream == "origin/main")
        #expect(snapshot.status?.ahead == 1)
        #expect(snapshot.status?.behind == 2)
        #expect(snapshot.branches == [GitBranch(name: "main", isCurrent: true)])
        #expect(snapshot.graph.first?.hash == "abc123")
        #expect(snapshot.revision == 1)
    }

    @Test("Identische Refreshes werden dedupliziert und an alle Fenster verteilt")
    func deduplicatesAndFansOut() async {
        let (executor, store) = makeStore()
        let repo = repository("fanout")
        let delivered = LockedValues<String>()
        var observations: [GitRepositoryObservation] = []
        await withCheckedContinuation { continuation in
            observations.append(store.observe(repository: repo) { snapshot in
                delivered.append("a:\(snapshot.headOID ?? "nil")")
                if delivered.snapshot().count == 2 { continuation.resume() }
            })
            observations.append(store.observe(repository: repo) { snapshot in
                delivered.append("b:\(snapshot.headOID ?? "nil")")
                if delivered.snapshot().count == 2 { continuation.resume() }
            })
            store.refresh(repository: repo, scope: .full)
            store.refresh(repository: repo, scope: .full)
            #expect(executor.count == 4)
            completeFull(executor, offset: 0, oid: "shared")
        }
        _ = observations
        #expect(Set(delivered.snapshot()) == ["a:shared", "b:shared"])
    }

    @Test("Zwei Workspaces erhalten denselben zentral erkannten Merge-Zustand")
    func operationFansOutToTwoWorkspaces() async throws {
        let (executor, store) = makeStore()
        let root = repository("operation-fanout")
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: gitDirectory.appendingPathComponent("MERGE_HEAD"))
        let operationPaths = GitOperationStateDetector.markers.map {
            gitDirectory.appendingPathComponent($0.1).path
        }.joined(separator: "\n") + "\n"
        let suiteA = "Fastra-Store-A-\(UUID().uuidString)"
        let suiteB = "Fastra-Store-B-\(UUID().uuidString)"
        let defaultsA = UserDefaults(suiteName: suiteA)!
        let defaultsB = UserDefaults(suiteName: suiteB)!
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }
        let coordinator = store.coordinator
        let first = Workspace(defaults: defaultsA,
                              gitOperationsCoordinator: coordinator,
                              gitRepositoryStore: store)
        let second = Workspace(defaults: defaultsB,
                               gitOperationsCoordinator: coordinator,
                               gitRepositoryStore: store)
        first.openProject(at: root)
        second.openProject(at: root)
        #expect(executor.count == 4)
        executor.complete(0, with: success(porcelainSnapshot(oid: "shared")))
        executor.complete(1, with: success(Data(operationPaths.utf8)))
        executor.complete(2, with: success(Data("main\t*\n".utf8)))
        executor.complete(3, with: success(graphSnapshot(hash: "shared")))
        for _ in 0..<500 where first.gitOperationState != .merge
            || second.gitOperationState != .merge {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(first.gitOperationState == .merge)
        #expect(second.gitOperationState == .merge)
        #expect(first.gitRepositorySnapshot?.revision
                == second.gitRepositorySnapshot?.revision)
    }

    @Test("Status-Refresh publiziert neuen HEAD nie mit altem Graph")
    func lightRefreshEscalatesChangedHead() async {
        let (executor, store) = makeStore()
        let repo = repository("light")
        let revisions = LockedValues<GitRepositorySnapshot>()
        let observation = store.observe(repository: repo) { revisions.append($0) }
        store.refresh(repository: repo, scope: .full)
        completeFull(executor, offset: 0, oid: "one")
        while revisions.snapshot().count < 1 { await Task.yield() }
        store.refresh(repository: repo, scope: .status)
        #expect(executor.count == 6)
        executor.complete(4, with: success(porcelainSnapshot(oid: "two")))
        executor.complete(5, with: success(Data()))
        while executor.count < 10 { await Task.yield() }
        #expect(revisions.snapshot().count == 1)
        #expect(store.snapshot(for: repo)?.headOID == "one")
        completeFull(executor, offset: 6, oid: "two")
        while revisions.snapshot().count < 2 { await Task.yield() }
        _ = observation
        #expect(revisions.snapshot()[1].headOID == "two")
        #expect(revisions.snapshot()[1].graph.first?.hash == "two")
    }

    @Test("Gerissener Full-Batch wird begrenzt wiederholt und erst konsistent publiziert")
    func retriesInconsistentFullBatch() async {
        let (executor, store) = makeStore()
        let repo = repository("full-race")
        let delivered = LockedValues<GitRepositorySnapshot>()
        let observation = store.observe(repository: repo) { delivered.append($0) }
        store.refresh(repository: repo, scope: .full)

        executor.complete(0, with: success(porcelainSnapshot(oid: "new")))
        executor.complete(1, with: success(Data()))
        executor.complete(2, with: success(Data("main\t*\n".utf8)))
        executor.complete(3, with: success(graphSnapshot(hash: "old")))
        while executor.count < 8 { await Task.yield() }
        #expect(delivered.snapshot().isEmpty)

        executor.complete(4, with: success(porcelainSnapshot(oid: "newer")))
        executor.complete(5, with: success(Data()))
        executor.complete(6, with: success(Data("main\t*\n".utf8)))
        executor.complete(7, with: success(graphSnapshot(hash: "new")))
        while executor.count < 12 { await Task.yield() }
        #expect(delivered.snapshot().isEmpty)

        completeFull(executor, offset: 8, oid: "stable")
        while delivered.snapshot().isEmpty { await Task.yield() }
        _ = observation
        #expect(delivered.snapshot().last?.headOID == "stable")
        #expect(delivered.snapshot().last?.graph.first?.hash == "stable")
        #expect(executor.count == 12)
    }

    @Test("Drei inkonsistente Full-Batches enden ohne Endlosschleife und ohne Snapshot")
    func boundedInconsistentFullBatch() async {
        let (executor, store) = makeStore()
        let repo = repository("bounded-race")
        store.refresh(repository: repo, scope: .full)
        for attempt in 0..<3 {
            let offset = attempt * 4
            executor.complete(offset, with: success(porcelainSnapshot(oid: "status-\(attempt)")))
            executor.complete(offset + 1, with: success(Data()))
            executor.complete(offset + 2, with: success(Data("main\t*\n".utf8)))
            executor.complete(offset + 3, with: success(graphSnapshot(hash: "graph-\(attempt)")))
            if attempt < 2 {
                while executor.count < offset + 8 { await Task.yield() }
            }
        }
        while store.coordinator.state(for: repo) != .idle { await Task.yield() }
        #expect(executor.count == 12)
        #expect(store.snapshot(for: repo) == nil)
    }

    @Test("Gekürzter Status überschreibt keinen verifizierten Snapshot")
    func truncatedStatusPreservesSnapshot() {
        let (executor, store) = makeStore()
        let repo = repository("truncated-status")
        store.refresh(repository: repo, scope: .full)
        completeFull(executor, offset: 0, oid: "verified")
        store.refresh(repository: repo, scope: .status)
        let truncated = GitResult(exitCode: 0,
                                  stdoutData: porcelainSnapshot(oid: "partial"),
                                  stderrData: Data(), stdoutWasTruncated: true)
        executor.complete(4, with: .completed(truncated))
        executor.complete(5, with: success(Data()))
        #expect(store.snapshot(for: repo)?.headOID == "verified")
        #expect(store.snapshot(for: repo)?.graph.first?.hash == "verified")
    }

    @Test("Mutation und vollständiger Read-Batch greifen nicht ineinander")
    func readWriteCoordination() {
        let (executor, store) = makeStore()
        let repo = repository("read-write")
        store.coordinator.perform(GitOperationRequest(repository: repo,
                                                      kind: .workingTreeMutation,
                                                      arguments: ["add", "-A"])) { _ in }
        store.refresh(repository: repo, scope: .full)
        #expect(executor.count == 1)
        executor.complete(0, with: success())
        #expect(executor.count == 5)
        completeFull(executor, offset: 1, oid: "after-write")
        #expect(store.coordinator.state(for: repo) == .idle)
    }

    @Test("Verschiedene Repositories aktualisieren parallel")
    func parallelRepositories() {
        let (executor, store) = makeStore()
        store.refresh(repository: repository("parallel-a"), scope: .full)
        store.refresh(repository: repository("parallel-b"), scope: .full)
        #expect(executor.count == 8)
    }

    @Test("Externer Checkout plus Commit eskaliert Status zu konsistentem Full-Snapshot")
    func realExternalCheckoutAndCommit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-store-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await storeGit(["init", "-q"], in: root)
        _ = try await storeGit(["config", "user.name", "Fastra Test"], in: root)
        _ = try await storeGit(["config", "user.email", "test@example.invalid"], in: root)
        let file = root.appendingPathComponent("a.txt")
        try Data("eins\n".utf8).write(to: file)
        _ = try await storeGit(["add", "--", "a.txt"], in: root)
        _ = try await storeGit(["commit", "-q", "-m", "eins"], in: root)

        let executor = GitRunnerExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let store = GitRepositoryStore(executor: executor, coordinator: coordinator)
        let delivered = LockedValues<GitRepositorySnapshot>()
        let observation = store.observe(repository: root) { delivered.append($0) }
        store.refresh(repository: root, scope: .full)
        let first = try await waitForStoreSnapshot(store, repository: root) { $0.revision >= 1 }

        _ = try await storeGit(["checkout", "-q", "-b", "extern"], in: root)
        try Data("zwei\n".utf8).write(to: file)
        _ = try await storeGit(["commit", "-qam", "zwei"], in: root)
        let newOID = try await storeGit(["rev-parse", "HEAD"], in: root).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        store.refresh(repository: root, scope: .status)
        let final = try await waitForStoreSnapshot(store, repository: root) {
            $0.revision > first.revision && $0.headOID == newOID
        }
        _ = observation
        #expect(final.graph.contains(where: { $0.hash == newOID }))
        #expect(delivered.snapshot().allSatisfy { snapshot in
            snapshot.headOID == nil || snapshot.graph.contains(where: { $0.hash == snapshot.headOID })
        })
    }
}

private enum StoreRealTestError: Error {
    case outcome(GitExecutionOutcome)
    case exit(Int32, String)
    case timeout
}

private func storeGit(_ arguments: [String], in root: URL) async throws -> GitResult {
    let outcome = await withCheckedContinuation { continuation in
        GitRunner.runDetailed(arguments, in: root) { continuation.resume(returning: $0) }
    }
    guard case .completed(let result) = outcome else { throw StoreRealTestError.outcome(outcome) }
    guard result.ok else { throw StoreRealTestError.exit(result.exitCode, result.stderrForDisplay) }
    return result
}

private func waitForStoreSnapshot(_ store: GitRepositoryStore, repository: URL,
                                  matching predicate: (GitRepositorySnapshot) -> Bool) async throws
    -> GitRepositorySnapshot {
    for _ in 0..<500 {
        if let snapshot = store.snapshot(for: repository), predicate(snapshot) { return snapshot }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw StoreRealTestError.timeout
}

@Suite("Projektgebundene Git-Aktionsketten", .serialized)
struct GitActionContextTests {
    private func makeWorkspace() -> (ControlledGitExecutor, Workspace, UserDefaults, String) {
        let executor = ControlledGitExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let store = GitRepositoryStore(executor: executor, coordinator: coordinator)
        let suite = "Fastra-GitActionContext-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (executor,
                Workspace(defaults: defaults, gitOperationsCoordinator: coordinator,
                          gitRepositoryStore: store),
                defaults, suite)
    }

    private func completeInitialRefresh(_ executor: ControlledGitExecutor) {
        executor.complete(0, with: success(porcelainSnapshot(oid: "initial")))
        executor.complete(1, with: success())
        executor.complete(2, with: success(Data("main\t*\n".utf8)))
        executor.complete(3, with: success(graphSnapshot(hash: "initial")))
    }

    @Test("Projektwechsel zwischen add und commit verhindert den Commit im neuen Repo")
    func projectSwitchStopsCommitChain() async throws {
        guard GitRunner.isAvailable else {
            Issue.record("git ist in der Testumgebung nicht verfügbar")
            return
        }
        let (executor, workspace, defaults, suite) = makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        workspace.openProject(at: repository("action-a"))
        completeInitialRefresh(executor)
        workspace.gitStatus = .empty
        workspace.gitCommit(message: "Test")
        #expect(executor.startedArguments[4]
                == ["config", "--includes", "--local", "--get", "user.name"])
        executor.complete(4, with: success(Data("Test User\n".utf8)))
        executor.complete(5, with: success(Data("test@example.test\n".utf8)))
        executor.complete(6, with: success(Data("Global User\n".utf8)))
        executor.complete(7, with: success(Data("global@example.test\n".utf8)))
        // Die Completion springt bewusst auf die Main Queue. In der gesamten
        // parallelen Suite kann deren Scheduling deutlich länger dauern als
        // im isolierten Test; die Sicherheitsbehauptung hat keine 1-s-Frist.
        for _ in 0..<2_500 where executor.count < 9 {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard executor.count >= 9 else {
            Issue.record("Identity-Prüfung startete add nicht binnen 5 Sekunden")
            return
        }
        #expect(executor.startedArguments[8] == ["add", "-A"])

        workspace.openProject(at: repository("action-b"))
        executor.complete(8, with: success())
        #expect(!executor.startedArguments.contains { $0.first == "commit" })
    }

    @Test("Projektwechsel während Push-Preflight startet keinen Push im neuen Repo")
    func projectSwitchStopsPushChain() {
        guard GitRunner.isAvailable else {
            Issue.record("git ist in der Testumgebung nicht verfügbar")
            return
        }
        let (executor, workspace, defaults, suite) = makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        workspace.openProject(at: repository("push-a"))
        completeInitialRefresh(executor)
        workspace.gitPush()
        #expect(executor.startedArguments[4]
                == ["rev-parse", "--abbrev-ref", "@{u}"])

        workspace.openProject(at: repository("push-b"))
        executor.complete(4, with: success(Data("origin/main\n".utf8)))
        #expect(!executor.startedArguments.contains { $0.first == "push" })
    }
}
