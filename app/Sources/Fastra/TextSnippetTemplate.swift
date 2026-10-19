import Foundation

enum TextSnippetError: LocalizedError {
    case invalidTemplate, sizeLimit, missingValues, unavailable, staleTarget, insertionFailed
    case invalidArchive, duplicateName, staleDefinition, staleCollection, invalidDefinition, collectionLimit

    var errorDescription: String? {
        switch self {
        case .invalidTemplate: return L10n.string("Platzhalter verwenden {{Name}} mit höchstens 64 Zeichen pro Name. Klammern und Zeilenumbrüche sind im Namen nicht erlaubt.")
        case .sizeLimit: return L10n.string("Textbaustein zu groß: höchstens 16 KiB Vorlage oder Feldwert, 32 Platzhalter, 256 KiB Ergebnis und 1 MiB Importdatei.")
        case .missingValues: return L10n.string("Bitte fülle die Platzhalter aus. Ein leerer Wert ist erlaubt.")
        case .unavailable: return L10n.string("Textbausteine benötigen ein editierbares Textdokument mit einer einzelnen Auswahl.")
        case .insertionFailed: return L10n.string("Der Textbaustein konnte nicht eingefügt werden. Prüfe den Hinweis und öffne die Textbausteine bei Bedarf erneut.")
        case .staleTarget: return L10n.string("Das Dokument oder die Einfügestelle hat sich geändert. Öffne die Textbausteine erneut; der vorhandene Inhalt blieb erhalten.")
        case .invalidDefinition: return L10n.string("Ein Textbaustein benötigt einen Namen mit höchstens 80 Zeichen und eine nicht leere Vorlage.")
        case .invalidArchive: return L10n.string("Die Datei enthält keine gültige Textbausteinsammlung. Es wurde nichts übernommen.")
        case .collectionLimit: return L10n.string("Die Sammlung enthält höchstens 50 Textbausteine. Lösche zuerst nicht mehr benötigte Vorlagen oder importiere eine kleinere Sammlung.")
        case .duplicateName: return L10n.string("Ein Textbaustein mit diesem Namen ist bereits vorhanden.")
        case .staleDefinition: return L10n.string("Dieser Textbaustein wurde inzwischen geändert. Lade die Sammlung neu, bevor du speicherst.")
        case .staleCollection: return L10n.string("Die Textbausteinsammlung hat sich während der Bestätigung geändert. Es wurde nichts importiert. Öffne den Import erneut.")
        }
    }
}

struct TextSnippetTemplate {
    static let maximumTemplateBytes = 16 * 1024
    static let maximumValueBytes = 16 * 1024
    static let maximumOutputBytes = 256 * 1024
    static let maximumPlaceholders = 32
    enum Part { case literal(String), placeholder(String) }
    let parts: [Part]
    let names: [String]

    init(_ source: String) throws {
        guard source.utf8.count <= Self.maximumTemplateBytes else { throw TextSnippetError.sizeLimit }
        var parts: [Part] = [], names: [String] = []
        var cursor = source.startIndex
        while let opening = source.range(of: "{{", range: cursor..<source.endIndex) {
            parts.append(.literal(String(source[cursor..<opening.lowerBound])))
            guard let closing = source.range(of: "}}", range: opening.upperBound..<source.endIndex) else {
                throw TextSnippetError.invalidTemplate
            }
            let name = source[opening.upperBound..<closing.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.count <= 64,
                  !name.contains(where: { $0 == "{" || $0 == "}" || $0.isNewline }),
                  name.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw TextSnippetError.invalidTemplate
            }
            if !names.contains(name) { names.append(name) }
            guard names.count <= Self.maximumPlaceholders else { throw TextSnippetError.sizeLimit }
            parts.append(.placeholder(name)); cursor = closing.upperBound
        }
        parts.append(.literal(String(source[cursor...])))
        self.parts = parts; self.names = names
    }

    func render(values: [String: String]) throws -> String {
        var output = "", bytes = 0
        for part in parts {
            let text: String
            switch part {
            case .literal(let literal): text = literal
            case .placeholder(let name):
                guard let value = values[name] else { throw TextSnippetError.missingValues }
                guard value.utf8.count <= Self.maximumValueBytes else { throw TextSnippetError.sizeLimit }
                text = value
            }
            let count = text.utf8.count
            guard count <= Self.maximumOutputBytes - bytes else { throw TextSnippetError.sizeLimit }
            bytes += count; output += text
        }
        return output
    }
}
