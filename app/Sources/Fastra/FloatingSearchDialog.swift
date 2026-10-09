import SwiftUI
import AppKit

// Floating Search Dialog (L1) — Variante 1.
//
// Stand v0.5: Grobschnitt-Layout nach Suchmasken-Konzept v1.0.
// Sichtbare Bausteine (statisch — Logik kommt in v0.6/v0.7):
//   • Scope-Tabs
//   • Vorlagen-Dropdown (Pattern aus BuiltInPatterns auswählen)
//   • Find-Feld mit Token-Highlighting + Element-Picker-Button [+]
//   • Such-Optionen-Toggle-Zeile (RegEx · Groß-Klein · Ganzes Wort · Wrap-around)
//     — alle deutsch, alle mit Tooltip
//   • Replace-Feld
//   • Gruppen-Tray (nur wenn RegEx an)
//   • Trefferliste in der Maske (Sofort-Treffer — Konzept Abschnitt 2)
//   • Detail-Bereich für aktiven Treffer mit Group-Markierungen
//     (Konzept Abschnitt 3 — Capture-Group-Definition am Treffer)
//   • Action-Zeile (Preview · Alle ersetzen)
//
// Die Logik (echte Suche, Token-Parsing, Group-Snap) folgt in späteren v0.x.

struct FloatingSearchDialog: View {
    @EnvironmentObject var workspace: Workspace
    @Environment(\.uiScale) private var uiScale

    /// Steuert das Element-Picker-Popover am `[+]`-Button.
    @State private var showElementPicker = false

    /// Live-Tokenisierung des Find-Patterns (tree-sitter-regex, v0.7) —
    /// Grundlage für Inline-Highlighting im Find-Feld, die Gruppen-Pills
    /// und die Token-Snap-Logik. `nil` bei RegEx=aus oder leerem Pattern.
    /// Patterns sind kurz → tokenize ist <1 ms, kein Debounce nötig.
    @State private var findTokenization: RegexTokenization? = nil

    /// Nutzer-Selektion im Treffer-Detail (UTF-16-Range im Match-Text).
    /// Daraus baut „Gruppe definieren" via GroupBuilder die Capture Group.
    @State private var detailSelection = NSRange(location: 0, length: 0)

    /// Steuer-Handles für Caret-genaues Einfügen: Element-Picker →
    /// Find-Feld, Pill-Klick → Replace-Feld. (@State hält die Instanzen
    /// über Re-Render hinweg stabil; die Klassen selbst sind leichtgewichtig.)
    @State private var findFieldController = RegexFieldController()
    @State private var replaceFieldController = RegexFieldController()
    @State private var showProjectFileSetEditor = false
    @State private var showExtractionDialog = false
    // Dieselbe Defaults-Suite wie der Workspace: Im Normalbetrieb `.standard`,
    // im Selbsttest die isolierte Suite — sonst schrieben Selbsttests eigene
    // Vorlagen in die echte Bibliothek des Nutzers.
    @StateObject private var patternLibrary = PatternLibrary(defaults: SelfTest.workspaceDefaults())
    @State private var showPatternEditor = false
    @State private var showExampleTransformation = false
    /// Tastaturfokus der Trefferliste. Solange er aktiv ist, bleiben Return
    /// und Pfeiltasten im Suchfenster und können das Dokument nicht ändern.
    @FocusState private var hitListFocused: Bool
    /// Zähler statt Bool: Jeder Klick auf eine Treffer-Zeile zählt hoch und
    /// löst über `.onChange` das Zentrieren der Liste aus — auch wenn derselbe
    /// Treffer erneut angeklickt wird (Etappe 2 Wunschpaket 2026-07b).
    @State private var matchTapScrollToken = 0

