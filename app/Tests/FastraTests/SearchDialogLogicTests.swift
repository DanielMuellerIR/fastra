// SearchDialogLogicTests.swift
//
// Regressionstests für pure Entscheidungslogik des Suchdialogs. Visuelle
// Geometrie (z. B. ob ein Toggle abgeschnitten wird) bleibt laut QA-Strategie
// ein echter GUI-Test; die Zuordnung Treffer → Dateiname lässt sich dagegen
// vollständig und schnell ohne Fenster absichern.

import Foundation
import Testing
@testable import Fastra

private final class JumpNotificationCapture: @unchecked Sendable {
    var notification: Notification?
}

/// Ergebnis eines verzögert geposteten Sprungs, aus der Main-Queue-Closure
/// heraus beschreibbar (Muster wie `JumpNotificationCapture`).
private final class MatchJumpPostCapture: @unchecked Sendable {
    var posted: Bool?
}

/// Erzeugt einen echten Suchtreffer für die Navigationsziel-Tests. Dadurch
/// hängen die Tests nicht von einem handgebauten Match mit erfundenen Ranges
/// ab, sondern verwenden denselben Datentyp wie der produktive SearchRunner.
private func dialogTestMatch() -> BufferSearch.Match {
    let result = BufferSearch.find(
        in: "TREFFER",
        options: SearchOptions(find: "TREFFER", replace: "", isRegex: false)
    )
    return result.matches[0]
}

@Test("Detailkopf im Geöffnet-Scope nennt den Ziel-Tab statt des aktiven Tabs")
func detailLabelUsesOpenScopeTargetTab() {
    let targetID = UUID()
    let targetTab = EditorTab(id: targetID, title: "Ziel.txt", path: "—")
    let activeTab = EditorTab(title: "Gerade-aktiv.txt", path: "—")
    let match = dialogTestMatch()
    let target = Workspace.NavMatch(id: match.id, url: nil,
                                    tabID: targetID, match: match)

    #expect(FloatingSearchDialog.detailFileLabel(
        for: target,
        tabs: [activeTab, targetTab],
        fallback: activeTab.title
    ) == "Ziel.txt")
}

@Test("Detailkopf im Ordner-Scope nennt die Datei des Treffers")
func detailLabelUsesFolderTargetURL() {
    let match = dialogTestMatch()
    let url = URL(fileURLWithPath: "/tmp/Unterordner/fundstelle.txt")
    let target = Workspace.NavMatch(id: match.id, url: url, match: match)

    #expect(FloatingSearchDialog.detailFileLabel(
        for: target,
        tabs: [],
        fallback: "Aktiver Buffer"
    ) == "fundstelle.txt")
}

@Test("Detailkopf im Datei-Scope verwendet weiterhin den aktiven Tab")
func detailLabelFallsBackForBufferMatch() {
    let match = dialogTestMatch()
    let target = Workspace.NavMatch(id: match.id, url: nil, match: match)

    #expect(FloatingSearchDialog.detailFileLabel(
        for: target,
        tabs: [],
        fallback: "Aktiv.txt"
    ) == "Aktiv.txt")
}

@Test("Treffer-Zeilennummer ist eine rohe Zahl ohne missverständliches Z-Präfix")
func hitLineLabelHasNoPrefixOrThousandsSeparator() {
    #expect(FloatingSearchDialog.hitLineLabel(1) == "1")
    #expect(FloatingSearchDialog.hitLineLabel(12_345) == "12345")
}

@Test("Offene Suche mit Suchbegriff behält ihren Scope bei beiden Suchkürzeln")
func presentingSearchPreservesPopulatedOpenScope() {
    for requested in [Workspace.SearchScope.file, .folder] {
        #expect(Workspace.searchScopeWhenPresenting(
            requested: requested,
            current: .folder,
            dialogOpen: true,
            findPattern: "Yellowjackets"
        ) == .folder)
    }
}

@Test("Leere oder geschlossene Suche übernimmt den Scope des Kürzels")
func presentingSearchUsesShortcutScopeWhenEmptyOrClosed() {
    #expect(Workspace.searchScopeWhenPresenting(
        requested: .file,
        current: .folder,
        dialogOpen: true,
        findPattern: ""
    ) == .file)
    #expect(Workspace.searchScopeWhenPresenting(
        requested: .folder,
        current: .file,
        dialogOpen: false,
        findPattern: "vorhanden"
    ) == .folder)
}

