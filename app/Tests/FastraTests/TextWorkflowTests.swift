import Foundation
import AppKit
import CodeEditTextView
import SwiftUI
import Testing
@testable import Fastra

@Suite("Gespeicherte Textabläufe: Grundlage")
struct TextWorkflowTests {
    @Test("Schritte bauen aufeinander auf und lassen Original und Auswahlrand erhalten")
    func sequence() throws {
        var prefix = TextWorkflowStep(kind: .prefixLines); prefix.argument = "> "
        let flow = TextWorkflow(name: "Liste", steps: [TextWorkflowStep(kind: .sortAscending), TextWorkflowStep(kind: .removeDuplicateLines), prefix])
        let source = "Davor 😀\r\nb\r\na\r\nb\r\nDanach"
        let range = (source as NSString).range(of: "b\r\na\r\nb")
        let preview = try TextWorkflowEngine.preview(flow, source: source, selection: range)
        #expect(preview.output == "Davor 😀\r\n> a\r\n> b\r\nDanach")
        #expect(preview.steps.count == 3)
        #expect(preview.steps[1].before == preview.steps[0].after)
        #expect(preview.source == source && preview.range == range)
    }

    @Test("Ausdrücklich eingefügte Zeilenenden in Parametern bleiben erhalten")
    func explicitEnding() throws {
        var suffix = TextWorkflowStep(kind: .suffixLines); suffix.argument = "\r\n"
        let value = try TextWorkflowEngine.preview(TextWorkflow(name: "Suffix", steps: [suffix]), source: "a")
        #expect(value.output.utf8.elementsEqual("a\r\n".utf8))
    }

    @Test("Wirkungslose Zeilenschritte vereinheitlichen keine gemischten Endungen", arguments: [
        TextWorkflowStep.Kind.hardWrap, .removeBlankLines, .removeDuplicateLines, .keepLinesMatching, .deleteLinesMatching
    ])
    func unchangedLineStepsPreserveEndings(_ kind: TextWorkflowStep.Kind) throws {
        var step = TextWorkflowStep(kind: kind)
        step.argument = kind == .keepLinesMatching ? "." : "never"
        let source = "a\r\nb\nc\rd"
        let preview = try TextWorkflowEngine.preview(TextWorkflow(name: "Unverändert", steps: [step]), source: source)
        #expect(preview.output.utf8.elementsEqual(source.utf8))
        #expect(!preview.changed)
    }

    @Test("Bestehende Textoperationen besitzen dauerhafte Ablaufkennungen")
    func operationCoverage() {
        let existing = Set(TextOpKind.allCases.map { String(describing: $0) })
        let persisted = Set(TextWorkflowStep.Kind.allCases.compactMap { $0.textOperation == nil ? nil : $0.rawValue })
        #expect(existing == persisted)
    }

    @Test("Regex, Wildcards und Case-Operatoren verwenden die bestehende Suchsemantik", arguments: [false, true])
    func replacement(_ regex: Bool) throws {
        var step = TextWorkflowStep(kind: .replace)
        step.find = regex ? "([a-z]+)=(\\d+)" : "*=*"
        step.replacement = regex ? "\\U$1\\E:$2" : "*:*"
        step.regex = regex
        let flow = TextWorkflow(name: "Suchen", steps: [step])
        let source = "abc=12\ndef=34"
        let expected = try #require(BufferSearch.replaceAll(in: source, options: step.searchOptions))
        let result = try TextWorkflowEngine.preview(flow, source: source)
        #expect(result.output == expected)
        #expect(result.steps[0].matches == 2)
    }

    @Test("Exakte Unicode-Änderungen und wirkungslose Schritte bleiben unterscheidbar")
    func unicode() throws {
        let flow = TextWorkflow(name: "Unicode", steps: [TextWorkflowStep(kind: .precomposeUnicode), TextWorkflowStep(kind: .precomposeUnicode)])
        let result = try TextWorkflowEngine.preview(flow, source: "e\u{301}")
        #expect(result.changed && result.steps[0].changed && !result.steps[1].changed)
        #expect(result.output.utf8.elementsEqual("é".utf8))
    }

