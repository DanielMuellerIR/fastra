// FourDStructureCheckTests.swift
//
// Unit-Tests der 4D-Struktur-Hinweise (Etappe 5 Wunschpaket 2026-07c).
// Leitregel des Checkers: valide 4D-Exporte dürfen KEINE Hinweise erzeugen
// (im Zweifel keine Meldung); gezielt kaputte Fälle finden die richtige
// Zeile.

import Testing
import Foundation
@testable import Fastra

// MARK: - Valide Exporte → keine Hinweise

@Test("Valide Methode mit allen Blockarten → kein Hinweis")
func validMethod() {
    let code = """
    // Struktur-Beispiel
    If (True)
    \tFor each ($item; $col)
    \t\tWhile ($x<10)
    \t\t\t$x:=$x+1
    \t\tEnd while
    \tEnd for each
    Else
    \tCase of
    \t\t: ($x=1)
    \t\t\tALERT("eins")
    \t\tElse
    \t\t\tALERT("sonst")
    \tEnd case
    End if
    Repeat
    \t$i:=$i+1
    Until ($i>3)
    For ($n; 1; 10)
    \tALERT(String($n))
    End for
    """
    #expect(FourDStructureCheck.check(code) == nil)
}

@Test("Valide Klassendatei mit zwei Functions → kein Hinweis")
func validClassFile() {
    let code = """
    Class constructor($name : Text)
    \tThis.name:=$name

    Function sayHello() : Text
    \tIf (This.name#"")
    \t\treturn "Hallo "+This.name
    \tEnd if
    \treturn "Hallo"

    Function count($col : Collection) : Integer
    \treturn $col.length
    """
    #expect(FourDStructureCheck.check(code) == nil)
}

@Test("Leerer Text und reine Kommentare → kein Hinweis")
func validTrivial() {
    #expect(FourDStructureCheck.check("") == nil)
    #expect(FourDStructureCheck.check("// nur ein Kommentar\n/* Block */") == nil)
}

@Test("Klammern in Strings, Kommentaren und Tabellen zählen nicht")
func bracketsInExcludedRanges() {
    let code = """
    ALERT("((( so viele Klammern")
    // ((( auch hier egal
    /* { und [ im Block */
    QUERY([Meine Tabelle]; [Meine Tabelle]Feld=1)
    $c:=[1; 2; 3]
    $o:={a: 1}
    """
    #expect(FourDStructureCheck.check(code) == nil)
}

@Test("Begin SQL … End SQL wird nicht gedeutet (SQL darf 4D-Wörter enthalten)")
func sqlBlockIsSkipped() {
    let code = """
    Begin SQL
    \tSELECT CASE WHEN x THEN 1 ELSE 2 END IF_COLUMN FROM t
    End SQL
    """
    #expect(FourDStructureCheck.check(code) == nil)
}

@Test("4D.Function als Typ ist keine Abschnittsgrenze (kein Zeilenanfang)")
func functionTypeAnnotationIsIgnored() {
    let code = """
    If (True)
    \tvar $f : 4D.Function
    End if
    """
    #expect(FourDStructureCheck.check(code) == nil)
}

// MARK: - Block-Balance

@Test("Fehlendes End if → Hinweis auf der If-Zeile")
func missingEndIf() {
    let code = """
    $a:=1
    If ($a=1)
    \t$a:=2
    """
    let issue = FourDStructureCheck.check(code)
    #expect(issue?.line == 2)
    #expect(issue?.message.contains("If") == true)
    #expect(issue?.message.contains("End if") == true)
}

@Test("End while schließt If → Mismatch nennt beide Zeilen")
func mismatchedCloser() {
    let code = """
    If (True)
    \t$x:=1
    End while
    """
    let issue = FourDStructureCheck.check(code)
    #expect(issue?.line == 3)
    // Erwartung über denselben L10n-Aufruf — der Testprozess kann je nach
    // System-Sprache Deutsch ODER Englisch auflösen.
    #expect(issue?.message == L10n.format(
        "„%@“ passt nicht zum offenen „%@“ aus Zeile %ld.",
        "End while", "If", 1
    ))
}

