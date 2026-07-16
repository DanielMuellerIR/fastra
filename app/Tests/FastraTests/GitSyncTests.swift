import Foundation
import Testing
@testable import Fastra

private final class SyncTestExecutor: GitCommandExecuting {
    final class Token: GitCancelling {
        private(set) var cancelled = false
        func cancel() { cancelled = true }
    }

    struct Call {
        let arguments: [String]
        let directory: URL
        let completion: (GitExecutionOutcome) -> Void
        let token: Token
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    var count: Int { lock.withLock { calls.count } }
    var arguments: [[String]] { lock.withLock { calls.map(\.arguments) } }
    var directories: [URL] { lock.withLock { calls.map(\.directory) } }
    func isCancelled(_ index: Int) -> Bool {
        lock.withLock { calls[index].token.cancelled }
    }

    @discardableResult
    func execute(arguments: [String], in directory: URL,
                 outputLimit: GitOutputLimit, policy: GitExecutionPolicy,
                 completion: @escaping (GitExecutionOutcome) -> Void) -> GitCancelling {
        let token = Token()
        lock.withLock {
            calls.append(Call(arguments: arguments, directory: directory,
                              completion: completion, token: token))
        }
        return token
    }

    func complete(_ index: Int, _ outcome: GitExecutionOutcome) {
        let completion = lock.withLock { calls[index].completion }
        completion(outcome)
    }
}

private func syncSuccess(_ stdout: String = "") -> GitExecutionOutcome {
    .completed(GitResult(exitCode: 0, stdout: stdout, stderr: ""))
}

private func syncFailure(_ stderr: String) -> GitExecutionOutcome {
    .completed(GitResult(exitCode: 1, stdout: "", stderr: stderr))
}

private func syncRepository(_ suffix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("Fastra-GitSync-\(suffix)-\(UUID().uuidString)")
}

private func syncPorcelain(oid: String = "abc", ahead: Int = 0,
                           behind: Int = 0) -> Data {
    var data = Data()
    for record in ["# branch.oid \(oid)", "# branch.head main",
                   "# branch.upstream origin/main",
                   "# branch.ab +\(ahead) -\(behind)"] {
        data.append(Data(record.utf8)); data.append(0)
    }
    return data
}

private func syncGraph(_ oid: String = "abc") -> Data {
    Data("\u{1e}\(oid)\u{1f}\u{1f}Test\u{1f}2026-07-15\u{1f}1\u{1f}HEAD -> main\u{1f}Commit".utf8)
}

@Suite("Git-Sync-Planung")
struct GitSyncPlanningTests {
    @Test("Fetch verwendet relevanten Upstream-Remote und optional Prune")
    func relevantFetchArguments() {
        var preferences = GitPreferences()
        preferences.prune = true
        #expect(GitFetchPlan.arguments(preferences: preferences,
                                       upstream: "company/topic",
                                       remotes: ["origin", "company"])
                == ["fetch", "--prune", "company"])
        #expect(GitFetchPlan.relevantRemote(upstream: nil,
                                            remotes: ["zeta", "origin"])
                == "origin")
        #expect(GitFetchPlan.relevantRemote(upstream: nil,
                                            remotes: ["zeta", "alpha"])
                == "alpha")
    }

    @Test("Alle Remotes erzeugt explizites --all ohne erfundenen Remote")
    func allFetchArguments() {
        var preferences = GitPreferences()
        preferences.remoteScope = .all
        #expect(GitFetchPlan.arguments(preferences: preferences,
                                       upstream: "origin/main", remotes: ["origin"])
                == ["fetch", "--all"])
    }

    @Test("Später unterdrückt die Frage bis zur nächsten sinnvollen Gelegenheit")
    func promptDeferral() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(GitFetchPromptPolicy.shouldPrompt(decision: .ask,
                                                  hasRemote: true, now: now,
                                                  deferredUntil: nil))
        #expect(!GitFetchPromptPolicy.shouldPrompt(
            decision: .ask, hasRemote: true, now: now,
            deferredUntil: now.addingTimeInterval(1)
        ))
        #expect(GitFetchPromptPolicy.shouldPrompt(
            decision: .ask, hasRemote: true,
            now: now.addingTimeInterval(GitFetchPromptPolicy.deferral),
            deferredUntil: now.addingTimeInterval(GitFetchPromptPolicy.deferral)
        ))
        #expect(!GitFetchPromptPolicy.shouldPrompt(decision: .automatic,
                                                   hasRemote: true, now: now,
                                                   deferredUntil: nil))
        #expect(!GitFetchPromptPolicy.shouldPrompt(decision: .ask,
                                                   hasRemote: false, now: now,
                                                   deferredUntil: nil))
    }

    @Test("Fetch-Fälligkeit misst ab dem letzten Versuch")
    func timing() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(GitAutoFetchTiming.isDue(lastAttempt: nil, now: now, interval: 180))
        #expect(!GitAutoFetchTiming.isDue(lastAttempt: now.addingTimeInterval(-179),
                                          now: now, interval: 180))
        #expect(GitAutoFetchTiming.isDue(lastAttempt: now.addingTimeInterval(-180),
                                         now: now, interval: 180))
    }

    @Test("Pull-Strategien haben ausschließlich explizite Argumente")
    func pullArguments() {
        #expect(GitPullPreflight.arguments(strategy: .unselected) == nil)
        #expect(GitPullPreflight.arguments(strategy: .rebase)
                == ["pull", "--rebase", "--no-autostash"])
        #expect(GitPullPreflight.arguments(strategy: .merge)
                == ["pull", "--no-rebase", "--no-autostash", "--ff"])
        #expect(GitPullPreflight.arguments(strategy: .ffOnly)
                == ["pull", "--ff-only", "--no-autostash"])
    }

    @Test("Pull-Preflight blockiert Operation, Konflikt und fehlenden Upstream")
    func pullPreflight() {
        var status = GitStatusSummary.empty
        #expect(GitPullPreflight.evaluate(status: status, operation: .rebase)
                == .operationInProgress(.rebase))
        #expect(GitPullPreflight.evaluate(status: status, operation: nil) == .noUpstream)
        status.upstream = "origin/main"
        status.changes = [GitChange(path: "file", staged: nil,
                                    unstaged: .conflicted)]
        #expect(GitPullPreflight.evaluate(status: status, operation: nil) == .unmerged)
        status.changes = [GitChange(path: "file", staged: nil,
                                    unstaged: .modified)]
        #expect(GitPullPreflight.evaluate(status: status, operation: nil)
                == .ready(hasLocalChanges: true))
    }

    @Test("Jede bekannte laufende Git-Operation blockiert Pull",
          arguments: GitOperationState.allCases)
    func everyOperationBlocksPull(_ operation: GitOperationState) {
        var status = GitStatusSummary.empty
        status.upstream = "origin/main"
        #expect(GitPullPreflight.evaluate(status: status, operation: operation)
                == .operationInProgress(operation))
    }
}

