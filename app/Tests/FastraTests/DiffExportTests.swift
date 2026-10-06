import Foundation
import Testing
@testable import Fastra

struct DiffExportTests {
    private func snapshot(_ left: String, _ right: String,
                          options: FileDiffOptions = .init(), source: URL? = nil) throws -> DiffExportSnapshot {
        guard case .result(let result) = FileDiff.compare(left: left, right: right, options: options) else {
            throw NSError(domain: "DiffExportTests", code: 1)
        }
        return .file(FileDiffRequest(left: .text(left, name: "Links", path: source?.path),
                                     right: .text(right, name: "Rechts"), options: options), result)
    }

    @Test("Bericht erhält Originalzeilen, getrennte Blöcke und verschobene Zeilennummern")
    func originalRowsAndRanges() throws {
        let options = FileDiffOptions(ignoreTrailingWhitespace: true, ignoreCase: true)
        let value = try snapshot("GLEICH  \nALT  \nmitte\nENDE", "gleich\nNEU \nzusatz\nmitte\nanders", options: options)
        let report = value.report()
        #expect(report.contains("- 2 | ALT  \n"))
        #expect(report.contains("+ 2 | NEU \n+ 3 | zusatz\n"))
        #expect(report.contains("- 4 | ENDE\n+ 5 | anders\n"))
        #expect(!report.contains("- 1 |"))
        #expect(report.contains(FileDiffView.optionsSummary(options)))
    }

    @Test("Neue Datei wird atomar als UTF-8 gespeichert; spätere Quellenänderung verändert den Bericht nicht")
    func savedSnapshot() throws {
        let base = testTemporaryDirectory().appendingPathComponent("export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Original #1 🇩🇪.txt")
        try "alt".write(to: source, atomically: true, encoding: .utf8)
        let value = try snapshot("alt 🇩🇪", "neu é", source: source)
        try "später".write(to: source, atomically: true, encoding: .utf8)
        let target = base.appendingPathComponent("Bericht.txt")
        try DiffExport.write(value, to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == value.report())
        #expect(try String(contentsOf: source, encoding: .utf8) == "später")
    }

    @Test("Original, Symlink und Hardlink bleiben beim versehentlichen Exportziel geschützt")
    func sourceProtection() throws {
        let base = testTemporaryDirectory().appendingPathComponent("export-protected-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Original.txt")
        try "Original bleibt".write(to: source, atomically: true, encoding: .utf8)
        let symlink = base.appendingPathComponent("Verweis.txt")
        let hardlink = base.appendingPathComponent("Zweiter Name.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        try FileManager.default.linkItem(at: source, to: hardlink)
        let value = try snapshot("alt", "neu", source: source)
        for target in [source, symlink, hardlink] {
            #expect(throws: NSError.self) { try DiffExport.write(value, to: target) }
            #expect(try String(contentsOf: target, encoding: .utf8) == "Original bleibt")
        }
    }

    @Test("Git-Bericht enthält alle Änderungsblöcke, Dateinamen, fehlenden Endumbruch und Binärgrenze")
    func gitRowsAndLimitations() {
        let patch = """
        diff --git a/eins.txt b/eins.txt
        --- a/eins.txt
        +++ b/eins.txt
        @@ -1,3 +1,3 @@
        -alt
        +neu
         mitte
        -ende
        +schluss
        \\ No newline at end of file
        diff --git a/zwei.bin b/zwei.bin
        Binary files a/zwei.bin and b/zwei.bin differ
        """
        let document = GitDiffParser.parse(Data(patch.utf8))
        let request = GitDiffRequest(repositoryPath: "/unused", source: .workingTree(path: nil))
        let report = DiffExportSnapshot.git(request, document).report()
        #expect(GitDiffDisplay.entries(document: document).count == 2)
        #expect(report.contains("eins.txt"))
        #expect(report.contains("- 1 | alt\n+ 1 | neu\n"))
        #expect(report.contains("- 3 | ende\n+ 3 | schluss\n"))
        #expect(report.contains(L10n.string("  Rechte Zeile ohne abschließenden Zeilenumbruch.")))
        #expect(report.contains(document.files.last!.limitation!.explanation))
        #expect(report.contains("zwei.bin"))
    }

    @Test("Identischer Vergleich hat null Unterschiede, globale Git-Grenze wird ausdrücklich berichtet")
    func emptyAndLimited() throws {
        let value = try snapshot("gleich", "gleich")
        #expect(value.report().contains(L10n.format("Unterschiede: %ld", 0)))
        let document = GitDiffDocument(files: [], limitation: .outputTruncated(retainedBytes: 42))
        let request = GitDiffRequest(repositoryPath: "/unused", source: .workingTree(path: nil))
        #expect(DiffExportSnapshot.git(request, document).report().contains(document.limitation!.explanation))
    }
}
