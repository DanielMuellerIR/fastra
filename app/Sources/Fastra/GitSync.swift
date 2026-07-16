import AppKit
import Foundation

// MARK: - Gemeinsame Repository-Identität

protocol GitRepositoryIdentityResolving: AnyObject {
    @discardableResult
    func resolve(_ repository: URL,
                 completion: @escaping (GitRepositoryIdentity) -> Void) -> GitCancelling
}

struct GitRepositoryIdentity: Equatable {
    let worktreeRoot: URL
    let commonDirectory: URL?

    var coordinationKey: String {
        GitOperationRequest.canonicalRepositoryPath(commonDirectory ?? worktreeRoot)
    }
}

/// `--git-common-dir` ist auch bei verlinkten Worktrees korrekt. Bis Git eine
/// verifizierte Antwort liefert, bleibt der kanonische Projektpfad der ehrliche
/// konservative Fallback; ein Fehler wird nicht als gemeinsames Repo geraten.
final class GitRepositoryIdentityResolver: GitRepositoryIdentityResolving {
    private struct CacheEntry {
        let identity: GitRepositoryIdentity
        let rootFingerprint: String
        let commonFingerprint: String
    }
    private let executor: GitCommandExecuting
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]

    init(executor: GitCommandExecuting = GitRunnerExecutor()) {
        self.executor = executor
    }

    @discardableResult
    func resolve(_ repository: URL,
                 completion: @escaping (GitRepositoryIdentity) -> Void) -> GitCancelling {
        let root = repository.standardizedFileURL.resolvingSymlinksInPath()
        let key = GitOperationRequest.canonicalRepositoryPath(root)
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached, let common = cached.identity.commonDirectory,
           cached.rootFingerprint == fingerprint(root.appendingPathComponent(".git")),
           cached.commonFingerprint == fingerprint(common),
           isPlausibleCommonDirectory(common) {
            completion(cached.identity)
            return GitOperationLease { }
        }
        return executor.execute(
            arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            in: root, outputLimit: GitOutputLimit(stdoutBytes: 16 * 1024,
                                                  stderrBytes: 16 * 1024),
            policy: .default
        ) { [weak self] outcome in
            let common: URL?
            if case .completed(let result) = outcome, result.ok,
               let decoded = String(data: result.stdoutData, encoding: .utf8) {
                // Genau eine optionale abschließende LF-Zeile akzeptieren.
                // Weitere Zeilen, CR und NUL sind kein plausibles rev-parse-
                // Ergebnis und dürfen nie als Cache-Identität dienen.
                let line = decoded.hasSuffix("\n") ? String(decoded.dropLast()) : decoded
                let hasEmbeddedSeparator = line.contains("\n") || line.contains("\r")
                    || line.contains("\0") || decoded.hasSuffix("\n\n")
                let candidate = URL(fileURLWithPath: line).standardizedFileURL
                    .resolvingSymlinksInPath()
                common = !line.isEmpty && line.hasPrefix("/") && !hasEmbeddedSeparator
                    && self?.isPlausibleCommonDirectory(candidate) == true ? candidate : nil
            } else {
                common = nil
            }
            let identity = GitRepositoryIdentity(worktreeRoot: root,
                                                 commonDirectory: common)
            if let self, let common,
               let rootFingerprint = self.fingerprint(root.appendingPathComponent(".git")),
               let commonFingerprint = self.fingerprint(common) {
                self.lock.lock()
                self.cache[key] = CacheEntry(identity: identity,
                                             rootFingerprint: rootFingerprint,
                                             commonFingerprint: commonFingerprint)
                self.lock.unlock()
            }
            completion(identity)
        }
    }

    private func isPlausibleCommonDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.fileExists(atPath: url.appendingPathComponent("HEAD").path)
    }

    private func fingerprint(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [
            .fileResourceIdentifierKey, .contentModificationDateKey, .fileSizeKey
        ]) else { return nil }
        return "\(String(describing: values.fileResourceIdentifier))|"
            + "\(values.contentModificationDate?.timeIntervalSince1970 ?? -1)|"
            + "\(values.fileSize ?? -1)"
    }
}

