import SwiftUI
import AppKit

/// Hierarchischer Projekt-Dateibaum in der Seitenleiste. Lädt lazy: jede
/// Ordner-Ebene erst beim Aufklappen (`FileTree.children`), kein rekursiver
/// Vollscan beim Projekt-Öffnen. Klick auf eine Datei lädt sie in einen Tab
/// (derselbe Pfad wie ⌘O — Encoding-Erkennung, Tab-Dedup inklusive).
struct FileTreeSidebar: View {
    let rootURL: URL
    @EnvironmentObject var workspace: Workspace

    /// Rekursiver FSEvents-Wächter; seine Generation macht externe Änderungen
    /// zu echten SwiftUI-State-Änderungen und löst damit ein neues Listing aus.
    @StateObject private var watcher: ProjectFileWatcher

    /// Aufgeklappte Ordner (Pfad-Set). Identität über Pfade, damit der
    /// Zustand ein Neuladen der Ebenen überlebt.
    @State private var expanded: Set<String>

    /// Asynchron festgestellte leere Ordner → deren Zeilen verlieren das
    /// Aufklapp-Chevron (Etappe 1 Wunschpaket 2026-07).
    @StateObject private var emptiness = FolderEmptinessCache()

    /// Ergebnis des Dateinamens-Filters (Etappe 3 Wunschpaket 2026-07c).
    /// `nil` = kein Filter aktiv ODER Scan läuft noch. Der gespeicherte
    /// Aufklappzustand (`expanded`) bleibt während des Filterns unberührt —
    /// Escape/X stellt so automatisch den vorigen Zustand wieder her.
    @State private var filterResult: FileTreeFilterResult?
    /// Laufender Scan — ein neuer Tastendruck ersetzt ihn (Debounce+Cancel).
    @State private var filterScanTask: Task<Void, Never>?

