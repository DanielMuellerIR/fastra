import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Testing
@testable import Fastra

private final class HighlightCallbackEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(main: Bool, success: Bool)] = []

    func record(_ result: Result<IndexSet, Error>) {
        let onMain = Thread.isMainThread
        let success: Bool
        if case .success = result { success = true } else { success = false }
        lock.withLock { entries.append((onMain, success)) }
    }

    var snapshot: [(main: Bool, success: Bool)] { lock.withLock { entries } }
}

@Suite("Asynchrone Syntaxänderungen", .serialized)
struct AsyncHighlightEditTests {
    @Test("Asynchrones Edit-Ergebnis kehrt vor jeder Highlight-Mutation auf Main zurück")
    @MainActor
    func asyncEditCompletionRunsOnMain() async throws {
        let original = "{\"value\":\"" + String(repeating: "a", count: 4096) + "\"}"
        let replacement = original.replacingOccurrences(of: "a", with: "b")
        let textView = CodeEditTextView.TextView(string: original)
        let client = TreeSitterClient()
        client.setUp(textView: textView, codeLanguage: .json)

        // Die Query bildet eine öffentliche Barriere hinter dem initialen Parse.
        var ready = false
        client.queryHighlightsFor(textView: textView, range: NSRange(location: 0, length: 1)) { _ in
            ready = true
        }
        try #require(await waitUntil { ready })

        let range = NSRange(location: 0, length: (original as NSString).length)
        #expect(range.length > TreeSitterClient.Constants.maxSyncEditLength)
        client.willApplyEdit(textView: textView, range: range)
        textView.replaceString(in: range, with: replacement)
        let evidence = HighlightCallbackEvidence()
        client.applyEdit(textView: textView, range: range, delta: 0) { result in
            // Die Messung selbst ist verriegelt: Auch der defekte Upstream-
            // Callback darf den Regressionstest ohne weiteren Datenwettlauf melden.
            evidence.record(result)
        }
        try #require(await waitUntil { !evidence.snapshot.isEmpty })
        #expect(evidence.snapshot.allSatisfy { $0.main })
        #expect(evidence.snapshot.contains { $0.success })
        #expect(textView.string == replacement)
    }

    @Test("Wiederholte große JSON-Eingaben und ersetzende Eingaben erhalten Text und Syntaxfarben")
    @MainActor
    func repeatedCompactJSONInsertionKeepsHighlighterStable() async throws {
        // Öffentliche, künstliche Daten; dieselbe insertText-Eingabe wie paste(_:) ohne Clipboard-Eingriff.
        let payload = "{\"number\":42,\"payload\":\"" + String(repeating: "x", count: 217_000) + "\"}\n"
        let configuration = SourceEditorConfiguration(
            appearance: .init(theme: EditorView.fastraTheme,
                              font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                              wrapLines: false, tabWidth: 4),
            peripherals: .init(showMinimap: false)
        )
        let controller = TextViewController(string: "", language: .json,
                                            configuration: configuration, cursorPositions: [])
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        let editor = controller.textView!
        var expected = ""
        for _ in 0..<6 {
            editor.selectionManager.setSelectedRange(NSRange(location: editor.length, length: 0))
            editor.insertText(payload, replacementRange: NSRange(location: NSNotFound, length: 0))
            expected += payload
            #expect(editor.string == expected)
            editor.layoutManager.layoutLines()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(editor.length > TreeSitterClient.Constants.maxSyncContentLength)

        // Der ganze Bereich erzwingt die asynchrone Edit-Route auch unabhängig
        // von einer zufällig noch laufenden vorherigen Parser-Anfrage.
        editor.selectionManager.setSelectedRange(NSRange(location: 0, length: editor.length))
        editor.insertText(payload, replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string == payload)
        editor.layoutManager.layoutLines()

        let client = try #require(controller.treeSitterClient)
        var finalHighlights: [HighlightRange]?
        client.queryHighlightsFor(textView: editor, range: NSRange(location: 0, length: 20)) { result in
            if case .success(let highlights) = result { finalHighlights = highlights }
        }
        try #require(await waitUntil(timeout: 10) { finalHighlights != nil })
        #expect(finalHighlights?.isEmpty == false)
        let numberColor = EditorView.fastraTheme.numbers.color
        try #require(await waitUntil {
            (editor.textStorage.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor)
                == numberColor
        })
        #expect(editor.string == payload)
        #expect(editor.fastraSafeSelectedRange.location <= editor.length)
        withExtendedLifetime(controller) {}
    }
}