    var body: some View {
        // Maske ist seit v0.5 in einem eigenen NSWindow — kein eigener
        // Card-Hintergrund, kein interner Header (Fenster-Titel weg via
        // `titleVisibility = .hidden`, Schließen geht über die roten
        // Punkte der Titelleiste oder den Abbrechen-Button unten).
        VStack(alignment: .leading, spacing: 12 * uiScale) {
            scopeRow

            // Wachsender Ordner-Block — nur bei Scope „Ordner" sichtbar,
            // animiert. Konzept-Frage 1 (Daniel, 2026-05-26): „Maske
            // wächst dynamisch statt zwei separate Fenster".
            if workspace.scope.isFolderLike {
                Group {
                    if workspace.scope == .project {
                        projectSourcesSection
                    } else {
                        folderSourcesSection
                    }
                }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider().opacity(0.4)

            // Kompaktes Formular (Layout-Umbau 2026-09-15): Die Vorlage sitzt
            // am Ende der Suchen-Zeile, die Gruppen-/Platzhalter-Pillen am
            // Ende der Ersetzen-Zeile. Jede eingesparte Zeile geht unten an
            // die Trefferliste — sie ist der einzige Bereich, der mit dem
            // Fenster wächst.
            findRow
            optionsRow
            replaceRow

            // Wildcard-Überzahl-Hinweis (Review-Befund 2026-06-23, Daniel-Entscheid:
            // dezenter Hinweis statt Block): Wenn im Platzhalter-Modus das Ersetzen-
            // Feld MEHR `*` enthält als das Suchen-Feld, haben die überzähligen
            // Sterne keine Capture-Gruppe und werden zu leerem Text. Transparent
            // machen (App-Linie „keine stille Trunkierung").
            if let warn = wildcardReplaceWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(warn)
                        .fastraFont(size: 11)
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                )
            }

            // Inline Live-Vorschau Vorher→Nachher direkt unter den Feldern
            // (Feature J, todo 3) — leer, wenn nicht anwendbar.
            livePreviewStrip

            Divider().opacity(0.4)

            hitsSection

            Divider().opacity(0.4)

            detailSection

            Divider().opacity(0.4)

            actionRow
        }
        .padding(16 * uiScale)
        // 520 pt: Die WIRKSAME Mindestbreite des Fensters kommt von hier, nicht
        // aus `SearchPanelController.minWidth` — NSHostingController schreibt
        // die SwiftUI-Mindestgröße in `contentMinSize`. Bei 500 pt fehlten der
        // Projekt-Zeile „Datei-Set … Dateitypen …" wenige Punkte, und sie
        // brach in zwei Zeilen (Sichtprüfung 2026-09-15).
        .frame(minWidth: 520 * uiScale, maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.surfaceRaised.ignoresSafeArea())
        .animation(.easeOut(duration: 0.22), value: workspace.scope)
        .animation(.easeOut(duration: 0.18), value: workspace.useRegex)
        // Tokenisierung live nachziehen — beim Öffnen und bei jeder
        // Änderung von Pattern oder RegEx-Schalter.
        .onAppear {
            retokenize()
            focusFindField()
        }
        // Fokus ins Suchfeld bei jedem Öffnen und Nach-vorn-Holen (Befund
        // 2026-09-15): Das Fenster wird beim Schließen nur ausgeblendet
        // (`orderOut`), und AppKit vergibt beim Wiederanzeigen den Fokus an
        // das erste Feld der Tab-Reihenfolge — im Projekt-Bereich ist das
        // „Ausschlüsse", nicht „Suchen". Deshalb ausdrücklich setzen.
        .onChange(of: workspace.showSearchDialog) { _, visible in
            if visible { focusFindField() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastraShowSearchFile)) { note in
            if notificationTargetsThisWorkspace(note) { focusFindField() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastraShowSearchFolder)) { note in
            if notificationTargetsThisWorkspace(note) { focusFindField() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastraShowSearchFolderForced)) { note in
            if notificationTargetsThisWorkspace(note) { focusFindField() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastraBringSearchToFront)) { note in
            if notificationTargetsThisWorkspace(note) { focusFindField() }
        }
        .onChange(of: workspace.findPattern) { retokenize() }
        .onChange(of: workspace.useRegex) { retokenize() }
        // Testhaken für den Geometrie-Selbsttest `dialoglayout`: Die Blätter
        // hängen an privatem @State und sind von außen sonst nicht erreichbar.
        .onReceive(NotificationCenter.default.publisher(for: .fastraSelfTestSearchSheet)) { note in
            guard notificationTargetsThisWorkspace(note),
                  let sheet = note.userInfo?["sheet"] as? String else { return }
            showExtractionDialog = sheet == "extraction"
            showPatternEditor = sheet == "patterns"
            showExampleTransformation = sheet == "example"
            showProjectFileSetEditor = sheet == "fileset"
        }
        .sheet(isPresented: $showProjectFileSetEditor) {
            ProjectFileSetEditor { name, paths in
                var config = workspace.projectSearchConfiguration
                let set = ProjectFileSet(name: name, paths: paths)
                config.fileSets.append(set)
                config.activeSetID = set.id
                workspace.projectSearchConfiguration = config
            }
        }
        .sheet(isPresented: $showExtractionDialog) {
            ExtractionDialog(defaultUseReplacement: !workspace.replacePattern.isEmpty) { options in
                _ = workspace.extractHits(options: options)
            }
        }
        .sheet(isPresented: $showPatternEditor) {
            PatternEditorView(library: patternLibrary, onApply: applyTemplate)
        }
        .sheet(isPresented: $showExampleTransformation) {
            ExampleTransformationView { inference in
                // Die Ableitung nutzt absichtlich den bestehenden Platzhalter-
                // Modus. So gelten dieselben Capture- und Preview-Regeln wie
                // bei manuell eingegebenem `*`.
                workspace.useRegex = false
                workspace.treatWildcardLiterally = false
                workspace.findPattern = inference.findPattern
                workspace.replacePattern = inference.replacePattern
            }
        }
    }

    /// Macht das Suchfeld zum First Responder. Läuft asynchron, weil beim
    /// Öffnen das Fenster erst nach dem aktuellen Durchlauf Key wird; bis zu
    /// zehn kurze Versuche, falls AppKit den Fokus noch einmal umsetzt.
    private func focusFindField(attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.05)) {
            guard let field = findFieldController.textView,
                  let window = field.window else {
                if attempt < 10 { focusFindField(attempt: attempt + 1) }
                return
            }
            if window.firstResponder !== field {
                window.makeFirstResponder(field)
            }
            if window.firstResponder !== field, attempt < 10 {
                focusFindField(attempt: attempt + 1)
            }
        }
    }

    /// Tokenisiert das Find-Pattern neu (oder setzt `nil` bei RegEx=aus).
    private func retokenize() {
        findTokenization = (workspace.useRegex && !workspace.findPattern.isEmpty)
            ? RegexTokenizer.tokenize(workspace.findPattern)
            : nil
    }

    /// Spiegelt `SearchOptions.usesWildcard` für die Maske (Single Source of
    /// Truth): Plain-Modus, Mini-Schalter „∗ wörtlich" aus, mindestens ein `*`
    /// im Suchausdruck. Steuert die Platzhalter-Pillen-Zeile — das Plain-
    /// Pendant zum `groupsRow` des RegEx-Modus.
    private var usesWildcard: Bool {
        workspace.currentSearchOptions.usesWildcard
    }

    /// Anzahl der Platzhalter-Sterne im Suchausdruck = Anzahl der Pillen. Über
    /// `WildcardPattern.compileFind` als SSoT (zählt UTF-16-genau, dieselbe
    /// Wahrheit wie die Such-Engine), statt das `*` hier separat zu zählen.
    private var wildcardStarCount: Int {
        WildcardPattern.compileFind(workspace.findPattern).starCount
    }

    // MARK: - Suchbereich-Zeile (Datei / Geöffnet / Ordner)

    private var scopeRow: some View {
        // Drei Umbruchstufen (Befunde 2026-09-15): (1) alles in einer Zeile;
        // (2) Datei-Set und Dateitypen in einer eigenen Zeile, deren
        // Beschriftung „Datei-Set" in der linken Beschriftungsspalte steht;
        // (3) Datei-Set und Dateitypen je in einer eigenen beschrifteten
        // Zeile. Die Projekt-Elemente hängen beim Umbruch also nicht
        // eingerückt unter den Tabs — die Spalte links wäre sonst leer.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                scopeLabel
                scopeTabs
                if workspace.scope == .project {
                    fileSetControls(labelWidth: nil)
                    fileTypeControls(labelWidth: nil)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { scopeLabel; scopeTabs; Spacer(minLength: 0) }
                if workspace.scope == .project {
                    ViewThatFits(in: .horizontal) {
                        // Enger Abstand (6): Bei Mindestbreite entscheiden
                        // wenige Punkte, ob die Zeile einzeilig bleibt.
                        HStack(spacing: 6) {
                            fileSetControls(labelWidth: 80 * uiScale)
                            fileTypeControls(labelWidth: nil)
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) { fileSetControls(labelWidth: 80 * uiScale); Spacer(minLength: 0) }
                            HStack(spacing: 8) { fileTypeControls(labelWidth: 80 * uiScale); Spacer(minLength: 0) }
                        }
                    }
                }
            }
        }
    }

    private var scopeLabel: some View {
        Text("Suchbereich")
            .fastraFont(.small)
            .foregroundColor(Theme.textSecondary)
            .frame(width: 80 * uiScale, alignment: .leading)
    }

    /// Die Bereichs-Tabs. Beschriftungen sind `fixedSize`, damit sie nie
    /// umbrechen; der Umbruch passiert nur zwischen Tabs und Projekt-Elementen.
    private var scopeTabs: some View {
            HStack(spacing: 4) {
                // `.open` („Geöffnet") ist noch NICHT wirklich implementiert:
                // die Such-Engine durchsucht in diesem Scope faktisch nur den
                // aktiven Tab, nicht alle geöffneten Tabs (siehe SearchRunner /
                // runBufferSearch). Deshalb blenden wir den Button aus, bis die
                // echte Mehr-Tab-Suche existiert — sonst verspräche das UI etwas,
                // das die App nicht tut. Der Enum-Fall bleibt bestehen (Engine-
                // Verhalten + Tests unverändert), nur die Auswahl ist gefiltert.
                ForEach(Workspace.SearchScope.allCases) { s in
                    Button {
                        workspace.scope = s
                    } label: {
                        // Kein Zahlen-Badge mehr: war ein hartcodierter
                        // Prototyp-Überrest (8/51/51, an nichts gekoppelt) und
                        // wurde regelmäßig mit der Treffer-Zahl verwechselt
                        // (Daniel-Befund 2026-06-22). Die echte Treffer-Zahl
                        // steht unten bei „Treffer (N)". Die Scope-Auswahl bleibt
                        // über die Sand-Füllung markiert.
                        Text(verbatim: L10n.string(s.rawValue))
                            .fastraFont(.small)
                            .fixedSize()
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(SelfTestMarker(id: "scopeTab-\(s.rawValue)"))
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(workspace.scope == s ? Theme.surfaceSand : Color.clear)
                            )
                            .foregroundColor(workspace.scope == s ? Theme.textPrimary : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    // Kein Tastatur-Fokusring auf den Scope-Buttons: der erste
                    // Button bekäme beim Öffnen den Fokus und zeigte einen
                    // amber Ring (App-Tint = Gold) um „Datei" — irreführend, da
                    // der gewählte Scope bereits über die Sand-Füllung markiert
                    // ist (Daniel-Befund 2026-06-13). Auswahl ≠ Fokus.
                    .focusEffectDisabled()
                    .disabled(s == .project && workspace.projectURL == nil)
                    .help(tooltip(for: s))
                }
            }
    }

    /// Datei-Set-Picker mit Anlegen/Löschen. Die Pfade des aktiven Sets
    /// stehen als Tooltip am Picker — die frühere eigene „Pfade"-Zeile zeigte
    /// nur Text ohne Bedienmöglichkeit. `labelWidth`: feste Breite der
    /// Beschriftung, wenn sie in der linken Spalte des Formulars steht.
    private func fileSetControls(labelWidth: CGFloat?) -> some View {
        HStack(spacing: 8) {
            formLabel("Datei-Set", width: labelWidth)
            Picker("", selection: Binding(
                get: { workspace.projectSearchConfiguration.activeSetID },
                set: { workspace.projectSearchConfiguration.activeSetID = $0 }
            )) {
                ForEach(workspace.projectSearchConfiguration.fileSets) { set in
                    // Gekürzt, weil der Picker unten `.fixedSize()` trägt und
                    // ein langer Name sonst die Projektzeile sprengt; der
                    // volle Name des aktiven Sets steht im Tooltip.
                    Text(verbatim: MenuLabelFit.shortened(
                        L10n.string(set.name), maxCharacters: MenuLabelFit.fileSetLabelCharacters
                    )).tag(set.id)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            // fixedSize statt maxWidth: Ein Picker ohne Mindestbreite wird
            // von SwiftUI bei Platzmangel auf null gedrückt (Befund 2026-09-15).
            .fixedSize()
            // Der volle Name steht mit im Tooltip: Zwei Sets, die sich nur in
            // der gekürzten Mitte unterscheiden, sähen in der Liste sonst
            // gleich aus (Review-Fund 2026-09-17).
            .help(L10n.format("Datei-Set „%@“ — Pfade: %@",
                              L10n.string(workspace.projectSearchConfiguration.activeSet?.name ?? "—"),
                              workspace.projectSearchConfiguration.activeSet?.paths.joined(separator: ", ") ?? "—"))
            Button { showProjectFileSetEditor = true } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
            .help("Gespeichertes Datei-Set anlegen")
            Button { removeActiveProjectFileSet() } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .disabled(workspace.projectSearchConfiguration.fileSets.count <= 1)
            .help("Aktives Datei-Set löschen")
        }
    }

    private func fileTypeControls(labelWidth: CGFloat?) -> some View {
        HStack(spacing: 8) {
            formLabel("Dateitypen", width: labelWidth)
            Picker("", selection: Binding(
                get: { workspace.projectSearchConfiguration.fileTypeFilter },
                set: { workspace.projectSearchConfiguration.fileTypeFilter = $0 }
            )) {
                ForEach(FileTypeFilter.allCases) { filter in
                    Text(verbatim: L10n.string(filter.rawValue)).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }

    /// Beschriftung eines Formularelements: mit `width` in der linken
    /// Spalte (wie „Suchen", „Optionen"), ohne `width` als Inline-Text.
    private func formLabel(_ key: LocalizedStringKey, width: CGFloat?) -> some View {
        Text(key)
            .fastraFont(.small)
            .foregroundColor(Theme.textSecondary)
            .fixedSize()
            .frame(width: width, alignment: .leading)
    }

    private func tooltip(for scope: Workspace.SearchScope) -> String {
        switch scope {
        case .file:   return L10n.string("Nur in der aktuell sichtbaren Datei suchen.")
        case .open:   return L10n.string("In allen geöffneten Tabs suchen.")
        case .folder: return L10n.string("In einem oder mehreren Ordnern suchen — Ordner werden weiter unten ausgewählt.")
        case .project: return L10n.string("Im aktiven Projekt suchen — mit gespeichertem Datei-Set, Filter und Ausschlüssen.")
        }
    }

    // MARK: - Ordner-Quellen (sichtbar nur bei Scope „Ordner")
    //
    // Stub für die Recent-Folders-Liste + Dateityp-Filter. Persistenz
    // und „Auswählen…"-Dialog folgen in v0.6, sobald die echte Folder-
    // Suche kommt.

    private var folderSourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Ordner")
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 80 * uiScale, alignment: .leading)
                Text("Zuletzt verwendete Ordner (Auswahl zum Durchsuchen ankreuzen):")
                    .fastraFont(size: 11)
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }

            // Gleiche Fehlerklasse wie die entfernte „GEÖFFNET"-Liste
            // (Befund 2026-09-01): Diese Liste wächst mit jedem hinzugefügten
            // Ordner unbegrenzt und würde den fest bemessenen Suchdialog
            // irgendwann sprengen. Ab acht Einträgen scrollt sie deshalb in
            // fester Höhe; darunter bleibt sie wie bisher kompakt ohne
            // Leerraum (eine ScrollView beansprucht ihre Maximalhöhe auch
            // bei wenigen Zeilen).
            Group {
                if workspace.recentSearchFolders.count > 7 {
                    ScrollView(.vertical) {
                        // Lazy: Nur sichtbare Zeilen werden gebaut — die
                        // Liste ist unbegrenzt (Review 2026-09-02).
                        LazyVStack(spacing: 2) { folderEntryRows }
                    }
                    .frame(height: 168 * uiScale)
                } else {
                    VStack(spacing: 2) { folderEntryRows }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.surfaceSand.opacity(0.5))
            )

            HStack(spacing: 8) {
                Spacer().frame(width: 80 * uiScale)
                Button("Ordner hinzufügen…") {
                    workspace.addSearchFolders()
                }
                .controlSize(.small)
                .help("Einen oder mehrere Ordner zur Liste hinzufügen.")

                Picker("Dateitypen", selection: $workspace.fileTypeFilter) {
                    ForEach(FileTypeFilter.allCases) { f in
                        Text(verbatim: L10n.string(f.rawValue)).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .help("„Bekannte Textformate\" ignoriert Binärdateien automatisch. „Alle Dateien\" sucht überall — Binärdateien werden trotzdem übersprungen, kein Crash.")

                Spacer()
            }
        }
    }

    /// Die eigentlichen Ordnerzeilen der „Zuletzt verwendete Ordner"-Liste —
    /// ausgelagert, damit die kurze (VStack) und die scrollende Fassung
    /// (LazyVStack) dieselben Zeilen verwenden.
    private var folderEntryRows: some View {
        // Einmal pro Darstellung ein Index Pfad → Häkchen, statt in jedem
        // Toggle-Getter das ganze Array zu durchsuchen (n² Vergleiche bei
        // n Einträgen, Review 2026-09-02).
        let enabledByPath = SearchFolderEntry.enabledByPath(workspace.recentSearchFolders)
        return ForEach(workspace.recentSearchFolders) { entry in
            HStack(spacing: 6) {
                Toggle("", isOn: Binding(
                    get: { enabledByPath[entry.path] ?? entry.enabled },
                    set: { enabled in
                        workspace.setSearchFolderEnabled(path: entry.path,
                                                         enabled: enabled)
                    }
                ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                Text(entry.path)
                    .fastraFont(size: 11, design: .monospaced)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    workspace.removeSearchFolder(path: entry.path)
                } label: {
                    Image(systemName: "minus.circle")
                        .fastraFont(size: 11)
                        .foregroundColor(Theme.textSecondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Diesen Ordner aus der Liste entfernen.")
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    /// Nur noch die Ausschlüsse-Zeile: Datei-Set und Dateitypen stehen in
    /// der Suchbereich-Zeile (`fileSetControls`/`fileTypeControls`). Die frühere
    /// „Pfade"-Anzeige und der Hinweis „DerivedData wird immer
    /// ausgeschlossen" sind entfallen — die Pfade zeigt der Picker-Tooltip,
    /// DerivedData steht ohnehin im Ausschlussfeld (Layout-Umbau 2026-09-15).
    private var projectSourcesSection: some View {
        HStack(spacing: 8) {
            Text("Ausschlüsse")
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 80 * uiScale, alignment: .leading)
            TextField("z.B. .git, build, *.generated.swift",
                      text: Binding(
                        get: { workspace.projectSearchConfiguration.excludePatternsText },
                        set: { workspace.projectSearchConfiguration.excludePatternsText = $0 }
                      ))
                .textFieldStyle(.roundedBorder)
                .fastraFont(.small)
                .accessibilityIdentifier("fastra.projectExclusions")
                .help("Ordner oder Muster, die die Projektsuche überspringt. DerivedData wird bei Projektsuchen immer ausgeschlossen.")
        }
    }

    private func removeActiveProjectFileSet() {
        var config = workspace.projectSearchConfiguration
        guard config.fileSets.count > 1,
              let index = config.fileSets.firstIndex(where: { $0.id == config.activeSetID })
        else { return }
        config.fileSets.remove(at: index)
        config.activeSetID = config.fileSets[0].id
        workspace.projectSearchConfiguration = config
    }

    // MARK: - Vorlagen-Dropdown

    /// Vorlagen-Picker am Ende der Suchen-Zeile (seit dem Layout-Umbau
    /// 2026-09-15 ohne eigene Zeile). Auswahl füllt das Find-Feld und ggf.
    /// das Replace-Feld bei `defaultReplacement`.
    private var templateMenu: some View {
        HStack(spacing: 4) {
            // Vorlage-Dropdown ist **immer** aktiv. Alle Vorlagen sind
            // RegEx-Patterns — beim Auswählen wird der RegEx-Schalter
            // automatisch eingeschaltet (sonst wirken die Patterns nicht).
            Menu {
                Button("— Keine —") {
                    workspace.selectedTemplateID = nil
                }
                Divider()
                ForEach(PatternCategory.allCases, id: \.self) { category in
                    Section(L10n.string(category.rawValue)) {
                        ForEach(BuiltInPatterns.patterns(in: category)) { template in
                            Button(L10n.string(template.name)) {
                                applyTemplate(template)
                            }
                        }
                    }
                }
                if !patternLibrary.templates.isEmpty {
                    Divider()
                    Section("Eigene Vorlagen") {
                        ForEach(patternLibrary.templates) { template in
                            Button(template.name) { applyTemplate(template) }
                        }
                    }
                }
                Divider()
                Button("Vorlagen verwalten…") { showPatternEditor = true }
            } label: {
                HStack(spacing: 5) {
                    Text(currentTemplateLabel)
                        .fastraFont(.small)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .fastraFont(size: 9, weight: .semibold)
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.surfaceSand)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Theme.stroke, lineWidth: 1)
                        )
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Fertige Such-Patterns einsetzen — z.B. E-Mail, ISO-Datum, Dateipfad. Auswahl füllt das Suchen-Feld komplett.")
            Button { showPatternEditor = true } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Eigene Vorlagen speichern sowie importieren oder exportieren")
        }
    }

    /// Beschriftung des Vorlagenmenüs. Eigene Vorlagen dürfen beliebig lange
    /// Namen tragen; das Menü steht aber mit `.fixedSize()` in der Suchen-
    /// Zeile und würde das Suchen-Feld sonst zusammenschieben. Deshalb auf
    /// eine feste Zeichenzahl mittig gekürzt (Review-Fund 2026-09-16).
    private var currentTemplateLabel: String {
        guard
            let id = workspace.selectedTemplateID,
            let template = (BuiltInPatterns.all + patternLibrary.templates).first(where: { $0.id == id })
        else { return L10n.string("Vorlage") }
        return MenuLabelFit.shortened(L10n.string(template.name),
                                      maxCharacters: MenuLabelFit.templateLabelCharacters)
    }

    /// Vorlage anwenden: Find-Pattern setzen, ggf. Replace-Vorschlag
    /// übernehmen, RegEx-Schalter aktivieren. Im Grobschnitt einfach;
    /// echte Capture-Group-Erkennung folgt in v0.7.
    private func applyTemplate(_ template: PatternTemplate) {
        workspace.selectedTemplateID = template.id
        workspace.findPattern = template.regex
        if let replace = template.defaultReplacement {
            workspace.replacePattern = replace
        }
        // Vorlagen sind RegEx-Patterns → RegEx-Modus zwingend an.
        workspace.useRegex = true
    }

    // MARK: - Find-Feld mit Element-Picker-Button

    private var findRow: some View {
        HStack(spacing: 8) {
            Text("Suchen")
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 80 * uiScale, alignment: .leading)

            // Editierbares Feld MIT Inline-Token-Highlighting (v0.7):
            // NSTextView-basiert (RegexFieldView), Farben pro Token-Typ
            // aus der tree-sitter-Tokenisierung. Bei RegEx=aus keine
            // Färbung (tokenization == nil). Return = Weitersuchen bzw.
            // im Ordner-Scope Suche erzwingen (gleiches Verhalten wie
            // die Buttons in der Action-Zeile).
            RegexFieldView(
                text: $workspace.findPattern,
                tokenization: findTokenization,
                placeholder: L10n.string("Suchausdruck…"),
                controller: findFieldController,
                onSubmit: {
                    if workspace.scope.isFolderLike {
                        workspace.runFolderSearchNow()
                    } else if !workspace.navMatches.isEmpty {
                        // Return im Suchfeld beginnt bewusst beim ersten
                        // Treffer. Danach gehört der Tastaturfokus der Liste,
                        // nicht dem im Hintergrund sichtbaren Dokumenteditor.
                        postNavigation(.fastraGotoFirstMatch)
                        requestHitListFocusAfterSubmit()
                    } else {
                        NSSound.beep()
                    }
                },
                accessibilityID: "fastra.findField"
            )
            // Mindestbreite: Vorlagenmenü und Knöpfe rechts sind `fixedSize`;
            // ohne Untergrenze bekäme das Feld bei Platzmangel null Breite.
            .frame(minWidth: 120 * uiScale, maxWidth: .infinity)
            .frame(height: 24 * uiScale)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.surfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            // accentReadable statt accent: Goldgelb (~1,4:1) war
                            // als Stroke auf weißem Grund kaum sichtbar; Bernstein
                            // (#A07800) erreicht ~4,0:1 auf Weiß.
                            .stroke(workspace.useRegex ? Theme.accentReadable.opacity(0.8) : Theme.stroke,
                                    lineWidth: 1.5)
                    )
            )

            // Element-Picker [+]: öffnet ein Popover mit RegEx-Bausteinen,
            // kategorisiert (Anker / Zeichenklassen / Quantifizierer /
            // Gruppen). Auswahl hängt den Token ans Find-Pattern an.
            // Im Klartext-Modus bleibt der Knopf bedienbar und schaltet den
            // RegEx-Modus beim Öffnen automatisch ein (wie die
            // RegEx-Vorlagen; dokumentiertes Verhalten seit dem
            // Klartext-Default in v1.113.0): Ein eingefügtes RegEx-Element
            // ergibt nur im RegEx-Modus das versprochene Verhalten.
            Button {
                if !workspace.useRegex { workspace.useRegex = true }
                showElementPicker = true
            } label: {
                Image(systemName: "plus.circle")
                    .fastraFont(size: 14, weight: .regular)
                    // Dunkelgrau statt Gelb — gelb auf weiß war zu undeutlich.
                    .foregroundColor(Theme.textPrimary)
            }
            .buttonStyle(.plain)
            .help("RegEx-Element einfügen — Zeichenklassen, Quantifizierer, Anker, Gruppen. Schaltet den RegEx-Modus automatisch ein.")
            .popover(isPresented: $showElementPicker, arrowEdge: .bottom) {
                ElementPickerView { element in
                    // Caret-genau ins Find-Feld einfügen (seit v0.7 über
                    // den RegexFieldController). Hat das Feld keinen
                    // Fokus, hängt insertAtCaret ans Ende an.
                    findFieldController.insertAtCaret(element.insert)
                }
            }

            // Such-Verlauf (K4): Uhr-Popup mit den letzten Find-/Replace-
            // Paaren. Auswahl füllt beide Felder (BBEdit „Search History").
            searchHistoryMenu

            // Vorlagen-Picker (Layout-Umbau 2026-09-15: statt eigener Zeile).
            templateMenu
        }
    }

    /// Übergibt Return und Pfeiltasten nach dem ersten Suchfeld-Return an die
    /// Trefferliste. Ein einzelnes `@FocusState = true` kann vor dem nächsten
    /// SwiftUI-Layout verpuffen; das Suchfeld bleibt dann First Responder und
    /// ein schnelles zweites Return springt erneut zum ersten Treffer. Solange
    /// AppKit das Suchfeld noch als First Responder meldet, setzt der nächste
    /// Main-Loop-Durchlauf den Fokuswunsch deshalb erneut.
    private func requestHitListFocusAfterSubmit(attempt: Int = 0) {
        hitListFocused = true
        guard attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let findField = findFieldController.textView,
                  findField.window?.firstResponder === findField else { return }
            // Ein unveränderter `true`-Wert löst keinen neuen Fokuslauf aus.
            // Das kurze Zurücksetzen macht den nächsten Versuch beobachtbar.
            hitListFocused = false
            DispatchQueue.main.async {
                requestHitListFocusAfterSubmit(attempt: attempt + 1)
            }
        }
    }

    /// Uhr-Popup rechts neben dem Element-Picker — listet `searchHistory`.
    private var searchHistoryMenu: some View {
        Menu {
            if workspace.searchHistory.isEmpty {
                Button("(kein Verlauf)") { }.disabled(true)
            } else {
                ForEach(workspace.searchHistory) { entry in
                    Button(Self.historyLabel(entry)) { workspace.applyHistoryEntry(entry) }
                }
                Divider()
                Button("Verlauf löschen") { workspace.clearSearchHistory() }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .fastraFont(size: 14, weight: .regular)
                .foregroundColor(Theme.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Zuletzt verwendete Such- und Ersetz-Paare. Auswahl füllt beide Felder.")
    }

    /// Baut die Menü-Beschriftung eines Verlaufs-Eintrags: Suchbegriff, bei
    /// nicht-leerem Ersetzen „ → Ersetzung". Auf ~48 Zeichen gekürzt, damit
    /// das Menü nicht ausufert.
    static func historyLabel(_ entry: SearchHistoryEntry) -> String {
        let raw = entry.replace.isEmpty ? entry.find : "\(entry.find) → \(entry.replace)"
        let oneLine = raw.replacingOccurrences(of: "\n", with: "⏎")
        return oneLine.count > 48 ? String(oneLine.prefix(47)) + "…" : oneLine
    }

    // MARK: - Such-Optionen-Toggle-Zeile (BBEdit-Stil)
    //
    // Seit dem Layout-Umbau 2026-09-15 EINE Zeile: Alle Schalter stehen
    // nebeneinander, solange die Fensterbreite reicht. Erst wenn sie nicht
    // mehr passen, rückt der zweite Block („Nur in Auswahl", „∗ wörtlich")
    // in eine zweite Zeile unter RegEx. `ViewThatFits` entscheidet das
    // anhand der tatsächlichen Breite — kein festes Umbruchmaß.

    private var optionsRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("Optionen")
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 80 * uiScale, alignment: .leading)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    primaryOptionToggles
                    secondaryOptionToggles
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) { primaryOptionToggles }
                    HStack(spacing: 14) { secondaryOptionToggles }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Die vier Grundschalter. Alle Toggles mit fixedSize, damit ihre Labels
    /// nie auf mehrere Zeilen umbrechen — der Umbruch passiert nur zwischen
    /// den Blöcken (`ViewThatFits`).
    @ViewBuilder
    private var primaryOptionToggles: some View {
        Toggle("RegEx", isOn: $workspace.useRegex)
            .toggleStyle(.checkbox)
            .fastraFont(.small)
            .fixedSize(horizontal: true, vertical: false)
            .help("Suchausdruck als regulären Ausdruck behandeln. Aus = wörtliche Suche; Sonderzeichen wie . oder ? werden buchstäblich gesucht.")
            .background(alignment: .leading) {
                SelfTestMarker(id: "searchOptionFirst")
                    .frame(width: 0, height: 0)
            }

        // „Groß = klein" ist die Kompaktform. Achtung: Semantik ist
        // gegenüber `caseSensitive` invertiert (Toggle AN heißt:
        // groß und klein als gleich behandeln, also case-insensitiv).
        Toggle("Groß = klein", isOn: Binding(
            get: { !workspace.caseSensitive },
            set: { workspace.caseSensitive = !$0 }
        ))
            .toggleStyle(.checkbox)
            .fastraFont(.small)
            .fixedSize(horizontal: true, vertical: false)
            .help("Groß- und Kleinschreibung gleich behandeln. Aus = unterscheiden; „Max\" findet dann nicht „max\". Standard: an.")

        Toggle("Ganzes Wort", isOn: $workspace.wholeWord)
            .toggleStyle(.checkbox)
            .fastraFont(.small)
            .fixedSize(horizontal: true, vertical: false)
            .help("Findet nur vollständige Wörter. „Test\" findet „Test\", aber nicht „Tester\" oder „Kontest\".")

        Toggle("Wrap-around", isOn: $workspace.wrapAround)
            .toggleStyle(.checkbox)
            .fastraFont(.small)
            .fixedSize(horizontal: true, vertical: false)
            .help("Nach dem letzten Treffer geht die Suche oben wieder von vorn los. Aus = die Suche hält am Dateiende an.")
    }

    /// Die kontextnahen Schalter: „Nur in Auswahl" (nur im Datei-Bereich)
    /// und „∗ wörtlich".
    @ViewBuilder
    private var secondaryOptionToggles: some View {
        // „Nur in Auswahl" (K3, BBEdit „Selected Text Only") — nur im
        // Datei-Scope sinnvoll.
        if workspace.scope == .file {
            Toggle("Nur in Auswahl", isOn: Binding(
                get: { workspace.searchInSelectionOnly },
                set: { workspace.setSearchInSelectionOnly($0) }
            ))
                .toggleStyle(.checkbox)
                .fastraFont(.small)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(workspace.selectionRange == nil && !workspace.searchInSelectionOnly)
                .help("Suchen und Ersetzen nur innerhalb des aktuell im Editor markierten Texts. Aktivierbar, sobald etwas selektiert ist; die Auswahl wird beim Einschalten eingefroren.")
                .background(alignment: .leading) {
                    SelfTestMarker(id: "searchOptionSecond")
                        .frame(width: 0, height: 0)
                }
        }

        Toggle("∗ wörtlich", isOn: $workspace.treatWildcardLiterally)
            .toggleStyle(.checkbox)
            .fastraFont(.small)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!workspace.wildcardLiteralOptionIsEnabled)
            .help("Den Stern ∗ als gewöhnliches Zeichen suchen statt als Platzhalter für beliebigen Text innerhalb einer Zeile (∗∗ fängt auch über Zeilenumbrüche). Der Schalter ist nur aktiv, wenn RegEx aus ist und der Suchausdruck mindestens einen Stern ∗ enthält; andernfalls ist er ausgeschaltet.")
            .background(SelfTestMarker(
                id: "wildcardLiteralOption-"
                    + (workspace.wildcardLiteralOptionIsEnabled ? "enabled" : "disabled")
                    + (workspace.treatWildcardLiterally ? "-on" : "-off")
            ).frame(width: 0, height: 0))
    }

    // MARK: - Replace-Feld

    /// Hinweistext, wenn im Platzhalter-Modus das Ersetzen-Feld MEHR `*` enthält
    /// als das Suchen-Feld. Die überzähligen Sterne haben keine Capture-Gruppe
    /// (`compileReplace` macht aus dem N-ten `*` ein `$N`, aber `compileFind`
    /// erzeugt nur so viele Gruppen wie Sterne im Suchen) → sie werden zu leerem
    /// Text. `nil` = kein Hinweis. Spiegelt `SearchOptions.usesWildcard`.
    private var wildcardReplaceWarning: String? {
        guard !workspace.useRegex,
              !workspace.treatWildcardLiterally,
              WildcardPattern.containsWildcard(workspace.findPattern) else { return nil }
        // Lauf-Zählung, nicht Roh-Zählung: `**` ist EIN Platzhalter (eine
        // mehrzeilige Gruppe bzw. ein Verweis), siehe WildcardPattern #6.
        let findStars = WildcardPattern.starRunCount(workspace.findPattern)
        let replaceStars = WildcardPattern.starRunCount(workspace.replacePattern)
        guard replaceStars > findStars else { return nil }
        let extra = replaceStars - findStars
        return extra == 1
            ? L10n.string("Ersetzen hat ein ∗ mehr als Suchen — das überzählige ∗ bleibt leer.")
            : L10n.format("Ersetzen hat %ld ∗ mehr als Suchen — die überzähligen bleiben leer.", extra)
    }

    private var replaceRow: some View {
        HStack(spacing: 8) {
            Text("Ersetzen")
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 80 * uiScale, alignment: .leading)
            // Seit v0.7 ebenfalls NSTextView-basiert (RegexFieldView):
            // nimmt Drops der Gruppen-Pills nativ an der Maus-Position an
            // und erlaubt Caret-genaues Einfügen per Pill-Klick (über den
            // replaceFieldController). Keine Tokenisierung — das Replace-
            // Template ist kein RegEx. (Die frühere Dark-Mode-Textfarben-
            // Falle betrifft die Komponente nicht: sie setzt ihre
            // Ink-Textfarbe explizit in sRGB.)
            RegexFieldView(
                text: $workspace.replacePattern,
                tokenization: nil,
                placeholder: L10n.string("Ersetzen durch… ($1, $2 für Gruppen)"),
                controller: replaceFieldController,
                accessibilityID: "fastra.replaceField"
            )
            // Mindestbreite gegen die Pillenreihe rechts (siehe `PillTray`).
            .frame(minWidth: 120 * uiScale, maxWidth: .infinity)
            .frame(height: 24 * uiScale)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.surfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Theme.stroke, lineWidth: 1)
                    )
            )

            // Swap-Button (K9, BBEdit „Swap"): vertauscht Suchen- und
            // Ersetzen-Feld. Sitzt am Ende der Ersetzen-Zeile, dort wo bei
            // der Suchen-Zeile der Element-Picker steht (symmetrisch).
            Button {
                workspace.swapFindReplace()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .fastraFont(size: 13, weight: .regular)
                    .foregroundColor(Theme.textPrimary)
            }
            .buttonStyle(.plain)
            .help("Suchen und Ersetzen vertauschen")

            // Gruppen- bzw. Platzhalter-Pillen direkt am Ersetzen-Feld
            // (Layout-Umbau 2026-09-15: statt eigener Zeile). Klick oder
            // Drag fügt `$N` ins Feld ein.
            if workspace.useRegex {
                groupsRow
            } else if usesWildcard {
                // Plain-Modus-Pendant zum Gruppen-Tray: nummerierte Pillen
                // pro `*` (Feature J, todo 1+2).
                wildcardGroupsRow
            }
        }
    }

    // MARK: - Gruppen-Tray (nur bei RegEx=an)

    /// Pills LIVE aus der Tokenisierung (v0.7) — eine pro fangender Gruppe
    /// im Find-Pattern. Drag ins Replace-Feld ODER Klick fügt dort `$N` ein
    /// (Low-Friction-Leitplanke: beides geht). Ohne Gruppen bleibt die Stelle
    /// leer; wie Gruppen entstehen, erklärt der Tooltip von „Gruppe
    /// definieren" im Detailbereich.
    @ViewBuilder
    private var groupsRow: some View {
        if let groups = findTokenization?.groups, !groups.isEmpty {
            PillTray(maxWidth: PillTrayLayout.maxWidth * uiScale) {
                HStack(spacing: 6) {
                    ForEach(groups, id: \.number) { group in
                        GroupPill(group: group,
                                  patternText: workspace.findPattern) {
                            replaceFieldController.insertAtCaret("$\(group.number)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Platzhalter-Tray (nur bei RegEx=aus + aktivem `*`)
    //
    // Das Plain-Modus-Pendant zum Gruppen-Tray (Feature J): jeder `*` im
    // Suchausdruck ist eine gierige Fanggruppe und bekommt eine nummerierte
    // Pille `$1`, `$2`, … — dieselbe Low-Friction-Mechanik wie die Capture-
    // Group-Pillen (Drag aufs Ersetzen-Feld ODER Klick fügt dort `$N` ein).
    // Sichtbar nur, wenn `usesWildcard` true ist (Plain + Schalter aus + `*`
    // vorhanden) → `wildcardStarCount` ist dann ≥ 1.
    private var wildcardGroupsRow: some View {
        PillTray(maxWidth: PillTrayLayout.maxWidth * uiScale) {
            // Eine Pille pro Stern. `max(1, …)` ist nur eine defensive Klammer:
            // die Zeile rendert ohnehin nur bei `usesWildcard` (≥ 1 Stern), aber
            // falls sich das Muster zwischen Bedingung und Body-Aufbau ändert,
            // bleibt `1...n` gültig (ForEach-Range darf nicht leer/absteigend sein).
            //
            // BEWUSST nur die Pillen, kein erklärender Fließtext — exakt wie das
            // `groupsRow`-Pendant im RegEx-Modus (Konsistenz + „chirurgisch").
            // Die Bedeutung tragen der Pillen-Tooltip und der Ersetzen-Feld-
            // Platzhalter („$1, $2 für Gruppen").
            HStack(spacing: 6) {
                ForEach(1...max(1, wildcardStarCount), id: \.self) { n in
                    WildcardPill(number: n) {
                        replaceFieldController.insertAtCaret("$\(n)")
                    }
                }
            }
        }
    }

    // MARK: - Inline Live-Vorschau Vorher→Nachher (Feature J, todo 3)

    /// Zeilen-Obergrenze der INLINE-Vorschau. Bewusst klein — das große
    /// „Vorschau der Änderungen"-Sheet zeigt alle Zeilen; hier geht es nur um
    /// Sofort-Feedback beim Tippen.
    private var livePreviewMaxRows: Int { 3 }

    /// Kompakte, LIVE mittippende Vorher→Nachher-Vorschau direkt unter den
    /// Feldern. Reuse der getesteten `ReplacePreview.build`-Logik (gleiche
    /// Quelle wie das große Sheet) — hier nur die ersten Zeilen als Sofort-
    /// Feedback (Produktprinzip „Vorschau ist das Produkt"). Nur in den Buffer-
    /// Scopes (Datei/Geöffnet — der Ordner-Scope hat keinen einzelnen aktiven
    /// Buffer), nur wenn ein Ersetzen-Text getippt ist UND es Treffer gibt;
    /// sonst leer → im Normalfall kein Layout-Sprung. Die Quelle bindet Treffer
    /// an die aktuellen Suchoptionen und im „Geöffnet"-Scope an den aktiven Tab;
    /// der alte Debounce-Stand darf dadurch nie als neue Vorschau erscheinen.
    @ViewBuilder
    private var livePreviewStrip: some View {
        if !workspace.scope.isFolderLike,
           !workspace.replacePattern.isEmpty,
           let source = SearchEmphasis.currentSource(
               scope: workspace.scope,
               activeTab: workspace.activeTab,
               bufferMatches: workspace.bufferMatches,
               bufferTotalMatches: workspace.bufferTotalMatches,
               folderResults: workspace.folderResults,
               openResults: workspace.openResults,
               visibleBufferResultsOptions: workspace.visibleBufferResultsOptions,
               currentOptions: workspace.currentSearchOptions
           ),
           !source.matches.isEmpty {
            let preview = ReplacePreview.build(text: workspace.activeTab?.content ?? "",
                                               matches: source.matches,
                                               maxRows: livePreviewMaxRows)
            // Treffer, deren Ersetzung == Original (z.B. Suchen == Ersetzen),
            // liefern keine Zeilen → dann zeigen wir nichts.
            if !preview.rows.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("VORSCHAU")
                        .fastraFont(size: 10, weight: .semibold)
                        .tracking(0.8)
                        .foregroundColor(Theme.textSecondary)
                    ForEach(preview.rows) { row in
                        LivePreviewRow(row: row)
                    }
                    // Ehrlich über die Begrenzung (App-Linie „keine stille
                    // Trunkierung"): auf das vollständige Sheet verweisen.
                    if preview.totalChangedLines > preview.rows.count {
                        Text(verbatim: L10n.format(
                            "… und %ld weitere geänderte Zeilen — „Vorschau der Änderungen\" zeigt alle.",
                            preview.totalChangedLines - preview.rows.count
                        ))
                            .fastraFont(size: 10)
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.surfaceSand.opacity(0.5))
                )
            }
        }
    }

    // MARK: - Trefferliste in der Maske (Sofort-Treffer)

    private var hitsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: L10n.format("Treffer (%ld)", scopeTotalMatches))
                    .fastraFont(.small)
                    .foregroundColor(Theme.textPrimary)
                // Spinner, solange im Hintergrund gesucht wird — Folder- ODER
                // Buffer-Scope (beide laufen async). „Suche noch läuft"-Signal,
                // damit der ehrliche Count nicht als „fertig" missverstanden wird.
                if workspace.folderSearching || workspace.bufferSearching {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                }
                Spacer()
                hitNavigator
            }

            // Fehler-Streifen unter dem Header, wenn das Pattern kaputt
            // ist. Erfüllt Interview-Erkenntnis 5 (Fehler erklären, nicht
            // nur markieren). Verschwindet, sobald das Pattern wieder
            // gültig ist.
            if let msg = workspace.searchError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(msg)
                        .fastraFont(size: 11)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.red.opacity(0.08))
                )
            }

            if let notice = workspace.folderNavigationNotice {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundColor(.orange)
                    Text(notice)
                        .fastraFont(size: 11)
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                )
            }

            // Cap-Hinweis: Trefferliste wurde durch den Gesamt-Cap abgeschnitten.
            // Erscheint NUR im Ordner-Scope und NUR wenn der Cap tatsächlich
            // ausgelöst hat — stilles Abschneiden ist schlechter UX.
            // Stil analog zum Fehler-Streifen, aber Gelb/Orange statt Rot,
            // da es kein Fehler ist, sondern ein informativer Hinweis.
            if (workspace.scope.isFolderLike && workspace.folderResultsWereCapped)
                || (workspace.scope == .open && workspace.openResultsWereCapped) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(verbatim: L10n.string(workspace.scope.isFolderLike
                         ? "Trefferliste auf 10.000 gekappt — Suchbegriff verfeinern."
                         : "Trefferliste gekappt — „Alle ersetzen“ bleibt gesperrt, bis alle Treffer sichtbar sind."))
                        .fastraFont(size: 11)
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                )
            }

            // Im Geöffnet-Scope bleibt die Vorschau vollständig sichtbar,
            // auch wenn ein Treffer aus einer schreibgeschützten Git-Ansicht
            // stammt. Da Apply diesen Treffer nicht ändern könnte, sperrt die
            // Maske die gesamte Aktion und erklärt die Sicherheitsgrenze.
            if workspace.scope == .open && workspace.openResultsContainReadOnlyTabs {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.orange)
                    Text("Treffer in schreibgeschützten Tabs — „Alle ersetzen“ bleibt gesperrt.")
                        .fastraFont(size: 11)
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                )
            }

            // Cap-Hinweis im Buffer-Scope: nur die ersten N von vielen Treffern
            // sind als Liste materialisiert. Der Header zeigt die echte
            // Gesamtzahl; hier steht ehrlich, wie viele davon gelistet sind.
            // „Alle ersetzen" bleibt bis zu einer vollständigen sichtbaren
            // Trefferbasis gesperrt (Produktinvariante Vorschau vor Apply).
            if !workspace.scope.isFolderLike && workspace.bufferResultsWereCapped {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(verbatim: bufferCapHint)
                        .fastraFont(size: 11)
                        .foregroundColor(.orange)
                        .lineLimit(3)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                )
            }

            // Trefferliste über SwiftUI `List` (NSTableView-backed) =
            // VIRTUALISIERT: rendert nur die SICHTBAREN Zeilen, nicht alle bis
            // zu 2000 Treffer. Das war der Performance-Killer (Daniel-Befund
            // 2026-06-22): der frühere nicht-lazy VStack baute bei JEDEM Render
            // alle Zeilen neu auf — und weil der geteilte Workspace den offenen
            // Dialog bei jeder Cursor-Bewegung mit-rendert, blockierte das den
            // Main-Thread → Beachball beim Treffer-Klick, träges CMD+W, träge
            // Klicks im Hauptfenster. `List` aktualisiert sichtbare Zeilen
            // zuverlässig bei Zustandswechsel (die `isActive`-Markierung stimmt
            // — anders als bei LazyVStack, das genau daran scheiterte — und es
            // gibt keinen AttributeGraph-Crash bei vielen Treffern).
            Group {
                if scopeTotalMatches == 0 && workspace.searchError == nil
                    && !workspace.folderSearching && !workspace.bufferSearching {
                    // Leerer Zustand: nur der Hinweis (kein List-Chrome), volle
                    // Breite/Höhe, damit die dunkle Box gefüllt wirkt.
                    Text(emptyHint)
                        .background(SelfTestMarker(id: "searchEmptyHint-\(emptyHint)"))
                        .fastraFont(size: 11)
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollViewReader { proxy in
                        List {
                            ForEach(groupedHits) { group in
                                Section {
                                    ForEach(group.matches) { match in
                                        HitRow(match: match,
                                               isActive: activeMatch?.id == match.id) {
                                            handleMatchTap(matchID: match.id)
                                        }
                                        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                        // Ziel-Anker für scrollTo (Etappe 2
                                        // Wunschpaket 2026-07b).
                                        .id(match.id)
                                    }
                                } header: {
                                    Text(verbatim: L10n.format("%@ (%ld)", group.label,
                                                              group.matches.count))
                                        .fastraFont(size: 11, weight: .semibold)
                                        .foregroundColor(Theme.textSecondary)
                                }
                            }
                        }
                        .listStyle(.plain)
                        // List-Eigenhintergrund ausblenden, damit die Sand-Box
                        // darunter sichtbar bleibt (macOS 13+).
                        .scrollContentBackground(.hidden)
                        .environment(\.defaultMinListRowHeight, 20)
                        // Die Liste folgt dem aktiven Treffer bei NAVIGATION
                        // (Return, Pfeile, Voriger/Nächster, Klick). Beim
                        // bloßen Neu-Suchen (Muster getippt) springt sie
                        // bewusst nicht (Etappe 2 Wunschpaket 2026-07b).
                        .onReceive(NotificationCenter.default.publisher(
                            for: .fastraGotoFirstMatch)) { note in
                            guard notificationTargetsThisWorkspace(note) else { return }
                            scrollToActiveMatch(proxy)
                        }
                        .onReceive(NotificationCenter.default.publisher(
                            for: .fastraGotoNextMatch)) { note in
                            guard notificationTargetsThisWorkspace(note) else { return }
                            scrollToActiveMatch(proxy)
                        }
                        .onReceive(NotificationCenter.default.publisher(
                            for: .fastraGotoPreviousMatch)) { note in
                            guard notificationTargetsThisWorkspace(note) else { return }
                            scrollToActiveMatch(proxy)
                        }
                        // Klick auf eine Zeile (handleMatchTap zählt den Token
                        // hoch): auch dann zentriert die Liste den Treffer.
                        .onChange(of: matchTapScrollToken) {
                            scrollToActiveMatch(proxy)
                        }
                    }
                }
            }
            // Flexibel — wächst mit dem Fenster. `maxWidth: .infinity`: die Box
            // füllt immer die volle Maskenbreite, egal wie kurz der Inhalt ist.
            .frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
            .background(SelfTestMarker(id: "hitList"))
            // Die Liste ist ein eigener Tastaturbereich: Pfeil hoch/runter
            // navigiert, Return geht zum nächsten Treffer. Der Editor bleibt
            // dabei nur Scroll-/Selektionsziel und erhält keine Eingaben.
            .focusable()
            .focused($hitListFocused)
            .onMoveCommand { direction in
                switch direction {
                case .up:
                    postNavigation(.fastraGotoPreviousMatch)
                case .down:
                    postNavigation(.fastraGotoNextMatch)
                default:
                    break
                }
            }
            // Zusätzlich zu `onMoveCommand`: Der Listenfokus landet in AppKit
            // auf der NSOutlineView der `List`, und die verarbeitet
            // Pfeiltasten selbst, ohne den Move-Command des Containers zu
            // erreichen — die Pfeilnavigation war damit wirkungslos, verdeckt
            // vom fensterweiten Return-Shortcut des „Nächster"-Buttons
            // (Review 2026-08-31, navmatch-Selbsttest). `onKeyPress` greift
            // in der SwiftUI-Ereigniskette vor der AppKit-Zustellung.
            .onKeyPress(.downArrow) {
                postNavigation(.fastraGotoNextMatch)
                return .handled
            }
            .onKeyPress(.upArrow) {
                postNavigation(.fastraGotoPreviousMatch)
                return .handled
            }
            .onKeyPress(.return) {
                postNavigation(.fastraGotoNextMatch)
                return .handled
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.surfaceSand.opacity(0.5))
            )
        }
    }

    /// Das vollständige Navigationsziel des aktuell aktiven Treffers. Anders
    /// als der nackte `BufferSearch.Match` trägt es im „Geöffnet"-Scope die
    /// Ziel-Tab-ID und im Ordner-Scope die Datei-URL. Detailtext, Dateiname und
    /// Sprung beziehen sich dadurch garantiert auf denselben Treffer.
    private var activeNavMatch: Workspace.NavMatch? {
        let matches = workspace.navMatches
        let transition = SearchMatchSelection.transition(
            activeIndex: workspace.activeMatchIndex,
            matches: matches,
            action: .reconcile
        )
        return SearchMatchSelection.target(for: transition.state, in: matches)
    }

    /// Der aktuell „aktive" Treffer (für Detail-Bereich + List-Highlight).
    /// `nil`, wenn keine Treffer da sind. Die Auswahl des passenden Indexes
    /// geschieht zentral in `activeNavMatch`, damit Metadaten und Text niemals
    /// aus verschiedenen Tabs stammen.
    private var activeMatch: BufferSearch.Match? {
        activeNavMatch?.match
    }

    /// Treffer-Gruppe für die Anzeige in der Maske. `url` ist nur im
    /// Folder-Scope gesetzt — die Maske braucht sie, um beim Klick die
    /// passende Datei zu öffnen.
    private struct HitGroup: Identifiable {
        // Stabile Identität über Renders hinweg. Vorher `UUID()` pro Erzeugung
        // → `groupedHits` lieferte bei jedem Render „neue" Gruppen, ForEach/List
        // bauten alles neu auf und die List-Virtualisierung lief ins Leere.
        // Datei-/Geöffnet-Scope: genau eine Gruppe ("buffer"); Ordner-Scope:
        // eine Gruppe je Datei (Pfad ist eindeutig).
        // Geöffnet-Scope: mehrere Gruppen ohne URL → Tab-ID als Identität.
        var id: String { url?.path ?? tabID?.uuidString ?? "buffer" }
        let label: String
        let url: URL?
        var tabID: UUID? = nil
        let matches: [BufferSearch.Match]
    }

    /// Treffer gruppiert nach Datei. Im Datei-Scope eine Gruppe (= aktiver
    /// Tab); im Folder-Scope eine Gruppe pro Datei mit Treffern.
    private var groupedHits: [HitGroup] {
        if workspace.scope.isFolderLike {
            return workspace.folderResults
                .filter { !$0.matches.isEmpty }
                .map { HitGroup(label: $0.url.lastPathComponent,
                                url: $0.url,
                                matches: $0.matches) }
        }
        if workspace.scope == .open {
            // Eine Gruppe pro offenem Tab mit Treffern (BBEdit-Results-
            // Browser-Analogon; Klick aktiviert den Tab statt zu laden).
            return workspace.openResults
                .filter { !$0.matches.isEmpty }
                .map { HitGroup(label: $0.title, url: nil,
                                tabID: $0.id, matches: $0.matches) }
        }
        guard !workspace.bufferMatches.isEmpty else { return [] }
        let title = workspace.activeTab?.title ?? L10n.string("Aktiver Buffer")
        return [HitGroup(label: title, url: nil, matches: workspace.bufferMatches)]
    }

    /// Summe aller Treffer im aktuellen Scope.
    private var scopeTotalMatches: Int {
        // Echte Gesamtzahl (kann > materialisierte Liste sein, wenn der
        // Cap griff) — ehrlicher Count wie BBEdits Statuszeile.
        switch workspace.scope {
        case .folder, .project: return workspace.folderTotalMatches
        case .open:   return workspace.openTotalMatches
        case .file:   return workspace.bufferTotalMatches
        }
    }

    /// Cap-Hinweis im Buffer-Scope. Im Datei-Scope hängt zusätzlich der
    /// Emphasis-Hinweis an (Etappe 2 Wunschpaket 2026-07b): Die Live-
    /// Markierung im Editor zeichnet höchstens die materialisierten Treffer —
    /// kein stilles Abschneiden (Leitplanke), der Nutzer liest hier, dass nur
    /// die ersten N markiert sind.
    private var bufferCapHint: String {
        var text = L10n.format(
            "Erste %ld von %ld Treffern gelistet — Suchbegriff verfeinern. „Alle ersetzen“ bleibt gesperrt, bis alle Treffer sichtbar sind.",
            workspace.bufferMatches.count, workspace.bufferTotalMatches
        )
        if workspace.scope == .file {
            text += " " + L10n.format(
                "Im Editor sind nur diese ersten %ld Treffer markiert.",
                workspace.bufferMatches.count
            )
        }
        return text
    }

    /// Hinweistext bei leerer Trefferliste, scope-spezifisch formuliert.
    private var emptyHint: String {
        if workspace.findPattern.isEmpty { return L10n.string("Suchausdruck eingeben…") }
        if workspace.scope.isFolderLike {
            if workspace.activeMultiFileSearchURLs.isEmpty {
                return workspace.scope == .project
                    ? L10n.string("Das aktive Datei-Set enthält keine vorhandenen Pfade.")
                    : L10n.string("Kein Ordner ausgewählt. Mindestens einen aktivieren.")
            }
            if workspace.folderResultsAreStale {
                return L10n.string("Die Dateien wurden geändert. Erneut suchen, um aktuelle Treffer zu sehen.")
            }
            // Unter der Live-Mindestlänge sucht der Ordner-Scope nicht
            // automatisch (Freeze-Schutz bei kurzen Pattern, siehe
            // SearchRunner.shouldRunFolderLive) — Hinweis statt „Keine Treffer.".
            if workspace.folderNeedsSearch && !SearchRunner.shouldRunFolderLive(for: workspace.findPattern) {
                return L10n.format("Mindestens %ld Zeichen für die Live-Ordner-Suche — oder „Suchen“ klicken.", SearchRunner.minFolderLiveChars)
            }
            // Ab Mindestlänge wird live gesucht; ist noch nichts da (z.B.
            // direkt nach Scope-Wechsel, vor dem Debounce), explizit anstoßen.
            if workspace.folderNeedsSearch {
                return L10n.string("„Suchen“ klicken oder Return drücken, um die Ordner zu durchsuchen.")
            }
        }
        // Ordner-Scope, Suche abgeschlossen, 0 Treffer: informativer Hinweis
        // statt generischem „Keine Treffer.", damit klar ist, dass tatsächlich
        // Dateien durchsucht wurden und nicht nur noch kein Suchlauf lief.
        if workspace.scope.isFolderLike
            && !workspace.folderNeedsSearch
            && !workspace.folderSearching {
            return L10n.string("Keine Treffer in den durchsuchten Ordnern.")
        }
        return L10n.string("Keine Treffer.")
    }

    /// Click-Handler für eine Treffer-Zeile. Auswahl und Zielauflösung laufen
    /// über `SearchMatchSelection`; dadurch kann eine inzwischen ersetzte
    /// List-Zeile weder einen alten Index noch ein altes Sprungziel verwenden.
    private func handleMatchTap(matchID: UUID) {
        // Nach einem Klick gehören weitere Pfeil-/Return-Eingaben ebenfalls
        // der Trefferliste, nicht dem Dokumenteditor.
        hitListFocused = true
        let matches = workspace.navMatches
        let transition = SearchMatchSelection.transition(
            activeIndex: workspace.activeMatchIndex,
            matches: matches,
            action: .select(matchID: matchID)
        )
        guard case .activate(let target) = transition.output else { return }
        guard target.url == nil || target.fileSnapshot != nil else { return }

        let previousIndex = workspace.activeMatchIndex
        let nextIndex = transition.state.index
        // Dieser Klick entwertet alle älteren, noch verzögerten Sprünge.
        let jumpGeneration = workspace.beginMatchJump()
        func commitIndexIfPosted(_ posted: Bool) {
            guard let index = MatchJumpCommit.index(
                previous: previousIndex, current: workspace.activeMatchIndex,
                next: nextIndex, posted: posted
            ) else { return }
            workspace.activeMatchIndex = index
            // Erst ein wirklich ausgeführter Sprung zentriert die Liste.
            matchTapScrollToken &+= 1
        }

        if let tabID = target.tabID {
            // Ziel-Tab und Sprung warten gemeinsam auf letzte WebKit-Eingaben.
            guard let documentID = workspace.tabs.first(where: { $0.id == tabID })?.documentID
            else { return }
            // Ziel synchron vormerken: Ein direkt folgendes ⌘G rechnet vom
            // geklickten Treffer weiter, nicht vom noch nicht bestätigten
            // alten Index (Review 2026-08-31, wie navigateMatch).
            workspace.noteMatchNavigationTarget(index: nextIndex,
                                                generation: jumpGeneration)
            workspace.navigateToMatch(target.match, tabID: tabID,
                                      requiring: .document(documentID),
                                      generation: jumpGeneration) { posted in
                defer {
                    workspace.resolveMatchNavigationTarget(generation: jumpGeneration)
                }
                commitIndexIfPosted(posted)
            }
            return
        }
        if let url = target.url, let snapshot = target.fileSnapshot {
            // Tab öffnen oder aktivieren — asynchron. Editor-Sprung erst in
            // der Completion, nachdem der Tab vollständig geladen ist
            // (Race vermieden: postMatchJump braucht den fertigen Inhalt).
            workspace.noteMatchNavigationTarget(index: nextIndex,
                                                generation: jumpGeneration)
            workspace.loadFolderMatchFile(
                atCanonicalURL: url,
                expectedDiskSnapshot: snapshot,
                jumpGeneration: jumpGeneration
            ) { outcome in
                guard outcome.isOpened else {
                    workspace.resolveMatchNavigationTarget(generation: jumpGeneration)
                    // Nur ein echter Plattenstand-Konflikt entwertet die
                    // Trefferbasis; laufende Ladevorgänge und ungesicherte
                    // Tabs werden getrennt behandelt (Review 2026-08-31).
                    workspace.handleFolderMatchLoadDenial(outcome,
                                                          jumpGeneration: jumpGeneration)
                    return
                }
                DispatchQueue.main.async {
                    workspace.navigateToMatch(target.match,
                                              requiring: .file(url: url, snapshot: snapshot),
                                              generation: jumpGeneration) { posted in
                        defer {
                            workspace.resolveMatchNavigationTarget(generation: jumpGeneration)
                        }
                        commitIndexIfPosted(posted)
                        if !posted, workspace.isCurrentMatchJump(jumpGeneration) {
                            workspace.folderMatchNavigationBecameStale()
                        }
                    }
                }
            }
            return
        }
        workspace.noteMatchNavigationTarget(index: nextIndex, generation: jumpGeneration)
        workspace.navigateToMatch(target.match,
                                  requiring: workspace.activeDocumentID.map(MatchJumpTarget.document),
                                  generation: jumpGeneration) { posted in
            workspace.resolveMatchNavigationTarget(generation: jumpGeneration)
            commitIndexIfPosted(posted)
        }
    }

    /// Zentriert die Trefferliste auf den aktiven Treffer — einen Tick
    /// später, denn die Navigations-Notification wird auch von ContentView
    /// verarbeitet (dort wird `activeMatchIndex` erst weitergeschaltet).
    private func scrollToActiveMatch(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            guard let id = activeMatch?.id else { return }
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
    }

    /// Schnelles Kopieren, konfigurierbares Extrahieren und die Anzeige
    /// „2 / 9" für die Detail-Navigation.
    private var hitNavigator: some View {
        HStack(spacing: 10) {
            // Textbutton statt Icon — das Feature ist zu praktisch, um
            // hinter einem kleinen Symbol zu verstecken (Daniel, 2026-05-26).
            Button("Treffer kopieren") {
                workspace.copyHitsToClipboard()
            }
            .controlSize(.small)
            .disabled(workspace.navMatches.isEmpty)
            .help("Alle gefundenen Treffer schnell als LF-getrennte Liste in die Zwischenablage kopieren.")

            // BBEdit „Extract" (Handbuch S. 168/193): Treffer in ein neues
            // Dokument statt ins Clipboard — mit gefülltem Ersetzen-Feld
            // transformiert ($1/\U/Pillen), sonst roh.
            Button("Treffer extrahieren") {
                showExtractionDialog = true
            }
            .controlSize(.small)
            .disabled(workspace.navMatches.isEmpty)
            .help("Extrahieren mit Trennzeichen, Ziel, Quoting, Duplikatfilter und optionaler Ersetzung konfigurieren.")

            Divider().frame(height: 14)

            HStack(spacing: 4) {
                Button {
                    postNavigation(.fastraGotoPreviousMatch)
                } label: {
                    Image(systemName: "chevron.left")
                        .fastraFont(size: 10, weight: .semibold)
                }
                .buttonStyle(.plain)
                .disabled(workspace.navMatches.isEmpty)
                .help("Vorheriger Treffer (⇧⌘G)")

                Text(workspace.navMatches.isEmpty
                     ? "0 / 0"
                     : "\(workspace.activeMatchIndex + 1) / \(workspace.navMatches.count)")
                    .fastraFont(size: 11, design: .monospaced)
                    .foregroundColor(Theme.textSecondary)

                Button {
                    postNavigation(.fastraGotoNextMatch)
                } label: {
                    Image(systemName: "chevron.right")
                        .fastraFont(size: 10, weight: .semibold)
                }
                .buttonStyle(.plain)
                .disabled(workspace.navMatches.isEmpty)
                .help("Nächster Treffer (⌘G)")
            }
        }
    }

    // MARK: - Detail-Bereich für den aktiven Treffer

    /// Zeigt genau einen Treffer ohne Kontext drumherum (Konzept §3).
    /// Seit v0.7 echt: Der Nutzer markiert im Match-Text eine Teil-
    /// Selektion; „Gruppe definieren" snappt sie auf Token-Grenzen
    /// (GroupBuilder) und setzt die `(...)`-Gruppe im Suchausdruck.
    /// Beiträge BESTEHENDER Gruppen sind farbig hinterlegt (gleiche
    /// Farbreihe wie die Pills).
    private var detailSection: some View {
        let fileLabel = Self.detailFileLabel(for: activeNavMatch,
                                             tabs: workspace.tabs,
                                             fallback: workspace.activeTab?.title ?? L10n.string("Aktiver Buffer"))
        let lineText = activeMatch.map {
            L10n.format("Zeile %ld · Spalte %ld", $0.line, $0.column)
        } ?? L10n.string("kein Treffer")
        // Feste Höhe (Layout-Umbau 2026-09-15): Kopfzeile mit den Gruppen-
        // Knöpfen, darunter genau eine Textzeile. Vorher hatte der Textkasten
        // keine feste Höhe, und SwiftUI gab ihm die Hälfte jeder zusätzlichen
        // Fensterhöhe — die Trefferliste bekam nur die andere Hälfte. Längere
        // oder mehrzeilige Treffer scrollen innerhalb der Zeile.
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(verbatim: L10n.format("Detail · %@ · %@", fileLabel, lineText))
                    .fastraFont(size: 11, weight: .medium)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Gruppe definieren") { defineGroupFromSelection() }
                    .controlSize(.small)
                    .disabled(!workspace.useRegex || activeMatch == nil)
                    .help("Markierten Text-Ausschnitt als Capture Group im Suchausdruck speichern. Die Auswahl snappt automatisch auf ganze RegEx-Bausteine. Gruppen lassen sich auch direkt als (…) im Suchausdruck tippen.")
                Button("Gruppe löschen") { deleteGroupAtSelection() }
                    .controlSize(.small)
                    .disabled(!workspace.useRegex || (findTokenization?.groups.isEmpty ?? true))
                    .help("Die Capture Group im markierten Bereich wieder auflösen — die Klammern verschwinden, der Inhalt bleibt.")
            }

            // Bei aktivem Treffer: selektierbarer Match-Text mit Gruppen-
            // Hinterlegung. Ohne Treffer: dezenter Hinweis — gleiche Höhe und
            // gleiches Padding wie das Textfeld, damit das Layout nicht springt.
            if let match = activeMatch {
                SelectableMatchText(matchText: match.matchText,
                                    groupRanges: detailGroupRanges,
                                    selection: $detailSelection)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: detailTextHeight)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.surfaceSand)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Theme.stroke, lineWidth: 1)
                            )
                    )
            } else {
                Text("Kein Treffer ausgewählt.")
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: detailTextHeight)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.surfaceSand)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Theme.stroke, lineWidth: 1)
                            )
                    )
            }
        }
    }

    /// Höhe der einen Textzeile im Detailkasten (Monospace 13 pt plus
    /// Zeilenabstand), skaliert mit dem UI-Zoom.
    private var detailTextHeight: CGFloat { 18 * uiScale }

    /// Ermittelt den Dateinamen für den Detailkopf aus DEMSELBEN
    /// Navigationsziel wie den angezeigten Treffertext. Diese kleine pure
    /// Funktion ist separat testbar, weil ein falscher Name im „Geöffnet"-
    /// Scope visuell plausibel aussah und deshalb durch reine Suchtests nicht
    /// auffiel.
    static func detailFileLabel(for target: Workspace.NavMatch?,
                                tabs: [EditorTab],
                                fallback: String) -> String {
        if let tabID = target?.tabID,
           let targetTab = tabs.first(where: { $0.id == tabID }) {
            return targetTab.title
        }
        if let fileURL = target?.url {
            return fileURL.lastPathComponent
        }
        return fallback
    }

    /// Formatiert die Zeilennummer in der Trefferliste ohne Präfix.
    ///
    /// Früher stand ein „Z" davor. In der kleinen Monospace-Schrift sah es
    /// leicht wie eine „2" aus und machte Angaben wie „Z12" unnötig schwer
    /// lesbar. Die Spalte ist bereits eindeutig eine Zeilennummern-Spalte;
    /// deshalb genügt die rohe Zahl. `String(line)` vermeidet außerdem die
    /// lokalisierte Tausendertrennung, die SwiftUIs interpolierter `Text`-
    /// Initializer sonst erzeugen kann.
    static func hitLineLabel(_ line: Int) -> String {
        String(line)
    }

    /// Der Status darf nach Abschluss nicht durch einen verspätet zugestellten
    /// Worker-Fortschritt wieder sichtbar werden.
    static func visibleFolderApplyProgress(isApplying: Bool,
                                           text: String?) -> String? {
        guard isApplying else { return nil }
        return text
    }

    /// Beiträge der bestehenden Gruppen im aktiven Match-Text — für die
    /// farbige Hinterlegung im Detail. Re-Match des Patterns gegen den
    /// Match-Text (verankert am Anfang); pro fangender Gruppe die
    /// gelieferte Range.
    private var detailGroupRanges: [(number: Int, range: NSRange)] {
        guard workspace.useRegex,
              let matchText = activeMatch?.matchText,
              let groups = findTokenization?.groups, !groups.isEmpty else { return [] }
        let options = SearchOptions(find: workspace.findPattern,
                                    replace: "",
                                    isRegex: true,
                                    caseSensitive: workspace.caseSensitive,
                                    wholeWord: false)
        guard let regex = try? ApplyEngine.buildRegex(options) else { return [] }
        let ns = matchText as NSString
        guard let match = regex.firstMatch(in: matchText,
                                           options: [.anchored],
                                           range: NSRange(location: 0, length: ns.length))
        else { return [] }
        return groups.compactMap { group in
            guard group.number < match.numberOfRanges else { return nil }
            let r = match.range(at: group.number)
            guard r.location != NSNotFound, r.length > 0 else { return nil }
            return (group.number, r)
        }
    }

    /// „Gruppe definieren": Detail-Selektion → GroupBuilder.propose →
    /// Pattern + Replace-Template aktualisieren. Verweigerung (nil)
    /// oder „ist schon eine Gruppe" → Beep statt stiller Änderung.
    private func defineGroupFromSelection() {
        guard let matchText = activeMatch?.matchText,
              let tokenization = findTokenization,
              let proposal = GroupBuilder.propose(selection: detailSelection,
                                                  pattern: workspace.findPattern,
                                                  tokenization: tokenization,
                                                  matchText: matchText,
                                                  replacement: workspace.replacePattern,
                                                  caseSensitive: workspace.caseSensitive)
        else {
            NSSound.beep()
            return
        }
        guard !proposal.isAlreadyGroup else {
            // Schon eine Gruppe — nichts zu tun, kein Fehler.
            return
        }
        workspace.findPattern = proposal.newPattern
        workspace.replacePattern = proposal.rewrittenReplacement
    }

    /// „Gruppe löschen": Gruppe unter der Detail-Selektion (oder die
    /// letzte, wenn nichts markiert ist) via GroupRemoval auflösen.
    /// GroupRemoval verweigert bei Semantik-Risiko (Quantifier dahinter,
    /// Top-Level-Alternation im Inhalt, $N-Referenz) → Beep.
    private func deleteGroupAtSelection() {
        guard let tokenization = findTokenization,
              let lastGroup = tokenization.groups.last else {
            NSSound.beep()
            return
        }
        // Gruppe wählen: deren Match-Beitrag die Selektion schneidet
        // bzw. den Cursor enthält; sonst die letzte Gruppe.
        let hit = detailGroupRanges.first { entry in
            if detailSelection.length == 0 {
                return entry.range.location <= detailSelection.location
                    && detailSelection.location <= entry.range.location + entry.range.length
            }
            return NSIntersectionRange(entry.range, detailSelection).length > 0
        }
        let number = hit?.number ?? lastGroup.number
        guard let result = GroupRemoval.remove(group: number,
                                               pattern: workspace.findPattern,
                                               tokenization: tokenization,
                                               replacement: workspace.replacePattern)
        else {
            NSSound.beep()
            return
        }
        workspace.findPattern = result.newPattern
        workspace.replacePattern = result.rewrittenReplacement
    }

    // MARK: - Action-Zeile

    /// `true`, wenn die sichtbaren Buffer-/Geöffnet-Treffer wirklich zum
    /// AKTUELL eingegebenen Muster gehören.
    ///
    /// Direkt nach einem Tastendruck stimmt das für rund 120 ms nicht: Die
    /// alte Trefferzahl bleibt absichtlich stehen (sonst blinkte sie bei jedem
    /// Zeichen auf 0), die Ersetzen-Pfade im Workspace lehnen den Aufruf aber
    /// still ab. Ohne diese Bedingung sähen Vorschau, „Ersetzen" und „Alle
    /// ersetzen" in diesem Fenster aktiv aus und täten nichts
    /// (Review 2026-08-06). Im Ordner-/Projekt-Bereich gilt sie nicht — dort
    /// sperren `folderSearching`/`folderNeedsSearch` bereits.
    private var visibleResultsMatchCurrentSearch: Bool {
        workspace.scope.isFolderLike
            || workspace.visibleBufferResultsOptions == workspace.currentSearchOptions
    }

    // Zweizeilig (Daniel-Feedback 2026-06-04): die sechs Buttons passten
    // bei minimaler Fensterbreite nicht sauber in eine Zeile. Aufteilung
    // nach Absicht — Zeile 1 navigiert nur durch die Treffer, Zeile 2
    // schließt die Maske bzw. ersetzt.
    private var actionRow: some View {
        VStack(spacing: 8) {
            if workspace.waitingForShortFolderSearch {
                // Zahl aus derselben Konstante wie der Nachbarhinweis, damit
                // eine geänderte Mindestlänge den Text nicht falsch macht.
                Text(verbatim: L10n.format("Auch 1–%ld Zeichen sind suchbar: „Suchen“ klicken oder Return drücken.",
                                           SearchRunner.minFolderLiveChars - 1))
                    .background(SelfTestMarker(id: "shortFolderSearchPrompt"))
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Eine Knopfzeile (Layout-Umbau 2026-09-15): links das Suchen-
            // Cluster, rechts das Ersetzen-Cluster. Reicht die Breite nicht,
            // teilt `ViewThatFits` die Zeile in zwei, bei Mindestbreite in
            // drei — sonst schnitt SwiftUI „Vorschau der Änderungen" ab. Der
            // frühere Knopf „Abbrechen" ist entfallen — Escape und der rote
            // Punkt schließen die Maske.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    searchCluster
                    Spacer()
                    transformCluster
                    applyCluster
                }
                VStack(spacing: 8) {
                    HStack(spacing: 8) { searchCluster; Spacer() }
                    HStack(spacing: 8) { Spacer(); transformCluster; applyCluster }
                }
                VStack(spacing: 8) {
                    HStack(spacing: 8) { searchCluster; Spacer() }
                    HStack(spacing: 8) { Spacer(); transformCluster }
                    HStack(spacing: 8) { Spacer(); applyCluster }
                }
            }
        }
    }

    /// Reines Navigieren durch die Treffer, OHNE zu ersetzen. Wiederverwendet
    /// die bestehende Sprung-Logik (navigateMatch in ContentView, via
    /// Notification).
    @ViewBuilder
    private var searchCluster: some View {
        Group {
                // „Suchen" nur im Ordner-Scope: ab der Live-Mindestlänge sucht
                // der Ordner zwar automatisch beim Tippen, aber Klick/Return
                // erzwingen die Suche auch bei kürzeren Pattern (umgeht die
                // Schwelle) bzw. lösen sofort aus, ohne aufs Debounce zu warten.
                if workspace.scope.isFolderLike {
                    Button("Suchen") { workspace.runFolderSearchNow() }
                        .background(SelfTestMarker(id: "folderSearchButton"))
                        .keyboardShortcut(.return, modifiers: [])
                        .buttonStyle(.bordered)
                        .tint(workspace.waitingForShortFolderSearch ? Color.accentColor : nil)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(workspace.waitingForShortFolderSearch ? Color.accentColor : .clear, lineWidth: 2))
                        .disabled(workspace.findPattern.isEmpty
                                  || workspace.activeMultiFileSearchURLs.isEmpty)
                        .help(L10n.format("Die ausgewählten Ordner jetzt durchsuchen. Ab %ld Zeichen läuft die Ordner-Suche live beim Tippen mit; Klick oder Return erzwingen sie auch bei kürzeren Suchausdrücken und ohne Wartezeit.", SearchRunner.minFolderLiveChars))
                }

                Button("Voriger") {
                    postNavigation(.fastraGotoPreviousMatch)
                }
                    .disabled(workspace.navMatches.isEmpty)
                    .help("Zum vorherigen Treffer springen — im Dokument an die Fundstelle. Tastenkürzel: ⇧⌘G.")

                Button("Nächster") {
                    postNavigation(.fastraGotoNextMatch)
                }
                    // Return = weitersuchen (BBEdit-Verhalten) — aber nur in
                    // Buffer-Scopes. Im Ordner-Scope gehört Return zu „Suchen"
                    // (zwei Views mit demselben Shortcut wären mehrdeutig).
                    .keyboardShortcut(workspace.scope.isFolderLike
                                      ? nil
                                      : KeyboardShortcut(.return, modifiers: []))
                    .disabled(workspace.navMatches.isEmpty)
                    .help("Zum nächsten Treffer springen — im Dokument an die Fundstelle. Tastenkürzel: ⌘G oder Return.")
        }
    }

    /// Beispiel-Ableitung und Vorschau — Schritte VOR dem Ersetzen.
    @ViewBuilder
    private var transformCluster: some View {
        Group {
                Button("Aus Beispiel…") { showExampleTransformation = true }
                    .help("Leitet aus einem Vorher/Nachher-Beispiel ein Platzhalter-Muster ab.")

                Button("Vorschau der Änderungen") { workspace.livePreview = true }
                    .buttonStyle(.bordered)
                    .disabled(workspace.scope != .file
                              || workspace.bufferMatches.isEmpty
                              || workspace.searchError != nil
                              || !visibleResultsMatchCurrentSearch)
                    .help("Zeigt im Hauptfenster ein Vorher/Nachher-Diff aller Ersetzungen im aktiven Buffer — jede betroffene Zeile vorher und nachher.")
        }
    }

    /// Einzel- und Gesamtersetzung sowie Rückgängig nach einem Ordner-Apply.
    @ViewBuilder
    private var applyCluster: some View {
        Group {
                // Einzel-Ersetzen (ein Treffer + zum nächsten springen). Nur im
                // Buffer-Scope (Datei/Geöffnet) — Ordner-Einzelersetzen schreibt
                // auf die Platte und kommt mit dem Ergebnis-Fenster (Schritt 2).
                Button("Ersetzen") { workspace.replaceActiveMatch() }
                    .disabled(!workspace.canReplaceActiveSearchMatch)
                    .help("Nur den aktiven Treffer ersetzen und zum nächsten springen. Im Ordner-Modus (noch) nicht verfügbar.")

                // Im Folder-Scope und nach einem erfolgreichen Apply gibt es
                // eine Rückgängig-Möglichkeit aus dem Backup-Ordner.
                if workspace.scope.isFolderLike, workspace.lastApplySession != nil {
                    Button("Rückgängig") { workspace.undoLastFolderApply() }
                        .disabled(workspace.folderApplying)
                        .help("Spielt die letzte Ordner-Apply-Session bit-exakt aus dem Backup-Ordner zurück.")
                }

                if workspace.scope.isFolderLike, workspace.folderApplying {
                    ProgressView()
                        .controlSize(.small)
                    if let progress = Self.visibleFolderApplyProgress(
                        isApplying: workspace.folderApplying,
                        text: workspace.folderApplyProgressText
                    ) {
                        Text(verbatim: progress)
                            .fastraFont(size: 10)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("fastra.folderApplyProgress")
                    }
                    Button("Apply abbrechen") { workspace.cancelFolderApply() }
                        .help("Bricht Planung und Preflight ab. Eine bereits begonnene atomare Schreibphase wird sicher abgeschlossen.")
                }

                Button(L10n.format("Alle ersetzen · %ld", scopeTotalMatches)) {
                    switch workspace.scope {
                    case .folder, .project: workspace.applyAllInFolder()
                    case .open:   workspace.applyAllInOpenTabs()
                    case .file:   workspace.applyAllInActiveBuffer()
                    }
                }
                    .keyboardShortcut(.return, modifiers: .command)
                    // Bewusst KEIN .borderedProminent mehr (Etappe 2 Wunschpaket
                    // 2026-07b): Der Return-Button („Nächster" bzw. „Suchen")
                    // trägt bereits den blauen Default-Look — zwei
                    // hervorgehobene Buttons wirkten wie zwei Standardaktionen.
                    .buttonStyle(.bordered)
                    .disabled(scopeTotalMatches == 0 || workspace.searchError != nil
                              || (workspace.scope == .file
                                  && !workspace.canApplyAllInActiveBuffer)
                              || (workspace.scope == .open
                                  && !workspace.canApplyAllInOpenTabs)
                              || (workspace.scope.isFolderLike
                                  && (workspace.folderSearching
                                      || workspace.folderNeedsSearch))
                              || workspace.folderApplying
                              || !visibleResultsMatchCurrentSearch)
                    .help({
                        switch workspace.scope {
                        case .folder, .project:
                            return L10n.string("Alle Treffer in allen aktivierten Ordnern ersetzen — atomar pro Datei, mit automatischem Backup unter ~/Library/Application Support/Fastra/undo/.")
                        case .open:
                            return L10n.string("Alle Treffer in ALLEN geöffneten Tabs ersetzen — nur im Speicher, geänderte Tabs werden als ungesichert markiert. Speichern wie gewohnt mit ⌘S.")
                        case .file:
                            return L10n.string("Alle Treffer im aktiven Buffer durch das Replace-Pattern ersetzen.")
                        }
                    }())
        }
    }

    /// Navigation bleibt an den Workspace dieser Suchmaske gebunden. Das ist
    /// besonders bei zwei offenen Dokumenten wichtig, weil alle Dialoge am
    /// app-weiten NotificationCenter lauschen.
    private func postNavigation(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: workspace)
    }

    private func notificationTargetsThisWorkspace(_ notification: Notification) -> Bool {
        if let target = notification.object as? Workspace {
            return target === workspace
        }
        return Workspace.shared === workspace
    }
}

