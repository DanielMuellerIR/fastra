import CoreGraphics

/// Gemeinsame Größenregeln für das SwiftUI-Hauptfenster und zusätzliche
/// AppKit-Dokumentfenster. Ein einziger Satz Werte verhindert, dass ⌘N ein
/// kleineres oder anders begrenztes Fenster als der normale App-Start erzeugt.
enum MainWindowSizing {
    static let minimumWidth: CGFloat = 760
    static let minimumHeight: CGFloat = 400
    static let defaultWidth: CGFloat = 1100
    static let defaultHeight: CGFloat = 720

    /// Übernimmt Größe und Position des Vorderfensters, klemmt aber alte oder
    /// ungewöhnlich kleine gespeicherte Frames auf die bedienbare Mindestgröße.
    static func cascadedFrame(from front: CGRect) -> CGRect {
        CGRect(
            x: front.origin.x + 24,
            y: front.origin.y - 24,
            width: max(front.width, minimumWidth),
            height: max(front.height, minimumHeight)
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
