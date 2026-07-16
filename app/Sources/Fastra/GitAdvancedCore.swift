import Foundation

final class GitSequenceCancellation: GitCancelling {
    private let lock = NSLock()
    private var tokens: [GitCancelling] = []
    private(set) var cancelled = false

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

    func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

/// Der Identity-Writer darf vor der ersten Mutation normal abgebrochen werden.
/// Sobald jedoch der erste `git config`-Write freigegeben wurde, muss er das
/// Paar entweder vollständig verifizieren oder unabhängig zurückrollen. Ein
/// späterer UI-Abbruch entfernt nur den Interessenten, nicht diesen Cleanup.
private final class GitIdentityMutationCancellation: GitCancelling {
    private let lock = NSLock()
    private let preflight = GitSequenceCancellation()
    private let cleanup = GitSequenceCancellation()
    private var cancelled = false
    private var mutationBoundaryReached = false
    private var cleanupDeadline: DispatchWorkItem?
    private let coordinatorGate: GitOperationCancellationGate

    init(coordinatorGate: GitOperationCancellationGate) {
        self.coordinatorGate = coordinatorGate
    }

    func addPreflight(_ token: GitCancelling) { preflight.add(token) }
    func addCleanup(_ token: GitCancelling) { cleanup.add(token) }

    func cancel() {
        let decision = coordinatorGate.requestCancellation()
        guard decision != .protected else { return }
        lock.lock(); cancelled = true; lock.unlock()
        preflight.cancel()
    }

    func beginMutation(cleanupTimeout: TimeInterval = 30) -> Bool {
        guard coordinatorGate.beginProtection() else { return false }
        lock.lock()
        guard !cancelled else { lock.unlock(); return false }
        mutationBoundaryReached = true
        let item = DispatchWorkItem { [weak self] in self?.cleanup.cancel() }
        cleanupDeadline = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + max(0, cleanupTimeout), execute: item
        )
        return true
    }

    func finish() {
        lock.lock()
        cleanupDeadline?.cancel()
        cleanupDeadline = nil
        lock.unlock()
    }
}

struct GitConfiguredIdentity: Equatable {
    let name: String
    let email: String
}

enum GitConfiguredIdentityResult {
    case value(GitConfiguredIdentity?)
    case failure(GitExecutionOutcome)
}

/// Liest ausschließlich bewusst konfigurierte lokale/globale Werte. `git var`
/// ist hier absichtlich ungeeignet: Git kann daraus still Nutzername und Host
/// ableiten, obwohl der Nutzer nie eine Commit-Identität konfiguriert hat.
enum GitConfiguredIdentityReader {
    @discardableResult
    static func read(repository: URL, executor: GitCommandExecuting,
                     completion: @escaping (GitConfiguredIdentityResult) -> Void)
        -> GitCancelling {
        let cancellation = GitSequenceCancellation()
        let requests = [
            ["config", "--includes", "--local", "--get", "user.name"],
            ["config", "--includes", "--local", "--get", "user.email"],
            ["config", "--includes", "--global", "--get", "user.name"],
            ["config", "--includes", "--global", "--get", "user.email"]
        ]
        var values: [String?] = Array(repeating: nil, count: requests.count)
        func next(_ index: Int) {
            guard index < requests.count else {
                let name = values[0] ?? values[2]
                let email = values[1] ?? values[3]
                if let name, let email {
                    completion(.value(GitConfiguredIdentity(name: name, email: email)))
                } else {
                    completion(.value(nil))
                }
                return
            }
            cancellation.add(executor.execute(
                arguments: requests[index], in: repository,
                outputLimit: GitOutputLimit(stdoutBytes: 64 * 1024,
                                            stderrBytes: 64 * 1024),
                policy: .default
            ) { outcome in
                guard case .completed(let result) = outcome,
                      !result.stdoutWasTruncated else {
                    completion(.failure(outcome)); return
                }
                if result.exitCode == 1 { values[index] = nil; next(index + 1); return }
                guard result.ok, var raw = String(data: result.stdoutData, encoding: .utf8)
                else { completion(.failure(outcome)); return }
                if raw.hasSuffix("\n") { raw.removeLast() }
                values[index] = GitIdentityInput.normalized(raw)
                next(index + 1)
            })
        }
        next(0)
        return cancellation
    }
}

struct GitSafetyInspection: Equatable {
    let status: GitStatusSummary
    let operation: GitOperationState?
    let identityAvailable: Bool?
    let configuredIdentity: GitConfiguredIdentity?
    let commitMessage: String?
    let rebaseCommand: String?
    let rebaseBackend: GitRebaseBackend?

    init(status: GitStatusSummary, operation: GitOperationState?,
         identityAvailable: Bool? = nil,
         configuredIdentity: GitConfiguredIdentity? = nil,
         commitMessage: String? = nil, rebaseCommand: String? = nil,
         rebaseBackend: GitRebaseBackend? = nil) {
        self.status = status
        self.operation = operation
        self.identityAvailable = identityAvailable
        self.configuredIdentity = configuredIdentity
        self.commitMessage = commitMessage
        self.rebaseCommand = rebaseCommand
        self.rebaseBackend = rebaseBackend
    }

    var hasUnmergedChanges: Bool {
        status.changes.contains {
            $0.staged == .conflicted || $0.unstaged == .conflicted
        }
    }

    var isWorkingTreeClean: Bool { status.changes.isEmpty }
}

enum GitPreparedCommitMessage {
    static func subject(_ message: String?) -> String? {
        message?.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty && !$0.hasPrefix("#") })
    }
}

/// Statischer Katalog aller erweiterten Mutationslabels und Erfolgstexte.
/// Dadurch bleiben auch die über gemeinsame Runner gereichten Schlüssel für
/// Lokalisierungsaudit und Vollständigkeitstest sichtbar.
enum GitActionText: CaseIterable {
    case continueOperation, abortOperation, rebaseSkip, newBranch
    case stash, stashPop, cherryPick, revert, forcePushWithLease
    case conflictResolution

    var labelKey: String {
        switch self {
        case .continueOperation: "Fortsetzen"
        case .abortOperation: "Abbrechen"
        case .rebaseSkip: "Rebase-Skip"
        case .newBranch: "Neuer Branch"
        case .stash: "Stash"
        case .stashPop: "Stash Pop"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        case .forcePushWithLease: "Force Push with Lease"
        case .conflictResolution: "Konfliktauflösung"
        }
    }

    var successKey: String {
        switch self {
        case .continueOperation: "%@ fortgesetzt"
        case .abortOperation: "%@ abgebrochen"
        case .rebaseSkip: "Commit im Rebase übersprungen"
        case .newBranch: "Branch „%@“ erstellt"
        case .stash: "Änderungen im Stash gesichert"
        case .stashPop: "Letzten Stash angewendet"
        case .cherryPick: "Commit per Cherry-pick übernommen"
        case .revert: "Gegen-Commit erstellt"
        case .forcePushWithLease: "Force Push with Lease erfolgreich"
        case .conflictResolution: "Datei als gelöst markiert"
        }
    }

    func localizedSuccess(_ formatValue: String? = nil) -> String {
        if let formatValue { return L10n.format(successKey, formatValue) }
        return L10n.string(successKey)
    }
}

enum GitAdvancedArguments {
    static func createBranch(name: String, commit: String?) -> [String] {
        var arguments = ["switch", "-c", name]
        if let commit { arguments.append(commit) }
        return arguments
    }

    static func stash(includeUntracked: Bool) -> [String] {
        // Der explizite Repo-Root-Pathspec verhindert, dass `git stash` unter
        // global literalisierten Pathspecs seine intern ermittelten Untracked-
        // Dateien auslässt.
        includeUntracked ? ["stash", "push", "--include-untracked", "--", "."]
            : ["stash", "push"]
    }

    static let stashPop = ["stash", "pop"]
    static func cherryPick(_ oid: String) -> [String] { ["cherry-pick", oid] }
    static func revert(_ oid: String) -> [String] { ["revert", "--no-edit", oid] }

    static func operation(_ state: GitOperationState, action: GitOperationAction)
        -> [String]? {
        switch (state, action) {
        case (.merge, .continue): return ["merge", "--continue"]
        case (.merge, .abort): return ["merge", "--abort"]
        case (.rebase, .continue): return ["rebase", "--continue"]
        case (.rebase, .abort): return ["rebase", "--abort"]
        case (.rebase, .skip): return ["rebase", "--skip"]
        case (.cherryPick, .continue): return ["cherry-pick", "--continue"]
        case (.cherryPick, .abort): return ["cherry-pick", "--abort"]
        case (.revert, .continue): return ["revert", "--continue"]
        case (.revert, .abort): return ["revert", "--abort"]
        case (.bisect, .abort): return ["bisect", "reset"]
        default: return nil
        }
    }
}

