// FourDComponentIndexTests.swift
//
// Tests für den ZIP-Leser und den Komponenten-Index. Die Fixtures sind
// vollständig selbst geschrieben (keine Inhalte realer Nutzerprojekte):
// ZIP-Archive werden byteweise im Test erzeugt — mit „stored"- und echten
// „deflate"-Einträgen, damit beide Lesepfade real geprüft sind.

import Compression
import Foundation
import Testing
@testable import Fastra

// MARK: - ZIP-Fixture-Erzeugung (nur Testcode)

/// Baut ein minimales, formatkorrektes ZIP-Archiv. CRC32 wird nicht
/// berechnet (der Leser prüft sie bewusst nicht — Formatfehler zeigen sich
/// über Größen und Signaturen).
private func makeZip(_ entries: [(path: String, data: Data, deflate: Bool)]) -> Data {
    var out = Data()
    var central = Data()

    func append16(_ value: Int, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }
    func append32(_ value: Int, to data: inout Data) {
        append16(value & 0xFFFF, to: &data)
        append16((value >> 16) & 0xFFFF, to: &data)
    }

    for entry in entries {
        let name = Data(entry.path.utf8)
        let method = entry.deflate ? 8 : 0
        let payload = entry.deflate ? rawDeflate(entry.data) : entry.data
        let offset = out.count

        // Lokaler Header
        append32(0x0403_4B50, to: &out)
        append16(20, to: &out)                  // benötigte Version
        append16(0, to: &out)                   // Flags
        append16(method, to: &out)
        append16(0, to: &out)                   // Zeit
        append16(0, to: &out)                   // Datum
        append32(0, to: &out)                   // CRC32 (ungenutzt)
        append32(payload.count, to: &out)
        append32(entry.data.count, to: &out)
        append16(name.count, to: &out)
        append16(0, to: &out)                   // Extra
        out.append(name)
        out.append(payload)

        // Zentraler Verzeichniseintrag
        append32(0x0201_4B50, to: &central)
        append16(20, to: &central)              // erzeugt von
        append16(20, to: &central)              // benötigte Version
        append16(0, to: &central)               // Flags
        append16(method, to: &central)
        append16(0, to: &central)               // Zeit
        append16(0, to: &central)               // Datum
        append32(0, to: &central)               // CRC32
        append32(payload.count, to: &central)
        append32(entry.data.count, to: &central)
        append16(name.count, to: &central)
        append16(0, to: &central)               // Extra
        append16(0, to: &central)               // Kommentar
        append16(0, to: &central)               // Disk
        append16(0, to: &central)               // interne Attribute
        append32(0, to: &central)               // externe Attribute
        append32(offset, to: &central)
        central.append(name)
    }

    let directoryOffset = out.count
    out.append(central)
    append32(0x0605_4B50, to: &out)
    append16(0, to: &out)                       // Disk
    append16(0, to: &out)                       // Disk des Verzeichnisses
    append16(entries.count, to: &out)
    append16(entries.count, to: &out)
    append32(central.count, to: &out)
    append32(directoryOffset, to: &out)
    append16(0, to: &out)                       // Kommentarlänge
    return out
}

/// Setzt Bit 0 der lokalen und zentralen General-Purpose-Flags. Bei einem
/// stored-Eintrag wären die Nutzdaten danach Chiffretext und dürfen niemals
/// als gelesener Klartext durchgereicht werden.
private func markFirstZipEntryAsEncrypted(_ archive: Data) -> Data {
    var result = archive
    result[6] |= 0x01
    let centralSignature = Data([0x50, 0x4B, 0x01, 0x02])
    if let central = result.range(of: centralSignature) {
        result[central.lowerBound + 8] |= 0x01
    }
    return result
}

/// Roher DEFLATE-Strom, wie ihn ZIP-Methode 8 erwartet.
private func rawDeflate(_ data: Data) -> Data {
    guard !data.isEmpty else { return Data() }
    let capacity = data.count + 1024
    var out = Data(count: capacity)
    let written = out.withUnsafeMutableBytes { destination -> Int in
        data.withUnsafeBytes { source -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                  let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return compression_encode_buffer(
                destinationBase, capacity,
                sourceBase, data.count,
                nil, COMPRESSION_ZLIB
            )
        }
    }
    return out.prefix(written)
}

private func makeTempDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - FourDZipArchive

