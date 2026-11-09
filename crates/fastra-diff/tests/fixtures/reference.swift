import Foundation
// Die unbenutzten UI-/Dateiquelltypen werden nur für die Originalmodule bereitgestellt.
enum L10n { static func string(_ value: String) -> String { value } }
enum FileLoader { static let largeFileThreshold = 32 * 1024 * 1024 }
struct FileDiffDocumentOrigin: Hashable, Sendable { func matchesLogically(_ other: Self) -> Bool { true } }
struct FileDiffSource: Hashable, Sendable {}
enum GitDiffParser {
    static func intraline(_ a: String, _ b: String) -> (before: Range<Int>?, after: Range<Int>?, wasLimited: Bool) { (nil, nil, false) }
}
struct Row: Codable { let left: Int?; let right: Int?; let kind: String; let ignored: Bool }
struct Block: Codable { let start: Int; let end: Int; let kind: String }
struct Transfer: Codable { let block: Int; let toLeft: Bool; let output: String; let replacement: String; let location: Int; let length: Int }
struct Vector: Codable { let left: String; let right: String; let options: [Bool]; let rows: [Row]; let blocks: [Block]; let transfers: [Transfer] }
@main struct Reference {
    static func main() throws {
        if CommandLine.arguments.contains("--large") { try large(); return }
        var vectors: [Vector] = []
        func add(_ left: String, _ right: String, _ options: FileDiffOptions = FileDiffOptions()) throws {
            guard case .result(let result) = FileDiff.compare(left: left, right: right, options: options) else { fatalError("reference limitation") }
            var transfers: [Transfer] = []
            for block in result.blocks {
                for direction in [FileDiffTransfer.Direction.toLeft, .toRight] {
                    do {
                        let t = try FileDiffTransfer.prepare(left: left, right: right, result: result, blockID: block.id, direction: direction)
                        transfers.append(Transfer(block: block.id, toLeft: direction == .toLeft, output: t.output, replacement: t.replacement, location: t.range.location, length: t.range.length))
                    } catch FileDiffTransfer.Failure.noChange { }
                }
            }
            vectors.append(Vector(left: left, right: right, options: [options.ignoreTrailingWhitespace,options.ignoreAllWhitespace,options.ignoreBlankLines,options.ignoreCase], rows: result.rows.map { Row(left: $0.beforeLine, right: $0.afterLine, kind: String(describing: $0.kind), ignored: $0.isIgnoredBlank) }, blocks: result.blocks.map { Block(start: $0.firstRowID, end: $0.lastRowID+1, kind: String(describing: $0.kind)) }, transfers: transfers))
        }
        for (a,b) in [("",""),("","🙂"),("🙂",""),("a\nb\nc","a\nx\nc"),("a\nb\nc","a\nc"),("a\nc","a\nb\nc"),("start\nold1\nold2\nend","start\nnew1\nnew2\nnew3\nend"),("a\r\nold\r\nz\r\n","a\nnew\nz\n"),("é\nold","e\u{301}\nnew"),("é","e\u{301}"),("a\r\nb","a\nb")] { try add(a,b) }
        for separator in ["\n","\r","\r\n","\u{85}","\u{2028}","\u{2029}"] {
            for (a,b) in [("a","a"+separator+"b"),("a"+separator+"b","a"),("a"+separator+"b"+separator+"c","a"),("a"+separator+"b","a"+separator),("a","a"+separator),("a"+separator,"a")] { try add(a,b) }
        }
        try add("a\n\nold\nz","a\nnew\nz",FileDiffOptions(ignoreBlankLines:true))
        try add("a\nx\n\n","a\ny",FileDiffOptions(ignoreBlankLines:true))
        try add("a  \nold\nz","A\nnew\nz",FileDiffOptions(ignoreTrailingWhitespace:true,ignoreCase:true))
        try add("a \t b\nΟΣ","ab\nος",FileDiffOptions(ignoreAllWhitespace:true,ignoreCase:true))
        try add("A\n\nB","a\nb",FileDiffOptions(ignoreBlankLines:true,ignoreCase:true))
        var state: UInt64 = 12345
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
        for _ in 0..<200 {
            let a = (0..<Int(next()%14)).map { _ in String(next()%4) }.joined(separator:"\n")
            let b = (0..<Int(next()%14)).map { _ in String(next()%4) }.joined(separator:"\n")
            try add(a,b)
        }
        let encoder = JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        print(String(data:try encoder.encode(vectors),encoding:.utf8)!)
    }
    static func large() throws {
        var summaries: [[String:Any]] = []
        let left = (0..<40000).map { "line \($0)" }.joined(separator:"\n") + "\n"
        for mode in ["spread", "rotation"] {
            let order = mode == "rotation" ? Array(20000..<40000) + Array(0..<20000) : Array(0..<40000)
            let right = order.map { mode == "spread" && $0 % 1000 == 0 ? "changed \($0)" : "line \($0)" }.joined(separator:"\n") + "\n"
            guard case .result(let result) = FileDiff.compare(left:left,right:right) else { fatalError("large reference limitation") }
            summaries.append(["mode":mode,"rowCount":result.rows.count,"leftCount":result.leftLineCount,"rightCount":result.rightLineCount,"blocks":result.blocks.map { ["start":$0.firstRowID,"end":$0.lastRowID+1,"kind":String(describing:$0.kind)] }])
        }
        print(String(data: try JSONSerialization.data(withJSONObject:summaries,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    }

}
