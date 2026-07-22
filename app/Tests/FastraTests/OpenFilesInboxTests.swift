// OpenFilesInboxTests.swift
//
// Tests für den Puffer hinter dem Finder-/CLI-Öffnen (K1). Reine Logik —
// kein AppKit, kein Workspace.

import Foundation
import Testing
@testable import Fastra

private func u(_ path: String) -> URL { URL(fileURLWithPath: path) }

@Test("Frischer Inbox ist leer; drain liefert leeres Array")
func inbox_startsEmpty() {
    var inbox = OpenFilesInbox()
    #expect(inbox.pending.isEmpty)
    #expect(!inbox.launchDidFinish)
    #expect(inbox.drain().isEmpty)
}

@Test("Kaltstart puffert in Reihenfolge, bis der Launch abgeschlossen ist")
func inbox_coldLaunchBuffersUntilFinished() {
    var inbox = OpenFilesInbox()
    #expect(inbox.receive([u("/a.txt"), u("/b.txt")]).isEmpty)
    #expect(inbox.receive([u("/c.txt")]).isEmpty)
    #expect(inbox.pending.count == 3)

    inbox.finishLaunching()
    #expect(inbox.launchDidFinish)
    let drained = inbox.drain()
    #expect(drained.map(\.path) == ["/a.txt", "/b.txt", "/c.txt"])
    // Nach dem Drain ist der Puffer leer — ein zweiter Drain liefert nichts.
    #expect(inbox.pending.isEmpty)
    #expect(inbox.drain().isEmpty)
}

@Test("Nach Launch-Ende werden neue URLs sofort statt gepuffert ausgeliefert")
func inbox_warmLaunchDeliversImmediately() {
    var inbox = OpenFilesInbox()
    #expect(inbox.receive([u("/a.txt")]).isEmpty)
    inbox.finishLaunching()
    _ = inbox.drain()

    let immediate = inbox.receive([u("/b.txt"), u("/c.txt")])
    #expect(immediate.map(\.path) == ["/b.txt", "/c.txt"])
    #expect(inbox.pending.isEmpty)
}