// MARK: - Hilfs-Views

/// Eine Zeile in der Trefferliste — anklickbar, markiert sich beim Klick.
private struct HitRow: View {
    let match: BufferSearch.Match
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // `verbatim:` ist hier Pflicht: Ein interpolierter Text würde
                // den LocalizedStringKey-Initializer wählen und die Zahl im
                // deutschen Gebietsschema mit Tausenderpunkt formatieren.
                // Das frühere Präfix „Z" entfällt, weil es wie „2" aussah.
                // `lineLimit(1)` + `fixedSize` verhindern den Umbruch bei ≥5-stelligen Zeilen
                // (feste 28 pt waren dafür zu schmal); `minWidth` hält die rechtsbündige Spalte.
                Text(verbatim: FloatingSearchDialog.hitLineLabel(match.line))
                    .fastraFont(size: 10, design: .monospaced)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 28, alignment: .trailing)
                // Treffer deutlich, den folgenden Zeilenrest schwächer:
                // dadurch liefert die Liste Kontext, ohne den Fund selbst zu
                // verwischen. Leerzeichen im Rest bleiben exakt erhalten.
                (Text(verbatim: match.matchText)
                    .foregroundColor(Theme.textPrimary)
                 + Text(verbatim: match.lineRemainder)
                    .foregroundColor(Theme.textSecondary))
                    .fastraFont(.monoSmall)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isActive ? Theme.accent.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(SelfTestMarker(id: "searchHit-\(match.id.uuidString)").allowsHitTesting(false))
    }
}


