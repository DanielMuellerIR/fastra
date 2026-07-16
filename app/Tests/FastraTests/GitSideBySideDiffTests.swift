import Foundation
import Testing
@testable import Fastra

private let normalPatch = """
diff --git a/Sources/App.swift b/Sources/App.swift
index 1111111..2222222 100644
--- a/Sources/App.swift
+++ b/Sources/App.swift
@@ -1,4 +1,5 @@
 eins
-alt value
+neu value
 drei
+vier
 fünf
"""

@Test("Side-by-side-Parser richtet Änderung, Einfügung und Zeilennummern aus")
func sideBySideParseNormal() {
    let document = GitDiffParser.parse(Data(normalPatch.utf8))
    #expect(document.limitation == nil)
    #expect(document.files.count == 1)
    #expect(document.files[0].oldPath == "Sources/App.swift")
    #expect(document.files[0].newPath == "Sources/App.swift")
    let rows = document.hunks[0].rows
    #expect(rows.map(\.kind) == [.context, .changed, .context, .added, .context])
    #expect(rows[1].before == "alt value")
    #expect(rows[1].after == "neu value")
    #expect(rows[1].beforeNumber == 2)
    #expect(rows[1].afterNumber == 2)
    #expect(rows[3].beforeNumber == nil)
    #expect(rows[3].afterNumber == 4)
}

@Test("Reine Löschungen und mehrere Hunks bleiben getrennt navigierbar")
func sideBySideMultipleHunksAndDeletion() {
    let patch = """
diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -1,2 +1,1 @@
-weg
 bleibt
@@ -20,2 +19,2 @@
-alt
+neu
 ende
"""
    let document = GitDiffParser.parse(Data(patch.utf8))
    #expect(document.hunks.count == 2)
    #expect(document.hunks[0].rows[0].kind == .removed)
    #expect(document.hunks[0].rows[0].after == nil)
    #expect(document.hunks[1].rows[0].kind == .changed)
    #expect(GitDiffViewModel.adjacentHunk(current: nil, count: 2, direction: 1) == 0)
    #expect(GitDiffViewModel.adjacentHunk(current: 0, count: 2, direction: 1) == 1)
    #expect(GitDiffViewModel.adjacentHunk(current: 1, count: 2, direction: 1) == 1)
    #expect(GitDiffViewModel.adjacentHunk(current: 0, count: 2, direction: -1) == 0)
    #expect(GitDiffViewModel.omittedLineCount(
        previous: document.hunks[0], current: document.hunks[1]
    ) == 17)
}

@Test("Unveränderte Bereiche sind faltbar und wieder ausklappbar")
func sideBySideFolds() {
    let context = (1...12).map { " zeile \($0)" }.joined(separator: "\n")
    let patch = """
diff --git a/a b/a
--- a/a
+++ b/a
@@ -1,13 +1,13 @@
\(context)
-alt
+neu
"""
    let hunk = GitDiffParser.parse(Data(patch.utf8)).hunks[0]
    let collapsed = GitDiffViewModel.visibleItems(hunk: hunk, expandedFolds: [])
    guard case .fold(let fold) = collapsed.first(where: {
        if case .fold = $0 { return true }; return false
    }) else {
        Issue.record("Fold fehlt")
        return
    }
    #expect(fold.count == 6)
    #expect(collapsed.count == 8) // 3 Kontext + Fold + 3 Kontext + Änderung
    let expanded = GitDiffViewModel.visibleItems(hunk: hunk, expandedFolds: [fold.id])
    #expect(expanded.count == 14) // Fold bleibt als Einklappknopf sichtbar
}

@Test("Intraline-Markierung nutzt linearen Präfix und Suffix")
func sideBySideIntraline() {
    let result = GitDiffParser.intraline("prefix ALT suffix", "prefix NEU suffix")
    #expect(result.before == 7..<10)
    #expect(result.after == 7..<10)
    let equal = GitDiffParser.intraline("gleich", "gleich")
    #expect(equal.before == nil)
    #expect(equal.after == nil)
    let long = String(repeating: "x", count: GitDiffParser.maximumIntralineCharacters + 1)
    #expect(GitDiffParser.intraline(long, long + "y").wasLimited)
}

