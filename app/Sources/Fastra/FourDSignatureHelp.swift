// FourDSignatureHelp.swift
//
// Parameterhilfe für 4D-Projektmethoden (Daniel-Wunsch 2026-07-24): Steht der
// Cursor innerhalb der runden Klammern eines Methodenaufrufes, zeigt Fastra
// die Parameter der Methode wie der 4D-Methodeneditor — dazu den
// Kommentarkopf der Methode. Die Informationen kommen NICHT aus tool4d
// (dessen LSP liefert nur Diagnosen), sondern direkt aus der `.4dm`-Datei
// der Methode im Projektbaum.
//
// Diese Datei enthält ausschließlich pure, unit-testbare Logik:
// - `FourDSignatureParser.parse` liest beide 4D-Deklarationsstile:
//   neu    `#DECLARE($name : Typ; …)->$rueckgabe : Typ`
//   klassisch `C_TEXT:C284($1;$2;…)` — nur `$N` sind Parameter, `$0` ist die
//   Rückgabe, benannte Variablen in derselben Deklaration sind Prozess-/
//   Interprozessvariablen und gehören nicht zur Signatur.
// - `FourDSignatureHelpLogic.callContext` bestimmt aus Text + Cursor den
//   umschließenden Aufruf: Eine offene linke Klammer genügt; gibt es die
//   rechte, gilt die Hilfe überall zwischen beiden.

import Foundation

/// Signatur einer 4D-Methode, wie sie aus ihrer Quelldatei hervorgeht.
struct FourDMethodSignature: Equatable {
    struct Parameter: Equatable {
        let name: String
        let type: String?
    }

    var parameters: [Parameter] = []
    var returnParameter: Parameter?
    /// Kommentarkopf: alle Zeilen ab Dateianfang bis zur ersten Zeile, die
    /// kein Kommentar ist. Die `//%attributes`-Metadatenzeile zählt nicht
    /// zum Kopf. Leer, wenn die Methode ohne Kommentar beginnt.
    var headerComment: String = ""

    var isEmpty: Bool {
        parameters.isEmpty && returnParameter == nil && headerComment.isEmpty
    }
}

enum FourDSignatureParser {

    /// Typnamen der klassischen Compiler-Deklarationen.
    private static let classicTypes: [String: String] = [
        "C_TEXT": "Text", "C_STRING": "Text", "C_LONGINT": "Longint",
        "C_INTEGER": "Integer", "C_REAL": "Real", "C_BOOLEAN": "Boolean",
        "C_DATE": "Date", "C_TIME": "Time", "C_POINTER": "Pointer",
        "C_PICTURE": "Picture", "C_BLOB": "Blob", "C_OBJECT": "Object",
        "C_COLLECTION": "Collection", "C_VARIANT": "Variant",
    ]

    /// `#DECLARE($a : Text; $b : Integer)->$r : Boolean` — Parameterliste
    /// und optionale Rückgabe. Typen dürfen Klassenpfade sein (`cs.Kunde`,
    /// `4D.File`).
    private static let declareRegex = try? NSRegularExpression(
        pattern: #"^\s*#DECLARE\s*\((.*)\)\s*(?:->\s*(\$[\p{L}\p{N}_]+)\s*:\s*([\p{L}\p{N}_.]+))?"#,
        options: [.caseInsensitive]
    )

    /// `C_TEXT:C284(…)` bzw. `C_TEXT(…)` — der `:Cnnn`-Suffix stammt aus dem
    /// tokenisierten 4D-Export.
    private static let classicRegex = try? NSRegularExpression(
        pattern: #"^\s*(C_[A-Z]+)(?::C\d+)?\s*\((.*?)\)"#,
        options: []
    )