enum GitOperationAction: Equatable {
    case `continue`
    case abort
    case skip
}

enum GitValidatedMutationOutcome: Equatable {
    case executed(GitExecutionOutcome)
    case blocked(String)
    case missingIdentity
    case repositoryChanged
    case inspectionFailed(GitExecutionOutcome)
    case cancelled
}

final class GitValidatedMutationBox {
    private let lock = NSLock()
    private var value: GitValidatedMutationOutcome?
    func set(_ newValue: GitValidatedMutationOutcome) {
        lock.lock(); value = newValue; lock.unlock()
    }
    func get() -> GitValidatedMutationOutcome? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

/// Hält Statusprüfung, Operationsmarker, Bestätigung, Revalidierung und die
/// eigentliche Mutation in einem Repository-Slot. Damit bleibt zwischen
/// sichtbarer Entscheidung und Git-Aufruf kein Fastra-internes Race-Fenster.
enum GitValidatedMutationRunner {
    typealias Validator = (GitSafetyInspection) -> String?
    typealias Decision = (GitSafetyInspection, @escaping (Bool) -> Void) -> Void
    typealias FinalCheck = (@escaping (String?) -> Void) -> Void

    @discardableResult
    static func run(repository: URL, kind: GitOperationKind,
                    identity: String, arguments: [String],
                    policy: GitExecutionPolicy = .default,
                    requiresIdentity: Bool = false,
                    readsCommitMessage: Bool = false,
                    coordinator: GitOperationsCoordinator,
                    validate: @escaping Validator,
                    decision: @escaping Decision,
                    finalCheck: @escaping FinalCheck = { $0(nil) },
                    completion: @escaping (GitValidatedMutationOutcome) -> Void)
        -> GitOperationLease {
        let box = GitValidatedMutationBox()
        let executor = coordinator.commandExecutor
        let starter: GitOperationsCoordinator.Starter = { finish in
                let cancellation = GitSequenceCancellation()
                inspect(repository: repository, executor: executor,
                        checkIdentity: requiresIdentity,
                        readCommitMessage: readsCommitMessage,
                        cancellation: cancellation) { firstResult in
                    switch firstResult {
                    case .failure(let failure):
                        box.set(.inspectionFailed(failure)); finish(failure)
                    case .success(let first):
                        if requiresIdentity, first.identityAvailable != true {
                            box.set(.missingIdentity)
                            finish(.completed(.emptySuccess)); return
                        }
                        if let reason = validate(first) {
                            box.set(.blocked(reason)); finish(.completed(.emptySuccess))
                            return
                        }
                        DispatchQueue.main.async {
                            decision(first) { proceed in
                                guard proceed, !cancellation.isCancelled() else {
                                    box.set(.cancelled); finish(.cancelled); return
                                }
                                inspect(repository: repository, executor: executor,
                                        checkIdentity: requiresIdentity,
                                        readCommitMessage: readsCommitMessage,
                                        cancellation: cancellation) { secondResult in
                                    switch secondResult {
                                    case .failure(let failure):
                                        box.set(.inspectionFailed(failure)); finish(failure)
                                    case .success(let second):
                                        if requiresIdentity, second.identityAvailable != true {
                                            box.set(.missingIdentity)
                                            finish(.completed(.emptySuccess)); return
                                        }
                                        if let reason = validate(second) {
                                            box.set(.blocked(reason))
                                            finish(.completed(.emptySuccess)); return
                                        }
                                        guard second == first else {
                                            box.set(.repositoryChanged)
                                            finish(.completed(.emptySuccess)); return
                                        }
                                        finalCheck { reason in
                                            guard !cancellation.isCancelled() else {
                                                box.set(.cancelled); finish(.cancelled); return
                                            }
                                            if let reason {
                                                box.set(.blocked(reason))
                                                finish(.completed(.emptySuccess)); return
                                            }
                                            cancellation.add(executor.execute(
                                                arguments: arguments, in: repository,
                                                outputLimit: .default, policy: policy
                                            ) { outcome in
                                                box.set(.executed(outcome)); finish(outcome)
                                            })
                                        }
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
        if requiresIdentity {
            return coordinator.performIdentityBarrierExclusive(
                repository: repository, kind: kind, identity: identity,
                starter: starter, completion: coordinatedCompletion
            )
        }
        return coordinator.performExclusive(
            repository: repository, kind: kind, identity: identity,
            starter: starter, completion: coordinatedCompletion
        )
    }

    enum InspectionResult {
        case success(GitSafetyInspection)
        case failure(GitExecutionOutcome)
    }

    static func inspect(repository: URL, executor: GitCommandExecuting,
                                checkIdentity: Bool = false,
                                readCommitMessage: Bool = false,
                                cancellation: GitSequenceCancellation,
                                argumentPrefix: [String] = [],
                                completion: @escaping (InspectionResult) -> Void) {
        func arguments(_ values: [String]) -> [String] {
            guard !argumentPrefix.isEmpty,
                  !values.starts(with: argumentPrefix) else { return values }
            return argumentPrefix + values
        }
        cancellation.add(executor.execute(
            arguments: arguments(GitStatusParser.arguments), in: repository,
            outputLimit: .default, policy: .default
        ) { statusOutcome in
            guard case .completed(let result) = statusOutcome, result.ok,
                  !result.stdoutWasTruncated else {
                completion(.failure(statusOutcome)); return
            }
            let status = GitStatusParser.parse(result.stdoutData)
            cancellation.add(executor.execute(
                arguments: arguments(GitOperationStateDetector.arguments),
                in: repository,
                outputLimit: .default, policy: .default
            ) { operationOutcome in
                guard case .completed(let operationResult) = operationOutcome,
                      operationResult.ok, !operationResult.stdoutWasTruncated else {
                    completion(.failure(operationOutcome)); return
                }
                let operation = GitOperationStateDetector.detect(
                    stdout: operationResult.stdout, repository: repository)
                let rebaseBackend = GitOperationStateDetector.rebaseBackend(
                    stdout: operationResult.stdout, repository: repository)
                func finishInspection(configuredIdentity: GitConfiguredIdentity?) {
                    guard readCommitMessage else {
                        completion(.success(GitSafetyInspection(
                            status: status, operation: operation,
                            identityAvailable: checkIdentity
                                ? configuredIdentity != nil : nil,
                            configuredIdentity: configuredIdentity)))
                        return
                    }
                    func readGitFile(_ gitPath: String,
                                     done: @escaping (String?, GitExecutionOutcome?) -> Void) {
                        cancellation.add(executor.execute(
                            arguments: arguments([
                                "rev-parse", "--path-format=absolute", "--git-path", gitPath
                            ]),
                            in: repository, outputLimit: GitOutputLimit(
                                stdoutBytes: 64 * 1024, stderrBytes: 64 * 1024),
                            policy: .default
                        ) { pathOutcome in
                            let partialResult: GitResult
                            if case .completed(let value) = pathOutcome {
                                partialResult = value
                            } else {
                                partialResult = .emptySuccess
                            }
                            guard case .completed(let pathResult) = pathOutcome,
                                  pathResult.ok, !pathResult.stdoutWasTruncated,
                                  let path = exactSingleLine(pathResult.stdoutData) else {
                                let failure = GitExecutionOutcome.captureFailed(
                                    GitCaptureFailure(
                                        stdoutError: L10n.string("Git lieferte keinen eindeutigen Pfad für die vorbereiteten Rebase-Daten. Setze den Vorgang im Terminal fort."),
                                        stderrError: nil,
                                        partialResult: partialResult))
                                done(nil, failure); return
                            }
                            DispatchQueue.global(qos: .userInitiated).async {
                                do {
                                    let url = URL(fileURLWithPath: path)
                                    let values = try url.resourceValues(forKeys: [.fileSizeKey])
                                    guard (values.fileSize ?? 0) <= 1024 * 1024 else {
                                        done(nil, .captureFailed(GitCaptureFailure(
                                            stdoutError: L10n.string("Die vorbereiteten Git-Daten sind unerwartet groß. Setze den Vorgang im Terminal fort."),
                                            stderrError: nil, partialResult: .emptySuccess)))
                                        return
                                    }
                                    let data = try Data(contentsOf: url)
                                    guard let text = String(data: data, encoding: .utf8) else {
                                        done(nil, .captureFailed(GitCaptureFailure(
                                            stdoutError: L10n.string("Die vorbereiteten Git-Daten sind kein gültiges UTF-8. Setze den Vorgang im Terminal fort."),
                                            stderrError: nil, partialResult: .emptySuccess)))
                                        return
                                    }
                                    done(text, nil)
                                } catch {
                                    done(nil, .captureFailed(GitCaptureFailure(
                                        stdoutError: L10n.format("Die vorbereiteten Git-Daten konnten nicht gelesen werden: %@", error.localizedDescription),
                                        stderrError: nil, partialResult: .emptySuccess)))
                                }
                            }
                        })
                    }
                    func readMessage(rebaseCommand: String?) {
                        let messagePath = rebaseBackend == .apply
                            ? "rebase-apply/final-commit" : "MERGE_MSG"
                        readGitFile(messagePath) { message, failure in
                            if let failure { completion(.failure(failure)); return }
                            completion(.success(GitSafetyInspection(
                                status: status, operation: operation,
                                identityAvailable: checkIdentity
                                    ? configuredIdentity != nil : nil,
                                configuredIdentity: configuredIdentity,
                                commitMessage: message,
                                rebaseCommand: rebaseCommand,
                                rebaseBackend: rebaseBackend)))
                        }
                    }
                    guard operation == .rebase else { readMessage(rebaseCommand: nil); return }
                    if rebaseBackend == .apply {
                        // Der Apply-Backend kennt keine interaktive Todo-Liste. Sein
                        // aktueller Schritt ist daher immer ein normaler Pick.
                        readMessage(rebaseCommand: "pick")
                        return
                    }
                    readGitFile("rebase-merge/done") { doneText, failure in
                        if let failure { completion(.failure(failure)); return }
                        let command = doneText?.split(whereSeparator: \.isNewline)
                            .map(String.init)
                            .last(where: {
                                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
                            })?
                            .split(whereSeparator: \.isWhitespace).first.map(String.init)
                            .map { $0 == "p" ? "pick" : $0.lowercased() }
                        readMessage(rebaseCommand: command)
                    }
                }
                guard checkIdentity else { finishInspection(configuredIdentity: nil); return }
                cancellation.add(GitConfiguredIdentityReader.read(
                    repository: repository, executor: executor
                ) { identityResult in
                    switch identityResult {
                    case .value(let identity):
                        finishInspection(configuredIdentity: identity)
                    case .failure(let failure):
                        completion(.failure(failure))
                    }
                })
            })
        })
    }

    private static func exactSingleLine(_ data: Data) -> String? {
        guard var value = String(data: data, encoding: .utf8), !value.contains("\0") else {
            return nil
        }
        if value.hasSuffix("\n") { value.removeLast() }
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r"),
              value.hasPrefix("/") else { return nil }
        return value
    }
}

struct GitConflictStageInspection: Equatable {
    let safety: GitSafetyInspection
    let markerSize: Int
    let indexMode: String
    let indexPath: String
    let headRef: String
    let headOID: String
    let headRefPath: String
    let headRefNeedsNoDeref: Bool
    let worktreeHeadPath: String
    let headSymbolicTarget: String?
    let indexRecords: Data
    let attributes: Data
    let conversionConfig: Data
}

/// Staged exakt die zuvor geprüften Editorbytes. Der Arbeitsbaum wird bewusst
/// nicht noch einmal von `git add` gelesen: `hash-object --path --stdin` schreibt
/// den pfadspezifisch konvertierten Blob. Erst unter Git-eigenem Index- und
/// HEAD-Ref-Lock setzt ein einzelner `update-index --index-info`-Record Stage 0.
enum GitConflictStagingRunner {
    typealias Validator = (GitSafetyInspection) -> String?
    typealias Decision = (Int, Bool, @escaping (Bool) -> Void) -> Void

    @discardableResult
    static func run(repository: URL, rawPath: Data, path: String, fileURL: URL,
                    expectedData: Data, expectedText: String,
                    coordinator: GitOperationsCoordinator,
                    validate: @escaping Validator,
                    decision: @escaping Decision,
                    completion: @escaping (GitValidatedMutationOutcome) -> Void)
        -> GitOperationLease {
        let box = GitValidatedMutationBox()
        let executor = coordinator.commandExecutor
        return coordinator.performExclusive(
            repository: repository, kind: .workingTreeMutation,
            identity: "resolve-conflict-index-\(rawPath.base64EncodedString())",
            starter: { finish in
                let cancellation = GitSequenceCancellation()

                func stop(_ outcome: GitValidatedMutationOutcome,
                          coordinatorOutcome: GitExecutionOutcome = .completed(.emptySuccess)) {
                    box.set(outcome)
                    finish(coordinatorOutcome)
                }

                func stage(_ inspection: GitConflictStageInspection) {
                    var hashPolicy = GitExecutionPolicy.default
                    hashPolicy.timeout = 30
                    hashPolicy.standardInput = expectedData
                    cancellation.add(executor.execute(
                        arguments: ["hash-object", "-w", "--path=\(path)", "--stdin"],
                        in: repository, outputLimit: GitOutputLimit(
                            stdoutBytes: 4096, stderrBytes: 64 * 1024),
                        policy: hashPolicy
                    ) { hashOutcome in
                        guard case .completed(let hashResult) = hashOutcome,
                              hashResult.ok, !hashResult.stdoutWasTruncated,
                              let oid = parseOID(hashResult.stdout) else {
                            stop(.inspectionFailed(hashOutcome), coordinatorOutcome: hashOutcome)
                            return
                        }
                        var record = Data("\(inspection.indexMode) \(oid)\t".utf8)
                        record.append(rawPath)
                        record.append(0)
                        var rejected: GitValidatedMutationOutcome?
                        cancellation.add(GitRunner.runHoldingIndexLock(
                            indexPath: inspection.indexPath, record: record,
                            headRef: inspection.headRef,
                            headOID: inspection.headOID,
                            headRefPath: inspection.headRefPath,
                            headRefNeedsNoDeref: inspection.headRefNeedsNoDeref,
                            worktreeHeadPath: inspection.worktreeHeadPath,
                            headSymbolicTarget: inspection.headSymbolicTarget,
                            in: repository,
                            verify: { approved in
                                // Git hält hier bereits seinen offiziellen
                                // index.lock. Read-only-Git erhält zusätzlich
                                // --no-optional-locks, damit die Prüfung nicht
                                // selbst einen Refresh-Lock anfordert.
                                inspect(repository: repository, rawPath: rawPath,
                                        path: path, fileURL: fileURL,
                                        expectedData: expectedData, executor: executor,
                                        cancellation: cancellation,
                                        disableOptionalLocks: true) { thirdResult in
                                    switch thirdResult {
                                    case .failure(let failure):
                                        rejected = .inspectionFailed(failure)
                                        approved(false)
                                    case .blocked(let reason):
                                        rejected = .blocked(reason)
                                        approved(false)
                                    case .success(let third):
                                        guard third == inspection else {
                                            rejected = .repositoryChanged
                                            approved(false)
                                            return
                                        }
                                        approved(true)
                                    }
                                }
                            },
                            completion: { outcome, submitted in
                                if submitted {
                                    box.set(.executed(outcome))
                                } else if let rejected {
                                    box.set(rejected)
                                } else if outcome == .cancelled {
                                    box.set(.cancelled)
                                } else {
                                    box.set(.inspectionFailed(outcome))
                                }
                                finish(outcome)
                            }
                        ))
                    })
                }

                inspect(repository: repository, rawPath: rawPath, path: path,
                        fileURL: fileURL, expectedData: expectedData,
                        executor: executor, cancellation: cancellation) { firstResult in
                    switch firstResult {
                    case .failure(let failure):
                        stop(.inspectionFailed(failure), coordinatorOutcome: failure)
                    case .blocked(let reason): stop(.blocked(reason))
                    case .success(let first):
                        if let reason = validate(first.safety) { stop(.blocked(reason)); return }
                        let hasMarkers = ConflictMarkerParser.containsMarkerLikeLines(expectedText)
                        DispatchQueue.main.async {
                            decision(first.markerSize, hasMarkers) { proceed in
                                guard proceed, !cancellation.isCancelled() else {
                                    stop(.cancelled, coordinatorOutcome: .cancelled); return
                                }
                                inspect(repository: repository, rawPath: rawPath,
                                        path: path, fileURL: fileURL,
                                        expectedData: expectedData, executor: executor,
                                        cancellation: cancellation) { secondResult in
                                    switch secondResult {
                                    case .failure(let failure):
                                        stop(.inspectionFailed(failure), coordinatorOutcome: failure)
                                    case .blocked(let reason): stop(.blocked(reason))
                                    case .success(let second):
                                        if let reason = validate(second.safety) {
                                            stop(.blocked(reason)); return
                                        }
                                        guard second == first else {
                                            stop(.repositoryChanged); return
                                        }
                                        stage(second)
                                    }
                                }
                            }
                        }
                    }
                }
                return cancellation
            },
            completion: { outcome in
                completion(box.get() ?? (outcome == .cancelled
                                         ? .cancelled : .inspectionFailed(outcome)))
            }
        )
    }

    private enum StageInspectionResult {
        case success(GitConflictStageInspection)
        case blocked(String)
        case failure(GitExecutionOutcome)
    }

    private static func inspect(repository: URL, rawPath: Data, path: String,
                                fileURL: URL, expectedData: Data,
                                executor: GitCommandExecuting,
                                cancellation: GitSequenceCancellation,
                                disableOptionalLocks: Bool = false,
                                completion: @escaping (StageInspectionResult) -> Void) {
        func arguments(_ values: [String]) -> [String] {
            disableOptionalLocks ? ["--no-optional-locks"] + values : values
        }
        GitValidatedMutationRunner.inspect(
            repository: repository, executor: executor, cancellation: cancellation,
            argumentPrefix: disableOptionalLocks ? ["--no-optional-locks"] : []
        ) { safetyResult in
            switch safetyResult {
            case .failure(let failure): completion(.failure(failure))
            case .success(let safety):
                cancellation.add(executor.execute(
                    arguments: arguments(GitConflictAttributeParser.arguments(path: path)),
                    in: repository, outputLimit: GitOutputLimit(
                        stdoutBytes: 64 * 1024, stderrBytes: 64 * 1024),
                    policy: .default
                ) { attrOutcome in
                    guard case .completed(let attrResult) = attrOutcome,
                          attrResult.ok, !attrResult.stdoutWasTruncated
                    else { completion(.failure(attrOutcome)); return }
                    guard let selectedAttributes = GitConflictAttributeParser.parseSelected(
                        attrResult.stdoutData, expectedRawPath: rawPath
                    ) else {
                        completion(.blocked(L10n.string(
                            "Git konnte die Dateiattribute dieses Konflikts nicht eindeutig prüfen. Fastra bietet keine Textauflösung oder Stage-Aktion an. Öffne ein Terminal für die Git-Auflösung.")))
                        return
                    }
                    guard !selectedAttributes.isBinary else {
                        completion(.blocked(L10n.string(
                            "Git klassifiziert diesen Konflikt über Dateiattribute als binär. Fastra bietet keine Textauflösung oder Stage-Aktion an. Öffne ein Terminal für die Git-Auflösung.")))
                        return
                    }
                    let markerSize = selectedAttributes.markerSize
                    cancellation.add(executor.execute(
                        arguments: arguments(["check-attr", "-z", "--all", "--", path]),
                        in: repository, outputLimit: GitOutputLimit(
                            stdoutBytes: 256 * 1024, stderrBytes: 64 * 1024),
                        policy: .default
                    ) { attributesOutcome in
                        guard case .completed(let attributesResult) = attributesOutcome,
                              attributesResult.ok,
                              !attributesResult.stdoutWasTruncated else {
                            completion(.failure(attributesOutcome)); return
                        }
                        guard let conflictAttributes = GitConflictAttributeParser.parseAll(
                            attributesResult.stdoutData, expectedRawPath: rawPath
                        ), conflictAttributes.markerSize == markerSize else {
                            completion(.blocked(L10n.string(
                                "Git konnte die Dateiattribute dieses Konflikts nicht eindeutig prüfen. Fastra bietet keine Textauflösung oder Stage-Aktion an. Öffne ein Terminal für die Git-Auflösung.")))
                            return
                        }
                        guard !conflictAttributes.isBinary else {
                            completion(.blocked(L10n.string(
                                "Git klassifiziert diesen Konflikt über Dateiattribute als binär. Fastra bietet keine Textauflösung oder Stage-Aktion an. Öffne ein Terminal für die Git-Auflösung.")))
                            return
                        }
                        cancellation.add(executor.execute(
                            arguments: arguments([
                                "config", "--includes", "-z", "--get-regexp",
                                "^(core\\.(autocrlf|eol|safecrlf|checkRoundtripEncoding|bigFileThreshold)|filter\\..*\\.(clean|process|required))$"
                            ]),
                            in: repository, outputLimit: GitOutputLimit(
                                stdoutBytes: 256 * 1024, stderrBytes: 64 * 1024),
                            policy: .default
                        ) { configOutcome in
                            guard case .completed(let configResult) = configOutcome,
                                  !configResult.stdoutWasTruncated,
                                  configResult.ok || configResult.exitCode == 1 else {
                                completion(.failure(configOutcome)); return
                            }
                    cancellation.add(executor.execute(
                        arguments: arguments(["ls-files", "--stage", "-z", "--", path]),
                        in: repository, outputLimit: GitOutputLimit(
                            stdoutBytes: 256 * 1024, stderrBytes: 64 * 1024),
                        policy: .default
                    ) { indexOutcome in
                        guard case .completed(let indexResult) = indexOutcome,
                              indexResult.ok, !indexResult.stdoutWasTruncated else {
                            completion(.failure(indexOutcome)); return
                        }
                        guard let mode = parseUnmergedMode(indexResult.stdoutData,
                                                           rawPath: rawPath) else {
                            completion(.blocked(L10n.string(
                                "Die Konfliktstufen besitzen keine eindeutige reguläre Dateimode. Fastra verändert den Index nicht.")))
                            return
                        }
                        cancellation.add(executor.execute(
                            arguments: arguments(["config", "--type=bool", "--get", "core.fileMode"]),
                            in: repository, outputLimit: GitOutputLimit(
                                stdoutBytes: 4096, stderrBytes: 64 * 1024),
                            policy: .default
                        ) { fileModeOutcome in
                            guard case .completed(let fileModeResult) = fileModeOutcome,
                                  !fileModeResult.stdoutWasTruncated else {
                                completion(.failure(fileModeOutcome)); return
                            }
                            let trimmed = fileModeResult.stdout
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .lowercased()
                            let honorsFileMode: Bool
                            if fileModeResult.exitCode == 1 { honorsFileMode = true }
                            else if fileModeResult.ok, trimmed == "true" { honorsFileMode = true }
                            else if fileModeResult.ok, trimmed == "false" { honorsFileMode = false }
                            else { completion(.failure(fileModeOutcome)); return }
                            guard let headOID = safety.status.headOID,
                                  let headRef = safety.status.isDetached
                                    ? "HEAD"
                                    : safety.status.branch.map({ "refs/heads/\($0)" }) else {
                                completion(.blocked(L10n.string(
                                    "Git meldet keinen eindeutigen HEAD. Fastra verändert den Index nicht.")))
                                return
                            }
                            cancellation.add(executor.execute(
                                arguments: arguments([
                                    "rev-parse", "--path-format=absolute",
                                    "--git-path", "index", "--git-path", headRef,
                                    "--git-path", "HEAD"
                                ]),
                                in: repository, outputLimit: GitOutputLimit(
                                    stdoutBytes: 64 * 1024, stderrBytes: 64 * 1024),
                                policy: .default
                            ) { indexPathOutcome in
                                guard case .completed(let indexPathResult) = indexPathOutcome,
                                      indexPathResult.ok,
                                      !indexPathResult.stdoutWasTruncated,
                                      let paths = parseAbsolutePaths(
                                        indexPathResult.stdoutData, count: 3) else {
                                    completion(.failure(indexPathOutcome)); return
                                }
                                let indexPath = paths[0]
                                let headRefPath = paths[1]
                                let worktreeHeadPath = paths[2]
                            DispatchQueue.global(qos: .userInitiated).async {
                                do {
                                    let data = try Data(contentsOf: fileURL,
                                                        options: [.mappedIfSafe])
                                    guard data == expectedData else {
                                        completion(.blocked(L10n.string(
                                            "Der gespeicherte Dateiinhalt stimmt nicht mehr mit dem geprüften Editorstand überein.")))
                                        return
                                    }
                                    if honorsFileMode {
                                        let attributes = try FileManager.default.attributesOfItem(
                                            atPath: fileURL.path)
                                        let permissions = (attributes[.posixPermissions] as? NSNumber)?
                                            .intValue ?? 0
                                        let workingTreeMode = permissions & 0o111 == 0
                                            ? "100644" : "100755"
                                        guard workingTreeMode == mode else {
                                            completion(.blocked(L10n.string(
                                                "Das Ausführbar-Bit der Konfliktdatei weicht von den Konfliktstufen ab. Fastra staged diese Mode-Änderung nicht still; gleiche den Dateimodus zuerst bewusst ab.")))
                                            return
                                        }
                                    }
                                    completion(.success(GitConflictStageInspection(
                                        safety: safety, markerSize: markerSize,
                                        indexMode: mode, indexPath: indexPath,
                                        headRef: headRef, headOID: headOID,
                                        headRefPath: headRefPath,
                                        headRefNeedsNoDeref: safety.status.isDetached,
                                        worktreeHeadPath: worktreeHeadPath,
                                        headSymbolicTarget: safety.status.isDetached
                                            ? nil : headRef,
                                        indexRecords: indexResult.stdoutData,
                                        attributes: attributesResult.stdoutData,
                                        conversionConfig: configResult.stdoutData)))
                                } catch {
                                    completion(.blocked(L10n.format(
                                        "Die gespeicherte Datei konnte nicht erneut geprüft werden: %@",
                                        error.localizedDescription)))
                                }
                            }
                            })
                        })
                    })
                        })
                    })
                })
            }
        }
    }

    private static func parseUnmergedMode(_ data: Data, rawPath: Data) -> String? {
        var modes = Set<String>()
        var sawUnmerged = false
        for rawRecord in data.split(separator: 0) {
            let record = Data(rawRecord)
            guard let tab = record.firstIndex(of: 0x09) else { return nil }
            let header = String(decoding: record[..<tab], as: UTF8.self)
                .split(separator: " ")
            let pathStart = record.index(after: tab)
            guard Data(record[pathStart...]) == rawPath, header.count == 3,
                  let stage = Int(header[2]), stage > 0 else { return nil }
            let mode = String(header[0])
            guard mode == "100644" || mode == "100755" else { return nil }
            modes.insert(mode)
            sawUnmerged = true
        }
        return sawUnmerged && modes.count == 1 ? modes.first : nil
    }

    private static func parseAbsolutePaths(_ data: Data, count: Int) -> [String]? {
        guard let value = String(data: data, encoding: .utf8),
              !value.contains("\0"), !value.contains("\r") else { return nil }
        let paths = value.split(separator: "\n", omittingEmptySubsequences: false)
        let normalized = paths.last == "" ? Array(paths.dropLast()) : paths
        guard normalized.count == count,
              normalized.allSatisfy({ !$0.isEmpty && $0.hasPrefix("/") }) else {
            return nil
        }
        return normalized.map(String.init)
    }

    private static func parseOID(_ output: String) -> String? {
        let oid = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (oid.count == 40 || oid.count == 64),
              oid.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...70).contains(byte)
                      || (97...102).contains(byte)
              })
        else { return nil }
        return oid
    }
}

struct GitForcePushTarget: Equatable {
    let localRef: String
    let branchName: String
    let sourceOID: String
    let remote: String
    let remoteRef: String
    let expectedOID: String

    var arguments: [String] {
        ["push", "--force-with-lease=\(remoteRef):\(expectedOID)", "--",
         remote, "\(sourceOID):\(remoteRef)"]
    }

    var displayTarget: String { "\(remote):\(remoteRef)" }
}

/// Löst genau ein Force-Push-Ziel aus Branch-Konfiguration und Upstream-OID
/// auf, bestätigt diesen Wert und liest alles im selben exklusiven Slot erneut.
enum GitForcePushRunner {
    typealias Decision = (GitForcePushTarget, @escaping (Bool) -> Void) -> Void

    @discardableResult
    static func run(repository: URL, coordinator: GitOperationsCoordinator,
                    decision: @escaping Decision,
                    completion: @escaping (GitValidatedMutationOutcome) -> Void)
        -> GitOperationLease {
        let box = GitValidatedMutationBox()
        let executor = coordinator.commandExecutor
        return coordinator.performExclusive(
            repository: repository, kind: .push, identity: "force-push-exact-target",
            starter: { finish in
                let cancellation = GitSequenceCancellation()
                func stop(_ value: GitValidatedMutationOutcome,
                          _ outcome: GitExecutionOutcome = .completed(.emptySuccess)) {
                    box.set(value); finish(outcome)
                }
                resolve(repository: repository, executor: executor,
                        cancellation: cancellation) { firstResult in
                    switch firstResult {
                    case .failure(let failure):
                        stop(.inspectionFailed(failure), failure)
                    case .blocked(let reason): stop(.blocked(reason))
                    case .success(let firstSafety, let firstTarget):
                        guard firstSafety.operation == nil else {
                            stop(.blocked(L10n.string(
                                "Schließe zuerst den laufenden Git-Vorgang ab.")))
                            return
                        }
                        DispatchQueue.main.async {
                            decision(firstTarget) { proceed in
                                guard proceed, !cancellation.isCancelled() else {
                                    stop(.cancelled, .cancelled); return
                                }
                                resolve(repository: repository, executor: executor,
                                        cancellation: cancellation) { secondResult in
                                    switch secondResult {
                                    case .failure(let failure):
                                        stop(.inspectionFailed(failure), failure)
                                    case .blocked:
                                        // Vor dem Dialog wäre dies eine normale
                                        // Vorbedingung; danach beweist es eine
                                        // Änderung des bereits bestätigten Ziels.
                                        stop(.repositoryChanged)
                                    case .success(let secondSafety, let secondTarget):
                                        guard firstSafety == secondSafety,
                                              firstTarget == secondTarget else {
                                            stop(.repositoryChanged); return
                                        }
                                        cancellation.add(executor.execute(
                                            arguments: secondTarget.arguments,
                                            in: repository, outputLimit: .default,
                                            policy: .default
                                        ) { outcome in
                                            box.set(.executed(outcome)); finish(outcome)
                                        })
                                    }
                                }
                            }
                        }
                    }
                }
                return cancellation
            }, completion: { outcome in
                completion(box.get() ?? (outcome == .cancelled
                                         ? .cancelled : .inspectionFailed(outcome)))
            }
        )
    }

    private enum ResolveResult {
        case success(GitSafetyInspection, GitForcePushTarget)
        case blocked(String)
        case failure(GitExecutionOutcome)
    }

    private static func resolve(repository: URL, executor: GitCommandExecuting,
                                cancellation: GitSequenceCancellation,
                                completion: @escaping (ResolveResult) -> Void) {
        GitValidatedMutationRunner.inspect(
            repository: repository, executor: executor, cancellation: cancellation
        ) { safetyResult in
            switch safetyResult {
            case .failure(let failure): completion(.failure(failure))
            case .success(let safety):
                read(["symbolic-ref", "-q", "HEAD"], repository: repository,
                     executor: executor, cancellation: cancellation) { localResult in
                    guard case .success(let localRef) = localResult else {
                        if case .failure(let failure) = localResult,
                           !isExpectedMissing(failure) {
                            completion(.failure(failure)); return
                        }
                        completion(.blocked(L10n.string(
                            "Force Push with Lease benötigt einen lokalen symbolischen Branch.")))
                        return
                    }
                    guard localRef.hasPrefix("refs/heads/") else {
                        completion(.blocked(L10n.string(
                            "Force Push with Lease benötigt einen lokalen symbolischen Branch.")))
                        return
                    }
                    let branch = String(localRef.dropFirst("refs/heads/".count))
                    read(["rev-parse", "--verify", "HEAD^{commit}"],
                         repository: repository, executor: executor,
                         cancellation: cancellation) { sourceResult in
                        guard case .success(let source) = sourceResult,
                              let sourceOID = parseOID(source) else {
                            if case .failure(let failure) = sourceResult,
                               !isExpectedMissing(failure) {
                                completion(.failure(failure)); return
                            }
                            completion(.blocked(L10n.string(
                                "Die lokale HEAD-Commit-OID konnte nicht eindeutig gelesen werden.")))
                            return
                        }
                    read(["config", "--local", "--get-all", "branch.\(branch).remote"],
                         repository: repository, executor: executor,
                         cancellation: cancellation) { remoteResult in
                        guard case .success(let remote) = remoteResult else {
                            if case .failure(let failure) = remoteResult,
                               !isExpectedMissing(failure) {
                                completion(.failure(failure)); return
                            }
                            completion(.blocked(L10n.string(
                                "Der Branch besitzt kein eindeutiges externes Push-Remote.")))
                            return
                        }
                        guard remote != ".", isSingleSafeLine(remote) else {
                            completion(.blocked(L10n.string(
                                "Der Branch besitzt kein eindeutiges externes Push-Remote.")))
                            return
                        }
                        func resolveMergeTarget() {
                            read(["config", "--local", "--get-all", "branch.\(branch).merge"],
                                 repository: repository, executor: executor,
                                 cancellation: cancellation) { mergeResult in
                            guard case .success(let remoteRef) = mergeResult else {
                                if case .failure(let failure) = mergeResult,
                                   !isExpectedMissing(failure) {
                                    completion(.failure(failure)); return
                                }
                                completion(.blocked(L10n.string(
                                    "Der Branch besitzt kein eindeutiges Upstream-Ziel unter refs/heads.")))
                                return
                            }
                            guard remoteRef.hasPrefix("refs/heads/"),
                                  isSingleSafeLine(remoteRef) else {
                                completion(.blocked(L10n.string(
                                    "Der Branch besitzt kein eindeutiges Upstream-Ziel unter refs/heads.")))
                                return
                            }
                            read(["rev-parse", "--verify", "@{upstream}^{commit}"],
                                 repository: repository, executor: executor,
                                 cancellation: cancellation) { oidResult in
                                guard case .success(let oid) = oidResult else {
                                    if case .failure(let failure) = oidResult,
                                       !isExpectedMissing(failure) {
                                        completion(.failure(failure)); return
                                    }
                                    completion(.blocked(L10n.string(
                                        "Die erwartete Upstream-OID konnte nicht eindeutig gelesen werden.")))
                                    return
                                }
                                guard let checkedOID = parseOID(oid) else {
                                    completion(.blocked(L10n.string(
                                        "Die erwartete Upstream-OID konnte nicht eindeutig gelesen werden.")))
                                    return
                                }
                                completion(.success(safety, GitForcePushTarget(
                                    localRef: localRef, branchName: branch,
                                    sourceOID: sourceOID,
                                    remote: remote, remoteRef: remoteRef,
                                    expectedOID: checkedOID)))
                            }
                        }
                        }
                        // Nur ein von `git remote` gelisteter Name darf je in
                        // Push-argv oder Bestätigungsdialog gelangen. Eine
                        // handeditierte URL (möglicherweise mit Credentials)
                        // bleibt damit vollständig außerhalb dieser Pfade.
                        read(["remote"], repository: repository,
                             executor: executor, cancellation: cancellation) { namesResult in
                            guard case .success(let namesOutput) = namesResult else {
                                if case .failure(let failure) = namesResult {
                                    completion(.failure(failure))
                                }
                                return
                            }
                            let names = namesOutput.split(whereSeparator: \.isNewline)
                                .map(String.init).filter(isSingleSafeLine)
                            guard names.contains(remote) else {
                                completion(.blocked(L10n.string(
                                    "Das konfigurierte Push-Remote ist kein vorhandener Remote-Name.")))
                                return
                            }
                            resolveMergeTarget()
                        }
                    }
                    }
                }
            }
        }
    }

    private enum ReadResult { case success(String); case failure(GitExecutionOutcome) }

    private static func read(_ arguments: [String], repository: URL,
                             executor: GitCommandExecuting,
                             cancellation: GitSequenceCancellation,
                             completion: @escaping (ReadResult) -> Void) {
        cancellation.add(executor.execute(
            arguments: arguments, in: repository,
            outputLimit: GitOutputLimit(stdoutBytes: 64 * 1024,
                                        stderrBytes: 64 * 1024),
            policy: .default
        ) { outcome in
            guard case .completed(let result) = outcome, result.ok,
                  !result.stdoutWasTruncated,
                  let output = String(data: result.stdoutData, encoding: .utf8)
            else { completion(.failure(outcome)); return }
            var value = output
            if value.hasSuffix("\n") { value.removeLast() }
            if value.hasSuffix("\r") { value.removeLast() }
            completion(.success(value))
        })
    }

    private static func isSingleSafeLine(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("\n") && !value.contains("\r")
            && !value.contains("\0")
    }

    private static func isExpectedMissing(_ outcome: GitExecutionOutcome) -> Bool {
        guard case .completed(let result) = outcome else { return false }
        return result.exitCode == 1
    }

    private static func parseOID(_ value: String) -> String? {
        let oid = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (oid.count == 40 || oid.count == 64),
              oid.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...70).contains(byte)
                      || (97...102).contains(byte)
              })
        else { return nil }
        return oid
    }
}

enum GitIdentityScope: Equatable {
    case repository
    case global
}

struct GitIdentitySnapshot: Equatable {
    let localName: String?
    let localEmail: String?
    let globalName: String?
    let globalEmail: String?

