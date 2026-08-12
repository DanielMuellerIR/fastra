import Foundation
import Testing
@testable import Fastra

private final class GitSnapshotTestExecutor: GitCommandExecuting {
    private final class Cancellation: GitCancelling {
        func cancel() { }
    }

    private let lock = NSLock()
    private var calls: [(arguments: [String], completion: (GitExecutionOutcome) -> Void)] = []

    var arguments: [[String]] {
        lock.withLock { calls.map { $0.arguments } }
    }

    @discardableResult
    func execute(arguments: [String], in directory: URL,
                 outputLimit: GitOutputLimit, policy: GitExecutionPolicy,
                 completion: @escaping (GitExecutionOutcome) -> Void) -> GitCancelling {
        lock.withLock { calls.append((arguments, completion)) }
        return Cancellation()
    }

    func complete(_ index: Int, stdout: Data) {
        let completion = lock.withLock { calls[index].completion }
        completion(.completed(GitResult(exitCode: 0, stdoutData: stdout,
                                        stderrData: Data())))
    }
}

@Test("Änderungsbaum sortiert Ordner vor Dateien und klappt gezielt auf")
func gitChangeTree_buildsAndExpandsHierarchy() {
    let changes = [
        GitChange(path: "z-root.txt", staged: nil, unstaged: .modified),
        GitChange(path: "Sources/Beta/b.swift", staged: nil, unstaged: .modified),
        GitChange(path: "Sources/Alpha/a.swift", staged: nil, unstaged: .modified),
        GitChange(path: "README.md", staged: nil, unstaged: .modified),
    ]
    let tree = GitChangeTreeBuilder.build(changes)
    #expect(tree.folders.map(\.name) == ["Sources"])
    #expect(tree.files.map(\.name) == ["README.md", "z-root.txt"])

    var visible = GitChangeTreeBuilder.visibleItems(in: tree, expanded: [])
    #expect(visible.map(\.id) == [
        "folder:Sources",
        "file:\(Data("README.md".utf8).base64EncodedString())",
        "file:\(Data("z-root.txt".utf8).base64EncodedString())",
    ])

    visible = GitChangeTreeBuilder.visibleItems(in: tree, expanded: ["Sources"])
    #expect(visible.map(\.id).prefix(3) == [
        "folder:Sources", "folder:Sources/Alpha", "folder:Sources/Beta",
    ])
}

@Test("Kompakt gemeldeter unversionierter Ordner bleibt eine Ordnerzeile")
func gitChangeTree_keepsSummarizedFolderAsFolderRow() {
    let change = GitChange(path: "material/", staged: nil, unstaged: .untracked)
    let visible = GitChangeTreeBuilder.visibleItems(
        in: GitChangeTreeBuilder.build([change]), expanded: []
    )
    guard case .summarizedFolder(let rendered, let depth) = visible.first else {
        Issue.record("Zusammengefasster Ordner wurde als Datei gerendert")
        return
    }
    #expect(rendered == change)
    #expect(depth == 0)
}

@Test("Nicht-UTF8-Pfad bleibt im Änderungsbaum als sichere Wurzelzeile sichtbar")
func gitChangeTree_keepsNonUTF8PathVisible() {
    let change = GitChange(rawPath: Data([0x66, 0xFF, 0x6F]),
                           staged: nil, unstaged: .modified)
    let tree = GitChangeTreeBuilder.build([change])
    #expect(tree.folders.isEmpty)
    #expect(tree.files.map(\.rawPath) == [change.rawPath])
}

@Test("Gelöschte Datei liest je Abschnitt die richtige Git-Version")
func gitFileSnapshot_usesIndexOrHead() {
    let index = GitFileSnapshotRequest(repositoryPath: "/tmp/repo",
                                       path: "Ordner/datei.txt", source: .index)
    let head = GitFileSnapshotRequest(repositoryPath: "/tmp/repo",
                                      path: "Ordner/datei.txt", source: .head)
    #expect(index.arguments == ["cat-file", "blob", ":Ordner/datei.txt"])
    #expect(head.arguments == ["cat-file", "blob", "HEAD:Ordner/datei.txt"])
}

