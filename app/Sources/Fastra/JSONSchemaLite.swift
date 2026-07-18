// JSONSchemaLite.swift
//
// Minimaler JSON-Schema-Prüfer (Etappe 6 Wunschpaket 2026-07c) für die
// `.4DForm`-Validierung gegen das gebündelte `formsSchema.json` (MIT,
// © Mathieu Ferry — siehe THIRD-PARTY-NOTICES.md).
//
// BEWUSST eine Teilmenge von JSON Schema 2020-12 — genau die Konstrukte,
// die das Formular-Schema tatsächlich nutzt: $ref (#/…), type, enum,
// const, minimum, pattern, properties, required, items, allOf, anyOf,
// oneOf, not, if/then/else, additionalProperties. Alles andere wird
// bewusst IGNORIERT (nie fehlgedeutet): lieber eine Prüfung weniger als
// eine falsche Meldung.
//
// Fehlerwahl: Bei Alternativen (anyOf/oneOf) gewinnt die Verletzung mit
// dem TIEFSTEN Pfad — die ist erfahrungsgemäß die hilfreichste Diagnose.

import Foundation

enum JSONSchemaLite {

    /// Ein Pfadsegment im geprüften JSON-Dokument.
    enum PathSegment: Equatable {
        case key(String)
        case index(Int)
    }

    /// Eine Schema-Verletzung mit Pfad und nutzersprachlicher Meldung.
    struct Violation: Equatable {
        let path: [PathSegment]
        let message: String

        /// „/pages/1/objects/MeinButton" — für die Meldung.
        var pathDescription: String {
            guard !path.isEmpty else { return "/" }
            return path.map {
                switch $0 {
                case .key(let key): return "/\(key)"
                case .index(let index): return "/\(index)"
                }
            }.joined()
        }
    }

    /// Geladenes Schema. `root` ist das JSON-Objekt des Schemas selbst.
    struct Schema {
        let root: [String: Any]

        init?(data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else { return nil }
            root = dictionary
        }

        /// Prüft einen (via JSONSerialization geparsten) Wert. `nil` = keine
        /// Verletzung gefunden.
        func validate(_ value: Any) -> Violation? {
            JSONSchemaLite.evaluate(value: value, schema: root, root: root,
                                    path: [], hops: 0)
        }
    }

    // MARK: - Auswertung

    /// Maximale $ref-Sprünge je Wertknoten — Schutz gegen zyklische
    /// Schemata (das echte Formular-Schema braucht deutlich weniger).
    private static let maximumHops = 64

