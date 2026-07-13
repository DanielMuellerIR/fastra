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

    // MARK: Git-Status (Etappe 2)

    /// Git-Status-Farben (VS-Code-Sprache, Daniel-Wunsch 2026-07-12): geändert =
    /// Orange, nicht versioniert = Blau, gelöscht/Konflikt = Rot, neu bereit-
    /// gestellt = Grün. Eigene, kontraststarke Tokens statt der Diff-Palette.
    static let gitModified  = dynamic(light: rgb(0xB5, 0x6C, 0x1A), dark: rgb(0xDF, 0xA2, 0x5A)) // orange
    static let gitUntracked = dynamic(light: rgb(0x2A, 0x66, 0xB5), dark: rgb(0x7F, 0xB0, 0xEE)) // blau

    /// Farbe für die Einfärbung eines Datei-Git-Zustands in der Seitenleiste.
    static func gitColor(for state: GitFileState) -> Color {
        switch state {
        case .modified, .renamed:   return gitModified
        case .untracked:            return gitUntracked
        case .added:                return diffAddedFG
        case .deleted, .conflicted: return diffRemovedFG
        }
    }

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

    // Schriftgrößen liegen absichtlich NICHT mehr als fertige `Font`-Werte
    // hier. Ein fertiger Font kann den Skalierungsfaktor aus dem SwiftUI-
    // Environment nicht sehen. `FastraFontModifier` weiter unten baut ihn
    // deshalb erst an der verwendenden View aus Rolle + Faktor zusammen.
}

// MARK: - Globale UI-Skalierung

/// Persistente Zoomstufe der gesamten Fastra-Oberfläche.
///
/// Eine diskrete Stufe ist stabiler als ein frei gespeicherter Double-Wert:
/// wiederholtes Vergrößern/Verkleinern sammelt keine Rundungsfehler an und
/// ⌘0 besitzt immer einen eindeutig definierten Ausgangspunkt.
enum UIZoom {
    static let defaultsKey = "ui.zoomLevel"
    static let minimumLevel = -3
    static let maximumLevel = 5
    static let step: CGFloat = 0.13

    static func clamped(_ level: Int) -> Int {
        min(max(level, minimumLevel), maximumLevel)
    }

    static func scale(for level: Int) -> CGFloat {
        1 + CGFloat(clamped(level)) * step
    }
}

/// Vom UI-Zoom unabhängige Größe des Dokumentinhalts. Damit bleiben Menüs
/// und Seitenleisten lesbar, wenn nur der Quelltext mehr oder weniger Platz
/// braucht (⇧⌘+/−/0).
enum DocumentZoom {
    static let defaultsKey = "editor.documentZoomLevel"
    static let minimumLevel = -4
    static let maximumLevel = 8
    static let step: CGFloat = 0.12
    static func clamped(_ level: Int) -> Int { min(max(level, minimumLevel), maximumLevel) }
    static func scale(for level: Int) -> CGFloat { 1 + CGFloat(clamped(level)) * step }
}

enum EditorFonts {
    static let defaultsKey = "editor.fontName"
    static let systemMonospacedName = "SFMono-Regular"
    static func monospacedNames(current: String) -> [String] {
        let preferred = [current] + [systemMonospacedName, "Menlo-Regular", "Monaco", "Courier"]
            .filter { NSFont(name: $0, size: 12)?.isFixedPitch == true }
        let all = NSFontManager.shared.availableFontFamilies.reduce(into: [String]()) { names, family in
            for member in NSFontManager.shared.availableMembers(ofFontFamily: family) ?? [] {
                guard let name = member[0] as? String,
                      NSFont(name: name, size: 12)?.isFixedPitch == true else { continue }
                names.append(name)
            }
        }.sorted()
        return orderedUnique(preferred + all)
    }
}