@Suite("Git-Repository-Identität")
struct GitRepositoryIdentityTests {
    @Test("Resolver verwendet git-common-dir, absolute Pfade und Cache")
    func resolverAndCache() throws {
        let executor = SyncTestExecutor()
        let resolver = GitRepositoryIdentityResolver(executor: executor)
        let root = syncRepository("identity")
        let common = syncRepository("common")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: common,
                                                withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8)
            .write(to: common.appendingPathComponent("HEAD"))
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: common)
        }
        var values: [GitRepositoryIdentity] = []
        resolver.resolve(root) { values.append($0) }
        #expect(executor.arguments == [["rev-parse", "--path-format=absolute",
                                        "--git-common-dir"]])
        executor.complete(0, syncSuccess(common.path + "\n"))
        #expect(values.last?.coordinationKey
                == GitOperationRequest.canonicalRepositoryPath(common))
        resolver.resolve(root) { values.append($0) }
        #expect(executor.count == 1)
        #expect(values.count == 2)
    }

    @Test("Resolver-Fehler fällt ehrlich auf den Worktree-Root zurück")
    func resolverFallback() {
        let executor = SyncTestExecutor()
        let resolver = GitRepositoryIdentityResolver(executor: executor)
        let root = syncRepository("fallback")
        var identity: GitRepositoryIdentity?
        resolver.resolve(root) { identity = $0 }
        executor.complete(0, .completed(GitResult(exitCode: 128, stdout: "",
                                                   stderr: "not a repository")))
        #expect(identity?.commonDirectory == nil)
        #expect(identity?.coordinationKey
                == GitOperationRequest.canonicalRepositoryPath(root))
    }

    @Test("Resolver verwirft ungültiges UTF-8 und nicht existente Common-Pfade")
    func resolverRejectsInvalidOutput() {
        let executor = SyncTestExecutor()
        let resolver = GitRepositoryIdentityResolver(executor: executor)
        let first = syncRepository("invalid-utf8")
        let second = syncRepository("missing-common")
        var identities: [GitRepositoryIdentity] = []
        resolver.resolve(first) { identities.append($0) }
        executor.complete(0, .completed(GitResult(
            exitCode: 0, stdoutData: Data([0xff, 0x0a]), stderrData: Data()
        )))
        resolver.resolve(second) { identities.append($0) }
        executor.complete(1, syncSuccess("/definitely/missing/fastra-common\n"))
        #expect(identities.count == 2)
        #expect(identities.allSatisfy { $0.commonDirectory == nil })
    }

    @Test("Worktrees mit gemeinsamem Common Directory teilen einen Slot")
    func commonDirectorySerializesWorktrees() {
        let executor = SyncTestExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let common = syncRepository("shared-common")
        let first = syncRepository("worktree-a")
        let second = syncRepository("worktree-b")
        coordinator.register(GitRepositoryIdentity(worktreeRoot: first,
                                                   commonDirectory: common))
        coordinator.register(GitRepositoryIdentity(worktreeRoot: second,
                                                   commonDirectory: common))
        coordinator.perform(GitOperationRequest(repository: first, kind: .pull,
                                                arguments: ["pull", "--ff-only"])) { _ in }
        coordinator.perform(GitOperationRequest(repository: second, kind: .push,
                                                arguments: ["push"])) { _ in }
        #expect(executor.count == 1)
        executor.complete(0, syncSuccess())
        #expect(executor.count == 2)
        executor.complete(1, syncSuccess())
        #expect(coordinator.state(for: first) == .idle)
        #expect(coordinator.state(for: second) == .idle)
    }

    @Test("Worktree-Reads bleiben getrennt, gemeinsamer Fetch wird dedupliziert")
    func worktreeReadIdentityAndFetchDedup() {
        let executor = SyncTestExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let common = syncRepository("shared-read-common")
        let first = syncRepository("read-worktree-a")
        let second = syncRepository("read-worktree-b")
        coordinator.register(GitRepositoryIdentity(worktreeRoot: first,
                                                   commonDirectory: common))
        coordinator.register(GitRepositoryIdentity(worktreeRoot: second,
                                                   commonDirectory: common))
        let read = ["status", "--short"]
        coordinator.perform(GitOperationRequest(repository: first, kind: .refresh,
                                                arguments: read)) { _ in }
        coordinator.perform(GitOperationRequest(repository: second, kind: .refresh,
                                                arguments: read)) { _ in }
        #expect(executor.count == 1)
        executor.complete(0, syncSuccess())
        #expect(executor.count == 2)
        executor.complete(1, syncSuccess())

        coordinator.perform(GitOperationRequest(repository: first, kind: .fetch,
                                                arguments: ["fetch", "origin"])) { _ in }
        coordinator.perform(GitOperationRequest(repository: second, kind: .fetch,
                                                arguments: ["fetch", "origin"])) { _ in }
        #expect(executor.count == 3)
        executor.complete(2, syncSuccess())
        #expect(coordinator.state(for: first) == .idle)
    }

    @Test("Operation-State nutzt die von Git gelieferten Worktree-Pfade")
    func operationStatePaths() throws {
        let root = syncRepository("operation-state")
        let git = root.appendingPathComponent("metadata")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        let marker = git.appendingPathComponent("rebase-merge")
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = GitOperationStateDetector.markers.map { state, name in
            state == .rebase && name == "rebase-merge" ? marker.path
                : git.appendingPathComponent(name).path
        }.joined(separator: "\n")
        #expect(GitOperationStateDetector.detect(stdout: paths, repository: root)
                == .rebase)
    }
}

