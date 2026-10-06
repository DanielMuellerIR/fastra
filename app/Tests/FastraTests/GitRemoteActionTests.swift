import Foundation
import Testing
@testable import Fastra

private func remoteActionGit(_ arguments: [String], in root: URL) async -> GitResult {
    await withCheckedContinuation { continuation in
        GitRunner.runDetailed(arguments, in: root) { outcome in
            if case .completed(let result) = outcome { continuation.resume(returning: result) }
            else { continuation.resume(returning: GitResult(exitCode: -1, stdout: "", stderr: "Git fehlgeschlagen")) }
        }
    }
}

@MainActor
@Suite("Remote-Auswahl mit echten lokalen Remotes", .serialized)
struct GitIntegrationRemoteActionTests {
    private func fixture() async throws -> (base: URL, local: URL, peer: URL) {
        let base = testTemporaryDirectory().appendingPathComponent("Fastra-RemoteChoice-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for name in ["source.git", "mirror.git", "peer"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in ["source.git", "mirror.git"] {
            #expect((await remoteActionGit(["init", "--bare", "-b", "main"], in: base.appendingPathComponent(name))).ok)
        }
        let peer = base.appendingPathComponent("peer")
        let local = base.appendingPathComponent("local")
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"],
                     ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"]] {
            #expect((await remoteActionGit(args, in: peer)).ok)
        }
        try "base\n".write(to: peer.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        for args in [["add", "base.txt"], ["commit", "-m", "base"],
                     ["remote", "add", "source", base.appendingPathComponent("source.git").path],
                     ["push", "source", "main"], ["push", base.appendingPathComponent("mirror.git").path, "main"]] {
            #expect((await remoteActionGit(args, in: peer)).ok)
        }
        #expect((await remoteActionGit(["clone", base.appendingPathComponent("mirror.git").path, local.path], in: base)).ok)
        #expect((await remoteActionGit(["remote", "rename", "origin", "mirror"], in: local)).ok)
        #expect((await remoteActionGit(["remote", "add", "source", base.appendingPathComponent("source.git").path], in: local)).ok)
        try "incoming\n".write(to: peer.appendingPathComponent("incoming.txt"), atomically: true, encoding: .utf8)
        for args in [["add", "incoming.txt"], ["commit", "-m", "incoming"], ["push", "source", "main"]] {
            #expect((await remoteActionGit(args, in: peer)).ok)
        }
        return (base, local, peer)
    }

