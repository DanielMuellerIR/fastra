// GitReviewFixTests.swift
//
// Regressionstests zu Git-Befunden der Code-Reviews vom 2026-08-10 und
// 2026-08-11:
//   A1  Fastra darf `index.lock` nie selbst entfernen: Selbst ein direkt nach
//       der Vorprüfung angelegter fremder Lock muss unangetastet bleiben.
//   A2  „Verwerfen" muss Repository und Aktionskontext vor der Rückfrage
//       einfrieren und danach auf Aktualität prüfen.
//   A3  Der Push muss gegen genau die geprüfte, eindeutige Adresse laufen,
//       ohne Geheimnisse in Prozessargumente zu schreiben oder die
//       Remote-Tracking-Referenz zu verlieren.
//
// Alle Git-Tests arbeiten ausschließlich gegen temporäre Repositories.

import Foundation
import Testing
@testable import Fastra

// MARK: - Gemeinsame Helfer

private func reviewFixTempDirectory(_ suffix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("Fastra-ReviewFix-\(suffix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func reviewFixGit(_ arguments: [String], in directory: URL) async -> GitResult {
    await withCheckedContinuation { continuation in
        GitRunner.runDetailed(arguments, in: directory) { outcome in
            switch outcome {
            case .completed(let result): continuation.resume(returning: result)
            default:
                continuation.resume(returning: GitResult(
                    exitCode: -1, stdout: "", stderr: "GitRunner: \(outcome)"))
            }
        }
    }
}

private func reviewFixGit(_ invocation: GitPushCommand.Invocation,
                          in directory: URL) async -> GitResult {
    await withCheckedContinuation { continuation in
        var policy = GitExecutionPolicy.default
        policy.environment = invocation.environment
        GitRunner.runDetailed(invocation.arguments, in: directory,
                              policy: policy) { outcome in
            switch outcome {
            case .completed(let result): continuation.resume(returning: result)
            default:
                continuation.resume(returning: GitResult(
                    exitCode: -1, stdout: "", stderr: "GitRunner: \(outcome)"))
            }
        }
    }
}

/// Fake-Executor: sammelt Aufrufe, ohne je einen Prozess zu starten.
private final class ReviewFixExecutor: GitCommandExecuting {
    final class Token: GitCancelling {
        private(set) var cancelled = false
        func cancel() { cancelled = true }
    }

    private struct Call {
        let arguments: [String]
        let directory: URL
        let policy: GitExecutionPolicy
        let completion: (GitExecutionOutcome) -> Void
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    var count: Int { lock.withLock { calls.count } }
    var arguments: [[String]] { lock.withLock { calls.map(\.arguments) } }
    var directories: [URL] { lock.withLock { calls.map(\.directory) } }
    var policies: [GitExecutionPolicy] { lock.withLock { calls.map(\.policy) } }

    @discardableResult
    func execute(arguments: [String], in directory: URL,
                 outputLimit: GitOutputLimit, policy: GitExecutionPolicy,
                 completion: @escaping (GitExecutionOutcome) -> Void) -> GitCancelling {
        lock.withLock {
            calls.append(Call(arguments: arguments, directory: directory,
                              policy: policy,
                              completion: completion))
        }
        return Token()
    }

    func complete(_ index: Int, _ outcome: GitExecutionOutcome) {
        let completion = lock.withLock { calls[index].completion }
        completion(outcome)
    }

    /// Index des ersten Aufrufs, der `predicate` erfüllt — robuster als eine
    /// feste Position, weil die Oberfläche nebenher Statusleseläufe anstößt.
    func firstIndex(where predicate: ([String]) -> Bool) -> Int? {
        lock.withLock { calls.map(\.arguments) }.firstIndex(where: predicate)
    }
}

private func reviewFixSuccess(_ stdout: String = "") -> GitExecutionOutcome {
    .completed(GitResult(exitCode: 0, stdout: stdout, stderr: ""))
}

/// `git config --get…` meldet „nicht gesetzt" als Exit 1 ohne Ausgabe.
private func reviewFixUnset() -> GitExecutionOutcome {
    .completed(GitResult(exitCode: 1, stdout: "", stderr: ""))
}

@Suite("Git-Index-Lock nach dem Preflight")
struct GitReviewFixLockCollisionTests {
    @Test("Fremder Lock aus dem Startfenster wird niemals gelöscht")
    func foreignLockAfterPreflightSurvives() async throws {
        guard GitRunner.isAvailable else { return }
        let root = try reviewFixTempDirectory("foreign-index-lock")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect((await reviewFixGit(["init", "-q", "-b", "main"], in: root)).ok)
        let index = root.appendingPathComponent(".git/index").path
        let lock = URL(fileURLWithPath: index + ".lock")
        var outcome: GitExecutionOutcome?
        _ = GitRunner.runHoldingIndexLock(
            indexPath: index, record: Data(), headRef: "refs/heads/main",
            headOID: String(repeating: "0", count: 40),
            headRefPath: root.appendingPathComponent(".git/refs/heads/main").path,
            headRefNeedsNoDeref: false,
            worktreeHeadPath: root.appendingPathComponent(".git/HEAD").path,
            headSymbolicTarget: "refs/heads/main", in: root,
            verify: { $0(false) }, afterLockPreflight: {
                try? Data("fremd".utf8).write(to: lock, options: .withoutOverwriting)
            }) { result, _ in outcome = result }
        #expect(await waitUntil(timeout: 10) { outcome != nil })
        #expect(try Data(contentsOf: lock) == Data("fremd".utf8))
    }
}

// MARK: - A2: Verwerfen bindet Repository und Aktionskontext

@MainActor
@Suite("Verwerfen mit eingefrorenem Repository", .serialized)
struct GitReviewFixDiscardContextTests {
    private struct Fixture {
        let workspace: Workspace
        let executor: ReviewFixExecutor
        let first: URL
        let second: URL
        let defaults: UserDefaults
        let suite: String
    }

    private func makeFixture(_ name: String) throws -> Fixture {
        let executor = ReviewFixExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let store = GitRepositoryStore(executor: executor, coordinator: coordinator)
        let suite = "Fastra-ReviewFix-\(name)-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        let workspace = Workspace(defaults: defaults,
                                  gitOperationsCoordinator: coordinator,
                                  gitRepositoryStore: store)
        return Fixture(workspace: workspace, executor: executor,
                       first: try reviewFixTempDirectory("\(name)-a"),
                       second: try reviewFixTempDirectory("\(name)-b"),
                       defaults: defaults, suite: suite)
    }

    @Test("Kompakter unversionierter Ordner wird nie rekursiv gelöscht")
    func untrackedDirectoryKeepsIgnoredContents() throws {
        let root = try reviewFixTempDirectory("discard-directory")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("material")
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        let ignored = folder.appendingPathComponent(".geheim")
        try Data("behalten".utf8).write(to: ignored)

        #expect(throws: (any Error).self) {
            try Workspace.removeUntrackedFile(at: folder)
        }
        #expect(try Data(contentsOf: ignored) == Data("behalten".utf8))
    }

    private func cleanUp(_ fixture: Fixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.suite)
        try? FileManager.default.removeItem(at: fixture.first)
        try? FileManager.default.removeItem(at: fixture.second)
    }

    @Test("Getracktes Verwerfen wirkt nicht im inzwischen geöffneten Repository")
    func trackedDiscardStopsAfterProjectChange() throws {
        guard GitRunner.isAvailable else { return }
        let fixture = try makeFixture("discard-tracked")
        defer { cleanUp(fixture) }
        let oldDialogs = Workspace.presentGitDialogs
        Workspace.presentGitDialogs = false
        defer { Workspace.presentGitDialogs = oldDialogs }

        fixture.workspace.projectURL = fixture.first
        let frozen = try #require(fixture.workspace.currentGitActionContext)
        // Zwischen Rückfrage und Ausführung wechselt das Fenster das Projekt.
        fixture.workspace.projectURL = fixture.second
        let change = GitChange(path: "gleicher-name.txt", staged: nil,
                               unstaged: .modified)
        fixture.workspace.gitDiscard(change: change, context: frozen)
        #expect(!fixture.executor.arguments.contains { $0.first == "checkout" })
    }

    @Test("Unversioniertes Verwerfen löscht nach Projektwechsel keine fremde Datei")
    func untrackedDiscardStopsAfterProjectChange() throws {
        let fixture = try makeFixture("discard-untracked")
        defer { cleanUp(fixture) }
        let oldDialogs = Workspace.presentGitDialogs
        Workspace.presentGitDialogs = false
        defer { Workspace.presentGitDialogs = oldDialogs }

        let name = "gleicher-name.txt"
        let inFirst = fixture.first.appendingPathComponent(name)
        let inSecond = fixture.second.appendingPathComponent(name)
        try Data("A".utf8).write(to: inFirst)
        try Data("B".utf8).write(to: inSecond)

        fixture.workspace.projectURL = fixture.first
        let frozen = try #require(fixture.workspace.currentGitActionContext)
        fixture.workspace.projectURL = fixture.second
        let change = GitChange(path: name, staged: nil, unstaged: .untracked)
        fixture.workspace.gitDiscard(change: change, context: frozen)
        // Weder im alten noch im neuen Projekt darf jetzt etwas gelöscht sein:
        // Die Bestätigung galt einem Repository, das nicht mehr offen ist.
        #expect(FileManager.default.fileExists(atPath: inFirst.path))
        #expect(FileManager.default.fileExists(atPath: inSecond.path))
    }

    @Test("Mehrfachauswahl stoppt nach einem Projektwechsel ebenfalls")
    func multipleDiscardStopsAfterProjectChange() throws {
        guard GitRunner.isAvailable else { return }
        let fixture = try makeFixture("discard-multi")
        defer { cleanUp(fixture) }
        let oldDialogs = Workspace.presentGitDialogs
        Workspace.presentGitDialogs = false
        defer { Workspace.presentGitDialogs = oldDialogs }

        let untracked = fixture.second.appendingPathComponent("neu.txt")
        try Data("B".utf8).write(to: untracked)
        fixture.workspace.projectURL = fixture.first
        let frozen = try #require(fixture.workspace.currentGitActionContext)
        fixture.workspace.projectURL = fixture.second
        fixture.workspace.gitDiscard(changes: [
            GitChange(path: "a.txt", staged: nil, unstaged: .modified),
            GitChange(path: "neu.txt", staged: nil, unstaged: .untracked)
        ], context: frozen)
        #expect(!fixture.executor.arguments.contains { $0.first == "checkout" })
        #expect(FileManager.default.fileExists(atPath: untracked.path))
    }

    @Test("Im unveränderten Projekt verwirft der eingefrorene Kontext wie bisher")
    func currentContextStillDiscards() throws {
        guard GitRunner.isAvailable else { return }
        let fixture = try makeFixture("discard-current")
        defer { cleanUp(fixture) }
        let oldDialogs = Workspace.presentGitDialogs
        Workspace.presentGitDialogs = false
        defer { Workspace.presentGitDialogs = oldDialogs }

        fixture.workspace.projectURL = fixture.first
        let frozen = try #require(fixture.workspace.currentGitActionContext)
        let change = GitChange(path: "a.txt", staged: nil, unstaged: .modified)
        fixture.workspace.gitDiscard(change: change, context: frozen)
        let index = fixture.executor.firstIndex { $0.first == "checkout" }
        #expect(index != nil)
        if let index {
            #expect(fixture.executor.arguments[index] == ["checkout", "--", "a.txt"])
            #expect(fixture.executor.directories[index].path == fixture.first.path)
        }
    }
}

