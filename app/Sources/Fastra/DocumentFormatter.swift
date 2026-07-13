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
