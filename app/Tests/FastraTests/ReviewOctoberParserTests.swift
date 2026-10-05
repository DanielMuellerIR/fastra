import Foundation
import Testing
@testable import Fastra

@Test("UTF-8-Roundtrip und Apply erhalten Inhalts-U+FEFF nach der Datei-BOM")
func october_utf8ContentBOMRoundtrip() throws {
    let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.txt")
    let bom = Data([0xEF, 0xBB, 0xBF])
    let content = "\u{FEFF}foo\n"
    let bytes = try #require(FileLoader.encodedData(content: content, encoding: .utf8, bom: bom, lineEnding: .lf))
    try bytes.write(to: source)
    for forced in [nil, String.Encoding.utf8] {
        let loaded = try FileLoader.load(url: source, forcedEncoding: forced)
        #expect(loaded.content.unicodeScalars.elementsEqual(content.unicodeScalars))
        #expect(FileLoader.encodedData(content: loaded.content, encoding: loaded.encoding,
                                     bom: loaded.bom, lineEnding: loaded.lineEnding) == bytes)
    }
    let plan = ApplyEngine.plan(files: [source], options: SearchOptions(find: "foo", replace: "bar", isRegex: false))
    let planned = try #require(plan.files.first)
    #expect(planned.newBytes == bom + Data("\u{FEFF}bar\n".utf8))
    #expect(try Data(contentsOf: source) == bytes)
    let backups = directory.appendingPathComponent("backups")
    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    _ = try ApplyEngine.apply(plan: plan, backupRoot: backups, cleanupOlderThan: nil)
    #expect(try Data(contentsOf: source) == planned.newBytes)
    #expect(ApplyEngine.decode(payload: Data([0xEF, 0xBB, 0xBF, 0xFF]), encoding: .utf8) == nil)
}

@Test("Zeilenoperationen bearbeiten echte ausgewählte und abschließende Leerzeilen", arguments: ["\n", "\r", "\r\n"])
func october_actualBlankLines(separator: String) {
    let source = "a" + separator + separator + "b"
    let selected = NSRange(location: 0, length: 1 + 2 * separator.utf16.count)
    #expect(TextOperations.prefixLines(in: source, selection: selected, with: "X")?.newText
            == "Xa" + separator + "X" + separator + "b")
    #expect(TextOperations.suffixLines(in: source, selection: selected, with: "X")?.newText
            == "aX" + separator + "X" + separator + "b")
    #expect(TextOperations.addLineNumbers(in: "a" + separator + separator,
                                         selection: NSRange(location: 0, length: 0))?.newText
            == "1 a" + separator + "2 " + separator)
}

@Test("XPath-Descendant-Positionen entsprechen der Referenz je Elternkontext")
func october_xpathDescendantPositions() throws {
    let xml = "<r><p><a id='1'/><a id='2'/><a/></p><p><a/><a id='3'/><a id='4'/></p><a id='5'/></r>"
    let index = try XPathIndex.build(from: xml).get()
    let document = try XMLDocument(xmlString: xml)
    for expression in ["//a[1]", "//a[2]", "//a[@id][1]", "//a[1][@id]", "//a[@id='3'][1]", "/r/p//a[2]", "//*//a[1]"] {
        let query = try XPathQuery.parse(expression).get()
        let matches = XPathEvaluator.evaluate(query, in: index)
        let actual = matches.map { match in
            index.elements.first { $0.nameRange == match.range }?.attributes.first { $0.name == "id" }?.value
        }
        let expected = try document.nodes(forXPath: expression).map {
            ($0 as? XMLElement)?.attribute(forName: "id")?.stringValue
        }
        #expect(actual == expected, "\(expression): \(actual) statt \(expected)")
    }
}

@Test("4D-Memberherkunft bleibt über Blockkommentare erhalten")
func october_fourDCommentedMembers() throws {
    let source = "$o. /* member comment */ Time()\n$o. /* unknown */ FutureCommand()\nTime()\nFutureCommand()"
    let tokens = FourDTokenizer.tokenize(source)
    let members = tokens.filter(\.isObjectMember)
    #expect(members.count == 2)
    #expect(members.allSatisfy { $0.kind == .methodCall })
    #expect(FourDTokenTransform.retokenize(source, learned: ["time": ":C178", "futurecommand": ":C9999"])
        == "$o. /* member comment */ Time()\n$o. /* unknown */ FutureCommand()\nTime:C178()\nFutureCommand:C9999()")
}
