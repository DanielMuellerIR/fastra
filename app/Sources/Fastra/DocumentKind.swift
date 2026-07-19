import Foundation

/// Zentrale Dateityp-Erkennung für Footer und formatabhängige UI. Die
/// Endung wird klein verglichen, damit `BEISPIEL.XML` korrekt erkannt wird.
enum DocumentKind {
    static func isXML(filename: String) -> Bool {
        DocumentFormatResolver.resolve(filename: filename).id == .xml
    }

    static func footerLabel(filename: String) -> String {
        DocumentFormatResolver.resolve(filename: filename).displayName
    }
}