@Test("Overview-Ruler verteilt Hunks stabil und Navigation behandelt leere Diffs")
func sideBySideRuler() {
    #expect(GitDiffViewModel.rulerPositions(hunkCount: 0).isEmpty)
    #expect(GitDiffViewModel.rulerPositions(hunkCount: 1) == [0.5])
    #expect(GitDiffViewModel.rulerPositions(hunkCount: 3) == [0, 0.5, 1])
    let sampled = GitDiffViewModel.rulerMarkerIndices(hunkCount: 10_000)
    #expect(sampled.count == 160)
    #expect(sampled.first == 0)
    #expect(sampled.last == 9_999)
    let sampledWithCurrent = GitDiffViewModel.rulerMarkerIndices(
        hunkCount: 2_000, currentHunk: 123
    )
    #expect(sampledWithCurrent.count == 160)
    #expect(sampledWithCurrent.contains(123))
    #expect(GitDiffViewModel.adjacentHunk(current: nil, count: 0, direction: 1) == nil)
}

@Test("CRLF im Dateiinhalt bleibt als sichtbares Zeilenende erhalten")
func sideBySideCRLF() {
    let patch = """
diff --git a/a b/a
--- a/a
+++ b/a
@@ -1 +1 @@
-alt
+neu\r
"""
    let document = GitDiffParser.parse(Data(patch.utf8))
    #expect(document.hunks.count == 1)
    #expect(document.hunks[0].rows[0].before == "alt")
    #expect(document.hunks[0].rows[0].after == "neu␍")
}

@Test("Fehlender finaler Zeilenumbruch bleibt als Metadatum sichtbar")
func sideBySideNoFinalNewline() {
    let patch = """
diff --git a/a b/a
--- a/a
+++ b/a
@@ -1 +1 @@
-alt
\\ No newline at end of file
+neu
\\ No newline at end of file
"""
    let rows = GitDiffParser.parse(Data(patch.utf8)).hunks[0].rows
    #expect(rows.count == 1)
    #expect(rows[0].kind == .changed)
    #expect(rows[0].beforeMissingFinalNewline)
    #expect(rows[0].afterMissingFinalNewline)
}

@Test("EOF-Marker bleibt getrennt an alter und neuer Rohzeile")
func sideBySideNoFinalNewlineSides() {
    func row(_ body: String) -> GitDiffAlignedRow {
        let patch = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n" + body
        return GitDiffParser.parse(Data(patch.utf8)).hunks[0].rows[0]
    }
    let oldOnly = row("-alt\n\\ No newline at end of file\n+neu\n")
    #expect(oldOnly.beforeMissingFinalNewline && !oldOnly.afterMissingFinalNewline)
    let newOnly = row("-alt\n+neu\n\\ No newline at end of file\n")
    #expect(!newOnly.beforeMissingFinalNewline && newOnly.afterMissingFinalNewline)
    let both = row("-alt\n\\ No newline at end of file\n+neu\n\\ No newline at end of file\n")
    #expect(both.beforeMissingFinalNewline && both.afterMissingFinalNewline)

    let asymmetric = """
diff --git a/a b/a
--- a/a
+++ b/a
@@ -1,2 +1 @@
-erste
-letzte alt
\\ No newline at end of file
+letzte neu
\\ No newline at end of file
"""
    let rows = GitDiffParser.parse(Data(asymmetric.utf8)).hunks[0].rows
    #expect(!rows[0].beforeMissingFinalNewline)
    #expect(rows[1].beforeMissingFinalNewline)
    #expect(rows[0].afterMissingFinalNewline)
}

@Test("Neue, gelöschte und leere Dateien behalten ihre Seiten")
func sideBySideNewDeletedEmpty() {
    let newPatch = """
diff --git a/leer.txt b/leer.txt
new file mode 100644
--- /dev/null
+++ b/leer.txt
"""
    let newDocument = GitDiffParser.parse(Data(newPatch.utf8))
    #expect(newDocument.files[0].oldPath == nil)
    #expect(newDocument.files[0].newPath == "leer.txt")
    #expect(!newDocument.isEmpty)

    let deletedPatch = """
diff --git a/weg.txt b/weg.txt
deleted file mode 100644
--- a/weg.txt
+++ /dev/null
"""
    let deleted = GitDiffParser.parse(Data(deletedPatch.utf8))
    #expect(deleted.files[0].oldPath == "weg.txt")
    #expect(deleted.files[0].newPath == nil)
}

