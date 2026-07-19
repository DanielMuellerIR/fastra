import Foundation
import CodeEditLanguages

/// Stabile, nicht lokalisierte Identität eines effektiven Dokumentformats.
///
/// Die Rohwerte landen in persistierten Formatprofilen. Sie dürfen deshalb
/// weder aus sichtbaren UI-Texten abgeleitet noch bei einer Übersetzung
/// verändert werden.
struct DocumentFormatID: RawRepresentable, Hashable, Codable, Identifiable {
    let rawValue: String

    var id: String { rawValue }

    static let plainText = DocumentFormatID(rawValue: "plain-text")
    static let fourD = DocumentFormatID(rawValue: "4d")
    static let xml = DocumentFormatID(rawValue: "xml")
    static let csv = DocumentFormatID(rawValue: "csv")

    /// Eigene, bewusst festgelegte IDs für alle CodeEdit-Sprachen. Ein neuer
    /// Enum-Fall macht den Switch nicht mehr vollständig und erzwingt damit
    /// eine Entscheidung, bevor er unbemerkt in die Persistenz gelangt.
    static func grammar(_ language: TreeSitterLanguage) -> DocumentFormatID {
        let stableID: String
        switch language {
        case .agda: stableID = "agda"
        case .bash: stableID = "bash"
        case .c: stableID = "c"
        case .cpp: stableID = "cpp"
        case .cSharp: stableID = "c-sharp"
        case .css: stableID = "css"
        case .dart: stableID = "dart"
        case .dockerfile: stableID = "dockerfile"
        case .elixir: stableID = "elixir"
        case .go: stableID = "go"
        case .goMod: stableID = "go-mod"
        case .haskell: stableID = "haskell"
        case .html: stableID = "html"
        case .java: stableID = "java"
        case .javascript: stableID = "javascript"
        case .jsdoc: stableID = "jsdoc"
        case .json: stableID = "json"
        case .jsx: stableID = "jsx"
        case .julia: stableID = "julia"
        case .kotlin: stableID = "kotlin"
        case .lua: stableID = "lua"
        case .markdown: stableID = "markdown"
        case .markdownInline: stableID = "markdown-inline"
        case .objc: stableID = "objective-c"
        case .ocaml: stableID = "ocaml"
        case .ocamlInterface: stableID = "ocaml-interface"
        case .perl: stableID = "perl"
        case .php: stableID = "php"
        case .python: stableID = "python"
        case .regex: stableID = "regex"
        case .ruby: stableID = "ruby"
        case .rust: stableID = "rust"
        case .scala: stableID = "scala"
        case .sql: stableID = "sql"
        case .swift: stableID = "swift"
        case .toml: stableID = "toml"
        case .tsx: stableID = "tsx"
        case .typescript: stableID = "typescript"
        case .verilog: stableID = "verilog"
        case .yaml: stableID = "yaml"
        case .zig: stableID = "zig"
        case .plainText: return .plainText
        }
        return DocumentFormatID(rawValue: stableID)
    }
}

/// Gemeinsames Ergebnis der Formatauflösung. Fußzeile, Soft-Wrap-Profil und
/// Editor lesen exakt dieses Objekt und können deshalb nicht auseinanderlaufen.
struct DocumentFormat: Equatable {
    let id: DocumentFormatID
    let displayName: String
    let grammar: CodeLanguage
    let customLanguage: CustomLanguage?
}

/// Werkseinstellung eines Formatprofils. Die Tabelle ist bewusst vollständig
/// statt eines stillen „alles andere aus"-Fallbacks: Der Anti-Drift-Test
/// vergleicht sie mit allen tatsächlich auswählbaren Sprachen.
enum SoftWrapFactoryDefaults {
    enum DefaultClass: Equatable {
        case on
        case off

        var isEnabled: Bool { self == .on }
    }

    static let classes: [DocumentFormatID: DefaultClass] = [
        .plainText: .on,
        .grammar(.bash): .off,
        .grammar(.c): .off,
        .grammar(.cpp): .off,
        .grammar(.cSharp): .off,
        .grammar(.css): .off,
        .grammar(.dart): .off,
        .grammar(.dockerfile): .off,
        .fourD: .off,
        .grammar(.go): .off,
        .grammar(.html): .on,
        .grammar(.java): .off,
        .grammar(.javascript): .off,
        .grammar(.json): .off,
        .grammar(.jsx): .off,
        .grammar(.kotlin): .off,
        .grammar(.lua): .off,
        .grammar(.markdown): .on,
        .grammar(.objc): .off,
        .grammar(.perl): .off,
        .grammar(.php): .off,
        .grammar(.python): .off,
        .grammar(.ruby): .off,
        .grammar(.rust): .off,
        .grammar(.sql): .off,
        .grammar(.swift): .off,
        .grammar(.toml): .off,
        .grammar(.tsx): .off,
        .grammar(.typescript): .off,
        .grammar(.yaml): .off,
        .xml: .on,
        .csv: .off,
    ]

    static func isEnabled(for formatID: DocumentFormatID) -> Bool {
        // Unbekannte künftige Formate bleiben konservativ ohne Soft Wrap.
        // Der Vollständigkeitstest verhindert diesen Pfad für auswählbare
        // Produktsprachen.
        classes[formatID]?.isEnabled ?? false
    }
}

