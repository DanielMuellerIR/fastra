import Foundation
import Testing
@testable import Fastra

@Suite("Git-Branch-Auswahl")
struct GitBranchTests {
    @Test("Parser erkennt aktuellen Branch und behält Leerzeichen")
    func parsesBranches() {
        let branches = GitBranchList.parse("feature/eins\t \nmain\t*\nmit leerzeichen\t \n")
        #expect(branches.map(\.name) == ["feature/eins", "main", "mit leerzeichen"])
        #expect(branches.map(\.isCurrent) == [false, true, false])
        #expect(branches.allSatisfy { $0.blockingWorktree == nil })
    }

    @Test("Leere Zeilen werden ignoriert")
    func ignoresEmptyLines() {
        #expect(GitBranchList.parse("\n\n").isEmpty)
    }

    @Test("Ein fremdes Arbeitsverzeichnis blockiert den Branch")
    func marksBranchHeldByAnotherWorktree() {
        let branches = GitBranchList.parse(
            "feature\t \t/pfad/zum/worktree\nmain\t*\t/pfad/zum/projekt\n"
        )
        #expect(branches.first?.blockingWorktree == "/pfad/zum/worktree")
        // Der EIGENE Worktree steht ebenfalls in der Ausgabe. Er blockiert
        // nichts — sonst gälte der aktuelle Branch als unerreichbar.
        #expect(branches.last?.isCurrent == true)
        #expect(branches.last?.blockingWorktree == nil)
    }

    @Test("Ein Tab im Verzeichnisnamen zerlegt die Zeile nicht")
    func keepsTabsInsideWorktreePath() {
        let branches = GitBranchList.parse("feature\t \t/pfad/mit\ttab\n")
        #expect(branches.first?.blockingWorktree == "/pfad/mit\ttab")
    }

    @Test("Ohne Worktree-Feld bleibt der Branch frei (ältere git-Ausgabe)")
    func toleratesMissingWorktreeField() {
        let branches = GitBranchList.parse("feature\t \n")
        #expect(branches.first?.blockingWorktree == nil)
    }

    @Test("Absagetext nennt Branch, Verzeichnis und den Weg nach vorn")
    func blockTextNamesWayForward() {
        let existing = GitBranchWorktreeBlock(branch: "topic", worktree: "/tmp/wt",
                                              worktreeExists: true)
        #expect(existing.informativeText.contains("topic"))
        #expect(existing.informativeText.contains("/tmp/wt"))
        // Ein noch vorhandener Ordner lässt sich öffnen — der Rat, ihn mit
        // `git worktree prune` abzumelden, gehört nur in den anderen Fall.
        #expect(!existing.informativeText.contains("prune"))
        let gone = GitBranchWorktreeBlock(branch: "topic", worktree: "/tmp/wt",
                                          worktreeExists: false)
        #expect(gone.informativeText.contains("prune"))
        #expect(gone.informativeText != existing.informativeText)
    }

    /// Beide Sprachfassungen müssen den Absagetext vollständig führen — ein
    /// fehlender Eintrag fiele sonst erst dem englischsprachigen Nutzer auf.
    @Test("Absagetext ist in Deutsch und Englisch übersetzt", arguments: ["de", "en"])
    func blockTextIsLocalized(language: String) {
        let advice = L10n.string("Du kannst dieses Arbeitsverzeichnis als Projekt öffnen — der gesuchte Stand liegt dort schon.",
                                 language: language)
        let prune = L10n.string("Der Ordner existiert nicht mehr. Melde ihn mit „git worktree prune“ ab, danach ist der Branch wieder frei.",
                                language: language)
        let title = L10n.string("Branch-Wechsel nicht möglich", language: language)
        let button = L10n.string("Arbeitsverzeichnis öffnen", language: language)
        if language == "en" {
            #expect(advice.contains("working tree"))
            #expect(prune.contains("prune"))
            #expect(title == "Cannot Switch Branch")
            #expect(button == "Open Working Tree")
        } else {
            #expect(advice.contains("Projekt"))
            #expect(prune.contains("prune"))
            #expect(title.contains("nicht möglich"))
            #expect(button.contains("Arbeitsverzeichnis"))
        }
    }

    /// Der Beweis, dass die Zerlegung oben die echte git-Ausgabe trifft — und
    /// zugleich der Beleg, warum das nötig ist: `git switch` weist denselben
    /// Branch in einem zweiten Arbeitsverzeichnis hart ab.
    @Test("Echtes git: verlinkter Worktree belegt den Branch")
    func realGitReportsBlockingWorktree() async throws {
        guard GitRunner.isAvailable else { return }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fastra-BranchWorktree-\(UUID().uuidString)")
        let primary = base.appendingPathComponent("projekt")
        let linked = base.appendingPathComponent("zweitkopie")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        _ = try await requireBranchGit(["init", "-q", "-b", "main"], in: primary)
        _ = try await requireBranchGit(["config", "user.name", "Fastra Test"], in: primary)
        _ = try await requireBranchGit(["config", "user.email", "fastra@example.test"],
                                       in: primary)
        try Data("basis\n".utf8).write(to: primary.appendingPathComponent("a.txt"))
        _ = try await requireBranchGit(["add", "a.txt"], in: primary)
        _ = try await requireBranchGit(["commit", "-q", "-m", "Basis"], in: primary)
        _ = try await requireBranchGit(["branch", "frei"], in: primary)
        _ = try await requireBranchGit(["worktree", "add", "-q", "-b", "belegt",
                                        linked.path, "main"], in: primary)

        let listed = try await requireBranchGit(GitBranchList.arguments, in: primary)
        let branches = GitBranchList.parse(listed.stdout)
        let blocked = try #require(branches.first { $0.name == "belegt" })
        let resolved = URL(fileURLWithPath: blocked.blockingWorktree ?? "")
            .resolvingSymlinksInPath().path
        #expect(resolved == linked.resolvingSymlinksInPath().path)
        #expect(branches.first { $0.name == "frei" }?.blockingWorktree == nil)
        #expect(branches.first { $0.name == "main" }?.isCurrent == true)
        #expect(branches.first { $0.name == "main" }?.blockingWorktree == nil)

        // Ohne diese Kenntnis böte die Branch-Auswahl einen Wechsel an, den
        // git anschließend mit Exit 128 abweist.
        let refused = try await requireBranchGit(["switch", "belegt"], in: primary,
                                                 expectedExit: 128)
        #expect(!refused.ok)
    }
}

private func requireBranchGit(_ arguments: [String], in repository: URL,
                              expectedExit: Int32 = 0) async throws -> GitResult {
    let outcome: GitExecutionOutcome = await withCheckedContinuation { continuation in
        _ = GitRunner.runDetailed(arguments, in: repository) {
            continuation.resume(returning: $0)
        }
    }
    guard case .completed(let result) = outcome else {
        Issue.record("git \(arguments.joined(separator: " ")) lief nicht: \(outcome)")
        throw GitBranchTestFailure()
    }
    if result.exitCode != expectedExit {
        let joined = arguments.joined(separator: " ")
        let message: String = "git \(joined) endete mit \(result.exitCode) statt "
            + "\(expectedExit): \(result.stderrForDisplay)"
        Issue.record(Comment(rawValue: message))
    }
    return result
}

private struct GitBranchTestFailure: Error {}
