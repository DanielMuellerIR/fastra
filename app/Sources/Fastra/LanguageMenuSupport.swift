// LanguageMenuSupport.swift
//
// Manueller Sprachumschalter im Footer (Etappe 3 Wunschpaket 2026-07) —
// das Sicherheitsventil gegen Fehlerkennung: Die manuelle Wahl gewinnt
// immer und beendet die Automatik für den Tab.

import Foundation
import CodeEditLanguages

enum LanguageMenuSupport {

    /// Grammatiken, die als eigenständige Dokumentsprache im Menü keinen
    /// Sinn ergeben (eingebettete Hilfs-Grammatiken).
    private static let hiddenIDs: Set<TreeSitterLanguage> = [
        .jsdoc, .markdownInline, .regex, .goMod,
    ]

    /// Wählbare Sprachen: Plaintext zuerst, danach alle Sprachen, deren
    /// Grammatik wirklich im Bundle steckt (build.sh schneidet exotische
    /// Grammatiken aus — die zeigen nur Plaintext und wären im Menü
    /// irreführend), alphabetisch nach Anzeigename.
    static var selectableLanguages: [CodeLanguage] {
        let withGrammar = CodeLanguage.allLanguages
            .filter { $0.language != nil && !hiddenIDs.contains($0.id) }
            .sorted {
                displayName(for: $0).localizedStandardCompare(displayName(for: $1))
                    == .orderedAscending
            }
        return [.default] + withGrammar
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
