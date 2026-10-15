// MarkdownImageStoreTests.swift
//
// Tests für die Bild-Ablage des Markdown-Assistenten (Etappe 5 Wunschpaket
// 2026-07b): Namensvergabe, Kollisions- und Dedup-Logik, Relativpfade
// (Umlaute, Leerzeichen, Unterordner) und die Drop-Abgrenzung.

import Foundation
import AppKit
import Testing
import CodeEditTextView
import Darwin
@testable import Fastra

private func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = testTemporaryDirectory()
        .appendingPathComponent("fastra-mdimage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

@MainActor
private func withImageUndoDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = testTemporaryDirectory().appendingPathComponent("fastra-image-undo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

@MainActor
private func awaitImageHistory(_ view: TextView) async throws {
    try #require(await waitUntil { view.undoManager?.isUndoing != true && view.undoManager?.isRedoing != true })
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

@Test("Bildnamen bleiben kurz und erweitern sich kollisionsfrei")
func pastedName_format() {
    #expect(MarkdownImageStore.shortImageName(counter: 1, fileExtension: "PNG") == "1.png")
    #expect(MarkdownImageStore.shortImageName(counter: 35, fileExtension: "png") == "z.png")
    #expect(MarkdownImageStore.shortImageName(counter: 36, fileExtension: "jpg") == "10.jpg")
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

@Test("storePastedData: Datei entsteht im images-Unterordner, Link ist relativ")
func store_pastedData() throws {
    try withTempDir { dir in
        let doc = dir.appendingPathComponent("Notizen.md")
        try "x".write(to: doc, atomically: true, encoding: .utf8)
        let prepared = MarkdownImageStore.PreparedImageData(data: tinyPNG(),
                                                            fileExtension: "png")
        let stored = try MarkdownImageStore.storePastedData(prepared, documentURL: doc)
        #expect(FileManager.default.fileExists(atPath: stored.fileURL.path))
        #expect(stored.fileURL.deletingLastPathComponent().path
                == dir.appendingPathComponent("images").path)
        #expect(stored.link.hasPrefix("![1]"))
        #expect(stored.link.contains("](images/"))
        #expect(stored.link.hasSuffix(".png)"))
        #expect(stored.createdByInsertion)
        #expect(stored.imagesDirectoryCreated)
    }
}

@Test("storePastedData: parallele Ablagen erhalten verschiedene Suffixnamen")
func store_parallelPastedDataUsesSuffix() async throws {
    let dir = testTemporaryDirectory()
        .appendingPathComponent("fastra-mdimage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let doc = dir.appendingPathComponent("Notizen.md")
    try "x".write(to: doc, atomically: true, encoding: .utf8)
    let prepared = MarkdownImageStore.PreparedImageData(data: tinyPNG(),
                                                        fileExtension: "png")

    let names = await withTaskGroup(of: String.self, returning: [String].self) { group in
        for _ in 0..<2 {
            group.addTask {
                do {
                    return try MarkdownImageStore.storePastedData(
                        prepared, documentURL: doc
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

    #expect(Set(names) == ["1.png", "2.png"])
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
            prepared, documentURL: doc,
            hooks: .init(beforePublishing: { target in
                guard !insertedCollision else { return }
                insertedCollision = true
                try? Data("fremd".utf8).write(to: target, options: .withoutOverwriting)
            }))

        #expect(try Data(contentsOf: dir.appendingPathComponent("images/1.png"))
                == Data("fremd".utf8))
        #expect(stored.fileURL.lastPathComponent == "2.png")
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
            prepared, documentURL: document)

        #expect(stored.link == MarkdownImageStore.markdownImageLink(
            fileName: stored.fileURL.lastPathComponent,
            relativePath: "images/\(stored.fileURL.lastPathComponent)"))
        #expect(stored.fileURL.deletingLastPathComponent().standardizedFileURL.path
                == real.appendingPathComponent("images").standardizedFileURL.path)
    }
}

@Test("storeImageFile: Jede Einfügung erhält auch bei gleichen Bytes eine eigene Nummer")
func store_fileCollisionAndIndependentCopies() throws {
    try withTempDir { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        try "x".write(to: doc, atomically: true, encoding: .utf8)
        // Quelle außerhalb des Dokumentordners.
        let outside = testTemporaryDirectory()
            .appendingPathComponent("fastra-mdimage-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let source = outside.appendingPathComponent("foto.png")
        try tinyPNG().write(to: source)

        // 1. Kopie: erste freie Nummer.
        let first = try MarkdownImageStore.storeImageFile(source, documentURL: doc)
        #expect(first.fileURL.lastPathComponent == "1.png")
        #expect(first.fileURL.deletingLastPathComponent().lastPathComponent == "images")
        #expect(first.link == "![1](images/1.png)")
        #expect(first.createdByInsertion)

        // 2. Dieselben Bytes gehören zu einer neuen Einfügung.
        let again = try MarkdownImageStore.storeImageFile(source, documentURL: doc)
        #expect(again.fileURL.lastPathComponent == "2.png")
        #expect(again.createdByInsertion)
        let files = try FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent("images").path
        )
            .filter { $0.hasSuffix(".png") }
        #expect(Set(files) == ["1.png", "2.png"])

        // 3. Andere Bytes erhalten ebenfalls die nächste freie Nummer.
        let source2 = outside.appendingPathComponent("v2/foto.png")
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("v2"),
                                                withIntermediateDirectories: true)
        var other = tinyPNG()
        other.append(Data([0x00]))   // andere Bytes
        try other.write(to: source2)
        let suffixed = try MarkdownImageStore.storeImageFile(source2, documentURL: doc)
        #expect(suffixed.fileURL.lastPathComponent == "3.png")
    }
}

@Test("storeImageFile: parallele Namenskollision wird per Suffix aufgelöst")
func store_parallelFileCollisionUsesSuffix() async throws {
    let dir = testTemporaryDirectory()
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

    #expect(Set(names) == ["1.png", "2.png"])
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
        #expect(try Data(contentsOf: dir.appendingPathComponent("images/1.png"))
                == Data("fremd".utf8))
        #expect(stored.fileURL.lastPathComponent == "2.png")
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
        #expect(stored.fileURL == images.appendingPathComponent("1.png"))
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

@Test("storeImageFile: Lange Namen auch innerhalb von images kürzen; Quelle erhalten")
func store_fileInsideImagesLinksOnly() throws {
    try withTempDir { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        try "x".write(to: doc, atomically: true, encoding: .utf8)
        let sub = dir.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let existing = sub.appendingPathComponent("logo.png")
        try tinyPNG().write(to: existing)

        let stored = try MarkdownImageStore.storeImageFile(existing, documentURL: doc)
        #expect(stored.fileURL == sub.appendingPathComponent("1.png"))
        #expect(stored.link == "![1](images/1.png)")
        #expect(stored.createdByInsertion)
        #expect(FileManager.default.fileExists(atPath: existing.path))
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
            "images/1.png"
        ).path)
        #expect(stored.link == "![1](images/1.png)")
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

        #expect(outcome.links == ["![1](images/1.png)"])
        #expect(outcome.failures.count == 1)
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("images/1.png").path))
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
        #expect(outcome.links[0].hasPrefix("![1]"))
        #expect(outcome.links[0].contains("](images/"))
        #expect(outcome.storedImages[0].createdByInsertion)
        #expect(outcome.storedImages[0].fileURL.deletingLastPathComponent()
            .lastPathComponent == "images")
    }
}

