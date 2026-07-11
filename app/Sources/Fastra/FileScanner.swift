// FileScanner.swift
//
// Bausteine für die Datei-Suche und die (noch kommende) Apply-Logik in
// v0.6. Bewusst klein und pur gehalten, damit jedes Stück einzeln testbar
// ist — die Apply-Logik selbst kommt ERST, wenn die Sicherheits-Tests
// stehen (siehe AGENTS.md, „Hartes Gate für die Apply-Logik").

import Foundation

enum FileScanner {
    /// Fenstergröße für die Binär-Heuristik. Git verwendet 8000 Bytes;
    /// das übernehmen wir — groß genug, um Text sicher zu erkennen, klein
    /// genug, um nicht ganze Dateien zu lesen.
    static let binarySniffWindow = 8000

    /// Heuristik: enthält der Anfang der Daten ein Null-Byte (`0x00`),
    /// behandeln wir die Datei als binär. Das ist dieselbe simple, robuste
    /// Regel, die auch Git nutzt — Textdateien (egal welches Encoding außer
    /// UTF-16/32 mit eingebetteten Nullen) haben keine Null-Bytes.
    ///
    /// ACHTUNG für später: UTF-16/UTF-32-kodierter Text enthält Null-Bytes
    /// und würde hier als „binär" gelten. Beim Öffnen/Suchen muss deshalb
    /// zuerst eine BOM-/Encoding-Erkennung laufen; erst der Rest geht in
    /// diese Heuristik. Für den Binär-SCHUTZ (nichts kaputt machen) ist die
    /// konservative Seite ohnehin richtig: im Zweifel nicht anfassen.
    static func isBinary(_ data: Data) -> Bool {
        let window = data.prefix(binarySniffWindow)
        return window.contains(0x00)
    }

    /// Wie `isBinary(_:)`, aber liest nur das nötige Fenster von der Platte —
    /// ohne die ganze (potenziell große) Datei in den Speicher zu ziehen.
    /// Gibt `nil` zurück, wenn die Datei nicht lesbar ist.
    static func isBinaryFile(at url: URL) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: binarySniffWindow)) ?? Data()
        return head.contains(0x00)
    }
}
