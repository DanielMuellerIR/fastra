import Testing
@testable import Fastra

@Suite("XML-Dateierkennung")
struct DocumentKindTests {
    @Test("XML ist im Footer sichtbar, JSON bleibt JSON")
    func footerLabels() {
        #expect(DocumentKind.footerLabel(filename: "Beispiel.XML") == "XML")
        #expect(DocumentKind.footerLabel(filename: "daten.json") == "JSON")
    }

    @Test("XML-Erkennung berücksichtigt Finder-Dateinamen")
    func xmlExtensions() {
        #expect(DocumentKind.isXML(filename: "layout.xsl"))
        #expect(DocumentKind.isXML(filename: "Info.PLIST"))
        #expect(!DocumentKind.isXML(filename: "data.json"))
    }
}