    static func parse(methodSource: String) -> FourDMethodSignature {
        var signature = FourDMethodSignature()
        // Zeilenenden normalisieren: Quelldateien nutzen `\n`, die von 4D
        // exportierten Methodendoku-Dateien (Komponenten) dagegen `\r` und
        // ein UTF-8-BOM, das sonst die erste Kommentarzeile verdecken würde.
        var normalized = methodSource
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        let lines = normalized.components(separatedBy: "\n")
        signature.headerComment = headerComment(of: lines)

        // Neuer Stil gewinnt: Die erste #DECLARE-Zeile beschreibt die
        // Signatur vollständig.
        for line in lines {
            guard let declareRegex,
                  let match = declareRegex.firstMatch(
                    in: line, range: NSRange(line.startIndex..., in: line)
                  ) else { continue }
            let ns = line as NSString
            let inner = ns.substring(with: match.range(at: 1))
            signature.parameters = declareParameters(inner)
            if match.range(at: 2).location != NSNotFound {
                let name = ns.substring(with: match.range(at: 2))
                let type = match.range(at: 3).location != NSNotFound
                    ? ns.substring(with: match.range(at: 3)) : nil
                signature.returnParameter = .init(name: name, type: type)
            }
            return signature
        }

        // Klassischer Stil: Alle C_-Deklarationszeilen einsammeln; nur
        // nummerierte `$N` (und `${N}` für variable Parameter) zählen.
        var numbered: [Int: FourDMethodSignature.Parameter] = [:]
        var variadic: FourDMethodSignature.Parameter?
        for line in lines {
            guard let classicRegex,
                  let match = classicRegex.firstMatch(
                    in: line, range: NSRange(line.startIndex..., in: line)
                  ) else { continue }
            let ns = line as NSString
            let command = ns.substring(with: match.range(at: 1)).uppercased()
            guard let type = classicTypes[command] else { continue }
            let arguments = ns.substring(with: match.range(at: 2))
                .components(separatedBy: ";")
            for rawArgument in arguments {
                let argument = rawArgument.trimmingCharacters(in: .whitespaces)
                if let number = classicParameterNumber(argument) {
                    if number == 0 {
                        signature.returnParameter = .init(name: "$0", type: type)
                    } else {
                        numbered[number] = .init(name: "$\(number)", type: type)
                    }
                } else if let start = variadicStart(argument) {
                    variadic = .init(name: "${\(start)}…", type: type)
                }
            }
        }
        if let highest = numbered.keys.max() {
            signature.parameters = (1...highest).map { number in
                numbered[number] ?? .init(name: "$\(number)", type: nil)
            }
        }
        if let variadic { signature.parameters.append(variadic) }
        return signature
    }

    /// `$3` → 3, sonst nil.
    private static func classicParameterNumber(_ argument: String) -> Int? {
        guard argument.hasPrefix("$") else { return nil }
        return Int(argument.dropFirst())
    }

    /// `${4}` → 4 (Deklaration „ab Parameter N beliebig viele“).
    private static func variadicStart(_ argument: String) -> Int? {
        guard argument.hasPrefix("${"), argument.hasSuffix("}") else { return nil }
        return Int(argument.dropFirst(2).dropLast())
    }

    private static func declareParameters(
        _ list: String
    ) -> [FourDMethodSignature.Parameter] {
        guard !list.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return list.components(separatedBy: ";").compactMap { entry in
            let parts = entry.components(separatedBy: ":")
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard name.hasPrefix("$") else { return nil }
            let type = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespaces) : nil
            return .init(name: name, type: type?.isEmpty == true ? nil : type)
        }
    }

    /// Kommentarkopf bis zur ersten Nicht-Kommentar-Zeile. `/* … */`-Blöcke
    /// zählen vollständig zum Kopf, die `//%attributes`-Zeile nie.
    private static func headerComment(of lines: [String]) -> String {
        var collected: [String] = []
        var inBlock = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inBlock {
                collected.append(line)
                if trimmed.contains("*/") { inBlock = false }
                continue
            }
            if index == 0, trimmed.hasPrefix("//%attributes") { continue }
            if trimmed.hasPrefix("//") {
                collected.append(line)
                continue
            }
            if trimmed.hasPrefix("/*") {
                collected.append(line)
                if !trimmed.dropFirst(2).contains("*/") { inBlock = true }
                continue
            }
            break
        }
        // Führende/abschließende Leer-Kommentarzeilen bleiben erhalten —
        // nur umgebender Leerraum des Gesamtblocks fällt weg.
        return collected.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Kontext eines Methodenaufrufes unter dem Cursor.
struct FourDCallContext: Equatable {
    let methodName: String
    /// UTF-16-Position der öffnenden Klammer im Gesamttext.
    let openParenLocation: Int
    /// 0-basierter Index des Parameters, in dem der Cursor gerade steht
    /// (Anzahl der `;` auf Klammertiefe 1 vor dem Cursor).
    let activeParameterIndex: Int
}

enum FourDSignatureHelpLogic {

