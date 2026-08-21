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
            // `Date` und `Time` sind zugleich Befehle und Typen. In einer
            // Deklaration darf aus `var $d : Date` deshalb nie `Date:C102`
            // werden.
            guard !isDeclarationType(token, in: original) else { continue }
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

    // MARK: - Lernende Rücktokenisierung (für die 4D-Makro-Engine)

    /// Lernt die vorhandenen Token-Suffixe eines tokenisierten Textes:
    /// Name (lowercased) → Suffix, z. B. `"alert" → ":C41"` und
    /// `"into variable" → ":K79:31"`. Grundlage, um nach einem headless
    /// ausgeführten 4D-Makro (das untokenisierten Code liefert) auch die
    /// KONSTANTEN-Token wiederherzustellen — deren Nummern stehen in keiner
    /// öffentlichen Quelle, wohl aber im Original-Puffer.
    static func learnedSuffixes(from text: String) -> [String: String] {
        let tokens = FourDTokenizer.tokenize(text)
        let original = text as NSString
        var learned: [String: String] = [:]
        for token in tokens where token.kind == .command || token.kind == .constant {
            let value = original.substring(with: token.range)
            guard let colon = value.firstIndex(of: ":") else { continue }
            let suffix = String(value[colon...])
            guard isTokenSuffix(suffix) else { continue }
            learned[String(value[..<colon]).lowercased()] = suffix
        }
        return learned
    }

    /// Token-Klassen, die ein gelerntes Suffix zurückbekommen dürfen: alles,
    /// was ein NAME ist. Der Umweg ist nötig, weil der Tokenizer denselben
    /// Namen vor und nach dem Entfernen des Suffixes unterschiedlich einstuft:
    /// `FutureCommand:C9999` erkennt er am `:C` als Befehl, das nackte
    /// `FutureCommand(` mangels Eintrag im Katalog aber als Methodenaufruf.
    /// Nur auf `.command`/`.constant` zu schauen verlöre deshalb genau die
    /// Suffixe neuer, noch unbekannter 4D-Symbole. Kommentare, Zeichenketten,
    /// Zahlen und Variablen mit Sigil (`$x`, `<>x`) bleiben außen vor.
    private static let retokenizableKinds: Set<FourDTokenizer.Kind> = [
        .command, .constant, .methodCall, .processVariable,
    ]

    /// Fügt einem untokenisierten Text Token-Suffixe wieder an: zuerst das
    /// gelernte Suffix aus dem Original, für neue Befehle ohne gelerntes
    /// Suffix die bekannte Befehlsnummer aus `FourDSymbols`. Konstanten ohne
    /// gelerntes Suffix bleiben unverändert (ehrliche Grenze wie beim
    /// Menübefehl „Befehls-Token ergänzen").
    static func retokenize(_ text: String, learned: [String: String]) -> String {
        let tokens = FourDTokenizer.tokenize(text)
        let original = text as NSString
        let result = NSMutableString(string: text)
        // Längster Name zuerst: Sind `MyConst` UND `MyConst Extra` gelernt,
        // gehört das Suffix am gemeinsamen Start dem vollständigen Symbol.
        var learnedNames: [(name: String, length: Int, suffix: String)] = []
        for (name, suffix) in learned {
            learnedNames.append((name, (name as NSString).length, suffix))
        }
        learnedNames.sort {
            $0.length == $1.length ? $0.name < $1.name : $0.length > $1.length
        }
        // Erst planen, dann anwenden. Ein gelernter mehrwortiger Name deckt
        // die Folge-Tokens mit ab: Für `Future Tail` liefert der Tokenizer
        // ohne Suffix zwei Namen (`Future` und `Tail`). Sind BEIDE gelernt,
        // bekäme derselbe Textbereich zwei Suffixe — zuerst das von `Tail`,
        // danach am selben Offset das von `Future Tail`. Der Vorwärtslauf mit
        // `claimedUntil` belegt den Bereich des längeren Treffers und lässt
        // die darin liegenden Tokens aus.
        var insertions: [(at: Int, suffix: String)] = []
        var claimedUntil = 0
        for token in tokens where retokenizableKinds.contains(token.kind) {
            guard token.range.location >= claimedUntil else { continue }
            let value = original.substring(with: token.range)
            guard !value.contains(":") else { continue }   // schon tokenisiert
            if let match = learnedMatch(at: token.range.location,
                                        tokenValue: value,
                                        in: original,
                                        candidates: learnedNames) {
                let end = token.range.location + match.length
                insertions.append((end, match.suffix))
                claimedUntil = end
            } else if token.kind == .command,
                      !isDeclarationType(token, in: original),
                      let number = FourDSymbols
                          .commandDetails[value.lowercased()]?.number {
                insertions.append((NSMaxRange(token.range), ":C\(number)"))
                claimedUntil = NSMaxRange(token.range)
            }
        }
        // Von hinten einfügen, damit die geplanten Offsets gültig bleiben.
        for insertion in insertions.reversed() {
            result.insert(insertion.suffix, at: insertion.at)
        }
        return result as String
    }

    /// Vollständiger gelernter Name am Tokenanfang. Der Tokenizer kennt einen
    /// unbekannten mehrwortigen Namen ohne Suffix nur bis zum ersten Wort;
    /// die gelernte Symbolmenge liefert hier die fehlende Grenze nach.
    private static func learnedMatch(
        at location: Int,
        tokenValue: String,
        in text: NSString,
        candidates: [(name: String, length: Int, suffix: String)]
    ) -> (length: Int, suffix: String)? {
        let tokenName = tokenValue.lowercased()
        for candidate in candidates
        where candidate.name.hasPrefix(tokenName)
            && location + candidate.length <= text.length {
            let range = NSRange(location: location, length: candidate.length)
            guard text.substring(with: range).compare(
                candidate.name, options: [.caseInsensitive]
            ) == .orderedSame else { continue }
            let end = NSMaxRange(range)
            if end < text.length,
               let scalar = UnicodeScalar(text.character(at: end)),
               CharacterSet.alphanumerics.contains(scalar) || scalar.value == 0x5F {
                continue
            }
            return (candidate.length, candidate.suffix)
        }
        return nil
    }

    /// Erkennt die Typposition in `var … : Typ` und `#DECLARE(… : Typ)`.
    /// Nur der Text derselben Zeile vor dem Token zählt; Strings und
    /// Kommentare erreichen diese Funktion nicht als Befehls-Token.
    private static func isDeclarationType(_ token: FourDTokenizer.Token,
                                          in text: NSString) -> Bool {
        guard token.range.location > 0 else { return false }
        let prefix = text.substring(to: token.range.location)
        let line = prefix.components(separatedBy: .newlines).last ?? ""
        return line.range(
            of: #"(?i)(?:\bvar\b|#declare\b)[^\r\n]*:\s*$"#,
            options: .regularExpression
        ) != nil
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
