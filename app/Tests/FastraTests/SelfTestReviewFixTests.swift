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

@Test("pasteindent verlässt den Test nur über den Zwischenablage-Rückgabepfad")
func pasteIndentRestoresPasteboardOnEveryExit() throws {
    let source = try String(contentsOf: selfTestSourceURL, encoding: .utf8)
    let body = try functionBody(named: "func runPasteMatchIndentationTest()", in: source)

    // Der Test überschreibt `NSPasteboard.general`. Jeder Weg hinaus — Erfolg,
    // Fehler, früher Abbruch — muss deshalb über `finishPasteIndent` laufen,
    // das die Sicherung zurückschreibt. Ein direktes `finish(` würde die
    // Zwischenablage des Nutzers behalten.
    let withoutWrapper = removing("finishPasteIndent(", from: body)
    #expect(!withoutWrapper.contains("finish("), """
        `runPasteMatchIndentationTest` ruft `finish(` direkt auf. Der Test \
        überschreibt die Zwischenablage des Nutzers; jeder Abschluss muss über \
        `finishPasteIndent` gehen, sonst bleibt der Testinhalt darin stehen.
        """)

    // Und er muss überhaupt sichern, bevor er schreibt.
    #expect(body.contains("capturePasteboardItems()"), """
        `runPasteMatchIndentationTest` sichert die Zwischenablage nicht mehr \
        (`capturePasteboardItems()` fehlt).
        """)
    #expect(body.contains("pasteIndentPasteboardOwnedChangeCount"), """
        `runPasteMatchIndentationTest` merkt sich den Besitzstand nicht mehr — \
        ohne ihn kann die Rückgabe eine neuere Kopie des Nutzers überschreiben.
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

    let pasteIndentFinish = try functionBody(
        named: "func finishPasteIndent(", in: source)
    #expect(pasteIndentFinish.contains("pasteboardIsStillOwned("), """
        `finishPasteIndent` prüft den Besitzstand nicht mehr und würde eine \
        neuere Kopie des Nutzers überschreiben.
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
