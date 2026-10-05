import Foundation
import AppKit
import Combine
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftTreeSitter

@MainActor
final class CodeFoldProviders: ObservableObject {
    private var providers: [String: CodeFoldProvider] = [:]

    func provider(language: CodeLanguage, isFourD: Bool) -> CodeFoldProvider {
        let key = isFourD ? "fourD" : String(describing: language.id)
        if let existing = providers[key] { return existing }
        let provider = CodeFoldProvider(language: language, isFourD: isFourD)
        providers[key] = provider
        return provider
    }
}

@MainActor
final class CodeFoldProvider: SnapshotLineFoldProvider {
    private let language: CodeLanguage
    private let isFourD: Bool

    init(language: CodeLanguage, isFourD: Bool = false) {
        self.language = language
        self.isFourD = isFourD
    }

    func foldRegions(in text: String) async -> [SourceFoldRegion] {
        let language = language, isFourD = isFourD
        return await Task.detached(priority: .utility) {
            isFourD ? FourDFolding.regions(in: text) : SyntaxFolding.regions(in: text, language: language)
        }.value
    }

    func foldLevelAtLine(lineNumber: Int, lineRange: NSRange, previousDepth: Int,
                         controller: TextViewController) -> [LineFoldProviderLineInfo] { [] }
}

enum FoldingRanges {
    static func normalized(_ ranges: [NSRange], text: NSString) -> [SourceFoldRegion] {
        let unique = Set(ranges).filter {
            $0.location >= 0 && $0.length > 0 && $0.upperBound <= text.length
                && text.rangeOfCharacter(from: .newlines, options: [], range: $0).location != NSNotFound
        }.sorted {
            $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location
        }
        var stack: [NSRange] = []
        var result: [SourceFoldRegion] = []
        for range in unique {
            while let parent = stack.last, range.location >= parent.upperBound { stack.removeLast() }
            // Zwei Platzhalter am selben Anker oder kreuzende Bereiche sind
            // nicht sicher darstellbar. Der äußere vollständige Bereich gewinnt.
            if let parent = stack.last,
               range.location == parent.location || range.upperBound > parent.upperBound { continue }
            result.append(.init(range: range, depth: stack.count + 1))
            stack.append(range)
        }
        return result
    }
}

enum SyntaxFolding {
    static func regions(in text: String, language: CodeLanguage) -> [SourceFoldRegion] {
        guard let grammar = language.language else { return [] }
        let parser = Parser()
        guard (try? parser.setLanguage(grammar)) != nil,
              let tree = parser.parse(text), let root = tree.rootNode else { return [] }
        let source = text as NSString
        var ranges: [NSRange] = []
        var pending = [root]
        let bodies: Set<String> = ["function_body", "class_body", "enum_class_body", "compound_statement",
                                   "field_declaration_list", "statement_block", "declaration_list",
                                   "struct_body", "impl_body", "interface_body"]
        let controls: Set<String> = ["if_statement", "for_statement", "while_statement", "repeat_while_statement",
                                     "do_statement", "guard_statement", "switch_statement", "catch_block"]
        while let node = pending.popLast() {
            let type = node.nodeType ?? ""
            guard type != "ERROR", !node.isMissing else { continue }
            if node.hasError && node != root { continue }
            if !node.hasError && (bodies.contains(type) || controls.contains(type)
                || (type == "block" && language.id != CodeLanguage.python.id)) {
                var opening: Node?
                for index in 0..<node.childCount {
                    guard let child = node.child(at: index), !child.isMissing else { continue }
                    if child.nodeType == "{" { opening = child }
                    if child.nodeType == "}", let start = opening, start.range.upperBound < child.range.location {
                        ranges.append(NSRange(location: start.range.upperBound,
                                              length: child.range.location - start.range.upperBound))
                        opening = nil
                    }
                }
            } else if type == "block", let parent = node.parent,
                      language.id == CodeLanguage.python.id {
                // Python hat keine Abschlussklammer: der Header des jeweiligen
                // Zweigs bleibt stehen, der grammatisch bestimmte Body verschwindet.
                let header = source.lineRange(for: NSRange(location: parent.range.location, length: 0))
                var contentsEnd = 0
                source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: header)
                if node.range.upperBound > contentsEnd {
                    ranges.append(NSRange(location: contentsEnd, length: node.range.upperBound - contentsEnd))
                }
            }
            for index in (0..<node.namedChildCount).reversed() {
                if let child = node.namedChild(at: index) { pending.append(child) }
            }
        }
        return FoldingRanges.normalized(ranges, text: source)
    }
}

enum FourDFolding {
    private struct Block {
        let close: String
        let start: Int
        var branchStart: Int?
    }

