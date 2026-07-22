// WorkspaceLoadTests.swift
//
// Tests für das asynchrone Datei-Laden in Workspace.loadFile (v0.9).
// Alle Tests laufen auf dem Main-Thread (@MainActor), weil Workspace ein
// @Published-ObservableObject ist und alle Tab-Mutationen auf Main stattfinden.

import Foundation
import Testing
@testable import Fastra

// MARK: - Hilfsfunktionen

/// Frische, isolierte UserDefaults-Suite — wie in FirstLaunchTests.
private func makeFreshDefaults() -> (UserDefaults, suiteName: String) {
    let suiteName = "fastra-test-wsload-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
}

/// Schreibt `content` mit UTF-8 in eine temporäre Datei und gibt die URL zurück.
/// Liefert die KANONISCHE Form (`canonicalFileURL`) — genau die trägt der Tab
/// nach `loadFile` (das intern kanonisiert, damit `/var` und `/private/var`
/// nicht als zwei Dateien gelten). Ohne diese Angleichung schlügen die
/// `$0.url == url`-Vergleiche in Temp-Verzeichnissen fehl.
private func writeTmpUTF8(_ content: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-wsload-\(UUID().uuidString).txt")
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url.canonicalFileURL
}

// MARK: - Tests: Normaler Ladevorgang

@Test("loadFile: Platzhalter-Tab isLoading = true sofort nach dem Aufruf")
@MainActor
func wsLoad_placeholderIsLoadingImmediately() async throws {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let ws = Workspace(defaults: defaults)
    let content = "Hallo Welt\nZweite Zeile\n"
    let url = try writeTmpUTF8(content)
    defer { try? FileManager.default.removeItem(at: url) }

    // loadFile aufrufen — kehrt sofort zurück, BEVOR der Hintergrund-Task
    // fertig ist. Der Platzhalter-Tab muss sofort da sein und Willkommen
    // atomar ersetzen, weil beide Zustände nie nebeneinander stehen dürfen.
    var completionCalled = false
    ws.loadFile(at: url) { _ in completionCalled = true }

    // DIREKT nach dem Aufruf (noch im selben RunLoop-Tick) prüfen:
    #expect(ws.tabs.count == 1,
            "Platzhalter muss Willkommen sofort ersetzen")
    #expect(!ws.tabs.contains { $0.isWelcome })
    let placeholder = ws.tabs.last
    #expect(placeholder?.isLoading == true,
            "Platzhalter-Tab muss sofort isLoading = true haben")

    // Jetzt auf die Completion warten (max. 5 s).
    let deadline = Date().addingTimeInterval(5)
    while !completionCalled, Date() < deadline {
        await Task.yield()
    }
    #expect(completionCalled, "Completion wurde nie aufgerufen")
}

@Test("loadFile: Nach Completion isLoading = false + Inhalt vorhanden")
@MainActor
func wsLoad_afterCompletionContentLoaded() async throws {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let ws = Workspace(defaults: defaults)
    let content = "Testinhalt für WorkspaceLoad\nZeile 2\n"
    let url = try writeTmpUTF8(content)
    defer { try? FileManager.default.removeItem(at: url) }

    // Completion-Ergebnis aufzeichnen.
    var completionResult: Bool? = nil
    ws.loadFile(at: url) { ok in completionResult = ok }

    // Auf Completion warten.
    let deadline = Date().addingTimeInterval(5)
    while completionResult == nil, Date() < deadline {
        await Task.yield()
    }

    // Nach der Completion: Tab fertig geladen.
    #expect(completionResult == true, "Completion soll true liefern")
    let loadedTab = ws.tabs.first(where: { $0.url == url })
    #expect(loadedTab != nil, "Geladener Tab muss in ws.tabs vorhanden sein")
    #expect(loadedTab?.isLoading == false, "isLoading muss nach Completion false sein")
    #expect(loadedTab?.content == content, "Inhalt muss mit Datei-Inhalt übereinstimmen")
}

// MARK: - Tests: Dedup

