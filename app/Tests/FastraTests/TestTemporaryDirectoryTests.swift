// TestTemporaryDirectoryTests.swift
//
// Quellprüfung für die Temp-Sandbox: Test-Fixtures nutzen die Helfer aus
// `Support/TestTemporaryDirectory.swift` statt Foundations direkter
// `.temporaryDirectory`, damit umgeleitetes TMPDIR auch auf macOS gilt.

import Foundation
import Testing
@testable import Fastra

private let temporaryDirectoryTestsRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // FastraTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // app

private struct TemporaryDirectoryAudit {
    let files: [String]
    let harnessFiles: [String]
    let offenders: [String]
}

private func auditTemporaryDirectoryAccess(in appRoot: URL) throws -> TemporaryDirectoryAudit {
    let allowed: Set<String> = [
        "Tests/FastraTests/Support/TestTemporaryDirectory.swift",
        "Tests/FastraTests/TestTemporaryDirectoryTests.swift",
        "Sources/Fastra/SelfTestTemporaryDirectory.swift",
    ]
    var files: Set<String> = []
    var harnessFiles: Set<String> = []
    for (relativeRoot, harnessOnly) in [("Tests/FastraTests", false), ("Sources/Fastra", true)] {
        // Root und Kind-Elternpfad brauchen dieselbe macOS-Aliasauflösung.
        let root = appRoot.appendingPathComponent(relativeRoot).resolvingSymlinksInPath()
        var enumerationError: Error?
        let enumerator = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, errorHandler: { _, error in
                enumerationError = error
                return false
            }))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            if harnessOnly && !name.hasPrefix("SelfTest") && !name.hasPrefix("SoakTest") {
                continue
            }
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
            let path = parent.appendingPathComponent(name).path
            try #require(path.hasPrefix(root.path + "/"))
            let relative = relativeRoot + "/" + String(path.dropFirst(root.path.count + 1))
            files.insert(relative)
            if harnessOnly { harnessFiles.insert(relative) }
        }
        if let enumerationError { throw enumerationError }
    }
    var offenders: [String] = []
    for relative in files.sorted() where !allowed.contains(relative) {
        let source = try String(contentsOf: appRoot.appendingPathComponent(relative), encoding: .utf8)
        for (index, line) in source.components(separatedBy: "\n").enumerated()
        where line.contains(".temporaryDirectory") || line.contains("NSTemporaryDirectory(") {
            offenders.append("\(relative):\(index + 1)")
        }
    }
    return TemporaryDirectoryAudit(files: files.sorted(), harnessFiles: harnessFiles.sorted(),
                                   offenders: offenders)
}

@Suite("Temp-Sandbox der Tests")
struct TestTemporaryDirectoryTests {
    @Test("Der Helfer folgt TMPDIR nur, wenn der Ordner existiert")
    func helperHonoursExistingTMPDIR() throws {
        let sandbox = testTemporaryDirectory()
            .appendingPathComponent("fastra-tmpdir-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // Wie `test.sh`: Pfad mit abschließendem Schrägstrich.
        let redirected = testTemporaryDirectory(environment: ["TMPDIR": sandbox.path + "/"])
        #expect(redirected.standardizedFileURL.path == sandbox.standardizedFileURL.path)
        // Fehlender Ordner und fehlende Variable fallen auf Foundation zurück.
        let missing = testTemporaryDirectory(
            environment: ["TMPDIR": sandbox.appendingPathComponent("gibt-es-nicht").path])
        #expect(missing == FileManager.default.temporaryDirectory)
        #expect(testTemporaryDirectory(environment: [:]) == FileManager.default.temporaryDirectory)
        #expect(testTemporaryDirectory(environment: ["TMPDIR": ""]) == FileManager.default.temporaryDirectory)
    }

    /// Jede Fixture der Testsuite geht über `testTemporaryDirectory()`; die
    /// Selbsttests über `selfTestTemporaryDirectory()`. Erlaubt bleibt der
    /// direkte Zugriff nur in den beiden Helfern selbst (ihr Rückfall) und in
    /// diesem Wächter (Vergleichswert).
    @Test("Kein Test und kein Selbsttest greift direkt auf .temporaryDirectory zu")
    func noDirectTemporaryDirectoryAccess() throws {
        let audit = try auditTemporaryDirectoryAccess(in: temporaryDirectoryTestsRoot)
        #expect(audit.files.count > 50, "Quelldateien nicht gefunden: \(audit.files.count)")
        #expect(!audit.harnessFiles.isEmpty, "Selbsttest-Quelldateien nicht gefunden")
        #expect(audit.harnessFiles == (try selfTestHarnessSources(in: temporaryDirectoryTestsRoot)).map(\.path))
        #expect(audit.harnessFiles.contains("Sources/Fastra/SelfTest.swift"))
        #expect(audit.harnessFiles.contains("Sources/Fastra/SelfTestSearchSemantics.swift"))
        #expect(audit.harnessFiles.contains("Sources/Fastra/SoakTest.swift"))
        #expect(audit.offenders.isEmpty, """
            Direkter Temp-Zugriff statt testTemporaryDirectory()/selfTestTemporaryDirectory(): \
            \(audit.offenders.joined(separator: ", "))
            """)
    }

    @Test("Zusätzliche Harness-Dateien werden einschließlich Unterordnern geprüft",
          arguments: ["SelfTestAdditional.swift", "Nested/SoakTestAdditional.swift"],
          ["FileManager.default.temporaryDirectory", "NSTemporaryDirectory()"])
    func additionalHarnessFilesAreAudited(relativeFile: String, forbiddenAccess: String) throws {
        let sandbox = testTemporaryDirectory()
            .appendingPathComponent("fastra-temp-audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sources = sandbox.appendingPathComponent("Sources/Fastra")
        try FileManager.default.createDirectory(
            at: sandbox.appendingPathComponent("Tests/FastraTests"), withIntermediateDirectories: true)
        let target = sources.appendingPathComponent(relativeFile)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// Fixture\nlet directory = \(forbiddenAccess)\n".write(
            to: target, atomically: true, encoding: .utf8)
        try forbiddenAccess.write(to: sources.appendingPathComponent("SelfTestTemporaryDirectory.swift"),
                                  atomically: true, encoding: .utf8)
        try forbiddenAccess.write(to: sources.appendingPathComponent("Document.swift"),
                                  atomically: true, encoding: .utf8)
        try forbiddenAccess.write(to: sources.appendingPathComponent("SelfTestNotes.md"),
                                  atomically: true, encoding: .utf8)

        let audit = try auditTemporaryDirectoryAccess(in: sandbox)
        let relative = "Sources/Fastra/" + relativeFile
        #expect(audit.harnessFiles == [relative, "Sources/Fastra/SelfTestTemporaryDirectory.swift"].sorted())
        #expect(audit.files == audit.harnessFiles)
        #expect(audit.offenders == ["\(relative):2"])
    }

    @Test("Eine fehlende Quellwurzel wird nicht als leerer Erfolg gewertet")
    func missingSourceRootFailsAudit() throws {
        let sandbox = testTemporaryDirectory()
            .appendingPathComponent("fastra-temp-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sandbox.appendingPathComponent("Tests/FastraTests"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        #expect(throws: (any Error).self) {
            try auditTemporaryDirectoryAccess(in: sandbox)
        }
    }
}