@Test("ZIP-Leser liefert stored- und deflate-Einträge unverändert zurück")
func zipArchive_roundtripsStoredAndDeflate() throws {
    let stored = Data("//%attributes = {\"shared\":true}\n// Stored".utf8)
    let deflated = Data(String(repeating: "// Zeile mit Text\n", count: 200).utf8)
    let zip = makeZip([
        ("Project/Sources/Methods/A.4dm", stored, false),
        ("Project/Sources/Methods/B.4dm", deflated, true),
        ("Project/Sources/", Data(), false),
    ])
    let root = try makeTempDirectory("zip")
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("Test.4DZ")
    try zip.write(to: archive)

    let entries = try #require(FourDZipArchive.entries(of: archive))
    #expect(entries.count == 3)
    let a = try #require(entries.first { $0.path.hasSuffix("A.4dm") })
    let b = try #require(entries.first { $0.path.hasSuffix("B.4dm") })
    #expect(entries.first { $0.path == "Project/Sources/" }?.isDirectory == true)
    #expect(FourDZipArchive.data(of: a, in: archive) == stored)
    #expect(FourDZipArchive.data(of: b, in: archive) == deflated)
}

@Test("ZIP-Leser lehnt zu große Einträge und Nicht-Archive ehrlich ab")
func zipArchive_rejectsOversizeAndGarbage() throws {
    let payload = Data(String(repeating: "x", count: 4096).utf8)
    let zip = makeZip([("big.txt", payload, true)])
    let root = try makeTempDirectory("ziplimit")
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("Limit.4DZ")
    try zip.write(to: archive)

    let entry = try #require(FourDZipArchive.entries(of: archive)?.first)
    #expect(FourDZipArchive.data(of: entry, in: archive, maximumSize: 100) == nil)
    #expect(FourDZipArchive.data(of: entry, in: archive) == payload)

    let garbage = root.appendingPathComponent("kein.zip")
    try Data("kein Archiv, nur Text".utf8).write(to: garbage)
    #expect(FourDZipArchive.entries(of: garbage) == nil)
}

@Test("ZIP-Leser lehnt verschlüsselte Einträge vor dem Lesen ab")
func zipArchive_rejectsEncryptedEntries() throws {
    let root = try makeTempDirectory("zip-encrypted")
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("Encrypted.4DZ")
    let zip = makeZip([("Project/Sources/Methods/Secret.4dm",
                        Data("kein Klartext".utf8), false)])
    try markFirstZipEntryAsEncrypted(zip).write(to: archive)

    #expect(FourDZipArchive.entries(of: archive) == nil)
}

// MARK: - Attribut-Erkennung

@Test("shared-Erkennung liest die //%attributes-Kopfzeile")
func componentIndex_detectsSharedAttribute() {
    #expect(FourDComponentIndex.isSharedMethodSource(
        "//%attributes = {\"shared\":true}\n// Kopf\n"
    ))
    #expect(FourDComponentIndex.isSharedMethodSource(
        "//%attributes = {\"shared\":true,\"preemptive\":\"capable\"}\r\nC_TEXT($1)"
    ))
    // Klassische reine `\r`-Zeilenenden.
    #expect(FourDComponentIndex.isSharedMethodSource(
        "//%attributes = {\"shared\":true}\r// Kopf"
    ))
    #expect(!FourDComponentIndex.isSharedMethodSource(
        "//%attributes = {}\n"
    ))
    #expect(!FourDComponentIndex.isSharedMethodSource(
        "// nur ein Kommentar\n"
    ))
}

// MARK: - FourDComponentIndex

@Test("Index findet geteilte Methoden entpackter Komponenten")
func componentIndex_readsUnpackedComponent() throws {
    let root = try makeTempDirectory("comp-unpacked")
    defer { try? FileManager.default.removeItem(at: root) }
    let methods = root.appendingPathComponent(
        "Components/Alpha.4dbase/Project/Sources/Methods"
    )
    try FileManager.default.createDirectory(at: methods, withIntermediateDirectories: true)
    try "//%attributes = {\"shared\":true}\n#DECLARE($a : Text)\n"
        .write(to: methods.appendingPathComponent("Alpha_Tu.4dm"),
               atomically: true, encoding: .utf8)
    try "// keine Attributzeile — nicht geteilt\n"
        .write(to: methods.appendingPathComponent("Alpha_Intern.4dm"),
               atomically: true, encoding: .utf8)

    let result = FourDComponentIndex.methods(in: root)
    #expect(result.count == 1)
    let method = try #require(result["alpha_tu"])
    #expect(method.displayName == "Alpha_Tu")
    #expect(method.componentName == "Alpha")
    guard case .sourceFile(let url) = method.source else {
        Issue.record("Quelle sollte die .4dm-Datei sein: \(method.source)")
        return
    }
    #expect(url.lastPathComponent == "Alpha_Tu.4dm")
}

