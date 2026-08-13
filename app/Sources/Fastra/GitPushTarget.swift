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
    /// einem zuerst konfigurierten `primary` liefern. `git config` bewahrt die
    /// Reihenfolge der lokalen Remote-Blöcke.
    static let orderedRemoteArguments = [
        "config", "--includes", "--local", "--null", "--get-regexp",
        "^remote\\..*\\.url$"
    ]

    static func orderedRemotes(from data: Data) -> [String] {
        var remotes: [String] = []
        var seen = Set<String>()
        for rawRecord in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let separator = rawRecord.firstIndex(of: 0x0A),
                  let key = String(data: rawRecord[..<separator], encoding: .utf8)
            else { continue }
            let lower = key.lowercased()
            guard lower.hasPrefix("remote."), lower.hasSuffix(".url"),
                  key.count > "remote..url".count else { continue }
            let remote = String(
                key.dropFirst("remote.".count).dropLast(".url".count)
            )
            // Ein Remote darf mehrere URL-Zeilen besitzen. Die Oberfläche
            // zeigt trotzdem genau eine Fläche je Name und behält dabei die
            // Reihenfolge der lokalen Konfiguration bei.
            if seen.insert(remote).inserted {
                remotes.append(remote)
            }
        }
        return remotes
    }

    static func firstRemote(from data: Data) -> String? {
        orderedRemotes(from: data).first
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

/// Bestimmt, ob die primäre Aktion im Änderungen-Tab committen oder die
/// getrennten Remote-Ziele zeigen soll. Lokale Dateiänderungen haben Vorrang;
/// erst der saubere Arbeitsbaum wechselt zu den Push-Flächen.
enum GitChangesPrimaryAction: Equatable {
    case commit
    case push([GitPushTarget])

    static func resolve(status: GitStatusSummary?, targets: [GitPushTarget])
        -> GitChangesPrimaryAction {
        guard let status, !targets.isEmpty,
              status.headOID != nil, status.branch != nil, !status.isDetached,
              status.changes.isEmpty else { return .commit }
        // Ein sauberer Branch darf bewusst zu jedem sichtbaren Remote geprüft
        // werden. Ob dort wirklich Commits fehlen, ermittelt erst die gebundene
        // Vorschau gegen den aktuellen Serverstand.
        return .push(targets)
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

struct GitPushTargetResolutionFailure {
    let remote: String?
    let outcome: GitExecutionOutcome
}

enum GitRemoteNameResolver {
    @discardableResult
    static func resolve(
        repository: URL,
        executor: GitCommandExecuting,
        completion: @escaping ([String]?, GitExecutionOutcome?) -> Void
    ) -> GitCancelling {
        executor.execute(
            arguments: GitRemoteConfiguration.orderedRemoteArguments,
            in: repository, outputLimit: .default, policy: .default
        ) { outcome in
            guard case .completed(let result) = outcome else {
                completion(nil, outcome)
                return
            }
            if result.exitCode == 1, result.stdoutData.isEmpty {
                completion([], nil)
            } else if result.ok, !result.stdoutWasTruncated {
                completion(GitRemoteConfiguration.orderedRemotes(
                    from: result.stdoutData
                ), nil)
            } else {
                completion(nil, outcome)
            }
        }
    }
}

enum GitPushTargetResolver {
    typealias Completion = ([GitPushTarget], GitPushTargetResolutionFailure?) -> Void

    /// Liest alle lokal konfigurierten Remotes in Config-Reihenfolge und danach
    /// nacheinander ihre effektiven Push-Adressen. Ein Exit 1 ohne Treffer beim
    /// Config-Lesen bedeutet schlicht „kein Remote“, nicht Prozessversagen.
    @discardableResult
    static func resolveAll(repository: URL, executor: GitCommandExecuting,
                           completion: @escaping Completion) -> GitCancelling {
        let lease = GitPushTargetResolutionLease()

        func finish(_ targets: [GitPushTarget],
                    failure: GitPushTargetResolutionFailure?) {
            guard lease.claimCompletion() else { return }
            completion(targets, failure)
        }

        let configToken = executor.execute(
            arguments: GitRemoteConfiguration.orderedRemoteArguments,
            in: repository, outputLimit: .default, policy: .default
        ) { configOutcome in
            guard lease.isActive() else { return }
            guard case .completed(let configResult) = configOutcome else {
                finish([], failure: .init(remote: nil, outcome: configOutcome))
                return
            }
            guard configResult.ok, !configResult.stdoutWasTruncated else {
                if configResult.exitCode == 1 && configResult.stdoutData.isEmpty {
                    finish([], failure: nil)
                } else {
                    finish([], failure: .init(remote: nil, outcome: configOutcome))
                }
                return
            }
            let remotes = GitRemoteConfiguration.orderedRemotes(
                from: configResult.stdoutData
            )
            guard !remotes.isEmpty else {
                finish([], failure: nil)
                return
            }

            var targets: [GitPushTarget] = []
            var firstFailure: GitPushTargetResolutionFailure?
            func resolveAddress(at index: Int) {
                guard lease.isActive() else { return }
                guard index < remotes.count else {
                    finish(targets, failure: firstFailure)
                    return
                }
                let remote = remotes[index]
                let addressToken = executor.execute(
                    arguments: ["remote", "get-url", "--push", "--all", remote],
                    in: repository, outputLimit: .default, policy: .default
                ) { addressOutcome in
                    guard lease.isActive() else { return }
                    guard case .completed(let addressResult) = addressOutcome,
                          addressResult.ok,
                          !addressResult.stdoutWasTruncated else {
                        if firstFailure == nil {
                            firstFailure = .init(remote: remote,
                                                 outcome: addressOutcome)
                        }
                        resolveAddress(at: index + 1)
                        return
                    }
                    let addresses = GitRemoteConfiguration.pushAddresses(
                        from: addressResult.stdoutData
                    )
                    guard !addresses.isEmpty else {
                        if firstFailure == nil {
                            firstFailure = .init(remote: remote,
                                                 outcome: addressOutcome)
                        }
                        resolveAddress(at: index + 1)
                        return
                    }
                    targets.append(GitPushTarget(remote: remote,
                                                 addresses: addresses))
                    resolveAddress(at: index + 1)
                }
                lease.install(addressToken)
            }
            resolveAddress(at: 0)
        }
        lease.install(configToken)
        return lease
    }

    /// Löst ausschließlich den ERSTEN lokal konfigurierten Remote auf. Ein
    /// Fehler dieses Ziels darf niemals dazu führen, dass ein normaler Push
    /// still auf den nächsten, noch erreichbaren Remote ausweicht.
    @discardableResult
    static func resolvePrimary(
        repository: URL,
        executor: GitCommandExecuting,
        completion: @escaping (GitPushTarget?, GitPushTargetResolutionFailure?) -> Void
    ) -> GitCancelling {
        let lease = GitPushTargetResolutionLease()

        func finish(_ target: GitPushTarget?,
                    failure: GitPushTargetResolutionFailure?) {
            guard lease.claimCompletion() else { return }
            completion(target, failure)
        }

        let configToken = executor.execute(
            arguments: GitRemoteConfiguration.orderedRemoteArguments,
            in: repository, outputLimit: .default, policy: .default
        ) { configOutcome in
            guard lease.isActive() else { return }
            guard case .completed(let configResult) = configOutcome else {
                finish(nil, failure: .init(remote: nil, outcome: configOutcome))
                return
            }
            guard configResult.ok, !configResult.stdoutWasTruncated else {
                if configResult.exitCode == 1 && configResult.stdoutData.isEmpty {
                    finish(nil, failure: nil)
                } else {
                    finish(nil, failure: .init(remote: nil, outcome: configOutcome))
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
                      addressResult.ok,
                      !addressResult.stdoutWasTruncated else {
                    finish(nil, failure: .init(remote: remote,
                                               outcome: addressOutcome))
                    return
                }
                let addresses = GitRemoteConfiguration.pushAddresses(
                    from: addressResult.stdoutData
                )
                guard !addresses.isEmpty else {
                    finish(nil, failure: .init(remote: remote,
                                               outcome: addressOutcome))
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

    /// Löst genau den sichtbar gewählten Remote neu auf. Der Config-Leseschritt
    /// stellt zuerst sicher, dass dieser Name weiterhin lokal konfiguriert ist;
    /// erst danach wird ausschließlich seine effektive Push-Adresse gelesen.
    @discardableResult
    static func resolve(remote expectedRemote: String, repository: URL,
                        executor: GitCommandExecuting,
                        completion: @escaping (GitPushTarget?, GitExecutionOutcome?) -> Void)
        -> GitCancelling {
        let lease = GitPushTargetResolutionLease()

        func finish(_ target: GitPushTarget?,
                    failure: GitExecutionOutcome?) {
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
            guard configResult.ok, !configResult.stdoutWasTruncated else {
                if configResult.exitCode == 1 && configResult.stdoutData.isEmpty {
                    finish(nil, failure: nil)
                } else {
                    finish(nil, failure: configOutcome)
                }
                return
            }
            guard GitRemoteConfiguration.orderedRemotes(
                from: configResult.stdoutData
            ).contains(expectedRemote) else {
                finish(nil, failure: nil)
                return
            }

            let addressToken = executor.execute(
                arguments: ["remote", "get-url", "--push", "--all",
                            expectedRemote],
                in: repository, outputLimit: .default, policy: .default
            ) { addressOutcome in
                guard lease.isActive() else { return }
                guard case .completed(let addressResult) = addressOutcome,
                      addressResult.ok,
                      !addressResult.stdoutWasTruncated else {
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
                finish(GitPushTarget(remote: expectedRemote,
                                     addresses: addresses), failure: nil)
            }
            lease.install(addressToken)
        }
        lease.install(configToken)
        return lease
    }

    /// Kompatibler Helfer für Stellen, die bewusst nur das erste Ziel brauchen.
    @discardableResult
    static func resolve(repository: URL, executor: GitCommandExecuting,
                        completion: @escaping (GitPushTarget?, GitExecutionOutcome?) -> Void)
        -> GitCancelling {
        resolvePrimary(repository: repository, executor: executor) { target, failure in
            completion(target, failure?.outcome)
        }
    }
}
