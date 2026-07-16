import Foundation
import Testing
@testable import Fastra

@Suite("Englische Lokalisierung")
struct LocalizationTests {
    @Test("Statische, dynamische und formatierte Schlüssel werden englisch aufgelöst")
    func representativeKeys() {
        #expect(L10n.string("Abbrechen", language: "en") == "Cancel")
        #expect(L10n.string("Gesamtes Projekt", language: "en") == "Entire Project")
        #expect(L10n.string("Voriger Konflikt", language: "en") == "Previous Conflict")
        #expect(L10n.string("Nächster Konflikt", language: "en") == "Next Conflict")
        #expect(L10n.string("Seitenleiste ausblenden", language: "en") == "Hide Sidebar")
        #expect(L10n.string("Seitenleiste einblenden", language: "en") == "Show Sidebar")
        #expect(L10n.string("Markdown-Vorschau ausblenden", language: "en")
                == "Hide Markdown Preview")
        #expect(L10n.string("Markdown-Vorschau einblenden", language: "en")
                == "Show Markdown Preview")
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

    @Test("Alle erweiterten Git-Aktionslabels und Erfolgstexte sind katalogisiert")
    func gitActionCatalog() {
        let languageNeutral = Set([
            "Stash", "Stash Pop", "Cherry-pick", "Revert", "Force Push with Lease"
        ])
        for action in GitActionText.allCases {
            #expect(languageNeutral.contains(action.labelKey)
                    || L10n.string(action.labelKey, language: "en") != action.labelKey,
                    "Englisches Git-Aktionslabel fehlt: \(action.labelKey)")
            #expect(L10n.string(action.successKey, language: "en") != action.successKey,
                    "Englischer Git-Erfolgstext fehlt: \(action.successKey)")
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
