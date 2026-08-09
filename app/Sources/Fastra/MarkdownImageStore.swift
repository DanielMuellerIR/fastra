// MarkdownImageStore.swift
//
// Bild-Ablage für das assistierte Markdown-Schreiben (Etappe 5 Wunschpaket
// 2026-07b): Pasteboard-Bilddaten und gezogene Bilddateien landen als Datei
// beim Datei-Import im images-Unterordner und werden relativ verlinkt.
//
// Leitplanken: Dateischreibvorgänge sind atomar (bei Abbruch bleibt der
// Ausgangszustand erhalten), beim Kopieren werden Dateiinhalte NIEMALS
// verändert, und ohne Speicherort gibt es keine stille Ablage (der Aufrufer
// zeigt die „erst speichern“-Meldung).

import Foundation
import AppKit
import UniformTypeIdentifiers

enum MarkdownImageStore {

    /// Serialisiert nur die kurze Namenswahl+Veröffentlichung je Zielordner.
    /// Die Registry selbst ist geschützt; verschiedene Dokumentordner
    /// können weiterhin parallel schreiben.
    private final class DirectoryLockRegistry: @unchecked Sendable {
        private let registryLock = NSLock()
        private var locks: [String: NSLock] = [:]

        func withLock<T>(for directory: URL, _ body: () throws -> T) rethrows -> T {
            let key = directory.resolvingSymlinksInPath().standardizedFileURL.path
            registryLock.lock()
            let lock: NSLock
            if let existing = locks[key] {
                lock = existing
            } else {
                let created = NSLock()
                locks[key] = created
                lock = created
            }
            registryLock.unlock()

            lock.lock()
            defer { lock.unlock() }
            return try body()
        }
    }

    private static let directoryLocks = DirectoryLockRegistry()

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
        case invalidImagesDirectory

