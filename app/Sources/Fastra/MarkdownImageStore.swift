// MarkdownImageStore.swift
//
// Bild-Ablage für das assistierte Markdown-Schreiben (Etappe 5 Wunschpaket
// 2026-07b): Pasteboard-Bilddaten und gezogene Bilddateien landen als Datei
// im Dokumentordner und werden relativ verlinkt.
//
// Leitplanken: Dateischreibvorgänge sind atomar (bei Abbruch bleibt der
// Ausgangszustand erhalten), beim Kopieren werden Dateiinhalte NIEMALS
// verändert, und ohne Speicherort gibt es keine stille Ablage (der Aufrufer
// zeigt die „erst speichern“-Meldung).

import Foundation
import AppKit
import UniformTypeIdentifiers

enum MarkdownImageStore {

    /// Bildformate, die beim Einfügen UNVERÄNDERT bleiben. Alles andere
    /// (z. B. TIFF vom System-Screenshot-Pasteboard) wird verlustfrei und
    /// universell als PNG abgelegt.
    static let passthroughExtensions: Set<String> = ["png", "jpg", "jpeg", "gif"]

    /// Dateiendungen, die als Bild-DATEI eingefügt (statt geöffnet) werden.
    /// Deckt sich mit den Vorschau-Formaten der WKWebView-Bildauflösung.
    static let insertableImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff",
    ]

    // MARK: - Pure Namenslogik

    /// Zeitstempel-Name für ROHE Bilddaten: `<dokumentname>-JJJJ-MM-TT-hhmmss`.
    static func pastedImageBaseName(documentName: String, date: Date) -> String {
        let base = (documentName as NSString).deletingPathExtension
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "\(base)-\(formatter.string(from: date))"
    }

    /// Erster freie Name: `base.ext`, dann `base-2.ext`, `base-3.ext`, …
    /// `exists` ist injizierbar → pure testbar.
    static func collisionFreeName(base: String, fileExtension: String,
                                  exists: (String) -> Bool) -> String {
        let first = "\(base).\(fileExtension)"
        guard exists(first) else { return first }
        var counter = 2
        while counter < 10_000 {
            let candidate = "\(base)-\(counter).\(fileExtension)"
            if !exists(candidate) { return candidate }
            counter += 1
        }
        // Praktisch unerreichbar — eindeutiger Notname statt Endlosschleife.
        return "\(base)-\(UUID().uuidString).\(fileExtension)"
    }

    /// Relativer Markdown-Pfad vom Dokument zur Bilddatei. Liegt das Bild
    /// nicht unterhalb des Dokumentordners, wird `nil` geliefert (die
    /// Ablage-Logik sorgt dafür, dass das nie passiert). Leerzeichen,
    /// Umlaute & Co. werden URL-prozent-codiert — cmark/WebKit lösen das
    /// beim Rendern korrekt auf.
    static func relativeLinkPath(from documentURL: URL, to imageURL: URL) -> String? {
        let docDir = documentURL.deletingLastPathComponent().standardizedFileURL
        let image = imageURL.standardizedFileURL
        let dirPrefix = docDir.path.hasSuffix("/") ? docDir.path : docDir.path + "/"
        guard image.path.hasPrefix(dirPrefix) else { return nil }
        let relative = String(image.path.dropFirst(dirPrefix.count))
        return relative.split(separator: "/").map { component in
            String(component).addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "%?#"))
            ) ?? String(component)
        }.joined(separator: "/")
    }

    /// Markdown-Bildlink; Alt-Text ist der Dateiname ohne Endung.
    static func markdownImageLink(fileName: String, relativePath: String) -> String {
        let alt = (fileName as NSString).deletingPathExtension
        return "![\(alt)](\(relativePath))"
    }

    // MARK: - Format-Entscheidung für Pasteboard-Daten

    /// Rohdaten vom Pasteboard: ankommendes Format behalten, wenn es
    /// PNG/JPEG/GIF ist — sonst nach PNG konvertieren.
    struct PreparedImageData {
        let data: Data
        let fileExtension: String
    }

    static func prepare(imageData: Data, typeIdentifier: String) -> PreparedImageData? {
        let type = UTType(typeIdentifier)
        if type?.conforms(to: .png) == true {
            return PreparedImageData(data: imageData, fileExtension: "png")
        }
        if type?.conforms(to: .jpeg) == true {
            return PreparedImageData(data: imageData, fileExtension: "jpg")
        }
        if type?.conforms(to: .gif) == true {
            return PreparedImageData(data: imageData, fileExtension: "gif")
        }
        // Anderes Format (TIFF, HEIC, …) → verlustfrei als PNG ablegen.
        guard let rep = NSBitmapImageRep(data: imageData),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return PreparedImageData(data: png, fileExtension: "png")
    }

    // MARK: - Ablage (IO)

    enum StoreError: LocalizedError {
        case documentNotSaved
        case unreadableImage

        var errorDescription: String? {
            switch self {
            case .documentNotSaved:
                return L10n.string("Das Dokument hat noch keinen Speicherort. Bitte erst speichern (⌘S) — dann kann Fastra Bilder daneben ablegen.")
            case .unreadableImage:
                return L10n.string("Die Bilddaten konnten nicht gelesen werden.")
            }
        }
    }

    /// Legt ROHE Bilddaten als neue Datei neben dem Dokument ab.
    /// Rückgabe: Markdown-Link + Ziel-URL.
    static func storePastedData(_ prepared: PreparedImageData,
                                documentURL: URL,
                                now: Date = Date(),
                                fileManager: FileManager = .default)
    throws -> (link: String, fileURL: URL) {
        let directory = documentURL.deletingLastPathComponent()
        let base = pastedImageBaseName(documentName: documentURL.lastPathComponent,
                                       date: now)
        let name = collisionFreeName(base: base, fileExtension: prepared.fileExtension) {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        let target = directory.appendingPathComponent(name)
        // Atomar: erst vollständig schreiben, dann sichtbar werden.
        try prepared.data.write(to: target, options: .atomic)
        guard let relative = relativeLinkPath(from: documentURL, to: target) else {
            // Kann konstruktionsbedingt nicht passieren — defensiv aufräumen.
            try? fileManager.removeItem(at: target)
            throw StoreError.unreadableImage
        }
        return (markdownImageLink(fileName: name, relativePath: relative), target)
    }

    /// Kopiert eine Bild-DATEI unverändert in den Dokumentordner:
    /// - liegt sie bereits unterhalb des Dokumentordners → nur verlinken;
    /// - Namenskollision → Suffix, byte-identische Datei → nicht doppeln.
    static func storeImageFile(_ sourceURL: URL,
                               documentURL: URL,
                               fileManager: FileManager = .default)
    throws -> (link: String, fileURL: URL) {
        let directory = documentURL.deletingLastPathComponent().standardizedFileURL

        // Schon im Dokumentbaum? Dann NICHT kopieren, nur verlinken.
        if let relative = relativeLinkPath(from: documentURL, to: sourceURL) {
            return (markdownImageLink(fileName: sourceURL.lastPathComponent,
                                      relativePath: relative), sourceURL)
        }

        let sourceName = sourceURL.lastPathComponent
        let base = (sourceName as NSString).deletingPathExtension
        let fileExtension = (sourceName as NSString).pathExtension

        // Kandidaten in Suffix-Reihenfolge: vorhandene byte-identische Datei
        // wird wiederverwendet, sonst der erste freie Name.
        var counter = 1
        while counter < 10_000 {
            let candidateName = counter == 1
                ? sourceName
                : "\(base)-\(counter).\(fileExtension)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                // `copyItem` verändert Inhalte nie; bei Abbruch bleibt die
                // Quelle unangetastet und das Ziel existiert nicht halb —
                // FileManager kopiert auf APFS über einen Klon/Temp-Pfad.
                try fileManager.copyItem(at: sourceURL, to: candidate)
                guard let relative = relativeLinkPath(from: documentURL, to: candidate) else {
                    try? fileManager.removeItem(at: candidate)
                    throw StoreError.unreadableImage
                }
                return (markdownImageLink(fileName: candidateName,
                                          relativePath: relative), candidate)
            }
            if contentsEqual(sourceURL, candidate, fileManager: fileManager) {
                guard let relative = relativeLinkPath(from: documentURL, to: candidate) else {
                    throw StoreError.unreadableImage
                }
                return (markdownImageLink(fileName: candidateName,
                                          relativePath: relative), candidate)
            }
            counter += 1
        }
        throw StoreError.unreadableImage
    }

    /// Byte-Vergleich zweier Dateien (Größe zuerst — billiger Kurzschluss).
    static func contentsEqual(_ a: URL, _ b: URL,
                              fileManager: FileManager = .default) -> Bool {
        fileManager.contentsEqual(atPath: a.path, andPath: b.path)
    }

    // MARK: - Drop-Abgrenzung (pure)

    /// Teilt gezogene Datei-URLs auf: Bilddateien werden ins Markdown
    /// EINGEFÜGT, alles andere behält das bestehende Verhalten „öffnen“.
    static func partitionDroppedURLs(_ urls: [URL]) -> (insert: [URL], open: [URL]) {
        var insert: [URL] = []
        var open: [URL] = []
        for url in urls {
            if insertableImageExtensions.contains(url.pathExtension.lowercased()) {
                insert.append(url)
            } else {
                open.append(url)
            }
        }
        return (insert, open)
    }
}
