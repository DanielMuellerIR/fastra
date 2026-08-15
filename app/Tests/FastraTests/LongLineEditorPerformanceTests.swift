// LongLineEditorPerformanceTests.swift
//
// Regression für Dateien mit einer einzelnen Base64-artigen Megazeile. Die
// Tests erzeugen ausschließlich künstliche ASCII-Daten und übernehmen keinen
// Inhalt der gemeldeten Datei.

import AppKit
import CodeEditLanguages
import CodeEditTextView
import CoreText
import Testing
@testable import Fastra

private var longLineTestCharacterCount: Int {
    // Standard ist die echte Größenklasse. Die Variable dient nur dazu,
    // denselben Test bei einer gezielten Diagnose kleiner oder größer zu
    // fahren, ohne die prozedurale Fixture umzuschreiben.
    ProcessInfo.processInfo.environment["FASTRA_LONG_LINE_TEST_CHARACTERS"]
        .flatMap(Int.init) ?? DifficultDocumentFixture.targetByteSize
}

@MainActor
private func unwrappedLongLineEditor(characterCount: Int) -> (TextView, NSScrollView) {
    let scrollView = NSScrollView(
        frame: NSRect(x: 0, y: 0, width: 800, height: 600)
    )
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true

    let textView = TextView(
        string: String(repeating: "A", count: characterCount),
        font: .monospacedSystemFont(ofSize: 13, weight: .regular),
        wrapLines: false
    )
    scrollView.documentView = textView
    textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
    textView.layoutManager.layoutLines()
    textView.updateFrameIfNeeded()
    textView.layoutManager.layoutLines()
    return (textView, scrollView)
}

@MainActor
private func wrappedLongLineEditor(characterCount: Int) -> (TextView, NSScrollView) {
    let scrollView = NSScrollView(
        frame: NSRect(x: 0, y: 0, width: 800, height: 600)
    )
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false

    let textView = TextView(
        string: String(repeating: "A", count: characterCount),
        font: .monospacedSystemFont(ofSize: 13, weight: .regular),
        wrapLines: true
    )
    scrollView.documentView = textView
    textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
    textView.layoutManager.layoutLines()
    textView.updateFrameIfNeeded()
    textView.layoutManager.layoutLines()
    return (textView, scrollView)
}

// Derselbe serialisierte Belastungskorpus wie in
// DifficultDocumentCorpusTests: mehrere parallele 4,36-MB-Layouts würden die
// Laufzeitmessungen gegenseitig verfälschen und unnötig viel Speicher binden.
extension DifficultDocumentCorpusTests {
@Test("Dokumenttransformationen blockieren den UI-Thread nicht")
@MainActor
func documentTransformationsRunOutsideTheMainThread() async {
    let operationStarted = DispatchSemaphore(value: 0)
    let mayFinish = DispatchSemaphore(value: 0)
    let clock = ContinuousClock()

    let completion: (value: String, ranOnMainThread: Bool) =
        await withCheckedContinuation { continuation in
            let invocationStart = clock.now
            EditorDocumentTransformationScheduler.run(
                operation: {
                    operationStarted.signal()
                    _ = mayFinish.wait(timeout: .now() + 2)
                    return "fertig"
                },
                completion: { value in
                    continuation.resume(returning: (value, Thread.isMainThread))
                }
            )
            let invocationDuration = invocationStart.duration(to: clock.now)

            #expect(invocationDuration < .milliseconds(100),
                    "Das Einreihen wartete \(invocationDuration) auf die Transformation")
            #expect(operationStarted.wait(timeout: .now() + 1) == .success,
                    "Die Hintergrundtransformation startete nicht")
            mayFinish.signal()
        }

    #expect(completion.value == "fertig")
    #expect(completion.ranOnMainThread,
            "Das Ergebnis muss für die Editoränderung auf den Main-Thread zurückkehren")
}

