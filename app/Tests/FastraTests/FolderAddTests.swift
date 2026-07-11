// FolderAddTests.swift
//
// Deckt die reine Logik von `Workspace.prependingFolders` ab: neue Ordner
// landen oben + aktiviert, Duplikate werden nach oben verschoben statt
// vervielfacht, die Auswahl-Reihenfolge bleibt erhalten. Das NSOpenPanel
// in `addSearchFolders` ist dünner Glue und hier nicht getestet.

import Testing
import Foundation
@testable import Fastra

@Test("Neuer Ordner landet oben und aktiviert")
func prepend_addsOnTopEnabled() {
    let existing = [SearchFolderEntry(path: "~/A", enabled: false)]
    let result = Workspace.prependingFolders(["/tmp/neu"], to: existing)
    #expect(result.count == 2)
    #expect(result[0].path == "/tmp/neu")
    #expect(result[0].enabled == true)
    #expect(result[1].path == "~/A")
}

@Test("Auswahl-Reihenfolge bleibt erhalten (erster oben)")
func prepend_keepsSelectionOrder() {
    let result = Workspace.prependingFolders(["/tmp/a", "/tmp/b", "/tmp/c"], to: [])
    #expect(result.map(\.path) == ["/tmp/a", "/tmp/b", "/tmp/c"])
    #expect(result.allSatisfy { $0.enabled })
}

@Test("Vorhandener Pfad wird nach oben verschoben, nicht dupliziert")
func prepend_dedupsExisting() {
    let existing = [
        SearchFolderEntry(path: "/tmp/x", enabled: false),
        SearchFolderEntry(path: "/tmp/y", enabled: true),
    ]
    let result = Workspace.prependingFolders(["/tmp/x"], to: existing)
    #expect(result.count == 2)                 // kein Duplikat
    #expect(result[0].path == "/tmp/x")
    #expect(result[0].enabled == true)          // re-aktiviert
    #expect(result[1].path == "/tmp/y")
}

@Test("Tilde- und absoluter Pfad auf dasselbe Ziel zählen als Duplikat")
func prepend_dedupsAcrossTildeExpansion() {
    let home = NSHomeDirectory()
    let existing = [SearchFolderEntry(path: "~/Documents", enabled: false)]
    let result = Workspace.prependingFolders(["\(home)/Documents"], to: existing)
    #expect(result.count == 1)
    #expect(result[0].enabled == true)
}

@Test("Leere Auswahl lässt die Liste unverändert")
func prepend_emptyKeepsList() {
    let existing = [SearchFolderEntry(path: "~/A", enabled: true)]
    let result = Workspace.prependingFolders([], to: existing)
    #expect(result.map(\.path) == existing.map(\.path))
}
