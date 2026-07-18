// FourDToolsTests.swift
//
// Tests für die 4D-Werkzeuge aus Etappe 6 (Wunschpaket 2026-07c):
// Vervollständigungs-Logik (Präfix + Matching mit Signaturen) und die
// Export-Transformation (Token-Suffixe strippen / Befehls-Token ergänzen,
// Roundtrip).

import Testing
import Foundation
@testable import Fastra

// MARK: - Vervollständigung: Präfix-Erkennung

private func prefix(_ text: String, cursorAt: Int? = nil) -> String? {
    let cursor = cursorAt ?? (text as NSString).length
    guard let range = FourDCompletionLogic.prefixRange(
        in: text, utf16CursorLocation: cursor
    ) else { return nil }
    return (text as NSString).substring(with: range)
}

@Test("Präfix: einfaches Wort und mehrwortige Befehle")
func completionPrefixBasics() {
    #expect(prefix("$x:=ALE") == "ALE")
    #expect(prefix("If (OBJECT Get") == "OBJECT Get")
    #expect(prefix("\tOBJECT SET ") == "OBJECT SET ")
    #expect(prefix("") == nil)
}

@Test("Präfix: hinter $, Punkt, Klammer und <> beginnt keine Phrase")
func completionPrefixBoundaries() {
    #expect(prefix("$loka") == nil)          // lokale Variable
    #expect(prefix("This.nam") == nil)       // Member
    #expect(prefix("[Tabel") == nil)         // Tabellenreferenz
    #expect(prefix("<>proz") == nil)         // Interprozess-Variable
    #expect(prefix("42") == nil)             // Zahl ist keine Phrase
}

@Test("Matching: Befehle (mit Signatur) vor Konstanten, case-tolerant")
func completionMatching() {
    let matches = FourDCompletionLogic.matches(forPrefix: "alert")
    #expect(!matches.isEmpty)
    #expect(matches[0].name == "ALERT")
    #expect(matches[0].isConstant == false)
    // Die Signatur stammt aus der generierten Symboltabelle.
    #expect(matches[0].signature?.contains("ALERT") == true)

    // Konstanten erscheinen nach den Befehlen.
    let mixed = FourDCompletionLogic.matches(forPrefix: "4D ")
    if let firstConstant = mixed.firstIndex(where: { $0.isConstant }) {
        let beforeFirstConstant = mixed[..<firstConstant].filter { $0.isConstant }
        #expect(beforeFirstConstant.isEmpty)
    }
}

@Test("Matching: Obergrenze und leeres Präfix")
func completionMatchingLimits() {
    #expect(FourDCompletionLogic.matches(forPrefix: "").isEmpty)
    let capped = FourDCompletionLogic.matches(forPrefix: "s", limit: 10)
    #expect(capped.count == 10)
}

// MARK: - Export-Transformation

@Test("Detokenisieren: Befehls- und Konstanten-Suffixe verschwinden")
func detokenizeBasics() {
    let tokenized = "ALERT:C41(\"Hallo\")\nRECEIVE PACKET:C104($vt;Into variable:K79:31)"
    let plain = FourDTokenTransform.detokenize(tokenized)
    #expect(plain == "ALERT(\"Hallo\")\nRECEIVE PACKET($vt;Into variable)")
}

@Test("Detokenisieren: Strings und Kommentare bleiben unangetastet")
func detokenizeSkipsStringsAndComments() {
    let code = "// ALERT:C41 im Kommentar\n$t:=\"ALERT:C41 im String\""
    #expect(FourDTokenTransform.detokenize(code) == code)
}

@Test("Befehls-Token ergänzen: bekannte Befehle bekommen ihre Nummer")
func tokenizeCommands() {
    let plain = "ALERT(\"Hallo\")"
    let tokenized = FourDTokenTransform.tokenizeCommands(plain)
    #expect(tokenized == "ALERT:C41(\"Hallo\")")
    // Bereits tokenisierte Vorkommen bleiben unverändert.
    #expect(FourDTokenTransform.tokenizeCommands(tokenized) == tokenized)
}

@Test("Befehls-Token ergänzen: Konstanten und Unbekanntes bleiben stehen")
func tokenizeLeavesConstantsAlone() {
    // Konstanten-Nummern kennt keine öffentliche Quelle — ehrliche Grenze.
    let code = "RECEIVE PACKET($vt;Into variable)"
    let result = FourDTokenTransform.tokenizeCommands(code)
    #expect(result.contains("RECEIVE PACKET:C"))
    #expect(result.contains("Into variable)"))
    #expect(!result.contains("Into variable:K"))
    // Eigene Projektmethoden (unbekannt) bleiben unangetastet.
    #expect(FourDTokenTransform.tokenizeCommands("MeineMethode($x)")
            == "MeineMethode($x)")
}

@Test("Roundtrip: Strippen und Wieder-Tokenisieren sind konsistent")
func tokenRoundtrip() {
    let tokenized = "ALERT:C41(\"x\")\nOPEN URL:C673(\"https://example.org\")"
    let plain = FourDTokenTransform.detokenize(tokenized)
    #expect(FourDTokenTransform.tokenizeCommands(plain) == tokenized)
    // Strippen ist idempotent.
    #expect(FourDTokenTransform.detokenize(plain) == plain)
}

@Test("Token-Suffix-Erkennung: nur echte :Cnnn/:Knnn(-Formen)")
func tokenSuffixShapes() {
    #expect(FourDTokenTransform.isTokenSuffix(":C41"))
    #expect(FourDTokenTransform.isTokenSuffix(":K79:31"))
    #expect(FourDTokenTransform.isTokenSuffix(":K5"))
    #expect(!FourDTokenTransform.isTokenSuffix(":X1"))
    #expect(!FourDTokenTransform.isTokenSuffix(":C"))
    #expect(!FourDTokenTransform.isTokenSuffix("C41"))
}

@Test("Menü-Adapter: Selektion wird respektiert, nil ohne Änderung")
func transformOperationAdapters() {
    let text = "ALERT:C41(\"a\")\nALERT:C41(\"b\")"
    // Nur die erste Zeile ist selektiert (UTF-16-Länge der ersten Zeile).
    let firstLine = NSRange(location: 0, length: 14)
    let result = FourDTokenTransform.detokenizeOperation(in: text,
                                                         selection: firstLine)
    #expect(result?.newText == "ALERT(\"a\")\nALERT:C41(\"b\")")
    // Nichts zu tun → nil (Aufrufer beept).
    #expect(FourDTokenTransform.detokenizeOperation(
        in: "$x:=1", selection: NSRange(location: 0, length: 0)) == nil)
}

// MARK: - Generierte Symboldaten

@Test("Generierte Details: Signaturen und Nummern sind plausibel gefüllt")
func generatedDetailsPlausible() {
    #expect(FourDSymbols.commandDetails.count > 1000)
    let alert = FourDSymbols.commandDetails["alert"]
    #expect(alert?.number == 41)
    #expect(alert?.signature?.hasPrefix("ALERT") == true)
}
