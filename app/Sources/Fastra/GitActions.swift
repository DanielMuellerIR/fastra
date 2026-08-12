import AppKit
import Darwin

struct GitActionFeedback: Identifiable, Equatable {
    let id = UUID()
    let message: String

    static func == (lhs: GitActionFeedback, rhs: GitActionFeedback) -> Bool {
        lhs.id == rhs.id && lhs.message == rhs.message
    }
}

struct GitActionContext: Equatable {
    let root: URL
    let repositoryKey: String
    let projectGeneration: UInt64

    init(root: URL, projectGeneration: UInt64) {
        self.root = root
        self.repositoryKey = GitOperationRequest.canonicalRepositoryPath(root)
        self.projectGeneration = projectGeneration
    }

    func isCurrent(in workspace: Workspace) -> Bool {
        workspace.projectGeneration == projectGeneration
            && workspace.projectURL.map(GitOperationRequest.canonicalRepositoryPath)
                == repositoryKey
    }
}

/// Baut einen Push, dessen geprüfte Adresse nur in der Prozessumgebung liegt.
/// Eine einmalige Zufallsadresse wird im SELBEN Git-Prozess genau einmal auf
/// das bestätigte Ziel abgebildet. Git wendet URL-Umschreibungen nicht erneut
/// auf das Ergebnis an; selbst eine inzwischen geänderte Repository-
/// Konfiguration kann das Ziel deshalb nicht mehr umleiten.
enum GitPushCommand {
    struct Invocation: Equatable {
        let arguments: [String]
        let environment: [String: String]
        let configuration: [GitConfigurationEntry]
    }

    static func verifiedAddress(of target: GitPushTarget) -> String? {
        guard target.addresses.count == 1,
              let address = target.addresses.first, !address.isEmpty else { return nil }
        return address
    }

    /// Exit 1 ohne Ausgabe bedeutet bei `git config --get-regexp`: kein
    /// Treffer. Jede Ausgabe oder ein technischer Fehler macht die Zielbindung
    /// dagegen uneindeutig.
    static func rewriteRulesAreAbsent(_ result: GitResult) -> Bool {
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty && (result.ok || result.exitCode == 1)
    }

    private static func boundInvocation(address: String, temporaryRemote: String,
                                        arguments: [String]) -> Invocation {
        let sentinel = "fastra-bound-\(UUID().uuidString.lowercased())://target"
        return Invocation(
            arguments: arguments,
            // Git-Ausgaben, die Fastra maschinell einordnet, bleiben damit
            // unabhängig von der Sprache des angemeldeten Nutzers stabil.
            // GIT_CONFIG_COUNT liegt auf Command-Scope. Der echte Zielwert
            // bleibt in der Umgebung; argv enthält weder Zugangsdaten noch
            // die Adresse. `url` UND `pushurl` tragen denselben einmaligen
            // Sentinel; damit kann auch eine breite `pushInsteadOf`-Regel den
            // Push nicht vor der exakten Abbildung auf das bestätigte Ziel
            // abfangen.
            environment: ["LC_ALL": "C", "LANG": "C"],
            configuration: [
                GitConfigurationEntry(
                    key: "remote.\(temporaryRemote).url", value: sentinel
                ),
                // Eine explizite Push-Adresse verhindert, dass eine kurz vor
                // dem Prozessstart ergänzte `pushInsteadOf`-Regel den noch
                // nicht aufgelösten Sentinel-Präfix als eigenes Ziel abfängt.
                GitConfigurationEntry(
                    key: "remote.\(temporaryRemote).pushurl", value: sentinel
                ),
                GitConfigurationEntry(
                    key: "url.\(address).insteadOf", value: sentinel
                ),
            ]
        )
    }

    static func inspectionInvocation(address: String, temporaryRemote: String,
                                     arguments: [String]) -> Invocation {
        boundInvocation(address: address, temporaryRemote: temporaryRemote,
                        arguments: arguments)
    }

    static func invocation(remote: String, address: String, refspec: String,
                           remoteRef: String, expectedOID: String?,
                           temporaryRemote: String) -> Invocation {
        let expected = expectedOID ?? ""
        return boundInvocation(
            address: address,
            temporaryRemote: temporaryRemote,
            arguments: [
                "-c", "remote.\(temporaryRemote).fetch=+refs/heads/*:refs/remotes/\(remote)/*",
                "push", "--porcelain",
                "--force-with-lease=\(remoteRef):\(expected)",
                temporaryRemote, refspec,
            ]
        )
    }
}

/// Kuratierte Git-Aktionen (Projekt- & Git-Ausbau, Etappe 2, Schritt 4).
/// Philosophie: **Git liefert Logik, Fastra macht die häufigen — und ein paar
/// pfiffige — Aufrufe per Knopf zugänglich**, für Leute, die Git verstehen,
/// sich aber Syntax/Parameter nicht merken wollen.
///
/// Alle Aktionen laufen asynchron über den zentral koordinierten `GitRunner`
/// (nie Main-Thread-Block).
/// Erfolg → still den Status auffrischen (der Branch-Zähler / Dateibaum
/// aktualisiert sich sichtbar). Fehler → die ECHTE git-Ausgabe zeigen
/// (UX-Regel), nicht schlucken.
extension Workspace {

    // MARK: Häufige Aktionen

    /// Alle Änderungen committen (`git add -A` + `git commit -m`). Für Daniels
    /// Zielgruppe der 80-%-Fall — kein manuelles Stagen nötig. Fragt die
    /// Commit-Botschaft in einem kleinen Dialog ab.
    func gitCommitAll() {
        guard projectURL != nil, !gitOperationsAreBusy else { return }
        guard let message = Self.promptForText(
            title: L10n.string("Commit"),
            info: L10n.string("Alle Änderungen werden committet. Kurze Botschaft:"),
            placeholder: L10n.string("z.B. Tippfehler in README behoben")
        ), !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        guard let context = currentGitActionContext else { return }
        ensureGitIdentity(context: context) { [weak self] context in
            self?.runGitAction(["add", "-A"], label: "Stagen", context: context,
                               then: {
                [weak self] context in
                self?.runGitAction(["commit", "-m", message], label: "Commit",
                                   context: context)
            })
        }
    }

    /// Letzten Commit um die aktuellen Änderungen ergänzen, Botschaft behalten
    /// (`git commit --amend --no-edit`) — die pfiffige Variante „Ups, das
    /// gehörte noch dazu", ohne die Message anzufassen.
    func gitAmendNoEdit() {
        guard projectURL != nil, !gitOperationsAreBusy else { return }
        guard let context = currentGitActionContext else { return }
        ensureGitIdentity(context: context) { [weak self] context in
            self?.runGitAction(["add", "-A"], label: "Stagen", context: context,
                               then: {
                [weak self] context in
                self?.runGitAction(["commit", "--amend", "--no-edit"],
                                   label: "Ergänzen", context: context)
            })
        }
    }

    // MARK: - Datei-genaues Staging (Änderungen-Ansicht, VS-Code-artig)

    /// Eine Datei bereitstellen (`git add -- <path>`). Deckt geänderte, gelöschte
    /// (die Löschung wird bereitgestellt) und untracked Dateien ab.
    func gitStage(path: String) {
        gitStage(paths: [path])
    }

    /// Mehrere Dateien in EINEM `git add` bereitstellen (Mehrfachauswahl in
    /// der Änderungen-Ansicht, Daniel-Wunsch 2026-07-30).
    func gitStage(paths: [String]) {
        guard !paths.isEmpty else { return }
        runGitAction(["add", "--"] + paths, label: "Bereitstellen")
    }

    /// Alle Änderungen bereitstellen (`git add -A`).
    func gitStageAll() {
        runGitAction(["add", "-A"], label: "Alles bereitstellen")
    }

