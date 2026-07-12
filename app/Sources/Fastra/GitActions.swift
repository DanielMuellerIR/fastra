import AppKit

/// Kuratierte Git-Aktionen (Projekt- & Git-Ausbau, Etappe 2, Schritt 4).
/// Philosophie: **Git liefert Logik, Fastra macht die häufigen — und ein paar
/// pfiffige — Aufrufe per Knopf zugänglich**, für Leute, die Git verstehen,
/// sich aber Syntax/Parameter nicht merken wollen.
///
/// Alle Aktionen laufen asynchron über `GitRunner` (nie Main-Thread-Block).
/// Erfolg → still den Status auffrischen (der Branch-Zähler / Dateibaum
/// aktualisiert sich sichtbar). Fehler → die ECHTE git-Ausgabe zeigen
/// (UX-Regel), nicht schlucken.
extension Workspace {

    // MARK: Häufige Aktionen

    /// Alle Änderungen committen (`git add -A` + `git commit -m`). Für Daniels
    /// Zielgruppe der 80-%-Fall — kein manuelles Stagen nötig. Fragt die
    /// Commit-Botschaft in einem kleinen Dialog ab.
    func gitCommitAll() {
        guard projectURL != nil else { return }
        guard let message = Self.promptForText(
            title: "Commit",
            info: "Alle Änderungen werden committet. Kurze Botschaft:",
            placeholder: "z.B. Tippfehler in README behoben"
        ), !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        runGitAction(["add", "-A"], label: "Stagen") { [weak self] in
            self?.runGitAction(["commit", "-m", message], label: "Commit")
        }
    }

