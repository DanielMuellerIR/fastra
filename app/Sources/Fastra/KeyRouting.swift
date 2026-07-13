// KeyRouting.swift
//
// Reine (UI-freie) Entscheidungs-Logik für globale Tastatur-Shortcuts.
//
// Warum eine eigene Datei mit reiner Logik?
//   Der „Zombie-Find-Bar"-Bug kam mehrfach zurück, weil die Shortcut-
//   Behandlung tief in AppKit-Glue (NSApplication-Subklasse, NSEvent-
//   Monitor) steckte — dort ist sie praktisch nicht automatisiert
//   testbar, und sie existierte in ZWEI Kopien (sendEvent + Monitor),
//   die auseinanderlaufen konnten.
//
//   Lösung: die Entscheidung „welches Event löst welche Aktion aus" ist
//   hier als pure Funktion gekapselt. Beide Aufrufer (FastraApplication
//   und AppDelegate) nutzen exakt dieselbe Funktion — keine Divergenz —
//   und die Funktion ist in `KeyRoutingTests` vollständig abgedeckt.

import AppKit

/// Welche App-Aktion ein Tasten-Event auslöst.
enum KeyRoute: Equatable {
    /// CMD+F — Suchmaske im Datei-Modus zeigen.
    case showSearchFile
    /// CMD+SHIFT+F — Suchmaske im Ordner-Modus zeigen.
    case showSearchFolder
    /// ESC bei aktiver Suchmaske — ausblenden.
    case hideSearch
    /// CMD+G — zum nächsten Treffer springen.
    case gotoNextMatch
    /// CMD+SHIFT+G — zum vorigen Treffer springen.
    case gotoPreviousMatch
    /// CMD+J — „Zu Zeile springen"-Dialog öffnen.
    case showGotoLine
    /// Home bzw. FN+← — an den Anfang des Dokuments springen.
    case moveToBeginningOfDocument(modifySelection: Bool)
    /// End bzw. FN+→ — an das Ende des Dokuments springen.
    case moveToEndOfDocument(modifySelection: Bool)
    /// Event nicht abfangen — normal weiterreichen.
    case passThrough
}

enum KeyRouting {
    /// macOS-Keycode der ESC-Taste.
    static let escapeKeyCode: UInt16 = 53
    /// macOS-Keycodes der echten Home-/End-Tasten. Die eingebaute
    /// MacBook-Tastatur sendet dieselben Codes für FN+← beziehungsweise FN+→.
    static let homeKeyCode: UInt16 = 115
    static let endKeyCode: UInt16 = 119

    /// Entscheidet rein anhand der Event-Eigenschaften, welche Aktion ein
    /// Tasten-Event auslöst. Keine Seiteneffekte, kein AppKit-State außer
    /// den übergebenen Werten — dadurch vollständig unit-testbar.
    ///
    /// - Parameters:
    ///   - isKeyDown: `true`, wenn es sich um ein `keyDown`-Event handelt.
    ///   - modifierFlags: Modifier des Events.
    ///   - charactersIgnoringModifiers: Zeichen ohne Modifier-Einfluss.
    ///   - keyCode: Hardware-Keycode (für ESC).
    ///   - isSearchWindowKey: Ob die Suchmaske gerade Key-Window ist.
    static func route(
        isKeyDown: Bool,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        keyCode: UInt16,
        isSearchWindowKey: Bool
    ) -> KeyRoute {
        guard isKeyDown else { return .passThrough }

        // CodeEditTextView kennt die AppKit-Aktionen „zum Dokumentanfang/-ende",
        // ordnet die Home-/End-Keycodes aber nicht selbst zuverlässig zu.
        // Shift erweitert dabei – wie in nativen Editoren üblich – die Auswahl.
        // Command, Option und Control bleiben ausdrücklich unangetastet, damit
        // bestehende System- und Nutzer-Shortcuts weiterhin durchgereicht werden.
        let navigationModifiers = modifierFlags.intersection([.command, .option, .control])
        if navigationModifiers.isEmpty {
            let modifiesSelection = modifierFlags.contains(.shift)
            if keyCode == homeKeyCode {
                return .moveToBeginningOfDocument(modifySelection: modifiesSelection)
            }
            if keyCode == endKeyCode {
                return .moveToEndOfDocument(modifySelection: modifiesSelection)
            }
        }

        // ESC blendet die Suchmaske aus — aber nur, wenn sie vorn ist.
        // Sonst nicht abfangen (würde andere Dialoge/Menüs stören).
        if keyCode == escapeKeyCode {
            return isSearchWindowKey ? .hideSearch : .passThrough
        }

        // CMD+W bei vorderer Suchmaske → ausblenden (wie roter Knopf/ESC).
        // Sonst durchreichen, damit CMD+W im Hauptfenster den aktiven Tab
        // schließt (Menü-Eintrag „Schließen").
        if modifierFlags.contains(.command),
           charactersIgnoringModifiers?.lowercased() == "w" {
            let extra = modifierFlags.intersection([.option, .control, .shift])
            return (extra.isEmpty && isSearchWindowKey) ? .hideSearch : .passThrough
        }

        // CMD+G / CMD+SHIFT+G — Treffer-Navigation.
        if modifierFlags.contains(.command),
           charactersIgnoringModifiers?.lowercased() == "g" {
            let extra = modifierFlags.intersection([.option, .control])
            guard extra.isEmpty else { return .passThrough }
            return modifierFlags.contains(.shift) ? .gotoPreviousMatch : .gotoNextMatch
        }

        // CMD+J — Zu-Zeile-Springen.
        if modifierFlags.contains(.command),
           charactersIgnoringModifiers?.lowercased() == "j" {
            let extra = modifierFlags.intersection([.option, .control, .shift])
            guard extra.isEmpty else { return .passThrough }
            return .showGotoLine
        }

        // Ab hier nur noch CMD+F / CMD+SHIFT+F.
        guard modifierFlags.contains(.command),
              charactersIgnoringModifiers?.lowercased() == "f" else {
            return .passThrough
        }

        // Weitere Modifier (Option, Control) ausschließen — damit wir
        // z.B. CMD+CTRL+F nicht versehentlich kapern.
        let extra = modifierFlags.intersection([.option, .control])
        guard extra.isEmpty else { return .passThrough }

        return modifierFlags.contains(.shift) ? .showSearchFolder : .showSearchFile
    }

    /// Notification, die für eine abzufangende Route gepostet wird, oder
    /// `nil` bei `.passThrough`.
    static func notificationName(for route: KeyRoute) -> Notification.Name? {
        switch route {
        case .showSearchFile:     return .fastraShowSearchFile
        case .showSearchFolder:   return .fastraShowSearchFolder
        case .hideSearch:         return .fastraHideSearch
        case .gotoNextMatch:      return .fastraGotoNextMatch
        case .gotoPreviousMatch:  return .fastraGotoPreviousMatch
        case .showGotoLine:       return .fastraShowGotoLine
        case .moveToBeginningOfDocument, .moveToEndOfDocument:
            // Diese Aktionen gehen direkt an die fokussierte Editor-TextView;
            // eine globale Notification würde Suchfelder versehentlich erfassen.
            return nil
        case .passThrough:        return nil
        }
    }
}
