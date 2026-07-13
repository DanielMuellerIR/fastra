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
}
