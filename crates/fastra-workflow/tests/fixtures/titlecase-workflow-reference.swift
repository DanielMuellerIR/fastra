// Serialisierte Typen aus TextWorkflow.swift; berechnete UI-/Suchadapter sind ausgelassen.
import Foundation

struct TextWorkflow: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var revision = UUID()
    var name: String
    var steps: [TextWorkflowStep]
}

struct TextWorkflowStep: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case replace, sortAscending, sortDescending, removeDuplicateLines
        case uppercase, lowercase, titlecase, trimTrailing, detab, entab
        case zapGremlins, straightenQuotes, educateQuotes, convertEscapeSequences
        case shiftRight, shiftLeft, reverseLines, removeBlankLines, joinLines, joinLinesTight
        case prefixLines, suffixLines, addLineNumbers, removeLineNumbers, exchangeCharacters, exchangeWords
        case keepLinesMatching, deleteLinesMatching, keepDuplicateLines, removeAllDuplicatedLines, hardWrap
        case normalizeSpaces, stripDiacriticals, precomposeUnicode, decomposeUnicode
        case fourDDetokenize, fourDTokenizeCommands, addEmojiPresentation, removeEmojiPresentation

    }
    var id = UUID()
    var kind: Kind
    var enabled = true
    var argument = ""
    var find = ""
    var replacement = ""
    var regex = false
    var caseSensitive = false
    var wholeWord = false
    var literalWildcard = false
    var tabWidth = 4
    var indentWidth = 4
    var usesTabs = false
    var wrapColumn = 72

}


struct WorkflowEnvelope: Codable {var schemaVersion = 1;var workflows:[TextWorkflow]}
var suffix=TextWorkflowStep(kind:.suffixLines);suffix.argument="!"
let flow=TextWorkflow(name:"Explicit system-locale Titlecase",steps:[TextWorkflowStep(kind:.titlecase),suffix])
let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
print(String(data:try encoder.encode(WorkflowEnvelope(workflows:[flow])),encoding:.utf8)!)
