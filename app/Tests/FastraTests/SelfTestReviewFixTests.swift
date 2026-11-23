// SelfTestReviewFixTests.swift
//
// Wächter über drei Aufräumregeln der Selbsttests. Sie lassen sich nicht am
// laufenden Fenstertest prüfen: Die Tests beenden den Prozess über `exit()`,
// und was sie dabei liegen lassen — eine überschriebene Zwischenablage, eine
// zusätzliche Preferences-Domain —, sieht man erst der Umgebung an. Geprüft
// wird deshalb die Quelle selbst, nach dem Vorbild von
// `AppStorageIsolationTests`.
// Die reguläre Clipboard-Session und Abschlussauswertung laufen zusätzlich
// in einem isolierten Kindprozess gegen eine Zwischenablage-Attrappe.
// Der Systemtastentreiber wird zusätzlich mit echten Antwortdateien geprüft.
//
// Hintergrund:
//
// 1. `finish` verlässt den Prozess über `exit()`. Der Swift-Stack wird dabei
//    nicht abgewickelt — ein `defer` zum Aufräumen läuft also nie.
// 2. Eine Sicherung der Zwischenablage darf nur zurückgeschrieben werden,
//    solange der Inhalt noch der test-eigene ist. Hat der Nutzer während des
//    Laufs selbst kopiert, würde das blinde Zurückschreiben seine frische
//    Kopie vernichten.

import Foundation
import Testing
@testable import Fastra

@Test("Der Systemtastentreiber wartet trotz alter oder unvollständiger Antwort auf die aktuelle Nonce", arguments: [false, true])
@MainActor func systemHistoryIgnoresStaleResponseSerialRunnerIntegration(_ malformed: Bool) async throws {
    let directory = testTemporaryDirectory().appendingPathComponent("history-response-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history-response.json")
    try Data((malformed ? "{" : "{\"nonce\":\"old\",\"ok\":true}").utf8).write(to: url)
    let nonce = UUID().uuidString
    let driver = Task { @MainActor in
        try await Task.sleep(for: .milliseconds(60))
        try JSONSerialization.data(withJSONObject: ["nonce": nonce, "ok": false])
            .write(to: url, options: .atomic)
    }
    defer { driver.cancel() }
    let response = try await SelfTest.waitForSystemHistoryResponse(at: url, nonce: nonce)
    try await driver.value
    #expect(response["nonce"] as? String == nonce)
    #expect(response["ok"] as? Bool == false)
}

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
/// Kommentare werden bewusst nicht ausgeklammert. Dieser Bindungsaudit ist
/// weder ein Swift-Parser noch ein Ausführungsbeleg; zusätzliche Klammern
/// können auch einen Ausschnitt liefern, der die gesuchten Literale enthält.
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