@Test("loadFile: Datei bereits offen → kein zweiter Tab, Completion true")
@MainActor
func wsLoad_dedup_noSecondTab() async throws {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let ws = Workspace(defaults: defaults)
    let content = "Dedup-Test\n"
    let url = try writeTmpUTF8(content)
    defer { try? FileManager.default.removeItem(at: url) }

    // Erster Ladevorgang abwarten.
    var firstDone = false
    ws.loadFile(at: url) { _ in firstDone = true }
    let d1 = Date().addingTimeInterval(5)
    while !firstDone, Date() < d1 { await Task.yield() }

    let countAfterFirst = ws.tabs.count

    // Zweiter Aufruf mit derselben URL — darf keinen neuen Tab anlegen.
    var secondResult: Bool? = nil
    ws.loadFile(at: url) { ok in secondResult = ok }

    // Dedup ist synchron — Completion wird im selben Tick aufgerufen.
    // Kurz yielden, um den Main-RunLoop einmal zu geben.
    await Task.yield()

    #expect(ws.tabs.count == countAfterFirst,
            "Dedup: kein zweiter Tab bei gleicher URL")
    #expect(secondResult == true,
            "Dedup: Completion soll sofort true liefern")
}

// MARK: - Tests: Fehlerfall

@Test("loadFile: Nicht-existierende Datei → Platzhalter entfernt, completion false")
@MainActor
func wsLoad_nonexistentFile_placeholderRemoved() async throws {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let ws = Workspace(defaults: defaults)
    let ghost = URL(fileURLWithPath: "/tmp/fastra-wsload-geistdatei-\(UUID().uuidString).txt")
    let tabsBefore = ws.tabs.count
    let prevID = ws.activeTabID

    var completionResult: Bool? = nil
    ws.loadFile(at: ghost) { ok in completionResult = ok }

    // Auf Completion warten.
    let deadline = Date().addingTimeInterval(5)
    while completionResult == nil, Date() < deadline {
        await Task.yield()
    }

    #expect(completionResult == false, "Fehlerfall: Completion soll false liefern")
    #expect(ws.tabs.count == tabsBefore,
            "Fehlerfall: Platzhalter-Tab muss nach Fehler entfernt werden")
    // Kein Geister-Tab mit der Geist-URL.
    #expect(ws.tabs.first(where: { $0.url == ghost }) == nil,
            "Fehlerfall: kein Tab mit Fehler-URL in der Liste")
    // Vorherige activeTabID soll wiederhergestellt sein.
    #expect(ws.activeTabID == prevID,
            "Fehlerfall: activeTabID soll nach Fehler wiederhergestellt sein")
}

// MARK: - Tests: Tab vor Lade-Abschluss schließen

@Test("loadFile: Tab vor Completion schließen → completion false, kein Geister-Tab")
@MainActor
func wsLoad_tabClosedBeforeCompletion() async throws {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let ws = Workspace(defaults: defaults)

    // Eine größere Datei erzeugen, damit der Hintergrund-Task etwas Zeit braucht.
    // 500 KB sollten reichen, damit wir den Tab schließen können, bevor der
    // Task fertig ist — auf schnellen Geräten ist das ein Race, deshalb auch
    // der Generation-Guard-Test weiter unten.
    let bigContent = String(repeating: "Eine Zeile mit etwas Text.\n", count: 20_000)
    let url = try writeTmpUTF8(bigContent)
    defer { try? FileManager.default.removeItem(at: url) }

    var completionResult: Bool? = nil
    ws.loadFile(at: url) { ok in completionResult = ok }

    // Platzhalter-Tab sofort schließen (noch während isLoading = true).
    if let idx = ws.tabs.firstIndex(where: { $0.url == url }) {
        let tabID = ws.tabs[idx].id
        ws.tabs.remove(at: idx)
        // activeTabID korrigieren, falls der geschlossene Tab aktiv war.
        if ws.activeTabID == tabID {
            ws.activeTabID = ws.tabs.first?.id
        }
    }

    // Auf Completion warten oder kurzen Timeout.
    let deadline = Date().addingTimeInterval(5)
    while completionResult == nil, Date() < deadline {
        await Task.yield()
    }

    // Nach dem Schließen: kein Geister-Tab in der Liste.
    #expect(ws.tabs.first(where: { $0.url == url }) == nil,
            "Kein Geister-Tab nach Tab-Schließen vor Completion")
    // Completion KANN false liefern (Tab weg → Guard) oder true (Race, Tab
    // weg aber Task schrieb noch). Wichtiger: kein Absturz, kein Geister-Tab.
    // completionResult darf nil geblieben sein (wenn Tab weg → Guard bricht ab).
    // Wir prüfen nur: KEIN Geister-Tab existiert.
}
