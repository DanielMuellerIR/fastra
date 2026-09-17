//
// MenuLabelFit.swift
//
// Kürzt dynamische Menü-Beschriftungen auf eine feste Zeichenzahl. Die
// Vorlagen- und Datei-Set-Menüs der Suchmaske stehen mit `.fixedSize()` in
// einer Zeile mit den Eingabefeldern; ein beliebig langer, vom Nutzer
// vergebener Name würde sonst das Suchen- bzw. Ersetzen-Feld bis zur
// Unbedienbarkeit zusammenschieben (Review-Fund 2026-09-16). Der volle Name
// bleibt lesbar: bei Vorlagen in der aufgeklappten Menüliste und im
// Verwalten-Dialog, beim aktiven Datei-Set im Tooltip des Pickers.

import Foundation

enum MenuLabelFit {
    /// Höchstzahl Zeichen für die Beschriftung des Vorlagenmenüs.
    static let templateLabelCharacters = 24
    /// Höchstzahl Zeichen für die Einträge des Datei-Set-Menüs.
    static let fileSetLabelCharacters = 28

    /// Kürzt `text` mittig auf höchstens `maxCharacters` Zeichen; die Kürzung
    /// zeigt Anfang und Ende („Sehr lang…Name“), weil Nutzer eigene Namen
    /// oft an beiden Enden unterscheiden. Kurze Texte bleiben unverändert.
    static func shortened(_ text: String, maxCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxCharacters >= 3, trimmed.count > maxCharacters else { return trimmed }
        // Ein Zeichen für die Ellipse; der Rest je zur Hälfte an Anfang und Ende,
        // bei ungerader Zahl bekommt der Anfang das zusätzliche Zeichen.
        let keep = maxCharacters - 1
        let head = (keep + 1) / 2
        let tail = keep - head
        return String(trimmed.prefix(head)) + "…" + String(trimmed.suffix(tail))
    }
}
