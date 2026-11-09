import AppKit
import SwiftUI
import Testing
@testable import Fastra

@Suite("Diff-Umbruch im Dokumentfenster", .serialized)
struct DiffWrapLayoutTests {
    @Test("Datei- und Git-Diff erhalten Platz für alle Umbruchfragmente nach Laden, Breitenwechsel und Umschalten", arguments: [false, true])
    @MainActor
    func wrappedFragmentsFitTheirCells(git: Bool) async throws {
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra.tests.diff-wrap.\(UUID())"))
        let long = String(repeating: "Lokale Daten mit äöü, é und 🙂 werden vollständig angezeigt. ", count: 7)
        let lines = (1...27).map { index in
            if index == 8 { return "" }
            if index == 25 { return "https://example.invalid/" + String(repeating: "long-segment/", count: 30) }
            return [3, 26, 27].contains(index) ? "\(index): \(long)" : "Zeile \(index)"
        }
        var patch = "diff --git a/fixture.md b/fixture.md\n--- a/fixture.md\n+++ b/fixture.md\n@@ -1,27 +1,27 @@\n"
        for (index, line) in lines.enumerated() {
            patch += index == 2 ? "-\(line)\n+\(line) neu\n" : " \(line)\n"
        }
        let document = GitDiffParser.parse(Data(patch.utf8))
        let request = GitDiffRequest(repositoryPath: testTemporaryDirectory().path,
                                     source: .unstaged(path: "fixture.md"))
        let source = EditorTab(title: "fixture.md", path: "", content: lines.joined(separator: "\n"))
        let fileRequest = FileDiffRequest(left: .text(lines.joined(separator: "\n"), name: "before.md"),
                                          right: .text(lines.enumerated().map { $0.offset == 2 ? $0.element + " neu" : $0.element }.joined(separator: "\n"), name: "after.md"),
                                          options: FileDiffOptions())
        let fileDocument = Workspace.computeFileDiffDocument(request: fileRequest)
        let tab = git
            ? EditorTab(title: "Git-Diff: fixture.md", path: "Vergleich", gitKind: .diff, gitDiff: GitDiffTabState(request: request))
            : EditorTab(title: "Diff: fixture.md", path: "Vergleich", fileDiff: FileDiffTabState(request: fileRequest))
        workspace.tabs = [source, tab]
        workspace.activeTabID = tab.id
        let host = NSHostingView(rootView: AnyView(EditorView().environmentObject(workspace)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1000),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 0
        window.orderBack(nil)
        defer { window.close() }
        // Das Ergebnis trifft wie im Produkt erst nach dem montierten Ladezustand ein.
        await Task.yield()
        if git { workspace.tabs[1].gitDiff?.document = document }
        else { workspace.tabs[1].fileDiff?.document = fileDocument }
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        func textViews() -> [DiffSelectionTextView] {
            allViews(host).compactMap { $0 as? DiffSelectionTextView }
        }
        func verify(width: CGFloat, wrapped: Bool) throws {
            let views = allViews(host)
            let texts = views.compactMap { $0 as? DiffSelectionTextView }
            let longTexts = texts.filter { $0.string.contains("Lokale Daten") }
            #expect(longTexts.count >= 2, "\(width), wrap=\(wrapped): lange Vergleichszeile fehlt")
            for text in texts {
                let manager = try #require(text.layoutManager)
                let container = try #require(text.textContainer)
                manager.ensureLayout(for: container)
                let used = manager.usedRect(for: container)
                let cell = try #require(views.first {
                    $0.accessibilityIdentifier() == "diffCell-\(text.before ? "before" : "after")-\(text.rowID)"
                })
                let cellFrame = cell.convert(cell.bounds, to: host)
                let drawn = text.convert(used.offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y), to: host)
                #expect(text.bounds.height + 1 >= used.height,
                        "\(width), wrap=\(wrapped), \(text.rowID): Textansicht \(text.bounds), Inhalt \(used)")
                #expect(drawn.minY >= cellFrame.minY - 1 && drawn.maxY <= cellFrame.maxY + 1,
                        "\(width), wrap=\(wrapped), \(text.rowID): Text \(drawn) liegt außerhalb der Zelle \(cellFrame)")
                if wrapped {
                    #expect(used.width <= text.bounds.width + 1)
                }
            }
        }
        var phase = 0
        for scale: CGFloat in [1, 1.5] {
            host.rootView = AnyView(EditorView().environmentObject(workspace).environment(\.uiScale, scale))
            for width: CGFloat in [1100, 760, 1800, 760] {
                window.setContentSize(NSSize(width: width, height: 1000))
                for wrapped in [true, false, true] {
                    workspace.setSoftWrapEnabled(wrapped)
                    let ready = await waitUntil {
                        host.layoutSubtreeIfNeeded()
                        guard let text = textViews().first(where: { $0.string.contains("Lokale Daten") }),
                              let manager = text.layoutManager, let container = text.textContainer else { return false }
                        manager.ensureLayout(for: container)
                        let height = manager.defaultLineHeight(for: text.font!)
                        return wrapped ? text.bounds.height > height * 2 : text.bounds.height < height * 2
                    }
                    if !ready {
                        for text in textViews().filter({ $0.string.contains("Lokale Daten") }) {
                            print("DIFF_WRAP_TIMEOUT phase=\(phase) width=\(width) wrapped=\(wrapped) frame=\(text.frame) container=\(String(describing:text.textContainer?.containerSize)) used=\(String(describing:text.layoutManager.flatMap { lm in text.textContainer.map { lm.usedRect(for:$0) } }))")
                        }
                    }
                    try #require(ready, "phase=\(phase), width=\(width), wrap=\(wrapped)")
                    try await Task.sleep(for: .milliseconds(150))
                    host.layoutSubtreeIfNeeded()
                    if let directory = ProcessInfo.processInfo.environment["FASTRA_DIFF_WRAP_DIR"], wrapped {
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let destination = URL(fileURLWithPath: directory)
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent("diff-wrap-\(git ? "git" : "file")-\(phase)-\(Int(width)).png"))
                    }
                    try verify(width: width, wrapped: wrapped)
                    phase += 1
                }
            }
        }
        #expect(workspace.tabs[0].content == lines.joined(separator: "\n"))
        if git { #expect(workspace.tabs[1].gitDiff?.document == document) }
        else { #expect(workspace.tabs[1].fileDiff?.document == fileDocument) }
    }
}
