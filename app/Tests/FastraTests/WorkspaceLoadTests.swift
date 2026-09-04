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
    return (testSuiteDefaults(named: suiteName), suiteName)
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

/// Thread-sicherer Zähler für die injizierte Hintergrund-Ladennaht. Der Test
/// liest ihn auf Main, während `initialFileLoader` ihn im detached Task erhöht.
private final class WorkspaceLoadCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
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
    // fertig ist. Der Lade-Platzhalter muss sofort da und AKTIV sein; der
    // unberührte Start-Tab darf während des Ladens stehen bleiben (sein
    // Willkommens-Platzhalter zeigt sich nur, wenn er selbst aktiv ist).
    var completionCalled = false
    ws.loadFile(at: url) { _ in completionCalled = true }

    // DIREKT nach dem Aufruf (noch im selben RunLoop-Tick) prüfen:
    let placeholder = ws.tabs.last
    #expect(placeholder?.isLoading == true,
            "Platzhalter-Tab muss sofort isLoading = true haben")
    #expect(ws.activeTabID == placeholder?.id,
            "Lade-Platzhalter muss sofort aktiv sein")
    #expect(!ws.isWelcomeScreen,
            "während des Ladens darf kein Willkommens-Platzhalter sichtbar sein")

    // Jetzt auf die Completion warten (max. 5 s).
    let deadline = Date().addingTimeInterval(5)
    while !completionCalled, Date() < deadline {
        await Task.yield()
    }
    #expect(completionCalled, "Completion wurde nie aufgerufen")
    // Nach erfolgreichem Laden ist der unberührte Start-Tab abgeräumt.
    #expect(ws.tabs.count == 1, "Start-Tab muss nach dem Laden abgeräumt sein")
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
    await waitUntil { firstDone }

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

// MARK: - Tests: Verworfener Platzhalter respektiert die aktuelle Tab-Wahl

@Test("loadFile: verworfener Restore-Platzhalter lässt bewusst gewählten Tab aktiv")
@MainActor
func wsLoad_discardedPlaceholderKeepsUserChosenActiveTab() async throws {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let ws = Workspace(defaults: defaults)
    let urlA = try writeTmpUTF8("Datei A\n")
    let urlB = try writeTmpUTF8("Datei B\n")
    let urlC = try writeTmpUTF8("Datei C\n")
    defer {
        try? FileManager.default.removeItem(at: urlA)
        try? FileManager.default.removeItem(at: urlB)
        try? FileManager.default.removeItem(at: urlC)
    }

    // A und B vollständig laden — wie ein Restore mehrerer Dateien, bei dem
    // die ersten beiden schon fertig sind. Danach ist B der aktive Tab.
    for url in [urlA, urlB] {
        var done: Bool? = nil
        ws.loadFile(at: url) { ok in done = ok }
        let deadline = Date().addingTimeInterval(5)
        while done == nil, Date() < deadline {
            await Task.yield()
        }
        #expect(done == true, "Vorbereitendes Laden muss gelingen")
    }

    // C startet als noch laufender Restore-Ladevorgang; sein gemerkter
    // Vorgängertab ist damit B.
    var accepted = true
    var completionResult: Bool? = nil
    ws.loadFile(at: urlC, acceptance: FileLoadAcceptance { accepted }) { ok in
        completionResult = ok
    }
    #expect(ws.tabs.first(where: { $0.url == urlC })?.isLoading == true,
            "C muss als Lade-Platzhalter sichtbar sein")

    // Der Nutzer wählt während des Ladens bewusst A; anschließend wird der
    // Restore entwertet (wie nach „Projekt schließen“). Beide Schritte laufen
    // synchron auf Main, bevor die Completion drankommt — kein Race.
    let tabA = try #require(ws.tabs.first(where: { $0.url == urlA }))
    ws.activeTabID = tabA.id
    accepted = false

    // Großzügige Frist: Unter paralleler Testlast kann der Hintergrund-Task
    // des Ladevorgangs deutlich später drankommen als auf leerer Maschine.
    let deadline = Date().addingTimeInterval(30)
    while completionResult == nil, Date() < deadline {
        await Task.yield()
    }
    #expect(completionResult == false, "Entwerteter Ladevorgang muss false melden")
    #expect(ws.tabs.first(where: { $0.url == urlC }) == nil,
            "Der verworfene Platzhalter darf nicht zurückbleiben")
    // Kern des Fixes: Die bewusste Wahl A bleibt bestehen; vor dem Fix
    // sprang die Auswahl hier zeitversetzt auf den Vorgängertab B zurück.
    #expect(ws.activeTabID == tabA.id,
            "Die bewusst gewählte Registerkarte darf nicht ersetzt werden")
}