@Test("Bild-Undo hält entfernte Bytes im RAM; Redo stellt sie ohne Sicherungsordner wieder her")
@MainActor
func imageUndoMovesCreatedFileAndRestoresOnRedo() async throws {
    try await withImageUndoDirectory { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        try "".write(to: doc, atomically: true, encoding: .utf8)
        let stored = try MarkdownImageStore.storePastedData(
            .init(data: tinyPNG(), fileExtension: "png"), documentURL: doc
        )
        let textView = TextView(string: "")
        textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: stored.link)
        MarkdownImageUndo.register(textView: textView, insertion: stored.link,
                                   storedImages: [stored])

        textView.undoManager?.undo()
        try await awaitImageHistory(textView)
        #expect(textView.string.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: stored.fileURL.path))

        textView.undoManager?.redo()
        try await awaitImageHistory(textView)
        #expect(textView.string == stored.link)
        #expect(FileManager.default.fileExists(atPath: stored.fileURL.path))
    }
}

@Test("Bild-Undo gehört zur konkreten Einfügung, auch wenn derselbe Link schon vorkommt")
@MainActor
func imageUndoWithDuplicateLinkKeepsReferencedFile() async throws {
    try await withImageUndoDirectory { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        try "".write(to: doc, atomically: true, encoding: .utf8)
        let stored = try MarkdownImageStore.storePastedData(
            .init(data: tinyPNG(), fileExtension: "png"), documentURL: doc
        )
        let textView = TextView(string: stored.link)
        (textView.undoManager as? CEUndoManager)?.clearStack()
        textView.replaceCharacters(
            in: NSRange(location: (textView.string as NSString).length, length: 0),
            with: "\n" + stored.link
        )
        MarkdownImageUndo.register(textView: textView, insertion: stored.link,
                                   storedImages: [stored], documentURL: doc)

        textView.undoManager?.undo()
        try await awaitImageHistory(textView)
        #expect(textView.string == stored.link)
        #expect(FileManager.default.fileExists(atPath: stored.fileURL.path), "Ein weiterhin sichtbarer Link schützt seine Bilddatei")

        // Ein neuer Edit verwirft Redo; der verbleibende Bildlink bleibt gültig.
        textView.replaceCharacters(
            in: NSRange(location: (textView.string as NSString).length, length: 0),
            with: "!"
        )
        let hidden = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".fastra-image-undo-") }
        #expect(hidden.isEmpty)
    }
}

