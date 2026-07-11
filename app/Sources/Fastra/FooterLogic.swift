// FooterLogic.swift
//
// Reine (UI-freie) Logik für die Footer-Anzeige: Cursor-/Selektions-
// Position und Dokument-Statistik. Bewusst von den SwiftUI-Views
// getrennt, damit sie unit-testbar ist (siehe FooterLogicTests) — diese
// Berechnungen sind subtil genug, um still zu regredieren.

import Foundation

/// Bestimmt, welche Kante einer Selektion im Footer angezeigt wird.
///
/// `CursorPosition` liefert nur `start` (untere Offset-Kante) und `end`
/// (obere Kante) eines Bereichs, NICHT die Zieh-Richtung. BBEdit zeigt im
/// Footer immer die Kante am Mauszeiger. Dafür merken wir uns die
/// *stillstehende* Kante (Anker) und zeigen die andere (Kopf).
enum CursorFooter {
    struct Resolved: Equatable {
        /// Anzuzeigende Zeile (1-indexed) der bewegten Kante.
        let line: Int
        /// Anzuzeigende Spalte (1-indexed) der bewegten Kante.
        let column: Int
        /// Neuer Anker-Offset für den nächsten Aufruf.
        let anchor: Int
    }

    /// - Parameters:
    ///   - rangeLocation: Start-Offset der Selektion (Zeichen-Index).
    ///   - rangeLength: Länge der Selektion (0 = nur Cursor).
    ///   - startLine/startColumn: Position der unteren Kante (1-indexed).
    ///   - endLine/endColumn: Position der oberen Kante, `nil` ohne Selektion.
    ///   - previousAnchor: Anker aus dem vorherigen Aufruf, `nil` beim Start.
    static func resolve(
        rangeLocation: Int,
        rangeLength: Int,
        startLine: Int,
        startColumn: Int,
        endLine: Int?,
        endColumn: Int?,
        previousAnchor: Int?
    ) -> Resolved {
        let maxLoc = rangeLocation + rangeLength

        // Keine Selektion → reiner Cursor. Anker = aktuelle Position.
        guard rangeLength > 0, let endLine, let endColumn else {
            return Resolved(line: startLine, column: startColumn, anchor: rangeLocation)
        }

        // Beim ersten Frame einer Selektion nehmen wir die untere Kante
        // als Anker an (Kopf unten); zieht der Nutzer nach oben, kippt das.
        let anchor = previousAnchor ?? rangeLocation

        if anchor == maxLoc {
            // Anker oben → bewegte Kante (Kopf) ist unten (`start`).
            return Resolved(line: startLine, column: startColumn, anchor: maxLoc)
        } else {
            // Anker unten → Kopf ist oben (`end`).
            return Resolved(line: endLine, column: endColumn, anchor: rangeLocation)
        }
    }
}

/// Zusammenfassung der Suchergebnisse für den Footer-Anzeigebereich rechts.
///
/// Liefert zwei Strings: den Treffer-Text und das Scope-Label.
/// Gehalten als pure Funktion, damit sie isoliert unit-testbar ist.
enum FooterLogic {

    /// Ergebnis-Tuple für die Footer-Anzeige.
    struct SearchSummary: Equatable {
        /// z.B. „3 Treffer · 2 Dateien", „Keine Treffer", „1 Treffer"
        let text: String
        /// z.B. „Datei" oder „Ordner" — Scope-Label rechts neben dem Treffer-Text.
        let label: String
    }

    /// Berechnet text + label aus den aktuellen Suchzuständen.
    ///
    /// - Parameters:
    ///   - scope: Aktiver Suchbereich (`.file` oder `.folder`).
    ///   - bufferCount: Anzahl Treffer im Buffer-Scope.
    ///   - folderTotal: Gesamtzahl Treffer im Ordner-Scope.
    ///   - folderFiles: Anzahl Dateien mit mindestens einem Treffer im Ordner-Scope.
    static func searchSummary(
        scope: Workspace.SearchScope,
        bufferCount: Int,
        folderTotal: Int,
        folderFiles: Int
    ) -> SearchSummary {
        switch scope {
        case .file:
            let text  = bufferCount == 0
                ? "Keine Treffer"
                : "\(bufferCount) Treffer"
            return SearchSummary(text: text, label: "Datei")

        case .open:
            // „Geöffnete Dateien"-Scope: verhält sich wie Ordner-Scope,
            // zeigt aber kein Datei-Label (nur Treffer-Summe).
            let text = folderTotal == 0
                ? "Keine Treffer"
                : "\(folderTotal) Treffer · \(folderFiles) Dateien"
            return SearchSummary(text: text, label: "Geöffnet")

        case .folder:
            let text: String
            if folderTotal == 0 {
                text = "Keine Treffer"
            } else {
                text = "\(folderTotal) Treffer · \(folderFiles) Dateien"
            }
            return SearchSummary(text: text, label: "Ordner")
        }
    }
}

/// Zeichen-/Wort-/Zeilen-Zählung für die Footer-Statistik.
enum DocumentStats {
    struct Counts: Equatable {
        let characters: Int
        let words: Int
        let lines: Int
    }

    /// Zählt Zeichen, Wörter und Zeilen eines Textes. Leerer Text → alles 0,
    /// aber 1 Zeile (eine leere Zeile), passend zu Editor-Erwartungen.
    static func counts(of text: some StringProtocol) -> Counts {
        let chars = text.count
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        return Counts(characters: chars, words: words, lines: lines)
    }

    /// Formatiert Counts als „chars / words / lines".
    static func format(_ c: Counts) -> String {
        "\(c.characters) / \(c.words) / \(c.lines)"
    }
}
