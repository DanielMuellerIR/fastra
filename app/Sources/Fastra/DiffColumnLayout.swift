import CoreGraphics

/// Spaltenbreite der zweispaltigen Diff-Ansicht.
///
/// Vorher bekamen beide Zellen `maxWidth: .infinity` und teilten sich damit die
/// sichtbare Breite, während der Text darin auf seiner vollen Idealbreite
/// bestand (`fixedSize`). Ergebnis: Jede Zeile, die breiter als eine halbe
/// Fensterbreite war, wurde über die Spaltengrenze hinaus gezeichnet und
/// überschrieb die andere Seite (Daniel-Befund 2026-07-30 am Gesamt-Diff).
///
/// Beide Spalten teilen sich seither die sichtbare Fläche, und die Trennlinie
/// ist über alle Zeilen gerade. Seit 2026-09-09 ist die Teilung nicht mehr
/// starr halbe-halbe, sondern ein vom Nutzer gezogenes Verhältnis: Wer links
/// lange Zeilen liest, gibt der linken Seite mehr Platz, ohne das Fenster zu
/// verbreitern. Die Rechnung liegt bewusst hier und nicht in der Ansicht —
/// so ist sie ohne Fenster prüfbar.
enum DiffColumnLayout {
    /// Breite der Zeilennummern-Spalte innerhalb einer Zelle.
    static let numberWidth: CGFloat = 44
    /// Abstand zwischen Zeilennummer und Text.
    static let numberSpacing: CGFloat = 6
    /// Innenabstand der Zelle je Seite.
    static let cellPadding: CGFloat = 5
    /// Freiraum am Textende, damit das letzte Zeichen nicht am Trenner klebt.
    static let trailingGap: CGFloat = 8
    /// Breite der Trennlinie zwischen beiden Spalten.
    static let dividerWidth: CGFloat = 1
    /// Untergrenze wie bisher — ein schmales Fenster soll die Spalten nicht
    /// unlesbar zusammenquetschen, dann wird die Fläche horizontal scrollbar.
    static let minimumColumnWidth: CGFloat = 459
    /// Untergrenze EINER Spalte beim Ziehen des Splitters. Sie ist bewusst
    /// viel kleiner als `minimumColumnWidth`: Wer den Trenner selbst zieht,
    /// will eine Seite absichtlich schmal machen — sie darf nur nicht ganz
    /// verschwinden, sonst wäre der Trenner nicht mehr zurückzuholen.
    static let minimumPaneWidth: CGFloat = 96
    /// Werksteilung: exakt halbe-halbe wie vor dem Splitter.
    static let defaultRatio: CGFloat = 0.5
    /// Schlüssel der gemerkten Teilung. Sie gilt bewusst für ALLE Vergleiche:
    /// Wer sich die Aufteilung einmal eingestellt hat, will sie im nächsten
    /// Diff wiederfinden, nicht je Tab neu ziehen.
    static let splitRatioDefaultsKey = "diff.splitRatio"
    /// Greifbreite des Splitters. Eine 1 pt schmale Linie träfe man nicht.
    static let splitterHitWidth: CGFloat = 9

    /// Gesamtbreite der Diff-Fläche: die sichtbare Breite, mindestens aber
    /// zwei Spalten Untergrenze plus Trenner. Darunter scrollt die Fläche
    /// horizontal, statt die Spalten weiter zu quetschen.
    static func contentWidth(availableWidth: CGFloat) -> CGFloat {
        max(availableWidth, minimumColumnWidth * 2 + dividerWidth)
    }

    /// Für die Spalten verfügbare Breite (Gesamtfläche ohne Trenner).
    static func usableWidth(contentWidth: CGFloat) -> CGFloat {
        max(0, contentWidth - dividerWidth)
    }

    /// Breite der LINKEN Spalte bei gegebenem Teilungsverhältnis.
    /// Bewusst ungerundet: Bei `defaultRatio` müssen beide Seiten auf den
    /// Punkt gleich breit sein, sonst stünde die Trennlinie schief.
    static func leadingWidth(contentWidth: CGFloat, ratio: CGFloat) -> CGFloat {
        let usable = usableWidth(contentWidth: contentWidth)
        // Zu schmal für zwei Mindestspalten: dann bleibt nur die Halbierung.
        guard usable > minimumPaneWidth * 2 else { return usable / 2 }
        let raw = usable * min(max(ratio, 0), 1)
        return min(max(raw, minimumPaneWidth), usable - minimumPaneWidth)
    }

    /// Breite der RECHTEN Spalte — der Rest, damit beide Spalten plus Trenner
    /// exakt die Gesamtfläche ergeben und rechts kein Streifen frei bleibt.
    static func trailingWidth(contentWidth: CGFloat, ratio: CGFloat) -> CGFloat {
        usableWidth(contentWidth: contentWidth)
            - leadingWidth(contentWidth: contentWidth, ratio: ratio)
    }

    /// Verhältnis aus einer gezogenen absoluten Splitter-Position. Nur auf
    /// 0…1 begrenzt; die Mindestbreite einer Spalte setzt erst `leadingWidth`
    /// durch. So merkt sich der gespeicherte Wert einen Zug bis an den Rand,
    /// und ein breiteres Fenster gibt der Seite später wieder mehr Platz.
    static func ratio(forLeadingWidth width: CGFloat,
                      contentWidth: CGFloat) -> CGFloat {
        let usable = usableWidth(contentWidth: contentWidth)
        guard usable > 0 else { return defaultRatio }
        return min(max(width / usable, 0), 1)
    }

    /// Anteil der linken Spalte in Prozent, wie er WIRKLICH zu sehen ist.
    /// `ratio` allein taugt dafür nicht: Es ist nur auf 0…1 begrenzt, die
    /// Mindestbreite von 96 pt setzt erst `leadingWidth` durch. Ein Zug bis an
    /// den Anschlag merkt sich also 0, sichtbar bleiben aber rund 10 Prozent.
    static func visibleLeadingPercent(contentWidth: CGFloat, ratio: CGFloat) -> Int {
        let usable = usableWidth(contentWidth: contentWidth)
        guard usable > 0 else { return Int((defaultRatio * 100).rounded()) }
        let leading = leadingWidth(contentWidth: contentWidth, ratio: ratio)
        return Int((leading / usable * 100).rounded())
    }

    /// Verhältnis nach EINEM Schritt der VoiceOver-Bedienung.
    ///
    /// Gerechnet wird vom SICHTBAREN Stand aus und im sichtbaren Bereich
    /// geklemmt. Vom gespeicherten Rohwert aus liefe die Bedienung sonst in
    /// eine Totzone: Ein Zug bis an den Anschlag merkt sich 0, sichtbar bleiben
    /// aber 96 pt (rund 10 Prozent) — die ersten zwei Schritte „mehr Platz
    /// links" bewegten dann gar nichts.
    static func adjustedRatio(contentWidth: CGFloat, ratio: CGFloat,
                              by step: CGFloat) -> CGFloat {
        let usable = usableWidth(contentWidth: contentWidth)
        guard usable > minimumPaneWidth * 2 else { return defaultRatio }
        let visible = leadingWidth(contentWidth: contentWidth, ratio: ratio) / usable
        let lower = minimumPaneWidth / usable
        return min(max(visible + step, lower), 1 - lower)
    }

    /// Mitte der Trennlinie in Flächenkoordinaten — Zeichen- und Greifpunkt
    /// des Splitters.
    static func splitterCenterX(contentWidth: CGFloat, ratio: CGFloat) -> CGFloat {
        leadingWidth(contentWidth: contentWidth, ratio: ratio) + dividerWidth / 2
    }
}
