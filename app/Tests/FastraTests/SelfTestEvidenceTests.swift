import WebKit
import AppKit
import CodeEditTextView
import Testing
@testable import Fastra

@Test("Dauertest-Protokoll erhält frühere Phasen und meldet Schreibfehler")
@MainActor
func soakReportPreservesEarlierPhasesAndReportsWriteFailures() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-soak-report-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("report.log")
    let expected = SoakTest.report() + "\n"
    try SoakTest.appendReport(to: log)
    #expect(try String(contentsOf: log, encoding: .utf8) == expected)
    try SoakTest.appendReport(to: log)
    #expect(try String(contentsOf: log, encoding: .utf8) == expected + expected)

    // Ein Verzeichnis als Datei und ein fehlender Elternordner scheitern auch
    // mit erhöhten Rechten zuverlässig; chmod allein wäre dafür kein Beleg.
    #expect(throws: (any Error).self) {
        try SoakTest.appendReport(to: directory)
    }
    #expect(throws: (any Error).self) {
        try SoakTest.appendReport(to: directory.appendingPathComponent("missing/report.log"))
    }
    #expect(try String(contentsOf: log, encoding: .utf8) == expected + expected)
}

@Test("Dauertest erkennt fremde Änderungen an seiner Textkopie")
@MainActor
func soakCopyEvidenceRejectsForeignPasteboardChanges() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let ownText = "Text aus einem Testdokument"
    try #require(pasteboard.setString(ownText, forType: .string))
    let copy = SoakTest.CopiedText(changeCount: pasteboard.changeCount, text: ownText)
    #expect(copy.isCurrent(in: pasteboard))

    pasteboard.clearContents()
    try #require(pasteboard.setString("fremder Inhalt", forType: .string))
    #expect(!copy.isCurrent(in: pasteboard))

    // Gleicher Text begründet keinen erneuten Besitz: Auch diese Kopie kann
    // aus einer anderen App stammen. Maßgeblich bleibt zusätzlich der Zähler.
    pasteboard.clearContents()
    try #require(pasteboard.setString(ownText, forType: .string))
    #expect(!copy.isCurrent(in: pasteboard))

    let wrongText = SoakTest.CopiedText(changeCount: pasteboard.changeCount,
                                      text: "nicht der kopierte Text")
    #expect(!wrongText.isCurrent(in: pasteboard))
    pasteboard.clearContents()
    try #require(pasteboard.setString("", forType: .string))
    let empty = SoakTest.CopiedText(changeCount: pasteboard.changeCount, text: "")
    #expect(!empty.isCurrent(in: pasteboard))
}

@Test("Ghosttext-Prüfung besteht weder ohne Editor noch ohne gezeichnete Fragmente")
@MainActor
func ghostTextRequiresObservableFragments() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    #expect(SelfTest.ghostViolation(in: root) != nil)

    let editor = TextView(string: "noch nicht ausgelegter Text")
    editor.frame = root.bounds
    root.addSubview(editor)
    #expect(SelfTest.ghostViolation(in: root) == nil)
    // Schon die Größenänderung kann CodeEdit synchron auslegen. Den fehlenden
    // sichtbaren Zustand daher ausdrücklich herstellen, statt ihn zu vermuten.
    func hideFragments(in view: NSView) {
        if view is LineFragmentView { view.isHidden = true }
        view.subviews.forEach { hideFragments(in: $0) }
    }
    hideFragments(in: editor)
    #expect(SelfTest.ghostViolation(in: root) != nil)
}

@Test("Negativsuchtest wartet auf seine eigene tatsächliche Such-Completion")
@MainActor
func emptySearchEvidenceRequiresCompletedCurrentSearch() async throws {
    let workspace = Workspace(defaults: testSuiteDefaults(
        named: "FastraTests.SearchEvidence.\(UUID().uuidString)"))
    workspace.scope = .file
    workspace.useRegex = false
    workspace.tabs[0].content = "vorhandener Text"
    workspace.findPattern = "kein Treffer"
    workspace.showSearchDialog = true

    // Vor dem Debounce sind die alten Ergebnisse ebenfalls leer. Genau dieser
    // Zustand ließ den Selbsttest seine neue Suche bislang sofort überspringen.
    #expect(workspace.bufferMatches.isEmpty)
    #expect(!SelfTest.hasCompletedEmptyBufferSearch(workspace))
    let completed = await waitUntil {
        SelfTest.hasCompletedEmptyBufferSearch(workspace)
    }
    try #require(completed)

    workspace.findPattern = "anderer fehlender Text"
    #expect(!SelfTest.hasCompletedEmptyBufferSearch(workspace))
    let nextCompleted = await waitUntil {
        SelfTest.hasCompletedEmptyBufferSearch(workspace)
    }
    #expect(nextCompleted)
}

