// SidebarVisibility.swift
//
// Ohne geöffneten Ordner oder Repo keine Seitenleiste, auch bei mehreren
// Tabs. Der Nutzerschalter gilt erst mit Projekt. Bei offenem Projekt bleibt
// die Hierarchie beim Ausblenden montiert und schrumpft auf Breite 0, damit
// Dateibaum, FSEvents-Watcher und Cache nicht neu aufgebaut werden müssen.
// `sidebartoggle` misst Dauer und Speicher über hunderte Umschaltungen.

import Foundation

enum SidebarVisibility {
    /// Sichtbar nur mit offenem Projekt und eingeschaltetem Nutzerschalter.
    static func isVisible(userWantsSidebar: Bool, hasProject: Bool) -> Bool {
        hasProject && userWantsSidebar
    }

    /// Eingehängt, solange ein Projekt offen ist — unabhängig vom Schalter.
    /// Umschalten ist dann nur eine Breitenänderung, kein Neuaufbau.
    static func isMounted(hasProject: Bool) -> Bool {
        hasProject
    }

    /// Der Umschalter im Fenster-Chrome ist nur mit Projekt sinnvoll; ohne
    /// Projekt gäbe es nichts ein- oder auszublenden.
    static func offersToggle(hasProject: Bool) -> Bool {
        hasProject
    }
}
