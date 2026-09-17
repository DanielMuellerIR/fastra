import AppKit
import Foundation
import Testing
@testable import Fastra

/// Der gemerkte Branch-Stand darf einen Fehlschlag nur dann erklären, wenn git
/// wirklich diese Ursache genannt hat. Sonst verschluckt die freundliche
/// Erklärung die echte Meldung — und das angebotene „Arbeitsverzeichnis
/// öffnen" führte in ein Verzeichnis, das den Branch gar nicht mehr hält.
@Suite("Absage des Branch-Wechsels zuordnen")
struct GitBranchSwitchFailureTests {
    private func failure(_ stderr: String, exit: Int32 = 128) -> GitResult {
        GitResult(exitCode: exit, stdout: "", stderr: stderr)
    }

    @Test("Nennt git den Pfad, ist es die Worktree-Sperre")
    func recognizesWorktreeBlock() {
        // Beide Sprachfassungen derselben git-Meldung; `GitRunner` setzt
        // bewusst kein `LC_ALL`, die Sprache steht also nicht fest.
        let english = failure(
            "fatal: 'topic' is already used by worktree at '/tmp/wt'\n")
        let german = failure(
            "Schwerwiegend: 'topic' wird bereits von Arbeitsverzeichnis in '/tmp/wt' verwendet\n")
        #expect(GitBranchSwitchFailure.isWorktreeBlock(english, worktree: "/tmp/wt"))
        #expect(GitBranchSwitchFailure.isWorktreeBlock(german, worktree: "/tmp/wt"))
    }

    @Test("Ein anderer Fehlschlag bleibt ein anderer Fehlschlag")
    func otherFailuresStayVisible() {
        // Genau der Fall aus dem Befund: Der gemerkte Stand trägt noch ein
        // blockierendes Verzeichnis, git scheitert aber aus einem anderen
        // Grund. Ohne diese Unterscheidung sähe der Nutzer die Worktree-
        // Erklärung statt der echten Ursache.
        let dirty = failure("error: Your local changes to 'a.txt' would be overwritten\n")
        let missing = failure("fatal: invalid reference: topic\n")
        #expect(!GitBranchSwitchFailure.isWorktreeBlock(dirty, worktree: "/tmp/wt"))
        #expect(!GitBranchSwitchFailure.isWorktreeBlock(missing, worktree: "/tmp/wt"))
    }

    @Test("Ein erfolgreicher Lauf und ein leerer Pfad sind nie die Sperre")
    func successAndEmptyPathAreNoBlock() {
        let ok = GitResult(exitCode: 0, stdout: "", stderr: "")
        #expect(!GitBranchSwitchFailure.isWorktreeBlock(ok, worktree: "/tmp/wt"))
        #expect(!GitBranchSwitchFailure.isWorktreeBlock(failure("egal"), worktree: ""))
    }

