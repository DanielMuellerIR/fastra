// Referenz aus NavigationAnchor.swift und SelectionClamping.
// Die zusätzliche Option korrigiert ausschließlich den doppelt gezählten letzten
// Zeilenkandidaten ohne Abschluss; das unveränderte Ergebnis bleibt mitgespeichert.
import Foundation
enum SelectionClamping {
    /// Bringt `range` in einen Bereich, der für einen Text der Länge
    /// `textLength` gefahrlos verwendbar ist.
    ///
    /// `NSNotFound` ist der Normalfall eines Editors ohne Auswahl und wird
    /// zum Dokumentanfang — dort erwartet auch AppKit einen frischen
    /// Einfügepunkt.
    static func clamp(_ range: NSRange, textLength: Int) -> NSRange {
        let length = max(0, textLength)
        guard range.location != NSNotFound, range.location >= 0 else {
            return NSRange(location: 0, length: 0)
        }
        let location = min(range.location, length)
        return NSRange(location: location,
                       length: min(max(0, range.length), length - location))
    }
}


/// Begrenzter Quellanker statt einer vollständigen Dokumentkopie je Sprung.
struct NavigationAnchor: Equatable, Sendable {
    let revision: UInt64
    let range: NSRange
    let textLength: Int
    let lineText: String?
    let before: String?
    let after: String?
    let column: Int

    init(source: String, revision: UInt64, range: NSRange) {
        let text = source as NSString
        self.revision = revision
        self.textLength = text.length
        self.range = SelectionClamping.clamp(range, textLength: text.length)
        var start = 0, end = 0, contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: self.range.location, length: 0))
        column = self.range.location - start
        func boundedLine(at offset: Int) -> String? {
            guard offset >= 0, offset <= text.length else { return nil }
            var first = 0, last = 0
            text.getLineStart(&first, end: nil, contentsEnd: &last, for: NSRange(location: offset, length: 0))
            guard last - first <= 1024 else { return nil }
            return text.substring(with: NSRange(location: first, length: last - first))
        }
        lineText = boundedLine(at: self.range.location)
        before = start > 0 ? boundedLine(at: start - 1) : nil
        after = end < text.length ? boundedLine(at: end) : nil
    }

    func resolve(in source: String, revision: UInt64, fixLastLine: Bool = false, isCancelled: () -> Bool = { false }) -> NSRange? {
        let text = source as NSString
        if revision == self.revision, text.length == textLength { return range }
        guard let lineText, source.utf8.count <= 10 * 1024 * 1024 else { return nil }
        var matches: [(range: NSRange, before: String?, after: String?)] = []
        var offset = 0, count = 0
        func line(at position: Int) -> String? {
            guard position >= 0, position <= text.length else { return nil }
            var start = 0, end = 0
            text.getLineStart(&start, end: nil, contentsEnd: &end, for: NSRange(location: position, length: 0))
            guard end - start <= 1024 else { return nil }
            return text.substring(with: NSRange(location: start, length: end - start))
        }
        while offset <= text.length {
            if isCancelled() || count >= 200_000 { return nil }
            count += 1
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
            if contentsEnd - start <= 1024, line(at: start)?.utf8.elementsEqual(lineText.utf8) == true,
               column + range.length <= contentsEnd - start {
                matches.append((NSRange(location: start + column, length: range.length),
                                start > 0 ? line(at: start - 1) : nil,
                                end < text.length ? line(at: end) : nil))
                if matches.count > 1000 { return nil }
            }
            guard end > offset else { break }
            if fixLastLine && end == text.length && contentsEnd == end { break }
            offset = end
        }
        if matches.count == 1 { return matches[0].range }
        let contextual = matches.filter { candidate in
            equal(candidate.before, before) && equal(candidate.after, after)
        }
        return contextual.count == 1 ? contextual[0].range : nil
    }

    private func equal(_ first: String?, _ second: String?) -> Bool {
        switch (first, second) {
        case (.none, .none): return true
        case (.some(let first), .some(let second)): return first.utf8.elementsEqual(second.utf8)
        default: return false
        }
    }
}

struct Case: Codable { let source:String; let current:String; let revision:UInt64; let currentRevision:UInt64; let location:Int; let length:Int; let expected:[Int]?; let originalExpected:[Int]? }
var cases:[Case]=[]
func add(_ source:String,_ current:String,_ at:Int,_ length:Int=0,_ revision:UInt64=1,_ currentRevision:UInt64=2){
 let anchor=NavigationAnchor(source:source,revision:revision,range:NSRange(location:at,length:length))
 let original=anchor.resolve(in:current,revision:currentRevision)
 let result=anchor.resolve(in:current,revision:currentRevision,fixLastLine:true)
 cases.append(Case(source:source,current:current,revision:revision,currentRevision:currentRevision,location:at,length:length,expected:result.map{[$0.location,$0.length]},originalExpected:original.map{[$0.location,$0.length]}))
}
for ending in ["\n","\r\n","\r","\u{85}","\u{2028}","\u{2029}"] {
 let text=["start","same","middle🙂","same","end"].joined(separator:ending)
 for at in 0...(text as NSString).length {
  for length in [0,1,3] { add(text,"new"+ending+text,at,length);add(text,text,at,length,7,7) }
 }
 add("x"+ending+"same"+ending+"z","x"+ending+"same"+ending+"z"+ending+"x"+ending+"same"+ending+"z",2)
}
for text in ["","a","a\n","a\r\n","🙂é\nlast","one\nsame\nend","long"+String(repeating:"x",count:1030)] {
 for at in [0,1,(text as NSString).length,999] {
  add(text,text,at,3,2,2);add(text,"prefix\n"+text,at,3)
 }
}
let data=try JSONEncoder().encode(cases);FileHandle.standardOutput.write(data)
