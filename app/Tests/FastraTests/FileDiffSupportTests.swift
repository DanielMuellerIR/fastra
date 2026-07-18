// FileDiffSupportTests.swift
//
// Tests der Begleitlogik des Datei-Vergleichs (Etappe 1 Wunschpaket
// 2026-07c): Differenzen-Beschreibungen, Optionen-Zusammenfassung,
// Dialog-Feldprüfung, Tab-Wiederverwendung und der Ladepfad mit seinen
// ehrlichen Grenzen (binär/zu groß/nicht lesbar).

import Testing
import Foundation
@testable import Fastra

// MARK: - Beschreibungen der Differenzen-Liste

// Die Erwartungen entstehen über dieselben L10n-Aufrufe wie der Code —
// geprüft wird die WAHL des richtigen Formats (Singular/Plural/asymmetrisch)
// und der Bereichs-Text, nicht die Übersetzung. Der Testprozess kann je nach
// System-Sprache Deutsch ODER Englisch auflösen; beides muss bestehen.

@Test("Blockbeschreibung: einzelne geänderte Zeile")
func descriptionSingleChanged() {
    let block = FileDiff.Block(id: 0, firstRowID: 0, lastRowID: 0, kind: .changed,
                               beforeLines: 12...12, afterLines: 12...12)
    #expect(FileDiffView.blockDescription(block)
            == L10n.format("Zeile %@ geändert", "12"))
}

@Test("Blockbeschreibung: Bereich geändert")
func descriptionRangeChanged() {
    let block = FileDiff.Block(id: 0, firstRowID: 0, lastRowID: 2, kind: .changed,
                               beforeLines: 12...14, afterLines: 12...14)
    #expect(FileDiffView.blockDescription(block)
            == L10n.format("Zeilen %@ geändert", "12–14"))
}

@Test("Blockbeschreibung: ungleiche Bereiche nennen beide Seiten")
func descriptionAsymmetricChanged() {
    let block = FileDiff.Block(id: 0, firstRowID: 0, lastRowID: 2, kind: .changed,
                               beforeLines: 12...13, afterLines: 12...15)
    #expect(FileDiffView.blockDescription(block)
            == L10n.format("Zeilen %@ ↔ %@ geändert", "12–13", "12–15"))
}

@Test("Blockbeschreibung: nur links / nur rechts")
func descriptionOneSided() {
    let left = FileDiff.Block(id: 0, firstRowID: 0, lastRowID: 0, kind: .onlyLeft,
                              beforeLines: 30...30, afterLines: nil)
    #expect(FileDiffView.blockDescription(left)
            == L10n.format("Zeile %@ nur links", "30"))
    let right = FileDiff.Block(id: 1, firstRowID: 0, lastRowID: 1, kind: .onlyRight,
                               beforeLines: nil, afterLines: 7...8)
    #expect(FileDiffView.blockDescription(right)
            == L10n.format("Zeilen %@ nur rechts", "7–8"))
}

@Test("Optionen-Zusammenfassung nennt genau die aktiven Optionen")
func optionsSummary() {
    var options = FileDiffOptions()
    #expect(FileDiffView.optionsSummary(options).isEmpty)
    options.ignoreBlankLines = true
    options.ignoreCase = true
    #expect(FileDiffView.optionsSummary(options)
            == [L10n.string("Leerzeilen"),
                L10n.string("Groß-/Kleinschreibung")].joined(separator: ", "))
    // „Alle Leerraum-Unterschiede" deckt das Zeilenende mit ab — nur die
    // stärkere Option erscheint.
    options = FileDiffOptions()
    options.ignoreAllWhitespace = true
    options.ignoreTrailingWhitespace = true
    #expect(FileDiffView.optionsSummary(options)
            == L10n.string("alle Leerraum-Unterschiede"))
}

// MARK: - Dialog-Feldprüfung

