import AppKit
import Foundation

struct GitMutationConfirmation: Equatable {
    let title: String
    let explanation: String
    let confirmTitle: String
    var isDestructive: Bool = false
}

struct GitIdentityChangeNotice {
    let scope: GitIdentityScope
    let repositoryKey: String

    func applies(to candidateRepositoryKey: String) -> Bool {
        scope == .global || repositoryKey == candidateRepositoryKey
    }
}

/// Reine Sicherheitsentscheidungen der erweiterten Aktionen. Die View bleibt
/// dadurch dünn und die wichtigen Blockaden lassen sich ohne Dialog testen.
enum GitAdvancedActionSafety {
    static func branchCreationBlockReason(_ inspection: GitSafetyInspection) -> String? {
        if inspection.operation != nil {
            return L10n.string("Während eines laufenden Git-Vorgangs kann kein neuer Branch erstellt werden.")
        }
        if inspection.hasUnmergedChanges {
            return L10n.string("Löse zuerst die offenen Konflikte.")
        }
        return inspection.isWorkingTreeClean ? nil
            : L10n.string("Ein neuer Branch wird in Fastra nur bei sauberem Arbeitsbaum erstellt.")
    }

    static func stashBlockReason(_ inspection: GitSafetyInspection,
                                 includeUntracked: Bool) -> String? {
        if inspection.operation != nil || inspection.hasUnmergedChanges {
            return L10n.string("Während eines laufenden oder ungelösten Git-Vorgangs legt Fastra keinen Stash an.")
        }
        if inspection.status.changes.isEmpty {
            return L10n.string("Es gibt keine Änderungen für einen Stash.")
        }
        if !includeUntracked {
            let hasTracked = inspection.status.changes.contains {
                $0.staged != nil || ($0.unstaged != nil && $0.unstaged != .untracked)
            }
            if !hasTracked {
                return L10n.string("Es gibt nur unversionierte Dateien. Verwende „Änderungen inkl. unversionierter Dateien stashen“.")
            }
        }
        return nil
    }

    static func selectedCommitConfirmation(commit: GitCommit, command: String,
                                           action: GitActionText,
                                           inspection: GitSafetyInspection)
        -> GitMutationConfirmation {
        GitMutationConfirmation(
            title: L10n.format("%@ %@?", L10n.string(action.labelKey), commit.shortHash),
            explanation: L10n.format(
                "Commit „%@“ (%@) wird auf Branch „%@“ %@.",
                commit.subject, commit.shortHash,
                inspection.status.branch ?? L10n.string("Detached HEAD"),
                command == "revert"
                    ? L10n.string("durch einen neuen Gegen-Commit rückgängig gemacht")
                    : L10n.string("als neuer Commit übernommen")
            ),
            confirmTitle: L10n.string(action.labelKey)
        )
    }
}

enum GitCommitCopyText {
    static func details(_ commit: GitCommit) -> String {
        var lines = [commit.hash, commit.subject]
        if !commit.author.isEmpty { lines.append(commit.author) }
        if !commit.date.isEmpty { lines.append(commit.date) }
        return lines.joined(separator: "\n")
    }
}

extension Workspace {
    // MARK: - Operationszustand

    func gitContinueOperation() {
        guard let operation = gitOperationState else { return }
        guard let arguments = GitAdvancedArguments.operation(operation, action: .continue) else {
            Self.presentGitErrorText(
                label: "Git-Vorgang",
                text: L10n.string("Bisect wird in diesem Ausbau nicht automatisch fortgesetzt. Öffne dafür das Terminal im Projektordner."))
            return
        }
        var policy = GitExecutionPolicy.default
        policy.editorPolicy = .acceptExistingMessage
        runAdvancedMutation(
            arguments: arguments, action: .continueOperation,
            successArgument: operation.localizedName,
            policy: policy,
            requiresIdentity: true,
            readsCommitMessage: true,
            validate: { inspection in
                guard inspection.operation == operation else {
                    return L10n.string("Der erkannte Git-Vorgang hat sich geändert.")
                }
                if operation == .rebase, inspection.rebaseCommand != "pick" {
                    return L10n.string("Dieser Rebase-Schritt benötigt eine interaktive Entscheidung (zum Beispiel edit, squash oder reword). Setze ihn im Terminal im Projektordner fort.")
                }
                return inspection.hasUnmergedChanges
                    ? L10n.string("Es sind noch Konfliktdateien ungelöst. Speichere und markiere sie zuerst als gelöst.")
                    : nil
            }, confirmation: nil,
            confirmationForInspection: { inspection in
                guard let message = inspection.commitMessage else { return nil }
                return GitMutationConfirmation(
                    title: L10n.format("%@ mit dieser Commit-Nachricht fortsetzen?", operation.localizedName),
                    explanation: L10n.string("Fastra übernimmt die vorbereitete Commit-Nachricht unverändert:")
                        + "\n\n" + message,
                    confirmTitle: L10n.string("Unverändert fortsetzen")
                )
            }
        )
    }