@Test("Dauertest erkennt ausgetauschte Fenster auch bei gleicher Anzahl und gleichem Titel",
      arguments: ["same", "rename", "added", "removed", "replaced", "expectedReplacement", "wrongExpectedCount"])
@MainActor
func soakWindowIdentityEvidence(_ mode: String) {
    // IDs genügen: Die geprüfte Invariante arbeitet mit dem fertigen Snapshot,
    // benötigt also weder sichtbare Fenster noch den Fokus des Testhosts.
    let objects = [NSObject(), NSObject()]
    SoakTest.reset()
    defer {
        withExtendedLifetime(objects) {}
        SoakTest.reset()
    }
    func snapshot(_ title: String) -> SoakTest.WindowSnapshot {
        SoakTest.WindowSnapshot(title: title, documentPath: nil,
                               selection: NSRange(location: 0, length: 0), scrollY: 0,
                               textLength: 0, textHash: 0, isEdited: false)
    }
    let first = ObjectIdentifier(objects[0])
    let second = ObjectIdentifier(objects[1])
    let before = [first: snapshot("Dokument")]
    var after = before
    var expectedCount: Int?
    switch mode {
    case "rename": after[first] = snapshot("Neuer Titel")
    case "added": after[second] = snapshot("Zusätzlich")
    case "removed": after = [:]
    case "replaced": after = [second: snapshot("Dokument")]
    case "expectedReplacement":
        after = [second: snapshot("Dokument")]
        expectedCount = 1
    case "wrongExpectedCount": expectedCount = 2
    default: break
    }
    SoakTest.checkNoWindowAppearedOrVanished(before: before, after: after,
                                            expectedWindowCount: expectedCount)
    let shouldFail = ["added", "removed", "replaced", "wrongExpectedCount"].contains(mode)
    #expect(SoakTest.findings.count == (shouldFail ? 1 : 0))
    if mode == "replaced" {
        #expect(SoakTest.findings.first?.detail.contains("aufgetaucht") == true)
        #expect(SoakTest.findings.first?.detail.contains("verschwunden") == true)
    }
}

@Test("Dauertest verlangt abgeschlossene Arbeitsrunden trotz vorhandener Zustandsprüfungen",
      arguments: [false, true])
@MainActor
func soakPhaseRequiresCompletedRounds(_ completeRound: Bool) {
    _ = NSApplication.shared
    SoakTest.reset()
    defer { SoakTest.reset() }
    // Ein echtes Zustands-Check ohne Aktion: genau der Start von Phase 2/3.
    // Eventuelle weitere Befunde der fensterlosen Testumgebung sind hierfür
    // unerheblich; geprüft wird ausschließlich die zusätzliche Rundenabdeckung.
    SoakTest.checkInvariants(action: "nach dem Neustart", before: [:],
                             target: nil, expectedWindowCount: nil)
    #expect(SoakTest.actionsRun == 1)
    #expect(SoakTest.completedRounds == 0)
    if completeRound {
        // Der Rundenabschluss bekommt wie im Treiber den Nachweis der vorher
        // ausgeführten Aktion. Das Testfenster bleibt unsichtbar und ohne Fokus.
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        SoakTest.finishRound(SoakTest.PendingRound(
            label: "markieren", target: window, action: .select, before: [:],
            undoBaseline: nil, pasteboardChangeCount: nil, pasteboardExpectedString: nil))
        #expect(SoakTest.completedRounds == 1)
    }
    SoakTest.validateRoundCoverage()
    let coverageFindings = SoakTest.findings.filter {
        $0.invariant == "Dauertest führt Arbeitsrunden aus"
    }
    #expect(coverageFindings.count == (completeRound ? 0 : 1))
    #expect(SoakTest.report().contains("runden=\(completeRound ? 1 : 0)"))
}