    init(rootURL: URL) {
        self.rootURL = rootURL
        _watcher = StateObject(wrappedValue: ProjectFileWatcher(rootURL: rootURL))
        _expanded = State(initialValue: FileTreeExpansionStore.load(for: rootURL))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Kopfzeile: gemeinsame Komponente (alle Seitenleisten-Tabs);
            // der Dateien-Tab hängt sein Vollmenü unter die Standardpunkte.
            // „Im Finder zeigen“ liefert schon der gemeinsame Kopf — deshalb
            // blendet das Vollmenü seinen eigenen Finder-Punkt hier aus.
            SidebarProjectHeader(rootURL: rootURL) {
                Divider()
                FileTreeContextMenu(directory: rootURL, node: nil,
                                    includeFinderReveal: false,
                                    onMutation: handleTreeMutation)
                    .environmentObject(workspace)
            }

            // Branch-Zeile (Etappe 2): nur sichtbar, wenn das Projekt ein
            // Git-Repo ist und git verfügbar (sonst still weg). Zeigt Branch,
            // Ahead/Behind und einen dezenten Auffrisch-Knopf.
            if let status = workspace.gitStatus {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .fastraFont(size: 10)
                        .foregroundColor(Theme.accentReadable)
                    Menu {
                        ForEach(workspace.gitBranches) { candidate in
                            Button {
                                workspace.gitSwitchBranch(candidate.name)
                            } label: {
                                if candidate.isCurrent {
                                    Label(candidate.name, systemImage: "checkmark")
                                } else {
                                    Text(candidate.name)
                                }
                            }
                            .disabled(candidate.isCurrent)
                        }
                        if workspace.gitBranches.isEmpty {
                            Button("Keine lokalen Branches") { }.disabled(true)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(status.branch ?? L10n.string("Detached HEAD"))
                                .fastraFont(.small)
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(status.upstream ?? L10n.string("Kein Upstream"))
                                .fastraFont(size: 9)
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Lokalen Branch auswählen")
                    .disabled(workspace.gitOperationsAreBusy)
                    if status.ahead > 0 || status.behind > 0 {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(Self.aheadBehindText(status))
                                .fastraFont(size: 9)
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(2)
                                .help(Self.comparisonDescription(
                                    status, fetch: workspace.gitRepositorySnapshot?.fetch,
                                    now: context.date
                                ))
                                .accessibilityLabel(L10n.format(
                                    "Vergleich mit %@: %@",
                                    status.upstream ?? L10n.string("Kein Upstream"),
                                    Self.aheadBehindText(status)
                                ))
                                .accessibilityHint("Der Vergleich nutzt den zuletzt abgerufenen Remote-Tracking-Stand. Der Server kann bereits neuer sein.")
                        }
                    }
                    Spacer(minLength: 0)
                    // Verlauf öffnen (git log --graph als read-only-Tab).
                    Button {
                        workspace.openGitLog()
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .fastraFont(size: 10)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Verlauf anzeigen (git log)")
                    .accessibilityLabel("Git-Verlauf anzeigen")
                    .accessibilityHint("Öffnet den Commit-Verlauf als schreibgeschützten Tab.")
                    // Diff öffnen (git diff HEAD als read-only-Tab). Nur sinnvoll,
                    // wenn es überhaupt Änderungen gibt — sonst gedimmt lassen,
                    // aber klickbar (zeigt dann „keine Änderungen").
                    Button {
                        workspace.openGitDiff()
                    } label: {
                        Image(systemName: "plusminus")
                            .fastraFont(size: 10)
                            .foregroundColor(status.entries.isEmpty ? Theme.textSecondary.opacity(0.5) : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Änderungen anzeigen (git diff)")
                    .accessibilityLabel("Git-Änderungen anzeigen")
                    .accessibilityHint("Öffnet den aktuellen Git-Diff als schreibgeschützten Tab.")
                    // Aktions-Menü (Commit/Push/Pull + pfiffige Varianten).
                    // Die dezenten Hilfe-Texte hängen als Tooltip an jedem Punkt.
                    Menu {
                        gitActionMenuItems
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .fastraFont(size: 10)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Git-Aktionen")
                    .accessibilityLabel("Git-Aktionen")
                    .accessibilityHint("Öffnet weitere sichere Git-Befehle.")

                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        fetchControl(now: context.date)
                    }

                    Button {
                        workspace.gitPull()
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                            .fastraFont(size: 10)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(workspace.gitOperationsAreBusy)
                    .help(L10n.format("Entfernte Commits mit %@ einbinden",
                                      workspace.gitPullStrategyName))
                    .accessibilityLabel("Pull")
                    .accessibilityHint("Prüft Upstream, lokale Änderungen und laufende Git-Vorgänge vor dem Pull.")

                    Button {
                        workspace.refreshGitStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .fastraFont(size: 9, weight: .semibold)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Git-Status neu einlesen")
                    .accessibilityLabel("Git-Status neu einlesen")
                    .accessibilityHint("Liest Branch, Änderungen und Vorgangsstatus erneut aus Git.")
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }

            if let feedback = workspace.gitFeedback {
                Label(feedback.message, systemImage: "checkmark.circle.fill")
                    .fastraFont(.small)
                    .foregroundColor(Theme.diffAddedFG)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    .transition(.opacity)
                    .accessibilityIdentifier("gitSuccessFeedback")
            }

            // Dezenter, nicht-modaler Hinweis — z. B. „Seitenleiste zeigt
            // jetzt …“ nach dem automatischen Ordnerwechsel (Etappe 1). Er
            // blendet sich nach wenigen Sekunden von selbst wieder aus.
            if let notice = workspace.sidebarNotice {
                Label(notice, systemImage: "arrow.triangle.2.circlepath")
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    .transition(.opacity)
                    .accessibilityIdentifier("sidebarNotice")
            }

            // Dateinamens-Filter (Etappe 3 Wunschpaket 2026-07c). Bewusst ein
            // DAUERHAFT sichtbares kompaktes Feld statt einer ausklappbaren
            // Lupe: zentrale Funktionen müssen sichtbar und mit der Maus
            // erreichbar sein (Produktregel) — ein verstecktes Feld würde
            // schlicht nicht gefunden, und die Seitenleiste hat den Platz.
            filterField

            if let result = filterResult, result.matchCount == 0,
               !workspace.fileTreeFilterQuery.isEmpty {
                // Leerer Treffer → verständlicher Leerzustand statt leerem
                // Baum, mit Brücke zur Volltextsuche (Ordner-Scope).
                filterEmptyState(result)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        FileTreeLevel(url: rootURL, depth: 0, expanded: $expanded,
                                      filter: activeFilterResult,
                                      emptiness: emptiness,
                                      onMutation: handleTreeMutation)
                    }
                    .padding(.bottom, 6)
                }
                // Das Lesen bindet die Published-Generation an diesen View.
                // Jede Änderung baut die sichtbaren Ebenen neu. Bewusst NUR
                // am Baum (nicht an Kopf + Filterfeld): FSEvents dürfen dem
                // Nutzer nicht das Filterfeld unter den Fingern zurücksetzen.
                .id(watcher.generation)
            }
        }
        .onChange(of: expanded) {
            FileTreeExpansionStore.save(expanded, for: rootURL)
        }
        .onChange(of: workspace.fileTreeFilterQuery) { _, newValue in
            scheduleFilterScan(query: newValue, debounced: true)
        }
        .onChange(of: watcher.generation) {
            // Externe Dateiänderungen bei aktivem Filter: denselben Scan
            // idempotent wiederholen — das Ergebnis hängt nur vom aktuellen
            // Plattenstand ab, nie von der Anzahl der Events.
            if !workspace.fileTreeFilterQuery.isEmpty {
                scheduleFilterScan(query: workspace.fileTreeFilterQuery,
                                   debounced: false)
            }
        }
        .onAppear {
            // Der Befehle-Button muss laufende Vorgänge und die Herkunft der
            // Identität auch erkennen, wenn der Nutzer nie in den Changes-Tab
            // wechselt. Beide Reads bleiben asynchron und repositorykoordiniert.
            //
            // WICHTIG: erst im nächsten Main-Loop-Durchlauf. Seit die
            // Seitenleiste auch programmatisch erscheinen kann (Elternordner-
            // Öffnen nach Einzeldatei, Etappe 1), läuft dieses onAppear sonst
            // MITTEN im SwiftUI-Layout-Pass — und `GitRunner.isAvailable`
            // spinnt beim allerersten Aufruf über `xcode-select` den RunLoop
            // (`waitUntilExit`). Ein UpdateCycle-Observer feuert dann reentrant
            // im Layout und stürzt ab (SIGSEGV, Befund Selbsttest 2026-07-17).
            DispatchQueue.main.async {
                workspace.refreshGitOperationState()
                workspace.refreshGitIdentity()
            }
        }
    }

    private func handleTreeMutation() {
        watcher.refresh()
        workspace.refreshGitStatus()
    }

    // MARK: - Dateinamens-Filter (Etappe 3 Wunschpaket 2026-07c)

    /// Nur ein fertiges Ergebnis ZUM AKTUELLEN Suchtext filtert den Baum —
    /// veraltete Ergebnisse (Nutzer tippt schneller als der Scan) nie.
    private var activeFilterResult: FileTreeFilterResult? {
        guard !workspace.fileTreeFilterQuery.isEmpty,
              let result = filterResult,
              result.query == workspace.fileTreeFilterQuery else { return nil }
        return result
    }

    private var filterField: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .fastraFont(size: 10)
                    .foregroundColor(Theme.textSecondary)
                TextField(L10n.string("Dateien filtern"),
                          text: $workspace.fileTreeFilterQuery)
                    .textFieldStyle(.plain)
                    .fastraFont(.small)
                    .foregroundColor(Theme.textPrimary)
                    // Escape leert den Filter — der Baum zeigt danach wieder
                    // seinen alten Aufklappzustand (der blieb unangetastet).
                    .onExitCommand { workspace.fileTreeFilterQuery = "" }
                    .help("Filtert den Dateibaum nach Dateinamen (Teilstring, Groß-/Kleinschreibung egal). Inhalte durchsucht „In Ordnern suchen…“ (⇧⌘F).")
                if !workspace.fileTreeFilterQuery.isEmpty {
                    Button {
                        workspace.fileTreeFilterQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .fastraFont(size: 10)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Filter leeren (Escape)")
                    .accessibilityLabel("Filter leeren")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.surfaceBase)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Theme.stroke, lineWidth: 1))

            // Zähler „N von M Dateien" + sichtbare Kappungs-Warnung.
            if let result = activeFilterResult {
                Text(result.truncated
                     ? L10n.format("%ld von %ld Dateien — nur die ersten %ld geprüft",
                                   result.matchCount, result.totalFileCount,
                                   FileTreeFilter.maximumScannedFiles)
                     : L10n.format("%ld von %ld Dateien",
                                   result.matchCount, result.totalFileCount))
                    .fastraFont(size: 9)
                    .foregroundColor(Theme.textSecondary)
                    .padding(.leading, 2)
                    .accessibilityLabel(L10n.format("%ld von %ld Dateien",
                                                    result.matchCount,
                                                    result.totalFileCount))
                    // Selbsttest `sidebarfilter` liest hier den ECHT
                    // gerenderten Zählerstand ab.
                    .background(SelfTestMarker(
                        id: "sidebarFilterState-n\(result.matchCount)-m\(result.totalFileCount)"
                    ).frame(width: 0, height: 0))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func filterEmptyState(_ result: FileTreeFilterResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.format("Keine Dateinamen passen zu „%@“.",
                             workspace.fileTreeFilterQuery))
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // Brücke zur Volltextsuche: Der Dateibaum filtert nur NAMEN —
            // wer Inhalte sucht, landet hier richtig.
            Button {
                workspace.scope = .folder
                workspace.showSearchDialog = true
            } label: {
                Label(L10n.string("Im Inhalt suchen…"), systemImage: "text.magnifyingglass")
                    .fastraFont(.small)
            }
            .buttonStyle(.link)
            .help("Öffnet den Suchdialog mit Ordner-Bereich für die Volltextsuche.")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SelfTestMarker(id: "sidebarFilterEmpty").frame(width: 0, height: 0))
    }

    /// Startet den asynchronen Filter-Scan. Tippen ist debounced (150 ms),
    /// FSEvents-Wiederholungen laufen sofort; ein neuer Scan bricht den
    /// laufenden ab. Ergebnisse veralteter Suchtexte werden verworfen.
    private func scheduleFilterScan(query: String, debounced: Bool) {
        filterScanTask?.cancel()
        guard !query.isEmpty else {
            filterScanTask = nil
            filterResult = nil
            return
        }
        let root = rootURL
        filterScanTask = Task {
            if debounced {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                FileTreeFilter.scan(rootURL: root, query: query)
            }.value
            guard let result, !Task.isCancelled else { return }
            await MainActor.run {
                // Nur übernehmen, wenn der Nutzer nicht längst weitertippte.
                guard workspace.fileTreeFilterQuery == query else { return }
                filterResult = result
            }
        }
    }

    static func aheadBehindText(_ status: GitStatusSummary) -> String {
        var parts: [String] = []
        if status.ahead == 1 {
            parts.append(L10n.string("1 lokaler Commit voraus"))
        } else if status.ahead > 1 {
            parts.append(L10n.format("%ld lokale Commits voraus", status.ahead))
        }
        if status.behind == 1 {
            parts.append(L10n.string("1 entfernter Commit fehlt"))
        } else if status.behind > 1 {
            parts.append(L10n.format("%ld entfernte Commits fehlen", status.behind))
        }
        return parts.joined(separator: L10n.string(", "))
    }

    @ViewBuilder private func fetchControl(now: Date) -> some View {
        if workspace.gitRepositorySnapshot?.fetch.isBusy == true {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Remote-Änderungen werden abgerufen")
        } else {
            Button { workspace.gitFetch() } label: {
                Image(systemName: workspace.gitRepositorySnapshot?.fetch.error == nil
                      ? "arrow.down.circle" : "exclamationmark.arrow.circlepath")
                    .fastraFont(size: 10)
                    .foregroundColor(workspace.gitRepositorySnapshot?.fetch.error == nil
                                     ? Theme.textSecondary : Theme.diffRemovedFG)
            }
            .buttonStyle(.plain)
            .disabled(workspace.gitOperationsAreBusy)
            .help(Self.fetchDescription(workspace.gitRepositorySnapshot?.fetch, now: now))
            .accessibilityLabel(workspace.gitRepositorySnapshot?.fetch.error == nil
                                ? "Remote-Änderungen abrufen" : "Fetch erneut versuchen")
            .accessibilityValue(Self.fetchDescription(
                workspace.gitRepositorySnapshot?.fetch, now: now
            ))
            .accessibilityHint("Führt git fetch aus und ändert keine lokalen Dateien.")
        }
    }

    static func comparisonDescription(_ status: GitStatusSummary,
                                      fetch: GitFetchSnapshot?, now: Date) -> String {
        let upstream = status.upstream ?? L10n.string("Kein Upstream")
        return L10n.format("Vergleich mit %@: %@. %@ Der Vergleich nutzt den zuletzt abgerufenen Remote-Tracking-Stand; der Server kann bereits neuer sein.",
                           upstream, aheadBehindText(status),
                           fetchDescription(fetch, now: now))
    }

    static func fetchDescription(_ snapshot: GitFetchSnapshot?, now: Date = Date()) -> String {
        guard let snapshot else { return L10n.string("Noch nie abgerufen") }
        if let error = snapshot.error {
            let success = snapshot.lastSuccess.map { ageDescription(since: $0, now: now) }
                ?? L10n.string("noch nie erfolgreich")
            return L10n.format("Letzter Fetch fehlgeschlagen: %@ · Letzter Erfolg: %@",
                               error, success)
        }
        guard let date = snapshot.lastSuccess else {
            return L10n.string("Noch nie erfolgreich abgerufen")
        }
        return L10n.format("Zuletzt %@ abgerufen", ageDescription(since: date, now: now))
    }

    static func ageDescription(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return L10n.string("vor weniger als einer Minute") }
        let minutes = seconds / 60
        if minutes < 60 {
            return minutes == 1 ? L10n.string("vor 1 Minute")
                : L10n.format("vor %ld Minuten", minutes)
        }
        let hours = minutes / 60
        if hours < 48 {
            return hours == 1 ? L10n.string("vor 1 Stunde")
                : L10n.format("vor %ld Stunden", hours)
        }
        let days = hours / 24
        if days < 7 {
            return days == 1 ? L10n.string("vor 1 Tag")
                : L10n.format("vor %ld Tagen", days)
        }
        return DateFormatter.localizedString(from: date, dateStyle: .medium,
                                             timeStyle: .short)
    }

