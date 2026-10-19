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

        var textOperation: TextOpKind? { TextOpKind.allCases.first { String(describing: $0) == rawValue } }
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

    var searchOptions: SearchOptions {
        SearchOptions(find: find, replace: replacement, isRegex: regex, caseSensitive: caseSensitive,
                      wholeWord: wholeWord, treatWildcardLiterally: literalWildcard)
    }
}

enum TextWorkflowError: Error, Equatable {
    case invalidDefinition(String)
    case invalidStep(Int, String)
    case invalidSelection
    case sizeLimit
    case matchLimit
    case cancelled
    case timeout
    case invalidArchive
    case staleDefinition
    case duplicateName
}

enum TextWorkflowEngine {
    struct Limits: Sendable {
        var textBytes = 4 * 1024 * 1024
        var intermediateBytes = 16 * 1024 * 1024
        var retainedBytes = 32 * 1024 * 1024
        var previewBytes: Int? = nil
        var matches = 100_000
        var seconds: TimeInterval = 5
        static let standard = Limits()
    }
    struct StepPreview: Identifiable, Sendable {
        let id: UUID
        let index: Int
        let before: String
        let after: String
        let matches: Int?
        var changed: Bool { !before.utf8.elementsEqual(after.utf8) }
    }
    struct Preview: Sendable {
        let source: String
        let range: NSRange
        let replacement: String
        let output: String
        let steps: [StepPreview]
        let retainedUTF8Bytes: Int?
        var changed: Bool { !source.utf8.elementsEqual(output.utf8) }
    }

    static func validate(_ workflow: TextWorkflow) throws {
        guard !workflow.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              workflow.name.utf8.count <= 256, (1...32).contains(workflow.steps.count),
              Set(workflow.steps.map(\.id)).count == workflow.steps.count,
              workflow.steps.contains(where: \.enabled) else { throw TextWorkflowError.invalidDefinition(workflow.name) }
        for (index, step) in workflow.steps.enumerated() {
            guard [step.argument, step.find, step.replacement].allSatisfy({ $0.utf8.count <= 4096 }),
                  (1...16).contains(step.tabWidth), (1...16).contains(step.indentWidth),
                  (1...10_000).contains(step.wrapColumn) else { throw TextWorkflowError.invalidStep(index, "parameters") }
            guard step.enabled else { continue }
            do {
                switch step.kind {
                case .replace:
                    guard !step.find.isEmpty else { throw TextWorkflowError.invalidStep(index, "empty") }
                    _ = try SearchPlan(options: step.searchOptions)
                case .keepLinesMatching, .deleteLinesMatching:
                    guard !step.argument.isEmpty else { throw TextWorkflowError.invalidStep(index, "empty") }
                    _ = try NSRegularExpression(pattern: step.argument, options: .caseInsensitive)
                default: break
                }
            } catch let error as TextWorkflowError { throw error }
            catch { throw TextWorkflowError.invalidStep(index, error.localizedDescription) }
        }
    }

    static func preview(_ workflow: TextWorkflow, source: String, selection: NSRange? = nil,
                        limits: Limits = .standard, shouldCancel: () -> Bool = { false }) throws -> Preview {
        let deadline = ProcessInfo.processInfo.systemUptime + limits.seconds
        try validate(workflow)
        guard source.utf8.count <= limits.textBytes else { throw TextWorkflowError.sizeLimit }
        let ns = source as NSString, range = selection ?? NSRange(location: 0, length: ns.length)
        guard range.location >= 0, range.location != NSNotFound, range.length >= 0,
              range.location <= ns.length, range.length <= ns.length - range.location,
              selection == nil || range.length > 0, Range(range, in: source) != nil,
              range.length == 0 || ns.rangeOfComposedCharacterSequences(for: range) == range else { throw TextWorkflowError.invalidSelection }
        func check() throws {
            if shouldCancel() { throw TextWorkflowError.cancelled }
            if ProcessInfo.processInfo.systemUptime > deadline { throw TextWorkflowError.timeout }
        }
        var previewBytes = 0
        func account(_ byteCount: @autoclosure () -> Int) throws {
            guard let maximum = limits.previewBytes else { return }
            let bytes = byteCount()
            guard bytes <= maximum - previewBytes else { throw TextWorkflowError.sizeLimit }
            previewBytes += bytes
        }
        try account(source.utf8.count)
        var working = ns.substring(with: range), previews: [StepPreview] = [], retained = source.utf8.count
        for (index, step) in workflow.steps.enumerated() where step.enabled {
            try check()
            let before = working
            var matches: Int?
            if step.kind == .replace {
                let result = try replace(before, step: step, limits: limits, check: check)
                working = result.text; matches = result.count
            } else {
                working = try transform(before, step: step, limits: limits, check: check)
            }
            try check()
            guard working.utf8.count <= limits.textBytes else { throw TextWorkflowError.sizeLimit }
            if !working.utf8.elementsEqual(before.utf8) { retained += working.utf8.count }
            guard retained <= limits.retainedBytes else { throw TextWorkflowError.sizeLimit }
            // Mehrdatei-Vorschauen begrenzen alle gehaltenen Textfelder,
            // konservativ auch dann, wenn Swift deren Speicher momentan teilt.
            try account(before.utf8.count)
            try account(working.utf8.count)
            previews.append(StepPreview(id: step.id, index: index, before: before, after: working, matches: matches))
        }
        let outsideBytes = source.utf8.count - ns.substring(with: range).utf8.count
        guard working.utf8.count <= limits.textBytes - outsideBytes else { throw TextWorkflowError.sizeLimit }
        try account(working.utf8.count)
        try account(outsideBytes + working.utf8.count)
        let output = ns.replacingCharacters(in: range, with: working)
        return Preview(source: source, range: range, replacement: working, output: output, steps: previews,
                       retainedUTF8Bytes: limits.previewBytes == nil ? nil : previewBytes)
    }