@Suite("Git-Fetch-Store")
struct GitFetchStoreTests {
    @Test("Fetch publiziert Busy, Erfolg und startet konsistent Full-Refresh")
    func fetchLifecycle() {
        let executor = SyncTestExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let store = GitRepositoryStore(executor: executor, coordinator: coordinator)
        let root = syncRepository("fetch-store")
        store.refresh(repository: root, scope: .full)
        executor.complete(0, .completed(GitResult(exitCode: 0,
                                                   stdoutData: syncPorcelain(),
                                                   stderrData: Data())))
        executor.complete(1, syncSuccess())
        executor.complete(2, syncSuccess("main\t*\n"))
        executor.complete(3, .completed(GitResult(exitCode: 0,
                                                   stdoutData: syncGraph(),
                                                   stderrData: Data())))

        store.fetch(repository: root, preferences: GitPreferences(),
                    remotes: ["origin"])
        #expect(executor.arguments[4] == ["fetch", "origin"])
        #expect(store.snapshot(for: root)?.fetch.isBusy == true)
        executor.complete(4, syncSuccess())
        #expect(store.snapshot(for: root)?.fetch.isBusy == false)
        #expect(store.snapshot(for: root)?.fetch.lastAttempt != nil)
        #expect(store.snapshot(for: root)?.fetch.lastSuccess != nil)
        #expect(store.snapshot(for: root)?.fetch.error == nil)
        #expect(executor.count == 9)
    }

