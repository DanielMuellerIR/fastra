// LanguageMenuSupport.swift
//
// Manueller Sprachumschalter im Footer (Etappe 3 Wunschpaket 2026-07) —
// das Sicherheitsventil gegen Fehlerkennung: Die manuelle Wahl gewinnt
// immer und beendet die Automatik für den Tab.

import Foundation
import CodeEditLanguages

enum LanguageMenuSupport {

    /// Grammatiken, die als eigenständige Dokumentsprache im Menü keinen
    /// Sinn ergeben (eingebettete Hilfs-Grammatiken). Bewusst dokumentierte
    /// Ausnahme-Liste — der Anti-Drift-Unit-Test wacht darüber, dass sie
    /// nicht unbemerkt wächst.
    static let hiddenIDs: Set<TreeSitterLanguage> = [
        .jsdoc, .markdownInline, .regex, .goMod,
    ]

    /// Ein Eintrag im Sprachmenü: entweder eine CodeEditLanguages-Grammatik
    /// oder eine Eigen-Sprache aus der `CustomLanguageRegistry` (Etappe 3
    /// Wunschpaket 2026-07b — 4D ist damit manuell wählbar).
    enum Entry: Identifiable, Equatable {
        case grammar(CodeLanguage)
        case custom(CustomLanguage)

        var id: String {
            switch self {
            case .grammar(let language): return "grammar.\(language.id.rawValue)"
            case .custom(let language):  return language.id
            }
        }

        var displayName: String {
            switch self {
            case .grammar(let language): return LanguageMenuSupport.displayName(for: language)
            case .custom(let language):  return language.displayName
            }
        }
    }

    /// Wählbare Sprachen: Plaintext zuerst, danach alle Sprachen, deren
    /// Grammatik wirklich im Bundle steckt (build.sh schneidet exotische
    /// Grammatiken aus — die zeigen nur Plaintext und wären im Menü
    /// irreführend), PLUS alle Eigen-Sprachen der Registry, gemeinsam
    /// alphabetisch nach Anzeigename.
    static var selectableEntries: [Entry] {
        let withGrammar = CodeLanguage.allLanguages
            .filter { $0.language != nil && !hiddenIDs.contains($0.id) }
            .map(Entry.grammar)
        let custom = CustomLanguageRegistry.all.map(Entry.custom)
        let sorted = (withGrammar + custom).sorted {
            $0.displayName.localizedStandardCompare($1.displayName)
                == .orderedAscending
        }
        return [.grammar(.default)] + sorted
    }

    /// Lesbarer Menü-/Chip-Name. `tsName` ist technisch („cpp", „csharp") —
    /// die gängigen Namen sind kuratiert, der Rest wird kapitalisiert.
    static func displayName(for language: CodeLanguage) -> String {
        switch language.id {
        case .plainText: return L10n.string("Reiner Text")
        case .c: return "C"
        case .cpp: return "C++"
        case .cSharp: return "C#"
        case .css: return "CSS"
        case .html: return "HTML"
        case .json: return "JSON"
        case .jsx: return "JSX"
        case .objc: return "Objective-C"
        case .php: return "PHP"
        case .sql: return "SQL"
        case .toml: return "TOML"
        case .tsx: return "TSX"
        case .typescript: return "TypeScript"
        case .javascript: return "JavaScript"
        case .yaml: return "YAML"
        case .goMod: return "go.mod"
        default: return language.tsName.capitalized
        }
    }
}