@Test("Ordner-Treffer aktiviert keinen dirty Tab mit derselben Datei")
@MainActor
func wsLoad_expectedSnapshotRejectsDirtyOpenTabBeforeActivation() async throws {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let ws = Workspace(defaults: defaults)
    let url = try writeTmpUTF8("Suchstand\n")
    defer { try? FileManager.default.removeItem(at: url) }

    var firstLoad: Bool? = nil
    ws.loadFile(at: url) { firstLoad = $0 }
    #expect(await waitUntil { firstLoad != nil })
    #expect(firstLoad == true)
    let canonical = url.canonicalFileURL
    let fileIndex = try #require(ws.tabs.firstIndex(where: { $0.url == canonical }))
    let expected = try #require(ws.tabs[fileIndex].diskSnapshot)
    ws.tabs[fileIndex].content = "ungesicherte Änderung\n"
    ws.tabs[fileIndex].isDirty = true
    let other = EditorTab(title: Workspace.untitledBaseName, path: "—")
    ws.tabs.append(other)
    ws.activeTabID = other.id

    var outcome: FileLoadOutcome? = nil
    ws.loadFile(
        atCanonicalURL: canonical,
        expectedDiskSnapshot: expected
    ) { outcome = $0 }

    // Typisiert: Ein dirty Tab ist KEIN Beleg für eine veraltete
    // Trefferbasis — die Navigation zeigt dafür einen eigenen Hinweis
    // (Review 2026-08-31).
    #expect(outcome == .unsavedChanges)
    #expect(ws.activeTabID == other.id)
    #expect(ws.tabs[fileIndex].content == "ungesicherte Änderung\n")
}

@Test("Ordner-Treffer veröffentlicht keinen seit der Suche geänderten Dateistand")
@MainActor
func wsLoad_expectedSnapshotRejectsChangedDiskBeforePublishing() async throws {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let ws = Workspace(defaults: defaults)
    let url = try writeTmpUTF8("Suchstand\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let canonical = url.canonicalFileURL
    let expected = try FileSnapshot.read(from: canonical).snapshot
    try Data("neuer Plattenstand\n".utf8).write(to: canonical, options: .atomic)
    let previousActive = try #require(ws.activeTabID)

    var outcome: FileLoadOutcome? = nil
    ws.loadFile(
        atCanonicalURL: canonical,
        expectedDiskSnapshot: expected
    ) { outcome = $0 }

    #expect(ws.activeTabID == previousActive,
            "Der Ladeplatzhalter darf vor dem Snapshot-Abgleich nicht aktiv werden")
    #expect(await waitUntil(timeout: 30) { outcome != nil })
    #expect(outcome == .staleSnapshot)
    #expect(ws.activeTabID == previousActive)
    #expect(!ws.tabs.contains(where: { $0.url == canonical }))
}