@Test("Feldprüfung: fehlende Datei, Ordner und Binärdatei werden erkannt")
func fieldProblems() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-filediff-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let missing = dir.appendingPathComponent("gibts-nicht.txt")
    #expect(CompareDialogLogic.problem(forFileAt: missing) == .missing)

    #expect(CompareDialogLogic.problem(forFileAt: dir) == .directory)

    let binary = dir.appendingPathComponent("bild.bin")
    try Data([0x89, 0x50, 0x00, 0x47, 0x0D, 0x0A]).write(to: binary)
    #expect(CompareDialogLogic.problem(forFileAt: binary) == .binary)

    let text = dir.appendingPathComponent("text.txt")
    try Data("hallo\nwelt\n".utf8).write(to: text)
    #expect(CompareDialogLogic.problem(forFileAt: text) == nil)

    // UTF-16 mit BOM enthält Nullbytes, ist aber KEINE Binärdatei.
    let utf16 = dir.appendingPathComponent("utf16.txt")
    try "hallo".data(using: .utf16)!.write(to: utf16)
    #expect(CompareDialogLogic.problem(forFileAt: utf16) == nil)
}

// MARK: - Tab-Wiederverwendung (matches)

@Test("Request-Matching: gleiche Quellen + Optionen, unabhängig vom Text")
func requestMatching() {
    let url = URL(fileURLWithPath: "/tmp/a.txt")
    let a = FileDiffRequest(left: .file(url),
                            right: .text("v1", name: "a.txt (ungespeichert)",
                                         path: url.path),
                            options: FileDiffOptions())
    let b = FileDiffRequest(left: .file(url),
                            right: .text("v2 — weitergetippt",
                                         name: "a.txt (ungespeichert)",
                                         path: url.path),
                            options: FileDiffOptions())
    // Anderer Text, gleiche logische Quelle → derselbe Tab wird recycelt.
    #expect(a.matches(b))
    // Andere Optionen → eigener Vergleich.
    var options = FileDiffOptions()
    options.ignoreCase = true
    let c = FileDiffRequest(left: a.left, right: a.right, options: options)
    #expect(!a.matches(c))
    // Datei- vs. Text-Quelle gleichen Namens → verschieden.
    let d = FileDiffRequest(left: .file(url),
                            right: .file(url),
                            options: FileDiffOptions())
    #expect(!a.matches(d))
}

// MARK: - Ladepfad (computeFileDiffDocument)

@Test("Ladepfad: zwei Textdateien liefern ein Ergebnis")
func computeWithFiles() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-filediff-load-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.txt")
    let b = dir.appendingPathComponent("b.txt")
    try "eins\nzwei\ndrei".write(to: a, atomically: true, encoding: .utf8)
    try "eins\nzwo\ndrei".write(to: b, atomically: true, encoding: .utf8)

    let document = Workspace.computeFileDiffDocument(request: FileDiffRequest(
        left: .file(a), right: .file(b), options: FileDiffOptions()
    ))
    #expect(document.limitation == nil)
    #expect(document.result?.blocks.count == 1)
}

@Test("Ladepfad: fehlende Datei → unreadable mit richtiger Seite")
func computeMissingFile() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-filediff-miss-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.txt")
    try "inhalt".write(to: a, atomically: true, encoding: .utf8)

    let document = Workspace.computeFileDiffDocument(request: FileDiffRequest(
        left: .file(a),
        right: .file(dir.appendingPathComponent("fehlt.txt")),
        options: FileDiffOptions()
    ))
    #expect(document.result == nil)
    #expect(document.limitation == .unreadable(side: .right))
}

@Test("Ladepfad: Binärdatei → binary-Grenze statt Zeilendiff")
func computeBinaryFile() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-filediff-bin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.txt")
    let b = dir.appendingPathComponent("b.bin")
    try "text".write(to: a, atomically: true, encoding: .utf8)
    try Data([0x00, 0x01, 0x02, 0x03]).write(to: b)

    let document = Workspace.computeFileDiffDocument(request: FileDiffRequest(
        left: .file(a), right: .file(b), options: FileDiffOptions()
    ))
    #expect(document.limitation == .binary(side: .right))
}

@Test("Ladepfad: Text-Seite (Editor-Inhalt) braucht keine Datei")
func computeWithTextSide() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-filediff-text-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.txt")
    try "gespeichert".write(to: a, atomically: true, encoding: .utf8)

    let document = Workspace.computeFileDiffDocument(request: FileDiffRequest(
        left: .file(a),
        right: .text("ungespeichert", name: "a.txt (ungespeichert)", path: a.path),
        options: FileDiffOptions()
    ))
    #expect(document.result?.blocks.count == 1)
    #expect(document.result?.blocks.first?.kind == .changed)
}