@Test("Umbenennung und Unicode-Pfad werden ohne Nachentquoten modelliert")
func sideBySideRenameUnicode() {
    let patch = """
diff --git a/Grüße alt.txt b/Grüße neu.txt
similarity index 100%
rename from Grüße alt.txt
rename to Grüße neu.txt
"""
    let file = GitDiffParser.parse(Data(patch.utf8)).files[0]
    #expect(file.oldPath == "Grüße alt.txt")
    #expect(file.newPath == "Grüße neu.txt")
    #expect(file.hunks.isEmpty)
}

@Test("Binärdatei zeigt Metadaten statt kaputtem Text")
func sideBySideBinary() {
    let patch = """
diff --git a/a.bin b/a.bin
index 111..222 100644
Binary files a/a.bin and b/a.bin differ
"""
    let document = GitDiffParser.parse(Data(patch.utf8))
    guard case .binary(let details) = document.files.first?.limitation else {
        Issue.record("Binärgrenze fehlt")
        return
    }
    #expect(details.contains("a.bin"))
    #expect(document.limitation == nil)
    #expect(document.files.count == 1)
}

@Test("Binärgrenze einer Datei verdeckt weitere Textdateien nicht")
func sideBySideMixedBinaryAndText() {
    let patch = """
diff --git a/a.bin b/a.bin
index 111..222 100644
Binary files a/a.bin and b/a.bin differ
diff --git a/text.txt b/text.txt
--- a/text.txt
+++ b/text.txt
@@ -1 +1 @@
-alt
+neu
"""
    let document = GitDiffParser.parse(Data(patch.utf8))
    #expect(document.files.count == 2)
    #expect(document.files[0].limitation != nil)
    #expect(document.files[1].hunks.count == 1)
}

@Test("Ungültiges UTF-8 und Ausgabegrenzen werden ehrlich abgebrochen")
func sideBySideEncodingAndLimits() {
    let invalid = GitDiffParser.parse(Data([0xff, 0xfe]))
    #expect(invalid.limitation == .invalidUTF8)

    let truncated = GitDiffParser.parse(Data(normalPatch.utf8), wasTruncated: true)
    #expect(truncated.limitation
            == .outputTruncated(retainedBytes: Data(normalPatch.utf8).count))

    let manyLines = GitDiffParser.parse(Data("a\nb\nc".utf8), maximumLines: 2)
    #expect(manyLines.limitation == .tooManyLines(limit: 2))

    let giantLine = Data(repeating: 0x61, count: 4 * 1024 * 1024)
    #expect(giantLine.count == GitDiffRequest.outputLimit.stdoutBytes)
    #expect(GitDiffParser.parse(giantLine).limitation
            == .lineTooLong(limit: GitDiffParser.maximumLineBytes))

    var flood = "diff --git a/a b/a\n--- a/a\n+++ b/a\n"
    for index in 0...GitDiffParser.maximumHunks {
        flood += "@@ -\(index + 1) +\(index + 1) @@\n-a\n+b\n"
    }
    #expect(GitDiffParser.parse(Data(flood.utf8)).limitation
            == .tooManyHunks(limit: GitDiffParser.maximumHunks))
}

@Test("Combined- und Konflikt-Diffs liefern auswählbaren Unified-Fallback")
func sideBySideCombinedDiffFallback() {
    let patch = """
diff --cc konflikt.txt
index 1111111,2222222..3333333
--- a/konflikt.txt
+++ b/konflikt.txt
@@@ -1,1 -1,1 +1,5 @@@
++<<<<<<< HEAD
+ links
++=======
+ rechts
++>>>>>>> branch
"""
    let document = GitDiffParser.parse(Data(patch.utf8))
    guard case .combinedDiff(let unified) = document.limitation else {
        Issue.record("Combined-Limitation fehlt")
        return
    }
    #expect(unified == patch)
    #expect(document.hunks.isEmpty)
}

@Test("No-index-Zeitstempel wird entfernt, echte Pfad-Tabs bleiben erhalten")
func sideBySideNoIndexTimestampPath() {
    let raw = "ordner/mit\tTab.txt\t2026-07-15 12:34:56.123456789 +0200"
    #expect(GitDiffParser.strippingTerminalTimestamp(from: raw) == "ordner/mit\tTab.txt")
    #expect(GitDiffParser.strippingTerminalTimestamp(from: "ordner/mit\tTab.txt")
            == "ordner/mit\tTab.txt")
    #expect(GitDiffParser.strippingTerminalTimestamp(from: "a\tkein timestamp")
            == "a\tkein timestamp")
}

