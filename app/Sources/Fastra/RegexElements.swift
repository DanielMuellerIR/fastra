// RegexElements.swift
//
// Kategorisierte RegEx-Bausteine für den Element-Picker (der `[+]`-Button
// neben dem Find-Feld). Jeder Baustein hat den einzufügenden Token-Text
// und einen Klartext-Hinweis — so lernt der Nutzer die Syntax beiläufig
// (Suchmasken-Konzept, Abschnitt „Element-Picker").
//
// Reine Daten ohne UI → in `RegexElementsTests` abgedeckt.

import Foundation

/// Ein einzelner RegEx-Baustein im Picker.
struct RegexElement: Identifiable, Equatable {
    /// Anzeige-Symbol, z.B. `\d` oder `{n,m}`.
    let symbol: String
    /// Tatsächlich ins Find-Feld eingefügter Text. Meist gleich `symbol`;
    /// bei Platzhaltern (z.B. `[…]`) ein editierbares Gerüst.
    let insert: String
    /// Klartext-Erklärung, z.B. „eine Ziffer 0–9".
    let hint: String

    var id: String { symbol }

    init(_ symbol: String, insert: String? = nil, _ hint: String) {
        self.symbol = symbol
        self.insert = insert ?? symbol
        self.hint = hint
    }
}

/// Eine benannte Gruppe von Bausteinen.
struct RegexElementCategory: Identifiable {
    let name: String
    let elements: [RegexElement]
    var id: String { name }
}

enum RegexElements {
    static let categories: [RegexElementCategory] = [
        RegexElementCategory(name: "Anker", elements: [
            RegexElement("^", "Zeilenanfang"),
            RegexElement("$", "Zeilenende"),
            RegexElement(#"\b"#, "Wortgrenze"),
            RegexElement(#"\B"#, "keine Wortgrenze"),
        ]),
        RegexElementCategory(name: "Zeichenklassen", elements: [
            RegexElement(#"\d"#, "eine Ziffer 0–9"),
            RegexElement(#"\D"#, "keine Ziffer"),
            RegexElement(#"\w"#, "Wortzeichen (Buchstabe, Ziffer, _)"),
            RegexElement(#"\W"#, "kein Wortzeichen"),
            RegexElement(#"\s"#, "Leerraum (Space, Tab, Umbruch)"),
            RegexElement(#"\S"#, "kein Leerraum"),
            RegexElement(".", "ein beliebiges Zeichen"),
        ]),
        RegexElementCategory(name: "Zeichengruppen", elements: [
            RegexElement("[abc]", insert: "[abc]", "eines der Zeichen in der Klammer"),
            RegexElement("[^abc]", insert: "[^abc]", "keines der Zeichen in der Klammer"),
            RegexElement("[a-z]", insert: "[a-z]", "ein Zeichen aus dem Bereich"),
        ]),
        RegexElementCategory(name: "Quantifizierer", elements: [
            RegexElement("*", "null- oder mehrmals"),
            RegexElement("+", "ein- oder mehrmals"),
            RegexElement("?", "optional (null- oder einmal)"),
            RegexElement("{n}", insert: "{1}", "genau n-mal"),
            RegexElement("{n,m}", insert: "{1,3}", "n- bis m-mal"),
        ]),
        RegexElementCategory(name: "Gruppen", elements: [
            RegexElement("(…)", insert: "()", "Capture-Gruppe (für $1, $2 …)"),
            RegexElement("(?:…)", insert: "(?:)", "Gruppe ohne Erfassung"),
            RegexElement("|", "oder (Alternative)"),
        ]),
    ]

    /// Alle Bausteine flach — bequem für Tests.
    static var all: [RegexElement] { categories.flatMap(\.elements) }
}
