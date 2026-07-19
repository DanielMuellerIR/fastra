// FourDHighlightProvider.swift
//
// Anbindung des eigenen 4D-Tokenizers an CodeEditSourceEditors
// `HighlightProviding`-Protokoll (Etappe 4 Wunschpaket 2026-07). Ersetzt
// für .4dm-Dokumente die tree-sitter-Pipeline vollständig — bewusst KEINE
// neue tree-sitter-Grammatik (Bundle-Größe, Wartung).
//
// Arbeitsweise: Der komplette Text wird EINMAL pro Änderung tokenisiert und
// als Capture-Ranges zwischengespeichert; die Chunk-Anfragen des Editors
// werden aus dem Cache beantwortet. 4D-Methoden sind typischerweise klein —
// oberhalb einer harten Grenze wird gar nicht mehr eingefärbt, damit der
// Main-Thread nie an einem Riesen-Dokument hängt.

import Foundation
import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import CodeEditLanguages

final class FourDHighlightProvider: ObservableObject, HighlightProviding {

    private let projectMethodNames: Set<String>

    init(projectMethodNames: Set<String> = []) {
        self.projectMethodNames = Set(projectMethodNames.map { $0.lowercased() })
    }

    /// Oberhalb dieser Textlänge (UTF-16) färbt der Provider nicht mehr —
    /// ein .4dm dieser Größe ist ohnehin ein Sonderfall.
    static let highlightingCharacterLimit = 2_000_000

    /// Capture-Zuordnung der Token-Klassen (Farb-Slots siehe FourD-Themes in
    /// EditorView und den EditorTheme-Patch in build.sh).
    static func capture(for kind: FourDTokenizer.Kind) -> CaptureName? {
        switch kind {
        case .comment: return .comment
        case .string: return .string
        case .number: return .number
        case .keyword: return .keyword
        case .command: return .function
        case .constant: return .variableBuiltin
        case .localVariable: return .variable
        case .processVariable, .interprocessVariable: return .property
        case .table: return .type
        case .field: return .typeAlternate
        // Nur der Projektindex führt zum neuen methods-Slot. Normale Aufrufe
        // und Member-Aufrufe behalten bewusst den bisherigen Befehls-Slot,
        // damit die neue Projektmethodenfarbe keine bestehende Kategorie
        // ungewollt umdeutet.
        case .methodCall: return .function
        case .projectMethod: return .method
        }
    }

    /// Tokenisierungs-Cache: gilt, solange sich der Text nicht ändert.
    private var cachedRanges: [HighlightRange] = []
    private var cachedTextLength = -1
    private var cacheValid = false

    func setUp(textView: TextView, codeLanguage: CodeLanguage) {
        cacheValid = false
    }

    func willApplyEdit(textView: TextView, range: NSRange) { }

    func applyEdit(textView: TextView, range: NSRange, delta: Int,
                   completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void) {
        cacheValid = false
        // Ein Edit kann Kommentar-/String-Zustände hinter sich verändern
        // (`/*` öffnet …). Konservativ ab Editposition bis Textende neu
        // einfärben; davor bleibt alles gültig.
        let length = textView.textStorage?.length ?? 0
        let from = max(0, min(range.location, length))
        completion(.success(IndexSet(integersIn: from..<max(from, length))))
    }

    func queryHighlightsFor(textView: TextView, range: NSRange,
                            completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void) {
        let text = textView.string
        let length = (text as NSString).length
        guard length <= Self.highlightingCharacterLimit else {
            completion(.success([]))
            return
        }
        if !cacheValid || cachedTextLength != length {
            // Einmal pro Änderung: kompletter Tokenizer-Lauf, dann bedienen
            // alle Chunk-Anfragen denselben Cache.
            cachedRanges = FourDTokenizer.tokenize(
                text, projectMethodNames: projectMethodNames
            ).compactMap { token in
                Self.capture(for: token.kind).map {
                    HighlightRange(range: token.range, capture: $0)
                }
            }
            cachedTextLength = length
            cacheValid = true
        }
        let requested = cachedRanges.filter {
            NSIntersectionRange($0.range, range).length > 0
        }
        completion(.success(requested))
    }
}
