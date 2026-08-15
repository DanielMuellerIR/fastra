// PatternTests.swift
//
// Smoke-Tests für die mitgelieferten Vorlagen aus BuiltInPatterns.
// Ziel: jede Vorlage soll …
//   1. einen gültigen NSRegularExpression-String haben (kompiliert).
//   2. ihren `exampleMatch` finden.
//   3. zur deklarierten Group-Anzahl konsistente `groupLabels` führen
//      (entweder leer oder gleich viele wie tatsächliche Gruppen).
//
// Wir verwenden das neue Swift-Testing-Framework (`import Testing`,
// `#expect`, `@Test`) statt XCTest — siehe AGENTS.md, Abschnitt
// „QA-Strategie".

import Testing
import Foundation
@testable import Fastra

// MARK: - 1. Alle Vorlagen kompilieren

@Test("Jede mitgelieferte Vorlage hat einen kompilierbaren RegEx")
func allPatternsCompile() throws {
    for pattern in BuiltInPatterns.all {
        // Wenn der RegEx-String defekt ist, wirft `compile()` —
        // dann fällt der Test mit klarem Bezug zur ID durch.
        _ = try pattern.compile()
    }
}

// MARK: - 2. Beispiel-Treffer muss matchen

@Test("Jeder exampleMatch wird von seinem RegEx gefunden",
      arguments: BuiltInPatterns.all)
func exampleMatches(_ pattern: PatternTemplate) throws {
    let regex = try pattern.compile()
    let range = NSRange(pattern.exampleMatch.startIndex..<pattern.exampleMatch.endIndex,
                        in: pattern.exampleMatch)
    let match = regex.firstMatch(in: pattern.exampleMatch,
                                 options: [],
                                 range: range)
    #expect(match != nil,
            "Vorlage '\(pattern.id)' findet ihren exampleMatch nicht: '\(pattern.exampleMatch)'")
}

// MARK: - 3. groupLabels.count stimmt mit declaredGroupCount überein

@Test("groupLabels.count passt zur tatsächlichen Group-Anzahl",
      arguments: BuiltInPatterns.all)
func groupLabelsMatchGroupCount(_ pattern: PatternTemplate) {
    let actual = pattern.declaredGroupCount
    // Leere `groupLabels` sind explizit erlaubt — Vorlage hat dann
    // keine benannten Gruppen. Sind welche da, muss die Anzahl passen.
    if !pattern.groupLabels.isEmpty {
        #expect(pattern.groupLabels.count == actual,
                "Vorlage '\(pattern.id)': \(pattern.groupLabels.count) Labels, aber \(actual) Capture Groups")
    }
}

// MARK: - 4. IDs sind eindeutig

@Test("Alle Pattern-IDs sind eindeutig")
func idsAreUnique() {
    let ids = BuiltInPatterns.all.map(\.id)
    let unique = Set(ids)
    #expect(ids.count == unique.count,
            "Doppelte Pattern-IDs: \(ids.count - unique.count) Duplikate")
}

// MARK: - 5. Default-Ersetzungen verweisen nur auf existierende Gruppen

@Test("defaultReplacement referenziert nur deklarierte Gruppen",
      arguments: BuiltInPatterns.all.filter { $0.defaultReplacement != nil })
func defaultReplacementGroupRefsValid(_ pattern: PatternTemplate) throws {
    let replacement = pattern.defaultReplacement!
    let groupCount = pattern.declaredGroupCount

    // Alle `$N` (N >= 1) aus dem Replacement-String einsammeln.
    // Wir greifen $0 nicht ab — das ist immer der gesamte Match
    // und damit ohne Capture Group gültig.
    let refRegex = try NSRegularExpression(pattern: #"\$(\d+)"#)
    let nsReplacement = replacement as NSString
    let refs = refRegex
        .matches(in: replacement,
                 options: [],
                 range: NSRange(location: 0, length: nsReplacement.length))
        .compactMap { match -> Int? in
            Int(nsReplacement.substring(with: match.range(at: 1)))
        }

    for n in refs where n > 0 {
        #expect(n <= groupCount,
                "Vorlage '\(pattern.id)': defaultReplacement '\(replacement)' verweist auf $\(n), es gibt aber nur \(groupCount) Gruppen")
    }
}

// MARK: - 6. Kategorien-Filter liefert konsistente Ergebnisse

@Test("patterns(in:) gibt nur Vorlagen der gewünschten Kategorie zurück")
func categoryFilterIsConsistent() {
    for category in PatternCategory.allCases {
        let filtered = BuiltInPatterns.patterns(in: category)
        for pattern in filtered {
            #expect(pattern.category == category)
        }
    }
}

