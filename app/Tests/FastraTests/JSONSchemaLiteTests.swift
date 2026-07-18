// JSONSchemaLiteTests.swift
//
// Tests des minimalen JSON-Schema-Prüfers (Etappe 6 Wunschpaket 2026-07c):
// erst die unterstützten Konstrukte gegen ein Mini-Schema, dann das ECHTE
// gebündelte 4D-Formular-Schema samt Positions-Zuordnung und die
// `.4DForm`-Anbindung im DocumentLinter.

import Testing
import Foundation
@testable import Fastra

// MARK: - Mini-Schema (Konstrukte einzeln)

private func makeSchema(_ json: String) -> JSONSchemaLite.Schema {
    JSONSchemaLite.Schema(data: Data(json.utf8))!
}

private func parse(_ json: String) -> Any {
    try! JSONSerialization.jsonObject(with: Data(json.utf8),
                                      options: [.fragmentsAllowed])
}

@Test("type/required/properties/minimum/enum/const/pattern")
func schemaBasics() {
    let schema = makeSchema("""
    {
      "type": "object",
      "required": ["name"],
      "properties": {
        "name": {"type": "string", "pattern": "^[a-z]+$"},
        "width": {"type": "integer", "minimum": 0},
        "kind": {"enum": ["button", "input"]},
        "fixed": {"const": true}
      }
    }
    """)
    #expect(schema.validate(parse(#"{"name": "ok", "width": 3}"#)) == nil)
    #expect(schema.validate(parse(#"{"width": 3}"#))?.message.contains("name") == true)
    #expect(schema.validate(parse(#"{"name": "ok", "width": -1}"#))?.pathDescription == "/width")
    #expect(schema.validate(parse(#"{"name": "ok", "kind": "slider"}"#))?.pathDescription == "/kind")
    #expect(schema.validate(parse(#"{"name": "NEIN"}"#))?.pathDescription == "/name")
    #expect(schema.validate(parse(#"{"name": "ok", "fixed": false}"#))?.pathDescription == "/fixed")
    #expect(schema.validate(parse(#"{"name": 5}"#))?.pathDescription == "/name")
}

@Test("items, $ref, allOf, anyOf, not und if/then")
func schemaCombinators() {
    let schema = makeSchema("""
    {
      "$defs": {
        "positive": {"type": "integer", "minimum": 1},
        "sized": {"properties": {"size": {"$ref": "#/$defs/positive"}}}
      },
      "allOf": [
        {"$ref": "#/$defs/sized"},
        {"properties": {"values": {"type": "array", "items": {"$ref": "#/$defs/positive"}}}}
      ],
      "properties": {
        "mode": {"anyOf": [{"type": "string"}, {"type": "integer"}]},
        "never": {"not": {"type": "string"}}
      },
      "if": {"required": ["a"]},
      "then": {"required": ["b"]}
    }
    """)
    #expect(schema.validate(parse(#"{"size": 2, "values": [1, 2], "mode": "x"}"#)) == nil)
    #expect(schema.validate(parse(#"{"size": 0}"#))?.pathDescription == "/size")
    #expect(schema.validate(parse(#"{"values": [1, 0]}"#))?.pathDescription == "/values/1")
    #expect(schema.validate(parse(#"{"mode": []}"#))?.pathDescription == "/mode")
    #expect(schema.validate(parse(#"{"never": "text"}"#))?.pathDescription == "/never")
    #expect(schema.validate(parse(#"{"a": 1}"#)) != nil)      // if→then verlangt b
    #expect(schema.validate(parse(#"{"a": 1, "b": 2}"#)) == nil)
}

@Test("additionalProperties: false meldet unbekannte Eigenschaften")
func schemaAdditionalProperties() {
    let schema = makeSchema("""
    {"properties": {"ok": {"type": "string"}}, "additionalProperties": false}
    """)
    #expect(schema.validate(parse(#"{"ok": "ja"}"#)) == nil)
    let violation = schema.validate(parse(#"{"ok": "ja", "fremd": 1}"#))
    #expect(violation?.message.contains("fremd") == true)
}

// MARK: - Positions-Zuordnung

@Test("Pfad → Zeile/Spalte im Originaltext")
func schemaPositionMapping() {
    let text = """
    {
      "pages": [
        {"objects": {
          "MeinButton": {"width": -1}
        }}
      ]
    }
    """
    let path: [JSONSchemaLite.PathSegment] = [
        .key("pages"), .index(0), .key("objects"),
        .key("MeinButton"), .key("width"),
    ]
    let position = JSONSchemaLite.position(of: path, in: text)
    #expect(position.line == 4)
    // Position zeigt auf den WERT von width (-1).
    #expect(position.column > 25)
}

// MARK: - Echtes Formular-Schema + Linter-Anbindung

@Test("Gebündeltes Formular-Schema: leeres Formular ist gültig")
func realSchemaEmptyForm() {
    let result = DocumentLinter.lint("{}", fileExtension: "4DForm")
    guard case .valid = result else {
        Issue.record("Erwartet gültig, bekommen: \(result)")
        return
    }
}

@Test("Gebündeltes Formular-Schema: falscher Typ wird mit Pfad gemeldet")
func realSchemaTypeViolation() {
    // `pages` muss eine Liste sein.
    let result = DocumentLinter.lint(#"{"pages": "keine Liste"}"#,
                                     fileExtension: "4DForm")
    guard case .issue(let issue) = result else {
        Issue.record("Erwartet Schema-Fehler, bekommen: \(result)")
        return
    }
    #expect(issue.message.contains("/pages"))
    #expect(issue.line == 1)
}

@Test("Kaputtes JSON in .4DForm meldet weiter den JSON-Fehler")
func realSchemaInvalidJSON() {
    let result = DocumentLinter.lint(#"{"pages": ["#, fileExtension: "4DForm")
    guard case .issue = result else {
        Issue.record("Erwartet JSON-Fehler, bekommen: \(result)")
        return
    }
}
