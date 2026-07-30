import CoreGraphics

/// Spaltenbreite der zweispaltigen Diff-Ansicht.
///
/// Vorher bekamen beide Zellen `maxWidth: .infinity` und teilten sich damit die
/// sichtbare Breite, während der Text darin auf seiner vollen Idealbreite
/// bestand (`fixedSize`). Ergebnis: Jede Zeile, die breiter als eine halbe
/// Fensterbreite war, wurde über die Spaltengrenze hinaus gezeichnet und
/// überschrieb die andere Seite (Daniel-Befund 2026-07-30 am Gesamt-Diff).
///
/// Beide Spalten sind jetzt gleich breit und teilen sich die sichtbare Fläche;
/// zu langer Text bricht INNERHALB seiner Spalte um. Damit bleiben immer beide
/// Seiten nebeneinander sichtbar, die Trennlinie ist über alle Zeilen gerade,
/// und es geht kein Zeichen verloren — eine Kürzung mit „…" hätte im Diff
/// gerade das Zeilenende verschwiegen, auf das es oft ankommt.
enum DiffColumnLayout {
    /// Breite der Zeilennummern-Spalte innerhalb einer Zelle.
    static let numberWidth: CGFloat = 44
    /// Abstand zwischen Zeilennummer und Text.
    static let numberSpacing: CGFloat = 6
    /// Innenabstand der Zelle je Seite.
    static let cellPadding: CGFloat = 5
    /// Freiraum am Textende, damit das letzte Zeichen nicht am Trenner klebt.
    static let trailingGap: CGFloat = 8
    /// Untergrenze wie bisher — ein schmales Fenster soll die Spalten nicht
    /// unlesbar zusammenquetschen, dann wird die Fläche horizontal scrollbar.
    static let minimumColumnWidth: CGFloat = 459

    /// Breite EINER Spalte: die Hälfte der sichtbaren Fläche (der 1 pt breite
    /// Trenner geht vorher ab), mindestens aber die Untergrenze.
    static func columnWidth(availableWidth: CGFloat) -> CGFloat {
        max((availableWidth - 1) / 2, minimumColumnWidth)
    }

    /// Gesamtbreite einer Diff-Zeile: beide Spalten plus Trenner. Auch die
    /// Dekorationszeilen (Dateikopf, Hunk, Lücke, Hinweis) nutzen sie, damit
    /// ihr Hintergrund nicht mitten in der Fläche endet.
    static func rowWidth(columnWidth: CGFloat) -> CGFloat {
        columnWidth * 2 + 1
    }
}
