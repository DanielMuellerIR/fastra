import Foundation
import Testing

private let runnerDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Ein Fall der Prüfmatrix: Umgebung setzen, erwartetes Urteil festhalten.
private struct QualificationCase: Sendable, CustomStringConvertible {
    let description: String
    let assignments: [String: String]
    let qualified: Bool
}

/// Die Qualifikations-Gatter entscheiden als EINZIGE Stelle, ob eine Messung in
/// die kanonische Performance-Historie aufgenommen wird. Die Zusage dazu steht
/// in `docs/BUILD-AND-TEST.md`: nur ein vollständig grüner Lauf von einem
/// sauberen, währenddessen unveränderten Stand. Bis zum Infrastruktur-Review
/// 2026-09-10 prüfte sie kein einziger Test — eine versehentlich invertierte
/// oder gelöschte Teilbedingung hätte rote oder schmutzige Läufe in die
/// Historie geschrieben, ohne dass irgendetwas rot geworden wäre.
@Suite("Qualifikation der Performance-Baseline")
struct BaselineQualificationTests {

    private func judge(function: String, in script: String,
                       assignments: [String: String]) throws -> Bool {
        let runner = runnerDirectory.appendingPathComponent(script)
        let definition = try shellFunction(named: function, in: runner)
        let setup = assignments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        let source = definition + "\n" + setup + "\n"
            + "if \(function); then exit 0; else exit 7; fi\n"
        let result = try runTestProcess("/bin/bash", arguments: ["-c", source])
        #expect(result.status == 0 || result.status == 7,
                "unerwarteter Status \(result.status): \(result.output)")
        return result.status == 0
    }

    /// Der grüne Ausgangsfall — und aus ihm abgeleitet je ein Fall, der genau
    /// EINE Bedingung verletzt.
    private static let selftestBase: [String: String] = [
        "real_fail_count": "0",
        "env_fail_count": "0",
        "skip_count": "0",
        "not_run_count": "0",
        "cleanup_env_errors": "0",
        "RUN_HEAD_START": "abc",
        "RUN_HEAD_END": "abc",
        "RUN_BINARY_SHA_START": "sha",
        "RUN_BINARY_SHA_END": "sha",
        "RUN_DIRTY_START": "''",
        "RUN_DIRTY_END": "''",
        "FASTRA_PERFORMANCE_BASELINE_RUN": "1",
    ]

    private static func selftestCase(_ description: String,
                                     _ overrides: [String: String],
                                     qualified: Bool) -> QualificationCase {
        var assignments = selftestBase
        for (key, value) in overrides { assignments[key] = value }
        return QualificationCase(description: description,
                                 assignments: assignments, qualified: qualified)
    }

    private static let selftestCases: [QualificationCase] = [
        selftestCase("vollständig grüner Baseline-Lauf", [:], qualified: true),
        selftestCase("ein echter Fehler", ["real_fail_count": "1"], qualified: false),
        selftestCase("ein Umgebungsfehler", ["env_fail_count": "1"], qualified: false),
        selftestCase("ein übersprungener Test", ["skip_count": "1"], qualified: false),
        selftestCase("ein nicht ausgeführter Test", ["not_run_count": "1"], qualified: false),
        selftestCase("Aufräumfehler", ["cleanup_env_errors": "1"], qualified: false),
        selftestCase("HEAD während des Laufs gewechselt",
                     ["RUN_HEAD_END": "def"], qualified: false),
        selftestCase("Binary während des Laufs getauscht",
                     ["RUN_BINARY_SHA_END": "anders"], qualified: false),
        selftestCase("Arbeitsbaum vorher schmutzig",
                     ["RUN_DIRTY_START": "' M x'"], qualified: false),
        selftestCase("Arbeitsbaum nachher schmutzig",
                     ["RUN_DIRTY_END": "' M x'"], qualified: false),
        selftestCase("kein ausdrücklicher Baseline-Lauf",
                     ["FASTRA_PERFORMANCE_BASELINE_RUN": "0"], qualified: false),
    ]

    @Test("Selbsttest-Lauf wird nur vollständig grün und unverändert zur Baseline",
          arguments: selftestCases)
    fileprivate func selftestQualification(fixture: QualificationCase) throws {
        let result = try judge(function: "performance_run_is_qualified",
                               in: "selftest.sh", assignments: fixture.assignments)
        #expect(result == fixture.qualified, Comment(rawValue: fixture.description))
    }

    private static let soakBase: [String: String] = [
        "ROUNDS": "60",
        // Die drei Ergebniszahlen des Laufs: keine Invarianten-Verstöße, keine
        // durch die Umgebung abgebrochene Phase, und wirklich geprüft wurde
        // auch etwas (Review-Fund 2026-09-17).
        "FINDINGS": "0",
        "ENVIRONMENT_PHASES": "0",
        "ACTIONS": "180",
        "SOAK_HEAD_START": "abc",
        "SOAK_HEAD_END": "abc",
        "SOAK_BINARY_SHA_START": "sha",
        "SOAK_BINARY_SHA_END": "sha",
        "SOAK_DIRTY_START": "''",
        "SOAK_DIRTY_END": "''",
        "FASTRA_PERFORMANCE_BASELINE_RUN": "1",
    ]

    private static func soakCase(_ description: String,
                                 _ overrides: [String: String],
                                 qualified: Bool) -> QualificationCase {
        var assignments = soakBase
        for (key, value) in overrides { assignments[key] = value }
        return QualificationCase(description: description,
                                 assignments: assignments, qualified: qualified)
    }

    private static let soakCases: [QualificationCase] = [
        soakCase("60 Runden, sauber, unverändert", [:], qualified: true),
        soakCase("zu wenige Runden", ["ROUNDS": "59"], qualified: false),
        soakCase("ein Invarianten-Verstoß", ["FINDINGS": "1"], qualified: false),
        soakCase("eine Phase durch die Umgebung abgebrochen",
                 ["ENVIRONMENT_PHASES": "1"], qualified: false),
        soakCase("keine einzige geprüfte Aktion", ["ACTIONS": "0"], qualified: false),
        soakCase("HEAD gewechselt", ["SOAK_HEAD_END": "def"], qualified: false),
        soakCase("Binary getauscht", ["SOAK_BINARY_SHA_END": "anders"], qualified: false),
        soakCase("vorher schmutzig", ["SOAK_DIRTY_START": "' M x'"], qualified: false),
        soakCase("nachher schmutzig", ["SOAK_DIRTY_END": "' M x'"], qualified: false),
        soakCase("kein Baseline-Lauf",
                 ["FASTRA_PERFORMANCE_BASELINE_RUN": "0"], qualified: false),
    ]

    @Test("Dauertest wird nur ab 60 Runden und unverändert zur Baseline",
          arguments: soakCases)
    fileprivate func soakQualification(fixture: QualificationCase) throws {
        let result = try judge(function: "soak_run_is_qualified",
                               in: "soak-test.sh", assignments: fixture.assignments)
        #expect(result == fixture.qualified, Comment(rawValue: fixture.description))
    }
}