@Test("Dauertest prüft Fenster, Workspace und Editor vor einer Aktion erneut")
@MainActor
func soakActionRequiresCompleteTarget() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                          styleMask: [], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer {
        WorkspaceWindowRegistry.unregister(window)
        window.contentView = nil
        window.close()
    }
    func expectIssue(_ issue: SoakTest.ActionPreparationIssue, in target: NSWindow?) {
        switch SoakTest.actionContext(in: target) {
        case .failure(let actual): #expect(actual == issue)
        case .success: Issue.record("Unvollständiges Aktionsziel wurde akzeptiert")
        }
    }
    expectIssue(.missingWindow, in: nil)
    expectIssue(.missingWorkspace, in: window)
    let workspace = Workspace(defaults: testSuiteDefaults(
        named: "FastraTests.SoakAction.\(UUID().uuidString)"))
    WorkspaceWindowRegistry.register(workspace, for: window)
    expectIssue(.missingEditor, in: window)

    let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    let editor = TextView(string: "Testtext")
    content.addSubview(editor)
    window.contentView = content
    let ready = try SoakTest.actionContext(in: window).get()
    #expect(ready.window === window)
    #expect(ready.workspace === workspace)
    #expect(ready.textView === editor)
    #expect(!window.isVisible)

    // Ein früherer Bereitschaftsnachweis gilt nicht für einen neuen View-Baum.
    editor.removeFromSuperview()
    expectIssue(.missingEditor, in: window)
    WorkspaceWindowRegistry.unregister(window)
    expectIssue(.missingWorkspace, in: window)
}

@Test("Dauertest behält echte Fehler vor und nach Fokusverlust",
      arguments: [false, true])
