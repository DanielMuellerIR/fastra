import AppKit
import Foundation

/// Entscheidungen und Rückmeldungen gehören zum jeweiligen Dokumentfenster.
/// AppKit-Aufrufe und Zustandsänderungen erfolgen wie beim Workspace auf Main.
final class GitInteraction {
    var presentsDialogs = true
    private let writeStandardError: (String) -> Void

    init(writeStandardError: @escaping (String) -> Void = {
        FileHandle.standardError.write(Data($0.utf8))
    }) {
        self.writeStandardError = writeStandardError
    }

    /// Die Beobachtung darf das Fenster nicht halten; auch nach dessen Ende
    /// muss der Auto-Fetch-Controller die offene Rückfrage freigeben können.
    func automaticFetchPromptHandler()
        -> (@escaping (GitFetchPromptChoice) -> Void) -> Void {
        { [weak self] completion in
            guard let self else { completion(.windowUnavailable); return }
            self.promptForAutomaticFetch(completion: completion)
        }
    }

    /// Destruktive Verwerfen-Rückfrage (in Selbsttests via `presentsDialogs`
    /// unterdrückt → dort implizit „ja").
    func confirmDiscard(name: String, untracked: Bool) -> Bool {
        guard presentsDialogs else { return true }
        // codereview-ok: „…“ (U+201E/U+201C) ist das korrekte deutsche Anführungszeichen-Paar
        let title = L10n.format("Änderungen an „%@“ verwerfen?", name)
        let message = untracked
            ? L10n.string("Die nicht versionierte Datei wird gelöscht. Das lässt sich nicht rückgängig machen.")
            : L10n.string("Die Änderungen an dieser Datei gehen verloren. Das lässt sich nicht rückgängig machen.")
        return presentDiscardConfirmation(title: title, message: message)
    }

    /// Verwerfen-Rückfrage für eine Mehrfachauswahl (immer ≥ 2 Dateien — der
    /// Einzelfall läuft über den Dialog mit Dateinamen). Weist gesondert aus,
    /// wie viele unversionierte Dateien dabei gelöscht würden.
    func confirmDiscard(count: Int, untrackedCount: Int) -> Bool {
        guard presentsDialogs else { return true }
        let title = L10n.format("Änderungen an %ld Dateien verwerfen?", count)
        var info = L10n.string("Die Änderungen an diesen Dateien gehen verloren. Das lässt sich nicht rückgängig machen.")
        if untrackedCount == 1 {
            info += "\n" + L10n.string("Eine nicht versionierte Datei wird dabei gelöscht.")
        } else if untrackedCount > 1 {
            info += "\n" + L10n.format("%ld nicht versionierte Dateien werden dabei gelöscht.",
                                       untrackedCount)
        }
        return presentDiscardConfirmation(title: title, message: info)
    }

    private func presentDiscardConfirmation(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("Verwerfen"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Einheitliche Meldung, wenn ein eingefrorener Kontext nach der Rückfrage
    /// nicht mehr das aktuelle Projekt beschreibt. Bewusst derselbe Text wie in
    /// den übrigen Sicherheitsabbrüchen (siehe `GitConflictActions`).
    func presentStaleGitContext(label: String) {
        presentGitErrorText(
            label: label,
            text: L10n.string("Repository, Branch oder Arbeitsbaum haben sich während der Sicherheitsprüfung geändert. Prüfe den neuen Stand und starte die Aktion erneut."))
    }

    func presentPullBlock(_ preflight: GitPullPreflightResult) {
        switch preflight {
        case .detached:
            presentGitErrorText(
                label: "Pull",
                text: L10n.string("Der aktuelle Stand ist keinem lokalen Branch zugeordnet. Wechsle vor Pull zu einem lokalen Branch.")
            )
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

    /// Produktpfad der Absage. Rückgabe `true`: Der Nutzer will das andere
    /// Arbeitsverzeichnis als Projekt öffnen.
    func defaultGitBranchWorktreeBlock(_ block: GitBranchWorktreeBlock) -> Bool {
        Workspace.gitBranchWorktreeBlockDecision(block, dialogsEnabled: presentsDialogs) {
            $0.runModal()
        }
    }

    /// Zeigt einen Git-Fehler mit der wörtlichen git-Ausgabe (stderr, sonst
    /// stdout). Kein Schönreden — der Nutzer soll den echten Grund sehen.
    func presentGitError(label: String, result: GitResult?) {
        let raw = [result?.stderrForDisplay, result?.stdoutForDisplay]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        let text = raw ?? L10n.format("git lieferte keine Meldung (Exit-Code %ld).",
                                      Int(result?.exitCode ?? -1))
        presentGitErrorText(label: label, text: text)
    }

    func presentGitExecutionFailure(label: String,
                                    outcome: GitExecutionOutcome) {
        guard let text = Workspace.gitExecutionFailureText(outcome) else { return }
        presentGitErrorText(label: label, text: text)
    }

    func presentGitErrorText(label: String, text: String) {
        guard presentsDialogs else {
            writeStandardError("GIT-ERROR [\(label)]: \(text)\n")
            return
        }
        NSAlert.runWarning(title: L10n.format("%@ fehlgeschlagen", L10n.string(label)),
                           text: text)
    }

    func promptForAutomaticFetch(
        completion: @escaping (GitFetchPromptChoice) -> Void
    ) {
        guard presentsDialogs else { completion(.later); return }
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

    func promptForPullStrategy() -> GitPullStrategy? {
        guard presentsDialogs else { return .rebase }
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

    func confirmPullWithLocalChanges() -> Bool {
        guard presentsDialogs else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Pull mit lokalen Änderungen fortsetzen?")
        alert.informativeText = L10n.string("Fastra legt keinen automatischen Stash an. Git bricht ab, bevor lokale Arbeit überschrieben würde; eine echte Git-Fehlermeldung bleibt sichtbar.")
        alert.addButton(withTitle: L10n.string("Pull fortsetzen"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func defaultGitIdentityPrompt(_ snapshot: GitIdentitySnapshot?)
        -> GitIdentityConfiguration? {
        guard presentsDialogs else { return nil }
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

    func defaultGitMutationConfirmation(_ confirmation: GitMutationConfirmation) -> Bool {
        guard presentsDialogs else { return false }
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.explanation
        alert.alertStyle = confirmation.isDestructive ? .warning : .informational
        alert.addButton(withTitle: confirmation.confirmTitle)
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func defaultConfirmIntentionalConflictMarkers(_ path: String) -> Bool {
        guard presentsDialogs else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Konfliktmarker absichtlich beibehalten?")
        alert.informativeText = L10n.format(
            "„%@“ enthält weiterhin Zeilen wie <<<<<<<, ======= oder >>>>>>>. Nur fortsetzen, wenn diese Zeichenfolgen beabsichtigter Dateiinhalt und keine ungelösten Konflikte sind. Fastra staged ausschließlich die zuvor geprüften Bytes dieser Datei.",
            path)
        alert.addButton(withTitle: L10n.string("Marker absichtlich beibehalten"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