/// `test.sh` weist zwei Aufrufe ausdrücklich mit Exit 2 ab — sich
/// ausschließende Phasenschalter und ein `--filter` ohne Muster. Beides ist
/// Umgebungs-/Bedienfehler und darf nicht als Testlauf durchgehen; geprüft hat
/// es bis 2026-09-10 nichts. Die Fälle laufen ohne echten Testlauf: Das Skript
/// bricht in der Argumentprüfung ab, bevor es irgendetwas startet.
@Suite("Argumentprüfung des Unit-Test-Runners")
struct UnitTestRunnerArgumentTests {
    private func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let runner = runnerDirectory.appendingPathComponent("test.sh")
        let result = try runTestProcess("/bin/bash",
                                        arguments: [runner.path] + arguments)
        return (result.status, result.output)
    }

    @Test("Sich ausschließende Phasenschalter enden mit Exit 2",
          arguments: [["--fast-only", "--serial-integration-only"],
                      ["--serial-integration-only", "--fast-only"]])
    func mutuallyExclusivePhaseFlags(flags: [String]) throws {
        let result = try run(flags)
        #expect(result.status == 2, "Status \(result.status): \(result.output)")
        #expect(result.output.contains("schließen sich aus"))
    }

    @Test("`--filter` ohne Muster endet mit Exit 2",
          arguments: [["--filter"], ["--filter", ""], ["--filter="]])
    func filterWithoutPattern(flags: [String]) throws {
        let result = try run(flags)
        #expect(result.status == 2, "Status \(result.status): \(result.output)")
        #expect(result.output.contains("braucht einen regulären Ausdruck"))
    }
}
