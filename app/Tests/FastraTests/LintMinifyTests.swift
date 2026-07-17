// LintMinifyTests.swift
//
// Tests für „Dokument prüfen" und „Dokument minifizieren" (Etappe 6
// Wunschpaket 2026-07): Fehlerpositionen gegen präparierte kaputte
// Dateien, konservatives XML-Minify und der Minify-→-Format-Roundtrip
// (semantisch identisches Dokument).

import Foundation
import Testing
@testable import Fastra

// MARK: - Lint: Fehlerpositionen

@Test("JSON-Lint: gültiges Dokument")
func lint_validJSON() {
    let result = DocumentLinter.lint(#"{"a": 1, "b": [true, null]}"#,
                                     fileExtension: "json")
    #expect(result == .valid("JSON"))
}

@Test("JSON-Lint: kaputtes Dokument nennt eine plausible Fehlerposition")
func lint_brokenJSONPosition() {
    // Fehlendes Komma in Zeile 3.
    let broken = """
    {
      "name": "Fastra"
      "version": 21
    }
    """
    guard case .issue(let issue) = DocumentLinter.lint(broken,
                                                       fileExtension: "json") else {
        Issue.record("Kaputtes JSON muss eine Fundstelle liefern")
        return
    }
    #expect(issue.line >= 2 && issue.line <= 4,
            "Zeile \(issue.line) liegt nicht bei der kaputten Stelle")
    #expect(!issue.message.isEmpty)
}

@Test("JSON-Lint: Byte-Offset wird multibyte-sicher in Zeile/Spalte übersetzt")
func lint_jsonOffsetTranslation() {
    // Position am Ende eines Präfixes mit Umlauten und Emoji.
    let position = DocumentLinter.lineColumn(atEndOf: "ä🙂\nabc")
    #expect(position.line == 2)
    #expect(position.column == 4)

    let data = Data("{\"grüße\": \n]".utf8)
    let issue = DocumentLinter.jsonIssue(
        from: "Garbage around character \(data.count - 1).", data: data)
    #expect(issue.line == 2)
}

@Test("XML-Lint: gültig und kaputt (Position der kaputten Stelle)")
func lint_xml() {
    #expect(DocumentLinter.lint("<a><b/></a>", fileExtension: "xml")
            == .valid("XML"))

    let broken = """
    <wurzel>
      <kind>
    </wurzel>
    """
    guard case .issue(let issue) = DocumentLinter.lint(broken,
                                                       fileExtension: "xml") else {
        Issue.record("Kaputtes XML muss eine Fundstelle liefern")
        return
    }
    #expect(issue.line == 3, "libxml meldet den Mismatch beim Schließ-Tag")
    #expect(!issue.message.isEmpty)
}

@Test("Lint: Zuständigkeit nach Endung (kein JS/CSS/HTML)")
func lint_supportedExtensions() {
    #expect(DocumentLinter.supports(fileExtension: "json"))
    #expect(DocumentLinter.supports(fileExtension: "xml"))
    #expect(DocumentLinter.supports(fileExtension: "plist"))
    #expect(DocumentLinter.supports(fileExtension: "4DProject"))
    #expect(DocumentLinter.supports(fileExtension: "4DCatalog"))
    #expect(!DocumentLinter.supports(fileExtension: "js"))
    #expect(!DocumentLinter.supports(fileExtension: "css"))
    #expect(!DocumentLinter.supports(fileExtension: "html"))
    #expect(!DocumentLinter.supports(fileExtension: nil))
}

// MARK: - Minify

@Test("JSON-Minify: kompakt, Schlüssel sortiert (konsistent zum Formatieren)")
func minify_json() throws {
    let source = """
    {
      "zebra": 1,
      "adler": [1, 2, 3]
    }
    """
    let minified = try DocumentFormatter.minify(source, fileExtension: "json")
    #expect(minified == #"{"adler":[1,2,3],"zebra":1}"#)
}

