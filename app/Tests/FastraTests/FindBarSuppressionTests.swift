// FindBarSuppressionTests.swift
//
// Deckt die zwei AppKit-Abwehrmechanismen gegen den „Zombie-Find-Bar" ab:
//   1. `disableFindBars(in:)` schaltet `usesFindBar` an allen NSTextViews
//      rekursiv aus.
//   2. `purge(menu:)` entfernt find-bezogene Menüpunkte.
//
// Diese Tests laufen ohne laufende NSApplication — sie bauen synthetische
// View-/Menü-Bäume. @MainActor, weil AppKit-Views Main-Thread brauchen.

import Testing
import AppKit
@testable import Fastra

@MainActor
@Test("disableFindBars schaltet usesFindBar an verschachtelten NSTextViews aus")
func disableFindBars_recursive() {
    let root = NSView()
    let mid = NSView()
    let tv1 = NSTextView()
    let tv2 = NSTextView()
    tv1.usesFindBar = true
    tv2.usesFindBar = true

    mid.addSubview(tv2)
    root.addSubview(tv1)
    root.addSubview(mid)

    let count = AppDelegate.disableFindBars(in: root)

    #expect(count == 2)
    #expect(tv1.usesFindBar == false)
    #expect(tv2.usesFindBar == false)
}

@MainActor
@Test("isFindRelated erkennt performTextFinderAction:")
func isFindRelated_textFinder() {
    let item = NSMenuItem(
        title: "Find…",
        action: #selector(NSResponder.performTextFinderAction(_:)),
        keyEquivalent: "f"
    )
    #expect(AppDelegate.isFindRelated(item) == true)
}

@MainActor
@Test("isFindRelated ignoriert harmlose Aktionen")
func isFindRelated_other() {
    let item = NSMenuItem(
        title: "Speichern",
        action: Selector(("saveDocument:")),
        keyEquivalent: "s"
    )
    #expect(AppDelegate.isFindRelated(item) == false)
}

@MainActor
@Test("purge entfernt find-Items, lässt andere stehen")
func purge_removesFindItems() {
    let menu = NSMenu(title: "Edit")
    let find = NSMenuItem(
        title: "Find…",
        action: #selector(NSResponder.performTextFinderAction(_:)),
        keyEquivalent: "f"
    )
    let save = NSMenuItem(
        title: "Speichern",
        action: Selector(("saveDocument:")),
        keyEquivalent: "s"
    )
    menu.addItem(find)
    menu.addItem(save)

    AppDelegate.purge(menu: menu)

    #expect(menu.items.count == 1)
    #expect(menu.items.first?.title == "Speichern")
}

@MainActor
@Test("purge wirkt rekursiv in Submenüs")
func purge_recursesIntoSubmenus() {
    let root = NSMenu(title: "MainMenu")
    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(NSMenuItem(
        title: "Find Next",
        action: Selector(("performFindPanelAction:")),
        keyEquivalent: "g"
    ))
    editItem.submenu = editMenu
    root.addItem(editItem)

    AppDelegate.purge(menu: root)

    #expect(editMenu.items.isEmpty)
}
