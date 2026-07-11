// RegexTokenizer.swift
//
// Parst einen RegEx-Suchausdruck mit tree-sitter-regex und liefert eine
// flache, sortierte, überlappungsfreie Token-Liste sowie Capture-Group-
// Informationen zurück (Typ `RegexTokenization`, definiert in RegexTokens.swift).
//
// Drei Verbraucher (alle lesen nur, schreiben nie):
//   1. Inline-Token-Highlighting im Find-Feld
//   2. Capture-Group-Pills in der Suchmaske
//   3. Token-Snap-Logik bei der geführten Gruppen-Definition
//
// Architektur-Überblick:
//   tokenize()
//     → Parser aufsetzen, Pattern parsen
//     → collectNodes() baut intern einen flachen Rohlisten
//       (rekursiver Descent durch den tree-sitter-Baum)
//     → aufeinanderfolgende pattern_character-Nodes zu einem
//       einzigen `.literal`-Token zusammenführen
//     → Capture-Group-Nummern in Klammer-Reihenfolge vergeben
//     → Ergebnis sortieren und zurückgeben
//
// Wichtige Eigenschaft der tree-sitter-regex-Grammatik:
//   • pattern/term/alternation sind reine Strukturknoten — sie erzeugen
//     keine eigenen Tokens, ihre Kinder schon.
//   • Quantifier-Knoten (one_or_more, zero_or_more, optional, count_quantifier)
//     enthalten ihr lazy-"?"-Kind SCHON in ihrer eigenen Range — deshalb
//     wird der GESAMTE Knoten als EIN Token ausgegeben (kein Descent).
//   • character_class (`[...]`) ist ein GANZER Knoten — ebenfalls KEIN Descent.
//   • Gruppen-Klammern sind anonyme Kinder (nodeType == "(" / ")" usw.),
//     wir lesen ihre Range direkt aus dem Baum.

import Foundation
import SwiftTreeSitter
import TreeSitterRegex

// MARK: - Thread-Safety

/// Globale Sperre für alle tree-sitter-Parser-Aufrufe.
///
/// tree-sitter ist grundsätzlich NICHT thread-safe — auch wenn jeder Aufruf
/// einen eigenen Parser erzeugt, teilen sich verschiedene Instanzen globalen
/// C-seitigen Zustand (Language-Initialisierung, Memory-Pools). Diese Sperre
/// serialisiert alle tokenize()-Aufrufe und verhindert „Fatal access conflict"-
/// Abstürze bei paralleler Nutzung (z.B. Swift-Testing-Parallelisierung).
/// Performance ist kein Problem: Patterns sind kurz, die kritische Sektion
/// endet sobald der Baum gebaut ist.
private let tokenizerLock = NSLock()

// MARK: - Öffentliche API

/// Parst einen RegEx-Pattern-String und liefert strukturierte Token- und
/// Capture-Group-Informationen zurück.
///
/// Beispiel:
/// ```swift
/// let result = RegexTokenizer.tokenize(#"(\w+)@(\w+)"#)
/// // result.tokens enthält Delimiter "(", escape "\w", quantifier "+", ...
/// // result.groups enthält zwei CaptureGroupInfo mit number 1 und 2
/// ```
enum RegexTokenizer {

