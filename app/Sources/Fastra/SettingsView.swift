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
    /// `AppearanceSetting.current()`, das der AppDelegate beim Start liest.
    @AppStorage(AppearanceSetting.defaultsKey)
    private var appearanceRaw = AppearanceSetting.system.rawValue
    @AppStorage(UIZoom.defaultsKey) private var uiZoomLevel = 0
    @AppStorage(DocumentZoom.defaultsKey) private var documentZoomLevel = 0
    @AppStorage(EditorFonts.defaultsKey) private var editorFontName = EditorFonts.systemMonospacedName
    @AppStorage(SessionRestorationPreferences.enabledKey)
    private var restoreLastSession = true
    @AppStorage("markdown.integratedPreview") private var showMarkdownPreview = true
    @AppStorage(PreviewFonts.defaultsKey) private var previewFontName = PreviewFonts.systemName
    @AppStorage(GitPreferencesStore.Keys.decision)
    private var gitFetchDecision = GitAutomaticFetchDecision.ask.rawValue
    @AppStorage(GitPreferencesStore.Keys.interval)
    private var gitFetchInterval = GitPreferences.defaultFetchInterval
    @AppStorage(GitPreferencesStore.Keys.fetchOnActivation)
    private var gitFetchOnActivation = true
    @AppStorage(GitPreferencesStore.Keys.remoteScope)
    private var gitRemoteScope = GitRemoteScope.relevant.rawValue
    @AppStorage(GitPreferencesStore.Keys.prune) private var gitFetchPrune = false
    @AppStorage(GitPreferencesStore.Keys.pullStrategy)
    private var gitPullStrategy = GitPullStrategy.unselected.rawValue
    @StateObject private var editorProfiles = SoftWrapProfileStore()

    init() {
        // AppStorage kennt die typisierte Migration/Intervallbegrenzung nicht.
        // Die geladenen Werte dienen deshalb als Initialwerte, solange der
        // jeweilige neue Schlüssel noch nicht existiert.
        let preferences = GitPreferencesStore().load()
        _gitFetchDecision = AppStorage(
            wrappedValue: preferences.automaticFetchDecision.rawValue,
            GitPreferencesStore.Keys.decision
        )
        _gitFetchInterval = AppStorage(
            wrappedValue: preferences.fetchIntervalSeconds,
            GitPreferencesStore.Keys.interval
        )
        _gitFetchOnActivation = AppStorage(
            wrappedValue: preferences.fetchOnActivation,
            GitPreferencesStore.Keys.fetchOnActivation
        )
        _gitRemoteScope = AppStorage(
            wrappedValue: preferences.remoteScope.rawValue,
            GitPreferencesStore.Keys.remoteScope
        )
        _gitFetchPrune = AppStorage(
            wrappedValue: preferences.prune,
            GitPreferencesStore.Keys.prune
        )
        _gitPullStrategy = AppStorage(
            wrappedValue: preferences.pullStrategy.rawValue,
            GitPreferencesStore.Keys.pullStrategy
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
                    GitPreferencesStore().clearAutomaticFetchPromptDeferral()
                    gitPreferencesChanged()
                }
                Text("Diese Einstellungen steuern nur Fastra. Sie ändern weder .git/config noch deine globale Git-Konfiguration.")
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
            AppearanceSetting.current().apply()
        }
        .onChange(of: restoreLastSession) {
            if !restoreLastSession {
                SessionStateStore.clear()
            }
        }
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
}
