import Foundation

enum L10n { static func string(_ value: String) -> String { value } }
// Nur der unbenutzte Einrückungs-Parameter der originalen TextOperations braucht
// diesen Typ. Die geprüften Befehle verwenden kein Einrückungsprofil.
struct IndentationProfile {
    let usesTabs: Bool
    let indentWidth: Int
    let tabWidth: Int
    static let factory = IndentationProfile(usesTabs: false, indentWidth: 4, tabWidth: 4)
    var unitString: String { usesTabs ? "\t" : String(repeating: " ", count: indentWidth) }
}
struct Vector: Codable {
    let operation: String
    let text: String
    let location: Int
    let length: Int
    let argument: String
    let output: String?
    let affectedLocation: Int?
    let affectedLength: Int?
    let lineCount: Int?
}
@main struct Reference {
    static func main() throws {
        var result: [Vector] = []
        func add(_ operation: String, _ text: String, _ location: Int = 0, _ length: Int = 0, _ argument: String = "") {
            let selection = NSRange(location: location, length: length)
            let r: LineOperations.Result?
            switch operation {
            case "sort": r = LineOperations.sortLines(in: text, selection: selection, direction: .ascending)
            case "descending": r = LineOperations.sortLines(in: text, selection: selection, direction: .descending)
            case "dedup": r = LineOperations.removeDuplicateLines(in: text, selection: selection)
            case "duplicates": r = LineOperations.keepDuplicateLines(in: text, selection: selection)
            case "unique": r = LineOperations.removeAllDuplicatedLines(in: text, selection: selection)
            case "reverse": r = TextOperations.reverseLines(in: text, selection: selection)
            case "blank": r = TextOperations.removeBlankLines(in: text, selection: selection)
            case "trim": r = TextOperations.trimTrailingWhitespace(in: text, selection: selection)
            case "prefix": r = TextOperations.prefixLines(in: text, selection: selection, with: argument)
            case "suffix": r = TextOperations.suffixLines(in: text, selection: selection, with: argument)
            case "join": r = TextOperations.joinLines(in: text, selection: selection, separator: argument)
            case "number": r = TextOperations.addLineNumbers(in: text, selection: selection)
            case "unnumber": r = TextOperations.removeLineNumbers(in: text, selection: selection)
            case "keep": r = LineFilter.filter(in: text, selection: selection, pattern: argument, keepMatching: true)
            case "delete": r = LineFilter.filter(in: text, selection: selection, pattern: argument, keepMatching: false)
            case "nfc": r = TextOperations.precomposeUnicode(in: text, selection: selection)
            case "nfd": r = TextOperations.decomposeUnicode(in: text, selection: selection)
            case "spaces": r = TextOperations.normalizeSpaces(in: text, selection: selection)
            case "zap": r = TextOperations.zapGremlins(in: text, selection: selection)
            default: fatalError(operation)
            }
            result.append(Vector(operation: operation, text: text, location: location, length: length, argument: argument, output: r?.newText, affectedLocation: r?.affectedRange.location, affectedLength: r?.affectedRange.length, lineCount: r?.lineCount))
        }
        add("sort", "a10\na2\na1\n")
        add("descending", "a2\na10\na1\r\n")
        add("dedup", "é\ne\u{301}\nx\né\n")
        add("duplicates", "a\nb\na\nc\nb")
        add("unique", "a\nb\na\nc\r\n")
        add("unique", "a\na")
        add("duplicates", "a\n\nb\n\n")
        add("duplicates", "a\n\nb\n")
        for text in ["", "x", "a\r\nb\r\n", "a\rb\r", "a\nb", "a\r\nb\nc\r"] { add("reverse", text) }
        add("reverse", "😀head\nleft\nright\ntail", 9, 7)
        add("prefix", "a\n\nb", 0, 3, ">")
        add("number", "a\n\nb", 0, 3)
        add("number", "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\n")
        add("unnumber", "  1 a\n2b\nthree\n 4  d\n９x\n")
        add("blank", "a\n \t\n\u{a0}\n\u{2003}\nb\n")
        add("blank", "\n \n\n")
        add("trim", "😀 \t\r\nx\u{a0}\r\n")
        add("prefix", "a\r\nb\r\n", 0, 0, "前")
        add("suffix", "a\nb", 0, 0, "😀")
        add("join", "a\r\nb\r\n", 0, 0, " ")
        add("join", "a\nb\nc", 0, 3, "")
        add("keep", "Élan\r\nx\r\nélan\r\n", 0, 0, "^él")
        add("delete", "a\nb\nc", 0, 0, "[ac]")
        add("delete", "a\na\n", 0, 0, "a")
        add("keep", "a\n\nb", 0, 3, "a")
        add("nfc", "x e\u{301} 😀", 2, 1)
        add("nfd", "x é 😀", 2, 1)
        add("nfc", "é")
        add("spaces", "a\u{a0}b\u{2003}c\u{3000}\t\r\n")
        add("spaces", "😀\u{a0}x", 2, 1)
        add("zap", "a\u{0}\u{b}\u{7f}😀\t\r\nx")
        add("reverse", "a\nb\n", 2, 2)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try encoder.encode(result), encoding: .utf8)!)
    }
}
