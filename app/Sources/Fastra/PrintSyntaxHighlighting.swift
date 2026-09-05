// PrintSyntaxHighlighting.swift
//
// Syntaxfarben im Quelltext-Ausdruck (Folgeauftrag „Syntaxfarben im
// Quelltext-Druck", 2026-09-05; beauftragt nach der Druckabnahme vom
// 2026-08-18).
//
// Der Druck nutzt dieselbe Syntaxanalyse wie der Editor — tree-sitter über
// CodeEditSourceEditors `TreeSitterClient` bzw. den 4D-Tokenizer über die
// `CustomLanguageProviders` — aber auf einem eigenen, unsichtbaren
// `TextView`, der nur als Textquelle dient. Dadurch werden ALLE Zeilen des
// Dokuments eingefärbt, nicht nur die auf dem Bildschirm gerade sichtbaren,
// und der Druck bleibt unabhängig von Auswahl, Cursorzeile und Suchmarkierung.
//
// Farben: immer der HELLE Farbsatz des jeweiligen Themes, egal welches
// Erscheinungsbild der Bildschirm gerade hat — Papier ist weiß. Der Grundtext
// bleibt Schwarz wie im einfarbigen Ausdruck.

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView

enum PrintSyntaxHighlighting {

    /// Ergebnis der Syntaxanalyse für den Druck.
    enum Outcome: Equatable {
        /// Eingefärbte Bereiche (Zeichen-Offsets im normalisierten Drucktext).
        case colored([HighlightRange])
        /// Reiner Text ohne Grammatik — es gibt nichts einzufärben.
        case plain
        /// Die Analyse kam nicht rechtzeitig zurück; der Ausdruck läuft
        /// einfarbig weiter, damit der Nutzer nicht auf ein Blatt wartet.
        case timedOut
    }

    /// Obergrenze für die Einfärbung. Darüber druckt Fastra einfarbig: Die
    /// Analyse eines sehr großen Dokuments würde den Druckdialog spürbar
    /// verzögern (gemessen: siehe `PrintSyntaxHighlightingTests`).
    static let maximumColoredLength = 2_000_000

    /// Frist, nach der der Ausdruck ohne Farben startet.
    static let analysisTimeout: TimeInterval = 10

    /// Heller Druck-Farbsatz des Formats: das Licht-Theme der Eigen-Sprache
    /// (4D) bzw. das Standard-Theme; der Grundtext wird Schwarz.
    static func printTheme(for format: DocumentFormat) -> EditorTheme {
        var theme = format.customLanguage?.lightTheme ?? EditorView.fastraTheme
        theme.text = .init(color: .black)
        return theme
    }

    /// Der Text, auf dem die Druckzeilen und damit auch die Farbbereiche
    /// beruhen: dieselbe Zeilenzerlegung wie `PrintLineNumbers.lines(of:)`,
    /// mit `\n` verbunden. CRLF-Dateien hätten sonst andere Offsets als die
    /// gedruckten Zeilen.
    static func normalizedText(_ text: String) -> String {
        PrintLineNumbers.lines(of: text).joined(separator: "\n")
    }

    /// Attribut (Farbe, fett, kursiv) eines Capture-Namens im Theme.
    /// Spiegelt `EditorTheme.mapCapture` aus CodeEditSourceEditor
    /// (einschließlich des Fastra-Patches für die 4D-Slots); die Funktion
    /// dort ist nicht öffentlich.
    static func attribute(for capture: CaptureName?,
                          in theme: EditorTheme) -> EditorTheme.Attribute {
        switch capture {
        case .include, .constructor, .keyword, .boolean,
             .keywordReturn, .keywordFunction, .repeat, .conditional, .tag:
            return theme.keywords
        case .variableBuiltin: return theme.values
        case .comment: return theme.comments
        case .variable: return theme.variables
        case .property: return theme.characters
        case .function: return theme.commands
        case .method: return theme.methods
        case .componentMethod: return theme.componentMethods
        case .number, .float: return theme.numbers
        case .string: return theme.strings
        case .type: return theme.types
        case .parameter: return theme.variables
        case .typeAlternate: return theme.attributes
        default: return theme.text
        }
    }

    /// Hält Textquelle und Analyse am Leben, bis die Antwort da ist. Die
    /// Provider halten den `TextView` nur schwach.
    private final class Analysis {
        let textView: TextView
        let provider: any HighlightProviding
        var finished = false

        init(textView: TextView, provider: any HighlightProviding) {
            self.textView = textView
            self.provider = provider
        }
    }

