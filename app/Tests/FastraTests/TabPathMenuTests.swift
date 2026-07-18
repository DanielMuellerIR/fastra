// TabPathMenuTests.swift
//
// Tests für die Pfadkette des Tab-Pfadmenüs (Etappe 1 Wunschpaket 2026-07b):
// Datei zuoberst, dann jeder Elternordner aufwärts bis zur Wurzel „/“.

import Foundation
import Testing
@testable import Fastra

@Test("pathChain: Datei → alle Elternordner bis zur Wurzel, in Reihenfolge")
func pathChain_fullHierarchy() {
    let chain = TabPathMenuModel.pathChain(
        for: URL(fileURLWithPath: "/Users/test/git/projekt/liesmich.md")
    ).map(\.path)
    #expect(chain == [
        "/Users/test/git/projekt/liesmich.md",
        "/Users/test/git/projekt",
        "/Users/test/git",
        "/Users/test",
        "/Users",
        "/",
    ])
}

@Test("pathChain: Eintrag direkt unter der Wurzel → zwei Einträge")
func pathChain_rootFile() {
    let chain = TabPathMenuModel.pathChain(for: URL(fileURLWithPath: "/wurzelkind"))
        .map(\.path)
    #expect(chain == ["/wurzelkind", "/"])
}

@Test("pathChain: relative Pfadanteile werden vor dem Aufbau standardisiert")
func pathChain_standardizesDotSegments() {
    let chain = TabPathMenuModel.pathChain(
        for: URL(fileURLWithPath: "/Users/test/a/../b/datei.txt")
    ).map(\.path)
    #expect(chain.first == "/Users/test/b/datei.txt")
    #expect(chain.last == "/")
    #expect(!chain.contains { $0.contains("..") })
}
