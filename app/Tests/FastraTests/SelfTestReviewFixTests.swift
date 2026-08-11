// SelfTestReviewFixTests.swift
//
// Wächter über drei Aufräumregeln der Selbsttests. Sie lassen sich nicht am
// laufenden Fenstertest prüfen: Die Tests beenden den Prozess über `exit()`,
// und was sie dabei liegen lassen — eine überschriebene Zwischenablage, eine
// zusätzliche Preferences-Domain —, sieht man erst der UMGEBUNG an. Geprüft
// wird deshalb die Quelle selbst, nach dem Vorbild von
// `AppStorageIsolationTests`.
//
// Hintergrund (Code-Review 2026-08-10):
//
// 1. `finish` verlässt den Prozess über `exit()`. Der Swift-Stack wird dabei
//    NICHT abgewickelt — ein `defer` zum Aufräumen läuft also nie.
// 2. Eine Sicherung der Zwischenablage darf nur zurückgeschrieben werden,
//    solange der Inhalt noch der test-eigene ist. Hat der Nutzer während des
//    Laufs selbst kopiert, würde das blinde Zurückschreiben seine frische
//    Kopie vernichten.

import Foundation
import Testing

/// Die Selbsttest-Quelle, robust aus der Testdatei-Position abgeleitet
/// (app/Tests/FastraTests/… → app/Sources/Fastra/SelfTest.swift).
private let selfTestSourceURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // FastraTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // app
    .appendingPathComponent("Sources")
    .appendingPathComponent("Fastra")
    .appendingPathComponent("SelfTest.swift")

/// Schneidet den Rumpf einer Swift-Funktion aus dem Quelltext.
///
/// Gesucht wird die Zeile mit der Deklaration; ab deren erster `{` werden die
/// Klammern gezählt, bis die Tiefe wieder null erreicht. Zeichenketten und
/// Kommentare werden bewusst nicht ausgeklammert — für die hier geprüften
/// Rümpfe reicht die einfache Zählung, und ein Fehlschnitt fiele sofort als
/// roter Test auf.
private func functionBody(named declaration: String, in source: String) throws -> String {
    let lines = source.components(separatedBy: .newlines)
    guard let start = lines.firstIndex(where: { $0.contains(declaration) }) else {
        Issue.record("Deklaration \(declaration) steht nicht mehr in SelfTest.swift")
        return ""
    }
    var body = ""
    var depth = 0
    var started = false
    for line in lines[start...] {
        for character in line {
            if character == "{" {
                depth += 1
                started = true
            } else if character == "}" {
                depth -= 1
            }
        }
        body += line + "\n"
        if started, depth == 0 { return body }
    }
    Issue.record("Rumpf von \(declaration) endet nicht — Klammern zählen nicht auf")
    return body
}

/// Entfernt die erlaubte Schreibweise, damit nur der verbotene Rest übrig
/// bleibt.
private func removing(_ allowed: String, from text: String) -> String {
    text.replacingOccurrences(of: allowed, with: "")
}