    static func regions(in text: String) -> [SourceFoldRegion] {
        let source = text as NSString
        let tokens = FourDTokenizer.tokenize(text)
        let opens = ["if": "end if", "case of": "end case", "for": "end for",
                     "for each": "end for each", "while": "end while", "repeat": "until",
                     "use": "end use", "try": "end try", "begin sql": "end sql"]
        let closes = Set(opens.values)
        var blocks: [Block] = []
        var ranges: [NSRange] = []
        var functionStart: Int?
        var position = 0, tokenIndex = 0

        func append(_ start: Int, _ end: Int) {
            if end > start { ranges.append(NSRange(location: start, length: end - start)) }
        }

        while position < source.length {
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            source.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                                for: NSRange(location: position, length: 0))
            var first = lineStart
            while first < contentsEnd, CharacterSet.whitespaces.contains(
                UnicodeScalar(source.character(at: first)) ?? UnicodeScalar(0)) { first += 1 }
            while tokenIndex < tokens.count, tokens[tokenIndex].range.upperBound <= first { tokenIndex += 1 }
            let token = tokenIndex < tokens.count ? tokens[tokenIndex] : nil
            var keyword = ""
            if let token, token.range.location == first {
                let phrase = source.substring(with: token.range).lowercased()
                if token.kind == .keyword || (token.kind == .command && ["begin sql", "end sql"].contains(phrase)) {
                    keyword = phrase
                }
            }
            let sql = blocks.last?.close == "end sql"
            if sql && keyword != "end sql" { position = lineEnd; continue }

            if keyword == "function" || keyword == "class constructor" {
                if let functionStart { append(functionStart, max(functionStart, lineStart - newlineLength(before: lineStart, source: source))) }
                functionStart = contentsEnd
                // Unvollständige Blöcke dürfen keine folgende Methode verschlucken.
                blocks.removeAll()
            } else if let closing = opens[keyword] {
                blocks.append(Block(close: closing, start: contentsEnd))
            } else if closes.contains(keyword) {
                if let block = blocks.last, block.close == keyword {
                    if let branch = block.branchStart { append(branch, first) }
                    append(block.start, first)
                    blocks.removeLast()
                } else {
                    // Fehlerhafte Syntax nicht durch erfundene Abschlüsse kaschieren.
                    blocks.removeAll()
                }
            } else if var block = blocks.last {
                let isBranch = (keyword == "else" && ["end if", "end case"].contains(block.close))
                    || (keyword == "catch" && block.close == "end try")
                    || (first < contentsEnd && source.character(at: first) == 58
                        && token?.kind != .comment && token?.kind != .string && block.close == "end case")
                if isBranch {
                    if let branch = block.branchStart { append(branch, first) }
                    block.branchStart = contentsEnd
                    blocks[blocks.count - 1] = block
                }
            }
            position = lineEnd
        }
        if let functionStart { append(functionStart, source.length - newlineLength(before: source.length, source: source)) }
        return FoldingRanges.normalized(ranges, text: source)
    }

    private static func newlineLength(before end: Int, source: NSString) -> Int {
        guard end > 0 else { return 0 }
        if source.character(at: end - 1) == 10 {
            return end > 1 && source.character(at: end - 2) == 13 ? 2 : 1
        }
        return source.character(at: end - 1) == 13 ? 1 : 0
    }
}

@MainActor
enum CodeFoldingCommands {
    private static func controller() -> TextViewController? {
        var responder: NSResponder? = CommandTargeting.targetEditorTextView()
        while let current = responder {
            if let controller = current as? TextViewController { return controller }
            responder = current.nextResponder
        }
        return nil
    }

    static func toggleCurrent() {
        guard let controller = controller() else { return }
        let caret = controller.textView.fastraSafeSelectedRange.location
        let folds = controller.fastraFoldRegions
        let atLine = folds.filter {
            controller.textView.layoutManager.textLineForOffset($0.range.location)?.range.contains(caret) == true
        }
        let fold = atLine.min(by: { $0.depth < $1.depth })
            ?? folds.filter { $0.range.location <= caret && caret < $0.range.upperBound }
                .max(by: { $0.depth < $1.depth })
        if let fold { controller.setFastraFold(range: fold.range, collapsed: !fold.isCollapsed) }
    }

    static func collapseAll() {
        guard let controller = controller() else { return }
        for fold in controller.fastraFoldRegions.sorted(by: { $0.depth > $1.depth }) {
            controller.setFastraFold(range: fold.range, collapsed: true)
        }
    }

    static func expandAll() { controller()?.unfoldAllFastraFolds() }
}