@Test("Scroll-Auswahl, Refresh-Clamp und Fold-Bereinigung bleiben stabil")
func sideBySideUIStateReconciliation() {
    func hunk(_ id: String) -> GitDiffHunk {
        GitDiffHunk(id: id, header: id, oldStart: 1, newStart: 1, rows: [])
    }
    let five = (1...5).map { hunk("h\($0)") }
    #expect(GitDiffViewModel.currentHunkIndex(
        positions: ["h1": -100, "h2": -10, "h3": 40],
        orderedIDs: five.map(\.id)
    ) == 1)
    #expect(GitDiffViewModel.reconciledHunkIndex(
        previousID: "h5", previousIndex: 4, hunks: [hunk("neu")]
    ) == 0)
    #expect(GitDiffViewModel.reconciledHunkIndex(
        previousID: "h2", previousIndex: 4, hunks: five
    ) == 1)

    let document = GitDiffParser.parse(Data(normalPatch.utf8))
    #expect(GitDiffViewModel.validExpandedFolds(["veraltet"], document: document).isEmpty)
}

@Test("Requests haben repo-gebundene Identität und sichere literal Pathspecs")
func sideBySideRequestIdentityAndArguments() {
    let weird = "dir/:(glob)**/[x] - Grüße.txt"
    let first = GitDiffRequest(repositoryPath: "/repo-a", source: .unstaged(path: weird))
    let second = GitDiffRequest(repositoryPath: "/repo-b", source: .unstaged(path: weird))
    #expect(first != second)
    #expect(GitDiffRequest(repositoryPath: "/repo", source: .workingTree(path: nil)).id
            != GitDiffRequest(repositoryPath: "/repo", source: .workingTree(path: "*")).id)
    #expect(first.arguments.contains("--literal-pathspecs"))
    #expect(first.arguments.contains("core.quotePath=false"))
    #expect(first.arguments.last == weird)
    #expect(first.arguments.contains("--no-color"))
    #expect(first.arguments.contains("--no-ext-diff"))
    #expect(first.arguments.contains("--no-textconv"))
    #expect(first.arguments.contains("--find-renames"))
}

@Test("Projektwechsel entfernt repositorygebundene Diff-Tabs statt sie umzudeuten")
func sideBySideProjectSwitchDropsStaleTab() {
    let request = GitDiffRequest(repositoryPath: "/repo-a",
                                 source: .unstaged(path: "a.txt"))
    let tab = EditorTab(title: "Git-Diff", path: "Git", gitKind: .diff,
                        gitDiffRequest: request,
                        gitDiffDocument: GitDiffDocument(files: [], limitation: nil))
    #expect(Workspace.tabsAfterOpeningProject([tab], root: URL(fileURLWithPath: "/repo-b"))
        .isEmpty)
}

@Test("Root und Merge benennen ihre Elternsemantik ausdrücklich")
func sideBySideCommitParents() {
    let root = GitDiffRequest(repositoryPath: "/repo", source: .commit(
        hash: "abcdef1234", parent: .emptyTree, path: "a.txt"
    ))
    #expect(root.arguments.contains("--root"))
    #expect(root.arguments.contains("diff-tree"))
    #expect(root.comparisonDescription == L10n.string("Root-Commit gegen leeren Baum"))

    let merge = GitDiffRequest(repositoryPath: "/repo", source: .commit(
        hash: "merge", parent: .commit(hash: "parent123", number: 1, total: 2),
        path: "a.txt"
    ))
    #expect(merge.arguments.contains("parent123"))
    #expect(merge.arguments.contains("merge"))
    #expect(merge.comparisonDescription?.contains("1") == true)
    #expect(merge.comparisonDescription?.contains("2") == true)
}