    var effectiveName: String? { localName ?? globalName }
    var effectiveEmail: String? { localEmail ?? globalEmail }
    var isComplete: Bool { effectiveName != nil && effectiveEmail != nil }

    var sourceDescription: String {
        let nameSource = localName != nil ? L10n.string("Repository-lokal")
            : (globalName != nil ? L10n.string("Global") : L10n.string("Fehlt"))
        let emailSource = localEmail != nil ? L10n.string("Repository-lokal")
            : (globalEmail != nil ? L10n.string("Global") : L10n.string("Fehlt"))
        return L10n.format("Name: %@ · E-Mail: %@", nameSource, emailSource)
    }
}

enum GitIdentityInput {
    static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0"),
              !trimmed.contains("\n"), !trimmed.contains("\r") else { return nil }
        return trimmed
    }
}

struct GitIdentityConfiguration: Equatable {
    let name: String
    let email: String
    let scope: GitIdentityScope
    let globalConfirmed: Bool

    var arguments: [[String]]? {
        guard let name = GitIdentityInput.normalized(name),
              let email = GitIdentityInput.normalized(email),
              scope != .global || globalConfirmed else { return nil }
        let scopeArgument = scope == .repository ? "--local" : "--global"
        return [
            ["config", scopeArgument, "--replace-all", "user.name", name],
            ["config", scopeArgument, "--replace-all", "user.email", email]
        ]
    }
}

enum GitIdentityReadOutcome: Equatable {
    case value(GitIdentitySnapshot)
    case failure(GitExecutionOutcome)
    case cancelled
}

enum GitIdentityLock {
    /// Reiner Koordinator-Key, kein Dateizugriff. Dadurch können globale
    /// Reads/Writes aus verschiedenen Repositories nie ein Mischpaar bilden.
    static let globalRepositoryKey = URL(fileURLWithPath: "/.fastra-global-git-config-lock")
}

private final class GitIdentityReadBox {
    private let lock = NSLock()
    private var outcome: GitIdentityReadOutcome?
    func set(_ value: GitIdentityReadOutcome) { lock.lock(); outcome = value; lock.unlock() }
    func get() -> GitIdentityReadOutcome? { lock.lock(); defer { lock.unlock() }; return outcome }
}

enum GitIdentityReader {
    private static let commands = [
        ["config", "--includes", "--local", "--get", "user.name"],
        ["config", "--includes", "--local", "--get", "user.email"],
        ["config", "--includes", "--global", "--get", "user.name"],
        ["config", "--includes", "--global", "--get", "user.email"]
    ]

