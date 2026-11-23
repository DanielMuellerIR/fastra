import Foundation

/// Behält die Großschreibung bei und liefert für ungültige String-Grenzen einen leeren Text.
enum UTF16Substring {
    static func extract(_ text: String, range: NSRange) -> String {
        guard let stringRange = Range(range, in: text) else { return "" }
        return String(text[stringRange])
    }
}
