// MainWindowTitleTests.swift
//
// Sichert die Daten ab, aus denen AppKit Fenstertitel, Datei-Icon und das
// native Command-Klick-Pfadmenü erzeugt. Die eigentliche Menü-Darstellung ist
// AppKit-Verhalten und wird deshalb zusätzlich im gebauten Programm geprüft.

import Foundation
import Testing
@testable import Fastra

@Test("Gespeicherter Tab liefert Dateiname, URL und Bearbeitungszustand")
func savedTabProvidesNativeWindowMetadata() {
    let url = URL(fileURLWithPath: "/tmp/Tests/Personen.txt")
    let tab = EditorTab(
        title: "Personen.txt",
        path: url.path,
        url: url,
        isDirty: true
    )

    let metadata = MainWindowTitleMetadata.from(tab)
    #expect(metadata.title == "Personen.txt")
    #expect(metadata.representedURL == url)
    #expect(metadata.isDocumentEdited)
}

@Test("Ungespeicherter Tab hat Titel, aber kein Pfadmenü")
func unsavedTabHasNoRepresentedURL() {
    let tab = EditorTab(title: "Ohne Titel", path: "—")
    let metadata = MainWindowTitleMetadata.from(tab)

    #expect(metadata.title == "Ohne Titel")
    #expect(metadata.representedURL == nil)
    #expect(!metadata.isDocumentEdited)
}

@Test("Ohne aktiven Tab bleibt der App-Name als Fenstertitel")
func missingTabFallsBackToAppName() {
    let metadata = MainWindowTitleMetadata.from(nil)
    #expect(metadata.title == "Fastra")
    #expect(metadata.representedURL == nil)
}

@Test("Willkommen-Zustand zeigt Version+Datum statt Dateiname, kein Pfadmenü")
func welcomeStateShowsVersionTitleNotUntitled() {
    // Selbst wenn der (leere) Start-Tab „Ohne Titel" heißt: im Willkommen-
    // Zustand zeigt die Titelzeile Version + Datum (es ist noch keine Datei).
    // Der Titel wird injiziert, damit die pure Umwandlung ohne echtes Bundle
    // testbar bleibt (im Programm liefert ihn `AppInfo.welcomeWindowTitle`).
    let tab = EditorTab(title: "Ohne Titel", path: "noch nicht gespeichert")
    let metadata = MainWindowTitleMetadata.from(tab, welcomeActive: true,
                                                welcomeTitle: "Fastra v1.6.2 2026-07-12")
    #expect(metadata.title == "Fastra v1.6.2 2026-07-12")
    #expect(metadata.representedURL == nil)
    #expect(!metadata.isDocumentEdited)
}