// MARK: - Fetch-Plan und Erstentscheidung

enum GitFetchPlan {
    static func arguments(preferences: GitPreferences, upstream: String?,
                          remotes: [String]) -> [String] {
        var arguments = ["fetch"]
        if preferences.prune { arguments.append("--prune") }
        switch preferences.remoteScope {
        case .all:
            arguments.append("--all")
        case .relevant:
            if let remote = relevantRemote(upstream: upstream, remotes: remotes) {
                arguments.append(remote)
            }
        }
        return arguments
    }

    static func relevantRemote(upstream: String?, remotes: [String]) -> String? {
        if let upstream, let slash = upstream.firstIndex(of: "/") {
            let candidate = String(upstream[..<slash])
            if remotes.isEmpty || remotes.contains(candidate) { return candidate }
        }
        if remotes.contains("origin") { return "origin" }
        return remotes.sorted().first
    }
}

enum GitFetchPromptChoice: Equatable {
    case automatic
    case disabled
    case later
}

enum GitFetchPromptPolicy {
    static let deferral: TimeInterval = 24 * 60 * 60

    static func shouldPrompt(decision: GitAutomaticFetchDecision,
                             hasRemote: Bool, now: Date,
                             deferredUntil: Date?) -> Bool {
        decision == .ask && hasRemote && (deferredUntil.map { now >= $0 } ?? true)
    }
}

// MARK: - Laufende Git-Operation

enum GitOperationState: String, Equatable, CaseIterable {
    case merge
    case rebase
    case cherryPick
    case revert
    case bisect
}

enum GitRebaseBackend: Equatable {
    case merge
    case apply
}

enum GitOperationStateDetector {
    static let markers: [(GitOperationState, String)] = [
        (.merge, "MERGE_HEAD"),
        (.rebase, "rebase-merge"),
        (.rebase, "rebase-apply"),
        (.cherryPick, "CHERRY_PICK_HEAD"),
        (.revert, "REVERT_HEAD"),
        (.bisect, "BISECT_LOG")
    ]

    static var arguments: [String] {
        ["rev-parse", "--path-format=absolute"]
            + markers.flatMap { ["--git-path", $0.1] }
    }

    static func detect(stdout: String, repository: URL,
                       fileManager: FileManager = .default) -> GitOperationState? {
        let paths = stdout.split(whereSeparator: \.isNewline).map(String.init)
        for (index, marker) in markers.enumerated() where index < paths.count {
            let url = URL(fileURLWithPath: paths[index], relativeTo: repository)
                .standardizedFileURL
            if fileManager.fileExists(atPath: url.path) { return marker.0 }
        }
        return nil
    }

    static func rebaseBackend(stdout: String, repository: URL,
                              fileManager: FileManager = .default) -> GitRebaseBackend? {
        let paths = stdout.split(whereSeparator: \.isNewline).map(String.init)
        for (index, marker) in markers.enumerated()
            where marker.0 == .rebase && index < paths.count {
            let url = URL(fileURLWithPath: paths[index], relativeTo: repository)
                .standardizedFileURL
            guard fileManager.fileExists(atPath: url.path) else { continue }
            return marker.1 == "rebase-apply" ? .apply : .merge
        }
        return nil
    }
}

enum GitPullPreflightResult: Equatable {
    case ready(hasLocalChanges: Bool)
    case noUpstream
    case unmerged
    case operationInProgress(GitOperationState)
    case missingIdentity
}

enum GitPullPreflight {
    static func evaluate(status: GitStatusSummary,
                         operation: GitOperationState?) -> GitPullPreflightResult {
        if let operation { return .operationInProgress(operation) }
        if status.changes.contains(where: {
            $0.staged == .conflicted || $0.unstaged == .conflicted
        }) { return .unmerged }
        guard status.upstream != nil else { return .noUpstream }
        return .ready(hasLocalChanges: !status.changes.isEmpty)
    }

