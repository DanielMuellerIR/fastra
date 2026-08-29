// SidebarScrollMemoryTests.swift
//
// Tests für die gemerkten Scrollpositionen der Seitenleisten-Listen: den
// Speicher selbst und die reine Rechnung der Wiederherstellung.

import AppKit
import Foundation
import Testing
@testable import Fastra

// MARK: - Speicher

@Test("Speicher gibt zurück, was zuletzt gemerkt wurde")
func scrollMemory_recordAndRead() {
    let memory = SidebarScrollMemory()
    #expect(memory.offset(for: "fileTree") == nil)
    memory.record(240, for: "fileTree")
    #expect(memory.offset(for: "fileTree") == 240)
    memory.record(12, for: "fileTree")
    #expect(memory.offset(for: "fileTree") == 12)
}

@Test("Listen stören sich gegenseitig nicht")
func scrollMemory_keysAreIndependent() {
    let memory = SidebarScrollMemory()
    memory.record(100, for: "fileTree")
    memory.record(300, for: "gitGraph")
    #expect(memory.offset(for: "fileTree") == 100)
    #expect(memory.offset(for: "gitGraph") == 300)
}

@Test("Negative Positionen gibt es nicht")
func scrollMemory_clampsNegative() {
    // Beim Überziehen am oberen Rand (Gummiband) meldet AppKit kurzzeitig
    // negative Werte. Als Ziel wären sie sinnlos.
    let memory = SidebarScrollMemory()
    memory.record(-40, for: "fileTree")
    #expect(memory.offset(for: "fileTree") == 0)
}

@Test("Leeren wirft alle Einträge weg")
func scrollMemory_removeAll() {
    // Der Projektwechsel leert den ganzen Speicher: Die Schlüssel sind über
    // Projekte hinweg dieselben (Review-Fund 2026-08-25).
    let memory = SidebarScrollMemory()
    memory.record(50, for: "gitGraph:a.txt")
    memory.record(240, for: "fileTree")
    memory.removeAll()
    #expect(memory.offset(for: "gitGraph:a.txt") == nil)
    #expect(memory.offset(for: "fileTree") == nil)
    // Auch die Altersliste muss leer sein — sonst zählte ein Geisterschlüssel
    // weiter gegen die Kapazität.
    for index in 0..<SidebarScrollMemory.capacity {
        memory.record(CGFloat(index), for: "neu-\(index)")
    }
    #expect(memory.offset(for: "neu-0") == 0)
}

@Test("Der Speicher wächst nicht unbegrenzt")
func scrollMemory_capacity() {
    // Die Verlaufsansicht legt pro betrachteter Datei einen Schlüssel an.
    let memory = SidebarScrollMemory()
    for index in 0..<(SidebarScrollMemory.capacity + 10) {
        memory.record(CGFloat(index), for: "datei-\(index)")
    }
    // Der älteste Eintrag ist weg, der jüngste steht.
    #expect(memory.offset(for: "datei-0") == nil)
    #expect(memory.offset(for: "datei-\(SidebarScrollMemory.capacity + 9)")
            == CGFloat(SidebarScrollMemory.capacity + 9))
}

@Test("Erneutes Merken hält einen Eintrag frisch")
func scrollMemory_recordRefreshesAge() {
    let memory = SidebarScrollMemory()
    memory.record(1, for: "alt")
    for index in 0..<(SidebarScrollMemory.capacity - 1) {
        memory.record(CGFloat(index), for: "füller-\(index)")
    }
    // „alt" wäre jetzt der nächste Rauswurf-Kandidat — bis er wieder benutzt wird.
    memory.record(2, for: "alt")
    memory.record(3, for: "neu")
    #expect(memory.offset(for: "alt") == 2)
}

// MARK: - Wiederherstellung

@Test("Ziel wird auf das tatsächlich Erreichbare geklemmt")
func scrollRestore_clampsToDocument() {
    // `NSClipView.scroll(to:)` klemmt selbst NICHT — ein zu großes Ziel wird
    // scheinbar übernommen und schnappt beim nächsten Layout auf null zurück.
    #expect(SidebarScrollRestore.reachable(target: 5000, documentHeight: 800,
                                           viewportHeight: 300) == 500)
    #expect(SidebarScrollRestore.reachable(target: 120, documentHeight: 800,
                                           viewportHeight: 300) == 120)
}

@Test("Kürzeres Dokument als Sichtfenster erlaubt nur null")
func scrollRestore_shortDocument() {
    #expect(SidebarScrollRestore.reachable(target: 300, documentHeight: 100,
                                           viewportHeight: 400) == 0)
}

@Test("Negatives Ziel wird zu null")
func scrollRestore_negativeTarget() {
    #expect(SidebarScrollRestore.reachable(target: -50, documentHeight: 800,
                                           viewportHeight: 300) == 0)
}

@Test("Erreichtes Ziel beendet die Nachzieh-Schleife")
func scrollRestore_settledWhenReached() {
    #expect(SidebarScrollRestore.isSettled(target: 400, achieved: 400,
                                           attempt: 0, maximumAttempts: 12))
}

@Test("Eine noch am Anfang stehende Liste läuft weiter")
func scrollRestore_keepsTryingWhileDocumentGrows() {
    // Der gefährliche Fall: Direkt nach dem Aufbau ist die LazyVStack leer,
    // die erreichbare Position also 0. Wer hier abbricht, lässt die Liste für
    // immer oben stehen (Selbsttest `sidebarstate`, 2026-08-24).
    #expect(!SidebarScrollRestore.isSettled(target: 400, achieved: 0,
                                            attempt: 0, maximumAttempts: 12))
    #expect(!SidebarScrollRestore.isSettled(target: 400, achieved: 100,
                                            attempt: 3, maximumAttempts: 12))
}

@Test("Die Versuchszahl ist begrenzt")
func scrollRestore_stopsAfterMaximumAttempts() {
    // Eine wirklich kürzer gewordene Liste erreicht das Ziel nie — dann
    // beendet die Versuchsgrenze die Schleife.
    #expect(SidebarScrollRestore.isSettled(target: 900, achieved: 200,
                                           attempt: 12, maximumAttempts: 12))
}

@MainActor
@Test("Frühes Layout überschreibt das noch nicht wiederhergestellte Ziel nicht")
func scrollProbe_suppressesRecordingBeforeDeferredRestore() {
    let memory = SidebarScrollMemory()
    memory.record(400, for: "fileTree")

    let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 1_000))
    let probe = SidebarScrollProbeView(frame: .zero)
    probe.configure(key: "fileTree", memory: memory)
    document.addSubview(probe)

    let scrollView = NSScrollView(
        frame: NSRect(x: 0, y: 0, width: 200, height: 100)
    )
    scrollView.documentView = document
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = scrollView
    defer { window.close() }

    // `viewDidMoveToWindow` hat den Observer installiert, sein verzögerter
    // Restore-Block kann im laufenden Main-Actor-Durchlauf aber noch nicht
    // gelaufen sein. Genau in diesem Fenster meldet AppKit beim Aufbau eine
    // Bounds-Änderung an Position 0.
    #expect(probe.window === window)
    scrollView.contentView.scroll(to: .zero)
    NotificationCenter.default.post(
        name: NSView.boundsDidChangeNotification,
        object: scrollView.contentView
    )

    #expect(memory.offset(for: "fileTree") == 400)
}
