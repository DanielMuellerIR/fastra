import Foundation

/// Der tatsächlich ausgeführte Prüfmodus. Eine Fähigkeitenabfrage löst weder
/// einen Parser noch das Laden des Formular-Schemas aus.
enum DocumentLintMode: Equatable, Sendable {
    case json
    case xml
    case fourDForm
    case fourD

    static func resolve(tab: EditorTab) -> DocumentLintMode? {
        let format = DocumentFormatResolver.resolve(tab: tab)
        let fileExtension = tab.url?.pathExtension ?? (tab.title as NSString).pathExtension
        // Die effektive Formatwahl gewinnt. Innerhalb der JSON-Familie bleibt
        // das Formular-Schema auch bei ausdrücklich gewähltem JSON erhalten.
        if format.id == .grammar(.json) {
            return fileExtension.lowercased() == "4dform" ? .fourDForm : .json
        }
        if format.id == .xml { return .xml }
        if format.id == .fourD { return .fourD }
        return nil
    }

    /// Der LSP-Pfad braucht eine echte 4D-Methodendatei. Manuell gewähltes 4D
    /// in einer anderen Datei erhält nur die lokale Strukturprüfung.
    func canUseTool4D(for tab: EditorTab) -> Bool {
        self == .fourD && tab.url?.pathExtension.lowercased() == "4dm"
    }

    /// Adapter für Aufrufer, die ausschließlich eine Dateiendung besitzen,
    /// etwa Format-Fixtures. Die Oberfläche verwendet immer `resolve(tab:)`.
    static func forFileExtension(_ fileExtension: String?) -> DocumentLintMode? {
        switch (fileExtension ?? "").lowercased() {
        case "json", "4dproject": return .json
        case "4dform": return .fourDForm
        case "xml", "xsd", "xsl", "xslt", "plist", "svg", "4dcatalog", "4dsettings":
            return .xml
        case "4dm": return .fourD
        default: return nil
        }
    }
}
