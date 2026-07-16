import AppKit
import CodeEditTextView
import Darwin
import Foundation
import Testing
@testable import Fastra

private final class AdvancedControlledExecutor: GitCommandExecuting {
    final class Token: GitCancelling {
        private(set) var cancelled = false
        func cancel() { cancelled = true }
    }
    struct Call {
        let arguments: [String]
        let directory: URL
        let policy: GitExecutionPolicy
        let completion: (GitExecutionOutcome) -> Void
        let token: Token
    }
    private let lock = NSLock()
    private var calls: [Call] = []

    var count: Int { lock.withLock { calls.count } }
    var arguments: [[String]] { lock.withLock { calls.map(\.arguments) } }
    var policies: [GitExecutionPolicy] { lock.withLock { calls.map(\.policy) } }
    var cancellations: [Bool] { lock.withLock { calls.map(\.token.cancelled) } }

    @discardableResult
    func execute(arguments: [String], in directory: URL,
                 outputLimit: GitOutputLimit, policy: GitExecutionPolicy,
                 completion: @escaping (GitExecutionOutcome) -> Void) -> GitCancelling {
        let token = Token()
        lock.withLock {
            calls.append(Call(arguments: arguments, directory: directory,
                              policy: policy, completion: completion, token: token))
        }
        return token
    }

    func complete(_ index: Int, _ outcome: GitExecutionOutcome) {
        let completion = lock.withLock { calls[index].completion }
        completion(outcome)
    }
}

private final class AdvancedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}

/// Reale Git-Prozesse mit einem ausschließlich testlokalen HOME. So kann der
/// globale Identity-Pfad geprüft werden, ohne Daniels echte Git-Konfiguration
/// zu lesen oder zu verändern.
private final class IsolatedHomeGitExecutor: GitCommandExecuting {
    let home: URL

