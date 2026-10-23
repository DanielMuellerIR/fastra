import Foundation
import Testing
@testable import Fastra

@Suite("Lokale Markdown-Verweise")
struct MarkdownReferencesTests {
    @Test("Nur echte a-Elemente erzeugen benannte HTML-Anker", arguments: ["article", "abbr", "a-custom", "a:custom"])
    func similarHTMLTagIsNotAnchor(_ tag: String) throws {
        let source = MarkdownReferenceCheck.Source(url: nil, title: "doc.md",
            content: "<\(tag) name=\"ziel\"></\(tag)>\n\n[Link](#ziel)\n")
        let result = try MarkdownReferenceCheck.check(document: source)
        #expect(result.findings.first?.status == .missing)
        let valid = try MarkdownReferences.parse("<A name=\"ziel\"></A>\n")
        #expect(valid.anchors["ziel"] == 1)
    }

    @Test("Leere Slugs verschleiern keine abgeschnittene Überschriftenanalyse")
    func emptySlugsExhaustHeadingBudget() throws {
        let source = String(repeating: "# !\n", count: 10_001) + "# Ziel\n\n[Link](#ziel)\n"
        let parsed = try MarkdownReferences.parse(source)
        #expect(parsed.incomplete && !parsed.anchorsComplete)
        let result = try MarkdownReferenceCheck.check(document: .init(url: nil, title: "doc.md", content: source))
        #expect(!result.isComplete)
        #expect(result.findings.first?.status == .unverified)
    }

    @Test("cmark löst Referenzlinks auf und lässt Code und Kommentare aus")
    func smallestProbe() throws {
        let source = "# Gleich\r\n\r\n# Gleich\r\n\r\n[Datei][ziel]\r\n![Bild](image%23one.png)\r\n\r\n[ziel]: <über%20uns.md#teil>\r\n\r\n<a href=\"other.md#html\">HTML</a>\r\n<!-- <img src=\"ignored.png\"> -->\r\n\r\n```md\r\n[Code](ignored.md)\r\n```\r\n"
        let parsed = try MarkdownReferences.parse(source)
        #expect(parsed.references.map(\.destination) == ["über%20uns.md#teil", "image%23one.png", "other.md#html"])
        #expect(parsed.references.map(\.line) == [5, 6, 10])
        #expect(parsed.anchors["gleich"] == 2)
        #expect(!parsed.incomplete && !parsed.unsupportedHTML)
    }

    @Test("Pfad und Fragment werden vor dem Decodieren getrennt")
    func encodedPaths() {
        let base = URL(fileURLWithPath: "/tmp/doc.md")
        #expect(MarkdownReferences.destination("image%23one.png#%C3%BCber", documentURL: base) == .local(URL(fileURLWithPath: "/tmp/image#one.png"), anchor: "über"))
        #expect(MarkdownReferences.destination("https://example.invalid/a.md#x", documentURL: base) == .remote)
        #expect(MarkdownReferences.destination("file://server/a.md", documentURL: base) == .remote)
        #expect(MarkdownReferences.destination("bad%ZZ.md", documentURL: base) == .invalid)
        #expect(MarkdownReferences.destination("file:///tmp/a%00b.md", documentURL: base) == .invalid)
    }

    @Test("Nicht unterstützte HTML-Inhalte liefern keine erfundenen Verweise")
    func opaqueHTML() throws {
        let parsed = try MarkdownReferences.parse("<script>\nconst sample = '<a href=\"imaginary.md\">';\n</script>\n\n<style>\n/* <img src=\"imaginary.png\"> */\n</style>\n")
        #expect(parsed.references.isEmpty)
        #expect(parsed.unsupportedHTML)
    }

    @Test("Ankerprüfung erklärt gleiche Überschriften, fehlende und HTML-Ziele")
    func anchors() throws {
        let source = MarkdownReferenceCheck.Source(url: nil, title: "Untitled", content: "# Gleich\n\n## Gleich\n\n# Einmal\n\n<a id=\"html\"></a>\n\n[a](#gleich) [b](#einmal) [c](#html) [d](#fehlt) [e](https://example.invalid)\n")
        let report = try MarkdownReferenceCheck.check(document: source)
        #expect(report.isComplete)
        #expect(report.findings.map(\.status) == [.ambiguous, .valid, .valid, .missing])
        #expect(report.remoteCount == 1)
        #expect(report.sources.first?.content.utf8.elementsEqual(source.content.utf8) == true)
    }