    @Test("Schreibende Vorschau zeigt Unicode-Schreibweise und Zeilenenden als echte Änderungen")
    func exactDiff() throws {
        let before = "caf\u{E9}\r\nx\ty\r\n", after = "cafe\u{301}\nx   y\n"
        let diff = try TextWorkflowDiff.build(before: before, after: after)
        let result = try #require(diff.document.result)
        #expect(!result.isIdentical && diff.hasAnnotations)
        #expect(result.rows[0].kind == .changed)
        #expect(result.rows[0].before?.contains("\\u{E9}") == true)
        #expect(result.rows[0].after?.contains("\\u{301}") == true)
        #expect(result.rows[0].before?.contains("⟦CRLF⟧") == true && result.rows[0].after?.contains("⟦LF⟧") == true)
        #expect(result.rows[1].before?.contains("\\u{9}") == true)
        let plain = try TextWorkflowDiff.build(before: "abc\n", after: "def\n")
        #expect(!plain.hasAnnotations && plain.document.result?.rows[0].before == "abc")
        #expect(throws: TextWorkflowError.sizeLimit) { try TextWorkflowDiff.build(before: before, after: after, maximumDisplayBytes: 10) }
    }

    @Test("Das gemeinsame Vorschau-Budget zählt beide Diff-Spalten samt Unicode-Markierungen")
    func totalDiffBudget() throws {
        let before = "é\n", after = "e\n"
        let complete = try TextWorkflowDiff.build(before: before, after: after)
        let rows = try #require(complete.document.result?.rows)
        let bytes = rows.reduce(0) { $0 + ($1.before?.utf8.count ?? 0) + ($1.after?.utf8.count ?? 0) }
        let exact = try TextWorkflowDiff.build(before: before, after: after, maximumTotalDisplayBytes: bytes)
        #expect(exact.document == complete.document)
        #expect(throws: TextWorkflowError.sizeLimit) {
            try TextWorkflowDiff.build(before: before, after: after, maximumTotalDisplayBytes: bytes - 1)
        }
        #expect(throws: TextWorkflowError.sizeLimit) {
            try TextWorkflowDiff.build(before: "abc\n", after: "def\n", maximumTotalDisplayBytes: 5)
        }
    }

    @Test("Einseitige Ablaufänderungen zeigen Steuerzeichen und exakte Zeilenenden", arguments: [false, true])
    func oneSidedDiff(_ deletion: Bool) throws {
        let short = "a\n", long = "a\nb\r\n\u{200B}\n"
        let diff = try TextWorkflowDiff.build(before: deletion ? long : short, after: deletion ? short : long)
        let result = try #require(diff.document.result)
        let displays = result.rows.filter { deletion ? $0.after == nil : $0.before == nil }.compactMap { deletion ? $0.before : $0.after }
        #expect(diff.hasAnnotations)
        #expect(displays.contains { $0.contains("⟦CRLF⟧") })
        #expect(displays.contains { $0.contains("\\u{200B}") && $0.contains("⟦LF⟧") })
        #expect(throws: TextWorkflowError.sizeLimit) {
            try TextWorkflowDiff.build(before: deletion ? long : short, after: deletion ? short : long, maximumDisplayBytes: 8)
        }
    }

    @Test("Hard Wrap reagiert innerhalb einer großen zulässigen Eingabe auf Abbruch")
    func cancelDuringHardWrap() throws {
        var step = TextWorkflowStep(kind: .hardWrap); step.wrapColumn = 10_000
        let workflow = TextWorkflow(name: "Wrap", steps: [step])
        let source = String(repeating: "a ", count: 2 * 1024 * 1024 - 1)
        var checks = 0
        #expect(throws: TextWorkflowError.cancelled) {
            try TextWorkflowEngine.preview(workflow, source: source, shouldCancel: { checks += 1; return checks == 8 })
        }
        #expect(checks == 8)
    }

    @Test("Ungültige Schritte werden auch nach gültigen Schritten vor jeder Ausgabe verworfen")
    func invalidInput() throws {
        var step = TextWorkflowStep(kind: .replace); step.regex = true; step.find = "["
        let flow = TextWorkflow(name: "Ungültig", steps: [TextWorkflowStep(kind: .uppercase), step])
        #expect(throws: TextWorkflowError.self) { try TextWorkflowEngine.preview(flow, source: "abc") }
        let valid = TextWorkflow(name: "Auswahl", steps: [TextWorkflowStep(kind: .uppercase)])
        for selection in [NSRange(location: NSNotFound, length: 1), NSRange(location: 1, length: 1), NSRange(location: 0, length: 0), NSRange(location: 0, length: Int.max)] {
            #expect(throws: TextWorkflowError.invalidSelection) { try TextWorkflowEngine.preview(valid, source: "😀x", selection: selection) }
        }
    }

    @Test("Größen-, Treffer- und Abbruchgrenzen liefern keine Teilvorschau")
    func limits() throws {
        var step = TextWorkflowStep(kind: .replace); step.find = "x"; step.replacement = "xx"
        let flow = TextWorkflow(name: "Grenze", steps: [step])
        var limits = TextWorkflowEngine.Limits.standard; limits.textBytes = 5
        #expect(throws: TextWorkflowError.sizeLimit) { try TextWorkflowEngine.preview(flow, source: "xxx", limits: limits) }
        limits.textBytes = 100; limits.matches = 2
        #expect(throws: TextWorkflowError.matchLimit) { try TextWorkflowEngine.preview(flow, source: "xxx", limits: limits) }
        #expect(throws: TextWorkflowError.cancelled) { try TextWorkflowEngine.preview(flow, source: "xxx", shouldCancel: { true }) }
        limits.seconds = -1
        #expect(throws: TextWorkflowError.timeout) { try TextWorkflowEngine.preview(flow, source: "xxx", limits: limits) }
    }

    @Test("Backref-Budget prüft tatsächlich referenzierte Gruppen, Escapes und Mehrfachreferenzen")
    func replacementBudget() throws {
        var step = TextWorkflowStep(kind: .replace); step.regex = true; step.find = "(a)(b+)"; step.replacement = "$1"
        let source = "a" + String(repeating: "b", count: 1000)
        var limits = TextWorkflowEngine.Limits.standard; limits.intermediateBytes = 4
        #expect(try TextWorkflowEngine.preview(TextWorkflow(name: "Klein", steps: [step]), source: source, limits: limits).output == "a")
        step.replacement = "$2$2"
        #expect(throws: TextWorkflowError.sizeLimit) { try TextWorkflowEngine.preview(TextWorkflow(name: "Groß", steps: [step]), source: source, limits: limits) }
        step.replacement = "\\$2"
        #expect(try TextWorkflowEngine.preview(TextWorkflow(name: "Literal", steps: [step]), source: source, limits: limits).output == "$2")
    }

    @Test("Archive bleiben begrenzt und weisen unbekannte Versionen zurück")
    func archive() throws {
        let flow = TextWorkflow(name: "Test", steps: [TextWorkflowStep(kind: .uppercase)])
        let data = try TextWorkflowArchive.encode([flow])
        #expect(try TextWorkflowArchive.decode(data) == [flow])
        #expect(throws: TextWorkflowError.invalidArchive) { try TextWorkflowArchive.decode(Data("{\"schemaVersion\":2,\"workflows\":[]}".utf8)) }
        #expect(throws: TextWorkflowError.sizeLimit) { try TextWorkflowArchive.decode(Data(repeating: 0, count: TextWorkflowArchive.maximumBytes+1)) }
    }

    @Test("Zwei Fenster führen Änderungen zusammen und schützen überholte Bearbeitung")
    @MainActor
    func persistence() throws {
        let domain = "fastra-test-workflow-store-" + UUID().uuidString, defaults = testSuiteDefaults(named: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = TextWorkflowStore(defaults: defaults), second = TextWorkflowStore(defaults: defaults)
        let a = try first.save(TextWorkflow(name: "A", steps: [TextWorkflowStep(kind: .uppercase)]), expectedRevision: nil)
        let b = try second.save(TextWorkflow(name: "B", steps: [TextWorkflowStep(kind: .lowercase)]), expectedRevision: nil)
        var edited = a; edited.name = "Neu"
        let saved = try first.save(edited, expectedRevision: a.revision)
        #expect(try second.load().map(\.name) == ["Neu", "B"])
        #expect(throws: TextWorkflowError.staleDefinition) { try second.save(edited, expectedRevision: a.revision) }
        try second.remove(id: b.id, expectedRevision: b.revision)
        #expect(try first.load() == [saved])
        let imported = try first.importDefinitions(TextWorkflowArchive.encode([saved]))
        #expect(imported[0].id != saved.id && imported[0].steps[0].id != saved.steps[0].id)
        defaults.set(Data("kaputt".utf8), forKey: TextWorkflowStore.key)
        #expect(throws: TextWorkflowError.invalidArchive) { try second.save(edited, expectedRevision: saved.revision) }
        #expect(defaults.data(forKey: TextWorkflowStore.key) == Data("kaputt".utf8))
        defaults.set("falscher Typ", forKey: TextWorkflowStore.key)
        #expect(throws: TextWorkflowError.invalidArchive) { try first.load() }
        #expect(defaults.string(forKey: TextWorkflowStore.key) == "falscher Typ")
    }

    @Test("Vorschau bleibt nach Metadaten-Speichern gültig; neue Eingaben und fremde Inhalte entwerten sie")
    @MainActor
    func previewSession() async throws {
        let domain = "fastra-test-workflow-session-" + UUID().uuidString, defaults = testSuiteDefaults(named: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let workspace = Workspace(defaults: defaults)
        let tab = EditorTab(title: "test.txt", path: "", content: "abc  \n")
        workspace.tabs = [tab]; workspace.activeTabID = tab.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer { WorkspaceWindowRegistry.unregister(window); window.close() }
        let snapshot = TextWorkflowDocumentSnapshot(tabID: tab.id, documentID: tab.documentID, url: nil,
            revision: tab.contentRevision, source: tab.content, selection: NSRange(location: 0, length: 3), windowID: ObjectIdentifier(window))
        let session = TextWorkflowSession(snapshot: snapshot, workspace: workspace, store: TextWorkflowStore(defaults: defaults))
        #expect(session.save())
        session.calculate()
        try #require(await waitUntil { session.preview != nil && session.diffDocument != nil })
        #expect(session.preview?.output == "abc\n" && session.canApply)
        session.definition.name = "Neu benannt"
        #expect(session.preview != nil && !session.canApply)
        #expect(session.save())
        #expect(session.preview != nil && session.canApply)
        let closing = TextWorkflowSession(snapshot: snapshot, workspace: workspace, store: TextWorkflowStore(defaults: defaults))
        closing.calculate()
        try #require(await waitUntil { closing.canApply })
        closing.cancel()
        #expect(!closing.canApply)
        session.definition.steps[0].kind = .uppercase
        #expect(session.preview == nil && !session.canApply)
        session.calculate()
        workspace.tabs[0].content = "Fremd"
        try #require(await waitUntil { !session.isBusy })
        #expect(session.preview == nil && session.error == TextWorkflowSession.staleMessage)
        session.cancel()
    }

    @Test("Angewendeter Dokumentablauf bleibt über den nativen Editor-Verlauf rückgängig und wiederholbar")
    @MainActor
    func nativeApplyHistory() async throws {
        let domain = "fastra-test-workflow-history-" + UUID().uuidString
        let defaults = testSuiteDefaults(named: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let workspace = Workspace(defaults: defaults)
        let source = "b  \na  \n", expected = "B\nA\n"
        let tab = EditorTab(title: "test.txt", path: "", content: source)
        workspace.tabs = [tab]; workspace.activeTabID = tab.id
        let host = NSHostingView(rootView: EditorView().environmentObject(workspace))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        WorkspaceWindowRegistry.register(workspace, for: window)
        defer { WorkspaceWindowRegistry.unregister(window); window.close() }
        window.alphaValue = 0
        window.orderBack(nil)
        try #require(await waitUntil { CommandTargeting.editorTextView(for: workspace)?.string == source })
        let editor = try #require(CommandTargeting.editorTextView(for: workspace))
        let snapshot = TextWorkflowDocumentSnapshot(tabID: tab.id, documentID: tab.documentID, url: nil,
            revision: tab.contentRevision, source: source, selection: NSRange(location: 0, length: 0), windowID: ObjectIdentifier(window))
        let session = TextWorkflowSession(snapshot: snapshot, workspace: workspace, store: TextWorkflowStore(defaults: defaults))
        defer { session.cancel() }
        session.definition.steps = [TextWorkflowStep(kind: .trimTrailing), TextWorkflowStep(kind: .uppercase)]
        workspace.textWorkflowSession = session
        try #require(session.save())
        session.calculate()
        try #require(await waitUntil { session.canApply })
        try #require(session.apply())
        #expect(editor.string == expected && workspace.activeTab?.content == expected)
        let history = try #require(editor.undoManager)
        try #require(history.canUndo)
        history.undo()
        try #require(await waitUntil { workspace.activeTab?.content == source && history.canRedo })
        #expect(editor.string == source)
        history.redo()
        try #require(await waitUntil { workspace.activeTab?.content == expected && history.canUndo })
        #expect(editor.string == expected)
    }

    @Test("Verspätete Feldbindungen folgen Schritt- und Definitionsidentität statt Arraypositionen")
    @MainActor
    func delayedBindings() throws {
        let domain = "fastra-test-workflow-bindings-" + UUID().uuidString, defaults = testSuiteDefaults(named: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let workspace = Workspace(defaults: defaults), window = NSWindow()
        let tab = EditorTab(title: "test.txt", path: "", content: "abc")
        let snapshot = TextWorkflowDocumentSnapshot(tabID: tab.id, documentID: tab.documentID, url: nil,
            revision: tab.contentRevision, source: tab.content, selection: NSRange(location: 0, length: 0), windowID: ObjectIdentifier(window))
        let session = TextWorkflowSession(snapshot: snapshot, workspace: workspace, store: TextWorkflowStore(defaults: defaults))
        let first = TextWorkflowStep(kind: .prefixLines), second = TextWorkflowStep(kind: .suffixLines)
        session.definition.steps = [first, second]
        let binding = session.binding(for: first)
        session.definition.steps.swapAt(0, 1)
        var edited = binding.wrappedValue; edited.argument = "Anfang"
        binding.wrappedValue = edited
        #expect(session.definition.steps[0].argument.isEmpty)
        #expect(session.definition.steps[1].argument == "Anfang")
        session.definition.steps.removeLast()
        edited.argument = "verspätet"; binding.wrappedValue = edited
        #expect(session.definition.steps.count == 1 && session.definition.steps[0].argument.isEmpty)
        let name = session.nameBinding
        session.new()
        let current = session.definition.name
        name.wrappedValue = "altes Feld"
        #expect(session.definition.name == current)
        session.cancel()
    }
}
