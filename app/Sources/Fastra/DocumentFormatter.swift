//
// DocumentFormatter.swift
//
// Kleine, verlustarme Formatter für Formate, die Foundation zuverlässig
// versteht. Bewusst keine halb fertigen Heuristiken für Quellcode: ein
// aktivierter Menüpunkt darf niemals ein Dokument semantisch beschädigen.

import Foundation

enum DocumentFormatterError: LocalizedError, Equatable {
    case unsupportedFormat
    case invalidJSON
    case invalidXML

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "Dieses Dateiformat kann Fastra nicht formatieren."
        case .invalidJSON: return "Das ausgewählte JSON ist ungültig und wurde nicht verändert."
        case .invalidXML: return "Das ausgewählte XML ist ungültig und wurde nicht verändert."
        }
    }
}

struct DocumentFormatResult: Equatable {
    let affectedRange: NSRange
    let replacement: String
}

enum DocumentFormatter {
    static let supportedExtensions: Set<String> = ["json", "xml", "xsd", "xsl", "xslt", "plist"]

    static func supports(fileExtension: String?) -> Bool {
        guard let fileExtension else { return false }
        return supportedExtensions.contains(fileExtension.lowercased())
    }

    /// Formatiert die Auswahl, falls sie nicht leer ist, sonst das gesamte
    /// Dokument. Der Rückgabewert ist `nil` bei einem echten No-op.
    static func format(in text: String, selection: NSRange, fileExtension: String) throws -> DocumentFormatResult? {
        guard supports(fileExtension: fileExtension) else { throw DocumentFormatterError.unsupportedFormat }
        let range = selection.length > 0 ? selection : NSRange(location: 0, length: (text as NSString).length)
        guard let swiftRange = Range(range, in: text) else { return nil }
        let original = String(text[swiftRange])
        let formatted = try format(original, fileExtension: fileExtension)
        guard formatted != original else { return nil }
        return DocumentFormatResult(affectedRange: range, replacement: formatted)
    }

    static func format(_ text: String, fileExtension: String) throws -> String {
        switch fileExtension.lowercased() {
        case "json":
            return try formatJSON(text)
        case "xml", "xsd", "xsl", "xslt", "plist":
            return try formatXML(text)
        default:
            throw DocumentFormatterError.unsupportedFormat
        }
    }

