// EditorViewMode.swift
//
// Ansichts-Umschalter Text/Vorschau/Hex (Etappe 2 Wunschpaket 2026-07).
// Reine, UI-unabhängige Routing-Logik: Welche Ansichten bietet eine Datei
// an, und welche gilt standardmäßig? Die Views werten das nur aus.

import Foundation

/// Vom Nutzer wählbare Ansicht eines Tabs. Unabhängig vom Lade-Ergebnis
/// (`EditorDisplayMode`): Der Loader entscheidet, WIE die Datei gelesen
/// wurde; der ViewMode entscheidet, WIE sie gerade angezeigt wird.
enum EditorViewMode: String, CaseIterable, Equatable, Hashable {
    case text
    case preview
    case hex

    /// Beschriftung im Umschalter und in den Menüpunkten.
    var title: String {
        switch self {
        case .text:    return L10n.string("Text")
        case .preview: return L10n.string("Vorschau")
        case .hex:     return L10n.string("Hex")
        }
    }
}

/// Entscheidet pro Dateityp über verfügbare Ansichten und Standardansicht.
enum ViewModeRouting {
    /// Bildformate mit Read-only-Vorschau über ImageIO (Downsampling).
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "webp",
    ]
    /// SVG ist Text (XML), bekommt aber standardmäßig die Vorschau.
    static let svgExtensions: Set<String> = ["svg"]
    /// PDF-Vorschau über PDFKit.
    static let pdfExtensions: Set<String> = ["pdf"]

    /// Kleingeschriebene Endung einer Datei-URL (`nil` → leer).
    static func normalizedExtension(_ fileExtension: String?) -> String {
        (fileExtension ?? "").lowercased()
    }

    /// Verfügbare Ansichten in Umschalter-Reihenfolge.
    ///
    /// - Ungespeicherte Tabs (`hasURL == false`) haben nur den Editor:
    ///   Vorschau und Hex lesen von der Platte und brauchen eine Datei.
    /// - SVG: Text (Quelltext editierbar), Vorschau (gerendert), Hex.
    /// - Bilder/PDF: Vorschau und Hex — ein Text-Editor über Binärdaten
    ///   wäre eine stille Verfälschung.
    /// - Sonstige Textdateien (auch abschnittsweise große): Text und Hex.
    /// - Erkannte Binärdateien: nur Hex (wie bisher).
    static func availableModes(fileExtension: String?,
                               loadedDisplayMode: EditorDisplayMode,
                               hasURL: Bool) -> [EditorViewMode] {
        guard hasURL else { return [.text] }
        let ext = normalizedExtension(fileExtension)
        if svgExtensions.contains(ext) { return [.text, .preview, .hex] }
        if imageExtensions.contains(ext) || pdfExtensions.contains(ext) {
            return [.preview, .hex]
        }
        switch loadedDisplayMode {
        case .text, .chunkedText: return [.text, .hex]
        case .hex:                return [.hex]
        }
    }

    /// Standardansicht, solange der Nutzer nichts umgeschaltet hat:
    /// Bild/PDF/SVG → Vorschau; erkannte Binärdatei → Hex; sonst Text.
    static func defaultMode(fileExtension: String?,
                            loadedDisplayMode: EditorDisplayMode,
                            hasURL: Bool) -> EditorViewMode {
        guard hasURL else { return .text }
        let ext = normalizedExtension(fileExtension)
        if svgExtensions.contains(ext) || imageExtensions.contains(ext)
            || pdfExtensions.contains(ext) {
            return .preview
        }
        return loadedDisplayMode == .hex ? .hex : .text
    }

    /// Effektive Ansicht eines Tabs: manuelle Wahl gewinnt, muss aber zu den
    /// verfügbaren Ansichten gehören (sonst Standard — schützt z. B. nach
    /// „Speichern unter" mit neuer Endung vor einer unpassenden Alt-Wahl).
    static func effectiveMode(chosen: EditorViewMode?,
                              fileExtension: String?,
                              loadedDisplayMode: EditorDisplayMode,
                              hasURL: Bool) -> EditorViewMode {
        let modes = availableModes(fileExtension: fileExtension,
                                   loadedDisplayMode: loadedDisplayMode,
                                   hasURL: hasURL)
        if let chosen, modes.contains(chosen) { return chosen }
        return defaultMode(fileExtension: fileExtension,
                           loadedDisplayMode: loadedDisplayMode,
                           hasURL: hasURL)
    }
}
