// LanguageDetection.swift
//
// Inhaltsbasierte Spracherkennung für ungespeicherte, endungslose Tabs
// (Etappe 3 Wunschpaket 2026-07). Reine, UI-unabhängige Logik:
// - konservative Format-Heuristiken (nur bei hoher Konfidenz ein Ergebnis)
// - Hysterese (einmal Erkanntes flackert beim Tippen nicht zurück)
// - Auslöser-/Drossel-Entscheidung (Paste sofort, sonst Debounce)
// Debounce, Hintergrundarbeit und Abbruch koordiniert der
// DocumentLanguageDetector; hier ist alles pure Funktion und damit direkt
// unit-testbar.

import Foundation

enum ContentLanguageDetection {

    /// Analysiert höchstens die ersten 64 KiB UTF-8 — mehr braucht keine der
    /// Heuristiken, und ein einzelner riesiger Graphemcluster darf die Grenze
    /// ebenso wenig umgehen wie ein langer ASCII-Text.
    static let analysisUTF8ByteLimit = 64 * 1024

    /// Begrenzte Parser-Eingabe samt Information, ob sie das vollständige
    /// Dokument enthält. Der zweite Wert ist für strenge Ganzdokument-Parser
    /// wichtig: Eine abgeschnittene XML-Probe darf nicht als vollständiges,
    /// aber ungültiges Dokument fehlgedeutet werden.
    struct AnalysisSample: Equatable, Sendable {
        let text: String
        let isComplete: Bool
    }

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
    /// analysiert wird. Der Aufrufer meldet nur echte Inhaltsänderungen;
    /// gleiche Länge kann deshalb eine vollständige Ersetzung bedeuten und
    /// darf die bisher erkannte Sprache nicht dauerhaft festhalten.
    static func trigger(oldLength: Int, newLength: Int,
                        lastAnalyzedLength: Int?) -> Trigger {
        let delta = abs(newLength - oldLength)
        if delta >= bulkInsertThreshold { return .immediate }
        if delta == 0 { return .debounced }
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

    /// Baut eine echte Bytegrenze auf einer UTF-8-Skalargrenze. Ein Swift-
    /// `Character` kann aus beliebig vielen kombinierenden Skalaren bestehen;
    /// `String.prefix(64 * 1024)` wäre deshalb keine Speichergrenze.
    static func analysisSample(from fullText: String) -> AnalysisSample {
        let utf8 = fullText.utf8
        guard utf8.count > analysisUTF8ByteLimit else {
            return AnalysisSample(text: fullText, isComplete: true)
        }

        var end = utf8.index(
            utf8.startIndex, offsetBy: analysisUTF8ByteLimit
        )
        // UTF-8-Skalare belegen höchstens vier Bytes. Deshalb läuft diese
        // Schleife höchstens drei Schritte zurück und niemals durch das
        // möglicherweise sehr große letzte Graphem.
        while end.samePosition(in: fullText.unicodeScalars) == nil {
            end = utf8.index(before: end)
        }
        return AnalysisSample(
            text: String(decoding: utf8[..<end], as: UTF8.self),
            isComplete: false
        )
    }

    /// Konservative Format-Erkennung über den Textanfang (max. 64 KiB).
    /// `nil` = keine Heuristik war sich sicher → Tab bleibt Plaintext.
    static func detect(in fullText: String) -> Format? {
        detect(in: analysisSample(from: fullText))
    }

    /// Fassung für den asynchronen Dokument-Detektor: Er erzeugt die Probe
    /// noch vor dem Scheduler, damit der Worker nie den Volltext festhält.
    static func detect(in sample: AnalysisSample) -> Format? {
        let trimmed = sample.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Sehr kurze Schnipsel liefern keine hohe Konfidenz.
        guard trimmed.count >= 8 else { return nil }

        if let structured = detectStructured(trimmed: trimmed,
                                             isComplete: sample.isComplete) {
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
