import Foundation
import Testing
@testable import Fastra

@Suite("Textabläufe über Dateien: eingefrorene Vorschau und gemeinsame Rücknahme")
struct TextWorkflowFilePlanTests {
    private let uppercase = TextWorkflow(name: "Großschreibung", steps: [TextWorkflowStep(kind: .uppercase)])

    private func fixture(_ body: (URL, URL, URL) throws -> Void) throws {
        let root = testTemporaryDirectory().appendingPathComponent("workflow-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("one.txt"), root.appendingPathComponent("two.txt"),
                 root.appendingPathComponent("backups"))
    }

    private func noSession(_ backups: URL) throws {
        let entries = try FileManager.default.fileExists(atPath: backups.path)
            ? FileManager.default.contentsOfDirectory(atPath: backups.path) : []
        #expect(entries.isEmpty)
    }

    @Test("Zeilenweise Abläufe erhalten gemischte Trenner und fehlenden Endumbruch bytegenau")
    func mixedEndingsThroughLineSteps() throws {
        try fixture { first, _, backups in
            let source = "a  \r\nb  \nc  \rd  "
            let original = Data([0xFF, 0xFE]) + (try #require(source.data(using: .utf16LittleEndian)))
            try original.write(to: first)
            let workflow = TextWorkflow(name: "Trim", steps: [.init(kind: .trimTrailing), .init(kind: .uppercase)])
            let plan = try TextWorkflowFilePlan.build(workflow, inputs: [.init(url: first)])
            let expected = Data([0xFF, 0xFE]) + (try #require("A\r\nB\nC\rD".data(using: .utf16LittleEndian)))
            #expect(plan.files[0].newBytes == expected)
            let applied = try ApplyEngine.execute(workflowPlan: plan, backupRoot: backups, cleanupOlderThan: nil)
            #expect(try Data(contentsOf: first) == expected)
            _ = try ApplyEngine.undo(applied)
            #expect(try Data(contentsOf: first) == original)
        }
    }

    @Test("Apply schreibt exakt die vollständige Vorschau; Undo stellt Originalbytes wieder her")
    func roundTrip() throws {
        try fixture { first, second, backups in
            let one = Data("a\r\nb\nc\r".utf8)
            let two = Data([0xFF, 0xFE]) + (try #require("café\r\n".data(using: .utf16LittleEndian)))
            try one.write(to: first); try two.write(to: second)
            let plan = try TextWorkflowFilePlan.build(uppercase, inputs: [.init(url: first), .init(url: second)])
            #expect(plan.changedFileCount == 2)
            #expect(try Data(contentsOf: first) == one && Data(contentsOf: second) == two)
            let session = try ApplyEngine.execute(workflowPlan: plan, backupRoot: backups, cleanupOlderThan: nil)
            #expect(session.entries.map(\.state) == [.applied, .applied])
            #expect(try Data(contentsOf: first) == plan.files[0].newBytes)
            #expect(try Data(contentsOf: second) == plan.files[1].newBytes)
            #expect(plan.files[0].preview.output == "A\r\nB\nC\r")
            _ = try ApplyEngine.undo(session)
            #expect(try Data(contentsOf: first) == one && Data(contentsOf: second) == two)
        }
    }

    @Test("Fremdänderungen stoppen vor dem ersten Schreiben, auch bei wirkungslosen Eingaben", arguments: [false, true])
    func staleInput(_ unchanged: Bool) throws {
        try fixture { first, second, backups in
            try Data("one".utf8).write(to: first)
            try Data((unchanged ? "TWO" : "two").utf8).write(to: second)
            let plan = try TextWorkflowFilePlan.build(uppercase, inputs: [.init(url: first), .init(url: second)])
            #expect(plan.files[1].changed == !unchanged)
            #expect(throws: ApplyError.self) {
                try ApplyEngine.execute(workflowPlan: plan, backupRoot: backups, cleanupOlderThan: nil,
                    beforePreflight: { try Data("external".utf8).write(to: second) })
            }
            #expect(try Data(contentsOf: first) == Data("one".utf8))
            #expect(try Data(contentsOf: second) == Data("external".utf8))
            try noSession(backups)
        }
    }

    @Test("Geänderte Symlink-Ziele werden bei Vorschau und Austausch geschützt", arguments: [false, true])
    func aliasBinding(_ duringSwap: Bool) throws {
        try fixture { first, second, backups in
            try Data("one".utf8).write(to: first); try Data("two".utf8).write(to: second)
            let alias = first.deletingLastPathComponent().appendingPathComponent("alias.txt")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
            let plan = try TextWorkflowFilePlan.build(uppercase, inputs: [.init(url: alias)])
            let retarget: () throws -> Void = {
                try FileManager.default.removeItem(at: alias)
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
            }
            if !duringSwap { try retarget() }
            #expect(throws: ApplyError.self) {
                try ApplyEngine.execute(workflowPlan: plan, backupRoot: backups, cleanupOlderThan: nil,
                    beforeAtomicReplace: duringSwap ? { _ in try retarget() } : nil)
            }
            #expect(try Data(contentsOf: first) == Data("one".utf8))
            #expect(try Data(contentsOf: second) == Data("two".utf8))
            try noSession(backups)
        }
    }

    @Test("Dieselbe Datei über Pfad, Symlink oder Hardlink erzeugt keinen doppelten Schreibauftrag", arguments: [0, 1, 2])
    func duplicateIdentity(_ kind: Int) throws {
        try fixture { first, second, _ in
            try Data("one".utf8).write(to: first)
            switch kind {
            case 1: try FileManager.default.createSymbolicLink(at: second, withDestinationURL: first)
            case 2: try FileManager.default.linkItem(at: first, to: second)
            default: break
            }
            let duplicate = kind == 0 ? first : second
            #expect(throws: TextWorkflowFilePlan.Failure.duplicateInput(duplicate.standardizedFileURL)) {
                try TextWorkflowFilePlan.build(uppercase, inputs: [.init(url: first), .init(url: duplicate)])
            }
            #expect(try Data(contentsOf: first) == Data("one".utf8))
        }
    }