@Test("Bild-Undo bleibt von Quelle, Ordnername und reinen Metadaten unabhängig",
      arguments: ["source-removed", "folder-moved", "metadata"])
func imageUndoSurvivesDocumentChanges(_ change: String) throws {
    try withTempDir { root in
        let directory = root.appendingPathComponent("document")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let doc = directory.appendingPathComponent("test.md")
        let source = root.appendingPathComponent("source.png")
        let bytes = tinyPNG()
        try bytes.write(to: source)
        let stored = try MarkdownImageStore.storeImageFile(source, documentURL: doc)
        let effect = MarkdownImageUndoSideEffect(images: [stored])
        var currentDirectory = directory
        switch change {
        case "source-removed": try FileManager.default.removeItem(at: source)
        case "folder-moved":
            currentDirectory = root.appendingPathComponent("renamed")
            try FileManager.default.moveItem(at: directory, to: currentDirectory)
        default:
            let data = Data("metadata".utf8)
            try #require(data.withUnsafeBytes {
                setxattr(stored.fileURL.path, "com.example.fastra.test", $0.baseAddress, $0.count, 0, 0)
            } == 0)
        }
        #expect(effect.undo(), "Undo nach \(change)")
        let copy = currentDirectory.appendingPathComponent("images/1.png")
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(effect.redo(), "Redo nach \(change)")
        #expect(try Data(contentsOf: copy) == bytes)
    }
}

@Test("Bild-Undo verschiebt keine in-place geänderte Datei mit zurückgesetztem mtime")
@MainActor
func imageUndoRejectsChangedFileWithRestoredModificationDate() async throws {
    try await withImageUndoDirectory { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        try "".write(to: doc, atomically: true, encoding: .utf8)
        let stored = try MarkdownImageStore.storePastedData(
            .init(data: tinyPNG(), fileExtension: "png"), documentURL: doc
        )
        let textView = TextView(string: "")
        textView.replaceCharacters(
            in: NSRange(location: 0, length: 0), with: stored.link
        )
        MarkdownImageUndo.register(textView: textView, insertion: stored.link,
                                   storedImages: [stored])

        let originalDate = try #require(FileManager.default.attributesOfItem(
            atPath: stored.fileURL.path
        )[.modificationDate] as? Date)
        var changed = try Data(contentsOf: stored.fileURL)
        changed[changed.startIndex] ^= 0x01
        Thread.sleep(forTimeInterval: 0.01)
        let handle = try FileHandle(forWritingTo: stored.fileURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: changed)
        try handle.synchronize()
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate], ofItemAtPath: stored.fileURL.path
        )

        textView.undoManager?.undo()
        try await awaitImageHistory(textView)

        #expect(textView.string.isEmpty)
        #expect(FileManager.default.fileExists(atPath: stored.fileURL.path),
                "ctime muss die inzwischen geänderte Nutzerversion schützen")
    }
}

// MARK: - Drop-Abgrenzung

