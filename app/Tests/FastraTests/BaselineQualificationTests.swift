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

/// Die Qualifikationsprüfung entscheidet über Aufnahme in die kanonische
/// Performance-Historie. Laut `docs/BUILD-AND-TEST.md` darf nur ein vollständig
/// grüner Lauf auf sauberem, währenddessen unverändertem Stand aufgenommen werden.
@Suite("Qualifikation der Performance-Baseline")
struct BaselineQualificationTests {

    private func judge(function: String,
                       assignments: [String: String]) throws -> Bool {
        let helper = runnerDirectory.appendingPathComponent("tools/performance-qualification.sh")
        let result = try runTestProcess("/bin/bash", arguments: [
            "-c", #"set -eu; . "$1"; "$2""#, "baseline-qualification", helper.path, function,
        ], environment: assignments)
        #expect(result.status == 0 || result.status == 1,
                "unerwarteter Status \(result.status): \(result.output)")
        return result.status == 0
    }

    /// Der grüne Ausgangsfall — und aus ihm abgeleitet je ein Fall, der genau
    /// eine Bedingung verletzt.
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
        "RUN_DIRTY_START": "",
        "RUN_DIRTY_END": "",
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
                     ["RUN_DIRTY_START": " M x"], qualified: false),
        selftestCase("Arbeitsbaum nachher schmutzig",
                     ["RUN_DIRTY_END": " M x"], qualified: false),
        selftestCase("kein ausdrücklicher Baseline-Lauf",
                     ["FASTRA_PERFORMANCE_BASELINE_RUN": "0"], qualified: false),
    ]

    @Test("Selbsttest-Lauf wird nur vollständig grün und unverändert zur Baseline",
          arguments: selftestCases)
    fileprivate func selftestQualification(fixture: QualificationCase) throws {
        let result = try judge(function: "performance_run_is_qualified", assignments: fixture.assignments)
        #expect(result == fixture.qualified, Comment(rawValue: fixture.description))
    }

    private static let soakBase: [String: String] = [
        "ROUNDS": "60",
        // Die drei Ergebniszahlen des Laufs: keine Invarianten-Verstöße, keine
        // durch die Umgebung abgebrochene Phase, und wirklich geprüft wurde
        // auch etwas.
        "FINDINGS": "0",
        "ENVIRONMENT_PHASES": "0",
        "ACTIONS": "180",
        "SOAK_HEAD_START": "abc",
        "SOAK_HEAD_END": "abc",
        "SOAK_BINARY_SHA_START": "sha",
        "SOAK_BINARY_SHA_END": "sha",
        "SOAK_DIRTY_START": "",
        "SOAK_DIRTY_END": "",
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
        soakCase("vorher schmutzig", ["SOAK_DIRTY_START": " M x"], qualified: false),
        soakCase("nachher schmutzig", ["SOAK_DIRTY_END": " M x"], qualified: false),
        soakCase("kein Baseline-Lauf",
                 ["FASTRA_PERFORMANCE_BASELINE_RUN": "0"], qualified: false),
    ]

    @Test("Dauertest wird nur ab 60 Runden und unverändert zur Baseline",
          arguments: soakCases)
    fileprivate func soakQualification(fixture: QualificationCase) throws {
        let result = try judge(function: "soak_run_is_qualified", assignments: fixture.assignments)
        #expect(result == fixture.qualified, Comment(rawValue: fixture.description))
    }
}

/// `test.sh` weist widersprüchliche Phasenschalter und `--filter` ohne
/// Muster mit Exit 2 ab. Die Tests prüfen nur die Argumentverarbeitung;
/// es wird kein eigentlicher Testlauf gestartet.
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
