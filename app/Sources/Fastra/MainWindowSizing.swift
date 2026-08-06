import CoreGraphics

/// Gemeinsame Größenregeln für das SwiftUI-Hauptfenster und zusätzliche
/// AppKit-Dokumentfenster. Ein einziger Satz Werte verhindert, dass ⌘N ein
/// kleineres oder anders begrenztes Fenster als der normale App-Start erzeugt.
enum MainWindowSizing {
    static let minimumWidth: CGFloat = 760
    static let minimumHeight: CGFloat = 400
    static let defaultWidth: CGFloat = 1100
    static let defaultHeight: CGFloat = 720

    /// Anteil der nutzbaren Bildschirmhöhe, den ein NEUES Fenster mindestens
    /// einnimmt. Die feste Starthöhe von 720 Punkten war auf einem aktuellen
    /// 15-Zoll-Notebook deutlich zu flach; gearbeitet wird im Editor fast
    /// immer in der Höhe (Daniel-Wunsch 2026-08-06). Kleiner ziehen darf der
    /// Nutzer das Fenster weiterhin bis `minimumHeight` — diese Größe gilt
    /// nur für Fenster, die ohne Vorbild neu entstehen.
    static let newWindowHeightShare: CGFloat = 0.8

    /// Startgröße eines Fensters ohne Vorbild, gemessen am nutzbaren Bereich
    /// des Zielbildschirms (`NSScreen.visibleFrame`, also ohne Menüleiste und
    /// Dock). Die Breite bleibt bei den bewährten 1100 Punkten, solange der
    /// Bildschirm so breit ist.
    static func newWindowSize(inVisibleScreen visible: CGSize) -> CGSize {
        let height = min(max(defaultHeight, visible.height * newWindowHeightShare),
                         max(visible.height, minimumHeight))
        let width = min(max(defaultWidth, minimumWidth),
                        max(visible.width, minimumWidth))
        return CGSize(width: width, height: height)
    }

    /// Mittig auf dem nutzbaren Bereich platzierte Startgröße.
    static func newWindowFrame(inVisibleScreen visible: CGRect) -> CGRect {
        let size = newWindowSize(inVisibleScreen: visible.size)
        return CGRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Einmalige Korrektur eines zu flach gespeicherten Rahmens: Ein Fenster
    /// unterhalb der praktischen Starthöhe wächst auf diese Höhe, behält dabei
    /// seine Oberkante und bleibt vollständig im nutzbaren Bereich. Ist es
    /// schon hoch genug, bleibt der Rahmen unverändert.
    ///
    /// AppKit-Koordinaten: y wächst nach OBEN, `maxY` ist die Oberkante.
    static func heightNormalizedFrame(_ frame: CGRect,
                                      inVisibleScreen visible: CGRect) -> CGRect {
        let target = newWindowSize(inVisibleScreen: visible.size).height
        guard frame.height < target else { return frame }
        let height = min(target, max(visible.height, minimumHeight))
        let top = frame.maxY
        let y = min(max(top - height, visible.minY), max(visible.maxY - height, visible.minY))
        return CGRect(x: frame.origin.x, y: y, width: frame.width, height: height)
    }

    /// Übernimmt Größe und Position des Vorderfensters. Die Startgröße gilt
    /// nur für das erste Fenster; ⌘N soll die zuletzt vom Nutzer gewählte
    /// Größe nicht still auf einen größeren Standardwert zurücksetzen.
    static func cascadedFrame(from front: CGRect) -> CGRect {
        CGRect(
            x: front.origin.x + 24,
            y: front.origin.y - 24,
            width: front.width,
            height: front.height
        )
    }

    /// Vertikale Position eines nativen Ampelknopfs innerhalb seiner AppKit-
    /// Titelleisten-View. Fastras sichtbarer Chrome kann durch den UI-Zoom
    /// höher als die native 28-Punkte-Titelleiste sein; der Knopf rückt dann
    /// so weit wie möglich zur Mitte des sichtbaren Chromes nach unten.
    static func trafficLightOriginY(superviewHeight: CGFloat,
                                    buttonHeight: CGFloat,
                                    chromeHeight: CGFloat,
                                    isFlipped: Bool) -> CGFloat {
        let desired: CGFloat
        if isFlipped {
            desired = chromeHeight / 2 - buttonHeight / 2
        } else {
            desired = superviewHeight - chromeHeight / 2 - buttonHeight / 2
        }
        return min(max(desired, 0), max(0, superviewHeight - buttonHeight))
    }
}