@MainActor
func soakFocusOutcomePreservesFailures(_ failureFirst: Bool) {
    SoakTest.reset()
    defer { SoakTest.reset() }
    #expect(SoakTest.phaseOutcome == .pass)
    if failureFirst { SoakTest.record("Dateiinhalt", "unerwartet geändert") }
    SoakTest.recordPreparationIssue(.focusUnavailable("active=false"))
    // Fokus kann alle Runden verhindern. Das bleibt ENV, ohne einen zweiten,
    // vermeintlichen Produktfehler für die dann fehlenden Runden zu erfinden.
    SoakTest.validateRoundCoverage()
    #expect(SoakTest.phaseOutcome == (failureFirst ? .fail : .environment))
    #expect(SoakTest.environmentIssues.count == 1)
    #expect(SoakTest.findings.count == (failureFirst ? 1 : 0))
    #expect(SoakTest.report().contains("SOAK-UMGEBUNG "))
    if !failureFirst { #expect(!SoakTest.report().contains("SOAK-BEFUND ")) }
    if !failureFirst { SoakTest.record("Dateiinhalt", "unerwartet geändert") }
    #expect(SoakTest.phaseOutcome == .fail)
    #expect(SoakTest.report().contains("SOAK-BEFUND "))

    SoakTest.reset()
    #expect(SoakTest.phaseOutcome == .pass)
    #expect(SoakTest.environmentIssues.isEmpty)
    SoakTest.recordPreparationIssue(.missingEditor)
    #expect(SoakTest.phaseOutcome == .fail)
}

@Test("Dauertest vergleicht Editor, Modell und die tatsächlichen Dateibytes",
      arguments: ["saved", "editor", "unicode", "missingEditor", "utf16", "bom", "crlf", "dirty", "dirtyMissing", "utf16DirtyMissing"])
@MainActor
func soakChecksVisibleTextAndFileRepresentation(_ mode: String) throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fastra-soak-content-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("document.txt")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                          styleMask: [], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    SoakTest.reset()
    defer {
        SoakTest.reset()
        WorkspaceWindowRegistry.unregister(window)
        window.contentView = nil
        window.close()
        try? FileManager.default.removeItem(at: root)
    }
    var model = "gleich\n"
    var shown = model
    var disk = model
    var encoding = String.Encoding.utf8
    var bom = Data()
    var lineEnding = LineEnding.lf
    switch mode {
    case "editor": shown = "anders\n"
    case "unicode":
        model = "e\u{301}"
        disk = model
        shown = "\u{e9}"  // Gleich aussehende Zeichen sind nicht dieselben UTF-8-Bytes.
    case "utf16", "utf16DirtyMissing":
        encoding = .utf16LittleEndian; bom = Data([0xff, 0xfe])
        if mode == "utf16DirtyMissing" { model = "neuer\n"; shown = model }
    case "bom": bom = Data([0xef, 0xbb, 0xbf])
    case "crlf": disk = "gleich\r\n"; lineEnding = .crlf
    case "dirty", "dirtyMissing": model = "neuer\n"; shown = model
    default: break
    }
    // Bewusst unabhängig vom Save-Encoder: Diese Bytes sind die Vorgabe.
    var bytes = bom
    bytes.append(try #require(disk.data(using: encoding)))
    try bytes.write(to: file)
    let workspace = Workspace(defaults: testSuiteDefaults(
        named: "FastraTests.SoakContent.\(UUID().uuidString)"))
    workspace.tabs[0].url = file
    workspace.tabs[0].content = model
    workspace.tabs[0].encoding = encoding
    workspace.tabs[0].bom = bom
    workspace.tabs[0].lineEnding = lineEnding
    workspace.tabs[0].isDirty = mode == "dirty"
    WorkspaceWindowRegistry.register(workspace, for: window)
    if mode != "missingEditor" { window.contentView = TextView(string: shown) }
    #expect(!window.isVisible)
    let brokenBinding = ["editor", "unicode", "missingEditor"].contains(mode)
    let missingDirtyFlag = ["dirtyMissing", "utf16DirtyMissing"].contains(mode)

    SoakTest.checkDirtyFlagMatchesDisk(window: window)
    #expect(SoakTest.findings.isEmpty == !(brokenBinding || missingDirtyFlag))
    SoakTest.reset()
    SoakTest.checkSaveWroteWindowContent(window: window)
    #expect(SoakTest.findings.isEmpty == !(brokenBinding || mode == "dirty" || missingDirtyFlag))
}


@Test("Kontrastnachweis unterscheidet messbare Farben und unvollständige Messung",
      arguments: ["readable", "low", "unmeasurable", "mixed", "failureAndMissing"])
@MainActor
func contrastEvidenceRequiresMeasuredColors(_ mode: String) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                          styleMask: [], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil; window.close() }
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    window.contentView = root
    let image = NSImage(size: NSSize(width: 1, height: 1))
    let pattern = NSColor(patternImage: image)
    #expect(pattern.usingColorSpace(.sRGB) == nil)
    var colors: [NSColor]
    switch mode {
    case "readable": colors = [.black]
    case "low": colors = [.white]
    case "mixed": colors = [.black, pattern]
    case "failureAndMissing": colors = [.white, pattern]
    default: colors = [pattern]
    }
    let fields = colors.map { color in
        let field = NSTextField(labelWithString: "sichtbarer Testtext")
        field.textColor = color
        root.addSubview(field)
        return field
    }
    let result = SelfTest.contrastEvaluation(fields: fields, windowBackground: .white)
    let expected: SelfTestOutcome = switch mode {
    case "readable": .pass
    case "low", "failureAndMissing": .fail
    default: .environment
    }
    #expect(result.outcome == expected)
    if mode == "unmeasurable" { #expect(result.message.hasPrefix("0 Felder geprüft, 1 Farben")) }
    if mode == "mixed" { #expect(result.message.hasPrefix("1 Felder geprüft, 1 Farben")) }
    #expect(!window.isVisible)
}


@Test("Push-Selbsttest verlangt belegbar fehlende Remote- und Merge-Konfiguration",
      arguments: ["absent", "remotePresent", "mergePresent", "launch", "exit", "stderr", "mergeError", "refMissing"])
func gitPushEvidenceRejectsFailedConfigReads(_ mode: String) {
    let absent = GitResult(exitCode: 1, stdout: "", stderr: "")
    let present = GitResult(exitCode: 0, stdout: "origin\n", stderr: "")
    var ref: GitResult? = GitResult(exitCode: 0, stdout: "abc\n", stderr: "")
    var remote: GitResult? = absent
    var merge: GitResult? = absent
    switch mode {
    case "remotePresent": remote = present
    case "mergePresent": merge = present
    case "launch": remote = nil
    case "exit": remote = GitResult(exitCode: 128, stdout: "", stderr: "")
    case "stderr": remote = GitResult(exitCode: 1, stdout: "", stderr: "Konfigurationsfehler")
    case "mergeError": merge = nil
    case "refMissing": ref = absent
    default: break
    }
    #expect(SelfTest.gitPushWithoutUpstreamSucceeded(
        remoteRef: ref, remoteConfig: remote, mergeConfig: merge
    ) == (mode == "absent"))
}