@Test("Gelöschte Datei erscheint aus Index oder HEAD als read-only Tab")
@MainActor
func gitFileSnapshot_loadsDeletedFileIntoReadOnlyTab() async {
    let suiteName = "fastra-test-deleted-preview-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let executor = GitSnapshotTestExecutor()
    let coordinator = GitOperationsCoordinator(executor: executor)
    let ws = Workspace(defaults: defaults, gitOperationsCoordinator: coordinator)
    let repository = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-deleted-preview-\(UUID().uuidString)")
    ws.projectURL = repository

    let unstaged = GitChange(path: "Ordner/offen.txt", staged: nil,
                             unstaged: .deleted)
    ws.openGitChangeFile(change: unstaged, staged: false, preview: true)
    #expect(executor.arguments == [["cat-file", "blob", ":Ordner/offen.txt"]])
    #expect(ws.activeTab?.isPreview == true)
    #expect(ws.activeTab?.readOnlyReason != nil)
    executor.complete(0, stdout: Data("Index-Fassung\n".utf8))
    await waitUntil { ws.activeTab?.isLoading == false }
    #expect(ws.activeTab?.content == "Index-Fassung\n")

    ws.openGitChangeFile(change: unstaged, staged: false, preview: false)
    #expect(ws.activeTab?.isPreview == false)

    let staged = GitChange(path: "Ordner/bereit.txt", staged: .deleted,
                           unstaged: nil)
    ws.openGitChangeFile(change: staged, staged: true, preview: true)
    #expect(executor.arguments.last == ["cat-file", "blob", "HEAD:Ordner/bereit.txt"])
    executor.complete(1, stdout: Data("HEAD-Fassung\n".utf8))
    await waitUntil { ws.activeTab?.isLoading == false }
    #expect(ws.activeTab?.content == "HEAD-Fassung\n")
    #expect(ws.activeTab?.gitSnapshotRequest?.source == .head)

    // Index/HEAD sind symbolische Quellen. Nach einer Git-Mutation lädt der
    // gemeinsame Refresh den offenen Vorversions-Tab wirklich neu.
    ws.refreshOpenGitSnapshotTabs()
    #expect(executor.arguments.count == 3)
    executor.complete(2, stdout: Data("HEAD-Fassung 2\n".utf8))
    await waitUntil { ws.activeTab?.content == "HEAD-Fassung 2\n" }
}

@Test("Staged MD-Datei wird trotz fehlendem Working-Tree-Pfad aus dem Index gelesen")
@MainActor
func gitFileSnapshot_mixedDeletionUsesIndexForStagedRow() async {
    let suiteName = "fastra-test-mixed-deleted-preview-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let executor = GitSnapshotTestExecutor()
    let ws = Workspace(defaults: defaults,
                       gitOperationsCoordinator: GitOperationsCoordinator(executor: executor))
    ws.projectURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-mixed-delete-\(UUID().uuidString)")
    let mixed = GitChange(path: "gemischt.txt", staged: .modified,
                          unstaged: .deleted)

    ws.openGitChangeFile(change: mixed, staged: true, preview: true)

    #expect(executor.arguments == [["cat-file", "blob", ":gemischt.txt"]])
    executor.complete(0, stdout: Data("Index\n".utf8))
    await waitUntil { ws.activeTab?.isLoading == false }
    #expect(ws.activeTab?.content == "Index\n")
}

