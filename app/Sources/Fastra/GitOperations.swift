import Foundation

protocol GitCancelling: AnyObject {
    func cancel()
}

extension GitCancellationToken: GitCancelling {}

protocol GitCommandExecuting: AnyObject {
    @discardableResult
    func execute(arguments: [String], in directory: URL,
                 outputLimit: GitOutputLimit, policy: GitExecutionPolicy,
                 completion: @escaping (GitExecutionOutcome) -> Void)
        -> GitCancelling
}

final class GitRunnerExecutor: GitCommandExecuting {
    @discardableResult
    func execute(arguments: [String], in directory: URL,
                 outputLimit: GitOutputLimit = .default,
                 policy: GitExecutionPolicy = .default,
                 completion: @escaping (GitExecutionOutcome) -> Void)
        -> GitCancelling {
        GitRunner.runDetailed(arguments, in: directory, outputLimit: outputLimit,
                              policy: policy, completion: completion)
    }
}

enum GitOperationKind: String, Equatable, Hashable {
    case refresh
    /// Veränderliche Diff-Lesevorgänge laufen seriell, werden aber niemals
    /// dedupliziert: Ein nach dem Speichern angeforderter Lauf muss wirklich
    /// hinter einem bereits laufenden alten Read ausgeführt werden.
    case diffRead
    case fetch
    case pull
    case push
    case checkout
    case workingTreeMutation
}

struct GitOperationRequest: Equatable, Hashable {
    let repository: URL
    let kind: GitOperationKind
    let arguments: [String]
    var outputLimit: GitOutputLimit = .default
    var policy: GitExecutionPolicy = .default

    static func canonicalRepositoryPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    var repositoryKey: String { Self.canonicalRepositoryPath(repository) }

    static func == (lhs: GitOperationRequest, rhs: GitOperationRequest) -> Bool {
        lhs.repositoryKey == rhs.repositoryKey && lhs.kind == rhs.kind
            && lhs.arguments == rhs.arguments && lhs.outputLimit == rhs.outputLimit
            && lhs.policy == rhs.policy
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(repositoryKey)
        hasher.combine(kind)
        hasher.combine(arguments)
        hasher.combine(outputLimit.stdoutBytes)
        hasher.combine(outputLimit.stderrBytes)
        hasher.combine(policy.timeout)
        hasher.combine(policy.terminationGracePeriod)
        hasher.combine(policy.editorPolicy)
        hasher.combine(policy.standardInput)
    }
}

struct GitOperationsState: Equatable {
    var active: GitOperationKind?
    var queued: [GitOperationKind]
    var isBusy: Bool { active != nil || !queued.isEmpty }

    static let idle = GitOperationsState(active: nil, queued: [])

    func contains(_ kind: GitOperationKind) -> Bool {
        active == kind || queued.contains(kind)
    }
}

/// Eine Lease storniert genau den zugehörigen Interessenten. Bei einem
/// deduplizierten Fetch läuft der gemeinsame Prozess für andere Fenster weiter.
final class GitOperationLease: GitCancelling, @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    init(_ cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        lock.lock()
        let action = cancellation
        cancellation = nil
        lock.unlock()
        action?()
    }
}

/// Schaltet eine verschachtelte Coordinator-Lease ab einer irreversiblen
/// Mutationsgrenze auf Cleanup um. Der Nutzer darf seinen Interessenten weiter
/// schließen; globale Barriere und Repository-Slot bleiben dennoch bis zum
/// internen Abschluss gehalten.
final class GitOperationCancellationGate: @unchecked Sendable {
    enum CancellationDecision: Equatable {
        case won
        case alreadyRequested
        case protected
    }

    private enum State { case open, cancelRequested, protected }
    private let lock = NSLock()
    private var state: State = .open
    private let beforeProtectionAttempt: (() -> Void)?

    init(beforeProtectionAttempt: (() -> Void)? = nil) {
        self.beforeProtectionAttempt = beforeProtectionAttempt
    }

