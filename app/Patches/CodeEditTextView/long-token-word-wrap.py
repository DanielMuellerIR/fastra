import sys

path = sys.argv[1]
source = open(path).read()
old_crlf_call = '''        var breakIndex = subrange.location + CTTypesetterSuggestClusterBreak(self, subrange.location, constrainingWidth)
        let isBreakAtEndOfString = breakIndex >= subrange.max

        let isNextCharacterCarriageReturn = checkIfLineBreakOnCRLF(breakIndex, for: string)'''
new_crlf_call = '''        var breakIndex = subrange.location + CTTypesetterSuggestClusterBreak(self, subrange.location, constrainingWidth)
        let isBreakAtEndOfString = breakIndex >= subrange.max
        let source = string.string as NSString

        let isNextCharacterCarriageReturn = checkIfLineBreakOnCRLF(breakIndex, for: source)'''
old_crlf_check = '''    private func checkIfLineBreakOnCRLF(_ breakIndex: Int, for string: NSAttributedString) -> Bool {
        guard breakIndex - 1 > 0 && breakIndex + 1 <= string.length else {
            return false
        }
        let substringRange = NSRange(location: breakIndex - 1, length: 2)
        let substring = string.attributedSubstring(from: substringRange).string

        return substring == LineEnding.carriageReturnLineFeed.rawValue
    }'''
new_crlf_check = '''    private func checkIfLineBreakOnCRLF(_ breakIndex: Int, for source: NSString) -> Bool {
        guard breakIndex - 1 > 0 && breakIndex < source.length else {
            return false
        }
        return source.character(at: breakIndex - 1) == 0x0d
            && source.character(at: breakIndex) == 0x0a
    }'''
old_word_search = '''        let canLastCharacterBreak = (breakIndex - 1 > 0 && ensureCharacterCanBreakLine(at: breakIndex - 1, for: string))

        if isBreakAtEndOfString || canLastCharacterBreak {
            // Breaking either at the end of the string, or on a whitespace.
            return breakIndex
        } else if breakIndex - 1 > 0 {
            // Try to walk backwards until we hit a whitespace or punctuation
            var index = breakIndex - 1

            while breakIndex - index < 100 && index > subrange.location {
                if ensureCharacterCanBreakLine(at: index, for: string) {
                    return index + 1
                }
                index -= 1
            }
        }

        return breakIndex
    }

    /// Ensures the character at the given index can break a line.
    /// - Parameter index: The index to check at.
    /// - Returns: True, if the character is a whitespace or punctuation character.
    private func ensureCharacterCanBreakLine(at index: Int, for string: NSAttributedString) -> Bool {
        let subrange = (string.string as NSString).rangeOfComposedCharacterSequence(at: index)
        let set = CharacterSet(charactersIn: (string.string as NSString).substring(with: subrange))
        return set.isSubset(of: .whitespacesAndNewlines) || set.isSubset(of: .punctuationCharacters)
    }'''
new_word_search = '''        if isBreakAtEndOfString {
            // Breaking either at the end of the string, or on a whitespace.
            return breakIndex
        }

        // Fastra-Patch: ASCII-Wortumbruch mit direkter UTF-16-Prüfung.
        // Upstream erzeugte für bis zu 100 einzelne Zeichen je visuellem
        // Fragment ein Substring und ein CharacterSet. Eine alphanumerische
        // 4,36-MB-Zeile brauchte dadurch rund 17 Sekunden statt unter einer.
        let searchStart = max(subrange.location, breakIndex - 100)
        if let asciiBreak = Self.fastASCIIWordBreak(
            in: source,
            searchStart: searchStart,
            breakIndex: breakIndex
        ) {
            return asciiBreak
        }

        // Unicode und zusammengesetzte Grapheme behalten die bisherige
        // allgemeine Prüfung. Sie ist teurer, aber für die exakte
        // Umbruchsemantik nötig und nicht der Megazeilen-Normalfall.
        var searchEnd = breakIndex
        while searchEnd > searchStart {
            let candidate = source.rangeOfCharacter(
                from: Self.wordBreakCandidates,
                options: .backwards,
                range: NSRange(
                    location: searchStart,
                    length: searchEnd - searchStart
                )
            )
            guard candidate.location != NSNotFound else { break }

            // `rangeOfCharacter` findet auch das Satzzeichen in einem
            // zusammengesetzten Graphem wie einer Emoji-Tastenkappe. Die
            // bisherige Semantik erlaubt den Umbruch nur, wenn das gesamte
            // Graphem aus Leerraum oder Satzzeichen besteht.
            let composed = source.rangeOfComposedCharacterSequence(
                at: candidate.location
            )
            let characters = CharacterSet(
                charactersIn: source.substring(with: composed)
            )
            if characters.isSubset(of: .whitespacesAndNewlines)
                || characters.isSubset(of: .punctuationCharacters) {
                return min(composed.max, breakIndex)
            }
            searchEnd = max(searchStart, composed.location)
        }

        return breakIndex
    }

    private static let wordBreakCandidates = CharacterSet
        .whitespacesAndNewlines
        .union(.punctuationCharacters)

    /// Liefert `nil`, sobald die allgemeine Unicode-Prüfung nötig ist.
    /// Ein gesetzter Wert ist entweder der letzte ASCII-Umbruchkandidat oder
    /// unverändert `breakIndex`, wenn die 100 Zeichen keinen enthalten.
    private static func fastASCIIWordBreak(
        in source: NSString,
        searchStart: Int,
        breakIndex: Int
    ) -> Int? {
        var index = breakIndex - 1
        while index >= searchStart {
            let character = source.character(at: index)
            guard character <= 0x7f else { return nil }
            if isASCIIWordBreak(character) {
                // Ein ASCII-Satzzeichen kann durch ein nachfolgendes
                // Kombinationszeichen Teil eines größeren Graphems sein.
                // Dann muss die vollständige Unicode-Prüfung entscheiden.
                let nextIndex = index + 1
                if nextIndex >= source.length {
                    return nextIndex
                }
                let nextCharacter = source.character(at: nextIndex)
                if nextCharacter <= 0x7f
                    && !(character == 0x0d && nextCharacter == 0x0a) {
                    return nextIndex
                }
                let composed = source.rangeOfComposedCharacterSequence(at: index)
                guard composed.length == 1 else { return nil }
                return composed.max
            }
            index -= 1
        }
        return breakIndex
    }

    /// ASCII-Teilmenge von `whitespacesAndNewlines ∪ punctuationCharacters`.
    private static func isASCIIWordBreak(_ character: unichar) -> Bool {
        (character >= 0x09 && character <= 0x0d)
            || character == 0x20
            || (character >= 0x21 && character <= 0x23)
            || (character >= 0x25 && character <= 0x2a)
            || (character >= 0x2c && character <= 0x2f)
            || (character >= 0x3a && character <= 0x3b)
            || (character >= 0x3f && character <= 0x40)
            || (character >= 0x5b && character <= 0x5d)
            || character == 0x5f
            || character == 0x7b
            || character == 0x7d
    }'''