/// Reihe der Gruppen- bzw. Platzhalter-Pillen neben dem Ersetzen-Feld.
///
/// Die Pillen sind so breit wie ihr Inhalt, aber höchstens `maxWidth`; ab
/// dort scrollt die Reihe seitlich (ohne Balken, per Trackpad). Ohne diese
/// Grenze drückte ein Muster mit vielen Gruppen das Ersetzen-Feld auf
/// Mindestbreite oder schob Pillen aus dem Fenster (Review-Fund 2026-09-16).
/// Die natürliche Breite kommt per PreferenceKey aus dem Inhalt; die
/// ScrollView selbst würde sonst gierig jede angebotene Breite nehmen.
private struct PillTray<Content: View>: View {
    let maxWidth: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content()
                .fixedSize()
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: PillTrayWidthKey.self,
                                           value: geometry.size.width)
                })
        }
        .onPreferenceChange(PillTrayWidthKey.self) { contentWidth = $0 }
        .frame(width: min(contentWidth, maxWidth))
        // Marker in voller Größe der Reihe: Der Selbsttest `searchlayout`
        // misst daran, dass die Reihe ihre Obergrenze einhält.
        .background(SelfTestMarker(id: "pillTray"))
    }
}

/// Obergrenze der Pillenreihe in Punkt bei `uiScale` 1 — reicht für etwa
/// vier Pillen. Eigener Typ, weil ein generischer View keine ohne Typargument
/// erreichbare Konstante haben kann. Bewusst nicht `private`: Der Selbsttest
/// `searchlayout` misst gegen genau diese Zahl, statt sie abzuschreiben
/// (Review-Fund 2026-09-17).
enum PillTrayLayout {
    static let maxWidth: CGFloat = 220
}