    /// Die Git-Aktions-Einträge — geteilt zwischen Seitenleisten-Popup und dem
    /// „Git"-Menü in der Menüleiste (via `GitActionMenu`).
    @ViewBuilder private var gitActionMenuItems: some View {
        GitActionMenu(workspace: workspace)
    }
}

/// Die kuratierten Git-Aktionen als Menü-Einträge (Etappe 2, Schritt 4).
/// Einmal definiert, an zwei Stellen eingehängt: Seitenleisten-Popup und
/// „Git"-Menü in der Menüleiste. Jeder Punkt trägt seinen dezenten Hilfe-Text
/// als Tooltip (`.help`) — sichtbar bei Bedarf, nie aufdringlich.
struct GitActionMenu: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        Button("Alles committen…") { workspace.gitCommitAll() }
            .help("Alle Änderungen stagen und committen (git add -A + commit).")
            .disabled(workspace.gitOperationsAreBusy)
        Button("Letzten Commit ergänzen") { workspace.gitAmendNoEdit() }
            .help("Aktuelle Änderungen in den letzten Commit aufnehmen, Botschaft bleibt (git commit --amend --no-edit).")
            .disabled(workspace.gitOperationsAreBusy)

        Divider()

        Button("Push") { workspace.gitPush() }
            .help("Lokale Commits zum entfernten Repository hochladen (git push).")
            .disabled(workspace.gitOperationsAreBusy)
        Button("Pull (Fast-Forward)") { workspace.gitPullFastForward() }
            .help("Entfernte Commits nur übernehmen, wenn nichts kollidiert — kein Merge-Commit (git pull --ff-only).")
            .disabled(workspace.gitOperationsAreBusy)
        Button("Pull") { workspace.gitPull() }
            .help("Entfernte Commits mit der in Fastra gewählten expliziten Strategie einbinden.")
            .disabled(workspace.gitOperationsAreBusy)
        Button("Fetch") { workspace.gitFetch() }
            .help("Entfernten Stand holen, ohne lokal etwas zu ändern (git fetch).")
            .disabled(workspace.gitOperationsAreBusy)

        Divider()

        Button("Verlauf durchsuchen…") { workspace.gitPickaxe() }
            .help("Finde den Commit, der eine Textstelle eingeführt oder entfernt hat (git log -S).")
        Button("Zum vorherigen Branch") { workspace.gitSwitchPrevious() }
            .help("Zum zuletzt ausgecheckten Branch zurückspringen (git switch -).")
            .disabled(workspace.gitOperationsAreBusy)

        Button("Neuen Branch erstellen…") { workspace.gitCreateBranch() }
            .help("Erstellt nach Git-Prüfung einen neuen Branch am aktuellen Commit.")
            .disabled(workspace.gitOperationsAreBusy)
        Button("Getrackte Änderungen stashen…") { workspace.gitStash(includeUntracked: false) }
            .help("Legt einen Stash nur für getrackte Änderungen an; nichts wird automatisch gepusht.")
            .disabled(workspace.gitOperationsAreBusy)
        Button("Änderungen inkl. unversionierter Dateien stashen…") {
            workspace.gitStash(includeUntracked: true)
        }
        .help("Legt einen Stash einschließlich unversionierter Dateien an.")
        .disabled(workspace.gitOperationsAreBusy)
        Button("Letzten Stash anwenden…") { workspace.gitStashPop() }
            .help("Nur bei sauberem Arbeitsbaum; kann Konflikte erzeugen.")
            .disabled(workspace.gitOperationsAreBusy)

        if workspace.gitOperationState == .rebase {
            Button("Aktuellen Rebase-Commit überspringen…") { workspace.gitSkipRebase() }
                .help("Warnung: Lässt den aktuellen Commit aus dem neu aufgebauten Verlauf aus.")
                .disabled(workspace.gitOperationsAreBusy)
        }
        if workspace.gitOperationState != nil {
            Button("Git-Vorgang fortsetzen") { workspace.gitContinueOperation() }
                .disabled(!GitOperationControlAvailability.continueEnabled(
                    isBusy: workspace.gitOperationsAreBusy,
                    hasConflicts: !workspace.conflictedGitChanges.isEmpty
                ))
                .help(GitOperationControlText.continueHelp(
                    hasConflicts: !workspace.conflictedGitChanges.isEmpty,
                    isBusy: workspace.gitOperationsAreBusy
                ))
            Button("Git-Vorgang abbrechen…") { workspace.gitAbortOperation() }
                .disabled(!GitOperationControlAvailability.abortEnabled(
                    isBusy: workspace.gitOperationsAreBusy
                ))
                .help(GitOperationControlText.abortHelp(
                    isBusy: workspace.gitOperationsAreBusy
                ))
        }

        Button("Force Push with Lease…") { workspace.gitForcePushWithLease() }
            .help("Erzwingt nur mit --force-with-lease und eigener Bestätigung; niemals blindes --force.")
            .disabled(workspace.gitOperationsAreBusy)

        Divider()
        Button("Git-Identität konfigurieren…") { workspace.gitConfigureIdentity() }
            .help(workspace.gitIdentity?.sourceDescription
                  ?? L10n.string("Repository-lokale und globale Git-Identität prüfen oder konfigurieren."))
            .disabled(workspace.gitOperationsAreBusy)

        Divider()
        Button("Terminal im aktuellen Ordner …") { workspace.openTerminal() }
            .disabled(workspace.terminalDirectory == nil)
            .help(workspace.terminalDirectory == nil
                  ? workspace.terminalUnavailableReason
                  : L10n.string("Öffnet Terminal.app nativ im Projektordner."))
    }
}

