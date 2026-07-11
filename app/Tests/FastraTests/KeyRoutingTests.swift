// KeyRoutingTests.swift
//
// Deckt die reine Shortcut-Entscheidungslogik ab (CMD+F, CMD+SHIFT+F,
// ESC). Diese Tests sind der Regressions-Schutz gegen den wiederkehrenden
// „Zombie-Find-Bar"-Bug: solange `KeyRouting.route` CMD+F korrekt als
// abzufangende Route meldet, leiten BEIDE Handler (sendEvent + Monitor)
// das Event nicht an die NSTextView weiter.

import Testing
import AppKit
@testable import Fastra

@Test("CMD+F → Datei-Suche")
func cmdF_showsFileSearch() {
    let route = KeyRouting.route(
        isKeyDown: true,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "f",
        keyCode: 3,
        isSearchWindowKey: false
    )
    #expect(route == .showSearchFile)
    #expect(KeyRouting.notificationName(for: route) == .fastraShowSearchFile)
}

@Test("CMD+SHIFT+F → Ordner-Suche")
func cmdShiftF_showsFolderSearch() {
    let route = KeyRouting.route(
        isKeyDown: true,
        modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "f",
        keyCode: 3,
        isSearchWindowKey: false
    )
    #expect(route == .showSearchFolder)
    #expect(KeyRouting.notificationName(for: route) == .fastraShowSearchFolder)
}

@Test("Großbuchstabe F wird wie f behandelt")
func cmdF_uppercase() {
    let route = KeyRouting.route(
        isKeyDown: true,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "F",
        keyCode: 3,
        isSearchWindowKey: false
    )
    #expect(route == .showSearchFile)
}

@Test("CMD+CTRL+F wird NICHT gekapert")
func cmdCtrlF_passesThrough() {
    let route = KeyRouting.route(
        isKeyDown: true,
        modifierFlags: [.command, .control],
        charactersIgnoringModifiers: "f",
        keyCode: 3,
        isSearchWindowKey: false
    )
    #expect(route == .passThrough)
    #expect(KeyRouting.notificationName(for: route) == nil)
}

@Test("CMD+OPT+F wird NICHT gekapert")
func cmdOptF_passesThrough() {
    let route = KeyRouting.route(
        isKeyDown: true,
        modifierFlags: [.command, .option],
        charactersIgnoringModifiers: "f",
        keyCode: 3,
        isSearchWindowKey: false
    )
    #expect(route == .passThrough)
}

@Test("F ohne CMD läuft normal durch (Tippen)")
func plainF_passesThrough() {
    let route = KeyRouting.route(
        isKeyDown: true,
        modifierFlags: [],
        charactersIgnoringModifiers: "f",
        keyCode: 3,
        isSearchWindowKey: false
    )
    #expect(route == .passThrough)
}

@Test("Nicht-keyDown (z.B. keyUp) wird nie abgefangen")
func nonKeyDown_passesThrough() {
    let route = KeyRouting.route(
        isKeyDown: false,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "f",
        keyCode: 3,
        isSearchWindowKey: false
    )
    #expect(route == .passThrough)
}

@Test("CMD+W schließt Suchmaske nur, wenn sie Key-Window ist")
func cmdW_hidesOnlyWhenSearchKey() {
    let whenKey = KeyRouting.route(
        isKeyDown: true, modifierFlags: [.command],
        charactersIgnoringModifiers: "w", keyCode: 13,
        isSearchWindowKey: true
    )
    #expect(whenKey == .hideSearch)

    let whenNotKey = KeyRouting.route(
        isKeyDown: true, modifierFlags: [.command],
        charactersIgnoringModifiers: "w", keyCode: 13,
        isSearchWindowKey: false
    )
    #expect(whenNotKey == .passThrough)
}

@Test("CMD+SHIFT+W wird nicht als Maske-Schließen behandelt")
func cmdShiftW_passesThrough() {
    let route = KeyRouting.route(
        isKeyDown: true, modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "w", keyCode: 13,
        isSearchWindowKey: true
    )
    #expect(route == .passThrough)
}

@Test("ESC schließt Suchmaske nur, wenn sie Key-Window ist")
func esc_hidesOnlyWhenSearchKey() {
    let whenKey = KeyRouting.route(
        isKeyDown: true,
        modifierFlags: [],
        charactersIgnoringModifiers: nil,
        keyCode: KeyRouting.escapeKeyCode,
        isSearchWindowKey: true
    )
    #expect(whenKey == .hideSearch)

    let whenNotKey = KeyRouting.route(
        isKeyDown: true,
        modifierFlags: [],
        charactersIgnoringModifiers: nil,
        keyCode: KeyRouting.escapeKeyCode,
        isSearchWindowKey: false
    )
    #expect(whenNotKey == .passThrough)
}

// MARK: - CMD+G / CMD+SHIFT+G — Treffer-Navigation

@Test("CMD+G → gotoNextMatch")
func cmdG_gotoNextMatch() {
    let route = KeyRouting.route(
        isKeyDown: true, modifierFlags: [.command],
        charactersIgnoringModifiers: "g", keyCode: 5,
        isSearchWindowKey: false
    )
    #expect(route == .gotoNextMatch)
    #expect(KeyRouting.notificationName(for: route) == .fastraGotoNextMatch)
}

@Test("CMD+SHIFT+G → gotoPreviousMatch")
func cmdShiftG_gotoPreviousMatch() {
    let route = KeyRouting.route(
        isKeyDown: true, modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "g", keyCode: 5,
        isSearchWindowKey: false
    )
    #expect(route == .gotoPreviousMatch)
    #expect(KeyRouting.notificationName(for: route) == .fastraGotoPreviousMatch)
}

@Test("CMD+CTRL+G wird NICHT gekapert")
func cmdCtrlG_passesThrough() {
    let route = KeyRouting.route(
        isKeyDown: true, modifierFlags: [.command, .control],
        charactersIgnoringModifiers: "g", keyCode: 5,
        isSearchWindowKey: false
    )
    #expect(route == .passThrough)
}

@Test("CMD+G greift unabhängig davon, ob Suchmaske vorne ist")
func cmdG_worksRegardlessOfKeyWindow() {
    let inSearch = KeyRouting.route(
        isKeyDown: true, modifierFlags: [.command],
        charactersIgnoringModifiers: "g", keyCode: 5,
        isSearchWindowKey: true
    )
    let inEditor = KeyRouting.route(
        isKeyDown: true, modifierFlags: [.command],
        charactersIgnoringModifiers: "g", keyCode: 5,
        isSearchWindowKey: false
    )
    #expect(inSearch == .gotoNextMatch)
    #expect(inEditor == .gotoNextMatch)
}

@Test("CMD+J → showGotoLine")
func cmdJ_showsGotoLine() {
    let route = KeyRouting.route(
        isKeyDown: true, modifierFlags: [.command],
        charactersIgnoringModifiers: "j", keyCode: 38,
        isSearchWindowKey: false
    )
    #expect(route == .showGotoLine)
    #expect(KeyRouting.notificationName(for: route) == .fastraShowGotoLine)
}

@Test("CMD+SHIFT+J wird NICHT als showGotoLine gewertet")
func cmdShiftJ_passesThrough() {
    let route = KeyRouting.route(
        isKeyDown: true, modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "j", keyCode: 38,
        isSearchWindowKey: false
    )
    #expect(route == .passThrough)
}