@Test("Drag-Hover entscheidet nur anhand deklarierter Pasteboard-Typen")
@MainActor
func imageDropHoverChecksTypesWithoutReadingPayload() {
    #expect(MarkdownAssist.canHandleImageDrop(types: [.fileURL]))
    #expect(MarkdownAssist.canHandleImageDrop(types: [
        NSPasteboard.PasteboardType("public.png")
    ]))
    #expect(!MarkdownAssist.canHandleImageDrop(types: [.string]))
}

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


@Test("Aktive Bild-Undo-Schritte schützen die eigene Datei und freie Redo-Namen")
func imageUndoReservesOwnershipAndStashedName() throws {
    try withTempDir { directory in
        let source = directory.appendingPathComponent("source.png")
        let bytes = tinyPNG()
        try bytes.write(to: source)
        let first = try MarkdownImageStore.storeImageFile(source, documentURL: directory.appendingPathComponent("a.md"))
        let effect = MarkdownImageUndoSideEffect(images: [first])
        defer { effect.discard() }
        let second = try MarkdownImageStore.storeImageFile(source, documentURL: directory.appendingPathComponent("b.md"))
        #expect(second.createdByInsertion)
        #expect(second.fileURL != first.fileURL)
        #expect(effect.undo())
        #expect(!FileManager.default.fileExists(atPath: first.fileURL.path))
        #expect(try Data(contentsOf: second.fileURL) == bytes)
        let third = try MarkdownImageStore.storePastedData(.init(data: bytes, fileExtension: "png"), documentURL: directory.appendingPathComponent("b.md"))
        #expect(third.fileURL != first.fileURL)
        #expect(effect.redo())
        #expect(try Data(contentsOf: first.fileURL) == bytes)
        #expect(effect.undo())
        effect.discard()
        let fourth = try MarkdownImageStore.storePastedData(.init(data: bytes, fileExtension: "png"), documentURL: directory.appendingPathComponent("b.md"))
        #expect(fourth.fileURL == first.fileURL)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".fastra-image-undo-") })
    }
}

@Test("Bild-Redo bewahrt Text und fremde Datei bei Kollision und bleibt wiederholbar")
@MainActor
func imageRedoCollisionKeepsTextAndRetry() async throws {
    try await withImageUndoDirectory { dir in
        let doc = dir.appendingPathComponent("Seite.md")
        let stored = try MarkdownImageStore.storePastedData(
            .init(data: tinyPNG(), fileExtension: "png"), documentURL: doc)
        let textView = TextView(string: "")
        textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: stored.link)
        MarkdownImageUndo.register(textView: textView, insertion: stored.link, storedImages: [stored])
        textView.undoManager?.undo()
        try await awaitImageHistory(textView)
        try FileManager.default.createDirectory(at: stored.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("foreign".utf8).write(to: stored.fileURL)
        textView.undoManager?.redo()
        try await awaitImageHistory(textView)
        #expect(textView.string.isEmpty)
        #expect(textView.undoManager?.canRedo == true)
        #expect(try Data(contentsOf: stored.fileURL) == Data("foreign".utf8))
        try FileManager.default.removeItem(at: stored.fileURL)
        textView.undoManager?.redo()
        try await awaitImageHistory(textView)
        #expect(textView.string == stored.link)
        #expect(try Data(contentsOf: stored.fileURL) == tinyPNG())
    }
}

@Test("Abgewiesener Redo rollt nur vorbereitete Nebenwirkungen zurück")
@MainActor
func redoPreflightRollsBackOnlyPreparations() {
    let textView = TextView(string: "")
    textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Link")
    let manager = textView.undoManager as! CEUndoManager
    var genericUndo = 0, prepared = false, permitted = false
    manager.fastraRegisterSideEffectForLatestUndo(undo: { genericUndo += 1 }, redo: {}, discard: {})
    manager.fastraRegisterSideEffectForLatestUndo(undo: {}, redo: {}, prepareRedo: { prepared = true; return true }, cancelPreparedRedo: { prepared = false }, discard: {})
    manager.fastraRegisterSideEffectForLatestUndo(undo: {}, redo: {}, prepareRedo: { permitted }, discard: {})
    manager.undo()
    manager.redo()
    #expect(textView.string.isEmpty && manager.canRedo)
    #expect(genericUndo == 1 && !prepared)
    permitted = true
    manager.redo()
    #expect(textView.string == "Link" && prepared)
}