    private static func transform(_ text: String, step: TextWorkflowStep, limits: Limits, check: () throws -> Void) throws -> String {
        let selection = NSRange(location: 0, length: 0)
        if step.kind == .detab {
            var bytes = text.utf8.count, column = 0
            for character in text {
                if character == "\t" {
                    let spaces = step.tabWidth - column % step.tabWidth
                    bytes += spaces - 1; column += spaces
                    guard bytes <= limits.intermediateBytes else { throw TextWorkflowError.sizeLimit }
                } else if character == "\r" || character == "\n" || character == "\r\n" { column = 0 }
                else { column += 1 }
            }
        }
        if [.prefixLines, .suffixLines, .shiftRight, .addLineNumbers].contains(step.kind) {
            let range = LineOperations.expandToFullLines(in: text, selection: selection)
            let (lines, _) = LineOperations.splitContentLines((text as NSString).substring(with: range), selection: selection)
            let addition: Int
            switch step.kind {
            case .shiftRight: addition = step.usesTabs ? 1 : step.indentWidth
            case .addLineNumbers: addition = String(lines.count).utf8.count + 2
            default: addition = step.argument.utf8.count
            }
            guard addition == 0 || lines.count <= max(0, limits.intermediateBytes - text.utf8.count) / addition else { throw TextWorkflowError.sizeLimit }
        }
        let result: LineOperations.Result?
        switch step.kind {
        case .sortAscending: result = LineOperations.sortLines(in: text, selection: selection, direction: .ascending)
        case .sortDescending: result = LineOperations.sortLines(in: text, selection: selection, direction: .descending)
        case .removeDuplicateLines: result = LineOperations.removeDuplicateLines(in: text, selection: selection)
        case .prefixLines: result = TextOperations.prefixLines(in: text, selection: selection, with: step.argument)
        case .suffixLines: result = TextOperations.suffixLines(in: text, selection: selection, with: step.argument)
        case .keepLinesMatching, .deleteLinesMatching:
            let regex = try NSRegularExpression(pattern: step.argument, options: step.caseSensitive ? [] : .caseInsensitive)
            result = try LineFilter.filter(in: text, selection: selection, keepMatching: step.kind == .keepLinesMatching) { line in
                var found = false, failure: Error?
                regex.enumerateMatches(in: line, options: .reportProgress, range: NSRange(location: 0, length: line.utf16.count)) { match, _, stop in
                    do {
                        try check()
                        if match != nil { found = true; stop.pointee = true }
                    } catch { failure = error; stop.pointee = true }
                }
                if let failure { throw failure }
                return found
            }
        case .hardWrap: result = try TextOperations.hardWrap(in: text, selection: selection, column: step.wrapColumn, check: check)
        default:
            guard let kind = step.kind.textOperation else { throw TextWorkflowError.invalidDefinition(step.kind.rawValue) }
            result = TextOperationTransform.operation(for: kind, profile: IndentationProfile(usesTabs: step.usesTabs, indentWidth: step.indentWidth, tabWidth: step.tabWidth))(text, selection)
        }
        let output = result?.newText ?? text
        if (step.kind == .prefixLines || step.kind == .suffixLines), step.argument.contains(where: \.isNewline) { return output }
        switch step.kind {
        case .sortAscending, .sortDescending, .reverseLines, .trimTrailing, .detab, .entab,
             .shiftRight, .shiftLeft, .prefixLines, .suffixLines, .addLineNumbers, .removeLineNumbers,
             .removeBlankLines, .removeDuplicateLines, .keepDuplicateLines, .removeAllDuplicatedLines,
             .keepLinesMatching, .deleteLinesMatching, .hardWrap:
            return try preservingLineEndings(of: text, in: output, check: check)
        default: return output
        }
    }

