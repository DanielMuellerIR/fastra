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
                  stderr: String = "") {
        calls[index].completion(.completed(GitResult(
            exitCode: exitCode, stdoutData: stdout, stderrData: Data(stderr.utf8)
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
        ])

        #expect(GitRemoteConfiguration.firstRemote(from: data) == "primary")
    }

    @Test("Resolver liest effektive Push-Adresse des ersten Remotes")
    func resolverUsesFirstRemoteAndPushURL() {
        let executor = PushTargetTestExecutor()
        var resolved: GitPushTarget?
        var failure: GitExecutionOutcome?
        let lease = GitPushTargetResolver.resolve(
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
        executor.complete(1, stdout: Data("push-one\npush-two\n".utf8))

        #expect(resolved == GitPushTarget(remote: "primary",
                                         addresses: ["push-one", "push-two"]))
        #expect(failure == nil)
        _ = lease
    }

    @Test("Fehlender Remote ist ehrlicher leerer Zustand")
    func noRemoteIsNotExecutionFailure() {
        let executor = PushTargetTestExecutor()
        var didComplete = false
        var resolved: GitPushTarget?
        var failure: GitExecutionOutcome?
        let lease = GitPushTargetResolver.resolve(
            repository: URL(fileURLWithPath: "/tmp/repo"), executor: executor
        ) {
            didComplete = true
            resolved = $0
            failure = $1
        }
        executor.complete(0, exitCode: 1)

        #expect(didComplete)
        #expect(resolved == nil)
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

        #expect(GitChangesPrimaryAction.resolve(status: status, target: primary)
                == .push(primary))
    }

    @Test("Dateiänderungen behalten Commit-Vorrang")
    func workingChangesKeepCommit() {
        var status = GitStatusSummary.empty
        status.branch = "main"
        status.headOID = "abc"
        status.changes = [GitChange(path: "README.md", staged: .modified,
                                    unstaged: nil)]

        #expect(GitChangesPrimaryAction.resolve(status: status, target: primary)
                == .commit)
    }

    @Test("Passender Upstream pusht nur bei Ahead")
    func matchingUpstreamUsesAhead() {
        var status = GitStatusSummary.empty
        status.branch = "main"
        status.headOID = "abc"
        status.upstream = "primary/main"
        status.ahead = 0
        #expect(GitChangesPrimaryAction.resolve(status: status, target: primary)
                == .commit)

        status.ahead = 2
        #expect(GitChangesPrimaryAction.resolve(status: status, target: primary)
                == .push(primary))
    }

    @Test("Upstream eines anderen Remotes ersetzt erstes Ziel nicht")
    func otherUpstreamDoesNotReplaceTarget() {
        var status = GitStatusSummary.empty
        status.branch = "main"
        status.headOID = "abc"
        status.upstream = "github/main"

        #expect(GitChangesPrimaryAction.resolve(status: status, target: primary)
                == .push(primary))
    }
}
