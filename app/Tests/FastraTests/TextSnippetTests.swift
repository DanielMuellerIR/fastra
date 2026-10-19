import AppKit
import SwiftUI
import Foundation
import Testing
@testable import Fastra

@Suite(.serialized) struct TextSnippetTests {
    @Test("Wiederholte Platzhalter teilen ein Feld in der Reihenfolge des ersten Auftretens")
    func repeatedNames() throws {
        let template = try TextSnippetTemplate("{{ Name }} / {{Ort}} / {{Name}}")
        #expect(template.names == ["Name", "Ort"])
        #expect(try template.render(values: ["Name": "Jo", "Ort": "Köln"]) == "Jo / Köln / Jo")
    }
    @Test("Mehrzeilige Unicode-Werte erhalten Bytes und werden nicht erneut ausgewertet")
    func literalUnicodeValues() throws {
        let value = "😀 e\u{301}\r\n{{Ort}}\nEnde"
        let result = try TextSnippetTemplate("vor {{Name}} nach {{Name}}").render(values: ["Name": value])
        #expect(Array(result.utf8) == Array(("vor " + value + " nach " + value).utf8))
    }
    @Test("Leere Werte und wörtliche einzelne Klammern sind erlaubt")
    func emptyAndLiteral() throws {
        #expect(try TextSnippetTemplate("if { {{Wert}} }").render(values: ["Wert": ""]) == "if {  }")
    }
    @Test("Fehlende Werte und unvollständige oder verschachtelte Platzhalter werden abgewiesen")
    func invalidTemplates() throws {
        for source in ["{{", "{{}}", "{{a\nb}}", "{{a\u{0}b}}", "{{a{{b}}", "{{" + String(repeating: "a", count: 65) + "}}"] {
            #expect(throws: TextSnippetError.self) { try TextSnippetTemplate(source) }
        }
        let template = try TextSnippetTemplate("{{Name}}")
        #expect(throws: TextSnippetError.self) { try template.render(values: [:]) }
    }
    @Test("Vorlage, Namenanzahl, Werte und expandiertes Ergebnis sind begrenzt")
    func boundedExpansion() throws {
        #expect(throws: TextSnippetError.self) { try TextSnippetTemplate(String(repeating: "x", count: 16 * 1024 + 1)) }
        #expect(throws: TextSnippetError.self) { try TextSnippetTemplate((0..<33).map { "{{p\($0)}}" }.joined()) }
        let template = try TextSnippetTemplate(String(repeating: "{{Name}}", count: 17))
        #expect(throws: TextSnippetError.self) { try template.render(values: ["Name": String(repeating: "x", count: 16 * 1024)]) }
        #expect(throws: TextSnippetError.self) { try template.render(values: ["Name": String(repeating: "x", count: 16 * 1024 + 1)]) }
    }
    @Test("Quelle ersetzt nur die festgehaltene Auswahl mit einem Undo-Schritt und weist einen Auswahlwechsel ab")
    @MainActor func sourceInsertionAndUndo() async throws {
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra.tests.snippet.source.\(UUID())"))
        let source = "vor OLD nach\r\nUnverändert 😀\n"
        let tab = EditorTab(title: "snippet.txt", path: "", content: source)
        workspace.tabs = [tab]; workspace.activeTabID = tab.id
        let host = NSHostingView(rootView: EditorView().environmentObject(workspace))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer { WorkspaceWindowRegistry.unregister(window); window.close() }
        window.alphaValue = 0; window.orderBack(nil)
        try #require(await waitUntil { CommandTargeting.editorTextView(for: workspace)?.string == source })
        let editor = try #require(CommandTargeting.editorTextView(for: workspace))
        let range = (source as NSString).range(of: "OLD")
        editor.selectionManager.setSelectedRange(range)
        let target: TextSnippetInsertionTarget = try await withCheckedThrowingContinuation { done in
            TextSnippetInsertionTarget.capture(in: workspace) { done.resume(with: $0) }
        }
        defer { target.release() }
        let value = "😀 e\u{301}\nzweite Zeile"
        let replacement = try TextSnippetTemplate("{{Name}} / {{Name}}").render(values: ["Name": value])
        let expected = (source as NSString).replacingCharacters(in: range, with: replacement)
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            target.insert(replacement) { done.resume(with: $0) }
        }
        #expect(workspace.activeTab?.content.utf8.elementsEqual(expected.utf8) == true)
        #expect(editor.string.utf8.elementsEqual(expected.utf8))
        let history = try #require(editor.undoManager)
        history.undo()
        #expect(await waitUntil { workspace.activeTab?.content.utf8.elementsEqual(source.utf8) == true })
        history.redo()
        #expect(await waitUntil { workspace.activeTab?.content.utf8.elementsEqual(expected.utf8) == true })
        let stale: TextSnippetInsertionTarget = try await withCheckedThrowingContinuation { done in
            TextSnippetInsertionTarget.capture(in: workspace) { done.resume(with: $0) }
        }
        defer { stale.release() }
        editor.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!stale.isCurrent)
        let result: Result<Void, Error> = await withCheckedContinuation { done in stale.insert("FALSCH") { done.resume(returning: $0) } }
        if case .success = result { Issue.record("Veraltete Auswahl wurde beschrieben") }
        #expect(editor.string.utf8.elementsEqual(expected.utf8))
    }

    @Test("Zwei Store-Instanzen erhalten fremde Einträge und weisen verlorene Revisionen ab")
    @MainActor func multiwindowStore() throws {
        let defaults = testSuiteDefaults(named: "fastra.tests.snippet.store.\(UUID())")
        let first = TextSnippetStore(defaults: defaults), second = TextSnippetStore(defaults: defaults)
        var a = try first.save(TextSnippetDefinition(name: "A", template: "eins"), expectedRevision: nil)
        let b = try second.save(TextSnippetDefinition(name: "B", template: "zwei"), expectedRevision: nil)
        let old = a
        a.template = "neu"
        a = try first.save(a, expectedRevision: a.revision)
        #expect(try second.load().map(\.name) == ["A", "B"])
        #expect(throws: TextSnippetError.self) { try second.save(old, expectedRevision: old.revision) }
        #expect(throws: TextSnippetError.self) { try second.remove(id: old.id, expectedRevision: old.revision) }
        #expect(try first.load() == [a, b])
        try second.remove(id: a.id, expectedRevision: a.revision)
        #expect(try first.load() == [b])
    }
    @Test("Import benennt Konflikte ohne Überschreiben um und vergibt neue Identitäten")
    @MainActor func mergeImport() throws {
        let defaults = testSuiteDefaults(named: "fastra.tests.snippet.import.\(UUID())")
        let store = TextSnippetStore(defaults: defaults)
        let original = try store.save(TextSnippetDefinition(name: "Gruß", template: "Alt"), expectedRevision: nil)
        let data = try TextSnippetArchive.encode([original, TextSnippetDefinition(name: "GRUSS", template: "{{Name}}")])
        let preview = try store.previewImport(data)
        #expect(preview.map(\.name) == ["Gruß (2)", "GRUSS (3)"])
        #expect(try store.load() == [original])
        let imported = try store.importDefinitions(data)
        #expect(imported.count == 2)
        #expect(imported[0].name == "Gruß (2)")
        #expect(imported[0].id != original.id && imported[0].revision != original.revision)
        #expect(try store.load().first == original)
        #expect(try TextSnippetArchive.decode(TextSnippetArchive.encode(store.load())) == store.load())
    }
    @Test("Importbestätigung übernimmt exakt die gezeigten Namen und weist eine inzwischen geänderte Sammlung ab")
    @MainActor func confirmedImportSnapshot() throws {
        let defaults = testSuiteDefaults(named: "fastra.tests.snippet.confirmed.\(UUID())")
        let store = TextSnippetStore(defaults: defaults), other = TextSnippetStore(defaults: defaults)
        _ = try store.save(TextSnippetDefinition(name: "A", template: "Original"), expectedRevision: nil)
        let data = try TextSnippetArchive.encode([TextSnippetDefinition(name: "A", template: "Neu")])
        let prepared = try store.prepareImport(data)
        #expect(prepared.incoming.map(\.name) == ["A (2)"])
        _ = try other.save(TextSnippetDefinition(name: "A (2)", template: "Fremd"), expectedRevision: nil)
        let before = try store.load()
        #expect(throws: TextSnippetError.self) { try store.importPrepared(prepared) }
        #expect(try store.load() == before)
        let current = try store.prepareImport(data)
        #expect(current.incoming.map(\.name) == ["A (3)"])
        #expect(try store.importPrepared(current) == current.incoming)
        #expect(try store.load() == before + current.incoming)
    }

    @Test("Ungültige und übergroße Importe verändern den Store nicht")
    @MainActor func invalidImportIsAtomic() throws {
        let defaults = testSuiteDefaults(named: "fastra.tests.snippet.invalid.\(UUID())")
        let store = TextSnippetStore(defaults: defaults)
        let original = try store.save(TextSnippetDefinition(name: "A", template: "Original"), expectedRevision: nil)
        var invalid = TextSnippetDefinition(name: "B", template: "{{offen")
        let encoder = JSONEncoder()
        var files = [Data("kein JSON".utf8), Data(repeating: 32, count: TextSnippetArchive.maximumBytes + 1)]
        files.append(try encoder.encode(TextSnippetArchive.Envelope(snippets: [TextSnippetDefinition(name: "OK", template: "OK"), invalid])))
        invalid.template = "OK"; invalid.id = original.id
        files.append(try encoder.encode(TextSnippetArchive.Envelope(snippets: [original, invalid])))
        var newer = TextSnippetArchive.Envelope(snippets: []); newer.schemaVersion = 2
        files.append(try encoder.encode(newer))
        for data in files {
            #expect(throws: TextSnippetError.self) { try store.importDefinitions(data) }
            #expect(try store.load() == [original])
        }
    }
    @Test("Defekter Store wird bei Speichern und Import nicht überschrieben")
    @MainActor func corruptStoreIsPreserved() throws {
        let defaults = testSuiteDefaults(named: "fastra.tests.snippet.corrupt.\(UUID())")
        let broken = Data("broken".utf8); defaults.set(broken, forKey: TextSnippetStore.key)
        let store = TextSnippetStore(defaults: defaults)
        #expect(throws: TextSnippetError.self) { try store.save(TextSnippetDefinition(name: "A", template: "A"), expectedRevision: nil) }
        #expect(throws: TextSnippetError.self) { try store.importDefinitions(TextSnippetArchive.encode([])) }
        #expect(defaults.data(forKey: TextSnippetStore.key) == broken)
    }
    @Test("Sammlungs- und Namensgrenzen sind atomar und lange Konfliktnamen bleiben gültig")
    @MainActor func collectionLimits() throws {
        let defaults = testSuiteDefaults(named: "fastra.tests.snippet.limit.\(UUID())")
        let store = TextSnippetStore(defaults: defaults)
        let definitions = (0..<50).map { TextSnippetDefinition(name: "Name \($0)", template: "Text") }
        _ = try store.importDefinitions(TextSnippetArchive.encode(definitions))
        let before = try store.load()
        #expect(throws: TextSnippetError.self) { try store.save(TextSnippetDefinition(name: "51", template: "Text"), expectedRevision: nil) }
        #expect(throws: TextSnippetError.self) { try store.importDefinitions(TextSnippetArchive.encode([TextSnippetDefinition(name: "51", template: "Text")])) }
        #expect(try store.load() == before)
        let long = String(repeating: "😀", count: 80)
        let name = TextSnippetStore.availableName(long, excluding: [long])
        #expect(name.count == 80 && name.hasSuffix(" (2)"))
        try TextSnippetDefinition(name: name, template: "Text").validate()
        #expect(throws: TextSnippetError.self) { try TextSnippetDefinition(name: "x\n", template: "Text").validate() }
    }

    @Test("Kanonisch gleiches Unicode bleibt für Vorlagenänderungen bytegenau unterscheidbar")
    func exactDefinitionEquality() {
        let first = TextSnippetDefinition(name: "Name", template: "é")
        var changed = first; changed.template = "e\u{301}"
        #expect(first != changed)
    }

}