    /// Parst den Suchausdruck mit tree-sitter-regex und liefert flache,
    /// sortierte, überlappungsfreie Tokens + Capture-Group-Struktur.
    ///
    /// - Parameter pattern: Der RegEx-Suchausdruck (UTF-16-String).
    /// - Returns: `RegexTokenization.empty` bei leerem Pattern.
    ///   Bei ungültigem Pattern: `hasErrors = true`, Tokens best-effort.
    static func tokenize(_ pattern: String) -> RegexTokenization {
        // Leeres Pattern → frühzeitig zurückkehren (vor der Sperre, kein C-Aufruf nötig)
        guard !pattern.isEmpty else {
            return .empty
        }

        // Globale Sperre — tree-sitter ist nicht thread-safe; alle Parser-Aufrufe
        // müssen serialisiert werden (Details: tokenizerLock-Kommentar oben).
        tokenizerLock.lock()
        defer { tokenizerLock.unlock() }

        // Jeden Aufruf einen frischen Parser erzeugen — Parser ist NICHT
        // thread-safe und Pattern sind kurz, daher kein Recycling.
        let language = Language(language: tree_sitter_regex())
        let parser = Parser()
        // setLanguage kann theoretisch werfen (Versions-Inkompatibilität),
        // in der Praxis aber nie bei tree-sitter-regex 0.25 vs TreeSitter 0.23.
        guard (try? parser.setLanguage(language)) != nil else {
            // Sprache konnte nicht gesetzt werden → leeres Ergebnis mit Fehler
            return RegexTokenization(tokens: [], groups: [], hasErrors: true)
        }

        // Pattern parsen — Parser.parse(_:) liefert nil nur bei OOM
        guard let tree = parser.parse(pattern) else {
            return RegexTokenization(tokens: [], groups: [], hasErrors: true)
        }

        // Wurzel-Knoten holen — nil bei leerem Baum (sollte nie vorkommen)
        guard let root = tree.rootNode else {
            return .empty
        }

        // Fehler-Flag vom Baum übernehmen (tree-sitter setzt hasError rekursiv
        // an allen Vorfahren, wenn irgendwo ein ERROR-Knoten existiert)
        let hasErrors = root.hasError

        // --- Schritt 1: Rohe Knoten-Liste per rekursivem Descent sammeln ---
        // pendingLiterals puffert aufeinanderfolgende pattern_character-Nodes,
        // damit sie am Ende als EIN Token zusammengeführt werden können.
        var rawTokens: [RegexToken] = []
        var pendingLiteralNodes: [NodeInfo] = []  // gepufferte Literale
        var captureGroupInfos: [CaptureGroupInfo] = []
        var captureCounter = 0  // 1-basierter Zähler, NSRegularExpression-Stil

        // Hilfsfunktion: gepufferte Literale zu einem Token zusammenführen
        // und in rawTokens einfügen.
        func flushLiterals() {
            guard !pendingLiteralNodes.isEmpty else { return }
            let first = pendingLiteralNodes.first!
            let last = pendingLiteralNodes.last!
            // Range überspannt alle gepufferten Knoten
            let merged = NSRange(
                location: first.range.location,
                length: last.range.location + last.range.length - first.range.location
            )
            let text = substring(of: pattern, range: merged)
            rawTokens.append(RegexToken(kind: .literal, range: merged, text: text))
            pendingLiteralNodes.removeAll()
        }

        // Hilfsfunktion: aus dem UTF-16-NSRange des Patterns den Substring holen
        // (inline weiter unten als closure definiert)

        // Rekursiver Descent durch den tree-sitter-Baum
        func collectNodes(node: Node) {
            let type = node.nodeType ?? ""

            // ERROR-Knoten → als Fehler-Token ausgeben, kein Descent
            if type == "ERROR" || node.isMissing {
                flushLiterals()
                let range = node.range
                let text = substring(of: pattern, range: range)
                rawTokens.append(RegexToken(kind: .error, range: range, text: text))
                return
            }

            switch type {

            // --- Strukturknoten: nur Kinder verarbeiten ---
            // Diese Knoten selbst erzeugen keine Tokens; alle semantischen
            // Inhalte kommen aus ihren Kindern.
            case "pattern", "term":
                flushLiterals()  // vor Abstieg aufräumen (Reihenfolge)
                for i in 0 ..< node.childCount {
                    if let child = node.child(at: i) {
                        collectNodes(node: child)
                    }
                }

            // alternation: das "|"-Zeichen selbst als Token, in die Terme descenden
            case "alternation":
                flushLiterals()
                for i in 0 ..< node.childCount {
                    guard let child = node.child(at: i) else { continue }
                    let childType = child.nodeType ?? ""
                    if childType == "|" {
                        // Das Pipe-Zeichen ist das Alternation-Token
                        let range = child.range
                        let text = substring(of: pattern, range: range)
                        rawTokens.append(RegexToken(kind: .alternation, range: range, text: text))
                    } else {
                        // term oder nil-term (leere Alternative): descenden
                        collectNodes(node: child)
                    }
                }

            // --- Anker: einzelner Token für den gesamten Knoten ---
            case "start_assertion",
                 "end_assertion",
                 "boundary_assertion",
                 "non_boundary_assertion":
                flushLiterals()
                let range = node.range
                let text = substring(of: pattern, range: range)
                rawTokens.append(RegexToken(kind: .anchor, range: range, text: text))

            // --- Zeichenklassen: gesamter Knoten als EIN Token (kein Descent) ---
            // character_class = das gesamte [...]-Konstrukt
            case "character_class",
                 "character_class_escape",
                 "any_character",
                 "posix_character_class":
                flushLiterals()
                let range = node.range
                let text = substring(of: pattern, range: range)
                rawTokens.append(RegexToken(kind: .characterClass, range: range, text: text))

            // --- Quantifier: gesamter Knoten (inkl. lazy-Kind) als EIN Token ---
            // Die Range des Quantifier-Knotens schließt das lazy-"?" bereits ein.
            case "one_or_more",
                 "zero_or_more",
                 "optional",
                 "count_quantifier":
                flushLiterals()
                let range = node.range
                let text = substring(of: pattern, range: range)
                rawTokens.append(RegexToken(kind: .quantifier, range: range, text: text))

            // --- Gruppen: Klammern als Delimiter, Inhalt rekursiv ---
            //
            // Muster bei allen fünf Gruppen-Typen: Die Nummer wird VOR dem
            // Handler-Aufruf vergeben (Klammer-Reihenfolge bleibt korrekt,
            // verschachtelte Gruppen nummerieren sich in der Rekursion
            // danach). Der Handler sammelt seine Delimiter-Tokens LOKAL und
            // gibt sie zurück; erst NACH der Rückkehr hängen wir sie an
            // rawTokens an. So hält niemand exklusiven Zugriff auf die
            // Sammlungen, während collectNodes hineinschreibt (Exclusivity-
            // Crash der ersten Fassung — siehe Kommentar bei den Handlern).
            case "anonymous_capturing_group":
                flushLiterals()
                captureCounter += 1
                let result = handleCapturingGroup(node: node,
                                                  name: nil,
                                                  number: captureCounter,
                                                  pattern: pattern,
                                                  collectNodes: collectNodes)
                rawTokens.append(contentsOf: result.tokens)
                captureGroupInfos.append(result.group)

            case "named_capturing_group":
                flushLiterals()
                captureCounter += 1
                let result = handleNamedCapturingGroup(node: node,
                                                       number: captureCounter,
                                                       pattern: pattern,
                                                       collectNodes: collectNodes)
                rawTokens.append(contentsOf: result.tokens)
                captureGroupInfos.append(result.group)

            case "non_capturing_group":
                flushLiterals()
                rawTokens.append(contentsOf:
                    handleNonCapturingGroup(node: node,
                                            pattern: pattern,
                                            collectNodes: collectNodes))

            case "lookaround_assertion":
                flushLiterals()
                rawTokens.append(contentsOf:
                    handleLookaroundGroup(node: node,
                                          pattern: pattern,
                                          collectNodes: collectNodes))

            case "inline_flags_group":
                flushLiterals()
                rawTokens.append(contentsOf:
                    handleInlineFlagsGroup(node: node,
                                           pattern: pattern,
                                           collectNodes: collectNodes))

            // --- Escapes ---
            case "identity_escape",
                 "control_escape",
                 "control_letter_escape",
                 "unicode_character_escape",
                 "unicode_property_value_expression":
                flushLiterals()
                let range = node.range
                let text = substring(of: pattern, range: range)
                rawTokens.append(RegexToken(kind: .escape, range: range, text: text))

            // --- Rückverweise ---
            // decimal_escape = \1 .. \9
            case "decimal_escape":
                flushLiterals()
                let range = node.range
                let text = substring(of: pattern, range: range)
                rawTokens.append(RegexToken(kind: .backreference, range: range, text: text))

            // backreference_escape = \k<name>  /  named_group_backreference = (?P=name)
            case "backreference_escape",
                 "named_group_backreference":
                flushLiterals()
                // Gesamten Knoten als EIN Token (inkl. <name>-Kind)
                let range = node.range
                let text = substring(of: pattern, range: range)
                rawTokens.append(RegexToken(kind: .backreference, range: range, text: text))

            // --- Literale: puffern, nicht sofort ausgeben ---
            case "pattern_character":
                let info = NodeInfo(range: node.range)
                // Prüfen ob direkt anschließend ans letzte gepufferte Literal
                if let last = pendingLiteralNodes.last,
                   last.range.location + last.range.length == info.range.location {
                    pendingLiteralNodes.append(info)
                } else {
                    // Lücke → vorherige Literale ausgeben, neues beginnen
                    flushLiterals()
                    pendingLiteralNodes.append(info)
                }

            default:
                // Unbekannte benannte Knoten: descenden (defensive Vorwärtskompatibilität)
                // Unbenannte Knoten (Satzzeichen wie "(" etc.) ignorieren, sie werden
                // in den Gruppen-Handlern explizit behandelt.
                if node.isNamed {
                    for i in 0 ..< node.childCount {
                        if let child = node.child(at: i) {
                            collectNodes(node: child)
                        }
                    }
                }
                // ansonsten: anonymes Satzzeichen ohne eigenen Semantic-Token — überspringen
            }
        }

        // Verarbeitung starten
        collectNodes(node: root)
        flushLiterals()  // letzte Literale ausgeben

        // --- Schritt 2: Tokens nach Position sortieren ---
        let sortedTokens = rawTokens.sorted { $0.range.location < $1.range.location }

        // --- Schritt 3: Capture Groups nach öffnender Klammer sortieren ---
        let sortedGroups = captureGroupInfos.sorted { $0.range.location < $1.range.location }

        return RegexTokenization(tokens: sortedTokens,
                                 groups: sortedGroups,
                                 hasErrors: hasErrors)
    }
}