    /// Letzten Commit um die aktuellen Änderungen ergänzen, Botschaft behalten
    /// (`git commit --amend --no-edit`) — die pfiffige Variante „Ups, das
    /// gehörte noch dazu", ohne die Message anzufassen.
    func gitAmendNoEdit() {
        guard projectURL != nil else { return }
        runGitAction(["add", "-A"], label: "Stagen") { [weak self] in
            self?.runGitAction(["commit", "--amend", "--no-edit"], label: "Ergänzen")
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
        guard let root = projectURL else { return }
        let isUntracked = change.unstaged == .untracked
        guard Self.confirmDiscard(name: change.name, untracked: isUntracked) else { return }
        if isUntracked {
            // Untracked: Datei physisch entfernen (VS-Code-Verhalten „Discard").
            try? FileManager.default.removeItem(at: root.appendingPathComponent(change.path))
            refreshGitStatus()
            refreshOpenGitViews()
        } else {
            runGitAction(["checkout", "--", change.path], label: "Verwerfen")
        }
    }

    /// Bereitgestellte Änderungen committen. Nichts bereitgestellt → erst alles
    /// bereitstellen, dann committen (VS-Code-Verhalten). Leere Botschaft = Beep.
    func gitCommit(message: String) {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { NSSound.beep(); return }
        guard projectURL != nil else { return }
        let done: () -> Void = { [weak self] in
            self?.commitMessage = ""
            self?.refreshGitStatus()
            self?.refreshGitLog()          // Graph-Tab nach Commit aktualisieren
            self?.refreshOpenGitViews()
        }
        if gitStatus?.stagedChanges.isEmpty == false {
            runGitAction(["commit", "-m", msg], label: "Commit", then: done)
        } else {
            runGitAction(["add", "-A"], label: "Bereitstellen") { [weak self] in
                self?.runGitAction(["commit", "-m", msg], label: "Commit", then: done)
            }
        }
    }

    /// Destruktive Verwerfen-Rückfrage (in Selbsttests via `presentGitDialogs`
    /// unterdrückt → dort implizit „ja").
    static func confirmDiscard(name: String, untracked: Bool) -> Bool {
        guard presentGitDialogs else { return true }
        let alert = NSAlert()
        // codereview-ok: „…“ (U+201E/U+201C) IST das korrekte deutsche Anführungszeichen-Paar (2026-07-12)
        alert.messageText = "Änderungen an „\(name)“ verwerfen?"
        alert.informativeText = untracked
            ? "Die nicht versionierte Datei wird gelöscht. Das lässt sich nicht rückgängig machen."
            : "Die Änderungen an dieser Datei gehen verloren. Das lässt sich nicht rückgängig machen."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Verwerfen")
        alert.addButton(withTitle: "Abbrechen")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Netzwerk

    /// Lokale Commits hochladen (`git push`). Pfiffiges Extra: hat der aktuelle
    /// Branch noch keinen Upstream (typischer erster Push eines neuen Branches),
    /// wird automatisch `push -u origin HEAD` gemacht — statt die kryptische
    /// „has no upstream branch"-Fehlermeldung zu zeigen, die genau Daniels
    /// Zielgruppe ausbremst.
    func gitPush() {
        guard let root = projectURL, GitRunner.isAvailable else { return }
        // Upstream vorhanden? `@{u}` löst nur mit gesetztem Upstream auf.
        GitRunner.run(["rev-parse", "--abbrev-ref", "@{u}"], in: root) { [weak self] result in
            guard let self else { return }
            if result?.ok == true {
                self.runGitAction(["push"], label: "Push")
            } else {
                self.runGitAction(["push", "-u", "origin", "HEAD"], label: "Push (Upstream anlegen)")
            }
        }
    }

    /// Entfernten Stand holen und einbinden (`git pull`, erzeugt bei Bedarf
    /// einen Merge-Commit).
    func gitPull() { runGitAction(["pull"], label: "Pull") }

    /// Fast-Forward-only Pull (`git pull --ff-only`) — die pfiffige Variante:
    /// übernimmt entfernte Commits NUR, wenn nichts kollidiert, nie ein
    /// Merge-Commit. Hält die Historie linear.
    func gitPullFastForward() { runGitAction(["pull", "--ff-only"], label: "Pull (Fast-Forward)") }

    /// Entfernten Stand holen, ohne lokal etwas zu ändern (`git fetch`).
    func gitFetch() { runGitAction(["fetch"], label: "Fetch") }

    // MARK: Pfiffige Extras

    /// Zum zuletzt ausgecheckten Branch zurück (`git switch -`).
    func gitSwitchPrevious() { runGitAction(["switch", "-"], label: "Branch-Wechsel") }

    /// Pickaxe-Suche (`git log -S<text>`): findet die Commits, die eine
    /// Textstelle eingeführt oder entfernt haben. Öffnet das Ergebnis als
    /// klickbaren Verlaufs-Tab (passt zur Suchen-&-Ersetzen-DNA).
    func gitPickaxe() {
        guard projectURL != nil else { return }
        guard let term = Self.promptForText(
            title: "Verlauf durchsuchen",
            info: "Findet Commits, die diesen Text eingeführt oder entfernt haben:",
            placeholder: "z.B. deprecatedFunction"
        ), !term.isEmpty else { return }

        loadGitTab(kind: .log, title: "Suche: \(term)",
                   args: ["log", "-S" + term, "--oneline", "--decorate"],
                   emptyText: "Keine Commits berühren diesen Text.")
    }

    // MARK: - Ausführung & Rückmeldung

    /// Führt eine git-Aktion aus, frischt bei Erfolg den Git-Zustand auf und
    /// ruft optional `then` (für verkettete Schritte wie add→commit). Bei einem
    /// Fehler zeigt es die echte git-Ausgabe in einem Dialog und bricht die
    /// Kette ab.
    private func runGitAction(_ args: [String], label: String, then: (() -> Void)? = nil) {
        guard let root = projectURL, GitRunner.isAvailable else { return }
        GitRunner.run(args, in: root) { [weak self] result in
            guard let self else { return }
            guard let result, result.ok else {
                Self.presentGitError(label: label, result: result)
                return
            }
            if let then {
                then()
            } else {
                // Kette fertig: Status + offene Verlauf-/Diff-Tabs auffrischen.
                self.refreshGitStatus()
                self.refreshOpenGitViews()
            }
        }
    }

    /// Frischt einen offenen „Git-Verlauf"- bzw. „Git-Diff"-Tab nach einer
    /// schreibenden Aktion auf (Snapshot war sonst veraltet). Commit-Tabs
    /// (`git show <hash>`) bleiben gültig (historisch) und werden nicht angefasst.
    private func refreshOpenGitViews() {
        if tabs.contains(where: { $0.gitKind == .log && $0.title == "Git-Verlauf" }) {
            openGitLog()
        }
        if tabs.contains(where: { $0.gitKind == .diff && $0.title == "Git-Diff" }) {
            openGitDiff()
        }
    }

    // MARK: - Dialog-Helfer

    /// Modaler Ein-Zeilen-Eingabedialog (NSAlert + NSTextField), gleiches Muster
    /// wie „Zu Zeile springen". Liefert `nil` bei Abbruch.
    static func promptForText(title: String, info: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")
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
        let raw = [result?.stderr, result?.stdout]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        let text = raw ?? "git lieferte keine Meldung (Exit-Code \(result?.exitCode ?? -1))."
        guard presentGitDialogs else {
            FileHandle.standardError.write(Data("GIT-ERROR [\(label)]: \(text)\n".utf8))
            return
        }
        NSAlert.runWarning(title: "\(label) fehlgeschlagen", text: text)
    }
}