enum PreviewFonts {
    static let defaultsKey = "markdown.previewFontName"
    static let systemName = ".AppleSystemUIFont"
    static func readingNames(current: String) -> [String] {
        let preferred = [current, systemName] + ["NewYork", "Georgia", "Palatino-Roman"]
            .filter { NSFont(name: $0, size: 12)?.isFixedPitch == false }
        let all = NSFontManager.shared.availableFontFamilies.reduce(into: [String]()) { names, family in
            for member in NSFontManager.shared.availableMembers(ofFontFamily: family) ?? [] {
                guard let name = member[0] as? String,
                      NSFont(name: name, size: 12)?.isFixedPitch == false else { continue }
                names.append(name)
            }
        }.sorted()
        return orderedUnique(preferred + all)
    }
}

private func orderedUnique(_ names: [String]) -> [String] {
    var seen = Set<String>()
    return names.filter { seen.insert($0).inserted }
}

private struct UIScaleEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// Zentraler Faktor für SwiftUI- und eingebettete AppKit-Oberflächen.
    var uiScale: CGFloat {
        get { self[UIScaleEnvironmentKey.self] }
        set { self[UIScaleEnvironmentKey.self] = newValue }
    }
}

/// Semantische Schriftrollen statt verteilter fester Punktgrößen.
enum FastraFontRole {
    case ui
    case small
    case mono
    case monoSmall
    case headline

    fileprivate var size: CGFloat {
        switch self {
        case .ui, .mono: return 13
        case .small, .monoSmall: return 11
        case .headline: return 15
        }
    }

    fileprivate var weight: Font.Weight {
        self == .headline ? .semibold : .regular
    }

    fileprivate var design: Font.Design {
        switch self {
        case .mono, .monoSmall: return .monospaced
        default: return .default
        }
    }
}

private struct FastraFontModifier: ViewModifier {
    @Environment(\.uiScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

/// Wurzel-Modifikator für eigenständige Fenster und Panels. Er liest dieselbe
/// AppStorage-Stufe wie die Menübefehle und reicht den daraus berechneten Faktor
/// per Environment weiter. Die diskrete `controlSize` lässt native SwiftUI-
/// Controls passend zur Schrift mitwachsen beziehungsweise schrumpfen.
private struct FastraScalingRootModifier: ViewModifier {
    @AppStorage(UIZoom.defaultsKey) private var zoomLevel = 0

    private var scale: CGFloat { UIZoom.scale(for: zoomLevel) }
    private var controlSize: ControlSize {
        if scale < 0.9 { return .small }
        if scale > 1.25 { return .large }
        return .regular
    }

    func body(content: Content) -> some View {
        content
            .environment(\.uiScale, scale)
            .controlSize(controlSize)
    }
}

extension View {
    /// Semantische Fastra-Schrift, die automatisch auf ⌘+/−/0 reagiert.
    func fastraFont(_ role: FastraFontRole) -> some View {
        modifier(FastraFontModifier(size: role.size,
                                    weight: role.weight,
                                    design: role.design))
    }

    /// Skalierbarer Sonderfont für Icons, Badges und bewusst abweichende Titel.
    func fastraFont(size: CGFloat,
                    weight: Font.Weight = .regular,
                    design: Font.Design = .default) -> some View {
        modifier(FastraFontModifier(size: size, weight: weight, design: design))
    }

    /// Versorgt eine eigenständige SwiftUI-View-Hierarchie mit dem UI-Faktor.
    func fastraScalingRoot() -> some View {
        modifier(FastraScalingRootModifier())
    }
}

extension NSFont {
    /// AppKit-Gegenstück zu `fastraFont`: NSTextView und SourceEditor erhalten
    /// denselben Faktor wie die umgebende SwiftUI-Oberfläche.
    static func fastraMonospaced(size: CGFloat, scale: CGFloat,
                                 weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size * scale, weight: weight)
    }

    static func fastraEditorFont(name: String, size: CGFloat, scale: CGFloat) -> NSFont {
        let requested = NSFont(name: name, size: size * scale)
        return (requested?.isFixedPitch == true ? requested : nil)
            ?? .monospacedSystemFont(ofSize: size * scale, weight: .regular)
    }
}
