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

@Test("Markdown-Bildlink maskiert Klammern und Alt-Text-Steuerzeichen")
func imageLink_escapesMarkdownSyntax() {
    let doc = URL(fileURLWithPath: "/tmp/projekt/Seite.md")
    let image = URL(fileURLWithPath: "/tmp/projekt/a:b(b)[c].png")
    #expect(MarkdownImageStore.relativeLinkPath(from: doc, to: image)
            == "a%3Ab%28b%29%5Bc%5D.png")
    #expect(MarkdownImageStore.markdownImageLink(
        fileName: "a[b]\\c\nzeile.png", relativePath: "sicher.png")
        == "![a\\[b\\]\\\\c zeile](sicher.png)")
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

@Test("storePastedData: parallele Ablagen erhalten verschiedene Suffixnamen")
func store_parallelPastedDataUsesSuffix() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-mdimage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let doc = dir.appendingPathComponent("Notizen.md")
    try "x".write(to: doc, atomically: true, encoding: .utf8)
    let prepared = MarkdownImageStore.PreparedImageData(data: tinyPNG(),
                                                        fileExtension: "png")
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let names = await withTaskGroup(of: String.self, returning: [String].self) { group in
        for _ in 0..<2 {
            group.addTask {
                do {
                    return try MarkdownImageStore.storePastedData(
                        prepared, documentURL: doc, now: now
                    ).fileURL.lastPathComponent
                } catch {
                    return "FEHLER: \(error.localizedDescription)"
                }
            }
        }
        var collected: [String] = []
        for await name in group { collected.append(name) }
        return collected
    }

    let base = MarkdownImageStore.pastedImageBaseName(
        documentName: doc.lastPathComponent, date: now
    )
    #expect(Set(names) == ["\(base).png", "\(base)-2.png"])
}

@Test("Paste veröffentlicht nie über eine gleichzeitig entstandene Datei")
func store_pastedDataUsesExclusivePublish() throws {
    try withTempDir { dir in
        let doc = dir.appendingPathComponent("Notizen.md")
        try "x".write(to: doc, atomically: true, encoding: .utf8)
        let prepared = MarkdownImageStore.PreparedImageData(
            data: Data("Fastra".utf8), fileExtension: "png")
        var insertedCollision = false
        let stored = try MarkdownImageStore.storePastedData(
            prepared, documentURL: doc, now: Date(timeIntervalSince1970: 1_800_000_000),
            hooks: .init(beforePublishing: { target in
                guard !insertedCollision else { return }
                insertedCollision = true
                try? Data("fremd".utf8).write(to: target, options: .withoutOverwriting)
            }))

        let base = MarkdownImageStore.pastedImageBaseName(
            documentName: doc.lastPathComponent,
            date: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try Data(contentsOf: dir.appendingPathComponent("\(base).png"))
                == Data("fremd".utf8))
        #expect(stored.fileURL.lastPathComponent == "\(base)-2.png")
        #expect(try Data(contentsOf: stored.fileURL) == Data("Fastra".utf8))
    }
}

@Test("Dokumentordner-Symlink behält einen relativen Bildlink")
func store_documentDirectorySymlinkKeepsRelativeLink() throws {
    try withTempDir { dir in
        let real = dir.appendingPathComponent("echt")
        let alias = dir.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real,
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias,
                                                   withDestinationURL: real)
        let document = alias.appendingPathComponent("Seite.md")
        try "x".write(to: document, atomically: true, encoding: .utf8)
        let prepared = MarkdownImageStore.PreparedImageData(
            data: Data("Bild".utf8), fileExtension: "png")
        let stored = try MarkdownImageStore.storePastedData(
            prepared, documentURL: document,
            now: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(stored.link == MarkdownImageStore.markdownImageLink(
            fileName: stored.fileURL.lastPathComponent,
            relativePath: stored.fileURL.lastPathComponent))
        #expect(stored.fileURL.deletingLastPathComponent().standardizedFileURL.path
                == real.standardizedFileURL.path)
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
        #expect(first.fileURL.deletingLastPathComponent().lastPathComponent == "images")
        #expect(first.link == "![foto](images/foto.png)")

        // 2. identische Quelle erneut → KEIN Doppel, vorhandene verlinken.
        let again = try MarkdownImageStore.storeImageFile(source, documentURL: doc)
        #expect(again.fileURL == first.fileURL)
        let files = try FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent("images").path
        )
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