// MARK: - A3: Push gegen die geprüfte Adresse

@Suite("Push-Argumente binden die geprüfte Adresse")
struct GitReviewFixPushArgumentTests {
    private let target = GitPushTarget(remote: "origin",
                                       addresses: ["https://example.test/x.git"])

    @Test("Geprüfte Adresse liegt nur in der Umgebung, nie in argv")
    func addressIsNotExposedInArguments() {
        let invocation = GitPushCommand.invocation(
            remote: target.remote, address: target.addresses[0],
            refspec: "refs/heads/main:refs/heads/main",
            temporaryRemote: "fastra-test")
        #expect(invocation.environment["FASTRA_GIT_PUSH_URL"]
                == "https://example.test/x.git")
        #expect(!invocation.arguments.joined(separator: " ")
            .contains("https://example.test/x.git"))
        #expect(invocation.arguments == [
            "--config-env=remote.fastra-test.url=FASTRA_GIT_PUSH_URL",
            "-c", "remote.fastra-test.fetch=+refs/heads/*:refs/remotes/origin/*",
            "push", "fastra-test", "refs/heads/main:refs/heads/main",
        ])
    }

    @Test("Mehrere Push-Adressen und URL-Umschreibregeln gelten als mehrdeutig")
    func ambiguousTargetsAreRejected() {
        let multiple = GitPushTarget(remote: "origin", addresses: ["a", "b"])
        #expect(GitPushCommand.verifiedAddress(of: multiple) == nil)
        #expect(GitPushCommand.verifiedAddress(of: target)
                == "https://example.test/x.git")
        #expect(GitPushCommand.rewriteRulesAreAbsent(GitResult(
            exitCode: 1, stdout: "", stderr: "")))
        #expect(!GitPushCommand.rewriteRulesAreAbsent(GitResult(
            exitCode: 0,
            stdout: "url.ssh://example/.insteadOf git@example:", stderr: "")))
        #expect(!GitPushCommand.rewriteRulesAreAbsent(GitResult(
            exitCode: 2, stdout: "", stderr: "kaputt")))
    }
}

