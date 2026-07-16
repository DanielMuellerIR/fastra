import Foundation

/// Reine Berechnung für persistente Splitter. Entscheidend ist die beim
/// Ziehbeginn gemerkte Breite; `DragGesture.translation` ist bereits die
/// gesamte Strecke. Würde man sie auf die fortlaufend geänderte Breite
/// addieren, würde der Splitter bei jedem Event weiter springen.
enum SplitterSizing {
    static func width(start: Double, translation: Double, direction: Double,
                      minimum: Double, maximum: Double) -> Double {
        min(max(start + translation * direction, minimum), maximum)
    }

    /// Wie breit der rechte Bereich (die Markdown-Vorschau) höchstens werden
    /// darf, damit dem linken Bereich (dem Dokumentinhalt) noch
    /// `minimumLeading` bleibt.
    ///
    /// Eine feste Obergrenze wäre hier falsch: Sie hindert den Nutzer daran,
    /// den Editor per Splitter so schmal zu ziehen, wie das Fenster es beim
    /// Verkleinern ohnehin zulässt. Ist das Fenster zu schmal für beide
    /// Mindestbreiten, gewinnt `minimumTrailing` — der Splitter bleibt dann
    /// unbeweglich, statt eine negative Breite zu erzeugen.
    static func trailingMaximum(total: Double, occupiedLeading: Double,
                                splitter: Double, minimumLeading: Double,
                                minimumTrailing: Double) -> Double {
        max(minimumTrailing, total - occupiedLeading - splitter - minimumLeading)
    }
}