    func gitAbortOperation() {
        guard let operation = gitOperationState else { return }
        guard let arguments = GitAdvancedArguments.operation(operation, action: .abort)
        else { return }
        runAdvancedMutation(
            arguments: arguments, action: .abortOperation,
            successArgument: operation.localizedName,
            validate: { inspection in
                inspection.operation == operation ? nil
                    : L10n.string("Der erkannte Git-Vorgang hat sich geändert.")
            }, confirmation: nil,
            confirmationForInspection: { inspection in
                GitMutationConfirmation(
                    title: L10n.format("%@ abbrechen?", operation.localizedName),
                    explanation: L10n.format("Der laufende %@-Vorgang auf Branch „%@“ wird abgebrochen. Git versucht, den Zustand vor dem Vorgang wiederherzustellen.", operation.localizedName, inspection.status.branch ?? L10n.string("Detached HEAD")),
                    confirmTitle: L10n.string("Vorgang abbrechen"), isDestructive: true)
            }
        )
    }

    func gitSkipRebase() {
        guard let arguments = GitAdvancedArguments.operation(.rebase, action: .skip)
        else { return }
        runAdvancedMutation(
            arguments: arguments, action: .rebaseSkip,
            requiresIdentity: true,
            readsCommitMessage: true,
            validate: { inspection in
                guard inspection.operation == .rebase else {
                    return L10n.string("Es läuft kein Rebase, der einen Commit überspringen könnte.")
                }
                return GitPreparedCommitMessage.subject(inspection.commitMessage) == nil
                    ? L10n.string("Der übersprungene Commit ist nicht eindeutig vorbereitet. Setze den Rebase im Terminal fort.")
                    : nil
            }, confirmation: nil,
            confirmationForInspection: { inspection in
                guard let subject = GitPreparedCommitMessage.subject(
                    inspection.commitMessage) else { return nil }
                return GitMutationConfirmation(
                    title: L10n.format("Commit „%@“ im Rebase überspringen?", subject),
                    explanation: L10n.format("Der vorbereitete Commit „%@“ wird ausgelassen. Dessen Änderungen können dadurch aus dem neuen Verlauf verschwinden.", subject),
                    confirmTitle: L10n.string("Commit überspringen"),
                    isDestructive: true
                )
            }
        )
    }

    // MARK: - Branch, Stash und Commit-Aktionen

