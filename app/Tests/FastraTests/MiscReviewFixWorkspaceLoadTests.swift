// MiscReviewFixWorkspaceLoadTests.swift
//
// Regressionstest zu Fund G1 des Code-Reviews vom 2026-08-10.
//
// `Workspace.loadFile` meldete sein Ergebnis nur, solange der Workspace noch
// lebte: Der Main-Actor-Block stieg bei `guard let self` ohne Rückmeldung aus.
// Wer die Fenster über diese Rückmeldungen zählt — der
// `SessionRestorationCoordinator` tut genau das —, wartete danach ewig; die
// gepufferten Finder-/CLI-Öffnungen wurden nie ausgeliefert.
//
// Der Test schließt das Fenster mitten im Ladevorgang nach: Er gibt die
// einzige starke Referenz auf den Workspace frei, während die Datei im
// Hintergrund gelesen wird, und verlangt trotzdem genau eine Rückmeldung.

import Foundation
import Testing
@testable import Fastra

@Test("loadFile meldet genau einmal, auch wenn der Workspace währenddessen verschwindet")
@MainActor
func miscReviewFix_loadFileReportsAfterWorkspaceDisappears() async throws {
    let suite = "fastra-test-miscfix-load-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-miscfix-load-\(UUID().uuidString).txt")
    try "Inhalt der Testdatei\n".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    var reportCount = 0
    var reportedSuccess: Bool?
    // Schwache Zweitreferenz: Nur wenn der Workspace wirklich freigegeben
    // wurde, prüft dieser Test den gemeldeten Fehlerpfad.
    weak var releasedWorkspace: Workspace?

    var workspace: Workspace? = Workspace(defaults: defaults)
    releasedWorkspace = workspace
    workspace?.loadFile(at: url.canonicalFileURL) { success in
        reportCount += 1
        reportedSuccess = success
    }
    // Fenster zu: Ab hier hält niemand mehr den Workspace. Der Hintergrund-
    // Task liest die Datei aber noch.
    workspace = nil

    // Auf die Rückmeldung warten (max. 5 s). `Task.yield` gibt den Main-Actor
    // frei, damit der Abschlussblock des Ladevorgangs überhaupt laufen kann.
    let deadline = Date().addingTimeInterval(5)
    while reportCount == 0, Date() < deadline {
        await Task.yield()
    }

    #expect(reportCount == 1,
            "Completion muss genau einmal kommen, kam \(reportCount)-mal")
    #expect(releasedWorkspace == nil,
            "Workspace wurde nicht freigegeben — der Test prüft dann nicht den Zielpfad")
    if releasedWorkspace == nil {
        #expect(reportedSuccess == false,
                "Ohne Workspace kann kein Inhalt angekommen sein")
    }
}

@Test("loadFile meldet bei lebendem Workspace unverändert genau einmal Erfolg")
@MainActor
func miscReviewFix_loadFileStillReportsSuccessOnce() async throws {
    let suite = "fastra-test-miscfix-load-ok-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-miscfix-load-ok-\(UUID().uuidString).txt")
    try "Zeile\n".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    // Gegenprobe zum `defer`-Fallback: Der Erfolgsweg darf nicht zusätzlich
    // ein `false` nachschieben.
    let workspace = Workspace(defaults: defaults)
    var reports: [Bool] = []
    workspace.loadFile(at: url.canonicalFileURL) { reports.append($0) }

    let deadline = Date().addingTimeInterval(5)
    while reports.isEmpty, Date() < deadline {
        await Task.yield()
    }
    // Kurz nachlaufen lassen: Eine doppelte Meldung käme im selben Tick.
    await Task.yield()
    #expect(reports == [true], "Erwartet genau eine Erfolgsmeldung, war \(reports)")
}