    /// Abbruch und Mutationsschutz konkurrieren um genau denselben Zustand.
    /// Dadurch kann kein bereits weitergeleiteter Abbruch anschließend noch
    /// von einer scheinbar erfolgreichen Mutationsgrenze überholt werden.
    func beginProtection() -> Bool {
        beforeProtectionAttempt?()
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .open:
            state = .protected
            return true
        case .cancelRequested:
            return false
        case .protected:
            return true
        }
    }

    func requestCancellation() -> CancellationDecision {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .open:
            state = .cancelRequested
            return .won
        case .cancelRequested:
            return .alreadyRequested
        case .protected:
            return .protected
        }
    }
}

private final class GitGatedCancellation: GitCancelling {
    private let token: GitCancelling
    private let gate: GitOperationCancellationGate

    init(token: GitCancelling, gate: GitOperationCancellationGate) {
        self.token = token
        self.gate = gate
    }

    func cancel() {
        if gate.requestCancellation() == .won { token.cancel() }
    }
}

/// Mehrere Prozesse eines atomaren Read-Batches teilen einen Abbruchzustand.
private final class GitCompositeCancellation: GitCancelling {
    private let lock = NSLock()
    private var tokens: [GitCancelling] = []
    private var cancelled = false

    func add(_ token: GitCancelling) {
        lock.lock()
        if cancelled { lock.unlock(); token.cancel(); return }
        tokens.append(token)
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let current = tokens
        lock.unlock()
        current.forEach { $0.cancel() }
    }
}

/// App-weite Schranke für Git-Operationen. Der Slot bleibt bei einem Full-
/// Refresh über alle drei Read-Prozesse gehalten; eine Mutation kann deshalb
/// nie zwischen Status, Branches und Graph rutschen.
final class GitOperationsCoordinator {
    static let shared = GitOperationsCoordinator(executor: GitRunnerExecutor())

    typealias Starter = (@escaping (GitExecutionOutcome) -> Void) -> GitCancelling

    private final class Pending {
        let id = UUID()
        let repository: URL
        let kind: GitOperationKind
        let identity: String
        let starter: Starter
        var subscribers: [UUID: (GitExecutionOutcome) -> Void] = [:]
        var activeToken: GitCancelling?
        var hasStarted = false

        init(repository: URL, kind: GitOperationKind, identity: String,
             subscriberID: UUID,
             completion: @escaping (GitExecutionOutcome) -> Void,
             starter: @escaping Starter) {
            self.repository = repository
            self.kind = kind
            self.identity = identity
            self.starter = starter
            subscribers[subscriberID] = completion
        }
    }

    private let executor: GitCommandExecuting
    private let lock = NSLock()
    private var queues: [String: [Pending]] = [:]
    /// Worktree-Root → gemeinsames Git-Verzeichnis. Die Zuordnung wird erst
    /// nach erfolgreichem `rev-parse --git-common-dir` eingetragen; Fehler
    /// lassen bewusst den bisherigen Root-Key stehen.
    private var repositoryAliases: [String: String] = [:]

    init(executor: GitCommandExecuting) {
        self.executor = executor
    }

    func register(_ identity: GitRepositoryIdentity) {
        guard identity.commonDirectory != nil else { return }
        let root = GitOperationRequest.canonicalRepositoryPath(identity.worktreeRoot)
        lock.lock()
        repositoryAliases[root] = identity.coordinationKey
        lock.unlock()
    }

    private func coordinationKey(for repository: URL) -> String {
        let root = GitOperationRequest.canonicalRepositoryPath(repository)
        lock.lock(); defer { lock.unlock() }
        return repositoryAliases[root] ?? root
    }

    @discardableResult
    func perform(_ request: GitOperationRequest,
                 completion: @escaping (GitExecutionOutcome) -> Void)
        -> GitOperationLease {
        let worktreeIdentity = request.kind == .fetch ? "" : request.repositoryKey + "|"
        let identity = worktreeIdentity + request.arguments.joined(separator: "\u{0}")
            + "|\(request.outputLimit.stdoutBytes)|\(request.outputLimit.stderrBytes)"
            + "|\(String(describing: request.policy.timeout))"
            + "|\(request.policy.terminationGracePeriod)"
            + "|\(String(describing: request.policy.editorPolicy))"
        return enqueue(repository: request.repository, kind: request.kind,
                       identity: identity, completion: completion) { [executor] finish in
            executor.execute(arguments: request.arguments, in: request.repository,
                             outputLimit: request.outputLimit, policy: request.policy,
                             completion: finish)
        }
    }