@Test("Projektwechsel beendet Git-Blob-Vorschau ohne ewigen Ladezustand")
@MainActor
func gitFileSnapshot_projectCloseFinalizesCancelledTab() async {
    let suiteName = "fastra-test-snapshot-project-close-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let executor = GitSnapshotTestExecutor()
    let ws = Workspace(defaults: defaults,
                       gitOperationsCoordinator: GitOperationsCoordinator(executor: executor))
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-snapshot-close-\(UUID().uuidString)")
    ws.projectURL = root
    let deleted = GitChange(path: "weg.txt", staged: nil, unstaged: .deleted)
    ws.openGitChangeFile(change: deleted, staged: false, preview: true)
    #expect(ws.activeTab?.isLoading == true)

    ws.closeProject()
    await waitUntil { ws.activeTab?.isLoading == false }

    #expect(ws.projectURL == nil)
    #expect(ws.activeTab?.content
            == L10n.string("Die Git-Vorschau wurde wegen eines Projektwechsels beendet."))
}

@Test("Älterer Git-Blob-Load überschreibt einen neueren Refresh nicht")
@MainActor
func gitFileSnapshot_refreshGenerationRejectsOldCompletion() async {
    let suiteName = "fastra-test-snapshot-generation-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let executor = GitSnapshotTestExecutor()
    let ws = Workspace(defaults: defaults,
                       gitOperationsCoordinator: GitOperationsCoordinator(executor: executor))
    ws.projectURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-snapshot-generation-\(UUID().uuidString)")
    let deleted = GitChange(path: "weg.txt", staged: nil, unstaged: .deleted)
    ws.openGitChangeFile(change: deleted, staged: false, preview: true)
    ws.refreshOpenGitSnapshotTabs()

    // Der Koordinator hält den zweiten Read bis zum Ende des bereits aktiven
    // ersten Prozesses seriell zurück.
    #expect(executor.arguments.count == 1)
    executor.complete(0, stdout: Data("alt\n".utf8))
    await waitUntil { executor.arguments.count == 2 }
    executor.complete(1, stdout: Data("neu\n".utf8))
    await waitUntil { ws.activeTab?.isLoading == false }

    #expect(ws.activeTab?.content == "neu\n")
}

@Test("Einfachklick ersetzt Vorschau-Tab, Doppelklick steckt ihn fest")
@MainActor
func gitChangePreview_reusesThenPinsTab() async throws {
    let suiteName = "fastra-test-change-preview-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let ws = Workspace(defaults: defaults)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-change-preview-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first.txt")
    let second = directory.appendingPathComponent("second.txt")
    try "eins".write(to: first, atomically: true, encoding: .utf8)
    try "zwei".write(to: second, atomically: true, encoding: .utf8)

    var firstDone = false
    ws.loadFile(at: first, preview: true) { _ in firstDone = true }
    await waitUntil { firstDone }
    let previewID = ws.activeTabID
    #expect(ws.tabs.count == 1)
    #expect(ws.activeTab?.isPreview == true)

    var secondDone = false
    ws.loadFile(at: second, preview: true) { _ in secondDone = true }
    await waitUntil { secondDone }
    #expect(ws.tabs.count == 1)
    #expect(ws.activeTabID == previewID)
    #expect(ws.activeTab?.url == second.canonicalFileURL)
    #expect(ws.activeTab?.content == "zwei")
    #expect(ws.activeTab?.documentID != nil)

    ws.loadFile(at: second, preview: false)
    #expect(ws.activeTab?.isPreview == false)
}

@Test("Vorschau-Ersatz erhält Tabplatz, aber wechselt Dokumentidentität")
@MainActor
func gitChangePreview_reuseChangesDocumentIdentity() async throws {
    let suiteName = "fastra-test-preview-document-id-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let ws = Workspace(defaults: defaults)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-preview-document-id-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first.txt")
    let second = directory.appendingPathComponent("second.txt")
    try "eins".write(to: first, atomically: true, encoding: .utf8)
    try "zwei".write(to: second, atomically: true, encoding: .utf8)

    var firstDone = false
    ws.loadFile(at: first, preview: true) { _ in firstDone = true }
    await waitUntil { firstDone }
    let tabID = ws.activeTabID
    let documentID = ws.activeDocumentID
    var secondDone = false
    ws.loadFile(at: second, preview: true) { _ in secondDone = true }
    await waitUntil { secondDone }

    #expect(ws.activeTabID == tabID)
    #expect(ws.activeDocumentID != documentID)
}

