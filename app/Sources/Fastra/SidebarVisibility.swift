// SidebarVisibility.swift
//
// Wann die linke Seitenleiste sichtbar ist und wann sie überhaupt im
// Fenster hängt (Änderungswunsch 2026-09-06).
//
// Ohne geöffneten Ordner oder Repo zeigt die Seitenleiste nur die Marke und
// den „Datei öffnen…"-Knopf. Auf dem Willkommensbildschirm stand die Marke
// damit zweimal nebeneinander — redundant und unelegant. Deshalb: Ohne
// Projekt gibt es keine Seitenleiste, auch wenn weitere Tabs offen sind; der
// Nutzerschalter („Seitenleiste anzeigen") gilt erst, sobald ein Projekt
// offen ist.
//
// Zweite Regel für die Geschwindigkeit: Mit offenem Projekt bleibt die
// Seitenleiste EINGEHÄNGT und wird beim Ausblenden nur auf Breite 0
// zusammengezogen. Vorher entfernte SwiftUI die ganze Hierarchie samt
// Dateibaum, FSEvents-Wächter und Verzeichnis-Cache und baute sie beim
// Einblenden neu auf — jedes Umschalten kostete einen kompletten Neuaufbau
// und war die Stelle, an der Speicher bei sehr häufigem Umschalten hätte
// wachsen können. Der `sidebartoggle`-Selbsttest misst Dauer und Speicher
// über hunderte Umschaltungen.

import Foundation

enum SidebarVisibility {
    /// Sichtbar nur mit offenem Projekt UND eingeschaltetem Nutzerschalter.
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
