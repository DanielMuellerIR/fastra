import Combine
import Foundation
import Testing
@testable import Fastra

private final class PushTargetTestExecutor: GitCommandExecuting {
    final class Token: GitCancelling {
        private(set) var cancelled = false
        func cancel() { cancelled = true }
    }

    struct Call {
        let arguments: [String]
        let completion: (GitExecutionOutcome) -> Void
        let token: Token
    }

    private(set) var calls: [Call] = []

    @discardableResult
    func execute(arguments: [String], in directory: URL,
                 outputLimit: GitOutputLimit, policy: GitExecutionPolicy,
                 completion: @escaping (GitExecutionOutcome) -> Void)
        -> GitCancelling {
        let token = Token()
        calls.append(Call(arguments: arguments, completion: completion,
                          token: token))
        return token
    }

    func complete(_ index: Int, exitCode: Int32 = 0, stdout: Data = Data(),
                  stderr: String = "", stdoutWasTruncated: Bool = false) {
        calls[index].completion(.completed(GitResult(
            exitCode: exitCode, stdoutData: stdout, stderrData: Data(stderr.utf8),
            stdoutWasTruncated: stdoutWasTruncated
        )))
    }
}

private func remoteConfigData(_ entries: [(String, String)]) -> Data {
    var data = Data()
    for (key, value) in entries {
        data.append(Data("\(key)\n\(value)".utf8))
        data.append(0)
    }
    return data
}

@Suite("Explizites Git-Push-Ziel")
struct GitPushTargetTests {
    let primary = GitPushTarget(remote: "primary",
                               addresses: ["git@example.test:repos/project.git"])

