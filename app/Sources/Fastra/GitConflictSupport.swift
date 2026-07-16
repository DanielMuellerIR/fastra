import AppKit
import CodeEditTextView
import Foundation

/// Ergebnis der pfadspezifischen Attributprüfung durch Git. Bis ein sicherer
/// Textbefund vorliegt, darf die Konfliktleiste weder Textblöcke übernehmen noch
/// die Datei als gelöst markieren.
enum GitConflictInspection: Equatable {
    case checking
    case text(markerSize: Int)
    case unsupportedBinary
    case unavailable
}

struct GitConflictAttributes: Equatable {
    let markerSize: Int
    let isBinary: Bool
}

/// Parst Gits NUL-getrennte `check-attr -z`-Ausgabe für die explizite
/// Sicherheitsabfrage und den vollständigen Attribut-Snapshot. Jeder Datensatz
/// muss wieder den exakt erwarteten rohen Pfad tragen; damit können weder
/// Zeilenumbrüche noch ein unerwarteter zweiter Pfad die Entscheidung
/// verschieben.
enum GitConflictAttributeParser {
    private static let selectedNames = [
        "binary", "text", "diff", "merge", "conflict-marker-size"
    ]

    static func arguments(path: String) -> [String] {
        ["check-attr", "-z"] + selectedNames + ["--", path]
    }

    /// Die explizite Abfrage liefert auch für nicht gesetzte Attribute je
    /// einen Datensatz. So ist selbst der normale Textfall an den erwarteten
    /// rohen Pfad gebunden und kein leeres stdout wird als Beweis missverstanden.
    static func parseSelected(_ data: Data,
                              expectedRawPath: Data) -> GitConflictAttributes? {
        guard let values = parseRecords(data, expectedRawPath: expectedRawPath,
                                        allowsEmpty: false),
              Set(values.keys) == Set(selectedNames) else { return nil }
        return classification(values)
    }

    static func parseAll(_ data: Data, expectedRawPath: Data) -> GitConflictAttributes? {
        guard let values = parseRecords(data, expectedRawPath: expectedRawPath,
                                        allowsEmpty: true) else { return nil }
        return classification(values)
    }

    private static func parseRecords(_ data: Data, expectedRawPath: Data,
                                     allowsEmpty: Bool) -> [String: String]? {
        guard !expectedRawPath.isEmpty, !expectedRawPath.contains(0) else { return nil }
        if data.isEmpty { return allowsEmpty ? [:] : nil }
        guard data.last == 0 else { return nil }
        var fields = Array(data).split(separator: UInt8(0),
                                       omittingEmptySubsequences: false)
            .map { Data($0) }
        guard fields.last?.isEmpty == true else { return nil }
        fields.removeLast()
        guard !fields.isEmpty, fields.count.isMultiple(of: 3) else { return nil }

        var values: [String: String] = [:]
        for index in stride(from: 0, to: fields.count, by: 3) {
            guard fields[index] == expectedRawPath,
                  let attribute = String(data: fields[index + 1], encoding: .utf8),
                  let value = String(data: fields[index + 2], encoding: .utf8),
                  !attribute.isEmpty,
                  values.updateValue(value, forKey: attribute) == nil else {
                return nil
            }
        }
        return values
    }

    private static func classification(_ values: [String: String])
        -> GitConflictAttributes? {
        let markerSize: Int
        if let rawSize = values["conflict-marker-size"] {
            if rawSize == "unspecified" || rawSize == "unset" {
                markerSize = 7
            } else {
                guard let size = Int(rawSize), size > 0, size <= 1024 else { return nil }
                markerSize = size
            }
        } else {
            markerSize = 7
        }

        func isSet(_ name: String) -> Bool {
            guard let value = values[name] else { return false }
            return value != "unset" && value != "unspecified"
        }
        // `binary` ist Gits eingebautes Makro für -diff/-merge/-text. Auch
        // einzeln gesetzte binäre Semantik bleibt bewusst im Terminalpfad.
        let isBinary = isSet("binary")
            || values["text"] == "unset"
            || values["diff"] == "unset"
            || values["merge"] == "unset"
            || values["merge"] == "binary"
        return GitConflictAttributes(markerSize: markerSize, isBinary: isBinary)
    }
}

/// Ein Konfliktblock im normalen Editor. Alle Bereiche sind UTF-16-`NSRange`s,
/// weil genau diese Koordinaten von `NSTextView` und CodeEditTextView verwendet
/// werden. Die Inhaltsbereiche enthalten niemals die Markerzeilen selbst.
struct ConflictMarkerBlock: Equatable, Identifiable {
    let id: Int
    let fullRange: NSRange
    let upperRange: NSRange
    let baseRange: NSRange?
    let lowerRange: NSRange
    let upperLabel: String?
    let baseLabel: String?
    let lowerLabel: String?
    let startLine: Int
    let endLine: Int
}

enum ConflictMarkerParseResult: Equatable {
    case parsed([ConflictMarkerBlock])
    case unsafe(String)

    var blocks: [ConflictMarkerBlock] {
        if case .parsed(let blocks) = self { return blocks }
        return []
    }
}