@Test("pasteindent nutzt die zentrale, absturzfeste Zwischenablage-Sicherung")
func pasteIndentRestoresPasteboardOnEveryExit() throws {
    let source = try String(contentsOf: selfTestSourceURL, encoding: .utf8)
    let body = try functionBody(named: "func runPasteMatchIndentationTest()", in: source)

    #expect(body.contains("writeSelfTestPasteboardString("), """
        `runPasteMatchIndentationTest` nutzt die zentrale, itemgetreue und vor \
        der Änderung persistierte Sicherung nicht mehr.
        """)
}

@Test("Zwischenablage wird nur zurückgeschrieben, solange sie test-eigen ist")
func pasteboardRestorePathsCheckOwnership() throws {
    let source = try String(contentsOf: selfTestSourceURL, encoding: .utf8)

    let soakRestore = try functionBody(
        named: "func restoreSoakPasteboardIfPresent(", in: source)
    #expect(soakRestore.contains("pasteboardIsStillOwned("), """
        Die Dauertest-Wiederherstellung prüft den Besitzstand nicht mehr. Sie \
        würde damit einen Inhalt überschreiben, den der Nutzer während des \
        langen Laufs selbst kopiert hat.
        """)
    #expect(soakRestore.contains("guard backup.mutationConfirmed"), """
        Ein nur vorbereiteter Soak-Zählerschritt darf nach einem Crash nicht \
        automatisch über eine mögliche Nutzerkopie geschrieben werden.
        """)

    let selfTestFinish = try functionBody(
        named: "func finishSelfTestPasteboardMutation(", in: source)
    #expect(selfTestFinish.contains("pasteboardIsStillOwned("), """
        Der zentrale Selbsttest-Abschluss prüft den Besitzstand nicht mehr und \
        würde eine neuere Kopie des Nutzers überschreiben.
        """)
    let persistence = try functionBody(
        named: "func persistSelfTestPasteboardBackup(", in: source)
    #expect(persistence.contains(".atomic"), """
        Die Crash-Sicherung der Zwischenablage wird nicht mehr atomar geschrieben.
        """)
    let prepare = try functionBody(
        named: "func prepareSelfTestPasteboardMutation()", in: source)
    #expect(prepare.contains("ownedChangeCount &+= 1"))
    #expect(prepare.contains("mutationConfirmed = false"), """
        Ein vorab journalisierter Zählerschritt muss bis zur Nachkontrolle als \
        unbestätigt gelten. Sonst könnte nach einem Crash genau eine Nutzerkopie \
        fälschlich als Testinhalt zurückgeschrieben werden.
        """)
    #expect(prepare.contains("persistSelfTestPasteboardBackup(backup)"), """
        Der erwartete Besitzstand muss VOR der Pasteboard-Änderung atomar auf \
        Platte stehen; eine nachträgliche Blindübernahme öffnet das Crash-Fenster.
        """)
    let note = try functionBody(
        named: "func noteSelfTestPasteboardMutation(", in: source)
    #expect(note.contains("mutationConfirmed = true"))
    #expect(note.contains("capturePasteboardItems() == expectedItems"), """
        Ein passender Zähler allein beweist nicht, dass der Test geschrieben \
        hat; vor der Bestätigung müssen Items, Typen und Daten vollständig dem \
        erwarteten Testinhalt entsprechen.
        """)
    #expect(note.contains("persistSelfTestPasteboardBackup(backup)"), """
        Erst die geprüfte Änderung darf das Crash-Journal als automatisch \
        wiederherstellbar bestätigen.
        """)
    #expect(selfTestFinish.contains("guard backup.mutationConfirmed"), """
        Eine nur vorbereitete Änderung darf nach einem Crash keinen möglicherweise \
        neueren Nutzerinhalt überschreiben.
        """)
}

@Test("Selbsttest-Suiten mit UUID werden am Prozessende wirklich entfernt")
func windowHeightSuiteIsRegisteredForPurge() throws {
    let source = try String(contentsOf: selfTestSourceURL, encoding: .utf8)

    let body = try functionBody(named: "func runWindowHeightTest()", in: source)
    #expect(body.contains("TestDefaultsPurge.register("), """
        `runWindowHeightTest` meldet seine eigene UUID-Suite nicht mehr beim \
        Aufräumer an. Da der Test über `finish`/`exit()` endet, läuft sein \
        `defer` nie — die Preferences-Domain bliebe nach jedem Lauf liegen.
        """)

    // Die Anmeldung nützt nur mit dem passenden Aufräumschritt am Prozessende:
    // `purgeStale` allein fasst frische Suiten (unter einer Stunde) nicht an.
    let launcher = try functionBody(named: "func runIfRequested()", in: source)
    #expect(launcher.contains("TestDefaultsPurge.purgeRegistered()"), """
        Der Selbsttest-Start meldet `purgeRegistered()` nicht mehr per `atexit` \
        an. Registrierte UUID-Suiten blieben dann liegen, denn `purgeStale` \
        räumt erst Domains ab, die älter als eine Stunde sind.
        """)
}