/// Eine Ordner-Ebene: listet die Kinder eines Ordners und rendert für
/// aufgeklappte Unterordner rekursiv die nächste Ebene. Die Kinder werden
/// direkt im `body` gelesen — ein Verzeichnis-Listing ist mikrosekunden-
/// schnell, und der Baum ist so bei jedem Neu-Render automatisch aktuell
/// (kein Live-Watch des Dateisystems nötig; `.onAppear`-Ladelogik war hier
/// zudem unzuverlässig — der Baum blieb leer, Befund Screenshot 2026-07-12).
/// Es rendern ohnehin nur AUFGEKLAPPTE Ebenen, große Repos bleiben billig.
private struct FileTreeLevel: View {
    let url: URL
    let depth: Int
    @Binding var expanded: Set<String>
    /// Aktiver Dateinamens-Filter (Etappe 3): blendet Nicht-Treffer aus und
    /// klappt Treffer-Pfade ZWANGSWEISE auf — ohne `expanded` anzufassen,
    /// damit Escape/X den vorigen Zustand unverändert wiederherstellt.
    let filter: FileTreeFilterResult?
    @ObservedObject var emptiness: FolderEmptinessCache
    @EnvironmentObject var workspace: Workspace
    let onMutation: () -> Void

    /// Effektiver Aufklappzustand: beim Filtern erzwungen, sonst gespeichert.
    private func isExpanded(_ node: FileTreeNode) -> Bool {
        if let filter {
            return filter.expandedDirectories.contains(node.url.path)
        }
        return expanded.contains(node.id)
    }