// MARK: - 7. Vereinigung der Kategorie-Filter ergibt die Gesamtliste

@Test("Vereinigung aller Kategorien deckt BuiltInPatterns.all ab")
func categoryUnionEqualsAll() {
    let unionCount = PatternCategory.allCases
        .map { BuiltInPatterns.patterns(in: $0).count }
        .reduce(0, +)
    #expect(unionCount == BuiltInPatterns.all.count)
}

// MARK: - 8. Zeilenbezogene Vorlagen beachten alle unterstützten Zeilenenden

@Test("Zeilen- und Codeblock-Vorlagen unterstützen LF, CRLF und CR",
      arguments: ["\n", "\r\n", "\r"])
func lineEndingPatterns(lineEnding: String) throws {
    let trailingText = "Erste   \(lineEnding)Zweite"
    let trailingMatch = try BuiltInPatterns.trailingWhitespace
        .compile(options: .anchorsMatchLines)
        .firstMatch(in: trailingText,
                    range: NSRange(location: 0, length: (trailingText as NSString).length))
    #expect(trailingMatch?.range == NSRange(location: 5, length: 3))

    let emptyLineText = "Erste\(lineEnding)  \(lineEnding)Letzte"
    let expectedEmptyRange = NSRange(
        location: (("Erste" + lineEnding) as NSString).length,
        length: (("  " + lineEnding) as NSString).length
    )
    let emptyLineMatch = try BuiltInPatterns.emptyLines
        .compile(options: .anchorsMatchLines)
        .firstMatch(in: emptyLineText,
                    range: NSRange(location: 0, length: (emptyLineText as NSString).length))
    #expect(emptyLineMatch?.range == expectedEmptyRange)

    let codeBlock = "```swift\(lineEnding)let value = 1\(lineEnding)```"
    let codeMatch = try BuiltInPatterns.codeBlock.compile().firstMatch(
        in: codeBlock,
        range: NSRange(location: 0, length: (codeBlock as NSString).length)
    )
    #expect(codeMatch?.range == NSRange(location: 0, length: (codeBlock as NSString).length))

    let leadingText = "Erste\(lineEnding)  Zweite"
    let expectedLeadingRange = NSRange(
        location: (("Erste" + lineEnding) as NSString).length,
        length: 2
    )
    let leadingMatch = try BuiltInPatterns.leadingWhitespace
        .compile(options: .anchorsMatchLines)
        .firstMatch(in: leadingText,
                    range: NSRange(location: 0, length: (leadingText as NSString).length))
    #expect(leadingMatch?.range == expectedLeadingRange)

    let headingText = "Einleitung\(lineEnding)## Titel\(lineEnding)Ende"
    let expectedHeadingRange = NSRange(
        location: (("Einleitung" + lineEnding) as NSString).length,
        length: ("## Titel" as NSString).length
    )
    let headingMatch = try BuiltInPatterns.markdownHeading
        .compile(options: .anchorsMatchLines)
        .firstMatch(in: headingText,
                    range: NSRange(location: 0, length: (headingText as NSString).length))
    #expect(headingMatch?.range == expectedHeadingRange)

    let orphanHeading = "##\(lineEnding)Kein Titel"
    let orphanMatch = try BuiltInPatterns.markdownHeading
        .compile(options: .anchorsMatchLines)
        .firstMatch(in: orphanHeading,
                    range: NSRange(location: 0, length: (orphanHeading as NSString).length))
    #expect(orphanMatch == nil)

    let wholeLineText = "Erste\(lineEnding)Zweite\(lineEnding)Dritte"
    let expectedWholeLineRange = NSRange(
        location: (("Erste" + lineEnding) as NSString).length,
        length: ("Zweite" as NSString).length
    )
    let wholeLineMatches = try BuiltInPatterns.wholeLine
        .compile(options: .anchorsMatchLines)
        .matches(in: wholeLineText,
                 range: NSRange(location: 0, length: (wholeLineText as NSString).length))
    #expect(wholeLineMatches.contains { $0.range == expectedWholeLineRange })

    let filePathText = "Erste\(lineEnding)/pfad/datei.txt\(lineEnding)Dritte"
    let expectedFilePathRange = NSRange(
        location: (("Erste" + lineEnding) as NSString).length,
        length: ("/pfad/datei.txt" as NSString).length
    )
    let filePathMatch = try BuiltInPatterns.filePath
        .compile(options: .anchorsMatchLines)
        .firstMatch(in: filePathText,
                    range: NSRange(location: 0, length: (filePathText as NSString).length))
    #expect(filePathMatch?.range == expectedFilePathRange)
}