    @Test("Fetch-Fehler bewahrt echte Git-Ausgabe und bietet neuen Versuch")
    func fetchFailureAndRetry() {
        let executor = SyncTestExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let store = GitRepositoryStore(executor: executor, coordinator: coordinator)
        let root = syncRepository("fetch-error")
        store.fetch(repository: root, preferences: GitPreferences(), remotes: ["origin"])
        executor.complete(0, .completed(GitResult(exitCode: 128, stdout: "",
                                                   stderr: "authentication failed")))
        #expect(store.snapshot(for: root)?.fetch.error == "authentication failed")
        #expect(store.snapshot(for: root)?.fetch.isBusy == false)
        // Der nach Fehler automatisch gestartete Full-Refresh bleibt zuerst im
        // Repo-Slot; nach dessen Abschluss darf ein bewusster Retry starten.
        executor.complete(1, .completed(GitResult(exitCode: 128, stdout: "",
                                                   stderr: "not a repository")))
        executor.complete(2, .completed(GitResult(exitCode: 128, stdout: "",
                                                   stderr: "not a repository")))
        executor.complete(3, .completed(GitResult(exitCode: 128, stdout: "",
                                                   stderr: "not a repository")))
        executor.complete(4, .completed(GitResult(exitCode: 128, stdout: "",
                                                   stderr: "not a repository")))
        store.fetch(repository: root, preferences: GitPreferences(), remotes: ["origin"])
        #expect(executor.arguments[5] == ["fetch", "origin"])
    }

    @Test("Fetch ohne Git-Text liefert lokalisierbaren Exit-Code-Fallback")
    func fetchFailureFallback() {
        let executor = SyncTestExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let store = GitRepositoryStore(executor: executor, coordinator: coordinator)
        let root = syncRepository("fetch-empty-error")
        store.fetch(repository: root, preferences: GitPreferences(), remotes: ["origin"])
        executor.complete(0, .completed(GitResult(exitCode: 23, stdout: "", stderr: "")))
        #expect(store.snapshot(for: root)?.fetch.error?.contains("23") == true)
    }

    @Test("Gleichzeitige Fetch-Anfragen reservieren atomar genau einen Start")
    func fetchReservationIsAtomic() {
        let executor = SyncTestExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let store = GitRepositoryStore(executor: executor, coordinator: coordinator)
        let root = syncRepository("fetch-atomic")
        let group = DispatchGroup()
        for _ in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                _ = store.fetch(repository: root, preferences: GitPreferences(),
                                remotes: ["origin"])
                group.leave()
            }
        }
        group.wait()
        #expect(executor.count == 1)
        #expect(store.snapshot(for: root)?.fetch.isBusy == true)
    }
}

private final class ManualGitScheduler: GitSyncScheduling {
    final class Token: GitCancelling {
        private(set) var cancelled = false
        func cancel() { cancelled = true }
    }
    private let lock = NSLock()
    private var items: [(Token, TimeInterval, () -> Void)] = []

    var scheduledCount: Int { lock.withLock { items.count } }
    var activeCount: Int { lock.withLock { items.filter { !$0.0.cancelled }.count } }
    var activeDelays: [TimeInterval] {
        lock.withLock { items.filter { !$0.0.cancelled }.map(\.1) }
    }

    func schedule(after seconds: TimeInterval,
                  action: @escaping () -> Void) -> GitCancelling {
        let token = Token()
        lock.withLock { items.append((token, seconds, action)) }
        return token
    }

    func fireNext() {
        let action: (() -> Void)? = lock.withLock {
            guard let index = items.firstIndex(where: { !$0.0.cancelled }) else { return nil }
            items[index].0.cancel()
            return items[index].2
        }
        action?()
    }
}

private final class MutableGitClock: GitSyncClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private struct AsyncTestTimeout: Error {}

private func waitUntil(_ description: String = "Asynchroner Testzustand wurde nicht erreicht",
                       timeout: Duration = .seconds(3),
                       _ condition: @escaping () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record(Comment(rawValue: description))
    throw AsyncTestTimeout()
}

@Suite("Auto-Fetch-Steuerung", .serialized)
struct GitAutoFetchControllerTests {
    private func makeController(decision: GitAutomaticFetchDecision = .automatic)
        -> (GitAutoFetchController, SyncTestExecutor, ManualGitScheduler,
            UserDefaults, String) {
        let suite = "Fastra-GitAutoFetch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferencesStore = GitPreferencesStore(defaults: defaults)
        var preferences = GitPreferences()
        preferences.automaticFetchDecision = decision
        preferencesStore.save(preferences)
        let executor = SyncTestExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let store = GitRepositoryStore(executor: executor, coordinator: coordinator)
        let scheduler = ManualGitScheduler()
        let controller = GitAutoFetchController(store: store,
                                                preferences: preferencesStore,
                                                executor: executor,
                                                scheduler: scheduler)
        return (controller, executor, scheduler, defaults, suite)
    }

