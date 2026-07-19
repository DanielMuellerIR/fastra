import Foundation
import Testing
import CodeEditLanguages
@testable import Fastra

@Suite("Zentrale Dokumentformat-Identität")
struct DocumentFormatTests {
    @Test("Manuelle Grammatik und Eigen-Sprache gewinnen vor Dateiendung")
    func manualChoiceWins() {
        var tab = EditorTab(
            title: "notizen.md",
            path: "—",
            url: URL(fileURLWithPath: "/tmp/notizen.md")
        )
        tab.languageOverride = .json
        var format = DocumentFormatResolver.resolve(tab: tab)
        #expect(format.id == .grammar(.json))
        #expect(format.displayName == "JSON")
        #expect(format.grammar == .json)

        tab.languageOverride = nil
        tab.customLanguageOverrideID = CustomLanguageRegistry.fourD.id
        format = DocumentFormatResolver.resolve(tab: tab)
        #expect(format.id == .fourD)
        #expect(format.displayName == "4D")
        #expect(format.customLanguage == CustomLanguageRegistry.fourD)
    }

    @Test("Inhaltserkennung bewahrt XML-Identität trotz HTML-Grammatik")
    func contentDetectionKeepsEffectiveIdentity() {
        var tab = EditorTab(title: Workspace.untitledBaseName, path: "—")
        tab.contentDetectedLanguage = .html
        tab.contentDetectedFormat = .xml

        let format = DocumentFormatResolver.resolve(tab: tab)
        #expect(format.id == .xml)
        #expect(format.displayName == "XML")
        #expect(format.grammar == .html)
        #expect(SoftWrapFactoryDefaults.isEnabled(for: format.id))
    }

    @Test("Endungs- und Inhaltsautomatik fallen zuletzt auf echten Plain Text zurück")
    func automaticPriorityAndFallback() {
        var tab = EditorTab(title: "deploy", path: "—")
        tab.url = URL(fileURLWithPath: "/tmp/deploy")
        tab.content = "#!/bin/bash\nset -euo pipefail\necho ok\n"
        #expect(DocumentFormatResolver.resolve(tab: tab).id == .grammar(.bash))

        tab = EditorTab(title: "unbekannt.zzz", path: "—")
        #expect(DocumentFormatResolver.resolve(tab: tab).id == .plainText)
        #expect(DocumentFormatResolver.resolve(tab: tab).displayName
                == L10n.string("Reiner Text"))
    }

    @Test(arguments: [
        ("Methode.4dm", DocumentFormatID.fourD, TreeSitterLanguage.plainText),
        ("Projekt.4DProject", .grammar(.json), .json),
        ("Form.4dFoRm", .grammar(.json), .json),
        ("Catalog.4DCatalog", .xml, .html),
        ("Settings.4dSeTtInGs", .xml, .html),
    ])
    func fourDSpecialFormats(filename: String,
                             expectedID: DocumentFormatID,
                             expectedGrammar: TreeSitterLanguage) {
        let format = DocumentFormatResolver.resolve(filename: filename)
        #expect(format.id == expectedID)
        #expect(format.grammar.id == expectedGrammar)
    }

    @Test("Alle auswählbaren Sprachen besitzen eine bewusst festgelegte Default-Klasse")
    func everySelectableLanguageHasExplicitDefault() {
        let selectable = Set(
            LanguageMenuSupport.selectableEntries
                .map { DocumentFormatResolver.format(for: $0).id }
        )
        let required = selectable.union(DocumentFormatResolver.additionalProfileIDs)
        #expect(Set(SoftWrapFactoryDefaults.classes.keys) == required,
                "Neue/entfernte Sprache braucht eine bewusste Soft-Wrap-Default-Entscheidung")
    }

    @Test("Alle eingebauten Formate liegen in der spezifizierten Default-Klasse")
    func factoryDefaults() {
        let expectedOn: Set<DocumentFormatID> = [
            .plainText, .grammar(.markdown), .grammar(.html), .xml,
        ]
        let actualOn = Set(
            SoftWrapFactoryDefaults.classes.compactMap { id, defaultClass in
                defaultClass == .on ? id : nil
            }
        )
        let actualOff = Set(
            SoftWrapFactoryDefaults.classes.compactMap { id, defaultClass in
                defaultClass == .off ? id : nil
            }
        )

        #expect(actualOn == expectedOn)
        #expect(actualOff == Set(SoftWrapFactoryDefaults.classes.keys)
            .subtracting(expectedOn))
    }
}