    @Test("Kodierung, BOM, Unicode-Schreibweise und gemischte Zeilenenden bleiben exakt", arguments: [
        String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian,
        .windowsCP1252, .isoLatin1, .macOSRoman,
    ])
    func encoding(_ encoding: String.Encoding) throws {
        try fixture { first, _, backups in
            let boms: [String.Encoding: Data] = [
                .utf8: Data([0xEF, 0xBB, 0xBF]), .utf16LittleEndian: Data([0xFF, 0xFE]),
                .utf16BigEndian: Data([0xFE, 0xFF]), .utf32LittleEndian: Data([0xFF, 0xFE, 0, 0]),
                .utf32BigEndian: Data([0, 0, 0xFE, 0xFF]),
            ]
            let bom = boms[encoding] ?? Data()
            let text = encoding == .utf8 ? "\u{FEFF}cafe\u{301}\r\n" : "café\r\n"
            let original = bom + (try #require(text.data(using: encoding)))
            try original.write(to: first)
            var prefix = TextWorkflowStep(kind: .prefixLines); prefix.argument = "> "
            let workflow = TextWorkflow(name: "Zitat", steps: [prefix])
            let plan = try TextWorkflowFilePlan.build(workflow, inputs: [.init(url: first, encoding: encoding)])
            #expect(plan.files[0].preview.source.utf8.elementsEqual(text.utf8))
            #expect(plan.files[0].newBytes == bom + (try #require(("> " + text).data(using: encoding))))
            let session = try ApplyEngine.execute(workflowPlan: plan, backupRoot: backups, cleanupOlderThan: nil)
            _ = try ApplyEngine.undo(session)
            #expect(try Data(contentsOf: first) == original)
        }
    }

    @Test("Widersprüchliche BOM, Binärdaten und nicht darstellbare Ersetzungen liefern keinen Plan")
    func invalidEncoding() throws {
        try fixture { first, _, _ in
            let data = Data([0xFF, 0xFE, 0x61, 0])
            try data.write(to: first)
            #expect(throws: TextWorkflowFilePlan.Failure.encodingConflict(first.standardizedFileURL)) {
                try TextWorkflowFilePlan.build(uppercase, inputs: [.init(url: first, encoding: .utf8)])
            }
            try Data([0x61, 0, 0x62]).write(to: first)
            #expect(throws: TextWorkflowFilePlan.Failure.binary(first.standardizedFileURL)) {
                try TextWorkflowFilePlan.build(uppercase, inputs: [.init(url: first)])
            }
            let original = try #require("café".data(using: .isoLatin1)); try original.write(to: first)
            var prefix = TextWorkflowStep(kind: .prefixLines); prefix.argument = "😀"
            #expect(throws: TextWorkflowFilePlan.Failure.unrepresentable(first.standardizedFileURL)) {
                try TextWorkflowFilePlan.build(TextWorkflow(name: "Emoji", steps: [prefix]),
                                               inputs: [.init(url: first, encoding: .isoLatin1)])
            }
            #expect(try Data(contentsOf: first) == original)
        }
    }

    @Test("Gesamtgrenzen erfassen Eingaben, Ausgaben und alle gehaltenen Vorschautexte", arguments: [0, 1, 2, 3])
    func aggregateLimits(_ kind: Int) throws {
        try fixture { first, second, _ in
            try Data("abc".utf8).write(to: first); try Data("def".utf8).write(to: second)
            var limits = TextWorkflowFilePlan.Limits.standard
            switch kind {
            case 0: limits.files = 1
            case 1: limits.originalBytes = 5
            case 2: limits.outputBytes = 5
            default: limits.previewBytes = 29
            }
            #expect(throws: TextWorkflowFilePlan.Failure.self) {
                try TextWorkflowFilePlan.build(uppercase, inputs: [.init(url: first), .init(url: second)], limits: limits)
            }
            #expect(try Data(contentsOf: first) == Data("abc".utf8) && Data(contentsOf: second) == Data("def".utf8))
        }
    }

    @Test("Leere Aufträge, Abbruch und Zeitablauf bleiben ohne Ergebnis oder Schreibwirkung")
    func cancellation() throws {
        #expect(throws: TextWorkflowFilePlan.Failure.empty) { try TextWorkflowFilePlan.build(uppercase, inputs: []) }
        try fixture { first, _, backups in
            try Data("abc".utf8).write(to: first)
            #expect(throws: TextWorkflowFilePlan.Failure.cancelled) {
                try TextWorkflowFilePlan.build(uppercase, inputs: [.init(url: first)], shouldCancel: { true })
            }
            var limits = TextWorkflowFilePlan.Limits.standard; limits.seconds = -1
            #expect(throws: TextWorkflowFilePlan.Failure.timeout) {
                try TextWorkflowFilePlan.build(uppercase, inputs: [.init(url: first)], limits: limits)
            }
            let plan = try TextWorkflowFilePlan.build(uppercase, inputs: [.init(url: first)])
            #expect(throws: ApplyError.cancelled) {
                try ApplyEngine.execute(workflowPlan: plan, backupRoot: backups, cleanupOlderThan: nil, shouldCancel: { true })
            }
            #expect(try Data(contentsOf: first) == Data("abc".utf8))
            try noSession(backups)
        }
    }

    @Test("Teilfehler behalten das vorhandene Journal und erlauben eine geschützte Rücknahme")
    func partialWrite() throws {
        try fixture { first, second, backups in
            try Data("one".utf8).write(to: first); try Data("two".utf8).write(to: second)
            let plan = try TextWorkflowFilePlan.build(uppercase, inputs: [.init(url: first), .init(url: second)])
            var partial: ApplySession?
            do {
                _ = try ApplyEngine.execute(workflowPlan: plan, backupRoot: backups, cleanupOlderThan: nil,
                    beforeAtomicReplace: { url in if url == second.canonicalFileURL { throw CocoaError(.fileWriteUnknown) } })
                Issue.record("Der zweite Austausch hätte scheitern müssen")
            } catch ApplyError.writeFailed(let session, _) { partial = session }
            let session = try #require(partial)
            #expect(session.entries.count == 1 && session.entries[0].state == .applied)
            #expect(try ApplyEngine.loadSession(at: session.sessionDirectory) == session)
            #expect(try Data(contentsOf: first) == Data("ONE".utf8))
            #expect(try Data(contentsOf: second) == Data("two".utf8))
            _ = try ApplyEngine.undo(session)
            #expect(try Data(contentsOf: first) == Data("one".utf8))
        }
    }

    @Test("Eine wirkungslose Gesamtvorschau legt keine Sicherungssitzung an")
    func noChanges() throws {
        try fixture { first, _, backups in
            try Data("ABC".utf8).write(to: first)
            let plan = try TextWorkflowFilePlan.build(uppercase, inputs: [.init(url: first)])
            #expect(plan.changedFileCount == 0)
            #expect(throws: TextWorkflowFilePlan.Failure.noChanges) {
                try ApplyEngine.execute(workflowPlan: plan, backupRoot: backups, cleanupOlderThan: nil)
            }
            try noSession(backups)
        }
    }

    @Test("Schreibgeschützte Dateien werden vor Planung und erneut vor Apply abgewiesen", arguments: [false, true])
    func readOnly(_ afterPreview: Bool) throws {
        try fixture { first, _, backups in
            try Data("abc".utf8).write(to: first)
            let plan = afterPreview ? try TextWorkflowFilePlan.build(uppercase, inputs: [.init(url: first)]) : nil
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: first.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: first.path) }
            #expect(throws: TextWorkflowFilePlan.Failure.readOnly(first.canonicalFileURL)) {
                if let plan {
                    _ = try ApplyEngine.execute(workflowPlan: plan, backupRoot: backups, cleanupOlderThan: nil)
                } else {
                    _ = try TextWorkflowFilePlan.build(uppercase, inputs: [.init(url: first)])
                }
            }
            #expect(try Data(contentsOf: first) == Data("abc".utf8))
            try noSession(backups)
        }
    }
}
