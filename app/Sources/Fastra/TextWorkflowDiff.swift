import Foundation

enum TextWorkflowDiff {
    struct Result {
        let document: FileDiffDocument
        let hasAnnotations: Bool
    }

    static func build(before: String, after: String, maximumDisplayBytes: Int = 4 * 1024 * 1024,
                      maximumTotalDisplayBytes: Int? = nil,
                      isCancelled: () -> Bool = { false }) throws -> Result {
        let outcome = try FileDiff.compare(left: before, right: after, isCancelled: isCancelled)
        guard case .result(let original) = outcome else {
            if case .limitation(let reason) = outcome { return Result(document: .failure(reason), hasAnnotations: false) }
            preconditionFailure("Unbekanntes Vergleichsergebnis")
        }
        let leftEndings = try endings(before, isCancelled: isCancelled)
        let rightEndings = try endings(after, isCancelled: isCancelled)
        var rows: [FileDiff.Row] = [], annotated = false
        var leftBytes = original.rows.reduce(0) { $0 + ($1.before?.utf8.count ?? 0) }
        var rightBytes = original.rows.reduce(0) { $0 + ($1.after?.utf8.count ?? 0) }
        let totalLimit = maximumTotalDisplayBytes ?? Int.max
        guard leftBytes <= maximumDisplayBytes, rightBytes <= maximumDisplayBytes,
              leftBytes <= totalLimit - rightBytes else { throw TextWorkflowError.sizeLimit }
        func room(sideBytes: Int, replacing bytes: Int) -> Int {
            min(maximumDisplayBytes - sideBytes + bytes, totalLimit - leftBytes - rightBytes + bytes)
        }
        for row in original.rows {
            if row.id % 128 == 0, isCancelled() { throw CancellationError() }
            guard let left = row.before, let right = row.after, let leftLine = row.beforeLine, let rightLine = row.afterLine else {
                let value = row.before ?? row.after ?? ""
                let unicode = value.unicodeScalars.contains { $0.value < 0x20 || $0.value > 0x7E }
                let isLeft = row.before != nil
                let line = row.beforeLine ?? row.afterLine
                let ending = line.map { (isLeft ? leftEndings : rightEndings)[$0 - 1] }
                let rendered = try display(value, ending: ending, unicode: unicode,
                    remainingBytes: room(sideBytes: isLeft ? leftBytes : rightBytes, replacing: value.utf8.count),
                    isCancelled: isCancelled)
                if isLeft { leftBytes += rendered.utf8.count - value.utf8.count }
                else { rightBytes += rendered.utf8.count - value.utf8.count }
                annotated = annotated || unicode || ending != nil
                rows.append(FileDiff.Row(id: row.id, beforeLine: row.beforeLine, afterLine: row.afterLine,
                    before: isLeft ? rendered : nil, after: isLeft ? nil : rendered, kind: row.kind,
                    beforeHighlight: isLeft ? 0..<rendered.count : nil, afterHighlight: isLeft ? nil : 0..<rendered.count,
                    intralineWasLimited: row.intralineWasLimited, isIgnoredBlank: false))
                continue
            }
            let leftEnding = leftEndings[leftLine-1], rightEnding = rightEndings[rightLine-1]
            let contentChanged = !left.utf8.elementsEqual(right.utf8), endingChanged = leftEnding != rightEnding
            guard contentChanged || endingChanged else {
                rows.append(row); continue
            }
            // Der allgemeine Dateivergleich behandelt kanonisch gleiche
            // Zeichen und CR/LF als gleich. Eine schreibende Ablaufvorschau
            // muss auch diese Änderungen sichtbar und vollständig zeigen.
            let unicode = contentChanged && [left, right].contains { text in
                text.unicodeScalars.contains { $0.value < 0x20 || $0.value > 0x7E }
            }
            let leftDisplay = try display(left, ending: endingChanged ? leftEnding : nil, unicode: unicode,
                                          remainingBytes: room(sideBytes: leftBytes, replacing: left.utf8.count), isCancelled: isCancelled)
            leftBytes += leftDisplay.utf8.count-left.utf8.count
            let rightDisplay = try display(right, ending: endingChanged ? rightEnding : nil, unicode: unicode,
                                           remainingBytes: room(sideBytes: rightBytes, replacing: right.utf8.count), isCancelled: isCancelled)
            rightBytes += rightDisplay.utf8.count-right.utf8.count
            annotated = annotated || unicode || endingChanged
            rows.append(FileDiff.Row(id: row.id, beforeLine: row.beforeLine, afterLine: row.afterLine,
                before: leftDisplay, after: rightDisplay, kind: .changed,
                beforeHighlight: unicode || endingChanged ? 0..<leftDisplay.count : row.beforeHighlight,
                afterHighlight: unicode || endingChanged ? 0..<rightDisplay.count : row.afterHighlight,
                intralineWasLimited: row.intralineWasLimited, isIgnoredBlank: false))
        }
        guard leftBytes <= maximumDisplayBytes, rightBytes <= maximumDisplayBytes,
              leftBytes <= totalLimit - rightBytes else { throw TextWorkflowError.sizeLimit }
        let blocks = try FileDiff.blocks(for: rows, isCancelled: isCancelled)
        return Result(document: .success(FileDiff.Result(rows: rows, blocks: blocks,
            leftLineCount: original.leftLineCount, rightLineCount: original.rightLineCount)), hasAnnotations: annotated)
    }

