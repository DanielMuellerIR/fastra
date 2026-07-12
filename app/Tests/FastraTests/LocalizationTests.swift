import Foundation
import Testing
@testable import Fastra

@Suite("Englische Lokalisierung")
struct LocalizationTests {
    @Test("Statische, dynamische und formatierte Schlüssel werden englisch aufgelöst")
    func representativeKeys() {
        #expect(L10n.string("Abbrechen", language: "en") == "Cancel")
        #expect(L10n.string("Gesamtes Projekt", language: "en") == "Entire Project")
        #expect(L10n.format("Zeile %ld · Spalte %ld", language: "en", 12, 4)
                == "Line 12 · Column 4")
        #expect(L10n.string("demo.contacts", language: "en").contains("# Address Book"))
    }

    @Test("Alle sichtbaren Enum-Werte besitzen eine englische Übersetzung")
    func enumValues() {
        let keys = Workspace.SearchScope.allCases.map(\.rawValue)
            + FileTypeFilter.allCases.map(\.rawValue)
            + HitExtraction.Separator.allCases.map(\.rawValue)
            + HitExtraction.Quoting.allCases.map(\.rawValue)
            + HitExtraction.Destination.allCases.map(\.rawValue)
            + SidebarMode.allCases.map(\.rawValue)
            + AppearanceSetting.allCases.map(\.label)
        let languageNeutral = Set(["Tab", "Graph"])
        for key in keys {
            #expect(languageNeutral.contains(key)
                    || L10n.string(key, language: "en") != key,
                    "Englische Übersetzung fehlt: \(key)")
        }
    }

    @Test("Alle Vorlagen, Kategorien und Regex-Hilfen sind übersetzt")
    func searchTeachingContent() {
        let keys = BuiltInPatterns.all.map(\.name)
            + PatternCategory.allCases.map(\.rawValue)
            + RegexElements.categories.map(\.name)
            + RegexElements.categories.flatMap { $0.elements.map(\.hint) }
        let languageNeutral = Set(["URL", "IBAN", "UUID"])
        for key in Set(keys) {
            #expect(languageNeutral.contains(key)
                    || L10n.string(key, language: "en") != key,
                    "Englische Übersetzung fehlt: \(key)")
        }
    }
}