        var errorDescription: String? {
            switch self {
            case .documentNotSaved:
                return L10n.string("Das Dokument hat noch keinen Speicherort. Bitte erst speichern (⌘S) — dann kann Fastra Bilder daneben ablegen.")
            case .unreadableImage:
                return L10n.string("Die Bilddaten konnten nicht gelesen werden.")
            case .invalidImagesDirectory:
                return L10n.string("„images“ ist kein echter Ordner. Bitte den symbolischen Link oder die Datei umbenennen und erneut versuchen.")
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
        return try directoryLocks.withLock(for: directory) {
            // Namenswahl und atomare Veröffentlichung bilden innerhalb DIESES
            // Dokumentordners einen Schritt. So können zwei gleichzeitige
            // Paste-Vorgänge nicht denselben freien Namen wählen.
            let name = collisionFreeName(base: base,
                                         fileExtension: prepared.fileExtension) {
                fileManager.fileExists(
                    atPath: directory.appendingPathComponent($0).path
                )
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
    }

    /// Kopiert eine Bild-DATEI unverändert in den `images`-Unterordner:
    /// - liegt sie bereits im images-Unterordner → nur verlinken;
    /// - Namenskollision → Suffix, byte-identische Datei → nicht doppeln.
    static func storeImageFile(_ sourceURL: URL,
                               documentURL: URL,
                               fileManager: FileManager = .default)
    throws -> (link: String, fileURL: URL) {
        let documentDirectory = documentURL.deletingLastPathComponent().standardizedFileURL
        let directory = documentDirectory
            .appendingPathComponent("images", isDirectory: true)
            .standardizedFileURL
        let source = sourceURL.standardizedFileURL
        guard let readableSource = regularFileURL(for: source) else {
            throw StoreError.unreadableImage
        }
        let directoryPrefix = directory.path.hasSuffix("/")
            ? directory.path
            : directory.path + "/"

        // `attributesOfItem` beschreibt den Pfad selbst. Ein vorhandenes
        // `images` darf deshalb weder Symlink noch gewöhnliche Datei sein;
        // andernfalls würde das Kopieren unbemerkt außerhalb des
        // Dokumentordners landen.
        let directoryExistedBefore = try ensureRealDirectory(
            directory, fileManager: fileManager
        )

        // Schon im images-Unterordner? Dann NICHT kopieren, nur verlinken.
        if source.path.hasPrefix(directoryPrefix),
           let relative = relativeLinkPath(from: documentURL, to: source) {
            return (markdownImageLink(fileName: source.lastPathComponent,
                                      relativePath: relative), source)
        }

        // Vor dem Anlegen merken, ob es den Ordner schon gab. Scheitert das
        // Kopieren danach (Quelle verschwunden, nicht lesbar), soll die
        // gescheiterte Aktion den Dokumentordner nicht sichtbar verändern —
        // ein leerer neuer `images`-Ordner blieb bisher stehen
        // (Review 2026-08-06).
        var stored = false
        defer {
            // Nur einen von DIESEM Aufruf angelegten und weiterhin leeren
            // Ordner zurücknehmen; fremde Inhalte bleiben unberührt.
            if !stored, !directoryExistedBefore,
               let entries = try? fileManager.contentsOfDirectory(atPath: directory.path),
               entries.isEmpty {
                try? fileManager.removeItem(at: directory)
            }
        }

        let sourceName = source.lastPathComponent
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
                do {
                    try fileManager.copyItem(at: readableSource, to: candidate)
                    guard let relative = relativeLinkPath(
                        from: documentURL, to: candidate
                    ) else {
                        try? fileManager.removeItem(at: candidate)
                        throw StoreError.unreadableImage
                    }
                    stored = true
                    return (markdownImageLink(fileName: candidateName,
                                              relativePath: relative), candidate)
                } catch {
                    // Ein paralleler Vorgang kann den eben noch freien Namen
                    // belegt haben. Nur dann neu suchen; echte Kopierfehler
                    // bleiben sichtbar.
                    guard isFileExistsError(error) else { throw error }
                }
            }
            if contentsEqual(readableSource, candidate, fileManager: fileManager) {
                guard let relative = relativeLinkPath(from: documentURL, to: candidate) else {
                    throw StoreError.unreadableImage
                }
                stored = true
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

    /// Gibt den aufgelösten Pfad nur für eine gewöhnliche Datei zurück.
    private static func regularFileURL(for url: URL) -> URL? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true ? resolved : nil
    }

    /// Legt `directory` bei Bedarf an und bestätigt danach per lstat-artiger
    /// FileManager-Abfrage, dass der Pfad selbst ein echter Ordner ist.
    /// Rückgabe `true` bedeutet: Er war schon vor diesem Aufruf vorhanden.
    private static func ensureRealDirectory(_ directory: URL,
                                            fileManager: FileManager) throws -> Bool {
        let existedBefore: Bool
        do {
            _ = try fileManager.attributesOfItem(atPath: directory.path)
            existedBefore = true
        } catch {
            guard isNoSuchFileError(error) else { throw error }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            existedBefore = false
        }
        let attributes = try fileManager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw StoreError.invalidImagesDirectory
        }
        return existedBefore
    }

    private static func isFileExistsError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == NSFileWriteFileExistsError
    }

    private static func isNoSuchFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSFileNoSuchFileError
                || nsError.code == NSFileReadNoSuchFileError)
    }

    // MARK: - Drop-Abgrenzung (Dateityp)

    /// Teilt gezogene Datei-URLs auf: Bilddateien werden ins Markdown
    /// EINGEFÜGT, alles andere behält das bestehende Verhalten „öffnen“.
    /// Der Typ wird am symlink-aufgelösten Ziel geprüft; ein Bild-Symlink
    /// bleibt damit zulässig, ein Ordner namens `archiv.png` dagegen nicht.
    static func partitionDroppedURLs(_ urls: [URL]) -> (insert: [URL], open: [URL]) {
        var insert: [URL] = []
        var open: [URL] = []
        for url in urls {
            if insertableImageExtensions.contains(url.pathExtension.lowercased()),
               regularFileURL(for: url) != nil {
                insert.append(url)
            } else {
                open.append(url)
            }
        }
        return (insert, open)
    }
}
