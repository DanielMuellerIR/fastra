import Foundation

/// Zentraler Zugriff für sichtbare Strings, die nicht als statischer
/// SwiftUI-Text geschrieben sind (AppKit, Enum-Rohwerte, zusammengesetzte
/// Statusmeldungen). Statische `Text("…")`-Schlüssel lokalisiert SwiftUI
/// direkt aus demselben Paket-Bundle.
enum L10n {
    /// Im CLI-/Test-Build liefert SwiftPM `Bundle.module`; in der gepackten
    /// macOS-App liegt dasselbe Bundle standardkonform unter
    /// `Contents/Resources`. Der explizite App-Pfad verhindert, dass ein auf
    /// dem Build-Mac vorhandener absoluter SwiftPM-Fallback einen kaputten
    /// verteilten Build kaschiert.
    private static let resourceBundle: Bundle = {
        if let resources = Bundle.main.resourceURL,
           let packaged = Bundle(
               url: resources.appendingPathComponent("Fastra_Fastra.bundle")
           ) {
            return packaged
        }
        return Bundle.module
    }()

    static func string(_ key: String) -> String {
        resourceBundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func string(_ key: String, defaultValue: String) -> String {
        resourceBundle.localizedString(forKey: key, value: defaultValue, table: nil)
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
        guard let url = resourceBundle.url(forResource: language, withExtension: "lproj"),
              let bundle = Bundle(url: url) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, language: String,
                       _ arguments: CVarArg...) -> String {
        String(format: string(key, language: language), locale: Locale(identifier: language),
               arguments: arguments)
    }
}