    /// Store-interner atomarer Batch. `identity` dedupliziert nur Read-Batches;
    /// Mutationen bleiben immer einzelne, bewusst geordnete Vorgänge.
    @discardableResult
    func performBatch(repository: URL, identity: String,
                      starter: @escaping Starter,
                      completion: @escaping (GitExecutionOutcome) -> Void)
        -> GitOperationLease {
        enqueue(repository: repository, kind: .refresh, identity: identity,
                completion: completion, starter: starter)
    }

    /// Hält denselben Repo-Slot über eine mehrstufige Operation. Der Starter
    /// bekommt den injizierten Executor, damit auch Preflight und Mutation in
    /// Tests exakt dieselbe kontrollierte Prozessquelle verwenden.
    @discardableResult
    func performExclusive(repository: URL, kind: GitOperationKind,
                          identity: String, starter: @escaping Starter,
                          completion: @escaping (GitExecutionOutcome) -> Void)
        -> GitOperationLease {
        enqueue(repository: repository, kind: kind,
                identity: GitOperationRequest.canonicalRepositoryPath(repository)
                    + "|" + identity,
                completion: completion, starter: starter)
    }

    /// Erzwingt appweit die feste Sperrreihenfolge „globale Git-Identität,
    /// dann Repository“. Commit-erzeugende Vorgänge und lokale Identity-Writer
    /// können dadurch nie ein halb aktualisiertes Name/E-Mail-Paar beobachten.
    @discardableResult
    func performIdentityBarrierExclusive(repository: URL, kind: GitOperationKind,
                                         identity: String,
                                         cancellationGate: GitOperationCancellationGate? = nil,
                                         starter: @escaping Starter,
                                         completion: @escaping (GitExecutionOutcome) -> Void)
        -> GitOperationLease {
        performExclusive(
            repository: GitIdentityLock.globalRepositoryKey,
            kind: .workingTreeMutation,
            identity: "identity-barrier|\(GitOperationRequest.canonicalRepositoryPath(repository))|\(identity)",
            starter: { [weak self] releaseBarrier in
                guard let self else {
                    releaseBarrier(.cancelled)
                    return GitOperationLease {}
                }
                let innerLease = self.performExclusive(
                    repository: repository, kind: kind, identity: identity,
                    starter: starter, completion: releaseBarrier
                )
                if let cancellationGate {
                    return GitGatedCancellation(token: innerLease,
                                                gate: cancellationGate)
                }
                return innerLease
            },
            completion: completion
        )
    }

    var commandExecutor: GitCommandExecuting { executor }

    func state(for repository: URL) -> GitOperationsState {
        let key = coordinationKey(for: repository)
        lock.lock(); defer { lock.unlock() }
        guard let queue = queues[key], let first = queue.first else { return .idle }
        return GitOperationsState(active: first.kind,
                                  queued: queue.dropFirst().map(\.kind))
    }

    private func enqueue(repository: URL, kind: GitOperationKind, identity: String,
                         completion: @escaping (GitExecutionOutcome) -> Void,
                         starter: @escaping Starter) -> GitOperationLease {
        let key = coordinationKey(for: repository)
        let subscriberID = UUID()
        lock.lock()
        var queue = queues[key] ?? []
        let mayDeduplicate = kind == .fetch || kind == .refresh
        let pending: Pending
        if mayDeduplicate,
           let existing = queue.first(where: {
               $0.kind == kind && $0.identity == identity
           }) {
            pending = existing
            pending.subscribers[subscriberID] = completion
        } else {
            pending = Pending(repository: repository, kind: kind, identity: identity,
                              subscriberID: subscriberID, completion: completion,
                              starter: starter)
            queue.append(pending)
            queues[key] = queue
        }
        let shouldStart = queue.first === pending && !pending.hasStarted
        if shouldStart { pending.hasStarted = true }
        lock.unlock()

        if shouldStart { start(pending, repositoryKey: key) }
        return GitOperationLease { [weak self, weak pending] in
            guard let pending else { return }
            self?.cancelSubscriber(subscriberID, pending: pending,
                                   repositoryKey: key)
        }
    }

