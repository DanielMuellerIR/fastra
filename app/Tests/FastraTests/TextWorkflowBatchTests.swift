import AppKit
import Foundation
import Testing
@testable import Fastra

@Suite("Mehrdokumentabläufe: vollständige Vorschau und Fensterkonflikte", .serialized)
struct TextWorkflowBatchTests {
    private let uppercase = TextWorkflow(name: "Upper", steps: [.init(kind: .uppercase)])

    private func directory() throws -> URL {
        let root = testTemporaryDirectory().appendingPathComponent("workflow-batch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Alle Eingaben und mehrere Fehler bleiben sichtbar; kein Teilplan")
    func allInputsAndErrors() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let urls = ["one.txt", "binary.txt", "missing.txt", "last.txt"].map { root.appendingPathComponent($0) }
        try Data("one".utf8).write(to: urls[0]); try Data([0, 1, 2]).write(to: urls[1]); try Data("last".utf8).write(to: urls[3])
        let batch = try TextWorkflowBatch.files(uppercase, inputs: urls.map { .init(url: $0) })
        #expect(batch.entries.count == 4 && batch.changedCount == 2)
        #expect(batch.entries.filter { $0.issue != nil }.count == 2)
        #expect(!batch.isComplete && batch.filePlan == nil)
        #expect(try Data(contentsOf: urls[0]) == Data("one".utf8))
    }

