// FourDTokenizerTests.swift
//
// Tests für den leichten 4D-Tokenizer (Etappe 4 Wunschpaket 2026-07).
// Alle .4dm-Fixtures sind SELBST GESCHRIEBEN (repräsentative Sprachmuster,
// nichts aus der 4D-Doku übernommen).

import AppKit
import CodeEditSourceEditor
import Foundation
import Testing
@testable import Fastra

/// Kurzform: tokenisiert und liefert (Text, Kind)-Paare für Vergleiche.
private func kinds(_ source: String) -> [(String, FourDTokenizer.Kind)] {
    FourDTokenizer.tokenize(source).map { token in
        let range = Range(token.range, in: source)!
        return (String(source[range]), token.kind)
    }
}

@Test("Zeilen- und Blockkommentare (auch mehrzeilig)")
func fourD_comments() {
    let source = """
    // Kundenliste neu aufbauen
    $a:=1  // Zähler
    /* mehr-
    zeiliger Block */
    """
    let result = kinds(source)
    #expect(result.contains { $0.1 == .comment && $0.0.hasPrefix("// Kundenliste") })
    #expect(result.contains { $0.1 == .comment && $0.0 == "// Zähler" })
    #expect(result.contains { $0.1 == .comment && $0.0.contains("zeiliger Block") })
}

@Test("Strings mit Escapes; Umlaute verschieben Offsets nicht")
func fourD_strings() {
    let source = "$grüße:=\"Schöne \\\"Grüße\\\" aus Köln\"\n$b:=\"zwei\""
    let result = kinds(source)
    let strings = result.filter { $0.1 == .string }
    #expect(strings.count == 2)
    #expect(strings[0].0.contains("Grüße"))
    #expect(strings[1].0 == "\"zwei\"")
}

@Test("Schlüsselwörter case-tolerant, auch mehrwortig")
func fourD_keywords() {
    let source = """
    If (True)
    Else
    End if
    For each ($e; $c)
    End for each
    """
    let result = kinds(source)
    #expect(result.contains { $0.1 == .keyword && $0.0 == "If" })
    #expect(result.contains { $0.1 == .keyword && $0.0 == "Else" })
    #expect(result.contains { $0.1 == .keyword && $0.0 == "End if" })
    #expect(result.contains { $0.1 == .keyword && $0.0 == "For each" })
    #expect(result.contains { $0.1 == .keyword && $0.0 == "End for each" })
    // True ist als Wert-Keyword klassifiziert (nicht Prozessvariable).
    #expect(result.contains { $0.1 == .keyword && $0.0 == "True" })
}

@Test("Mehrwortige Befehle per Longest-Prefix, case-tolerant")
func fourD_multiWordCommands() throws {
    // Fixe Erwartung an die generierte Liste — schlägt an, falls der
    // Generator diese Kernbefehle je verlieren sollte.
    #expect(FourDSymbols.commands.contains("ALERT"))
    #expect(FourDSymbols.commands.contains("ABORT PROCESS BY ID"))

    let source = """
    ALERT("Hallo")
    ABORT PROCESS BY ID($pid)
    alert("kleingeschrieben")
    """
    let result = kinds(source)
    #expect(result.contains { $0.1 == .command && $0.0 == "ALERT" })
    #expect(result.contains { $0.1 == .command && $0.0 == "ABORT PROCESS BY ID" })
    #expect(result.contains { $0.1 == .command && $0.0 == "alert" })
}

@Test("Konstanten aus der generierten Liste, auch mehrwortig")
func fourD_constants() throws {
    // Einen stabilen mehrwortigen Eintrag direkt aus der Liste nehmen, der
    // NICHT zugleich Befehl ist — so bleibt der Test namensunabhängig.
    let commandSet = Set(FourDSymbols.commands.map { $0.lowercased() })
    let sample = try #require(FourDSymbols.constants.first {
        $0.contains(" ") && !commandSet.contains($0.lowercased())
    })
    let source = "$x:=\(sample)+1"
    let result = kinds(source)
    #expect(result.contains { $0.1 == .constant && $0.0 == sample },
            "\(sample) muss als Konstante erkannt werden")
}

