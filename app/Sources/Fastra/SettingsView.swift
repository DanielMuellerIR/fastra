import SwiftUI

/// Einstellungs-Dialog (⌘,) — Stage B des Umbruch-Features.
///
/// SwiftUIs `Settings`-Scene (in `FastraApp`) bindet diesen View automatisch an
/// das Standard-macOS-Tastenkürzel ⌘, und legt den Menüpunkt „Einstellungen…"
/// unter dem App-Menü an. Der Dialog ist die AUFFINDBARE Heimat für persistente
/// App-Voreinstellungen — bisher war der Umbruch-Default nur über den
/// versteckten Menüpunkt „Zeilen umbrechen" (⌘⇧L) erreichbar.
///
/// Umfang bewusst klein gehalten (Karpathy: nichts Spekulatives):
///   - Erscheinungsbild (Dark Mode): automatisch/hell/dunkel — gespeichert
///     als `AppearanceSetting.rawValue`, sofort app-weit angewendet.
///   - Umbruch-Default an/aus — derselbe `@AppStorage("editor.wrapLines")` wie
///     in `EditorView`/`FastraApp`; Änderung wirkt sofort app-weit (CESE
///     reconcilet die ungleiche Config live).
///
/// BEWUSST NICHT enthalten — „Soft-Wrap an fester Spalte N" (+ Spaltenzahl):
/// CodeEditSourceEditor kennt nur `wrapLines: Bool` (Umbruch am Fensterrand
/// vs. gar nicht). `reformatAtColumn` ist nur eine visuelle Hilfslinie, KEIN
/// echter Umbruch. Spaltenbasiertes Soft-Wrap bräuchte tiefe CESE-Chirurgie
/// (eigene `wrapLinesWidth = Spalte × Zeichenbreite`) → als v1.1-Entscheidung
/// zurückgestellt (siehe todo.md / _log/decisions.md).
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
        }
        .formStyle(.grouped)
        .frame(width: 420 * uiScale, height: 300 * uiScale)
        // Auswahl sofort app-weit anwenden — alle Fenster (Dokument, Suche,
        // Über, dieser Dialog) wechseln live; die dynamischen Theme-Farben
        // und das Editor-Theme ziehen automatisch mit.
        .onChange(of: appearanceRaw) {
            AppearanceSetting.current().apply()
        }
    }
}
