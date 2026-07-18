// FourDTokenTransform.swift
//
// Transformation „tokenisierter 4D-Export ↔ Klartext" (Etappe 6 Wunschpaket
// 2026-07c). Kanonische 4D-Exporte hängen Token-Suffixe an Befehle und
// Konstanten (`ALERT:C41`, `Into variable:K79:31`) — zum Lesen/Diffen stört
// das, zum Wiedereinspielen hilft es.
//
// Ehrliche Grenzen:
// - „Token-Suffixe entfernen" strippt BEIDE Formen (:Cnnn und :Knn:mm) —
//   token-basiert über den FourDTokenizer, Strings/Kommentare bleiben also
//   unangetastet.
// - „Befehls-Token ergänzen" kennt nur BEFEHLS-Nummern (aus der 4D-Doku
//   generiert, siehe FourDSymbols). Konstanten-Nummern stehen in keiner
//   öffentlichen Quelle — Konstanten bleiben unverändert, das steht so im
//   Menütitel (kein stilles Halbergebnis).

import Foundation

enum FourDTokenTransform {

    // MARK: - Reiner Kern (unit-getestet, Roundtrip)

    /// Entfernt Token-Suffixe von Befehlen und Konstanten: `ALERT:C41` →
    /// `ALERT`, `Into variable:K79:31` → `Into variable`.
    static func detokenize(_ text: String) -> String {
        let tokens = FourDTokenizer.tokenize(text)
        let original = text as NSString
        let result = NSMutableString(string: text)
        // Rückwärts ersetzen — vordere Ranges bleiben gültig.
        for token in tokens.reversed()
        where token.kind == .command || token.kind == .constant {
            let value = original.substring(with: token.range)
            guard let colon = value.firstIndex(of: ":") else { continue }
            let suffix = String(value[colon...])
            guard isTokenSuffix(suffix) else { continue }
            let name = String(value[..<colon])
            result.replaceCharacters(in: token.range, with: name)
        }
        return result as String
    }

    /// Ergänzt Befehls-Token: `ALERT` → `ALERT:C41`. Nur für Befehle mit
    /// bekannter Nummer; bereits tokenisierte Vorkommen bleiben unverändert.
    static func tokenizeCommands(_ text: String) -> String {
        let tokens = FourDTokenizer.tokenize(text)
        let original = text as NSString
        let result = NSMutableString(string: text)
        for token in tokens.reversed() where token.kind == .command {
            let value = original.substring(with: token.range)
            guard !value.contains(":") else { continue }   // schon tokenisiert
            guard let number = FourDSymbols
                .commandDetails[value.lowercased()]?.number else { continue }
            result.insert(":C\(number)", at: NSMaxRange(token.range))
        }
        return result as String
    }

    /// Echte 4D-Token-Suffixe: `:C123` (Befehl) bzw. `:K12:34`/`:K123`
    /// (Konstante). Alles andere (etwa ein Doppelpunkt im Text) bleibt stehen.
    static func isTokenSuffix(_ suffix: String) -> Bool {
        suffix.range(of: #"^:(C\d+|K\d+(:\d+)?)$"#,
                     options: .regularExpression) != nil
    }

    // MARK: - Adapter für das „Text"-Menü (Selektion bzw. ganze Datei)

    static func detokenizeOperation(in text: String,
                                    selection: NSRange) -> LineOperations.Result? {
        transformSelection(in: text, selection: selection, detokenize)
    }

    static func tokenizeCommandsOperation(in text: String,
                                          selection: NSRange) -> LineOperations.Result? {
        transformSelection(in: text, selection: selection, tokenizeCommands)
    }

    /// Zeichen-Scope wie die Groß-/Klein-Operationen: wirkt exakt auf die
    /// Selektion, ohne Selektion auf den ganzen Text; `nil` = nichts zu tun.
    private static func transformSelection(
        in text: String, selection: NSRange,
        _ transform: (String) -> String
    ) -> LineOperations.Result? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let full = NSRange(location: 0, length: ns.length)
        let range = selection.length > 0
            ? NSIntersectionRange(selection, full) : full
        guard range.length > 0 else { return nil }
        let original = ns.substring(with: range)
        let transformed = transform(original)
        guard transformed != original else { return nil }
        let newText = ns.replacingCharacters(in: range, with: transformed)
        return LineOperations.Result(newText: newText, affectedRange: range,
                                     lineCount: 0)
    }
}