@Test("Variablenarten: $lokal, $1-Parameter, <>interprozess, prozessVar")
func fourD_variableKinds() {
    let source = """
    $name:="a"
    $1:=42
    <>gesamt:=<>gesamt+1
    zaehler:=zaehler+1
    """
    let result = kinds(source)
    #expect(result.contains { $0.1 == .localVariable && $0.0 == "$name" })
    #expect(result.contains { $0.1 == .localVariable && $0.0 == "$1" })
    #expect(result.filter { $0.1 == .interprocessVariable && $0.0 == "<>gesamt" }.count == 2)
    #expect(result.filter { $0.1 == .processVariable && $0.0 == "zaehler" }.count == 2)
}

@Test("Tabellen und Felder: [Tabelle]Feld")
func fourD_tablesAndFields() {
    let source = "QUERY([Kunden]; [Kunden]Name=\"Muster\")"
    let result = kinds(source)
    #expect(result.contains { $0.1 == .command && $0.0 == "QUERY" })
    #expect(result.filter { $0.1 == .table && $0.0 == "[Kunden]" }.count == 2)
    #expect(result.contains { $0.1 == .field && $0.0 == "Name" })
}

@Test("Klassische Tabelle mit ID bleibt eine Tabelle")
func fourD_tableWithClassicID() {
    let source = "QUERY([Auftraege:1]; [Auftraege:1]Nummer=42)"
    let result = kinds(source)
    #expect(result.filter { $0.1 == .table && $0.0 == "[Auftraege:1]" }.count == 2)
    #expect(result.contains { $0.1 == .field && $0.0 == "Nummer" })
}

@Test("Unindizierte Aufrufe und Member bleiben im bisherigen Befehls-Slot")
func fourD_methodsAndMembers() {
    let source = """
    MeineMethode($a)
    $o.gesamtBetrag:=$o.rechne()
    """
    let result = kinds(source)
    #expect(result.contains { $0.1 == .methodCall && $0.0 == "MeineMethode" })
    // `.gesamtBetrag` bleibt bewusst OHNE Token (plain).
    #expect(!result.contains { $0.0 == "gesamtBetrag" })
    #expect(result.contains { $0.1 == .methodCall && $0.0 == "rechne" })
}

@Test("Indizierte Projektmethoden mit und ohne Klammern gewinnen den eigenen Slot")
func fourD_indexedProjectMethods() {
    let source = "Abr_init\nABR_SUCHEN\nABR_LISTE_LB_AB\nAbr_Suchen()"
    let methods: Set<String> = ["abr_init", "abr_suchen"]
    let result = FourDTokenizer.tokenize(source, projectMethodNames: methods).map { token in
        let range = Range(token.range, in: source)!
        return (String(source[range]), token.kind)
    }
    #expect(result.contains { $0.0 == "Abr_init" && $0.1 == .projectMethod })
    #expect(result.contains { $0.0 == "ABR_SUCHEN" && $0.1 == .projectMethod })
    #expect(result.contains { $0.0 == "Abr_Suchen" && $0.1 == .projectMethod })
    #expect(result.contains { $0.0 == "ABR_LISTE_LB_AB" && $0.1 == .processVariable })
}

@Test("Zahlen inkl. Dezimalteil; Zahlen in Namen bleiben Namensteil")
func fourD_numbers() {
    let source = "$pi:=3.14159\n$x2:=7"
    let result = kinds(source)
    #expect(result.contains { $0.1 == .number && $0.0 == "3.14159" })
    #expect(result.contains { $0.1 == .number && $0.0 == "7" })
    #expect(result.contains { $0.1 == .localVariable && $0.0 == "$x2" })
}

@Test("Tokenisierte Suffixe: name:C123 → Befehl, name:K…: → Konstante")
func fourD_canonicalSuffixes() {
    let source = "ALERT:C41(\"x\")\n$y:=Into currency:K903:9"
    let result = kinds(source)
    #expect(result.contains { $0.1 == .command && $0.0 == "ALERT:C41" })
    #expect(result.contains { $0.1 == .constant && $0.0.hasSuffix(":K903:9") })
}