enum ConflictResolutionChoice: Equatable {
    case upper
    case lower
    case both
}

struct ConflictMarkerReplacement: Equatable {
    let range: NSRange
    let replacement: String
    let cursorLocation: Int
}

/// Parser für Git-Konfliktmarker mit normalem und diff3-Aufbau. Er arbeitet auf
/// Zeilenbereichen des unveränderten Strings und normalisiert daher weder LF,
/// CRLF noch ein fehlendes finales Zeilenende.
enum ConflictMarkerParser {
    private struct Line {
        let contentRange: NSRange
        let wholeRange: NSRange
        let text: String
        let number: Int
    }

    private enum Marker {
        case start(width: Int, label: String?)
        case base(width: Int, label: String?)
        case separator(width: Int)
        case end(width: Int, label: String?)
    }

    static func parse(_ text: String, markerSize: Int = 7) -> ConflictMarkerParseResult {
        guard markerSize > 0 else {
            return .unsafe(L10n.string("Die konfigurierte Konfliktmarker-Breite ist ungültig."))
        }
        let lines = splitLines(text)
        var blocks: [ConflictMarkerBlock] = []
        var index = 0
        while index < lines.count {
            guard let openingMarker = marker(in: lines[index].text, size: markerSize) else {
                index += 1
                continue
            }
            guard case .start(let width, let upperLabel) = openingMarker else {
                // Auch nach einem bereits vollständigen Block darf keine
                // einzelne Steuerzeile als normaler Text durchrutschen.
                return .unsafe(L10n.string("Die Datei enthält unvollständige Konfliktmarker."))
            }

            let start = lines[index]
            var cursor = index + 1
            var baseLine: Line?
            var baseLabel: String?
            var separatorLine: Line?
            var endLine: Line?
            var lowerLabel: String?

            while cursor < lines.count {
                guard let current = marker(in: lines[cursor].text, size: markerSize) else {
                    cursor += 1
                    continue
                }
                switch current {
                case .start:
                    return .unsafe(L10n.string("Verschachtelte Konfliktmarker können nicht sicher aufgelöst werden."))
                case .base(let candidateWidth, let label):
                    guard candidateWidth == width, baseLine == nil, separatorLine == nil else {
                        return .unsafe(L10n.string("Der Konfliktmarker-Aufbau ist unvollständig oder widersprüchlich."))
                    }
                    baseLine = lines[cursor]
                    baseLabel = label
                case .separator(let candidateWidth):
                    guard candidateWidth == width, separatorLine == nil else {
                        return .unsafe(L10n.string("Der Konfliktmarker-Aufbau ist unvollständig oder widersprüchlich."))
                    }
                    separatorLine = lines[cursor]
                case .end(let candidateWidth, let label):
                    guard candidateWidth == width, separatorLine != nil else {
                        return .unsafe(L10n.string("Der Konfliktmarker-Aufbau ist unvollständig oder widersprüchlich."))
                    }
                    endLine = lines[cursor]
                    lowerLabel = label
                }
                if endLine != nil { break }
                cursor += 1
            }

            guard let separatorLine, let endLine else {
                return .unsafe(L10n.string("Ein Konfliktmarker endet nicht vollständig. Die Datei wurde nicht verändert."))
            }
            let upperEnd = baseLine?.wholeRange.location ?? separatorLine.wholeRange.location
            let upperStart = NSMaxRange(start.wholeRange)
            let lowerStart = NSMaxRange(separatorLine.wholeRange)
            let baseRange = baseLine.map {
                NSRange(location: NSMaxRange($0.wholeRange),
                        length: separatorLine.wholeRange.location - NSMaxRange($0.wholeRange))
            }
            guard upperEnd >= upperStart,
                  endLine.wholeRange.location >= lowerStart else {
                return .unsafe(L10n.string("Der Konflikt enthält ungültige Textbereiche. Die Datei wurde nicht verändert."))
            }
            blocks.append(ConflictMarkerBlock(
                id: blocks.count,
                fullRange: NSRange(location: start.wholeRange.location,
                                   length: NSMaxRange(endLine.wholeRange) - start.wholeRange.location),
                upperRange: NSRange(location: upperStart, length: upperEnd - upperStart),
                baseRange: baseRange,
                lowerRange: NSRange(location: lowerStart,
                                    length: endLine.wholeRange.location - lowerStart),
                upperLabel: upperLabel,
                baseLabel: baseLabel,
                lowerLabel: lowerLabel,
                startLine: start.number,
                endLine: endLine.number
            ))
            index = cursor + 1
        }

        return .parsed(blocks)
    }

    static func replacement(in text: String, block: ConflictMarkerBlock,
                            choice: ConflictResolutionChoice) -> ConflictMarkerReplacement? {
        let source = text as NSString
        guard NSMaxRange(block.fullRange) <= source.length,
              NSMaxRange(block.upperRange) <= source.length,
              NSMaxRange(block.lowerRange) <= source.length else { return nil }
        let upper = source.substring(with: block.upperRange)
        let lower = source.substring(with: block.lowerRange)
        let replacement: String
        switch choice {
        case .upper: replacement = upper
        case .lower: replacement = lower
        case .both: replacement = upper + lower
        }
        return ConflictMarkerReplacement(range: block.fullRange,
                                         replacement: replacement,
                                         cursorLocation: block.fullRange.location)
    }

