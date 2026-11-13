import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Testing
@testable import Fastra

@MainActor
private final class MinimapQueryRecorder: HighlightProviding {
    var queries: [NSRange] = []
    func setUp(textView: TextView, codeLanguage: CodeLanguage) {}
    func willApplyEdit(textView: TextView, range: NSRange) {}
    func applyEdit(textView: TextView, range: NSRange, delta: Int,
                   completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void) {
        completion(.success(IndexSet()))
    }
    func queryHighlightsFor(textView: TextView, range: NSRange,
                            completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void) {
        queries.append(range)
        completion(.success([]))
    }
    var queried: IndexSet {
        var result = IndexSet()
        for range in queries { result.insert(integersIn: range.location..<range.upperBound) }
        return result
    }
}

@Suite("Sichtbare Minimap-Bereiche", .serialized)
struct MinimapVisibleRangeTests {
    @MainActor
    private func fixture(source: String, wrap: Bool) throws -> (NSWindow, TextViewController, MinimapView, MinimapQueryRecorder) {
        let provider = MinimapQueryRecorder()
        let configuration = SourceEditorConfiguration(
            appearance: .init(theme: EditorView.fastraTheme,
                              font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                              wrapLines: wrap, tabWidth: 4),
            peripherals: .init(showMinimap: true)
        )
        let controller = TextViewController(string: source, language: .json,
                                            configuration: configuration, cursorPositions: [],
                                            highlightProviders: [provider])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        controller.textView.layoutManager.layoutLines()
        func find(_ view: NSView) -> MinimapView? {
            if let mini = view as? MinimapView { return mini }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let mini = try #require(find(controller.view))
        mini.contentView.layoutSubtreeIfNeeded()
        return (window, controller, mini, provider)
    }

    @MainActor
    private func visibleFragments(_ mini: MinimapView) -> [LineFragmentView] {
        mini.contentView.subviews.compactMap { $0 as? LineFragmentView }
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.intersects(mini.contentView.visibleRect) && $0.lineFragment != nil }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    @MainActor
    private func diagnose(_ label: String, controller: TextViewController, mini: MinimapView,
                          provider: MinimapQueryRecorder, watched: Int) {
        let views = mini.contentView.subviews.compactMap { $0 as? LineFragmentView }
        let visible = visibleFragments(mini)
        let ranges = mini.visibleTextRanges
        let frames = visible.prefix(2).map { "\($0.frame):\(String(describing: $0.lineFragment?.documentRange))" }
            + visible.suffix(2).map { "\($0.frame):\(String(describing: $0.lineFragment?.documentRange))" }
        if views.count <= 4 {
            for view in views {
                guard let fragment = view.lineFragment else { continue }
                print("MINIMAP_VIEW frame=\(view.frame) hidden=\(view.isHidden) range=\(fragment.documentRange) width=\(fragment.width) height=\(fragment.height)/\(fragment.scaledHeight) fixed=\(fragment.fastraHasFixedCells) contents=\(fragment.contents.count) first=\(fragment.contents.first?.width ?? -1)/\(fragment.contents.first?.length ?? -1)")
            }
        }
        print("MINIMAP_DIAG phase=\(label) windowVisible=\(controller.view.window?.isVisible == true) editorClip=\(String(describing: controller.textView.enclosingScrollView?.contentView.bounds)) editorHeight=\(controller.textView.frame.height) miniFrame=\(mini.frame) miniClip=\(mini.scrollView.contentView.bounds) miniContent=\(mini.contentView.frame) contentVisible=\(mini.contentView.visibleRect) needsLayout=\(mini.contentView.needsLayout) views=\(views.count) hidden=\(views.filter { $0.isHiddenOrHasHiddenAncestor }.count) visible=\(visible.count) first=\(String(describing: ranges.first)) last=\(String(describing: ranges.last)) queryCount=\(provider.queries.count) queryMax=\(provider.queries.map { $0.upperBound }.max() ?? -1) watched=\(watched) covered=\(provider.queried.contains(watched)) frames=\(frames)")
    }

    @Test("Megazeile fragt nur sichtbare Miniaturfragmente an und färbt nach echtem Scrollen bis zum letzten Fragment")
    @MainActor
    func wrappedMegabyteMinimapQueriesFollowVisibleFragments() async throws {
        let source = "{\"payload\":\"" + String(repeating: "a", count: 3_000_000) + "\"}"
        let (window, controller, mini, provider) = try fixture(source: source, wrap: true)
        defer { window.contentViewController = nil; window.close() }
        try #require(await waitUntil {
            mini.contentView.layoutSubtreeIfNeeded()
            return visibleFragments(mini).count > 5 && !provider.queries.isEmpty
        })
        func drawnPrefix(_ view: LineFragmentView) -> NSRange? {
            guard let fragment = view.lineFragment else { return nil }
            let right = min(view.frame.maxX, mini.contentView.visibleRect.maxX) - view.frame.minX
            let count = min(fragment.documentRange.length, max(1, Int(ceil((right - 8) / 1.5))))
            return NSRange(location: fragment.documentRange.location, length: count)
        }
        let lastView = try #require(visibleFragments(mini).last)
        let expected = try #require(drawnPrefix(lastView))
        let firstEnd = expected.upperBound
        let visible = mini.visibleTextRanges
        #expect(visible.contains { NSIntersectionRange($0, expected) == expected })
        try #require(await waitUntil {
            IndexSet(integersIn: expected.location..<expected.upperBound).isSubset(of: provider.queried)
        })
        #expect(provider.queried.count < source.utf16.count / 8)

        let firstQueriedEnd = provider.queried.last ?? firstEnd
        let scroll = try #require(controller.textView.enclosingScrollView)
        let before = scroll.contentView.bounds.minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: before + 30_000))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.minY > before + 100)
        let scrolledReady = await waitUntil {
            controller.view.layoutSubtreeIfNeeded()
            mini.contentView.layoutSubtreeIfNeeded()
            guard let last = visibleFragments(mini).last,
                  let expected = drawnPrefix(last) else { return false }
            return expected.upperBound > firstQueriedEnd
                && IndexSet(integersIn: expected.location..<expected.upperBound).isSubset(of: provider.queried)
        }
        if !scrolledReady {
            diagnose("wrapped-after-wait", controller: controller, mini: mini, provider: provider,
                     watched: (visibleFragments(mini).last?.lineFragment?.documentRange.upperBound ?? 1) - 1)
        }
        try #require(scrolledReady)
        let scrolledLast = try #require(visibleFragments(mini).last)
        let scrolledExpected = try #require(drawnPrefix(scrolledLast))
        #expect(mini.visibleTextRanges.contains { NSIntersectionRange($0, scrolledExpected) == scrolledExpected })
        #expect(provider.queried.count < source.utf16.count / 8)
        #expect(controller.textView.string == source)
    }

    @Test("Ungebrochene Megazeile fragt nur die horizontal sichtbare Miniatur und die folgende sichtbare Zeile an")
    @MainActor
    func unwrappedMinimapKeepsDisjointHorizontalRanges() async throws {
        let source = "start\n" + String(repeating: "a", count: 3_000_000) + "\nend"
        let (window, controller, mini, provider) = try fixture(source: source, wrap: false)
        defer { window.contentViewController = nil; window.close() }
        let tail = (source as NSString).length - 1
        let unwrappedReady = await waitUntil {
            mini.contentView.layoutSubtreeIfNeeded()
            return visibleFragments(mini).count >= 3 && provider.queried.contains(tail)
        }
        if !unwrappedReady {
            diagnose("unwrapped-after-wait", controller: controller, mini: mini, provider: provider, watched: tail)
        }
        try #require(unwrappedReady)
        let view = try #require(visibleFragments(mini).first {
            ($0.lineFragment?.documentRange.length ?? 0) > 1_000_000
        })
        let fragment = try #require(view.lineFragment)
        let range = try #require(mini.visibleTextRanges.first {
            NSIntersectionRange($0, fragment.documentRange).length > 0
        })
        #expect(range.location == fragment.documentRange.location)
        // Die verifizierte Monospace-Miniatur zeichnet exakt 1,5 pt je ASCII-Zeichen.
        // Die rechte Clipkante ist deshalb ein unabhängiger Wächter gegen einen
        // willkürlichen Zeichen-Cutoff oder eine um eins zu kurze Highlight-Range.
        let clippedRight = mini.contentView.visibleRect.maxX - view.frame.minX
        let coveredRight = 8 + CGFloat(range.upperBound - fragment.documentRange.location) * 1.5
        #expect(coveredRight >= clippedRight)
        #expect(coveredRight < clippedRight + 5)
        #expect(mini.visibleTextRanges.contains { NSLocationInRange(tail, $0) })
        #expect(provider.queried.count < source.utf16.count / 100)
        #expect(!provider.queried.contains(fragment.documentRange.location + 1_000_000))
        #expect(controller.textView.string == source)
    }
    @Test("Umbruchwechsel veröffentlicht vor dem neuen Layout keine vollständige Megazeile")
    @MainActor
    func wrapTransitionKeepsStaleUnwrappedFragmentsBounded() throws {
        let source = "{\"blob\":\"" + String(repeating: "a", count: 3_000_000) + "\"}"
        let (window, controller, mini, _) = try fixture(source: source, wrap: false)
        defer { window.contentViewController = nil; window.close() }
        let editor = controller.textView!
        let line = try #require(editor.layoutManager.lineStorage.first)
        #expect(line.data.lineFragments.count == 1)
        try #require(visibleFragments(mini).contains { ($0.lineFragment?.documentRange.length ?? 0) >= 3_000_000 })
        editor.wrapLines = true
        // Der neue Wert ist bereits sichtbar, die alten Fragmente sind bis
        // zum naechsten Layout noch ungebrochen. Genau dann feuern Observer.
        #expect(line.data.lineFragments.count == 1)
        let editorRanges = editor.visibleTextRanges
        let miniRanges = mini.visibleTextRanges
        #expect(!editorRanges.isEmpty && !miniRanges.isEmpty)
        #expect(editorRanges.reduce(0) { $0 + $1.length } <= 16 * 1024)
        #expect(miniRanges.reduce(0) { $0 + $1.length } < 1024)
        editor.updateFrameIfNeeded()
        editor.layoutManager.layoutLines()
        #expect(line.data.lineFragments.count > 1)
        #expect(editor.visibleTextRanges.reduce(0) { $0 + $1.length } < source.utf16.count / 8)
        #expect(editor.string == source)
    }

    @Test("Bidi, Emoji und kombinierte Zeichen behalten im ungebrochenen CoreText-Pfad vollständige Farben")
    @MainActor
    func unwrappedGeneralCoreTextKeepsCompleteFragmentCoverage() async throws {
        let source = String(repeating: "אבג😀e\u{0301} text ", count: 250)
        let (window, controller, mini, provider) = try fixture(source: source, wrap: false)
        defer { window.contentViewController = nil; window.close() }
        try #require(await waitUntil { !visibleFragments(mini).isEmpty && !provider.queries.isEmpty })
        let fragment = try #require(visibleFragments(mini).first?.lineFragment)
        #expect(!fragment.fastraHasFixedCells)
        #expect(mini.visibleTextRanges.contains {
            NSIntersectionRange($0, fragment.documentRange) == fragment.documentRange
        })
        try #require(await waitUntil { provider.queried.contains(fragment.documentRange.upperBound - 1) })
        #expect(controller.textView.string == source)
    }

}
