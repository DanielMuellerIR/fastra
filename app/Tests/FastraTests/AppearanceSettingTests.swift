import Testing
import AppKit
@testable import Fastra

/// Tests für die Erscheinungsbild-Einstellung (Dark Mode manuell/automatisch)
/// und die beiden CESE-Editor-Themes.
@Suite("Erscheinungsbild (Dark Mode)")
struct AppearanceSettingTests {

    /// Isolierte Defaults-Suite, damit die Tests die echten Nutzer-
    /// Einstellungen nicht anfassen.
    private func freshDefaults() -> UserDefaults {
        let name = "fastra.tests.appearance.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("Default ohne gespeicherten Wert ist Automatisch")
    func defaultIstSystem() {
        #expect(AppearanceSetting.current(defaults: freshDefaults()) == .system)
    }

    @Test("Unbekannter gespeicherter Wert fällt sicher auf Automatisch zurück")
    func unbekannterWertFaelltZurueck() {
        let d = freshDefaults()
        d.set("neon-pink", forKey: AppearanceSetting.defaultsKey)
        #expect(AppearanceSetting.current(defaults: d) == .system)
    }

    @Test("Gespeicherte Werte werden korrekt gelesen")
    func gespeicherteWerte() {
        let d = freshDefaults()
        for setting in AppearanceSetting.allCases {
            d.set(setting.rawValue, forKey: AppearanceSetting.defaultsKey)
            #expect(AppearanceSetting.current(defaults: d) == setting)
        }
    }

    @Test("Appearance-Zuordnung: system→nil, light→aqua, dark→darkAqua")
    func appearanceZuordnung() {
        #expect(AppearanceSetting.system.nsAppearanceName == nil)
        #expect(AppearanceSetting.light.nsAppearanceName == .aqua)
        #expect(AppearanceSetting.dark.nsAppearanceName == .darkAqua)
    }

    @Test("Dunkles Editor-Theme unterscheidet sich vom hellen")
    func editorThemesVerschieden() {
        #expect(EditorView.fastraTheme.background != EditorView.fastraThemeDark.background)
        #expect(EditorView.fastraTheme.text.color != EditorView.fastraThemeDark.text.color)
    }

    @Test("Editor-Theme-Farben sind komponentenbasiert (Minimap-Falle F.6b)")
    func editorThemeFarbenSindRGB() {
        // CESEs MinimapView.setTheme ruft `brightnessComponent` auf den
        // Theme-Farben auf — das wirft auf Gray-Colorspace- und Provider-
        // Farben eine NSException. Hier belegen wir für BEIDE Themes, dass
        // jede Farbe sich nach sRGB konvertieren lässt und Komponenten
        // liefert (genau die Operation, die die Minimap braucht).
        for theme in [EditorView.fastraTheme, EditorView.fastraThemeDark] {
            let farben: [NSColor] = [
                theme.text.color, theme.insertionPoint, theme.invisibles.color,
                theme.background, theme.lineHighlight, theme.selection,
                theme.keywords.color, theme.commands.color, theme.types.color,
                theme.attributes.color, theme.variables.color, theme.values.color,
                theme.numbers.color, theme.strings.color, theme.characters.color,
                theme.comments.color,
            ]
            for farbe in farben {
                let srgb = farbe.usingColorSpace(.sRGB)
                #expect(srgb != nil)
                if let srgb {
                    #expect(srgb.brightnessComponent >= 0)
                }
            }
        }
    }

    @Test("Dynamische Theme-Farben lösen hell und dunkel verschieden auf")
    func dynamischeFarbenLoesenAuf() {
        // Stellvertretend für alle Theme-Tokens: eine dynamische NSColor muss
        // unter aqua- und darkAqua-Appearance verschiedene Werte liefern.
        let dyn = Theme.dynamicNSColor(
            light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            dark:  NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))

        var hell = NSColor.black, dunkel = NSColor.white
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            hell = NSColor(cgColor: dyn.cgColor)!
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            dunkel = NSColor(cgColor: dyn.cgColor)!
        }
        #expect(hell.usingColorSpace(.sRGB)?.brightnessComponent == 1)
        #expect(dunkel.usingColorSpace(.sRGB)?.brightnessComponent == 0)
    }
}
