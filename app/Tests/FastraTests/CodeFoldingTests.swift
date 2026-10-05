import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import Testing
@testable import Fastra

@Suite("Syntaxbasierte Faltbereiche")
struct CodeFoldingTests {
    @Test("4D erkennt Methoden und unindentierte verschachtelte Zweige mit CRLF und Emoji")
    func fourD() throws {
        let text = "Function run($x : Boolean)\r\nIf ($x)\r\nWhile (True)\r\nALERT(\"😀 End if\")\r\nEnd while\r\nElse\r\nALERT(\"no\")\r\nEnd if\r\nFunction other\r\nALERT(\"done\")\r\n"
        let source = text as NSString
        let folds = FourDFolding.regions(in: text)
        #expect(folds.count == 5)
        try #require(folds.count == 5)
        #expect(folds.map(\.depth) == [1, 2, 3, 3, 1])
        #expect(source.substring(with: folds[2].range).contains("😀 End if"))
        #expect(source.substring(with: folds[0].range).contains("End if"))
        #expect(!source.substring(with: folds[0].range).contains("Function other"))
    }

    @Test("4D ignoriert Kommentare, Strings und SQL-Inhalt; Fehler schließen keine falschen Blöcke")
    func lexicalBoundaries() throws {
        let text = "/*\nIf (True)\nEnd if\n*/\n\"If\"\nBegin SQL\nIf x then\nEnd if\nEnd SQL\nIf (True)\nFor ($i;1;2)\nEnd if\n"
        let folds = FourDFolding.regions(in: text)
        #expect(folds.count == 1)
        try #require(folds.count == 1)
        #expect((text as NSString).substring(with: folds[0].range).contains("If x then"))
    }

    @Test("4D unterstützt alle Blockfamilien und Case-Zweige")
    func families() {
        for (open, close) in [("For each ($x;$xs)", "End for each"), ("For ($i;1;2)", "End for"),
                              ("Repeat", "Until (True)"), ("Use ($x)", "End use"),
                              ("Try", "End try"), ("Case of", "End case")] {
            #expect(FourDFolding.regions(in: "\(open)\nALERT(\"x\")\n\(close)\n").count == 1)
        }
        #expect(FourDFolding.regions(in: "Case of\n: ($x=1)\nALERT(\"a\")\n: ($x=2)\nALERT(\"b\")\nEnd case").count == 3)
        #expect(FourDFolding.regions(in: "Try\nALERT(\"a\")\nCatch\nALERT(\"b\")\nEnd try").count == 2)
        let cases = "Case of\n: ($x=1)\nALERT(\"a\")\n: ($x=2)\nALERT(\"b\")\nElse\nALERT(\"c\")\nEnd case"
        let branches = FourDFolding.regions(in: cases).dropFirst()
        #expect(branches.count == 3)
        #expect(branches.allSatisfy { !(cases as NSString).substring(with: $0.range).contains("Else") })
        #expect(FourDFolding.regions(in: "If (True)\nALERT(\"x\")").isEmpty)
    }