    static func containsPotentialMarkers(_ text: String, markerSize: Int = 7) -> Bool {
        splitLines(text).contains { marker(in: $0.text, size: markerSize) != nil }
    }

    /// Vor `git add` konservativer als der Parser: Auch Markerbreiten, die
    /// nicht dem aktuell aufgelösten Attribut entsprechen, brauchen eine
    /// bewusste Ausnahme. Das schützt echte Inhalte mit 1/3/7/32 Zeichen ebenso
    /// wie nachträglich geänderte Attribute.
    static func containsMarkerLikeLines(_ text: String) -> Bool {
        splitLines(text).contains { line in
            [Character("<"), "|", "=", ">"].contains { character in
                let run = line.text.prefix { $0 == character }
                guard !run.isEmpty else { return false }
                let remainder = line.text.dropFirst(run.count)
                if character == "=" { return remainder.isEmpty }
                return remainder.isEmpty || remainder.first == " " || remainder.first == "\t"
            }
        }
    }

    private static func splitLines(_ text: String) -> [Line] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var lines: [Line] = []
        var location = 0
        var number = 1
        while location < ns.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: location, length: 0))
            let contentRange = NSRange(location: lineStart,
                                       length: contentsEnd - lineStart)
            lines.append(Line(contentRange: contentRange,
                              wholeRange: NSRange(location: lineStart,
                                                  length: lineEnd - lineStart),
                              text: ns.substring(with: contentRange), number: number))
            location = lineEnd
            number += 1
        }
        return lines
    }

    private static func marker(in line: String, size: Int) -> Marker? {
        func parse(_ character: Character, allowsLabel: Bool = true) -> (Int, String?)? {
            let run = line.prefix { $0 == character }
            guard run.count == size else { return nil }
            let remainder = line.dropFirst(run.count)
            if !allowsLabel { return remainder.isEmpty ? (run.count, nil) : nil }
            guard remainder.isEmpty || remainder.first == " " || remainder.first == "\t"
            else { return nil }
            let label = remainder.trimmingCharacters(in: .whitespaces)
            return (run.count, label.isEmpty ? nil : label)
        }
        if let (width, label) = parse("<") { return .start(width: width, label: label) }
        if let (width, label) = parse("|") { return .base(width: width, label: label) }
        if let (width, _) = parse("=", allowsLabel: false) { return .separator(width: width) }
        if let (width, label) = parse(">") { return .end(width: width, label: label) }
        return nil
    }
}

/// Adressierter Auftrag an den tatsächlich sichtbaren CodeEdit-`NSTextView`.
/// Nur dieser Pfad erzeugt eine native Undo-Aktion; ein reiner Binding-Ersatz
/// würde den Editorzustand und dessen Undo-Manager umgehen.
final class ConflictEditorReplacementRequest {
    weak var workspace: Workspace?
    let tabID: UUID
    let expectedText: String
    let range: NSRange
    let replacement: String
    let selectionAfterReplacement: NSRange
    let completion: (String) -> Void

    init(workspace: Workspace, tabID: UUID, expectedText: String,
         replacement: ConflictMarkerReplacement,
         completion: @escaping (String) -> Void) {
        self.workspace = workspace
        self.tabID = tabID
        self.expectedText = expectedText
        self.range = replacement.range
        self.replacement = replacement.replacement
        self.selectionAfterReplacement = NSRange(
            location: replacement.cursorLocation,
            length: (replacement.replacement as NSString).length
        )
        self.completion = completion
    }
}

typealias ConflictTextReplacementHandler = (ConflictEditorReplacementRequest) -> Void

enum ConflictEditorBridge {
    static func post(_ request: ConflictEditorReplacementRequest) {
        NotificationCenter.default.post(name: .fastraReplaceConflictText,
                                        object: request)
    }
}

enum ConflictNativeTextMutation {
    @discardableResult
    static func apply(_ request: ConflictEditorReplacementRequest,
                      to textView: CodeEditTextView.TextView) -> Bool {
        let length = (textView.string as NSString).length
        guard textView.string == request.expectedText,
              request.range.location >= 0, NSMaxRange(request.range) <= length else {
            return false
        }
        textView.replaceCharacters(in: request.range, with: request.replacement)
        let newLength = (textView.string as NSString).length
        let location = min(max(0, request.selectionAfterReplacement.location), newLength)
        let safeSelection = NSRange(
            location: location,
            length: min(max(0, request.selectionAfterReplacement.length), newLength - location)
        )
        textView.selectionManager.setSelectedRange(safeSelection)
        textView.scrollToRange(safeSelection)
        request.completion(textView.string)
        return true
    }
}

extension Notification.Name {
    static let fastraReplaceConflictText = Notification.Name("fastra.conflict.replace")
}
