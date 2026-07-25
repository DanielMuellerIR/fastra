import Foundation

/// Das explizite Ziel eines normalen Pushs. Der Remote-Name kommt aus der
/// Reihenfolge der lokalen Repository-Konfiguration; die Adressen stammen aus
/// `git remote get-url --push --all` und entsprechen damit dem wirklichen
/// Push-Ziel einschließlich `pushurl`- und URL-Umschreibungen.
struct GitPushTarget: Equatable {
    let remote: String
    let addresses: [String]

    /// Für die sichtbare Sicherheitsanzeige bleiben Host und Repository-Pfad
    /// erhalten. Eingebettete HTTP-Zugangsdaten oder Query-Secrets erscheinen
    /// dagegen niemals in der Oberfläche.
    var displayAddress: String {
        addresses.map(GitRemoteAddressDisplay.sanitized).joined(separator: "\n")
    }
}

enum GitRemoteConfiguration {
    /// `git remote` sortiert alphabetisch und würde damit z. B. `github` vor
    /// einem zuerst konfigurierten `minipc` liefern. `git config` bewahrt die
    /// Reihenfolge der lokalen Remote-Blöcke.
    static let orderedRemoteArguments = [
        "config", "--includes", "--local", "--null", "--get-regexp",
        "^remote\\..*\\.url$"
    ]

    static func firstRemote(from data: Data) -> String? {
        for rawRecord in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let separator = rawRecord.firstIndex(of: 0x0A),
                  let key = String(data: rawRecord[..<separator], encoding: .utf8)
            else { continue }
            let lower = key.lowercased()
            guard lower.hasPrefix("remote."), lower.hasSuffix(".url"),
                  key.count > "remote..url".count else { continue }
            return String(key.dropFirst("remote.".count).dropLast(".url".count))
        }
        return nil
    }

    static func pushAddresses(from data: Data) -> [String] {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

enum GitRemoteAddressDisplay {
    static func sanitized(_ address: String) -> String {
        guard let schemeEnd = address.range(of: "://") else { return address }
        let authorityStart = schemeEnd.upperBound
        let authorityEnd = address[authorityStart...].firstIndex(where: {
            $0 == "/" || $0 == "?" || $0 == "#"
        }) ?? address.endIndex
        let authority = address[authorityStart..<authorityEnd]
        let visibleAuthority: Substring
        if let at = authority.lastIndex(of: "@") {
            visibleAuthority = Substring("•••@") + authority[authority.index(after: at)...]
        } else {
            visibleAuthority = authority
        }

        let tail = address[authorityEnd...]
        let secretStart = tail.firstIndex(where: { $0 == "?" || $0 == "#" })
        let visibleTail = secretStart.map { tail[..<$0] + "…" } ?? tail
        return String(address[..<authorityStart] + visibleAuthority + visibleTail)
    }
}

/// Bestimmt, ob die primäre Aktion im Änderungen-Tab committen oder pushen
/// soll. Lokale Dateiänderungen haben Vorrang; erst der saubere Arbeitsbaum
/// wechselt bei noch nicht zum ersten Remote übertragenem HEAD in den Push.
enum GitChangesPrimaryAction: Equatable {
    case commit
    case push(GitPushTarget)

    static func resolve(status: GitStatusSummary?, target: GitPushTarget?)
        -> GitChangesPrimaryAction {
        guard let status, let target,
              status.headOID != nil, status.branch != nil, !status.isDetached,
              status.changes.isEmpty else { return .commit }

        let tracksTarget = status.upstream.map {
            $0 == target.remote || $0.hasPrefix(target.remote + "/")
        } ?? false
        if tracksTarget {
            return status.ahead > 0 ? .push(target) : .commit
        }
        // Ohne Upstream zu genau diesem Remote ist ein expliziter Erst-Push
        // sinnvoll. Er setzt danach den Upstream und macht den Zustand eindeutig.
        return .push(target)
    }
}

private final class GitPushTargetResolutionLease: GitCancelling {
    private let lock = NSLock()
    private var current: GitCancelling?
    private var cancelled = false
    private var completed = false

    func install(_ token: GitCancelling) {
        lock.lock()
        if cancelled || completed {
            lock.unlock()
            token.cancel()
            return
        }
        current = token
        lock.unlock()
    }

    func isActive() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !cancelled && !completed
    }

    func claimCompletion() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !completed else { return false }
        completed = true
        current = nil
        return true
    }

    func cancel() {
        lock.lock()
        guard !cancelled, !completed else { lock.unlock(); return }
        cancelled = true
        let token = current
        current = nil
        lock.unlock()
        token?.cancel()
    }
}

enum GitPushTargetResolver {
    typealias Completion = (GitPushTarget?, GitExecutionOutcome?) -> Void

    /// Zwei lokale, asynchrone Git-Lesevorgänge: erst der erste konfigurierte
    /// Remote, dann dessen effektive Push-Adresse. Ein Exit 1 ohne Treffer beim
    /// Config-Lesen bedeutet schlicht „kein Remote“, nicht Prozessversagen.
    @discardableResult
    static func resolve(repository: URL, executor: GitCommandExecuting,
                        completion: @escaping Completion) -> GitCancelling {
        let lease = GitPushTargetResolutionLease()

        func finish(_ target: GitPushTarget?, failure: GitExecutionOutcome?) {
            guard lease.claimCompletion() else { return }
            completion(target, failure)
        }

        let configToken = executor.execute(
            arguments: GitRemoteConfiguration.orderedRemoteArguments,
            in: repository, outputLimit: .default, policy: .default
        ) { configOutcome in
            guard lease.isActive() else { return }
            guard case .completed(let configResult) = configOutcome else {
                finish(nil, failure: configOutcome)
                return
            }
            guard configResult.ok else {
                if configResult.exitCode == 1 && configResult.stdoutData.isEmpty {
                    finish(nil, failure: nil)
                } else {
                    finish(nil, failure: configOutcome)
                }
                return
            }
            guard let remote = GitRemoteConfiguration.firstRemote(
                from: configResult.stdoutData
            ) else {
                finish(nil, failure: nil)
                return
            }

            let addressToken = executor.execute(
                arguments: ["remote", "get-url", "--push", "--all", remote],
                in: repository, outputLimit: .default, policy: .default
            ) { addressOutcome in
                guard lease.isActive() else { return }
                guard case .completed(let addressResult) = addressOutcome,
                      addressResult.ok else {
                    finish(nil, failure: addressOutcome)
                    return
                }
                let addresses = GitRemoteConfiguration.pushAddresses(
                    from: addressResult.stdoutData
                )
                guard !addresses.isEmpty else {
                    finish(nil, failure: addressOutcome)
                    return
                }
                finish(GitPushTarget(remote: remote, addresses: addresses),
                       failure: nil)
            }
            lease.install(addressToken)
        }
        lease.install(configToken)
        return lease
    }
}
