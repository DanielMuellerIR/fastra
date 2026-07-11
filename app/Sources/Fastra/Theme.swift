import SwiftUI
import AppKit

/// Design Tokens — Moodboard A "Solo-Profi".
///
/// Seit v1.1 sind alle Farb-Tokens DYNAMISCH: jede Farbe trägt eine helle
/// und eine dunkle Ausprägung und löst sich zur Zeichenzeit über die
/// effektive Appearance des Fensters auf (`NSColor(name:dynamicProvider:)`).
/// Damit folgt das gesamte UI automatisch dem Erscheinungsbild — gesteuert
/// über `AppearanceSetting` (Einstellungen → Erscheinungsbild).
///
/// Dark-Palette: warmes Dunkel passend zum Cream/Ink/Gold-Light-Theme —
/// Flächen leicht warm abgetönt (kein reines Schwarz/Blau), Text als warmes
/// Off-White, Goldgelb bleibt unverändert der Marken-Akzent (leuchtet auf
/// dunklem Grund von selbst).
///
/// WICHTIG: Die CESE-Editor-Themes (`EditorView.fastraTheme[Dark]`) nutzen
/// diese dynamischen Farben bewusst NICHT — CodeEditSourceEditors Minimap
/// ruft `brightnessComponent` auf Theme-Farben auf, was auf Provider-Farben
/// (kein komponentenbasierter Colorspace) crashen würde. Der Editor bekommt
/// zwei statische sRGB-Themes und schaltet per `colorScheme` um.
enum Theme {
    // MARK: Dynamik-Helfer

    /// Baut eine SwiftUI-Farbe, die sich je nach effektiver Appearance
    /// (hell/dunkel) zur Zeichenzeit auflöst.
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: dynamicNSColor(light: light, dark: dark))
    }

    /// Dynamische NSColor für AppKit-Verbraucher (z.B. die Token-Färbung im
    /// RegEx-Eingabefeld, `RegexFieldView.color(for:)`). `bestMatch` deckt
    /// auch die Hochkontrast-Varianten (aqua/darkAqua HC) mit ab.
    static func dynamicNSColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// sRGB-Farbe aus 0–255-Komponenten. Immer sRGB, nie Gray-Colorspace
    /// (LESSONS-LEARNED F.6b — `brightnessComponent`-Falle der Minimap).
    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255.0,
                green:   CGFloat(g) / 255.0,
                blue:    CGFloat(b) / 255.0,
                alpha:   a)
    }

    // MARK: Backgrounds

    /// Grundfläche: Cream ↔ warmes, sehr dunkles Grau.
    static let surfaceBase   = dynamic(light: rgb(0xFB, 0xF7, 0xEC), dark: rgb(0x15, 0x16, 0x1B))
    /// Erhöhte Fläche (Editor, Karten): Weiß ↔ eine Stufe heller als Base.
    static let surfaceRaised = dynamic(light: rgb(0xFF, 0xFF, 0xFF), dark: rgb(0x1E, 0x20, 0x26))
    /// Sand-Ton (Sidebar, Zeilen-Highlight): Sand ↔ warmes Anthrazit.
    static let surfaceSand   = dynamic(light: rgb(0xE8, 0xE0, 0xCB), dark: rgb(0x2A, 0x2C, 0x33))
    /// Night (historischer Token aus dem Moodboard, aktuell ungenutzt).
    static let surfaceNight  = Color(nsColor: rgb(0x0E, 0x10, 0x15))

    // MARK: Text

    /// Primärtext: Ink ↔ warmes Off-White.
    static let textPrimary   = dynamic(light: rgb(0x1A, 0x18, 0x10), dark: rgb(0xEC, 0xE7, 0xDB))
    /// Sekundärtext (gedämpft) — beide Richtungen ≥ 4,5:1 auf ihrer Base.
    static let textSecondary = dynamic(light: rgb(0x6C, 0x65, 0x5A), dark: rgb(0xA2, 0x9B, 0x8E))

    // MARK: Accent

    /// Goldgelb — Marken-Akzent, in beiden Modi identisch (Flächen unter
    /// dunklem Text; leuchtet auf dunklem Grund ohne Anpassung).
    static let accent        = Color(nsColor: rgb(0xFF, 0xCC, 0x00))

    /// Lesbares Akzent-Gelb für KLEINE Akzente (Icons, Strokes, Indikator-
    /// Punkte). Hell: dunkles Bernstein (#A07800 ≈ 4,0:1 auf Weiß — das
    /// helle Gold hätte nur ~1,4:1). Dunkel: kräftiges Gold (#E6B800), auf
    /// dunklem Grund von selbst kontraststark.
    static let accentReadable = dynamic(light: rgb(0xA0, 0x78, 0x00), dark: rgb(0xE6, 0xB8, 0x00))

    // MARK: Diff

    static let diffRemovedBG = dynamic(light: rgb(0xF7, 0xE4, 0xE0), dark: rgb(0x46, 0x24, 0x1F))
    static let diffRemovedFG = dynamic(light: rgb(0xA3, 0x39, 0x2A), dark: rgb(0xE8, 0x8D, 0x7C))
    static let diffAddedBG   = dynamic(light: rgb(0xE2, 0xEF, 0xE3), dark: rgb(0x1F, 0x3A, 0x26))
    static let diffAddedFG   = dynamic(light: rgb(0x2F, 0x5D, 0x3A), dark: rgb(0x94, 0xCE, 0x9F))

    // MARK: Token colors (RegEx)

    static let tokenAnchor    = dynamic(light: rgb(0xA3, 0x39, 0x2A), dark: rgb(0xE8, 0x8D, 0x7C))
    static let tokenCharClass = dynamic(light: rgb(0x2A, 0x66, 0xB5), dark: rgb(0x7F, 0xB0, 0xEE))
    static let tokenQuant     = dynamic(light: rgb(0xB5, 0x6C, 0x1A), dark: rgb(0xDF, 0xA2, 0x5A))

    // MARK: Capture-Group-Farben (G1, G2, G3)

    /// Gesättigte Füllfarben mit dunklem Text darauf — funktionieren auf
    /// hellen wie dunklen Flächen, daher bewusst statisch.
    static let groupColors: [Color] = [
        Color(red: 1.00, green: 0.85, blue: 0.20),  // Yellow
        Color(red: 0.35, green: 0.78, blue: 0.78),  // Türkis
        Color(red: 0.65, green: 0.40, blue: 0.85),  // Violett
    ]

    // MARK: Strokes / Borders

    /// Hell: schwarze Hauchlinien. Dunkel: weiße — auf dunklen Flächen ist
    /// eine helle Kante die sichtbare Trennung.
    static let stroke       = dynamic(light: rgb(0, 0, 0, 0.08), dark: rgb(0xFF, 0xFF, 0xFF, 0.10))
    static let strokeStrong = dynamic(light: rgb(0, 0, 0, 0.14), dark: rgb(0xFF, 0xFF, 0xFF, 0.18))

    // MARK: Fonts

    static let uiFont   = Font.system(size: 13, design: .default)
    static let uiSmall  = Font.system(size: 11, design: .default)
    static let monoFont = Font.system(size: 13, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let headline  = Font.system(size: 15, weight: .semibold, design: .default)
}