@Test("Clipboard-Session und Abschluss laufen regulär im isolierten Prozess")
func pasteboardCaptureSerialRunnerIntegration() throws {
    let directory = testTemporaryDirectory().appendingPathComponent("clipboard-race-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // Ganze reguläre Quelldateien statt ausgeschnittener privater Funktionen.
    // Die Attrappe besitzt nur Backendinhalt und Journal, kein AppKit-Objekt.
    let fixture = #"""
        import Foundation
        import Darwin

        @main struct ClipboardProcess {
            static func main() {
                let mode = CommandLine.arguments[1]
                let initialForeign = mode.hasPrefix("initial-foreign")
                let journal = URL(fileURLWithPath: CommandLine.arguments[2])
                var count = 6
                var items: SelfTestPasteboardBackup.Items = [["original": Data([1])]]
                var checking = false
                let expected: SelfTestPasteboardBackup.Items = [["test": Data([2])]]
                let session = SelfTestPasteboardSession<SelfTestPasteboardBackup.Items>(backend: .init(
                    currentChangeCount: { count },
                    captureItems: {
                        if initialForeign && !checking {
                            let captured = items
                            count += 1
                            items = [["foreign": Data([3])]]
                            if mode.hasSuffix("unreadable") {
                                throw NSError(domain: "FastraSelfTestPasteboard", code: 4)
                            }
                            return captured
                        }
                        if checking {
                            if mode.hasPrefix("foreign") {
                                count += 1
                                items = [["foreign": Data([3])]]
                            }
                            if mode.hasSuffix("unreadable") {
                                throw NSError(domain: "FastraSelfTestPasteboard", code: 4)
                            }
                            if mode != "roundtrip" && mode != "abandon" {
                                items = [["foreign": Data([3])]]
                            }
                        }
                        return items
                    },
                    persistBackup: { backup in
                        let data = try PropertyListSerialization.data(fromPropertyList: [
                            "items": backup.items,
                            "ownedChangeCount": backup.ownedChangeCount,
                            "mutationConfirmed": backup.mutationConfirmed
                        ], format: .binary, options: 0)
                        try data.write(to: journal, options: .atomic)
                    },
                    abandonBackup: { try? FileManager.default.removeItem(at: journal) },
                    prepareRestore: { $0 },
                    writeRestore: { restored in
                        guard mode == "roundtrip" else { fatalError("fremden Inhalt überschrieben") }
                        count += 1
                        items = restored
                    }
                ))
                var outcome = SelfTestOutcome.pass
                do {
                    try session.prepare()
                    count += 1
                    items = expected
                    checking = true
                    try session.note(expectedItems: expected)
                    if mode == "abandon" { session.abandon() }
                } catch {
                    outcome = SelfTestPasteboardSession<SelfTestPasteboardBackup.Items>.outcome(for: error)
                }
                let result = SelfTestCompletion.resolve(
                    outcome: outcome, message: "Nachkontrolle", pasteboardCleanup: session.finish()
                )
                if mode == "roundtrip" && items != [["original": Data([1])]] { exit(90) }
                if mode.contains("foreign") && items != [["foreign": Data([3])]] { exit(91) }
                if initialForeign && count != 7 { exit(92) }
                FileHandle.standardError.write(Data((
                    "SELFTEST-RESULT v=1 test=clipboard-capture-race status=\(result.outcome.protocolStatus)\n"
                    + "SELFTEST clipboard-capture-race: \(result.outcome.protocolStatus) — \(result.message)\n"
                ).utf8))
                exit(result.outcome == .pass ? 0 : 1)
            }
        }
        """#
    let script = directory.appendingPathComponent("fixture.swift")
    let binary = directory.appendingPathComponent("fixture")
    try fixture.write(to: script, atomically: true, encoding: .utf8)
    let sourceDirectory = selfTestSourceURL.deletingLastPathComponent()
    let compiler = try runTestProcess("/usr/bin/xcrun", arguments: [
        "swiftc", "-swift-version", "5", "-module-cache-path",
        directory.appendingPathComponent("cache").path,
        sourceDirectory.appendingPathComponent("SelfTestPasteboardSession.swift").path,
        sourceDirectory.appendingPathComponent("SelfTestCompletion.swift").path,
        script.path, "-o", binary.path
    ])
    try #require(compiler.status == 0, Comment(rawValue: compiler.output))
    for mode in ["foreign-unreadable", "foreign-readable", "own-unreadable", "own-mismatch", "roundtrip", "abandon", "initial-foreign-readable", "initial-foreign-unreadable"] {
        let journal = directory.appendingPathComponent(mode + ".plist")
        let process = try runTestProcess(binary.path, arguments: [mode, journal.path], timeout: 10)
        let foreign = mode.contains("foreign")
        let passed = mode == "roundtrip" || mode == "abandon"
        #expect(process.status == (passed ? 0 : 1), Comment(rawValue: process.output))
        #expect(process.output.contains("test=clipboard-capture-race status=\(passed ? "PASS" : foreign ? "ENV" : "FAIL")"), Comment(rawValue: process.output))
        #expect(FileManager.default.fileExists(atPath: journal.path) == (!foreign && !passed))
        if !foreign && !passed {
            let data = try Data(contentsOf: journal)
            let backup = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            #expect(backup["items"] as? SelfTestPasteboardBackup.Items == [["original": Data([1])]])
            #expect(backup["ownedChangeCount"] as? Int == 7)
            #expect(backup["mutationConfirmed"] as? Bool == false)
        }
    }
}

@Test("pasteindent ist an die zentrale Zwischenablage-Sicherung angebunden")
func pasteIndentUsesCentralPasteboardAdapter() throws {
    let source = try String(contentsOf: selfTestSourceURL, encoding: .utf8)
    let body = try functionBody(named: "func runPasteMatchIndentationTest()", in: source)

    #expect(body.contains("writeSelfTestPasteboardString("), """
        `runPasteMatchIndentationTest` nutzt die zentrale, itemgetreue und vor \
        der Änderung persistierte Sicherung nicht mehr.
        """)
}

@Test("Private Clipboard-Adapter behalten ihre Sicherheitsbindungen")
func pasteboardAdaptersKeepSafetyBindings() throws {
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

    // Reguläre Sessiontests prüfen Besitz und Übergänge. Dieser Audit prüft
    // private Aufrufbindungen und den angeforderten atomaren Schreibmodus,
    // nicht dessen tatsächliche Ausführung oder die Wiederaufnahme nach Crash.
    let selfTestFinish = try functionBody(
        named: "func finishSelfTestPasteboardMutation(", in: source)
    #expect(selfTestFinish.contains("selfTestPasteboardSession.finish()"))
    let completion = try functionBody(named: "func finish(_ outcome: SelfTestOutcome,", in: source)
    #expect(completion.contains("finishSelfTestPasteboardMutation()"))
    #expect(completion.contains("SelfTestCompletion.resolve("))
    let persistence = try functionBody(
        named: "func persistSelfTestPasteboardBackup(", in: source)
    #expect(persistence.contains(".atomic"), "Crash-Sicherung muss atomar geschrieben werden")
    let prepare = try functionBody(named: "func prepareSelfTestPasteboardMutation()", in: source)
    #expect(prepare.contains("selfTestPasteboardSession.prepare()"))
    let note = try functionBody(named: "func noteSelfTestPasteboardMutation(", in: source)
    #expect(note.contains("selfTestPasteboardSession.note(expectedItems: expectedItems)"))
}

@Test("Fensterhöhen-Test behält seine Purge-Registrierungsbindung")
func windowHeightKeepsPurgeRegistrationBinding() throws {
    let source = try String(contentsOf: selfTestSourceURL, encoding: .utf8)

    let body = try functionBody(named: "func runWindowHeightTest()", in: source)
    #expect(body.contains("TestDefaultsPurge.register("), """
        `runWindowHeightTest` meldet seine eigene UUID-Suite nicht mehr beim \
        Aufräumer an. Da der Test über `finish`/`exit()` endet, läuft sein \
        `defer` nie — die Preferences-Domain bliebe nach jedem Lauf liegen.
        """)


}

/// `exit()` wickelt den Swift-Stack nicht ab; `defer` läuft dort nicht.
/// Der Test erlaubt nur namentlich begründete `defer`-Blöcke in Pfaden, die
/// über `finish` enden, damit nötiges Aufräumen nicht unbemerkt entfällt.
@Test("Jeder defer im gesamten Harness ist ausdrücklich begründet")
func everyDeferInSelfTestIsAccountedFor() throws {
    let sources = try selfTestHarnessSources(in: selfTestSourceURL
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())

    // Erlaubt, weil die umgebende Closure regulär zurückkehrt (kein `finish`):
    // die Aufräumzeile der Bildschirmaufnahme.
    let screenshotCleanup = "defer { try? FileManager.default.removeItem(at: url) }"
    // Erlaubt und im Code ausführlich begründet: Der Test meldet seine Suite
    // zusätzlich bei `TestDefaultsPurge` an, der `defer` ist nur der Weg für
    // den Fall, dass die Funktion doch einmal regulär zurückkehrt.
    let defaultsDomainCleanup = "defer { defaults.removePersistentDomain(forName: suiteName) }"
    // focusEditor kehrt regulär zurück oder wirft vor dem äußeren `finish`.
    // Sein vorübergehender Mausmonitor muss in beiden Fällen entfernt werden.
    let focusMonitorCleanup = "defer { if let monitor { NSEvent.removeMonitor(monitor) } }"
    // Der getrackte Menühilfsaufruf beendet sich regulär oder wirft; der äußere
    // Selbsttest ruft erst danach finish auf. Seine Observer müssen immer weg.
    let trackedMenuCleanup = "defer { // trackedHistoryFromEditMenu kehrt vor dem äußeren finish regulär zurück oder wirft."
    // Derselbe enge Lebensdauervertrag gilt für den frischen Hauptmenüaufruf:
    // kein finish im Helfer, Observer/Timer enden vor dem äußeren Abschluss.
    let trackedMainMenuCleanup = "defer { // trackedMainMenuItem kehrt vor dem äußeren finish regulär zurück oder wirft."
    // exercise() räumt vor seinem regulären Ergebnis bzw. Fehler auf; erst
    // die äußere Task ruft finish auf. Die Fixture ist zusätzlich registriert.
    let jsonFixtureCleanup = "defer { try? FileManager.default.removeItem(at: base) }"
    // Der Datei-Worker liefert seine fertige Fixture vor dem äußeren finish.
    let jsonFileHandleCleanup = "defer { try? handle.close() }"
    // delayedIndicator() kehrt vor exercise()/finish regulär zurück oder
    // wirft. Aktivität und ursprünglicher Fensterrahmen werden dabei immer
    // zurückgesetzt; der Helfer beendet den Prozess selbst nicht.
    let indicatorCleanup = "defer { ws.documentTransformationActivity = nil; window.setFrame(originalFrame, display: true) }"
    // Der native Shortcut-Helfer wirft oder kehrt vor finish zurück; der
    // zentrale Abschluss entfernt denselben Monitor zusätzlich bei exit.
    let shortcutMonitorCleanup = "defer { // deliverSoftWrapShortcut kehrt vor dem äußeren finish regulär zurück oder wirft."
    let main = "Sources/Fastra/SelfTest.swift"
    // Jede Ausnahme bindet Datei, Anweisung und deren konkrete Lebensdauer.
    let allowed: [(file: String, statement: String, reason: String)] = [
        (main, screenshotCleanup, "Aufnahme-Closure kehrt regulär zurück und entfernt ihre Bilddatei."),
        (main, defaultsDomainCleanup, "Nur regulärer Rückkehrweg; bei exit räumt die zusätzlich registrierte Purge auf."),
        (main, focusMonitorCleanup, "focusEditor entfernt seinen Mausmonitor vor Rückkehr oder throw."),
        (main, trackedMenuCleanup, "trackedHistoryFromEditMenu entfernt Observer vor äußerem finish."),
        (main, trackedMainMenuCleanup, "trackedMainMenuItem beendet Observer und Timer vor äußerem finish."),
        (main, jsonFixtureCleanup, "exercise entfernt die registrierte Fixture vor Ergebnis oder Fehler."),
        (main, jsonFileHandleCleanup, "Datei-Worker schließt sein Handle vor Übergabe der fertigen Fixture."),
        (main, indicatorCleanup, "delayedIndicator setzt Aktivität und Fensterrahmen vor Rückkehr oder throw zurück."),
        (main, shortcutMonitorCleanup, "Shortcut-Helfer entfernt Monitor vor Rückkehr oder throw; finish sichert exit zusätzlich."),
        ("Sources/Fastra/SelfTestMenuRootExchange.swift", "defer { close(fd) }",
         "read schließt den nur für diesen regulär zurückkehrenden oder werfenden Leseaufruf geöffneten Deskriptor."),
        ("Sources/Fastra/SelfTestMenuRootExchange.swift", "defer { close(fd); unlinkat(descriptor, temporary, 0) }",
         "write schließt seinen Deskriptor und entfernt den temporären Namen nach Rückkehr oder throw."),
        ("Sources/Fastra/SoakTest.swift", "defer { try? handle.close() }",
         "append schließt sein lokales Berichtshandle vor Rückkehr oder throw."),
        ("Sources/Fastra/SoakTest.swift", "defer { try? handle.close() }",
         "appendReport schließt sein lokales Berichtshandle vor Rückkehr oder throw."),
    ]
    // Nur echte Anweisungszeilen zählen, keine Kommentare über `defer`.
    let statements = sources.flatMap { source in
        source.source.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("defer") }
            .map { source.path + ": " + $0 }
    }
    let expected = allowed.map { $0.file + ": " + $0.statement }
    #expect(statements.sorted() == expected.sorted(), """
        Harness-defer weichen von den begründeten Ausnahmen ab. Tatsächlich: \(statements).
        Erlaubt: \(allowed). Bei finish/exit läuft defer nie; dort ausdrücklich aufräumen.
        """)

}

/// Die Abfrage baut dieselbe Registrierung wie der reale Caller auf; doppelte
/// Namen würden bereits dort fehlschlagen, ohne Testaktionen auszuführen.
@Test("Die echte Selbsttest-Registrierung ist vollständig und eindeutig")
func knownSelfTestNamesMatchDispatch() throws {
    let descriptors = try SelfTest.launchDescriptors()
    let names = descriptors.map(\.name)
    #expect(names.count == 172)
    #expect(Set(names).count == names.count)
}

/// Fremdes Kopieren oder nicht gelieferte zugesagte Zwischenablage-Typen
/// sind Umgebungsfehler; sie dürfen keinen Produkt-FAIL ergeben.
@Test("Zwischenablage-Ursachen werden richtig eingestuft")
func pasteboardFailuresAreClassifiedByCause() {
    func outcome(_ code: Int) -> SelfTestOutcome {
        SelfTest.selfTestPasteboardOutcome(for: NSError(
            domain: "FastraSelfTestPasteboard", code: code,
            userInfo: [NSLocalizedDescriptionKey: "Testfall"]
        ))
    }
    // Fremdeingriff und nicht lieferbarer Typ: Umgebung.
    #expect(outcome(1) == .environment)
    #expect(outcome(4) == .environment)
    #expect(outcome(5) == .environment)
    // Alles andere aus dieser Domain bleibt ein echter Fehler.
    #expect(outcome(2) == .fail)
    #expect(outcome(3) == .fail)
    // Und ein fremder Fehler wird nicht stillschweigend heruntergestuft.
    #expect(SelfTest.selfTestPasteboardOutcome(for: NSError(
        domain: "NSCocoaErrorDomain", code: 1, userInfo: nil)) == .fail)
}
