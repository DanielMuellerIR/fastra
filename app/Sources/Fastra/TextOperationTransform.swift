import Foundation

// Gemeinsame Zuordnung für Einzelbefehle und gespeicherte Textabläufe.
enum TextOperationTransform {
    static func operation(for kind: TextOpKind, profile: IndentationProfile = .factory)
        -> (String, NSRange) -> LineOperations.Result? {
        switch kind {
        case .uppercase:        return TextOperations.uppercase
        case .lowercase:        return TextOperations.lowercase
        case .titlecase:        return TextOperations.titlecase
        case .trimTrailing:     return TextOperations.trimTrailingWhitespace
        case .detab:            return { TextOperations.detab(in: $0, selection: $1, tabWidth: profile.tabWidth) }
        case .entab:            return { TextOperations.entab(in: $0, selection: $1, tabWidth: profile.tabWidth) }
        case .zapGremlins:      return TextOperations.zapGremlins
        case .straightenQuotes: return TextOperations.straightenQuotes
        case .educateQuotes:    return TextOperations.educateQuotes
        case .convertEscapeSequences: return TextOperations.convertEscapeSequences
        case .shiftRight:       return { TextOperations.shiftRight(in: $0, selection: $1, profile: profile) }
        case .shiftLeft:        return { TextOperations.shiftLeft(in: $0, selection: $1, profile: profile) }
        case .reverseLines:     return TextOperations.reverseLines
        case .removeBlankLines: return TextOperations.removeBlankLines
        // Beide Join-Varianten teilen sich die pure Funktion, nur der Trenner
        // unterscheidet sie (Leerzeichen für Fließtext, leer für Daten-Spalten).
        case .joinLines:        return { TextOperations.joinLines(in: $0, selection: $1, separator: " ") }
        case .joinLinesTight:   return { TextOperations.joinLines(in: $0, selection: $1, separator: "") }
        case .addLineNumbers:     return TextOperations.addLineNumbers
        case .removeLineNumbers:  return TextOperations.removeLineNumbers
        case .exchangeCharacters: return TextOperations.exchangeCharacters
        case .exchangeWords:      return TextOperations.exchangeWords
        // Process Duplicate Lines (BBEdit) — ohne Eingabe, direkt über LineOperations.
        case .keepDuplicateLines:       return LineOperations.keepDuplicateLines
        case .removeAllDuplicatedLines: return LineOperations.removeAllDuplicatedLines
        // Unicode-Gruppe (BBEdit Kap. 5): Zs-Leerzeichen → ASCII-Space,
        // Diakritika strippen, NFC-/NFD-Normalisierung.
        case .normalizeSpaces:   return TextOperations.normalizeSpaces
        case .stripDiacriticals: return TextOperations.stripDiacriticals
        case .precomposeUnicode: return TextOperations.precomposeUnicode
        case .decomposeUnicode:  return TextOperations.decomposeUnicode
        // Emoji-Präsentation: Variantenselektor U+FE0F ergänzen/entfernen.
        case .addEmojiPresentation:    return TextOperations.addEmojiPresentation
        case .removeEmojiPresentation: return TextOperations.removeEmojiPresentation
        // 4D-Export-Transformation (Etappe 6): token-basiert über den
        // FourDTokenizer — Strings/Kommentare bleiben unangetastet.
        case .fourDDetokenize:       return FourDTokenTransform.detokenizeOperation
        case .fourDTokenizeCommands: return FourDTokenTransform.tokenizeCommandsOperation
        // Parametrisierte Befehle führt der Aufrufer mit den erfassten Eingaben aus.
        case .prefixLines, .suffixLines, .keepLinesMatching, .deleteLinesMatching, .hardWrap:
            return { _, _ in nil }
        }
    }

}