    /// Liefert `nil`, wenn `value` das Schema erfüllt, sonst die tiefste
    /// gefundene Verletzung.
    private static func evaluate(value: Any, schema: Any, root: [String: Any],
                                 path: [PathSegment], hops: Int) -> Violation? {
        guard hops < maximumHops else { return nil }   // im Zweifel keine Meldung
        // Bool-Schemata: true = alles erlaubt, false = nichts erlaubt.
        if let allowed = schema as? Bool {
            return allowed ? nil : Violation(
                path: path, message: L10n.string("Hier ist kein Wert erlaubt.")
            )
        }
        guard let schema = schema as? [String: Any] else { return nil }

        var worst: Violation? = nil
        func record(_ violation: Violation?) -> Bool {
            guard let violation else { return false }
            if let current = worst {
                if violation.path.count > current.path.count { worst = violation }
            } else {
                worst = violation
            }
            return true
        }

        // $ref zuerst — in 2020-12 gilt er ZUSÄTZLICH zu den Geschwistern.
        if let ref = schema["$ref"] as? String {
            if let resolved = resolve(ref: ref, in: root) {
                if record(evaluate(value: value, schema: resolved, root: root,
                                   path: path, hops: hops + 1)) {
                    return worst
                }
            }
            // Unbekannte/nicht auflösbare Referenz: bewusst ignorieren.
        }

        if let types = typeList(schema["type"]), !types.isEmpty,
           !types.contains(where: { matchesType(value, $0) }) {
            return Violation(path: path, message: L10n.format(
                "Erwartet %@, gefunden %@.",
                types.map(germanTypeName).joined(separator: L10n.string(" oder ")),
                germanTypeName(jsonTypeName(of: value))
            ))
        }

        if let allowed = schema["enum"] as? [Any],
           !allowed.contains(where: { jsonEqual($0, value) }) {
            return Violation(path: path, message: L10n.format(
                "„%@“ ist keiner der erlaubten Werte.", displayValue(value)
            ))
        }

        if let constant = schema["const"], !jsonEqual(constant, value) {
            return Violation(path: path, message: L10n.format(
                "Erwartet den festen Wert „%@“.", displayValue(constant)
            ))
        }

        if let minimum = schema["minimum"] as? NSNumber,
           let number = value as? NSNumber, !isBoolean(number),
           number.doubleValue < minimum.doubleValue {
            return Violation(path: path, message: L10n.format(
                "%@ liegt unter dem Minimum %@.",
                displayValue(number), displayValue(minimum)
            ))
        }

        if let pattern = schema["pattern"] as? String,
           let string = value as? String,
           let regex = try? NSRegularExpression(pattern: pattern),
           regex.firstMatch(in: string,
                            range: NSRange(string.startIndex..., in: string)) == nil {
            return Violation(path: path, message: L10n.string(
                "Der Text entspricht nicht dem erwarteten Muster."
            ))
        }

        // Objekt-Schlüsselwörter.
        if let object = value as? [String: Any] {
            if let required = schema["required"] as? [String] {
                for key in required where object[key] == nil {
                    return Violation(path: path, message: L10n.format(
                        "Pflicht-Eigenschaft „%@“ fehlt.", key
                    ))
                }
            }
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for (key, subSchema) in properties {
                guard let subValue = object[key] else { continue }
                if record(evaluate(value: subValue, schema: subSchema, root: root,
                                   path: path + [.key(key)], hops: hops + 1)) {
                    return worst
                }
            }
            if let additional = schema["additionalProperties"] {
                for (key, subValue) in object where properties[key] == nil {
                    if let allowed = additional as? Bool {
                        if !allowed {
                            return Violation(path: path, message: L10n.format(
                                "Unbekannte Eigenschaft „%@“.", key
                            ))
                        }
                    } else if record(evaluate(value: subValue, schema: additional,
                                              root: root,
                                              path: path + [.key(key)],
                                              hops: hops + 1)) {
                        return worst
                    }
                }
            }
        }

        // Array-Elemente.
        if let array = value as? [Any], let items = schema["items"] {
            for (index, element) in array.enumerated() {
                if record(evaluate(value: element, schema: items, root: root,
                                   path: path + [.index(index)], hops: hops + 1)) {
                    return worst
                }
            }
        }

        // Kombinatoren.
        if let allOf = schema["allOf"] as? [Any] {
            for subSchema in allOf {
                if record(evaluate(value: value, schema: subSchema, root: root,
                                   path: path, hops: hops + 1)) {
                    return worst
                }
            }
        }
        for keyword in ["anyOf", "oneOf"] {
            guard let branches = schema[keyword] as? [Any], !branches.isEmpty else {
                continue
            }
            // oneOf wird bewusst wie anyOf geprüft (mindestens ein Treffer):
            // „genau eins" kann bei überlappenden Ästen technisch verletzt
            // sein, ohne dass am Dokument etwas falsch wäre — keine
            // falschen Meldungen.
            var deepest: Violation? = nil
            var anyPassed = false
            for branch in branches {
                if let violation = evaluate(value: value, schema: branch,
                                            root: root, path: path,
                                            hops: hops + 1) {
                    if deepest == nil
                        || violation.path.count > deepest!.path.count {
                        deepest = violation
                    }
                } else {
                    anyPassed = true
                    break
                }
            }
            if !anyPassed {
                return deepest ?? Violation(path: path, message: L10n.string(
                    "Keine der erlaubten Varianten passt."
                ))
            }
        }
        if let not = schema["not"] {
            if evaluate(value: value, schema: not, root: root,
                        path: path, hops: hops + 1) == nil {
                return Violation(path: path, message: L10n.string(
                    "Verletzt eine Ausschluss-Regel des Formular-Schemas."
                ))
            }
        }
        if let condition = schema["if"] {
            let passes = evaluate(value: value, schema: condition, root: root,
                                  path: path, hops: hops + 1) == nil
            if passes, let then = schema["then"] {
                if record(evaluate(value: value, schema: then, root: root,
                                   path: path, hops: hops + 1)) {
                    return worst
                }
            } else if !passes, let otherwise = schema["else"] {
                if record(evaluate(value: value, schema: otherwise, root: root,
                                   path: path, hops: hops + 1)) {
                    return worst
                }
            }
        }

        return worst
    }

    // MARK: - $ref-Auflösung

    /// Löst lokale Referenzen wie `#/$defs/types/windowSize` auf.
    private static func resolve(ref: String, in root: [String: Any]) -> Any? {
        guard ref.hasPrefix("#/") else { return nil }
        var current: Any = root
        for rawComponent in ref.dropFirst(2).split(separator: "/") {
            // JSON-Pointer-Escapes (~1 = /, ~0 = ~).
            let component = rawComponent
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[component] else { return nil }
            current = next
        }
        return current
    }

    // MARK: - Typen und Vergleiche

    private static func typeList(_ raw: Any?) -> [String]? {
        if let single = raw as? String { return [single] }
        if let list = raw as? [String] { return list }
        return nil
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func jsonTypeName(of value: Any) -> String {
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            if isBoolean(number) { return "boolean" }
            // Ganzzahlig gespeicherte Zahlen gelten auch als integer.
            return number.doubleValue.truncatingRemainder(dividingBy: 1) == 0
                ? "integer" : "number"
        }
        if value is String { return "string" }
        if value is [Any] { return "array" }
        if value is [String: Any] { return "object" }
        return "unknown"
    }