@Suite("Push gegen die geprüfte Adresse (echtes Git)", .serialized)
struct GitReviewFixPushTargetTests {
    @Test("Die festgenagelte Adresse gewinnt gegen eine geänderte Remote-URL")
    func pinnedAddressWinsAndKeepsTracking() async throws {
        guard GitRunner.isAvailable else { return }
        let base = try reviewFixTempDirectory("push-pin")
        defer { try? FileManager.default.removeItem(at: base) }
        let confirmed = base.appendingPathComponent("bestaetigt.git")
        let changed = base.appendingPathComponent("geaendert.git")
        #expect((await reviewFixGit(["init", "--bare", confirmed.path], in: base)).ok)
        #expect((await reviewFixGit(["init", "--bare", changed.path], in: base)).ok)

        let work = base.appendingPathComponent("arbeit")
        #expect((await reviewFixGit(["init", "-b", "main", work.path], in: base)).ok)
        #expect((await reviewFixGit(["config", "user.name", "Fastra Test"], in: work)).ok)
        #expect((await reviewFixGit(["config", "user.email", "fastra@example.test"],
                                    in: work)).ok)
        #expect((await reviewFixGit(["commit", "--allow-empty", "-m", "Start"],
                                    in: work)).ok)
        // Die Konfiguration zeigt auf das FALSCHE Ziel — genau der Zustand, den
        // eine Änderung zwischen Prüfung und Prozessstart hinterlassen würde.
        #expect((await reviewFixGit(["remote", "add", "origin", changed.path],
                                    in: work)).ok)

        let invocation = GitPushCommand.invocation(
            remote: "origin", address: confirmed.path,
            refspec: "refs/heads/main:refs/heads/main",
            temporaryRemote: "fastra-test")
        #expect((await reviewFixGit(invocation, in: work)).ok)
        #expect((await reviewFixGit(
            ["branch", "--set-upstream-to=origin/main", "main"], in: work)).ok)

        let head = (await reviewFixGit(["rev-parse", "HEAD"], in: work)).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pushed = await reviewFixGit(["rev-parse", "refs/heads/main"], in: confirmed)
        #expect(pushed.ok)
        #expect(pushed.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == head)
        // Das konfigurierte, aber nie bestätigte Ziel bleibt leer.
        #expect(!(await reviewFixGit(["rev-parse", "--verify", "refs/heads/main"],
                                     in: changed)).ok)
        // Wichtig für die Oberfläche: Remote-Tracking und Upstream entstehen
        // wie bisher, weil der Remote-NAME im Aufruf stehen bleibt.
        let tracking = await reviewFixGit(["rev-parse", "refs/remotes/origin/main"],
                                          in: work)
        #expect(tracking.ok)
        #expect(tracking.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == head)
        let upstream = await reviewFixGit(["config", "--get", "branch.main.remote"],
                                          in: work)
        #expect(upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "origin")
    }
}

