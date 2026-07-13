// DropHandlingTests.swift
//
// Deckt die reine Drop-Filter-Logik ab (`DropHandling.loadableFiles`):
// reguläre Dateien rein, Ordner und nicht-existierende Pfade raus,
// Duplikate entfernt, Reihenfolge erhalten. Das SwiftUI-`onDrop` und
// `loadFile` selbst sind dünner Glue und hier bewusst nicht getestet.

import Testing
import Foundation
@testable import Fastra

/// Legt eine temporäre Sandbox mit echten Dateien/Ordnern an und räumt
/// am Ende wieder auf. Gibt den Wurzel-Ordner zurück.
private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("fastra-drop-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try body(root)
}

@Test("Reguläre Dateien werden akzeptiert")
func loadable_acceptsRegularFiles() throws {
    try withTempDir { root in
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.md")
        try "hallo".write(to: a, atomically: true, encoding: .utf8)
        try "welt".write(to: b, atomically: true, encoding: .utf8)

        let result = DropHandling.loadableFiles(from: [a, b])
        #expect(result == [a, b])
    }
}

@Test("Verzeichnisse werden verworfen")
func loadable_dropsDirectories() throws {
    try withTempDir { root in
        let dir = root.appendingPathComponent("unterordner")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("datei.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let result = DropHandling.loadableFiles(from: [dir, file])
        #expect(result == [file])
    }
}

@Test("Nicht-existierende Pfade werden verworfen")
func loadable_dropsMissingPaths() throws {
    try withTempDir { root in
        let missing = root.appendingPathComponent("gibtsnicht.txt")
        let real = root.appendingPathComponent("real.txt")
        try "x".write(to: real, atomically: true, encoding: .utf8)

        let result = DropHandling.loadableFiles(from: [missing, real])
        #expect(result == [real])
    }
}

@Test("Duplikate werden entfernt, Reihenfolge bleibt")
func loadable_dedupsKeepsOrder() throws {
    try withTempDir { root in
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        try "1".write(to: a, atomically: true, encoding: .utf8)
        try "2".write(to: b, atomically: true, encoding: .utf8)

        let result = DropHandling.loadableFiles(from: [a, b, a])
        #expect(result == [a, b])
    }
}

@Test("Leere Eingabe ergibt leeres Ergebnis")
func loadable_emptyStaysEmpty() {
    #expect(DropHandling.loadableFiles(from: []).isEmpty)
}

@Test("Öffnen-Drop akzeptiert Dateien und Ordner")
func openable_acceptsFilesAndDirectories() throws {
    try withTempDir { root in
        let directory = root.appendingPathComponent("projekt")
        let file = root.appendingPathComponent("datei.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "x".write(to: file, atomically: true, encoding: .utf8)

        #expect(DropHandling.openableItems(from: [directory, file]) == [directory, file])
    }
}
