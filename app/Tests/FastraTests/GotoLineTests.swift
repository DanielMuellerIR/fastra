// GotoLineTests.swift
//
// Deckt die reine Parse-Logik des „Zu Zeile springen"-Dialogs (CMD+J)
// und die `nsRange(forLine:column:in:)`-Konvertierung ab.

import Testing
import Foundation
@testable import Fastra

// MARK: - GotoLineParse

@Test("Reine Zahl wird als Zeile interpretiert")
func parse_lineOnly() {
    let r = GotoLineParse.parse("42")
    #expect(r?.line == 42)
    #expect(r?.column == nil)
}

@Test("Zeile:Spalte wird beides erkannt")
func parse_lineAndColumn() {
    let r = GotoLineParse.parse("42:8")
    #expect(r?.line == 42)
    #expect(r?.column == 8)
}

@Test("Whitespace wird gelöscht")
func parse_whitespaceIgnored() {
    let r = GotoLineParse.parse("   5  :  12 ")
    #expect(r?.line == 5)
    #expect(r?.column == 12)
}

@Test("Leere Eingabe → nil")
func parse_emptyIsNil() {
    #expect(GotoLineParse.parse("") == nil)
    #expect(GotoLineParse.parse("   ") == nil)
}

@Test("Nicht-numerische Eingabe → nil")
func parse_garbageIsNil() {
    #expect(GotoLineParse.parse("abc") == nil)
    #expect(GotoLineParse.parse("5:") == nil)
    #expect(GotoLineParse.parse(":12") == nil)
    #expect(GotoLineParse.parse("5:12:99") == nil)
}

@Test("Zeile/Spalte < 1 → nil")
func parse_nonPositiveIsNil() {
    #expect(GotoLineParse.parse("0") == nil)
    #expect(GotoLineParse.parse("-5") == nil)
    #expect(GotoLineParse.parse("5:0") == nil)
    #expect(GotoLineParse.parse("5:-1") == nil)
}

// MARK: - BufferSearch.nsRange(forLine:column:in:)

@Test("Zeile 1 ohne Spalte → Offset 0")
func nsRange_firstLineStart() {
    let r = BufferSearch.nsRange(forLine: 1, column: nil, in: "abc\ndef\n")
    #expect(r == NSRange(location: 0, length: 0))
}

@Test("Zeile 2 ohne Spalte → hinter dem ersten Newline")
func nsRange_secondLineStart() {
    let r = BufferSearch.nsRange(forLine: 2, column: nil, in: "abc\ndef\n")
    #expect(r == NSRange(location: 4, length: 0))
}

@Test("Zeile 2, Spalte 3 → zwei Zeichen in die Zeile rein")
func nsRange_secondLineColumn3() {
    let r = BufferSearch.nsRange(forLine: 2, column: 3, in: "abc\ndefgh\n")
    // 'd'=4, 'e'=5, 'f'=6 → Spalte 3 = Offset 6
    #expect(r == NSRange(location: 6, length: 0))
}

@Test("Spalte jenseits Zeilenende wird ans Zeilenende geclampt")
func nsRange_columnClampedToLineEnd() {
    let r = BufferSearch.nsRange(forLine: 1, column: 999, in: "abc\ndef\n")
    // Zeile 1 endet vor dem \n bei Offset 3.
    #expect(r == NSRange(location: 3, length: 0))
}

@Test("Zeile jenseits Dokumentende wird ans Dokumentende geclampt")
func nsRange_lineBeyondEnd() {
    let text = "abc\ndef\n"
    let r = BufferSearch.nsRange(forLine: 999, column: nil, in: text)
    #expect(r == NSRange(location: (text as NSString).length, length: 0))
}