    @Test("Ohne Aktivierungs-Fetch wartet der erste Abruf ein volles Intervall")
    func activationWithoutImmediateFetch() async throws {
        let suite = "Fastra-GitAutoFetch-Activation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = GitPreferences()
        preferences.automaticFetchDecision = .automatic
        preferences.fetchOnActivation = false
        let preferenceStore = GitPreferencesStore(defaults: defaults)
        preferenceStore.save(preferences)
        let executor = SyncTestExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let store = GitRepositoryStore(executor: executor, coordinator: coordinator)
        let scheduler = ManualGitScheduler()
        let clock = MutableGitClock(Date(timeIntervalSince1970: 10_000))
        let controller = GitAutoFetchController(
            store: store, preferences: preferenceStore, clock: clock,
            executor: executor, scheduler: scheduler
        )
        controller.setActive(false)
        let observation = controller.attach(repository: syncRepository("activation-floor"),
                                            remotes: ["origin"])
        controller.setActive(true)
        try await waitUntil { scheduler.activeCount == 1 }
        #expect(executor.count == 0)
        #expect(scheduler.activeDelays.first == 180)
        clock.now = clock.now.addingTimeInterval(180)
        scheduler.fireNext()
        try await waitUntil { executor.count == 1 }
        observation.cancel()
    }

    @Test("Timer startet nur die pro Repository fälligen Fetches")
    func staggeredRepositories() async throws {
        let suite = "Fastra-GitAutoFetch-Staggered-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = GitPreferences()
        preferences.automaticFetchDecision = .automatic
        let preferenceStore = GitPreferencesStore(defaults: defaults)
        preferenceStore.save(preferences)
        let executor = SyncTestExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let store = GitRepositoryStore(executor: executor, coordinator: coordinator)
        let scheduler = ManualGitScheduler()
        let clock = MutableGitClock(Date(timeIntervalSince1970: 20_000))
        let controller = GitAutoFetchController(
            store: store, preferences: preferenceStore, clock: clock,
            executor: executor, scheduler: scheduler
        )
        let firstRoot = syncRepository("stagger-a")
        let secondRoot = syncRepository("stagger-b")
        let first = controller.attach(repository: firstRoot, remotes: ["origin"])
        try await waitUntil { executor.count == 1 }
        executor.complete(0, syncSuccess())
        try await waitUntil { executor.count == 5 }
        for index in 1...4 { executor.complete(index, syncSuccess()) }

        clock.now = clock.now.addingTimeInterval(60)
        let second = controller.attach(repository: secondRoot, remotes: ["origin"])
        try await waitUntil { executor.count == 6 }
        executor.complete(5, syncSuccess())
        try await waitUntil { executor.count == 10 }
        for index in 6...9 { executor.complete(index, syncSuccess()) }

        clock.now = clock.now.addingTimeInterval(120)
        scheduler.fireNext()
        try await waitUntil("Fälliger Fetch des ersten Repositories wurde nicht gestartet") {
            executor.count == 11
        }
        let directories = executor.directories
        let arguments = executor.arguments
        let directory = try #require(
            directories.indices.contains(10) ? directories[10] : nil
        )
        let fetchArguments = try #require(
            arguments.indices.contains(10) ? arguments[10] : nil
        )
        #expect(directory.standardizedFileURL == firstRoot.standardizedFileURL)
        #expect(fetchArguments == ["fetch", "origin"])
        first.cancel(); second.cancel()
    }

    @Test("Inaktive App startet keinen Fetch und hält keinen Timer")
    func inactiveStopsTimer() async {
        let (controller, executor, scheduler, defaults, suite) = makeController()
        defer { defaults.removePersistentDomain(forName: suite) }
        controller.setActive(false)
        let observation = controller.attach(repository: syncRepository("inactive"),
                                            remotes: ["origin"])
        for _ in 0..<100 { await Task.yield() }
        #expect(executor.count == 0)
        #expect(scheduler.scheduledCount == 0)
        #expect(scheduler.activeCount == 0)
        observation.cancel()
    }

    @Test("Mehrere Fenster desselben Repositories deduplizieren Fetch")
    func sameRepositoryDedup() async throws {
        let (controller, executor, _, defaults, suite) = makeController()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = syncRepository("multi-window")
        let first = controller.attach(repository: root, remotes: ["origin"])
        let second = controller.attach(repository: root, remotes: ["origin"])
        try await waitUntil { executor.count == 1 }
        #expect(executor.arguments == [["fetch", "origin"]])
        first.cancel()
        #expect(!executor.isCancelled(0))
        second.cancel()
        try await waitUntil { executor.isCancelled(0) }
        #expect(executor.isCancelled(0))
    }

    @Test("Mehrere Fenster zeigen nur eine Erstfrage und Später wird respektiert")
    func promptIsSingleAndDeferred() async throws {
        let (controller, executor, _, defaults, suite) = makeController(decision: .ask)
        defer { defaults.removePersistentDomain(forName: suite) }
        let lock = NSLock()
        var prompts: [((GitFetchPromptChoice) -> Void)] = []
        let prompt: (@escaping (GitFetchPromptChoice) -> Void) -> Void = { choice in
            lock.withLock { prompts.append(choice) }
        }
        let root = syncRepository("prompt-shared")
        let first = controller.observe(repository: root, prompt: prompt)
        let second = controller.observe(repository: root, prompt: prompt)
        executor.complete(0, syncSuccess("origin\n"))
        executor.complete(1, syncSuccess("origin\n"))
        try await waitUntil { lock.withLock { prompts.count == 1 } }
        lock.withLock { prompts[0] }(.later)
        try await waitUntil {
            GitPreferencesStore(defaults: defaults).promptDeferredUntil != nil
        }
        let third = controller.observe(repository: root, prompt: prompt)
        try await waitUntil { executor.count == 3 }
        executor.complete(2, syncSuccess("origin\n"))
        for _ in 0..<100 { await Task.yield() }
        #expect(lock.withLock { prompts.count } == 1)
        first.cancel(); second.cancel(); third.cancel()
    }

    @Test("Verschiedene Repositories dürfen parallel fetchen")
    func differentRepositoriesParallel() async throws {
        let (controller, executor, _, defaults, suite) = makeController()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = controller.attach(repository: syncRepository("parallel-a"),
                                      remotes: ["origin"])
        let second = controller.attach(repository: syncRepository("parallel-b"),
                                       remotes: ["origin"])
        try await waitUntil { executor.count == 2 }
        #expect(executor.arguments.allSatisfy { $0 == ["fetch", "origin"] })
        first.cancel(); second.cancel()
    }
}