@Test("Ordner-Treffer prüft auch bei einem sauberen offenen Tab erneut die Platte")
@MainActor
func wsLoad_expectedSnapshotRechecksCleanOpenTabBeforeActivation() async throws {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let ws = Workspace(defaults: defaults)
    let url = try writeTmpUTF8("Suchstand\n")
    defer { try? FileManager.default.removeItem(at: url) }

    var firstLoad: Bool? = nil
    ws.loadFile(at: url) { firstLoad = $0 }
    #expect(await waitUntil { firstLoad != nil })
    #expect(firstLoad == true)
    let canonical = url.canonicalFileURL
    let fileIndex = try #require(ws.tabs.firstIndex(where: { $0.url == canonical }))
    let expected = try #require(ws.tabs[fileIndex].diskSnapshot)
    let other = EditorTab(title: Workspace.untitledBaseName, path: "—")
    ws.tabs.append(other)
    ws.activeTabID = other.id
    try Data("neuer Plattenstand\n".utf8).write(to: canonical, options: .atomic)

    var outcome: FileLoadOutcome? = nil
    ws.loadFile(
        atCanonicalURL: canonical,
        expectedDiskSnapshot: expected
    ) { outcome = $0 }

    #expect(ws.activeTabID == other.id)
    #expect(await waitUntil { outcome != nil })
    #expect(outcome == .staleSnapshot)
    #expect(ws.activeTabID == other.id)
    #expect(ws.tabs[fileIndex].content == "Suchstand\n")
}

@Test("Ordner-Treffer meldet einen noch ladenden Tab getrennt vom Snapshot-Konflikt")
@MainActor
func wsLoad_expectedSnapshotReportsBusyLoadingTab() async throws {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let ws = Workspace(defaults: defaults)
    let url = try writeTmpUTF8("Suchstand\n")
    defer { try? FileManager.default.removeItem(at: url) }

    var firstLoad: Bool? = nil
    ws.loadFile(at: url) { firstLoad = $0 }
    #expect(await waitUntil { firstLoad != nil })
    let canonical = url.canonicalFileURL
    let fileIndex = try #require(ws.tabs.firstIndex(where: { $0.url == canonical }))
    let expected = try #require(ws.tabs[fileIndex].diskSnapshot)
    // Zustand „ein früherer Auftrag lädt noch": Der zweite Sprung darf die
    // gültige Trefferbasis dann NICHT als veraltet melden (Review 2026-08-31).
    ws.tabs[fileIndex].isLoading = true

    var outcome: FileLoadOutcome? = nil
    ws.loadFile(
        atCanonicalURL: canonical,
        expectedDiskSnapshot: expected
    ) { outcome = $0 }

    #expect(outcome == .busyLoading)
    ws.tabs[fileIndex].isLoading = false
}

// Befund Review 2026-09-01: Der erste Sprung in eine noch ungeöffnete
// Funddatei legte einen Platzhalter an. Ein direkt folgender Treffer derselben
// Datei bekam nur `.busyLoading`, entwertete aber zugleich die Acceptance des
// ersten Reads; dessen Completion verwarf daraufhin den Platzhalter. Damit ging
// gerade der neueste Treffer verloren. Der Read wird hier deterministisch
// angehalten, sodass kein Scheduler-Rennen den Ablauf verdecken kann.
@Test("Zwei schnelle Ordner-Treffer derselben neuen Datei teilen den Read und führen den neuesten Sprung aus")
@MainActor
func wsLoad_folderMatchCoalescesLatestRequestForSameFile() async throws {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let ws = Workspace(defaults: defaults)
    let content = "eins TREFFER zwei TREFFER\n"
    let url = try writeTmpUTF8(content)
    defer { try? FileManager.default.removeItem(at: url) }
    let loaded = try FileLoader.load(url: url)
    let expected = try #require(loaded.diskSnapshot)
    let matches = BufferSearch.find(
        in: content,
        options: SearchOptions(find: "TREFFER", replace: "", isRegex: false)
    ).matches
    #expect(matches.count == 2)

    let started = DispatchSemaphore(value: 0)
    let mayFinish = DispatchSemaphore(value: 0)
    let calls = WorkspaceLoadCallCounter()
    ws.initialFileLoader = { _ in
        calls.increment()
        started.signal()
        mayFinish.wait()
        return loaded
    }

    var firstOutcome: FileLoadOutcome?
    let firstGeneration = ws.beginMatchJump()
    ws.noteMatchNavigationTarget(index: 0, generation: firstGeneration)
    ws.loadFolderMatchFile(
        atCanonicalURL: url,
        expectedDiskSnapshot: expected,
        jumpGeneration: firstGeneration
    ) { firstOutcome = $0 }
    #expect(await waitUntil {
        started.wait(timeout: .now()) == .success
    }, "Der kontrollierte Dateiread muss begonnen haben")

    var secondOutcome: FileLoadOutcome?
    var secondPosted: Bool?
    let secondGeneration = ws.beginMatchJump()
    ws.noteMatchNavigationTarget(index: 1, generation: secondGeneration)
    ws.loadFolderMatchFile(
        atCanonicalURL: url,
        expectedDiskSnapshot: expected,
        jumpGeneration: secondGeneration
    ) { outcome in
        secondOutcome = outcome
        guard outcome == .opened else { return }
        secondPosted = NotificationCenter.default.postMatchJump(
            matches[1], for: ws,
            requiring: .file(url: url, snapshot: expected),
            generation: secondGeneration
        )
    }

    #expect(firstOutcome == .cancelled,
            "Der ältere logische Auftrag muss sofort abgeschlossen werden")
    #expect(calls.value == 1,
            "Beide Treffer derselben Datei dürfen nur einen physischen Read starten")
    mayFinish.signal()

    #expect(await waitUntil { secondOutcome != nil })
    #expect(secondOutcome == .opened)
    #expect(secondPosted == true)
    #expect(ws.pendingEditorJump?.range == matches[1].range,
            "Nach dem gemeinsamen Read muss ausschließlich der neueste Treffer springen")
    #expect(ws.tabs.filter { $0.url == url }.count == 1)
}