    private func start(_ pending: Pending, repositoryKey: String) {
        let token = pending.starter { [weak self, weak pending] outcome in
            guard let pending else { return }
            self?.finish(pending, repositoryKey: repositoryKey, outcome: outcome)
        }
        lock.lock()
        pending.activeToken = token
        let abandoned = pending.subscribers.isEmpty
        lock.unlock()
        if abandoned { token.cancel() }
    }

    private func cancelSubscriber(_ subscriberID: UUID, pending: Pending,
                                  repositoryKey: String) {
        lock.lock()
        guard var queue = queues[repositoryKey],
              let index = queue.firstIndex(where: { $0 === pending }),
              let completion = pending.subscribers.removeValue(forKey: subscriberID)
        else { lock.unlock(); return }

        let hasSubscribers = !pending.subscribers.isEmpty
        let isActive = index == 0
        let token = pending.activeToken
        if !hasSubscribers && !isActive {
            queue.remove(at: index)
            queues[repositoryKey] = queue
        } else if !hasSubscribers && isActive && token == nil {
            // `start` läuft außerhalb des Locks; es sieht anschließend den
            // leeren Subscriber-Satz und storniert den gerade erzeugten Token.
        }
        if queue.isEmpty { queues.removeValue(forKey: repositoryKey) }
        lock.unlock()

        completion(.cancelled)
        if !hasSubscribers && isActive { token?.cancel() }
    }

    private func finish(_ pending: Pending, repositoryKey: String,
                        outcome: GitExecutionOutcome) {
        lock.lock()
        var queue = queues[repositoryKey] ?? []
        guard queue.first === pending else { lock.unlock(); return }
        queue.removeFirst()
        if queue.isEmpty { queues.removeValue(forKey: repositoryKey) }
        else { queues[repositoryKey] = queue }
        let next = queue.first
        next?.hasStarted = true
        let completions = Array(pending.subscribers.values)
        pending.subscribers.removeAll()
        lock.unlock()

        completions.forEach { $0(outcome) }
        if let next { start(next, repositoryKey: repositoryKey) }
    }
}

struct GitFetchSnapshot: Equatable {
    var lastAttempt: Date?
    var lastSuccess: Date?
    var error: String?
    var isBusy: Bool

    static let none = GitFetchSnapshot(lastAttempt: nil, lastSuccess: nil,
                                       error: nil, isBusy: false)
}

struct GitRepositorySnapshot: Equatable {
    let repositoryPath: String
    let status: GitStatusSummary?
    let upstream: String?
    let headOID: String?
    let branches: [GitBranch]
    let graph: [GitCommit]
    let operation: GitOperationState?
    let fetch: GitFetchSnapshot
    let operations: GitOperationsState
    let revision: UInt64
}

enum GitRefreshScope: String {
    case status
    case full
}

final class GitRepositoryObservation: GitCancelling {
    private let cancellation: () -> Void
    private var active = true
    private let lock = NSLock()

    init(_ cancellation: @escaping () -> Void) { self.cancellation = cancellation }

    func cancel() {
        lock.lock()
        guard active else { lock.unlock(); return }
        active = false
        lock.unlock()
        cancellation()
    }

    deinit { cancel() }
}

/// Appweite Snapshot-Quelle. Ein Repository besitzt genau eine Revision und
/// beliebig viele Fenster-Beobachter. Status-Refresh ist leichtgewichtig;
/// Branches und der teure Graph werden nur bei `.full` neu geladen.
final class GitRepositoryStore {
    static let shared = GitRepositoryStore(executor: GitRunnerExecutor(),
                                           coordinator: .shared)

    private final class Batch {
        let scope: GitRefreshScope
        var fullRequestedAfterStatus = false
        var lease: GitOperationLease?
        var consistencyAttempt = 0
        init(scope: GitRefreshScope) { self.scope = scope }
    }

    private final class Aggregate {
        let lock = NSLock()
        var remaining: Int
        var status: GitExecutionOutcome?
        var operation: GitExecutionOutcome?
        var branches: GitExecutionOutcome?
        var graph: GitExecutionOutcome?
        init(remaining: Int) { self.remaining = remaining }
    }