    /// Färbt `text` (bereits normalisiert, siehe `normalizedText`) für das
    /// Format ein. Läuft asynchron: tree-sitter parst auf seinem eigenen
    /// Executor, die Antwort kommt auf dem Main-Thread. Der Aufrufer bekommt
    /// genau EINE Rückmeldung — auch wenn Analyse und Frist gleichzeitig
    /// enden.
    @MainActor
    static func analyze(text: String, format: DocumentFormat,
                        fourDMethodIndex: FourDMethodIndexSnapshot,
                        timeout: TimeInterval = analysisTimeout,
                        completion: @escaping @MainActor (Outcome) -> Void) {
        let length = (text as NSString).length
        guard length <= maximumColoredLength else {
            completion(.plain)
            return
        }
        let provider: any HighlightProviding
        if let custom = format.customLanguage {
            // Eigene Instanz statt der des Editors: Der Druck darf die
            // Provider-Identität des sichtbaren Editors nicht anfassen —
            // eine neue Instanz dort würde seine Highlights invalidieren.
            let providers = CustomLanguageProviders()
            provider = providers.provider(
                for: custom,
                projectMethodNames: custom.id == CustomLanguageRegistry.fourD.id
                    ? fourDMethodIndex.projectMethodNames : [],
                componentMethodNames: custom.id == CustomLanguageRegistry.fourD.id
                    ? Set(fourDMethodIndex.componentMethods.keys) : []
            )
        } else if format.grammar.id == .plainText {
            completion(.plain)
            return
        } else {
            provider = TreeSitterClient()
        }

        // Unsichtbare Textquelle: kein Fenster, kein Layout — nur der
        // Textspeicher, aus dem die Analyse liest.
        let textView = TextView(string: text, isEditable: false, isSelectable: false)
        let analysis = Analysis(textView: textView, provider: provider)
        provider.setUp(textView: textView, codeLanguage: format.grammar)

        func finish(_ outcome: Outcome) {
            guard !analysis.finished else { return }
            analysis.finished = true
            completion(outcome)
        }
        provider.queryHighlightsFor(
            textView: textView,
            range: NSRange(location: 0, length: length)
        ) { result in
            switch result {
            case .success(let ranges):
                finish(.colored(ranges.sorted { $0.range.location < $1.range.location }))
            case .failure:
                finish(.plain)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            finish(.timedOut)
        }
    }

    /// Färbt einen bereits aufgebauten Drucktext ein.
    ///
    /// `lineOffsets` sind die Startpositionen der gedruckten Zeilen im
    /// Ergebnis-String, `sourceOffsets` die Startpositionen derselben Zeilen im
    /// normalisierten Quelltext (ohne Nummernspalte). Ein Farbbereich, der über
    /// mehrere Zeilen reicht (Blockkommentar), wird zeilenweise übertragen —
    /// die Nummernspalte dazwischen bleibt grau.
    static func apply(_ highlights: [HighlightRange], theme: EditorTheme,
                      font: NSFont, to result: NSMutableAttributedString,
                      lines: [String], lineOffsets: [Int], sourceOffsets: [Int]) {
        guard !highlights.isEmpty else { return }
        var fonts: [EditorTheme.Attribute: NSFont] = [:]
        func styledFont(_ attribute: EditorTheme.Attribute) -> NSFont {
            if let cached = fonts[attribute] { return cached }
            var styled = font
            if attribute.bold {
                styled = NSFontManager.shared.convert(styled, toHaveTrait: .boldFontMask)
            }
            if attribute.italic {
                styled = NSFontManager.shared.convert(styled, toHaveTrait: .italicFontMask)
            }
            fonts[attribute] = styled
            return styled
        }

        var next = 0
        for (index, line) in lines.enumerated() {
            let lineStart = sourceOffsets[index]
            let lineEnd = lineStart + (line as NSString).length
            // Bereiche, die vor dieser Zeile enden, sind erledigt.
            while next < highlights.count,
                  highlights[next].range.upperBound <= lineStart {
                next += 1
            }
            var cursor = next
            while cursor < highlights.count,
                  highlights[cursor].range.location < lineEnd {
                let range = highlights[cursor].range
                let start = max(range.location, lineStart)
                let end = min(range.upperBound, lineEnd)
                if end > start {
                    let attribute = attribute(for: highlights[cursor].capture, in: theme)
                    result.addAttributes(
                        [.foregroundColor: attribute.color, .font: styledFont(attribute)],
                        range: NSRange(location: lineOffsets[index] + (start - lineStart),
                                       length: end - start)
                    )
                }
                cursor += 1
            }
        }
    }
}