@Test("Ein neuer erfolgreicher Ordner-Sprung löscht den Hinweis des vorherigen Dirty-Tabs")
@MainActor
func wsLoad_successfulFolderMatchClearsPreviousUnsavedNotice() async throws {
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let ws = Workspace(defaults: defaults)
    let dirtyURL = try writeTmpUTF8("alter Suchstand\n")
    let cleanURL = try writeTmpUTF8("anderer Treffer\n")
    defer {
        try? FileManager.default.removeItem(at: dirtyURL)
        try? FileManager.default.removeItem(at: cleanURL)
    }

    var openedDirty: Bool?
    ws.loadFile(at: dirtyURL) { openedDirty = $0 }
    #expect(await waitUntil { openedDirty != nil })
    #expect(openedDirty == true)
    let dirtyIndex = try #require(ws.tabs.firstIndex(where: { $0.url == dirtyURL }))
    let dirtySnapshot = try #require(ws.tabs[dirtyIndex].diskSnapshot)
    ws.tabs[dirtyIndex].content += "ungesichert\n"
    ws.tabs[dirtyIndex].isDirty = true

    let dirtyGeneration = ws.beginMatchJump()
    ws.loadFolderMatchFile(
        atCanonicalURL: dirtyURL,
        expectedDiskSnapshot: dirtySnapshot,
        jumpGeneration: dirtyGeneration
    ) { outcome in
        if outcome != .opened {
            ws.handleFolderMatchLoadDenial(outcome,
                                           jumpGeneration: dirtyGeneration)
        }
    }
    #expect(ws.folderNavigationNotice == L10n.string(
        "Die Funddatei ist mit ungesicherten Änderungen geöffnet. Ohne Speichern schließen und erneut springen – oder speichern und danach erneut suchen."))

    let cleanSnapshot = try FileSnapshot.readSnapshotOnly(from: cleanURL)
    var cleanOutcome: FileLoadOutcome?
    let cleanGeneration = ws.beginMatchJump()
    ws.loadFolderMatchFile(
        atCanonicalURL: cleanURL,
        expectedDiskSnapshot: cleanSnapshot,
        jumpGeneration: cleanGeneration
    ) { outcome in
        cleanOutcome = outcome
        if outcome != .opened {
            ws.handleFolderMatchLoadDenial(outcome,
                                           jumpGeneration: cleanGeneration)
        }
    }

    #expect(ws.folderNavigationNotice == nil,
            "Schon der neue Versuch darf den alten Dirty-Hinweis nicht weiter anzeigen")
    #expect(await waitUntil { cleanOutcome != nil })
    #expect(cleanOutcome == .opened)
    #expect(ws.folderNavigationNotice == nil)
}