@Test("Kaltstart verlangt eine volle Ruhephase nach dem ersten korrekten Zustand",
      arguments: ["early", "late", "interrupted", "never"])
func coldOpenEvidenceRequiresContinuousExpectedState(_ mode: String) {
    let samples: [(Int, Bool, Bool)]
    switch mode {
    case "early": samples = [(0, true, false), (19, true, false), (20, true, true)]
    case "late": samples = [(99, false, false), (100, true, false), (119, true, false), (120, true, true)]
    case "interrupted": samples = [(100, true, false), (119, false, false), (120, true, false), (139, true, false), (140, true, true)]
    default: samples = [(0, false, false), (100, false, false), (200, false, false)]
    }
    var stableSinceTick: Int?
    for (tick, expectedState, shouldFinish) in samples {
        #expect(SelfTest.coldOpenStateIsStable(
            expectedState: expectedState, tick: tick, stableSinceTick: &stableSinceTick
        ) == shouldFinish)
    }
}


@Test("Completion-Warteablauf beobachtet Ruhe auch nach hartem Schließen und endet begrenzt",
      arguments: ["absent", "escape", "forced", "persistent", "reappearing"])
func completionClosureRequiresObservedQuietPeriod(_ mode: String) {
    var visible = mode != "absent"
    var now = 0.0
    var reads = 0
    var escapeCount = 0
    var closeCount = 0
    var closedAt: Double?
    var outcome: Bool?
    var completionCount = 0
    var queued: [(Double, () -> Void)] = []
    SelfTest.waitForCompletionPopupClosure(
        isVisible: {
            reads += 1
            // Bei jedem Ruhecheck erscheint es wieder. Der alte Ablauf setzte
            // seinen Zähler dabei immer auf null und beendete sich nie selbst.
            if mode == "reappearing" { return reads % 2 == 0 }
            return visible
        },
        escape: {
            escapeCount += 1
            if mode == "escape" { visible = false }
        },
        forceClose: {
            closeCount += 1
            closedAt = now
            if mode == "forced" { visible = false }
        },
        schedule: { delay, action in queued.append((now + delay, action)) },
        completion: { completionCount += 1; outcome = $0 }
    )
    // Führt die tatsächlich geplanten Callbacks mit einer kontrollierten Uhr
    // aus; keine Wartezeit, Fensteraktivierung oder Kopie des Poll-Algorithmus.
    var steps = 0
    while !queued.isEmpty && steps < 200 {
        let (deadline, action) = queued.removeFirst()
        now = deadline
        action()
        steps += 1
    }
    #expect(outcome == (!["persistent", "reappearing"].contains(mode)))
    #expect(completionCount == 1)
    #expect(now <= 3.05)
    #expect(queued.isEmpty)
    #expect(escapeCount <= 1)
    if mode == "forced", let closedAt {
        #expect(now - closedAt >= 0.3 - 0.000001)
    }
    if mode == "forced" || mode == "persistent" { #expect(closeCount == 1) }
}


@Test("Horizontaler Scrollnachweis verändert das Layout nicht und verlangt Umbruch aus",
      arguments: ["wide", "narrow", "wrap", "noScroller"])
@MainActor
func horizontalScrollEvidenceDoesNotRepairLayout(_ mode: String) {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    scroll.hasHorizontalScroller = mode != "noScroller"
    let text = TextView(string: String(repeating: "lange_Zeile_", count: 150))
    text.wrapLines = mode == "wrap"
    scroll.documentView = text
    // Den beobachteten Zustand gezielt setzen. Die Auswertung darf ihn nicht
    // durch einen eigenen Frame-/Layout-Aufruf vor der Bewertung reparieren.
    text.frame = NSRect(x: 0, y: 0, width: mode == "narrow" ? 500 : 3000, height: 500)
    let before = text.frame
    let result = SelfTest.horizontalScrollEvaluation(textView: text, scrollView: scroll)
    #expect(result.passed == (mode == "wide"))
    #expect(text.frame == before)
}


@Test("Findbar-Nachweis verlangt die eigene Suche statt nur ein fehlendes altes Panel",
      arguments: ["ownSearch", "nothing", "modelOnly", "windowOnly", "oldPanel"])
func findBarEvidenceRequiresSuccessfulSearchRouting(_ mode: String) {
    #expect(SelfTest.findBarObservationPassed(
        editorPanelVisible: mode == "oldPanel",
        searchModelVisible: ["ownSearch", "modelOnly", "oldPanel"].contains(mode),
        searchWindowVisible: ["ownSearch", "windowOnly", "oldPanel"].contains(mode)
    ) == (mode == "ownSearch"))
}