    init(home: URL) throws {
        self.home = home
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    @discardableResult
    func execute(arguments: [String], in directory: URL,
                 outputLimit: GitOutputLimit, policy: GitExecutionPolicy,
                 completion: @escaping (GitExecutionOutcome) -> Void) -> GitCancelling {
        guard let gitPath = GitRunner.resolvedPath else {
            DispatchQueue.main.async { completion(.startFailed(.gitUnavailable)) }
            return GitOperationLease {}
        }
        return GitRunner.runExecutable(
            URL(fileURLWithPath: gitPath),
            arguments: ["--no-pager"] + arguments,
            in: directory,
            environment: [
                "HOME": home.path,
                "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path
            ],
            editorPolicy: policy.editorPolicy,
            outputLimit: outputLimit,
            policy: policy,
            completion: completion
        )
    }
}

private struct AdvancedTimeout: Error {}

private func waitAdvanced(_ description: String,
                          timeout: Duration = .seconds(3),
                          _ condition: @escaping () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record(Comment(rawValue: description))
    throw AdvancedTimeout()
}

private func advancedSuccess(_ data: Data = Data()) -> GitExecutionOutcome {
    .completed(GitResult(exitCode: 0, stdoutData: data, stderrData: Data()))
}

private func advancedFailure(_ text: String = "failure", code: Int32 = 1)
    -> GitExecutionOutcome {
    .completed(GitResult(exitCode: code, stdout: "", stderr: text))
}

private func identityOriginData(_ entries: [(origin: String, value: String)]) -> Data {
    var data = Data()
    for entry in entries {
        data.append(Data(entry.origin.utf8)); data.append(0)
        data.append(Data(entry.value.utf8)); data.append(0)
    }
    return data
}

private func directIdentityOriginData(_ value: String) -> Data {
    identityOriginData([("file:.git/config", value)])
}

private func selectedConflictAttributeData(path: String,
                                           markerSize: String = "unspecified",
                                           binary: Bool = false) -> Data {
    let values = [
        ("binary", binary ? "set" : "unspecified"),
        ("text", binary ? "unset" : "unspecified"),
        ("diff", binary ? "unset" : "unspecified"),
        ("merge", binary ? "unset" : "unspecified"),
        ("conflict-marker-size", markerSize)
    ]
    var data = Data()
    for (attribute, value) in values {
        data.append(Data(path.utf8)); data.append(0)
        data.append(Data(attribute.utf8)); data.append(0)
        data.append(Data(value.utf8)); data.append(0)
    }
    return data
}

private func statusData(branch: String = "main", upstream: String? = "origin/main",
                        conflictPath: String? = nil, modifiedPath: String? = nil,
                        untrackedPath: String? = nil) -> Data {
    var records = ["# branch.oid abcdef", "# branch.head \(branch)"]
    if let upstream { records.append("# branch.upstream \(upstream)") }
    records.append("# branch.ab +0 -0")
    if let conflictPath {
        records.append("u UU N... 100644 100644 100644 100644 aaaaaaa bbbbbbb ccccccc \(conflictPath)")
    }
    if let modifiedPath {
        records.append("1 .M N... 100644 100644 100644 aaaaaaa bbbbbbb \(modifiedPath)")
    }
    if let untrackedPath { records.append("? \(untrackedPath)") }
    var data = Data()
    for record in records { data.append(Data(record.utf8)); data.append(0) }
    return data
}

private func absentOperationPaths(in repository: URL) -> GitExecutionOutcome {
    let base = repository.appendingPathComponent("absent-git-state")
    let output = GitOperationStateDetector.markers.map {
        base.appendingPathComponent($0.1).path
    }.joined(separator: "\n") + "\n"
    return advancedSuccess(Data(output.utf8))
}

private func makeDefaults(_ suffix: String) -> (UserDefaults, String) {
    let name = "Fastra-P4-\(suffix)-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return (defaults, name)
}

private func runAdvancedGit(_ arguments: [String], in repository: URL) async
    -> GitExecutionOutcome {
    await withCheckedContinuation { continuation in
        _ = GitRunner.runDetailed(arguments, in: repository) {
            continuation.resume(returning: $0)
        }
    }
}

private func requireAdvancedGit(_ arguments: [String], in repository: URL,
                                expectedExit: Int32 = 0) async throws -> GitResult {
    let outcome = await runAdvancedGit(arguments, in: repository)
    guard case .completed(let result) = outcome else {
        Issue.record("git \(arguments.joined(separator: " ")) wurde nicht ausgeführt: \(outcome)")
        throw AdvancedTimeout()
    }
    if result.exitCode != expectedExit {
        Issue.record("git \(arguments.joined(separator: " ")) endete mit \(result.exitCode) statt \(expectedExit): \(result.stderrForDisplay)")
    }
    return result
}

private func makeRebaseConflict(in root: URL, applyBackend: Bool = false) async throws -> URL {
    _ = try await requireAdvancedGit(["init", "-q", "-b", "main"], in: root)
    _ = try await requireAdvancedGit(["config", "user.name", "Fastra Test"], in: root)
    _ = try await requireAdvancedGit(["config", "user.email", "fastra@example.test"], in: root)
    let file = root.appendingPathComponent("rebase.txt")
    try Data("basis\n".utf8).write(to: file)
    _ = try await requireAdvancedGit(["add", "rebase.txt"], in: root)
    _ = try await requireAdvancedGit(["commit", "-q", "-m", "Basis"], in: root)
    _ = try await requireAdvancedGit(["switch", "-q", "-c", "topic"], in: root)
    try Data("topic\n".utf8).write(to: file)
    _ = try await requireAdvancedGit(["commit", "-q", "-am", "Topic-Nachricht"], in: root)
    _ = try await requireAdvancedGit(["switch", "-q", "main"], in: root)
    try Data("main\n".utf8).write(to: file)
    _ = try await requireAdvancedGit(["commit", "-q", "-am", "Main"], in: root)
    _ = try await requireAdvancedGit(["switch", "-q", "topic"], in: root)
    var rebaseArguments = ["rebase"]
    if applyBackend { rebaseArguments.append("--apply") }
    rebaseArguments.append("main")
    _ = try await requireAdvancedGit(rebaseArguments, in: root, expectedExit: 1)
    return file
}

private func makeMergeConflict(in root: URL) async throws -> URL {
    _ = try await requireAdvancedGit(["init", "-q", "-b", "main"], in: root)
    _ = try await requireAdvancedGit(["config", "user.name", "Fastra Test"], in: root)
    _ = try await requireAdvancedGit(["config", "user.email", "fastra@example.test"], in: root)
    let file = root.appendingPathComponent("merge.txt")
    try Data("basis\n".utf8).write(to: file)
    _ = try await requireAdvancedGit(["add", "merge.txt"], in: root)
    _ = try await requireAdvancedGit(["commit", "-q", "-m", "Basis"], in: root)
    _ = try await requireAdvancedGit(["switch", "-q", "-c", "topic"], in: root)
    try Data("topic\n".utf8).write(to: file)
    _ = try await requireAdvancedGit(["commit", "-q", "-am", "Topic"], in: root)
    _ = try await requireAdvancedGit(["switch", "-q", "main"], in: root)
    try Data("main\n".utf8).write(to: file)
    _ = try await requireAdvancedGit(["commit", "-q", "-am", "Main"], in: root)
    _ = try await requireAdvancedGit(["merge", "topic"], in: root, expectedExit: 1)
    return file
}

@Suite("Konfliktmarker", .serialized)
struct GitConflictMarkerTests {
    @Test("Git-eigener update-index-Lock koppelt Prüfung und Stage-0-Mutation",
          .timeLimit(.minutes(1)))
    func interactiveUpdateIndexHoldsOfficialLock() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-IndexLock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await requireAdvancedGit(["init", "-q", "-b", "main"], in: root)
        _ = try await requireAdvancedGit(["config", "user.name", "Fastra Test"], in: root)
        _ = try await requireAdvancedGit(["config", "user.email", "fastra@example.test"], in: root)
        let path = "locked.txt"
        let file = root.appendingPathComponent(path)
        try Data("basis\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["add", "--", path], in: root)
        _ = try await requireAdvancedGit(["commit", "-q", "-m", "Basis"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "-c", "topic"], in: root)
        try Data("topic\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Topic"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "main"], in: root)
        try Data("main\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Main"], in: root)
        _ = try await requireAdvancedGit(["merge", "topic"], in: root, expectedExit: 1)
        let resolved = Data("gelöst\n".utf8)
        try resolved.write(to: file)
        let blob = try await requireAdvancedGit(
            ["hash-object", "-w", "--path=\(path)", path], in: root
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let indexPath = try await requireAdvancedGit(
            ["rev-parse", "--path-format=absolute", "--git-path", "index"], in: root
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentRef = try await requireAdvancedGit(
            ["symbolic-ref", "-q", "HEAD"], in: root
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentOID = try await requireAdvancedGit(
            ["rev-parse", "HEAD"], in: root
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let competingOID = try await requireAdvancedGit(
            ["rev-parse", "topic"], in: root
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPath = try await requireAdvancedGit(
            ["rev-parse", "--path-format=absolute", "--git-path", currentRef], in: root
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let worktreeHeadPath = try await requireAdvancedGit(
            ["rev-parse", "--path-format=absolute", "--git-path", "HEAD"], in: root
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let lockPath = indexPath + ".lock"
        let refLockPath = refPath + ".lock"
        let headLockPath = worktreeHeadPath + ".lock"
        let process = Process()
        guard let gitPath = GitRunner.resolvedPath else {
            Issue.record("git ist für den Lock-Test nicht verfügbar")
            return
        }
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["--no-pager", "update-index", "-z", "--index-info"]
        process.currentDirectoryURL = root
        process.environment = GitRunner.sanitizedEnvironment(
            base: ProcessInfo.processInfo.environment
        )
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        for _ in 0..<2_000 where !FileManager.default.fileExists(atPath: lockPath) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(FileManager.default.fileExists(atPath: lockPath))
        let abortWhileLocked = await runAdvancedGit(["merge", "--abort"], in: root)
        guard case .completed(let abortResult) = abortWhileLocked else {
            Issue.record("merge --abort lieferte unter Indexlock kein Git-Ergebnis"); return
        }
        #expect(!abortResult.ok)
        let competingWriter = await runAdvancedGit(["update-index", "--refresh"], in: root)
        guard case .completed(let writerResult) = competingWriter else {
            Issue.record("Zweiter Indexwriter lieferte kein Git-Ergebnis"); return
        }
        #expect(!writerResult.ok)

        let refProcess = Process()
        refProcess.executableURL = URL(fileURLWithPath: gitPath)
        refProcess.arguments = ["--no-pager", "update-ref", "--stdin"]
        refProcess.currentDirectoryURL = root
        refProcess.environment = GitRunner.sanitizedEnvironment(
            base: ProcessInfo.processInfo.environment
        )
        let refInput = Pipe()
        let refOutput = Pipe()
        let refError = Pipe()
        refProcess.standardInput = refInput
        refProcess.standardOutput = refOutput
        refProcess.standardError = refError
        try refProcess.run()
        try refInput.fileHandleForWriting.write(contentsOf: Data(
            "start\nverify \(currentRef) \(currentOID)\nprepare\n".utf8
        ))
        for _ in 0..<2_000 where !FileManager.default.fileExists(atPath: refLockPath) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(FileManager.default.fileExists(atPath: refLockPath))
        let competingRefWriter = await runAdvancedGit(
            ["update-ref", currentRef, competingOID, currentOID], in: root
        )
        guard case .completed(let refWriterResult) = competingRefWriter else {
            Issue.record("Zweiter Ref-Writer lieferte kein Git-Ergebnis"); return
        }
        #expect(!refWriterResult.ok)
        try input.fileHandleForWriting.write(contentsOf:
            Data("100644 \(blob)\t\(path)\0".utf8))
        try input.fileHandleForWriting.close()
        for _ in 0..<5_000 where process.isRunning {
            try await Task.sleep(for: .milliseconds(1))
        }
        if process.isRunning { process.terminate() }
        #expect(process.terminationStatus == 0)
        output.fileHandleForReading.closeFile()
        error.fileHandleForReading.closeFile()
        #expect(!FileManager.default.fileExists(atPath: lockPath))
        try refInput.fileHandleForWriting.write(contentsOf: Data("commit\n".utf8))
        try refInput.fileHandleForWriting.close()
        for _ in 0..<5_000 where refProcess.isRunning {
            try await Task.sleep(for: .milliseconds(1))
        }
        if refProcess.isRunning { refProcess.terminate() }
        #expect(refProcess.terminationStatus == 0)
        refOutput.fileHandleForReading.closeFile()
        refError.fileHandleForReading.closeFile()
        #expect(!FileManager.default.fileExists(atPath: refLockPath))
        #expect(try await requireAdvancedGit(["rev-parse", currentRef], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines) == currentOID)
        let staged = try await requireAdvancedGit(["ls-files", "--stage", "--", path],
                                                  in: root)
        #expect(staged.stdout.contains("100644 \(blob) 0\t\(path)"))
        let operation = try await requireAdvancedGit(GitOperationStateDetector.arguments,
                                                     in: root)
        #expect(GitOperationStateDetector.detect(stdout: operation.stdout,
                                                 repository: root) == .merge)

        // Ein leeres stdin ist der sichere Abbruchpfad: Git verwirft seine temporäre
        // Indexkopie und gibt den offiziellen Lock frei, ohne den Index anzutasten.
        let stagedBeforeCancel = staged.stdout
        let cancelledProcess = Process()
        cancelledProcess.executableURL = URL(fileURLWithPath: gitPath)
        cancelledProcess.arguments = ["--no-pager", "update-index", "-z", "--index-info"]
        cancelledProcess.currentDirectoryURL = root
        cancelledProcess.environment = GitRunner.sanitizedEnvironment(
            base: ProcessInfo.processInfo.environment
        )
        let cancelledInput = Pipe()
        let cancelledOutput = Pipe()
        let cancelledError = Pipe()
        cancelledProcess.standardInput = cancelledInput
        cancelledProcess.standardOutput = cancelledOutput
        cancelledProcess.standardError = cancelledError
        try cancelledProcess.run()
        for _ in 0..<2_000 where !FileManager.default.fileExists(atPath: lockPath) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(FileManager.default.fileExists(atPath: lockPath))
        try cancelledInput.fileHandleForWriting.close()
        for _ in 0..<5_000 where cancelledProcess.isRunning {
            try await Task.sleep(for: .milliseconds(1))
        }
        if cancelledProcess.isRunning { cancelledProcess.terminate() }
        #expect(cancelledProcess.terminationStatus == 0)
        cancelledOutput.fileHandleForReading.closeFile()
        cancelledError.fileHandleForReading.closeFile()
        #expect(!FileManager.default.fileExists(atPath: lockPath))
        let stagedAfterCancel = try await requireAdvancedGit(
            ["ls-files", "--stage", "--", path], in: root
        )
        #expect(stagedAfterCancel.stdout == stagedBeforeCancel)

        var rejectedOutcome: GitExecutionOutcome?
        var rejectedSubmitted = true
        _ = GitRunner.runHoldingIndexLock(
            indexPath: indexPath,
            record: Data("100644 \(blob)\t\(path)\0".utf8),
            headRef: currentRef, headOID: currentOID,
            headRefPath: refPath, headRefNeedsNoDeref: false,
            worktreeHeadPath: worktreeHeadPath,
            headSymbolicTarget: currentRef,
            in: root, verify: { $0(false) }
        ) { outcome, submitted in
            rejectedOutcome = outcome
            rejectedSubmitted = submitted
        }
        try await waitAdvanced("Abgelehnte Lock-Session endete nicht", timeout: .seconds(10)) {
            rejectedOutcome != nil
        }
        guard case .completed(let rejectedResult) = rejectedOutcome else {
            Issue.record("Abgelehnte Lock-Session lieferte kein Git-Ergebnis")
            return
        }
        #expect(rejectedResult.ok)
        #expect(!rejectedSubmitted)
        #expect(!FileManager.default.fileExists(atPath: lockPath))
        #expect(!FileManager.default.fileExists(atPath: refLockPath))
        #expect(!FileManager.default.fileExists(atPath: headLockPath))
        #expect(try await requireAdvancedGit(
            ["ls-files", "--stage", "--", path], in: root
        ).stdout == stagedBeforeCancel)

        var earlyVerifyCalled = false
        var earlyCancelledOutcome: GitExecutionOutcome?
        let earlyTransaction = GitRunner.runHoldingIndexLock(
            indexPath: indexPath,
            record: Data("100644 \(blob)\t\(path)\0".utf8),
            headRef: currentRef, headOID: currentOID,
            headRefPath: refPath, headRefNeedsNoDeref: false,
            worktreeHeadPath: worktreeHeadPath,
            headSymbolicTarget: currentRef,
            in: root, verify: { _ in earlyVerifyCalled = true }
        ) { outcome, _ in earlyCancelledOutcome = outcome }
        earlyTransaction.cancel()
        try await waitAdvanced("Früh abgebrochene Lock-Session endete nicht",
                               timeout: .seconds(10)) {
            earlyCancelledOutcome != nil
        }
        #expect(!earlyVerifyCalled)
        #expect(earlyCancelledOutcome == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: lockPath))
        #expect(!FileManager.default.fileExists(atPath: refLockPath))
        #expect(!FileManager.default.fileExists(atPath: headLockPath))

        var postSubmitBoundaryReached = false
        var postSubmitOutcome: GitExecutionOutcome?
        var postSubmitRecordWritten = false
        var postSubmitTransaction: GitCancelling?
        postSubmitTransaction = GitRunner.runHoldingIndexLock(
            indexPath: indexPath,
            record: Data("100644 \(blob)\t\(path)\0".utf8),
            headRef: currentRef, headOID: currentOID,
            headRefPath: refPath, headRefNeedsNoDeref: false,
            worktreeHeadPath: worktreeHeadPath,
            headSymbolicTarget: currentRef,
            in: root, verify: { $0(true) },
            commitBoundaryReached: {
                postSubmitBoundaryReached = true
                postSubmitTransaction?.cancel()
            }
        ) { outcome, recordWritten in
            postSubmitOutcome = outcome
            postSubmitRecordWritten = recordWritten
        }
        try await waitAdvanced("Nach Submit abgebrochene Lock-Session endete nicht",
                               timeout: .seconds(10)) {
            postSubmitOutcome != nil
        }
        guard case .completed(let postSubmitResult) = postSubmitOutcome else {
            Issue.record("Nach Submit wurde die echte Mutation als Abbruch ausgegeben")
            return
        }
        #expect(postSubmitBoundaryReached)
        #expect(postSubmitRecordWritten)
        #expect(postSubmitResult.ok)
        #expect(!FileManager.default.fileExists(atPath: lockPath))
        #expect(!FileManager.default.fileExists(atPath: refLockPath))
        #expect(!FileManager.default.fileExists(atPath: headLockPath))
        #expect(try await requireAdvancedGit(
            ["ls-files", "--stage", "--", path], in: root
        ).stdout == stagedBeforeCancel)

        var cancelVerifierStarted = false
        var cancelledOutcome: GitExecutionOutcome?
        let transaction = GitRunner.runHoldingIndexLock(
            indexPath: indexPath,
            record: Data("100644 \(blob)\t\(path)\0".utf8),
            headRef: currentRef, headOID: currentOID,
            headRefPath: refPath, headRefNeedsNoDeref: false,
            worktreeHeadPath: worktreeHeadPath,
            headSymbolicTarget: currentRef,
            in: root, verify: { _ in cancelVerifierStarted = true }
        ) { outcome, _ in cancelledOutcome = outcome }
        try await waitAdvanced("Lock-Session erreichte den Verify-Punkt nicht",
                               timeout: .seconds(10)) {
            cancelVerifierStarted
                && FileManager.default.fileExists(atPath: lockPath)
                && FileManager.default.fileExists(atPath: refLockPath)
                && FileManager.default.fileExists(atPath: headLockPath)
        }
        transaction.cancel()
        try await waitAdvanced("Abgebrochene Lock-Session endete nicht",
                               timeout: .seconds(10)) {
            cancelledOutcome != nil
        }
        #expect(cancelledOutcome == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: lockPath))
        #expect(!FileManager.default.fileExists(atPath: refLockPath))
        #expect(!FileManager.default.fileExists(atPath: headLockPath))
        #expect(try await requireAdvancedGit(
            ["ls-files", "--stage", "--", path], in: root
        ).stdout == stagedBeforeCancel)
    }

    @Test("Verify-only-Reftransaktion sperrt auch einen detached HEAD")
    func lockedSessionSupportsDetachedHead() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-DetachedLock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await requireAdvancedGit(["init", "-q", "-b", "main"], in: root)
        _ = try await requireAdvancedGit(["config", "user.name", "Fastra Test"], in: root)
        _ = try await requireAdvancedGit(["config", "user.email", "fastra@example.test"], in: root)
        let path = "detached.txt"
        try Data("inhalt\n".utf8).write(to: root.appendingPathComponent(path))
        _ = try await requireAdvancedGit(["add", "--", path], in: root)
        _ = try await requireAdvancedGit(["commit", "-q", "-m", "Basis"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "--detach", "HEAD"], in: root)
        let oid = try await requireAdvancedGit(["rev-parse", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let blob = try await requireAdvancedGit(["rev-parse", ":\(path)"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = try await requireAdvancedGit([
            "rev-parse", "--path-format=absolute", "--git-path", "index",
            "--git-path", "HEAD"
        ], in: root).stdout.split(whereSeparator: \.isNewline).map(String.init)
        #expect(paths.count == 2)
        var outcome: GitExecutionOutcome?
        var recordWasWritten = true
        _ = GitRunner.runHoldingIndexLock(
            indexPath: paths[0], record: Data("100644 \(blob)\t\(path)\0".utf8),
            headRef: "HEAD", headOID: oid, headRefPath: paths[1],
            headRefNeedsNoDeref: true, worktreeHeadPath: paths[1],
            headSymbolicTarget: nil, in: root, verify: { $0(false) }
        ) { result, written in
            outcome = result
            recordWasWritten = written
        }
        try await waitAdvanced("Detached-HEAD-Transaktion endete nicht",
                               timeout: .seconds(10)) { outcome != nil }
        guard case .completed(let result) = outcome else {
            Issue.record("Detached HEAD ließ sich nicht sicher sperren: \(String(describing: outcome))")
            return
        }
        #expect(result.ok)
        #expect(!recordWasWritten)
        #expect(!FileManager.default.fileExists(atPath: paths[0] + ".lock"))
        #expect(!FileManager.default.fileExists(atPath: paths[1] + ".lock"))
        #expect(try await requireAdvancedGit(["rev-parse", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines) == oid)
    }

    @Test("HEAD-Race vor Prepare scheitert geschlossen und räumt eigene Locks")
    func symbolicHeadRaceBeforePrepareFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-HeadRaceBeforePrepare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await makeMergeConflict(in: root)
        let headRef = try await requireAdvancedGit(["symbolic-ref", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let headOID = try await requireAdvancedGit(["rev-parse", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = try await requireAdvancedGit([
            "rev-parse", "--path-format=absolute", "--git-path", "index",
            "--git-path", headRef, "--git-path", "HEAD"
        ], in: root).stdout.split(whereSeparator: \.isNewline).map(String.init)
        let gitPath = try #require(GitRunner.resolvedPath)
        var verifyCalled = false
        var outcome: GitExecutionOutcome?
        _ = GitRunner.runHoldingIndexLock(
            indexPath: paths[0], record: Data(), headRef: headRef, headOID: headOID,
            headRefPath: paths[1], headRefNeedsNoDeref: false,
            worktreeHeadPath: paths[2], headSymbolicTarget: headRef, in: root,
            verify: { _ in verifyCalled = true },
            refPreparationHook: { phase in
                #expect(phase == .beforeFirst)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: gitPath)
                process.arguments = ["--no-pager", "symbolic-ref", "HEAD",
                                     "refs/heads/topic"]
                process.currentDirectoryURL = root
                try? process.run()
                process.waitUntilExit()
                #expect(process.terminationStatus == 0)
            }
        ) { result, _ in outcome = result }
        try await waitAdvanced("HEAD-Race vor Prepare endete nicht", timeout: .seconds(10)) {
            outcome != nil
        }
        guard case .startFailed = outcome else {
            Issue.record("HEAD-Race vor Prepare wurde nicht fail-closed abgelehnt")
            return
        }
        #expect(!verifyCalled)
        #expect(try await requireAdvancedGit(["symbolic-ref", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "refs/heads/topic")
        #expect(!FileManager.default.fileExists(atPath: paths[0] + ".lock"))
        #expect(!FileManager.default.fileExists(atPath: paths[1] + ".lock"))
        #expect(!FileManager.default.fileExists(atPath: paths[2] + ".lock"))
    }

    @Test("Fremder Branch-Lock bleibt erhalten und verhindert den sicheren Start")
    func preexistingBranchLockFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-PreexistingRefLock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await makeMergeConflict(in: root)
        let headRef = try await requireAdvancedGit(["symbolic-ref", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let headOID = try await requireAdvancedGit(["rev-parse", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = try await requireAdvancedGit([
            "rev-parse", "--path-format=absolute", "--git-path", "index",
            "--git-path", headRef, "--git-path", "HEAD"
        ], in: root).stdout.split(whereSeparator: \.isNewline).map(String.init)
        let foreignLock = paths[1] + ".lock"
        _ = FileManager.default.createFile(atPath: foreignLock,
                                           contents: Data("fremd".utf8))
        var verifyCalled = false
        var outcome: GitExecutionOutcome?
        _ = GitRunner.runHoldingIndexLock(
            indexPath: paths[0], record: Data(), headRef: headRef, headOID: headOID,
            headRefPath: paths[1], headRefNeedsNoDeref: false,
            worktreeHeadPath: paths[2], headSymbolicTarget: headRef, in: root,
            verify: { _ in verifyCalled = true }
        ) { result, _ in outcome = result }
        try await waitAdvanced("Fremder Ref-Lock wurde nicht abgelehnt") { outcome != nil }
        guard case .startFailed = outcome else {
            Issue.record("Fremder Ref-Lock wurde nicht fail-closed gemeldet")
            return
        }
        #expect(!verifyCalled)
        #expect(FileManager.default.fileExists(atPath: foreignLock))
        #expect(!FileManager.default.fileExists(atPath: paths[0] + ".lock"))
        #expect(!FileManager.default.fileExists(atPath: paths[2] + ".lock"))
        try FileManager.default.removeItem(atPath: foreignLock)
    }

    @Test("Abbruch gewinnt deterministisch gegen einen bereits vorhandenen Index-Lock")
    func cancellationWinsPreexistingIndexLockCollision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-CancelIndexCollision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await requireAdvancedGit(["init", "-q", "-b", "main"], in: root)
        let paths = try await requireAdvancedGit([
            "rev-parse", "--path-format=absolute", "--git-path", "index",
            "--git-path", "refs/heads/main", "--git-path", "HEAD"
        ], in: root).stdout.split(whereSeparator: \.isNewline).map(String.init)
        let foreignLock = paths[0] + ".lock"
        _ = FileManager.default.createFile(atPath: foreignLock,
                                           contents: Data("fremd".utf8))
        let entered = AdvancedFlag()
        let release = DispatchSemaphore(value: 0)
        var verifyCalled = false
        var outcome: GitExecutionOutcome?
        let transaction = GitRunner.runHoldingIndexLock(
            indexPath: paths[0], record: Data(), headRef: "refs/heads/main",
            headOID: String(repeating: "0", count: 40), headRefPath: paths[1],
            headRefNeedsNoDeref: false, worktreeHeadPath: paths[2],
            headSymbolicTarget: "refs/heads/main", in: root,
            verify: { _ in verifyCalled = true },
            beforeLockPreflight: {
                entered.set()
                _ = release.wait(timeout: .now() + 5)
            }
        ) { result, _ in outcome = result }
        try await waitAdvanced("Index-Lock-Preflight wurde nicht erreicht") {
            entered.value
        }
        transaction.cancel()
        release.signal()
        try await waitAdvanced("Abbruch/Index-Lock-Kollision endete nicht") {
            outcome != nil
        }
        #expect(outcome == .cancelled)
        #expect(!verifyCalled)
        #expect(FileManager.default.fileExists(atPath: foreignLock))
    }

    @Test("Timeout gewinnt deterministisch gegen einen bereits vorhandenen Ref-Lock")
    func timeoutWinsPreexistingRefLockCollision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-TimeoutRefCollision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await makeMergeConflict(in: root)
        let headRef = try await requireAdvancedGit(["symbolic-ref", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let headOID = try await requireAdvancedGit(["rev-parse", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = try await requireAdvancedGit([
            "rev-parse", "--path-format=absolute", "--git-path", "index",
            "--git-path", headRef, "--git-path", "HEAD"
        ], in: root).stdout.split(whereSeparator: \.isNewline).map(String.init)
        let foreignLock = paths[1] + ".lock"
        _ = FileManager.default.createFile(atPath: foreignLock,
                                           contents: Data("fremd".utf8))
        let entered = AdvancedFlag()
        let release = DispatchSemaphore(value: 0)
        var verifyCalled = false
        var outcome: GitExecutionOutcome?
        _ = GitRunner.runHoldingIndexLock(
            indexPath: paths[0], record: Data(), headRef: headRef, headOID: headOID,
            headRefPath: paths[1], headRefNeedsNoDeref: false,
            worktreeHeadPath: paths[2], headSymbolicTarget: headRef, in: root,
            timeout: 0.05, verify: { _ in verifyCalled = true },
            beforeRefLockPreflight: {
                entered.set()
                _ = release.wait(timeout: .now() + 5)
            }
        ) { result, _ in outcome = result }
        try await waitAdvanced("Ref-Lock-Preflight wurde nicht erreicht",
                               timeout: .seconds(10)) { entered.value }
        try await Task.sleep(for: .milliseconds(100))
        release.signal()
        try await waitAdvanced("Timeout/Ref-Lock-Kollision endete nicht",
                               timeout: .seconds(10)) { outcome != nil }
        #expect(outcome == .timedOut)
        #expect(!verifyCalled)
        #expect(FileManager.default.fileExists(atPath: foreignLock))
        #expect(!FileManager.default.fileExists(atPath: paths[0] + ".lock"))
        #expect(!FileManager.default.fileExists(atPath: paths[2] + ".lock"))
    }

    @Test("Symbolischer Worktree-HEAD bleibt unter derselben Reftransaktion unverändert",
          .timeLimit(.minutes(1)))
    func lockedTransactionProtectsSymbolicWorktreeHead() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-SymbolicHeadLock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await makeMergeConflict(in: root)
        let headRef = try await requireAdvancedGit(["symbolic-ref", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let headOID = try await requireAdvancedGit(["rev-parse", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = try await requireAdvancedGit([
            "rev-parse", "--path-format=absolute", "--git-path", "index",
            "--git-path", headRef, "--git-path", "HEAD"
        ], in: root).stdout.split(whereSeparator: \.isNewline).map(String.init)
        #expect(paths.count == 3)

        var switchOutcome: GitExecutionOutcome?
        var branchOutcome: GitExecutionOutcome?
        var transactionOutcome: GitExecutionOutcome?
        var sawBothRefLocks = false
        _ = GitRunner.runHoldingIndexLock(
            indexPath: paths[0], record: Data(), headRef: headRef, headOID: headOID,
            headRefPath: paths[1], headRefNeedsNoDeref: false,
            worktreeHeadPath: paths[2], headSymbolicTarget: headRef, in: root,
            verify: { approve in
                sawBothRefLocks = FileManager.default.fileExists(atPath: paths[1] + ".lock")
                    && FileManager.default.fileExists(atPath: paths[2] + ".lock")
                Task {
                    switchOutcome = await runAdvancedGit(
                        ["symbolic-ref", "HEAD", "refs/heads/topic"], in: root
                    )
                    branchOutcome = await runAdvancedGit(
                        ["update-ref", headRef, String(repeating: "0", count: 40), headOID],
                        in: root
                    )
                    approve(false)
                }
            }
        ) { outcome, _ in transactionOutcome = outcome }
        try await waitAdvanced("Symbolic-HEAD-Locktest endete nicht", timeout: .seconds(10)) {
            transactionOutcome != nil && switchOutcome != nil && branchOutcome != nil
        }
        guard case .completed(let switchResult) = switchOutcome else {
            Issue.record("Konkurrierender symbolic-ref-Aufruf lieferte kein Git-Ergebnis")
            return
        }
        #expect(sawBothRefLocks)
        #expect(!switchResult.ok)
        guard case .completed(let branchResult) = branchOutcome else {
            Issue.record("Konkurrierender Branch-Writer lieferte kein Git-Ergebnis")
            return
        }
        #expect(!branchResult.ok)
        #expect(try await requireAdvancedGit(["symbolic-ref", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines) == headRef)
        #expect(!FileManager.default.fileExists(atPath: paths[0] + ".lock"))
        #expect(!FileManager.default.fileExists(atPath: paths[1] + ".lock"))
        #expect(!FileManager.default.fileExists(atPath: paths[2] + ".lock"))
    }

    @Test("Hängende Prozesse nach Submit enden bounded mit ungewissem Ergebnis",
          .timeLimit(.minutes(1)))
    func postSubmitDeadlineKillsStoppedProcessGroups() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-PostSubmitDeadline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try await makeMergeConflict(in: root)
        let path = file.lastPathComponent
        let blob = try await requireAdvancedGit(
            ["hash-object", "-w", "--path=\(path)", path], in: root
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let headRef = try await requireAdvancedGit(["symbolic-ref", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let headOID = try await requireAdvancedGit(["rev-parse", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = try await requireAdvancedGit([
            "rev-parse", "--path-format=absolute", "--git-path", "index",
            "--git-path", headRef, "--git-path", "HEAD"
        ], in: root).stdout.split(whereSeparator: \.isNewline).map(String.init)
        var outcome: GitExecutionOutcome?
        var submitted = false
        var stoppedGroups = false
        _ = GitRunner.runHoldingIndexLock(
            indexPath: paths[0], record: Data("100644 \(blob)\t\(path)\0".utf8),
            headRef: headRef, headOID: headOID,
            headRefPath: paths[1], headRefNeedsNoDeref: false,
            worktreeHeadPath: paths[2], headSymbolicTarget: headRef, in: root,
            postSubmitTimeout: 0.2, verify: { $0(true) },
            postSubmitProcessGroups: { processGroups in
                stoppedGroups = processGroups.allSatisfy {
                    Darwin.kill(-$0, SIGSTOP) == 0
                }
            }
        ) { result, wasSubmitted in
            outcome = result
            submitted = wasSubmitted
        }
        try await waitAdvanced("Post-Submit-Deadline endete nicht", timeout: .seconds(10)) {
            outcome != nil
        }
        guard case .captureFailed(let failure) = outcome else {
            Issue.record("Hänger nach Submit wurde nicht als ungewiss gemeldet: \(String(describing: outcome))")
            return
        }
        #expect(stoppedGroups)
        #expect(submitted)
        #expect(failure.stdoutError == L10n.string(
            "Git antwortete nach dem Einreichen der Indexänderung nicht rechtzeitig. Das Ergebnis ist ungewiss; Fastra liest den aktuellen Git-Zustand neu ein."
        ))
        #expect(!FileManager.default.fileExists(atPath: paths[0] + ".lock"))
        #expect(!FileManager.default.fileExists(atPath: paths[1] + ".lock"))
        #expect(!FileManager.default.fileExists(atPath: paths[2] + ".lock"))
        // Der Zustand wird unabhängig neu gelesen; Stage 0 oder die alten
        // Konfliktstufen sind beide möglich, ein stale Lock dagegen nie.
        _ = try await requireAdvancedGit(["ls-files", "--stage", "--", path], in: root)
    }

    @Test("Timeout vor der Prepare-Phase bleibt ein Timeout")
    func timeoutBeforePrepareIsClassified() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-PrePrepareTimeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await requireAdvancedGit(["init", "-q", "-b", "main"], in: root)
        let paths = try await requireAdvancedGit([
            "rev-parse", "--path-format=absolute", "--git-path", "index",
            "--git-path", "refs/heads/main", "--git-path", "HEAD"
        ], in: root).stdout.split(whereSeparator: \.isNewline).map(String.init)
        let zeroOID = String(repeating: "0", count: 40)
        var verifyCalled = false
        var outcome: GitExecutionOutcome?
        _ = GitRunner.runHoldingIndexLock(
            indexPath: paths[0], record: Data(), headRef: "refs/heads/main",
            headOID: zeroOID, headRefPath: paths[1], headRefNeedsNoDeref: false,
            worktreeHeadPath: paths[2], headSymbolicTarget: "refs/heads/main",
            in: root, timeout: 0, verify: { _ in verifyCalled = true }
        ) { result, _ in outcome = result }
        try await waitAdvanced("Früher Lock-Timeout endete nicht", timeout: .seconds(10)) {
            outcome != nil
        }
        #expect(outcome == .timedOut)
        #expect(!verifyCalled)
        #expect(paths.allSatisfy {
            !FileManager.default.fileExists(atPath: $0 + ".lock")
        })
    }

    @Test("Timeout unter Index- und Ref-Lock bleibt von Nutzerabbruch unterscheidbar")
    func lockedTransactionReportsTimeout() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-LockTimeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await makeMergeConflict(in: root)
        let indexPath = try await requireAdvancedGit(
            ["rev-parse", "--path-format=absolute", "--git-path", "index"], in: root
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let headRef = try await requireAdvancedGit(["symbolic-ref", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let headOID = try await requireAdvancedGit(["rev-parse", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPath = try await requireAdvancedGit(
            ["rev-parse", "--path-format=absolute", "--git-path", headRef], in: root
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let headPath = try await requireAdvancedGit(
            ["rev-parse", "--path-format=absolute", "--git-path", "HEAD"], in: root
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var verifyCalled = false
        var outcome: GitExecutionOutcome?
        _ = GitRunner.runHoldingIndexLock(
            indexPath: indexPath, record: Data(), headRef: headRef, headOID: headOID,
            headRefPath: refPath, headRefNeedsNoDeref: false,
            worktreeHeadPath: headPath, headSymbolicTarget: headRef, in: root,
            timeout: 0.2, verify: { _ in verifyCalled = true }
        ) { result, _ in outcome = result }
        try await waitAdvanced("Lock-Timeout endete nicht", timeout: .seconds(10)) {
            outcome != nil
        }
        #expect(verifyCalled)
        #expect(outcome == .timedOut)
        #expect(!FileManager.default.fileExists(atPath: indexPath + ".lock"))
        #expect(!FileManager.default.fileExists(atPath: refPath + ".lock"))
        #expect(!FileManager.default.fileExists(atPath: headPath + ".lock"))
    }

    @Test("Markerbreiten 1, 3 und 32 werden exakt geparst; falsche Breiten und Separator-Suffixe nicht")
    func exactMarkerWidths() {
        for size in [1, 3, 32] {
            let opening = String(repeating: "<", count: size)
            let separator = String(repeating: "=", count: size)
            let closing = String(repeating: ">", count: size)
            let text = "\(opening) ours\noben\n\(separator)\nunten\n\(closing) theirs\n"
            #expect(ConflictMarkerParser.parse(text, markerSize: size).blocks.count == 1)
            #expect(ConflictMarkerParser.parse(text, markerSize: size == 3 ? 7 : 3)
                .blocks.isEmpty)
            #expect(ConflictMarkerParser.containsMarkerLikeLines(text))
            let invalid = "\(opening) ours\noben\n\(separator) suffix\nunten\n\(closing) theirs\n"
            let result = ConflictMarkerParser.parse(invalid, markerSize: size)
            #expect(result.blocks.isEmpty)
            if case .unsafe = result { } else {
                Issue.record("Separator mit Suffix muss als unsicher gelten")
            }
        }
    }

    @Test("Pfadspezifische .gitattributes-Markerbreite entspricht realer Git-Ausgabe")
    func realPathSpecificMarkerWidth() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-MarkerWidth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await requireAdvancedGit(["init", "-q", "-b", "main"], in: root)
        _ = try await requireAdvancedGit(["config", "user.name", "Fastra Test"], in: root)
        _ = try await requireAdvancedGit(["config", "user.email", "fastra@example.test"], in: root)
        try Data("*.txt conflict-marker-size=13\n".utf8)
            .write(to: root.appendingPathComponent(".gitattributes"))
        let file = root.appendingPathComponent("breite.txt")
        try Data("basis\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["add", "--", ".gitattributes", "breite.txt"], in: root)
        _ = try await requireAdvancedGit(["commit", "-q", "-m", "Basis"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "-c", "topic"], in: root)
        try Data("topic\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Topic"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "main"], in: root)
        try Data("main\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Main"], in: root)
        _ = try await requireAdvancedGit(["merge", "topic"], in: root, expectedExit: 1)

        let attr = try await requireAdvancedGit(
            ["check-attr", "-z", "conflict-marker-size", "--", "breite.txt"], in: root)
        #expect(Workspace.parseConflictMarkerSize(attr.stdoutData) == 13)
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.contains(String(repeating: "<", count: 13)))
        #expect(ConflictMarkerParser.parse(contents, markerSize: 13).blocks.count == 1)
        #expect(ConflictMarkerParser.parse(contents, markerSize: 7).blocks.isEmpty)
    }

    @Test("check-attr-Parser verlangt NUL-Rahmen, exakten Pfad und eindeutige Attribute")
    func conflictAttributeParserFailsClosed() throws {
        let path = Data("Ordner/blob.dat".utf8)
        let binary = Data(
            "Ordner/blob.dat\0binary\0set\0Ordner/blob.dat\0diff\0unset\0Ordner/blob.dat\0text\0unset\0".utf8
        )
        let parsed = try #require(GitConflictAttributeParser.parseAll(
            binary, expectedRawPath: path
        ))
        #expect(parsed == GitConflictAttributes(markerSize: 7, isBinary: true))

        let text = Data(
            "Ordner/blob.dat\0text\0set\0Ordner/blob.dat\0conflict-marker-size\013\0".utf8
        )
        #expect(GitConflictAttributeParser.parseAll(text, expectedRawPath: path)
                == GitConflictAttributes(markerSize: 13, isBinary: false))
        #expect(GitConflictAttributeParser.parseAll(Data(), expectedRawPath: path)
                == GitConflictAttributes(markerSize: 7, isBinary: false))
        #expect(GitConflictAttributeParser.parseAll(binary.dropLast(), expectedRawPath: path)
                == nil)
        #expect(GitConflictAttributeParser.parseAll(binary,
                                                     expectedRawPath: Data("anderer.dat".utf8))
                == nil)
        let duplicate = Data("Ordner/blob.dat\0text\0set\0Ordner/blob.dat\0text\0unset\0".utf8)
        #expect(GitConflictAttributeParser.parseAll(duplicate, expectedRawPath: path) == nil)
        let malformedSize = Data("Ordner/blob.dat\0conflict-marker-size\0abc\0".utf8)
        #expect(GitConflictAttributeParser.parseAll(malformedSize,
                                                    expectedRawPath: path) == nil)
        let selectedText = selectedConflictAttributeData(
            path: "Ordner/blob.dat", markerSize: "13"
        )
        #expect(GitConflictAttributeParser.parseSelected(
            selectedText, expectedRawPath: path
        ) == GitConflictAttributes(markerSize: 13, isBinary: false))
        #expect(GitConflictAttributeParser.parseSelected(
            selectedConflictAttributeData(path: "Ordner/blob.dat", binary: true),
            expectedRawPath: path
        )?.isBinary == true)
        #expect(GitConflictAttributeParser.parseSelected(Data(),
                                                         expectedRawPath: path) == nil)
    }

    @Test("Git-Attributklassifikation wertet jede Binärsemantik unabhängig aus")
    func conflictAttributeClassificationMatrix() throws {
        let pathString = "matrix.dat"
        let path = Data(pathString.utf8)

        func records(_ attributes: [(String, String)]) -> Data {
            var data = Data()
            for (attribute, value) in attributes {
                data.append(Data("\(pathString)\0\(attribute)\0\(value)\0".utf8))
            }
            return data
        }

        let cases: [(name: String, attributes: [(String, String)], expected: Bool)] = [
            ("binary gesetzt", [("binary", "set")], true),
            ("text deaktiviert", [("text", "unset")], true),
            ("diff deaktiviert", [("diff", "unset")], true),
            ("merge deaktiviert", [("merge", "unset")], true),
            ("binärer Merge-Treiber", [("merge", "binary")], true),
            ("text gesetzt", [("text", "set")], false),
            ("binary deaktiviert", [("binary", "unset")], false),
            ("eigener Diff-Treiber", [("diff", "word-diff")], false),
            ("eigener Merge-Treiber", [("merge", "ours")], false),
            ("alles unspezifiziert", [
                ("binary", "unspecified"), ("text", "unspecified"),
                ("diff", "unspecified"), ("merge", "unspecified")
            ], false)
        ]

        for value in cases {
            let parsed = try #require(GitConflictAttributeParser.parseAll(
                records(value.attributes), expectedRawPath: path
            ), "Klassifikation fehlt für \(value.name)")
            #expect(parsed.isBinary == value.expected,
                    "Falsche Klassifikation für \(value.name)")
        }
    }

    @Test("Normaler Marker liefert Labels und obere, untere sowie beide Ersetzungen")
    func normalConflictChoices() throws {
        let text = "vor\n<<<<<<< HEAD\noben 🟢\n=======\nunten 🔵\n>>>>>>> topic\nnach\n"
        let block = try #require(ConflictMarkerParser.parse(text).blocks.first)
        #expect(block.upperLabel == "HEAD")
        #expect(block.lowerLabel == "topic")
        #expect(block.baseRange == nil)
        #expect(block.startLine == 2)
        #expect(block.endLine == 6)
        let upper = try #require(ConflictMarkerParser.replacement(in: text, block: block,
                                                                  choice: .upper))
        let lower = try #require(ConflictMarkerParser.replacement(in: text, block: block,
                                                                  choice: .lower))
        let both = try #require(ConflictMarkerParser.replacement(in: text, block: block,
                                                                 choice: .both))
        let ns = text as NSString
        #expect(ns.replacingCharacters(in: upper.range, with: upper.replacement)
                == "vor\noben 🟢\nnach\n")
        #expect(ns.replacingCharacters(in: lower.range, with: lower.replacement)
                == "vor\nunten 🔵\nnach\n")
        #expect(ns.replacingCharacters(in: both.range, with: both.replacement)
                == "vor\noben 🟢\nunten 🔵\nnach\n")
    }

    @Test("diff3-Basis und CRLF bleiben bytegetreu in den ausgewählten Blöcken")
    func diff3AndCRLF() throws {
        let text = "<<<<<<< lokal\r\noben\r\n||||||| basis\r\nalt\r\n=======\r\nunten\r\n>>>>>>> remote\r\n"
        let block = try #require(ConflictMarkerParser.parse(text).blocks.first)
        let base = try #require(block.baseRange)
        #expect((text as NSString).substring(with: base) == "alt\r\n")
        let both = try #require(ConflictMarkerParser.replacement(in: text, block: block,
                                                                 choice: .both))
        #expect(both.replacement == "oben\r\nunten\r\n")
        #expect(block.baseLabel == "basis")
    }

    @Test("Mehrere Konflikte werden stabil neu indiziert und manuelle Bearbeitung zählt")
    func multipleAndManualEdit() throws {
        let one = "<<<<<<< A\na\n=======\nb\n>>>>>>> B\n"
        let original = one + "mitte\n" + one
        let blocks = ConflictMarkerParser.parse(original).blocks
        #expect(blocks.count == 2)
        let second = try #require(blocks.last)
        let replacement = try #require(ConflictMarkerParser.replacement(
            in: original, block: second, choice: .lower))
        let manuallyEdited = (original as NSString).replacingCharacters(
            in: replacement.range, with: replacement.replacement)
        let remaining = ConflictMarkerParser.parse(manuallyEdited).blocks
        #expect(remaining.count == 1)
        #expect(remaining[0].id == 0)
        #expect(ConflictMarkerParser.parse("vollständig manuell gelöst\n").blocks.isEmpty)
    }

    @Test("Unvollständige und verschachtelte Marker werden nicht als sicher behandelt")
    func malformedAndNested() {
        let malformed = "<<<<<<< A\ntext\n=======\nohne Ende\n"
        let nested = "<<<<<<< A\n<<<<<<< X\nx\n=======\ny\n>>>>>>> Y\n=======\nb\n>>>>>>> B\n"
        let validThenStray = "<<<<<<< A\na\n=======\nb\n>>>>>>> B\n=======\n"
        if case .unsafe = ConflictMarkerParser.parse(malformed) { } else {
            Issue.record("Unvollständiger Marker wurde akzeptiert")
        }
        if case .unsafe = ConflictMarkerParser.parse(nested) { } else {
            Issue.record("Verschachtelter Marker wurde akzeptiert")
        }
        if case .unsafe = ConflictMarkerParser.parse(validThenStray) { } else {
            Issue.record("Steuerzeile nach gültigem Block wurde akzeptiert")
        }
        #expect(ConflictMarkerParser.containsPotentialMarkers(malformed))
        #expect(!ConflictMarkerParser.containsPotentialMarkers("x <<<<<<< y\n"))
    }

    @Test("Native CodeEdit-Mutation ist nach oberer, unterer und beiden Übernahmen undo-fähig",
          arguments: [ConflictResolutionChoice.upper, .lower, .both])
    func nativeUndo(choice: ConflictResolutionChoice) throws {
        let text = "<<<<<<< A\noben\n=======\nunten\n>>>>>>> B\n"
        let block = try #require(ConflictMarkerParser.parse(text).blocks.first)
        let replacement = try #require(ConflictMarkerParser.replacement(
            in: text, block: block, choice: choice))
        let (defaults, suite) = makeDefaults("undo")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        let tabID = try #require(workspace.activeTabID)
        var synchronized = ""
        let request = ConflictEditorReplacementRequest(
            workspace: workspace, tabID: tabID, expectedText: text,
            replacement: replacement
        ) { synchronized = $0 }
        let textView = CodeEditTextView.TextView(string: text)
        #expect(ConflictNativeTextMutation.apply(request, to: textView))
        #expect(textView.string == synchronized)
        #expect(textView.string != text)
        #expect(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        #expect(textView.string == text)
        #expect(textView.undoManager?.canRedo == true)
        textView.undoManager?.redo()
        #expect(textView.string == synchronized)
        textView.undoManager?.undo()
        #expect(textView.string == text)
        textView.string = "zwischenzeitlich manuell geändert\n"
        #expect(!ConflictNativeTextMutation.apply(request, to: textView))
        #expect(textView.string == "zwischenzeitlich manuell geändert\n")
    }

    @Test("Binär- und Chunked-Konflikte werden nicht als Textauflösung angeboten")
    func binaryAndLargeAreUnsupported() throws {
        let oldDialogs = Workspace.presentGitDialogs
        Workspace.presentGitDialogs = false
        defer { Workspace.presentGitDialogs = oldDialogs }
        for mode in [EditorDisplayMode.hex, .chunkedText] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("Fastra-BinaryConflict-\(UUID().uuidString)")
            let file = root.appendingPathComponent("binär.dat")
            let (defaults, suite) = makeDefaults("binary")
            defer { defaults.removePersistentDomain(forName: suite) }
            let executor = AdvancedControlledExecutor()
            let workspace = Workspace(
                defaults: defaults,
                gitOperationsCoordinator: GitOperationsCoordinator(executor: executor)
            )
            workspace.projectURL = root
            let tab = EditorTab(title: file.lastPathComponent, path: root.path, url: file,
                                content: "", displayMode: mode)
            workspace.tabs = [tab]
            workspace.activeTabID = tab.id
            workspace.gitStatus = GitStatusSummary(
                branch: "main", isDetached: false, headOID: "abc", upstream: nil,
                ahead: 0, behind: 0, entries: ["binär.dat": .conflicted],
                changes: [GitChange(path: "binär.dat", staged: nil,
                                    unstaged: .conflicted)])
            if case .unsupported(let change, _) = workspace.activeConflictSupport {
                #expect(change.path == "binär.dat")
            } else {
                Issue.record("Nicht-textueller Konflikt wurde nicht ehrlich gesperrt")
            }
            workspace.markActiveConflictResolved()
            #expect(executor.count == 0)
        }
    }

    @Test("Workspace-Konfliktaktion nutzt nativen Editor-Undo/Redo-Pfad")
    func workspaceConflictActionUsesNativeUndoRedo() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-WorkspaceUndo-\(UUID().uuidString)")
        let file = root.appendingPathComponent("undo.txt")
        let text = "<<<<<<< A\noben\n=======\nunten\n>>>>>>> B\n"
        let (defaults, suite) = makeDefaults("workspace-native-undo")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        workspace.projectURL = root
        let tab = EditorTab(title: "undo.txt", path: root.path, url: file,
                            content: text, isDirty: false)
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        workspace.gitStatus = GitStatusSummary(
            branch: "main", isDetached: false, headOID: "abc", upstream: nil,
            ahead: 0, behind: 0, entries: ["undo.txt": .conflicted],
            changes: [GitChange(path: "undo.txt", staged: .conflicted,
                                unstaged: .conflicted)]
        )
        workspace.gitConflictInspections[Data("undo.txt".utf8)] = .text(markerSize: 7)
        let textView = CodeEditTextView.TextView(string: text)
        var applied = false
        workspace.conflictTextReplacementHandler = { request in
            applied = ConflictNativeTextMutation.apply(request, to: textView)
        }
        workspace.acceptActiveConflict(.both)
        #expect(applied)
        #expect(workspace.activeTab?.content == textView.string)
        #expect(workspace.activeTab?.isDirty == true)
        let resolved = textView.string
        textView.undoManager?.undo()
        #expect(textView.string == text)
        textView.undoManager?.redo()
        #expect(textView.string == resolved)
        // Die Modell-Synchronisierung nach Undo/Redo stammt im echten Fenster
        // vom normalen Editor-Delegate. Headless ist hier kein SwiftUI-Fenster
        // aktiv; geprüft sind der reale Workspace-Request und native Undo-Manager.
    }

    @Test("Späte Attributantwort eines alten Tabs überschreibt den aktiven Konflikt nicht")
    func staleConflictAttributeResponseIsIgnored() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-ConflictAttrRace-\(UUID().uuidString)")
        let firstFile = root.appendingPathComponent("eins.txt")
        let secondFile = root.appendingPathComponent("zwei.dat")
        let executor = AdvancedControlledExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let (defaults, suite) = makeDefaults("conflict-attribute-race")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults,
                                  gitOperationsCoordinator: coordinator)
        workspace.projectURL = root
        workspace.gitStatus = GitStatusSummary(
            branch: "main", isDetached: false, headOID: "abc", upstream: nil,
            ahead: 0, behind: 0,
            entries: ["eins.txt": .conflicted, "zwei.dat": .conflicted],
            changes: [
                GitChange(path: "eins.txt", staged: .conflicted, unstaged: .conflicted),
                GitChange(path: "zwei.dat", staged: .conflicted, unstaged: .conflicted)
            ]
        )
        let first = EditorTab(title: "eins.txt", path: root.path, url: firstFile,
                              content: "<<<<<<< A\na\n=======\nb\n>>>>>>> B\n")
        let second = EditorTab(title: "zwei.dat", path: root.path, url: secondFile,
                               content: "gültiges UTF-8 ohne Marker\n")
        workspace.tabs = [first, second]
        workspace.activeTabID = first.id
        workspace.invalidateAndRefreshActiveConflictInspection()
        #expect(executor.count == 1)
        workspace.activeTabID = second.id
        workspace.invalidateAndRefreshActiveConflictInspection()
        #expect(executor.count == 1)
        #expect(executor.cancellations[0])

        executor.complete(0, advancedSuccess(selectedConflictAttributeData(path: "eins.txt")))
        try await waitAdvanced("Attributprüfung des neuen Tabs startete nicht") {
            executor.count == 2
        }
        executor.complete(1, advancedSuccess(selectedConflictAttributeData(
            path: "zwei.dat", binary: true
        )))
        try await waitAdvanced("Aktive Binärattribut-Antwort wurde nicht übernommen") {
            workspace.gitConflictInspections[Data("zwei.dat".utf8)] == .unsupportedBinary
        }
        #expect(workspace.gitConflictInspections[Data("eins.txt".utf8)] == .checking)
        guard case .unsupported = workspace.activeConflictSupport else {
            Issue.record("Späte alte Attributantwort entsperrte den aktiven Binärkonflikt")
            return
        }
    }


    @Test("Als gelöst markieren verlangt zuerst einen gespeicherten Editorstand")
    func resolveRequiresSave() throws {
        let oldDialogs = Workspace.presentGitDialogs
        Workspace.presentGitDialogs = false
        defer { Workspace.presentGitDialogs = oldDialogs }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-Resolve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let relativePath = "Ordner/konflikt 🧪.txt"
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let content = "manuell gelöst\n"
        try Data(content.utf8).write(to: file)

        let executor = AdvancedControlledExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let (defaults, suite) = makeDefaults("resolve")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults, gitOperationsCoordinator: coordinator)
        workspace.projectURL = root
        let tab = EditorTab(title: file.lastPathComponent,
                            path: file.deletingLastPathComponent().path,
                            url: file, content: content, isDirty: true)
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        workspace.gitStatus = GitStatusSummary(
            branch: "main", isDetached: false, headOID: "abcdef", upstream: nil,
            ahead: 0, behind: 0, entries: [relativePath: .conflicted],
            changes: [GitChange(path: relativePath, staged: .conflicted,
                                unstaged: .conflicted)])
        workspace.gitConflictInspections[Data(relativePath.utf8)] = .text(markerSize: 7)

        workspace.markActiveConflictResolved()
        #expect(executor.count == 0)
    }

    @Test("Exact-byte-Staging schreibt genau die geprüften Sonderpfad-Bytes nach Stage 0")
    func exactByteStagingRealRepository() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-ExactStage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await requireAdvancedGit(["init", "-q", "-b", "main"], in: root)
        _ = try await requireAdvancedGit(["config", "user.name", "Fastra Test"], in: root)
        _ = try await requireAdvancedGit(["config", "user.email", "fastra@example.test"], in: root)
        let path = "Ordner/konflikt 🧪.txt"
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("basis\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["add", "--", path], in: root)
        _ = try await requireAdvancedGit(["commit", "-q", "-m", "Basis"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "-c", "topic"], in: root)
        try Data("topic\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Topic"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "main"], in: root)
        try Data("main\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Main"], in: root)
        _ = try await requireAdvancedGit(["merge", "topic"], in: root, expectedExit: 1)

        let exact = Data("gelöst ohne Abschluss-LF 🧪".utf8)
        try exact.write(to: file)
        let coordinator = GitOperationsCoordinator(executor: GitRunnerExecutor())
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: file.path)
        var modeOutcome: GitValidatedMutationOutcome?
        _ = GitConflictStagingRunner.run(
            repository: root, rawPath: Data(path.utf8), path: path,
            fileURL: file, expectedData: exact,
            expectedText: String(decoding: exact, as: UTF8.self),
            coordinator: coordinator, validate: { _ in nil },
            decision: { _, _, proceed in proceed(true) }
        ) { modeOutcome = $0 }
        try await waitAdvanced("Mode-Abweichung wurde nicht geprüft", timeout: .seconds(10)) {
            modeOutcome != nil
        }
        guard case .blocked(let modeReason) = modeOutcome else {
            Issue.record("Executable-Bit hätte blockiert werden müssen: \(String(describing: modeOutcome))")
            return
        }
        #expect(modeReason == L10n.string(
            "Das Ausführbar-Bit der Konfliktdatei weicht von den Konfliktstufen ab. Fastra staged diese Mode-Änderung nicht still; gleiche den Dateimodus zuerst bewusst ab."
        ))
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: file.path)
        var outcome: GitValidatedMutationOutcome?
        _ = GitConflictStagingRunner.run(
            repository: root, rawPath: Data(path.utf8), path: path,
            fileURL: file, expectedData: exact,
            expectedText: String(decoding: exact, as: UTF8.self),
            coordinator: coordinator, validate: { inspection in
                inspection.hasUnmergedChanges ? nil : "Konflikt fehlt"
            }, decision: { _, hasMarkers, proceed in proceed(!hasMarkers) }
        ) { outcome = $0 }
        try await waitAdvanced("Exact-byte-Staging endete nicht", timeout: .seconds(10)) {
            outcome != nil
        }
        guard case .executed(.completed(let result)) = outcome else {
            Issue.record("Unerwartetes Staging-Ergebnis: \(String(describing: outcome))")
            return
        }
        #expect(result.ok)
        let staged = try await requireAdvancedGit(["show", ":\(path)"], in: root)
        #expect(staged.stdoutData == exact)
        let unmerged = try await requireAdvancedGit(["ls-files", "-u", "--", path], in: root)
        #expect(unmerged.stdoutData.isEmpty)
    }

    @Test("Pfadspezifische EOL-, Working-Tree-Encoding- und Clean-Konvertierung entspricht git add")
    func stagingMatchesRealGitAddConversion() async throws {
        let cases: [(name: String, attributes: String, bytes: Data, config: [[String]])] = [
            ("eol", "*.txt text eol=lf\n", Data("alpha\r\nbeta\r\n".utf8), []),
            ("encoding", "*.txt text working-tree-encoding=UTF-16LE\n",
             try #require("alpha\nbeta\n".data(using: .utf16LittleEndian)), []),
            ("clean", "*.txt filter=fastra-upper\n", Data("alpha beta\n".utf8), [
                ["config", "filter.fastra-upper.clean", "/usr/bin/tr a-z A-Z"],
                ["config", "filter.fastra-upper.required", "true"]
             ])
        ]
        for value in cases {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("Fastra-Conversion-\(value.name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try await requireAdvancedGit(["init", "-q", "-b", "main"], in: root)
            _ = try await requireAdvancedGit(["config", "user.name", "Fastra Test"], in: root)
            _ = try await requireAdvancedGit(["config", "user.email", "fastra@example.test"], in: root)
            let targetPath = "conflict.txt"
            let referencePath = "reference.txt"
            let target = root.appendingPathComponent(targetPath)
            let reference = root.appendingPathComponent(referencePath)
            try Data("basis\n".utf8).write(to: target)
            _ = try await requireAdvancedGit(["add", "--", targetPath], in: root)
            _ = try await requireAdvancedGit(["commit", "-q", "-m", "Basis"], in: root)
            _ = try await requireAdvancedGit(["switch", "-q", "-c", "topic"], in: root)
            try Data("topic\n".utf8).write(to: target)
            _ = try await requireAdvancedGit(["commit", "-q", "-am", "Topic"], in: root)
            _ = try await requireAdvancedGit(["switch", "-q", "main"], in: root)
            try Data("main\n".utf8).write(to: target)
            _ = try await requireAdvancedGit(["commit", "-q", "-am", "Main"], in: root)
            _ = try await requireAdvancedGit(["merge", "topic"], in: root, expectedExit: 1)

            try Data(value.attributes.utf8)
                .write(to: root.appendingPathComponent(".gitattributes"))
            for command in value.config { _ = try await requireAdvancedGit(command, in: root) }
            try value.bytes.write(to: target)
            try value.bytes.write(to: reference)
            _ = try await requireAdvancedGit(["add", "--", referencePath], in: root)
            let expectedBlob = try await requireAdvancedGit(
                ["rev-parse", ":\(referencePath)"], in: root
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            var outcome: GitValidatedMutationOutcome?
            let coordinator = GitOperationsCoordinator(executor: GitRunnerExecutor())
            _ = GitConflictStagingRunner.run(
                repository: root, rawPath: Data(targetPath.utf8), path: targetPath,
                fileURL: target, expectedData: value.bytes,
                expectedText: "bewusst gelöst", coordinator: coordinator,
                validate: { inspection in
                        inspection.hasUnmergedChanges ? nil : "Konflikt fehlt"
                    }, decision: { _, _, proceed in proceed(true) }
            ) { outcome = $0 }
            try await waitAdvanced("Konvertiertes Staging \(value.name) endete nicht",
                                   timeout: .seconds(15)) {
                outcome != nil
            }
            guard case .executed(.completed(let result)) = outcome else {
                Issue.record("Konvertiertes Staging wurde nicht ausgeführt: \(String(describing: outcome))")
                continue
            }
            #expect(result.ok)
            let stagedBlob = try await requireAdvancedGit(
                ["rev-parse", ":\(targetPath)"], in: root
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(stagedBlob == expectedBlob)
            #expect(try Data(contentsOf: target) == value.bytes)
            #expect(try Data(contentsOf: reference) == value.bytes)
        }
    }

    @Test("Absichtlich verbleibende Marker brauchen eine bewusste Ausnahme")
    func intentionalMarkersNeedConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-Markers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("beispiel.txt")
        let content = "<<<<<<< ist hier Dokumentation\n"
        try Data(content.utf8).write(to: file)
        let executor = AdvancedControlledExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let (defaults, suite) = makeDefaults("markers")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults, gitOperationsCoordinator: coordinator)
        workspace.projectURL = root
        let tab = EditorTab(title: file.lastPathComponent, path: root.path,
                            url: file, content: content)
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        workspace.gitStatus = GitStatusSummary(
            branch: "main", isDetached: false, headOID: "abcdef", upstream: nil,
            ahead: 0, behind: 0, entries: ["beispiel.txt": .conflicted],
            changes: [GitChange(path: "beispiel.txt", staged: .conflicted,
                                unstaged: .conflicted)])
        workspace.gitConflictInspections[Data("beispiel.txt".utf8)] = .text(markerSize: 7)
        var askedForPath: String?
        workspace.confirmIntentionalConflictMarkersHandler = { path in
            askedForPath = path
            return false
        }
        workspace.markActiveConflictResolved()
        #expect(executor.arguments[0] == GitStatusParser.arguments)
        executor.complete(0, advancedSuccess(statusData(conflictPath: "beispiel.txt")))
        executor.complete(1, absentOperationPaths(in: root))
        try await waitAdvanced("Attributprüfung fehlt") { executor.count >= 3 }
        let attribute = selectedConflictAttributeData(path: "beispiel.txt")
        executor.complete(2, advancedSuccess(attribute))
        try await waitAdvanced("Vollständige Attributprüfung fehlt") { executor.count >= 4 }
        executor.complete(3, advancedSuccess())
        try await waitAdvanced("Konvertierungskonfiguration fehlt") { executor.count >= 5 }
        executor.complete(4, advancedFailure(code: 1))
        try await waitAdvanced("Indexprüfung fehlt") { executor.count >= 6 }
        let oid = String(repeating: "a", count: 40)
        let stages = [1, 2, 3].map { "100644 \(oid) \($0)\tbeispiel.txt\0" }
            .joined()
        executor.complete(5, advancedSuccess(Data(stages.utf8)))
        try await waitAdvanced("Filemode-Prüfung fehlt") { executor.count >= 7 }
        executor.complete(6, advancedSuccess(Data("false\n".utf8)))
        try await waitAdvanced("Index- und Refpfad-Prüfung fehlt") { executor.count >= 8 }
        let paths = "\(root.path)/.git/index\n\(root.path)/.git/refs/heads/main\n\(root.path)/.git/HEAD\n"
        executor.complete(7, advancedSuccess(Data(paths.utf8)))
        try await waitAdvanced("Markerbestätigung fehlt") { askedForPath != nil }
        #expect(askedForPath == "beispiel.txt")
        #expect(executor.count == 8)
    }

    @Test("Echte Merge- und Rebase-Konflikte werden aus Git und Markern erkannt")
    func realMergeAndRebaseConflict() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-RealConflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await requireAdvancedGit(["init", "-q", "-b", "main"], in: root)
        _ = try await requireAdvancedGit(["config", "user.name", "Fastra Test"], in: root)
        _ = try await requireAdvancedGit(["config", "user.email", "fastra@example.test"], in: root)
        let file = root.appendingPathComponent("konflikt-ä.txt")
        try Data("basis\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["add", "--", file.lastPathComponent], in: root)
        _ = try await requireAdvancedGit(["commit", "-q", "-m", "Basis"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "-c", "topic"], in: root)
        try Data("topic\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Topic"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "main"], in: root)
        try Data("main\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Main"], in: root)

        _ = try await requireAdvancedGit(["merge", "topic"], in: root, expectedExit: 1)
        let mergeStatus = try await requireAdvancedGit(GitStatusParser.arguments, in: root)
        #expect(GitStatusParser.parse(mergeStatus.stdoutData).changes.contains {
            $0.path == file.lastPathComponent && $0.unstaged == .conflicted
        })
        let mergeMarkers = try String(contentsOf: file, encoding: .utf8)
        #expect(ConflictMarkerParser.parse(mergeMarkers).blocks.count == 1)
        let markerResult = try await requireAdvancedGit(GitOperationStateDetector.arguments,
                                                        in: root)
        #expect(GitOperationStateDetector.detect(stdout: markerResult.stdout,
                                                 repository: root) == .merge)

        let mergeStatusSummary = GitStatusParser.parse(mergeStatus.stdoutData)
        let mergeChange = try #require(mergeStatusSummary.changes.first {
            $0.staged == .conflicted || $0.unstaged == .conflicted
        })
        let coordinator = GitOperationsCoordinator(executor: GitRunnerExecutor())
        let (defaults, suite) = makeDefaults("real-text-conflict-inspection")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults,
                                  gitOperationsCoordinator: coordinator)
        workspace.projectURL = root
        workspace.gitStatus = mergeStatusSummary
        let tab = EditorTab(title: file.lastPathComponent, path: root.path,
                            url: file, content: mergeMarkers, displayMode: .text)
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        workspace.invalidateAndRefreshActiveConflictInspection()
        try await waitAdvanced("Normaler Textkonflikt wurde nicht klassifiziert",
                               timeout: .seconds(10)) {
            guard let inspection = workspace.gitConflictInspections[mergeChange.rawPath]
            else { return false }
            return inspection != .checking
        }
        #expect(workspace.gitConflictInspections[mergeChange.rawPath]
                == .text(markerSize: 7))
        guard case .text(_, let inspectedBlocks) = workspace.activeConflictSupport else {
            Issue.record("Normaler Git-Textkonflikt blieb nach Attributprüfung gesperrt")
            return
        }
        #expect(inspectedBlocks.count == 1)

        _ = try await requireAdvancedGit(["merge", "--abort"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "topic"], in: root)
        _ = try await requireAdvancedGit(["rebase", "main"], in: root, expectedExit: 1)
        let rebaseMarkers = try String(contentsOf: file, encoding: .utf8)
        #expect(ConflictMarkerParser.parse(rebaseMarkers).blocks.count == 1)
        let rebaseState = try await requireAdvancedGit(GitOperationStateDetector.arguments,
                                                       in: root)
        #expect(GitOperationStateDetector.detect(stdout: rebaseState.stdout,
                                                 repository: root) == .rebase)
    }

    @Test("Reales diff3 liefert mehrere Blöcke über mehrere Konfliktdateien")
    func realDiff3MultipleFilesAndBlocks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-Diff3Multiple-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await requireAdvancedGit(["init", "-q", "-b", "main"], in: root)
        _ = try await requireAdvancedGit(["config", "user.name", "Fastra Test"], in: root)
        _ = try await requireAdvancedGit(["config", "user.email", "fastra@example.test"], in: root)
        _ = try await requireAdvancedGit(["config", "merge.conflictStyle", "diff3"], in: root)
        let first = root.appendingPathComponent("mehrfach.txt")
        let second = root.appendingPathComponent("zweite.txt")
        let baseLines = (0..<32).map { "Zeile \($0)" }
        try Data((baseLines.joined(separator: "\n") + "\n").utf8).write(to: first)
        try Data("Anfang\nBasis\nEnde\n".utf8).write(to: second)
        _ = try await requireAdvancedGit(["add", "--all"], in: root)
        _ = try await requireAdvancedGit(["commit", "-q", "-m", "Basis"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "-c", "topic"], in: root)
        var topicLines = baseLines
        topicLines[2] = "Topic früh"
        topicLines[27] = "Topic spät"
        try Data((topicLines.joined(separator: "\n") + "\n").utf8).write(to: first)
        try Data("Anfang\nTopic\nEnde\n".utf8).write(to: second)
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Topic"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "main"], in: root)
        var mainLines = baseLines
        mainLines[2] = "Main früh"
        mainLines[27] = "Main spät"
        try Data((mainLines.joined(separator: "\n") + "\n").utf8).write(to: first)
        try Data("Anfang\nMain\nEnde\n".utf8).write(to: second)
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Main"], in: root)
        _ = try await requireAdvancedGit(["merge", "topic"], in: root, expectedExit: 1)

        let status = GitStatusParser.parse(try await requireAdvancedGit(
            GitStatusParser.arguments, in: root
        ).stdoutData)
        #expect(status.changes.filter {
            $0.staged == .conflicted || $0.unstaged == .conflicted
        }.count == 2)
        let firstBlocks = ConflictMarkerParser.parse(
            try String(contentsOf: first, encoding: .utf8)
        ).blocks
        let secondBlocks = ConflictMarkerParser.parse(
            try String(contentsOf: second, encoding: .utf8)
        ).blocks
        #expect(firstBlocks.count == 2)
        #expect(secondBlocks.count == 1)
        #expect((firstBlocks + secondBlocks).allSatisfy { $0.baseRange != nil })
    }

    @Test("Linked Worktree bestätigt verbleibende Marker bewusst und staged exakt Stage 0",
          .timeLimit(.minutes(1)))
    func linkedWorktreeIntentionalMarkersReachStageZero() async throws {
        let primary = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-LinkedPrimary-\(UUID().uuidString)")
        let linked = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-LinkedWorktree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        defer {
            _ = try? FileManager.default.removeItem(at: linked)
            _ = try? FileManager.default.removeItem(at: primary)
        }
        _ = try await requireAdvancedGit(["init", "-q", "-b", "main"], in: primary)
        _ = try await requireAdvancedGit(["config", "user.name", "Fastra Test"], in: primary)
        _ = try await requireAdvancedGit(["config", "user.email", "fastra@example.test"], in: primary)
        let primaryFile = primary.appendingPathComponent("linked.txt")
        try Data("basis\n".utf8).write(to: primaryFile)
        _ = try await requireAdvancedGit(["add", "linked.txt"], in: primary)
        _ = try await requireAdvancedGit(["commit", "-q", "-m", "Basis"], in: primary)
        _ = try await requireAdvancedGit(["switch", "-q", "-c", "topic"], in: primary)
        try Data("topic\n".utf8).write(to: primaryFile)
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Topic"], in: primary)
        _ = try await requireAdvancedGit(["switch", "-q", "main"], in: primary)
        try Data("main\n".utf8).write(to: primaryFile)
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Main"], in: primary)
        _ = try await requireAdvancedGit(
            ["worktree", "add", "-q", "-b", "linked", linked.path, "main"], in: primary
        )
        _ = try await requireAdvancedGit(["merge", "topic"], in: linked, expectedExit: 1)
        let file = linked.appendingPathComponent("linked.txt")
        let data = try Data(contentsOf: file)
        let text = try #require(String(data: data, encoding: .utf8))
        let status = GitStatusParser.parse(try await requireAdvancedGit(
            GitStatusParser.arguments, in: linked
        ).stdoutData)
        let change = try #require(status.changes.first { $0.path == "linked.txt" })
        let coordinator = GitOperationsCoordinator(executor: GitRunnerExecutor())
        var sawMarkers = false
        var outcome: GitValidatedMutationOutcome?
        _ = GitConflictStagingRunner.run(
            repository: linked, rawPath: change.rawPath, path: "linked.txt",
            fileURL: file, expectedData: data, expectedText: text,
            coordinator: coordinator,
            validate: { inspection in
                inspection.operation == .merge && inspection.hasUnmergedChanges
                    ? nil : "Merge-Konflikt fehlt"
            },
            decision: { _, hasMarkers, proceed in
                sawMarkers = hasMarkers
                proceed(true)
            }
        ) { outcome = $0 }
        try await waitAdvanced("Linked-Worktree-Staging endete nicht", timeout: .seconds(15)) {
            outcome != nil
        }
        guard case .executed(.completed(let result)) = outcome else {
            Issue.record("Linked-Worktree-Staging wurde nicht ausgeführt: \(String(describing: outcome))")
            return
        }
        #expect(result.ok)
        #expect(sawMarkers)
        #expect(try await requireAdvancedGit(["ls-files", "-u", "--", "linked.txt"],
                                             in: linked).stdout.isEmpty)
        let staged = try await requireAdvancedGit(
            ["ls-files", "--stage", "--", "linked.txt"], in: linked
        )
        #expect(staged.stdout.contains(" 0\tlinked.txt"))
        let stagedBlob = staged.stdout.split(whereSeparator: \.isWhitespace).dropFirst().first
        let expectedBlob = try await requireAdvancedGit(
            ["hash-object", "--path=linked.txt", "linked.txt"], in: linked
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(stagedBlob.map(String.init) == expectedBlob)
    }

    @Test("Realer Binärkonflikt bleibt unverändert und bietet nur die sichere Hilfe an")
    func realBinaryConflictIsUnsupported() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-RealBinaryConflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await requireAdvancedGit(["init", "-q", "-b", "main"], in: root)
        _ = try await requireAdvancedGit(["config", "user.name", "Fastra Test"], in: root)
        _ = try await requireAdvancedGit(["config", "user.email", "fastra@example.test"], in: root)
        let file = root.appendingPathComponent("binary.dat")
        try Data([0, 1, 10]).write(to: file)
        _ = try await requireAdvancedGit(["add", "binary.dat"], in: root)
        _ = try await requireAdvancedGit(["commit", "-q", "-m", "Basis"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "-c", "topic"], in: root)
        try Data([0, 2, 10]).write(to: file)
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Topic"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "main"], in: root)
        let mainBytes = Data([0, 3, 10])
        try mainBytes.write(to: file)
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Main"], in: root)
        _ = try await requireAdvancedGit(["merge", "topic"], in: root, expectedExit: 1)
        let status = GitStatusParser.parse(try await requireAdvancedGit(
            GitStatusParser.arguments, in: root
        ).stdoutData)
        let (defaults, suite) = makeDefaults("real-binary-help")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        workspace.projectURL = root
        workspace.gitStatus = status
        let tab = EditorTab(title: "binary.dat", path: root.path, url: file,
                            content: "00 03 0a", displayMode: .hex)
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        guard case .unsupported(_, let reason) = workspace.activeConflictSupport else {
            Issue.record("Realer Binärkonflikt wurde als Textauflösung angeboten")
            return
        }
        #expect(reason == L10n.string("Dieser Konflikt ist binär oder nicht sicher als Text dekodierbar. Fastra wählt keine Seite automatisch."))
        #expect(try Data(contentsOf: file) == mainBytes)
    }

    @Test("Git-Attribut binary sperrt auch UTF-8-Inhalt, Textaktionen und Stage 0",
          .timeLimit(.minutes(1)))
    func attributedTextualBinaryConflictIsUnsupported() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-AttributedBinary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await requireAdvancedGit(["init", "-q", "-b", "main"], in: root)
        _ = try await requireAdvancedGit(["config", "user.name", "Fastra Test"], in: root)
        _ = try await requireAdvancedGit(["config", "user.email", "fastra@example.test"], in: root)
        let path = "blob.dat"
        let rawPath = Data(path.utf8)
        let file = root.appendingPathComponent(path)
        try Data("*.dat binary\n".utf8)
            .write(to: root.appendingPathComponent(".gitattributes"))
        try Data("basis\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["add", "--", ".gitattributes", path], in: root)
        _ = try await requireAdvancedGit(["commit", "-q", "-m", "Basis"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "-c", "topic"], in: root)
        try Data("topic, aber gültiges UTF-8\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Topic"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "main"], in: root)
        let mainBytes = Data("main, ebenfalls gültiges UTF-8\n".utf8)
        try mainBytes.write(to: file)
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Main"], in: root)
        let merge = try await requireAdvancedGit(["merge", "topic"], in: root,
                                                  expectedExit: 1)
        #expect((merge.stdout + merge.stderr).lowercased().contains("binary"))
        #expect(String(data: try Data(contentsOf: file), encoding: .utf8) != nil)

        let attrResult = try await requireAdvancedGit(
            ["check-attr", "-z", "--all", "--", path], in: root
        )
        let attributes = try #require(GitConflictAttributeParser.parseAll(
            attrResult.stdoutData, expectedRawPath: rawPath
        ))
        #expect(attributes.isBinary)

        let status = GitStatusParser.parse(try await requireAdvancedGit(
            GitStatusParser.arguments, in: root
        ).stdoutData)
        let coordinator = GitOperationsCoordinator(executor: GitRunnerExecutor())
        let (defaults, suite) = makeDefaults("attributed-binary")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults,
                                  gitOperationsCoordinator: coordinator)
        workspace.projectURL = root
        workspace.gitStatus = status
        let content = try #require(String(data: mainBytes, encoding: .utf8))
        let tab = EditorTab(title: path, path: root.path, url: file,
                            content: content, displayMode: .text, isDirty: false)
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        workspace.invalidateAndRefreshActiveConflictInspection()
        try await waitAdvanced("Binärattribut-Prüfung endete nicht",
                               timeout: .seconds(10)) {
            workspace.gitConflictInspections[rawPath] == .unsupportedBinary
        }
        guard case .unsupported(_, let reason) = workspace.activeConflictSupport else {
            Issue.record("Git-attributierter Binärkonflikt bot Textauflösung an")
            return
        }
        #expect(reason == L10n.string(
            "Git klassifiziert diesen Konflikt über Dateiattribute als binär. Fastra bietet keine Textauflösung oder Stage-Aktion an. Öffne ein Terminal für die Git-Auflösung."
        ))

        let oldDialogs = Workspace.presentGitDialogs
        Workspace.presentGitDialogs = false
        defer { Workspace.presentGitDialogs = oldDialogs }
        workspace.acceptActiveConflict(.upper)
        workspace.markActiveConflictResolved()
        #expect(try Data(contentsOf: file) == mainBytes)
        #expect(!(try await requireAdvancedGit(["ls-files", "-u", "--", path], in: root))
            .stdoutData.isEmpty)
        #expect(!GitOperationControlAvailability.continueEnabled(
            isBusy: false, hasConflicts: true
        ))

        var decisionWasShown = false
        var stageOutcome: GitValidatedMutationOutcome?
        _ = GitConflictStagingRunner.run(
            repository: root, rawPath: rawPath, path: path, fileURL: file,
            expectedData: mainBytes, expectedText: content,
            coordinator: coordinator, validate: { _ in nil },
            decision: { _, _, proceed in
                decisionWasShown = true
                proceed(true)
            }
        ) { stageOutcome = $0 }
        try await waitAdvanced("Binärattribut-Staging endete nicht",
                               timeout: .seconds(10)) { stageOutcome != nil }
        guard case .blocked(let stageReason) = stageOutcome else {
            Issue.record("Git-attributierter Binärkonflikt erreichte Stage 0")
            return
        }
        #expect(stageReason == reason)
        #expect(!decisionWasShown)
        #expect(try Data(contentsOf: file) == mainBytes)
        #expect(!(try await requireAdvancedGit(["ls-files", "-u", "--", path], in: root))
            .stdoutData.isEmpty)
    }

    @Test("merge=binary sperrt gültigen UTF-8-Konflikt ohne binary-Makro",
          .timeLimit(.minutes(1)))
    func binaryMergeDriverBlocksDirectStaging() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-BinaryMergeDriver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await requireAdvancedGit(["init", "-q", "-b", "main"], in: root)
        _ = try await requireAdvancedGit(["config", "user.name", "Fastra Test"], in: root)
        _ = try await requireAdvancedGit(["config", "user.email", "fastra@example.test"], in: root)
        let path = "driver.dat"
        let rawPath = Data(path.utf8)
        let file = root.appendingPathComponent(path)
        try Data("*.dat merge=binary\n".utf8)
            .write(to: root.appendingPathComponent(".gitattributes"))
        try Data("basis\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["add", "--", ".gitattributes", path], in: root)
        _ = try await requireAdvancedGit(["commit", "-q", "-m", "Basis"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "-c", "topic"], in: root)
        try Data("topic bleibt gültiges UTF-8\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Topic"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "main"], in: root)
        try Data("main bleibt gültiges UTF-8\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Main"], in: root)
        _ = try await requireAdvancedGit(["merge", "topic"], in: root, expectedExit: 1)

        let bytesBefore = try Data(contentsOf: file)
        let text = try #require(String(data: bytesBefore, encoding: .utf8))
        let indexBefore = try await requireAdvancedGit(
            ["ls-files", "-s", "-z", "--", path], in: root
        ).stdoutData
        #expect(!indexBefore.isEmpty)
        let attrResult = try await requireAdvancedGit(
            ["check-attr", "-z", "--all", "--", path], in: root
        )
        let attributes = try #require(GitConflictAttributeParser.parseAll(
            attrResult.stdoutData, expectedRawPath: rawPath
        ))
        #expect(attributes.isBinary)

        let coordinator = GitOperationsCoordinator(executor: GitRunnerExecutor())
        var decisionWasShown = false
        var outcome: GitValidatedMutationOutcome?
        _ = GitConflictStagingRunner.run(
            repository: root, rawPath: rawPath, path: path, fileURL: file,
            expectedData: bytesBefore, expectedText: text,
            coordinator: coordinator, validate: { _ in nil },
            decision: { _, _, proceed in
                decisionWasShown = true
                proceed(true)
            }
        ) { outcome = $0 }
        try await waitAdvanced("merge=binary-Staging endete nicht",
                               timeout: .seconds(10)) { outcome != nil }
        guard case .blocked(let reason) = outcome else {
            Issue.record("merge=binary erreichte trotz Git-Klassifikation Stage 0")
            return
        }
        #expect(reason == L10n.string(
            "Git klassifiziert diesen Konflikt über Dateiattribute als binär. Fastra bietet keine Textauflösung oder Stage-Aktion an. Öffne ein Terminal für die Git-Auflösung."
        ))
        #expect(!decisionWasShown)
        #expect(try Data(contentsOf: file) == bytesBefore)
        let indexAfter = try await requireAdvancedGit(
            ["ls-files", "-s", "-z", "--", path], in: root
        ).stdoutData
        #expect(indexAfter == indexBefore)
    }
}