    /// Eine Datei aus dem Index nehmen (`git reset -q HEAD -- <path>`). Bewusst
    /// `reset` statt `restore --staged` — breit kompatibel auch mit älterem git.
    func gitUnstage(path: String) {
        gitUnstage(paths: [path])
    }

    /// Mehrere Dateien in EINEM `git reset` aus dem Index nehmen
    /// (Mehrfachauswahl in der Änderungen-Ansicht).
    func gitUnstage(paths: [String]) {
        guard !paths.isEmpty else { return }
        runGitAction(["reset", "-q", "HEAD", "--"] + paths,
                     label: "Aus Bereitstellung nehmen")
    }

    /// Alle bereitgestellten Änderungen aus dem Index nehmen (`git reset -q HEAD`).
    func gitUnstageAll() {
        runGitAction(["reset", "-q", "HEAD"], label: "Bereitstellung aufheben")
    }

    /// Ungespeicherte Änderungen an einer Datei VERWERFEN (destruktiv!). Erst
    /// Rückfrage. Untracked → Datei löschen (git kennt sie nicht); getrackt →
    /// Working-Tree auf den Index-/HEAD-Stand zurücksetzen (`git checkout --`).
    /// Nur in der Unstaged-Sektion angeboten (VS-Code-Platzierung).
    func gitDiscard(change: GitChange) {
        // Repository UND Aktionskontext vor der Rückfrage gemeinsam einfrieren.
        guard let context = currentGitActionContext, change.isPathActionable
        else { return }
        let isUntracked = change.unstaged == .untracked
        guard Self.confirmDiscard(name: change.name, untracked: isUntracked) else { return }
        gitDiscard(change: change, context: context)
    }

    /// Führt das Verwerfen mit dem VOR der Rückfrage eingefrorenen Kontext aus.
    /// Der modale Dialog dreht eine eigene Ereignisschleife, in der das Fenster
    /// längst ein anderes Projekt öffnen kann. Ohne die Aktualitätsprüfung würde
    /// eine Bestätigung für Repository A eine gleichnamige Datei im inzwischen
    /// geöffneten Repository B verwerfen (Review 2026-08-10).
    func gitDiscard(change: GitChange, context: GitActionContext) {
        guard let path = change.actionPath else { return }
        guard context.isCurrent(in: self) else {
            Self.presentStaleGitContext(label: "Verwerfen")
            return
        }
        let root = context.root
        let isUntracked = change.unstaged == .untracked
        if isUntracked {
            // Untracked: Datei physisch entfernen (VS-Code-Verhalten „Discard").
            // Ein Fehlschlag (Rechte, bereits gesperrt) wird sichtbar gemeldet —
            // die Datei stünde sonst weiter in der Liste, ohne dass klar wäre,
            // warum das Verwerfen „nichts getan" hat (Review 2026-08-02).
            do {
                try Self.removeUntrackedFile(at: root.appendingPathComponent(path))
            } catch {
                Self.presentGitErrorText(
                    label: "Verwerfen",
                    text: L10n.format("„%@“ konnte nicht gelöscht werden: %@",
                                      change.name, error.localizedDescription))
            }
            refreshGitStatus()
            refreshOpenGitViews()
        } else {
            runGitAction(["checkout", "--", path], label: "Verwerfen",
                         context: context)
        }
    }

    /// Mehrere Dateien auf einen Schlag verwerfen (Mehrfachauswahl in der
    /// Änderungen-Ansicht, Daniel-Wunsch 2026-07-30). EINE Rückfrage für die
    /// ganze Auswahl; danach werden unversionierte Dateien gelöscht und alle
    /// getrackten in einem gemeinsamen `git checkout --` zurückgesetzt.
    func gitDiscard(changes: [GitChange]) {
        // Wie im Einzelfall: Repository und Aktionskontext werden gemeinsam vor
        // der Rückfrage eingefroren und danach auf Aktualität geprüft.
        guard let context = currentGitActionContext else { return }
        let plan = GitDiscardPlan(changes: changes)
        guard !plan.isEmpty else { return }
        // Einzelfall: der bestehende Dialog nennt den Dateinamen — präziser.
        if plan.totalCount == 1, let only = plan.changes.first {
            gitDiscard(change: only)
            return
        }
        guard Self.confirmDiscard(count: plan.totalCount,
                                  untrackedCount: plan.untrackedPaths.count) else { return }
        gitDiscard(changes: changes, context: context)
    }

    /// Mehrfach-Verwerfen mit dem eingefrorenen Kontext (Begründung siehe
    /// `gitDiscard(change:context:)`).
    func gitDiscard(changes: [GitChange], context: GitActionContext) {
        let plan = GitDiscardPlan(changes: changes)
        guard !plan.isEmpty else { return }
        guard context.isCurrent(in: self) else {
            Self.presentStaleGitContext(label: "Verwerfen")
            return
        }
        let root = context.root
        // Teil-Löschfehler nicht verschlucken: Was sich nicht löschen ließ,
        // wird gesammelt und EINMAL sichtbar gemeldet — sonst blieben Dateien
        // kommentarlos in der Liste stehen (Review 2026-08-02).
        var deleteFailures: [String] = []
        for path in plan.untrackedPaths {
            do {
                try Self.removeUntrackedFile(at: root.appendingPathComponent(path))
            } catch {
                deleteFailures.append((path as NSString).lastPathComponent)
            }
        }
        if !deleteFailures.isEmpty {
            Self.presentGitErrorText(
                label: "Verwerfen",
                text: L10n.format("%ld Datei(en) konnten nicht gelöscht werden: %@",
                                  deleteFailures.count,
                                  deleteFailures.joined(separator: ", ")))
        }
        if plan.trackedPaths.isEmpty {
            refreshGitStatus()
            refreshOpenGitViews()
        } else {
            runGitAction(["checkout", "--"] + plan.trackedPaths,
                         label: "Verwerfen", context: context)
        }
    }

    /// Einheitliche Meldung, wenn ein eingefrorener Kontext nach der Rückfrage
    /// nicht mehr das aktuelle Projekt beschreibt. Bewusst derselbe Text wie in
    /// den übrigen Sicherheitsabbrüchen (siehe `GitConflictActions`).
    static func presentStaleGitContext(label: String) {
        presentGitErrorText(
            label: label,
            text: L10n.string("Repository, Branch oder Arbeitsbaum haben sich während der Sicherheitsprüfung geändert. Prüfe den neuen Stand und starte die Aktion erneut."))
    }

    /// Bereitgestellte Änderungen committen. Nichts bereitgestellt → erst alles
    /// bereitstellen, dann committen (VS-Code-Verhalten). Leere Botschaft = Beep.
    func gitCommit(message: String) {
        guard !gitOperationsAreBusy else { return }
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { NSSound.beep(); return }
        guard projectURL != nil else { return }
        guard let context = currentGitActionContext else { return }
        ensureGitIdentity(context: context) { [weak self] context in
            guard let self else { return }
            let done: (GitActionContext) -> Void = { [weak self] _ in
                self?.commitMessage = ""
                self?.refreshGitRepositoryFully()
                self?.refreshOpenGitViews()
            }
            if self.gitStatus?.stagedChanges.isEmpty == false {
                self.runGitAction(["commit", "-m", msg], label: "Commit",
                                  context: context, then: done)
            } else {
                self.runGitAction(["add", "-A"], label: "Bereitstellen",
                                  context: context, then: { [weak self] context in
                    self?.runGitAction(["commit", "-m", msg], label: "Commit",
                                       context: context, then: done)
                })
            }
        }
    }

