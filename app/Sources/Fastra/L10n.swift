import Foundation

/// Zentraler Zugriff für sichtbare Strings, die nicht als statischer
/// SwiftUI-Text geschrieben sind (AppKit, Enum-Rohwerte, zusammengesetzte
/// Statusmeldungen). Statische `Text("…")`-Schlüssel lokalisiert SwiftUI
/// direkt aus demselben Paket-Bundle.
enum L10n {
    static func string(_ key: String) -> String {
        AppResources.bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func string(_ key: String, defaultValue: String) -> String {
        AppResources.bundle.localizedString(forKey: key, value: defaultValue, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let format = string(key)
        return String(format: format, locale: Locale.current, arguments: arguments)
    }

    static func format(_ key: String, defaultValue: String,
                       _ arguments: CVarArg...) -> String {
        let format = string(key, defaultValue: defaultValue)
        return String(format: format, locale: Locale.current, arguments: arguments)
    }

    /// Explizite Sprache für automatisierte Prüfungen; die App selbst nutzt
    /// immer die macOS-Sprachreihenfolge über die Methoden oben.
    static func string(_ key: String, language: String) -> String {
        guard let url = AppResources.bundle.url(forResource: language, withExtension: "lproj"),
              let bundle = Bundle(url: url) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, language: String,
                       _ arguments: CVarArg...) -> String {
        String(format: string(key, language: language), locale: Locale(identifier: language),
               arguments: arguments)
    }
}