    private let executor: GitCommandExecuting
    let coordinator: GitOperationsCoordinator
    private let lock = NSLock()
    private var snapshots: [String: GitRepositorySnapshot] = [:]
    private var observers: [String: [UUID: (GitRepositorySnapshot) -> Void]] = [:]
    private var batches: [String: Batch] = [:]

    init(executor: GitCommandExecuting, coordinator: GitOperationsCoordinator) {
        self.executor = executor
        self.coordinator = coordinator
    }

    func observe(repository: URL,
                 completion: @escaping (GitRepositorySnapshot) -> Void)
        -> GitRepositoryObservation {
        let path = GitOperationRequest.canonicalRepositoryPath(repository)
        let id = UUID()
        lock.lock()
        observers[path, default: [:]][id] = completion
        let current = snapshots[path]
        lock.unlock()
        if let current { DispatchQueue.main.async { completion(current) } }
        return GitRepositoryObservation { [weak self] in
            self?.removeObserver(id, path: path)
        }
    }

    func refresh(repository: URL, scope: GitRefreshScope) {
        let path = GitOperationRequest.canonicalRepositoryPath(repository)
        lock.lock()
        if let batch = batches[path] {
            if batch.scope == .status && scope == .full {
                batch.fullRequestedAfterStatus = true
            }
            lock.unlock()
            return
        }
        batches[path] = Batch(scope: scope)
        lock.unlock()
        startBatch(repository: repository, path: path, scope: scope, attempt: 0)
    }

    func snapshot(for repository: URL) -> GitRepositorySnapshot? {
        let path = GitOperationRequest.canonicalRepositoryPath(repository)
        lock.lock(); defer { lock.unlock() }
        return snapshots[path]
    }

    func publishOperations(for repository: URL) {
        let path = GitOperationRequest.canonicalRepositoryPath(repository)
        lock.lock()
        guard let previous = snapshots[path] else { lock.unlock(); return }
        let snapshot = GitRepositorySnapshot(
            repositoryPath: path, status: previous.status,
            upstream: previous.upstream, headOID: previous.headOID,
            branches: previous.branches, graph: previous.graph,
            operation: previous.operation,
            fetch: previous.fetch, operations: coordinator.state(for: repository),
            revision: previous.revision + 1
        )
        snapshots[path] = snapshot
        let callbacks = Array(observers[path, default: [:]].values)
        lock.unlock()
        DispatchQueue.main.async { callbacks.forEach { $0(snapshot) } }
    }

    /// Fetch aktualisiert nur Remote-Tracking-Refs. Versuch, Erfolg, Fehler und
    /// Busy-Zustand werden appweit publiziert; danach liest ein Full-Refresh
    /// Status, Branches und Graph für alle Fenster konsistent neu ein.
    @discardableResult
    func fetch(repository: URL, preferences: GitPreferences, remotes: [String],
               attemptDate: Date = Date()) -> GitOperationLease? {
        let path = GitOperationRequest.canonicalRepositoryPath(repository)
        lock.lock()
        let previous = snapshots[path]
        if previous?.fetch.isBusy == true { lock.unlock(); return nil }
        let upstream = previous?.upstream
        var reservedFetch = previous?.fetch ?? .none
        reservedFetch.lastAttempt = attemptDate
        reservedFetch.error = nil
        reservedFetch.isBusy = true
        let reserved = GitRepositorySnapshot(
            repositoryPath: path, status: previous?.status,
            upstream: previous?.upstream, headOID: previous?.headOID,
            branches: previous?.branches ?? [], graph: previous?.graph ?? [],
            operation: previous?.operation,
            fetch: reservedFetch, operations: coordinator.state(for: repository),
            revision: (previous?.revision ?? 0) + 1
        )
        snapshots[path] = reserved
        let reserveCallbacks = Array(observers[path, default: [:]].values)
        lock.unlock()
        DispatchQueue.main.async { reserveCallbacks.forEach { $0(reserved) } }

        let arguments = GitFetchPlan.arguments(preferences: preferences,
                                               upstream: upstream,
                                               remotes: remotes)
        let request = GitOperationRequest(repository: repository, kind: .fetch,
                                          arguments: arguments)
        return coordinator.perform(request) { [weak self] outcome in
            guard let self else { return }
            let error: String?
            let succeeded: Bool
            switch outcome {
            case .completed(let result):
                succeeded = result.ok
                error = result.ok ? nil : [result.stderrForDisplay, result.stdoutForDisplay]
                    .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    ?? L10n.format("git fetch schlug ohne Meldung fehl (Exit-Code %ld).",
                                   Int(result.exitCode))
            default:
                succeeded = false
                error = Workspace.gitExecutionFailureText(outcome)
            }
            self.updateFetch(repository: repository) {
                $0.isBusy = false
                $0.error = error
                if succeeded { $0.lastSuccess = Date() }
            }
            if outcome != .cancelled {
                self.refresh(repository: repository, scope: .full)
            }
        }
    }