    /// Destruktive Verwerfen-Rückfrage (in Selbsttests via `presentGitDialogs`
    /// unterdrückt → dort implizit „ja").
    static func confirmDiscard(name: String, untracked: Bool) -> Bool {
        guard presentGitDialogs else { return true }
        let alert = NSAlert()
        // codereview-ok: „…“ (U+201E/U+201C) IST das korrekte deutsche Anführungszeichen-Paar (2026-07-12)
        alert.messageText = L10n.format("Änderungen an „%@“ verwerfen?", name)
        alert.informativeText = untracked
            ? L10n.string("Die nicht versionierte Datei wird gelöscht. Das lässt sich nicht rückgängig machen.")
            : L10n.string("Die Änderungen an dieser Datei gehen verloren. Das lässt sich nicht rückgängig machen.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("Verwerfen"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Verwerfen-Rückfrage für eine Mehrfachauswahl (immer ≥ 2 Dateien — der
    /// Einzelfall läuft über den Dialog mit Dateinamen). Weist gesondert aus,
    /// wie viele unversionierte Dateien dabei GELÖSCHT würden.
    static func confirmDiscard(count: Int, untrackedCount: Int) -> Bool {
        guard presentGitDialogs else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.format("Änderungen an %ld Dateien verwerfen?", count)
        var info = L10n.string("Die Änderungen an diesen Dateien gehen verloren. Das lässt sich nicht rückgängig machen.")
        if untrackedCount == 1 {
            info += "\n" + L10n.string("Eine nicht versionierte Datei wird dabei gelöscht.")
        } else if untrackedCount > 1 {
            info += "\n" + L10n.format("%ld nicht versionierte Dateien werden dabei gelöscht.",
                                       untrackedCount)
        }
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("Verwerfen"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Entfernt ausschließlich einen einzelnen Verzeichniseintrag. `unlink`
    /// verweigert echte Ordner; dadurch kann eine kompakt als unversioniert
    /// gemeldete Verzeichniszeile nie rekursiv darin liegende ignorierte Daten
    /// mitlöschen. Ein Symlink wird selbst entfernt, nicht sein Ziel.
    static func removeUntrackedFile(at url: URL) throws {
        var result: Int32 = -1
        var savedErrno: Int32 = EINVAL
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            result = Darwin.unlink(path)
            if result != 0 { savedErrno = errno }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(savedErrno))
        }
    }

    // MARK: Netzwerk

    /// Liest alle lokal konfigurierten Remotes und ihre effektiven
    /// Push-Adressen neu ein. `git remote` wäre hier falsch, weil es Namen
    /// alphabetisch statt in der sichtbaren Config-Reihenfolge sortiert.
    func refreshGitPushTarget() {
        guard let context = currentGitActionContext, GitRunner.isAvailable else {
            gitPushTargetInspection?.cancel()
            gitPushTargetInspection = nil
            gitPushTargetInspectionRequestID = nil
            gitPushTargets = []
            gitPushTargetWarning = nil
            return
        }
        gitPushTargetInspection?.cancel()
        let requestID = UUID()
        gitPushTargetInspectionRequestID = requestID
        gitPushTargetInspection = GitPushTargetResolver.resolveAll(
            repository: context.root,
            executor: gitOperationsCoordinator.commandExecutor
        ) { [weak self] targets, failure in
            DispatchQueue.main.async {
                guard let self, context.isCurrent(in: self),
                      self.gitPushTargetInspectionRequestID == requestID else {
                    return
                }
                self.gitPushTargets = targets
                self.gitPushTargetWarning = failure.map(Self.pushTargetFailureText)
            }
        }
    }

    /// Lokale Commits explizit zum ersten konfigurierten Remote hochladen.
    /// Andere Git-Defaults (`origin`, `remote.pushDefault`, `push.default`)
    /// dürfen das sichtbare Ziel niemals still ersetzen.
    func gitPush() {
        guard let context = currentGitActionContext, GitRunner.isAvailable else { return }
        resolveGitPushTargets(context: context) { [weak self] targets, failure in
            guard let self else { return }
            guard let target = targets.first else {
                self.presentMissingPushTarget(failure)
                return
            }
            self.performGitPush(to: target, context: context)
        }
    }

    /// Push vom transparenten Changes-Knopf. Vor der Netzwerkaktion wird das
    /// sichtbare Ziel erneut aus Git gelesen; eine zwischenzeitliche Änderung
    /// bricht ab, statt unbemerkt an eine andere Adresse zu senden.
    func gitPush(to expectedTarget: GitPushTarget) {
        guard let context = currentGitActionContext, GitRunner.isAvailable else { return }
        resolveGitPushTarget(remote: expectedTarget.remote,
                             context: context) { [weak self] currentTarget, failure in
            guard let self else { return }
            guard let currentTarget else {
                self.presentMissingPushTarget(failure.map {
                    GitPushTargetResolutionFailure(
                        remote: expectedTarget.remote, outcome: $0
                    )
                })
                return
            }
            guard currentTarget == expectedTarget else {
                Self.presentGitErrorText(
                    label: "Push",
                    text: L10n.string(
                        "Das Push-Ziel hat sich seit der Anzeige geändert. Prüfe Remote und Adresse erneut; es wurde nichts übertragen."
                    )
                )
                return
            }
            self.performGitPush(to: currentTarget, context: context)
        }
    }

    private func performGitPush(to target: GitPushTarget,
                                context: GitActionContext) {
        // Zuerst den aktuellen Branch bestimmen: Der Push nennt sein Ziel
        // unten als EXPLIZITEN Refspec. `git push <remote> HEAD` überließe
        // die Zielwahl der HEAD-Auflösung — ein Detached HEAD soll aber
        // sichtbar scheitern, statt dass Git rät (Review 2026-08-02).
        let branchRequest = GitOperationRequest(
            repository: context.root, kind: .refresh,
            arguments: ["symbolic-ref", "--short", "--quiet", "HEAD"])
        gitOperationsCoordinator.perform(branchRequest) { [weak self] branchOutcome in
            DispatchQueue.main.async {
                guard let self, context.isCurrent(in: self) else { return }
                guard case .completed(let branchResult) = branchOutcome else {
                    Self.presentGitExecutionFailure(label: "Push", outcome: branchOutcome)
                    return
                }
                let branch = branchResult.stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard branchResult.ok, !branch.isEmpty else {
                    Self.presentGitErrorText(label: "Push", text: L10n.string(
                        "Kein aktiver Branch (Detached HEAD) — es ist unklar, wohin der Push gehen soll. Erst einen Branch auschecken."))
                    return
                }
                self.performGitPush(to: target, branch: branch, context: context)
            }
        }
    }

    private func performGitPush(to target: GitPushTarget, branch: String,
                                context: GitActionContext) {
        // Das Ziel unmittelbar vor der Netzwerkaktion noch einmal aus Git
        // lesen. Upstream-Konfiguration und OIDs werden anschließend als ein
        // gemeinsamer Plan aufgelöst und vor dem Push nochmals neu gelesen.
        resolveGitPushTarget(remote: target.remote,
                             context: context) { [weak self] current, _ in
            guard let self else { return }
            guard let current, current == target else {
                Self.presentGitErrorText(
                    label: "Push",
                    text: L10n.string(
                        "Das Push-Ziel hat sich seit der Anzeige geändert. Prüfe Remote und Adresse erneut; es wurde nichts übertragen."))
                return
            }
            self.preparePushPreview(target: current, branch: branch,
                                    context: context)
        }
    }

    /// Prüft die sichtbare Push-Adresse auf Eindeutigkeit, bevor sie für die
    /// Remote-Inspektion in die Prozessumgebung gebunden wird. `url` und
    /// `pushurl` dürfen auf verschiedene Repositorys zeigen; ein gewöhnliches
    /// `git fetch <remote>` wäre deshalb keine verlässliche Push-Vorschau.
    private func preparePushPreview(
        target: GitPushTarget,
        branch: String,
        context: GitActionContext
    ) {
        validatePushTargetBinding(target, context: context) { [weak self] in
            guard let self else { return }
            self.resolvePushPlan(
                target: target,
                expectedBranch: branch,
                context: context,
                completion: { [weak self] plan in
                    self?.presentPushPlan(plan, context: context)
                }
            )
        }
    }

    private func validatePushTargetBinding(
        _ target: GitPushTarget,
        context: GitActionContext,
        completion: @escaping () -> Void
    ) {
        guard GitPushCommand.verifiedAddress(of: target) != nil else {
            Self.presentGitErrorText(
                label: "Push",
                text: L10n.string("Das Remote hat mehrere Push-Adressen. Fastra überträgt erst, wenn genau ein sichtbares Ziel konfiguriert ist."))
            return
        }
        performPushRead(
            ["config", "--includes", "--get-regexp",
             "^url\\..*\\.\\(insteadOf\\|pushInsteadOf\\)$"],
            label: "Push",
            context: context,
            acceptedExitCodes: [0, 1]
        ) { result in
            guard GitPushCommand.rewriteRulesAreAbsent(result) else {
                Self.presentGitErrorText(
                    label: "Push",
                    text: L10n.string("Git-URL-Umschreibregeln machen das Push-Ziel mehrdeutig. Entferne insteadOf/pushInsteadOf oder pushe bewusst im Terminal."))
                return
            }
            completion()
        }
    }

    /// Liest den Plan ausschließlich über OIDs. Ref-Namen werden nur zum
    /// Auflösen benutzt; die spätere Mutation bekommt den unveränderlichen
    /// Source-Commit aus diesem Ergebnis.
    private func resolvePushPlan(
        target: GitPushTarget,
        expectedBranch: String,
        context: GitActionContext,
        completion: @escaping (GitPushPlan) -> Void
    ) {
        performPushRead(
            ["symbolic-ref", "--short", "--quiet", "HEAD"],
            label: "Push",
            context: context
        ) { [weak self] branchResult in
            guard let self else { return }
            let currentBranch = branchResult.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard branchResult.ok, currentBranch == expectedBranch else {
                Self.presentGitErrorText(
                    label: "Push",
                    text: L10n.string(
                        "Der aktive Branch hat sich während der Push-Prüfung geändert. Öffne die Vorschau erneut."
                    )
                )
                return
            }
            self.resolvePushUpstreamState(
                branch: currentBranch, target: target, context: context
            ) { [weak self] tracksTarget in
                guard let self else { return }
                self.performPushRead(["rev-parse", "HEAD"], label: "Push",
                                     context: context) { [weak self] sourceResult in
                    guard let self,
                          let sourceOID = GitPushPlanParsing.oid(sourceResult) else {
                        Self.presentGitError(label: "Push", result: sourceResult)
                        return
                    }
                    self.resolvePushRemoteState(
                        target: target,
                        branch: currentBranch,
                        sourceOID: sourceOID,
                        tracksTarget: tracksTarget,
                        context: context,
                        completion: completion
                    )
                }
            }
        }
    }

    /// Liest die Upstream-KONFIGURATION statt nur die lokale Tracking-Ref.
    /// `@{u}` kann trotz vorhandenem Upstream scheitern, wenn die Remote-Ref
    /// noch nicht gefetcht oder lokal gelöscht wurde. Das darf einen Push zu
    /// einem zweiten Remote niemals zum stillen Upstream-Wechsel machen.
    private func resolvePushUpstreamState(
        branch: String,
        target: GitPushTarget,
        context: GitActionContext,
        completion: @escaping (_ tracksTarget: Bool) -> Void
    ) {
        performPushRead(
            ["config", "--get", "branch.\(branch).remote"],
            label: "Push", context: context, acceptedExitCodes: [0, 1]
        ) { [weak self] remoteResult in
            guard let self else { return }
            self.performPushRead(
                ["config", "--get", "branch.\(branch).merge"],
                label: "Push", context: context, acceptedExitCodes: [0, 1]
            ) { mergeResult in
                let configuredRemote = remoteResult.ok
                    ? remoteResult.stdout.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) : nil
                let configuredMerge = mergeResult.ok
                    ? mergeResult.stdout.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) : nil
                completion(configuredRemote == target.remote
                    && configuredMerge == "refs/heads/\(branch)")
            }
        }
    }