    /// Der Beweis am echten git: Die Meldung enthält den Pfad wortwörtlich —
    /// auch dann noch, wenn der Ordner längst gelöscht ist. Genau dieser Fall
    /// bleibt sonst ohne jede Rückmeldung stehen.
    @Test("Echtes git: die Absage nennt den Pfad, auch nach gelöschtem Ordner")
    func realGitNamesTheWorktreePath() async throws {
        guard GitRunner.isAvailable else { return }
        let base = testTemporaryDirectory()
            .appendingPathComponent("Fastra-SwitchFailure-\(UUID().uuidString)")
        let primary = base.appendingPathComponent("projekt")
        let linked = base.appendingPathComponent("zweitkopie")
        try FileManager.default.createDirectory(at: primary,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        func git(_ arguments: [String], expect zero: Bool = true) async throws -> GitResult {
            let outcome: GitExecutionOutcome = await withCheckedContinuation { c in
                _ = GitRunner.runDetailed(arguments, in: primary) { c.resume(returning: $0) }
            }
            guard case .completed(let result) = outcome else {
                throw GitBranchSwitchFailureTestError.notCompleted
            }
            if zero { #expect(result.ok) }
            return result
        }

        _ = try await git(["init", "-q", "-b", "main"])
        _ = try await git(["config", "user.name", "Fastra Test"])
        _ = try await git(["config", "user.email", "fastra@example.test"])
        try Data("basis\n".utf8).write(to: primary.appendingPathComponent("a.txt"))
        _ = try await git(["add", "a.txt"])
        _ = try await git(["commit", "-q", "-m", "Basis"])
        _ = try await git(["worktree", "add", "-q", "-b", "belegt", linked.path, "main"])

        let listed = try await git(GitBranchList.arguments)
        let blocked = try #require(GitBranchList.parse(listed.stdout)
            .first { $0.name == "belegt" }?.blockingWorktree)

        let refused = try await git(["switch", "belegt"], expect: false)
        #expect(!refused.ok)
        #expect(GitBranchSwitchFailure.isWorktreeBlock(refused, worktree: blocked))

        // Und der Fall aus dem Befund: Ordner weg, git weiß noch nichts davon.
        try FileManager.default.removeItem(at: linked)
        let stillRefused = try await git(["switch", "belegt"], expect: false)
        #expect(!stillRefused.ok)
        #expect(GitBranchSwitchFailure.isWorktreeBlock(stillRefused, worktree: blocked))
        #expect(!Workspace.isExistingDirectory(blocked))
    }
}

private enum GitBranchSwitchFailureTestError: Error {
    case notCompleted
}

/// Der Dialog der Worktree-Sperre. Geprüft wird die Zusage, an der die
/// Funktion zerbrach: Er muss AUCH dann erscheinen, wenn der Ordner des
/// fremden Arbeitsverzeichnisses längst gelöscht ist — genau dann trägt er
/// nämlich den einzigen brauchbaren Rat („git worktree prune").
@Suite("Dialog der Worktree-Sperre")
@MainActor
struct GitBranchWorktreeDialogTests {
    private func block(exists: Bool) -> GitBranchWorktreeBlock {
        GitBranchWorktreeBlock(branch: "topic", worktree: "/tmp/wt",
                               worktreeExists: exists)
    }

    @Test("Der Dialog erscheint auch ohne vorhandenen Ordner", arguments: [true, false])
    func dialogIsShownRegardlessOfTheFolder(exists: Bool) {
        var shown: [NSAlert] = []
        let opens = Workspace.gitBranchWorktreeBlockDecision(
            block(exists: exists), dialogsEnabled: true
        ) { alert in
            shown.append(alert)
            return .alertFirstButtonReturn
        }
        #expect(shown.count == 1)
        let alert = try? #require(shown.first)
        #expect(alert?.informativeText == block(exists: exists).informativeText)
        // Ohne Ordner gibt es nur Abbrechen; der erste Knopf darf dann NICHT
        // als „öffnen" gelten.
        #expect(alert?.buttons.count == (exists ? 2 : 1))
        #expect(opens == exists)
    }

    @Test("Abbrechen öffnet nichts, auch wenn der Ordner da ist")
    func cancelNeverOpens() {
        var shown = 0
        let opens = Workspace.gitBranchWorktreeBlockDecision(
            block(exists: true), dialogsEnabled: true
        ) { _ in
            shown += 1
            return .alertSecondButtonReturn
        }
        #expect(shown == 1)
        #expect(!opens)
    }

    @Test("Ohne Dialoge geht die Erklärung nach stderr, ohne Anzeigeschritt")
    func headlessPathSkipsTheDialog() {
        var shown = 0
        let opens = Workspace.gitBranchWorktreeBlockDecision(
            block(exists: true), dialogsEnabled: false
        ) { _ in
            shown += 1
            return .alertFirstButtonReturn
        }
        #expect(shown == 0)
        #expect(!opens)
    }
}
