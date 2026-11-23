import AppKit

/// Erscheinungsbild-Einstellung: Hell, Dunkel oder dem System folgen
/// (Einstellungen → Erscheinungsbild, ⌘,). Die dynamischen `Theme`-Farben
/// besitzen helle und dunkle Ausprägungen.
enum AppearanceSetting: String, CaseIterable, Identifiable {
    /// Automatisch — dem macOS-System-Erscheinungsbild folgen.
    case system
    /// Manuell hell (Aqua), unabhängig vom System.
    case light
    /// Manuell dunkel (Dark Aqua), unabhängig vom System.
    case dark

    /// UserDefaults-Schlüssel — geteilt von `SettingsView` (Picker) und
    /// `AppDelegate` (Anwenden beim Start).
    static let defaultsKey = "app.appearance"

    var id: String { rawValue }

    /// Anzeigename im Einstellungs-Dialog.
    var label: String {
        switch self {
        case .system: return "Automatisch"
        case .light:  return "Hell"
        case .dark:   return "Dunkel"
        }
    }

    /// Ziel-Appearance für `NSApp.appearance`. `nil` = dem System folgen
    /// (AppKit-Konvention: nil-Appearance erbt vom System).
    var nsAppearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light:  return .aqua
        case .dark:   return .darkAqua
        }
    }

    /// Aktuell gespeicherte Einstellung. Fehlender oder unbekannter Wert
    /// (z.B. aus einer künftigen Version) fällt sicher auf `.system` zurück.
    static func current(defaults: UserDefaults = .standard) -> AppearanceSetting {
        AppearanceSetting(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .system
    }

    /// Wendet die Einstellung app-weit an. Alle Fenster (Dokument-, Such-,
    /// Über-Fenster) erben von `NSApp.appearance`.
    func apply() {
        NSApp.appearance = nsAppearanceName.flatMap { NSAppearance(named: $0) }
    }
}
