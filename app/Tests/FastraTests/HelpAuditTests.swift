// HelpAuditTests.swift
//
// Tests für app/help-audit.sh (Etappe 4 Wunschpaket 2026-07b) gegen
// TEMPORÄRE Fixture-Repos (nie das echte Arbeitsrepo): Marker aktuell →
// PASS; Marker veraltet → Hinweis, aber Exit 0; Release-Modus → Exit 1.

import Foundation
import Testing
@testable import Fastra

/// Pfad zum echten Skript, robust aus der Testdatei-Position abgeleitet
/// (app/Tests/FastraTests/… → app/help-audit.sh).
private let scriptURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // FastraTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // app
    .appendingPathComponent("help-audit.sh")

private struct AuditResult {
    let exitCode: Int32
    let output: String
}

/// Führt ein Kommando im Fixture-Repo aus und liefert stdout+stderr.
@discardableResult
private func run(_ launchPath: String, _ arguments: [String], cwd: URL,
                 environment: [String: String] = [:]) throws -> AuditResult {
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
    return AuditResult(exitCode: process.terminationStatus,
                       output: String(data: data, encoding: .utf8) ?? "")
}

/// Baut ein temporäres Git-Repo im Fastra-Layout (app/Sources + Marker).
/// Gibt Root und den Hash des ersten Commits zurück.
private func makeFixtureRepo() throws -> (root: URL, firstCommit: String) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-helpaudit-\(UUID().uuidString)")
    let sources = root.appendingPathComponent("app/Sources/Fastra")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try "let a = 1\n".write(to: sources.appendingPathComponent("A.swift"),
                            atomically: true, encoding: .utf8)
    for arguments in [["init", "-q"],
                      ["-c", "user.email=t@example.invalid", "-c", "user.name=T",
                       "add", "."],
                      ["-c", "user.email=t@example.invalid", "-c", "user.name=T",
                       "commit", "-q", "-m", "erster Stand"]] {
        let result = try run("/usr/bin/git", arguments, cwd: root)
        #expect(result.exitCode == 0, "git \(arguments) schlug fehl: \(result.output)")
    }
    let head = try run("/usr/bin/git", ["rev-parse", "HEAD"], cwd: root)
    let hash = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
    try (hash + "\n").write(to: root.appendingPathComponent("app/help-reviewed-commit"),
                            atomically: true, encoding: .utf8)
    return (root, hash)
}

private func runAudit(root: URL, release: Bool = false) throws -> AuditResult {
    try run("/bin/zsh", [scriptURL.path] + (release ? ["--release"] : []),
            cwd: root, environment: ["FASTRA_HELP_AUDIT_ROOT": root.path])
}

@Test("Marker aktuell → PASS, Exit 0")
func audit_currentMarkerPasses() throws {
    let (root, _) = try makeFixtureRepo()
    defer { try? FileManager.default.removeItem(at: root) }
    let result = try runAudit(root: root)
    #expect(result.exitCode == 0)
    #expect(result.output.contains("HELP AUDIT: PASS"))
}

@Test("Produktrelevanter Commit nach dem Marker → Hinweis mit Commit, Exit 0")
func audit_outdatedMarkerHints() throws {
    let (root, _) = try makeFixtureRepo()
    defer { try? FileManager.default.removeItem(at: root) }
    // Neuer Commit unter app/Sources → Marker ist veraltet.
    try "let b = 2\n".write(
        to: root.appendingPathComponent("app/Sources/Fastra/B.swift"),
        atomically: true, encoding: .utf8)
    try run("/usr/bin/git", ["-c", "user.email=t@example.invalid",
                             "-c", "user.name=T", "add", "."], cwd: root)
    try run("/usr/bin/git", ["-c", "user.email=t@example.invalid",
                             "-c", "user.name=T",
                             "commit", "-q", "-m", "neue Funktion"], cwd: root)

    let result = try runAudit(root: root)
    #expect(result.exitCode == 0, "Normallauf darf nicht hart fehlschlagen")
    #expect(result.output.contains("neue Funktion"))
    #expect(result.output.contains("B.swift"))
    #expect(result.output.contains("Marker fortschreiben"))
}

@Test("Release-Modus: veralteter Marker → harter Fehler (Exit 1)")
func audit_releaseModeFails() throws {
    let (root, _) = try makeFixtureRepo()
    defer { try? FileManager.default.removeItem(at: root) }
    try "let c = 3\n".write(
        to: root.appendingPathComponent("app/Sources/Fastra/C.swift"),
        atomically: true, encoding: .utf8)
    try run("/usr/bin/git", ["-c", "user.email=t@example.invalid",
                             "-c", "user.name=T", "add", "."], cwd: root)
    try run("/usr/bin/git", ["-c", "user.email=t@example.invalid",
                             "-c", "user.name=T",
                             "commit", "-q", "-m", "ungeprüft"], cwd: root)

    let result = try runAudit(root: root, release: true)
    #expect(result.exitCode == 1)
    #expect(result.output.contains("FAIL (Release-Modus)"))
}

@Test("Release-Modus: aktueller Marker → Exit 0 (auch Doku-Commits stören nicht)")
func audit_releaseModePassesWithDocsOnly() throws {
    let (root, _) = try makeFixtureRepo()
    defer { try? FileManager.default.removeItem(at: root) }
    // Ein Commit AUSSERHALB von app/Sources zählt nicht als produktrelevant.
    try "Notiz\n".write(to: root.appendingPathComponent("README.md"),
                        atomically: true, encoding: .utf8)
    try run("/usr/bin/git", ["-c", "user.email=t@example.invalid",
                             "-c", "user.name=T", "add", "."], cwd: root)
    try run("/usr/bin/git", ["-c", "user.email=t@example.invalid",
                             "-c", "user.name=T",
                             "commit", "-q", "-m", "nur Doku"], cwd: root)

    let result = try runAudit(root: root, release: true)
    #expect(result.exitCode == 0)
    #expect(result.output.contains("HELP AUDIT: PASS"))
}

@Test("Fehlende oder kaputte Markerdatei → Exit 1")
func audit_missingMarkerFails() throws {
    let (root, _) = try makeFixtureRepo()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(
        at: root.appendingPathComponent("app/help-reviewed-commit"))
    let missing = try runAudit(root: root)
    #expect(missing.exitCode == 1)

    try "kein-commit\n".write(
        to: root.appendingPathComponent("app/help-reviewed-commit"),
        atomically: true, encoding: .utf8)
    let broken = try runAudit(root: root)
    #expect(broken.exitCode == 1)
}