@Test("Index liest interpretierte 4DZ-Komponenten aus dem Archiv")
func componentIndex_readsInterpretedArchive() throws {
    let root = try makeTempDirectory("comp-zip")
    defer { try? FileManager.default.removeItem(at: root) }
    let contents = root.appendingPathComponent("components/Beta.4dbase/Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let zip = makeZip([
        ("Project/Sources/Methods/Beta_Geteilt.4dm",
         Data("//%attributes = {\"shared\":true}\n// Kopf\n#DECLARE($x : Integer)\n".utf8),
         true),
        ("Project/Sources/Methods/Beta_Intern.4dm",
         Data("//%attributes = {}\n".utf8), false),
        ("Project/Sources/Methods/Unter/Ordner.4dm",
         Data("//%attributes = {\"shared\":true}\n".utf8), false),
    ])
    try zip.write(to: contents.appendingPathComponent("Beta.4DZ"))

    let result = FourDComponentIndex.methods(in: root)
    #expect(result.count == 1)
    let method = try #require(result["beta_geteilt"])
    #expect(method.componentName == "Beta")
    guard case .zipEntry(_, let path) = method.source else {
        Issue.record("Quelle sollte der ZIP-Eintrag sein: \(method.source)")
        return
    }
    #expect(path == "Project/Sources/Methods/Beta_Geteilt.4dm")
}

@Test("Index nutzt für kompilierte Komponenten Katalog und Dokumentation")
func componentIndex_readsCompiledArchiveCatalog() throws {
    let root = try makeTempDirectory("comp-compiled")
    defer { try? FileManager.default.removeItem(at: root) }
    let contents = root.appendingPathComponent("Components/Gamma.4dbase/Contents")
    let documentation = contents.appendingPathComponent("Documentation/Methods")
    try FileManager.default.createDirectory(at: documentation,
                                            withIntermediateDirectories: true)
    let catalog = """
    {"methods": {
        "Gamma_Dokumentiert": {"attributes": {"shared": true}},
        "Gamma_NurName": {"attributes": {"shared": true, "preemptive": "capable"}},
        "Gamma_Intern": {"timeStamp": "2026-01-01T00:00:00Z"}
    }}
    """
    let zip = makeZip([
        ("Project/DerivedData/methodAttributes.json", Data(catalog.utf8), true),
    ])
    try zip.write(to: contents.appendingPathComponent("Gamma.4DZ"))
    // Doku im 4D-Stil: BOM + `\r`-Zeilenenden + klassische Deklaration.
    try "\u{FEFF}// Macht etwas Dokumentiertes\rC_LONGINT($1)"
        .write(to: documentation.appendingPathComponent("Gamma_Dokumentiert.md"),
               atomically: true, encoding: .utf8)

    let result = FourDComponentIndex.methods(in: root)
    #expect(result.count == 2)
    let documented = try #require(result["gamma_dokumentiert"])
    guard case .documentation(let url) = documented.source else {
        Issue.record("Quelle sollte die Doku sein: \(documented.source)")
        return
    }
    #expect(url.lastPathComponent == "Gamma_Dokumentiert.md")
    #expect(result["gamma_nurname"]?.source == .nameOnly)
    #expect(result["gamma_intern"] == nil)
}

// MARK: - Signatur aus Dokumentation

@Test("Parser versteht Doku-Quellen mit BOM und CR-Zeilenenden")
func signatureParser_normalizesDocumentationSource() {
    let source = "\u{FEFF}// Methode: Tu was / Autor\rC_LONGINT($1;$2)\rC_TEXT($3)"
    let signature = FourDSignatureParser.parse(methodSource: source)
    #expect(signature.headerComment == "// Methode: Tu was / Autor")
    #expect(signature.parameters == [
        .init(name: "$1", type: "Longint"),
        .init(name: "$2", type: "Longint"),
        .init(name: "$3", type: "Text"),
    ])
}

// MARK: - Vervollständigung

@Test("Typeahead bietet Komponentenmethoden an; Projektmethode gewinnt")
func completion_offersComponentMethods() {
    let components = [
        FourDCompletionLogic.ComponentMethodEntry(
            name: "Util_Tu", componentName: "Util"
        ),
        FourDCompletionLogic.ComponentMethodEntry(
            name: "Util_Doppelt", componentName: "Util"
        ),
    ]
    let matches = FourDCompletionLogic.matches(
        forPrefix: "util_",
        projectMethods: ["Util_Doppelt"],
        componentMethods: components
    )
    // Die Projektmethode zuerst, die Komponentenmethode danach; der
    // Namensdoppelgänger aus der Komponente entfällt.
    #expect(matches.map(\.name) == ["Util_Doppelt", "Util_Tu"])
    #expect(matches[0].isProjectMethod)
    #expect(matches[0].componentName == nil)
    #expect(matches[1].componentName == "Util")
}