    private static func display(_ text: String, ending: String?, unicode: Bool, remainingBytes: Int,
                                isCancelled: () -> Bool) throws -> String {
        let endingLabel: String
        switch ending {
        case "\r\n": endingLabel = "CRLF"
        case "\r": endingLabel = "CR"
        case "\n": endingLabel = "LF"
        case "": endingLabel = "EOF"
        case .some(let value): endingLabel = value.unicodeScalars.map { "U+" + String($0.value, radix: 16, uppercase: true) }.joined(separator: " ")
        case nil: endingLabel = ""
        }
        let suffix = ending == nil ? "" : " ⟦" + endingLabel + "⟧"
        var bytes = text.utf8.count + suffix.utf8.count + (unicode ? " ⟦⟧".utf8.count : 0)
        guard bytes <= remainingBytes else { throw TextWorkflowError.sizeLimit }
        func escaped(_ scalar: Unicode.Scalar) -> String {
            if scalar.value == 0x5C { return "\\\\" }
            if (0x20...0x7E).contains(scalar.value) { return String(scalar) }
            return "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
        }
        if unicode {
            for (index, scalar) in text.unicodeScalars.enumerated() {
                if index % 2048 == 0, isCancelled() { throw CancellationError() }
                bytes += escaped(scalar).utf8.count
                guard bytes <= remainingBytes else { throw TextWorkflowError.sizeLimit }
            }
        }
        var output = text
        if unicode {
            var detail = ""
            for (index, scalar) in text.unicodeScalars.enumerated() {
                if index % 2048 == 0, isCancelled() { throw CancellationError() }
                detail += escaped(scalar)
            }
            output += " ⟦" + detail + "⟧"
        }
        return output + suffix
    }

    private static func endings(_ text: String, isCancelled: () -> Bool) throws -> [String] {
        let ns = text as NSString
        guard ns.length > 0 else { return [""] }
        var result: [String] = [], offset = 0, finalEnding = false
        while offset < ns.length {
            if result.count % 2048 == 0, isCancelled() { throw CancellationError() }
            var end = 0, contentEnd = 0
            ns.getLineStart(nil, end: &end, contentsEnd: &contentEnd, for: NSRange(location: offset, length: 0))
            result.append(ns.substring(with: NSRange(location: contentEnd, length: end-contentEnd)))
            finalEnding = contentEnd < end; offset = end
        }
        if finalEnding { result.append("") }
        return result
    }
}