private struct PillTrayWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Pille im Gruppen-Tray — seit v0.7 LIVE aus der Tokenisierung.
///
/// Zwei Wege ins Replace-Feld (Low Friction, Konzept B):
///   - DRAG der Pille aufs Replace-Feld: NSTextView nimmt den String
///     (`$N`) nativ an der Maus-Position an.
///   - KLICK auf die Pille: fügt `$N` an der Replace-Caret-Position ein.
private struct GroupPill: View {
    /// Die fangende Gruppe aus der Tokenisierung (Nummer, Name, Ranges).
    let group: CaptureGroupInfo
    /// Das aktuelle Find-Pattern — für das Label (Gruppen-Inhalt).
    let patternText: String
    /// Klick-Aktion: `$N` ins Replace-Feld einfügen.
    let onInsert: () -> Void

    /// Anzeige-Label: Gruppen-Name (bei `(?<name>…)`) oder der
    /// Gruppen-Inhalt aus dem Pattern, auf Pillen-Breite gekürzt.
    private var label: String {
        if let name = group.name, !name.isEmpty { return name }
        let ns = patternText as NSString
        guard group.innerRange.location + group.innerRange.length <= ns.length else {
            return L10n.format("Gruppe %ld", group.number)
        }
        let inner = ns.substring(with: group.innerRange)
        return inner.count > 14 ? String(inner.prefix(13)) + "…" : inner
    }

