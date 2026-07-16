import AppKit

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
            self?.runGitAction(["add", "-A"], label: "Stagen", context: context) {
                [weak self] context in
                self?.runGitAction(["commit", "-m", message], label: "Commit",
                                   context: context)
            }
        }
    }

    /// Letzten Commit um die aktuellen Änderungen ergänzen, Botschaft behalten
    /// (`git commit --amend --no-edit`) — die pfiffige Variante „Ups, das
    /// gehörte noch dazu", ohne die Message anzufassen.
    func gitAmendNoEdit() {
        guard projectURL != nil, !gitOperationsAreBusy else { return }
        guard let context = currentGitActionContext else { return }
        ensureGitIdentity(context: context) { [weak self] context in
            self?.runGitAction(["add", "-A"], label: "Stagen", context: context) {
                [weak self] context in
                self?.runGitAction(["commit", "--amend", "--no-edit"],
                                   label: "Ergänzen", context: context)
            }
        }
    }

    // MARK: - Datei-genaues Staging (Änderungen-Ansicht, VS-Code-artig)

    /// Eine Datei bereitstellen (`git add -- <path>`). Deckt geänderte, gelöschte
    /// (die Löschung wird bereitgestellt) und untracked Dateien ab.
    func gitStage(path: String) {
        runGitAction(["add", "--", path], label: "Bereitstellen")
    }

    /// Alle Änderungen bereitstellen (`git add -A`).
    func gitStageAll() {
        runGitAction(["add", "-A"], label: "Alles bereitstellen")
    }

    /// Eine Datei aus dem Index nehmen (`git reset -q HEAD -- <path>`). Bewusst
    /// `reset` statt `restore --staged` — breit kompatibel auch mit älterem git.
    func gitUnstage(path: String) {
        runGitAction(["reset", "-q", "HEAD", "--", path], label: "Aus Bereitstellung nehmen")
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
        guard let root = projectURL, let path = change.actionPath else { return }
        let isUntracked = change.unstaged == .untracked
        guard Self.confirmDiscard(name: change.name, untracked: isUntracked) else { return }
        if isUntracked {
            // Untracked: Datei physisch entfernen (VS-Code-Verhalten „Discard").
            try? FileManager.default.removeItem(at: root.appendingPathComponent(path))
            refreshGitStatus()
            refreshOpenGitViews()
        } else {
            runGitAction(["checkout", "--", path], label: "Verwerfen")
        }
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
                                  context: context) { [weak self] context in
                    self?.runGitAction(["commit", "-m", msg], label: "Commit",
                                       context: context, then: done)
                }
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

    // MARK: Netzwerk

    /// Lokale Commits hochladen (`git push`). Pfiffiges Extra: hat der aktuelle
    /// Branch noch keinen Upstream (typischer erster Push eines neuen Branches),
    /// wird automatisch `push -u origin HEAD` gemacht — statt die kryptische
    /// „has no upstream branch"-Fehlermeldung zu zeigen, die genau Daniels
    /// Zielgruppe ausbremst.
    func gitPush() {
        guard let context = currentGitActionContext, GitRunner.isAvailable else { return }
        // Upstream vorhanden? `@{u}` löst nur mit gesetztem Upstream auf.
        let request = GitOperationRequest(repository: context.root, kind: .refresh,
                                          arguments: ["rev-parse", "--abbrev-ref", "@{u}"])
        gitOperationsCoordinator.perform(request) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self, context.isCurrent(in: self) else { return }
                if case .completed(let result) = outcome, result.ok {
                    self.runGitAction(["push"], label: "Push",
                                      successMessage: "Push erfolgreich", context: context)
                } else if case .completed = outcome {
                    self.runGitAction(["push", "-u", "origin", "HEAD"],
                                      label: "Push (Upstream anlegen)",
                                      successMessage: "Push erfolgreich · Upstream angelegt",
                                      context: context)
                } else {
                    Self.presentGitExecutionFailure(label: "Push", outcome: outcome)
                }
            }
        }
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
        guard let root = projectURL else { return }
        gitRepositoryStore.fetch(repository: root,
                                 preferences: gitPreferencesStore.load(),
                                 remotes: [])
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
        runGitAction(["switch", name], label: "Branch-Wechsel") {
            [weak self] _ in
            guard let self else { return }
            self.recordGitSuccess(L10n.format("Branch „%@“ aktiv", name))
            self.refreshGitRepositoryFully()
            self.refreshOpenGitViews()
        }
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
                      successMessage: String? = nil,
                      context suppliedContext: GitActionContext? = nil,
                      refreshOnFailure: Bool = false,
                      then: ((GitActionContext) -> Void)? = nil)
        -> GitOperationLease? {
        guard let context = suppliedContext ?? currentGitActionContext,
              GitRunner.isAvailable else { return nil }
        let first = args.first
        let kind: GitOperationKind
        switch first {
        case "fetch": kind = .fetch
        case "pull": kind = .pull
        case "push": kind = .push
        case "switch", "checkout": kind = .checkout
        default: kind = .workingTreeMutation
        }
        let request = GitOperationRequest(repository: context.root, kind: kind,
                                          arguments: args)
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
                    Self.presentGitError(label: label, result: result)
                    return
                }
                if let then {
                    then(context)
                } else {
                    if let successMessage {
                        self.recordGitSuccess(L10n.string(successMessage))
                    }
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
    static func promptForText(title: String, info: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: L10n.string("OK"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
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
