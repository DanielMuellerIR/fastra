import Foundation
import Testing
@testable import Fastra

@Suite("Git-Branch-Auswahl")
struct GitBranchTests {
    @Test("Parser erkennt aktuellen Branch und behält Leerzeichen")
    func parsesBranches() {
        let branches = GitBranchList.parse(
            "feature/eins\t \0\nmain\t*\0\nmit leerzeichen\t \0\n"
        )
        #expect(branches.map(\.name) == ["feature/eins", "main", "mit leerzeichen"])
        #expect(branches.map(\.isCurrent) == [false, true, false])
        #expect(branches.allSatisfy { $0.blockingWorktree == nil })
    }

    @Test("Leere Datensätze werden ignoriert")
    func ignoresEmptyLines() {
        #expect(GitBranchList.parse("\0\n\0\n").isEmpty)
        // Ein Repository ohne lokale Branches liefert gar nichts.
        #expect(GitBranchList.parse("").isEmpty)
    }

    /// Kürzt `GitRunner` die Ausgabe an der Byte-Grenze, endet der letzte
    /// Datensatz ohne Nullbyte. Sein halber Branchname darf nicht ins Menü —
    /// ein Klick darauf startete `git switch` mit einem Namen, den es nicht
    /// gibt.
    @Test("Ein abgeschnittener letzter Datensatz zählt nicht")
    func ignoresTruncatedTrailingRecord() {
        let branches = GitBranchList.parse("main\t*\0\nfeature/lang")
        #expect(branches.map(\.name) == ["main"])
    }

    @Test("Ein fremdes Arbeitsverzeichnis blockiert den Branch")
    func marksBranchHeldByAnotherWorktree() {
        let branches = GitBranchList.parse(
            "feature\t \t/pfad/zum/worktree\0\nmain\t*\t/pfad/zum/projekt\0\n"
        )
        #expect(branches.first?.blockingWorktree == "/pfad/zum/worktree")
        // Der EIGENE Worktree steht ebenfalls in der Ausgabe. Er blockiert
        // nichts — sonst gälte der aktuelle Branch als unerreichbar.
        #expect(branches.last?.isCurrent == true)
        #expect(branches.last?.blockingWorktree == nil)
    }

    @Test("Ein Tab im Verzeichnisnamen zerlegt die Zeile nicht")
    func keepsTabsInsideWorktreePath() {
        let branches = GitBranchList.parse("feature\t \t/pfad/mit\ttab\0\n")
        #expect(branches.first?.blockingWorktree == "/pfad/mit\ttab")
    }

    /// macOS erlaubt in Verzeichnisnamen jedes Zeichen außer `/` und NUL —
    /// auch Zeilenumbrüche und die exotischen Trenner U+0085/U+2028/U+2029.
    /// Eine zeilenweise Zerlegung hätte daraus einen zweiten, erfundenen
    /// Branch gemacht, dessen Anklicken `git switch <Pfadrest>` gestartet
    /// hätte. Der Datensatz endet deshalb am Nullbyte.
    @Test("Zeilentrenner im Verzeichnisnamen erzeugen keinen Phantom-Branch",
          arguments: ["\n", "\r", "\u{0085}", "\u{2028}", "\u{2029}"])
    func keepsLineSeparatorsInsideWorktreePath(separator: String) {
        let pfad = "/pfad/mit\(separator)umbruch"
        let branches = GitBranchList.parse("feature\t \t\(pfad)\0\nmain\t*\t/projekt\0\n")
        #expect(branches.map(\.name) == ["feature", "main"])
        #expect(branches.first?.blockingWorktree == pfad)
    }

    @Test("Ohne Worktree-Feld bleibt der Branch frei (ältere git-Ausgabe)")
    func toleratesMissingWorktreeField() {
        let branches = GitBranchList.parse("feature\t \0\n")
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

    /// Nur die ENGLISCHE Seite ist hier prüfbar: Deutsch ist die Quellsprache,
    /// unter `Resources/` liegt allein `en.lproj`, und `L10n.string(_:language:)`
    /// gibt ohne passendes `lproj` den Schlüssel selbst zurück. Ein „de"-Arm
    /// vergliche also das Testliteral mit sich selbst und könnte nie
    /// fehlschlagen. Dass die deutschen Quellstrings vollständig sind, hält
    /// stattdessen `localization-audit.sh` durch.
    @Test("Absagetext ist ins Englische übersetzt")
    func blockTextIsLocalized() {
        let advice = L10n.string("Du kannst dieses Arbeitsverzeichnis als Projekt öffnen — der gesuchte Stand liegt dort schon.",
                                 language: "en")
        let prune = L10n.string("Der Ordner existiert nicht mehr. Melde ihn mit „git worktree prune“ ab, danach ist der Branch wieder frei.",
                                language: "en")
        let title = L10n.string("Branch-Wechsel nicht möglich", language: "en")
        let button = L10n.string("Arbeitsverzeichnis öffnen", language: "en")
        #expect(advice.contains("working tree"))
        #expect(prune.contains("prune"))
        #expect(title == "Cannot Switch Branch")
        #expect(button == "Open Working Tree")
    }

    /// Der Beweis, dass die Zerlegung oben die echte git-Ausgabe trifft — und
    /// zugleich der Beleg, warum das nötig ist: `git switch` weist denselben
    /// Branch in einem zweiten Arbeitsverzeichnis hart ab.
    @Test("Echtes git: verlinkter Worktree belegt den Branch")
    func realGitReportsBlockingWorktree() async throws {
        guard GitRunner.isAvailable else { return }
        let base = testTemporaryDirectory()
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