    private var pillColor: Color {
        // abs(): defensive Klammer gegen negativen Swift-Modulo (Gruppen
        // sind 1-basiert, number 0 sollte nie vorkommen).
        Theme.groupColors[abs(group.number - 1) % Theme.groupColors.count]
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "$\(group.number)")
                .fastraFont(size: 11, weight: .bold, design: .monospaced)
                .foregroundColor(Theme.textPrimary)
            Text(label)
                .fastraFont(size: 11, design: .monospaced)
                .foregroundColor(Theme.textPrimary.opacity(0.8))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(pillColor.opacity(0.35)))
        // groupColors sind für Fill-Tönung gedacht; gelber Stroke auf
        // Weiß war fast unsichtbar (~1,3:1). textSecondary gibt einen
        // neutralen, lesbaren Rahmen ohne Farb-Clash.
        .overlay(Capsule().stroke(Theme.textSecondary.opacity(0.4), lineWidth: 1))
        // Drag-Source: liefert `$N` als Plain-String — das Replace-Feld
        // (NSTextView) nimmt ihn nativ an der Maus-Position an.
        .onDrag { NSItemProvider(object: "$\(group.number)" as NSString) }
        .onTapGesture(perform: onInsert)
        .help(L10n.format("Gruppe %ld ins Ersetzen-Feld übernehmen — Pille dorthin ziehen oder einfach klicken (fügt $%ld ein).", group.number, group.number))
    }
}