@Test("storeImageFile: parallele Namenskollision wird per Suffix aufgelöst")
func store_parallelFileCollisionUsesSuffix() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-mdimage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let doc = dir.appendingPathComponent("Seite.md")
    try "x".write(to: doc, atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("images"), withIntermediateDirectories: true
    )
    let sourceA = dir.appendingPathComponent("a/foto.png")
    let sourceB = dir.appendingPathComponent("b/foto.png")
    try FileManager.default.createDirectory(
        at: sourceA.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: sourceB.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try tinyPNG().write(to: sourceA)
    var other = tinyPNG()
    other.append(0)
    try other.write(to: sourceB)

    let names = await withTaskGroup(of: String.self, returning: [String].self) { group in
        for source in [sourceA, sourceB] {
            group.addTask {
                do {
                    return try MarkdownImageStore.storeImageFile(
                        source, documentURL: doc
                    ).fileURL.lastPathComponent
                } catch {
                    return "FEHLER: \(error.localizedDescription)"
                }
            }
        }
        var collected: [String] = []
        for await name in group { collected.append(name) }
        return collected
    }

    #expect(Set(names) == ["foto.png", "foto-2.png"])
}

@Test("Bildkopie veröffentlicht bei externer Namenskollision mit Suffix")
func store_fileUsesExclusivePublish() throws {
    try withTempDir { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        let source = dir.appendingPathComponent("quelle/foto.png")
        try "x".write(to: doc, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Quelle".utf8).write(to: source)
        var insertedCollision = false
        let stored = try MarkdownImageStore.storeImageFile(
            source, documentURL: doc,
            hooks: .init(beforePublishing: { target in
                guard !insertedCollision else { return }
                insertedCollision = true
                try? Data("fremd".utf8).write(to: target, options: .withoutOverwriting)
            }))
        #expect(try Data(contentsOf: dir.appendingPathComponent("images/foto.png"))
                == Data("fremd".utf8))
        #expect(stored.fileURL.lastPathComponent == "foto-2.png")
    }
}

@Test("storeImageFile: images-Symlink wird abgelehnt, echter Ordner akzeptiert")
func store_imagesDirectoryMustNotBeSymlink() throws {
    try withTempDir { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        let source = dir.appendingPathComponent("quelle/foto.png")
        let foreign = dir.appendingPathComponent("fremd", isDirectory: true)
        try "x".write(to: doc, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try tinyPNG().write(to: source)
        let images = dir.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: images, withDestinationURL: foreign)

        var rejected = false
        do {
            _ = try MarkdownImageStore.storeImageFile(source, documentURL: doc)
        } catch MarkdownImageStore.StoreError.invalidImagesDirectory {
            rejected = true
        }
        #expect(rejected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: foreign.path).isEmpty)

        try FileManager.default.removeItem(at: images)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let stored = try MarkdownImageStore.storeImageFile(source, documentURL: doc)
        #expect(stored.fileURL == images.appendingPathComponent("foto.png"))
    }
}

@Test("Austausch des geöffneten images-Ordners schreibt nie ins Symlink-Ziel")
func store_imagesDirectorySwapIsRejected() throws {
    try withTempDir { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        let source = dir.appendingPathComponent("quelle/foto.png")
        let foreign = dir.appendingPathComponent("fremd")
        try "x".write(to: doc, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: foreign,
                                                withIntermediateDirectories: true)
        try Data("Bild".utf8).write(to: source)

        #expect(throws: MarkdownImageStore.StoreError.self) {
            _ = try MarkdownImageStore.storeImageFile(
                source, documentURL: doc,
                hooks: .init(afterOpeningImagesDirectory: {
                    let images = dir.appendingPathComponent("images")
                    let held = dir.appendingPathComponent("images-alt")
                    try? FileManager.default.moveItem(at: images, to: held)
                    try? FileManager.default.createSymbolicLink(
                        at: images, withDestinationURL: foreign)
                }))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: foreign.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent("images-alt").path).isEmpty)
    }
}

