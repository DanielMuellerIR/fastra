import Foundation
struct Parse: Codable { let input:String; let line:Int?; let column:Int? }
struct Jump: Codable { let text:String; let line:Int; let column:Int?; let offset:Int }
struct Reference: Codable { let parses:[Parse]; let jumps:[Jump]; let whitespace:[UInt32] }
enum BufferSearch {
    static func collectLineStarts(in ns: NSString) -> [Int] {
        // Die Live-Suche zählt inzwischen direkt bis zum aktuellen Treffer.
        // Diesen vollständigen Index brauchen nur noch Cursorberechnungen.
        var starts: [Int] = [0]
        let length = ns.length
        starts.reserveCapacity(length / 40)  // grobe Schätzung
        var index = 0
        while index < length {
            var end = NSNotFound
            ns.getLineStart(nil, end: &end, contentsEnd: nil,
                            for: NSRange(location: index, length: 0))
            // `end` = Start der nächsten Zeile (hinter dem Terminator).
            // Schutz gegen Stillstand/NSNotFound → Abbruch.
            if end == NSNotFound || end <= index { break }
            if end < length { starts.append(end) }
            index = end
        }
        return starts
    }
    static func nsRange(forLine line: Int, column: Int?, in text: String) -> NSRange {
        let ns = text as NSString
        let length = ns.length
        let lineStarts = collectLineStarts(in: ns)
        let safeLine = max(1, line)
        // Anfangs-Offset der gewünschten Zeile (jenseits Dok-Ende → Dok-Ende).
        let lineStart: Int = (safeLine - 1 < lineStarts.count) ? lineStarts[safeLine - 1] : length
        // Ende der Zeile VOR dem Terminator — über dieselbe NSString-API, die
        // CR/LF/CRLF/Unicode-Trenner einheitlich erkennt.
        var contentsEnd = NSNotFound
        if lineStart < length {
            ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd,
                            for: NSRange(location: lineStart, length: 0))
        }
        let lineEnd = (contentsEnd == NSNotFound) ? length : contentsEnd
        let col = max(1, column ?? 1)
        let offset = min(lineStart + col - 1, lineEnd)
        return NSRange(location: offset, length: 0)
    }
}
@main struct Main {
 static func main() throws {
  let inputs=["", " ", "42", "42:8", " 5 : 12 ", "+5:+2", "005:003", "0", "-1", "1:0", "1:", ":2", "1:2:3", "-0", "1\n", "\r1", "1\t", "1\u{a0}", "1\u{200b}", "1\u{2028}", "1\u{2029}", "1\u{85}", "9223372036854775807", "9223372036854775808"]
  let parses=inputs.map { value in let parsed=GotoLineParse.parse(value);return Parse(input:value,line:parsed?.line,column:parsed?.column) }
  let texts=["", "abc", "abc\ndef\n", "A\rB\r\nC\u{85}D\u{2028}E\u{2029}F", "a\u{000b}b\u{000c}c", "🙂é\r\ne\u{301}Z\n尾", "\r\n\n", "first\u{2028}second"]
  var jumps:[Jump]=[]
  for text in texts {for line in [0,1,2,3,4,8,999] {for column:Int? in [nil,0,1,2,3,4,999] {jumps.append(Jump(text:text,line:line,column:column,offset:BufferSearch.nsRange(forLine:line,column:column,in:text).location))}}}
  let scalars=Array(0...255).map(UInt32.init)+[0x1680,0x180e,0x2000,0x2001,0x2002,0x2003,0x2004,0x2005,0x2006,0x2007,0x2008,0x2009,0x200a,0x200b,0x2028,0x2029,0x202f,0x205f,0x3000,0xfeff]
  let whitespace=scalars.filter { CharacterSet.whitespaces.contains(UnicodeScalar($0)!)}
  let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];FileHandle.standardOutput.write(try encoder.encode(Reference(parses:parses,jumps:jumps,whitespace:whitespace)))
 }
}
