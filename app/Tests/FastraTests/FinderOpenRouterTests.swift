// FinderOpenRouterTests.swift
//
// Reine Routing-Auswahl für aus dem Finder/Dock geöffnete Dateien
// (Nutzerwunsch 2026-07-20 „alle Fenster durchsuchen"): Eine Datei landet im
// Fenster, das ihr Projekt/Repo zeigt oder sie bereits offen hat; sonst neu.

import Foundation
import Testing
@testable import Fastra

private func window(project: String?, files: [String] = [],
                    emptyWelcome: Bool = false) -> OpenWindowSnapshot {
    OpenWindowSnapshot(
        projectURL: project.map { URL(fileURLWithPath: $0) },
        openFileURLs: files.map { URL(fileURLWithPath: $0) },
        isEmptyWelcome: emptyWelcome
    )
}

@Test("Routing: Datei im Projektordner eines Fensters → genau dieses Fenster")
func router_matchesProjectFolder() {
    let windows = [window(project: "/tmp/repoA"), window(project: "/tmp/repoB")]
    let file = URL(fileURLWithPath: "/tmp/repoB/src/x.swift")
    #expect(FinderOpenRouter.targetIndex(for: file, in: windows) == 1)
}

@Test("Routing: kein passendes Fenster → nil (Aufrufer öffnet ein neues)")
func router_noMatchYieldsNil() {
    let windows = [window(project: "/tmp/repoA")]
    let file = URL(fileURLWithPath: "/tmp/woanders/y.txt")
    #expect(FinderOpenRouter.targetIndex(for: file, in: windows) == nil)
}

@Test("Routing: bereits offene Datei gewinnt (Dedup), auch ohne Projektordner")
func router_dedupWinsOverNewTab() {
    let windows = [
        window(project: "/tmp/repoA"),
        window(project: nil, files: ["/tmp/woanders/y.txt"])
    ]
    let file = URL(fileURLWithPath: "/tmp/woanders/y.txt")
    #expect(FinderOpenRouter.targetIndex(for: file, in: windows) == 1)
}

@Test("Routing: Präfix-Nachbar zählt nicht als im Projekt")
func router_prefixNeighborIsForeign() {
    // „/tmp/projekt-alt“ beginnt wie „/tmp/projekt“, liegt aber außerhalb.
    let windows = [window(project: "/tmp/projekt")]
    let file = URL(fileURLWithPath: "/tmp/projekt-alt/z.txt")
    #expect(FinderOpenRouter.targetIndex(for: file, in: windows) == nil)
}

@Test("Routing: bei mehreren Treffern gewinnt das vorderste Fenster")
func router_frontmostMatchWins() {
    let windows = [window(project: "/tmp/repo"), window(project: "/tmp/repo")]
    let file = URL(fileURLWithPath: "/tmp/repo/a.txt")
    #expect(FinderOpenRouter.targetIndex(for: file, in: windows) == 0)
}

@Test("Routing: Datei genau im Projektordner (nicht Unterordner) zählt als drin")
func router_fileDirectlyInProject() {
    let windows = [window(project: "/tmp/repo")]
    let file = URL(fileURLWithPath: "/tmp/repo/README.md")
    #expect(FinderOpenRouter.targetIndex(for: file, in: windows) == 0)
}

@Test("Routing: leeres Willkommensfenster nimmt die Datei auf statt neues Fenster")
func router_emptyWelcomeAbsorbsFile() {
    let windows = [window(project: nil, emptyWelcome: true)]
    let file = URL(fileURLWithPath: "/tmp/woanders/neu.txt")
    #expect(FinderOpenRouter.targetIndex(for: file, in: windows) == 0)
}

@Test("Routing: Projekt-Treffer gewinnt vor leerem Willkommensfenster")
func router_projectMatchBeatsEmptyWelcome() {
    // Willkommensfenster vorne (Index 0), passendes Projektfenster hinten (1).
    let windows = [
        window(project: nil, emptyWelcome: true),
        window(project: "/tmp/repo")
    ]
    let file = URL(fileURLWithPath: "/tmp/repo/x.swift")
    #expect(FinderOpenRouter.targetIndex(for: file, in: windows) == 1)
}

@Test("Routing: nicht-leeres Fenster ohne Projekt nimmt keine fremde Datei auf")
func router_nonEmptyWindowDoesNotAbsorb() {
    // Fenster ohne Projekt, aber mit ungesicherter Arbeit (isEmptyWelcome=false):
    // darf keine fremde Datei aufnehmen → neues Fenster (nil).
    let windows = [window(project: nil, emptyWelcome: false)]
    let file = URL(fileURLWithPath: "/tmp/woanders/neu.txt")
    #expect(FinderOpenRouter.targetIndex(for: file, in: windows) == nil)
}