// MARK: - Hilfs-Datenstruktur

/// Minimal-Info für gepufferte pattern_character-Nodes
private struct NodeInfo {
    let range: NSRange
}

// MARK: - Gruppen-Handler (ausgelagert für Lesbarkeit)
//
// WICHTIG (Exclusivity-Lehre, 2026-06-11): Die Handler nehmen die Token-/
// Gruppen-Sammlungen NICHT als `inout` entgegen. Frühere Fassung tat das —
// und hielt damit für die gesamte Handler-Laufzeit EXKLUSIVEN Zugriff auf
// `rawTokens`, während der `collectNodes`-Callback im Gruppeninhalt
// DIESELBE Variable mutierte → „Fatal access conflict" (Swift-Exclusivity-
// Verletzung, crasht zur Laufzeit). Stattdessen sammeln die Handler ihre
// Delimiter-Tokens LOKAL und geben sie zurück; der Aufrufer hängt sie nach
// der Rückkehr an. Die Reihenfolge ist egal — tokenize() sortiert am Ende
// alle Tokens nach Position.

/// Verarbeitet eine anonymous_capturing_group: öffnende "(" + Inhalt + schließende ")".
/// `number` wird vom Aufrufer VOR dem Aufruf vergeben (Klammer-Reihenfolge).
/// Rückgabe: Delimiter-Tokens der Klammern + die fertige Gruppen-Info.
private func handleCapturingGroup(
    node: Node,
    name: String?,
    number: Int,
    pattern: String,
    collectNodes: (Node) -> Void
) -> (tokens: [RegexToken], group: CaptureGroupInfo) {
    let groupRange = node.range  // gesamte Gruppe inkl. Klammern
    var ownTokens: [RegexToken] = []

    // Kinder-Iteration: "(" und ")" als Delimiter, pattern als Inhalt
    var openPrefixRange: NSRange? = nil
    var closingRange: NSRange? = nil
    var innerRange: NSRange = NSRange(location: groupRange.location + 1, length: 0)

    for i in 0 ..< node.childCount {
        guard let child = node.child(at: i) else { continue }
        let childType = child.nodeType ?? ""

        switch childType {
        case "(":
            // Öffnende Klammer
            openPrefixRange = child.range
            ownTokens.append(RegexToken(kind: .groupDelimiter,
                                        range: child.range,
                                        text: substring(of: pattern, range: child.range)))
        case ")":
            // Schließende Klammer
            closingRange = child.range
            ownTokens.append(RegexToken(kind: .groupDelimiter,
                                        range: child.range,
                                        text: substring(of: pattern, range: child.range)))
        default:
            // Gruppeninhalt: rekursiv verarbeiten (schreibt direkt in die
            // Sammlungen von tokenize — wir halten hier bewusst keinen
            // exklusiven Zugriff darauf).
            collectNodes(child)
        }
    }

    // innerRange = alles zwischen öffnendem Präfix und schließender Klammer
    if let open = openPrefixRange, let close = closingRange {
        let innerLoc = open.location + open.length
        let innerLen = close.location - innerLoc
        innerRange = NSRange(location: innerLoc, length: max(0, innerLen))
    }

    let group = CaptureGroupInfo(
        number: number,
        name: name,
        range: groupRange,
        innerRange: innerRange
    )
    return (ownTokens, group)
}

