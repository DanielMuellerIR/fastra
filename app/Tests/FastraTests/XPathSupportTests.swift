// XPathSupportTests.swift
//
// Tests für die XPath-Navigation (Etappe 5 Wunschpaket 2026-07):
// Index-Aufbau mit Quell-Offsets (inkl. Umlaute/Emoji — UTF-16!),
// Teilset-Auswertung, Fehlerfälle in Nutzersprache und
// Autovervollständigung aus dem Index.

import Foundation
import Testing
@testable import Fastra

/// Beispiel-XML mit Multibyte-Inhalten VOR den relevanten Fundstellen —
/// genau die Offset-Falle, die byteorientierte Parser reißen.
private let sampleXML = """
<?xml version="1.0" encoding="UTF-8"?>
<bibliothek name="Köln 🙂">
    <!-- Kommentar mit Umlauten: äöü -->
    <buch id="1" sprache="de">
        <titel>Süße Grüße</titel>
    </buch>
    <buch id="42" sprache="en">
        <titel>Emoji 🚀 Handbuch</titel>
    </buch>
    <zeitschrift id="7"/>
</bibliothek>
"""

private func buildIndex(_ xml: String = sampleXML) throws -> XPathIndex {
    switch XPathIndex.build(from: xml) {
    case .success(let index): return index
    case .failure(let error): throw error
    }
}

/// Substring-Helfer über NSRange (UTF-16) — genau das, was der Editor nutzt.
private func text(_ source: String, _ range: NSRange) -> String {
    (source as NSString).substring(with: range)
}

// MARK: - Index

@Test("Index: Struktur, Attribute und Eltern-Kind-Beziehungen")
func xpath_indexStructure() throws {
    let index = try buildIndex()
    #expect(index.roots.count == 1)
    let root = index.elements[index.roots[0]]
    #expect(root.name == "bibliothek")
    #expect(root.attributes.first?.value == "Köln 🙂")
    #expect(root.children.count == 3)
    let firstBook = index.elements[root.children[0]]
    #expect(firstBook.name == "buch")
    #expect(firstBook.attributes.map(\.name) == ["id", "sprache"])
}

@Test("Index: Offsets sind UTF-16-korrekt trotz Umlauten und Emoji")
func xpath_offsetsSurviveMultibyte() throws {
    let index = try buildIndex()
    // Jede nameRange muss im Quelltext EXAKT den Elementnamen treffen.
    for element in index.elements {
        #expect(text(sampleXML, element.nameRange) == element.name)
        for attribute in element.attributes {
            #expect(text(sampleXML, attribute.nameRange) == attribute.name)
        }
    }
    // Der Titel-Text hinter dem Emoji-Attribut sitzt punktgenau.
    let titel = index.elements.first { $0.name == "titel" }!
    #expect(text(sampleXML, titel.firstTextRange!).hasPrefix("Süße"))
}

@Test("Index: kaputtes XML meldet verständliche Fehler")
func xpath_indexErrors() {
    if case .failure(let error) = XPathIndex.build(from: "<a><b></a>") {
        #expect(error == .mismatchedTag(expected: "b", found: "a", offset: 6))
        #expect(error.userMessage.contains("</b>"))
    } else {
        Issue.record("Mismatch muss als Fehler gemeldet werden")
    }
    if case .failure(let error) = XPathIndex.build(from: "<a><b/>") {
        #expect(error == .unclosedTag(name: "a", offset: 1))
    } else {
        Issue.record("Unverschlossenes Tag muss als Fehler gemeldet werden")
    }
}

@Test("Index: CDATA, Kommentare und PI stören die Offsets nicht")
func xpath_indexSkipsNonElements() throws {
    let xml = "<r><!-- <fake> --><a><![CDATA[<auch kein tag>]]></a><?pi <x> ?><b/></r>"
    let index = try buildIndex(xml)
    let names = index.elements.map(\.name)
    #expect(names == ["r", "a", "b"])
    for element in index.elements {
        #expect(text(xml, element.nameRange) == element.name)
    }
}

// MARK: - Teilset-Auswertung

private func evaluate(_ expression: String,
                      xml: String = sampleXML) throws -> [String] {
    let index = try buildIndex(xml)
    guard case .success(let query) = XPathQuery.parse(expression) else {
        throw XPathQuery.ParseError.malformed(expression)
    }
    return XPathEvaluator.evaluate(query, in: index).map { text(xml, $0.range) }
}

@Test("Absolute Pfade: /bibliothek/buch/titel")
func xpath_absolutePath() throws {
    #expect(try evaluate("/bibliothek/buch/titel") == ["titel", "titel"])
    #expect(try evaluate("/bibliothek/zeitschrift") == ["zeitschrift"])
    #expect(try evaluate("/buch").isEmpty)   // buch ist kein Wurzelelement
}