@Test("Austausch des Quellpfads nach open ändert die kopierten Bytes nicht")
func store_sourcePathSwapKeepsOpenedFile() throws {
    try withTempDir { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        let source = dir.appendingPathComponent("quelle/foto.png")
        try "x".write(to: doc, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ursprünglich".utf8).write(to: source)
        let stored = try MarkdownImageStore.storeImageFile(
            source, documentURL: doc,
            hooks: .init(afterOpeningSource: {
                let old = source.deletingLastPathComponent()
                    .appendingPathComponent("alt.png")
                try? FileManager.default.moveItem(at: source, to: old)
                try? Data("ausgetauscht".utf8).write(to: source)
            }))
        #expect(try Data(contentsOf: stored.fileURL) == Data("ursprünglich".utf8))
    }
}

@Test("Abgebrochene Kopie veröffentlicht keine Teil- oder Tempdatei")
func store_partialCopyIsNeverVisible() throws {
    try withTempDir { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        let source = dir.appendingPathComponent("quelle/gross.png")
        try "x".write(to: doc, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 200_000).write(to: source)
        #expect(throws: (any Error).self) {
            _ = try MarkdownImageStore.storeImageFile(
                source, documentURL: doc,
                hooks: .init(failCopyAfterBytes: 70_000))
        }
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("images").path))
    }
}

@Test("storeImageFile: Datei bereits im images-Ordner → nur verlinken, nicht kopieren")
func store_fileInsideImagesLinksOnly() throws {
    try withTempDir { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        try "x".write(to: doc, atomically: true, encoding: .utf8)
        let sub = dir.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let existing = sub.appendingPathComponent("logo.png")
        try tinyPNG().write(to: existing)

        let stored = try MarkdownImageStore.storeImageFile(existing, documentURL: doc)
        #expect(stored.fileURL == existing)
        #expect(stored.link == "![logo](images/logo.png)")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!files.contains("logo.png"), "es darf keine Kopie neben dem Dokument entstehen")
    }
}

@Test("storeImageFile: Bild aus anderem Dokument-Unterordner wird nach images kopiert")
func store_fileElsewhereInDocumentTreeCopiesIntoImages() throws {
    try withTempDir { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        try "x".write(to: doc, atomically: true, encoding: .utf8)
        let sourceDirectory = dir.appendingPathComponent("uploads")
        try FileManager.default.createDirectory(at: sourceDirectory,
                                                withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("Original Name.png")
        try tinyPNG().write(to: source)

        let stored = try MarkdownImageStore.storeImageFile(source, documentURL: doc)

        #expect(stored.fileURL.path == dir.appendingPathComponent(
            "images/Original Name.png"
        ).path)
        #expect(stored.link == "![Original Name](images/Original%20Name.png)")
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}

@Test("storeImageFile: gescheitertes Kopieren lässt keinen leeren images-Ordner zurück")
func store_failedCopyLeavesNoEmptyImagesFolder() throws {
    try withTempDir { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        try "x".write(to: doc, atomically: true, encoding: .utf8)
        // Quelle existiert nicht → `copyItem` wirft. Der Zielordner wird
        // vorher angelegt und muss danach wieder verschwinden: Eine
        // gescheiterte Aktion darf den Dokumentordner nicht sichtbar
        // verändern (Review 2026-08-06).
        let missing = dir.appendingPathComponent("gibtsnicht.png")

        #expect(throws: (any Error).self) {
            _ = try MarkdownImageStore.storeImageFile(missing, documentURL: doc)
        }
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("images").path))
    }
}

@Test("storeImageFile: ein vorhandener images-Ordner bleibt auch im Fehlerfall stehen")
func store_failedCopyKeepsPreexistingImagesFolder() throws {
    try withTempDir { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        try "x".write(to: doc, atomically: true, encoding: .utf8)
        let images = dir.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images,
                                                withIntermediateDirectories: true)
        let missing = dir.appendingPathComponent("gibtsnicht.png")

        #expect(throws: (any Error).self) {
            _ = try MarkdownImageStore.storeImageFile(missing, documentURL: doc)
        }
        #expect(FileManager.default.fileExists(atPath: images.path))
    }
}

// MARK: - Hintergrund-Ablage mehrerer Bilder

@Test("storeImageFiles: sammelt Links und Fehler, ohne beim ersten Fehler aufzugeben")
func storeImageFiles_collectsLinksAndFailures() throws {
    try withTempDir { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        try "x".write(to: doc, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("uploads"), withIntermediateDirectories: true)
        let good = dir.appendingPathComponent("uploads/foto.png")
        try tinyPNG().write(to: good)
        let missing = dir.appendingPathComponent("gibtsnicht.png")

        // Dieser Schritt läuft im Produktivpfad auf einer Hintergrund-Queue
        // (Review 2026-08-06). Er darf deshalb keine Oberfläche anfassen und
        // muss alle Ergebnisse als Rückgabewert liefern — Fehlermeldungen
        // eingeschlossen.
        let outcome = MarkdownAssist.storeImageFiles([missing, good], documentURL: doc)

        #expect(outcome.links == ["![foto](images/foto.png)"])
        #expect(outcome.failures.count == 1)
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("images/foto.png").path))
    }
}

