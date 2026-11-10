import AppKit
import CodeEditTextView
import CodeEditLanguages
import SwiftTreeSitter

enum BracketSelection {
    /// UTF-16 wie die Editor-Auswahl. Bereits vollständig gewählte Blöcke
    /// werden übersprungen, damit ein weiterer Aufruf nach außen erweitert.
    static func range(in text: String, selection: NSRange, language: CodeLanguage? = nil) -> NSRange? {
        let source = text as NSString
        guard selection.location != NSNotFound, selection.location >= 0,
              selection.length >= 0, selection.location <= source.length,
              selection.length <= source.length - selection.location else { return nil }
        let ignored = language.map { ignoredRanges(in: text, language: $0) } ?? []
        var ignoredIndex = 0
        var stack: [(character: unichar, position: Int)] = []
        var quote: unichar?
        var best: NSRange?
        var bestPriority = Int.max
        var position = 0
        while position < source.length {
            while ignoredIndex < ignored.count, ignored[ignoredIndex].upperBound <= position {
                ignoredIndex += 1
            }
            if ignoredIndex < ignored.count, ignored[ignoredIndex].location <= position {
                position = ignored[ignoredIndex].upperBound
                continue
            }
            let character = source.character(at: position)
            if let delimiter = quote {
                if character == 92 { position += 2; continue }
                if character == delimiter { quote = nil }
            } else if character == 34 {
                // JSON-Escapes werden oben paarweise übersprungen. Eine
                // Klammer im String darf den Objekt-Stack niemals verändern.
                quote = character
            } else if character == 123 || character == 91 || character == 40 {
                stack.append((character, position))
            } else if character == 125 || character == 93 || character == 41 {
                let opening: unichar = character == 125 ? 123 : (character == 93 ? 91 : 40)
                if let start = stack.last, start.character == opening {
                    stack.removeLast()
                    let range = NSRange(location: start.position, length: position - start.position + 1)
                    if range.location <= selection.location,
                       range.upperBound >= selection.upperBound,
                       range != selection {
                        // Direkt vor einer äußeren Schlussklammer liegt der
                        // Cursor zugleich hinter dem inneren Block: Die
                        // Klammer UNTER dem Cursor hat dann Vorrang.
                        let priority = selection.length == 0
                            ? (range.location == selection.location || position == selection.location ? 0
                               : (range.upperBound == selection.location ? 1 : 2)) : 2
                        if priority < bestPriority || (priority == bestPriority && range.length < (best?.length ?? Int.max)) {
                            best = range
                            bestPriority = priority
                        }
                    }
                } else {
                    // Fehlerhafte Schachtelung nicht mit einem erfundenen
                    // Klammerpartner überbrücken.
                    stack.removeAll()
                }
            }
            position += 1
        }
        return best
    }

    private static func ignoredRanges(in text: String, language: CodeLanguage) -> [NSRange] {
        guard let grammar = language.language else { return [] }
        let parser = Parser()
        guard (try? parser.setLanguage(grammar)) != nil,
              let tree = parser.parse(text), let root = tree.rootNode else { return [] }
        var pending = [root]
        var ranges: [NSRange] = []
        while let node = pending.popLast() {
            let type = node.nodeType ?? ""
            // Die Grammatik kennt auch einfache Quotes, Raw-Strings und
            // sprachspezifische Kommentare; deren Klammern sind kein Code.
            if type.contains("string") || type.contains("comment")
                || ["character_literal", "char_literal", "regex", "regex_literal"].contains(type) {
                if node.range.length > 0 { ranges.append(node.range) }
                continue
            }
            for index in 0..<node.namedChildCount {
                if let child = node.namedChild(at: index) { pending.append(child) }
            }
        }
        return ranges.sorted { $0.location < $1.location }
    }
}

@MainActor
enum BracketSelectionCommands {
    static func performCommandB() -> Bool {
        guard let document = CommandTargeting.targetDocument(),
              document.window === NSApp.keyWindow else { return false }
        // Native Untermenüs behalten bis zum nächsten Öffnen alte Kürzel.
        // Der Eventpfad entscheidet deshalb am aktuellen Dokumenttyp.
        if document.workspace.activeTabIsMarkdown {
            NotificationCenter.default.post(name: .fastraMarkdownFormat,
                object: MarkdownFormatCommand.bold.rawValue)
            return true
        }
        guard let target = CommandTargeting.target(),
              target.window.firstResponder === target.textView else { return false }
        selectEnclosingBlock()
        return true
    }

    static func selectEnclosingBlock() {
        guard let target = CommandTargeting.target(),
              target.window.firstResponder === target.textView,
              target.textView.selectionManager.textSelections.count == 1 else { return }
        let editor = target.textView
        let tabID = target.workspace.activeTabID
        let documentID = target.workspace.activeTab?.documentID
        let source = editor.string
        let selection = editor.fastraSafeSelectedRange
        let language = target.workspace.activeDocumentFormat.grammar
        // Auch bei großen Dokumenten darf die Analyse keine Eingabe blockieren.
        DispatchQueue.global(qos: .userInitiated).async {
            let range = BracketSelection.range(in: source, selection: selection, language: language)
            DispatchQueue.main.async {
                guard let current = CommandTargeting.target(),
                      current.textView === editor,
                      current.workspace.activeTabID == tabID,
                      current.workspace.activeTab?.documentID == documentID,
                      current.window.firstResponder === editor,
                      editor.string == source,
                      editor.selectionManager.textSelections.count == 1,
                      editor.fastraSafeSelectedRange == selection else { return }
                guard let range else { NSSound.beep(); return }
                editor.selectionManager.setSelectedRange(range)
                editor.scrollSelectionToVisible()
            }
        }
    }
}
