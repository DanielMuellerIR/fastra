import Foundation
import Testing

private struct SelfTestParserFixture: Sendable, CustomStringConvertible {
    let description: String
    let payload: String
    let legacyLine: String
    let expected: String
    var protocolError = false

    static let cases: [SelfTestParserFixture] = [
        .init(description: "Fehlerpriorität aufsteigend", payload: """
            SELFTEST-RESULT v=1 test=search status=PASS
            SELFTEST-RESULT v=1 test=search status=SKIP
            SELFTEST-RESULT v=1 test=search status=ENV
            SELFTEST-RESULT v=1 test=search status=FAIL
            """, legacyLine: "SELFTEST search: PASS", expected: "FAIL"),
        .init(description: "Fehlerpriorität absteigend", payload: """
            SELFTEST-RESULT v=1 test=search status=FAIL
            SELFTEST-RESULT v=1 test=search status=ENV
            SELFTEST-RESULT v=1 test=search status=SKIP
            SELFTEST-RESULT v=1 test=search status=PASS
            """, legacyLine: "SELFTEST search: PASS", expected: "FAIL"),
        .init(description: "PASS im Diagnosetext", payload: "",
              legacyLine: "SELFTEST search: FAIL — erwartet SELFTEST search: PASS",
              expected: "FAIL"),
        .init(description: "Falscher Altbundle-Testname", payload: "",
              legacyLine: "SELFTEST project: PASS — falscher Testname", expected: "FAIL"),
        .init(description: "Altbundle-Umgebungsfehler", payload: "",
              legacyLine: "SELFTEST search: FAIL — Umgebungsproblem: Fokus fehlt", expected: "ENV"),
        .init(description: "Unbekannte Protokollversion", payload:
              "SELFTEST-RESULT v=2 test=search status=MAYBE",
              legacyLine: "SELFTEST search: PASS", expected: "FAIL", protocolError: true),
        .init(description: "Fehlender Statusschlüssel", payload:
              "SELFTEST-RESULT v=1 test=search FAIL",
              legacyLine: "SELFTEST search: PASS", expected: "FAIL", protocolError: true),
        .init(description: "Beschädigtes Präfix", payload:
              "SELFTEST-RESULTX v=1 test=search status=PASS",
              legacyLine: "SELFTEST search: PASS", expected: "FAIL", protocolError: true),
        // Ab hier: Zweige, die der Parser hat, aber bis 2026-09-10 kein
        // Fixture erreichte.
        .init(description: "Unbekannter Statuswert bei gültigem Rahmen", payload:
              "SELFTEST-RESULT v=1 test=search status=WEIRD",
              legacyLine: "SELFTEST search: PASS", expected: "FAIL", protocolError: true),
        .init(description: "Fremder Testname in der Maschinenzeile", payload:
              "SELFTEST-RESULT v=1 test=project status=PASS",
              legacyLine: "SELFTEST search: PASS", expected: "FAIL", protocolError: true),
        .init(description: "Fünftes Feld hinter dem Status", payload:
              "SELFTEST-RESULT v=1 test=search status=PASS zusatz=1",
              legacyLine: "SELFTEST search: PASS", expected: "FAIL", protocolError: true),
        // Der wichtigste der vier: Eine gültige PASS-Zeile darf einen
        // Protokollfehler in derselben Ausgabe NICHT überstimmen.
        .init(description: "Gültige PASS-Zeile neben einer beschädigten", payload: """
            SELFTEST-RESULT v=1 test=search status=PASS
            SELFTEST-RESULT v=1 test=search status=KAPUTT
            """, legacyLine: "SELFTEST search: PASS", expected: "FAIL", protocolError: true),
        // Und die Gegenprobe zur Bereitschaftsprüfung des Runners: Eine
        // Maschinenzeile ohne Begleitzeile ist vollwertig.
        .init(description: "Maschinenzeile ohne Begleitzeile", payload:
              "SELFTEST-RESULT v=1 test=search status=ENV",
              legacyLine: "", expected: "ENV"),
    ]
}

@Suite("Ergebnisparser des Selbsttest-Runners")
struct SelfTestResultParserTests {
    @Test("Protokollfehler, Altbundles und Fehlerpriorität", arguments: SelfTestParserFixture.cases)
    fileprivate func parsesResult(fixture: SelfTestParserFixture) throws {
        let root = testTemporaryDirectory()
            .appendingPathComponent("fastra-result-parser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("result.log")
        try (fixture.payload + "\n").write(to: input, atomically: true, encoding: .utf8)
        let parser = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/selftest-results.sh")

        // Dieselbe Bash-Funktion wie im Runner, ohne App-Start oder Zugriff auf
        // Nutzereinstellungen. Alte Rückgabewerte dürfen den nächsten Aufruf
        // nicht beeinflussen; der Runner verwendet die Funktion mehrfach.
        let result = try runTestProcess("/bin/bash", arguments: [
            "-c", #"""
            set -eu
            . "$1"
            SELFTEST_RESULT_STATUS=ENV
            SELFTEST_PROTOCOL_ERROR='Fehler aus dem vorigen Test'
            classify_selftest_result search "$2" "$3"
            printf '%s\n' "$SELFTEST_RESULT_STATUS"
            if [ -n "$SELFTEST_PROTOCOL_ERROR" ]; then
                printf 'PROTOCOL_ERROR %s\n' "$SELFTEST_PROTOCOL_ERROR"
            fi
            """#, "result-parser", parser.path, input.path, fixture.legacyLine,
        ])
        try #require(result.status == 0, "Parser-Aufruf: \(result.output)")
        #expect(result.output.hasPrefix(fixture.expected + "\n"))
        #expect(result.output.contains("PROTOCOL_ERROR ") == fixture.protocolError)
    }
}
