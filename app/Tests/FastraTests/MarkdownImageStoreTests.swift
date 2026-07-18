// MarkdownImageStoreTests.swift
//
// Tests für die Bild-Ablage des Markdown-Assistenten (Etappe 5 Wunschpaket
// 2026-07b): Namensvergabe, Kollisions- und Dedup-Logik, Relativpfade
// (Umlaute, Leerzeichen, Unterordner) und die Drop-Abgrenzung.

import Foundation
import AppKit
import Testing
@testable import Fastra

private func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-mdimage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

/// Kleine echte PNG-Daten (1×1 Pixel) für Ablage-Tests.
private func tinyPNG() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.setColor(.red, atX: 0, y: 0)
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Namensvergabe

@Test("Paste-Name: dokumentname-JJJJ-MM-TT-hhmmss")
func pastedName_format() {
    var components = DateComponents()
    components.year = 2026; components.month = 7; components.day = 18
    components.hour = 14; components.minute = 3; components.second = 9
    let date = Calendar.current.date(from: components)!
    let name = MarkdownImageStore.pastedImageBaseName(documentName: "Notizen.md",
                                                      date: date)
    #expect(name == "Notizen-2026-07-18-140309")
}

@Test("collisionFreeName: erst base.ext, dann base-2.ext, base-3.ext")
func collisionName_suffixes() {
    var taken: Set<String> = []
    #expect(MarkdownImageStore.collisionFreeName(base: "b", fileExtension: "png",
                                                 exists: { taken.contains($0) }) == "b.png")
    taken = ["b.png"]
    #expect(MarkdownImageStore.collisionFreeName(base: "b", fileExtension: "png",
                                                 exists: { taken.contains($0) }) == "b-2.png")
    taken = ["b.png", "b-2.png"]
    #expect(MarkdownImageStore.collisionFreeName(base: "b", fileExtension: "png",
                                                 exists: { taken.contains($0) }) == "b-3.png")
}

// MARK: - Relativpfade

@Test("relativeLinkPath: Umlaute und Leerzeichen werden prozent-codiert")
func relativePath_encodesSpecials() {
    let doc = URL(fileURLWithPath: "/tmp/projekt/Notizen.md")
    let image = URL(fileURLWithPath: "/tmp/projekt/Bild über alles.png")
    let link = MarkdownImageStore.relativeLinkPath(from: doc, to: image)
    #expect(link == "Bild%20u%CC%88ber%20alles.png" || link == "Bild%20%C3%BCber%20alles.png",
            "unerwartete Codierung: \(link ?? "nil")")
}

@Test("relativeLinkPath: Unterordner bleiben als Pfadsegmente erhalten")
func relativePath_subfolder() {
    let doc = URL(fileURLWithPath: "/tmp/projekt/doku/Seite.md")
    let image = URL(fileURLWithPath: "/tmp/projekt/doku/bilder/foto 1.jpg")
    #expect(MarkdownImageStore.relativeLinkPath(from: doc, to: image)
            == "bilder/foto%201.jpg")
}

@Test("relativeLinkPath: außerhalb des Dokumentordners → nil")
func relativePath_outsideIsNil() {
    let doc = URL(fileURLWithPath: "/tmp/projekt/Seite.md")
    let image = URL(fileURLWithPath: "/tmp/anderswo/foto.png")
    #expect(MarkdownImageStore.relativeLinkPath(from: doc, to: image) == nil)
}

@Test("markdownImageLink: Alt-Text ist der Name ohne Endung")
func imageLink_altText() {
    #expect(MarkdownImageStore.markdownImageLink(fileName: "foto-2.png",
                                                 relativePath: "foto-2.png")
            == "![foto-2](foto-2.png)")
}

// MARK: - Format-Entscheidung