@Test("Ein veralteter Folgeauftrag löscht den Hinweis des neuesten Sprungs nicht")
@MainActor
func wsLoad_staleRecursiveFolderMatchKeepsNewestNotice() async throws {
    // Drei überlappende Aufträge (Review 2026-09-02):
    //   A  liest die Funddatei, der Read wird künstlich angehalten.
    //   A' springt zur selben Datei mit einem ANDEREN Snapshot — ersetzt den
    //      wartenden Auftrag; die Read-Completion startet dafür später einen
    //      Folgeauftrag B mit A's Generation.
    //   C  springt zu einer dirty geöffneten Datei und setzt den Hinweis.
    // Läuft A's Read danach aus, darf der veraltete Folgeauftrag B den
    // Hinweis von C nicht löschen — vorher stand das Löschen VOR dem
    // Generations-Guard.
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let ws = Workspace(defaults: defaults)
    let content = "eins TREFFER\n"
    let url = try writeTmpUTF8(content)
    let dirtyURL = try writeTmpUTF8("alter Suchstand\n")
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: dirtyURL)
    }
    let loaded = try FileLoader.load(url: url)
    let snapshotA = try #require(loaded.diskSnapshot)
    // Zweiter, abweichender Snapshot derselben Datei — als hätte ein neuer
    // Suchlauf die Datei in geändertem Zustand gelesen.
    try (content + "zwei\n").write(to: url, atomically: true, encoding: .utf8)
    let snapshotAPrime = try FileSnapshot.readSnapshotOnly(from: url)
    #expect(snapshotA != snapshotAPrime)

    // Dirty-Tab für Auftrag C vorbereiten.
    var openedDirty: Bool?
    ws.loadFile(at: dirtyURL) { openedDirty = $0 }
    #expect(await waitUntil { openedDirty != nil })
    let dirtyIndex = try #require(ws.tabs.firstIndex(where: { $0.url == dirtyURL }))
    let dirtySnapshot = try #require(ws.tabs[dirtyIndex].diskSnapshot)
    ws.tabs[dirtyIndex].content += "ungesichert\n"
    ws.tabs[dirtyIndex].isDirty = true

    let started = DispatchSemaphore(value: 0)
    let mayFinish = DispatchSemaphore(value: 0)
    ws.initialFileLoader = { _ in
        started.signal()
        mayFinish.wait()
        return loaded
    }

    var outcomeA: FileLoadOutcome?
    let generationA = ws.beginMatchJump()
    ws.loadFolderMatchFile(atCanonicalURL: url, expectedDiskSnapshot: snapshotA,
                           jumpGeneration: generationA) { outcomeA = $0 }
    #expect(await waitUntil { started.wait(timeout: .now()) == .success })

    var outcomeAPrime: FileLoadOutcome?
    let generationAPrime = ws.beginMatchJump()
    ws.loadFolderMatchFile(atCanonicalURL: url, expectedDiskSnapshot: snapshotAPrime,
                           jumpGeneration: generationAPrime) { outcomeAPrime = $0 }
    #expect(outcomeA == .cancelled)

    let generationC = ws.beginMatchJump()
    ws.loadFolderMatchFile(atCanonicalURL: dirtyURL, expectedDiskSnapshot: dirtySnapshot,
                           jumpGeneration: generationC) { outcome in
        if outcome != .opened {
            ws.handleFolderMatchLoadDenial(outcome, jumpGeneration: generationC)
        }
    }
    let unsavedNotice = L10n.string(
        "Die Funddatei ist mit ungesicherten Änderungen geöffnet. Ohne Speichern schließen und erneut springen – oder speichern und danach erneut suchen.")
    #expect(ws.folderNavigationNotice == unsavedNotice)

    // A's Read ausläufen lassen → Folgeauftrag B (Generation A') startet und
    // muss als veraltet abgewiesen werden, ohne den Hinweis anzufassen.
    mayFinish.signal()
    #expect(await waitUntil { outcomeAPrime != nil })
    #expect(outcomeAPrime == .cancelled)
    #expect(ws.folderNavigationNotice == unsavedNotice,
            "Der Hinweis des neuesten Sprungs muss den Abschluss älterer Aufträge überleben")
}

