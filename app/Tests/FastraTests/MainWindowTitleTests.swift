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