@Test("Markdown-Paste: Nur dekodierte Fixture-Bilder zählen", arguments: ["valid", "broken", "absent"])
@MainActor
func markdownPastePreviewRequiresDecodedImage(_ mode: String) async throws {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 200),
                        configuration: configuration)
    defer { web.stopLoading() }
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let source = mode == "valid" ? png.base64EncodedString() : "bm90IGEgcG5n"
    let image = mode == "absent" ? "" : "<img src=\"data:image/png;base64,\(source)\">"
    // Ausschließlich eingebettete Daten; keine Netzwerkverbindung und kein Fenster.
    web.loadHTMLString("<html><body>\(image)</body></html>", baseURL: nil)
    var loaded = false
    for _ in 0..<100 {
        let complete = try? await web.evaluateJavaScript(
            "document.readyState === 'complete' && Array.from(document.images).every(i => i.complete)"
        )
        if complete as? Bool == true, !web.isLoading {
            loaded = true
            break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    try #require(loaded, "WebView-Fixture wurde nicht fertig geladen")
    let value = try await web.evaluateJavaScript(SelfTest.markdownPastePreviewObservation)
    let pair = try #require(value as? [NSNumber])
    #expect(pair.count == 2)
    #expect(pair.first?.intValue == (mode == "valid" ? 1 : 0))
}


@Test("Emoji-Paste: Vorschau muss alle 13 vollständigen Emojis enthalten",
      arguments: ["missing", "empty", "frozen", "short", "complete", "extra", "bare"])
func emojiPreviewRequiresCompleteSweep(_ mode: String) {
    let shown: String?
    switch mode {
    case "missing": shown = nil
    case "empty": shown = "kein Symbol"
    case "frozen": shown = "⏸️"
    case "short": shown = String(repeating: "⏸️", count: 12)
    case "extra": shown = String(repeating: "⏸️", count: 14)
    case "bare": shown = String(repeating: "⏸️", count: 12) + "⏸"
    default: shown = String(repeating: "⏸️", count: 13)
    }
    #expect(SelfTest.emojiPreviewEvaluation(shown: shown, stepCount: 13).passed
        == (mode == "complete"))
}


@Test("Emoji-Pixel: Fehlende Aufnahme ist kein Farbnachweis",
      arguments: ["missing", "colored", "gray", "transparent"])
@MainActor
func emojiPixelEvidenceDistinguishesMissingCapture(_ mode: String) throws {
    var bitmap: NSBitmapImageRep?
    if mode != "missing" {
        let image = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let color = NSColor(deviceRed: mode == "colored" ? 1 : 0.5,
                            green: mode == "colored" ? 0 : 0.5,
                            blue: mode == "colored" ? 0 : 0.5,
                            alpha: mode == "transparent" ? 0 : 1)
        for x in 0..<2 {
            for y in 0..<2 { image.setColor(color, atX: x, y: y) }
        }
        bitmap = image
    }
    let expected: SelfTestOutcome = mode == "colored" ? .pass
        : mode == "gray" ? .fail : .environment
    #expect(SelfTest.emojiPixelEvaluation(bitmap: bitmap).outcome == expected)
}


@Test("External-Diff-Helfer: Stiller Erfolg, volle Pipe und ignoriertes TERM",
      arguments: ["quiet", "noisy", "ignoresTerm"])
@MainActor
func externalDiffHelperHasBoundedExecution(_ mode: String) async throws {
    let script: String
    switch mode {
    case "quiet": script = "exit 0"
    case "noisy": script = "for i in {1..20000}; do print -r -- 'keine stille Ausgabe'; done"
    default:
        // Kein Kindprozess und kein Busy-Wait: zselect wartet im selben Prozess.
        script = "trap '' TERM; zmodload zsh/zselect; while true; do zselect -t 10; done"
    }
    var errors: [String]?
    let token = SelfTest.runExternalDiffHelper(
        URL(fileURLWithPath: "/bin/zsh"), arguments: ["-f", "-c", script],
        in: FileManager.default.temporaryDirectory
    ) { result in
        DispatchQueue.main.async { errors = result }
    }
    defer { token.cancel() }
    let finished = await waitUntil(timeout: 20) { errors != nil }
    try #require(finished, "Helfer-Completion bleibt aus")
    switch mode {
    case "quiet": #expect(errors == [])
    case "noisy": #expect(errors == ["Helfer bestätigt nicht still mit Exit 0"])
    default: #expect(errors == ["Helfer überschreitet seine Frist"])
    }
}

