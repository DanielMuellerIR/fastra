import SwiftUI
import AppKit

/// Einstellungs-Dialog (⌘,) — Stage B des Umbruch-Features.
///
/// SwiftUIs `Settings`-Scene (in `FastraApp`) bindet diesen View automatisch an
/// das Standard-macOS-Tastenkürzel ⌘, und legt den Menüpunkt „Einstellungen…"
/// unter dem App-Menü an. Der Dialog ist die AUFFINDBARE Heimat für persistente
/// App-Voreinstellungen — bisher war der Umbruch-Default nur über den
/// versteckten Menüpunkt „Zeilen umbrechen" (⌘⇧L) erreichbar.
///
/// Zusätzlich liegen hier Schriftwahl, die zwei getrennten Skalierungen und
/// die integrierte Markdown-Vorschau. Alle Werte sind app-weit persistent.
struct SettingsView: View {
    @Environment(\.uiScale) private var uiScale
    /// App-weiter Umbruch-Default. Gleicher Schlüssel wie EditorView/FastraApp
    /// → die drei Stellen teilen exakt einen Wert.
    @AppStorage("editor.wrapLines") private var wrapLines = true

    /// Erscheinungsbild (automatisch/hell/dunkel). Als String gespeichert
    /// (`AppearanceSetting.rawValue`) — gleicher Schlüssel wie
    /// `AppearanceSetting.current()`, das der AppDelegate beim Start liest.
    @AppStorage(AppearanceSetting.defaultsKey)
    private var appearanceRaw = AppearanceSetting.system.rawValue
    @AppStorage(UIZoom.defaultsKey) private var uiZoomLevel = 0
    @AppStorage(DocumentZoom.defaultsKey) private var documentZoomLevel = 0
    @AppStorage(EditorFonts.defaultsKey) private var editorFontName = EditorFonts.systemMonospacedName
    @AppStorage("markdown.integratedPreview") private var showMarkdownPreview = true
    @AppStorage(PreviewFonts.defaultsKey) private var previewFontName = PreviewFonts.systemName

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

            Section {
                Toggle("Lange Zeilen am Fensterrand umbrechen", isOn: $wrapLines)
                Text(verbatim: L10n.string("Wirkt sofort in allen geöffneten Tabs. Ohne Umbruch lässt sich langer Text horizontal scrollen. Auch über „Darstellung → Zeilen umbrechen“ (⌘⇧L) umschaltbar."))
                    .fastraFont(.small)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Editor")
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
    }
}