    @discardableResult
    static func read(repository: URL, coordinator: GitOperationsCoordinator,
                     completion: @escaping (GitIdentityReadOutcome) -> Void)
        -> GitOperationLease {
        let box = GitIdentityReadBox()
        let executor = coordinator.commandExecutor
        return coordinator.performExclusive(
            repository: GitIdentityLock.globalRepositoryKey, kind: .refresh,
            identity: "identity-read-\(GitOperationRequest.canonicalRepositoryPath(repository))",
            starter: { finish in
                let cancellation = GitSequenceCancellation()
                var values = Array<String?>(repeating: nil, count: commands.count)
                func run(_ index: Int) {
                    guard index < commands.count else {
                        box.set(.value(GitIdentitySnapshot(
                            localName: values[0], localEmail: values[1],
                            globalName: values[2], globalEmail: values[3]
                        )))
                        finish(.completed(.emptySuccess)); return
                    }
                    cancellation.add(executor.execute(
                        arguments: commands[index], in: repository,
                        outputLimit: GitOutputLimit(stdoutBytes: 64 * 1024,
                                                    stderrBytes: 64 * 1024),
                        policy: .default
                    ) { outcome in
                        guard case .completed(let result) = outcome,
                              !result.stdoutWasTruncated else {
                            box.set(.failure(outcome)); finish(outcome); return
                        }
                        if result.exitCode == 0 {
                            guard let decoded = String(data: result.stdoutData,
                                                       encoding: .utf8),
                                  !decoded.contains("\0") else {
                                box.set(.failure(.captureFailed(GitCaptureFailure(
                                    stdoutError: L10n.string("Git-Identität ist kein gültiges UTF-8."),
                                    stderrError: nil, partialResult: result
                                ))))
                                finish(.captureFailed(GitCaptureFailure(
                                    stdoutError: L10n.string("Git-Identität ist kein gültiges UTF-8."),
                                    stderrError: nil, partialResult: result
                                )))
                                return
                            }
                            values[index] = normalizeOutput(decoded)
                        } else if result.exitCode != 1 {
                            box.set(.failure(outcome)); finish(outcome); return
                        }
                        run(index + 1)
                    })
                }
                run(0)
                return cancellation
            },
            completion: { coordinatorOutcome in
                completion(box.get() ?? (coordinatorOutcome == .cancelled
                                         ? .cancelled : .failure(coordinatorOutcome)))
            }
        )
    }