    /// Die Einzelbefehle bauen Zeilen mit einem gemeinsamen Trenner auf.
    /// Ein Ablauf auf Plattenbytes darf dadurch gemischte Endungen nicht
    /// nebenbei vereinheitlichen. Bei gleicher Zeilenzahl bleiben die exakten
    /// Trenner an ihren Positionen; ausdrücklich eingefügte Zeilen bleiben erhalten.
    private static func preservingLineEndings(of source: String, in output: String,
                                              check: () throws -> Void) throws -> String {
        let before = source as NSString, after = output as NSString
        var left = 0, right = 0, result = "", lines = 0
        while left < before.length && right < after.length {
            if lines % 2048 == 0 { try check() }
            var leftEnd = 0, leftContentEnd = 0, rightEnd = 0, rightContentEnd = 0
            before.getLineStart(nil, end: &leftEnd, contentsEnd: &leftContentEnd, for: NSRange(location: left, length: 0))
            after.getLineStart(nil, end: &rightEnd, contentsEnd: &rightContentEnd, for: NSRange(location: right, length: 0))
            result += after.substring(with: NSRange(location: right, length: rightContentEnd - right))
            result += before.substring(with: NSRange(location: leftContentEnd, length: leftEnd - leftContentEnd))
            left = leftEnd; right = rightEnd; lines += 1
        }
        return left == before.length && right == after.length ? result : output
    }

    private static func replace(_ text: String, step: TextWorkflowStep, limits: Limits,
                                check: () throws -> Void) throws -> (text: String, count: Int) {
        let plan = try SearchPlan(options: step.searchOptions), ns = text as NSString
        let budget = ReplacementBudget(regex: plan.regex, template: plan.replacementTemplate)
        var output = "", cursor = 0, count = 0, bytes = 0, failure: Error?
        func append(_ piece: String) throws {
            let size = piece.utf8.count
            guard size <= limits.textBytes - bytes else { throw TextWorkflowError.sizeLimit }
            output.append(piece); bytes += size
        }
        plan.regex.enumerateMatches(in: text, options: .reportProgress, range: NSRange(location: 0, length: ns.length)) { result, _, stop in
            do {
                try check()
                guard let result else { return }
                count += 1
                guard count <= limits.matches else { throw TextWorkflowError.matchLimit }
                try budget.check(result, in: ns, maximumBytes: limits.intermediateBytes)
                try append(ns.substring(with: NSRange(location: cursor, length: result.range.location - cursor)))
                try append(CaseTemplate.replacement(for: result, in: text, regex: plan.regex, template: plan.replacementTemplate))
                cursor = NSMaxRange(result.range)
            } catch { failure = error; stop.pointee = true }
        }
        if let failure { throw failure }
        try append(ns.substring(from: cursor))
        return (output, count)
    }

    // Foundation selbst löst die $N-Grammatik an kurzen Platzhaltern auf.
    // So wird eine riesige Backref-Wiederholung vor ihrer Allokation erkannt,
    // ohne eine zweite Ersetzungssprache mit abweichenden Regeln einzuführen.
    private struct ReplacementBudget {
        let references: [Int: Int]
        let literalBytes: Int
        init(regex: NSRegularExpression, template: String) {
            let prefix = "FASTRA" + UUID().uuidString + ":"
            var fake = "", ranges: [NSRange] = []
            for index in 0...regex.numberOfCaptureGroups {
                let token = prefix + String(index) + ";"
                ranges.append(NSRange(location: fake.utf16.count, length: token.utf16.count)); fake += token
            }
            let match: NSTextCheckingResult = ranges.withUnsafeMutableBufferPointer { buffer -> NSTextCheckingResult in
                NSTextCheckingResult.regularExpressionCheckingResult(ranges: buffer.baseAddress!, count: buffer.count, regularExpression: regex)
            }
            let expanded = CaseTemplate.pieces(of: template).compactMap { piece -> String? in
                guard case .text(let segment) = piece else { return nil }
                return regex.replacementString(for: match, in: fake, offset: 0, template: segment)
            }.joined()
            let pattern = try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: prefix) + "([0-9]+);")
            var refs: [Int: Int] = [:], literals = expanded.utf8.count
            for item in pattern.matches(in: expanded, range: NSRange(location: 0, length: expanded.utf16.count)) {
                let group = Int((expanded as NSString).substring(with: item.range(at: 1)))!
                refs[group, default: 0] += 1
                literals -= (expanded as NSString).substring(with: item.range).utf8.count
            }
            references = refs; literalBytes = literals
        }
        func check(_ match: NSTextCheckingResult, in text: NSString, maximumBytes: Int) throws {
            var size = literalBytes
            for (group, count) in references {
                let range = match.range(at: group)
                guard range.location != NSNotFound else { continue }
                let bytes = text.substring(with: range).utf8.count
                guard bytes == 0 || count <= max(0, maximumBytes - size) / bytes else { throw TextWorkflowError.sizeLimit }
                size += bytes * count
            }
            guard size <= maximumBytes else { throw TextWorkflowError.sizeLimit }
        }
    }
}