    @Test("Erster lokaler Remote folgt Config-Reihenfolge, nicht Alphabet")
    func configOrderWins() {
        let data = remoteConfigData([
            ("remote.primary.url", "git@example.test:repos/project.git"),
            ("remote.github.url", "https://github.com/example/projekt.git"),
            ("remote.primary.url", "second-fetch-address"),
        ])

        #expect(GitRemoteConfiguration.orderedRemotes(from: data)
                == ["primary", "github"])
        #expect(GitRemoteConfiguration.firstRemote(from: data) == "primary")
    }

    @Test("Resolver liest alle effektiven Push-Adressen in Config-Reihenfolge")
    func resolverUsesAllRemotesAndPushURLs() {
        let executor = PushTargetTestExecutor()
        var resolved: [GitPushTarget] = []
        var failure: GitPushTargetResolutionFailure?
        let lease = GitPushTargetResolver.resolveAll(
            repository: URL(fileURLWithPath: "/tmp/repo"), executor: executor
        ) {
            resolved = $0
            failure = $1
        }

        #expect(executor.calls.map(\.arguments) == [
            GitRemoteConfiguration.orderedRemoteArguments
        ])
        executor.complete(0, stdout: remoteConfigData([
            ("remote.primary.url", "fetch-address"),
            ("remote.github.url", "github-address"),
        ]))
        #expect(executor.calls.map(\.arguments) == [
            GitRemoteConfiguration.orderedRemoteArguments,
            ["remote", "get-url", "--push", "--all", "primary"],
        ])
        executor.complete(1, stdout: Data("primary-push\n".utf8))
        #expect(executor.calls.map(\.arguments) == [
            GitRemoteConfiguration.orderedRemoteArguments,
            ["remote", "get-url", "--push", "--all", "primary"],
            ["remote", "get-url", "--push", "--all", "github"],
        ])
        executor.complete(2, stdout: Data("github-push\n".utf8))

        #expect(resolved == [
            GitPushTarget(remote: "primary", addresses: ["primary-push"]),
            GitPushTarget(remote: "github", addresses: ["github-push"]),
        ])
        #expect(failure == nil)
        _ = lease
    }

    @Test("Defekter später Remote behält bereits aufgelöste Push-Ziele")
    func laterRemoteFailureKeepsValidTargets() {
        let executor = PushTargetTestExecutor()
        var resolved: [GitPushTarget] = []
        var failure: GitPushTargetResolutionFailure?
        let lease = GitPushTargetResolver.resolveAll(
            repository: URL(fileURLWithPath: "/tmp/repo"), executor: executor
        ) {
            resolved = $0
            failure = $1
        }
        executor.complete(0, stdout: remoteConfigData([
            ("remote.primary.url", "primary-fetch"),
            ("remote.broken.url", "broken-fetch"),
            ("remote.github.url", "github-fetch"),
        ]))
        executor.complete(1, stdout: Data("primary-push\n".utf8))
        executor.complete(2, exitCode: 2, stderr: "defekter Remote")
        executor.complete(3, stdout: Data("github-push\n".utf8))

        #expect(resolved.map(\.remote) == ["primary", "github"])
        #expect(failure?.remote == "broken")
        guard case .completed(let result) = failure?.outcome else {
            Issue.record("Der Remote-Fehler fehlt")
            return
        }
        #expect(result.stderr == "defekter Remote")
        _ = lease
    }

    @Test("Verspäteter alter Anzeige-Refresh überschreibt den jüngeren nicht")
    @MainActor
    func staleDisplayRefreshCannotPublish() async {
        let executor = PushTargetTestExecutor()
        let coordinator = GitOperationsCoordinator(executor: executor)
        let suite = "Fastra-PushTarget-Race-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults,
                                  gitOperationsCoordinator: coordinator)
        workspace.projectURL = URL(fileURLWithPath: "/tmp/repo")
        var publishedRemotes: [[String]] = []
        let observation = workspace.$gitPushTargets.sink { targets in
            let remotes = targets.map(\.remote)
            if !remotes.isEmpty { publishedRemotes.append(remotes) }
        }

        workspace.refreshGitPushTarget()
        #expect(executor.calls.count == 1)
        executor.complete(0, stdout: remoteConfigData([
            ("remote.old.url", "old-fetch")
        ]))
        #expect(executor.calls.count == 2)
        executor.complete(1, stdout: Data("old-push\n".utf8))

        // Die alte Auflösung ist nun fertig, ihre Veröffentlichung liegt aber
        // noch auf der Main-Queue. Der zweite Refresh muss sie allein über die
        // Anfrage-ID entwerten; ein nachträgliches cancel() käme zu spät.
        workspace.refreshGitPushTarget()
        #expect(executor.calls.count == 3)
        executor.complete(2, stdout: remoteConfigData([
            ("remote.new.url", "new-fetch")
        ]))
        #expect(executor.calls.count == 4)
        executor.complete(3, stdout: Data("new-push\n".utf8))

        #expect(await waitUntil {
            workspace.gitPushTargets.map(\.remote) == ["new"]
        })
        #expect(publishedRemotes == [["new"]])
        _ = observation
    }

    @Test("Gezielte Auflösung fragt nur den ausgewählten Remote ab")
    func targetedResolverReadsOnlySelectedRemote() {
        let executor = PushTargetTestExecutor()
        var resolved: GitPushTarget?
        let lease = GitPushTargetResolver.resolve(
            remote: "github",
            repository: URL(fileURLWithPath: "/tmp/repo"),
            executor: executor
        ) { target, _ in
            resolved = target
        }
        executor.complete(0, stdout: remoteConfigData([
            ("remote.primary.url", "primary-fetch"),
            ("remote.github.url", "github-fetch"),
        ]))
        #expect(executor.calls.map(\.arguments) == [
            GitRemoteConfiguration.orderedRemoteArguments,
            ["remote", "get-url", "--push", "--all", "github"],
        ])
        executor.complete(1, stdout: Data("github-push\n".utf8))
        #expect(resolved == GitPushTarget(remote: "github",
                                         addresses: ["github-push"]))
        _ = lease
    }

    @Test("Fehlender Remote ist ehrlicher leerer Zustand")
    func noRemoteIsNotExecutionFailure() {
        let executor = PushTargetTestExecutor()
        var didComplete = false
        var resolved: [GitPushTarget] = []
        var failure: GitPushTargetResolutionFailure?
        let lease = GitPushTargetResolver.resolveAll(
            repository: URL(fileURLWithPath: "/tmp/repo"), executor: executor
        ) {
            didComplete = true
            resolved = $0
            failure = $1
        }
        executor.complete(0, exitCode: 1)

        #expect(didComplete)
        #expect(resolved.isEmpty)
        #expect(failure == nil)
        _ = lease
    }

    @Test("Anzeige verbirgt URL-Zugangsdaten und Query-Secrets")
    func addressDisplayRedactsSecrets() {
        let at = String(UnicodeScalar(64)!)
        let address = "https://opaque" + at
            + "example.test/team/repo.git?access=hidden"
        let expected = "https://•••" + at + "example.test/team/repo.git…"
        #expect(GitRemoteAddressDisplay.sanitized(address) == expected)
        #expect(GitRemoteAddressDisplay.sanitized(
            "git@example.test:repos/project.git"
        ) == "git@example.test:repos/project.git")
    }

    @Test("Sauberer Branch ohne Upstream zum ersten Remote bietet Push")
    func cleanBranchWithoutTargetUpstreamOffersPush() {
        var status = GitStatusSummary.empty
        status.branch = "main"
        status.headOID = "abc"

        #expect(GitChangesPrimaryAction.resolve(status: status,
                                                targets: [primary])
                == .push([primary]))
    }

    @Test("Dateiänderungen behalten Commit-Vorrang")
    func workingChangesKeepCommit() {
        var status = GitStatusSummary.empty
        status.branch = "main"
        status.headOID = "abc"
        status.changes = [GitChange(path: "README.md", staged: .modified,
                                    unstaged: nil)]

        #expect(GitChangesPrimaryAction.resolve(status: status,
                                                targets: [primary])
                == .commit)
    }

    @Test("Sauberer Branch zeigt alle Ziele auch ohne Ahead-Zähler")
    func cleanBranchShowsEveryTarget() {
        var status = GitStatusSummary.empty
        status.branch = "main"
        status.headOID = "abc"
        status.upstream = "primary/main"
        status.ahead = 0
        let github = GitPushTarget(remote: "github",
                                   addresses: ["github-address"])
        #expect(GitChangesPrimaryAction.resolve(
            status: status, targets: [primary, github]
        ) == .push([primary, github]))
    }

    @Test("Upstream eines anderen Remotes ersetzt erstes Ziel nicht")
    func otherUpstreamDoesNotReplaceTarget() {
        var status = GitStatusSummary.empty
        status.branch = "main"
        status.headOID = "abc"
        status.upstream = "github/main"

        #expect(GitChangesPrimaryAction.resolve(status: status,
                                                targets: [primary])
                == .push([primary]))
    }
}