    private static func matchesType(_ value: Any, _ type: String) -> Bool {
        let actual = jsonTypeName(of: value)
        if type == "number" { return actual == "number" || actual == "integer" }
        return actual == type
    }

    static func germanTypeName(_ type: String) -> String {
        switch type {
        case "object": return L10n.string("ein Objekt")
        case "array": return L10n.string("eine Liste")
        case "string": return L10n.string("einen Text")
        case "number": return L10n.string("eine Zahl")
        case "integer": return L10n.string("eine Ganzzahl")
        case "boolean": return L10n.string("einen Wahrheitswert")
        case "null": return "null"
        default: return type
        }
    }

    /// JSON-Wertegleichheit über die Foundation-Objekte (NSObject-isEqual
    /// deckt String/Number/Array/Dictionary/Null korrekt ab).
    private static func jsonEqual(_ a: Any, _ b: Any) -> Bool {
        (a as AnyObject).isEqual(b as AnyObject)
    }

    private static func displayValue(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            return isBoolean(number)
                ? (number.boolValue ? "true" : "false")
                : number.stringValue
        }
        if value is NSNull { return "null" }
        return String(describing: value)
    }

    // MARK: - Pfad → Textposition

    /// Findet die Textposition eines JSON-Pfads im ORIGINALTEXT — ein
    /// leichter JSON-Läufer (Strings mit Escapes, verschachtelte
    /// Container). Liefert (1,1), wenn der Pfad nicht auffindbar ist.
    static func position(of path: [PathSegment], in text: String)
        -> (line: Int, column: Int) {
        let scalars = Array(text.utf16)
        var index = 0

        func char(_ at: Int) -> Character? {
            guard at < scalars.count,
                  let scalar = Unicode.Scalar(scalars[at]) else { return nil }
            return Character(scalar)
        }
        func skipWhitespace() {
            while let c = char(index), c == " " || c == "\n" || c == "\t" || c == "\r" {
                index += 1
            }
        }
        func skipString() {
            guard char(index) == "\"" else { return }
            index += 1
            while let c = char(index) {
                if c == "\\" { index += 2; continue }
                index += 1
                if c == "\"" { return }
            }
        }
        func parseKey() -> String? {
            guard char(index) == "\"" else { return nil }
            let start = index + 1
            var i = start
            var key = ""
            while let c = char(i) {
                if c == "\\" {
                    // Escapes im Schlüssel: einfach beide Zeichen übernehmen —
                    // für den Pfadvergleich reichen unescapte Klartext-Keys.
                    if let next = char(i + 1) { key.append(next) }
                    i += 2
                    continue
                }
                if c == "\"" { break }
                key.append(c)
                i += 1
            }
            index = i + 1
            return key
        }
        /// Überspringt einen kompletten JSON-Wert ab `index`.
        func skipValue() {
            skipWhitespace()
            guard let c = char(index) else { return }
            switch c {
            case "\"":
                skipString()
            case "{", "[":
                var depth = 0
                while let c = char(index) {
                    if c == "\"" { skipString(); continue }
                    if c == "{" || c == "[" { depth += 1 }
                    if c == "}" || c == "]" {
                        depth -= 1
                        index += 1
                        if depth == 0 { return }
                        continue
                    }
                    index += 1
                }
            default:
                while let c = char(index),
                      c != "," && c != "}" && c != "]" { index += 1 }
            }
        }

        var remaining = path
        while !remaining.isEmpty {
            skipWhitespace()
            let segment = remaining.removeFirst()
            switch segment {
            case .key(let target):
                guard char(index) == "{" else { return fallback(text) }
                index += 1
                var found = false
                while true {
                    skipWhitespace()
                    if char(index) == "}" || char(index) == nil { break }
                    guard let key = parseKey() else { return fallback(text) }
                    skipWhitespace()
                    guard char(index) == ":" else { return fallback(text) }
                    index += 1
                    skipWhitespace()
                    if key == target { found = true; break }
                    skipValue()
                    skipWhitespace()
                    if char(index) == "," { index += 1 }
                }
                guard found else { return fallback(text) }
            case .index(let target):
                guard char(index) == "[" else { return fallback(text) }
                index += 1
                var current = 0
                while current < target {
                    skipValue()
                    skipWhitespace()
                    guard char(index) == "," else { return fallback(text) }
                    index += 1
                    current += 1
                }
                skipWhitespace()
            }
        }
        guard let range = Range(NSRange(location: 0, length: index), in: text) else {
            return (1, 1)
        }
        return DocumentLinter.lineColumn(atEndOf: String(text[range]))
    }

    private static func fallback(_ text: String) -> (line: Int, column: Int) {
        (1, 1)
    }
}
