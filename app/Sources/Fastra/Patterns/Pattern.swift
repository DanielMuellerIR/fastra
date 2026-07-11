// Patterns/Pattern.swift
//
// Datenstruktur für die mitgelieferten RegEx-Vorlagen.
// Siehe Konzept: Produktmanagement/Suchmasken-Konzept-v1.0.md (Abschnitt B).
//
// Eine `PatternTemplate` beschreibt einen wieder­verwendbaren Such­ausdruck —
// inklusive eines Beispiel-Treffers (für Tests + UI-Vorschau) und einer
// menschen­lesbaren Beschriftung pro Capture Group.
//
// Die `defaultReplacement` ist optional und enthält die Standard-Umsortierung
// für die Ersetzung (z.B. `$2/$1` für „Dateiname vor Pfad"). Wenn `nil`,
// wird keine Ersetzungsvorlage vorgeschlagen.

import Foundation

/// Kategorie einer Vorlage. Wird in der UI als Gruppierung im Vorlagen-Picker
/// verwendet (Suchmasken-Konzept Abschnitt B).
public enum PatternCategory: String, CaseIterable, Sendable, Codable {
    case identifier   = "Identifikatoren"
    case dateTime     = "Datum & Zeit"
    case textStructure = "Text-Strukturen"
    case numbers      = "Zahlen"
    // Neue Kategorien (v1.1) bewusst NACH den bestehenden — der Picker
    // iteriert `allCases`, so bleiben die etablierten Vorlagen oben.
    case words        = "Wörter & Zeilen"
    case whitespace   = "Leerraum & Aufräumen"
}

/// Eine kuratierte RegEx-Vorlage (E-Mail, ISO-Datum, Dateipfad …).
///
/// Die Vorlagen liegen statisch in `BuiltInPatterns.all`. Eigene Vorlagen
/// (User-defined) sind erst für v1.1+ geplant — die Struktur ist trotzdem
/// schon vorhanden, damit der Datenfluss von Anfang an einheitlich bleibt.
public struct PatternTemplate: Identifiable, Hashable, Sendable {
    /// Stabiler Bezeichner (snake_case, intern). Wird **nicht** lokalisiert
    /// und nicht angezeigt. Wichtig für persistente Verweise (z.B. „zuletzt
    /// benutzte Vorlage" im UserDefaults).
    public let id: String

    /// Klartext-Name, wie er im Vorlagen-Picker erscheint.
    public let name: String

    /// Welche Spalte/Kategorie im Picker.
    public let category: PatternCategory

    /// Der eigentliche RegEx-String, kompatibel zu `NSRegularExpression`.
    /// Wir bleiben bewusst bei NSRegularExpression statt Swift-`Regex`,
    /// weil AGENTS.md das so festgelegt hat (v1.0-Scope).
    public let regex: String

    /// Beispiel-Text, der von `regex` exakt komplett gematcht wird.
    /// Wird sowohl in den Tests verwendet (jeder Beispiel-Match muss
    /// matchen) als auch in der UI-Vorschau („Beispiel: max@…").
    public let exampleMatch: String

    /// Menschen-lesbare Beschriftung pro Capture Group (1-basiert).
    /// `groupLabels[0]` beschreibt Gruppe `$1`, `groupLabels[1]` Gruppe
    /// `$2` usw. Leer, wenn die Vorlage keine Gruppen hat.
    public let groupLabels: [String]

    /// Vorschlag für eine Standard-Ersetzung. Beispiel: bei „Dateipfad"
    /// (`(ordner)/(datei)`) könnte das `$2` sein (nur Dateiname behalten),
    /// oder `$2/$1` (Reihenfolge umdrehen). `nil` = kein Vorschlag.
    public let defaultReplacement: String?

    public init(
        id: String,
        name: String,
        category: PatternCategory,
        regex: String,
        exampleMatch: String,
        groupLabels: [String] = [],
        defaultReplacement: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.regex = regex
        self.exampleMatch = exampleMatch
        self.groupLabels = groupLabels
        self.defaultReplacement = defaultReplacement
    }
}

// MARK: - Hilfsfunktionen

public extension PatternTemplate {
    /// Kompiliert den RegEx (wirft, wenn der RegEx-String defekt ist).
    /// Die mitgelieferten Vorlagen werden im Test abgesichert — diese
    /// Methode dient zur Laufzeit-Anwendung in der App.
    func compile(options: NSRegularExpression.Options = []) throws -> NSRegularExpression {
        try NSRegularExpression(pattern: regex, options: options)
    }

    /// Anzahl Capture Groups laut kompilierter RegEx. Praktisch in Tests
    /// und für Debugging, damit `groupLabels.count` zur tatsächlichen
    /// Gruppen­anzahl konsistent bleibt.
    var declaredGroupCount: Int {
        // Wenn der RegEx defekt ist, geben wir 0 zurück — Tests fangen das ab.
        (try? compile().numberOfCaptureGroups) ?? 0
    }
}