    private func updateFetch(repository: URL,
                             mutate: (inout GitFetchSnapshot) -> Void) {
        let path = GitOperationRequest.canonicalRepositoryPath(repository)
        lock.lock()
        let previous = snapshots[path]
        var fetch = previous?.fetch ?? .none
        mutate(&fetch)
        let revision = (previous?.revision ?? 0) + 1
        let snapshot = GitRepositorySnapshot(
            repositoryPath: path,
            status: previous?.status,
            upstream: previous?.upstream,
            headOID: previous?.headOID,
            branches: previous?.branches ?? [],
            graph: previous?.graph ?? [],
            operation: previous?.operation,
            fetch: fetch,
            operations: coordinator.state(for: repository),
            revision: revision
        )
        snapshots[path] = snapshot
        let callbacks = Array(observers[path, default: [:]].values)
        lock.unlock()
        DispatchQueue.main.async { callbacks.forEach { $0(snapshot) } }
    }

    private func startBatch(repository: URL, path: String, scope: GitRefreshScope,
                            attempt: Int) {
        let aggregate = Aggregate(remaining: scope == .status ? 2 : 4)
        let lease = coordinator.performBatch(repository: repository,
                                              identity: "repository-store-\(path)-\(scope.rawValue)-\(attempt)") {
            [executor] finish in
            let composite = GitCompositeCancellation()
            func record(_ keyPath: ReferenceWritableKeyPath<Aggregate, GitExecutionOutcome?>,
                        _ outcome: GitExecutionOutcome) {
                aggregate.lock.lock()
                aggregate[keyPath: keyPath] = outcome
                aggregate.remaining -= 1
                let done = aggregate.remaining == 0
                aggregate.lock.unlock()
                if done { finish(.completed(.emptySuccess)) }
            }
            composite.add(executor.execute(arguments: GitStatusParser.arguments,
                                           in: repository, outputLimit: .default,
                                           policy: .default) { record(\.status, $0) })
            composite.add(executor.execute(
                arguments: GitOperationStateDetector.arguments,
                in: repository, outputLimit: .default,
                policy: .default
            ) { record(\.operation, $0) })
            if scope == .full {
                composite.add(executor.execute(arguments: GitBranchList.arguments,
                                               in: repository, outputLimit: .default,
                                               policy: .default) { record(\.branches, $0) })
                composite.add(executor.execute(arguments: GitGraph.arguments,
                                               in: repository, outputLimit: .default,
                                               policy: .default) { record(\.graph, $0) })
            }
            return composite
        } completion: { [weak self] outcome in
            self?.completeBatch(repository: repository, path: path, scope: scope,
                                aggregate: aggregate, coordinatorOutcome: outcome,
                                attempt: attempt)
        }
        lock.lock()
        if let batch = batches[path] {
            batch.lease = lease
            batch.consistencyAttempt = attempt
            lock.unlock()
        } else {
            lock.unlock()
            lease.cancel()
        }
    }