@Test("Reale Git-Diffs funktionieren für Sonderpfad, Index, Arbeitsbaum und Root-Commit")
func sideBySideRealRepository() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-diff-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try await completedGit(["init", "-q"], in: root)
    _ = try await completedGit(["config", "user.name", "Fastra Test"], in: root)
    _ = try await completedGit(["config", "user.email", "test@example.invalid"], in: root)
    let path = "dir/:(glob) [x] - Grüße.txt"
    let directory = root.appendingPathComponent("dir", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = root.appendingPathComponent(path)
    try Data("alt\n".utf8).write(to: file)
    _ = try await completedGit(["--literal-pathspecs", "add", "--", path], in: root)
    _ = try await completedGit(["commit", "-q", "-m", "root"], in: root)
    let hash = try await completedGit(["rev-parse", "HEAD"], in: root).stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)

    let rootRequest = GitDiffRequest(repositoryPath: root.path, source: .commit(
        hash: hash, parent: .emptyTree, path: path
    ))
    let rootResult = try await completedGit(rootRequest.arguments, in: root)
    #expect(!GitDiffParser.parse(rootResult.stdoutData).hunks.isEmpty)

    try Data("neu\n".utf8).write(to: file)
    let unstaged = GitDiffRequest(repositoryPath: root.path, source: .unstaged(path: path))
    let workResult = try await completedGit(unstaged.arguments, in: root)
    #expect(GitDiffParser.parse(workResult.stdoutData).hunks[0].rows.contains {
        $0.kind == .changed && $0.before == "alt" && $0.after == "neu"
    })

    _ = try await completedGit(["--literal-pathspecs", "add", "--", path], in: root)
    let staged = GitDiffRequest(repositoryPath: root.path, source: .staged(path: path))
    let stagedResult = try await completedGit(staged.arguments, in: root)
    #expect(!GitDiffParser.parse(stagedResult.stdoutData).hunks.isEmpty)

    let untrackedPath = "- neu ü [x].txt"
    try Data("inhalt\n".utf8).write(to: root.appendingPathComponent(untrackedPath))
    let untracked = GitDiffRequest(repositoryPath: root.path,
                                   source: .untracked(path: untrackedPath))
    let untrackedResult = try await completedGit(untracked.arguments,
                                                 acceptedExitCodes: [0, 1], in: root)
    #expect(!GitDiffParser.parse(untrackedResult.stdoutData).hunks.isEmpty)
}

@Test("Realer Merge-Konflikt wird nicht als leerer strukturierter Diff missverstanden")
func sideBySideRealMergeConflict() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-conflict-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Default-Branch ausdrücklich festlegen: ohne -b bestimmt die Umgebung
    // (init.defaultBranch) den Namen, und der checkout unten würde auf Rechnern
    // mit abweichender Git-Konfiguration fehlschlagen.
    _ = try await completedGit(["init", "-q", "-b", "main"], in: root)
    _ = try await completedGit(["config", "user.name", "Fastra Test"], in: root)
    _ = try await completedGit(["config", "user.email", "test@example.invalid"], in: root)
    let file = root.appendingPathComponent("konflikt.txt")
    try Data("basis\n".utf8).write(to: file)
    _ = try await completedGit(["add", "--", "konflikt.txt"], in: root)
    _ = try await completedGit(["commit", "-q", "-m", "base"], in: root)
    _ = try await completedGit(["checkout", "-q", "-b", "seite"], in: root)
    try Data("seite\n".utf8).write(to: file)
    _ = try await completedGit(["commit", "-qam", "seite"], in: root)
    _ = try await completedGit(["checkout", "-q", "main"], in: root)
    try Data("main\n".utf8).write(to: file)
    _ = try await completedGit(["commit", "-qam", "main"], in: root)
    _ = try await completedGit(["merge", "seite"], acceptedExitCodes: [1], in: root)
    let result = try await completedGit(
        ["diff", "--cc", "--no-color", "--no-ext-diff", "--no-textconv"], in: root
    )
    let document = GitDiffParser.parse(result.stdoutData)
    guard case .combinedDiff(let unified) = document.limitation else {
        Issue.record("Realer Konflikt wurde nicht als Combined-Diff erkannt")
        return
    }
    #expect(unified.contains("diff --cc konflikt.txt"))
    #expect(unified.contains("@@@"))
}

private enum DiffTestFailure: Error {
    case outcome(GitExecutionOutcome)
    case exit(Int32, String)
}

