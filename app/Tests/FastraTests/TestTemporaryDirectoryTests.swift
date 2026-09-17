// TestTemporaryDirectoryTests.swift
//
// Wächter für die Temp-Sandbox der Tests. Hintergrund in
// `Support/TestTemporaryDirectory.swift`: Foundation ignoriert `TMPDIR`, die
// Sandbox von `test.sh` und `selftest.sh` greift deshalb nur über die eigenen
// Helfer. Ein einzelner direkter Zugriff auf `.temporaryDirectory` legt seine
// Fixtures wieder im echten Benutzer-Temp ab — und bleibt bei einem Timeout
// dort liegen (CodeQA-Fund test-temp-leaks, 2026-09-17).

import Foundation
import Testing
@testable import Fastra

private let temporaryDirectoryTestsRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // FastraTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // app

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
        let allowed: Set<String> = [
            "Tests/FastraTests/Support/TestTemporaryDirectory.swift",
            "Tests/FastraTests/TestTemporaryDirectoryTests.swift",
            "Sources/Fastra/SelfTestTemporaryDirectory.swift",
        ]
        var files = ["Sources/Fastra/SelfTest.swift"]
        let testsRoot = temporaryDirectoryTestsRoot.appendingPathComponent("Tests/FastraTests")
        let enumerator = try #require(FileManager.default.enumerator(
            at: testsRoot, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append("Tests/FastraTests/" + url.path.replacingOccurrences(
                of: testsRoot.path + "/", with: ""))
        }
        var offenders: [String] = []
        for relative in files.sorted() where !allowed.contains(relative) {
            let url = temporaryDirectoryTestsRoot.appendingPathComponent(relative)
            let source = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in source.components(separatedBy: "\n").enumerated()
            where line.contains(".temporaryDirectory") || line.contains("NSTemporaryDirectory(") {
                offenders.append("\(relative):\(index + 1)")
            }
        }
        #expect(files.count > 50, "Quelldateien nicht gefunden: \(files.count)")
        #expect(offenders.isEmpty, """
            Direkter Temp-Zugriff statt testTemporaryDirectory()/selfTestTemporaryDirectory(): \
            \(offenders.joined(separator: ", "))
            """)
    }
}