@Test("Descendant-Suche: //titel und relativer Einstieg")
func xpath_descendantAndRelative() throws {
    #expect(try evaluate("//titel").count == 2)
    // Relativer Einstieg wirkt wie „//“ (dokumentiertes Verhalten).
    #expect(try evaluate("titel").count == 2)
    #expect(try evaluate("buch//titel").count == 2)
}

@Test("Wildcard und Position: /bibliothek/*[2], //buch[2]")
func xpath_wildcardAndPosition() throws {
    let index = try buildIndex()
    guard case .success(let query) = XPathQuery.parse("/bibliothek/*[2]") else {
        Issue.record("Parse fehlgeschlagen"); return
    }
    let matches = XPathEvaluator.evaluate(query, in: index)
    #expect(matches.count == 1)
    // Das zweite Kind-Element ist das zweite buch.
    let element = index.elements.first { $0.nameRange == matches[0].range }
    #expect(element?.attributes.first?.value == "42")

    #expect(try evaluate("//buch[1]").count == 1)
}

@Test("Attribut-Prädikate: [@id], [@id='42']")
func xpath_attributePredicates() throws {
    #expect(try evaluate("//buch[@id]").count == 2)
    let index = try buildIndex()
    guard case .success(let query) = XPathQuery.parse("//buch[@id='42']/titel") else {
        Issue.record("Parse fehlgeschlagen"); return
    }
    let matches = XPathEvaluator.evaluate(query, in: index)
    #expect(matches.count == 1)
    #expect(text(sampleXML, matches[0].range) == "titel")
}

@Test("Attribut- und Text-Ziele: @sprache, titel/text()")
func xpath_terminals() throws {
    #expect(try evaluate("//buch/@sprache") == ["sprache", "sprache"])
    let texts = try evaluate("//titel/text()")
    #expect(texts.count == 2)
    #expect(texts[0].hasPrefix("Süße"))
    #expect(texts[1].contains("🚀"))
}

@Test("Nicht unterstützte Syntax → verständliche Meldung")
func xpath_unsupportedSyntax() {
    for expression in ["//a/ancestor::b", "//a/..", "count(//a)", "//a[last()]"] {
        if case .failure(let error) = XPathQuery.parse(expression) {
            #expect(!error.userMessage.isEmpty)
        } else {
            Issue.record("\(expression) darf nicht als gültig durchgehen")
        }
    }
    if case .failure(let error) = XPathQuery.parse("//buch[@id='42") {
        // Meldungstext läuft über L10n (Sprache testumgebungsabhängig) —
        // entscheidend ist der Fehlertyp „unvollständig/ungültig".
        if case .malformed = error {
            #expect(!error.userMessage.isEmpty)
        } else {
            Issue.record("Unvollständiges Prädikat muss als malformed gelten")
        }
    } else {
        Issue.record("Unvollständiges Prädikat muss scheitern")
    }
}

// MARK: - Autovervollständigung

@Test("Autovervollständigung: Kind-Elemente und Attribute aus dem Index")
func xpath_completions() throws {
    let index = try buildIndex()
    // Wurzelebene.
    #expect(XPathAutocomplete.completions(for: "/", index: index) == ["bibliothek"])
    // Kind-Elemente mit Präfix-Filter.
    #expect(XPathAutocomplete.completions(for: "/bibliothek/b", index: index) == ["buch"])
    // Alle Kinder ohne Präfix (dedupliziert).
    #expect(Set(XPathAutocomplete.completions(for: "/bibliothek/", index: index))
            == Set(["buch", "zeitschrift"]))
    // Attributnamen nach `@`.
    #expect(Set(XPathAutocomplete.completions(for: "//buch/@", index: index))
            == Set(["@id", "@sprache"]))
}

@Test("Vorschlag übernehmen ersetzt nur das letzte Teilstück")
func xpath_completionSplit() {
    let split = XPathAutocomplete.splitForCompletion("/bibliothek/bu")
    #expect(split.path == "/bibliothek")
    #expect(split.partial == "bu")
    let short = XPathAutocomplete.splitForCompletion("//ti")
    #expect(short.path == "//")
    #expect(short.partial == "ti")
}

// MARK: - Großes Dokument (asynchroner Aufbau bleibt korrekt)

@Test("Großes XML: Index bleibt korrekt und vollständig")
func xpath_largeDocument() throws {
    var xml = "<wurzel>\n"
    for i in 1...5000 {
        xml += "  <eintrag id=\"\(i)\"><wert>Nr. \(i) — Grüße 🙂</wert></eintrag>\n"
    }
    xml += "</wurzel>"
    let index = try buildIndex(xml)
    #expect(index.elements.count == 1 + 5000 * 2)
    #expect(try evaluate("//eintrag[@id='4711']/wert", xml: xml).count == 1)
}
