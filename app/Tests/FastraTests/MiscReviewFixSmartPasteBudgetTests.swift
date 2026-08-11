// MiscReviewFixSmartPasteBudgetTests.swift
//
// Regressionstest zu Fund G2 des Code-Reviews vom 2026-08-10.
//
// `ProcessPipeCapture` begrenzte nur die Bytes JE Drain-Durchlauf (1 MiB) und
// hängte sonst alles bis zum Fristablauf an `Data` an. Ein defektes oder
// manipuliertes md-clip konnte in den zehn Sekunden also beliebig viel
// Speicher belegen. Jetzt teilen sich stdout und stderr ein hartes
// Gesamtbudget; bei Überschreitung endet die ganze Prozessgruppe sofort und
// der Nutzer bekommt einen sichtbaren Konvertierungsfehler.

import Foundation
import Testing
@testable import Fastra

/// Kleines ausführbares Shell-Skript als kontrollierter md-clip-Ersatz.
private func makeBudgetStub(name: String, body: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("smartpaste-budget-\(UUID().uuidString)-\(name)")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

@Test("markdownFromClipboard: endlose Ausgabe wird am Budget abgebrochen")
func miscReviewFix_outputBudgetStopsEndlessOutput() throws {
    // `yes` schreibt endlos auf stdout. Ohne Gesamtbudget wuchs der Puffer bis
    // zum Fristablauf; mit Budget muss der Lauf sofort mit einem sichtbaren
    // Fehler enden.
    let stub = try makeBudgetStub(name: "flood", body: "exec /usr/bin/yes fastra")
    defer { try? FileManager.default.removeItem(at: stub) }

    let started = Date()
    let result = SmartPaste.markdownFromClipboard(
        mdClipURL: stub, timeout: 10, maximumOutputBytes: 64 * 1024)
    let elapsed = Date().timeIntervalSince(started)

    guard case .failure(.conversionFailed(let detail)) = result else {
        Issue.record("Budgetüberschreitung lieferte falsches Ergebnis: \(result)")
        return
    }
    // Der Text ist lokalisiert; sprachunabhängig steht darin der Werkzeugname.
    #expect(detail.contains("md-clip"))
    // Deutlich unter der Frist von zehn Sekunden: Ein Rückfall auf das alte
    // Verhalten liefe in den Timeout statt in den Budgetabbruch.
    #expect(elapsed < 5.0,
            "Budgetabbruch wartete \(elapsed) Sekunden statt sofort zu greifen")
}

@Test("markdownFromClipboard: Ausgabe unterhalb des Budgets bleibt unangetastet")
func miscReviewFix_outputBudgetKeepsSmallOutput() throws {
    let stub = try makeBudgetStub(
        name: "small", body: "printf '# Titel\\nAbsatz\\n'")
    defer { try? FileManager.default.removeItem(at: stub) }

    let result = SmartPaste.markdownFromClipboard(
        mdClipURL: stub, timeout: 10, maximumOutputBytes: 64 * 1024)

    guard case .success(let markdown) = result else {
        Issue.record("Kleiner Output schlug fehl: \(result)")
        return
    }
    #expect(markdown == "# Titel\nAbsatz")
}

@Test("markdownFromClipboard: auch endlose stderr-Ausgabe zählt aufs Budget")
func miscReviewFix_outputBudgetCoversStderr() throws {
    // Das Budget gilt für BEIDE Ströme zusammen — ein Fehlerkanal-Schwall darf
    // den Speicher genauso wenig füllen wie stdout.
    let stub = try makeBudgetStub(
        name: "flood-stderr", body: "exec /usr/bin/yes fastra >&2")
    defer { try? FileManager.default.removeItem(at: stub) }

    let started = Date()
    let result = SmartPaste.markdownFromClipboard(
        mdClipURL: stub, timeout: 10, maximumOutputBytes: 64 * 1024)
    let elapsed = Date().timeIntervalSince(started)

    guard case .failure(.conversionFailed) = result else {
        Issue.record("stderr-Schwall lieferte falsches Ergebnis: \(result)")
        return
    }
    #expect(elapsed < 5.0,
            "Budgetabbruch wartete \(elapsed) Sekunden statt sofort zu greifen")
}

@Test("markdownFromClipboard: letztes Byte nach Prozessende überschreitet das Budget")
func miscReviewFix_outputBudgetChecksFinalDrain() throws {
    let output = String(repeating: "x", count: 65)
    let stub = try makeBudgetStub(name: "final-drain", body: "printf '\(output)'")
    defer { try? FileManager.default.removeItem(at: stub) }

    let result = SmartPaste.markdownFromClipboard(
        mdClipURL: stub, timeout: 10, maximumOutputBytes: 64)

    guard case .failure(.conversionFailed) = result else {
        Issue.record("65 Bytes wurden trotz 64-Byte-Grenze als Erfolg geliefert: \(result)")
        return
    }
}
