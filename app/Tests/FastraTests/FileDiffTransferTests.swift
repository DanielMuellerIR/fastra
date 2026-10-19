import Foundation
import Testing
@testable import Fastra

@Suite("Exakte Einzelübernahme im Dateivergleich")
struct FileDiffTransferTests {
    struct Example: Sendable {
        let target: String
        let source: String
        let expected: String
        var options = FileDiffOptions()
    }

    @Test("Einzelblöcke erhalten unberührte Zeilen und exakte Dateigrenzen", arguments: [
        Example(target: "a\r\nold\r\nz\r\n", source: "a\nnew\nz\n", expected: "a\r\nnew\nz\r\n"),
        Example(target: "a\nz\n", source: "a\nx\nz\n", expected: "a\nx\nz\n"),
        Example(target: "a\nx\nz\n", source: "a\nz\n", expected: "a\nz\n"),
        Example(target: "a", source: "a\nb", expected: "a\nb"),
        Example(target: "a", source: "a\n", expected: "a\n"),
        Example(target: "a\n", source: "a", expected: "a"),
        Example(target: "a\r\nb", source: "a\r\nb\r\n", expected: "a\r\nb\r\n"),
        Example(target: "", source: "🙂", expected: "🙂"),
        Example(target: "🙂", source: "", expected: ""),
        Example(target: "a\n", source: "a\n\n", expected: "a\n\n"),
        Example(target: "a\n\n", source: "a\n", expected: "a\n"),
        Example(target: "a  \nold\nz", source: "A\nnew\nz", expected: "a  \nnew\nz",
                options: FileDiffOptions(ignoreTrailingWhitespace: true, ignoreCase: true)),
        Example(target: "a\n\nold\nz", source: "a\nnew\nz", expected: "a\n\nnew\nz",
                options: FileDiffOptions(ignoreBlankLines: true)),
        Example(target: "a\nx\n\n", source: "a\ny", expected: "a\ny\n\n",
                options: FileDiffOptions(ignoreBlankLines: true))
    ])
    func transfer(_ example: Example) throws {
        for direction in [FileDiffTransfer.Direction.toLeft, .toRight] {
            let left = direction == .toLeft ? example.target : example.source
            let right = direction == .toLeft ? example.source : example.target
            guard case .result(let result) = FileDiff.compare(left: left, right: right, options: example.options) else {
                Issue.record("Kleiner Vergleich liefert keine vollständige Basis"); return
            }
            #expect(result.blocks.count == 1)
            let change = try FileDiffTransfer.prepare(left: left, right: right, result: result, blockID: 0, direction: direction)
            #expect(change.output.utf8.elementsEqual(example.expected.utf8))
        }
    }

    @Test("Byteverschiedene kanonisch gleiche Quellen entwerten einen alten Diff")
    func staleUnicode() throws {
        guard case .result(let result) = FileDiff.compare(left: "é", right: "new") else { return }
        #expect(throws: FileDiffTransfer.Failure.stale) {
            try FileDiffTransfer.prepare(left: "e\u{301}", right: "new", result: result, blockID: 0, direction: .toLeft)
        }
    }

    @Test("EOF-Verbindungen erhalten auch CR und Unicode-Zeilentrenner", arguments: ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"])
    func terminators(_ separator: String) throws {
        for example in [
            Example(target: "a", source: "a" + separator + "b", expected: "a" + separator + "b"),
            Example(target: "a", source: "a" + separator, expected: "a" + separator),
            Example(target: "a" + separator, source: "a", expected: "a")
        ] { try transfer(example) }
    }

    @Test("Ein einzelner wachsender Block darf das gemeinsame Ausgabelimit nicht umgehen")
    func outputLimit() throws {
        let left = "AAAAAA\nsep\nx\n", right = "a\nsep\nyyyyyy\n"
        guard case .result(let result) = FileDiff.compare(left: left, right: right) else { return }
        #expect(result.blocks.count == 2)
        #expect(throws: FileDiffTransfer.Failure.sizeLimit) {
            try FileDiffTransfer.prepare(left: left, right: right, result: result, blockID: 1, direction: .toLeft,
                                         maximumTextBytes: left.utf8.count)
        }
        #expect(throws: CancellationError.self) {
            try FileDiffTransfer.prepare(left: left, right: right, result: result, blockID: 1, direction: .toLeft,
                                         isCancelled: { true })
        }
    }

    @Test("Sehr viele kurze Zeilen erreichen die erklärte Grenze vor vollständiger Zeilenaufbereitung")
    func lineMapStopsAtLimit() throws {
        let input = String(repeating: "\n", count: 1_000_000)
        var checks = 0, returnedCount: Int?
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let map = try FileDiffLineMap(input, isCancelled: { checks += 1; return false })
            returnedCount = map.lines.count
        } catch let limitation as FileDiffLimitation {
            #expect(limitation == .tooManyLines(side: .left, limit: FileDiff.maximumLineCount))
        }
        print("FILE_DIFF_LINE_BOUND bytes=\(input.utf8.count) returned=\(String(describing: returnedCount)) checks=\(checks) seconds=\(ProcessInfo.processInfo.systemUptime - started)")
        #expect(returnedCount == nil)
        #expect(checks <= FileDiff.maximumLineCount / FileDiff.cancellationCheckStride + 2)
    }
}
