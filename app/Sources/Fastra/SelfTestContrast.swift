// Kontrastprüfung der sichtbaren Textfelder; Abschluss und Fensterzugriff
// bleiben an die Infrastruktur des gestarteten SelfTest gebunden.
import AppKit
import Foundation

@MainActor
struct SelfTestContrast {
    private let windows: @MainActor () -> [NSWindow]
    private let finish: @MainActor (SelfTestOutcome, String) -> Never

    init(
        windows: @escaping @MainActor () -> [NSWindow],
        finish: @escaping @MainActor (SelfTestOutcome, String) -> Never
    ) {
        self.windows = windows
        self.finish = finish
    }

    /// Wächter gegen weiß-auf-weiß (und analoge unsichtbare Farb-Kombos):
    ///
    /// 1. Suchmaske öffnen (via .fastraShowSearchFile — gleicher Weg wie CMD+F).
    /// 2. Im Suchfenster und im Hauptfenster alle NSTextField-Instanzen
    ///    rekursiv einsammeln (sichtbar, nicht versteckt — Labels sind in
    ///    SwiftUI ebenfalls als NSTextField gebrückt).
    /// 3. Für jedes sichtbare Feld: Textfarbe gegen den effektiven Fensterhinter-
    ///    grund nach sRGB konvertieren, relative Luminanz per WCAG-Formel
    ///    berechnen, Kontrastverhältnis bestimmen. Verhältnis < 2.0 → FAIL.
    /// 4. PASS: beide Fenstergruppen messbar, kein Feld unter der Schwelle.
    ///    FAIL bei 0 geprüften Feldern in einer Gruppe — soll auffallen.
    ///
    /// Schwelle 2.0 ist absichtlich niedrig (WCAG AA für Fließtext wäre 4.5).
    /// Ziel: klares „weiß auf weiß" fangen, ohne bei leicht gedämpften
    /// Sekundärfarben (z.B. Platzhalter auf hellem Hintergrund) zu klagen.
    func runContrastTest() {
        // Suchmaske öffnen — exakt der Weg, den CMD+F auch geht.
        NotificationCenter.default.post(name: .fastraShowSearchFile, object: nil)

        // SwiftUI/AppKit Zeit geben, das Fenster zu rendern. Ohne die
        // Verzögerung sind viele Subviews noch nicht in der View-Hierarchie
        // (lazy SwiftUI body rendering).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let currentWindows = windows()
            let searchWindow = currentWindows.first(where: {
                $0.frameAutosaveName == SearchWindow.frameAutosaveName && $0.isVisible
            })
            let mainWindow = currentWindows.first(where: {
                $0.frameAutosaveName != SearchWindow.frameAutosaveName
                    && $0.contentView != nil && $0.isVisible
            })
            var searchFields: [NSTextField] = []
            var mainFields: [NSTextField] = []
            if let root = searchWindow?.contentView {
                Self.collectAllTextFields(in: root, into: &searchFields)
            }
            if let root = mainWindow?.contentView {
                Self.collectAllTextFields(in: root, into: &mainFields)
            }

            // Hintergrundfarbe des Suchfensters als Standard-Fallback. Die
            // Suchmaske hat einen expliziten hellen Hintergrund (Theme.surfaceRaised),
            // NSWindow.backgroundColor spiegelt das systemseitig wider.
            // Für Felder ohne eigenen definierten Hintergrund ist das der
            // beste Proxy, den wir ohne vollständiges CALayer-Traversal haben.
            // Konservativer Fallback: reines Weiß — ist das Suchfenster
            // nicht auffindbar, bleibt die Prüfung auf der sicheren Seite
            // (Textfarbe wird gegen Weiß verglichen, genau die Bug-Klasse).
            let windowBg = searchWindow?.backgroundColor ?? NSColor.white

            // Jede Gruppe muss für sich den ursprünglichen Messvertrag erfüllen.
            // Ein Fehler bleibt auch bei unmessbaren Farben der anderen Gruppe erhalten.
            let search = Self.contrastEvaluation(fields: searchFields, windowBackground: windowBg)
            let main = Self.contrastEvaluation(fields: mainFields, windowBackground: windowBg)
            finish(max(search.outcome, main.outcome),
                "Suchfenster: \(search.message)\nHauptfenster: \(main.message)")
        }
    }

    /// Wertet die tatsächlich messbaren Textfelder aus; separat aufrufbar,
    /// damit die Nachweisgrenzen ohne sichtbares Fenster geprüft werden können.
    static func contrastEvaluation(
        fields allFields: [NSTextField], windowBackground windowBg: NSColor
    ) -> (outcome: SelfTestOutcome, message: String) {
        var failDescriptions: [String] = []
        var checkedCount = 0
        var unmeasurableCount = 0

        for field in allFields {
            // Versteckte oder transparent gerenderte Felder überspringen —
            // sie sind für den Nutzer nicht sichtbar.
            guard !field.isHidden, field.alphaValue > 0.05 else { continue }
            // Felder ohne window-Kontext sind noch nicht auf dem Schirm.
            guard field.window != nil else { continue }
            // Leere Felder überspringen: SwiftUIs `Menu` (.borderlessButton)
            // legt intern ein leeres NSTextField-Hilfsfeld an (stringValue
            // ""), das fg≈bg hat (contrast ~1.07). Da es keinen Text zeigt,
            // ist es per Definition kein „weiß-auf-weiß"-Lesbarkeitsproblem —
            // der Test zielt auf sichtbaren Text (Dark-Mode-Bug-Klasse).
            guard !field.stringValue.isEmpty else { continue }

            // Textfarbe des Felds — SwiftUI setzt `.textColor` auf dem
            // gebrückten NSTextField. Fehlt sie, gilt die System-Label-Farbe.
            let rawText = field.textColor ?? NSColor.labelColor

            // Hintergrundfarbe: wenn das Feld selbst einen definierten,
            // nicht-transparenten Hintergrund hat, nehmen wir den.
            // Sonst Fensterhintergrund als Fallback.
            let rawBg: NSColor = {
                if field.drawsBackground,
                   let bg = field.backgroundColor,
                   bg.alphaComponent > 0.05 {
                    return bg
                }
                return windowBg
            }()

            // Musterfarben besitzen beispielsweise keinen einzelnen sRGB-Wert.
            // Ohne Messwert darf dieses Feld weder als geprüft zählen noch
            // eine unvollständige Messung als erfolgreicher Test enden.
            guard
                let textSRGB = rawText.usingColorSpace(.sRGB),
                let bgSRGB   = rawBg.usingColorSpace(.sRGB)
            else {
                unmeasurableCount += 1
                continue
            }

            checkedCount += 1
            let ratio = contrastRatio(textSRGB, bgSRGB)
            if ratio < 2.0 {
                // Beschreibung enthält genug Info, um das Feld im UI
                // zu identifizieren: Platzhalter + Wert-Präfix + Frame.
                let valuePreview = String(field.stringValue.prefix(20))
                let desc = "ph=\"\(field.placeholderString ?? "")\" "
                    + "value=\"\(valuePreview)\" "
                    + "frame=\(field.frame) "
                    + "contrast=\(String(format: "%.2f", ratio))"
                failDescriptions.append(desc)
            }
        }

        // Ein tatsächlich gemessener Fehler hat Vorrang vor fehlenden Werten.
        // Auch eine teilweise messbare Oberfläche liefert sonst nur ENV.
        if failDescriptions.isEmpty && unmeasurableCount > 0 {
            return (.environment,
                "\(checkedCount) Felder geprüft, \(unmeasurableCount) Farben nicht nach sRGB konvertierbar")
        }

        if checkedCount == 0 {
            // Alle Felder waren versteckt oder ohne window-Kontext —
            // verdächtig, könnte aber beim Erst-Start kurz auftreten.
            return (.fail,
                "0 sichtbare NSTextField geprüft "
                + "(von \(allFields.count) insgesamt gefunden)")
        }

        if failDescriptions.isEmpty {
            return (.pass,
                "\(checkedCount) Felder geprüft, keins unter Kontrast 2.0")
        } else {
            return (.fail,
                "\(failDescriptions.count) Feld(er) unter Kontrast 2.0 "
                + "(von \(checkedCount) geprüft):\n"
                + failDescriptions.joined(separator: "\n")
                + "\n\(unmeasurableCount) Felder ohne messbaren Farbwert")
        }
    }

    /// Sammelt alle `NSTextField` (editierbar und Labels) rekursiv ein.
    /// Im Gegensatz zu `collectEditableFields` werden auch nicht-editierbare
    /// Labels erfasst — in SwiftUI sind `Text`-Views als `NSTextField` mit
    /// `isEditable=false` gebrückt und können genauso unsichtbar sein
    /// (weiß auf weiß war exakt dieser Fall, s. Commit-Historie).
    private static func collectAllTextFields(in view: NSView, into out: inout [NSTextField]) {
        if let tf = view as? NSTextField {
            out.append(tf)
        }
        for sub in view.subviews {
            collectAllTextFields(in: sub, into: &out)
        }
    }

    /// Berechnet das WCAG-Kontrastverhältnis zweier Farben.
    ///
    /// Formel: (L_hell + 0.05) / (L_dunkel + 0.05), wobei L die
    /// relative Luminanz nach WCAG 2.1 Appendix A ist. Ergebnis liegt
    /// zwischen 1.0 (kein Kontrast, identische Farben) und 21.0
    /// (maximaler Kontrast: schwarz auf weiß). Beide Farben müssen im
    /// sRGB-Farbraum vorliegen — das stellt der Aufrufer sicher.
    private static func contrastRatio(_ a: NSColor, _ b: NSColor) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        // Die hellere Farbe kommt in den Zähler.
        let lighter = max(la, lb)
        let darker  = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Relative Luminanz einer sRGB-Farbe nach WCAG 2.1 (linearisierter
    /// Gamma-Wert, gewichtet nach menschlicher Empfindlichkeit).
    private static func relativeLuminance(_ color: NSColor) -> Double {
        // WCAG-Linearisierung: Werte ≤ 0.04045 werden linear skaliert,
        // höhere Werte über eine Potenzfunktion (Gamma ≈ 2.2).
        func linearize(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        // `redComponent` etc. sind im sRGB-Farbraum im Bereich 0…1.
        let r = linearize(Double(color.redComponent))
        let g = linearize(Double(color.greenComponent))
        let b = linearize(Double(color.blueComponent))
        // ITU-R BT.709 Gewichtung (WCAG-Standard).
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