    private func resolvePushRemoteState(
        target: GitPushTarget,
        branch: String,
        sourceOID: String,
        tracksTarget: Bool,
        context: GitActionContext,
        completion: @escaping (GitPushPlan) -> Void
    ) {
        guard let address = GitPushCommand.verifiedAddress(of: target) else { return }
        let remoteRef = "refs/heads/\(branch)"
        let temporaryRemote = "fastra-inspect-\(UUID().uuidString)"
        let inspection = GitPushCommand.inspectionInvocation(
            address: address,
            temporaryRemote: temporaryRemote,
            arguments: ["ls-remote", "--exit-code", "--refs",
                        temporaryRemote, remoteRef]
        )
        performPushRead(
            inspection.arguments,
            label: "Push",
            context: context,
            environment: inspection.environment,
            configuration: inspection.configuration,
            acceptedExitCodes: [0, 2]
        ) { [weak self] remoteResult in
            guard let self else { return }
            if remoteResult.exitCode == 2 {
                completion(GitPushPlan(
                    target: target, branch: branch, sourceOID: sourceOID,
                    remoteRef: remoteRef, remoteOID: nil,
                    localAhead: 0, localBehind: 0, tracksTarget: tracksTarget,
                ))
                return
            }
            guard let remoteOID = GitPushPlanParsing.remoteOID(
                remoteResult, expectedRef: remoteRef
            ) else {
                Self.presentGitErrorText(
                    label: "Push",
                    text: L10n.string("Das Push-Ziel lieferte keinen eindeutigen Branch-Stand. Es wurde nichts übertragen."))
                return
            }
            // Den soeben angekündigten Commit über dieselbe gebundene Adresse
            // holen. Bewegt sich der Ref dazwischen und der Server liefert die
            // alte angekündigte OID nicht mehr, bricht die Vorschau sicher ab.
            let fetch = GitPushCommand.inspectionInvocation(
                address: address,
                temporaryRemote: temporaryRemote,
                arguments: ["fetch", "--no-tags", "--no-write-fetch-head",
                            temporaryRemote, remoteOID]
            )
            self.performPushRead(
                fetch.arguments,
                label: "Fetch",
                context: context,
                environment: fetch.environment,
                configuration: fetch.configuration
            ) { [weak self] _ in
                guard let self else { return }
                self.performPushRead(
                    ["rev-list", "--left-right", "--count",
                     "\(sourceOID)...\(remoteOID)"],
                    label: "Push",
                    context: context
                ) { countResult in
                    guard let counts = GitPushPlanParsing.counts(countResult) else {
                        Self.presentGitError(label: "Push", result: countResult)
                        return
                    }
                    completion(GitPushPlan(
                        target: target, branch: branch, sourceOID: sourceOID,
                        remoteRef: remoteRef, remoteOID: remoteOID,
                        localAhead: counts.ahead, localBehind: counts.behind,
                        tracksTarget: tracksTarget
                    ))
                }
            }
        }
    }

