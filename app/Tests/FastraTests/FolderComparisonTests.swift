import Darwin
import Foundation
import Testing
@testable import Fastra

@Suite("Schreibgeschützter Ordnervergleich")
struct FolderComparisonTests {
    @Test("Verschachtelte Unicode-Pfade, Binärbytes und einseitige Dateien werden exakt zugeordnet")
    func basic() throws {
        try fixture { left, right in
            try write(Data([0, 1, 255]), "über/gleich.bin", in: left)
            try write(Data([0, 1, 255]), "über/gleich.bin", in: right)
            try write(Data("left\r\n".utf8), "über/anders.txt", in: left)
            try write(Data("right\n".utf8), "über/anders.txt", in: right)
            try write(Data(), "links.txt", in: left)
            try write(Data(), "rechts.txt", in: right)
            let result = try FolderComparison.compare(left: left, right: right)
            #expect(result.isComplete)
            let rows = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.path, $0) })
            #expect(rows["über/gleich.bin"]?.status == .identical)
            #expect(rows["über/anders.txt"]?.status == .different)
            #expect(rows["über"]?.status == .different)
            #expect(rows["links.txt"]?.status == .onlyLeft)
            #expect(rows["rechts.txt"]?.status == .onlyRight)
            #expect(rows["über/anders.txt"]?.canOpenPair == true)
            #expect(rows["über"]?.canOpenPair == false)
            #expect(result.budgetBytes == 18)
        }
    }

    @Test("Datei- und Verzeichnissymlinks bleiben sichtbar und werden nicht verfolgt")
    func symlinks() throws {
        try fixture { left, right in
            let external = left.deletingLastPathComponent().appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            try write(Data("secret".utf8), "target.txt", in: external)
            for root in [left, right] {
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.txt"), withDestinationURL: external.appendingPathComponent("target.txt"))
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
            }
            let result = try FolderComparison.compare(left: left, right: right)
            #expect(!result.isComplete)
            #expect(result.rows.count == 2)
            #expect(result.rows.allSatisfy { $0.status == .unavailable && !$0.canOpenPair })
            #expect(result.budgetBytes == 0)
        }
    }

    @Test("Vorhandene Dateityp- und Pfadfilter gelten auf beiden Seiten")
    func filters() throws {
        try fixture { left, right in
            for root in [left, right] {
                try write(Data(), "visible.txt", in: root)
                try write(Data(), "image.bin", in: root)
                try write(Data(), "build/generated.txt", in: root)
                try write(Data(), ".hidden.txt", in: root)
            }
            let result = try FolderComparison.compare(left: left, right: right,
                options: .init(knownTextOnly: true, excludedPatterns: ["build"]))
            #expect(result.isComplete)
            #expect(result.rows.map(\.path) == ["visible.txt"])
        }
    }

    @Test("Ausschlüsse behandeln zusammengesetzte und zerlegte Unicode-Dateinamen gleich", arguments: ["über/*.txt", "u\u{0308}ber/*.txt"])
    func unicodeExclusions(_ pattern: String) throws {
        try fixture { left, right in
            for root in [left, right] {
                try write(Data("excluded".utf8), "über/a.txt", in: root)
                try write(Data(), "keep.txt", in: root)
            }
            let result = try FolderComparison.compare(left: left, right: right,
                options: .init(excludedPatterns: [pattern]))
            #expect(result.isComplete)
            #expect(!result.rows.contains { $0.path.hasSuffix("/a.txt") })
            #expect(result.budgetBytes == 0)
            #expect(PathExclusion.glob(pattern, matches: "über/a.txt"))
            #expect(PathExclusion.glob(pattern, matches: "u\u{0308}ber/a.txt"))
        }
    }

    @Test("Datei-, Gesamtlese- und Eintragsgrenzen melden unvollständige Ergebnisse")
    func limits() throws {
        try fixture { left, right in
            for root in [left, right] { try write(Data([1, 2, 3, 4]), "a.bin", in: root) }
            var options = FolderComparison.Options(); options.maximumFileBytes = 3
            let size = try FolderComparison.compare(left: left, right: right, options: options)
            #expect(!size.isComplete && size.rows.first?.status == .unavailable)
            options.maximumFileBytes = 4; options.maximumTotalBytes = 7
            let total = try FolderComparison.compare(left: left, right: right, options: options)
            #expect(!total.isComplete && total.budgetBytes == 4)
            try write(Data(), "b.txt", in: left)
            options.maximumEntries = 1
            let capped = try FolderComparison.compare(left: left, right: right, options: options)
            #expect(!capped.isComplete && !capped.issues.isEmpty)
            #expect(!capped.rows.contains { $0.status == .onlyLeft || $0.status == .onlyRight })
        }
    }

    @Test("Eintrags- und Besuchslimits bestätigen keinen ungeprüften Unterordner", arguments: [false, true])
    func truncatedDirectory(_ visitedLimit: Bool) throws {
        try fixture { left, right in
            try write(Data("left".utf8), "d/a.txt", in: left)
            try write(Data("right".utf8), "d/a.txt", in: right)
            var options = FolderComparison.Options()
            if visitedLimit { options.maximumVisitedEntries = 1 }
            else { options.maximumEntries = 1 }
            let result = try FolderComparison.compare(left: left, right: right, options: options)
            #expect(!result.isComplete)
            #expect(result.rows.count == 1)
            #expect(result.rows.first?.path == "d")
            #expect(result.rows.first?.status == .unavailable)
            #expect(result.rows.first?.detail != nil)
        }
    }

    @Test("Änderungen nach dem Bytevergleich werden vor dem Ergebnis erkannt")
    func changes() throws {
        try fixture { left, right in
            for root in [left, right] { try write(Data("before".utf8), "a.txt", in: root) }
            let result = try FolderComparison.compare(left: left, right: right, progress: { progress in
                if progress.phase == .validating && progress.completed == 0 {
                    try? Data("after!".utf8).write(to: left.appendingPathComponent("a.txt"), options: .atomic)
                }
            })
            #expect(!result.isComplete)
            #expect(result.rows.first?.status == .unavailable)
        }
    }

    @Test("Ein unlesbarer Unterordner bleibt unvollständig und niemals identisch")
    func unreadableDirectory() throws {
        try fixture { left, right in
            for root in [left, right] { try write(Data(), "blocked/a.txt", in: root) }
            let blocked = left.appendingPathComponent("blocked")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path) }
            let result = try FolderComparison.compare(left: left, right: right)
            #expect(!result.isComplete)
            #expect(result.rows.first { $0.path == "blocked" }?.status == .unavailable)
            #expect(!result.rows.contains { $0.status == .onlyLeft || $0.status == .onlyRight })
            #expect(!result.issues.contains(L10n.string("Die Ordnerstruktur hat sich während der Prüfung geändert. Das Ergebnis ist unvollständig.")))
        }
    }

    @Test("Abbruch endet vor der Rekursion und innerhalb gestreamter Snapshot-Reads")
    func cancellation() throws {
        try fixture { left, right in
            #expect(throws: CancellationError.self) {
                try FolderComparison.compare(left: left, right: right, isCancelled: { true })
            }
            let file = left.appendingPathComponent("stream.bin")
            try Data(repeating: 0, count: 9 * 1024 * 1024).write(to: file)
            var polls = 0
            #expect(throws: CancellationError.self) {
                try FileSnapshot.readSnapshotOnly(from: file, isCancelled: { polls += 1; return polls >= 3 })
            }
            #expect(polls == 3)
        }
    }

    @Test("Ein wachsender Snapshot liest höchstens ein Prüfbyte über seine Grenze")
    func growingRead() throws {
        try fixture { left, _ in
            let file = left.appendingPathComponent("growing.bin")
            try Data(repeating: 1, count: 4).write(to: file)
            let opened = try FileSnapshot.openRegularFile(at: file)
            defer { close(opened.descriptor) }
            var changed = false
            #expect(throws: FileSnapshotReadError.self) {
                try FileSnapshot.readSnapshotOnly(descriptor: opened.descriptor, fileStat: opened.stat,
                    byteLimit: 4, isCancelled: {
                        if !changed {
                            changed = true
                            try? Data(repeating: 2, count: 100).write(to: file)
                        }
                        return false
                    })
            }
            let readBytes = lseek(opened.descriptor, 0, SEEK_CUR)
            print("FOLDER_COMPARE_GROWTH_PROBE limit=4 actualRead=\(readBytes)")
            #expect(readBytes <= 5)
        }
    }

    @Test("Pfadfilter funktionieren auch mit der Dateisystemwurzel")
    func rootFilter() {
        let matcher = PathExclusion.Matcher(patterns: ["x/sub/*.txt"], relativeTo: URL(fileURLWithPath: "/"))
        #expect(matcher.matches(URL(fileURLWithPath: "/x/sub/a.txt")))
        #expect(!matcher.matches(URL(fileURLWithPath: "/other/a.txt")))
    }

    @Test("Nichtlokale Wurzeln werden vor Dateisystemauflösung abgewiesen")
    func nonlocalRoot() throws {
        try fixture { _, right in
            try write(Data("local".utf8), "a.txt", in: right)
            let result = try FolderComparison.compare(left: URL(string: "https://example.invalid/")!, right: right)
            #expect(!result.isComplete && result.budgetBytes == 0)
            #expect(result.rows.allSatisfy { $0.status == .unavailable })
            #expect(result.issues.first == L10n.format("%@: Es können nur lokale Ordner verglichen werden.", L10n.string("Links")))
        }
    }

    @Test("Datei-Ordner-Konflikte und begrenzte Unterbäume erlauben kein falsches Dateipaar")
    func directoryLimits() throws {
        try fixture { left, right in
            try write(Data(), "conflict", in: left)
            try write(Data(), "conflict/a.txt", in: right)
            let types = try FolderComparison.compare(left: left, right: right)
            #expect(types.rows.first { $0.path == "conflict" }?.status == .different)
            #expect(types.rows.first { $0.path == "conflict" }?.canOpenPair == false)
            for root in [left, right] { try write(Data(), "deep/nested/a.txt", in: root) }
            var options = FolderComparison.Options(); options.maximumDepth = 1
            let depth = try FolderComparison.compare(left: left, right: right, options: options)
            #expect(!depth.isComplete)
            #expect(depth.rows.first { $0.path == "deep" }?.status == .unavailable)
            #expect(depth.rows.first { $0.path == "deep" }?.detail != nil)
            #expect(!depth.rows.contains { $0.path == "deep/nested/a.txt" })
        }
    }

    @Test("Ein nicht verfolgter Gegenpfad bestätigt keine fehlenden Unterdateien")
    func unverifiedAncestor() throws {
        try fixture { left, right in
            try write(Data("same".utf8), "linked/a.txt", in: left)
            try FileManager.default.createSymbolicLink(at: right.appendingPathComponent("linked"),
                withDestinationURL: left.appendingPathComponent("linked"))
            let result = try FolderComparison.compare(left: left, right: right)
            #expect(!result.isComplete)
            #expect(result.rows.first { $0.path == "linked/a.txt" }?.status == .unavailable)
            #expect(!result.issues.contains(L10n.string("Die Ordnerstruktur hat sich während der Prüfung geändert. Das Ergebnis ist unvollständig.")))
        }
    }

    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = testTemporaryDirectory().appendingPathComponent("fastra-folder-compare-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right")
        for url in [left, right] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try body(left, right)
    }

    private func write(_ data: Data, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
