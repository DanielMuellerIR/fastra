// LanguageDetection.swift
//
// Inhaltsbasierte Spracherkennung für ungespeicherte, endungslose Tabs
// (Etappe 3 Wunschpaket 2026-07). Reine, UI-unabhängige Logik:
// - konservative Format-Heuristiken (nur bei hoher Konfidenz ein Ergebnis)
// - Hysterese (einmal Erkanntes flackert beim Tippen nicht zurück)
// - Auslöser-/Drossel-Entscheidung (Paste sofort, sonst Debounce)
// Die Einbettung (Debounce-Timer, Hintergrund-Thread, Tab-Zustand) liegt im
// Workspace; hier ist alles pure Funktion und damit direkt unit-testbar.

import Foundation

enum ContentLanguageDetection {

    /// Analysiert höchstens die ersten ~64 KB — mehr braucht keine der
    /// Heuristiken, und riesige Einfügungen dürfen nie teuer werden.
    static let analysisCharacterLimit = 64 * 1024

    /// Ab dieser Zeichenzahl in EINER Änderung gilt sie als Block-Einfügung
    /// (Paste/Drop) → sofort analysieren statt zu warten.
    static let bulkInsertThreshold = 32

    /// Drossel: Eine erneute (debouncte) Analyse lohnt erst, wenn sich der
    /// Inhalt gegenüber der letzten Analyse substanziell geändert hat.
    static let substantialChangeThreshold = 8

    /// Debounce nach normalem Tippen (Spezifikation: 0,8 s).
    static let debounceInterval: TimeInterval = 0.8

    /// Erkennbare Formate — bewusst nur die, für die eine Heuristik mit
    /// hoher Konfidenz möglich ist.
    enum Format: String, CaseIterable, Equatable {
        case json, xml, html, markdown, css, javascript
    }

    // MARK: - Auslöser/Drossel (pure)

    enum Trigger: Equatable {
        case immediate   // Block-Einfügung → sofort analysieren
        case debounced   // normales Tippen → nach 0,8 s Ruhe analysieren
        case none        // Änderung zu klein → gar nicht analysieren
    }

    /// Entscheidet aus Längenänderung und letzter Analyse, ob und wie
    /// analysiert wird. Längen statt Hashes: billig, und für „substanziell
    /// geändert" völlig ausreichend.
    static func trigger(oldLength: Int, newLength: Int,
                        lastAnalyzedLength: Int?) -> Trigger {
        let delta = abs(newLength - oldLength)
        if delta >= bulkInsertThreshold { return .immediate }
        guard let lastAnalyzedLength else { return .debounced }
        return abs(newLength - lastAnalyzedLength) >= substantialChangeThreshold
            ? .debounced : .none
    }

    // MARK: - Hysterese (pure)

    /// Eine gesetzte Erkennung wird nur durch STARKE Gegenevidenz ersetzt —
    /// also durch ein ANDERES Format mit hoher Konfidenz. Liefert die
    /// Analyse nichts (`nil`), bleibt die bisherige Erkennung stehen (kein
    /// Hin-und-her-Flackern, während ein Dokument beim Tippen kurzzeitig
    /// „ungültig" ist).
    static func shouldReplace(current: Format?, with new: Format?) -> Bool {
        guard let new else { return false }
        return new != current
    }

    // MARK: - Erkennung (pure)

    /// Konservative Format-Erkennung über den Textanfang (max. ~64 KB).
    /// `nil` = keine Heuristik war sich sicher → Tab bleibt Plaintext.
    static func detect(in fullText: String) -> Format? {
        let text = String(fullText.prefix(analysisCharacterLimit))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Sehr kurze Schnipsel liefern keine hohe Konfidenz.
        guard trimmed.count >= 8 else { return nil }

        if let structured = detectStructured(trimmed: trimmed,
                                             isComplete: fullText.count <= analysisCharacterLimit) {
            return structured
        }

        // CSS und JavaScript können sich oberflächlich ähneln — sind BEIDE
        // Heuristiken überzeugt, ist gar nichts sicher (konservativ).
        let css = looksLikeCSS(trimmed)
        let js = looksLikeJavaScript(trimmed)
        switch (css, js) {
        case (true, false): return .css
        case (false, true): return .javascript
        default: break
        }

        if looksLikeMarkdown(trimmed) { return .markdown }
        return nil
    }

