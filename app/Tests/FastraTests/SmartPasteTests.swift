// SmartPasteTests.swift
//
// Unit-Tests für SmartPaste.swift (Roadmap H, v0.8 — Markdown Smart-Paste).
//
// Was NICHT getestet wird:
//   - Das echte md-clip (externes CLI, nicht in der Testumgebung verfügbar)
//   - NSAlert-Anzeige (AppKit-UI, nicht unit-testbar)
//   - insertText-Logik (benötigt First Responder in einem echten Fenster)
//
// Was getestet wird:
//   - findMdClip: Pfad-Suche mit und ohne x-Bit (Temp-Dateien im /tmp)
//   - SmartPasteError.userMessage: nicht leer + enthält bei mdClipNotInstalled
//     die GitHub-Release-URL
//   - clipboardHasFormattedContent: mit privatem Test-Pasteboard, das explizit
//     befüllt wird (HTML vs. nur-plain)
//   - Prozess-Pipes: großer Output, geerbter stderr-Descriptor und Timeout

import Testing
import AppKit
import Foundation
@testable import Fastra

// MARK: - findMdClip

/// Legt eine temporäre Datei im /tmp an und gibt ihre URL zurück.
/// `withXBit` steuert, ob sie ausführbar ist.
private func makeTempFile(name: String, withXBit: Bool) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("smartpaste-test-\(UUID().uuidString)-\(name)")
    // Leere Datei anlegen — der Inhalt ist für den Test irrelevant.
    try Data().write(to: url)
    if withXBit {
        // x-Bit setzen: Berechtigung 0o755
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    } else {
        // Kein x-Bit: nur lesbar (0o644)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: url.path
        )
    }
    return url
}

/// Erstellt ein kleines ausführbares Shell-Skript als kontrollierten
/// md-clip-Ersatz. Damit testen wir den echten `Process`-/Pipe-Lebenszyklus,
/// ohne eine md-clip-Installation oder das Clipboard vorauszusetzen.
private func makeMdClipStub(name: String, body: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("smartpaste-stub-\(UUID().uuidString)-\(name)")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
    return url
}

@Test("findMdClip: gibt nil zurück, wenn kein Pfad ausführbar ist")
func findMdClip_noneExecutable() throws {
    // Zwei temporäre Dateien anlegen — beide OHNE x-Bit.
    let fileA = try makeTempFile(name: "md-clip-a", withXBit: false)
    let fileB = try makeTempFile(name: "md-clip-b", withXBit: false)
    defer {
        try? FileManager.default.removeItem(at: fileA)
        try? FileManager.default.removeItem(at: fileB)
    }

    // Beide Pfade als searchPaths übergeben — keiner hat x-Bit.
    let result = SmartPaste.findMdClip(searchPaths: [fileA.path, fileB.path])
    #expect(result == nil)
}

@Test("findMdClip: gibt URL des ersten ausführbaren Pfads zurück")
func findMdClip_firstExecutable() throws {
    // Erster Pfad OHNE x-Bit, zweiter MIT x-Bit.
    let noXBit = try makeTempFile(name: "md-clip-nox", withXBit: false)
    let withXBit = try makeTempFile(name: "md-clip-x", withXBit: true)
    defer {
        try? FileManager.default.removeItem(at: noXBit)
        try? FileManager.default.removeItem(at: withXBit)
    }

    let result = SmartPaste.findMdClip(searchPaths: [noXBit.path, withXBit.path])
    // Erwartet: withXBit, weil noXBit kein x-Bit hat.
    #expect(result?.path == withXBit.path)
}

@Test("findMdClip: gibt nil zurück, wenn searchPaths leer ist")
func findMdClip_emptyPaths() {
    let result = SmartPaste.findMdClip(searchPaths: [])
    #expect(result == nil)
}

@Test("findMdClip: gibt nil zurück, wenn Pfad nicht existiert")
func findMdClip_nonExistentPath() {
    // Ein Pfad, den es mit Sicherheit nicht gibt.
    let result = SmartPaste.findMdClip(searchPaths: ["/tmp/smartpaste-does-not-exist-\(UUID().uuidString)"])
    #expect(result == nil)
}

// MARK: - SmartPasteError.userMessage

@Test("userMessage ist nicht leer für alle Fehlertypen")
func userMessage_neverEmpty() {
    let allCases: [SmartPasteError] = [
        .mdClipNotInstalled,
        .noFormattedContent,
        .conversionFailed("Testdetail"),
        .timeout
    ]
    for error in allCases {
        // Jede userMessage muss mindestens einen lesbaren Satz enthalten.
        #expect(!error.userMessage.isEmpty, "userMessage für \(error) ist leer")
    }
}

