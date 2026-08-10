// FourDReviewFixTests.swift
//
// Regressionstests zu den 4D-Funden des Code-Reviews vom 2026-08-10. Geprüft
// wird jeweils das reale Fehlverhalten, nicht die geänderte Zeile:
//
// - F2: Eine Zeile, die in einem mehrzeiligen Blockkommentar BEGINNT, kann
//   hinter ihrem `*/` wieder gültigen 4D-Code enthalten. Parameterhilfe und
//   Vervollständigung müssen dort wieder greifen.
// - F6: Ein Projekt- oder Komponentenmethodenname darf mehr Wörter haben als
//   der längste eingebaute 4D-Befehl und muss trotzdem vollständig erkannt
//   werden.
// - F7: Nur nachweislich normale Dateien gehören in den Methodenindex — ein
//   ins Leere zeigender Symlink erzeugte sonst eine Phantommethode.
//
// Alle Fixtures sind selbst geschrieben (nichts aus Arbeitsprojekten).

import Foundation
import Testing
@testable import Fastra

// MARK: - F2: Code hinter dem Ende eines mehrzeiligen Blockkommentars

@Test("Aufruf hinter dem `*/` einer Kommentar-Schlusszeile bekommt Hilfe")
func fourDReviewFix_contextAfterBlockCommentEndInSameLine() {
    // Zeile 2 beginnt im Kommentar, endet ihn aber vor dem Aufruf.
    let text = "/* Anfang\nEnde */ Rechne($a"
    let context = FourDSignatureHelpLogic.callContext(
        in: text, utf16CursorLocation: (text as NSString).length
    )
    #expect(context?.methodName == "Rechne")
    #expect(context?.activeParameterIndex == 0)
}

@Test("Mehrere Argumente hinter dem `*/` zählen normal weiter")
func fourDReviewFix_activeParameterAfterBlockCommentEnd() {
    let text = "/* Anfang\nEnde */ Rechne($a;$b"
    let context = FourDSignatureHelpLogic.callContext(
        in: text, utf16CursorLocation: (text as NSString).length
    )
    #expect(context?.methodName == "Rechne")
    #expect(context?.activeParameterIndex == 1)
}

@Test("Ohne `*/` vor dem Cursor bleibt die Zeile Kommentar")
func fourDReviewFix_contextStaysNilWithoutBlockCommentEnd() {
    // Der Kommentar endet erst HINTER dem Cursor — dort gibt es keine Hilfe.
    let text = "/* Anfang\nRechne($a */"
    let cursor = (text as NSString).range(of: "$a").max
    #expect(FourDSignatureHelpLogic.callContext(
        in: text, utf16CursorLocation: cursor) == nil)
}

@Test("isInsideCommentOrString: hinter dem `*/` ist wieder Code")
func fourDReviewFix_insideCommentEndsWithBlockClose() {
    let text = "/* Anfang\nEnde */ ALERT(Variable"
    let ns = text as NSString
    // Vor dem `*/` steht die Position noch im Kommentar …
    #expect(FourDSignatureHelpLogic.isInsideCommentOrString(
        in: text, utf16Location: ns.range(of: "Ende").max))
    // … dahinter nicht mehr, sonst blieben die Vorschläge stumm.
    #expect(!FourDSignatureHelpLogic.isInsideCommentOrString(
        in: text, utf16Location: ns.length))
}

// MARK: - F6: Methodennamen mit mehr Wörtern als der längste 4D-Befehl

/// Acht Wörter — mehr als jeder eingebaute Befehl und jede Konstante
/// (längste statische Einträge: sieben Wörter).
private let eightWordMethodName = "Berechne Summe Aller Offenen Posten Pro Kunde Jetzt"

@Test("Achtwortige Projektmethode wird vollständig hervorgehoben")
func fourDReviewFix_tokenizesLongProjectMethodName() {
    let text = "\(eightWordMethodName)(1)"
    let tokens = FourDTokenizer.tokenize(
        text, projectMethodNames: [eightWordMethodName.lowercased()]
    )
    let expected = (text as NSString).range(of: eightWordMethodName)
    #expect(tokens.contains {
        $0.kind == .projectMethod && $0.range == expected
    })
}

@Test("Achtwortige Komponentenmethode wird vollständig hervorgehoben")
func fourDReviewFix_tokenizesLongComponentMethodName() {
    let text = "\(eightWordMethodName)(1)"
    let tokens = FourDTokenizer.tokenize(
        text, componentMethodNames: [eightWordMethodName.lowercased()]
    )
    let expected = (text as NSString).range(of: eightWordMethodName)
    #expect(tokens.contains {
        $0.kind == .componentMethod && $0.range == expected
    })
}

@Test("Kurze Namen und Befehle bleiben unverändert klassifiziert")
func fourDReviewFix_shortNamesUnchanged() {
    let tokens = FourDTokenizer.tokenize(
        "ALERT(\"Hallo\")\nAbr_Init(1)",
        projectMethodNames: ["abr_init"]
    )
    #expect(tokens.contains { $0.kind == .command })
    #expect(tokens.contains { $0.kind == .projectMethod })
}

// MARK: - F7: kaputte Symlinks gehören nicht in den Methodenindex

@Test("Index nimmt echte Dateien und gültige Symlinks, aber keine toten Links")
func fourDReviewFix_indexRejectsBrokenSymlink() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory
        .appendingPathComponent("fastra-4d-reviewfix-\(UUID().uuidString)")
    defer { try? manager.removeItem(at: root) }
    let methods = root.appendingPathComponent("Project/Sources/Methods")
    try manager.createDirectory(at: methods, withIntermediateDirectories: true)

    let real = methods.appendingPathComponent("Echt.4dm")
    try Data().write(to: real)
    // Gültiger Link auf eine normale Methodendatei — der muss drinbleiben.
    try manager.createSymbolicLink(
        at: methods.appendingPathComponent("Verlinkt.4dm"),
        withDestinationURL: real
    )
    // Link ins Leere: Vorher zählte er als Methode, weil die fehlgeschlagene
    // Attributabfrage `nil` lieferte und `nil != false` durchging.
    try manager.createSymbolicLink(
        at: methods.appendingPathComponent("Kaputt.4dm"),
        withDestinationURL: methods.appendingPathComponent("FehltGanz.4dm")
    )

    #expect(FourDProjectMethodIndex.methodNames(in: root) == ["echt", "verlinkt"])
}