@Suite("Sichere Git-Mutationen", .serialized)
struct GitValidatedMutationTests {
    @Test("Abbruch und Mutationsschutz entscheiden atomar; genau der erste gewinnt")
    func cancellationGateHasOneAtomicWinner() {
        var cancellationDecision: GitOperationCancellationGate.CancellationDecision?
        var cancellationFirstGate: GitOperationCancellationGate!
        cancellationFirstGate = GitOperationCancellationGate {
            cancellationDecision = cancellationFirstGate.requestCancellation()
        }

        #expect(!cancellationFirstGate.beginProtection())
        #expect(cancellationDecision == .won)
        #expect(cancellationFirstGate.requestCancellation() == .alreadyRequested)

        let protectionFirstGate = GitOperationCancellationGate()
        #expect(protectionFirstGate.beginProtection())
        #expect(protectionFirstGate.requestCancellation() == .protected)
        #expect(protectionFirstGate.beginProtection())
    }

    @Test("Tracked-only Stash blockiert den unversionierten No-op, Include-Untracked erlaubt ihn")
    func trackedOnlyStashNoOpIsBlocked() {
        let status = GitStatusParser.parse(statusData(untrackedPath: "nur-neu.txt"))
        let inspection = GitSafetyInspection(status: status, operation: nil)
        #expect(GitAdvancedActionSafety.stashBlockReason(
            inspection, includeUntracked: false
        ) != nil)
        #expect(GitAdvancedActionSafety.stashBlockReason(
            inspection, includeUntracked: true
        ) == nil)
    }

    @Test("Branch ab Commit bleibt bei Dirty-Worktree gesperrt; Bestätigung nutzt frischen Branch")
    func branchAtCommitSafetyAndFreshText() {
        let dirty = GitSafetyInspection(
            status: GitStatusParser.parse(statusData(
                branch: "frisch/topic", modifiedPath: "offen.txt"
            )), operation: nil
        )
        #expect(GitAdvancedActionSafety.branchCreationBlockReason(dirty) != nil)
        let clean = GitSafetyInspection(
            status: GitStatusParser.parse(statusData(branch: "frisch/topic")),
            operation: nil
        )
        #expect(GitAdvancedActionSafety.branchCreationBlockReason(clean) == nil)
        let commit = GitCommit(hash: "abcdef123456", parents: [], author: "Ada",
                               date: "2026-07-16", refs: [], subject: "Sicher")
        let confirmation = GitAdvancedActionSafety.selectedCommitConfirmation(
            commit: commit, command: "revert", action: .revert, inspection: clean
        )
        #expect(confirmation.explanation.contains("frisch/topic"))
    }

    @Test("Graph-Mutationen sind bei Busy aus; schneller Doppelaufruf startet nur eine Prüfung")
    func graphBusyAndDuplicateMutation() {
        #expect(GitGraphActionAvailability.mutationEnabled(isBusy: false))
        #expect(!GitGraphActionAvailability.mutationEnabled(isBusy: true))
        let executor = AdvancedControlledExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let (defaults, suite) = makeDefaults("graph-double")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults,
                                  gitOperationsCoordinator: coordinator)
        workspace.projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-GraphDouble-\(UUID().uuidString)")
        let commit = GitCommit(hash: "abcdef123456", parents: [], author: "Ada",
                               date: "2026-07-16", refs: [], subject: "Sicher")
        workspace.gitLog = [commit]
        workspace.gitCherryPick(commitHash: commit.hash)
        workspace.gitCherryPick(commitHash: commit.hash)
        #expect(executor.count == 1)
        #expect(executor.arguments[0] == GitStatusParser.arguments)
    }

    @Test("Konfliktdateiwechsel setzt auch bei gleicher Blockzahl zurück; Tooltips benennen Guards")
    func conflictFileSwitchAndOperationTooltips() {
        let (defaults, suite) = makeDefaults("conflict-tab-event")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        let first = EditorTab(title: "eins.txt", path: "/tmp", content: "eins")
        let normal = EditorTab(title: "normal.txt", path: "/tmp", content: "normal")
        let third = EditorTab(title: "drei.txt", path: "/tmp", content: "drei")
        workspace.tabs = [first, normal, third]
        workspace.activeTabID = first.id
        workspace.activeConflictIndex = 4
        workspace.activeTabID = normal.id
        workspace.activeGitConflictFileDidChange()
        #expect(workspace.activeConflictIndex == 0)
        workspace.activeConflictIndex = 3
        workspace.activeTabID = third.id
        workspace.activeGitConflictFileDidChange()
        #expect(workspace.activeConflictIndex == 0)
        #expect(GitOperationControlText.continueHelp(hasConflicts: true)
            == L10n.string("Löse und markiere zuerst alle Konfliktdateien als gelöst."))
        #expect(GitOperationControlText.continueHelp(hasConflicts: false)
            == L10n.string("Prüft Zustand, Identität und vorbereitete Commit-Nachricht erneut und setzt erst nach Bestätigung fort."))
        #expect(GitOperationControlText.abortHelp()
            == L10n.string("Stellt den Zustand vor dem erkannten Git-Vorgang wieder her; Fastra prüft den Vorgang erneut und fragt vorher nach."))
        #expect(GitOperationControlText.continueHelp(hasConflicts: false, isBusy: true)
            == L10n.string("Warte, bis der laufende Git-Befehl beendet ist."))
        #expect(!GitOperationControlAvailability.continueEnabled(
            isBusy: true, hasConflicts: false))
        #expect(!GitOperationControlAvailability.continueEnabled(
            isBusy: false, hasConflicts: true))
        #expect(GitOperationControlAvailability.continueEnabled(
            isBusy: false, hasConflicts: false))
        #expect(!GitOperationControlAvailability.abortEnabled(isBusy: true))
        #expect(GitOperationControlAvailability.abortEnabled(isBusy: false))
        #expect(!GitOperationControlAvailability.resolvedEnabled(
            isBusy: true, isDirty: false))
        #expect(!GitOperationControlAvailability.resolvedEnabled(
            isBusy: false, isDirty: true))
        #expect(!GitOperationControlAvailability.resolvedEnabled(
            isBusy: false, isDirty: nil))
        #expect(GitOperationControlAvailability.resolvedEnabled(
            isBusy: false, isDirty: false))
    }

    @Test("Busy-Guard blockiert Branch- und Commit-Einstiege auch hinter der UI")
    func busyGuardBlocksBranchAndCommitEntryPoints() {
        let executor = AdvancedControlledExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let (defaults, suite) = makeDefaults("busy-entry-points")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults,
                                  gitOperationsCoordinator: coordinator)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-BusyEntry-\(UUID().uuidString)")
        workspace.projectURL = root
        workspace.gitBranches = [GitBranch(name: "main", isCurrent: true),
                                 GitBranch(name: "topic", isCurrent: false)]
        _ = coordinator.perform(GitOperationRequest(
            repository: root, kind: .workingTreeMutation,
            arguments: ["test-running-mutation"]
        )) { _ in }
        #expect(workspace.gitOperationsAreBusy)
        #expect(executor.count == 1)

        workspace.gitSwitchPrevious()
        workspace.gitSwitchBranch("topic")
        workspace.gitCommit(message: "Soll nicht starten")
        workspace.gitAmendNoEdit()
        workspace.gitCommitAll()
        #expect(executor.count == 1)
    }

    @Test("Bestätigung, zweite identische Prüfung und Mutation teilen einen Slot")
    func revalidatesThenMutates() async throws {
        let executor = AdvancedControlledExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-Validated-\(UUID().uuidString)")
        var outcome: GitValidatedMutationOutcome?
        _ = GitValidatedMutationRunner.run(
            repository: root, kind: .workingTreeMutation, identity: "test",
            arguments: ["stash", "push"], coordinator: coordinator,
            validate: { $0.operation == nil ? nil : "blocked" },
            decision: { _, proceed in proceed(true) }
        ) { outcome = $0 }

        #expect(executor.arguments == [GitStatusParser.arguments])
        executor.complete(0, advancedSuccess(statusData()))
        #expect(executor.arguments[1] == GitOperationStateDetector.arguments)
        executor.complete(1, absentOperationPaths(in: root))
        try await waitAdvanced("Zweite Statusprüfung fehlt") { executor.count >= 3 }
        executor.complete(2, advancedSuccess(statusData()))
        executor.complete(3, absentOperationPaths(in: root))
        try await waitAdvanced("Mutation fehlt") { executor.count >= 5 }
        #expect(executor.arguments[4] == ["stash", "push"])
        executor.complete(4, advancedSuccess())
        try await waitAdvanced("Mutationsergebnis fehlt") { outcome != nil }
        #expect(outcome == .executed(advancedSuccess()))
    }

    @Test("Ablehnung startet weder zweite Prüfung noch Mutation")
    func cancellationPath() async throws {
        let executor = AdvancedControlledExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-Cancel-\(UUID().uuidString)")
        var outcome: GitValidatedMutationOutcome?
        _ = GitValidatedMutationRunner.run(
            repository: root, kind: .push, identity: "cancel",
            arguments: ["push", "noop"],
            coordinator: coordinator, validate: { _ in nil },
            decision: { _, proceed in proceed(false) }
        ) { outcome = $0 }
        executor.complete(0, advancedSuccess(statusData()))
        executor.complete(1, absentOperationPaths(in: root))
        try await waitAdvanced("Abbruchergebnis fehlt") { outcome != nil }
        #expect(outcome == .cancelled)
        #expect(!executor.arguments.contains(["push", "noop"]))
    }

    @Test("Branchwechsel zwischen Prüfung und Aktion bricht vor Mutation ab")
    func changedRepositoryBlocks() async throws {
        let executor = AdvancedControlledExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-Changed-\(UUID().uuidString)")
        var outcome: GitValidatedMutationOutcome?
        _ = GitValidatedMutationRunner.run(
            repository: root, kind: .workingTreeMutation, identity: "changed",
            arguments: ["revert", "abc"], coordinator: coordinator,
            validate: { _ in nil }, decision: { _, proceed in proceed(true) }
        ) { outcome = $0 }
        executor.complete(0, advancedSuccess(statusData(branch: "main")))
        executor.complete(1, absentOperationPaths(in: root))
        try await waitAdvanced("Zweite Prüfung fehlt") { executor.count >= 3 }
        executor.complete(2, advancedSuccess(statusData(branch: "topic")))
        executor.complete(3, absentOperationPaths(in: root))
        try await waitAdvanced("Changed-Ergebnis fehlt") { outcome != nil }
        #expect(outcome == .repositoryChanged)
        #expect(executor.count == 4)
    }

    @Test("Alle erweiterten Befehle bleiben getrennte sichere Argumentarrays")
    func commandPlans() {
        #expect(GitAdvancedArguments.createBranch(name: "feature/ä space", commit: "abc")
                == ["switch", "-c", "feature/ä space", "abc"])
        #expect(GitAdvancedArguments.stash(includeUntracked: false)
                == ["stash", "push"])
        #expect(GitAdvancedArguments.stash(includeUntracked: true)
                == ["stash", "push", "--include-untracked", "--", "."])
        #expect(GitAdvancedArguments.stashPop == ["stash", "pop"])
        #expect(GitAdvancedArguments.cherryPick("abc") == ["cherry-pick", "abc"])
        #expect(GitAdvancedArguments.revert("abc") == ["revert", "--no-edit", "abc"])
        #expect(GitAdvancedArguments.operation(.merge, action: .continue)
                == ["merge", "--continue"])
        #expect(GitAdvancedArguments.operation(.merge, action: .abort)
                == ["merge", "--abort"])
        #expect(GitAdvancedArguments.operation(.rebase, action: .continue)
                == ["rebase", "--continue"])
        #expect(GitAdvancedArguments.operation(.rebase, action: .abort)
                == ["rebase", "--abort"])
        #expect(GitAdvancedArguments.operation(.rebase, action: .skip)
                == ["rebase", "--skip"])
    }

    @Test("Reale App-Pfade erstellen Branch, stashen, poppen, cherry-picken und reverten",
          .timeLimit(.minutes(1)))
    func realWorkspaceMutationMatrix() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-AppMutationMatrix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await requireAdvancedGit(["init", "-q", "-b", "main"], in: root)
        _ = try await requireAdvancedGit(["config", "user.name", "Fastra Test"], in: root)
        _ = try await requireAdvancedGit(
            ["config", "user.email", "fastra@example.test"], in: root
        )
        let tracked = root.appendingPathComponent("tracked.txt")
        try Data("Basis\n".utf8).write(to: tracked)
        _ = try await requireAdvancedGit(["add", "tracked.txt"], in: root)
        _ = try await requireAdvancedGit(["commit", "-q", "-m", "Basis"], in: root)
        _ = try await requireAdvancedGit(["switch", "-q", "-c", "donor"], in: root)
        try Data("Donor\n".utf8).write(to: root.appendingPathComponent("donor.txt"))
        _ = try await requireAdvancedGit(["add", "donor.txt"], in: root)
        _ = try await requireAdvancedGit(["commit", "-q", "-m", "Donor-Commit"], in: root)
        let donorOID = try await requireAdvancedGit(["rev-parse", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await requireAdvancedGit(["switch", "-q", "main"], in: root)

        let coordinator = GitOperationsCoordinator(executor: GitRunnerExecutor())
        let (defaults, suite) = makeDefaults("real-app-matrix")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults,
                                  gitOperationsCoordinator: coordinator)
        workspace.projectURL = root
        workspace.gitMutationConfirmationHandler = { _ in true }
        workspace.gitBranchNamePromptHandler = { _ in "feature/app-matrix" }

        func updateStatus() async throws {
            let result = try await requireAdvancedGit(GitStatusParser.arguments, in: root)
            workspace.gitStatus = GitStatusParser.parse(result.stdoutData)
        }
        func waitForSuccess(_ description: String, expected: String) async throws {
            try await waitAdvanced(description, timeout: .seconds(15)) {
                workspace.gitFeedback?.message == expected
            }
            workspace.gitFeedback = nil
            try await waitAdvanced("Refresh nach \(description) endete nicht",
                                   timeout: .seconds(15)) {
                !coordinator.state(for: root).isBusy
            }
        }

        try await updateStatus()
        workspace.gitCreateBranch()
        try await waitForSuccess(
            "Branch-App-Pfad endete nicht",
            expected: GitActionText.newBranch.localizedSuccess("feature/app-matrix")
        )
        #expect(try await requireAdvancedGit(["branch", "--show-current"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            == "feature/app-matrix")

        try Data("Geändert\n".utf8).write(to: tracked)
        let untracked = root.appendingPathComponent("untracked.txt")
        try Data("Unversioniert\n".utf8).write(to: untracked)
        try await updateStatus()
        workspace.gitStash(includeUntracked: true)
        try await waitForSuccess(
            "Stash-App-Pfad endete nicht",
            expected: GitActionText.stash.localizedSuccess()
        )
        let afterStash = try await requireAdvancedGit(["status", "--porcelain"], in: root)
        #expect(afterStash.stdout.isEmpty,
                "Arbeitsbaum nach Stash nicht sauber: \(afterStash.stdout)")
        #expect(try await requireAdvancedGit(["stash", "list"], in: root)
            .stdout.contains("stash@{0}"))

        try await updateStatus()
        workspace.gitStashPop()
        try await waitForSuccess(
            "Stash-Pop-App-Pfad endete nicht",
            expected: GitActionText.stashPop.localizedSuccess()
        )
        #expect(try String(contentsOf: tracked, encoding: .utf8) == "Geändert\n")
        #expect(try String(contentsOf: untracked, encoding: .utf8) == "Unversioniert\n")
        #expect(try await requireAdvancedGit(["stash", "list"], in: root).stdout.isEmpty)

        _ = try await requireAdvancedGit(["add", "--all"], in: root)
        _ = try await requireAdvancedGit(
            ["commit", "-q", "-m", "Arbeitsstand nach Stash"], in: root
        )
        try await updateStatus()
        workspace.gitLog = [GitCommit(
            hash: donorOID, parents: [], author: "Fastra Test", date: "",
            refs: [], subject: "Donor-Commit"
        )]
        workspace.gitCherryPick(commitHash: donorOID)
        try await waitForSuccess(
            "Cherry-pick-App-Pfad endete nicht",
            expected: GitActionText.cherryPick.localizedSuccess()
        )
        #expect(try String(contentsOf: root.appendingPathComponent("donor.txt"),
                           encoding: .utf8) == "Donor\n")
        let pickedOID = try await requireAdvancedGit(["rev-parse", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        try await updateStatus()
        workspace.gitLog = [GitCommit(
            hash: pickedOID, parents: [], author: "Fastra Test", date: "",
            refs: [], subject: "Donor-Commit"
        )]
        workspace.gitRevert(commitHash: pickedOID)
        try await waitForSuccess(
            "Revert-App-Pfad endete nicht",
            expected: GitActionText.revert.localizedSuccess()
        )
        #expect(!FileManager.default.fileExists(atPath:
            root.appendingPathComponent("donor.txt").path))
        let finalSubject = try await requireAdvancedGit(
            ["log", "-1", "--format=%s"], in: root
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(finalSubject.contains("Revert"))
    }

    @Test("Reale Workspace-Aktionen setzen Merge fort und brechen Merge ab",
          .timeLimit(.minutes(1)))
    func realWorkspaceMergeContinueAndAbort() async throws {
        let continueRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-MergeContinue-\(UUID().uuidString)")
        let abortRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-MergeAbort-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: continueRoot,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: abortRoot,
                                                withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: continueRoot)
            try? FileManager.default.removeItem(at: abortRoot)
        }

        let continueFile = try await makeMergeConflict(in: continueRoot)
        try Data("bewusst zusammengeführt\n".utf8).write(to: continueFile)
        _ = try await requireAdvancedGit(["add", "merge.txt"], in: continueRoot)
        let continueStatus = try await requireAdvancedGit(
            GitStatusParser.arguments, in: continueRoot
        )
        let continueCoordinator = GitOperationsCoordinator(executor: GitRunnerExecutor())
        let (continueDefaults, continueSuite) = makeDefaults("merge-continue")
        defer { continueDefaults.removePersistentDomain(forName: continueSuite) }
        let continueWorkspace = Workspace(
            defaults: continueDefaults, gitOperationsCoordinator: continueCoordinator
        )
        continueWorkspace.projectURL = continueRoot
        continueWorkspace.gitStatus = GitStatusParser.parse(continueStatus.stdoutData)
        continueWorkspace.gitOperationState = .merge
        var continueConfirmation: GitMutationConfirmation?
        continueWorkspace.gitMutationConfirmationHandler = {
            continueConfirmation = $0
            return true
        }
        continueWorkspace.gitContinueOperation()
        try await waitAdvanced("Merge-Continue-App-Pfad endete nicht", timeout: .seconds(15)) {
            !FileManager.default.fileExists(atPath:
                continueRoot.appendingPathComponent(".git/MERGE_HEAD").path)
        }
        #expect(continueConfirmation?.explanation.contains("Merge branch 'topic'") == true)
        let parents = try await requireAdvancedGit(
            ["rev-list", "--parents", "-1", "HEAD"], in: continueRoot
        ).stdout.split(whereSeparator: \.isWhitespace)
        #expect(parents.count == 3)
        #expect(try String(contentsOf: continueFile, encoding: .utf8)
                == "bewusst zusammengeführt\n")

        let abortFile = try await makeMergeConflict(in: abortRoot)
        let abortStatus = try await requireAdvancedGit(
            GitStatusParser.arguments, in: abortRoot
        )
        let abortCoordinator = GitOperationsCoordinator(executor: GitRunnerExecutor())
        let (abortDefaults, abortSuite) = makeDefaults("merge-abort")
        defer { abortDefaults.removePersistentDomain(forName: abortSuite) }
        let abortWorkspace = Workspace(
            defaults: abortDefaults, gitOperationsCoordinator: abortCoordinator
        )
        abortWorkspace.projectURL = abortRoot
        abortWorkspace.gitStatus = GitStatusParser.parse(abortStatus.stdoutData)
        abortWorkspace.gitOperationState = .merge
        abortWorkspace.gitMutationConfirmationHandler = { _ in true }
        abortWorkspace.gitAbortOperation()
        try await waitAdvanced("Merge-Abort-App-Pfad endete nicht", timeout: .seconds(15)) {
            !FileManager.default.fileExists(atPath:
                abortRoot.appendingPathComponent(".git/MERGE_HEAD").path)
        }
        #expect(try String(contentsOf: abortFile, encoding: .utf8) == "main\n")
        let abortSubject = try await requireAdvancedGit(
            ["log", "-1", "--format=%s"], in: abortRoot
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(abortSubject == "Main")
    }

    @Test("Continue erlaubt nur das unveränderte Git-Message-Fenster; Standard lehnt Editor ab")
    func editorPolicies() {
        let rejected = GitRunner.sanitizedEnvironment(base: [:])
        let accepted = GitRunner.sanitizedEnvironment(base: [:],
                                                       editorPolicy: .acceptExistingMessage)
        #expect(rejected["GIT_EDITOR"] == "/usr/bin/false")
        #expect(rejected["GIT_SEQUENCE_EDITOR"] == "/usr/bin/false")
        #expect(accepted["GIT_EDITOR"] == "/usr/bin/true")
        #expect(accepted["GIT_SEQUENCE_EDITOR"] == "/usr/bin/true")
        #expect(accepted["GIT_TERMINAL_PROMPT"] == "0")
    }

    @Test("Normaler Rebase-Pick zeigt die unveränderte Nachricht und wird nichtinteraktiv fortgesetzt")
    func realRebasePickContinue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-RebaseContinue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try await makeRebaseConflict(in: root)
        try Data("bewusst gelöst\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["add", "--", "rebase.txt"], in: root)
        let statusResult = try await requireAdvancedGit(GitStatusParser.arguments, in: root)
        let coordinator = GitOperationsCoordinator(executor: GitRunnerExecutor())
        let (defaults, suite) = makeDefaults("rebase-continue")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults,
                                  gitOperationsCoordinator: coordinator)
        workspace.projectURL = root
        workspace.gitStatus = GitStatusParser.parse(statusResult.stdoutData)
        workspace.gitOperationState = .rebase
        var shown: GitMutationConfirmation?
        workspace.gitMutationConfirmationHandler = { confirmation in
            shown = confirmation
            return true
        }
        workspace.gitContinueOperation()
        let marker = root.appendingPathComponent(".git/rebase-merge")
        try await waitAdvanced("Rebase wurde nicht fortgesetzt", timeout: .seconds(15)) {
            !FileManager.default.fileExists(atPath: marker.path)
        }
        #expect(shown?.explanation.contains("Topic-Nachricht") == true)
        let subject = try await requireAdvancedGit(["log", "-1", "--format=%s"], in: root)
        #expect(subject.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "Topic-Nachricht")
    }

    @Test("Rebase-Apply liest final-commit und setzt einen normalen Pick nichtinteraktiv fort")
    func realRebaseApplyContinue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-RebaseApplyContinue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try await makeRebaseConflict(in: root, applyBackend: true)
        #expect(FileManager.default.fileExists(atPath:
            root.appendingPathComponent(".git/rebase-apply/final-commit").path))
        try Data("bewusst gelöst\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["add", "--", "rebase.txt"], in: root)
        let statusResult = try await requireAdvancedGit(GitStatusParser.arguments, in: root)
        let coordinator = GitOperationsCoordinator(executor: GitRunnerExecutor())
        let (defaults, suite) = makeDefaults("rebase-apply-continue")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults,
                                  gitOperationsCoordinator: coordinator)
        workspace.projectURL = root
        workspace.gitStatus = GitStatusParser.parse(statusResult.stdoutData)
        workspace.gitOperationState = .rebase
        var shown: GitMutationConfirmation?
        workspace.gitMutationConfirmationHandler = { confirmation in
            shown = confirmation
            return true
        }
        workspace.gitContinueOperation()
        let marker = root.appendingPathComponent(".git/rebase-apply")
        try await waitAdvanced("Apply-Rebase wurde nicht fortgesetzt", timeout: .seconds(15)) {
            !FileManager.default.fileExists(atPath: marker.path)
        }
        #expect(shown?.explanation.contains("Topic-Nachricht") == true)
        let subject = try await requireAdvancedGit(["log", "-1", "--format=%s"], in: root)
        #expect(subject.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "Topic-Nachricht")
    }

    @Test("Rebase-Apply Skip zeigt den frisch geprüften Commit-Betreff und lässt ihn aus")
    func realRebaseApplySkip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-RebaseApplySkip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await makeRebaseConflict(in: root, applyBackend: true)
        let statusResult = try await requireAdvancedGit(GitStatusParser.arguments, in: root)
        let coordinator = GitOperationsCoordinator(executor: GitRunnerExecutor())
        let (defaults, suite) = makeDefaults("rebase-apply-skip")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults,
                                  gitOperationsCoordinator: coordinator)
        workspace.projectURL = root
        workspace.gitStatus = GitStatusParser.parse(statusResult.stdoutData)
        workspace.gitOperationState = .rebase
        var shown: GitMutationConfirmation?
        workspace.gitMutationConfirmationHandler = { confirmation in
            shown = confirmation
            return true
        }
        workspace.gitSkipRebase()
        try await waitAdvanced("Apply-Rebase-Skip endete nicht", timeout: .seconds(15)) {
            !FileManager.default.fileExists(atPath:
                root.appendingPathComponent(".git/rebase-apply").path)
        }
        #expect(shown?.title.contains("Topic-Nachricht") == true)
        #expect(shown?.explanation.contains("Topic-Nachricht") == true)
        let subjects = try await requireAdvancedGit(["log", "-2", "--format=%s"], in: root)
        #expect(!subjects.stdout.contains("Topic-Nachricht"))
    }

    @Test("Rebase-Apply Abort stellt den Zustand vor dem Rebase wieder her")
    func realRebaseApplyAbort() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-RebaseApplyAbort-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try await makeRebaseConflict(in: root, applyBackend: true)
        let statusResult = try await requireAdvancedGit(GitStatusParser.arguments, in: root)
        let coordinator = GitOperationsCoordinator(executor: GitRunnerExecutor())
        let (defaults, suite) = makeDefaults("rebase-apply-abort")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults,
                                  gitOperationsCoordinator: coordinator)
        workspace.projectURL = root
        workspace.gitStatus = GitStatusParser.parse(statusResult.stdoutData)
        workspace.gitOperationState = .rebase
        workspace.gitMutationConfirmationHandler = { _ in true }
        workspace.gitAbortOperation()
        try await waitAdvanced("Apply-Rebase-Abort endete nicht", timeout: .seconds(15)) {
            !FileManager.default.fileExists(atPath:
                root.appendingPathComponent(".git/rebase-apply").path)
        }
        let subject = try await requireAdvancedGit(["log", "-1", "--format=%s"], in: root)
        #expect(subject.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "Topic-Nachricht")
        #expect(try String(contentsOf: file, encoding: .utf8) == "topic\n")
    }

    @Test("Edit-Rebase bleibt im Terminalpfad und startet kein automatisches Continue")
    func editRebaseRequiresTerminal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-RebaseEdit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try await makeRebaseConflict(in: root)
        try Data("bewusst gelöst\n".utf8).write(to: file)
        _ = try await requireAdvancedGit(["add", "--", "rebase.txt"], in: root)
        let done = root.appendingPathComponent(".git/rebase-merge/done")
        let originalDone = try String(contentsOf: done, encoding: .utf8)
        try originalDone.replacingOccurrences(of: "pick ", with: "edit ")
            .write(to: done, atomically: true, encoding: .utf8)
        let statusResult = try await requireAdvancedGit(GitStatusParser.arguments, in: root)
        let coordinator = GitOperationsCoordinator(executor: GitRunnerExecutor())
        let (defaults, suite) = makeDefaults("rebase-edit")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults,
                                  gitOperationsCoordinator: coordinator)
        workspace.projectURL = root
        workspace.gitStatus = GitStatusParser.parse(statusResult.stdoutData)
        workspace.gitOperationState = .rebase
        var confirmationWasShown = false
        workspace.gitMutationConfirmationHandler = { _ in
            confirmationWasShown = true
            return true
        }
        let oldDialogs = Workspace.presentGitDialogs
        Workspace.presentGitDialogs = false
        defer { Workspace.presentGitDialogs = oldDialogs }
        workspace.gitContinueOperation()
        try await waitAdvanced("Edit-Rebase-Prüfung endete nicht", timeout: .seconds(10)) {
            !coordinator.state(for: root).isBusy
        }
        #expect(FileManager.default.fileExists(atPath:
            root.appendingPathComponent(".git/rebase-merge").path))
        #expect(!confirmationWasShown)
    }

    @Test("Force Push löst trotz Push-Konfig exakt Upstream-Remote, Ref und Lease-OID auf")
    func forcePushResolvesExactConfiguredTarget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-ForceLease-\(UUID().uuidString)")
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-ForceRemote-\(UUID().uuidString).git")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: remote)
        }
        _ = try await requireAdvancedGit(["init", "-q", "--bare", remote.path], in: root)
        _ = try await requireAdvancedGit(["init", "-q", "-b", "feature/sicher"], in: root)
        _ = try await requireAdvancedGit(["config", "user.name", "Fastra Test"], in: root)
        _ = try await requireAdvancedGit(["config", "user.email", "fastra@example.test"], in: root)
        try Data("eins\n".utf8).write(to: root.appendingPathComponent("datei.txt"))
        _ = try await requireAdvancedGit(["add", "datei.txt"], in: root)
        _ = try await requireAdvancedGit(["commit", "-q", "-m", "Basis"], in: root)
        _ = try await requireAdvancedGit(["remote", "add", "origin", remote.path], in: root)
        _ = try await requireAdvancedGit(["push", "-q", "-u", "origin", "HEAD"], in: root)
        _ = try await requireAdvancedGit(["config", "push.default", "nothing"], in: root)
        _ = try await requireAdvancedGit(["config", "remote.pushDefault", "anderes"], in: root)
        _ = try await requireAdvancedGit(["config", "branch.feature/sicher.pushRemote", "anderes"], in: root)
        _ = try await requireAdvancedGit(["config", "--add", "remote.origin.push", "refs/heads/falsch:refs/heads/falsch"], in: root)
        let expected = try await requireAdvancedGit(
            ["rev-parse", "refs/remotes/origin/feature/sicher"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialSource = try await requireAdvancedGit(["rev-parse", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        var target: GitForcePushTarget?
        var outcome: GitValidatedMutationOutcome?
        let coordinator = GitOperationsCoordinator(executor: GitRunnerExecutor())
        _ = GitForcePushRunner.run(repository: root, coordinator: coordinator,
                                   decision: { value, proceed in
            target = value; proceed(false)
        }) { outcome = $0 }
        try await waitAdvanced("Force-Ziel wurde nicht aufgelöst", timeout: .seconds(10)) {
            outcome != nil
        }
        #expect(outcome == .cancelled)
        #expect(target?.remote == "origin")
        #expect(target?.remoteRef == "refs/heads/feature/sicher")
        #expect(target?.expectedOID == expected)
        #expect(target?.sourceOID == initialSource)
        #expect(target?.arguments == [
            "push", "--force-with-lease=refs/heads/feature/sicher:\(expected)",
            "--", "origin", "\(initialSource):refs/heads/feature/sicher"
        ])

        try Data("zwei\n".utf8).write(to: root.appendingPathComponent("datei.txt"))
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Lokal zwei"], in: root)
        outcome = nil
        _ = GitForcePushRunner.run(repository: root, coordinator: coordinator,
                                   decision: { _, proceed in proceed(true) }) {
            outcome = $0
        }
        try await waitAdvanced("Exakter Lease-Push endete nicht", timeout: .seconds(15)) {
            outcome != nil
        }
        guard case .executed(.completed(let pushed)) = outcome else {
            Issue.record("Lease-Push wurde nicht ausgeführt"); return
        }
        #expect(pushed.ok)
        let localHead = try await requireAdvancedGit(["rev-parse", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteHead = try await requireAdvancedGit(
            ["--git-dir", remote.path, "rev-parse", "refs/heads/feature/sicher"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(remoteHead == localHead)

        try Data("drei\n".utf8).write(to: root.appendingPathComponent("datei.txt"))
        _ = try await requireAdvancedGit(["commit", "-q", "-am", "Lokal drei"], in: root)
        let foreign = try await requireAdvancedGit(
            ["commit-tree", "HEAD^{tree}", "-p", "refs/remotes/origin/feature/sicher",
             "-m", "Fremder Remote-Commit"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await requireAdvancedGit(
            ["push", "-q", "origin", "\(foreign):refs/heads/lease-fixture"], in: root)
        outcome = nil
        _ = GitForcePushRunner.run(repository: root, coordinator: coordinator,
                                   decision: { _, proceed in
            Task {
                _ = try? await requireAdvancedGit(
                    ["--git-dir", remote.path, "update-ref",
                     "refs/heads/feature/sicher", foreign], in: root)
                proceed(true)
            }
        }) { outcome = $0 }
        try await waitAdvanced("Stale-Lease-Push endete nicht", timeout: .seconds(15)) {
            outcome != nil
        }
        guard case .executed(.completed(let staleResult)) = outcome else {
            Issue.record("Stale-Lease-Test führte keinen Push aus"); return
        }
        #expect(!staleResult.ok)
        let protectedRemote = try await requireAdvancedGit(
            ["--git-dir", remote.path, "rev-parse", "refs/heads/feature/sicher"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(protectedRemote == foreign)

        // Selbst ein Checkout nach dem Dialog ändert nie still die Quelle:
        // Die zweite Auflösung erkennt den Wechsel, und argv enthält ohnehin
        // eine feste Commit-OID statt des beweglichen Namens HEAD.
        _ = try await requireAdvancedGit(["branch", "anderer-branch", "HEAD~1"], in: root)
        outcome = nil
        _ = GitForcePushRunner.run(repository: root, coordinator: coordinator,
                                   decision: { _, proceed in
            Task {
                _ = try? await requireAdvancedGit(["switch", "-q", "anderer-branch"],
                                                  in: root)
                proceed(true)
            }
        }) { outcome = $0 }
        try await waitAdvanced("Checkout-Race wurde nicht erkannt", timeout: .seconds(10)) {
            outcome != nil
        }
        #expect(outcome == .repositoryChanged)
        let afterCheckoutRace = try await requireAdvancedGit(
            ["--git-dir", remote.path, "rev-parse", "refs/heads/feature/sicher"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(afterCheckoutRace == foreign)
        _ = try await requireAdvancedGit(["switch", "-q", "feature/sicher"], in: root)

        _ = try await requireAdvancedGit(
            ["config", "branch.feature/sicher.remote", "https://secret@example.invalid/repo.git"],
            in: root)
        var unsafeTargetWasShown = false
        outcome = nil
        _ = GitForcePushRunner.run(repository: root, coordinator: coordinator,
                                   decision: { _, proceed in
            unsafeTargetWasShown = true; proceed(false)
        }) { outcome = $0 }
        try await waitAdvanced("URL-Remote-Prüfung endete nicht", timeout: .seconds(10)) {
            outcome != nil
        }
        guard case .blocked = outcome else {
            Issue.record("URL statt Remote-Name hätte blockiert werden müssen")
            return
        }
        #expect(!unsafeTargetWasShown)
    }
}

@Suite("Git-Identität", .serialized)
struct GitIdentityTests {
    @Test("Lokale und globale Identity-Paare werden mit isoliertem HOME real geschrieben")
    func realLocalAndGlobalPairWrites() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-RealIdentityRepo-\(UUID().uuidString)")
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-RealIdentityHome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: isolatedHome)
        }
        _ = try await requireAdvancedGit(["init", "-q"], in: root)
        let executor = try IsolatedHomeGitExecutor(home: isolatedHome)
        let coordinator = GitOperationsCoordinator(executor: executor)

        var localOutcome: GitIdentityWriteOutcome?
        _ = GitIdentityWriter.write(
            GitIdentityConfiguration(
                name: "Lokaler Name", email: "lokal@example.test",
                scope: .repository, globalConfirmed: false
            ),
            repository: root, coordinator: coordinator
        ) { localOutcome = $0 }
        try await waitAdvanced("Realer lokaler Identity-Write endete nicht",
                               timeout: .seconds(10)) { localOutcome != nil }
        #expect(localOutcome == .written)
        #expect(!coordinator.state(for: root).isBusy)
        #expect(!coordinator.state(for: GitIdentityLock.globalRepositoryKey).isBusy)
        #expect(try await requireAdvancedGit(
            ["config", "--local", "--get", "user.name"], in: root
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "Lokaler Name")
        #expect(try await requireAdvancedGit(
            ["config", "--local", "--get", "user.email"], in: root
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "lokal@example.test")

        var globalOutcome: GitIdentityWriteOutcome?
        _ = GitIdentityWriter.write(
            GitIdentityConfiguration(
                name: "Globaler Name", email: "global@example.test",
                scope: .global, globalConfirmed: true
            ),
            repository: root, coordinator: coordinator
        ) { globalOutcome = $0 }
        try await waitAdvanced("Realer globaler Identity-Write endete nicht",
                               timeout: .seconds(10)) { globalOutcome != nil }
        #expect(globalOutcome == .written)

        func isolatedConfig(_ key: String) async -> GitExecutionOutcome {
            await withCheckedContinuation { continuation in
                _ = executor.execute(
                    arguments: ["config", "--global", "--get", key], in: root,
                    outputLimit: .default, policy: .default
                ) { continuation.resume(returning: $0) }
            }
        }
        guard case .completed(let globalName) = await isolatedConfig("user.name"),
              case .completed(let globalEmail) = await isolatedConfig("user.email") else {
            Issue.record("Isolierte globale Identity konnte nicht zurückgelesen werden")
            return
        }
        #expect(globalName.ok)
        #expect(globalEmail.ok)
        #expect(globalName.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "Globaler Name")
        #expect(globalEmail.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "global@example.test")
        #expect(FileManager.default.fileExists(atPath:
            isolatedHome.appendingPathComponent(".gitconfig").path))
    }

    @Test("Später Include-Wert lässt reale Configbytes unverändert und gilt im Commit")
    func realLaterIncludeFailsBeforeWriteAndSuppliesCommitIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-RealIdentityInclude-\(UUID().uuidString)")
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-RealIdentityIncludeHome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: isolatedHome)
        }
        _ = try await requireAdvancedGit(["init", "-q", "-b", "main"], in: root)
        _ = try await requireAdvancedGit(
            ["config", "--local", "user.name", "Direkter Name"], in: root
        )
        _ = try await requireAdvancedGit(
            ["config", "--local", "user.email", "direkt@example.test"], in: root
        )
        let included = root.appendingPathComponent("identity-include.config")
        _ = try await requireAdvancedGit(
            ["config", "--file", included.path, "user.name", "Include Name"], in: root
        )
        _ = try await requireAdvancedGit(
            ["config", "--file", included.path, "user.email", "include@example.test"],
            in: root
        )
        // Der Include steht absichtlich hinter den direkten Werten und gewinnt
        // damit in Gits effektiver Konfigurationsreihenfolge.
        _ = try await requireAdvancedGit(
            ["config", "--local", "include.path", included.path], in: root
        )
        let configURL = root.appendingPathComponent(".git/config")
        let configBefore = try Data(contentsOf: configURL)
        let includeBefore = try Data(contentsOf: included)
        let executor = try IsolatedHomeGitExecutor(home: isolatedHome)
        let coordinator = GitOperationsCoordinator(executor: executor)

        var writeOutcome: GitIdentityWriteOutcome?
        _ = GitIdentityWriter.write(
            GitIdentityConfiguration(
                name: "Neuer Name", email: "neu@example.test",
                scope: .repository, globalConfirmed: false
            ), repository: root, coordinator: coordinator
        ) { writeOutcome = $0 }
        try await waitAdvanced("Realer Include-Preflight endete nicht",
                               timeout: .seconds(10)) { writeOutcome != nil }
        guard case .failure(.captureFailed(let failure)) = writeOutcome else {
            Issue.record("Später Include-Wert wurde nicht vor dem Schreiben abgelehnt")
            return
        }
        #expect(failure.stdoutError == L10n.string(
            "Eine include- oder includeIf-Konfiguration würde die direkte Git-Identität weiterhin überschreiben. Fastra hat nichts geschrieben."
        ))
        #expect(try Data(contentsOf: configURL) == configBefore)
        #expect(try Data(contentsOf: included) == includeBefore)

        func isolated(_ arguments: [String]) async -> GitExecutionOutcome {
            await withCheckedContinuation { continuation in
                _ = executor.execute(
                    arguments: arguments, in: root, outputLimit: .default,
                    policy: .default
                ) { continuation.resume(returning: $0) }
            }
        }
        guard case .completed(let commit) = await isolated([
            "commit", "--allow-empty", "-m", "Include identity"
        ]) else {
            Issue.record("Commit mit Include-Identität wurde nicht ausgeführt")
            return
        }
        #expect(commit.ok)
        guard case .completed(let author) = await isolated([
            "show", "-s", "--format=%an%x00%ae", "HEAD"
        ]) else {
            Issue.record("Commit-Identität konnte nicht gelesen werden")
            return
        }
        #expect(author.stdoutData == Data("Include Name\0include@example.test\n".utf8))
        #expect(!coordinator.state(for: root).isBusy)
        #expect(!coordinator.state(for: GitIdentityLock.globalRepositoryKey).isBusy)
    }

    @Test("Commit in zweitem Repository wartet auf vollständig verifiziertes Identity-Paar")
    func commitWaitsForIdentityPairAcrossRepositories() async throws {
        let executor = AdvancedControlledExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let repositoryA = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-IdentityWriter-\(UUID().uuidString)")
        let repositoryB = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-IdentityCommit-\(UUID().uuidString)")
        let configuration = GitIdentityConfiguration(
            name: "Neuer Name", email: "neu@example.test",
            scope: .repository, globalConfirmed: false
        )
        var writeOutcome: GitIdentityWriteOutcome?
        _ = GitIdentityWriter.write(
            configuration, repository: repositoryA, coordinator: coordinator
        ) { writeOutcome = $0 }

        executor.complete(0, advancedSuccess(directIdentityOriginData("Alter Name")))
        executor.complete(1, advancedSuccess(directIdentityOriginData("alt@example.test")))
        executor.complete(2, advancedSuccess(directIdentityOriginData("Alter Name")))
        executor.complete(3, advancedSuccess(directIdentityOriginData("alt@example.test")))
        executor.complete(4, advancedSuccess())
        try await waitAdvanced("Zweiter Identity-Key wurde nicht gestartet") {
            executor.count == 6
        }

        var mutationOutcome: GitValidatedMutationOutcome?
        _ = GitValidatedMutationRunner.run(
            repository: repositoryB, kind: .workingTreeMutation,
            identity: "commit-across-repositories", arguments: ["commit", "--no-edit"],
            requiresIdentity: true, coordinator: coordinator,
            validate: { _ in nil }, decision: { _, proceed in proceed(true) }
        ) { mutationOutcome = $0 }

        // user.name ist bereits neu, user.email aber noch nicht. Der globale
        // Identity-Barrier-Slot darf im zweiten Repository noch keinen Read starten.
        try await Task.sleep(for: .milliseconds(30))
        #expect(executor.count == 6)
        executor.complete(5, advancedSuccess())
        executor.complete(6, advancedSuccess(Data("Neuer Name\0".utf8)))
        executor.complete(7, advancedSuccess(Data("neu@example.test\0".utf8)))
        executor.complete(8, advancedSuccess(directIdentityOriginData("Neuer Name")))
        executor.complete(9, advancedSuccess(directIdentityOriginData("neu@example.test")))
        try await waitAdvanced("Verifizierter Identity-Writer endete nicht") {
            writeOutcome == .written && executor.count >= 11
        }

        // Erst nach der Paarverifikation beginnt der Commit-Preflight in Repo B.
        #expect(executor.arguments[10] == GitStatusParser.arguments)
        executor.complete(10, advancedSuccess(statusData()))
        executor.complete(11, absentOperationPaths(in: repositoryB))
        executor.complete(12, advancedSuccess(Data("Neuer Name\n".utf8)))
        executor.complete(13, advancedSuccess(Data("neu@example.test\n".utf8)))
        executor.complete(14, advancedFailure(code: 1))
        executor.complete(15, advancedFailure(code: 1))
        try await waitAdvanced("Zweiter Commit-Preflight fehlt") { executor.count >= 17 }
        executor.complete(16, advancedSuccess(statusData()))
        executor.complete(17, absentOperationPaths(in: repositoryB))
        executor.complete(18, advancedSuccess(Data("Neuer Name\n".utf8)))
        executor.complete(19, advancedSuccess(Data("neu@example.test\n".utf8)))
        executor.complete(20, advancedFailure(code: 1))
        executor.complete(21, advancedFailure(code: 1))
        try await waitAdvanced("Commit wurde nach vollständigem Paar nicht gestartet") {
            executor.count >= 23
        }
        #expect(executor.arguments[22] == ["commit", "--no-edit"])
        executor.complete(22, advancedSuccess())
        try await waitAdvanced("Commit-Ergebnis fehlt") { mutationOutcome != nil }
        #expect(mutationOutcome == .executed(advancedSuccess()))
    }

    @Test("Identity-Reader berücksichtigt lokale include- und includeIf-Dateien")
    func configuredIdentityReadsIncludes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-IdentityIncludes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await requireAdvancedGit(["init", "-q", "-b", "main"], in: root)
        let includedName = root.appendingPathComponent("identity-name.config")
        let conditionalEmail = root.appendingPathComponent("identity-email.config")
        _ = try await requireAdvancedGit(
            ["config", "--file", includedName.path, "user.name", "Include Name"], in: root
        )
        _ = try await requireAdvancedGit(
            ["config", "--file", conditionalEmail.path,
             "user.email", "conditional@example.test"], in: root
        )
        _ = try await requireAdvancedGit(
            ["config", "--local", "include.path", includedName.path], in: root
        )
        _ = try await requireAdvancedGit(
             ["config", "--local",
             "includeIf.onbranch:main.path", conditionalEmail.path], in: root
        )

        var result: GitConfiguredIdentityResult?
        _ = GitConfiguredIdentityReader.read(
            repository: root, executor: GitRunnerExecutor()
        ) { result = $0 }
        try await waitAdvanced("Identity aus Include-Dateien wurde nicht gelesen",
                               timeout: .seconds(10)) { result != nil }
        guard case .value(let identity) = result else {
            Issue.record("Identity-Reader meldete für gültige Includes einen Fehler")
            return
        }
        #expect(identity == GitConfiguredIdentity(
            name: "Include Name", email: "conditional@example.test"
        ))
    }

    @Test("Lokale Identity-Änderungen bleiben repositorygebunden; globale gelten appweit")
    func identityChangeRouting() {
        let local = GitIdentityChangeNotice(scope: .repository,
                                            repositoryKey: "/repo/a")
        #expect(local.applies(to: "/repo/a"))
        #expect(!local.applies(to: "/repo/b"))
        let global = GitIdentityChangeNotice(scope: .global,
                                             repositoryKey: "/repo/a")
        #expect(global.applies(to: "/repo/a"))
        #expect(global.applies(to: "/repo/b"))
    }

    @Test("Automatische Git-Fallbackidentität zählt ohne lokale/globale Konfiguration nicht")
    func fallbackIdentityDoesNotCount() async throws {
        let executor = AdvancedControlledExecutor()
        let root = FileManager.default.temporaryDirectory
        var result: GitConfiguredIdentityResult?
        _ = GitConfiguredIdentityReader.read(repository: root, executor: executor) {
            result = $0
        }
        for index in 0..<4 {
            #expect(executor.arguments[index].prefix(3) == [
                "config", "--includes", index < 2 ? "--local" : "--global"
            ])
            executor.complete(index, advancedFailure(code: 1))
        }
        try await waitAdvanced("Konfigurationsprüfung endete nicht") { result != nil }
        guard case .value(let identity) = result else {
            Issue.record("Identity-Leseergebnis fehlt"); return
        }
        #expect(identity == nil)
        #expect(!executor.arguments.contains(["var", "GIT_AUTHOR_IDENT"]))
    }

    @Test("Fehlende Identität öffnet den lokalen Dialog und setzt erst nach verifiziertem Paar fort")
    func ensureIdentityPromptsAndContinues() async throws {
        let executor = AdvancedControlledExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let (defaults, suite) = makeDefaults("identity-prompt")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults,
                                  gitOperationsCoordinator: coordinator)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-IdentityPrompt-\(UUID().uuidString)")
        workspace.projectURL = root
        var promptCount = 0
        workspace.gitIdentityPromptHandler = { _ in
            promptCount += 1
            return GitIdentityConfiguration(name: "Ada", email: "ada@example.test",
                                            scope: .repository,
                                            globalConfirmed: false)
        }
        var continued = false
        let context = try #require(workspace.currentGitActionContext)
        workspace.ensureGitIdentity(context: context) { _ in continued = true }
        for index in 0..<4 { executor.complete(index, advancedFailure(code: 1)) }
        try await waitAdvanced("Identity-Dialog startete Writer nicht") { executor.count >= 5 }
        executor.complete(4, advancedFailure(code: 1))
        executor.complete(5, advancedFailure(code: 1))
        executor.complete(6, advancedFailure(code: 1))
        executor.complete(7, advancedFailure(code: 1))
        executor.complete(8, advancedSuccess())
        executor.complete(9, advancedSuccess())
        executor.complete(10, advancedSuccess(Data("Ada\0".utf8)))
        executor.complete(11, advancedSuccess(Data("ada@example.test\0".utf8)))
        executor.complete(12, advancedSuccess(directIdentityOriginData("Ada")))
        executor.complete(13, advancedSuccess(directIdentityOriginData("ada@example.test")))
        try await waitAdvanced("Identity-Fortsetzung fehlt") { continued }
        #expect(promptCount == 1)
    }

    @Test("Abbruch des Identity-Dialogs startet weder Writer noch Mutation")
    func ensureIdentityPromptCanCancel() async throws {
        let executor = AdvancedControlledExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let (defaults, suite) = makeDefaults("identity-cancel")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults,
                                  gitOperationsCoordinator: coordinator)
        workspace.projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-IdentityCancel-\(UUID().uuidString)")
        workspace.gitIdentityPromptHandler = { _ in nil }
        var continued = false
        workspace.ensureGitIdentity(context: try #require(workspace.currentGitActionContext)) {
            _ in continued = true
        }
        for index in 0..<4 { executor.complete(index, advancedFailure(code: 1)) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(executor.count == 4)
        #expect(!continued)
    }

    @Test("Reader unterscheidet lokale, globale und partielle Werte")
    func localGlobalRead() async throws {
        let executor = AdvancedControlledExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let root = FileManager.default.temporaryDirectory
        var outcome: GitIdentityReadOutcome?
        _ = GitIdentityReader.read(repository: root, coordinator: coordinator) {
            outcome = $0
        }
        executor.complete(0, advancedFailure(code: 1))
        executor.complete(1, advancedSuccess(Data("local@example.test\n".utf8)))
        executor.complete(2, advancedSuccess(Data("Global Name\n".utf8)))
        executor.complete(3, advancedSuccess(Data("global@example.test\n".utf8)))
        try await waitAdvanced("Identity-Ergebnis fehlt") { outcome != nil }
        guard case .value(let snapshot) = outcome else {
            Issue.record("Identity-Read schlug fehl"); return
        }
        #expect(snapshot.localName == nil)
        #expect(snapshot.localEmail == "local@example.test")
        #expect(snapshot.globalName == "Global Name")
        #expect(snapshot.effectiveName == "Global Name")
        #expect(snapshot.effectiveEmail == "local@example.test")
        #expect(snapshot.isComplete)
    }

    @Test("Repository-lokal ist Default; global braucht explizite Bestätigung")
    func configurationSafety() {
        let local = GitIdentityConfiguration(name: "  Ada Lovelace ",
                                             email: " ada@example.test ",
                                             scope: .repository,
                                             globalConfirmed: false)
        #expect(local.arguments == [
            ["config", "--local", "--replace-all", "user.name", "Ada Lovelace"],
            ["config", "--local", "--replace-all", "user.email", "ada@example.test"]
        ])
        let unconfirmedGlobal = GitIdentityConfiguration(name: "Ada", email: "a@b",
                                                         scope: .global,
                                                         globalConfirmed: false)
        #expect(unconfirmedGlobal.arguments == nil)
        let confirmedGlobal = GitIdentityConfiguration(name: "Ada", email: "a@b",
                                                       scope: .global,
                                                       globalConfirmed: true)
        #expect(confirmedGlobal.arguments?.allSatisfy { $0.contains("--global") } == true)
        #expect(GitIdentityConfiguration(name: "\n", email: "a@b",
                                         scope: .repository,
                                         globalConfirmed: false).arguments == nil)
    }

    @Test("Writer sichert, schreibt und verifiziert Name und E-Mail als Paar")
    func writerArguments() async throws {
        let executor = AdvancedControlledExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let config = GitIdentityConfiguration(name: "Renée Example",
                                              email: "renee+git@example.test",
                                              scope: .repository,
                                              globalConfirmed: false)
        var outcome: GitIdentityWriteOutcome?
        _ = GitIdentityWriter.write(config, repository: FileManager.default.temporaryDirectory,
                                    coordinator: coordinator) { outcome = $0 }
        #expect(executor.arguments[0] == [
            "config", "--local", "--show-origin", "-z", "--get-all", "user.name"
        ])
        executor.complete(0, advancedFailure(code: 1))
        #expect(executor.arguments[1] == [
            "config", "--local", "--show-origin", "-z", "--get-all", "user.email"
        ])
        executor.complete(1, advancedFailure(code: 1))
        executor.complete(2, advancedFailure(code: 1))
        executor.complete(3, advancedFailure(code: 1))
        #expect(executor.arguments[4].suffix(2) == ["user.name", "Renée Example"])
        executor.complete(4, advancedSuccess())
        #expect(executor.arguments[5].suffix(2) == ["user.email", "renee+git@example.test"])
        executor.complete(5, advancedSuccess())
        executor.complete(6, advancedSuccess(Data("Renée Example\0".utf8)))
        executor.complete(7, advancedSuccess(Data("renee+git@example.test\0".utf8)))
        executor.complete(8, advancedSuccess(directIdentityOriginData("Renée Example")))
        executor.complete(9, advancedSuccess(directIdentityOriginData("renee+git@example.test")))
        try await waitAdvanced("Identity-Write-Ergebnis fehlt") { outcome != nil }
        #expect(outcome == .written)
    }

    @Test("Fehler beim zweiten Identity-Key rollt beide vorherigen Werte zurück")
    func writerRollsBackPair() async throws {
        let executor = AdvancedControlledExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let config = GitIdentityConfiguration(name: "Neu", email: "neu@example.test",
                                              scope: .repository,
                                              globalConfirmed: false)
        var outcome: GitIdentityWriteOutcome?
        _ = GitIdentityWriter.write(config, repository: FileManager.default.temporaryDirectory,
                                    coordinator: coordinator) { outcome = $0 }
        executor.complete(0, advancedSuccess(directIdentityOriginData("Alt")))
        executor.complete(1, advancedSuccess(directIdentityOriginData("alt@example.test")))
        executor.complete(2, advancedSuccess(directIdentityOriginData("Alt")))
        executor.complete(3, advancedSuccess(directIdentityOriginData("alt@example.test")))
        executor.complete(4, advancedSuccess())
        executor.complete(5, advancedFailure("E-Mail nicht schreibbar", code: 3))
        try await waitAdvanced("Rollback für Name fehlt") { executor.count >= 7 }
        #expect(executor.arguments[6] == [
            "config", "--local", "--replace-all", "user.name", "Alt"
        ])
        executor.complete(6, advancedSuccess())
        executor.complete(7, advancedSuccess()) // Alten E-Mail-Wert an Ort und Stelle ersetzen.
        executor.complete(8, advancedSuccess(Data("Alt\0".utf8)))
        executor.complete(9, advancedSuccess(Data("alt@example.test\0".utf8)))
        executor.complete(10, advancedSuccess(directIdentityOriginData("Alt")))
        executor.complete(11, advancedSuccess(directIdentityOriginData("alt@example.test")))
        try await waitAdvanced("Identity-Rollback endete nicht") { outcome != nil }
        #expect(outcome == .failure(advancedFailure("E-Mail nicht schreibbar", code: 3)))
    }

    @Test("Spätes includeIf-Override beendet den Writer vor der ersten Mutation")
    func includedOverrideFailsBeforeWriteAndBarrierRelease() async throws {
        let executor = AdvancedControlledExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let repositoryA = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-IncludeOverride-\(UUID().uuidString)")
        let repositoryB = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-IncludeFollower-\(UUID().uuidString)")
        let configuration = GitIdentityConfiguration(
            name: "Neu", email: "neu@example.test", scope: .repository,
            globalConfirmed: false
        )
        var outcome: GitIdentityWriteOutcome?
        _ = GitIdentityWriter.write(
            configuration, repository: repositoryA, coordinator: coordinator
        ) { outcome = $0 }

        executor.complete(0, advancedSuccess(directIdentityOriginData("Alt")))
        executor.complete(1, advancedSuccess(directIdentityOriginData("alt@example.test")))
        executor.complete(2, advancedSuccess(identityOriginData([
            ("file:.git/config", "Alt"),
            ("file:/included/config", "Include Override")
        ])))

        var followerStarted = false
        var followerOutcome: GitExecutionOutcome?
        _ = coordinator.performIdentityBarrierExclusive(
            repository: repositoryB, kind: .workingTreeMutation,
            identity: "commit-after-include-preflight",
            starter: { finish in
                followerStarted = true
                finish(advancedSuccess())
                return GitOperationLease {}
            },
            completion: { followerOutcome = $0 }
        )
        #expect(!followerStarted)

        executor.complete(3, advancedSuccess(identityOriginData([
            ("file:.git/config", "alt@example.test"),
            ("file:/included/config", "included@example.test")
        ])))
        try await waitAdvanced("Barrier wurde nach includeIf-Preflight nicht freigegeben") {
            outcome != nil && followerOutcome != nil
        }
        guard case .failure(.captureFailed(let failure)) = outcome else {
            Issue.record("includeIf-Override wurde nicht vor dem Schreiben abgelehnt")
            return
        }
        #expect(failure.stdoutError == L10n.string(
            "Eine include- oder includeIf-Konfiguration würde die direkte Git-Identität weiterhin überschreiben. Fastra hat nichts geschrieben."
        ))
        #expect(executor.count == 4)
        #expect(followerStarted)
    }

    @Test("Abbruch nach dem ersten Identity-Write lässt Rollback und Barriere fertiglaufen")
    func cancellationAfterMutationCannotInterruptRollback() async throws {
        let executor = AdvancedControlledExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let repositoryA = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-IdentityCancelCleanup-\(UUID().uuidString)")
        let repositoryB = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-IdentityCancelFollower-\(UUID().uuidString)")
        var outcome: GitIdentityWriteOutcome?
        let lease = try #require(GitIdentityWriter.write(
            GitIdentityConfiguration(
                name: "Neu", email: "neu@example.test", scope: .repository,
                globalConfirmed: false
            ),
            repository: repositoryA, coordinator: coordinator
        ) { outcome = $0 })
        executor.complete(0, advancedSuccess(directIdentityOriginData("Alt")))
        executor.complete(1, advancedSuccess(directIdentityOriginData("alt@example.test")))
        executor.complete(2, advancedSuccess(directIdentityOriginData("Alt")))
        executor.complete(3, advancedSuccess(directIdentityOriginData("alt@example.test")))
        executor.complete(4, advancedSuccess())
        try await waitAdvanced("Zweiter Identity-Write wurde nicht gestartet") {
            executor.count >= 6
        }
        lease.cancel()
        #expect(outcome == .cancelled)
        #expect(!executor.cancellations[5])

        var followerStarted = false
        _ = coordinator.performIdentityBarrierExclusive(
            repository: repositoryB, kind: .workingTreeMutation,
            identity: "commit-after-cancelled-cleanup",
            starter: { finish in
                followerStarted = true
                finish(advancedSuccess())
                return GitOperationLease {}
            }, completion: { _ in }
        )
        #expect(!followerStarted)

        executor.complete(5, advancedFailure("E-Mail nicht schreibbar", code: 3))
        try await waitAdvanced("Rollback nach Nutzerabbruch startete nicht") {
            executor.count >= 7
        }
        executor.complete(6, advancedSuccess())
        executor.complete(7, advancedSuccess())
        executor.complete(8, advancedSuccess(Data("Alt\0".utf8)))
        executor.complete(9, advancedSuccess(Data("alt@example.test\0".utf8)))
        executor.complete(10, advancedSuccess(directIdentityOriginData("Alt")))
        executor.complete(11, advancedSuccess(directIdentityOriginData("alt@example.test")))
        try await waitAdvanced("Barriere blieb nach abgebrochenem Cleanup hängen") {
            followerStarted
        }
        #expect(executor.arguments[6] == [
            "config", "--local", "--replace-all", "user.name", "Alt"
        ])
        #expect(executor.arguments[11].contains("--includes"))
        #expect(!coordinator.state(for: repositoryA).isBusy)
        #expect(!coordinator.state(for: GitIdentityLock.globalRepositoryKey).isBusy)
    }
}