    @Test("Fetch eines Remotes mit Schrägstrich erreicht Vergleich und Erfolgs-/Fehlermarker")
    func slashRemoteFetchPresentation() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        #expect((await remoteActionGit(["remote", "rename", "source", "team/fork"], in: f.local)).ok)
        let executor = GitRunnerExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let store = GitRepositoryStore(executor: executor, coordinator: coordinator)
        var outcome: GitExecutionOutcome?
        _ = store.fetch(repository: f.local, preferences: GitPreferences(),
                        remotes: ["team/fork"], selection: .remote("team/fork")) { value in
            Task { @MainActor in outcome = value }
        }
        try await waitUntil { outcome != nil }
        store.refresh(repository: f.local, scope: .full)
        try await waitUntil { store.snapshot(for: f.local)?.remoteTracking.contains { $0.remote == "team/fork" } == true }
        let snapshot = try #require(store.snapshot(for: f.local))
        let state = try #require(snapshot.remoteTracking.first { $0.remote == "team/fork" })
        #expect(state.branch == "main" && state.localBehind == 1)
        #expect(GitRemoteTrackingPresentation.compactCounts(state, fetch: snapshot.fetch) == "↓1")
        #expect(GitRemoteTrackingPresentation.relevantStates(snapshot.remoteTracking, branch: "main", upstream: nil).contains(state))
        #expect((await remoteActionGit(["remote", "set-url", "team/fork", f.base.appendingPathComponent("missing.git").path], in: f.local)).ok)
        outcome = nil
        _ = store.fetch(repository: f.local, preferences: GitPreferences(),
                        remotes: ["team/fork"], selection: .remote("team/fork")) { value in
            Task { @MainActor in outcome = value }
        }
        try await waitUntil { outcome != nil }
        #expect(GitRemoteTrackingPresentation.compactCounts(state, fetch: store.snapshot(for: f.local)?.fetch) == "↓1 !")
    }

    @Test("Pull von anderer Quelle übernimmt deren Commit und behält den Upstream")
    func explicitPullRetainsUpstream() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let result = await pull(f.local, branch: "main")
        guard case .pulled(.completed(let git)) = result else { Issue.record("Pull scheiterte: \(result)"); return }
        #expect(git.ok)
        #expect(try String(contentsOf: f.local.appendingPathComponent("incoming.txt"), encoding: .utf8) == "incoming\n")
        #expect((await remoteActionGit(["rev-parse", "--symbolic-full-name", "@{upstream}"], in: f.local)).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "refs/remotes/mirror/main")
    }

    @Test("Explizite Quelle funktioniert auch ohne Upstream; fehlender Branch ändert keine Datei")
    func noUpstreamAndMissingBranch() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        #expect((await remoteActionGit(["branch", "--unset-upstream"], in: f.local)).ok)
        let before = await remoteActionGit(["rev-parse", "HEAD"], in: f.local)
        let missing = await pull(f.local, branch: "missing")
        guard case .pulled(.completed(let failed)) = missing else { Issue.record("Unerwarteter Pull-Ausgang"); return }
        #expect(!failed.ok)
        #expect((await remoteActionGit(["rev-parse", "HEAD"], in: f.local)).stdout == before.stdout)
        guard case .pulled(.completed(let success)) = await pull(f.local, branch: "main") else { Issue.record("Pull ohne Upstream scheiterte"); return }
        #expect(success.ok)
        #expect((await remoteActionGit(["checkout", "--detach"], in: f.local)).ok)
        #expect(await pull(f.local, branch: "main", localBranch: "(detached)") == .blocked(.detached))
    }

    @Test("Refspec im Branchfeld wird vor jedem Fetch abgewiesen")
    func rejectsRefspecInjection() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let result = await pull(f.local, branch: "main:refs/heads/injected")
        guard case .inspectionFailed = result else { Issue.record("Ungültiger Branch nicht gestoppt"); return }
        #expect(!(await remoteActionGit(["show-ref", "--verify", "refs/heads/injected"], in: f.local)).ok)
        #expect(!(await remoteActionGit(["show-ref", "--verify", "refs/remotes/source/main"], in: f.local)).ok)
    }

    @Test("Alle-Fetch erfasst skipFetchAll-Remote und markiert nur erfolgreich geholte Quellen")
    func allFetchIncludesSkippedRemote() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        #expect((await remoteActionGit(["config", "remote.source.skipFetchAll", "true"], in: f.local)).ok)
        #expect((await remoteActionGit(["config", "remotes.source", "mirror"], in: f.local)).ok)
        let executor = GitRunnerExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let store = GitRepositoryStore(executor: executor, coordinator: coordinator)
        var outcome: GitExecutionOutcome?
        let lease = store.fetch(repository: f.local, preferences: GitPreferences(),
                                remotes: ["mirror", "source"], selection: .all) { value in
            Task { @MainActor in outcome = value }
        }
        #expect(lease != nil)
        try await waitUntil { outcome != nil }
        guard case .completed(let git) = outcome else { Issue.record("Fetch scheiterte"); return }
        #expect(git.ok)
        #expect(store.snapshot(for: f.local)?.fetch.lastSuccessByRemote.keys.sorted() == ["mirror", "source"])
        #expect((await remoteActionGit(["rev-parse", "refs/remotes/source/main"], in: f.local)).stdout
                == (await remoteActionGit(["rev-parse", "HEAD"], in: f.peer)).stdout)
        #expect(!FileManager.default.fileExists(atPath: f.local.appendingPathComponent("incoming.txt").path))
    }

    @Test("Ein gescheiterter Remote verhindert die übrigen Fetches nicht")
    func partialFetchFailure() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        #expect((await remoteActionGit(["remote", "add", "broken", f.base.appendingPathComponent("missing.git").path], in: f.local)).ok)
        let executor = GitRunnerExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let store = GitRepositoryStore(executor: executor, coordinator: coordinator)
        var outcome: GitExecutionOutcome?
        let lease = store.fetch(repository: f.local, preferences: GitPreferences(),
                                remotes: ["broken", "source"], selection: .all) { value in
            Task { @MainActor in outcome = value }
        }
        #expect(lease != nil)
        try await waitUntil { outcome != nil }
        guard case .completed(let git) = outcome else { Issue.record("Fetch-Ergebnis fehlt"); return }
        #expect(!git.ok)
        let fetch = store.snapshot(for: f.local)?.fetch
        #expect(fetch?.lastSuccessByRemote.keys.sorted() == ["source"])
        #expect(fetch?.errorsByRemote.keys.sorted() == ["broken"])
        #expect(fetch?.error?.contains("missing.git") == true)
        #expect((await remoteActionGit(["rev-parse", "refs/remotes/source/main"], in: f.local)).stdout
                == (await remoteActionGit(["rev-parse", "HEAD"], in: f.peer)).stdout)
        #expect(!FileManager.default.fileExists(atPath: f.local.appendingPathComponent("incoming.txt").path))
    }

    @Test("Geänderte Adresse oder Branch während der Bestätigung stoppt Pull",
          arguments: ["address", "branch"])
    func changedPullContext(_ change: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let coordinator = GitOperationsCoordinator(executor: GitRunnerExecutor())
        var outcome: GitSafePullOutcome?
        _ = GitSafePullRunner.run(repository: f.local, strategy: .ffOnly,
                                 source: GitPullSource(remote: "source", branch: "main", localBranch: "main"),
                                 coordinator: coordinator) { _, proceed in
            Task { @MainActor in
                let args = change == "address"
                    ? ["remote", "set-url", "source", f.base.appendingPathComponent("mirror.git").path]
                    : ["switch", "-c", "other"]
                #expect((await remoteActionGit(args, in: f.local)).ok)
                proceed(true)
            }
        } completion: { value in Task { @MainActor in outcome = value } }
        try await waitUntil { outcome != nil }
        #expect(outcome == .repositoryChanged)
        #expect(!FileManager.default.fileExists(atPath: f.local.appendingPathComponent("incoming.txt").path))
        withExtendedLifetime(coordinator) { }
    }

    private func pull(_ root: URL, branch: String, localBranch: String = "main") async -> GitSafePullOutcome {
        let coordinator = GitOperationsCoordinator(executor: GitRunnerExecutor())
        let outcome = await withCheckedContinuation { continuation in
            _ = GitSafePullRunner.run(repository: root, strategy: .ffOnly,
                                      source: GitPullSource(remote: "source", branch: branch, localBranch: localBranch),
                                      coordinator: coordinator) { _, proceed in proceed(true) }
                completion: { continuation.resume(returning: $0) }
        }
        withExtendedLifetime(coordinator) { }
        return outcome
    }
}