current_ascii_marker = "Fastra-Patch: ASCII-Wortumbruch ohne Zeichensatzobjekte"

def replace_intermediate_word_search(marker):
    marker_index = source.index(marker)
    start = source.rfind("        if isBreakAtEndOfString {", 0, marker_index)
    end = source.index("\n    /// Check if the break index", marker_index)
    if start < 0:
        raise SystemExit(f"{path}: Beginn des bestehenden Wortumbruch-Patches fehlt")
    return source[:start] + new_word_search + source[end:]

if current_ascii_marker in source:
    source = source.replace(
        "Fastra-Patch: ASCII-Wortumbruch ohne Zeichensatzobjekte",
        "Fastra-Patch: ASCII-Wortumbruch mit direkter UTF-16-Prüfung",
        1
    )
    old_source_line = "        let source = string.string as NSString\n        if let asciiBreak"
    if old_source_line not in source:
        raise SystemExit(f"{path}: bestehender ASCII-Pfad hat sich geaendert")
    source = source.replace(old_source_line, "        if let asciiBreak", 1)
    old_candidate = '''                let composed = source.rangeOfComposedCharacterSequence(at: index)
                guard composed.length == 1 else { return nil }
                return composed.max'''
    new_candidate = '''                let nextIndex = index + 1
                if nextIndex >= source.length {
                    return nextIndex
                }
                let nextCharacter = source.character(at: nextIndex)
                if nextCharacter <= 0x7f
                    && !(character == 0x0d && nextCharacter == 0x0a) {
                    return nextIndex
                }
                let composed = source.rangeOfComposedCharacterSequence(at: index)
                guard composed.length == 1 else { return nil }
                return composed.max'''
    old_predicate = '''        switch character {
        case 0x09...0x0d, 0x20,
             0x21...0x23, 0x25...0x2a, 0x2c...0x2f,
             0x3a...0x3b, 0x3f...0x40,
             0x5b...0x5d, 0x5f, 0x7b, 0x7d:
            true
        default:
            false
        }'''
    new_predicate = '''        (character >= 0x09 && character <= 0x0d)
            || character == 0x20
            || (character >= 0x21 && character <= 0x23)
            || (character >= 0x25 && character <= 0x2a)
            || (character >= 0x2c && character <= 0x2f)
            || (character >= 0x3a && character <= 0x3b)
            || (character >= 0x3f && character <= 0x40)
            || (character >= 0x5b && character <= 0x5d)
            || character == 0x5f
            || character == 0x7b
            || character == 0x7d'''
    if old_candidate not in source or old_predicate not in source:
        raise SystemExit(f"{path}: bestehende ASCII-Pruefung hat sich geaendert")
    source = source.replace(old_candidate, new_candidate, 1)
    source = source.replace(old_predicate, new_predicate, 1)
elif old_word_search in source:
    source = source.replace(old_word_search, new_word_search, 1)
elif "Fastra-Patch: Wortumbruch-Kandidaten gesammelt rückwärts suchen" in source:
    source = replace_intermediate_word_search(
        "Fastra-Patch: Wortumbruch-Kandidaten gesammelt rückwärts suchen"
    )
elif "Fastra-Patch: Den Wortumbruch in einem Schritt rückwärts suchen" in source:
    source = replace_intermediate_word_search(
        "Fastra-Patch: Den Wortumbruch in einem Schritt rückwärts suchen"
    )
else:
    raise SystemExit(
        f"{path}: Wortumbruch-Suche hat sich geaendert — Patch 4z7 pruefen"
    )
if old_crlf_call not in source or old_crlf_check not in source:
    raise SystemExit(f"{path}: CRLF-Pruefung hat sich geaendert — Patch 4z7 pruefen")
source = source.replace(old_crlf_call, new_crlf_call, 1)
source = source.replace(old_crlf_check, new_crlf_check, 1)
open(path, "w").write(source)