    /// JSON/XML/HTML: Formate mit eindeutigem Anfang bzw. echtem Parser.
    private static func detectStructured(trimmed: String, isComplete: Bool) -> Format? {
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("<!doctype html") || lowered.hasPrefix("<html") {
            return .html
        }
        if lowered.hasPrefix("<?xml") { return .xml }

        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            // Vollständig vorliegender Text: der echte Parser ist die höchste
            // Konfidenz, die es gibt.
            if isComplete,
               (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil {
                return .json
            }
            // Abgeschnittener Riesen-Paste: typischer JSON-Anfang
            // („{ "schlüssel": …" bzw. „[ { "schlüssel": …") reicht — ein
            // JavaScript-PROGRAMM beginnt nie mit einem nackten Objektliteral.
            if trimmed.range(of: #"^[\[{][\s\[{]*"[^"\n]+"\s*:"#,
                             options: .regularExpression) != nil {
                return .json
            }
            return nil
        }

        if trimmed.hasPrefix("<"), isComplete, parsesAsXML(trimmed) {
            return .xml
        }
        return nil
    }

    /// Streng: nur wohlgeformtes XML zählt (XMLParser über den ganzen Text).
    private static func parsesAsXML(_ text: String) -> Bool {
        let parser = XMLParser(data: Data(text.utf8))
        parser.externalEntityResolvingPolicy = .never
        return parser.parse()
    }

    /// CSS: mindestens zwei Regelblöcke `selektor { eigenschaft: wert; }` und
    /// keine JavaScript-Marker.
    private static func looksLikeCSS(_ text: String) -> Bool {
        guard !text.hasPrefix("<") else { return false }
        let rulePattern = #"[^\{\}\n;]+\{[^\{\}]*[a-zA-Z-]+\s*:[^\{\}]+\}"#
        guard countMatches(of: rulePattern, in: text) >= 2 else { return false }
        let jsMarkers = ["function ", "=>", "const ", "let ", "console.", "==="]
        return !jsMarkers.contains(where: text.contains)
    }

    /// JavaScript: mindestens zwei VERSCHIEDENE starke, JS-typische Marker.
    /// (Ein einzelner Treffer wie `const` käme auch in C/C++ vor.)
    private static func looksLikeJavaScript(_ text: String) -> Bool {
        let markers = [
            "function ", "function(", "=>", "const ", "let ", "console.",
            "===", "!==", "document.", "require(", "export ", "import ",
        ]
        let hits = markers.filter(text.contains).count
        return hits >= 2
    }

    /// Markdown: mindestens zwei VERSCHIEDENE Marker-Arten. Eine einzelne
    /// `#`-Zeile könnte auch ein Shell-Kommentar sein — erst die Kombination
    /// (Überschrift + Link, Überschrift + Codezaun, …) ist hohe Konfidenz.
    private static func looksLikeMarkdown(_ text: String) -> Bool {
        var kinds = 0
        if countMatches(of: #"(?m)^#{1,6} \S"#, in: text) >= 1 { kinds += 1 }
        if countMatches(of: #"(?m)^```"#, in: text) >= 2 { kinds += 1 }
        if countMatches(of: #"\[[^\]\n]+\]\([^)\n]+\)"#, in: text) >= 1 { kinds += 1 }
        if countMatches(of: #"(?m)^[-*] \S[^\n]*\n[-*] \S"#, in: text) >= 1 { kinds += 1 }
        if countMatches(of: #"(?m)^> \S"#, in: text) >= 1 { kinds += 1 }
        return kinds >= 2
    }

    private static func countMatches(of pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text,
                                     range: NSRange(text.startIndex..., in: text))
    }
}