@Suite("Sichtbarer Remote-Fetch-Stand")
struct GitRemoteActionPresentationTests {
    @Test("Ungeprüfter Gleichstand, Fehlversuch und Erfolg sind unterscheidbar")
    func unknownAndFailedEquality() {
        let state = GitRemoteTrackingState(remote: "source", branch: "main",
            refName: "refs/remotes/source/main", oid: "abc", localAhead: 0, localBehind: 0)
        var fetch = GitFetchSnapshot.none
        #expect(FileTreeSidebar.remoteBadgeText(state, fetch: fetch) == "source ?")
        fetch.lastSuccessByRemote["mirror"] = Date()
        #expect(FileTreeSidebar.remoteBadgeText(state, fetch: fetch) == "source ?")
        fetch.lastSuccessByRemote["source"] = Date()
        #expect(FileTreeSidebar.remoteBadgeText(state, fetch: fetch) == "source ✓")
        fetch.errorsByRemote["source"] = "offline"
        #expect(FileTreeSidebar.remoteBadgeText(state, fetch: fetch) == "source !")
    }

    @Test("Ein expliziter Pull-Erfolg aktualisiert nur seinen Remote-Fetch-Stand")
    func pullFetchSuccessIsScoped() {
        let coordinator = GitOperationsCoordinator(executor: GitRunnerExecutor())
        let store = GitRepositoryStore(executor: GitRunnerExecutor(), coordinator: coordinator)
        let root = testTemporaryDirectory().appendingPathComponent("Fastra-PullFreshness-\(UUID())")
        let date = Date(timeIntervalSince1970: 1_000)
        store.recordSuccessfulFetch(repository: root, remote: "source", date: date)
        #expect(store.snapshot(for: root)?.fetch.lastSuccessByRemote == ["source": date])
    }

    @Test("Remote-Namen und Upstream-Branches mit Schrägstrichen bleiben eindeutig")
    func slashRemoteNames() {
        var status = GitStatusSummary.empty
        status.branch = "local/topic"
        status.upstream = "team/fork/remote/topic"
        #expect(GitPullSource.defaultBranch(remote: "team/fork", remotes: ["team", "team/fork"], status: status) == "remote/topic")
        #expect(GitPullSource.defaultBranch(remote: "team", remotes: ["team", "team/fork"], status: status) == "local/topic")
    }
}
