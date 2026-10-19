import Foundation
import Testing
@testable import Fastra

@Suite("Markdown-Formelbereiche")
struct MarkdownMathTests {
    // Unveränderte Syntax vor der Leistungsreparatur als unabhängige Referenz.
    private static let reference = [
        #"(?ms)(^|\n)([ \t]{0,3})(`{3,}|~{3,})[^\n]*\n.*?\n[ \t]{0,3}\3[ \t]*(?=\n|$)"#,
        #"`+[^`\n]*`+"#,
        #"(?ms)^[ \t]*\$\$[ \t]*(?:\n)?(.+?)(?:\n)?[ \t]*\$\$[ \t]*$"#,
        #"(?<!\\)\$\$(?!\s)(.+?)(?<!\s)\$\$"#,
        #"(?<![\\$])\$(?![\s$])([^$\n]+?)(?<![\s$])\$(?!\$)"#
    ].map { try! NSRegularExpression(pattern: $0) }

    private func referenceRanges(_ source: String) -> [NSRange] {
        let ranges = Self.reference.map {
            $0.matches(in: source, range: NSRange(location: 0, length: source.utf16.count)).map(\.range)
        }
        let code = ranges[0] + ranges[1]
        return ranges.dropFirst(2).flatMap { $0 }.filter { candidate in
            !code.contains { NSIntersectionRange($0, candidate).length > 0 }
        }
    }

    @Test("Die bisherige Formel-Syntax bleibt bei gemischten und unvollständigen Markern erhalten")
    func syntaxParity() {
        var seed: UInt64 = 127
        func next(_ count: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(count))
        }
        let chunks = ["$", "$$", "$$$$$", "`", "```\n", "````a\n", "~~~\n", "~~~~\n",
                      "a\n", "\n", "$$\n", "$$x$$\n", "\t```\n", "    ```\n", "``` \u{2028}",
                      "`$x$`\n", " ", "\t", "\\", "😀", "\u{85}", "\u{2029}"]
        let examples = ["$$$$$", "$$\n$$\n$$", "````\nx\n```\ny\n````",
                        "`$x$`\n$$\n```\n~~~~\n``` \u{2028}~~~\n~~~~\n$$\n\n\t```\n~~~\n"]
        for source in examples {
            #expect(MarkdownMath.formulaRanges(in: source) == referenceRanges(source))
        }
        for _ in 0..<2_000 {
            let source = (0..<next(20)).map { _ in chunks[next(chunks.count)] }.joined()
            #expect(MarkdownMath.formulaRanges(in: source) == referenceRanges(source), "\(source.debugDescription)")
        }
    }

    @Test("Große unvollständige Markerfolgen liefern vollständige Bereiche")
    func repeatedMarkers() {
        #expect(MarkdownMath.formulaRanges(in: String(repeating: "```a\n![x](no)\n", count: 20_000)).isEmpty)
        #expect(MarkdownMath.formulaRanges(in: String(repeating: "$$a$ [x](target) `a` ", count: 20_000)).isEmpty)
        let ranges = MarkdownMath.formulaRanges(in: String(repeating: "`x` $a$ ", count: 100_000))
        #expect(ranges.count == 100_000)
        #expect(ranges.first == NSRange(location: 4, length: 3))
        #expect(ranges.last == NSRange(location: 799_996, length: 3))
    }

    @Test("Ein Abbruch beendet die Formelbereichsanalyse ohne Teilergebnis")
    func cancellation() {
        let source = String(repeating: "```a\n![x](no)\n", count: 20_000)
        var checks = 0
        #expect(throws: CancellationError.self) {
            try MarkdownMath.formulaRanges(in: source) {
                checks += 1
                if checks == 20 { throw CancellationError() }
            }
        }
        #expect(checks == 20)
    }

    @Test("Viele Blockformeln erhalten jedes HTML-Ziel und die nachfolgenden Quellzeilen")
    func manyBlockFormulas() {
        let source = (0..<1_000).map { "$$\nx_\($0)\n$$\n\nLine\($0)\n" }.joined()
        let extraction = MarkdownMath.extract(from: source)
        let html = extraction.insertingHTML(into: extraction.markdown)
        #expect(html.components(separatedBy: "class=\"math-block\"").count - 1 == 1_000)
        #expect(html.contains("data-tex=\"x_999\""))
        let preparedLine = extraction.markdown.components(separatedBy: "\n").firstIndex(of: "Line999")!
        #expect(extraction.originalLine(for: preparedLine + 1) == 5_000)
    }

}