@Test("userMessage für mdClipNotInstalled enthält GitHub-Release-URL")
func userMessage_mdClipNotInstalled_containsReleaseURL() {
    let message = SmartPasteError.mdClipNotInstalled.userMessage
    // Nutzer braucht die konkrete URL, um das Tool zu installieren.
    #expect(message.contains("https://github.com/DanielMuellerIR/md-clip/releases"))
}

// MARK: - clipboardHasFormattedContent

/// Erstellt ein privates, isoliertes Pasteboard, das den `NSPasteboard.general`
/// nicht beeinflusst. Der zufällige Name verhindert Kollisionen zwischen
/// parallel laufenden Tests.
private func makePrivatePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
}

@Test("clipboardHasFormattedContent: true bei HTML-Inhalt")
@MainActor
func clipboardHasFormattedContent_html() {
    let pb = makePrivatePasteboard()
    // Pasteboard mit HTML befüllen.
    pb.declareTypes([.html, .string], owner: nil)
    pb.setString("<b>Test</b>", forType: .html)
    pb.setString("Test", forType: .string)

    #expect(SmartPaste.clipboardHasFormattedContent(pb) == true)
    // Aufräumen: Pasteboard freigeben.
    pb.releaseGlobally()
}

@Test("clipboardHasFormattedContent: false bei nur Plain-Text")
@MainActor
func clipboardHasFormattedContent_plainOnly() {
    let pb = makePrivatePasteboard()
    // Nur .string, kein HTML und kein RTF.
    pb.declareTypes([.string], owner: nil)
    pb.setString("Nur Text, kein Markdown", forType: .string)

    #expect(SmartPaste.clipboardHasFormattedContent(pb) == false)
    pb.releaseGlobally()
}

// MARK: - markdownFromClipboard Prozess-Lebenszyklus

@Test("markdownFromClipboard: großer stdout-Output blockiert die Pipe nicht")
func markdownFromClipboard_largeOutputDoesNotBlock() throws {
    // Deutlich mehr als ein typischer Pipe-Puffer: Die alte Implementierung
    // wartete auf Prozessende, während der Prozess auf freien Puffer wartete.
    let stub = try makeMdClipStub(
        name: "large-output",
        body: "/usr/bin/yes x | /usr/bin/head -c 200000"
    )
    defer { try? FileManager.default.removeItem(at: stub) }

    let result = SmartPaste.markdownFromClipboard(mdClipURL: stub, timeout: 2)

    guard case .success(let markdown) = result else {
        Issue.record("Großer Output schlug fehl: \(result)")
        return
    }
    #expect(markdown.utf8.count > 190_000)
}

@Test("markdownFromClipboard: geerbter stderr-Descriptor blockiert Fehlerpfad nicht")
func markdownFromClipboard_inheritedStderrDoesNotBlock() throws {
    // Der Hintergrundprozess hält stderr nach dem Ende des Stubs noch offen.
    // Auf EOF zu lesen würde bis zum Ende des `sleep` blockieren.
    let stub = try makeMdClipStub(
        name: "inherited-stderr",
        body: "(sleep 2) &\nprintf 'Pandoc-Testfehler\\n' >&2\nexit 2"
    )
    defer { try? FileManager.default.removeItem(at: stub) }

    let started = Date()
    let result = SmartPaste.markdownFromClipboard(mdClipURL: stub, timeout: 2)
    let elapsed = Date().timeIntervalSince(started)

    guard case .failure(.conversionFailed(let detail)) = result else {
        Issue.record("Falsches Ergebnis: \(result)")
        return
    }
    #expect(detail.contains("Pandoc-Testfehler"))
    #expect(elapsed < 1.0, "Fehlerpfad wartete \(elapsed) Sekunden auf Pipe-EOF")
}

@Test("markdownFromClipboard: Timeout beendet auch SIGTERM-resistenten Prozess")
func markdownFromClipboard_timeoutKillsResistantProcess() throws {
    // Kein Kindprozess: Nach ignoriertem SIGTERM muss Fastra den Stub selbst
    // per SIGKILL beenden und darf nicht auf offene Descriptoren warten.
    let stub = try makeMdClipStub(
        name: "timeout",
        body: "trap '' TERM\nwhile :; do :; done"
    )
    defer { try? FileManager.default.removeItem(at: stub) }

    let started = Date()
    let result = SmartPaste.markdownFromClipboard(mdClipURL: stub, timeout: 0.1)
    let elapsed = Date().timeIntervalSince(started)

    #expect(result == .failure(.timeout))
    #expect(elapsed < 1.0, "Timeout-Aufräumen dauerte \(elapsed) Sekunden")
}