@Test("Der Menüpunkt „In Ordnern suchen…“ erzwingt den Ordner-Bereich")
@MainActor
func menuEntryForcesFolderScope() {
    let suiteName = "fastra-test-presentsearch-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let ws = Workspace(defaults: defaults)
    ws.scope = .file
    ws.findPattern = "Yellowjackets"
    ws.showSearchDialog = true

    // Kurzbefehl ⇧⌘F: befüllte Maske bleibt in ihrem Bereich.
    ws.presentSearch(requestedScope: .folder)
    #expect(ws.scope == .file)

    // Menüpunkt: Der sichtbare Text verspricht die Ordnersuche und muss sie
    // deshalb auch herstellen (Review 2026-08-06).
    ws.presentSearch(requestedScope: .folder, forceScope: true)
    #expect(ws.scope == .folder)
    #expect(ws.showSearchDialog)
}

@Test("Ordner-Apply-Fortschritt ist nur während des laufenden Apply sichtbar")
func folderApplyProgressVisibilityFollowsLifecycle() {
    #expect(FloatingSearchDialog.visibleFolderApplyProgress(
        isApplying: true, text: "Ordner-Apply: a.txt (1/2)") ==
        "Ordner-Apply: a.txt (1/2)")
    #expect(FloatingSearchDialog.visibleFolderApplyProgress(
        isApplying: false, text: "verspäteter Fortschritt") == nil)
}

@MainActor
@Test("Treffer-Sprung ist ausschließlich an sein Dokumentfenster adressiert")
func matchJumpTargetsOnlyItsWorkspace() {
    let first = Workspace(defaults: UserDefaults(
        suiteName: "search-jump-first-\(UUID().uuidString)"
    )!)
    let second = Workspace(defaults: UserDefaults(
        suiteName: "search-jump-second-\(UUID().uuidString)"
    )!)
    let match = dialogTestMatch()
    let capture = JumpNotificationCapture()
    let observer = NotificationCenter.default.addObserver(
        forName: .fastraJumpToRange,
        object: nil,
        queue: .main
    ) { note in
        capture.notification = note
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    NotificationCenter.default.postMatchJump(match, for: second)

    guard let received = capture.notification else {
        #expect(capture.notification != nil)
        return
    }
    #expect(received.object as? Workspace === second)
    #expect(EditorView.jumpNotification(received, targets: second))
    #expect(!EditorView.jumpNotification(received, targets: first))
}

@MainActor
@Test("Treffer-Sprung wählt und scrollt auch in Git-Vorversionen")
func matchJumpUpdatesReadOnlySnapshotView() {
    let suite = "fastra-search-readonly-jump-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = Workspace(defaults: defaults)
    let content = "vor TREFFER nach"
    let match = BufferSearch.find(
        in: content,
        options: SearchOptions(find: "TREFFER", replace: "", isRegex: false)
    ).matches[0]
    let textView = ReadOnlySnapshotTextView()
    textView.string = content
    let coordinator = ReadOnlySourceView.Coordinator(workspace: workspace)
    coordinator.attach(textView)

    NotificationCenter.default.postMatchJump(match, for: workspace)

    #expect(textView.selectedRange() == match.range)
}

@MainActor
@Test("Verzögerter Treffer-Sprung prüft Dokument-ID und kanonische Datei-URL")
func delayedMatchJumpUsesDocumentIdentity() throws {
    let suite = "fastra-search-target-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = Workspace(defaults: defaults)
    let documentID = workspace.activeDocumentID!
    let tabID = workspace.activeTabID!
    let fileName = "fastra-target-\(UUID().uuidString).txt"
    let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(fileName)
    try Data().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    workspace.tabs[0].url = url

    #expect(MatchJumpTarget.document(documentID).isActive(in: workspace))
    #expect(!MatchJumpTarget.document(tabID).isActive(in: workspace))
    #expect(MatchJumpTarget.url(URL(
        fileURLWithPath: "/private/tmp/\(fileName)"
    )).isActive(in: workspace))
    #expect(!MatchJumpTarget.url(url.appendingPathExtension("fremd"))
        .isActive(in: workspace))
}