enum DocumentFormatResolver {
    /// Formate, die nicht als eigenständige CodeEdit-Grammatik auswählbar
    /// sind, aber ein eigenes Profil brauchen.
    static let additionalProfileIDs: Set<DocumentFormatID> = [.xml, .csv]

    /// Liefert die Formatidentität eines Menüeintrags. Diese Menge bildet mit
    /// `additionalProfileIDs` die verbindliche Vollständigkeitsbasis der
    /// Werkseinstellungen.
    static func format(for entry: LanguageMenuSupport.Entry) -> DocumentFormat {
        switch entry {
        case .grammar(let language):
            return format(for: language)
        case .custom(let language):
            return format(for: language)
        }
    }

    static func format(for language: CodeLanguage) -> DocumentFormat {
        DocumentFormat(
            id: .grammar(language.id),
            displayName: LanguageMenuSupport.displayName(for: language),
            grammar: language,
            customLanguage: nil
        )
    }

    static func format(for language: CustomLanguage) -> DocumentFormat {
        DocumentFormat(
            id: language.id == CustomLanguageRegistry.fourD.id
                ? .fourD
                : DocumentFormatID(rawValue: language.id),
            displayName: language.displayName,
            grammar: language.baseGrammar,
            customLanguage: language
        )
    }

    static func format(for detected: ContentLanguageDetection.Format) -> DocumentFormat {
        switch detected {
        case .json: return format(for: CodeLanguage.json)
        case .xml: return xmlFormat
        case .html: return format(for: CodeLanguage.html)
        case .markdown: return format(for: CodeLanguage.markdown)
        case .css: return format(for: CodeLanguage.css)
        case .javascript: return format(for: CodeLanguage.javascript)
        }
    }

    /// Effektives Format eines Tabs. Priorität:
    /// 1. bewusste manuelle Wahl,
    /// 2. vorhandene Datei-/Inhaltserkennung,
    /// 3. echter Plain-Text-Fallback.
    static func resolve(tab: EditorTab?) -> DocumentFormat {
        guard let tab else { return plainTextFormat }

        if let customID = tab.customLanguageOverrideID,
           let custom = CustomLanguageRegistry.language(withID: customID) {
            return format(for: custom)
        }
        if let manual = tab.languageOverride {
            return format(for: manual)
        }

        let filename = tab.url?.lastPathComponent ?? tab.title
        let fileExtension = (filename as NSString).pathExtension
        if !fileExtension.isEmpty {
            if let special = formatForSpecialExtension(fileExtension) {
                return special
            }
            let detectionURL = tab.url ?? URL(fileURLWithPath: filename)
            let detected = CodeLanguage.detectLanguageFrom(
                url: detectionURL,
                prefixBuffer: tab.url == nil ? nil : String(tab.content.prefix(512)),
                suffixBuffer: nil
            )
            if detected.id != .plainText {
                return format(for: detected)
            }
            return plainTextFormat
        }

        // Gespeicherte Dateien ohne Endung können über Shebang oder Modeline
        // erkannt werden. Bei ungespeicherten Tabs hat der Workspace dieselbe
        // Upstream-Erkennung bereits nebenläufig ausgeführt.
        if let url = tab.url {
            let detected = CodeLanguage.detectLanguageFrom(
                url: url,
                prefixBuffer: String(tab.content.prefix(512)),
                suffixBuffer: nil
            )
            if detected.id != .plainText {
                return format(for: detected)
            }
        }
        if let detectedFormat = tab.contentDetectedFormat {
            return format(for: detectedFormat)
        }
        if let detectedLanguage = tab.contentDetectedLanguage {
            return format(for: detectedLanguage)
        }
        return plainTextFormat
    }

    static func resolve(filename: String) -> DocumentFormat {
        resolve(tab: EditorTab(title: filename, path: "—"))
    }

    /// Zentrale Sonderendungstabelle. Editor-Grammatik, Footer und Profil
    /// dürfen diese 4D-/XML-/CSV-Zuordnung nicht separat nachbauen.
    static func formatForSpecialExtension(_ fileExtension: String) -> DocumentFormat? {
        switch fileExtension.lowercased() {
        case "4dm":
            return format(for: CustomLanguageRegistry.fourD)
        case "4dproject", "4dform":
            return format(for: CodeLanguage.json)
        case "xml", "xsd", "xsl", "xslt", "plist", "4dcatalog", "4dsettings":
            return xmlFormat
        case "csv":
            return csvFormat
        default:
            return nil
        }
    }

    private static var plainTextFormat: DocumentFormat {
        format(for: CodeLanguage.default)
    }

    private static var xmlFormat: DocumentFormat {
        DocumentFormat(
            id: .xml,
            displayName: "XML",
            // CodeEditLanguages besitzt keine XML-Grammatik; die HTML-
            // Grammatik zeichnet XML-Tags und Attribute verlustfrei.
            grammar: .html,
            customLanguage: nil
        )
    }

    private static var csvFormat: DocumentFormat {
        DocumentFormat(
            id: .csv,
            displayName: "CSV",
            grammar: .default,
            customLanguage: nil
        )
    }
}
