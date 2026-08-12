// DifficultDocumentFixtures.swift
//
// Prozedural erzeugter Belastungs-Korpus. Keine Datei und kein Text aus einem
// realen Dokument wird übernommen oder eingecheckt. Der Fülltext ähnelt dem
// Alphabet langer Base64-Felder, enthält aber absichtlich ungültige Zeichen
// und wird von den Tests niemals dekodiert.

import Foundation
@testable import Fastra

struct DifficultDocumentFixture {
    static let targetByteSize = 4_357_697

    let label: String
    let filename: String
    let expectedFormatID: DocumentFormatID
    let prefix: String
    let suffix: String

    func makeContent(byteSize: Int = targetByteSize) -> String {
        let wrapperSize = prefix.utf8.count + suffix.utf8.count
        return prefix + Self.makeSyntheticPayload(
            length: max(0, byteSize - wrapperSize)
        ) + suffix
    }

    func makePayload(byteSize: Int = targetByteSize) -> String {
        Self.makeSyntheticPayload(
            length: max(0, byteSize - prefix.utf8.count - suffix.utf8.count)
        )
    }

    private static func makeSyntheticPayload(length: Int) -> String {
        // `_`, `-` und `?` machen die Folge bewusst zu keinem gültigen
        // Standard-Base64. Das kurze deterministische Muster hält die
        // Fixture-Erzeugung schnell und reproduzierbar.
        let pattern = "A7+/qZ09_-?mN4xB"
        let fullPatterns = length / pattern.utf8.count
        let remainder = length % pattern.utf8.count
        return String(repeating: pattern, count: fullPatterns)
            + String(pattern.prefix(remainder))
    }

    static let all: [DifficultDocumentFixture] = [
        .init(
            label: "Plain Text",
            filename: "synthetic-long-line.txt",
            expectedFormatID: .plainText,
            prefix: "synthetic-payload:",
            suffix: ""
        ),
        .init(
            label: "JSON",
            filename: "synthetic-long-line.json",
            expectedFormatID: .grammar(.json),
            prefix: #"{"payload":""#,
            suffix: #"","sequence":1}"#
        ),
        .init(
            label: "XML",
            filename: "synthetic-long-line.xml",
            expectedFormatID: .xml,
            prefix: #"<document><payload encoding="synthetic">"#,
            suffix: "</payload><sequence>1</sequence></document>"
        ),
        .init(
            label: "CSV",
            filename: "synthetic-long-line.csv",
            expectedFormatID: .csv,
            prefix: "sequence,payload\n1,\"",
            suffix: "\"\n"
        ),
        .init(
            label: "Markdown",
            filename: "synthetic-long-line.md",
            expectedFormatID: .grammar(.markdown),
            prefix: "# Synthetic stress document\n\n[data](data:application/octet-stream;synthetic,",
            suffix: ")\n"
        ),
    ]

    static var json: DifficultDocumentFixture {
        all.first { $0.expectedFormatID == .grammar(.json) }!
    }

    static var xml: DifficultDocumentFixture {
        all.first { $0.expectedFormatID == .xml }!
    }
}
