import Foundation
import Testing
@testable import Fastra

private func porcelain(_ records: String...) -> Data {
    porcelain(records)
}

private func porcelain(_ records: [String]) -> Data {
    var data = Data()
    for record in records {
        data.append(Data(record.utf8))
        data.append(0)
    }
    return data
}

private func ordinary(_ xy: String, _ path: String) -> String {
    "1 \(xy) N... 100644 100644 100644 aaaaaaa bbbbbbb \(path)"
}

@Suite("Git-Status Porcelain v2")
struct GitStatusParserTests {
    @Test("Argumente fordern NUL-sicheres Porcelain v2 mit Branchdaten")
    func arguments() {
        #expect(GitStatusParser.arguments.contains("--porcelain=v2"))
        #expect(GitStatusParser.arguments.contains("--branch"))
        #expect(GitStatusParser.arguments.contains("-z"))
    }

    @Test("Branch, exakter HEAD, Upstream und Ahead/Behind")
    func branchAheadBehind() {
        let summary = GitStatusParser.parse(porcelain(
            "# branch.oid 0123456789abcdef",
            "# branch.head feature/überblick",
            "# branch.upstream origin/feature/überblick",
            "# branch.ab +2 -3"
        ))
        #expect(summary.branch == "feature/überblick")
        #expect(summary.headOID == "0123456789abcdef")
        #expect(summary.upstream == "origin/feature/überblick")
        #expect(summary.ahead == 2)
        #expect(summary.behind == 3)
        #expect(!summary.isDetached)
    }

    @Test("Branch ohne Upstream hat keine erfundenen Zähler")
    func branchWithoutUpstream() {
        let summary = GitStatusParser.parse(porcelain(
            "# branch.oid abc", "# branch.head main"
        ))
        #expect(summary.branch == "main")
        #expect(summary.upstream == nil)
        #expect(summary.ahead == 0)
        #expect(summary.behind == 0)
    }

    @Test("Repository ohne Commit behält Branch und hat keine HEAD-OID")
    func unbornBranch() {
        let summary = GitStatusParser.parse(porcelain(
            "# branch.oid (initial)", "# branch.head main"
        ))
        #expect(summary.branch == "main")
        #expect(summary.headOID == nil)
    }

    @Test("Detached HEAD wird unabhängig von Decorations erkannt")
    func detachedHead() {
        let summary = GitStatusParser.parse(porcelain(
            "# branch.oid deadbeef", "# branch.head (detached)"
        ))
        #expect(summary.branch == nil)
        #expect(summary.isDetached)
        #expect(summary.headOID == "deadbeef")
    }

    @Test("Dateizustände bleiben nach Index und Arbeitsbaum getrennt")
    func fileStates() {
        let summary = GitStatusParser.parse(porcelain(
            ordinary(".M", "app/geändert.swift"),
            "? neu.txt",
            ordinary("A.", "gestaged.swift"),
            ordinary(".D", "gelöscht.swift"),
            ordinary("MM", "beides.swift")
        ))
        #expect(summary.entries["app/geändert.swift"] == .modified)
        #expect(summary.entries["neu.txt"] == .untracked)
        #expect(summary.entries["gestaged.swift"] == .added)
        #expect(summary.entries["gelöscht.swift"] == .deleted)
        #expect(summary.changes.last?.staged == .modified)
        #expect(summary.changes.last?.unstaged == .modified)
    }

    @Test("Rename hält NUL-getrennten Ziel- und Quellpfad")
    func renamed() {
        let summary = GitStatusParser.parse(porcelain(
            "2 R. N... 100644 100644 100644 aaaaaaa bbbbbbb R100 neu\tname.swift",
            "alt\nname.swift"
        ))
        #expect(summary.entries["neu\tname.swift"] == .renamed)
        #expect(summary.entries["alt\nname.swift"] == nil)
        #expect(summary.changes == [GitChange(path: "neu\tname.swift",
                                             originalPath: "alt\nname.swift",
                                             staged: .renamed, unstaged: nil)])
    }

    @Test("Unmerged-Datensatz wird als Konflikt erkannt")
    func conflict() {
        let record = "u UU N... 100644 100644 100644 100644 aaaaaaa bbbbbbb ccccccc streit.swift"
        let summary = GitStatusParser.parse(porcelain(record))
        #expect(summary.entries["streit.swift"] == .conflicted)
        #expect(summary.changes[0].unstaged == .conflicted)
    }

    @Test("Leerzeichen, Nicht-ASCII, Tab und Zeilenumbruch bleiben unverändert")
    func unusualPaths() {
        let paths = ["ordner/mit leer.txt", "grüße/東京.txt", "tab\tdatei", "zeile\ndatei"]
        let summary = GitStatusParser.parse(porcelain(paths.map { ordinary(".M", $0) }))
        #expect(Set(summary.entries.keys) == Set(paths))
        #expect(summary.changes.map(\.path) == paths)
    }

    @Test("Leere Ausgabe ergibt leeren Summary")
    func empty() {
        #expect(GitStatusParser.parse(Data()) == GitStatusSummary.empty)
    }

    @Test("Ungültige UTF-8-Pfade bleiben roh eindeutig und sind nicht adressierbar")
    func invalidUTF8Paths() {
        let prefix = Data("1 .M N... 100644 100644 100644 aaaaaaa bbbbbbb ".utf8)
        var output = Data()
        output.append(prefix); output.append(contentsOf: [0xff]); output.append(0)
        output.append(prefix); output.append(contentsOf: [0xfe]); output.append(0)

        let summary = GitStatusParser.parse(output)
        #expect(summary.changes.count == 2)
        #expect(summary.changes[0].path == summary.changes[1].path)
        #expect(summary.changes[0].id != summary.changes[1].id)
        #expect(summary.changes.allSatisfy { !$0.isPathActionable })
        #expect(summary.changes.allSatisfy { $0.actionPath == nil })
        #expect(summary.entries.isEmpty)
    }
}
