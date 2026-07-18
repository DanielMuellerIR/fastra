// HelpContent.swift
//
// Inhalt und Anker der Fastra-Hilfe (Etappe 4 Wunschpaket 2026-07b).
// Die Hilfe liegt als mitgelieferte Markdown-Dateien (DE + EN) im
// Ressourcen-Bundle und wird read-only über den vorhandenen
// Markdown-Renderer dargestellt — bewusst KEIN Apple-Help-Buch
// (Indexer-/Caching-Ärger) und keine Bilder (ToDo „Hilfe später
// hübscher“ in ROADMAP.md).

import Foundation

enum HelpContent {

    /// Sprachwahl nach App-Sprache: Löst macOS die App-Lokalisierung auf
    /// Englisch auf, kommt die englische Hilfe, sonst die deutsche
    /// (Entwicklungs­sprache). Injizierbar für Tests.
    static func languageCode(
        preferred: [String] = Bundle.main.preferredLocalizations
    ) -> String {
        preferred.first?.lowercased().hasPrefix("en") == true ? "en" : "de"
    }

    /// Lädt die Hilfe-Markdown-Datei aus dem Bundle. `nil` nur bei kaputter
    /// Paketierung — genau das prüft der Selbsttest `help`.
    static func markdown(languageCode: String = languageCode()) -> String? {
        let name = "hilfe.\(languageCode)"
        // Erst der Unterordner (Normalfall), dann flach — SwiftPM kann
        // `.process`-Ressourcen je nach Plattform flach ablegen (gleiches
        // Muster wie `MarkdownPreviewAssets.resource`).
        let url = AppResources.bundle.url(forResource: name, withExtension: "md",
                                          subdirectory: "Help")
            ?? AppResources.bundle.url(forResource: name, withExtension: "md")
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Stabiler Anker-Slug für eine Überschrift: Kleinbuchstaben,
    /// alles außer Buchstaben/Ziffern wird zu „-“ (zusammengefasst,
    /// Ränder gekappt). „Suchen und Ersetzen“ → „suchen-und-ersetzen“.
    /// Pure Funktion → unit-testbar; JS braucht keine Kopie, weil die
    /// IDs bereits ins HTML geschrieben werden (`addingHeadingAnchors`).
    static func anchor(forHeading heading: String) -> String {
        let lowered = heading.lowercased()
        var slug = ""
        var previousWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash && !slug.isEmpty {
                slug.append("-")
                previousWasDash = true
            }
        }
        if slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }

    /// Überschriften-Regex: cmark rendert `<h2 data-sourcepos=…>Text</h2>`.
    private static let heading = try! NSRegularExpression(
        pattern: "<h([1-6])([^>]*)>(.*?)</h\\1>",
        options: [.dotMatchesLineSeparators]
    )

    /// Schreibt jedem `<h1>`–`<h6>` eine `id` aus dem Überschriftstext ins
    /// gerenderte HTML — die Sprungziele für „Hilfe öffnen bei Anker X“.
    static func addingHeadingAnchors(to html: String) -> String {
        let ns = html as NSString
        var result = ""
        var cursor = 0
        for match in heading.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor,
                                                 length: match.range.location - cursor))
            let level = ns.substring(with: match.range(at: 1))
            let attributes = ns.substring(with: match.range(at: 2))
            let inner = ns.substring(with: match.range(at: 3))
            // Für den Slug zählt der reine Text (ohne Inline-Markup).
            let plain = inner.replacingOccurrences(of: "<[^>]+>", with: "",
                                                   options: .regularExpression)
            let slug = anchor(forHeading: plain)
            if slug.isEmpty {
                result += ns.substring(with: match.range)
            } else {
                result += "<h\(level)\(attributes) id=\"\(slug)\">\(inner)</h\(level)>"
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}

/// Benannte Hilfe-Abschnitte für programmatische Sprünge („Hilfe öffnen bei
/// Anker X“, genutzt ab Etappe 5 für Erst-Nutzungs-Hinweise). Die Überschrift
/// je Sprache steht hier bewusst NOCH EINMAL — ein Unit-Test stellt sicher,
/// dass jede davon wirklich in der jeweiligen Markdown-Datei existiert
/// (Anti-Drift zwischen Enum und Hilfetext).
enum HelpSection: CaseIterable {
    case searchAndReplace
    case compareFiles
    case textTransformations
    case goToTarget
    case views
    case markdown
    case markdownWriting
    case languages
    case fourD
    case fourDTool
    case xpath
    case projectSidebar
    case git
    case encodings
    case windowsAndTabs

    /// Exakter Überschriftstext in der Hilfe-Datei der Sprache.
    func heading(languageCode: String) -> String {
        switch (self, languageCode) {
        case (.searchAndReplace, "en"):    return "Search and Replace"
        case (.searchAndReplace, _):       return "Suchen und Ersetzen"
        case (.compareFiles, "en"):        return "Comparing Files"
        case (.compareFiles, _):           return "Dateien vergleichen"
        case (.textTransformations, "en"): return "Text Transformations"
        case (.textTransformations, _):    return "Text-Transformationen"
        case (.goToTarget, "en"):          return "Go to Target"
        case (.goToTarget, _):             return "Gehe zum Ziel"
        case (.views, "en"):               return "Views: Text, Preview, Hex"
        case (.views, _):                  return "Ansichten: Text, Vorschau, Hex"
        case (.markdown, _):               return "Markdown"
        case (.markdownWriting, "en"):     return "Writing Markdown"
        case (.markdownWriting, _):        return "Markdown schreiben"
        case (.languages, "en"):           return "Languages and Syntax Colors"
        case (.languages, _):              return "Sprachen und Syntaxfarben"
        case (.fourD, "en"):               return "4D Support"
        case (.fourD, _):                  return "4D-Unterstützung"
        // Bewusst ohne „&“ — das Ampersand wird im gerenderten HTML zu
        // „&amp;“ escapet und ergäbe einen abweichenden Anker-Slug.
        case (.fourDTool, "en"):           return "4D and tool4d"
        case (.fourDTool, _):              return "4D und tool4d"
        case (.xpath, "en"):               return "XPath Bar"
        case (.xpath, _):                  return "XPath-Leiste"
        case (.projectSidebar, "en"):      return "Project and Sidebar"
        case (.projectSidebar, _):         return "Projekt und Seitenleiste"
        case (.git, _):                    return "Git"
        case (.encodings, "en"):           return "Encoding and Line Endings"
        case (.encodings, _):              return "Encoding und Zeilenenden"
        case (.windowsAndTabs, "en"):      return "Windows and Tabs"
        case (.windowsAndTabs, _):         return "Fenster und Tabs"
        }
    }

    /// Anker-Slug in der aktuell aktiven Hilfe-Sprache.
    func anchor(languageCode: String = HelpContent.languageCode()) -> String {
        HelpContent.anchor(forHeading: heading(languageCode: languageCode))
    }
}