@MainActor
@Suite("Push-Ablauf nagelt die geprüfte Adresse fest", .serialized)
struct GitReviewFixPushFlowTests {
    @Test("gitPush prüft Umschreibregeln und startet ohne Adresse in argv")
    func pushFlowPinsVerifiedAddress() async throws {
        guard GitRunner.isAvailable else { return }
        let executor = ReviewFixExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let store = GitRepositoryStore(executor: executor, coordinator: coordinator)
        let suite = "Fastra-ReviewFix-Push-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults,
                                  gitOperationsCoordinator: coordinator,
                                  gitRepositoryStore: store)
        let root = try reviewFixTempDirectory("push-flow")
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.projectURL = root
        let oldDialogs = Workspace.presentGitDialogs
        Workspace.presentGitDialogs = false
        defer { Workspace.presentGitDialogs = oldDialogs }

        var remoteRecord = Data("remote.origin.url\nhttps://example.test/x.git".utf8)
        remoteRecord.append(0)
        let address = "https://example.test/x.git\n"

        workspace.gitPush()
        // Zielauflösung: erst der erste konfigurierte Remote, dann die Adresse.
        try await reviewFixSettle(executor, count: 1)
        executor.complete(0, .completed(GitResult(exitCode: 0,
                                                  stdoutData: remoteRecord,
                                                  stderrData: Data())))
        try await reviewFixSettle(executor, count: 2)
        executor.complete(1, reviewFixSuccess(address))
        try await reviewFixSettle(executor, count: 3)
        executor.complete(2, reviewFixSuccess("main\n"))       // symbolic-ref
        try await reviewFixSettle(executor, count: 4)
        executor.complete(3, reviewFixSuccess("origin/main\n")) // @{u}
        // Prüfung unmittelbar vor der Netzwerkaktion: dieselbe Auflösung erneut.
        try await reviewFixSettle(executor, count: 5)
        executor.complete(4, .completed(GitResult(exitCode: 0,
                                                  stdoutData: remoteRecord,
                                                  stderrData: Data())))
        try await reviewFixSettle(executor, count: 6)
        executor.complete(5, reviewFixSuccess(address))
        // Unmittelbar vor dem Push müssen URL-Umschreibregeln ausgeschlossen sein.
        try await reviewFixSettle(executor, count: 7)
        let rewriteQuery = try #require(executor.firstIndex {
            $0 == ["config", "--includes", "--get-regexp",
                   "^url\\..*\\.\\(insteadOf\\|pushInsteadOf\\)$"]
        })
        executor.complete(rewriteQuery, reviewFixUnset())
        try await reviewFixSettle(executor, count: 8)
        let pushIndex = executor.arguments.count - 1
        #expect(executor.arguments[pushIndex].contains("push"))
        #expect(!executor.arguments[pushIndex].joined(separator: " ")
            .contains("https://example.test/x.git"))
        #expect(executor.policies[pushIndex].environment["FASTRA_GIT_PUSH_URL"]
                == "https://example.test/x.git")
    }
}

@MainActor
private func reviewFixSettle(_ executor: ReviewFixExecutor, count: Int) async throws {
    let reached = await waitUntil(timeout: 5) { executor.count >= count }
    #expect(reached, "Git-Aufruf \(count) wurde nicht gestartet")
    if !reached { throw CancellationError() }
}