    var body: some View {
        ForEach(visibleChildren) { node in
            FileTreeRow(node: node,
                        depth: depth,
                        isExpanded: isExpanded(node),
                        filterActive: filter != nil,
                        isActive: workspace.activeTab?.url == node.url,
                        isSelected: node.isDirectory
                            && workspace.selectedFileTreeFolder == node.url,
                        // Erst Chevron zeigen, dann ggf. entfernen: bis die
                        // Hintergrund-Prüfung fertig ist, gilt der Ordner als
                        // aufklappbar (kein Blockieren auf langsamen Volumes).
                        showsChevron: !emptiness.isKnownEmpty(node.url),
                        gitState: workspace.gitState(for: node.url),
                        gitFolderChanged: node.isDirectory
                            && workspace.gitFolderHasChanges(node.url),
                        onMutation: onMutation) {
                if node.isDirectory {
                    // Ordner-Klick markiert den Ordner (Save-Dialog-Vorschlag,
                    // Etappe 1); leere Ordner bleiben selektierbar, klappen
                    // aber nichts auf.
                    workspace.selectedFileTreeFolder = node.url
                    if emptiness.isKnownEmpty(node.url) { return }
                    // Beim Filtern ist die Aufklappung erzwungen — der
                    // gespeicherte Zustand darf sich nicht still ändern.
                    if filter != nil { return }
                    if expanded.contains(node.id) {
                        expanded.remove(node.id)
                    } else {
                        expanded.insert(node.id)
                    }
                } else {
                    // Datei-Klick hebt die Ordner-Markierung wieder auf.
                    workspace.selectedFileTreeFolder = nil
                    workspace.loadFile(at: node.url)
                }
            }
            .onAppear {
                if node.isDirectory { emptiness.probe(node.url) }
            }
            if node.isDirectory && isExpanded(node) {
                FileTreeLevel(url: node.url, depth: depth + 1,
                              expanded: $expanded, filter: filter,
                              emptiness: emptiness,
                              onMutation: onMutation)
            }
        }
    }

