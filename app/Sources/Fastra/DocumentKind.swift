import Foundation

/// Zentrale Dateityp-Erkennung für Footer und formatabhängige UI. Die
/// Endung wird klein verglichen, damit `BEISPIEL.XML` korrekt erkannt wird.
enum DocumentKind {
    static let xmlExtensions: Set<String> = ["xml", "xsd", "xsl", "xslt", "plist"]

    static func isXML(filename: String) -> Bool {
        xmlExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    static func footerLabel(filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "md", "markdown": return "Markdown"
        case "csv": return "CSV"
        // 4D-Projektdateien (Etappe 4): Container-Formate zeigen ihr
        // tatsächliches Datenformat, Methoden zeigen „4D".
        case "json", "4dproject", "4dform": return "JSON"
        case "xml", "xsd", "xsl", "xslt", "plist", "4dcatalog", "4dsettings":
            return "XML"
        case "4dm": return "4D"
        case "html", "htm": return "HTML"
        case "swift": return "Swift"
        case "py": return "Python"
        case "js": return "JavaScript"
        case "ts": return "TypeScript"
        case "rs": return "Rust"
        case "go": return "Go"
        default: return "Plain"
        }
    }
}