@Test("prepare: PNG/JPEG/GIF behalten Format, TIFF wird PNG")
func prepare_formats() {
    let png = tinyPNG()
    #expect(MarkdownImageStore.prepare(imageData: png,
                                       typeIdentifier: "public.png")?.fileExtension == "png")
    // TIFF-Daten aus dem PNG erzeugen und konvertieren lassen.
    let tiff = NSBitmapImageRep(data: png)!.tiffRepresentation!
    let prepared = MarkdownImageStore.prepare(imageData: tiff,
                                              typeIdentifier: "public.tiff")
    #expect(prepared?.fileExtension == "png")
    // Ergebnis ist echtes PNG (Signatur 89 50 4E 47).
    #expect(prepared?.data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
}

// MARK: - Ablage (IO)

@Test("storePastedData: Datei entsteht im Dokumentordner, Link ist relativ")
func store_pastedData() throws {
    try withTempDir { dir in
        let doc = dir.appendingPathComponent("Notizen.md")
        try "x".write(to: doc, atomically: true, encoding: .utf8)
        let prepared = MarkdownImageStore.PreparedImageData(data: tinyPNG(),
                                                            fileExtension: "png")
        let stored = try MarkdownImageStore.storePastedData(prepared, documentURL: doc)
        #expect(FileManager.default.fileExists(atPath: stored.fileURL.path))
        #expect(stored.fileURL.deletingLastPathComponent().path == dir.path)
        #expect(stored.link.hasPrefix("![Notizen-"))
        #expect(stored.link.hasSuffix(".png)"))
    }
}

@Test("storeImageFile: Kollision → Suffix, byte-identisch → dedup (kein Doppel)")
func store_fileCollisionAndDedup() throws {
    try withTempDir { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        try "x".write(to: doc, atomically: true, encoding: .utf8)
        // Quelle außerhalb des Dokumentordners.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-mdimage-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let source = outside.appendingPathComponent("foto.png")
        try tinyPNG().write(to: source)

        // 1. Kopie: Originalname.
        let first = try MarkdownImageStore.storeImageFile(source, documentURL: doc)
        #expect(first.fileURL.lastPathComponent == "foto.png")

        // 2. identische Quelle erneut → KEIN Doppel, vorhandene verlinken.
        let again = try MarkdownImageStore.storeImageFile(source, documentURL: doc)
        #expect(again.fileURL == first.fileURL)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".png") }
        #expect(files == ["foto.png"])

        // 3. ANDERE Datei mit gleichem Namen → Suffix-Kopie.
        let source2 = outside.appendingPathComponent("v2/foto.png")
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("v2"),
                                                withIntermediateDirectories: true)
        var other = tinyPNG()
        other.append(Data([0x00]))   // andere Bytes
        try other.write(to: source2)
        let suffixed = try MarkdownImageStore.storeImageFile(source2, documentURL: doc)
        #expect(suffixed.fileURL.lastPathComponent == "foto-2.png")
    }
}

@Test("storeImageFile: Datei bereits im Dokumentbaum → nur verlinken, nicht kopieren")
func store_fileInsideTreeLinksOnly() throws {
    try withTempDir { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        try "x".write(to: doc, atomically: true, encoding: .utf8)
        let sub = dir.appendingPathComponent("bilder")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let existing = sub.appendingPathComponent("logo.png")
        try tinyPNG().write(to: existing)

        let stored = try MarkdownImageStore.storeImageFile(existing, documentURL: doc)
        #expect(stored.fileURL == existing)
        #expect(stored.link == "![logo](bilder/logo.png)")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!files.contains("logo.png"), "es darf keine Kopie neben dem Dokument entstehen")
    }
}

// MARK: - Drop-Abgrenzung

@Test("partitionDroppedURLs: Bilder → einfügen, alles andere → öffnen")
func partition_dropURLs() {
    let image = URL(fileURLWithPath: "/tmp/a.PNG")
    let text = URL(fileURLWithPath: "/tmp/b.txt")
    let folder = URL(fileURLWithPath: "/tmp/ordner")
    let result = MarkdownImageStore.partitionDroppedURLs([image, text, folder])
    #expect(result.insert == [image])
    #expect(result.open == [text, folder])
}