@Test("TypeScroll-Pixel: Cursor und Oberfläche liefern keinen Textnachweis",
      arguments: ["text", "cursor", "outside", "identical", "sourceChanged", "masked"])
@MainActor
func typeScrollPixelsRequireTextChanges(_ mode: String) throws {
    func png(changed: (Int, Int)?) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
        let black = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
        for x in 0..<20 {
            for y in 0..<20 { bitmap.setColor(white, atX: x, y: y) }
        }
        if let changed { bitmap.setColor(black, atX: changed.0, y: changed.1) }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
    let changed: (Int, Int)? = mode == "text" ? (6, 8)
        : mode == "cursor" ? (8, 8) : mode == "outside" ? (0, 0) : nil
    // Der Inhalt liegt versetzt im Fenster. PNG-y wächst entgegen Fenster-y.
    let frame = NSRect(x: 3, y: 5, width: 20, height: 20)
    let region = NSRect(x: 8, y: 13, width: 8, height: 6)
    let before = SelfTest.TypeScrollSnapshot(data: try png(changed: nil),
                                            windowRect: frame, source: "layer")
    let after = SelfTest.TypeScrollSnapshot(data: try png(changed: changed),
        windowRect: frame, source: mode == "sourceChanged" ? "screen" : "layer")
    let excluded = mode == "masked" ? [region] : [NSRect(x: 10, y: 15, width: 3, height: 3)]
    let result = SelfTest.typeScrollPixelEvaluation(before: before, after: after,
                                                    region: region, excluded: excluded)
    let expected: SelfTestOutcome = mode == "text" ? .pass
        : ["sourceChanged", "masked"].contains(mode) ? .environment : .fail
    #expect(result.outcome == expected)
}

@Test("Screenshot-Fixtures behalten sichtbare Namen ohne fremde Dateien zu verändern")
@MainActor
func screenshotFixtureDirectoriesAreOwned() throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-shot-isolation-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer {
        SelfTest.cleanupScreenshotFixtures()
        try? FileManager.default.removeItem(at: parent)
    }
    let foreignFile = parent.appendingPathComponent("Filmliste.txt")
    let foreignProject = parent.appendingPathComponent("Webseite")
    try Data("vorhandene Datei".utf8).write(to: foreignFile)
    try FileManager.default.createDirectory(at: foreignProject, withIntermediateDirectories: false)
    let sentinel = foreignProject.appendingPathComponent("behalten.txt")
    try Data("vorhandenes Projekt".utf8).write(to: sentinel)

    let first = SelfTest.makeScreenshotFixtureDirectory(in: parent)
    let second = SelfTest.makeScreenshotFixtureDirectory(in: parent)
    let sandbox = parent.appendingPathComponent("runner-tmp")
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: false)
    let fromRunner = SelfTest.makeScreenshotFixtureDirectory(environment: ["TMPDIR": sandbox.path])
    #expect(fromRunner.deletingLastPathComponent().standardizedFileURL == sandbox.standardizedFileURL)
    #expect(first != second)
    for root in [first, second, fromRunner] {
        let file = root.appendingPathComponent("Filmliste.txt")
        try Data("Fixture".utf8).write(to: file)
        #expect(file.lastPathComponent == "Filmliste.txt")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Webseite"),
                                                 withIntermediateDirectories: false)
    }
    SelfTest.cleanupScreenshotFixtures()
    SelfTest.cleanupScreenshotFixtures()
    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(!FileManager.default.fileExists(atPath: second.path))
    #expect(!FileManager.default.fileExists(atPath: fromRunner.path))
    #expect(try Data(contentsOf: foreignFile) == Data("vorhandene Datei".utf8))
    #expect(try Data(contentsOf: sentinel) == Data("vorhandenes Projekt".utf8))
}