@Test("Git-Dateivorschau öffnet geschlossenes Projekt nicht verspätet wieder")
@MainActor
func gitChangePreview_projectCloseDoesNotReopenRepository() async throws {
    let suiteName = "fastra-test-preview-project-context-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let ws = Workspace(defaults: defaults)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-preview-context-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("large.txt")
    try Data(repeating: 65, count: 8 * 1024 * 1024).write(to: file)
    ws.projectURL = directory
    let change = GitChange(path: "large.txt", staged: nil, unstaged: .modified)
    ws.openGitChangeFile(change: change, staged: false, preview: true)
    let previewID = ws.activeTabID
    ws.closeProject()
    await waitUntil { !ws.tabs.contains { $0.id == previewID } }

    #expect(ws.projectURL == nil)
    #expect(!ws.tabs.contains { $0.url == file.canonicalFileURL })
}

@Test("Fehlgeschlagener Vorschau-Ersatz lässt keinen leeren Workspace zurück")
@MainActor
func gitChangePreview_failedReplacementRestoresScratch() async throws {
    let suiteName = "fastra-test-change-preview-failure-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let ws = Workspace(defaults: defaults)
    let existing = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-preview-ok-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: existing) }
    try "vorhanden".write(to: existing, atomically: true, encoding: .utf8)

    var firstDone = false
    ws.loadFile(at: existing, preview: true) { _ in firstDone = true }
    await waitUntil { firstDone }
    #expect(ws.tabs.count == 1)

    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-preview-fehlt-\(UUID().uuidString).txt")
    var secondResult: Bool?
    ws.loadFile(at: missing, preview: true) { secondResult = $0 }
    await waitUntil { secondResult != nil }

    #expect(secondResult == false)
    #expect(ws.tabs.count == 1)
    #expect(ws.activeTab?.isPristineScratch == true)
}

@Test("Erste Eingabe pinnt Vorschau und read-only Inhalt bleibt unverändert")
@MainActor
func gitChangePreview_editPinsAndReadOnlyRejectsMutation() {
    let suiteName = "fastra-test-change-preview-edit-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let ws = Workspace(defaults: defaults)
    let editable = EditorTab(title: "edit.txt", path: "/tmp", content: "alt",
                             isPreview: true)
    ws.tabs = [editable]
    ws.activeTabID = editable.id
    ws.activeTabContent.wrappedValue = "neu"
    #expect(ws.activeTab?.isPreview == false)
    #expect(ws.activeTab?.content == "neu")

    let readOnly = EditorTab(title: "gone.txt", path: "Git", content: "vorher",
                             readOnlyReason: "gelöscht")
    ws.tabs = [readOnly]
    ws.activeTabID = readOnly.id
    ws.activeTabContent.wrappedValue = "unerlaubt"
    #expect(ws.activeTab?.content == "vorher")
    #expect(ws.activeTab?.isDirty == false)
}

@Test("Amend verlangt vor jeder Git-Aktion eine destruktive Bestätigung")
@MainActor
func gitAmend_requestsDestructiveConfirmation() {
    let suiteName = "fastra-test-amend-confirm-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let ws = Workspace(defaults: defaults)
    ws.projectURL = URL(fileURLWithPath: "/tmp/fastra-confirm-fixture")
    var captured: GitMutationConfirmation?
    ws.gitMutationConfirmationHandler = { confirmation in
        captured = confirmation
        return false
    }

    ws.gitAmendNoEdit()

    #expect(captured?.isDestructive == true)
    #expect(captured?.confirmTitle == L10n.string("Commit ersetzen"))
}
