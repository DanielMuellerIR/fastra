// FinderOpenRouterTests.swift
//
// Reine Routing-Auswahl für aus dem Finder/Dock geöffnete Dateien
// (Nutzerwunsch 2026-07-20 „alle Fenster durchsuchen"): Eine Datei landet im
// Fenster, das ihr Projekt/Repo zeigt oder sie bereits offen hat; sonst neu.

import Foundation
import Testing
@testable import Fastra

private func window(project: String?, files: [String] = []) -> OpenWindowSnapshot {
    OpenWindowSnapshot(
        projectURL: project.map { URL(fileURLWithPath: $0) },
        openFileURLs: files.map { URL(fileURLWithPath: $0) }
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
