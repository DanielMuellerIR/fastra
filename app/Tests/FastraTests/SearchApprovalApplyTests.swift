import Foundation
import Testing
@testable import Fastra

@Suite("Freigegebene Dateiänderungen")
struct SearchApprovalApplyTests {
    @Test("Schreibschutz vor Planung, vor Preflight und vor Austausch verhindert jede freigegebene Änderung", arguments: [0, 1, 2])
    func readOnlyDenied(_ when: Int) throws {
        let root = try directory()
        let file = root.appendingPathComponent("read-only.txt")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: root)
        }
        let original = Data("foo".utf8)
        try original.write(to: file)
        let options = SearchOptions(find: "foo", replace: "bar", isRegex: false)
        let plan = try #require(ApplyEngine.plan(files: [file], options: options).files.first)
        let input = ApplyTransaction.Input(url: file, snapshot: try #require(plan.originalSnapshot),
            matches: plan.matches, approvedRanges: Set(plan.matches.map(\.range)))
        func protect() throws {
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            try #require(!FileManager.default.isWritableFile(atPath: file.path))
        }
        if when == 0 { try protect() }
        #expect(throws: (any Error).self) {
            try ApplyTransaction(inputs: [input], options: options).execute(
                backupRoot: root.appendingPathComponent("undo"), cleanupOlderThan: nil,
                beforePreflight: { if when == 1 { try protect() } },
                beforeAtomicReplace: { _ in if when == 2 { try protect() } })
        }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("Eine unfreigegebene schreibgeschützte Datei bleibt unverändert Teil der Basis")
    func unapprovedReadOnly() throws {
        let root = try directory()
        let files = [root.appendingPathComponent("selected.txt"), root.appendingPathComponent("protected.txt")]
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files[1].path)
            try? FileManager.default.removeItem(at: root)
        }
        for file in files { try Data("foo".utf8).write(to: file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: files[1].path)
        let options = SearchOptions(find: "foo", replace: "bar", isRegex: false)
        let plan = ApplyEngine.plan(files: files, options: options)
        let inputs = try plan.files.enumerated().map { index, file in
            ApplyTransaction.Input(url: file.url, snapshot: try #require(file.originalSnapshot),
                matches: file.matches, approvedRanges: index == 0 ? Set(file.matches.map(\.range)) : [])
        }
        let session = try ApplyTransaction(inputs: inputs, options: options).execute(
            backupRoot: root.appendingPathComponent("undo"), cleanupOlderThan: nil)
        #expect(session.entries.count == 1)
        #expect(try Data(contentsOf: files[0]) == Data("bar".utf8))
        #expect(try Data(contentsOf: files[1]) == Data("foo".utf8))
        _ = try ApplyEngine.undo(session)
        #expect(try Data(contentsOf: files[0]) == Data("foo".utf8))
    }

    @Test("Schreibschutz vor Rückgängig und unmittelbar vor Austausch verhindert die Rücknahme", arguments: [0, 1])
    func readOnlyUndoDenied(_ when: Int) throws {
        let root = try directory()
        let file = root.appendingPathComponent("text.txt")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: root)
        }
        try Data("foo".utf8).write(to: file)
        let options = SearchOptions(find: "foo", replace: "bar", isRegex: false)
        let plan = try #require(ApplyEngine.plan(files: [file], options: options).files.first)
        let input = ApplyTransaction.Input(url: file, snapshot: try #require(plan.originalSnapshot),
            matches: plan.matches, approvedRanges: Set(plan.matches.map(\.range)))
        let session = try ApplyTransaction(inputs: [input], options: options).execute(
            backupRoot: root.appendingPathComponent("undo"), cleanupOlderThan: nil)
        func protect() throws {
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            try #require(!FileManager.default.isWritableFile(atPath: file.path))
        }
        if when == 0 { try protect() }
        #expect(throws: (any Error).self) {
            try ApplyEngine.undo(session, beforeAtomicReplace: { _ in
                if when == 1 { try protect() }
            })
        }
        #expect(try Data(contentsOf: file) == Data("bar".utf8))
    }

    @Test("Ein schreibgeschütztes späteres Rücknahmeziel verhindert Änderungen an früheren Zielen")
    func undoPermissionPreflight() throws {
        let root = try directory()
        let files = [root.appendingPathComponent("a.txt"), root.appendingPathComponent("b.txt")]
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files[1].path)
            try? FileManager.default.removeItem(at: root)
        }
        for file in files { try Data("foo".utf8).write(to: file) }
        let options = SearchOptions(find: "foo", replace: "bar", isRegex: false)
        let session = try ApplyEngine.apply(plan: ApplyEngine.plan(files: files, options: options),
            backupRoot: root.appendingPathComponent("undo"), cleanupOlderThan: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: files[1].path)
        #expect(throws: (any Error).self) { try ApplyEngine.undo(session) }
        for file in files { #expect(try Data(contentsOf: file) == Data("bar".utf8)) }
    }

    @Test("Teilfreigabe erhält Unicode/CRLF und wird über den bestehenden Planadapter bitgenau zurückgenommen")
    func selectedMatchAndUndo() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("text.txt")
        let original = Data("foo 1\r\n🙂 foo 2\r\nfoo 3\n".utf8)
        try original.write(to: file)
        let options = SearchOptions(find: "foo (\\d)", replace: "bar $1")
        let all = try #require(ApplyEngine.plan(files: [file], options: options).files.first)
        let input = ApplyTransaction.Input(url: file, snapshot: try #require(all.originalSnapshot),
            matches: all.matches, approvedRanges: [all.matches[1].range])
        let read = try FileSnapshot.read(from: file)
        let partial = try ApplyEngine.planApprovedInput(input, data: read.data, snapshot: read.snapshot,
            searchPlan: SearchPlan(options: options), shouldCancel: { false })
        #expect(partial.matches == all.matches)
        #expect(partial.newBytes == Data("foo 1\r\n🙂 bar 2\r\nfoo 3\n".utf8))
        #expect(try Data(contentsOf: file) == original)
        let session = try ApplyEngine.apply(plan: ReplacePlan(files: [partial], options: options),
            backupRoot: root.appendingPathComponent("undo"), cleanupOlderThan: nil)
        #expect(try Data(contentsOf: file) == partial.newBytes)
        _ = try ApplyEngine.undo(session)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("Eine unfreigegebene Datei bleibt im abschließenden Snapshot-Preflight")
    func unapprovedFileStillProtected() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [root.appendingPathComponent("a.txt"), root.appendingPathComponent("b.txt")]
        for file in files { try Data("foo".utf8).write(to: file) }
        let options = SearchOptions(find: "foo", replace: "bar", isRegex: false)
        let plan = ApplyEngine.plan(files: files, options: options)
        let inputs = try plan.files.enumerated().map { index, file in
            ApplyTransaction.Input(url: file.url, snapshot: try #require(file.originalSnapshot),
                matches: file.matches, approvedRanges: index == 0 ? Set(file.matches.map(\.range)) : [])
        }
        #expect(throws: (any Error).self) {
            try ApplyTransaction(inputs: inputs, options: options).execute(
                backupRoot: root.appendingPathComponent("undo"), cleanupOlderThan: nil,
                beforePreflight: { try Data("extern".utf8).write(to: files[1], options: .atomic) })
        }
        #expect(try Data(contentsOf: files[0]) == Data("foo".utf8))
        #expect(try Data(contentsOf: files[1]) == Data("extern".utf8))
    }

    @Test("Weggelassene unfreigegebene Treffer und fremde Freigabebereiche werden abgewiesen")
    func fullMatchBasis() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("text.txt")
        try Data("foo foo".utf8).write(to: file)
        let options = SearchOptions(find: "foo", replace: "bar", isRegex: false)
        let all = try #require(ApplyEngine.plan(files: [file], options: options).files.first)
        let read = try FileSnapshot.read(from: file)
        for input in [
            ApplyTransaction.Input(url: file, snapshot: read.snapshot,
                matches: [all.matches[0]], approvedRanges: [all.matches[0].range]),
            ApplyTransaction.Input(url: file, snapshot: read.snapshot,
                matches: all.matches, approvedRanges: [NSRange(location: 4, length: 1)])
        ] {
            #expect(throws: (any Error).self) {
                try ApplyEngine.planApprovedInput(input, data: read.data, snapshot: read.snapshot,
                    searchPlan: SearchPlan(options: options), shouldCancel: { false })
            }
        }
        #expect(try Data(contentsOf: file) == Data("foo foo".utf8))
    }

    @Test("Eine unfreigegebene nicht darstellbare Ersetzung verfälscht keine Einbyte-Datei")
    func unapprovedEncodingFailure() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("text.txt")
        let original = Data([0x66, 0x6f, 0x6f, 0x20, 0xb5])
        try original.write(to: file)
        let options = SearchOptions(find: "\\w+", replace: "\\U$0\\E", caseSensitive: true)
        let all = try #require(ApplyEngine.plan(files: [file], options: options).files.first)
        #expect(all.skipped == .undecodable)
        let input = ApplyTransaction.Input(url: file, snapshot: try #require(all.originalSnapshot),
            matches: all.matches, approvedRanges: [try #require(all.matches.first).range])
        let session = try ApplyTransaction(inputs: [input], options: options).execute(
            backupRoot: root.appendingPathComponent("undo"), cleanupOlderThan: nil)
        #expect(try Data(contentsOf: file) == Data([0x46, 0x4f, 0x4f, 0x20, 0xb5]))
        _ = try ApplyEngine.undo(session)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("UTF-16-BOM, Emoji und gemischte Zeilenenden bleiben außerhalb der Freigabe exakt erhalten")
    func utf16() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("text.txt")
        var original = Data([0xff, 0xfe])
        original.append(try #require("foo 🙂\r\nfoo\rEnde\n".data(using: .utf16LittleEndian)))
        try original.write(to: file)
        let options = SearchOptions(find: "foo", replace: "bar", isRegex: false)
        let plan = try #require(ApplyEngine.plan(files: [file], options: options).files.first)
        let input = ApplyTransaction.Input(url: file, snapshot: try #require(plan.originalSnapshot),
            matches: plan.matches, approvedRanges: [plan.matches[1].range])
        let session = try ApplyTransaction(inputs: [input], options: options).execute(
            backupRoot: root.appendingPathComponent("undo"), cleanupOlderThan: nil)
        var expected = Data([0xff, 0xfe])
        expected.append(try #require("foo 🙂\r\nbar\rEnde\n".data(using: .utf16LittleEndian)))
        #expect(try Data(contentsOf: file) == expected)
        _ = try ApplyEngine.undo(session)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("Kanonisch gleiche, aber byteverschiedene Ersetzungen gelten nicht als dieselbe Vorschau")
    func exactReplacementBytes() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("text.txt")
        try Data("foo".utf8).write(to: file)
        let read = try FileSnapshot.read(from: file)
        let options = SearchOptions(find: "foo", replace: "e\u{301}", isRegex: false)
        let input = ApplyTransaction.Input(url: file, snapshot: read.snapshot,
            matches: [PlannedMatch(range: NSRange(location: 0, length: 3), before: "foo", after: "é")],
            approvedRanges: [NSRange(location: 0, length: 3)])
        #expect(throws: (any Error).self) {
            try ApplyEngine.planApprovedInput(input, data: read.data, snapshot: read.snapshot,
                searchPlan: SearchPlan(options: options), shouldCancel: { false })
        }
        #expect(try Data(contentsOf: file) == Data("foo".utf8))
    }

    private func directory() throws -> URL {
        let root = testTemporaryDirectory().appendingPathComponent("approvals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

}