    private func completeBatch(repository: URL, path: String, scope: GitRefreshScope,
                               aggregate: Aggregate,
                               coordinatorOutcome: GitExecutionOutcome,
                               attempt: Int) {
        guard case .completed = coordinatorOutcome else {
            finishBatch(repository: repository, path: path, publish: nil)
            return
        }
        lock.lock()
        let previous = snapshots[path]
        let revision = (previous?.revision ?? 0) + 1
        lock.unlock()

        let statusResult = aggregate.status?.usableResult
        let operationResult = aggregate.operation?.usableResult
        let branchResult = aggregate.branches?.usableResult
        let graphResult = aggregate.graph?.usableResult
        let status = statusResult.map { GitStatusParser.parse($0.stdoutData) }
            ?? (aggregate.status?.isCompletedGitFailure == true
                ? nil : previous?.status)
        let branches = scope == .full
            ? branchResult.map { GitBranchList.parse($0.stdout) }
                ?? (aggregate.branches?.isCompletedGitFailure == true
                    ? [] : previous?.branches ?? [])
            : previous?.branches ?? []
        let graph = scope == .full
            ? graphResult.map { GitGraph.parse($0.stdoutData) }
                ?? (aggregate.graph?.isCompletedGitFailure == true
                    ? [] : previous?.graph ?? [])
            : previous?.graph ?? []
        let operation = operationResult.map {
            GitOperationStateDetector.detect(stdout: $0.stdout,
                                             repository: repository)
        } ?? (aggregate.operation?.isCompletedGitFailure == true
              ? nil : previous?.operation)

        // Status und Graph dürfen nie verschiedene Checkout-Zeitpunkte
        // repräsentieren. Bei einem externen Checkout/Commit lesen wir den
        // vollständigen Batch begrenzt erneut. Nach drei Versuchen behalten wir
        // den letzten verifizierten Snapshot, statt inkonsistent zu publizieren.
        let headIsRepresented = status?.headOID == nil
            || graph.contains(where: { $0.hash == status?.headOID })
        if !headIsRepresented {
            if scope == .status {
                lock.lock()
                batches[path]?.fullRequestedAfterStatus = true
                lock.unlock()
                finishBatch(repository: repository, path: path, publish: nil)
            } else if attempt < 2 {
                startBatch(repository: repository, path: path, scope: .full,
                           attempt: attempt + 1)
            } else {
                finishBatch(repository: repository, path: path, publish: nil)
            }
            return
        }

        let snapshot = GitRepositorySnapshot(
            repositoryPath: path,
            status: status,
            upstream: status?.upstream,
            headOID: status?.headOID,
            branches: branches,
            graph: graph,
            operation: operation,
            fetch: previous?.fetch ?? .none,
            operations: coordinator.state(for: repository),
            revision: revision
        )
        finishBatch(repository: repository, path: path, publish: snapshot)
    }

    private func finishBatch(repository: URL, path: String,
                             publish snapshot: GitRepositorySnapshot?) {
        lock.lock()
        let requestFull = batches[path]?.fullRequestedAfterStatus == true
        batches.removeValue(forKey: path)
        if let snapshot { snapshots[path] = snapshot }
        let callbacks = snapshot == nil ? [] : Array(observers[path, default: [:]].values)
        lock.unlock()

        if let snapshot {
            DispatchQueue.main.async { callbacks.forEach { $0(snapshot) } }
        }
        if requestFull { refresh(repository: repository, scope: .full) }
    }

    private func removeObserver(_ id: UUID, path: String) {
        lock.lock()
        observers[path]?.removeValue(forKey: id)
        let becameEmpty = observers[path]?.isEmpty == true
        if becameEmpty { observers.removeValue(forKey: path) }
        let lease = becameEmpty ? batches[path]?.lease : nil
        lock.unlock()
        // Cancel außerhalb des Store-Locks: der Coordinator darf den
        // Completion-Pfad synchron zurückrufen.
        lease?.cancel()
    }
}

private extension GitResult {
    static let emptySuccess = GitResult(exitCode: 0, stdoutData: Data(),
                                        stderrData: Data())
}

private extension GitExecutionOutcome {
    var usableResult: GitResult? {
        guard case .completed(let result) = self, result.ok,
              !result.stdoutWasTruncated else { return nil }
        return result
    }

    /// Ein echter Git-Fehler (Prozess lief und meldete Exit != 0) darf einen
    /// bisherigen Repo-Zustand leeren. Timeout, Abbruch, Capture-Fehler oder
    /// gekürzte Ausgabe sind dagegen kein Beleg für einen leeren Zustand.
    var isCompletedGitFailure: Bool {
        guard case .completed(let result) = self else { return false }
        return !result.ok
    }
}