/// Verarbeitet eine named_capturing_group: `(?<name>` + Inhalt + `)`.
/// Das öffnende Präfix inkl. Name und `>` ist EIN groupDelimiter-Token.
private func handleNamedCapturingGroup(
    node: Node,
    number: Int,
    pattern: String,
    collectNodes: (Node) -> Void
) -> (tokens: [RegexToken], group: CaptureGroupInfo) {
    let groupRange = node.range
    var ownTokens: [RegexToken] = []

    // Kinder-Layout bei named_capturing_group (laut grammar.js):
    //   "(?<"  |  "(?P<"       → anonymes Kind, Teil des Präfixes
    //   group_name              → benanntes Kind mit dem Namen
    //   ">"                     → anonymes Kind, schließt Präfix ab
    //   pattern                 → Gruppeninhalt
    //   ")"                     → schließende Klammer
    //
    // Strategie: alle Kind-Ranges bis incl. ">" akkumulieren → Präfix-Range.
    // Danach den Inhalt rekursiv sammeln, dann ")".

    var prefixEndLoc: Int = groupRange.location  // wird hochgezählt
    var groupName: String? = nil
    var closingRange: NSRange? = nil
    var innerRange: NSRange = NSRange(location: groupRange.location, length: 0)
    var prefixEndReached = false   // nach ">" ist Präfix zu Ende

    for i in 0 ..< node.childCount {
        guard let child = node.child(at: i) else { continue }
        let childType = child.nodeType ?? ""

        if !prefixEndReached {
            // Noch im Präfix-Bereich
            if childType == "group_name" {
                groupName = substring(of: pattern, range: child.range)
                prefixEndLoc = child.range.location + child.range.length
            } else if childType == ">" {
                // ">" schließt das Präfix
                prefixEndLoc = child.range.location + child.range.length
                prefixEndReached = true
                // Präfix als EIN groupDelimiter-Token ausgeben
                let prefixRange = NSRange(location: groupRange.location,
                                          length: prefixEndLoc - groupRange.location)
                ownTokens.append(RegexToken(kind: .groupDelimiter,
                                         range: prefixRange,
                                         text: substring(of: pattern, range: prefixRange)))
                // innerRange beginnt nach dem Präfix
                innerRange = NSRange(location: prefixEndLoc, length: 0)
            }
        } else {
            // Nach dem Präfix
            if childType == ")" {
                closingRange = child.range
                ownTokens.append(RegexToken(kind: .groupDelimiter,
                                         range: child.range,
                                         text: substring(of: pattern, range: child.range)))
            } else {
                // Gruppeninhalt rekursiv
                collectNodes(child)
            }
        }
    }

    if let close = closingRange {
        innerRange = NSRange(location: innerRange.location,
                             length: close.location - innerRange.location)
    }

    let group = CaptureGroupInfo(
        number: number,
        name: groupName,
        range: groupRange,
        innerRange: innerRange
    )
    return (ownTokens, group)
}

