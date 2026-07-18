// SiblingFolderListingTests.swift
//
// Tests für das Geschwisterordner-Menü am Seitenleisten-Kopf (Etappe 1
// Wunschpaket 2026-07b): nur Ordner, versteckte ausgeblendet, alphabetisch,
// aktueller Ordner bleibt in der Liste (fürs Häkchen im Menü).

import Foundation
import Testing
@testable import Fastra

/// Legt einen temporären Ordner an und räumt ihn nach dem Test wieder ab.
private func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-siblings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

@Test("siblings: nur Ordner — Dateien und versteckte Einträge fallen heraus")
func siblings_filtersFilesAndHidden() throws {
    try withTempDir { parent in
        let fm = FileManager.default
        for name in ["beta", "alpha"] {
            try fm.createDirectory(at: parent.appendingPathComponent(name),
                                   withIntermediateDirectories: true)
        }
        // Versteckter Ordner und eine normale Datei dürfen NICHT erscheinen.
        try fm.createDirectory(at: parent.appendingPathComponent(".versteckt"),
                               withIntermediateDirectories: true)
        try "x".write(to: parent.appendingPathComponent("datei.txt"),
                      atomically: true, encoding: .utf8)

        let current = parent.appendingPathComponent("alpha")
        let names = try SiblingFolderListing.siblings(of: current)
            .map(\.lastPathComponent)
        #expect(names == ["alpha", "beta"])
    }
}

@Test("siblings: alphabetische Finder-Ordnung (Groß/Klein egal, Zahlen numerisch)")
func siblings_sortsLikeFinder() throws {
    try withTempDir { parent in
        let fm = FileManager.default
        for name in ["Zebra", "anton", "Projekt10", "Projekt2"] {
            try fm.createDirectory(at: parent.appendingPathComponent(name),
                                   withIntermediateDirectories: true)
        }
        let current = parent.appendingPathComponent("anton")
        let names = try SiblingFolderListing.siblings(of: current)
            .map(\.lastPathComponent)
        // `localizedStandardCompare`: case-insensitiv und numerisch —
        // „Projekt2“ steht vor „Projekt10“.
        #expect(names == ["anton", "Projekt2", "Projekt10", "Zebra"])
    }
}

@Test("siblings: der aktuelle Ordner selbst bleibt in der Liste")
func siblings_includesCurrentFolder() throws {
    try withTempDir { parent in
        let current = parent.appendingPathComponent("einzig")
        try FileManager.default.createDirectory(at: current,
                                                withIntermediateDirectories: true)
        let names = try SiblingFolderListing.siblings(of: current)
            .map(\.lastPathComponent)
        #expect(names == ["einzig"])
    }
}

@Test("siblings: nicht lesbarer Elternordner → Fehler statt leerer Liste")
func siblings_throwsForUnreadableParent() {
    let missing = URL(fileURLWithPath: "/definitiv/nicht/da/\(UUID().uuidString)/kind")
    #expect(throws: (any Error).self) {
        _ = try SiblingFolderListing.siblings(of: missing)
    }
}