@Test("Klassensyntax: Function/Class constructor als Keywords")
func fourD_classSyntax() {
    let source = """
    Class constructor($name : Text)
    Function gesamtwert() : Real
    return This.wert
    """
    let result = kinds(source)
    #expect(result.contains { $0.1 == .keyword && $0.0 == "Class constructor" })
    #expect(result.contains { $0.1 == .keyword && $0.0 == "Function" })
    #expect(result.contains { $0.1 == .keyword && $0.0 == "return" })
    // `This` ist in der 4D-Doku zugleich als Befehl gelistet — Befehle
    // gewinnen vor Keywords; beides ergibt eine sichtbare Hervorhebung.
    #expect(result.contains {
        ($0.1 == .keyword || $0.1 == .command) && $0.0 == "This"
    })
}

@Test("UTF-16-Offsets stimmen auch nach Emoji/Umlauten (Capture-Ranges)")
func fourD_utf16Offsets() throws {
    let source = "// 🙂 Grüße\nALERT(\"ok\")"
    let tokens = FourDTokenizer.tokenize(source)
    let ns = source as NSString
    let alert = try #require(tokens.first { $0.kind == .command })
    #expect(ns.substring(with: alert.range) == "ALERT")
}

// MARK: - Capture-Zuordnung + Themes

@Test("Capture-Mapping deckt alle Token-Klassen ab (Mapping-Tabelle)")
func fourD_captureMapping() {
    #expect(FourDHighlightProvider.capture(for: .comment) == .comment)
    #expect(FourDHighlightProvider.capture(for: .string) == .string)
    #expect(FourDHighlightProvider.capture(for: .command) == .function)
    #expect(FourDHighlightProvider.capture(for: .constant) == .variableBuiltin)
    #expect(FourDHighlightProvider.capture(for: .localVariable) == .variable)
    #expect(FourDHighlightProvider.capture(for: .processVariable) == .property)
    #expect(FourDHighlightProvider.capture(for: .interprocessVariable) == .property)
    #expect(FourDHighlightProvider.capture(for: .table) == .type)
    #expect(FourDHighlightProvider.capture(for: .field) == .typeAlternate)
    #expect(FourDHighlightProvider.capture(for: .methodCall) == .function)
    #expect(FourDHighlightProvider.capture(for: .projectMethod) == .method)
    #expect(FourDHighlightProvider.capture(for: .keyword) == .keyword)
}

/// Liest eine Farbkategorie aus den eingecheckten 4D-Theme-Fixtures.
/// Die Themes müssen exakt daraus abgeleitet sein (nur Vordergrundfarben
/// und Bold/Italic).
private func themeJSON(_ name: String) throws -> [String: Any] {
    let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
    let url = try #require(Bundle.module.url(
        forResource: parts[0],
        withExtension: parts.count == 2 ? parts[1] : nil,
        subdirectory: "FourDTheme"
    ))
    let data = try Data(contentsOf: url)
    let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    return root["4D"] as! [String: Any]
}

private func expectColor(_ attribute: EditorTheme.Attribute,
                         matches category: [String: Any],
                         _ label: String) {
    let hex = (category["color"] as! String).dropFirst()
    let r = CGFloat(Int(hex.prefix(2), radix: 16)!) / 255
    let g = CGFloat(Int(hex.dropFirst(2).prefix(2), radix: 16)!) / 255
    let b = CGFloat(Int(hex.dropFirst(4).prefix(2), radix: 16)!) / 255
    let color = attribute.color.usingColorSpace(.sRGB)!
    #expect(abs(color.redComponent - r) < 0.01
            && abs(color.greenComponent - g) < 0.01
            && abs(color.blueComponent - b) < 0.01,
            "\(label): Farbe weicht von der JSON-Vorgabe ab")
    let style = category["style"] as? [String: Any]
    #expect(attribute.bold == (style?["bold"] as? Bool ?? false), "\(label): bold")
    #expect(attribute.italic == (style?["italic"] as? Bool ?? false), "\(label): italic")
}