    @Test("Grammatiken liefern vollständige Methoden und If/Else-Körper",
          arguments: ["swift", "javascript", "c", "python"])
    func grammars(name: String) throws {
        let language: CodeLanguage
        let text: String
        switch name {
        case "swift":
            language = .swift
            text = "func run(_ x: Bool) {\nif x {\nprint(\"😀 }\")\n} else {\nprint(\"no\")\n}\n}\n"
        case "javascript":
            language = .javascript
            text = "function run(x) {\nif (x) {\nconsole.log('😀 }');\n} else {\nconsole.log('no');\n}\n}\n"
        case "c":
            language = .c
            text = "void run(int x) {\nif (x) {\nprintf(\"😀 }\");\n} else {\nprintf(\"no\");\n}\n}\n"
        default:
            language = .python
            text = "def run(x):\n    if x:\n        print('😀')\n    else:\n        print('no')\n"
        }
        let folds = SyntaxFolding.regions(in: text, language: language)
        #expect(folds.count == 3, "\(name): \(folds)")
        #expect(folds.first?.depth == 1)
        #expect(folds.dropFirst().allSatisfy { $0.depth == 2 })
        for fold in folds { #expect(fold.range.upperBound <= (text as NSString).length) }
        if name != "python" {
            let broken = text.replacingOccurrences(of: "}\n", with: "\n")
            #expect(SyntaxFolding.regions(in: broken, language: language).isEmpty)
        }
    }
}

@MainActor
private final class DelayedFoldProvider: SnapshotLineFoldProvider {
    var pending: CheckedContinuation<[SourceFoldRegion], Never>?
    var calls = 0
    func foldRegions(in text: String) async -> [SourceFoldRegion] {
        calls += 1
        if calls == 1 { return await withCheckedContinuation { pending = $0 } }
        return FourDFolding.regions(in: text)
    }
    func foldLevelAtLine(lineNumber: Int, lineRange: NSRange, previousDepth: Int,
                         controller: TextViewController) -> [LineFoldProviderLineInfo] { [] }
}

@Suite("Folding im echten CodeEdit-Editor")
@MainActor
struct CodeFoldingIntegrationTests {
    private func editor(_ text: String, provider: LineFoldProvider? = nil) -> TextViewController {
        let controller = TextViewController(string: text, language: .default,
            configuration: .init(appearance: .init(theme: EditorView.fastraTheme,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: true)),
            cursorPositions: [], foldProvider: provider ?? CodeFoldProvider(language: .default, isFourD: true))
        controller.loadView()
        controller.view.frame = CGRect(x: 0, y: 0, width: 760, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    @Test("SourceEditor kann die wiederhergestellte Auswahl vor dem Gutter-Aufbau setzen")
    func cursorBeforeViewLoad() {
        _ = NSApplication.shared
        let controller = TextViewController(string: "If (True)\nEnd if\n", language: .default,
            configuration: .init(appearance: .init(theme: EditorView.fastraTheme,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: true)), cursorPositions: [],
            foldProvider: CodeFoldProvider(language: .default, isFourD: true))
        controller.setCursorPositions([CursorPosition(range: NSRange(location: 3, length: 2))])
        #expect(controller.textView.fastraSafeSelectedRange == NSRange(location: 3, length: 2))
        #expect(controller.fastraFoldRegions.isEmpty)
        controller.loadView()
    }

    @Test("Providerwechsel vor loadView verwendet beim Aufbau den neuen Provider")
    func providerBeforeViewLoad() async {
        _ = NSApplication.shared
        let controller = TextViewController(string: "If (True)\nALERT(\"x\")\nEnd if\n", language: .default,
            configuration: .init(appearance: .init(theme: EditorView.fastraTheme,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: true)), cursorPositions: [])
        controller.setFastraFoldProvider(CodeFoldProvider(language: .default, isFourD: true))
        controller.loadView()
        #expect(await waitUntil { controller.fastraFoldRegions.count == 1 })
    }

    @Test("Ein wartender Snapshot-Provider hält den geschlossenen Editor nicht fest")
    func releaseDuringParse() async {
        let provider = DelayedFoldProvider()
        var controller: TextViewController? = editor("If (True)\nEnd if\n", provider: provider)
        weak var released = controller
        #expect(await waitUntil { provider.pending != nil })
        controller = nil
        #expect(await waitUntil { released == nil })
        provider.pending?.resume(returning: [])
        provider.pending = nil
    }

    @Test("Kind bleibt eingeklappt, wenn der Elternbereich wieder geöffnet wird; Quelle und Undo bleiben unverändert")
    func nesting() async throws {
        let text = "If (True)\r\nWhile (True)\r\nALERT(\"😀\")\r\nEnd while\r\nEnd if\r\n"
        let controller = editor(text)
        #expect(await waitUntil { controller.fastraFoldRegions.count == 2 })
        let parent = try #require(controller.fastraFoldRegions.first)
        let child = try #require(controller.fastraFoldRegions.last)
        controller.setFastraFold(range: child.range, collapsed: true)
        controller.textView.layoutManager.layoutLines()
        let fragments = controller.textView.layoutManager.textLineForOffset(child.range.location)?.data.lineFragments
        #expect(fragments?.contains(where: { fragment in
            fragment.data.contents.contains { content in
                if case let .attachment(box) = content.data { return box.range == child.range }
                return false
            }
        }) == true, "Der gefaltete Body braucht einen gezeichneten/klickbaren Platzhalter")
        controller.setFastraFold(range: parent.range, collapsed: true)
        #expect(controller.textView.layoutManager.attachments.getAttachmentsOverlapping(controller.textView.documentRange).count == 2)
        controller.setFastraFold(range: parent.range, collapsed: false)
        controller.textView.layoutManager.layoutLines()
        #expect(controller.fastraFoldRegions.last?.isCollapsed == true)
        #expect(controller.textView.layoutManager.attachments.getAttachmentsOverlapping(controller.textView.documentRange).count == 1)
        let placeholderRect = try #require(controller.textView.layoutManager.rectForOffset(child.range.location))
        let charWidth = (" " as NSString).size(withAttributes: [.font: controller.textView.font]).width
        let placeholderPoint = CGPoint(x: placeholderRect.minX + charWidth * 2.5, y: placeholderRect.midY)
        #expect(controller.textView.layoutManager.textOffsetAtPoint(placeholderPoint) == child.range.location,
                "Nach Öffnen des Elternbereichs bleibt der Kind-Platzhalter treffbar")
        let body = (text as NSString).range(of: "ALERT").location
        #expect(controller.textView.layoutManager.lineStorage.getLine(atOffset: body)?.height == 0)
        #expect((controller.textView.layoutManager.textLineForOffset(body)?.range.location ?? body) < body)
        #expect(controller.textView.string == text)
        #expect(controller.textView.undoManager?.canUndo != true)
        controller.setFastraFold(range: parent.range, collapsed: true, includeChildren: true)
        controller.setFastraFold(range: parent.range, collapsed: false, includeChildren: true)
        #expect(controller.fastraFoldRegions.allSatisfy { !$0.isCollapsed })
        #expect(controller.textView.string == text)
        controller.unfoldAllFastraFolds()
        controller.setFastraFold(range: parent.range, collapsed: true)
        #expect(controller.fastraFoldRegions.first?.isCollapsed == true,
                "Alles öffnen → sofort schließen darf kein asynchrones Ergebnis benötigen")
    }

    @Test("Platzhalter-Doppelklick öffnet und wählt den gesamten unveränderten Body")
    func placeholderSelection() async throws {
        let text = "If (True)\nWhile (True)\nALERT(\"😀\")\nEnd while\nEnd if\n"
        let controller = editor(text)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        #expect(await waitUntil { controller.fastraFoldRegions.count == 2 })
        let child = try #require(controller.fastraFoldRegions.last)
        controller.setFastraFold(range: child.range, collapsed: true)
        let tv = controller.textView!
        tv.layoutManager.layoutLines()
        let rect = try #require(tv.layoutManager.rectForOffset(child.range.location))
        let charWidth = (" " as NSString).size(withAttributes: [.font: tv.font]).width
        let local = CGPoint(x: rect.minX + charWidth * 2.5, y: rect.midY)
        #expect(tv.layoutManager.textOffsetAtPoint(local) == child.range.location)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: tv.convert(local, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        tv.mouseDown(with: event)
        #expect(tv.fastraSafeSelectedRange == child.range)
        #expect(controller.fastraFoldRegions.last?.isCollapsed == false)
        #expect(tv.string == text && tv.undoManager?.canUndo != true)
    }

    @Test("Ersetzung im geschlossenen Bereich bleibt vollständig rückgängig und wiederholbar")
    func replacementUndoRedo() async throws {
        let text = "If (True)\r\nALERT(\"😀 alt\")\r\nEnd if\r\n"
        let controller = editor(text)
        #expect(await waitUntil { controller.fastraFoldRegions.count == 1 })
        controller.setFastraFold(range: try #require(controller.fastraFoldRegions.first).range, collapsed: true)
        let range = (text as NSString).range(of: "😀 alt")
        controller.textView.replaceCharacters(in: range, with: "neu")
        let changed = text.replacingOccurrences(of: "😀 alt", with: "neu")
        #expect(controller.textView.string == changed)
        #expect(await waitUntil { controller.fastraFoldRegions.count == 1 })
        controller.textView.undoManager?.undo()
        #expect(controller.textView.string == text)
        #expect(await waitUntil { controller.fastraFoldRegions.first?.range == FourDFolding.regions(in: text).first?.range })
        controller.setFastraFold(range: try #require(controller.fastraFoldRegions.first).range, collapsed: true)
        controller.textView.undoManager?.redo()
        #expect(controller.textView.string == changed)
        #expect(await waitUntil { controller.fastraFoldRegions.first?.range == FourDFolding.regions(in: changed).first?.range })
        #expect(controller.textView.layoutManager.attachments.getAttachmentsOverlapping(controller.textView.documentRange).isEmpty)
    }

    @Test("Ein Sprung in ein verstecktes Kind öffnet alle umschließenden Bereiche")
    func jump() async throws {
        let text = "If (True)\nWhile (True)\nALERT(\"x\")\nEnd while\nEnd if\n"
        let controller = editor(text)
        #expect(await waitUntil { controller.fastraFoldRegions.count == 2 })
        for fold in controller.fastraFoldRegions.reversed() { controller.setFastraFold(range: fold.range, collapsed: true) }
        let range = (text as NSString).range(of: "ALERT")
        controller.setCursorPositions([CursorPosition(range: range)])
        #expect(controller.textView.layoutManager.attachments.getAttachmentsOverlapping(controller.textView.documentRange).isEmpty)
        #expect(controller.textView.fastraSafeSelectedRange == range)
        #expect(controller.textView.string == text)
        let parent = try #require(controller.fastraFoldRegions.first)
        controller.setFastraFold(range: parent.range, collapsed: true)
        #expect(controller.fastraFoldRegions.first?.isCollapsed == true)
    }

    @Test("Edits vor, in und über einem gefalteten Bereich halten Ranges gültig",
          arguments: ["before", "inside", "overlap", "replace", "after"])
    func edits(kind: String) async throws {
        let text = "// prefix\nIf (True)\nALERT(\"😀\")\nEnd if\n// suffix\n"
        let controller = editor(text)
        #expect(await waitUntil { controller.fastraFoldRegions.count == 1 })
        let fold = try #require(controller.fastraFoldRegions.first)
        controller.setFastraFold(range: fold.range, collapsed: true)
        let edit: NSRange
        switch kind {
        case "before": edit = NSRange(location: 0, length: 0)
        case "inside": edit = NSRange(location: fold.range.location + 2, length: 1)
        case "overlap": edit = NSRange(location: 0, length: fold.range.location + 4)
        case "replace": edit = NSRange(location: 0, length: (text as NSString).length)
        default: edit = NSRange(location: (text as NSString).length, length: 0)
        }
        let expected = (text as NSString).replacingCharacters(in: edit, with: "// new\n")
        controller.textView.textStorage.replaceCharacters(in: edit, with: "// new\n")
        #expect(controller.fastraFoldRegions.isEmpty, "Sofortiger Klick darf keine alten Bereiche verwenden")
        let expectedFolds = FourDFolding.regions(in: expected)
        #expect(await waitUntil { controller.fastraFoldRegions.map(\.range) == expectedFolds.map(\.range) })
        let attachments = controller.textView.layoutManager.attachments.getAttachmentsOverlapping(controller.textView.documentRange)
        #expect(attachments.count == (kind == "before" || kind == "after" ? 1 : 0))
        for attachment in attachments { #expect(attachment.range.upperBound <= controller.textView.textStorage.length) }
        controller.unfoldAllFastraFolds()
        controller.textView.layoutManager.layoutLines()
        #expect(controller.textView.string == expected)
    }

    @Test("Ein verspätetes Ergebnis der alten Textrevision wird verworfen")
    func staleResult() async {
        let provider = DelayedFoldProvider()
        let old = "If (True)\nALERT(\"old\")\nEnd if\n"
        let controller = editor(old, provider: provider)
        #expect(await waitUntil { provider.pending != nil })
        controller.textView.textStorage.replaceCharacters(in: controller.textView.documentRange, with: "plain\n")
        provider.pending?.resume(returning: FourDFolding.regions(in: old))
        provider.pending = nil
        #expect(await waitUntil { provider.calls == 2 })
        #expect(controller.fastraFoldRegions.isEmpty)
        #expect(controller.textView.string == "plain\n")
    }

    @Test("Geänderter Kopf entfernt verwaiste Platzhalter; neue Tiefe bindet erhaltene Platzhalter neu")
    func structureEdits() async throws {
        let text = "If (True)\nALERT(\"x\")\nEnd if\n"
        let controller = editor(text)
        #expect(await waitUntil { controller.fastraFoldRegions.count == 1 })
        controller.setFastraFold(range: try #require(controller.fastraFoldRegions.first).range, collapsed: true)
        controller.textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "//")
        #expect(await waitUntil {
            controller.textView.layoutManager.attachments.getAttachmentsOverlapping(controller.textView.documentRange).isEmpty
        })
        controller.textView.layoutManager.layoutLines()
        #expect(controller.textView.layoutManager.lineStorage.allSatisfy { $0.height > 0 })

        let nested = editor(text)
        #expect(await waitUntil { nested.fastraFoldRegions.count == 1 })
        nested.setFastraFold(range: try #require(nested.fastraFoldRegions.first).range, collapsed: true)
        nested.textView.textStorage.replaceCharacters(in: NSRange(location: nested.textView.textStorage.length, length: 0), with: "End while\n")
        nested.textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "While (True)\n")
        #expect(await waitUntil { nested.fastraFoldRegions.count == 2 })
        // Ein zusammengefasster Edit darf die Falte sicher öffnen; falls ein
        // Platzhalter erhalten bleibt, muss sein neuer Tiefenwert passen.
        let child = try #require(nested.fastraFoldRegions.last)
        #expect(child.isCollapsed && child.depth == 2)
        nested.setFastraFold(range: child.range, collapsed: true)
        nested.setFastraFold(range: child.range, collapsed: true)
        #expect(nested.textView.layoutManager.attachments.getAttachmentsOverlapping(nested.textView.documentRange).count == 1)
    }

    @Test("Überlappende Löschung gibt auch weit entfernte überlebende Bodyzeilen frei")
    func overlappingDeletionLayout() async throws {
        let prefix = String(repeating: "// prefix\n", count: 15)
        let body = (0..<80).map { "ALERT(\"\($0)\")\n" }.joined()
        let text = prefix + "If (True)\n" + body + "End if\n"
        let controller = editor(text)
        #expect(await waitUntil { controller.fastraFoldRegions.count == 1 })
        controller.setFastraFold(range: try #require(controller.fastraFoldRegions.first).range, collapsed: true)
        let end = (text as NSString).range(of: "ALERT(\"20\")").location
        controller.textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: end), with: "// new\n")
        #expect(await waitUntil {
            controller.textView.layoutManager.attachments.getAttachmentsOverlapping(controller.textView.documentRange).isEmpty
        })
        controller.textView.layoutManager.layoutLines(in: CGRect(x: 0, y: 0, width: 760, height: 3000))
        #expect(controller.textView.layoutManager.lineStorage.allSatisfy { $0.height > 0 })
    }
}
