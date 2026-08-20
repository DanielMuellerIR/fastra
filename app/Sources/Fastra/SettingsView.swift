import SwiftUI
import AppKit

/// Einstellungs-Dialog (⌘,).
///
/// SwiftUIs `Settings`-Scene (in `FastraApp`) bindet diesen View automatisch an
/// das Standard-macOS-Tastenkürzel ⌘, und legt den Menüpunkt „Einstellungen…"
/// unter dem App-Menü an.
///
/// Zusätzlich liegen hier Schriftwahl, die zwei getrennten Skalierungen und
/// die integrierte Markdown-Vorschau. Alle Werte sind app-weit persistent.
struct SettingsView: View {
    @Environment(\.uiScale) private var uiScale
    /// Erscheinungsbild (automatisch/hell/dunkel). Als String gespeichert
    /// (`AppearanceSetting.rawValue`) — gleicher Schlüssel wie
    /// `AppearanceSetting.current(defaults:)`, das der AppDelegate beim Start
    /// liest.
    @AppStorage(AppearanceSetting.defaultsKey, store: SelfTest.workspaceDefaults())
    private var appearanceRaw = AppearanceSetting.system.rawValue
    @AppStorage(UIZoom.defaultsKey, store: SelfTest.workspaceDefaults()) private var uiZoomLevel = 0
    @AppStorage(DocumentZoom.defaultsKey, store: SelfTest.workspaceDefaults()) private var documentZoomLevel = 0
    @AppStorage(EditorFonts.defaultsKey, store: SelfTest.workspaceDefaults()) private var editorFontName = EditorFonts.systemMonospacedName
    @AppStorage(SessionRestorationPreferences.enabledKey, store: SelfTest.workspaceDefaults())
    private var restoreLastSession = true
    @AppStorage("markdown.integratedPreview", store: SelfTest.workspaceDefaults()) private var showMarkdownPreview = true
    @AppStorage(PreviewFonts.defaultsKey, store: SelfTest.workspaceDefaults()) private var previewFontName = PreviewFonts.systemName
    // Druckeinstellungen. Die Voreinstellungen hier müssen mit
    // `PrintPreferences` übereinstimmen: Beide lesen denselben Schlüssel, und
    // ein nie gesetzter Schlüssel liefert bei `bool(forKey:)` immer `false`.
    @AppStorage(PrintPreferences.Keys.lineNumbers, store: SelfTest.workspaceDefaults())
    private var printLineNumbers = PrintPreferences.defaultLineNumbers
    @AppStorage(PrintPreferences.Keys.headerFooter, store: SelfTest.workspaceDefaults())
    private var printHeaderFooter = PrintPreferences.defaultHeaderFooter
    @AppStorage(PrintPreferences.Keys.fontSize, store: SelfTest.workspaceDefaults())
    private var printFontSize = PrintPreferences.defaultFontSize
    @AppStorage(GitPreferencesStore.Keys.decision, store: SelfTest.workspaceDefaults())
    private var gitFetchDecision = GitAutomaticFetchDecision.ask.rawValue
    @AppStorage(GitPreferencesStore.Keys.interval, store: SelfTest.workspaceDefaults())
    private var gitFetchInterval = GitPreferences.defaultFetchInterval
    @AppStorage(GitPreferencesStore.Keys.fetchOnActivation, store: SelfTest.workspaceDefaults())
    private var gitFetchOnActivation = true
    @AppStorage(GitPreferencesStore.Keys.remoteScope, store: SelfTest.workspaceDefaults())
    private var gitRemoteScope = GitRemoteScope.relevant.rawValue
    @AppStorage(GitPreferencesStore.Keys.prune, store: SelfTest.workspaceDefaults()) private var gitFetchPrune = false
    @AppStorage(GitPreferencesStore.Keys.pullStrategy, store: SelfTest.workspaceDefaults())
    private var gitPullStrategy = GitPullStrategy.unselected.rawValue
    // 4D-Werkzeuge: gemerkter tool4d-Pfad (derselbe Schlüssel, den auch
    // „Hilfe → tool4d finden…" pflegt) und das Makro-Engine-Projekt.
    @AppStorage(Tool4DAssist.rememberedPathKey, store: SelfTest.workspaceDefaults())
    private var tool4dPath = ""
    @AppStorage(FourDMacroEngineSettings.projectPathKey, store: SelfTest.workspaceDefaults())
    private var macroEngineProjectPath = ""
    /// Einmal beim Öffnen ermittelter Discovery-Fund als Platzhaltertext —
    /// nicht bei jedem Tastendruck neu suchen.
    @State private var tool4dDiscoveryPlaceholder = ""
    /// Sichtbares Problem der beiden 4D-Pfadfelder. Beide Prüfungen fassen das
    /// Dateisystem an und laufen deshalb im Hintergrund; beim Rendern wird nur
    /// das fertige Ergebnis gelesen.
    @State private var tool4dPathProblem: String?
    @State private var macroEngineProblem: String?
    // Auch dieser Speicher gehört in die Selbsttest-Suite: Sein `init`
    // migriert und schreibt beim ersten Zugriff. Mit `.standard` hätte ein
    // Einstellungs-Selbsttest die echten Editor-Profile des Nutzers
    // verändert (Review 2026-08-06). Im Normalbetrieb liefert
    // `SelfTest.workspaceDefaults()` `.standard` — Verhalten unverändert.
    @StateObject private var editorProfiles =
        SoftWrapProfileStore(defaults: SelfTest.workspaceDefaults())