@Suite("Workspace-Pull", .serialized)
struct GitWorkspacePullTests {
    @Test("Erster Pull persistiert Rebase und startet weder Stash noch Push")
    func firstPullUsesExplicitRebase() async throws {
        guard GitRunner.isAvailable else { return }
        let executor = SyncTestExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let store = GitRepositoryStore(executor: executor, coordinator: coordinator)
        let suite = "Fastra-Pull-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults,
                                  gitOperationsCoordinator: coordinator,
                                  gitRepositoryStore: store)
        let root = syncRepository("workspace-pull")
        workspace.openProject(at: root)
        executor.complete(0, .completed(GitResult(exitCode: 0,
                                                   stdoutData: syncPorcelain(),
                                                   stderrData: Data())))
        let absentMarkers = GitOperationStateDetector.markers
            .map { root.appendingPathComponent($0.1).path }
            .joined(separator: "\n") + "\n"
        executor.complete(1, syncSuccess(absentMarkers))
        executor.complete(2, syncSuccess("main\t*\n"))
        executor.complete(3, .completed(GitResult(exitCode: 0,
                                                   stdoutData: syncGraph(),
                                                   stderrData: Data())))
        try await waitUntil("Initialer Store-Snapshot wurde nicht veröffentlicht") {
            workspace.gitStatus != nil
        }
        let oldDialogs = Workspace.presentGitDialogs
        Workspace.presentGitDialogs = false
        defer { Workspace.presentGitDialogs = oldDialogs }
        workspace.gitPull()
        #expect(executor.arguments[4] == GitStatusParser.arguments)
        executor.complete(4, .completed(GitResult(exitCode: 0,
                                                   stdoutData: syncPorcelain(),
                                                   stderrData: Data())))
        try await waitUntil("Erste Operationsprüfung wurde nicht gestartet") { executor.count >= 6 }
        #expect(executor.arguments[5] == GitOperationStateDetector.arguments)
        executor.complete(5, syncSuccess(absentMarkers))
        try await waitUntil("Zweite Statusprüfung wurde nicht gestartet") { executor.count >= 7 }
        #expect(executor.arguments[6] == GitStatusParser.arguments)
        executor.complete(6, .completed(GitResult(exitCode: 0,
                                                   stdoutData: syncPorcelain(),
                                                   stderrData: Data())))
        try await waitUntil("Zweite Operationsprüfung wurde nicht gestartet") { executor.count >= 8 }
        executor.complete(7, syncSuccess(absentMarkers))
        try await waitUntil("Lokaler Name wurde nicht geprüft") { executor.count >= 9 }
        #expect(executor.arguments[8]
                == ["config", "--includes", "--local", "--get", "user.name"])
        executor.complete(8, syncSuccess("Fastra Test\n"))
        try await waitUntil("Lokale E-Mail wurde nicht geprüft") { executor.count >= 10 }
        #expect(executor.arguments[9]
                == ["config", "--includes", "--local", "--get", "user.email"])
        executor.complete(9, syncSuccess("fastra@example.test\n"))
        try await waitUntil("Globaler Name wurde nicht geprüft") { executor.count >= 11 }
        #expect(executor.arguments[10]
                == ["config", "--includes", "--global", "--get", "user.name"])
        executor.complete(10, syncFailure("nicht gesetzt"))
        try await waitUntil("Globale E-Mail wurde nicht geprüft") { executor.count >= 12 }
        #expect(executor.arguments[11]
                == ["config", "--includes", "--global", "--get", "user.email"])
        executor.complete(11, syncFailure("nicht gesetzt"))
        try await waitUntil("Pull wurde nach Identitätsprüfung nicht gestartet") { executor.count >= 13 }
        #expect(executor.arguments[12]
                == ["pull", "--rebase", "--no-autostash"])
        #expect(workspace.gitPreferencesStore.load().pullStrategy == .rebase)
        #expect(!executor.arguments.contains { $0.first == "stash" || $0.first == "push" })
    }

    @Test("Geänderter frischer Status stoppt Pull vor der Mutation")
    func statusChangeStopsPull() async throws {
        let executor = SyncTestExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let root = syncRepository("pull-revalidation")
        let outcomeLock = NSLock()
        var outcome: GitSafePullOutcome?
        _ = GitSafePullRunner.run(repository: root, strategy: .rebase,
                                  coordinator: coordinator) { _, proceed in
            proceed(true)
        } completion: { value in
            outcomeLock.withLock { outcome = value }
        }
        executor.complete(0, .completed(GitResult(exitCode: 0,
                                                   stdoutData: syncPorcelain(),
                                                   stderrData: Data())))
        try await waitUntil { executor.count == 2 }
        let absent = GitOperationStateDetector.markers
            .map { root.appendingPathComponent($0.1).path }.joined(separator: "\n") + "\n"
        executor.complete(1, syncSuccess(absent))
        try await waitUntil { executor.count == 3 }
        executor.complete(2, .completed(GitResult(exitCode: 0,
                                                   stdoutData: syncPorcelain(oid: "changed"),
                                                   stderrData: Data())))
        try await waitUntil { executor.count == 4 }
        executor.complete(3, syncSuccess(absent))
        try await waitUntil { outcomeLock.withLock { outcome != nil } }
        #expect(outcomeLock.withLock { outcome } == .repositoryChanged)
        #expect(!executor.arguments.contains { $0.first == "pull" })
    }

    @Test("Zwei schnelle Pull-Klicks starten genau eine Sicherheitsprüfung")
    func duplicatePullIsIgnored() {
        let executor = SyncTestExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let store = GitRepositoryStore(executor: executor, coordinator: coordinator)
        let suite = "Fastra-Pull-Dedup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = GitPreferences()
        preferences.pullStrategy = .rebase
        GitPreferencesStore(defaults: defaults).save(preferences)
        let workspace = Workspace(defaults: defaults,
                                  gitOperationsCoordinator: coordinator,
                                  gitRepositoryStore: store)
        workspace.projectURL = syncRepository("pull-dedup")
        var status = GitStatusSummary.empty
        status.upstream = "origin/main"
        workspace.gitStatus = status
        workspace.gitPull()
        workspace.gitPull()
        #expect(executor.count == 1)
        #expect(executor.arguments[0] == GitStatusParser.arguments)
    }
}