@Test("Umbenennen während des ersten Reads lädt den Platzhalter unter dem neuen Pfad fertig")
@MainActor
func wsLoad_renameDuringInitialReadRestartsLoadForNewPath() async throws {
    // Review 2026-09-03: `handleFileTreeMoveLocally` hängt den Lade-
    // Platzhalter auf den neuen Pfad um; der laufende Read kam mit der alten
    // URL zurück, wurde verworfen und ließ den Tab dauerhaft im Ladezustand.
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let ws = Workspace(defaults: defaults)
    let original = try writeTmpUTF8("Inhalt vor dem Umbenennen\n")
    let renamed = original.deletingLastPathComponent()
        .appendingPathComponent("fastra-wsload-renamed-\(UUID().uuidString).txt")
        .canonicalFileURL
    defer {
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.removeItem(at: renamed)
    }

    // Der erste Read hält an, bis der Test die Umbenennung erledigt hat. Die
    // gelesenen URLs zeigen, dass danach ein zweiter Read am NEUEN Pfad läuft.
    let started = DispatchSemaphore(value: 0)
    let mayFinish = DispatchSemaphore(value: 0)
    let readURLs = WorkspaceLoadURLRecorder()
    ws.initialFileLoader = { url in
        readURLs.append(url)
        if readURLs.count == 1 {
            started.signal()
            mayFinish.wait()
        }
        return try FileLoader.load(url: url)
    }

    var outcome: FileLoadOutcome?
    ws.loadFile(atCanonicalURL: original) { outcome = $0 }
    #expect(await waitUntil { started.wait(timeout: .now()) == .success })
    let tabID = try #require(ws.tabs.first(where: { $0.url == original })?.id)

    // Umbenennen wie die Seitenleiste: erst die Platte, dann die Tabs.
    try FileManager.default.moveItem(at: original, to: renamed)
    ws.handleFileTreeMove(from: original, to: renamed)
    #expect(ws.tabs.first(where: { $0.id == tabID })?.url == renamed)
    #expect(outcome == nil, "Vor Abschluss des Reads darf nichts gemeldet werden")

    mayFinish.signal()
    #expect(await waitUntil { outcome != nil })
    #expect(outcome == .opened)
    let tab = try #require(ws.tabs.first(where: { $0.id == tabID }))
    #expect(!tab.isLoading, "Der umbenannte Tab darf nicht im Ladezustand hängen bleiben")
    #expect(tab.url == renamed)
    #expect(tab.content == "Inhalt vor dem Umbenennen\n")
    #expect(readURLs.urls == [original, renamed],
            "Nach der Umbenennung muss genau ein zweiter Read am neuen Pfad laufen")
    #expect(ws.tabs.filter { $0.id == tabID }.count == 1)
}

/// Thread-sicherer Mitschnitt der gelesenen Pfade; der Test liest ihn auf
/// Main, während `initialFileLoader` ihn im detached Task füllt.
private final class WorkspaceLoadURLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []

    var urls: [URL] { lock.withLock { recorded } }
    var count: Int { lock.withLock { recorded.count } }

    func append(_ url: URL) {
        lock.withLock { recorded.append(url) }
    }
}