/// Pille im Platzhalter-Tray (Feature J) — eine pro `*` im Suchausdruck.
///
/// Wie `GroupPill`, aber ohne Capture-Group-Inhalt: der `*` SELBST ist die
/// (gierige) Fanggruppe, es gibt keinen Klammer-Inhalt zum Anzeigen. Zwei Wege
/// ins Ersetzen-Feld (Low-Friction-Leitplanke, identisch zu GroupPill):
///   - DRAG der Pille aufs Ersetzen-Feld → NSTextView nimmt den String (`$N`)
///     nativ an der Maus-Position an (RegexFieldTextView akzeptiert den Drop
///     auch bei Fokus).
///   - KLICK auf die Pille → `$N` an der Replace-Caret-Position (über onInsert).
private struct WildcardPill: View {
    /// 1-basierte Platzhalter-Nummer: der N-te `*` (von links) → `$N`.
    let number: Int
    /// Klick-Aktion: `$N` ins Ersetzen-Feld einfügen.
    let onInsert: () -> Void

    private var pillColor: Color {
        // Gleiche Farbreihe wie die Capture-Group-Pillen → visuelle Kontinuität;
        // abs(): defensive Klammer gegen negativen Swift-Modulo.
        Theme.groupColors[abs(number - 1) % Theme.groupColors.count]
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "$\(number)")
                .fastraFont(size: 11, weight: .bold, design: .monospaced)
                .foregroundColor(Theme.textPrimary)
            // Der Stern als Inhalts-Hinweis (statt eines Gruppen-Texts) — macht
            // sichtbar, dass diese Pille zum N-ten `*` gehört.
            Text("∗")
                .fastraFont(size: 11, design: .monospaced)
                .foregroundColor(Theme.textPrimary.opacity(0.8))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(pillColor.opacity(0.35)))
        .overlay(Capsule().stroke(Theme.textSecondary.opacity(0.4), lineWidth: 1))
        // Drag-Source: liefert `$N` als Plain-String — das Ersetzen-Feld nimmt
        // ihn nativ an (exakt dieselbe Mechanik wie GroupPill).
        .onDrag { NSItemProvider(object: "$\(number)" as NSString) }
        .onTapGesture(perform: onInsert)
        .help(L10n.format("Platzhalter %ld (der %ld. Stern ∗) ins Ersetzen-Feld übernehmen — Pille dorthin ziehen oder einfach klicken (fügt $%ld ein).", number, number, number))
    }
}