    init() {
        // AppStorage kennt die typisierte Migration/Intervallbegrenzung nicht.
        // Die geladenen Werte dienen deshalb als Initialwerte, solange der
        // jeweilige neue Schlüssel noch nicht existiert.
        //
        // WICHTIG: Diese sechs Wrapper werden hier NEU gebaut und ersetzen die
        // oben deklarierten. Ohne `store:` läge der Ersatz auf `.standard` —
        // ein Selbsttest hätte damit die echten Git-Einstellungen des Nutzers
        // gelesen UND überschrieben, obwohl `SelfTest.workspaceDefaults()`
        // genau das verhindern soll (Review 2026-08-02). Im normalen Betrieb
        // liefert diese Funktion `.standard`, das Verhalten bleibt also gleich.
        let preferences = GitPreferencesStore(
            defaults: SelfTest.workspaceDefaults()
        ).load()
        _gitFetchDecision = AppStorage(
            wrappedValue: preferences.automaticFetchDecision.rawValue,
            GitPreferencesStore.Keys.decision,
            store: SelfTest.workspaceDefaults()
        )
        _gitFetchInterval = AppStorage(
            wrappedValue: preferences.fetchIntervalSeconds,
            GitPreferencesStore.Keys.interval,
            store: SelfTest.workspaceDefaults()
        )
        _gitFetchOnActivation = AppStorage(
            wrappedValue: preferences.fetchOnActivation,
            GitPreferencesStore.Keys.fetchOnActivation,
            store: SelfTest.workspaceDefaults()
        )
        _gitRemoteScope = AppStorage(
            wrappedValue: preferences.remoteScope.rawValue,
            GitPreferencesStore.Keys.remoteScope,
            store: SelfTest.workspaceDefaults()
        )
        _gitFetchPrune = AppStorage(
            wrappedValue: preferences.prune,
            GitPreferencesStore.Keys.prune,
            store: SelfTest.workspaceDefaults()
        )
        _gitPullStrategy = AppStorage(
            wrappedValue: preferences.pullStrategy.rawValue,
            GitPreferencesStore.Keys.pullStrategy,
            store: SelfTest.workspaceDefaults()
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Dark Mode", selection: $appearanceRaw) {
                    ForEach(AppearanceSetting.allCases) { setting in
                        Text(verbatim: L10n.string(setting.label)).tag(setting.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text(verbatim: L10n.string("„Automatisch“ folgt dem macOS-Erscheinungsbild (Systemeinstellungen → Erscheinungsbild). „Hell“ und „Dunkel“ legen das Erscheinungsbild von Fastra fest, unabhängig vom System."))
                    .fastraFont(.small)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Erscheinungsbild")
            }

            Section("Schrift und Größe") {
                Picker("Dokumentschrift", selection: $editorFontName) {
                    ForEach(EditorFonts.monospacedNames(current: editorFontName), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Stepper("Gesamte Oberfläche: \(uiZoomLevel > 0 ? "+" : "")\(uiZoomLevel)", value: $uiZoomLevel, in: UIZoom.minimumLevel...UIZoom.maximumLevel)
                Stepper("Dokumentschrift: \(documentZoomLevel > 0 ? "+" : "")\(documentZoomLevel)", value: $documentZoomLevel, in: DocumentZoom.minimumLevel...DocumentZoom.maximumLevel)
                Text("⌘−/⌘+/⌘0 skaliert die Oberfläche. ⇧⌘−/⇧⌘+/⇧⌘0 ändert nur die Dokument-Schrift.")
                    .fastraFont(.small).foregroundColor(.secondary)
            }

            Section("Editor") {
                Toggle("Seitenlinie anzeigen", isOn: Binding(
                    get: { editorProfiles.showPageGuide },
                    set: { editorProfiles.setShowPageGuide($0) }
                ))
                Stepper(
                    L10n.format("Seitenlinie: Spalte %ld",
                                editorProfiles.pageGuideColumn),
                    value: Binding(
                        get: { editorProfiles.pageGuideColumn },
                        set: { editorProfiles.setPageGuideColumn($0) }
                    ),
                    in: SoftWrapProfileStore.validColumnRange
                )
                Text("Die Seitenlinie ist eine appweite Orientierung. Soft Wrap kann pro Format unabhängig an Fensterbreite, Seitenlinie oder einer festen Spalte umbrechen.")
                    .fastraFont(.small)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Start") {
                Toggle("Zuletzt geöffnete Fenster und Dokumente wiederherstellen",
                       isOn: $restoreLastSession)
                Text("Fastra öffnet beim nächsten Start dieselben Projektfenster und gespeicherten Dokumente. Ungesicherte oder unbenannte Dokumentinhalte werden nie wiederhergestellt.")
                    .fastraFont(.small)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Markdown-Vorschau") {
                Toggle("Bei Markdown rechts anzeigen", isOn: $showMarkdownPreview)
                Picker("Vorschau-Schrift", selection: $previewFontName) {
                    ForEach(PreviewFonts.readingNames(current: previewFontName), id: \.self) { name in
                        Text(name == PreviewFonts.systemName ? "Systemschrift" : name).tag(name)
                    }
                }
                Text("Die Vorschau übernimmt die Dokument-Schriftgröße. Markierter Text wird als Klartext und formatiertes HTML kopiert.")
                    .fastraFont(.small).foregroundColor(.secondary)
            }

            Section("Drucken") {
                Toggle("Zeilennummern drucken", isOn: $printLineNumbers)
                Toggle("Kopf- und Fußzeile drucken", isOn: $printHeaderFooter)
                Stepper(L10n.format("Schriftgröße im Ausdruck: %ld pt",
                                    Int(printFontSize.rounded())),
                        value: $printFontSize,
                        in: PrintPreferences.fontSizeRange,
                        step: 1)
                Text("Die Schriftgröße gilt für Quelltext, Hex-Abzüge und die gedruckte Markdown-Vorschau. Zeilennummern gibt es nur beim Quelltext; Kopf- und Fußzeile tragen Quelltext-, Hex- und Bildausdrucke. Papiergröße und Ausrichtung stehen unter „Datei → Papierformat“.")
                    .fastraFont(.small)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Git") {
                Picker("Automatischer Fetch", selection: $gitFetchDecision) {
                    Text("Nachfragen").tag(GitAutomaticFetchDecision.ask.rawValue)
                    Text("Automatisch").tag(GitAutomaticFetchDecision.automatic.rawValue)
                    Text("Deaktiviert").tag(GitAutomaticFetchDecision.disabled.rawValue)
                }
                .accessibilityHint("Legt fest, ob Fastra Remote-Änderungen im Hintergrund abruft.")
                Stepper(
                    L10n.format("Fetch-Intervall: %ld Sekunden", gitFetchInterval),
                    value: $gitFetchInterval,
                    in: GitPreferences.fetchIntervalRange,
                    step: 60
                )
                .disabled(gitFetchDecision != GitAutomaticFetchDecision.automatic.rawValue)
                Toggle("Bei App-Aktivierung abrufen", isOn: $gitFetchOnActivation)
                    .disabled(gitFetchDecision != GitAutomaticFetchDecision.automatic.rawValue)
                Picker("Remotes abrufen", selection: $gitRemoteScope) {
                    Text("Nur relevanten Remote").tag(GitRemoteScope.relevant.rawValue)
                    Text("Alle Remotes").tag(GitRemoteScope.all.rawValue)
                }
                Toggle("Gelöschte Remote-Branches bereinigen (--prune)",
                       isOn: $gitFetchPrune)
                Picker("Pull-Strategie", selection: $gitPullStrategy) {
                    Text("Beim ersten Pull fragen").tag(GitPullStrategy.unselected.rawValue)
                    Text("Rebase (empfohlen)").tag(GitPullStrategy.rebase.rawValue)
                    Text("Merge").tag(GitPullStrategy.merge.rawValue)
                    Text("Nur Fast-Forward").tag(GitPullStrategy.ffOnly.rawValue)
                }
                Button("Erstfrage zu automatischem Fetch zurücksetzen") {
                    gitFetchDecision = GitAutomaticFetchDecision.ask.rawValue
                    // Gleiche Isolation wie im `init()`: im Selbsttest darf auch
                    // dieses Zurücksetzen nur die Testablage treffen.
                    GitPreferencesStore(defaults: SelfTest.workspaceDefaults())
                        .clearAutomaticFetchPromptDeferral()
                    gitPreferencesChanged()
                }
                Text("Diese Einstellungen steuern nur Fastra. Sie ändern weder .git/config noch deine globale Git-Konfiguration.")
                    .fastraFont(.small)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("4D") {
                TextField("tool4d (Pfad zur ausführbaren Datei)",
                          text: $tool4dPath,
                          prompt: Text(verbatim: tool4dDiscoveryPlaceholder))
                    .autocorrectionDisabled()
                if let problem = tool4dPathProblem {
                    Text(verbatim: problem)
                        .fastraFont(.small)
                        .foregroundColor(Theme.gitModified)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField("Makro-Engine-Projekt (Ordner mit Project/…)",
                          text: $macroEngineProjectPath,
                          prompt: Text(verbatim: "~/git-arbeit/MAO_Makros"))
                    .autocorrectionDisabled()
                if let problem = macroEngineProblem {
                    Text(verbatim: problem)
                        .fastraFont(.small)
                        .foregroundColor(Theme.gitModified)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Leer gelassen sucht Fastra tool4d selbst (PATH, Programme-Ordner, 4D-Analyzer). Das Makro-Engine-Projekt ist das 4D-Projekt mit der Startup-Methode MacroRun (z. B. MAO_Makros); ohne diesen Pfad laufen nur die nativen Text-Makros, die Komplettieren-Makros erklären dann, was fehlt.")
                    .fastraFont(.small)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .background(SettingsWindowConfiguration(
            preferredContentSize: NSSize(width: 680 * uiScale, height: 720 * uiScale),
            minimumContentSize: NSSize(width: 480 * uiScale, height: 380 * uiScale)
        ))
        // Auswahl sofort app-weit anwenden — alle Fenster (Dokument, Suche,
        // Über, dieser Dialog) wechseln live; die dynamischen Theme-Farben
        // und das Editor-Theme ziehen automatisch mit.
        .onChange(of: appearanceRaw) {
            // Gelesen wird aus DERSELBEN Suite, in die der Picker oben
            // geschrieben hat. Mit `.standard` läse ein Selbsttest den echten
            // Wert des Nutzers und wendete den falschen an (Review 2026-08-06).
            AppearanceSetting.current(defaults: SelfTest.workspaceDefaults()).apply()
        }
        .onChange(of: restoreLastSession) {
            if !restoreLastSession {
                // Ohne die Suite löschte ein Selbsttest den echten
                // wiederherstellbaren Sitzungszustand des Nutzers.
                SessionStateStore.clear(in: SelfTest.workspaceDefaults())
            }
        }
        .onAppear {
            // Einmalige Discovery für den Platzhalter des tool4d-Felds. Sie
            // liest alle PATH-Einträge, beide Programme-Ordner und die Ablage
            // der Analyzer-Extension — das gehört nicht auf den Main-Thread,
            // sonst hängt das Öffnen der Einstellungen an einem langsamen
            // Verzeichnis.
            DispatchQueue.global(qos: .userInitiated).async {
                let found = Tool4DDiscovery.locate()?.executableURL.path
                let placeholder = found
                    ?? L10n.string("automatisch (derzeit nicht gefunden — Hilfe → tool4d finden…)")
                DispatchQueue.main.async { tool4dDiscoveryPlaceholder = placeholder }
            }
            checkFourDPaths()
        }
        .onChange(of: tool4dPath) { checkFourDPaths() }
        .onChange(of: macroEngineProjectPath) { checkFourDPaths() }
        .onChange(of: gitFetchDecision) { gitPreferencesChanged() }
        .onChange(of: gitFetchInterval) {
            gitFetchInterval = GitPreferences.clampedFetchInterval(gitFetchInterval)
            gitPreferencesChanged()
        }
        .onChange(of: gitFetchOnActivation) { gitPreferencesChanged() }
        .onChange(of: gitRemoteScope) { gitPreferencesChanged() }
        .onChange(of: gitFetchPrune) { gitPreferencesChanged() }
        .onChange(of: gitPullStrategy) { gitPreferencesChanged() }
    }

    private func gitPreferencesChanged() {
        NotificationCenter.default.post(name: .fastraGitPreferencesChanged,
                                        object: nil)
    }

    /// Prüft beide 4D-Pfadfelder im Hintergrund und veröffentlicht nur das
    /// Ergebnis. Die Prüfung fasst das Dateisystem an; beim Rendern oder bei
    /// jedem Tastendruck auf dem Main-Thread verzögerte sie die Eingabe.
    private func checkFourDPaths() {
        let toolPath = tool4dPath
        let enginePath = macroEngineProjectPath
        DispatchQueue.global(qos: .userInitiated).async {
            let toolProblem = Tool4DAssist.executablePathProblem(toolPath)
            let engineProblem = Self.macroEngineProblem(for: enginePath)
            DispatchQueue.main.async {
                tool4dPathProblem = toolProblem
                macroEngineProblem = engineProblem
            }
        }
    }

    /// Sichtbares Problem des eingetragenen Engine-Projektpfads — pure
    /// Prüfung ohne stillen Fallback: leer ist erlaubt (Engine dann bewusst
    /// unkonfiguriert), ein gesetzter Pfad muss auf ein echtes 4D-Projekt
    /// zeigen.
    static func macroEngineProblem(for rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let path = (trimmed as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return L10n.string("Dieser Ordner existiert nicht.")
        }
        guard Tool4DProjectLocator.projectFile(in: URL(fileURLWithPath: path)) != nil else {
            return L10n.string("Im Ordner liegt keine .4DProject-Datei (erwartet unter „Project/“).")
        }
        return nil
    }
}