@Test("End if ohne If → Hinweis auf der End-if-Zeile")
func strayCloser() {
    let code = """
    $a:=1
    End if
    """
    let issue = FourDStructureCheck.check(code)
    #expect(issue?.line == 2)
    #expect(issue?.message.contains("End if") == true)
}

@Test("Else außerhalb von If/Case of → Hinweis")
func strayElse() {
    let code = """
    While ($x<3)
    \tElse
    End while
    """
    let issue = FourDStructureCheck.check(code)
    #expect(issue?.line == 2)
    #expect(issue?.message.contains("Else") == true)
}

@Test("Repeat ohne Until → Hinweis auf der Repeat-Zeile")
func repeatWithoutUntil() {
    let code = """
    Repeat
    \t$i:=$i+1
    """
    let issue = FourDStructureCheck.check(code)
    #expect(issue?.line == 1)
    #expect(issue?.message.contains("Until") == true)
}

@Test("Offener Block vor der nächsten Function → Hinweis mit Grenz-Zeile")
func unclosedBlockBeforeFunction() {
    let code = """
    Function eins()
    \tIf (True)
    \t\t$x:=1

    Function zwei()
    \treturn 2
    """
    let issue = FourDStructureCheck.check(code)
    #expect(issue?.line == 2)
    #expect(issue?.message == L10n.format(
        "„%@“ ohne schließendes „%@“ (vor %@).",
        "If", "End if", L10n.format("„Function“ in Zeile %ld", 5)
    ))
}

// MARK: - Klammer-Balance

@Test("Offene Klammer ohne Schluss → Hinweis an der Klammer-Position")
func unclosedParenthesis() {
    let code = """
    $a:=1
    $x:=(1+2
    $b:=3
    """
    let issue = FourDStructureCheck.check(code)
    #expect(issue?.line == 2)
    #expect(issue?.column == 5)
    #expect(issue?.message.contains("(") == true)
}

@Test("Schließende Klammer ohne Öffner → Hinweis")
func strayClosingParenthesis() {
    let code = "$x:=1)\n"
    let issue = FourDStructureCheck.check(code)
    #expect(issue?.line == 1)
    #expect(issue?.message.contains(")") == true)
}

@Test("Falsche Klammerart → Mismatch mit Zeile der offenen Klammer")
func mismatchedBracketKind() {
    let code = """
    $c:=New collection
    $x:=($c[0}
    """
    let issue = FourDStructureCheck.check(code)
    #expect(issue?.line == 2)
    #expect(issue?.message.contains("}") == true)
}

@Test("Unvollständiges Kollektions-Literal → Hinweis")
func unclosedCollectionLiteral() {
    let code = "$c:=[1; 2\n$d:=3\n"
    let issue = FourDStructureCheck.check(code)
    #expect(issue?.line == 1)
    #expect(issue?.message.contains("[") == true)
}

// MARK: - String- und Kommentar-Balance

@Test("String ohne schließendes Anführungszeichen → richtige Zeile")
func unterminatedString() {
    let code = """
    $a:="sauber"
    $b:="offen
    $c:=1
    """
    let issue = FourDStructureCheck.check(code)
    #expect(issue?.line == 2)
    #expect(issue?.message == L10n.string(
        "String ohne schließendes Anführungszeichen — 4D-Strings enden auf derselben Zeile."
    ))
}

@Test("Blockkommentar ohne */ → Hinweis am Kommentaranfang")
func unterminatedBlockComment() {
    let code = """
    $a:=1
    /* offen bleibt offen
    $b:=2
    """
    let issue = FourDStructureCheck.check(code)
    #expect(issue?.line == 2)
    #expect(issue?.message.contains("*/") == true)
}

@Test("Escapte Anführungszeichen bleiben ein sauberer String")
func escapedQuotes() {
    let code = "$a:=\"er sagte \\\"hallo\\\" laut\"\n"
    #expect(FourDStructureCheck.check(code) == nil)
}

// MARK: - Reihenfolge

@Test("Bei mehreren Problemen gewinnt die kleinste Position")
func earliestHintWins() {
    let code = """
    $x:="offen
    If (True)
    """
    let issue = FourDStructureCheck.check(code)
    #expect(issue?.line == 1)
    #expect(issue?.message == L10n.string(
        "String ohne schließendes Anführungszeichen — 4D-Strings enden auf derselben Zeile."
    ))
}
