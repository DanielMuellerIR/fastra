import Foundation
import Testing
@testable import Fastra

@Suite("Eigene Vorlagen und Beispiel-Transformation")
struct PatternLibraryTests {
    private func defaults() -> UserDefaults {
        let suite = "FastraTests.PatternLibrary.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Eigene Vorlage überlebt einen neuen Store")
    @MainActor func persistsTemplate() throws {
        let store = defaults()
        let library = PatternLibrary(defaults: store)
        let template = PatternTemplate(id: "mine", name: "Meine Zahl", category: .numbers,
                                       regex: #"\\d+"#, exampleMatch: "1")
        try library.save(template)
        #expect(PatternLibrary(defaults: store).templates == [template])
    }

    @Test("Import verwirft ungültige RegEx-Vorlagen")
    @MainActor func importFiltersInvalidTemplates() throws {
        let store = defaults()
        let valid = PatternTemplate(id: "ok", name: "OK", category: .words, regex: "x", exampleMatch: "x")
        let broken = PatternTemplate(id: "no", name: "Kaputt", category: .words, regex: "(", exampleMatch: "")
        let data = try JSONEncoder().encode([valid, broken])
        let library = PatternLibrary(defaults: store)
        #expect(try library.import(data: data) == 2)
        #expect(library.templates == [valid])
    }

    @Test("Beispiel leitet die Artikel-Umstellung als Platzhalter ab")
    func infersArticleTransformation() {
        #expect(ExampleTransformation.infer(source: "ring, The", destination: "The ring") ==
                .init(findPattern: "*, The", replacePattern: "The *"))
    }

    @Test("Gleiche oder überlange Beispiele werden nicht geraten")
    func rejectsUnsafeExamples() {
        #expect(ExampleTransformation.infer(source: "gleich", destination: "gleich") == nil)
        #expect(ExampleTransformation.infer(source: String(repeating: "x", count: 513), destination: "x") == nil)
    }
}
