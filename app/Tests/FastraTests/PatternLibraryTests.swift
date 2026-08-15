import Foundation
import Testing
@testable import Fastra

@Suite("Eigene Vorlagen und Beispiel-Transformation")
struct PatternLibraryTests {
    private func defaults() -> UserDefaults {
        let suite = "FastraTests.PatternLibrary.\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
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
        let collision = PatternTemplate(id: BuiltInPatterns.email.id, name: "Kollision",
                                        category: .words, regex: "x", exampleMatch: "x")
        let data = try JSONEncoder().encode([valid, broken, collision])
        let library = PatternLibrary(defaults: store)
        #expect(try library.import(data: data) == 1)
        #expect(library.templates == [valid])
    }

    @Test("Mehrere Fenster führen Speichern, Import und Löschen zusammen")
    @MainActor func mergesMutationsAcrossInstances() throws {
        let store = defaults()
        let first = PatternLibrary(defaults: store)
        let second = PatternLibrary(defaults: store)
        let third = PatternLibrary(defaults: store)
        let one = PatternTemplate(id: "one", name: "Eins", category: .words,
                                  regex: "one", exampleMatch: "one")
        let two = PatternTemplate(id: "two", name: "Zwei", category: .words,
                                  regex: "two", exampleMatch: "two")
        let three = PatternTemplate(id: "three", name: "Drei", category: .words,
                                    regex: "three", exampleMatch: "three")

        try first.save(one)
        try second.save(two)
        #expect(try third.import(data: JSONEncoder().encode([three])) == 1)
        first.delete(id: one.id)

        let reloaded = PatternLibrary(defaults: store)
        #expect(reloaded.templates.map(\.id) == [two.id, three.id])
    }

    @Test("Leere und eingebaute IDs können nicht als eigene Vorlage gespeichert werden")
    @MainActor func rejectsInvalidUserIDs() {
        let library = PatternLibrary(defaults: defaults())
        let empty = PatternTemplate(id: "", name: "Leer", category: .words,
                                    regex: "x", exampleMatch: "x")
        let whitespace = PatternTemplate(id: "  \n", name: "Leerraum", category: .words,
                                         regex: "x", exampleMatch: "x")
        let builtIn = PatternTemplate(id: BuiltInPatterns.email.id, name: "Kollision",
                                      category: .words, regex: "x", exampleMatch: "x")

        #expect(throws: PatternLibraryError.self) { try library.save(empty) }
        #expect(throws: PatternLibraryError.self) { try library.save(whitespace) }
        #expect(throws: PatternLibraryError.self) { try library.save(builtIn) }
        #expect(library.templates.isEmpty)
    }

    @Test("Importdateien werden begrenzt gelesen")
    func boundsImportFileRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-patterns-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x20,
                 count: PatternLibraryImportFile.maximumBytes + 1).write(to: url)

        #expect(throws: PatternLibraryError.self) {
            try PatternLibraryImportFile.read(from: url)
        }
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
        #expect(ExampleTransformation.infer(source: "a*b", destination: "b*a") == nil)
    }
}
