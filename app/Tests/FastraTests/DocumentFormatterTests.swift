import Foundation
import Testing
@testable import Fastra

@Suite("Dokument formatieren")
struct DocumentFormatterTests {
    @Test("JSON wird sortiert, eingerückt und behält CRLF")
    func formatsJSONWithLineEnding() throws {
        let crlf = String(UnicodeScalar(13)) + "\n"
        let source = "{\"z\":1,\"a\":[true,false]}" + crlf
        #expect(source.hasSuffix(crlf))
        #expect(source.contains(crlf))
        let result = try DocumentFormatter.format(source, fileExtension: "json")
        #expect(result.contains("\r\n"))
        #expect(Array(result.utf8.suffix(2)) == [13, 10])
        #expect(result.contains("\"a\" : ["))
    }

    @Test("Ungültiges JSON bleibt ohne Ersatz")
    func rejectsInvalidJSON() {
        #expect(throws: DocumentFormatterError.invalidJSON) {
            try DocumentFormatter.format("{broken", fileExtension: "json")
        }
    }

    @Test("XML wird eingerückt und ungültiges XML abgelehnt")
    func formatsAndValidatesXML() throws {
        let formatted = try DocumentFormatter.format("<root><entry id=\"1\">Text</entry></root>", fileExtension: "xml")
        #expect(formatted.contains("\n"))
        #expect(formatted.contains("<entry id=\"1\">Text</entry>"))
        #expect(throws: DocumentFormatterError.invalidXML) {
            try DocumentFormatter.format("<root>", fileExtension: "xml")
        }
    }

    @Test("Eine Auswahl wird einzeln formatiert, kein No-op erzeugt Undo")
    func formatsSelectionAndDetectsNoOp() throws {
        let source = "vor {\"b\":2,\"a\":1} nach"
        let range = (source as NSString).range(of: "{\"b\":2,\"a\":1}")
        let result = try DocumentFormatter.format(in: source, selection: range, fileExtension: "json")
        #expect(result?.affectedRange == range)
        #expect(result?.replacement.contains("\"a\"" ) == true)
        #expect(try DocumentFormatter.format(in: "{\n  \"a\" : 1\n}", selection: .init(location: 0, length: 0), fileExtension: "json") == nil)
    }

    @Test("Nur explizit unterstützte Formate werden aktiviert")
    func supportedTypes() {
        #expect(DocumentFormatter.supports(fileExtension: "XML"))
        #expect(DocumentFormatter.supports(fileExtension: "json"))
        #expect(!DocumentFormatter.supports(fileExtension: "swift"))
    }
}
