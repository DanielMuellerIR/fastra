// GitStatusParserTests.swift
//
// Tests für das Parsen von `git status --porcelain=v1 -b` (Projekt- &
// Git-Ausbau, Etappe 2). Rein funktional — kein echtes Repo nötig.

import Foundation
import Testing
@testable import Fastra

@Test("Branch mit Upstream und Ahead/Behind")
func status_branchAheadBehind() {
    let out = "## main...origin/main [ahead 2, behind 3]\n"
    let s = GitStatusParser.parse(out)
    #expect(s.branch == "main")
    #expect(s.ahead == 2)
    #expect(s.behind == 3)
}

@Test("Branch nur ahead")
func status_branchAheadOnly() {
    let s = GitStatusParser.parse("## feature/x...origin/feature/x [ahead 1]\n")
    #expect(s.branch == "feature/x")
    #expect(s.ahead == 1)
    #expect(s.behind == 0)
}

@Test("Branch ohne Upstream → Name, keine Zähler")
func status_branchNoUpstream() {
    let s = GitStatusParser.parse("## main\n")
    #expect(s.branch == "main")
    #expect(s.ahead == 0)
    #expect(s.behind == 0)
}

@Test("Frisches Repo ohne Commits")
func status_noCommitsYet() {
    let s = GitStatusParser.parse("## No commits yet on main\n")
    #expect(s.branch == "main")
}

@Test("Detached HEAD → branch nil")
func status_detachedHead() {
    let s = GitStatusParser.parse("## HEAD (no branch)\n")
    #expect(s.branch == nil)
}

@Test("Dateizustände: modified, untracked, added, deleted")
func status_fileStates() {
    let out = """
    ## main
     M app/geändert.swift
    ?? neu.txt
    A  gestaged.swift
     D geloescht.swift
    """
    let s = GitStatusParser.parse(out)
    #expect(s.entries["app/geändert.swift"] == .modified)
    #expect(s.entries["neu.txt"] == .untracked)
    #expect(s.entries["gestaged.swift"] == .added)
    #expect(s.entries["geloescht.swift"] == .deleted)
}

@Test("Umbenennung: neuer Pfad, Zustand renamed")
func status_renamed() {
    let s = GitStatusParser.parse("## main\nR  alt.swift -> neu.swift\n")
    #expect(s.entries["neu.swift"] == .renamed)
    #expect(s.entries["alt.swift"] == nil)
}

@Test("Merge-Konflikt (UU) → conflicted")
func status_conflict() {
    let s = GitStatusParser.parse("## main\nUU streit.swift\n")
    #expect(s.entries["streit.swift"] == .conflicted)
}

@Test("Zitierter Pfad (Sonderzeichen) wird entklammert")
func status_quotedPath() {
    let s = GitStatusParser.parse("## main\n M \"mit leer.txt\"\n")
    #expect(s.entries["mit leer.txt"] == .modified)
}

@Test("Leere Ausgabe → leerer Summary")
func status_empty() {
    #expect(GitStatusParser.parse("") == GitStatusSummary.empty)
}

@Test("Sauberer Baum: Branch da, keine Einträge")
func status_cleanTree() {
    let s = GitStatusParser.parse("## main...origin/main\n")
    #expect(s.branch == "main")
    #expect(s.entries.isEmpty)
}
