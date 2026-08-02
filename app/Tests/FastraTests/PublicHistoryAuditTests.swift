// PublicHistoryAuditTests.swift
//
// Tests für app/public-history-audit.sh gegen TEMPORÄRE Fixture-Repos (nie das
// echte Arbeitsrepo). Geprüft werden die beiden Lücken aus dem Review
// 2026-08-02:
//
//   1. Der Audit sah nur den Netto-Diff `Basis..HEAD`. Eine interne Angabe, die
//      ein Zwischen-Commit hinzufügt und ein späterer wieder entfernt, fehlte
//      dort — nach dem Push bleibt sie über die SHA des Zwischen-Commits aber
//      dauerhaft erreichbar.
//   2. `grep … || true` machte aus einem unanwendbaren Muster ein „nichts
//      gefunden". Eine kaputte private Musterdatei täuschte damit PASS vor.

import Foundation
import Testing
@testable import Fastra

/// Pfad zum echten Skript, robust aus der Testdatei-Position abgeleitet
/// (app/Tests/FastraTests/… → app/public-history-audit.sh).
private let historyScriptURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // FastraTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // app
    .appendingPathComponent("public-history-audit.sh")

private struct HistoryAuditResult {
    let exitCode: Int32
    let output: String
}

@discardableResult
private func runHistoryCommand(_ launchPath: String, _ arguments: [String],
                               cwd: URL,
                               environment: [String: String] = [:]) throws -> HistoryAuditResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    var env = ProcessInfo.processInfo.environment
    for (key, value) in environment { env[key] = value }
    process.environment = env
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return HistoryAuditResult(exitCode: process.terminationStatus,
                              output: String(data: data, encoding: .utf8) ?? "")
}

/// Ein Commit im Fixture-Repo — ohne globale Git-Identität des Rechners.
@discardableResult
private func fixtureGit(_ arguments: [String], in root: URL) throws -> HistoryAuditResult {
    try runHistoryCommand("/usr/bin/git",
                          ["-c", "user.email=t@example.invalid",
                           "-c", "user.name=T"] + arguments,
                          cwd: root)
}

/// Baut ein temporäres Repo im Fastra-Layout. Das Skript arbeitet immer
/// relativ zu SEINEM eigenen Ort (`cd "$(dirname "$0")/.."`), deshalb wird es
/// in das `app/`-Verzeichnis des Fixtures kopiert.
private func makeHistoryFixtureRepo() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-historyaudit-\(UUID().uuidString)")
    let appDirectory = root.appendingPathComponent("app")
    try FileManager.default.createDirectory(at: appDirectory,
                                            withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: historyScriptURL,
        to: appDirectory.appendingPathComponent("public-history-audit.sh"))

    try "erste Zeile\n".write(to: root.appendingPathComponent("datei.txt"),
                              atomically: true, encoding: .utf8)
    try runHistoryCommand("/usr/bin/git", ["init", "-q"], cwd: root)
    try fixtureGit(["add", "."], in: root)
    try fixtureGit(["commit", "-q", "-m", "Grundstand"], in: root)

    // Der „öffentliche" Stand ist genau dieser erste Commit. Alles danach ist
    // ausgehend und damit Prüfgegenstand.
    let head = try runHistoryCommand("/usr/bin/git", ["rev-parse", "HEAD"], cwd: root)
    let base = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
    try fixtureGit(["update-ref", "refs/remotes/github/main", base], in: root)
    return root
}

private func runHistoryAudit(root: URL, patterns: String?,
                             release: Bool = false) throws -> HistoryAuditResult {
    var environment: [String: String] = [:]
    if let patterns {
        let file = root.appendingPathComponent("muster.local")
        try patterns.write(to: file, atomically: true, encoding: .utf8)
        environment["FASTRA_PRIVATE_PATTERNS"] = file.path
    }
    let script = root.appendingPathComponent("app/public-history-audit.sh")
    return try runHistoryCommand("/bin/zsh",
                                 [script.path] + (release ? ["--release"] : []),
                                 cwd: root, environment: environment)
}