    /// Findet den innersten offenen Aufruf um den Cursor — innerhalb der
    /// logischen Zeile, denn 4D-Anweisungen sind zeilenbasiert. Eine offene
    /// linke Klammer genügt; steht der Cursor hinter der zugehörigen rechten
    /// Klammer, gibt es keinen Kontext. Strings und Kommentare der Zeile
    /// werden übersprungen.
    static func callContext(in text: String,
                            utf16CursorLocation cursor: Int) -> FourDCallContext? {
        let ns = text as NSString
        guard cursor >= 0, cursor <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: min(cursor, max(ns.length - 1, 0)),
                                                  length: 0))
        guard cursor >= lineRange.location else { return nil }

        struct OpenParen {
            let location: Int
            var semicolons: Int
        }
        var stack: [OpenParen] = []
        var index = lineRange.location
        var inString = false
        while index < cursor, index < ns.length {
            let unit = ns.character(at: index)
            guard let scalar = Unicode.Scalar(unit) else { index += 1; continue }
            let char = Character(scalar)
            if inString {
                if char == "\\" { index += 2; continue }
                if char == "\"" { inString = false }
                index += 1
                continue
            }
            switch char {
            case "\"":
                inString = true
            case "/":
                // Zeilenkommentar: Alles dahinter ist kein Code mehr. Steht
                // der Cursor im Kommentar, gibt es keine Hilfe.
                if index + 1 < ns.length,
                   let next = Unicode.Scalar(ns.character(at: index + 1)),
                   Character(next) == "/" {
                    return nil
                }
            case "(":
                stack.append(OpenParen(location: index, semicolons: 0))
            case ")":
                if !stack.isEmpty { stack.removeLast() }
            case ";":
                if !stack.isEmpty { stack[stack.count - 1].semicolons += 1 }
            default:
                break
            }
            index += 1
        }
        // `inString` maskiert nur Klammern und Semikolons WÄHREND des Scans.
        // Steht der Cursor selbst in einem String-Argument, bleibt die Hilfe
        // sichtbar — genau dann tippt man ja gerade einen Parameter.
        guard let innermost = stack.last else { return nil }
        guard let name = calleeName(in: ns, beforeParenAt: innermost.location,
                                    lineStart: lineRange.location) else {
            return nil
        }
        return FourDCallContext(
            methodName: name,
            openParenLocation: innermost.location,
            activeParameterIndex: innermost.semicolons
        )
    }

    /// Bezeichner unmittelbar vor der Klammer — wie in 4D dürfen Methoden-
    /// namen einzelne Leerzeichen enthalten („000 DBE SERVER“). Schlüssel-
    /// wörter (`If`, `While`, …) liefern bewusst keinen Kontext.
    private static func calleeName(in ns: NSString, beforeParenAt paren: Int,
                                   lineStart: Int) -> String? {
        func char(_ at: Int) -> Character? {
            guard at >= lineStart, at < ns.length,
                  let scalar = Unicode.Scalar(ns.character(at: at)) else {
                return nil
            }
            return Character(scalar)
        }
        func isWordChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_"
        }
        var end = paren
        // Leerraum zwischen Name und Klammer (`Methode (…)`).
        while let c = char(end - 1), c == " " { end -= 1 }
        var start = end
        var index = end - 1
        while let c = char(index) {
            if isWordChar(c) {
                start = index
                index -= 1
                continue
            }
            if c == " ", let before = char(index - 1), isWordChar(before) {
                start = index
                index -= 1
                continue
            }
            break
        }
        guard start < end else { return nil }
        let name = ns.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespaces)
        guard let first = name.first, first.isLetter || first == "_" else {
            return nil
        }
        // `$methode(...)`, `.member(...)` und `[Tabelle]feld(...)` sind keine
        // Projektmethodenaufrufe.
        if let boundary = char(start - 1),
           boundary == "$" || boundary == "." || boundary == "]" || boundary == ">" {
            return nil
        }
        if FourDTokenizer.keywords.contains(name.lowercased()) { return nil }
        return name
    }

    /// Sucht die Quelldatei einer Projektmethode in den bekannten
    /// Methodenordnern (wie „Gehe zum Ziel“).
    static func methodFileURL(named name: String,
                              projectURL: URL?,
                              documentURL: URL?,
                              fileManager: FileManager = .default) -> URL? {
        var roots: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            guard seen.insert(url.path).inserted else { return }
            roots.append(url)
        }
        if let document = documentURL {
            var current = document.deletingLastPathComponent()
            for _ in 0..<8 {
                if current.lastPathComponent == "Sources",
                   current.deletingLastPathComponent()
                       .lastPathComponent == "Project" {
                    add(current)
                }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
        }
        if let project = projectURL {
            add(project.appendingPathComponent("Project/Sources"))
            add(project.appendingPathComponent("Sources"))
        }
        for root in roots {
            let candidate = root.appendingPathComponent("Methods/\(name).4dm")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