    @Test("Alias-/Hardlink-Duplikate bleiben Fehler, auch bei getrennten Einzelprüfungen", arguments: [false, true])
    func aliases(_ hardlink: Bool) throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("one.txt"), alias = root.appendingPathComponent("alias.txt")
        try Data("one".utf8).write(to: one)
        if hardlink { try FileManager.default.linkItem(at: one, to: alias) }
        else { try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: one) }
        let batch = try TextWorkflowBatch.files(uppercase, inputs: [.init(url: one), .init(url: alias)])
        #expect(batch.entries.count == 2 && batch.entries[1].issue != nil && batch.filePlan == nil)
    }

    @Test("Gemeinsame Budgets und nicht darstellbare Diffs sperren den ganzen Satz")
    func aggregateLimits() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("one.txt"), two = root.appendingPathComponent("two.txt")
        try Data("one".utf8).write(to: one); try Data("two".utf8).write(to: two)
        var limits = TextWorkflowFilePlan.Limits.standard; limits.originalBytes = 5
        let batch = try TextWorkflowBatch.files(uppercase, inputs: [.init(url: one), .init(url: two)], limits: limits)
        #expect(batch.entries.count == 2 && !batch.isComplete && batch.filePlan == nil)
        #expect(throws: TextWorkflowFilePlan.Failure.cancelled) {
            try TextWorkflowBatch.files(uppercase, inputs: [.init(url: one)], shouldCancel: { true })
        }
        limits.seconds = -1
        #expect(throws: TextWorkflowFilePlan.Failure.timeout) {
            try TextWorkflowBatch.files(uppercase, inputs: [.init(url: one)], limits: limits)
        }
    }

    @Test("Enumeration nutzt Dateitypen, Ausschlüsse, Datei-Sets und Paketgrenzen")
    func filteredEnumeration() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["one.txt", "two.png", "skip.txt"] { try Data("x".utf8).write(to: root.appendingPathComponent(name)) }
        let package = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: package.appendingPathComponent("hidden.txt"))
        let source = TextWorkflowBatch.FileSource(roots: [root, root.appendingPathComponent("one.txt")], filter: .knownText,
                                                  exclusions: ["skip.txt"], projectRoot: root)
        let inputs = try source.enumerate(shouldCancel: { false })
        #expect(inputs.map { $0.url.lastPathComponent } == ["one.txt"])
        #expect(throws: TextWorkflowFilePlan.Failure.cancelled) { try source.enumerate(shouldCancel: { true }) }
        #expect(throws: TextWorkflowFilePlan.Failure.timeout) { try source.enumerate(seconds: 0, shouldCancel: { false }) }
        let missing = TextWorkflowBatch.FileSource(roots: [root.appendingPathComponent("missing")], filter: .all, exclusions: [], projectRoot: nil)
        #expect(throws: TextWorkflowFilePlan.Failure.self) { try missing.enumerate(shouldCancel: { false }) }
    }

    @MainActor private func workspace(_ defaults: UserDefaults, url: URL, dirty: Bool = false) -> Workspace {
        let ws = Workspace(defaults: defaults)
        ws.tabs = [EditorTab(title: url.lastPathComponent, path: url.path, url: url, content: "one")]
        ws.tabs[0].recordSavedContentBaseline(); ws.tabs[0].isDirty = dirty; ws.activeTabID = ws.tabs[0].id
        return ws
    }

    @Test("Abbruch greift auch zwischen den Metadatenabfragen des Workspace-Preflights")
    @MainActor func serialRunnerIntegrationMetadataCancellation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("one.txt"), two = root.appendingPathComponent("two.txt")
        try Data("one".utf8).write(to: one); try Data("two".utf8).write(to: two)
        let domain = "fastra-test-workflow-cancel-" + UUID().uuidString
        let defaults = testSuiteDefaults(named: domain); defer { defaults.removePersistentDomain(forName: domain) }
        let ws = workspace(defaults, url: one)
        ws.fileTreeMutationWorkspaceProvider = { [] }
        let mutation = try ws.beginTextWorkflowDiskMutation(urls: [one, two])
        defer { ws.finishTextWorkflowDiskMutation(mutation, changedURLs: [], session: nil) }
        let cancelled = await Task.detached {
            var checks = 0
            do {
                try mutation.preflight(in: ws, shouldCancel: { checks += 1; return checks > 1 })
                return false
            } catch ApplyError.cancelled { return true }
            catch { Issue.record(error); return false }
        }.value
        #expect(cancelled)
        #expect(try Data(contentsOf: one) == Data("one".utf8))
        #expect(try Data(contentsOf: two) == Data("two".utf8))
    }

    @Test("Andere Fenster blockieren Platten-Apply einschließlich Hex und Hardlink", arguments: [0, 1, 2])
    @MainActor func serialRunnerIntegrationOtherWindow(_ kind: Int) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("one.txt"), alias = root.appendingPathComponent("alias.txt")
        try Data("one".utf8).write(to: one)
        try FileManager.default.linkItem(at: one, to: alias)
        let domain = "fastra-test-workflow-batch-" + UUID().uuidString
        let defaults = testSuiteDefaults(named: domain); defer { defaults.removePersistentDomain(forName: domain) }
        let ws = workspace(defaults, url: one), other = workspace(defaults, url: kind == 2 ? alias : one, dirty: kind != 1)
        if kind == 1 {
            var hex = HexEditSession()
            hex.editRow("FE", data: Data([0x6F]), baseOffset: 0, row: 0)
            other.tabs[0].hexEditSession = hex
        }
        ws.fileTreeMutationWorkspaceProvider = { [other] }
        let tabStates = ws.textWorkflowDiskTabStates()
        let batch = try await Task.detached { try TextWorkflowBatch.files(uppercase, inputs: [.init(url: one)], openTabs: tabStates) }.value
        #expect(batch.entries[0].issue != nil && batch.filePlan == nil)
        let mutation = try ws.beginTextWorkflowDiskMutation(urls: [one])
        defer { ws.finishTextWorkflowDiskMutation(mutation, changedURLs: [], session: nil) }
        #expect(!ws.textEditingIsAllowed(for: ws.tabs[0]))
        #expect(!other.textEditingIsAllowed(for: other.tabs[0]))
        let outcome = await Task.detached { Result { try mutation.preflight(in: ws) } }.value
        guard case .failure(let error) = outcome else { Issue.record("Dirty-/Hex-Konflikt wurde zugelassen"); return }
        #expect(error is ApplyError)
        #expect(try Data(contentsOf: one) == Data("one".utf8))
    }

    @Test("Neu geöffnete Fenster und wiederverwendete Tabs entwerten den gestarteten Preflight")
    @MainActor func serialRunnerIntegrationLateWindow() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("one.txt"); try Data("one".utf8).write(to: one)
        let domain = "fastra-test-workflow-late-" + UUID().uuidString
        let defaults = testSuiteDefaults(named: domain); defer { defaults.removePersistentDomain(forName: domain) }
        let ws = workspace(defaults, url: one)
        ws.fileTreeMutationWorkspaceProvider = { [] }
        let mutation = try ws.beginTextWorkflowDiskMutation(urls: [one])
        defer { ws.finishTextWorkflowDiskMutation(mutation, changedURLs: [], session: nil) }
        let other = workspace(defaults, url: one)
        #expect(!other.textEditingIsAllowed(for: other.tabs[0]))
        ws.fileTreeMutationWorkspaceProvider = { [other] }
        let outcome = await Task.detached { Result { try mutation.preflight(in: ws) } }.value
        if case .success = outcome { Issue.record("Neues Fenster wurde nicht erkannt") }
        #expect(throws: ApplyError.self) { try ws.beginTextWorkflowDiskMutation(urls: [one]) }
    }
}
