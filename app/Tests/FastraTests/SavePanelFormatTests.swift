import Testing
import CodeEditLanguages
import Foundation
@testable import Fastra

@Test("Speichern-Formate enthalten jede im Editor auswählbare Sprache")
func saveFormatsContainEverySelectableLanguage() {
    let choices = SavePanelFormatSupport.choices
    let choiceIDs = Set(choices.map(\.formatID))
    let expectedIDs = Set(LanguageMenuSupport.selectableEntries.map {
        DocumentFormatResolver.format(for: $0).id
    })
    #expect(expectedIDs.isSubset(of: choiceIDs))
    #expect(Set(choices.map(\.id)).count == choices.count)
}

@Test("Neue Text- und Markdown-Dateien erhalten .txt beziehungsweise .md")
func saveFormatsSuggestUsefulDefaultExtensions() {
    let plain = SavePanelFormatSupport.choice(for: .plainText)
    let markdown = SavePanelFormatSupport.choice(for: .grammar(.markdown))
    #expect(SavePanelFormatSupport.initialFileName("Notiz", choice: plain) == "Notiz.txt")
    #expect(SavePanelFormatSupport.initialFileName("Notiz", choice: markdown) == "Notiz.md")
    #expect(SavePanelFormatSupport.initialFileName("Notiz.eigen", choice: markdown)
            == "Notiz.eigen")
}

@Test("Formatwechsel ersetzt nur die Endung und erhält den Basisnamen")
func saveFormatsReplaceExtension() {
    #expect(SavePanelFormatSupport.replacingExtension(of: "Archiv.tar.txt", with: "md")
            == "Archiv.tar.md")
    #expect(SavePanelFormatSupport.replacingExtension(of: "README", with: "swift")
            == "README.swift")
}

@Test("Dateinamen-Sonderformat Dockerfile bleibt ohne künstliche Endung erkennbar")
func saveFormatsHandleExactFileNames() {
    let docker = SavePanelFormatSupport.choice(for: .grammar(.dockerfile))
    #expect(docker.exactFileName == "Dockerfile")
    #expect(SavePanelFormatSupport.initialFileName("Unbenannt", choice: docker)
            == "Dockerfile")
    #expect(SavePanelFormatSupport.applying(docker, to: "Entwurf.swift")
            == "Dockerfile")
    let detected = CodeLanguage.detectLanguageFrom(
        url: URL(fileURLWithPath: "/tmp/Dockerfile")
    )
    #expect(detected.id == .dockerfile)
}
