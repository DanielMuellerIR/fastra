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

@Test("Langzeilen-Schwelle unterscheidet Megazeile von großer normaler Datei")
func longLinePolicyDetectsOnlyIndividualLongLines() {
    let limit = LongLinePerformancePolicy.wrappedLineLimit
    #expect(LongLinePerformancePolicy.requiresSoftWrapSuppression(
        in: String(repeating: "A", count: limit)
    ))
    #expect(!LongLinePerformancePolicy.requiresSoftWrapSuppression(
        in: String(repeating: "A", count: limit - 1)
    ))
    #expect(!LongLinePerformancePolicy.requiresSoftWrapSuppression(
        in: String(repeating: "A\n", count: limit)
    ))
}

@Test("FileLoader meldet eine kritische Langzeile bereits im Hintergrundpfad")
func fileLoaderReportsPerformanceCriticalLongLine() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-long-line-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(
        repeating: 0x41,
        count: LongLinePerformancePolicy.wrappedLineLimit
    ).write(to: url)

    let loaded = try FileLoader.load(url: url)
    #expect(loaded.displayMode == .text)
    #expect(loaded.hasPerformanceCriticalLongLine)
}

@Test("Plain Text setzt Soft Wrap nur für das betroffene Langzeilen-Dokument aus")
@MainActor
func workspaceSuppressesSoftWrapForLongLine() {
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
        content: String(
            repeating: "A",
            count: LongLinePerformancePolicy.wrappedLineLimit
        )
    )
    workspace.tabs = [tab]
    workspace.activeTabID = tab.id

    #expect(workspace.configuredSoftWrapEnabled)
    #expect(workspace.softWrapSuppressedForLongLine)
    #expect(!workspace.softWrapEnabled)

    workspace.setLanguageOverride(.json)
    #expect(workspace.activeDocumentFormat.id == .grammar(.json))
    #expect(workspace.activeDocumentFormattingExtension == "json")
    #expect(!workspace.softWrapEnabled)
    #expect(workspace.softWrapSuppressedForLongLine)
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
