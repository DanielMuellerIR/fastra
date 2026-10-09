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
import Darwin

enum MarkdownImageStore {
    struct StoredFileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let statusChangeSeconds: Int64
        let statusChangeNanoseconds: Int64
    }

    /// Ergebnis einer Bildablage. Nur `createdByInsertion == true` darf beim
    /// Rückgängig-Machen des zugehörigen Markdown-Links angefasst werden.
    struct StoredImage: Sendable {
        let link: String
        let fileURL: URL
        let createdByInsertion: Bool
        let imagesDirectoryCreated: Bool
        let identity: StoredFileIdentity
    }

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
    private static let reservationLock = NSLock()
    private static var reservedPaths: [String: Int] = [:]

    private static func isReserved(_ url: URL) -> Bool {
        reservationLock.lock()
        defer { reservationLock.unlock() }
        return reservedPaths[url.standardizedFileURL.path, default: 0] > 0
    }

    static func releaseReservations(_ images: [StoredImage]) {
        reservationLock.lock()
        defer { reservationLock.unlock() }
        for image in images {
            let key = image.fileURL.standardizedFileURL.path
            let remaining = reservedPaths[key, default: 0] - 1
            reservedPaths[key] = remaining > 0 ? remaining : nil
        }
    }

    static func reserveForUndo(_ images: [StoredImage]) {
        for image in images { reserve(image) }
    }

    private static func reserve(_ image: StoredImage) {
        reservationLock.lock()
        defer { reservationLock.unlock() }
        reservedPaths[image.fileURL.standardizedFileURL.path, default: 0] += 1
    }

    /// Dateiendungen, die als Bild-DATEI eingefügt (statt geöffnet) werden.
    /// Deckt sich mit den Vorschau-Formaten der WKWebView-Bildauflösung.
    static let insertableImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff",
    ]

    // MARK: - Pure Namenslogik

    /// Kurze Namen in Basis 36: 1…9, a…z, 10… . Der exklusive
    /// Dateiaustausch im Ablagepfad entscheidet über jede Kollision.
    static func shortImageName(counter: Int, fileExtension: String) -> String {
        "\(String(counter, radix: 36)).\(fileExtension.lowercased())"
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
                withAllowedCharacters: .urlPathAllowed.subtracting(
                    CharacterSet(charactersIn: "%?#()<>[]\\:")
                )
            ) ?? String(component)
        }.joined(separator: "/")
    }

    /// Markdown-Bildlink; Alt-Text ist der Dateiname ohne Endung.
    static func markdownImageLink(fileName: String, relativePath: String) -> String {
        let alt = (fileName as NSString).deletingPathExtension
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
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
                return L10n.string("Das Dokument hat noch keinen Speicherort. Bitte erst speichern (⌘S) — dann kann Fastra Bilder im Unterordner „images“ ablegen.")
            case .unreadableImage:
                return L10n.string("Die Bilddaten konnten nicht gelesen werden.")
            case .invalidImagesDirectory:
                return L10n.string("„images“ ist kein echter Ordner. Bitte den symbolischen Link oder die Datei umbenennen und erneut versuchen.")
            }
        }
    }

    /// Nur für deterministische Regressionstests der Dateisystem-Races. Die
    /// Produktpfade verwenden den leeren Standardwert.
    struct StoreHooks {
        var afterOpeningSource: (() -> Void)?
        var afterOpeningImagesDirectory: (() -> Void)?
        var beforePublishing: ((URL) -> Void)?
        var failCopyAfterBytes: Int?

        init(afterOpeningSource: (() -> Void)? = nil,
             afterOpeningImagesDirectory: (() -> Void)? = nil,
             beforePublishing: ((URL) -> Void)? = nil,
             failCopyAfterBytes: Int? = nil) {
            self.afterOpeningSource = afterOpeningSource
            self.afterOpeningImagesDirectory = afterOpeningImagesDirectory
            self.beforePublishing = beforePublishing
            self.failCopyAfterBytes = failCopyAfterBytes
        }
    }

    private struct OpenDirectory {
        let parentFD: Int32?
        let fd: Int32
        let url: URL
        let identity: LockIdentity
        let created: Bool
    }

    private struct LockIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    /// Legt ROHE Bilddaten als neue Datei im `images`-Unterordner ab.
    static func storePastedData(_ prepared: PreparedImageData,
                                documentURL: URL,
                                reserveForTransaction: Bool = false,
                                hooks: StoreHooks = StoreHooks())
    throws -> StoredImage {
        let documentDirectory = documentURL.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        let linkDocumentURL = documentDirectory.appendingPathComponent(
            documentURL.lastPathComponent)
        let directory = documentDirectory.appendingPathComponent("images", isDirectory: true)
        return try directoryLocks.withLock(for: directory) {
            let opened = try openImagesDirectory(beside: documentDirectory)
            defer {
                Darwin.close(opened.fd)
                if let parentFD = opened.parentFD { Darwin.close(parentFD) }
            }
            var stored = false
            defer {
                if !stored, opened.created, let parentFD = opened.parentFD {
                    _ = unlinkat(parentFD, "images", AT_REMOVEDIR)
                }
            }
            let temporaryName = ".fastra-paste-\(UUID().uuidString).tmp"
            let temporaryFD = try createFile(named: temporaryName, in: opened.fd)
            var temporaryExists = true
            defer {
                Darwin.close(temporaryFD)
                if temporaryExists { _ = unlinkat(opened.fd, temporaryName, 0) }
            }
            try writeAll(prepared.data, to: temporaryFD)
            guard fsync(temporaryFD) == 0 else { throw currentPOSIXError() }
            for counter in 1..<10_000 {
                let name = shortImageName(counter: counter, fileExtension: prepared.fileExtension)
                let target = directory.appendingPathComponent(name)
                if isReserved(target) { continue }
                hooks.beforePublishing?(target)
                if renameatx_np(opened.fd, temporaryName, opened.fd, name,
                                UInt32(RENAME_EXCL)) == 0 {
                    temporaryExists = false
                    guard directoryStillMatches(opened),
                          let relative = relativeLinkPath(from: linkDocumentURL,
                                                          to: target)
                    else {
                        _ = unlinkat(opened.fd, name, 0)
                        throw StoreError.invalidImagesDirectory
                    }
                    let identity: StoredFileIdentity
                    do {
                        // `rename` ändert ctime. Deshalb erst danach am
                        // weiterhin gebundenen FD lesen; ein Pfadaustausch
                        // kann die Identität dabei nicht umlenken.
                        identity = try storedFileIdentity(fromFD: temporaryFD)
                    } catch {
                        _ = unlinkat(opened.fd, name, 0)
                        throw error
                    }
                    let result = StoredImage(
                        link: markdownImageLink(fileName: name, relativePath: relative),
                        fileURL: target,
                        createdByInsertion: true,
                        imagesDirectoryCreated: opened.created,
                        identity: identity
                    )
                    if reserveForTransaction { reserve(result) }
                    stored = true
                    return result
                }
                guard errno == EEXIST else { throw currentPOSIXError() }
            }
            throw StoreError.unreadableImage
        }
    }

    /// Kopiert eine Bild-DATEI unverändert in den `images`-Unterordner:
    /// Jede Einfügung erhält eine eigene freie Nummer. So besitzt ihr
    /// Undo-Schritt die neue Datei auch bei bytegleichen Quellen eindeutig.
    static func storeImageFile(_ sourceURL: URL,
                               documentURL: URL,
                               reserveForTransaction: Bool = false,
                               hooks: StoreHooks = StoreHooks())
    throws -> StoredImage {
        // Die Quelle wird genau einmal geöffnet. Ein Austausch des Pfads nach
        // dieser Stelle kann weder andere Bytes einschleusen noch die spätere
        // Kopie auf eine zweite Datei umlenken.
        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let sourceFD = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceFD >= 0 else { throw StoreError.unreadableImage }
        defer { Darwin.close(sourceFD) }
        var sourceBefore = stat()
        guard fstat(sourceFD, &sourceBefore) == 0,
              sourceBefore.st_mode & S_IFMT == S_IFREG else {
            throw StoreError.unreadableImage
        }
        hooks.afterOpeningSource?()

        let documentDirectory = documentURL.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        let linkDocumentURL = documentDirectory.appendingPathComponent(
            documentURL.lastPathComponent)
        let directory = documentDirectory.appendingPathComponent(
            "images", isDirectory: true)

        return try directoryLocks.withLock(for: directory) {
            let opened = try openImagesDirectory(beside: documentDirectory)
            defer {
                Darwin.close(opened.fd)
                if let parentFD = opened.parentFD { Darwin.close(parentFD) }
            }
            var stored = false
            defer {
                // `unlinkat(..., AT_REMOVEDIR)` entfernt ausschließlich den
                // von uns erzeugten, noch leeren echten Ordner. Ein inzwischen
                // untergeschobener Symlink wird niemals verfolgt.
                if !stored, opened.created, let parentFD = opened.parentFD {
                    _ = unlinkat(parentFD, "images", AT_REMOVEDIR)
                }
            }
            hooks.afterOpeningImagesDirectory?()

            let temporaryName = ".fastra-copy-\(UUID().uuidString).tmp"
            let temporaryFD = try createFile(named: temporaryName, in: opened.fd)
            var temporaryExists = true
            defer {
                Darwin.close(temporaryFD)
                if temporaryExists { _ = unlinkat(opened.fd, temporaryName, 0) }
            }
            try copy(sourceFD: sourceFD, targetFD: temporaryFD,
                     failAfterBytes: hooks.failCopyAfterBytes)
            guard fsync(temporaryFD) == 0 else { throw currentPOSIXError() }
            var sourceAfter = stat()
            guard fstat(sourceFD, &sourceAfter) == 0,
                  sameSnapshot(sourceBefore, sourceAfter) else {
                throw StoreError.unreadableImage
            }

            let fileExtension = sourceURL.pathExtension
            for counter in 1..<10_000 {
                let candidateName = shortImageName(counter: counter, fileExtension: fileExtension)
                let candidate = directory.appendingPathComponent(candidateName)
                if isReserved(candidate) { continue }
                hooks.beforePublishing?(candidate)
                if renameatx_np(opened.fd, temporaryName, opened.fd,
                                candidateName, UInt32(RENAME_EXCL)) == 0 {
                    temporaryExists = false
                    guard directoryStillMatches(opened),
                          let relative = relativeLinkPath(from: linkDocumentURL,
                                                          to: candidate) else {
                        _ = unlinkat(opened.fd, candidateName, 0)
                        throw StoreError.invalidImagesDirectory
                    }
                    let copiedIdentity: StoredFileIdentity
                    do {
                        copiedIdentity = try storedFileIdentity(fromFD: temporaryFD)
                    } catch {
                        _ = unlinkat(opened.fd, candidateName, 0)
                        throw error
                    }
                    let result = StoredImage(
                        link: markdownImageLink(fileName: candidateName,
                                                relativePath: relative),
                        fileURL: candidate,
                        createdByInsertion: true,
                        imagesDirectoryCreated: opened.created,
                        identity: copiedIdentity
                    )
                    if reserveForTransaction { reserve(result) }
                    stored = true
                    return result
                }
                guard errno == EEXIST else { throw currentPOSIXError() }
            }
            throw StoreError.unreadableImage
        }
    }

    private static func openImagesDirectory(beside documentDirectory: URL) throws
        -> OpenDirectory {
        let parentFD = open(documentDirectory.path,
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parentFD >= 0 else { throw currentPOSIXError() }
        var created = false
        if mkdirat(parentFD, "images", mode_t(0o755)) == 0 {
            created = true
        } else if errno != EEXIST {
            let error = currentPOSIXError()
            Darwin.close(parentFD)
            throw error
        }
        let fd = openat(parentFD, "images",
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if created { _ = unlinkat(parentFD, "images", AT_REMOVEDIR) }
            Darwin.close(parentFD)
            throw StoreError.invalidImagesDirectory
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = currentPOSIXError()
            Darwin.close(fd)
            Darwin.close(parentFD)
            throw error
        }
        return OpenDirectory(
            parentFD: parentFD, fd: fd,
            url: documentDirectory.appendingPathComponent("images", isDirectory: true),
            identity: LockIdentity(device: info.st_dev, inode: info.st_ino),
            created: created
        )
    }

    private static func directoryStillMatches(_ directory: OpenDirectory) -> Bool {
        var info = stat()
        guard lstat(directory.url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else { return false }
        return LockIdentity(device: info.st_dev, inode: info.st_ino)
            == directory.identity
    }

    private static func createFile(named name: String, in directoryFD: Int32) throws
        -> Int32 {
        let fd = openat(directoryFD, name,
                        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                        mode_t(0o644))
        guard fd >= 0 else { throw currentPOSIXError() }
        return fd
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress! + offset,
                                           bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                guard written > 0 else { throw StoreError.unreadableImage }
                offset += written
            }
        }
    }

    private static func copy(sourceFD: Int32, targetFD: Int32,
                             failAfterBytes: Int?) throws {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var total = 0
        while true {
            let count = Darwin.read(sourceFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw currentPOSIXError()
            }
            if count == 0 { return }
            if let failAfterBytes, total + count > failAfterBytes {
                throw CocoaError(.fileWriteUnknown)
            }
            try buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let written = Darwin.write(targetFD,
                                               bytes.baseAddress! + offset,
                                               count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw currentPOSIXError()
                    }
                    guard written > 0 else { throw StoreError.unreadableImage }
                    offset += written
                }
            }
            total += count
        }
    }

    private static func sameSnapshot(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino
            && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
            && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
    }

    private static func storedFileIdentity(fromFD fd: Int32) throws
        -> StoredFileIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw StoreError.unreadableImage
        }
        return storedFileIdentity(from: info)
    }

    private static func storedFileIdentity(from info: stat) -> StoredFileIdentity {
        StoredFileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(info.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    private static func currentPOSIXError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    /// Gibt den aufgelösten Pfad nur für eine gewöhnliche Datei zurück.
    private static func regularFileURL(for url: URL) -> URL? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true ? resolved : nil
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