    private static func normalizeOutput(_ value: String) -> String? {
        var value = value
        if value.hasSuffix("\n") { value.removeLast() }
        if value.hasSuffix("\r") { value.removeLast() }
        return GitIdentityInput.normalized(value)
    }
}

enum GitIdentityWriteOutcome: Equatable {
    case written
    case failure(GitExecutionOutcome)
    case rollbackFailed(original: GitExecutionOutcome, rollback: GitExecutionOutcome)
    case verificationFailed
    case invalidOrUnconfirmed
    case cancelled
}

private final class GitIdentityWriteBox {
    private let lock = NSLock()
    private var outcome: GitIdentityWriteOutcome?
    func set(_ value: GitIdentityWriteOutcome) { lock.lock(); outcome = value; lock.unlock() }
    func get() -> GitIdentityWriteOutcome? { lock.lock(); defer { lock.unlock() }; return outcome }
}

enum GitIdentityWriter {
    @discardableResult
    static func write(_ configuration: GitIdentityConfiguration,
                      repository: URL, coordinator: GitOperationsCoordinator,
                      completion: @escaping (GitIdentityWriteOutcome) -> Void)
        -> GitOperationLease? {
        guard let commands = configuration.arguments,
              let expectedName = GitIdentityInput.normalized(configuration.name),
              let expectedEmail = GitIdentityInput.normalized(configuration.email) else {
            completion(.invalidOrUnconfirmed); return nil
        }
        let box = GitIdentityWriteBox()
        let executor = coordinator.commandExecutor
        let identity = "identity-write-\(configuration.scope)"
        let cancellationGate = GitOperationCancellationGate()
        let starter: GitOperationsCoordinator.Starter = { finish in
                let cancellation = GitIdentityMutationCancellation(
                    coordinatorGate: cancellationGate
                )
                let scope = configuration.scope == .repository ? "--local" : "--global"
                var previous: [[String]] = [[], []]
                var previousDirectOrigins: [[OriginValue]] = [[], []]
                var previousIncluded: [[OriginValue]] = [[], []]

                func complete(_ outcome: GitIdentityWriteOutcome,
                              coordinatorOutcome: GitExecutionOutcome) {
                    cancellation.finish()
                    box.set(outcome)
                    finish(coordinatorOutcome)
                }

                func execute(_ arguments: [String],
                             done: @escaping (GitExecutionOutcome) -> Void) {
                    cancellation.addCleanup(executor.execute(
                        arguments: arguments, in: repository,
                        outputLimit: GitOutputLimit(stdoutBytes: 64 * 1024,
                                                    stderrBytes: 64 * 1024),
                        policy: .default, completion: done))
                }

                func verifyRestored(_ original: GitExecutionOutcome, index: Int) {
                    guard index < 2 else {
                        verifyIncludedRestored(original, index: 0); return
                    }
                    let key = index == 0 ? "user.name" : "user.email"
                    readAll(scope: scope, key: key, repository: repository,
                            executor: executor, register: cancellation.addCleanup) { result in
                        switch result {
                        case .failure(let rollbackFailure):
                            complete(.rollbackFailed(original: original,
                                                     rollback: rollbackFailure),
                                     coordinatorOutcome: rollbackFailure)
                        case .success(let values) where values == previous[index]:
                            verifyRestored(original, index: index + 1)
                        case .success:
                            let rollbackFailure = GitExecutionOutcome.captureFailed(
                                GitCaptureFailure(
                                    stdoutError: L10n.string("Die vorherige Git-Identität konnte nicht vollständig wiederhergestellt werden."),
                                    stderrError: nil, partialResult: .emptySuccess))
                            complete(.rollbackFailed(original: original,
                                                     rollback: rollbackFailure),
                                     coordinatorOutcome: rollbackFailure)
                        }
                    }
                }

                func verifyIncludedRestored(_ original: GitExecutionOutcome,
                                            index: Int) {
                    guard index < 2 else {
                        complete(.failure(original), coordinatorOutcome: original)
                        return
                    }
                    let key = index == 0 ? "user.name" : "user.email"
                    readOrigins(scope: scope, key: key, includes: true,
                                repository: repository, executor: executor,
                                register: cancellation.addCleanup) { result in
                        switch result {
                        case .failure(let rollbackFailure):
                            complete(.rollbackFailed(original: original,
                                                     rollback: rollbackFailure),
                                     coordinatorOutcome: rollbackFailure)
                        case .success(let values) where values == previousIncluded[index]:
                            verifyIncludedRestored(original, index: index + 1)
                        case .success:
                            let rollbackFailure = GitExecutionOutcome.captureFailed(
                                GitCaptureFailure(
                                    stdoutError: L10n.string("Die wirksame Git-Identität aus include- oder includeIf-Konfigurationen konnte nicht vollständig wiederhergestellt werden."),
                                    stderrError: nil, partialResult: .emptySuccess))
                            complete(.rollbackFailed(original: original,
                                                     rollback: rollbackFailure),
                                     coordinatorOutcome: rollbackFailure)
                        }
                    }
                }

                func rollback(_ original: GitExecutionOutcome, keyIndex: Int = 0) {
                    guard keyIndex < 2 else {
                        verifyRestored(original, index: 0); return
                    }
                    let key = keyIndex == 0 ? "user.name" : "user.email"
                    let arguments = previous[keyIndex].isEmpty
                        ? ["config", scope, "--unset-all", key]
                        : ["config", scope, "--replace-all", key,
                           previous[keyIndex][0]]
                    execute(arguments) { outcome in
                        guard case .completed(let result) = outcome,
                              result.ok || (previous[keyIndex].isEmpty
                                            && result.exitCode == 5) else {
                            complete(.rollbackFailed(original: original,
                                                     rollback: outcome),
                                     coordinatorOutcome: outcome)
                            return
                        }
                        rollback(original, keyIndex: keyIndex + 1)
                    }
                }

                func verifyIncluded(_ index: Int) {
                    guard index < 2 else {
                        complete(.written, coordinatorOutcome: .completed(.emptySuccess))
                        return
                    }
                    let key = index == 0 ? "user.name" : "user.email"
                    let expected = index == 0 ? expectedName : expectedEmail
                    readOrigins(scope: scope, key: key, includes: true,
                                repository: repository, executor: executor,
                                register: cancellation.addCleanup) { result in
                        switch result {
                        case .failure(let failure): rollback(failure)
                        case .success(let values):
                            let effective = values.last.flatMap {
                                GitIdentityInput.normalized($0.value)
                            }
                            guard effective == expected else {
                                let failure = GitExecutionOutcome.captureFailed(
                                    GitCaptureFailure(
                                        stdoutError: L10n.string("Eine include- oder includeIf-Konfiguration überschreibt die eben geschriebene Git-Identität. Fastra stellt die vorherigen Werte wieder her."),
                                        stderrError: nil, partialResult: .emptySuccess))
                                rollback(failure)
                                return
                            }
                            verifyIncluded(index + 1)
                        }
                    }
                }

                func verify(_ index: Int) {
                    guard index < 2 else { verifyIncluded(0); return }
                    let key = index == 0 ? "user.name" : "user.email"
                    readAll(scope: scope, key: key, repository: repository,
                            executor: executor, register: cancellation.addCleanup) { result in
                        switch result {
                        case .failure(let failure): rollback(failure)
                        case .success(let values):
                            let expected = index == 0 ? expectedName : expectedEmail
                            guard values == [expected] else {
                                let failure = GitExecutionOutcome.captureFailed(
                                    GitCaptureFailure(
                                        stdoutError: L10n.string("Git meldet nach dem Schreiben andere Identitätswerte."),
                                        stderrError: nil, partialResult: .emptySuccess))
                                rollback(failure)
                                return
                            }
                            verify(index + 1)
                        }
                    }
                }

                func write(_ index: Int) {
                    guard index < commands.count else { verify(0); return }
                    execute(commands[index]) { outcome in
                        guard case .completed(let result) = outcome, result.ok else {
                            rollback(outcome); return
                        }
                        write(index + 1)
                    }
                }

                func captureIncluded(_ index: Int) {
                    guard index < 2 else {
                        for keyIndex in 0..<2 {
                            if let message = unsafeWriteReason(
                                direct: previousDirectOrigins[keyIndex],
                                included: previousIncluded[keyIndex]
                            ) {
                                let failure = GitExecutionOutcome.captureFailed(
                                    GitCaptureFailure(stdoutError: L10n.string(message),
                                                      stderrError: nil,
                                                      partialResult: .emptySuccess))
                                complete(.failure(failure), coordinatorOutcome: failure)
                                return
                            }
                        }
                        guard cancellation.beginMutation() else {
                            complete(.cancelled, coordinatorOutcome: .cancelled)
                            return
                        }
                        write(0)
                        return
                    }
                    let key = index == 0 ? "user.name" : "user.email"
                    readOrigins(scope: scope, key: key, includes: true,
                                repository: repository, executor: executor,
                                register: cancellation.addPreflight) { result in
                        switch result {
                        case .failure(let failure):
                            complete(.failure(failure), coordinatorOutcome: failure)
                        case .success(let values):
                            previousIncluded[index] = values
                            captureIncluded(index + 1)
                        }
                    }
                }

                func capture(_ index: Int) {
                    guard index < 2 else { captureIncluded(0); return }
                    let key = index == 0 ? "user.name" : "user.email"
                    readOrigins(scope: scope, key: key, includes: false,
                                repository: repository, executor: executor,
                                register: cancellation.addPreflight) { result in
                        switch result {
                        case .failure(let failure):
                            complete(.failure(failure), coordinatorOutcome: failure)
                        case .success(let values):
                            previousDirectOrigins[index] = values
                            previous[index] = values.map(\.value)
                            capture(index + 1)
                        }
                    }
                }
                capture(0)
                return cancellation
            }
        let coordinatedCompletion: (GitExecutionOutcome) -> Void = { coordinatorOutcome in
            completion(box.get() ?? (coordinatorOutcome == .cancelled
                                     ? .cancelled : .failure(coordinatorOutcome)))
        }
        return coordinator.performIdentityBarrierExclusive(
            repository: repository, kind: .workingTreeMutation,
            identity: identity, cancellationGate: cancellationGate,
            starter: starter,
            completion: coordinatedCompletion
        )
    }