    static func arguments(strategy: GitPullStrategy) -> [String]? {
        switch strategy {
        case .unselected: return nil
        case .rebase: return ["pull", "--rebase", "--no-autostash"]
        case .merge: return ["pull", "--no-rebase", "--no-autostash", "--ff"]
        case .ffOnly: return ["pull", "--ff-only", "--no-autostash"]
        }
    }
}

enum GitSafePullOutcome: Equatable {
    case pulled(GitExecutionOutcome)
    case blocked(GitPullPreflightResult)
    case repositoryChanged
    case cancelled
    case inspectionFailed(GitExecutionOutcome)
}

private final class GitSafePullOutcomeBox {
    private let lock = NSLock()
    private var value: GitSafePullOutcome?
    func set(_ newValue: GitSafePullOutcome) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> GitSafePullOutcome? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class GitSerialCancellation: GitCancelling {
    private let lock = NSLock()
    private var tokens: [GitCancelling] = []
    private var cancelled = false
    func add(_ token: GitCancelling) {
        lock.lock()
        if cancelled { lock.unlock(); token.cancel(); return }
        tokens.append(token); lock.unlock()
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

/// Status, Operation-Marker, Nutzerbestätigung, erneute Validierung und Pull
/// bleiben in genau einem Coordinator-Slot. Damit kann keine von Fastra
/// gestartete Mutation zwischen Sicherheitsprüfung und Pull gelangen.
enum GitSafePullRunner {
    @discardableResult
    static func run(repository: URL, strategy: GitPullStrategy,
                    coordinator: GitOperationsCoordinator,
                    decision: @escaping (GitPullPreflightResult,
                                         @escaping (Bool) -> Void) -> Void,
                    completion: @escaping (GitSafePullOutcome) -> Void)
        -> GitOperationLease? {
        guard let pullArguments = GitPullPreflight.arguments(strategy: strategy) else {
            completion(.cancelled); return nil
        }
        let box = GitSafePullOutcomeBox()
        let executor = coordinator.commandExecutor
        let identity = pullArguments.joined(separator: "\u{0}")
        let starter: GitOperationsCoordinator.Starter = { finish in
            let cancellation = GitSerialCancellation()
            inspect(repository: repository, executor: executor,
                    cancellation: cancellation) { first in
                switch first {
                case .failure(let outcome):
                    box.set(.inspectionFailed(outcome)); finish(outcome)
                case .success(let inspection):
                    let preflight = GitPullPreflight.evaluate(
                        status: inspection.status, operation: inspection.operation
                    )
                    guard case .ready = preflight else {
                        box.set(.blocked(preflight)); finish(emptyGitSuccess); return
                    }
                    DispatchQueue.main.async {
                        decision(preflight) { proceed in
                            guard proceed else {
                                box.set(.cancelled); finish(.cancelled); return
                            }
                            inspect(repository: repository, executor: executor,
                                    cancellation: cancellation) { second in
                                switch second {
                                case .failure(let outcome):
                                    box.set(.inspectionFailed(outcome)); finish(outcome)
                                case .success(let validated):
                                    let validatedPreflight = GitPullPreflight.evaluate(
                                        status: validated.status,
                                        operation: validated.operation
                                    )
                                    guard case .ready = validatedPreflight else {
                                        box.set(.blocked(validatedPreflight))
                                        finish(emptyGitSuccess); return
                                    }
                                    guard validated.status == inspection.status else {
                                        box.set(.repositoryChanged)
                                        finish(emptyGitSuccess); return
                                    }
                                    func executePull() {
                                        cancellation.add(executor.execute(
                                            arguments: pullArguments, in: repository,
                                            outputLimit: .default, policy: .default
                                        ) { outcome in
                                            box.set(.pulled(outcome)); finish(outcome)
                                        })
                                    }
                                    guard strategy != .ffOnly else {
                                        executePull(); return
                                    }
                                    // Merge und Rebase können einen Commit
                                    // erzeugen. Nur bewusst konfigurierte
                                    // lokale/globale Werte zählen; Git darf
                                    // nicht still Nutzer+Host ableiten.
                                    cancellation.add(GitConfiguredIdentityReader.read(
                                        repository: repository, executor: executor
                                    ) { identityResult in
                                        switch identityResult {
                                        case .value(nil):
                                            box.set(.blocked(.missingIdentity))
                                            finish(emptyGitSuccess)
                                        case .value:
                                            executePull()
                                        case .failure(let failure):
                                            box.set(.inspectionFailed(failure))
                                            finish(failure)
                                        }
                                    })
                                }
                            }
                        }
                    }
                }
            }
            return cancellation
        }
        let coordinatedCompletion: (GitExecutionOutcome) -> Void = { coordinatorOutcome in
            completion(box.get() ?? (coordinatorOutcome == .cancelled
                                      ? .cancelled
                                      : .inspectionFailed(coordinatorOutcome)))
        }
        if strategy != .ffOnly {
            return coordinator.performIdentityBarrierExclusive(
                repository: repository, kind: .pull, identity: identity,
                starter: starter, completion: coordinatedCompletion
            )
        }
        return coordinator.performExclusive(
            repository: repository, kind: .pull, identity: identity,
            starter: starter, completion: coordinatedCompletion
        )
    }

    private struct Inspection {
        let status: GitStatusSummary
        let operation: GitOperationState?
    }

    private enum InspectionResult {
        case success(Inspection)
        case failure(GitExecutionOutcome)
    }

    private static func inspect(repository: URL, executor: GitCommandExecuting,
                                cancellation: GitSerialCancellation,
                                completion: @escaping (InspectionResult) -> Void) {
        cancellation.add(executor.execute(arguments: GitStatusParser.arguments,
                                          in: repository, outputLimit: .default,
                                          policy: .default) { statusOutcome in
            guard case .completed(let result) = statusOutcome, result.ok,
                  !result.stdoutWasTruncated else {
                completion(.failure(statusOutcome)); return
            }
            let status = GitStatusParser.parse(result.stdoutData)
            cancellation.add(executor.execute(
                arguments: GitOperationStateDetector.arguments,
                in: repository, outputLimit: .default, policy: .default
            ) { markerOutcome in
                guard case .completed(let markerResult) = markerOutcome,
                      markerResult.ok, !markerResult.stdoutWasTruncated else {
                    completion(.failure(markerOutcome)); return
                }
                completion(.success(Inspection(
                    status: status,
                    operation: GitOperationStateDetector.detect(
                        stdout: markerResult.stdout, repository: repository
                    )
                )))
            })
        })
    }

    private static var emptyGitSuccess: GitExecutionOutcome {
        .completed(GitResult(exitCode: 0, stdoutData: Data(), stderrData: Data()))
    }
}

// MARK: - Zentraler Auto-Fetch-Scheduler

protocol GitSyncClock {
    var now: Date { get }
}

protocol GitSyncScheduling {
    func schedule(after seconds: TimeInterval,
                  action: @escaping () -> Void) -> GitCancelling
}

struct DispatchGitSyncScheduler: GitSyncScheduling {
    func schedule(after seconds: TimeInterval,
                  action: @escaping () -> Void) -> GitCancelling {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + seconds, execute: item)
        return GitOperationLease { item.cancel() }
    }
}

enum GitAutoFetchTiming {
    static func isDue(lastAttempt: Date?, now: Date, interval: Int) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= Double(interval)
    }
}

struct SystemGitSyncClock: GitSyncClock {
    var now: Date { Date() }
}

/// Eine zentrale Queue verwaltet alle beobachteten Repositories. Es gibt nur
/// einen neu geplanten Dispatch-Block; bei Inaktivität existiert kein Timer.
final class GitAutoFetchController {
    static let shared = GitAutoFetchController(store: .shared,
                                               preferences: GitPreferencesStore())