/// Eine kompakte Inline-Vorschau-Zeile (Feature J, todo 3): Zeilennummer ·
/// Vorher (getönt entfernt) → Nachher (getönt hinzugefügt). Schmaler und
/// einzeilig (Truncation in der Mitte) — die ausführliche, mehrzeilige
/// `DiffRow` lebt im großen „Vorschau der Änderungen"-Sheet.
private struct LivePreviewRow: View {
    let row: ReplacePreview.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "\(row.line)")
                .fastraFont(size: 10, design: .monospaced)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 40, alignment: .trailing)
            Text(row.before)
                .fastraFont(.monoSmall)
                .foregroundColor(Theme.diffRemovedFG)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .fastraFont(size: 9)
                .foregroundColor(Theme.textSecondary)
            Text(row.after)
                .fastraFont(.monoSmall)
                .foregroundColor(Theme.diffAddedFG)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Element-Picker-Popover

/// Inhalt des Element-Picker-Popovers: kategorisierte RegEx-Bausteine.
/// Ein Klick ruft `onPick` mit dem gewählten Element auf.
private struct ElementPickerView: View {
    let onPick: (RegexElement) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(RegexElements.categories) { category in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: L10n.string(category.name).uppercased())
                            .fastraFont(size: 10, weight: .semibold)
                            .tracking(0.6)
                            .foregroundColor(Theme.textSecondary)
                            .padding(.bottom, 2)

                        ForEach(category.elements) { element in
                            Button {
                                onPick(element)
                            } label: {
                                HStack(spacing: 10) {
                                    Text(element.symbol)
                                        .fastraFont(size: 12, weight: .semibold, design: .monospaced)
                                        .foregroundColor(Theme.tokenCharClass)
                                        .frame(width: 56, alignment: .leading)
                                    Text(verbatim: L10n.string(element.hint))
                                        .fastraFont(.small)
                                        .foregroundColor(Theme.textPrimary)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 3)
                                .padding(.horizontal, 6)
                            }
                            .buttonStyle(ElementRowButtonStyle())
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 320, height: 380)
        // Opaker Hintergrund — sonst schimmert das halbtransparente
        // Popover-Material durch und die Symbole sind schlecht lesbar.
        .background(Theme.surfaceRaised)
    }
}

/// Dezenter Hover-Hintergrund für eine Picker-Zeile.
private struct ElementRowButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? Theme.surfaceSand : Color.clear)
            )
            .onHover { hovering = $0 }
    }
}

/// Kleiner Editor für ein persistentes Projekt-Datei-Set. Pfade sind bewusst
/// projekt-relativ und komma-/zeilengetrennt, damit ein Set schnell aus einer
/// Handvoll Ordner oder Einzeldateien zusammengestellt werden kann.
private struct ProjectFileSetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var paths = "Sources, Tests"
    let onSave: (String, [String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Projekt-Datei-Set")
                .fastraFont(.headline)
            TextField("Name", text: $name)
            Text("Projekt-relative Dateien oder Ordner, durch Komma oder Zeilenumbruch getrennt:")
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
            TextEditor(text: $paths)
                .fastraFont(.monoSmall)
                .frame(minHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.stroke))
            HStack {
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Sichern") {
                    let parsed = paths
                        .split(whereSeparator: { $0 == "," || $0.isNewline })
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), parsed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || parsedPaths.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
        .background(Theme.surfaceRaised)
    }

    private var parsedPaths: [String] {
        paths.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct ExtractionDialog: View {
    @Environment(\.dismiss) private var dismiss
    @State private var options: HitExtraction.Options
    let onExtract: (HitExtraction.Options) -> Void

    init(defaultUseReplacement: Bool,
         onExtract: @escaping (HitExtraction.Options) -> Void) {
        var initial = HitExtraction.Options()
        initial.useReplacement = defaultUseReplacement
        _options = State(initialValue: initial)
        self.onExtract = onExtract
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Treffer extrahieren")
                .fastraFont(.headline)
            Form {
                Picker("Trennzeichen", selection: $options.separator) {
                    ForEach(HitExtraction.Separator.allCases) { separator in
                        Text(verbatim: L10n.string(separator.rawValue)).tag(separator)
                    }
                }
                if options.separator == .custom {
                    TextField("Eigenes Trennzeichen", text: $options.customSeparator)
                }
                Picker("Ziel", selection: $options.destination) {
                    ForEach(HitExtraction.Destination.allCases) { destination in
                        Text(verbatim: L10n.string(destination.rawValue)).tag(destination)
                    }
                }
                Picker("Quoting", selection: $options.quoting) {
                    ForEach(HitExtraction.Quoting.allCases) { quoting in
                        Text(verbatim: L10n.string(quoting.rawValue)).tag(quoting)
                    }
                }
                Toggle("Duplikate entfernen", isOn: $options.deduplicate)
                Toggle("Ersetzungsmuster auf Treffer anwenden",
                       isOn: $options.useReplacement)
            }
            .formStyle(.grouped)

            HStack {
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Extrahieren") {
                    onExtract(options)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(options.separator == .custom && options.customSeparator.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(Theme.surfaceRaised)
    }
}