    private struct OriginValue: Equatable {
        let origin: String
        let value: String
    }

    private enum ValuesResult { case success([String]); case failure(GitExecutionOutcome) }
    private enum OriginsResult {
        case success([OriginValue])
        case failure(GitExecutionOutcome)
    }

    /// Git selbst liefert Herkunft und effektive Reihenfolge. Fastra parst keine
    /// Configdatei und legt keinen eigenen Lock an. Ein späterer Include-Wert
    /// würde eine direkte Ersetzung weiterhin überstimmen; mehrere direkte
    /// Einträge ließen sich nach einem Teilfehler nicht positionsgetreu mit
    /// `unset`/`add` restaurieren. Beides wird daher vor dem ersten Write beendet.
    private static func unsafeWriteReason(direct: [OriginValue],
                                          included: [OriginValue]) -> String? {
        guard direct.count <= 1 else {
            return "Mehrere direkte Werte verhindern eine positionsgetreue Wiederherstellung der Git-Identität. Fastra hat nichts geschrieben."
        }
        guard let entry = direct.first else {
            return included.isEmpty ? nil
                : "Eine include- oder includeIf-Konfiguration würde die direkte Git-Identität weiterhin überschreiben. Fastra hat nichts geschrieben."
        }
        let directIndices = included.indices.filter {
            included[$0].origin == entry.origin
        }
        guard directIndices.count == 1,
              let index = directIndices.first,
              included[index].value == entry.value else {
            return "Die Herkunft der direkten Git-Identität ist nicht eindeutig. Fastra hat nichts geschrieben."
        }
        return index == included.index(before: included.endIndex) ? nil
            : "Eine include- oder includeIf-Konfiguration würde die direkte Git-Identität weiterhin überschreiben. Fastra hat nichts geschrieben."
    }

