// CustomLanguageRegistry.swift
//
// Eigen-Sprachen-Registry (Etappe 3 Wunschpaket 2026-07b): die EINE zentrale
// Beschreibung aller Sprachen, die NICHT über CodeEditLanguages laufen
// (derzeit einziger Eintrag: 4D). Sowohl das Fußzeilen-Sprachmenü
// (`LanguageMenuSupport`) als auch das Editor-Routing (Provider, Theme,
// Endungs-Automatik in `EditorView`) speisen sich aus dieser Quelle — eine
// künftige Eigen-Sprache kann damit nicht mehr am Menü vorbeilaufen
// (Anti-Drift-Unit-Test in LanguageMenuTests).

import Foundation
import CodeEditLanguages
import CodeEditSourceEditor

/// Beschreibung einer Eigen-Sprache: Anzeigename, Endungen, Grammatik-
/// Unterbau, Themes und Highlight-Provider.
struct CustomLanguage: Identifiable {
    /// Stabile Registry-ID — wird als manueller Override am Tab gespeichert.
    let id: String
    /// Name im Sprachmenü und im Fußzeilen-Chip.
    let displayName: String
    /// Kleingeschriebene Dateiendungen für die Endungs-Automatik.
    let fileExtensions: Set<String>
    /// Tree-sitter-Unterbau im Editor. Für 4D bewusst Plaintext — die
    /// Farben liefert vollständig der eigene Highlight-Provider.
    let baseGrammar: CodeLanguage
    /// Editor-Themes (hell/dunkel) für Dokumente dieser Sprache.
    let lightTheme: EditorTheme
    let darkTheme: EditorTheme
    /// Erzeugt den Highlight-Provider. Ein Provider lebt pro Editor-Fenster
    /// (`CustomLanguageProviders`-Cache), nicht pro Aufruf.
    let makeHighlightProvider: () -> any HighlightProviding
}

extension CustomLanguage: Equatable, Hashable {
    static func == (lhs: CustomLanguage, rhs: CustomLanguage) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum CustomLanguageRegistry {
    /// 4D-Methoden (.4dm). Die Projekt-Begleitdateien `.4DProject`/`.4DForm`
    /// (JSON) und `.4DCatalog`/`.4DSettings` (XML) gehören bewusst NICHT
    /// hierher — das sind echte JSON-/XML-Dateien und behalten ihr Routing
    /// in `EditorView.grammarForSpecialExtension`.
    static let fourD = CustomLanguage(
        id: "fastra.lang.4d",
        displayName: "4D",
        fileExtensions: ["4dm"],
        baseGrammar: .default,
        lightTheme: EditorView.fourDTheme,
        darkTheme: EditorView.fourDThemeDark,
        makeHighlightProvider: { FourDHighlightProvider() }
    )

    /// Alle Eigen-Sprachen. Neue Einträge hier ergänzen — Menü und Routing
    /// ziehen automatisch nach (Anti-Drift-Test schlägt sonst an).
    static let all: [CustomLanguage] = [fourD]

    static func language(forExtension fileExtension: String) -> CustomLanguage? {
        let lowered = fileExtension.lowercased()
        guard !lowered.isEmpty else { return nil }
        return all.first { $0.fileExtensions.contains(lowered) }
    }

    static func language(withID id: String) -> CustomLanguage? {
        all.first { $0.id == id }
    }
}

/// Hält je Editor-Fenster einen Highlight-Provider pro Eigen-Sprache am
/// Leben (lazily erzeugt). Als `@StateObject` gebunden, damit der Provider
/// Tab-Wechsel und Editor-Remounts überlebt und seinen Zustand behält.
final class CustomLanguageProviders: ObservableObject {
    private var cache: [String: any HighlightProviding] = [:]
    private var fourDProjectMethodNames = Set<String>()

    func provider(for language: CustomLanguage,
                  projectMethodNames: Set<String> = []) -> any HighlightProviding {
        if language.id == CustomLanguageRegistry.fourD.id {
            let normalized = Set(projectMethodNames.map { $0.lowercased() })
            // CESE vergleicht Provider über ihre Objektidentität. Eine neue
            // Instanz nach abgeschlossenem Index-Scan invalidiert daher die
            // sichtbaren Highlights, ohne den Editor neu zu mounten oder die
            // Selektion anzutasten.
            if normalized != fourDProjectMethodNames || cache[language.id] == nil {
                fourDProjectMethodNames = normalized
                let fresh = FourDHighlightProvider(projectMethodNames: normalized)
                cache[language.id] = fresh
                return fresh
            }
        }
        if let existing = cache[language.id] { return existing }
        let fresh = language.makeHighlightProvider()
        cache[language.id] = fresh
        return fresh
    }
}
