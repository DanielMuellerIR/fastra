import AppKit
import Testing
@testable import Fastra

@MainActor
struct TabFileDragTests {
    @Test("Nur gespeicherte Dokumente geben die echte Datei weiter")
    func documentPolicy() {
        let url = URL(fileURLWithPath: "/tmp/Bericht #1 🇩🇪.txt")
        var tab = EditorTab(title: url.lastPathComponent, path: url.path, url: url,
                            content: "ungespeichert", isDirty: true)
        #expect(TabFileDrag.fileURL(for: tab) == url)
        tab.isLoading = true
        #expect(TabFileDrag.fileURL(for: tab) == nil)
        tab.isLoading = false
        tab.externalFileUnavailable = true
        #expect(TabFileDrag.fileURL(for: tab) == nil)
        tab.externalFileUnavailable = false
        tab.url = nil
        #expect(TabFileDrag.fileURL(for: tab) == nil)
        tab.url = URL(string: "https://example.invalid/file")
        #expect(TabFileDrag.fileURL(for: tab) == nil)
        tab.url = url
        tab.gitKind = .commit
        #expect(TabFileDrag.fileURL(for: tab) == nil)
        tab.gitKind = nil
        tab.fileDiff = FileDiffTabState(request: FileDiffRequest(
            left: .file(url), right: .text("anders", name: "Neu"), options: FileDiffOptions()))
        #expect(TabFileDrag.fileURL(for: tab) == nil)
    }

    @Test("Datei-Pasteboard erhält Sonderzeichen und exportiert keine Editoränderung")
    func realFilePasteboard() throws {
        let directory = testTemporaryDirectory().appendingPathComponent("drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Bericht #1 🇩🇪.txt")
        try "Gespeichert".write(to: url, atomically: true, encoding: .utf8)
        let tab = EditorTab(title: url.lastPathComponent, path: url.path, url: url,
                            content: "Andere Editorfassung", isDirty: true)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeObjects([try #require(TabFileDrag.fileURL(for: tab)) as NSURL]))
        let received = (pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
        #expect(pasteboard.types?.contains(.fileURL) == true)
        #expect(received == url)
        #expect(try String(contentsOf: try #require(received), encoding: .utf8) == "Gespeichert")
    }
}