    func gitCreateBranch(at commitHash: String? = nil) {
        guard !gitOperationsAreBusy else { return }
        if let commitHash,
           !gitLog.contains(where: { $0.hash == commitHash }) {
            Self.presentGitErrorText(label: "Neuer Branch",
                                     text: L10n.string("Der ausgewählte Commit ist nicht mehr im aktuellen Graph enthalten."))
            return
        }
        guard let name = gitBranchNamePromptHandler(commitHash),
              let normalized = GitIdentityInput.normalized(name),
              let context = currentGitActionContext else { return }

        let request = GitOperationRequest(repository: context.root, kind: .refresh,
                                          arguments: ["check-ref-format", "--branch", normalized],
                                          outputLimit: GitOutputLimit(stdoutBytes: 16 * 1024,
                                                                      stderrBytes: 64 * 1024))
        gitOperationsCoordinator.perform(request) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self, context.isCurrent(in: self) else { return }
                guard case .completed(let result) = outcome, result.ok else {
                    if case .completed(let result) = outcome {
                        Self.presentGitError(label: "Branchname", result: result)
                    } else {
                        Self.presentGitExecutionFailure(label: "Branchname", outcome: outcome)
                    }
                    return
                }
                let arguments = GitAdvancedArguments.createBranch(name: normalized,
                                                                  commit: commitHash)
                self.runAdvancedMutation(
                    arguments: arguments, action: .newBranch,
                    successArgument: normalized,
                    kind: .checkout,
                    validate: GitAdvancedActionSafety.branchCreationBlockReason,
                    confirmation: nil)
            }
        }
    }

    func gitStash(includeUntracked: Bool) {
        let args = GitAdvancedArguments.stash(includeUntracked: includeUntracked)
        runAdvancedMutation(
            arguments: args, action: .stash,
            validate: { GitAdvancedActionSafety.stashBlockReason(
                $0, includeUntracked: includeUntracked
            ) }, confirmation: nil,
            confirmationForInspection: { inspection in
                let branch = inspection.status.branch ?? L10n.string("Detached HEAD")
                return GitMutationConfirmation(
                    title: includeUntracked
                        ? L10n.string("Änderungen einschließlich unversionierter Dateien stashen?")
                        : L10n.string("Getrackte Änderungen stashen?"),
                    explanation: includeUntracked
                        ? L10n.format("Branch „%@“: Getrackte und unversionierte Dateien werden aus dem Arbeitsbaum in einen neuen Stash verschoben.", branch)
                        : L10n.format("Branch „%@“: Nur getrackte Änderungen werden in einen neuen Stash verschoben; unversionierte Dateien bleiben liegen.", branch),
                    confirmTitle: L10n.string("Stash anlegen"))
            }
        )
    }

    func gitStashPop() {
        runAdvancedMutation(
            arguments: GitAdvancedArguments.stashPop, action: .stashPop,
            validate: { inspection in
                if inspection.operation != nil || inspection.hasUnmergedChanges {
                    return L10n.string("Schließe zuerst den laufenden Git-Vorgang ab.")
                }
                return inspection.isWorkingTreeClean ? nil
                    : L10n.string("Stash Pop ist in Fastra nur bei einem sauberen Arbeitsbaum möglich.")
            }, confirmation: nil,
            confirmationForInspection: { inspection in
                GitMutationConfirmation(
                    title: L10n.string("Letzten Stash anwenden?"),
                    explanation: L10n.format("Der neueste Stash wird auf Branch „%@“ angewendet und bei Erfolg aus der Stash-Liste entfernt. Konflikte sind möglich.", inspection.status.branch ?? L10n.string("Detached HEAD")),
                    confirmTitle: L10n.string("Stash anwenden"))
            }
        )
    }

    func gitCherryPick(commitHash: String) {
        runSelectedCommitMutation(hash: commitHash, command: "cherry-pick",
                                  action: .cherryPick)
    }

    func gitRevert(commitHash: String) {
        runSelectedCommitMutation(hash: commitHash, command: "revert",
                                  action: .revert)
    }

    private func runSelectedCommitMutation(hash: String, command: String,
                                           action: GitActionText) {
        guard let commit = gitLog.first(where: { $0.hash == hash }) else {
            Self.presentGitErrorText(label: action.labelKey,
                                     text: L10n.string("Der ausgewählte Commit ist nicht mehr im aktuellen Graph enthalten."))
            return
        }
        runAdvancedMutation(
            arguments: command == "revert" ? GitAdvancedArguments.revert(hash)
                : GitAdvancedArguments.cherryPick(hash), action: action,
            requiresIdentity: true,
            validate: { inspection in
                if inspection.operation != nil || inspection.hasUnmergedChanges {
                    return L10n.string("Schließe zuerst den laufenden Git-Vorgang und alle Konflikte ab.")
                }
                return inspection.isWorkingTreeClean ? nil
                    : L10n.string("Diese Aktion ist in Fastra nur bei einem sauberen Arbeitsbaum möglich.")
            }, confirmation: nil,
            confirmationForInspection: { inspection in
                GitAdvancedActionSafety.selectedCommitConfirmation(
                    commit: commit, command: command, action: action,
                    inspection: inspection
                )
            }
        )
    }

    func gitForcePushWithLease() {
        guard let context = currentGitActionContext else { return }
        _ = GitForcePushRunner.run(
            repository: context.root, coordinator: gitOperationsCoordinator,
            decision: { [weak self] target, proceed in
                guard let self, context.isCurrent(in: self) else {
                    proceed(false); return
                }
                proceed(self.gitMutationConfirmationHandler(GitMutationConfirmation(
                    title: L10n.string("Force Push with Lease ausführen?"),
                    explanation: L10n.format("Lokaler Branch „%@“ wird vom unveränderlich aufgelösten Commit %@ zum exakten Ziel „%@“ übertragen. Entfernte Commits werden nur überschrieben, wenn das Ziel noch die erwartete OID %@ besitzt. Fastra aktualisiert genau diesen einen Ref und verwendet niemals --force.", target.branchName, String(target.sourceOID.prefix(12)), target.displayTarget, String(target.expectedOID.prefix(12))),
                    confirmTitle: L10n.string("Mit Lease erzwingen"),
                    isDestructive: true)))
            }
        ) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitRepositoryStore.publishOperations(for: context.root)
                guard context.isCurrent(in: self) else { return }
                self.handleValidatedMutationOutcome(
                    outcome, action: .forcePushWithLease)
            }
        }
        gitRepositoryStore.publishOperations(for: context.root)
    }

    func copyGitCommitHash(_ hash: String) {
        guard gitLog.contains(where: { $0.hash == hash }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hash, forType: .string)
        recordGitSuccess(L10n.string("Commit-Hash kopiert"))
    }

    func copyGitCommitDetails(_ hash: String) {
        guard let commit = gitLog.first(where: { $0.hash == hash }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(GitCommitCopyText.details(commit), forType: .string)
        recordGitSuccess(L10n.string("Commitdetails kopiert"))
    }

    // MARK: - Git-Identität

    func refreshGitIdentity(force: Bool = false) {
        guard gitIdentityInspection == nil,
              (force || gitIdentity == nil),
              let context = currentGitActionContext else { return }
        gitIdentityInspection = GitIdentityReader.read(
            repository: context.root, coordinator: gitOperationsCoordinator
        ) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitIdentityInspection = nil
                guard context.isCurrent(in: self) else { return }
                if case .value(let identity) = outcome { self.gitIdentity = identity }
            }
        }
    }

    func gitConfigureIdentity() {
        guard let context = currentGitActionContext else { return }
        gitIdentityInspection?.cancel()
        gitIdentityInspection = GitIdentityReader.read(
            repository: context.root, coordinator: gitOperationsCoordinator
        ) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitIdentityInspection = nil
                guard context.isCurrent(in: self) else { return }
                switch outcome {
                case .value(let snapshot):
                    self.gitIdentity = snapshot
                    guard let configuration = self.gitIdentityPromptHandler(snapshot) else { return }
                    self.writeGitIdentity(configuration, context: context, then: nil)
                case .failure(let failure):
                    Self.presentGitExecutionFailure(label: "Git-Identität", outcome: failure)
                case .cancelled:
                    break
                }
            }
        }
    }

    func ensureGitIdentity(context: GitActionContext,
                           then: @escaping (GitActionContext) -> Void) {
        gitIdentityInspection?.cancel()
        gitIdentityInspection = GitIdentityReader.read(
            repository: context.root, coordinator: gitOperationsCoordinator
        ) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitIdentityInspection = nil
                guard context.isCurrent(in: self) else { return }
                switch outcome {
                case .value(let snapshot):
                    self.gitIdentity = snapshot
                    if snapshot.isComplete { then(context); return }
                    guard let configuration = self.gitIdentityPromptHandler(snapshot) else { return }
                    self.writeGitIdentity(configuration, context: context, then: then)
                case .failure(let failure):
                    Self.presentGitExecutionFailure(label: "Git-Identität", outcome: failure)
                case .cancelled:
                    break
                }
            }
        }
    }

    private func writeGitIdentity(_ configuration: GitIdentityConfiguration,
                                  context: GitActionContext,
                                  then: ((GitActionContext) -> Void)?) {
        GitIdentityWriter.write(configuration, repository: context.root,
                                coordinator: gitOperationsCoordinator) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                let contextIsCurrent = context.isCurrent(in: self)
                // Ein globaler Schreibvorgang gilt appweit. Sein Ergebnis darf
                // nach einem Projektwechsel weder verschwinden noch fälschlich
                // dem neu geöffneten Repository als lokaler Wert zugerechnet
                // werden. Repository-lokale Ergebnisse bleiben kontextgebunden.
                guard configuration.scope == .global || contextIsCurrent else { return }
                switch outcome {
                case .written:
                    self.recordGitSuccess(configuration.scope == .repository
                        ? L10n.string("Git-Identität für dieses Repository gespeichert")
                        : L10n.string("Globale Git-Identität gespeichert"))
                    if contextIsCurrent {
                        self.gitIdentity = nil
                        self.refreshGitIdentity(force: true)
                    }
                    NotificationCenter.default.post(
                        name: .fastraGitIdentityChanged,
                        object: GitIdentityChangeNotice(
                            scope: configuration.scope,
                            repositoryKey: context.repositoryKey
                        )
                    )
                    if contextIsCurrent { then?(context) }
                case .failure(let failure):
                    if case .completed(let result) = failure {
                        Self.presentGitError(label: "Git-Identität", result: result)
                    } else {
                        Self.presentGitExecutionFailure(label: "Git-Identität", outcome: failure)
                    }
                case .rollbackFailed(let original, let rollback):
                    let originalText = Self.gitExecutionFailureText(original)
                        ?? L10n.string("Das Schreiben der Git-Identität ist fehlgeschlagen.")
                    let rollbackText = Self.gitExecutionFailureText(rollback)
                        ?? L10n.string("Auch das Wiederherstellen der vorherigen Identität ist fehlgeschlagen.")
                    Self.presentGitErrorText(
                        label: "Git-Identität",
                        text: originalText + "\n\n" + rollbackText
                    )
                case .verificationFailed:
                    Self.presentGitErrorText(
                        label: "Git-Identität",
                        text: L10n.string("Git meldet nach dem Schreiben andere Identitätswerte.")
                    )
                case .invalidOrUnconfirmed:
                    Self.presentGitErrorText(label: "Git-Identität",
                        text: L10n.string("Name und E-Mail müssen nichtleer und einzeilig sein. Eine globale Änderung braucht eine separate Bestätigung."))
                case .cancelled:
                    break
                }
            }
        }
    }

    static func defaultGitIdentityPrompt(_ snapshot: GitIdentitySnapshot?)
        -> GitIdentityConfiguration? {
        guard presentGitDialogs else { return nil }
        let alert = NSAlert()
        alert.messageText = L10n.string("Git-Identität konfigurieren")
        alert.informativeText = (snapshot?.sourceDescription ?? L10n.string("Noch nicht gelesen"))
            + "\n" + L10n.string("Git benötigt Name und E-Mail für Commits. Standardmäßig speichert Fastra beide Werte nur in diesem Repository.")
        alert.addButton(withTitle: L10n.string("Speichern"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))

        let name = NSTextField(string: snapshot?.effectiveName ?? "")
        name.placeholderString = L10n.string("Name")
        name.setAccessibilityLabel(L10n.string("Git-Name"))
        let email = NSTextField(string: snapshot?.effectiveEmail ?? "")
        email.placeholderString = L10n.string("E-Mail")
        email.setAccessibilityLabel(L10n.string("Git-E-Mail"))
        let global = NSButton(checkboxWithTitle: L10n.string("Global für alle Repositories speichern"),
                              target: nil, action: nil)
        global.state = .off
        let stack = NSStackView(views: [name, email, global])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 84)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let scope: GitIdentityScope = global.state == .on ? .global : .repository
        var globalConfirmed = false
        if scope == .global {
            let confirmation = NSAlert()
            confirmation.alertStyle = .warning
            confirmation.messageText = L10n.string("Git-Identität wirklich global ändern?")
            confirmation.informativeText = L10n.string("Name und E-Mail gelten danach als Standard für alle Git-Repositories dieses Benutzerkontos. Repository-lokale Werte haben weiterhin Vorrang.")
            confirmation.addButton(withTitle: L10n.string("Global speichern"))
            confirmation.addButton(withTitle: L10n.string("Abbrechen"))
            globalConfirmed = confirmation.runModal() == .alertFirstButtonReturn
            if !globalConfirmed { return nil }
        }
        return GitIdentityConfiguration(name: name.stringValue, email: email.stringValue,
                                        scope: scope, globalConfirmed: globalConfirmed)
    }

    static func defaultGitMutationConfirmation(_ confirmation: GitMutationConfirmation) -> Bool {
        guard presentGitDialogs else { return false }
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.explanation
        alert.alertStyle = confirmation.isDestructive ? .warning : .informational
        alert.addButton(withTitle: confirmation.confirmTitle)
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func defaultGitBranchNamePrompt(commitHash: String?) -> String? {
        promptForText(
            title: L10n.string("Neuer Branch"),
            info: commitHash.map {
                L10n.format("Branch ab Commit %@ erstellen:", String($0.prefix(12)))
            } ?? L10n.string("Branch ab dem aktuell ausgecheckten Commit erstellen:"),
            placeholder: L10n.string("z.B. feature/sichere-suche")
        )
    }

    // MARK: - Gemeinsame sichere Mutation

    private func runAdvancedMutation(
        arguments: [String], action: GitActionText,
        successArgument: String? = nil,
        kind: GitOperationKind = .workingTreeMutation,
        policy: GitExecutionPolicy = .default,
        requiresIdentity: Bool = false,
        readsCommitMessage: Bool = false,
        validate: @escaping GitValidatedMutationRunner.Validator,
        confirmation: GitMutationConfirmation?,
        confirmationForInspection: ((GitSafetyInspection) -> GitMutationConfirmation?)? = nil
    ) {
        // Kontextmenüs werden bei Busy bereits deaktiviert. Dieser zweite Guard
        // schließt zusätzlich das kleine Ereignisfenster schneller Doppelklicks.
        guard let context = currentGitActionContext,
              !gitOperationsCoordinator.state(for: context.root).isBusy else { return }
        let lease = GitValidatedMutationRunner.run(
            repository: context.root, kind: kind,
            identity: arguments.joined(separator: "\u{0}"),
            arguments: arguments, policy: policy,
            requiresIdentity: requiresIdentity,
            readsCommitMessage: readsCommitMessage,
            coordinator: gitOperationsCoordinator,
            validate: validate,
            decision: { [weak self] inspection, proceed in
                guard let self, context.isCurrent(in: self) else { proceed(false); return }
                let currentConfirmation = confirmationForInspection?(inspection) ?? confirmation
                proceed(currentConfirmation.map(self.gitMutationConfirmationHandler) ?? true)
            }
        ) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitRepositoryStore.publishOperations(for: context.root)
                guard context.isCurrent(in: self) else { return }
                if outcome == .missingIdentity {
                    self.ensureGitIdentity(context: context) { [weak self] _ in
                        guard let self else { return }
                        self.runAdvancedMutation(
                            arguments: arguments, action: action,
                            successArgument: successArgument,
                            kind: kind, policy: policy,
                            requiresIdentity: requiresIdentity,
                            readsCommitMessage: readsCommitMessage,
                            validate: validate, confirmation: confirmation,
                            confirmationForInspection: confirmationForInspection
                        )
                    }
                    return
                }
                self.handleValidatedMutationOutcome(outcome, action: action,
                    successArgument: successArgument)
            }
        }
        _ = lease
        gitRepositoryStore.publishOperations(for: context.root)
    }
}

extension Notification.Name {
    static let fastraGitIdentityChanged = Notification.Name("fastra.git.identity.changed")
}
