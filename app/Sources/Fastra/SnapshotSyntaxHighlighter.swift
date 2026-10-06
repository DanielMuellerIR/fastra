import AppKit
import CodeEditSourceEditor

/// Attribute ändern nur die Darstellung; der eingefrorene Text und seine
/// UTF-16-Positionen bleiben einschließlich CRLF unverändert.
@MainActor
final class SnapshotSyntaxHighlighter {
    private weak var textView: ReadOnlySnapshotTextView?
    private var format = DocumentFormatResolver.resolve(filename: "")
    private var ranges: [HighlightRange] = []
    // Die Schrift des ersten Tokens kann fett oder kursiv sein; sie ist keine Grundschrift.
    private var baseFont: NSFont
    private var revision = 0
    private var task: Task<Void, Never>?

    init(textView: ReadOnlySnapshotTextView) {
        self.textView = textView
        self.baseFont = textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    func setBaseFont(_ font: NSFont) {
        baseFont = font
        applyColors()
    }

    func analyze(filename: String) {
        guard let textView else { return }
        revision += 1
        let expectedRevision = revision
        task?.cancel()
        ranges = []
        format = DocumentFormatResolver.resolve(filename: filename)
        applyColors()
        let text = textView.string
        guard (text as NSString).length <= PrintSyntaxHighlighting.maximumColoredLength else { return }
        if format.id == .fourD {
            task = Task { [weak self] in
                // Die 4D-Analyse ist synchron. Bei Snapshots darf sie die
                // Oberfläche beim Quellenwechsel nicht blockieren.
                let tokens = await Task.detached(priority: .userInitiated) {
                    FourDTokenizer.tokenize(text)
                }.value
                guard let self, !Task.isCancelled, self.revision == expectedRevision else { return }
                self.ranges = tokens.compactMap { token in
                    FourDHighlightProvider.capture(for: token.kind).map {
                        HighlightRange(range: token.range, capture: $0)
                    }
                }
                self.applyColors()
            }
        } else {
            // Dieselben Provider wie im Editor und Ausdruck. Hier ausdrücklich
            // KEINE Druck-Normalisierung: Positionsaufträge beziehen sich auf
            // den unveränderten Snapshot-Text.
            PrintSyntaxHighlighting.analyze(text: text, format: format,
                                           fourDMethodIndex: .empty) { [weak self] outcome in
                guard let self, self.revision == expectedRevision else { return }
                if case .colored(let ranges) = outcome { self.ranges = ranges }
                self.applyColors()
            }
        }
    }

    func applyColors() {
        guard let textView, let storage = textView.textStorage else { return }
        let dark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = format.customLanguage.map { dark ? $0.darkTheme : $0.lightTheme }
            ?? (dark ? EditorView.fastraThemeDark : EditorView.fastraTheme)
        let font = baseFont
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.foregroundColor: theme.text.color, .font: font], range: full)
        for highlight in ranges {
            let range = NSIntersectionRange(highlight.range, full)
            guard range.length > 0 else { continue }
            let style = PrintSyntaxHighlighting.attribute(for: highlight.capture, in: theme)
            var styledFont = font
            if style.bold { styledFont = NSFontManager.shared.convert(styledFont, toHaveTrait: .boldFontMask) }
            if style.italic { styledFont = NSFontManager.shared.convert(styledFont, toHaveTrait: .italicFontMask) }
            storage.addAttributes([.foregroundColor: style.color, .font: styledFont], range: range)
        }
        storage.endEditing()
        textView.backgroundColor = theme.background
    }

    deinit { task?.cancel() }
}