private func realGit(_ arguments: [String], in directory: URL) async -> GitResult {
    await withCheckedContinuation { continuation in
        GitRunner.runDetailed(arguments, in: directory) { outcome in
            switch outcome {
            case .completed(let result): continuation.resume(returning: result)
            default:
                continuation.resume(returning: GitResult(exitCode: -1,
                                                          stdout: "",
                                                          stderr: "GitRunner: \(outcome)"))
            }
        }
    }
}

@Suite("Git-Sync mit lokalen Remotes", .serialized)
struct GitSyncRepositoryIntegrationTests {
    @Test("Echte verlinkte Worktrees teilen Common Dir, nicht HEAD oder Markerpfade")
    func linkedWorktreeIdentity() async throws {
        guard GitRunner.isAvailable else { return }
        let base = syncRepository("linked-worktree-fixture")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let main = base.appendingPathComponent("main")
        let linked = base.appendingPathComponent("linked")
        #expect((await realGit(["init", "-b", "main", main.path], in: base)).ok)
        #expect((await realGit(["config", "user.name", "Fastra Test"], in: main)).ok)
        #expect((await realGit(["config", "user.email", "fastra@example.invalid"],
                              in: main)).ok)
        try Data("initial\n".utf8).write(to: main.appendingPathComponent("file.txt"))
        #expect((await realGit(["add", "--", "file.txt"], in: main)).ok)
        #expect((await realGit(["commit", "-m", "Initial"], in: main)).ok)
        #expect((await realGit(["branch", "linked-branch"], in: main)).ok)
        #expect((await realGit(["worktree", "add", linked.path, "linked-branch"],
                              in: main)).ok)

        let commonArguments = ["rev-parse", "--path-format=absolute", "--git-common-dir"]
        let mainCommon = await realGit(commonArguments, in: main)
        let linkedCommon = await realGit(commonArguments, in: linked)
        #expect(mainCommon.ok && linkedCommon.ok)
        #expect(mainCommon.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == linkedCommon.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        let mainStatus = GitStatusParser.parse(
            (await realGit(GitStatusParser.arguments, in: main)).stdoutData
        )
        let linkedStatus = GitStatusParser.parse(
            (await realGit(GitStatusParser.arguments, in: linked)).stdoutData
        )
        #expect(mainStatus.branch == "main")
        #expect(linkedStatus.branch == "linked-branch")
        let mainMarkers = await realGit(GitOperationStateDetector.arguments, in: main)
        let linkedMarkers = await realGit(GitOperationStateDetector.arguments, in: linked)
        #expect(mainMarkers.ok && linkedMarkers.ok)
        #expect(mainMarkers.stdout != linkedMarkers.stdout)
    }

    @Test("Lokaler Bare-Remote liefert nach Fetch exaktes Behind")
    func fetchAheadBehind() async throws {
        guard GitRunner.isAvailable else { return }
        let base = syncRepository("bare-fixture")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let remote = base.appendingPathComponent("remote.git")
        let local = base.appendingPathComponent("local")
        let peer = base.appendingPathComponent("peer")

        #expect((await realGit(["init", "--bare", remote.path], in: base)).ok)
        #expect((await realGit(["init", "-b", "main", local.path], in: base)).ok)
        #expect((await realGit(["config", "user.name", "Fastra Test"], in: local)).ok)
        #expect((await realGit(["config", "user.email", "fastra@example.invalid"], in: local)).ok)
        try Data("one\n".utf8).write(to: local.appendingPathComponent("file.txt"))
        #expect((await realGit(["add", "--", "file.txt"], in: local)).ok)
        #expect((await realGit(["commit", "-m", "Initial"], in: local)).ok)
        #expect((await realGit(["remote", "add", "origin", remote.path], in: local)).ok)
        #expect((await realGit(["push", "-u", "origin", "main"], in: local)).ok)
        #expect((await realGit(["clone", "--branch", "main", remote.path, peer.path],
                               in: base)).ok)
        #expect((await realGit(["config", "user.name", "Fastra Test"], in: peer)).ok)
        #expect((await realGit(["config", "user.email", "fastra@example.invalid"], in: peer)).ok)
        try Data("two\n".utf8).write(to: peer.appendingPathComponent("file.txt"))
        #expect((await realGit(["add", "--", "file.txt"], in: peer)).ok)
        #expect((await realGit(["commit", "-m", "Remote"], in: peer)).ok)
        #expect((await realGit(["push", "origin", "main"], in: peer)).ok)

        let fetch = await realGit(["fetch", "origin"], in: local)
        #expect(fetch.ok)
        let status = await realGit(GitStatusParser.arguments, in: local)
        #expect(status.ok)
        let summary = GitStatusParser.parse(status.stdoutData)
        #expect(summary.upstream == "origin/main")
        #expect(summary.ahead == 0)
        #expect(summary.behind == 1)

        // Ein zusätzlicher lokaler Commit erzeugt echte Divergenz. FF-only
        // muss ablehnen und darf weder Stash noch Push als Nebenwirkung starten.
        try Data("local\n".utf8).write(to: local.appendingPathComponent("local.txt"))
        #expect((await realGit(["add", "--", "local.txt"], in: local)).ok)
        #expect((await realGit(["commit", "-m", "Local"], in: local)).ok)
        let divergentStatus = await realGit(GitStatusParser.arguments, in: local)
        let divergent = GitStatusParser.parse(divergentStatus.stdoutData)
        #expect(divergent.ahead == 1)
        #expect(divergent.behind == 1)
        #expect((await realGit(["config", "rebase.autoStash", "true"], in: local)).ok)
        #expect((await realGit(["config", "merge.autoStash", "true"], in: local)).ok)
        #expect((await realGit(["config", "pull.ff", "only"], in: local)).ok)
        let ffOnly = await realGit(
            GitPullPreflight.arguments(strategy: .ffOnly)!, in: local
        )
        #expect(!ffOnly.ok)
        #expect((await realGit(["stash", "list"], in: local)).stdout.isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: local.appendingPathComponent("local.txt").path
        ))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