@Test("Gespeicherte Bilder bleiben bis zum Speichern erhalten und lassen sich danach zurückholen")
func savedImageDeletionWaitsForSave() throws {
    try withTempDir { directory in
        let doc = directory.appendingPathComponent("test.md")
        let stored = try MarkdownImageStore.storePastedData(.init(data: tinyPNG(), fileExtension: "png"), documentURL: doc)
        let effect = MarkdownImageUndoSideEffect(images: [stored], alreadySaved: true)
        #expect(effect.undo())
        #expect(FileManager.default.fileExists(atPath: stored.fileURL.path))
        #expect(effect.documentSaved(visible: false))
        #expect(!FileManager.default.fileExists(atPath: stored.fileURL.path))
        #expect(effect.redo())
        #expect(try Data(contentsOf: stored.fileURL) == tinyPNG())
    }
}

@Test("Aufräumen schützt echte Bildreferenzen, andere Dokumente und veränderte Vorschauen")
func cleanupProtectsSharedImagesAndPreview() throws {
    try withTempDir { directory in
        let doc = directory.appendingPathComponent("test.md")
        let other = directory.appendingPathComponent("other.md")
        try "".write(to: doc, atomically: true, encoding: .utf8)
        let first = try MarkdownImageStore.storePastedData(.init(data: tinyPNG(), fileExtension: "png"), documentURL: doc)
        let second = try MarkdownImageStore.storePastedData(.init(data: tinyPNG(), fileExtension: "png"), documentURL: doc)
        try "![shared](images/1.png)".write(to: other, atomically: true, encoding: .utf8)
        let preview = try MarkdownImageCleanup.plan(documentURL: doc, content: "", openDocuments: [:])
        #expect(preview.candidates.map { $0.fileURL.canonicalFileURL } == [second.fileURL.canonicalFileURL])
        let opened = try MarkdownImageCleanup.plan(documentURL: doc, content: "", openDocuments: [other: [
            "![x][ref]\n\n[ref]: images/1.png", "![x][ref]\n\n[ref]: images/2.png"
        ]])
        #expect(opened.candidates.isEmpty)

        try "![shared](images/1.png)\n![new](images/2.png)".write(to: other, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try MarkdownImageCleanup.apply(preview) }
        #expect(FileManager.default.fileExists(atPath: second.fileURL.path))
        try "![shared](images/1.png)".write(to: other, atomically: true, encoding: .utf8)
        try MarkdownImageCleanup.apply(preview)
        #expect(FileManager.default.fileExists(atPath: first.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: second.fileURL.path))
    }
}