@Test("4D-Theme hell folgt light.json (Kernkategorien)")
func fourD_lightThemeMatchesJSON() throws {
    let json = try themeJSON("light.json")
    expectColor(EditorView.fourDTheme.keywords, matches: json["keywords"] as! [String: Any], "keywords")
    expectColor(EditorView.fourDTheme.commands, matches: json["commands"] as! [String: Any], "commands")
    expectColor(EditorView.fourDTheme.methods, matches: json["methods"] as! [String: Any], "methods")
    expectColor(EditorView.fourDTheme.variables, matches: json["local_variables"] as! [String: Any], "local_variables")
    expectColor(EditorView.fourDTheme.characters, matches: json["process_variables"] as! [String: Any], "process_variables")
    expectColor(EditorView.fourDTheme.types, matches: json["tables"] as! [String: Any], "tables")
    expectColor(EditorView.fourDTheme.attributes, matches: json["fields"] as! [String: Any], "fields")
    expectColor(EditorView.fourDTheme.text, matches: json["plain_text"] as! [String: Any], "plain_text")
    // Konstanten: Farbe muss stimmen; das JSON-Underline ist in CESE nicht
    // abbildbar (nur bold/italic existieren) — dokumentierter Verzicht.
    let constants = json["constants"] as! [String: Any]
    let hex = (constants["color"] as! String)
    #expect(hex.lowercased() == "#bf30b5")
    let values = EditorView.fourDTheme.values.color.usingColorSpace(.sRGB)!
    #expect(abs(values.redComponent - 0xBF / 255.0) < 0.01)
}

@Test("4D-Theme dunkel folgt dark.json (inkl. Fallbacks)")
func fourD_darkThemeMatchesJSON() throws {
    let json = try themeJSON("dark.json")
    expectColor(EditorView.fourDThemeDark.keywords, matches: json["keywords"] as! [String: Any], "keywords")
    expectColor(EditorView.fourDThemeDark.commands, matches: json["commands"] as! [String: Any], "commands")
    expectColor(EditorView.fourDThemeDark.methods, matches: json["methods"] as! [String: Any], "methods")
    expectColor(EditorView.fourDThemeDark.variables, matches: json["local_variables"] as! [String: Any], "local_variables")
    expectColor(EditorView.fourDThemeDark.characters, matches: json["process_variables"] as! [String: Any], "process_variables")
    expectColor(EditorView.fourDThemeDark.types, matches: json["tables"] as! [String: Any], "tables")
    expectColor(EditorView.fourDThemeDark.attributes, matches: json["fields"] as! [String: Any], "fields")
    expectColor(EditorView.fourDThemeDark.text, matches: json["plain_text"] as! [String: Any], "plain_text")
    // dark.json kennt keine Kommentar-Kursivierung — Farbe muss stimmen.
    expectColor(EditorView.fourDThemeDark.comments, matches: json["comments"] as! [String: Any], "comments")
}

@Test("Endungs-Mapping: 4D-Containerdateien und .4dm")
func fourD_extensionMapping() {
    #expect(EditorView.grammarForSpecialExtension("4DProject") == .json)
    #expect(EditorView.grammarForSpecialExtension("4DForm") == .json)
    #expect(EditorView.grammarForSpecialExtension("4DCatalog") == .html)
    #expect(EditorView.grammarForSpecialExtension("4DSettings") == .html)
    // .4dm läuft seit Etappe 3 Wunschpaket 2026-07b über die Registry
    // (CustomLanguageRegistry) — nicht mehr über das Grammatik-Mapping.
    #expect(EditorView.grammarForSpecialExtension("4dm") == nil)
    #expect(CustomLanguageRegistry.language(forExtension: "4dm") == CustomLanguageRegistry.fourD)
    #expect(EditorView.grammarForSpecialExtension("swift") == nil)
    #expect(DocumentKind.footerLabel(filename: "methode.4dm") == "4D")
    #expect(DocumentKind.footerLabel(filename: "Projekt.4DProject") == "JSON")
    #expect(DocumentKind.footerLabel(filename: "catalog.4DCatalog") == "XML")
}