@Test("Sauberer ausgehender Stand → PASS, Exit 0")
func publicHistory_cleanOutgoingPasses() throws {
    let root = try makeHistoryFixtureRepo()
    defer { try? FileManager.default.removeItem(at: root) }

    try "zweite Zeile\n".write(to: root.appendingPathComponent("datei.txt"),
                               atomically: true, encoding: .utf8)
    try fixtureGit(["add", "."], in: root)
    try fixtureGit(["commit", "-q", "-m", "harmlose Ergaenzung"], in: root)

    let result = try runHistoryAudit(root: root, patterns: "GEHEIMHOST\n")
    #expect(result.exitCode == 0)
    #expect(result.output.contains("PASS"))
}

@Test("Interne Angabe nur in einem Zwischen-Commit wird gefunden")
func publicHistory_findsIntermediateCommitLeak() throws {
    let root = try makeHistoryFixtureRepo()
    defer { try? FileManager.default.removeItem(at: root) }

    // Commit 2 fügt die interne Angabe hinzu …
    try "erste Zeile\nHost GEHEIMHOST erreichbar\n".write(
        to: root.appendingPathComponent("datei.txt"),
        atomically: true, encoding: .utf8)
    try fixtureGit(["add", "."], in: root)
    try fixtureGit(["commit", "-q", "-m", "Zwischenstand"], in: root)

    // … Commit 3 nimmt sie wieder heraus. Der Netto-Diff Basis..HEAD ist
    // damit sauber, der Zwischen-Commit bleibt nach einem Push aber lesbar.
    try "erste Zeile\nHost anonym erreichbar\n".write(
        to: root.appendingPathComponent("datei.txt"),
        atomically: true, encoding: .utf8)
    try fixtureGit(["add", "."], in: root)
    try fixtureGit(["commit", "-q", "-m", "allgemeiner formuliert"], in: root)

    // Vorbedingung des Tests: Im Netto-Diff steht die Angabe wirklich nicht
    // mehr — sonst würde der Test auch mit der alten Prüfung bestehen.
    let netDiff = try runHistoryCommand("/usr/bin/git",
                                        ["diff", "refs/remotes/github/main..HEAD"],
                                        cwd: root)
    #expect(!netDiff.output.contains("+Host GEHEIMHOST"))

    let result = try runHistoryAudit(root: root, patterns: "GEHEIMHOST\n")
    #expect(result.output.contains("Neue Zeile:"))
    #expect(result.output.contains("GEHEIMHOST"))
    // Normallauf: Hinweis, aber kein harter Abbruch.
    #expect(result.exitCode == 0)

    let releaseRun = try runHistoryAudit(root: root, patterns: "GEHEIMHOST\n",
                                         release: true)
    #expect(releaseRun.exitCode == 1)
    #expect(releaseRun.output.contains("FAIL (Release-Modus)"))
}

@Test("Unanwendbares privates Muster bricht hart ab statt PASS zu melden")
func publicHistory_brokenPatternIsHardError() throws {
    let root = try makeHistoryFixtureRepo()
    defer { try? FileManager.default.removeItem(at: root) }

    try "zweite Zeile\n".write(to: root.appendingPathComponent("datei.txt"),
                               atomically: true, encoding: .utf8)
    try fixtureGit(["add", "."], in: root)
    try fixtureGit(["commit", "-q", "-m", "harmlose Ergaenzung"], in: root)

    // Unbalancierte Klammer → grep endet mit Status 2.
    let result = try runHistoryAudit(root: root, patterns: "GEHEIM[HOST\n")
    #expect(result.exitCode == 1)
    #expect(result.output.contains("FEHLER"))
    #expect(!result.output.contains("PASS"))
}