@Test("Aufräumen erhält Quellreferenzen trotz Vorschaufiltern", arguments: [
    "![Logo](images/logo.svg)",
    "<img src=\"images/logo.png\" style=\"width:100px\">",
    "<img src=images/logo.png>",
    "![Logo][ref]\n\n[ref]: images/logo.png",
    "[Download](images/logo.png)",
    "<object data=\"images/logo.png\" type=\"image/png\"></object>",
    "<object data=images/logo.png type=image/png></object>",
    "<object data=\"logo.png\" codebase=\"images/\" type=\"image/png\"></object>",
    "<picture><source srcset=\"images/logo.png 1x, images/other.png 2x\"></picture>"
])
func cleanupProtectsSourceReferences(_ source: String) throws {
    try withTempDir { directory in
        let doc = directory.appendingPathComponent("test.md")
        let other = directory.appendingPathComponent("other.md")
        let images = directory.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let svg = images.appendingPathComponent("logo.svg")
        let png = images.appendingPathComponent("logo.png")
        let unused = images.appendingPathComponent("unused.png")
        try Data("<svg/>".utf8).write(to: svg)
        try tinyPNG().write(to: png)
        try tinyPNG().write(to: unused)
        try source.write(to: doc, atomically: true, encoding: .utf8)
        let preview = try MarkdownImageCleanup.plan(documentURL: doc, content: source, openDocuments: [:])
        #expect(!preview.candidates.contains { $0.fileURL == png && source.contains("logo.png") || $0.fileURL == svg })
        try MarkdownImageCleanup.apply(preview)
        #expect(FileManager.default.fileExists(atPath: svg.path))
        if source.contains("logo.png") { #expect(FileManager.default.fileExists(atPath: png.path)) }
        // Auch gespeicherte Nachbardokumente und ihre offenen Fassungen schützen Bilder.
        try source.write(to: other, atomically: true, encoding: .utf8)
        try "".write(to: doc, atomically: true, encoding: .utf8)
        let shared = try MarkdownImageCleanup.plan(documentURL: doc, content: "", openDocuments: [other: [source]])
        #expect(!shared.candidates.contains { $0.fileURL == png && source.contains("logo.png") || $0.fileURL == svg })
    }
}

@Test("Prozentzeichen schützen Bildreferenzen in Dokument, Nachbardatei und Undo",
      arguments: ["100%.png", "100%25.png"])
func cleanupProtectsPercentReferences(_ destination: String) throws {
    try withTempDir { directory in
        let doc = directory.appendingPathComponent("test.md")
        let other = directory.appendingPathComponent("other.md")
        let images = directory.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let image = images.appendingPathComponent("100%.png")
        let unused = images.appendingPathComponent("unused.png")
        try tinyPNG().write(to: image)
        try tinyPNG().write(to: unused)
        let source = "![image](images/\(destination))"
        try source.write(to: doc, atomically: true, encoding: .utf8)
        let preview = try MarkdownImageCleanup.plan(documentURL: doc, content: source, openDocuments: [:])
        #expect(preview.candidates.map { $0.fileURL.canonicalFileURL } == [unused.canonicalFileURL])
        try MarkdownImageCleanup.apply(preview)
        #expect(try Data(contentsOf: image) == tinyPNG())

        try "".write(to: doc, atomically: true, encoding: .utf8)
        try source.write(to: other, atomically: true, encoding: .utf8)
        #expect(try MarkdownImageCleanup.plan(documentURL: doc, content: "", openDocuments: [:]).candidates.isEmpty)
        try FileManager.default.removeItem(at: other)
        #expect(try MarkdownImageCleanup.plan(documentURL: doc, content: "", openDocuments: [other: [source]]).candidates.isEmpty)

        let stored = try MarkdownImageStore.captureExisting(image)
        let effect = MarkdownImageUndoSideEffect(images: [stored])
        #expect(effect.undo(usedImages: MarkdownImageCleanup.references(source, documentURL: doc)))
        #expect(FileManager.default.fileExists(atPath: image.path))
    }
}

@Test("Bild-Undo erhält Finder-Tags, Rechte und Änderungsdatum unabhängig von der umask")
func imageUndoPreservesMetadata() throws {
    try withTempDir { directory in
        let doc = directory.appendingPathComponent("test.md")
        let stored = try MarkdownImageStore.storePastedData(.init(data: tinyPNG(), fileExtension: "png"), documentURL: doc)
        let tag = try PropertyListEncoder().encode(["Review\n6"])
        let name = "com.apple.metadata:_kMDItemUserTags"
        let assigned = tag.withUnsafeBytes { setxattr(stored.fileURL.path, name, $0.baseAddress, $0.count, 0, 0) }
        try #require(assigned == 0)
        try #require(chmod(stored.fileURL.path, 0o664) == 0)
        let acl = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:deny:write\n"))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        try #require(acl_set_file(stored.fileURL.path, ACL_TYPE_EXTENDED, acl) == 0)
        var original = stat()
        try #require(lstat(stored.fileURL.path, &original) == 0)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: stored.fileURL.path)
        let image = try MarkdownImageStore.captureExisting(stored.fileURL)
        let files = MarkdownImageUndoFiles(images: [image])
        try #require(files.removeForUndo())
        #expect(!FileManager.default.fileExists(atPath: image.fileURL.path))
        // Der Runner setzt selbst umask 077; der Test verändert keinen prozessweiten Zustand.
        try #require(files.restoreFromMemory())
        let attributes = try FileManager.default.attributesOfItem(atPath: image.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o664)
        #expect(attributes[.modificationDate] as? Date == date)
        var restored = Data(count: tag.count)
        let count = restored.withUnsafeMutableBytes { getxattr(image.fileURL.path, name, $0.baseAddress, $0.count, 0, 0) }
        #expect(count == tag.count)
        #expect(restored == tag)
        #expect(try Data(contentsOf: image.fileURL) == tinyPNG())
        let restoredACL = try #require(acl_get_file(image.fileURL.path, ACL_TYPE_EXTENDED))
        defer { acl_free(UnsafeMutableRawPointer(restoredACL)) }
        let aclText = try #require(acl_to_text(acl, nil))
        defer { acl_free(aclText) }
        let restoredText = try #require(acl_to_text(restoredACL, nil))
        defer { acl_free(restoredText) }
        #expect(String(cString: restoredText) == String(cString: aclText))
        var actual = stat()
        try #require(lstat(image.fileURL.path, &actual) == 0)
        #expect(actual.st_uid == original.st_uid)
        #expect(actual.st_gid == original.st_gid)
    }
}

@Test("Nicht restaurierbare geerbte Zugriffsregeln verhindern das Entfernen")
func imageUndoRejectsUnrestorableMetadata() throws {
    try withTempDir { directory in
        let doc = directory.appendingPathComponent("test.md")
        let image = try MarkdownImageStore.storePastedData(.init(data: tinyPNG(), fileExtension: "png"), documentURL: doc)
        let tag = Data("tag".utf8)
        try #require(tag.withUnsafeBytes {
            setxattr(image.fileURL.path, "com.example.fastra-test", $0.baseAddress, $0.count, 0, 0)
        } == 0)
        // Nur neu angelegte Dateien erben die Sperre; das Original bleibt lesbar.
        let acl = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:deny,only_inherit,file_inherit:writeextattr\n"))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let images = image.fileURL.deletingLastPathComponent()
        try #require(acl_set_file(images.path, ACL_TYPE_EXTENDED, acl) == 0)
        let buffer = MarkdownImageUndoBuffer(byteLimit: 1024 * 1024)
        let files = MarkdownImageUndoFiles(images: [image], buffer: buffer)
        #expect(!files.removeForUndo())
        #expect(try Data(contentsOf: image.fileURL) == tinyPNG())
        #expect(buffer.byteCount == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: images.path) == [image.fileURL.lastPathComponent])
    }
}

