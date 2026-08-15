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

@Test("Index: strukturell ungültiges XML wird nicht als navigierbar akzeptiert",
      arguments: [
        "<a x></a>",
        "<a></a",
        "<a><!-- offen</a>",
        "<a/><b/>",
        "Text<a/>",
        "<1/>",
        "<a x='offen></a>",
        "<a><</a>",
        "<a x='1' x='2'/>",
        "<a x='<'/>",
        "<a>AT&T</a>",
        "<a>&#0;</a>",
        "<a>\u{1}</a>",
        "<a><!-- a -- b --></a>",
        "<a>Text ]]> Rest</a>",
        "<!DOCTYPE a [<!ELEMENT a EMPTY>",
      ])
func xpath_rejectsMalformedStructure(xml: String) {
    guard case .failure = XPathIndex.build(from: xml) else {
        Issue.record("Ungültiges XML wurde akzeptiert: \(xml)")
        return
    }
}

@Test("Index: text() beginnt bei Emoji- und CDATA-Inhalt statt an Markup")
func xpath_textRangesStartAtContent() throws {
    let xml = "<r><![CDATA[  🚀 Start  ]]><a>🚀 Anfang</a></r>"
    let index = try buildIndex(xml)
    let root = index.elements[index.roots[0]]
    let child = index.elements[root.children[0]]

    #expect(root.firstTextRange.map { text(xml, $0) } == "🚀 Start")
    #expect(child.firstTextRange.map { text(xml, $0) } == "🚀 Anfang")
}

@Test("Index: interne DOCTYPE-Teilmengen werden vollständig übersprungen")
func xpath_doctypeInternalSubset() throws {
    let xml = "<!DOCTYPE r [<!ELEMENT r (a)><!ELEMENT a EMPTY>]><r><a/></r>"
    #expect(try buildIndex(xml).elements.map(\.name) == ["r", "a"])
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

@Test("Attribut-Prädikate vergleichen decodierte XML-Entities")
func xpath_attributeEntities() throws {
    let xml = #"<r><a name="A&amp;B"/><a name="&#x1F680;"/></r>"#
    #expect(try evaluate(#"//a[@name='A&B']"#, xml: xml).count == 1)
    #expect(try evaluate(#"//a[@name='🚀']"#, xml: xml).count == 1)
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

@Test("Achsenwörter bleiben als normale Elementnamen erlaubt")
func xpath_axisWordsAreValidNames() {
    for expression in ["//ancestor", "//following-item", "/preceding/value"] {
        guard case .success = XPathQuery.parse(expression) else {
            Issue.record("Gültiger Elementpfad wurde als Achse abgelehnt: \(expression)")
            continue
        }
    }
}

@Test("Schließende Klammern in Attributwerten beenden das Prädikat nicht")
func xpath_predicateMayContainClosingBracket() throws {
    #expect(try evaluate(#"//buch[@id=']']"#,
                         xml: #"<r><buch id="]"/></r>"#).count == 1)
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
    // Eine angefangene Descendant-Achse schlägt Namen in beliebiger Tiefe vor.
    #expect(XPathAutocomplete.completions(for: "//ti", index: index) == ["titel"])
    #expect(XPathAutocomplete.completions(for: "/bibliothek//ti", index: index)
            == ["titel"])
}

@Test("Vorschlag übernehmen ersetzt nur das letzte Teilstück")
func xpath_completionSplit() {
    let split = XPathAutocomplete.splitForCompletion("/bibliothek/bu")
    #expect(split.path == "/bibliothek")
    #expect(split.partial == "bu")
    let short = XPathAutocomplete.splitForCompletion("//ti")
    #expect(short.path == "//")
    #expect(short.partial == "ti")
    let descendant = XPathAutocomplete.splitForCompletion("/bibliothek//ti")
    #expect(descendant.path == "/bibliothek//")
    #expect(descendant.partial == "ti")
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

@Test("Tiefes XML wertet Descendants ohne rekursiven Callstack aus")
func xpath_deepDocument() throws {
    let depth = 12_000
    let xml = String(repeating: "<n>", count: depth)
        + "<ziel/>"
        + String(repeating: "</n>", count: depth)
    #expect(try evaluate("//ziel", xml: xml) == ["ziel"])
}

@Test("Modell springt nach Inhaltswechsel nicht mit veralteten Quellbereichen")
@MainActor func xpath_modelRejectsStaleIndex() async throws {
    let suite = "fastra-xpath-model-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = Workspace(defaults: defaults)
    workspace.activeTabContent.wrappedValue = "<r><a/></r>"
    let model = XPathBarModel(workspace: workspace)
    model.activate()
    defer { model.deactivate() }

    for _ in 0..<200 where model.index == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.index != nil)
    model.query = "//a"
    #expect(!model.statusText.isEmpty)

    workspace.activeTabContent.wrappedValue = "<r><b/><a/></r>"
    model.step(1)
    #expect(model.statusText.isEmpty)

    for _ in 0..<200 where model.statusText.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.statusText.isEmpty)
}
