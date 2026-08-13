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
        #expect(DocumentFormatter.supports(formatID: .grammar(.json)))
        #expect(!DocumentFormatter.supports(formatID: .plainText))
    }

    @Test("Manuell gewähltes JSON formatiert unabhängig von der txt-Endung")
    @MainActor
    func manuallySelectedJSONUsesEffectiveFormat() throws {
        let source = #"{"blob":"AAAA","z":1}"#
        let suite = "fastra-format-id-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        let tab = EditorTab(title: "daten.txt", path: "—", content: source)
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        workspace.setLanguageOverride(.json)
        let formatID = try #require(workspace.activeDocumentFormattingID)

        let result = try DocumentFormatter.format(
            in: source,
            selection: NSRange(location: 0, length: 0),
            formatID: formatID
        )
        #expect(formatID == .grammar(.json))
        #expect(result?.replacement.contains("\n") == true)
        #expect(result?.replacement.contains(#""blob" : "AAAA""#) == true)

        workspace.tabs[0].title = "daten.json"
        #expect(workspace.activeDocumentLintingExtension == "json")
        workspace.tabs[0].readOnlyReason = "Git-Vorversion"
        #expect(workspace.activeDocumentFormattingID == nil)
        #expect(workspace.activeDocumentLintingExtension == nil)
    }

}