@Test("storeImageData: Aufbereitung und Ablage liefern UI-freies Ergebnis")
func storeImageData_returnsLinkWithoutUI() throws {
    try withTempDir { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        try "x".write(to: doc, atomically: true, encoding: .utf8)

        let outcome = MarkdownAssist.storeImageData(
            tinyPNG(), typeIdentifier: "public.png", documentURL: doc
        )

        #expect(outcome.failures.isEmpty)
        #expect(outcome.links.count == 1)
        #expect(outcome.links[0].hasPrefix("![Seite-"))
    }
}

// MARK: - Drop-Abgrenzung

@Test("partitionDroppedURLs: Bilder → einfügen, alles andere → öffnen")
func partition_dropURLs() throws {
    try withTempDir { dir in
        let image = dir.appendingPathComponent("a.PNG")
        let text = dir.appendingPathComponent("b.txt")
        let folder = dir.appendingPathComponent("ordner", isDirectory: true)
        try tinyPNG().write(to: image)
        try "Text".write(to: text, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)

        let result = MarkdownImageStore.partitionDroppedURLs([image, text, folder])

        #expect(result.insert == [image])
        #expect(result.open == [text, folder])
    }
}

@Test("partitionDroppedURLs: PNG-Ordner wird geöffnet, Bild-Symlink eingefügt")
func partition_dropURLTypesFollowSymlinks() throws {
    try withTempDir { dir in
        let folder = dir.appendingPathComponent("archiv.png", isDirectory: true)
        let image = dir.appendingPathComponent("original.png")
        let symlink = dir.appendingPathComponent("verweis.png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try tinyPNG().write(to: image)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: image)

        let result = MarkdownImageStore.partitionDroppedURLs([folder, symlink])

        #expect(result.insert == [symlink])
        #expect(result.open == [folder])
    }
}

// MARK: - Asynchroner Abschluss

@Test("Bild-Einfügemarke: nur unverändertes Ziel ersetzt die alte Auswahl")
@MainActor
func imageInsertionRange_usesRevisionBoundSelection() {
    let tabID = UUID()
    let initial = MarkdownAssist.ImageInsertionState(
        tabID: tabID, contentRevision: 4, selectionRevision: 7,
        selectedRange: NSRange(location: 3, length: 5)
    )
    #expect(MarkdownAssist.imageInsertionRange(
        initial: initial, current: initial
    ) == NSRange(location: 3, length: 5))

    let edited = MarkdownAssist.ImageInsertionState(
        tabID: tabID, contentRevision: 5, selectionRevision: 8,
        selectedRange: NSRange(location: 12, length: 4)
    )
    #expect(MarkdownAssist.imageInsertionRange(
        initial: initial, current: edited
    ) == NSRange(location: 12, length: 0))

    // Auch zurück an dieselbe sichtbare Range bewegen zählt als Änderung.
    let movedBack = MarkdownAssist.ImageInsertionState(
        tabID: tabID, contentRevision: 4, selectionRevision: 9,
        selectedRange: initial.selectedRange
    )
    #expect(MarkdownAssist.imageInsertionRange(
        initial: initial, current: movedBack
    ) == NSRange(location: 3, length: 0))
}

@Test("DroppedURLCollector liefert Provider-Reihenfolge trotz verdrehter Callbacks")
@MainActor
func droppedURLCollector_preservesProviderOrder() {
    let first = URL(fileURLWithPath: "/tmp/erst.png")
    let second = URL(fileURLWithPath: "/tmp/zweit.png")
    let third = URL(fileURLWithPath: "/tmp/dritt.png")
    var completed: [[URL]] = []
    let collector = DroppedURLCollector(expected: 3) { completed.append($0) }

    collector.add(third, at: 2)
    collector.add(third, at: 2) // Doppel-Callback darf nicht doppelt zählen.
    collector.add(first, at: 0)
    #expect(completed.isEmpty)
    collector.add(second, at: 1)

    #expect(completed == [[first, second, third]])
}