@Test("Absolute Bildverweise und mehrdeutige Quellen fremder offener Dokumente schützen die Bereinigung")
func cleanupProtectsAbsoluteAndOpaqueReferences() throws {
    try withTempDir { directory in
        let doc = directory.appendingPathComponent("test.md")
        try "".write(to: doc, atomically: true, encoding: .utf8)
        let image = try MarkdownImageStore.storePastedData(.init(data: tinyPNG(), fileExtension: "png"), documentURL: doc)
        for path in [image.fileURL.path, image.fileURL.absoluteString] {
            let source = "![image](<\(path)>)"
            let preview = try MarkdownImageCleanup.plan(documentURL: doc, content: source, openDocuments: [:])
            #expect(preview.candidates.isEmpty)
        }
        let foreign = directory.appendingPathComponent("elsewhere/note.md")
        let preview = try MarkdownImageCleanup.plan(documentURL: doc, content: "",
            openDocuments: [foreign: ["<img srcset=\"../images/1.png 1x\">"]])
        #expect(preview.candidates.isEmpty)
    }
}

@Test("Erweiterte Attribute zählen zum gemeinsamen Bild-Undo-Budget")
func imageMetadataCountsAgainstBudget() throws {
    try withTempDir { directory in
        let doc = directory.appendingPathComponent("test.md")
        let image = try MarkdownImageStore.storePastedData(.init(data: tinyPNG(), fileExtension: "png"), documentURL: doc)
        let metadata = Data(repeating: 65, count: 2048)
        try #require(metadata.withUnsafeBytes {
            setxattr(image.fileURL.path, "com.example.fastra-test", $0.baseAddress, $0.count, 0, 0)
        } == 0)
        let buffer = MarkdownImageUndoBuffer(byteLimit: Int(image.identity.size) + 512)
        var invalidated = false
        let files = MarkdownImageUndoFiles(images: [image], buffer: buffer, invalidated: { invalidated = true })
        try #require(files.removeForUndo())
        #expect(buffer.byteCount == 0)
        #expect(!files.restoreFromMemory())
        buffer.takeInvalidations().forEach { $0() }
        #expect(invalidated)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}

@Test("Mehrdeutige HTML-Quellen schützen auch Bilder nach dem Referenzscan")
func opaqueReferencesProtectFutureImages() throws {
    try withTempDir { directory in
        let doc = directory.appendingPathComponent("test.md")
        let references = MarkdownImageCleanup.references("<img srcset=\"images/future.png 1x\">", documentURL: doc)
        let image = try MarkdownImageStore.storePastedData(.init(data: tinyPNG(), fileExtension: "png"), documentURL: doc)
        let effect = MarkdownImageUndoSideEffect(images: [image])
        #expect(effect.undo(usedImages: references))
        #expect(FileManager.default.fileExists(atPath: image.fileURL.path))
    }
}
