// EncodingLineEndingTabTests.swift
//
// Tests für K6 (Reopen-Encoding), K7 (Zeilenenden), K8 (Tab-Komfort),
// K9 (Swap). Reine Logik + Workspace-Verhalten.

import Foundation
import Testing
@testable import Fastra

// MARK: - K7: Zeilenenden-Konvertierung (pure)

@Test("converting: LF → CRLF")
func lineEnding_lfToCrlf() {
    #expect(LineEnding.crlf.converting("a\nb\nc") == "a\r\nb\r\nc")
}

@Test("converting: CRLF → LF")
func lineEnding_crlfToLf() {
    #expect(LineEnding.lf.converting("a\r\nb\r\nc") == "a\nb\nc")
}

@Test("converting: CR → LF (klassisches Mac / 4D-Log)")
func lineEnding_crToLf() {
    #expect(LineEnding.lf.converting("a\rb\rc") == "a\nb\nc")
}

@Test("converting: gemischte Umbrüche werden vereinheitlicht")
func lineEnding_mixedNormalized() {
    // CRLF, CR und LF gemischt → alle zu CR.
    #expect(LineEnding.cr.converting("a\r\nb\rc\nd") == "a\rb\rc\rd")
}

@Test("converting: Text ohne Umbruch bleibt unverändert")
func lineEnding_noBreakUnchanged() {
    #expect(LineEnding.crlf.converting("abc") == "abc")
}

// MARK: - K6: FileLoader mit forcedEncoding

@Test("FileLoader forcedEncoding: Latin-1-Datei wird korrekt dekodiert")
func fileLoader_forcedLatin1() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-enc-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    // „café" in Latin-1: é = 0xE9 (Einzelbyte).
    let data = "café".data(using: .isoLatin1)!
    try data.write(to: url)

    let loaded = try FileLoader.load(url: url, forcedEncoding: .isoLatin1)
    #expect(loaded.content == "café")
    #expect(loaded.encoding == .isoLatin1)
}

@Test("FileLoader forcedEncoding: falsches Encoding wirft unreadable (kein Lossy)")
func fileLoader_forcedWrongEncodingThrows() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-enc-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    // Latin-1-Bytes (0xE9 allein) sind KEIN gültiges UTF-8.
    try "café".data(using: .isoLatin1)!.write(to: url)

    #expect(throws: FileLoader.LoadError.self) {
        _ = try FileLoader.load(url: url, forcedEncoding: .utf8)
    }
}

// MARK: - Workspace-Verhalten (K7/K8/K9)

@MainActor
private func makeWS(content: String) -> Workspace {
    let suite = "fastra.tests.k69.\(UUID().uuidString)"
    let ws = Workspace(defaults: UserDefaults(suiteName: suite)!)
    ws.tabs = [EditorTab(title: "t", path: "-", content: content)]
    ws.activeTabID = ws.tabs[0].id
    return ws
}

@Test("K7: setActiveLineEnding setzt das Format und markiert den Tab als geändert")
@MainActor
func setActiveLineEnding_marksDirty() {
    let ws = makeWS(content: "a\nb")
    #expect(ws.tabs[0].lineEnding == .lf)
    #expect(ws.tabs[0].isDirty == false)
    ws.setActiveLineEnding(.crlf)
    #expect(ws.tabs[0].lineEnding == .crlf)
    #expect(ws.tabs[0].isDirty == true)
}

@Test("K7: Speichern schreibt die gewählten Zeilenenden auf die Platte")
@MainActor
func save_writesChosenLineEndings() throws {
    let ws = makeWS(content: "a\nb\nc")
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-save-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    ws.tabs[0].url = url
    ws.tabs[0].title = url.lastPathComponent

    ws.setActiveLineEnding(.crlf)
    ws.saveActiveTab()

    let written = String(data: try Data(contentsOf: url), encoding: .utf8)
    #expect(written == "a\r\nb\r\nc")
}

@Test("K8: closeOtherTabs behält nur den gewählten Tab und macht ihn aktiv")
@MainActor
func closeOtherTabs_keepsOnlyOne() {
    let ws = makeWS(content: "x")
    ws.tabs = [
        EditorTab(title: "a", path: "-"),
        EditorTab(title: "b", path: "-"),
        EditorTab(title: "c", path: "-"),
    ]
    let keep = ws.tabs[1].id
    ws.activeTabID = ws.tabs[0].id
    ws.closeOtherTabs(keeping: keep)
    #expect(ws.tabs.count == 1)
    #expect(ws.tabs.first?.id == keep)
    #expect(ws.activeTabID == keep)
}

@Test("K8: closeOtherTabs mit unbekannter ID lässt die Tabs unangetastet")
@MainActor
func closeOtherTabs_unknownIDNoOp() {
    let ws = makeWS(content: "x")
    ws.tabs = [EditorTab(title: "a", path: "-"), EditorTab(title: "b", path: "-")]
    ws.closeOtherTabs(keeping: UUID())
    #expect(ws.tabs.count == 2)
}

@Test("K9: swapFindReplace vertauscht die beiden Felder")
@MainActor
func swapFindReplace_swaps() {
    let ws = makeWS(content: "x")
    ws.findPattern = "foo"
    ws.replacePattern = "bar"
    ws.swapFindReplace()
    #expect(ws.findPattern == "bar")
    #expect(ws.replacePattern == "foo")
}