@MainActor
@Test("Unterdrückter Treffer-Sprung setzt weder Auftrag noch sichtbaren Index fort")
func suppressedMatchJumpKeepsNavigationState() {
    let suite = "fastra-search-suppressed-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = Workspace(defaults: defaults)
    let posted = NotificationCenter.default.postMatchJump(
        dialogTestMatch(), for: workspace,
        requiring: .document(UUID())
    )

    #expect(!posted)
    #expect(workspace.pendingEditorJump == nil)
    #expect(MatchJumpCommit.index(previous: 2, current: 2,
                                  next: 3, posted: posted) == nil)
    #expect(MatchJumpCommit.index(previous: 2, current: 2,
                                  next: 3, posted: true) == 3)
    #expect(MatchJumpCommit.index(previous: 2, current: 4,
                                  next: 3, posted: true) == nil)
}

@MainActor
@Test("Ein neuer Sprungauftrag entwertet die Completion des älteren")
func newerMatchJumpInvalidatesOlderRequest() {
    let suite = "fastra-search-generation-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = Workspace(defaults: defaults)
    let documentID = workspace.activeDocumentID!

    // Zwei Treffer DERSELBEN Datei: Der Dokument-Guard ist für beide wahr,
    // nur die Auftragsnummer trennt sie.
    let older = workspace.beginMatchJump()
    let newer = workspace.beginMatchJump()
    #expect(!workspace.isCurrentMatchJump(older))
    #expect(workspace.isCurrentMatchJump(newer))

    // Zwei unterscheidbare Treffer derselben Zeile.
    let content = "eins TREFFER zwei TREFFER"
    let found = BufferSearch.find(
        in: content,
        options: SearchOptions(find: "TREFFER", replace: "", isRegex: false)
    ).matches
    let newerPosted = NotificationCenter.default.postMatchJump(
        found[1], for: workspace,
        requiring: .document(documentID), generation: newer
    )
    #expect(newerPosted)
    #expect(workspace.pendingEditorJump?.range == found[1].range)

    // Die verspätete Completion des ersten Auftrags darf den bereits
    // geposteten neueren Sprung nicht mehr überschreiben.
    let olderPosted = NotificationCenter.default.postMatchJump(
        found[0], for: workspace,
        requiring: .document(documentID), generation: older
    )
    #expect(!olderPosted)
    #expect(workspace.pendingEditorJump?.range == found[1].range)
}

// Befund Review 2026-08-22: `searchInputsDidChange` verwarf die
// Ordner-Trefferbasis, ließ die Sprunggeneration aber stehen. Ablauf: Klick
// auf einen Treffer einer noch ladenden Funddatei → Suchmuster wechselt vor
// der Lade-Completion → die Completion passierte Generation und URL-Guard,
// postete den Treffer der ALTEN Liste und übernahm dessen Index in die neue,
// inzwischen leere Trefferbasis.
@MainActor
@Test("Ein Suchmusterwechsel entwertet den Sprung einer noch ladenden Funddatei")
func patternChangeInvalidatesPendingFolderMatchJump() async throws {
    let suite = "fastra-search-stale-jump-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = Workspace(defaults: defaults)

    // Ordnersuche mit sichtbarer Maske: Nur dann reagiert der SearchRunner
    // synchron auf ein neues Muster (Trigger-Filter in `SearchRunner.init`).
    workspace.scope = .folder
    workspace.showSearchDialog = true
    workspace.findPattern = "TREFFER"

    // Die Funddatei liegt wirklich auf der Platte: `loadFile` lädt sie im
    // Hintergrund und meldet sich erst später auf dem Main-Thread zurück —
    // genau dieses Fenster nutzt der Ablauf.
    let content = "eins TREFFER zwei TREFFER"
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-stale-jump-\(UUID().uuidString).txt")
    try content.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let found = BufferSearch.find(
        in: content,
        options: SearchOptions(find: "TREFFER", replace: "", isRegex: false)
    ).matches

    // Wie `FloatingSearchDialog.handleMatchTap` im Ordner-Scope: Nummer beim
    // Klick ziehen, Datei laden, Sprung und Index erst in der Completion.
    let previousIndex = workspace.activeMatchIndex
    let nextIndex = 1
    let jumpGeneration = workspace.beginMatchJump()
    let capture = MatchJumpPostCapture()
    workspace.loadFile(at: url) { ok in
        #expect(ok, "Die Funddatei muss sich laden lassen")
        DispatchQueue.main.async {
            let didPost = NotificationCenter.default.postMatchJump(
                found[1], for: workspace, requiring: .url(url),
                generation: jumpGeneration
            )
            if let index = MatchJumpCommit.index(
                previous: previousIndex, current: workspace.activeMatchIndex,
                next: nextIndex, posted: didPost
            ) {
                workspace.activeMatchIndex = index
            }
            capture.posted = didPost
        }
    }

    // Noch VOR der Lade-Completion tippt der Nutzer ein neues Muster. Die
    // Trefferbasis ist damit weg — und mit ihr der offene Sprungauftrag.
    workspace.findPattern = "ANDERES"
    #expect(workspace.folderResults.isEmpty)
    #expect(!workspace.isCurrentMatchJump(jumpGeneration),
            "Der Musterwechsel muss den Klick-Auftrag entwerten")

    let completed = await waitUntil { capture.posted != nil }
    #expect(completed, "Die Lade-Completion muss eintreffen")
    #expect(capture.posted == false,
            "Kein Sprung zu einem Treffer des alten Musters")
    #expect(workspace.pendingEditorJump == nil)
    #expect(workspace.activeMatchIndex == 0,
            "Der alte Index darf nicht in die neue Trefferbasis wandern")
}