    private static func formatJSON(_ text: String) throws -> String {
        guard let source = text.data(using: .utf8) else { throw DocumentFormatterError.invalidJSON }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: source, options: [.fragmentsAllowed])
        } catch {
            throw DocumentFormatterError.invalidJSON
        }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        } catch {
            throw DocumentFormatterError.invalidJSON
        }
        guard let formatted = String(data: data, encoding: .utf8) else { throw DocumentFormatterError.invalidJSON }
        return restoringLineEnding(from: text, in: formatted)
    }

    private static func formatXML(_ text: String) throws -> String {
        let document: XMLDocument
        do {
            document = try XMLDocument(xmlString: text, options: [.nodePreserveAll])
        } catch {
            throw DocumentFormatterError.invalidXML
        }
        let formatted = document.xmlString(options: [.nodePrettyPrint])
        return restoringLineEnding(from: text, in: formatted)
    }

    // MARK: - Minify (Etappe 6 Wunschpaket 2026-07)

    /// Minifiziert die Auswahl bzw. das ganze Dokument. Gleiche Infrastruktur
    /// und Rückgabe-Semantik wie `format` (nil = No-op).
    static func minify(in text: String, selection: NSRange,
                       fileExtension: String) throws -> DocumentFormatResult? {
        guard supports(fileExtension: fileExtension) else {
            throw DocumentFormatterError.unsupportedFormat
        }
        let range = selection.length > 0
            ? selection : NSRange(location: 0, length: (text as NSString).length)
        guard let swiftRange = Range(range, in: text) else { return nil }
        let original = String(text[swiftRange])
        let minified = try minify(original, fileExtension: fileExtension)
        guard minified != original else { return nil }
        return DocumentFormatResult(affectedRange: range, replacement: minified)
    }

    static func minify(_ text: String, fileExtension: String) throws -> String {
        switch fileExtension.lowercased() {
        case "json":
            return try minifyJSON(text)
        case "xml", "xsd", "xsl", "xslt", "plist":
            return try minifyXML(text)
        default:
            throw DocumentFormatterError.unsupportedFormat
        }
    }

    /// Kompakte JSON-Serialisierung. Schlüssel werden — konsistent zum
    /// Formatieren — sortiert (dokumentiertes Verhalten: beide Wege nutzen
    /// dieselbe Serialisierung, nur mit/ohne Einrückung).
    private static func minifyJSON(_ text: String) throws -> String {
        guard let source = text.data(using: .utf8) else {
            throw DocumentFormatterError.invalidJSON
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: source,
                                                      options: [.fragmentsAllowed])
        } catch {
            throw DocumentFormatterError.invalidJSON
        }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys, .fragmentsAllowed])
        } catch {
            throw DocumentFormatterError.invalidJSON
        }
        guard let minified = String(data: data, encoding: .utf8) else {
            throw DocumentFormatterError.invalidJSON
        }
        return minified
    }

    /// BEWUSST konservatives XML-Minify: entfernt ausschließlich
    /// Whitespace-Läufe MIT Zeilenumbruch zwischen zwei Tags (typische
    /// Einrückung). Einzelne Leerzeichen zwischen Inline-Elementen bleiben
    /// stehen (können bedeutungstragend sein), ebenso alles innerhalb von
    /// CDATA und Kommentaren. Ungültiges XML wird nicht angefasst.
    private static func minifyXML(_ text: String) throws -> String {
        // Erst validieren — Minify darf nie ein kaputtes Dokument „reparieren".
        let parser = XMLParser(data: Data(text.utf8))
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse() else { throw DocumentFormatterError.invalidXML }

        var result = String()
        result.reserveCapacity(text.count)
        var pendingWhitespace = ""
        var pendingHasNewline = false
        var index = text.startIndex
        var lastNonWhitespace: Character = " "

        func flushPending() {
            if !pendingWhitespace.isEmpty {
                result.append(pendingWhitespace)
                pendingWhitespace = ""
                pendingHasNewline = false
            }
        }

        while index < text.endIndex {
            let character = text[index]
            // CDATA und Kommentare unverändert übernehmen. Einrückungs-
            // Whitespace davor fällt wie vor jedem anderen Tag weg.
            if character == "<" {
                if pendingHasNewline && lastNonWhitespace == ">" {
                    pendingWhitespace = ""
                    pendingHasNewline = false
                }
                let rest = text[index...]
                for (opener, closer) in [("<![CDATA[", "]]>"), ("<!--", "-->")] {
                    if rest.hasPrefix(opener) {
                        flushPending()
                        if let end = text.range(of: closer, range: index..<text.endIndex) {
                            result.append(contentsOf: text[index..<end.upperBound])
                            index = end.upperBound
                        } else {
                            result.append(contentsOf: rest)
                            index = text.endIndex
                        }
                        lastNonWhitespace = ">"
                        break
                    }
                }
                if index < text.endIndex, text[index] == "<", !text[index...].hasPrefix("<![CDATA["),
                   !text[index...].hasPrefix("<!--") {
                    flushPending()
                    result.append(character)
                    lastNonWhitespace = character
                    index = text.index(after: index)
                }
                continue
            }
            if character.isWhitespace {
                pendingWhitespace.append(character)
                if character == "\n" || character == "\r" { pendingHasNewline = true }
                index = text.index(after: index)
                continue
            }
            flushPending()
            result.append(character)
            lastNonWhitespace = character
            index = text.index(after: index)
        }
        // Whitespace am Dokumentende mit Zeilenumbruch entfällt ebenfalls.
        if !pendingHasNewline { flushPending() }
        return result
    }

    /// Formatter geben LF aus. Die Datei behält dennoch ihre bisherige
    /// Zeilenende-Konvention und einen bereits vorhandenen Endzeilenumbruch.
    private static func restoringLineEnding(from original: String, in formatted: String) -> String {
        // Nicht `LineEnding.converting` verwenden: Die Formatter arbeiten
        // bewusst mit einem einzelnen Ausschnitt; die konkrete Konvention
        // wird daher hier direkt aus diesem Ausschnitt übernommen.
        let separator: String
        if original.contains("\r\n") { separator = "\r\n" }
        else if original.contains("\r") { separator = "\r" }
        else { separator = "\n" }
        // Byteweise statt `hasSuffix`: CRLF ist ein Zeichenpaar und soll als
        // vorhandener Endumbruch auch dann erhalten bleiben, wenn Foundation
        // den String intern über eine bridged Darstellung liefert.
        let hasFinalNewline = original.utf8.last == 10 || original.utf8.last == 13
        var normalized = formatted
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if !hasFinalNewline {
            while normalized.hasSuffix("\n") { normalized.removeLast() }
        } else if !normalized.hasSuffix("\n") {
            normalized.append("\n")
        }
        return separator == "\n" ? normalized : normalized.replacingOccurrences(of: "\n", with: separator)
    }
}