/// Verarbeitet eine non_capturing_group: `(?:` + Inhalt + `)`.
/// Zählt NICHT als Capture Group. Rückgabe: die Delimiter-Tokens.
private func handleNonCapturingGroup(
    node: Node,
    pattern: String,
    collectNodes: (Node) -> Void
) -> [RegexToken] {
    var ownTokens: [RegexToken] = []
    // Kinder: "(?:" (anonym), pattern, ")"
    // Strategie: erstes anonymes Kind = Öffner-Token, letztes ")" = Schließer
    var openingEmitted = false

    for i in 0 ..< node.childCount {
        guard let child = node.child(at: i) else { continue }
        let childType = child.nodeType ?? ""

        if !openingEmitted {
            // Erstes Kind = das "(?:"-Token (anonym, nicht benannt)
            ownTokens.append(RegexToken(kind: .groupDelimiter,
                                     range: child.range,
                                     text: substring(of: pattern, range: child.range)))
            openingEmitted = true
        } else if childType == ")" {
            ownTokens.append(RegexToken(kind: .groupDelimiter,
                                     range: child.range,
                                     text: substring(of: pattern, range: child.range)))
        } else {
            collectNodes(child)
        }
    }
    return ownTokens
}

/// Verarbeitet eine lookaround_assertion: `(?=…)`, `(?!…)`, `(?<=…)`, `(?<!…)`.
/// Kein Capture. Öffnendes Präfix (alles bis und inkl. "=" oder "!") als EIN Token.
/// Rückgabe: die Delimiter-Tokens.
private func handleLookaroundGroup(
    node: Node,
    pattern: String,
    collectNodes: (Node) -> Void
) -> [RegexToken] {
    var ownTokens: [RegexToken] = []
    // Kinder-Layout (aus grammar.js _lookahead_assertion/_lookbehind_assertion):
    //   "(?", "=" oder "!" → Präfix (anonym)
    //   pattern             → Inhalt
    //   ")"                 → Schließer
    // Für Lookbehind: "(?<", "=" oder "!" → Präfix
    //
    // Strategie: Kinder sammeln bis pattern/")"-Kind erreicht ist;
    // alle vorherigen anonymen Kinder bilden zusammen das Präfix.

    let nodeRange = node.range
    var prefixLength = 0
    var prefixEmitted = false

    for i in 0 ..< node.childCount {
        guard let child = node.child(at: i) else { continue }
        let childType = child.nodeType ?? ""

        if !prefixEmitted {
            // Anonyme Kinder akkumulieren bis das erste benannte Kind kommt
            if !child.isNamed {
                prefixLength = (child.range.location + child.range.length) - nodeRange.location
                // Prüfen ob dieses Kind "=" oder "!" ist → Präfix abgeschlossen
                if childType == "=" || childType == "!" {
                    let prefixRange = NSRange(location: nodeRange.location,
                                              length: prefixLength)
                    ownTokens.append(RegexToken(kind: .groupDelimiter,
                                             range: prefixRange,
                                             text: substring(of: pattern, range: prefixRange)))
                    prefixEmitted = true
                }
            } else {
                // Benanntes Kind (pattern) → Präfix war alles davor
                if !prefixEmitted && prefixLength > 0 {
                    let prefixRange = NSRange(location: nodeRange.location,
                                              length: prefixLength)
                    ownTokens.append(RegexToken(kind: .groupDelimiter,
                                             range: prefixRange,
                                             text: substring(of: pattern, range: prefixRange)))
                    prefixEmitted = true
                }
                collectNodes(child)
            }
        } else {
            if childType == ")" {
                ownTokens.append(RegexToken(kind: .groupDelimiter,
                                         range: child.range,
                                         text: substring(of: pattern, range: child.range)))
            } else {
                collectNodes(child)
            }
        }
    }
    return ownTokens
}