private func completedGit(_ arguments: [String], acceptedExitCodes: Set<Int32> = [0],
                          in root: URL) async throws -> GitResult {
    let outcome = await withCheckedContinuation { continuation in
        GitRunner.runDetailed(arguments, in: root) { continuation.resume(returning: $0) }
    }
    guard case .completed(let result) = outcome else { throw DiffTestFailure.outcome(outcome) }
    guard acceptedExitCodes.contains(result.exitCode) else {
        throw DiffTestFailure.exit(result.exitCode, result.stderrForDisplay)
    }
    return result
}

private final class ControlledDiffExecutor: GitCommandExecuting {
    final class Cancellation: GitCancelling {
        private(set) var cancelled = false
        func cancel() { cancelled = true }
    }
    struct Call {
        let arguments: [String]
        let cancellation: Cancellation
        let completion: (GitExecutionOutcome) -> Void
    }
    private var calls: [Call] = []
    private let lock = NSLock()
    var count: Int { lock.withLock { calls.count } }
    func arguments(_ index: Int) -> [String] { lock.withLock { calls[index].arguments } }
    func isCancelled(_ index: Int) -> Bool { lock.withLock { calls[index].cancellation.cancelled } }
    @discardableResult
    func execute(arguments: [String], in directory: URL, outputLimit: GitOutputLimit,
                 policy: GitExecutionPolicy,
                 completion: @escaping (GitExecutionOutcome) -> Void) -> GitCancelling {
        let cancellation = Cancellation()
        lock.withLock { calls.append(Call(arguments: arguments, cancellation: cancellation,
                                          completion: completion)) }
        return cancellation
    }
    func complete(_ index: Int, result: GitResult) {
        let completion = lock.withLock { calls[index].completion }
        completion(.completed(result))
    }
}

private func makeDiffWorkspace() async throws
    -> (ControlledDiffExecutor, Workspace, UserDefaults, String, URL) {
    let executor = ControlledDiffExecutor()
    let coordinator = GitOperationsCoordinator(executor: executor)
    let store = GitRepositoryStore(executor: executor, coordinator: coordinator)
    let suite = "Fastra-DiffLifecycle-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let workspace = Workspace(defaults: defaults, gitOperationsCoordinator: coordinator,
                              gitRepositoryStore: store)
    let repo = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-controlled-diff-\(UUID().uuidString)")
    workspace.openProject(at: repo)
    let oid = "abc123"
    executor.complete(0, result: GitResult(exitCode: 0,
                                           stdoutData: porcelainDiffSnapshot(oid),
                                           stderrData: Data()))
    executor.complete(1, result: GitResult(exitCode: 0,
                                           stdoutData: Data(),
                                           stderrData: Data()))
    executor.complete(2, result: GitResult(exitCode: 0,
                                           stdoutData: Data("main\t*\n".utf8),
                                           stderrData: Data()))
    executor.complete(3, result: GitResult(exitCode: 0,
                                           stdoutData: graphDiffSnapshot(oid),
                                           stderrData: Data()))
    // Der Store publiziert den vollständigen Snapshot bewusst auf Main. Erst
    // danach dürfen Lifecycle-Tests einen Diff-Tab öffnen, sonst kann die noch
    // ausstehende Graph-Aktualisierung dessen erste Generation abbrechen.
    try await waitForDiffState("Initialer Repository-Snapshot wurde nicht publiziert") {
        workspace.gitStatus?.headOID == oid
    }
    return (executor, workspace, defaults, suite, repo)
}

private func porcelainDiffSnapshot(_ oid: String) -> Data {
    var data = Data()
    for record in ["# branch.oid \(oid)", "# branch.head main"] {
        data.append(Data(record.utf8)); data.append(0)
    }
    return data
}

private func graphDiffSnapshot(_ oid: String) -> Data {
    var data = Data("\u{1e}\(oid)\u{1f}\u{1f}Test\u{1f}2026-07-15\u{1f}1\u{1f}HEAD -> main\u{1f}Test".utf8)
    data.append(0)
    return data
}

private func gitResult(_ text: String, exitCode: Int32 = 0) -> GitResult {
    GitResult(exitCode: exitCode, stdoutData: Data(text.utf8), stderrData: Data())
}