    private struct Registration {
        var count: Int
        var repository: URL
        var remotes: [String]
        var fetchLease: GitCancelling?
    }

    private let store: GitRepositoryStore
    private let preferencesStore: GitPreferencesStore
    private let executor: GitCommandExecuting
    private let clock: GitSyncClock
    private let scheduler: GitSyncScheduling
    private let queue = DispatchQueue(label: "Fastra.GitAutoFetch")
    private var registrations: [String: Registration] = [:]
    private var scheduled: GitCancelling?
    private var active = true
    private var promptInFlight = false
    private var regularFetchNotBefore: Date?

    init(store: GitRepositoryStore, preferences: GitPreferencesStore,
         clock: GitSyncClock = SystemGitSyncClock(),
         executor: GitCommandExecuting = GitRunnerExecutor(),
         scheduler: GitSyncScheduling = DispatchGitSyncScheduler()) {
        self.store = store
        self.preferencesStore = preferences
        self.clock = clock
        self.executor = executor
        self.scheduler = scheduler
    }

    /// Remote-Erkennung ist rein lokal (`git remote`) und läuft vor der
    /// Registrierung. Ein verspätetes Ergebnis kann nach Cancel kein Repo mehr
    /// an den Scheduler hängen.
    func observe(repository: URL,
                 prompt: @escaping (@escaping (GitFetchPromptChoice) -> Void) -> Void)
        -> GitRepositoryObservation {
        let state = GitDeferredRegistration()
        let token = executor.execute(arguments: ["remote"], in: repository,
                                     outputLimit: .default, policy: .default) {
            [weak self, weak state] outcome in
            guard let self, let state, !state.isCancelled else { return }
            guard case .completed(let result) = outcome, result.ok else { return }
            let remotes = result.stdout.split(whereSeparator: \.isNewline)
                .map(String.init).filter { !$0.isEmpty }
            guard !remotes.isEmpty else { return }
            let attached = self.attach(repository: repository, remotes: remotes)
            if state.installIfActive(attached) {
                self.considerPrompt(hasRemote: true, prompt: prompt)
            }
        }
        _ = state.installIfActive(token)
        return GitRepositoryObservation { state.cancel() }
    }