/// Verarbeitet eine inline_flags_group: `(?flags:…)` oder `(?flags)`.
/// Kein Capture. Kinder werden zu Delimiter/Inhalt aufgeteilt.
/// Rückgabe: die Delimiter-Tokens.
private func handleInlineFlagsGroup(
    node: Node,
    pattern: String,
    collectNodes: (Node) -> Void
) -> [RegexToken] {
    var ownTokens: [RegexToken] = []
    // Erstes Kind = "(?"-Token (Öffner), letztes = ")" (Schließer),
    // Kinder dazwischen: flags, optional ":", optional pattern
    var openingEmitted = false

    for i in 0 ..< node.childCount {
        guard let child = node.child(at: i) else { continue }
        let childType = child.nodeType ?? ""

        if !openingEmitted {
            // "(?"-Token
            ownTokens.append(RegexToken(kind: .groupDelimiter,
                                     range: child.range,
                                     text: substring(of: pattern, range: child.range)))
            openingEmitted = true
        } else if childType == ")" {
            ownTokens.append(RegexToken(kind: .groupDelimiter,
                                     range: child.range,
                                     text: substring(of: pattern, range: child.range)))
        } else if childType == "flags" || childType == ":" || childType == "-" {
            // Flags-Teil als groupDelimiter (kein eigener Token-Typ)
            ownTokens.append(RegexToken(kind: .groupDelimiter,
                                     range: child.range,
                                     text: substring(of: pattern, range: child.range)))
        } else {
            // pattern-Inhalt: descenden
            collectNodes(child)
        }
    }
    return ownTokens
}

// MARK: - Hilfsfunktion: UTF-16-Substring

/// Extrahiert den Substring des Pattern-Strings an einer UTF-16-NSRange.
///
/// tree-sitter rechnet intern in UTF-16-Bytes (je 2 Bytes pro Code Unit) und
/// liefert die Ranges in Code Units via `Node.range`. Diese Funktion wandelt
/// die NSRange in String-Indices um, was für korrekte Emoji-Unterstützung
/// (Surrogatpaare, 2 UTF-16-Einheiten) notwendig ist.
private func substring(of string: String, range: NSRange) -> String {
    let utf16 = string.utf16
    let count = utf16.count

    // Grenzen auf valide Bereiche klemmen
    let startOffset = max(0, min(range.location, count))
    let endOffset = max(startOffset, min(range.location + range.length, count))

    guard let startIndex = string.utf16.index(
        string.utf16.startIndex,
        offsetBy: startOffset,
        limitedBy: string.utf16.endIndex
    ),
    let endIndex = string.utf16.index(
        string.utf16.startIndex,
        offsetBy: endOffset,
        limitedBy: string.utf16.endIndex
    ) else {
        return ""
    }

    return String(string.utf16[startIndex ..< endIndex]) ?? ""
}