@Test("Geschlossener Diff-Tab wird durch verspätete Completion nicht neu angelegt")
func sideBySideClosedTabStaysClosed() async throws {
    guard GitRunner.isAvailable else { return }
    let (executor, workspace, defaults, suite, _) = try await makeDiffWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }
    workspace.openGitChangeDiff(change: GitChange(path: "a.txt", staged: nil,
                                                  unstaged: .modified), staged: false)
    #expect(executor.count == 5)
    let tabID = try? #require(workspace.tabs.first(where: { $0.gitDiffRequest != nil })?.id)
    guard let tabID else { return }
    workspace.closeTab(id: tabID)
    #expect(executor.isCancelled(4))
    executor.complete(4, result: gitResult(normalPatch))
    #expect(!workspace.tabs.contains(where: { $0.id == tabID }))
    #expect(!workspace.tabs.contains(where: { $0.gitDiffRequest != nil }))
}

@Test("Trailing Diff-Refresh gewinnt gegen laufenden alten Read")
func sideBySideRefreshDoesNotDeduplicateRunningRead() async throws {
    guard GitRunner.isAvailable else { return }
    let (executor, workspace, defaults, suite, _) = try await makeDiffWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }
    let change = GitChange(path: "a.txt", staged: nil, unstaged: .modified)
    workspace.openGitChangeDiff(change: change, staged: false)
    workspace.refreshOpenGitDiffTabs()
    #expect(executor.count == 5)
    #expect(executor.isCancelled(4))
    executor.complete(4, result: gitResult(normalPatch.replacingOccurrences(of: "neu value",
                                                                             with: "alt-read")))
    try await waitForDiffState("Trailing Refresh wurde nicht gestartet") {
        executor.count >= 6
    }
    executor.complete(5, result: gitResult(normalPatch.replacingOccurrences(of: "neu value",
                                                                             with: "fresh-read")))
    try await waitForDiffState("Trailing Refresh wurde nicht im Tab publiziert") {
        workspace.tabs.first(where: { $0.gitDiffRequest != nil })?.gitDiffDocument?
            .hunks.flatMap(\.rows).contains(where: { $0.after == "fresh-read" }) == true
    }
    let document = try #require(
        workspace.tabs.first(where: { $0.gitDiffRequest != nil })?.gitDiffDocument
    )
    let rows = try #require(document.hunks.first).rows
    #expect(rows.contains(where: { $0.after == "fresh-read" }))
    #expect(!rows.contains(where: { $0.after == "alt-read" }))
}

@Test("Untracked Diff akzeptiert Exit 1 auch beim Refresh")
func sideBySideUntrackedRefreshAcceptsDifferenceExit() async throws {
    guard GitRunner.isAvailable else { return }
    let (executor, workspace, defaults, suite, _) = try await makeDiffWorkspace()
    defer { defaults.removePersistentDomain(forName: suite) }
    let change = GitChange(path: "neu.txt", staged: nil, unstaged: .untracked)
    workspace.openGitChangeDiff(change: change, staged: false)
    #expect(executor.arguments(4).contains("--no-index"))
    executor.complete(4, result: gitResult(normalPatch, exitCode: 1))
    try await waitForDiffState("Erster Untracked-Diff wurde nicht publiziert") {
        workspace.tabs.first(where: { $0.gitDiffRequest != nil })?.gitDiffDocument?
            .hunks.isEmpty == false
    }
    workspace.refreshOpenGitDiffTabs()
    try await waitForDiffState("Untracked-Refresh wurde nicht gestartet") {
        executor.count >= 6
    }
    #expect(executor.arguments(5).contains("--no-index"))
    let refreshedPatch = normalPatch.replacingOccurrences(of: "neu value",
                                                           with: "refresh-read")
    executor.complete(5, result: gitResult(refreshedPatch, exitCode: 1))
    try await waitForDiffState("Untracked-Refresh wurde nicht im Tab publiziert") {
        workspace.tabs.first(where: { $0.gitDiffRequest != nil })?.gitDiffDocument?
            .hunks.flatMap(\.rows).contains(where: { $0.after == "refresh-read" }) == true
    }
    let document = try #require(
        workspace.tabs.first(where: { $0.gitDiffRequest != nil })?.gitDiffDocument
    )
    #expect(document.limitation == nil)
    #expect(!document.hunks.isEmpty)
}

private struct DiffStateTimeout: Error {}

private func waitForDiffState(_ description: String, timeout: Duration = .seconds(3),
                              _ condition: @escaping () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record(Comment(rawValue: description))
    throw DiffStateTimeout()
}
