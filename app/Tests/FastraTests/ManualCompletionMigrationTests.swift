import Foundation
import Testing

@Suite("Manual-Completion-Migration im Build")
struct ManualCompletionMigrationTests {
    private var appDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    // Minimaler Kontext der echten aktuellen/historischen Checkoutzustände:
    // Außer diesem Zweig liest die Migration keinen Swift-Kontext.
    private let visible = """
                if SuggestionController.shared.isVisible {
                    SuggestionController.shared.close()
                    return event
                }
    """ + "\n"
    private let note = "            NotificationCenter.default.post(name: Notification.Name(\"fastra.completion.manualTrigger\"), object: self)  // Fastra-Patch: manueller Aufruf (Esc/Ctrl-Space) erlaubt Ein-Zeichen-Vorschlaege\n"

    @Test("Reale Patchhülle migriert, überspringt und weist Helferfehler ab")
    func migrationStatusContract() throws {
        let script = try String(contentsOf: appDirectory.appendingPathComponent("build.sh"), encoding: .utf8)
        // Ganze bestehende Sektion einschließlich frischem Patch und Endkontrolle;
        // keine nachgebildete if/else-Logik und keine übrigen Checkoutpatches.
        let start = try #require(script.range(of: "# 4b-2. Patch CodeEditSourceEditor"))
        let end = try #require(script.range(of: "# 4c. Patch CodeEditSourceEditor"))
        let wrapper = "set -e\nCESE_LC=source.swift\n" + String(script[start.lowerBound..<end.lowerBound])
            + "\nprintf continued > continuation\n"
        let cases: [(String, String?, String, Int32, Bool)] = [
            ("fresh", visible, "intact", 0, true),
            ("current", visible + note, "intact", 0, false),
            ("historical", note + visible, "intact", 0, true),
            ("missing-current", visible + note, "missing", 2, false),
            ("missing-historical", note + visible, "missing", 2, false),
            ("syntax", visible + note, "syntax", 1, false),
            ("unreadable", visible + note, "unreadable", 2, false),
            ("missing-source", nil, "intact", 1, false)
        ]
        for (name, source, helperState, expectedStatus, invalidatesCache) in cases {
            let root = testTemporaryDirectory()
                .appendingPathComponent("Fastra completion \(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let helpers = root.appendingPathComponent("Patches/CodeEditSourceEditor")
            try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
            for helper in ["manual-completion-trigger-migration.py", "manual-completion-trigger-verification.py"] {
                try FileManager.default.copyItem(at: appDirectory.appendingPathComponent("Patches/CodeEditSourceEditor/\(helper)"),
                                                to: helpers.appendingPathComponent(helper))
            }
            let migration = helpers.appendingPathComponent("manual-completion-trigger-migration.py")
            if helperState == "missing" { try FileManager.default.removeItem(at: migration) }
            if helperState == "syntax" { try "def broken(:\n".write(to: migration, atomically: true, encoding: .utf8) }
            if helperState == "unreadable" {
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: migration.path)
            }
            if let source { try source.write(to: root.appendingPathComponent("source.swift"), atomically: true, encoding: .utf8) }
            let caches = ["debug/CodeEditSourceEditor.build/sentinel", "release/CodeEditSourceEditor.build/sentinel",
                          "debug/Modules/CodeEditSourceEditor.swiftmodule", "release/Modules/CodeEditSourceEditor.swiftmodule"]
                .map { root.appendingPathComponent(".build/test/\($0)") }
            for cache in caches {
                try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("cache".utf8).write(to: cache)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", wrapper]
            process.currentDirectoryURL = root
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == expectedStatus, "\(name)")
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("continuation").path)
                    == (expectedStatus == 0), "\(name)")
            for cache in caches {
                #expect(FileManager.default.fileExists(atPath: cache.path) == !invalidatesCache, "\(name): \(cache.lastPathComponent)")
            }
            if expectedStatus == 0 {
                let result = try String(contentsOf: root.appendingPathComponent("source.swift"), encoding: .utf8)
                #expect(result == visible + note, "\(name)")
            } else if let source {
                #expect(try String(contentsOf: root.appendingPathComponent("source.swift"), encoding: .utf8) == source, "\(name)")
            }
        }
    }
}