    /// Kinder dieser Ebene — unter aktivem Filter nur Treffer-Dateien und
    /// Ordner auf dem Weg zu Treffern.
    private var visibleChildren: [FileTreeNode] {
        let children = FileTree.children(of: url)
        guard let filter else { return children }
        return children.filter { FileTreeFilter.isVisible(node: $0, result: filter) }
    }
}

/// Eine Zeile im Dateibaum: Einrückung nach Tiefe, Chevron nur bei Ordnern,
/// aktive Datei hervorgehoben (gleiche Sprache wie `FileRow` der
/// „GEÖFFNET"-Liste).
private struct FileTreeRow: View {
    let node: FileTreeNode
    let depth: Int
    let isExpanded: Bool
    /// `true`, während der Dateinamens-Filter aktiv ist — Teil der
    /// Selbsttest-Marker-ID (siehe unten).
    let filterActive: Bool
    let isActive: Bool
    /// Ordner in der Seitenleiste markiert (Save-Dialog-Vorschlag, Etappe 1).
    let isSelected: Bool
    /// `false`, sobald die Hintergrund-Prüfung den Ordner als leer erkannt
    /// hat — dann Ordnersymbol ohne Aufklapp-Chevron, weiter selektierbar.
    let showsChevron: Bool
    /// Git-Zustand dieser Datei (nil = unverändert / kein Repo).
    let gitState: GitFileState?
    /// Enthält dieser Ordner geänderte Dateien? (Rollup-Punkt an Ordnern.)
    let gitFolderChanged: Bool
    let onMutation: () -> Void
    let action: () -> Void

