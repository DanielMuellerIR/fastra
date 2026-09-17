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
@testable import Fastra

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
    #expect(note.contains("actualItems.map { $0 == expectedItems }"), """
        Bei unerwartetem Zähler muss der aktuelle Inhalt entscheiden: Fremder
        Inhalt ist Umgebung, erwarteter Testinhalt mit falschem Zähler ein
        echter Fehler.
        """)
    #expect(note.contains("abandonSelfTestPasteboardBackup()"), """
        Nach einem belegten Fremdeingriff darf `finish` die alte Sicherung
        weder wiederherstellen noch den Umgebungsstatus zu FAIL hochstufen.
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

/// `finish` endet in `exit()`, und `exit()` wickelt den Swift-Stack nicht ab:
/// Ein `defer` in einer Funktion, die nur über `finish` endet, läuft NIE. Das
/// ist keine graue Theorie — genau so blieben Aufräumschritte für ein
/// Temp-Verzeichnis, eine persistente Umbruchwahl und ein gemerktes
/// Teilungsverhältnis liegen (Code-Review 2026-09-10, vier Fundstellen).
///
/// Der Test führt deshalb die beiden ERLAUBTEN `defer`-Blöcke namentlich und
/// weist jeden weiteren zurück. Ein neuer `defer` ist damit kein Versehen mehr,
/// sondern eine bewusste Entscheidung samt Begründung — dieselbe Mechanik wie
/// bei den Soft-Wrap-Werkseinstellungen, wo ein neues Format den Test bricht,
/// bis jemand die Klasse festlegt.
@Test("Jeder defer in SelfTest.swift ist ausdrücklich begründet")
func everyDeferInSelfTestIsAccountedFor() throws {
    let source = try String(contentsOf: selfTestSourceURL, encoding: .utf8)

    // Erlaubt, weil die umgebende Closure regulär zurückkehrt (kein `finish`):
    // die Aufräumzeile der Bildschirmaufnahme.
    let screenshotCleanup = "defer { try? FileManager.default.removeItem(at: url) }"
    // Erlaubt und im Code ausführlich begründet: Der Test meldet seine Suite
    // zusätzlich bei `TestDefaultsPurge` an, der `defer` ist nur der Weg für
    // den Fall, dass die Funktion doch einmal regulär zurückkehrt.
    let defaultsDomainCleanup = "defer { defaults.removePersistentDomain(forName: suiteName) }"
    let allowed = [screenshotCleanup, defaultsDomainCleanup]

    // Nur echte Anweisungen zählen, keine Kommentare über `defer`.
    let statements = source
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("defer") }

    #expect(statements.count == allowed.count, """
        SelfTest.swift enthält \(statements.count) defer-Anweisungen, erlaubt sind \
        \(allowed.count): \(statements)
        """)
    for allowedStatement in allowed {
        #expect(statements.contains(allowedStatement), """
            Der begründete defer „\(allowedStatement)" steht nicht mehr in \
            SelfTest.swift — entweder wurde er entfernt oder umformuliert; dann \
            gehört dieser Wächter mit angepasst.
            """)
    }
    for statement in statements where !allowed.contains(statement) {
        Issue.record("""
            Neuer defer in SelfTest.swift: „\(statement)". Endet die umgebende \
            Funktion über `finish`, läuft er nie — dann vor jedem `finish` \
            ausdrücklich aufräumen. Kehrt sie regulär zurück, gehört der Block \
            hier in die Liste der begründeten Ausnahmen.
            """)
    }
}

/// Der `default:`-Zweig der Selbsttest-Auswahl zählt die bekannten Namen in
/// einer Zeichenkette auf. Sie stand von Hand neben dem `switch` und lief
/// auseinander: Am 2026-09-10 fehlten 53 von 127 Namen, darunter `print`,
/// `soak`, `gototarget`, `diffsplit` und sämtliche Diagnose-Aufnahmen. Wer
/// sich vertippte, bekam eine Liste, die 42 Prozent der echten Tests
/// verschwieg — und schloss daraus, der gesuchte Test existiere nicht.
@Test("Die Liste der bekannten Selbsttests passt zu den Fällen der Auswahl")
func knownSelfTestNamesMatchDispatch() throws {
    let source = try String(contentsOf: selfTestSourceURL, encoding: .utf8)
    let lines = source.components(separatedBy: .newlines)

    guard let switchLine = lines.firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces) == "switch name {"
            && $0.contains("        switch name {")
    }) else {
        Issue.record("Die Auswahl `switch name {` steht nicht mehr in SelfTest.swift")
        return
    }
    guard let messageLine = lines.firstIndex(where: {
        $0.contains("unbekannter Selbsttest-Name")
    }), messageLine > switchLine else {
        Issue.record("Der default-Zweig mit der Namensliste fehlt")
        return
    }

    // `case "a":` und `case "a", "b":` — beides kommt vor.
    var dispatched: [String] = []
    for line in lines[switchLine..<messageLine] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("case \""), let colon = trimmed.lastIndex(of: ":") else {
            continue
        }
        let labels = trimmed[trimmed.startIndex..<colon]
        var name = ""
        var inside = false
        for character in labels {
            if character == "\"" {
                if inside, !name.isEmpty { dispatched.append(name) }
                name = ""
                inside.toggle()
            } else if inside {
                name.append(character)
            }
        }
    }
    #expect(dispatched.count > 100, "Die Fall-Erkennung greift nicht mehr")

    guard let listed = lines[messageLine...].prefix(3)
        .compactMap({ line -> String? in
            guard let open = line.range(of: "(bekannt: "),
                  let close = line.range(of: ")\"", range: open.upperBound..<line.endIndex)
            else { return nil }
            return String(line[open.upperBound..<close.lowerBound])
        }).first else {
        Issue.record("Die Namensliste (bekannt: ...) ist nicht mehr auffindbar")
        return
    }
    let known = Set(listed.components(separatedBy: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) })

    let missing = dispatched.filter { !known.contains($0) }
    #expect(missing.isEmpty, """
        Diese Selbsttests sind auswählbar, fehlen aber in der Fehlermeldung: \
        \(missing.joined(separator: ", "))
        """)
    let unknown = known.subtracting(dispatched)
    #expect(unknown.isEmpty, """
        Diese Namen stehen in der Fehlermeldung, aber es gibt keinen Fall dafür: \
        \(unknown.sorted().joined(separator: ", "))
        """)
}

/// Ein Zwischenablage-Fehler des Selbsttests muss die Ursache treffen: Hat der
/// Nutzer während des Laufs selbst kopiert oder liefert ein fremder Besitzer
/// einen zugesagten Typ nicht, ist das die UMGEBUNG. Als FAIL gemeldet
/// behauptete der Test einen Produktfehler, den es nicht gibt — beobachtet am
/// 2026-09-10 im Gesamtlauf an `public.utf16-external-plain-text`, isoliert
/// grün.
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