    private static func readAll(scope: String, key: String, repository: URL,
                                executor: GitCommandExecuting,
                                register: (GitCancelling) -> Void,
                                completion: @escaping (ValuesResult) -> Void) {
        register(executor.execute(
            arguments: ["config", scope, "-z", "--get-all", key],
            in: repository, outputLimit: GitOutputLimit(
                stdoutBytes: 64 * 1024, stderrBytes: 64 * 1024),
            policy: .default
        ) { outcome in
            guard case .completed(let result) = outcome,
                  !result.stdoutWasTruncated else {
                completion(.failure(outcome)); return
            }
            if result.exitCode == 1 { completion(.success([])); return }
            guard result.ok else { completion(.failure(outcome)); return }
            let rawValues = result.stdoutData.split(separator: UInt8(0)).map { Data($0) }
            var values: [String] = []
            for raw in rawValues {
                guard let value = String(data: raw, encoding: .utf8) else {
                    completion(.failure(.captureFailed(GitCaptureFailure(
                        stdoutError: L10n.string("Git-Identität ist kein gültiges UTF-8."),
                        stderrError: nil, partialResult: result))))
                    return
                }
                values.append(value)
            }
            completion(.success(values))
        })
    }

    /// Liest Herkunft und Reihenfolge direkt über Git. `--show-origin -z`
    /// liefert abwechselnd Origin und Wert; Includes bleiben dadurch sichtbar,
    /// ohne dass Fastra die Configsyntax selbst interpretieren müsste.
    private static func readOrigins(scope: String, key: String, includes: Bool,
                                    repository: URL,
                                    executor: GitCommandExecuting,
                                    register: (GitCancelling) -> Void,
                                    completion: @escaping (OriginsResult) -> Void) {
        var arguments = ["config"]
        if includes { arguments.append("--includes") }
        arguments += [scope, "--show-origin", "-z", "--get-all", key]
        register(executor.execute(
            arguments: arguments,
            in: repository, outputLimit: GitOutputLimit(
                stdoutBytes: 64 * 1024, stderrBytes: 64 * 1024),
            policy: .default
        ) { outcome in
            guard case .completed(let result) = outcome,
                  !result.stdoutWasTruncated else {
                completion(.failure(outcome)); return
            }
            if result.exitCode == 1 { completion(.success([])); return }
            guard result.ok else { completion(.failure(outcome)); return }
            let fields = result.stdoutData.split(separator: UInt8(0)).map { Data($0) }
            guard fields.count.isMultiple(of: 2) else {
                completion(.failure(.captureFailed(GitCaptureFailure(
                    stdoutError: L10n.string("Git lieferte keine eindeutige Herkunft der Identitätswerte."),
                    stderrError: nil, partialResult: result))))
                return
            }
            var values: [OriginValue] = []
            for index in stride(from: 0, to: fields.count, by: 2) {
                guard let origin = String(data: fields[index], encoding: .utf8),
                      let value = String(data: fields[index + 1], encoding: .utf8) else {
                    completion(.failure(.captureFailed(GitCaptureFailure(
                        stdoutError: L10n.string("Git-Identität ist kein gültiges UTF-8."),
                        stderrError: nil, partialResult: result))))
                    return
                }
                values.append(OriginValue(origin: origin, value: value))
            }
            completion(.success(values))
        })
    }
}

private extension GitResult {
    static let emptySuccess = GitResult(exitCode: 0, stdoutData: Data(),
                                        stderrData: Data())
}
