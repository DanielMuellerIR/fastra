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
        let d = testSuiteDefaults(named: name)
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

    @Test("Offener Suchdialog verstärkt ausschließlich die aktuelle Zeile")
    func searchThemeHighlightsCurrentLine() {
        let base = EditorView.fastraTheme
        let active = EditorView.theme(base, emphasizingCurrentLine: true,
                                      darkMode: false)
        #expect(active.lineHighlight != base.lineHighlight)
        #expect(active.text == base.text)
        #expect(active.background == base.background)
        #expect(active.selection == base.selection)
        #expect(EditorView.theme(base, emphasizingCurrentLine: false,
                                 darkMode: false) == base)
    }

    @Test("Aktuelle Zeile hebt sich in Hell und Dunkel deutlich vom Hintergrund ab")
    func currentLineHasVisibleContrast() {
        for theme in [EditorView.fastraTheme, EditorView.fastraThemeDark,
                      EditorView.fourDTheme, EditorView.fourDThemeDark] {
            guard let background = theme.background.usingColorSpace(.sRGB),
                  let highlight = theme.lineHighlight.usingColorSpace(.sRGB) else {
                Issue.record("Theme-Farbe ließ sich nicht nach sRGB wandeln")
                continue
            }
            // Tatsächlich sichtbare Farbe nach Alpha-Mischung mit dem
            // Editorgrund; bloß unterschiedliche Rohwerte wären zu schwach.
            let visibleBrightness = highlight.brightnessComponent
                * highlight.alphaComponent
                + background.brightnessComponent * (1 - highlight.alphaComponent)
            #expect(abs(visibleBrightness - background.brightnessComponent) >= 0.09)
        }
    }

    @Test("Helle Textauswahl ist heller als die aktive Zeile und bleibt auf Weiß sichtbar")
    func lightSelectionSeparatesFromCurrentLine() {
        for theme in [EditorView.fastraTheme, EditorView.fourDTheme] {
            guard let background = theme.background.usingColorSpace(.sRGB),
                  let highlight = theme.lineHighlight.usingColorSpace(.sRGB),
                  let selection = theme.selection.usingColorSpace(.sRGB) else {
                Issue.record("Theme-Farbe ließ sich nicht nach sRGB wandeln")
                continue
            }
            func mean(_ color: NSColor) -> CGFloat {
                (color.redComponent + color.greenComponent + color.blueComponent) / 3
            }
            func visibleMean(_ foreground: NSColor, over backgroundMean: CGFloat) -> CGFloat {
                mean(foreground) * foreground.alphaComponent
                    + backgroundMean * (1 - foreground.alphaComponent)
            }

            let backgroundMean = mean(background)
            let activeLineMean = visibleMean(highlight, over: backgroundMean)
            let selectedActiveLineMean = visibleMean(selection, over: activeLineMean)
            let selectedWhiteMean = visibleMean(selection, over: backgroundMean)

            // Die Auswahl soll auf der aktiven Zeile klar nach HELL absetzen,
            // aber auf dem weißen Dokumentgrund weiterhin als Fläche stehen.
            #expect(selectedActiveLineMean - activeLineMean >= 0.08)
            #expect(backgroundMean - selectedWhiteMean >= 0.08)
        }
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