    /// Textfarbe des Namens: geänderte Datei in ihrer Git-Farbe, aktive Datei
    /// betont, sonst gedämpft. Git-Farbe schlägt den Aktiv-Zustand nicht —
    /// die Aktiv-Hervorhebung reicht über den Hintergrund.
    private var nameColor: Color {
        if let gitState { return Theme.gitColor(for: gitState) }
        return isActive || isSelected ? Theme.textPrimary : Theme.textSecondary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if node.isDirectory {
                    if showsChevron {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .fastraFont(size: 8, weight: .semibold)
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 10)
                    } else {
                        // Leerer Ordner: Platz bleibt reserviert, damit die
                        // Einrückung aller Zeilen bündig bleibt.
                        Spacer().frame(width: 10)
                    }
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .fastraFont(size: 11)
                        .foregroundColor(Theme.textSecondary)
                } else {
                    Spacer().frame(width: 10)
                    Image(systemName: "doc")
                        .fastraFont(size: 11)
                        .foregroundColor(isActive ? Theme.accentReadable : Theme.textSecondary)
                }
                Text(node.name)
                    .fastraFont(.small)
                    .foregroundColor(nameColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                // Git-Badge rechts: Datei-Kürzel (M/U/A/…) oder ein dezenter
                // Punkt am Ordner, dessen Inhalt Änderungen enthält.
                if let gitState {
                    Text(gitState.badge)
                        .fastraFont(size: 10, weight: .semibold, design: .monospaced)
                        .foregroundColor(Theme.gitColor(for: gitState))
                        .help(gitState.tooltip)
                } else if gitFolderChanged {
                    Circle()
                        .fill(Theme.accentReadable)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.leading, 14 + CGFloat(depth) * 12)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .background(isActive || isSelected ? Theme.surfaceRaised : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            FileTreeContextMenu(directory: node.isDirectory
                                ? node.url : node.url.deletingLastPathComponent(),
                                node: node,
                                onMutation: onMutation)
        }
        // Selbsttests (`sidebarfilter`) prüfen über diesen Marker, welche
        // Zeilen WIRKLICH gerendert sind — nicht bloß den Modellzustand.
        // Die Filterphase steckt MIT in der ID: LazyVStack hält NSViews
        // entfernter Zeilen in einem Wiederverwendungs-Pool, eine bloße
        // „Marker weg?"-Prüfung wäre deshalb unzuverlässig. Gepoolte
        // Alt-Views tragen aber nie die ID der AKTUELLEN Phase.
        .background(SelfTestMarker(
            id: "fileTreeRow-\(node.name)-\(filterActive ? "gefiltert" : "voll")"
        ).frame(width: 0, height: 0))
    }
}

/// Native Dateiaktionen am Baum. Löschen bedeutet bewusst „in den Papierkorb“
/// statt unwiderruflichem `removeItem`; Umbenennen und Neu validieren Namen
/// zentral über `FileTreeOperations`.
private struct FileTreeContextMenu: View {
    let directory: URL
    let node: FileTreeNode?
    /// `false` nur am gemeinsamen Seitenleisten-Kopf: Dort zeigt bereits der
    /// Kopf selbst „Im Finder zeigen…“ — der Punkt wäre sonst doppelt.
    var includeFinderReveal: Bool = true
    let onMutation: () -> Void
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        Button("Neue Datei…") { create(isDirectory: false) }
        Button("Neuer Ordner…") { create(isDirectory: true) }

        Divider()
        if includeFinderReveal {
            Button("Im Finder zeigen…") { revealInFinder() }
        }
        Button("Terminal hier öffnen …") { workspace.openTerminal(at: directory) }
            .help("Öffnet Terminal.app nativ in diesem Ordner.")

