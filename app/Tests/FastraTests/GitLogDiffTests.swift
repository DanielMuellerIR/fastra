// GitLogDiffTests.swift
//
// Tests für die puren Helfer der Git-Text-Tabs (Etappe 2, Schritt 2+3):
// Commit-Hash-Extraktion aus Log-Zeilen und Diff-Zeilen-Klassifikation.

import Foundation
import Testing
@testable import Fastra

@Test("Commit-Diff zeigt Dateiliste und Patch")
func gitDiff_commitArguments() {
    #expect(GitDiff.showArguments(hash: "abc123")
            == ["show", "--no-color", "--no-ext-diff", "--no-textconv",
                "--stat", "--patch", "abc123"])
}

@Test("Datei-Diff trennt Pfad sicher von git-Optionen")
func gitDiff_fileArguments() {
    #expect(GitDiff.showFileArguments(hash: "abc123", path: "Sources/-test.swift")
            == ["-c", "core.quotePath=false", "--literal-pathspecs", "show",
                "--no-color", "--no-ext-diff", "--no-textconv",
                "--format=", "abc123", "--", "Sources/-test.swift"])
}

@Test("Datei-Diffs trennen Index, Working-Tree und unversionierte Dateien")
func gitDiff_changeFileArguments() {
    let path = "Sources/-test.swift"
    for arguments in [GitDiff.stagedFileArguments(path: path),
                      GitDiff.unstagedFileArguments(path: path),
                      GitDiff.untrackedFileArguments(path: path)] {
        #expect(arguments.contains("--literal-pathspecs"))
        #expect(arguments.contains("core.quotePath=false"))
        #expect(arguments.contains("--no-color"))
        #expect(arguments.contains("--no-ext-diff"))
        #expect(arguments.contains("--no-textconv"))
        #expect(arguments.contains("--"))
        #expect(arguments.last == path)
    }
    #expect(GitDiff.stagedFileArguments(path: path).contains("--cached"))
    #expect(GitDiff.untrackedFileArguments(path: path).contains("--no-index"))
}

// MARK: - git log

@Test("Hash aus einfacher Graph-Zeile")
func log_hashSimple() {
    #expect(GitLog.commitHash(inLine: "* a1b2c3d Erster Commit") == "a1b2c3d")
}

@Test("Hash mit vorangehenden Graph-Verbindungen")
func log_hashWithGraph() {
    #expect(GitLog.commitHash(inLine: "| * 0f1e2d3 (HEAD -> main) Nachricht") == "0f1e2d3")
}

@Test("Reine Verbindungslinie (kein Commit) → nil")
func log_noHashOnConnector() {
    #expect(GitLog.commitHash(inLine: "|/") == nil)
    #expect(GitLog.commitHash(inLine: "| |") == nil)
}

@Test("Zeile ohne Graph-Präfix")
func log_hashNoGraphPrefix() {
    #expect(GitLog.commitHash(inLine: "deadbeef Nachricht") == "deadbeef")
}

@Test("Kein-Hex-Token (Wort) → nil")
func log_wordIsNoHash() {
    #expect(GitLog.commitHash(inLine: "* Merge branch main") == nil)
}

@Test("Voller 40-Zeichen-Hash wird akzeptiert")
func log_fullHash() {
    let full = "0123456789abcdef0123456789abcdef01234567"
    #expect(GitLog.commitHash(inLine: "* \(full) x") == full)
}

// MARK: - git diff

@Test("Hinzugefügte Zeile")
func diff_added() {
    #expect(GitDiff.classify("+neue Zeile") == .added)
}

@Test("Entfernte Zeile")
func diff_removed() {
    #expect(GitDiff.classify("-alte Zeile") == .removed)
}

@Test("+++ und --- sind Datei-Header, nicht added/removed")
func diff_fileHeaderNotContent() {
    #expect(GitDiff.classify("+++ b/datei.txt") == .fileHeader)
    #expect(GitDiff.classify("--- a/datei.txt") == .fileHeader)
}

@Test("diff --git und index sind Datei-Header")
func diff_gitHeaders() {
    #expect(GitDiff.classify("diff --git a/x b/x") == .fileHeader)
    #expect(GitDiff.classify("index 000..111 100644") == .fileHeader)
    #expect(GitDiff.classify("new file mode 100644") == .fileHeader)
}

@Test("Hunk-Kopf")
func diff_hunk() {
    #expect(GitDiff.classify("@@ -1,3 +1,4 @@ func x()") == .hunk)
}

@Test("Commit-Metadaten aus git show")
func diff_commitMeta() {
    #expect(GitDiff.classify("commit a1b2c3d") == .commitMeta)
    #expect(GitDiff.classify("Author: T <t@t>") == .commitMeta)
    #expect(GitDiff.classify("Date:   Mon") == .commitMeta)
}

@Test("Kontextzeile (unverändert)")
func diff_context() {
    #expect(GitDiff.classify(" unverändert") == .context)
    #expect(GitDiff.classify("") == .context)
}