@Test("JSON-Minify-Roundtrip: minify → format ist semantisch identisch")
func minify_jsonRoundtrip() throws {
    let source = #"{"b": {"y": [1, 2]}, "a": "grüße 🙂"}"#
    let minified = try DocumentFormatter.minify(source, fileExtension: "json")
    let formatted = try DocumentFormatter.format(minified, fileExtension: "json")
    // Semantik-Vergleich über geparste Objekte (Reihenfolge egal).
    let lhs = try JSONSerialization.jsonObject(with: Data(source.utf8)) as! NSDictionary
    let rhs = try JSONSerialization.jsonObject(with: Data(formatted.utf8)) as! NSDictionary
    #expect(lhs == rhs)
}

@Test("XML-Minify: entfernt nur Einrückungs-Whitespace zwischen Tags")
func minify_xmlConservative() throws {
    let source = """
    <lager>
        <regal id="1">
            <fach>Grüße 🙂</fach>
        </regal>
    </lager>
    """
    let minified = try DocumentFormatter.minify(source, fileExtension: "xml")
    #expect(minified == "<lager><regal id=\"1\"><fach>Grüße 🙂</fach></regal></lager>")
}

@Test("XML-Minify: Inline-Leerzeichen und CDATA/Kommentare bleiben erhalten")
func minify_xmlPreservesMeaningfulContent() throws {
    // Ein EINZELNES Leerzeichen zwischen Inline-Elementen kann Bedeutung
    // tragen — es bleibt. CDATA und Kommentare bleiben byte-genau.
    let source = "<p><b>fett</b> <i>kursiv</i>\n  <pre><![CDATA[  <kein tag>\n  ]]></pre>\n  <!-- Hinweis:\n  mehrzeilig --></p>"
    let minified = try DocumentFormatter.minify(source, fileExtension: "xml")
    #expect(minified.contains("</b> <i>"))
    #expect(minified.contains("<![CDATA[  <kein tag>\n  ]]>"))
    #expect(minified.contains("<!-- Hinweis:\n  mehrzeilig -->"))
    // Die Einrückungen VOR <pre> und VOR dem Kommentar sind verschwunden.
    #expect(minified.contains("</i><pre>"))
    #expect(minified.contains("</pre><!--"))
}

@Test("XML-Minify-Roundtrip: minify → format ergibt dieselbe Struktur")
func minify_xmlRoundtrip() throws {
    let source = """
    <bibliothek>
        <buch id="42">
            <titel>Süße Grüße</titel>
        </buch>
    </bibliothek>
    """
    let minified = try DocumentFormatter.minify(source, fileExtension: "xml")
    let formatted = try DocumentFormatter.format(minified, fileExtension: "xml")
    // Struktur-Vergleich über kanonisches XML (Whitespace-unabhängig).
    let lhs = try XMLDocument(xmlString: source).rootElement()?.canonicalXMLStringPreservingComments(false)
    let rhs = try XMLDocument(xmlString: formatted).rootElement()?.canonicalXMLStringPreservingComments(false)
    #expect(lhs != nil && lhs == rhs)
}

@Test("Minify: ungültige Dokumente bleiben unangetastet")
func minify_rejectsInvalidInput() {
    #expect(throws: DocumentFormatterError.invalidJSON) {
        try DocumentFormatter.minify("{kaputt", fileExtension: "json")
    }
    #expect(throws: DocumentFormatterError.invalidXML) {
        try DocumentFormatter.minify("<a><b></a>", fileExtension: "xml")
    }
    #expect(throws: DocumentFormatterError.unsupportedFormat) {
        try DocumentFormatter.minify("x", fileExtension: "js")
    }
}

@Test("Minify über die Formatter-Infrastruktur: Auswahl und No-op")
func minify_selectionAndNoop() throws {
    // Bereits minimal → nil (No-op, gleiche Semantik wie format).
    let compact = #"{"a":1}"#
    #expect(try DocumentFormatter.minify(
        in: compact, selection: NSRange(location: 0, length: 0),
        fileExtension: "json"
    ) == nil)

    // Nur die Auswahl wird ersetzt.
    let text = "vorher {\n  \"a\": 1\n} nachher"
    let jsonRange = (text as NSString).range(of: "{\n  \"a\": 1\n}")
    let result = try DocumentFormatter.minify(in: text, selection: jsonRange,
                                              fileExtension: "json")
    #expect(result?.affectedRange == jsonRange)
    #expect(result?.replacement == #"{"a":1}"#)
}