        if let node {
            Divider()
            Button("Umbenennen…") { rename(node) }
            Button("In den Papierkorb legen…", role: .destructive) { trash(node) }
        }
    }

    /// Zeigt den angeklickten Eintrag im Finder. Beim Kontextmenü der
    /// Projektüberschrift gibt es keinen einzelnen Knoten; dort wird stattdessen
    /// der Projektordner selbst ausgewählt.
    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([node?.url ?? directory])
    }

    private func create(isDirectory: Bool) {
        let kindKey = isDirectory ? "Ordner" : "Datei"
        let kind = L10n.string(kindKey)
        guard let name = Workspace.promptForText(
            title: L10n.format("Neu: %@", kind),
            info: L10n.format("Name im Ordner „%@“:", directory.lastPathComponent),
            placeholder: L10n.string(isDirectory ? "Neuer Ordner" : "Neue Datei.txt")
        ) else { return }
        do {
            let created = try FileTreeOperations.create(named: name, in: directory,
                                                        isDirectory: isDirectory)
            onMutation()
            if !isDirectory { workspace.loadFile(at: created) }
        } catch {
            showError(title: L10n.format("%@ konnte nicht angelegt werden", kind), error: error)
        }
    }

    private func rename(_ node: FileTreeNode) {
        guard let name = Workspace.promptForText(
            title: L10n.string("Umbenennen"),
            info: L10n.format("Neuer Name für „%@“:", node.name),
            placeholder: node.name
        ) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != node.name else { return }
        do {
            let destination = try FileTreeOperations.rename(node.url, to: trimmed)
            workspace.handleFileTreeMove(from: node.url, to: destination)
            onMutation()
        } catch {
            showError(title: L10n.format("„%@“ konnte nicht umbenannt werden", node.name), error: error)
        }
    }

    private func trash(_ node: FileTreeNode) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.format("„%@“ in den Papierkorb legen?", node.name)
        alert.informativeText = L10n.string("Der Eintrag kann über den Finder wiederhergestellt werden.")
        alert.addButton(withTitle: L10n.string("In den Papierkorb"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        NSWorkspace.shared.recycle([node.url]) { _, error in
            DispatchQueue.main.async {
                if let error {
                    showError(title: L10n.format("„%@“ konnte nicht verschoben werden", node.name),
                              error: error)
                } else {
                    workspace.handleFileTreeTrash(node.url)
                    onMutation()
                }
            }
        }
    }

    private func showError(title: String, error: Error) {
        NSAlert.runWarning(title: title, text: error.localizedDescription)
    }
}

/// Merkt sich asynchron festgestellte leere Ordner (Etappe 1 Wunschpaket
/// 2026-07: Ordner ohne sichtbaren Inhalt zeigen kein Aufklapp-Chevron).
///
/// Grundsätze:
/// - Erst Chevron zeigen, dann ggf. entfernen: bis das Ergebnis da ist, gilt
///   der Ordner als aufklappbar. Die Prüfung läuft auf einer Hintergrund-
///   Queue und blockiert auf langsamen Volumes niemals den Main-Thread.
/// - Gleiche Filterregeln wie beim Aufklappen: `FileTree.children` (versteckte
///   Einträge zählen nicht als Inhalt).
/// - Idempotent gegenüber gebündelten FSEvents: Ergebnisse landen als
///   Set-Insert/-Remove; doppelte Proben desselben Pfads werden gebündelt.
@MainActor
final class FolderEmptinessCache: ObservableObject {
    @Published private(set) var emptyFolders: Set<String> = []
    private var inFlight: Set<String> = []
    /// Verzeichnis-Listing, für Tests injizierbar; Default sind die echten
    /// Filterregeln des Dateibaums.
    private let listChildren: @Sendable (URL) -> [FileTreeNode]

    init(listChildren: @escaping @Sendable (URL) -> [FileTreeNode]
            = { FileTree.children(of: $0) }) {
        self.listChildren = listChildren
    }

    func isKnownEmpty(_ url: URL) -> Bool {
        emptyFolders.contains(url.path)
    }

    /// Stößt die Hintergrund-Prüfung für einen Ordner an. Läuft für denselben
    /// Pfad bereits eine Probe, passiert nichts (die laufende liefert das
    /// Ergebnis); nach ihrem Abschluss darf erneut geprüft werden.
    func probe(_ url: URL) {
        let path = url.path
        guard !inFlight.contains(path) else { return }
        inFlight.insert(path)
        let list = listChildren
        DispatchQueue.global(qos: .utility).async {
            let isEmpty = list(url).isEmpty
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight.remove(path)
                if isEmpty {
                    self.emptyFolders.insert(path)
                } else {
                    self.emptyFolders.remove(path)
                }
            }
        }
    }
}