    func attach(repository: URL, remotes: [String]) -> GitRepositoryObservation {
        let key = GitOperationRequest.canonicalRepositoryPath(repository)
        queue.async { [weak self] in
            guard let self else { return }
            var registration = self.registrations[key]
                ?? Registration(count: 0, repository: repository, remotes: remotes,
                                fetchLease: nil)
            registration.count += 1
            registration.remotes = remotes
            self.registrations[key] = registration
            self.reschedule(runDueNow: true)
        }
        return GitRepositoryObservation { [weak self] in
            self?.queue.async {
                guard let self, var registration = self.registrations[key] else { return }
                registration.count -= 1
                if registration.count <= 0 {
                    registration.fetchLease?.cancel()
                    self.registrations.removeValue(forKey: key)
                }
                else { self.registrations[key] = registration }
                self.reschedule(runDueNow: false)
            }
        }
    }

    func setActive(_ value: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.active = value
            let preferences = self.preferencesStore.load()
            if value && !preferences.fetchOnActivation {
                self.regularFetchNotBefore = self.clock.now.addingTimeInterval(
                    Double(preferences.fetchIntervalSeconds)
                )
            } else if !value || preferences.fetchOnActivation {
                self.regularFetchNotBefore = nil
            }
            // Ein bereits laufender Fetch darf sauber enden. Inaktive Apps
            // starten aber weder einen neuen Fetch noch einen neuen Timer.
            self.reschedule(runDueNow: value && preferences.fetchOnActivation)
        }
    }