// Gegenprobe: Im Geöffnet-Scope ist der Tabwechsel Teil der Navigation. Er
// ändert die Trefferbasis des Geöffnet-Scope nicht und darf deshalb weder
// einen neuen Suchlauf auslösen noch den gerade gezogenen Sprungauftrag
// entwerten — sonst käme kein Sprung in einen anderen Tab mehr an.
@MainActor
@Test("Ein Tabwechsel der Navigation entwertet den eigenen Sprungauftrag nicht")
func navigationTabSwitchKeepsOwnMatchJump() {
    let suite = "fastra-search-tabswitch-jump-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = Workspace(defaults: defaults)
    workspace.tabs = [
        EditorTab(title: "a.txt", path: "—", content: "eins"),
        EditorTab(title: "b.txt", path: "—", content: "TREFFER"),
    ]
    workspace.activeTabID = workspace.tabs[0].id
    workspace.scope = .open
    workspace.showSearchDialog = true
    workspace.activeMatchIndex = 1

    let jumpGeneration = workspace.beginMatchJump()
    workspace.selectTab(id: workspace.tabs[1].id)
    #expect(workspace.isCurrentMatchJump(jumpGeneration))
    #expect(workspace.activeMatchIndex == 1,
            "Der Tabwechsel darf den noch nicht bestätigten flachen Trefferindex nicht löschen")
    #expect(MatchJumpCommit.index(
        previous: 1, current: workspace.activeMatchIndex,
        next: 2, posted: true
    ) == 2, "Der erfolgreiche Sprung muss seinen gewählten Index übernehmen können")

    // Ein neues Muster entwertet dagegen auch hier.
    workspace.findPattern = "TREFFER"
    #expect(!workspace.isCurrentMatchJump(jumpGeneration))
}

@Test("Dateigebundene Ansicht wechselt Identität bei Dokument, Pfad oder Plattenstand")
func fileViewIdentityIncludesBothInputs() {
    let firstID = UUID()
    let secondID = UUID()
    let firstURL = URL(fileURLWithPath: "/tmp/eins.txt")
    let secondURL = URL(fileURLWithPath: "/tmp/zwei.txt")
    let firstSnapshot = FileSnapshot(data: Data("eins".utf8), identity: nil)
    let secondSnapshot = FileSnapshot(data: Data("zwei".utf8), identity: nil)
    let original = EditorView.fileViewIdentity(
        tabID: firstID, url: firstURL, diskSnapshot: firstSnapshot
    )

    #expect(original == EditorView.fileViewIdentity(
        tabID: firstID, url: firstURL, diskSnapshot: firstSnapshot
    ))
    #expect(original != EditorView.fileViewIdentity(tabID: secondID, url: firstURL))
    #expect(original != EditorView.fileViewIdentity(tabID: firstID, url: secondURL))
    #expect(original != EditorView.fileViewIdentity(
        tabID: firstID, url: firstURL, diskSnapshot: secondSnapshot
    ))
}