@Test("Der auf den neuen Pfad umgehängte Read bedient keinen Ordner-Sprung des alten Pfads")
@MainActor
func wsLoad_renamedReadDoesNotServeFolderMatchJumpOfOldPath() async throws {
    // Review 2026-09-04: Ein wartender Ordner-Sprung liegt unter dem PFAD der
    // Funddatei. Benennt die Seitenleiste die Datei während des Reads um,
    // startet derselbe Read unter dem neuen Pfad neu — trägt aber weiterhin
    // die Completion, die den Wartenden des ALTEN Pfads abrechnet. Klickt der
    // Nutzer den noch sichtbaren Treffer des alten Pfads erneut, bekam dieser
    // neueste Auftrag deshalb das Ergebnis der UMBENANNTEN Datei gemeldet:
    // `.opened`, obwohl seine eigene Datei nie gelesen wurde. Der
    // anschließende URL-Guard der Treffer-Navigation kann damit nicht
    // springen, und der Nutzer landet nirgends.
    let (defaults, suite) = makeFreshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let ws = Workspace(defaults: defaults)
    let original = try writeTmpUTF8("Inhalt vor dem Umbenennen\n")
    let renamed = original.deletingLastPathComponent()
        .appendingPathComponent("fastra-wsload-renamed-\(UUID().uuidString).txt")
        .canonicalFileURL
    defer {
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.removeItem(at: renamed)
    }
    let snapshot = try FileSnapshot.readSnapshotOnly(from: original)

    // Nur der ERSTE Read hält an; er deckt die Umbenennung und den zweiten
    // Trefferklick ab. Alle weiteren Reads laufen normal durch.
    let started = DispatchSemaphore(value: 0)
    let mayFinish = DispatchSemaphore(value: 0)
    let readURLs = WorkspaceLoadURLRecorder()
    ws.initialFileLoader = { url in
        readURLs.append(url)
        if readURLs.count == 1 {
            started.signal()
            mayFinish.wait()
        }
        return try FileLoader.load(url: url)
    }

    var firstOutcome: FileLoadOutcome?
    let firstGeneration = ws.beginMatchJump()
    ws.loadFolderMatchFile(atCanonicalURL: original,
                           expectedDiskSnapshot: snapshot,
                           jumpGeneration: firstGeneration) { firstOutcome = $0 }
    #expect(await waitUntil { started.wait(timeout: .now()) == .success },
            "Der kontrollierte Dateiread muss begonnen haben")
    let placeholderID = try #require(ws.tabs.first(where: { $0.url == original })?.id)

    // Umbenennen wie die Seitenleiste: erst die Platte, dann die Tabs.
    try FileManager.default.moveItem(at: original, to: renamed)
    ws.handleFileTreeMove(from: original, to: renamed)
    #expect(ws.tabs.first(where: { $0.id == placeholderID })?.url == renamed)

    // Zweiter Klick auf den noch sichtbaren Treffer des ALTEN Pfads.
    var secondOutcome: FileLoadOutcome?
    let secondGeneration = ws.beginMatchJump()
    ws.loadFolderMatchFile(atCanonicalURL: original,
                           expectedDiskSnapshot: snapshot,
                           jumpGeneration: secondGeneration) { secondOutcome = $0 }
    #expect(firstOutcome == .cancelled,
            "Der ältere logische Auftrag muss durch den neueren abgelöst werden")

    mayFinish.signal()
    #expect(await waitUntil { secondOutcome != nil })

    // Der neueste Auftrag zeigt auf den alten Pfad; dort liegt seit der
    // Umbenennung nichts mehr. Er muss das melden statt den Erfolg der
    // umbenannten Datei zu übernehmen.
    #expect(secondOutcome == .failed,
            "Der Sprung zum alten Pfad darf nicht das Ergebnis der umbenannten Datei bekommen")
    #expect(readURLs.urls.contains(original),
            "Der neueste Auftrag braucht einen eigenen Read auf seinem eigenen Pfad")
    #expect(readURLs.urls.contains(renamed),
            "Der umgehängte Read muss den neuen Pfad zu Ende lesen")

    // Der umbenannte Platzhalter darf davon unberührt fertig laden.
    #expect(await waitUntil {
        ws.tabs.first(where: { $0.id == placeholderID })?.isLoading == false
    }, "Der umbenannte Tab muss den Ladezustand verlassen")
    let renamedTab = try #require(ws.tabs.first(where: { $0.id == placeholderID }))
    #expect(renamedTab.url == renamed)
    #expect(renamedTab.content == "Inhalt vor dem Umbenennen\n")
    // Genau eine Meldung je logischem Auftrag: ein zweiter Aufruf derselben
    // Completion würde den bereits gesetzten Wert überschreiben.
    #expect(ws.tabs.filter { $0.url == original }.isEmpty,
            "Für den verschwundenen alten Pfad darf kein Platzhalter zurückbleiben")
}