    private func performPushRead(
        _ arguments: [String],
        label: String,
        context: GitActionContext,
        environment: [String: String] = [:],
        configuration: [GitConfigurationEntry] = [],
        acceptedExitCodes: Set<Int32> = [0],
        completion: @escaping (GitResult) -> Void
    ) {
        var policy = GitExecutionPolicy.default
        policy.environment = environment
        policy.configuration = configuration
        let request = GitOperationRequest(
            repository: context.root,
            kind: .refresh,
            arguments: arguments,
            policy: policy
        )
        gitOperationsCoordinator.perform(request) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self, context.isCurrent(in: self) else { return }
                guard case .completed(let result) = outcome else {
                    Self.presentGitExecutionFailure(label: label, outcome: outcome)
                    return
                }
                guard acceptedExitCodes.contains(result.exitCode) else {
                    Self.presentGitError(label: label, result: result)
                    return
                }
                completion(result)
            }
        }
    }

    private func presentPushPlan(_ plan: GitPushPlan,
                                 context: GitActionContext) {
        guard plan.hasChangesToPush else {
            Self.presentGitErrorText(
                label: "Push",
                text: L10n.string("Für dieses Remote gibt es keine lokalen Commits zu pushen.")
            )
            return
        }
        if !plan.canFastForward {
            guard plan.tracksTarget else {
                Self.presentGitErrorText(
                    label: "Push",
                    text: plan.confirmation.explanation + "\n\n" + L10n.string(
                        "Das gewählte Remote ist nicht der Upstream dieses Branches. Ein Force Push wird deshalb nicht automatisch angeboten."
                    )
                )
                return
            }
            if gitMutationConfirmationHandler(plan.confirmation) {
                prepareBoundForcePush(plan, context: context)
            }
            return
        }
        guard gitMutationConfirmationHandler(plan.confirmation) else { return }
        revalidatePushPlan(plan, context: context, force: false)
    }

    private func revalidatePushPlan(_ plan: GitPushPlan,
                                    context: GitActionContext,
                                    force: Bool) {
        resolveGitPushTarget(remote: plan.target.remote,
                             context: context) { [weak self] current, _ in
            guard let self else { return }
            guard let current, current == plan.target else {
                Self.presentGitErrorText(
                    label: "Push",
                    text: L10n.string(
                        "Das Push-Ziel hat sich seit der Vorschau geändert. Prüfe Remote und Adresse erneut; es wurde nichts übertragen."
                    )
                )
                return
            }
            self.validatePushTargetBinding(current, context: context) { [weak self] in
                guard let self else { return }
                self.resolvePushPlan(
                    target: current,
                    expectedBranch: plan.branch,
                    context: context
                ) { [weak self] currentPlan in
                    guard let self else { return }
                    guard currentPlan == plan else {
                        Self.presentGitErrorText(
                            label: "Push",
                            text: L10n.string(
                                "Commits oder Remote-Stand haben sich seit der Vorschau geändert. Öffne die Push-Vorschau erneut; es wurde nichts übertragen."
                            )
                        )
                        return
                    }
                    self.startVerifiedPush(plan, context: context, force: force)
                }
            }
        }
    }

    /// Der erste Divergenzdialog ist nur das Folgeangebot. Vor der eigentlichen
    /// Force-Bestätigung werden Adresse, Quell-Commit und echte Remote-OID erneut
    /// über die gebundene Push-Adresse gelesen.
    private func prepareBoundForcePush(_ previousPlan: GitPushPlan,
                                       context: GitActionContext) {
        resolveGitPushTarget(remote: previousPlan.target.remote,
                             context: context) { [weak self] current, _ in
            guard let self else { return }
            guard let current, current == previousPlan.target else {
                Self.presentGitErrorText(
                    label: "Push",
                    text: L10n.string("Das Push-Ziel hat sich seit der Anzeige geändert. Prüfe Remote und Adresse erneut; es wurde nichts übertragen."))
                return
            }
            self.validatePushTargetBinding(current, context: context) { [weak self] in
                guard let self else { return }
                self.resolvePushPlan(
                    target: current,
                    expectedBranch: previousPlan.branch,
                    context: context
                ) { [weak self] plan in
                    guard let self else { return }
                    guard let remoteOID = plan.remoteOID else {
                        Self.presentGitErrorText(
                            label: "Push",
                            text: L10n.string("Der Remote-Branch existiert nicht mehr. Öffne die normale Push-Vorschau erneut."))
                        return
                    }
                    guard !plan.canFastForward else {
                        // Die erneute Inspektion kann eine inzwischen behobene
                        // Divergenz zeigen. Dann gilt wieder der normale Pfad.
                        self.presentPushPlan(plan, context: context)
                        return
                    }
                    let confirmation = GitMutationConfirmation(
                        title: L10n.string("Force Push with Lease ausführen?"),
                        explanation: L10n.format(
                            "Remote: %@\nAdresse: %@\nZiel: %@\nQuell-Commit: %@\nErwarteter Remote-Commit: %@\n\nFastra überschreibt nur, wenn das Ziel noch exakt diesen Remote-Commit besitzt. Es wird niemals --force ohne Lease verwendet.",
                            plan.target.remote,
                            plan.target.displayAddress,
                            plan.remoteRef,
                            String(plan.sourceOID.prefix(12)),
                            String(remoteOID.prefix(12))
                        ),
                        confirmTitle: L10n.string("Mit Lease erzwingen"),
                        isDestructive: true
                    )
                    guard self.gitMutationConfirmationHandler(confirmation) else { return }
                    self.revalidatePushPlan(plan, context: context, force: true)
                }
            }
        }
    }

    /// Startet nur bei genau einer Adresse und ohne globale URL-Umschreibregeln.
    /// Solche Regeln könnten selbst eine wörtlich geprüfte Adresse ein zweites
    /// Mal umschreiben; ein sichtbarer Abbruch ist dann die einzige eindeutige
    /// Zielbindung.
    private func startVerifiedPush(_ plan: GitPushPlan,
                                   context: GitActionContext,
                                   force: Bool) {
        let target = plan.target
        guard let address = GitPushCommand.verifiedAddress(of: target) else {
            Self.presentGitErrorText(
                label: "Push",
                text: L10n.string("Das Remote hat mehrere Push-Adressen. Fastra überträgt erst, wenn genau ein sichtbares Ziel konfiguriert ist."))
            return
        }
        let request = GitOperationRequest(
            repository: context.root, kind: .refresh,
            arguments: ["config", "--includes", "--get-regexp",
                        "^url\\..*\\.\\(insteadOf\\|pushInsteadOf\\)$"])
        gitOperationsCoordinator.perform(request) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self, context.isCurrent(in: self) else { return }
                guard case .completed(let result) = outcome else {
                    Self.presentGitExecutionFailure(label: "Push", outcome: outcome)
                    return
                }
                guard GitPushCommand.rewriteRulesAreAbsent(result) else {
                    Self.presentGitErrorText(
                        label: "Push",
                        text: L10n.string("Git-URL-Umschreibregeln machen das Push-Ziel mehrdeutig. Entferne insteadOf/pushInsteadOf oder pushe bewusst im Terminal."))
                    return
                }
                let temporaryRemote = "fastra-verified-\(UUID().uuidString)"
                let invocation = GitPushCommand.invocation(
                    remote: target.remote, address: address,
                    refspec: "\(plan.sourceOID):\(plan.remoteRef)",
                    remoteRef: plan.remoteRef,
                    expectedOID: plan.remoteOID,
                    temporaryRemote: temporaryRemote)
                let finish: (GitActionContext) -> Void = { [weak self] _ in
                    guard let self else { return }
                    // Eine bewusst gewählte Remote-Fläche ändert niemals die
                    // Upstream-Konfiguration. So bleiben mehrere Ziele
                    // gleichwertig und ein anderes Werkzeug kann die lokale
                    // Tracking-Entscheidung nicht während des Pushs verlieren.
                    self.recordGitSuccess(L10n.format(
                        "Push zu %@ erfolgreich", target.remote))
                    self.refreshGitRepositoryFully()
                    self.refreshOpenGitViews()
                }
                self.runGitAction(
                    invocation.arguments,
                    label: L10n.format("Push zu %@", target.remote),
                    context: context, kind: .push,
                    environment: invocation.environment,
                    configuration: invocation.configuration,
                    refreshOnFailure: true,
                    failureHandler: { [weak self] result in
                        self?.handleRejectedPush(
                            result, plan: plan, context: context,
                            alreadyForced: force
                        ) ?? false
                    },
                    then: finish)
            }
        }
    }

    /// Ein Remote kann sich auch nach dem verpflichtenden Fetch und der
    /// Vorschau noch ändern. Git bleibt die letzte Instanz und lehnt diesen
    /// Push ab. Fastra erklärt den Konflikt, zeigt die echte Ausgabe und bietet
    /// Force-with-Lease ausschließlich als neue, getrennte Prüfung an.
    private func handleRejectedPush(_ result: GitResult,
                                    plan: GitPushPlan,
                                    context: GitActionContext,
                                    alreadyForced: Bool) -> Bool {
        let leaseChanged = GitPushFailureClassification.isLeaseStale(result)
        guard leaseChanged
                || GitPushFailureClassification.isNonFastForward(result) else {
            return false
        }
        let raw = [result.stderrForDisplay, result.stdoutForDisplay]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        var explanation = leaseChanged
            ? L10n.string(
                "Der Remote-Branch entspricht nicht mehr dem bestätigten Stand. Fastra hat nichts übertragen. Hole den neuen Stand und öffne die Push-Vorschau erneut."
            )
            : L10n.string(
                "Das Remote enthält inzwischen Commits, die in deinem lokalen Branch fehlen. Fastra hat nichts übertragen. Hole den neuen Stand und prüfe die Änderungen; ein normaler Push würde sonst Remote-Commits überschreiben."
            )
        if !raw.isEmpty {
            explanation += "\n\n" + L10n.string("Git-Ausgabe:") + "\n" + raw
        }
        guard plan.tracksTarget, !alreadyForced else {
            Self.presentGitErrorText(label: "Push", text: explanation)
            return true
        }
        let confirmation = GitMutationConfirmation(
            title: L10n.string("Push abgelehnt"),
            explanation: explanation,
            confirmTitle: L10n.string("Force Push with Lease prüfen"),
            isDestructive: true
        )
        if gitMutationConfirmationHandler(confirmation) {
            prepareBoundForcePush(plan, context: context)
        }
        return true
    }

    private func resolveGitPushTargets(
        context: GitActionContext,
        completion: @escaping ([GitPushTarget], GitPushTargetResolutionFailure?) -> Void
    ) {
        gitPushActionTargetInspection?.cancel()
        gitPushActionTargetInspection = GitPushTargetResolver.resolveAll(
            repository: context.root,
            executor: gitOperationsCoordinator.commandExecutor
        ) { [weak self] targets, failure in
            DispatchQueue.main.async {
                guard let self, context.isCurrent(in: self) else { return }
                completion(targets, failure)
            }
        }
    }

    /// Löst die ausgewählte Remote-Fläche erneut gegen die aktuelle lokale
    /// Konfiguration auf. Andere Remotes dürfen dabei weder das Ziel ersetzen
    /// noch die Config-Reihenfolge zur impliziten Auswahl machen.
    private func resolveGitPushTarget(
        remote: String,
        context: GitActionContext,
        completion: @escaping (GitPushTarget?, GitExecutionOutcome?) -> Void
    ) {
        gitPushActionTargetInspection?.cancel()
        gitPushActionTargetInspection = GitPushTargetResolver.resolve(
            remote: remote,
            repository: context.root,
            executor: gitOperationsCoordinator.commandExecutor
        ) { [weak self] target, failure in
            DispatchQueue.main.async {
                guard let self, context.isCurrent(in: self) else { return }
                completion(target, failure)
            }
        }
    }

    private func presentMissingPushTarget(_ failure: GitPushTargetResolutionFailure?) {
        if let failure {
            let label = failure.remote.map { "Push-Ziel \($0)" } ?? "Push-Ziel"
            if case .completed(let result) = failure.outcome {
                Self.presentGitError(label: label, result: result)
            } else {
                Self.presentGitExecutionFailure(label: label,
                                                outcome: failure.outcome)
            }
        } else {
            Self.presentGitErrorText(
                label: "Push",
                text: L10n.string(
                    "Kein Git-Remote ist in diesem Repository konfiguriert. Es wurde nichts übertragen."
                )
            )
        }
    }

    private static func pushTargetFailureText(
        _ failure: GitPushTargetResolutionFailure
    ) -> String {
        let remote = failure.remote ?? L10n.string("Git-Konfiguration")
        let detail: String
        if case .completed(let result) = failure.outcome {
            detail = [result.stderrForDisplay, result.stdoutForDisplay]
                .first(where: { !$0.isEmpty })
                ?? L10n.format("git lieferte keine Meldung (Exit-Code %ld).",
                               Int(result.exitCode))
        } else {
            detail = gitExecutionFailureText(failure.outcome)
                ?? L10n.string("Der Git-Vorgang wurde abgebrochen.")
        }
        return L10n.format("Remote %@ konnte nicht gelesen werden: %@",
                           remote, detail)
    }

    /// Entfernten Stand mit einer explizit gewählten Strategie einbinden.
    /// Fastra stash-t, pusht oder synchronisiert dabei niemals automatisch.
    func gitPull() {
        startSafePull(strategyOverride: nil)
    }

    /// Fast-Forward-only Pull (`git pull --ff-only`) — die pfiffige Variante:
    /// übernimmt entfernte Commits NUR, wenn nichts kollidiert, nie ein
    /// Merge-Commit. Hält die Historie linear.
    func gitPullFastForward() {
        startSafePull(strategyOverride: .ffOnly)
    }

    /// Entfernten Stand holen, ohne lokal etwas zu ändern (`git fetch`).
    func gitFetch() {
        guard let context = currentGitActionContext else { return }
        gitFetchRemoteInspection?.cancel()
        let requestID = UUID()
        gitFetchRemoteInspectionRequestID = requestID
        gitFetchRemoteInspection = GitRemoteNameResolver.resolve(
            repository: context.root,
            executor: gitOperationsCoordinator.commandExecutor
        ) { [weak self] remotes, failure in
            DispatchQueue.main.async {
                guard let self, context.isCurrent(in: self),
                      self.gitFetchRemoteInspectionRequestID == requestID else { return }
                self.gitFetchRemoteInspection = nil
                self.gitFetchRemoteInspectionRequestID = nil
                guard let remotes else {
                    if let failure {
                        if case .completed(let result) = failure {
                            Self.presentGitError(label: "Fetch-Ziel", result: result)
                        } else {
                            Self.presentGitExecutionFailure(label: "Fetch-Ziel",
                                                            outcome: failure)
                        }
                    }
                    return
                }
                self.gitRepositoryStore.fetch(
                    repository: context.root,
                    preferences: self.gitPreferencesStore.load(),
                    remotes: remotes
                )
            }
        }
    }

    private func startSafePull(strategyOverride: GitPullStrategy?) {
        guard let context = currentGitActionContext, gitStatus != nil else { return }
        guard !gitOperationsCoordinator.state(for: context.root).contains(.pull) else {
            recordGitSuccess(L10n.string("Pull läuft bereits"))
            return
        }
        var preferences = gitPreferencesStore.load()
        let strategy: GitPullStrategy
        if let strategyOverride {
            strategy = strategyOverride
        } else if preferences.pullStrategy == .unselected {
            guard let selected = Self.promptForPullStrategy() else { return }
            preferences.pullStrategy = selected
            gitPreferencesStore.save(preferences)
            strategy = selected
        } else {
            strategy = preferences.pullStrategy
        }
        let lease = GitSafePullRunner.run(
            repository: context.root, strategy: strategy,
            coordinator: gitOperationsCoordinator
        ) { [weak self] preflight, proceed in
            guard let self, context.isCurrent(in: self) else { proceed(false); return }
            if case .ready(let dirty) = preflight, dirty {
                proceed(Self.confirmPullWithLocalChanges())
            } else {
                proceed(true)
            }
        } completion: { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitRepositoryStore.publishOperations(for: context.root)
                guard context.isCurrent(in: self) else { return }
                switch outcome {
                case .pulled(.completed(let result)) where result.ok:
                    self.recordGitSuccess(L10n.string("Pull erfolgreich"))
                    self.refreshGitRepositoryFully()
                    self.refreshOpenGitViews()
                case .pulled(let failure), .inspectionFailed(let failure):
                    self.refreshGitRepositoryFully()
                    self.refreshOpenGitViews()
                    if case .completed(let result) = failure {
                        Self.presentGitError(label: "Pull", result: result)
                    } else {
                        Self.presentGitExecutionFailure(label: "Pull-Prüfung",
                                                        outcome: failure)
                    }
                case .blocked(let reason):
                    if reason == .missingIdentity {
                        self.ensureGitIdentity(context: context) { [weak self] _ in
                            self?.startSafePull(strategyOverride: strategy)
                        }
                        return
                    }
                    Self.presentPullBlock(reason)
                    self.refreshGitRepositoryFully()
                case .repositoryChanged:
                    Self.presentGitErrorText(
                        label: "Pull",
                        text: L10n.string("Repository oder lokale Änderungen haben sich während der Pull-Prüfung geändert. Prüfe den neuen Stand und starte Pull erneut.")
                    )
                    self.refreshGitRepositoryFully()
                case .cancelled:
                    break
                }
            }
        }
        if lease != nil { gitRepositoryStore.publishOperations(for: context.root) }
    }

    private static func presentPullBlock(_ preflight: GitPullPreflightResult) {
        switch preflight {
        case .noUpstream:
            presentGitErrorText(
                label: "Pull",
                text: L10n.string("Der aktuelle Branch hat keinen Upstream. Lege zuerst einen Upstream fest oder pushe den Branch mit Upstream.")
            )
        case .unmerged:
            presentGitErrorText(
                label: "Pull",
                text: L10n.string("Es gibt noch ungelöste Konflikte. Löse sie und schließe den laufenden Git-Vorgang ab, bevor du erneut pullst.")
            )
        case .operationInProgress(let operation):
            presentGitErrorText(
                label: "Pull",
                text: L10n.format("Ein Git-Vorgang läuft bereits (%@). Schließe ihn ab oder brich ihn bewusst ab, bevor du pullst.", operation.localizedName)
            )
        case .missingIdentity:
            presentGitErrorText(
                label: "Pull",
                text: L10n.string("Git benötigt für Pull mit Merge oder Rebase eine gültige Commit-Identität. Konfiguriere Name und E-Mail und starte Pull erneut.")
            )
        case .ready:
            break
        }
    }

    // MARK: Pfiffige Extras

    /// Zum zuletzt ausgecheckten Branch zurück (`git switch -`).
    func gitSwitchPrevious() {
        guard !gitOperationsAreBusy else { return }
        runGitAction(["switch", "-"], label: "Branch-Wechsel")
    }

    /// Wechselt zu einem explizit ausgewählten lokalen Branch. Argumente gehen
    /// getrennt an `Process`, daher werden auch Namen mit Leerzeichen sicher
    /// und ohne Shell-Interpolation behandelt.
    func gitSwitchBranch(_ name: String) {
        guard !name.isEmpty, !gitOperationsAreBusy else { return }
        // Die Branch-Liste ist die Quelle des Auswahlmenüs. `gitStatus` kann
        // nach einem externen Wechsel noch den alten Branch enthalten; darauf
        // zu guard-en würde dann genau den gewünschten Wechsel verschlucken.
        guard gitBranches.first(where: { $0.isCurrent })?.name != name else { return }
        runGitAction(["switch", name], label: "Branch-Wechsel", then: {
            [weak self] _ in
            guard let self else { return }
            self.recordGitSuccess(L10n.format("Branch „%@“ aktiv", name))
            self.refreshGitRepositoryFully()
            self.refreshOpenGitViews()
        })
    }

    /// Pickaxe-Suche (`git log -S<text>`): findet die Commits, die eine
    /// Textstelle eingeführt oder entfernt haben. Öffnet das Ergebnis als
    /// klickbaren Verlaufs-Tab (passt zur Suchen-&-Ersetzen-DNA).
    func gitPickaxe() {
        guard projectURL != nil else { return }
        guard let term = Self.promptForText(
            title: L10n.string("Verlauf durchsuchen"),
            info: L10n.string("Findet Commits, die diesen Text eingeführt oder entfernt haben:"),
            placeholder: L10n.string("z.B. deprecatedFunction")
        ), !term.isEmpty else { return }

        loadGitTab(kind: .log, title: L10n.format("Suche: %@", term),
                   args: ["log", "-S" + term, "--oneline", "--decorate"],
                   emptyText: L10n.string("Keine Commits berühren diesen Text."))
    }

    // MARK: - Ausführung & Rückmeldung

    /// Führt eine git-Aktion aus, frischt bei Erfolg den Git-Zustand auf und
    /// ruft optional `then` (für verkettete Schritte wie add→commit). Bei einem
    /// Fehler zeigt es die echte git-Ausgabe in einem Dialog und bricht die
    /// Kette ab.
    var currentGitActionContext: GitActionContext? {
        projectURL.map { GitActionContext(root: $0,
                                          projectGeneration: projectGeneration) }
    }

    @discardableResult
    func runGitAction(_ args: [String], label: String,
                      context suppliedContext: GitActionContext? = nil,
                      kind explicitKind: GitOperationKind? = nil,
                      environment: [String: String] = [:],
                      configuration: [GitConfigurationEntry] = [],
                      refreshOnFailure: Bool = false,
                      failureHandler: ((GitResult) -> Bool)? = nil,
                      then: ((GitActionContext) -> Void)? = nil)
        -> GitOperationLease? {
        guard let context = suppliedContext ?? currentGitActionContext,
              GitRunner.isAvailable else { return nil }
        let kind: GitOperationKind
        // Beginnt der Aufruf mit einer `-c`-Option, sagt das erste Argument
        // nichts mehr über die Art der Operation. Solche Aufrufe geben sie
        // deshalb ausdrücklich mit.
        if let explicitKind {
            kind = explicitKind
        } else {
            switch args.first {
            case "fetch": kind = .fetch
            case "pull": kind = .pull
            case "push": kind = .push
            case "switch", "checkout": kind = .checkout
            default: kind = .workingTreeMutation
            }
        }
        var policy = GitExecutionPolicy.default
        policy.environment = environment
        policy.configuration = configuration
        let request = GitOperationRequest(repository: context.root, kind: kind,
                                          arguments: args, policy: policy)
        let lease = gitOperationsCoordinator.perform(request) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitRepositoryStore.publishOperations(for: context.root)
                guard context.isCurrent(in: self) else { return }
                guard case .completed(let result) = outcome else {
                    if refreshOnFailure {
                        self.refreshGitRepositoryFully()
                        self.refreshOpenGitViews()
                    }
                    Self.presentGitExecutionFailure(label: label, outcome: outcome)
                    return
                }
                guard result.ok else {
                    if refreshOnFailure {
                        self.refreshGitRepositoryFully()
                        self.refreshOpenGitViews()
                    }
                    if failureHandler?(result) == true { return }
                    Self.presentGitError(label: label, result: result)
                    return
                }
                if let then {
                    then(context)
                } else {
                    // Kette fertig: Status + offene Verlauf-/Diff-Tabs auffrischen.
                    self.refreshGitRepositoryFully()
                    self.refreshOpenGitViews()
                }
            }
        }
        gitRepositoryStore.publishOperations(for: context.root)
        return lease
    }

    /// Zeigt Erfolg für wenige Sekunden direkt in der Seitenleiste. Eine ID
    /// verhindert, dass der Timer einer älteren Aktion eine neuere Meldung
    /// vorzeitig ausblendet.
    func recordGitSuccess(_ message: String) {
        let feedback = GitActionFeedback(message: message)
        gitFeedback = feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard self?.gitFeedback?.id == feedback.id else { return }
            self?.gitFeedback = nil
        }
    }

    /// Frischt einen offenen „Git-Verlauf"- bzw. „Git-Diff"-Tab nach einer
    /// schreibenden Aktion auf (Snapshot war sonst veraltet). Commit-Tabs
    /// (`git show <hash>`) bleiben gültig (historisch) und werden nicht angefasst.
    func refreshOpenGitLogView() {
        if tabs.contains(where: { $0.gitKind == .log && $0.title == L10n.string("Git-Verlauf") }) {
            openGitLog()
        }
    }

    func refreshOpenGitViews() {
        refreshOpenGitLogView()
        refreshOpenGitDiffTabs()
    }

    // MARK: - Dialog-Helfer

    /// Modaler Ein-Zeilen-Eingabedialog (NSAlert + NSTextField), gleiches Muster
    /// wie „Zu Zeile springen". Liefert `nil` bei Abbruch.
    static func promptForText(title: String, info: String, placeholder: String,
                              initialValue: String? = nil) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: L10n.string("OK"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        let field = promptTextField(placeholder: placeholder, initialValue: initialValue)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        DispatchQueue.main.async {
            // Beim Umbenennen ist der vorhandene Name echter Feldinhalt und
            // sofort vollständig ausgewählt: Tippen ersetzt ihn, Pfeil rechts
            // setzt den Cursor ans Ende, wenn nur etwas angehängt werden soll.
            _ = focusAndSelectPromptText(field)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    static func promptTextField(placeholder: String,
                                initialValue: String?) -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initialValue ?? ""
        return field
    }

    /// Liefert die echte Feldeditor-Auswahl als Regressionstest-Anker.
    @discardableResult
    static func focusAndSelectPromptText(_ field: NSTextField) -> NSRange? {
        guard field.window?.makeFirstResponder(field) == true else { return nil }
        field.selectText(nil)
        return field.currentEditor()?.selectedRange
    }

    /// Steuert, ob Git-Fehler als modaler Dialog erscheinen. In Selbsttests auf
    /// `false` gesetzt, damit ein unerwarteter Fehler den Lauf nicht an einem
    /// modalen NSAlert aufhängt (der Fehler geht dann nach stderr, der Test
    /// läuft in seinen Timeout).
    static var presentGitDialogs = true

    /// Zeigt einen Git-Fehler mit der wörtlichen git-Ausgabe (stderr, sonst
    /// stdout). Kein Schönreden — der Nutzer soll den echten Grund sehen.
    static func presentGitError(label: String, result: GitResult?) {
        let raw = [result?.stderrForDisplay, result?.stdoutForDisplay]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        let text = raw ?? L10n.format("git lieferte keine Meldung (Exit-Code %ld).",
                                      Int(result?.exitCode ?? -1))
        guard presentGitDialogs else {
            FileHandle.standardError.write(Data("GIT-ERROR [\(label)]: \(text)\n".utf8))
            return
        }
        NSAlert.runWarning(title: L10n.format("%@ fehlgeschlagen", L10n.string(label)),
                           text: text)
    }

    static func presentGitExecutionFailure(label: String,
                                           outcome: GitExecutionOutcome) {
        guard let text = gitExecutionFailureText(outcome) else { return }
        presentGitErrorText(label: label, text: text)
    }

    /// Textform für Tabs und Dialoge. Ein Nutzerabbruch bleibt bewusst still.
    static func gitExecutionFailureText(_ outcome: GitExecutionOutcome) -> String? {
        switch outcome {
        case .startFailed(.launchFailed(let detail)):
            return L10n.format("Prozess konnte nicht gestartet werden: %@", detail)
        case .timedOut:
            return L10n.string("Der Git-Vorgang hat das Zeitlimit überschritten.")
        case .captureFailed(let failure):
            let details = [failure.stdoutError, failure.stderrError]
                .compactMap { $0 }.joined(separator: "\n")
            let prefix = L10n.format("Git-Ausgabe konnte nicht vollständig gelesen werden: %@",
                                     details)
            let partial = [failure.partialResult.stderrForDisplay,
                           failure.partialResult.stdoutForDisplay]
                .first(where: { !$0.isEmpty }) ?? ""
            return partial.isEmpty ? prefix : prefix + "\n\n" + partial
        case .cancelled, .startFailed(.gitUnavailable):
            return nil
        case .completed:
            return nil
        }
    }

    static func presentGitErrorText(label: String, text: String) {
        guard presentGitDialogs else {
            FileHandle.standardError.write(Data("GIT-ERROR [\(label)]: \(text)\n".utf8))
            return
        }
        NSAlert.runWarning(title: L10n.format("%@ fehlgeschlagen", L10n.string(label)),
                           text: text)
    }

    static func promptForAutomaticFetch(
        completion: @escaping (GitFetchPromptChoice) -> Void
    ) {
        guard presentGitDialogs else { completion(.later); return }
        let alert = NSAlert()
        alert.messageText = L10n.string("Remote-Änderungen automatisch abrufen?")
        alert.informativeText = L10n.string("Fastra kann im Hintergrund regelmäßig git fetch ausführen. Das holt nur den Remote-Stand ab. Deine Projektdateien und der aktuelle Branch bleiben unverändert.")
        alert.addButton(withTitle: L10n.string("Automatisch (empfohlen)"))
        alert.addButton(withTitle: L10n.string("Nein"))
        alert.addButton(withTitle: L10n.string("Später"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: completion(.automatic)
        case .alertSecondButtonReturn: completion(.disabled)
        default: completion(.later)
        }
    }

    private static func promptForPullStrategy() -> GitPullStrategy? {
        guard presentGitDialogs else { return .rebase }
        let alert = NSAlert()
        alert.messageText = L10n.string("Wie soll Pull entfernte Commits einbinden?")
        alert.informativeText = L10n.string("Die Auswahl gilt global und kann in den Einstellungen geändert werden. Fastra verwendet immer die entsprechende explizite Git-Option.")
        alert.addButton(withTitle: L10n.string("Rebase (empfohlen)"))
        alert.addButton(withTitle: L10n.string("Merge"))
        alert.addButton(withTitle: L10n.string("Nur Fast-Forward"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .rebase
        case .alertSecondButtonReturn: return .merge
        case .alertThirdButtonReturn: return .ffOnly
        default: return nil
        }
    }

    private static func confirmPullWithLocalChanges() -> Bool {
        guard presentGitDialogs else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Pull mit lokalen Änderungen fortsetzen?")
        alert.informativeText = L10n.string("Fastra legt keinen automatischen Stash an. Git bricht ab, bevor lokale Arbeit überschrieben würde; eine echte Git-Fehlermeldung bleibt sichtbar.")
        alert.addButton(withTitle: L10n.string("Pull fortsetzen"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension GitOperationState {
    var localizedName: String {
        switch self {
        case .merge: return L10n.string("Merge")
        case .rebase: return L10n.string("Rebase")
        case .cherryPick: return L10n.string("Cherry-pick")
        case .revert: return L10n.string("Revert")
        case .bisect: return L10n.string("Bisect")
        }
    }
}