    @Test("Lokale codierte Datei-, Bild-, Referenz- und Symlinkziele bleiben rein lesend")
    func localTargets() throws {
        try fixture { root in
            let target = root.appendingPathComponent("über # eins.md")
            var bytes = Data([0xff, 0xfe]); bytes.append("# Titel\r\n".data(using: .utf16LittleEndian)!)
            try bytes.write(to: target)
            let image = root.appendingPathComponent("bild#1.png")
            try Data([0, 255, 2]).write(to: image)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.md"), withDestinationURL: target)
            let document = MarkdownReferenceCheck.Source(url: root.appendingPathComponent("doc.md"), title: "doc.md",
                content: "[x][ref]\n![Bild](bild%231.png)\n[Link](link.md#titel)\n[Fehlt](missing/sub.md)\n\n[ref]: <%C3%BCber%20%23%20eins.md#titel>\n")
            let report = try MarkdownReferenceCheck.check(document: document)
            #expect(report.isComplete)
            #expect(report.findings.map(\.status) == [.valid, .valid, .valid, .missing])
            #expect(try Data(contentsOf: target) == bytes)
            #expect(try Data(contentsOf: image) == Data([0, 255, 2]))
        }
    }

    @Test("Projekt nutzt offene Fassungen, vorhandene Ausschlüsse und eine feste Dateigrenze")
    func project() throws {
        try fixture { root in
            let current = root.appendingPathComponent("current.md"), other = root.appendingPathComponent("other.md")
            try Data("[Other](other.md#neu)\n".utf8).write(to: current)
            try Data("# Alt\n".utf8).write(to: other)
            try Data("[X](missing.md)".utf8).write(to: root.appendingPathComponent(".hidden.md"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
            try Data("[X](missing.md)".utf8).write(to: root.appendingPathComponent("build/ignored.md"))
            let source = MarkdownReferenceCheck.Source(documentID: UUID(), url: current, title: "current.md", content: "[Other](other.md#neu)\n")
            let opened = MarkdownReferenceCheck.Source(documentID: UUID(), url: other.canonicalFileURL, title: "other.md", content: "# Neu\n")
            var options = MarkdownReferenceCheck.Options(); options.excludedPatterns = ["build"]
            let report = try MarkdownReferenceCheck.check(document: source, openDocuments: [opened], project: root, options: options)
            #expect(report.isComplete && report.sources.count == 2)
            #expect(report.findings.map(\.status) == [.valid])
            options.maximumFiles = 1
            let capped = try MarkdownReferenceCheck.check(document: source, project: root, options: options)
            #expect(!capped.isComplete && capped.sources.count == 1)
        }
    }

    @Test("Abbruch, Verweisgrenze und Lesebudget ergeben keine vollständige Freigabe")
    func limits() throws {
        let source = MarkdownReferenceCheck.Source(url: nil, title: "doc.md", content: "[a](#x) [b](#x)\n\n# X\n")
        #expect(throws: CancellationError.self) { try MarkdownReferenceCheck.check(document: source, isCancelled: { true }) }
        var options = MarkdownReferenceCheck.Options(); options.maximumReferences = 1
        let capped = try MarkdownReferenceCheck.check(document: source, options: options)
        #expect(!capped.isComplete && capped.findings.count == 1)
        options.maximumBytes = 2
        let budget = try MarkdownReferenceCheck.check(document: source, options: options)
        #expect(!budget.isComplete && budget.sources.isEmpty)
    }

    @Test("Ungespeicherte relative und nicht unterstützte HTML-Ziele bleiben sichtbar ungeprüft")
    func unsupported() throws {
        let source = MarkdownReferenceCheck.Source(url: nil, title: "Untitled", content: "[rel](file.md)\n\n<img srcset=\"one.png 1x\" src=\"two.png\">\n")
        let report = try MarkdownReferenceCheck.check(document: source)
        #expect(!report.isComplete)
        #expect(report.findings.count == 2)
        #expect(report.findings.allSatisfy { $0.status == .unverified })
        #expect(!report.issues.isEmpty)
    }

    @Test("Nicht unterstützte HTML-Anker dürfen nicht als fehlend behauptet werden")
    func unsupportedAnchor() throws {
        let source = MarkdownReferenceCheck.Source(url: nil, title: "Untitled", content: "<div id=unquoted></div>\n\n[Anker](#unquoted)\n")
        let report = try MarkdownReferenceCheck.check(document: source)
        #expect(!report.isComplete)
        #expect(report.findings.map(\.status) == [.unverified])
    }

    @Test("Auch nicht dekodierbare Projektquellen verbrauchen das Lesebudget")
    func failedReadBudget() throws {
        try fixture { root in
            for name in ["a.md", "b.md", "c.md"] { try Data([0, 1, 2, 3, 4, 5]).write(to: root.appendingPathComponent(name)) }
            try Data().write(to: root.appendingPathComponent("doc.md"))
            let source = MarkdownReferenceCheck.Source(url: root.appendingPathComponent("doc.md"), title: "doc.md", content: "")
            var options = MarkdownReferenceCheck.Options(); options.maximumBytes = 6
            let report = try MarkdownReferenceCheck.check(document: source, project: root, options: options)
            #expect(!report.isComplete && report.readBytes == 6)
            #expect(report.sources.count == 1)
        }
    }

    @Test("Paket-Ausschluss gilt auch unter der Dateisystemwurzel")
    func rootPackageExclusion() throws {
        try fixture { root in
            let package = root.appendingPathComponent("Fixture.app/Contents/a.md")
            try FileManager.default.createDirectory(at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: package)
            var local = FolderSearch.PackageMembershipCache(root: root)
            let containedLocally = local.contains(package)
            #expect(containedLocally)
            var filesystem = FolderSearch.PackageMembershipCache(root: URL(fileURLWithPath: "/"))
            let containedFromRoot = filesystem.contains(package)
            #expect(containedFromRoot)
        }
    }

    @Test("Gekappte Ankerlisten und viele Umbruchzeichen sind keine fehlenden Anker")
    func anchorLimits() throws {
        let parsed = try MarkdownReferences.parse("# Eins\n\n# Zwei\n\n[a](#zwei)\n", maximumAnchors: 1)
        #expect(!parsed.anchorsComplete && parsed.incomplete)
        #expect(parsed.anchors.count == 1 && parsed.anchorCount == 1)
        #expect(throws: CocoaError.self) { try MarkdownReferences.parse(String(repeating: "\n", count: 200_001)) }
    }

    @Test("Abgebrochene alte Generation kann keine neuere Prüfung überschreiben")
    @MainActor func generations() async throws {
        let workspace = Workspace()
        var tab = EditorTab(title: "doc.md", path: "doc.md", content: "[Alt](#alt)\n")
        tab.markdownVisualOverride = false
        workspace.tabs = [tab]; workspace.activeTabID = tab.id
        let controller = workspace.markdownReferences
        controller.present(in: workspace); controller.start(in: workspace, project: false)
        controller.cancel()
        workspace.tabs[0].content = "# Neu\n\n[Neu](#neu)\n"
        controller.start(in: workspace, project: false)
        #expect(await waitUntil { !controller.running })
        #expect(controller.report?.findings.map(\.status) == [.valid])
        #expect(controller.report?.sources.first?.content == workspace.tabs[0].content)
        controller.close()
        #expect(!controller.isPresented && !controller.running)
    }

    @Test("Zur Quelle verlässt WYSIWYG und schützt geänderte oder geschlossene Dokumente")
    @MainActor func sourceJump() async throws {
        let workspace = Workspace()
        var tab = EditorTab(title: "doc.md", path: "doc.md", content: "# Titel\n\n[Fehlt](#weg)\n")
        tab.markdownVisualOverride = true
        workspace.tabs = [tab]; workspace.activeTabID = tab.id
        let controller = workspace.markdownReferences
        controller.present(in: workspace); controller.start(in: workspace, project: false)
        #expect(await waitUntil { !controller.running })
        let finding = try #require(controller.report?.findings.first)
        controller.jump(to: finding, in: workspace)
        #expect(!workspace.activeMarkdownIsVisual)
        #expect(workspace.pendingEditorJump?.documentID == tab.documentID)
        #expect(workspace.pendingEditorJump?.range?.location == "# Titel\n\n".utf16.count)
        controller.present(in: workspace); controller.start(in: workspace, project: false)
        #expect(await waitUntil { !controller.running })
        let stale = try #require(controller.report?.findings.first)
        #expect(!controller.hasChanged(in: workspace))
        workspace.tabs[0].url = URL(fileURLWithPath: "/tmp/renamed.md")
        #expect(controller.hasChanged(in: workspace))
        workspace.tabs[0].url = tab.url
        workspace.tabs[0].content = "# Geändert\n"
        workspace.pendingEditorJump = nil
        controller.jump(to: stale, in: workspace)
        #expect(workspace.pendingEditorJump == nil && controller.notice != nil)
        workspace.tabs = []
        controller.jump(to: stale, in: workspace)
        #expect(workspace.tabs.isEmpty)
        controller.close()
    }

    @Test("Mountgrenzen und lokale Symlinks werden ohne Netzfixture geprüft")
    func mountGuard() throws {
        try fixture { root in
            let canonical = root.canonicalFileURL
            let remote = canonical.appendingPathComponent("remote")
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            let link = canonical.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: remote)
            let guardPaths = LocalMarkdownPath(mounts: [.init(path: "/", isLocal: true), .init(path: remote.path, isLocal: false)])
            #expect(!guardPaths.isLocal(remote.appendingPathComponent("missing.md").path))
            #expect(guardPaths.isLocal(canonical.appendingPathComponent("remote-other.md").path))
            #expect(throws: CocoaError.self) { try guardPaths.resolve(link.appendingPathComponent("missing.md")) }
            let local = LocalMarkdownPath()
            let resolved = try local.resolve(link)
            #expect(FileIdentity(url: resolved) != nil)
            #expect(FileIdentity(url: resolved) == FileIdentity(url: remote))
            let cycle = canonical.appendingPathComponent("cycle")
            try FileManager.default.createSymbolicLink(at: cycle, withDestinationURL: cycle)
            #expect(throws: POSIXError.self) { try local.resolve(cycle) }
        }
    }

    @Test("Eine ausdrücklich als Markdown geprüfte Quelle braucht keine Markdown-Endung")
    func explicitFormat() throws {
        try fixture { root in
            let url = root.appendingPathComponent("text.txt")
            try Data("# Alt\n".utf8).write(to: url)
            let source = MarkdownReferenceCheck.Source(url: url, title: "text.txt", content: "# Neu\n\n[Selbst](text.txt#neu)\n")
            let report = try MarkdownReferenceCheck.check(document: source)
            #expect(report.findings.map(\.status) == [.valid])
        }
    }

    @Test("Zu große Ankerziele liefern eine verständliche Grenze ohne internen Fehlernamen")
    func largeTargetMessage() throws {
        try fixture { root in
            let target = root.appendingPathComponent("large.md")
            #expect(FileManager.default.createFile(atPath: target.path, contents: Data()))
            let handle = try FileHandle(forWritingTo: target)
            try handle.truncate(atOffset: UInt64(MarkdownReferences.maximumSourceBytes + 1))
            try handle.close()
            let source = MarkdownReferenceCheck.Source(url: root.appendingPathComponent("doc.md"), title: "doc.md", content: "[Groß](large.md#x)\n")
            let report = try MarkdownReferenceCheck.check(document: source)
            #expect(!report.isComplete && report.findings.first?.status == .unverified)
            #expect(report.findings.first?.message.contains("FileSnapshotReadError") == false)
            #expect(report.readBytes == source.content.utf8.count)
        }
    }

    @Test("Dollarzeichen in echten Linkzielen bleiben erhalten, Formeln liefern keine Scheinverweise")
    func dollarDestinations() throws {
        let source = "[Dollar](file$x$.md)\n[Referenz][r]\n\n[r]: ref$y$.md\n\n<img src=\"image$z$.png\">\n\n$x+[Fake](phantom.md)$\n\n$$\n[Fake](other.md)\n$$\n"
        let parsed = try MarkdownReferences.parse(source)
        #expect(parsed.references.map(\.destination) == ["file$x$.md", "ref$y$.md", "image$z$.png"])
    }

    @Test("Ein Elternsprung hinter einem Symlink folgt derselben Zielbasis wie die Vorschau")
    func symlinkParentSemantics() throws {
        try fixture { root in
            let deep = root.appendingPathComponent("sub/deep")
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            let physical = root.appendingPathComponent("sub/target.md")
            try Data("# Physical\n".utf8).write(to: physical)
            try Data("# Root\n".utf8).write(to: root.appendingPathComponent("target.md"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: deep)
            let input = root.appendingPathComponent("link/../target.md", isDirectory: false)
            let expected = FileIdentity(url: input.standardizedFileURL)
            #expect(expected == FileIdentity(url: physical))
            let resolved = try LocalMarkdownPath().resolve(input)
            #expect(FileIdentity(url: resolved) == expected)
            let source = MarkdownReferenceCheck.Source(url: root.appendingPathComponent("doc.md"), title: "doc.md", content: "[Ziel](link/../target.md#physical)\n")
            let report = try MarkdownReferenceCheck.check(document: source)
            #expect(report.findings.map(\.status) == [.valid])
        }
    }

    @Test("Parallele Fenster erhalten unabhängige lokale Mount- und Pfadergebnisse")
    func parallelMounts() async throws {
        let root = testTemporaryDirectory().appendingPathComponent("markdown-mount-parallel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.md"), link = root.appendingPathComponent("link.md")
        try Data("# Ziel\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let identity = try #require(FileIdentity(url: target))
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<100 {
                group.addTask {
                    guard let resolved = try? LocalMarkdownPath().resolve(link) else { return false }
                    return FileIdentity(url: resolved) == identity
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(results.count == 100 && results.allSatisfy { $0 })
    }

    @Test("Projektbereich prüft weder die äußere aktive Datei noch ausgeschlossene Quellen")
    func projectScope() throws {
        try fixture { base in
            let root = base.appendingPathComponent("project"), outside = base.appendingPathComponent("outside.md")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
            try Data("# A\n\n[Eigen](#a)\n".utf8).write(to: root.appendingPathComponent("a.md"))
            try Data("[Außen](missing.md)\n".utf8).write(to: outside)
            let external = MarkdownReferenceCheck.Source(url: outside, title: "outside.md", content: "[Außen](missing.md)\n")
            let result = try MarkdownReferenceCheck.check(document: external, project: root)
            #expect(result.sources.count == 1 && result.sources.first?.title == "a.md")
            #expect(result.findings.map(\.reference.destination) == ["#a"])
            let excludedURL = root.appendingPathComponent("build/current.md")
            try Data("[Ausgeschlossen](missing.md)\n".utf8).write(to: excludedURL)
            let excluded = MarkdownReferenceCheck.Source(url: excludedURL, title: "current.md", content: "[Ausgeschlossen](missing.md)\n")
            var options = MarkdownReferenceCheck.Options(); options.excludedPatterns = ["build"]
            let filtered = try MarkdownReferenceCheck.check(document: excluded, project: root, options: options)
            #expect(filtered.sources.count == 1 && filtered.findings.map(\.reference.destination) == ["#a"])
            let document = try MarkdownReferenceCheck.check(document: excluded)
            #expect(document.sources.count == 1 && document.findings.first?.status == .missing)
        }
    }

    @Test("Bewusst als Markdown geöffnete Projektdateien zählen auch mit anderer Endung")
    func projectExplicitFormat() throws {
        try fixture { root in
            let currentURL = root.appendingPathComponent("a.md"), manualURL = root.appendingPathComponent("manual.txt")
            try Data("# A\n".utf8).write(to: currentURL)
            try Data("Plain text\n".utf8).write(to: manualURL)
            let current = MarkdownReferenceCheck.Source(url: currentURL, title: "a.md", content: "# A\n")
            let manual = MarkdownReferenceCheck.Source(documentID: UUID(), url: manualURL, title: "manual.txt", content: "# Manuel\n\n[Eigen](#manuel)\n")
            let result = try MarkdownReferenceCheck.check(document: current, openDocuments: [manual], project: root)
            #expect(result.sources.count == 2)
            #expect(result.findings.map(\.status) == [.valid])
        }
    }

    @Test("Bereichswechsel entwertet alte Sprünge und fehlendes Projekt fällt nicht auf Dokument zurück")
    @MainActor func scopeInvalidation() async throws {
        let workspace = Workspace()
        var tab = EditorTab(title: "doc.md", path: "doc.md", content: "# A\n\n[Eigen](#a)\n")
        tab.markdownVisualOverride = false
        workspace.tabs = [tab]; workspace.activeTabID = tab.id
        let controller = workspace.markdownReferences
        controller.present(in: workspace); controller.start(in: workspace, project: false)
        #expect(await waitUntil { !controller.running })
        let finding = try #require(controller.report?.findings.first)
        workspace.pendingEditorJump = nil
        controller.invalidateScope()
        controller.jump(to: finding, in: workspace)
        #expect(controller.report == nil && workspace.pendingEditorJump == nil)
        controller.start(in: workspace, project: true)
        #expect(!controller.running && controller.report == nil && controller.notice != nil)
        controller.close()
    }

    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = testTemporaryDirectory().appendingPathComponent("markdown-reference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
