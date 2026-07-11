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
    #expect(inbox.drain().isEmpty)
}

@Test("enqueue puffert in Reihenfolge, drain liefert alles und leert")
func inbox_enqueueThenDrain() {
    var inbox = OpenFilesInbox()
    inbox.enqueue([u("/a.txt"), u("/b.txt")])
    inbox.enqueue([u("/c.txt")])
    #expect(inbox.pending.count == 3)

    let drained = inbox.drain()
    #expect(drained.map(\.path) == ["/a.txt", "/b.txt", "/c.txt"])
    // Nach dem Drain ist der Puffer leer — ein zweiter Drain liefert nichts.
    #expect(inbox.pending.isEmpty)
    #expect(inbox.drain().isEmpty)
}

@Test("Nach drain können neue URLs erneut gepuffert werden")
func inbox_reusableAfterDrain() {
    var inbox = OpenFilesInbox()
    inbox.enqueue([u("/a.txt")])
    _ = inbox.drain()
    inbox.enqueue([u("/b.txt")])
    #expect(inbox.drain().map(\.path) == ["/b.txt"])
}