@Test("Minifizieren nutzt die asynchrone, revisionsgebundene Editortransformation")
@MainActor
func minifyUsesTheAsynchronousEditorTransformation() async throws {
    let suiteName = "fastra-minify-scheduler-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let source = """
    {
      "zebra": 1,
      "adler": [1, 2, 3]
    }
    """
    let workspace = Workspace(defaults: defaults)
    let tab = EditorTab(
        title: "gross.json",
        path: "—",
        content: source
    )
    workspace.tabs = [tab]
    workspace.activeTabID = tab.id

    let textView = TextView(string: source)
    let controller = NSViewController()
    controller.view = textView
    let window = NSWindow(contentViewController: controller)
    WorkspaceWindowRegistry.register(workspace, for: window)
    defer {
        WorkspaceWindowRegistry.unregister(window)
        window.close()
    }

    EditorContextMenu().minify(on: textView)
    #expect(textView.string == source,
            "Die Hintergrundtransformation darf nicht noch im Aufruf anwenden")

    let expected = #"{"adler":[1,2,3],"zebra":1}"#
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while textView.string != expected && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(textView.string == expected)
}

@Test("TXT öffnet eine Megazeile standardmäßig mit Soft Wrap am Fensterrand")
@MainActor
func workspaceKeepsSoftWrapAvailableForLongLine() {
    let suiteName = "fastra-long-line-wrap-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let workspace = Workspace(
        defaults: defaults,
        softWrapProfiles: SoftWrapProfileStore(defaults: defaults)
    )
    let tab = EditorTab(
        title: "daten.txt",
        path: "—",
        content: String(repeating: "A", count: 512 * 1024)
    )
    workspace.tabs = [tab]
    workspace.activeTabID = tab.id

    #expect(workspace.activeDocumentFormat.id == .plainText)
    #expect(workspace.configuredSoftWrapEnabled)
    #expect(workspace.softWrapEnabled)
    #expect(workspace.softWrapTarget == .window)
    #expect(workspace.effectiveSoftWrapColumn == nil)

    workspace.toggleSoftWrap()
    #expect(!workspace.softWrapEnabled)
    workspace.toggleSoftWrap()
    #expect(workspace.softWrapEnabled)

    workspace.setLanguageOverride(.json)
    #expect(workspace.activeDocumentFormat.id == .grammar(.json))
    #expect(workspace.activeDocumentFormattingID == .grammar(.json))
    #expect(workspace.softWrapEnabled,
            "Die gemerkte JSON-Wahl darf Soft Wrap der TXT-Megazeile nicht abschalten")
    #expect(workspace.softWrapTarget == .window)
    #expect(workspace.effectiveSoftWrapColumn == nil)
}

@Test("Megazeile ohne Soft Wrap erzeugt nur eine Fragment-View")
@MainActor
func unwrappedLongLineHasBoundedViewCount() {
    let (textView, _) = unwrappedLongLineEditor(
        characterCount: longLineTestCharacterCount
    )
    let fragmentViewCount = textView.subviews
        .compactMap { $0 as? LineFragmentView }.count
    #expect(fragmentViewCount <= 2,
            "Es wurden \(fragmentViewCount) Fragment-Views erzeugt")
}

@Test("Megazeile mit Soft Wrap öffnet schnell und erzeugt nur sichtbare Views")
@MainActor
func wrappedLongLineStaysResponsiveAndScrolls() throws {
    let clock = ContinuousClock()
    let start = clock.now
    let (textView, scrollView) = wrappedLongLineEditor(
        characterCount: longLineTestCharacterCount
    )
    let duration = start.duration(to: clock.now)

    let initialRange = try #require(textView.visibleTextRange)
    let initialViews = textView.subviews
        .compactMap { $0 as? LineFragmentView }.count
    #expect(duration < .seconds(2),
            "Soft-Wrap-Layout brauchte \(duration)")
    #expect(initialViews < 100,
            "Es wurden \(initialViews) Fragment-Views erzeugt")

    let middleY = max(0, textView.layoutManager.estimatedHeight() / 2)
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: middleY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    textView.layoutManager.layoutLines(in: NSRect(
        x: 0,
        y: middleY,
        width: scrollView.contentView.bounds.width,
        height: scrollView.contentView.bounds.height
    ))

    let scrolledFragmentViews = textView.subviews
        .compactMap { $0 as? LineFragmentView }
        .filter { !$0.isHidden && $0.lineFragment != nil }
    let retainedFragmentViews = textView.subviews
        .compactMap { $0 as? LineFragmentView }.count
    #expect(scrollView.contentView.bounds.minY > 0,
            "Der Test hat nicht wirklich gescrollt")
    #expect(scrolledFragmentViews.contains {
        ($0.lineFragment?.documentRange.location ?? 0) > initialRange.location
    }, "Die sichtbaren Fragment-Views folgten dem Scrollen nicht")
    #expect(scrolledFragmentViews.count < 100,
            "Nach dem Scrollen waren \(scrolledFragmentViews.count) Fragment-Views sichtbar")
    #expect(retainedFragmentViews < 200,
            "Die Wiederverwendung hielt \(retainedFragmentViews) Fragment-Views vor")
}

@Test("Highlighter sieht horizontal nur den Bildschirmausschnitt der Megazeile")
@MainActor
func unwrappedLongLineReportsHorizontalVisibleRange() throws {
    let characterCount = 512 * 1024
    let (textView, _) = unwrappedLongLineEditor(characterCount: characterCount)
    let visible = try #require(textView.visibleTextRange)

    #expect(visible.location == 0)
    #expect(visible.length < 4 * 1024,
            "Sichtbarer Bereich umfasst fälschlich die ganze Langzeile: \(visible)")
}

@Test("Interne Langzeilen-Segmente trennen keine Unicode-Zeichen")
@MainActor
func unwrappedSegmentsPreserveComposedCharacters() throws {
    let family = "👨‍👩‍👧‍👦"
    let content = String(repeating: "A", count: 16 * 1024 - 1)
        + family
        + String(repeating: "B", count: 16 * 1024)
    let scrollView = NSScrollView(
        frame: NSRect(x: 0, y: 0, width: 800, height: 600)
    )
    let textView = TextView(
        string: content,
        font: .monospacedSystemFont(ofSize: 13, weight: .regular),
        wrapLines: false
    )
    scrollView.documentView = textView
    textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
    textView.layoutManager.layoutLines()

    let fragmentView = try #require(
        textView.subviews.compactMap { $0 as? LineFragmentView }.first
    )
    let fragment = try #require(fragmentView.lineFragment)
    let textRanges = fragment.contents.compactMap { content -> NSRange? in
        guard case .text(let line) = content.data else { return nil }
        let range = CTLineGetStringRange(line)
        return NSRange(location: range.location, length: range.length)
    }
    let familyRange = (content as NSString).range(of: family)

    #expect(textRanges.count >= 2)
    #expect(fragment.documentRange.length == (content as NSString).length)
    #expect(!textRanges.dropLast().contains { range in
        range.max > familyRange.location && range.max < familyRange.max
    })
}

@Test("Der sichtbare Teil einer Megazeile wird in begrenzter Zeit gezeichnet")
@MainActor
func unwrappedLongLineDrawingStaysBounded() throws {
    let (textView, _) = unwrappedLongLineEditor(
        characterCount: longLineTestCharacterCount
    )
    let rect = NSRect(x: 0, y: 0, width: 800, height: 600)
    let bitmap = try #require(textView.bitmapImageRepForCachingDisplay(in: rect))
    let clock = ContinuousClock()
    let start = clock.now
    textView.cacheDisplay(in: rect, to: bitmap)
    let duration = start.duration(to: clock.now)

    #expect(duration < .seconds(1),
            "Zeichnen des sichtbaren Ausschnitts brauchte \(duration)")
}
}
