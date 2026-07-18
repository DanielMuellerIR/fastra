// DocumentLinter.swift
//
// „Dokument prüfen" (Etappe 6 Wunschpaket 2026-07): native Validierung für
// JSON und XML mit Fehlerposition (Zeile/Spalte) und Meldung in
// Nutzersprache — ohne gebündelte Fremd-Linter (Größe/Lizenz/Wartung
// stünden in keinem Verhältnis; JS/CSS/HTML bleiben bewusst außen vor).

import Foundation

enum DocumentLinter {

    struct Issue: Equatable {
        let line: Int      // 1-basiert
        let column: Int    // 1-basiert
        let message: String
    }

    enum LintResult: Equatable {
        /// Dokument ist gültig; der String ist das Format-Label („JSON"/„XML").
        case valid(String)
        case issue(Issue)
        /// Heuristische Prüfung OHNE Auffälligkeiten (4D-Struktur-Hinweise,
        /// Etappe 5 Wunschpaket 2026-07c). Bewusst NICHT `.valid`: die
        /// Heuristik ist kein Compiler-Ersatz und darf nie „gültig" sagen.
        case hintFree
        /// Ein heuristischer Struktur-HINWEIS (kein bewiesener Fehler).
        case hint(Issue)
        case unsupported
    }

    /// Prüft den Text nach Dateiendung. Gleiche Format-Zuständigkeit wie
    /// der Formatter (JSON bzw. XML-artige inkl. plist); `.4dm`-Methoden
    /// bekommen die heuristischen Struktur-Hinweise.
    static func lint(_ text: String, fileExtension: String?) -> LintResult {
        switch (fileExtension ?? "").lowercased() {
        case "json", "4dproject":
            return lintJSON(text)
        case "4dform":
            // Erst die JSON-Syntax, dann das gebündelte Formular-Schema
            // (Etappe 6 Wunschpaket 2026-07c).
            let json = lintJSON(text)
            guard case .valid = json else { return json }
            return lintFormSchema(text)
        case "xml", "xsd", "xsl", "xslt", "plist", "svg", "4dcatalog", "4dsettings":
            return lintXML(text)
        case "4dm":
            if let issue = FourDStructureCheck.check(text) {
                return .hint(issue)
            }
            return .hintFree
        default:
            return .unsupported
        }
    }

    // MARK: - 4D-Formular-Schema (Etappe 6 Wunschpaket 2026-07c)

    /// Das gebündelte Formular-Schema (formsSchema.json, MIT — siehe
    /// THIRD-PARTY-NOTICES.md), einmalig geladen.
    private static let formSchema: JSONSchemaLite.Schema? = {
        guard let url = AppResources.bundle.url(forResource: "formsSchema",
                                                withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return JSONSchemaLite.Schema(data: data)
    }()

    /// Prüft ein (syntaktisch gültiges) `.4DForm`-JSON gegen das Schema.
    static func lintFormSchema(_ text: String) -> LintResult {
        guard let schema = formSchema else {
            // Kein stiller Fallback: fehlt das Schema im Bundle, wird das
            // sichtbar gesagt statt „gültig" vorzutäuschen.
            return .hint(Issue(line: 1, column: 1, message: L10n.string(
                "Das gebündelte Formular-Schema konnte nicht geladen werden — nur die JSON-Syntax wurde geprüft."
            )))
        }
        guard let value = try? JSONSerialization.jsonObject(
            with: Data(text.utf8), options: [.fragmentsAllowed]
        ) else {
            return lintJSON(text)
        }
        if let violation = schema.validate(value) {
            let position = JSONSchemaLite.position(of: violation.path, in: text)
            return .issue(Issue(
                line: position.line, column: position.column,
                message: L10n.format("Formular-Schema: %@ (Pfad %@)",
                                     violation.message,
                                     violation.pathDescription)
            ))
        }
        return .valid(L10n.string("4D-Formular (JSON- und Schema-Prüfung)"))
    }

    static func supports(fileExtension: String?) -> Bool {
        if case .unsupported = lint("", fileExtension: fileExtension) {
            return false
        }
        return true
    }

    // MARK: - JSON

    private static func lintJSON(_ text: String) -> LintResult {
        let data = Data(text.utf8)
        do {
            _ = try JSONSerialization.jsonObject(with: data,
                                                 options: [.fragmentsAllowed])
            return .valid("JSON")
        } catch let error as NSError {
            let debug = (error.userInfo["NSDebugDescription"] as? String)
                ?? error.localizedDescription
            let issue = jsonIssue(from: debug, data: data)
            return .issue(issue)
        }
    }

    /// Zieht die Fehlerposition aus der Foundation-Fehlermeldung. Je nach
    /// System nennt sie „line X, column Y" oder nur „character N" (Byte-
    /// Offset in den UTF-8-Daten) — beides wird in Zeile/Spalte übersetzt.
    static func jsonIssue(from debugDescription: String, data: Data) -> Issue {
        let message = L10n.string("Ungültiges JSON — Struktur, Kommas und Anführungszeichen prüfen.")
        if let match = firstMatch(of: #"line (\d+), column (\d+)"#,
                                  in: debugDescription),
           let line = Int(match[0]), let column = Int(match[1]) {
            return Issue(line: line, column: column, message: message)
        }
        if let match = firstMatch(of: #"character (\d+)"#, in: debugDescription),
           let offset = Int(match[0]) {
            let prefix = String(decoding: data.prefix(offset), as: UTF8.self)
            let position = lineColumn(atEndOf: prefix)
            return Issue(line: position.line, column: position.column,
                         message: message)
        }
        return Issue(line: 1, column: 1, message: message)
    }

    // MARK: - XML

    private static func lintXML(_ text: String) -> LintResult {
        let parser = XMLParser(data: Data(text.utf8))
        parser.externalEntityResolvingPolicy = .never
        let delegate = LintParserDelegate()
        parser.delegate = delegate
        if parser.parse() {
            return .valid("XML")
        }
        let line = max(1, parser.lineNumber)
        let column = max(1, parser.columnNumber)
        // libxml2-Detail (englisch, technisch) ergänzt die eigene Meldung —
        // es benennt oft das konkrete Tag und ist die ehrlichste Diagnose.
        let detail = (parser.parserError as NSError?)?
            .localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var message = L10n.string("Ungültiges XML — Tags und Verschachtelung prüfen.")
        if let detail, !detail.isEmpty {
            message += "\n(\(detail))"
        }
        return .issue(Issue(line: line, column: column, message: message))
    }

    /// XMLParser verlangt einen Delegate, sonst liefert er keine brauchbaren
    /// Fehlerpositionen für alle Fehlerklassen. Der Delegate tut nichts —
    /// Validierung genügt.
    private final class LintParserDelegate: NSObject, XMLParserDelegate { }

    // MARK: - Positions-Helfer (pure, testbar)

    /// Zeile/Spalte (1-basiert) am ENDE des übergebenen Präfix-Textes.
    /// Spalten zählen Zeichen (nicht Bytes) — multibyte-sicher.
    static func lineColumn(atEndOf prefix: String) -> (line: Int, column: Int) {
        var line = 1
        var column = 1
        for character in prefix {
            if character == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return (line, column)
    }

    private static func firstMatch(of pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text,
                                           range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
