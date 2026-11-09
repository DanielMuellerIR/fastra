import Foundation
import Testing
@testable import Fastra

@MainActor
private final class PendingGitMarkdownImport {
    var completion: ((MarkdownImportProcessOutcome) -> Void)?
    var output: URL?

    func finish() throws {
        let output = try #require(output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let file = output.appendingPathComponent("Report.md")
        try "# Converted\n".write(to: file, atomically: true, encoding: .utf8)
        let data = try JSONSerialization.data(withJSONObject: ["ok": true,
            "markdownFile": file.path, "assets": []] as [String: Any])
        let callback = try #require(completion)
        completion = nil
        callback(MarkdownImportProcessOutcome(exitCode: 0, stdout: data,
            stderr: Data(), outputIsComplete: true))
    }
}

@Suite("Verspätete Markdown-Umwandlung aus Git", .serialized)
@MainActor
struct GitMarkdownConversionTests {
    private func withImport(package: Bool = false, _ body: (Workspace, URL, PendingGitMarkdownImport) async throws -> Void) async throws {
        let root = testTemporaryDirectory().appendingPathComponent("git-md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent(package ? "Report.rtfd" : "Report.rtf")
        if package { try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true) }
        let original = package ? source.appendingPathComponent("TXT.rtf") : source
        try "Original".write(to: original, atomically: true, encoding: .utf8)
        let suite = "fastra-test-git-md-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        let service = MarkdownImportService()
        let pending = PendingGitMarkdownImport()
        let previousChoice = Workspace.markdownImportFileChoiceProvider
        let previousPackageChoice = Workspace.markdownImportPackageChoiceProvider
        Workspace.markdownImportFileChoiceProvider = { _, _ in .convert }
        Workspace.markdownImportPackageChoiceProvider = { _, _ in .convert }
        service.locateTool = { URL(fileURLWithPath: "/bin/echo") }
        service.runProcess = { _, arguments, _, _, completion in
            if arguments.contains("--formats") {
                let catalog = Data(#"{"ok":true,"formats":[{"format":"rtf","extensions":["rtf"],"container":"file","available":true},{"format":"rtfd","extensions":["rtfd"],"container":"package","available":true}]}"#.utf8)
                completion(.init(exitCode: 0, stdout: catalog, stderr: Data(), outputIsComplete: true))
            } else if arguments.contains("--help") {
                completion(.init(exitCode: 0, stdout: Data(), stderr: Data(), outputIsComplete: true))
            } else if let index = arguments.firstIndex(of: "--output") {
                pending.output = URL(fileURLWithPath: arguments[index + 1])
                pending.completion = completion
            }
            return nil
        }
        let workspace = Workspace(defaults: defaults, markdownImportService: service)
        workspace.projectURL = root.canonicalFileURL
        defer {
            service.runProcess = nil
            Workspace.markdownImportFileChoiceProvider = previousChoice
            Workspace.markdownImportPackageChoiceProvider = previousPackageChoice
            workspace.closeProject()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try await body(workspace, root, pending)
        #expect(try String(contentsOf: original, encoding: .utf8) == "Original")
    }

    @Test("Projektwechsel und Projektschließen entwerten verspätete Umwandlungen", arguments: [false, true], [false, true])
    func obsoleteProjectCannotBeReopened(close: Bool, package: Bool) async throws {
        try await withImport(package: package) { workspace, root, pending in
            workspace.openGitChangeFile(change: .init(path: package ? "Report.rtfd" : "Report.rtf", staged: nil, unstaged: .modified),
                staged: false, preview: false)
            #expect(pending.completion != nil)
            let other = root.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            if close { workspace.closeProject() }
            else { workspace.openProject(at: other) }
            let project = workspace.projectURL
            try pending.finish()
            await waitUntil { !workspace.tabs.contains { $0.isLoading } }
            #expect(workspace.projectURL == project)
            #expect(!workspace.tabs.contains { $0.url?.lastPathComponent == "Report.md" })
        }
    }

    @Test("Nur die unveränderte flüchtige Diff-Vorschau wird nach Erfolg geschlossen",
          arguments: ["unchanged", "replaced", "pinnedReplacement", "pinnedOriginal"])
    func previewCleanupRespectsDocumentIdentity(mode: String) async throws {
        try await withImport { workspace, _, pending in
            let source = GitChange(path: "Report.rtf", staged: nil, unstaged: .modified)
            workspace.openGitChangeDiff(change: source, staged: false, preview: true)
            await waitUntil { !workspace.tabs.contains { $0.isLoading } }
            let slot = try #require(workspace.activeTabID)
            let originalDocument = workspace.activeDocumentID
            workspace.openGitChangeFile(change: source, staged: false, preview: false)
            #expect(pending.completion != nil)
            if mode == "replaced" || mode == "pinnedReplacement" {
                workspace.openGitChangeDiff(change: .init(path: "other.txt", staged: nil, unstaged: .modified),
                    staged: false, preview: true)
                #expect(workspace.activeTabID == slot)
                #expect(workspace.activeDocumentID != originalDocument)
            }
            if mode == "pinnedReplacement" || mode == "pinnedOriginal",
               let index = workspace.tabs.firstIndex(where: { $0.id == slot }) {
                workspace.tabs[index].isPreview = false
            }
            let preservedDocument = workspace.tabs.first { $0.id == slot }?.documentID
            try pending.finish()
            await waitUntil { !workspace.tabs.contains { $0.isLoading } }
            #expect(workspace.tabs.contains { $0.url?.lastPathComponent == "Report.md" && !$0.isPreview })
            if mode == "unchanged" {
                #expect(!workspace.tabs.contains { $0.id == slot })
            } else {
                #expect(workspace.tabs.contains { $0.id == slot && $0.documentID == preservedDocument })
            }
        }
    }
}