    func preferencesDidChange() {
        queue.async { [weak self] in self?.reschedule(runDueNow: false) }
    }

    private func considerPrompt(
        hasRemote: Bool,
        prompt: @escaping (@escaping (GitFetchPromptChoice) -> Void) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let preferences = self.preferencesStore.load()
            guard !self.promptInFlight,
                  GitFetchPromptPolicy.shouldPrompt(
                    decision: preferences.automaticFetchDecision,
                    hasRemote: hasRemote, now: self.clock.now,
                    deferredUntil: self.preferencesStore.promptDeferredUntil
                  ) else { return }
            self.promptInFlight = true
            DispatchQueue.main.async {
                prompt { [weak self] choice in
                    guard let self else { return }
                    self.queue.async {
                        var preferences = self.preferencesStore.load()
                        switch choice {
                        case .automatic:
                            preferences.automaticFetchDecision = .automatic
                            self.preferencesStore.clearAutomaticFetchPromptDeferral()
                        case .disabled:
                            preferences.automaticFetchDecision = .disabled
                            self.preferencesStore.clearAutomaticFetchPromptDeferral()
                        case .later:
                            self.preferencesStore.deferAutomaticFetchPrompt(from: self.clock.now)
                        }
                        if choice != .later { self.preferencesStore.save(preferences) }
                        self.promptInFlight = false
                        self.reschedule(runDueNow: choice == .automatic)
                    }
                }
            }
        }
    }

    private func reschedule(runDueNow: Bool) {
        scheduled?.cancel()
        scheduled = nil
        let preferences = preferencesStore.load()
        guard active, preferences.automaticFetchDecision == .automatic,
              !registrations.isEmpty else { return }

        let now = clock.now
        var nextDelay = Double(preferences.fetchIntervalSeconds)
        let mayRunNow = runDueNow
            && (regularFetchNotBefore.map { now >= $0 } ?? true)
        for key in Array(registrations.keys) {
            guard var registration = registrations[key] else { continue }
            let last = store.snapshot(for: registration.repository)?.fetch.lastAttempt
            let due = GitAutoFetchTiming.isDue(lastAttempt: last, now: now,
                                                interval: preferences.fetchIntervalSeconds)
            if due && mayRunNow {
                if let lease = store.fetch(
                    repository: registration.repository,
                    preferences: preferences, remotes: registration.remotes,
                    attemptDate: now
                ) { registration.fetchLease = lease }
                registrations[key] = registration
            } else if let last {
                let elapsed = max(0, now.timeIntervalSince(last))
                nextDelay = min(nextDelay,
                                max(0, Double(preferences.fetchIntervalSeconds) - elapsed))
            } else {
                nextDelay = 0
            }
        }
        if let floor = regularFetchNotBefore {
            nextDelay = max(nextDelay, max(0, floor.timeIntervalSince(now)))
        }
        scheduled = scheduler.schedule(after: nextDelay) {
            [weak self] in
            guard let self else { return }
            self.queue.async {
                let preferences = self.preferencesStore.load()
                guard self.active,
                      preferences.automaticFetchDecision == .automatic else { return }
                if let floor = self.regularFetchNotBefore,
                   self.clock.now >= floor {
                    self.regularFetchNotBefore = nil
                }
                self.reschedule(runDueNow: true)
            }
        }
    }
}

private final class GitDeferredRegistration: GitCancelling {
    private let lock = NSLock()
    private var tokens: [GitCancelling] = []
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    @discardableResult
    func installIfActive(_ token: GitCancelling) -> Bool {
        lock.lock()
        if cancelled { lock.unlock(); token.cancel(); return false }
        tokens.append(token)
        lock.unlock()
        return true
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let current = tokens
        tokens.removeAll()
        lock.unlock()
        current.forEach { $0.cancel() }
    }
}
