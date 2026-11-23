// MarkdownImageStore.swift
//
// Bild-Ablage für assistiertes Markdown: Pasteboard-Bilddaten und gezogene
// Bilddateien landen als Datei
// beim Datei-Import im images-Unterordner und werden relativ verlinkt.
//
// Leitplanken: Unvollständige Kopien werden nicht veröffentlicht; die Quelle
// bleibt unverändert. Ein Fehler nach Publish hält nicht sicher entfernbare
// eigene Restkopien mit Identitätsbeleg im Fehlerergebnis. Ohne Speicherort
// gibt es keine stille Ablage (der Aufrufer zeigt die „erst speichern“-Meldung).

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

    /// Ergebnis einer Bildablage oder einer geprüften vorhandenen Bilddatei.
    /// Vorhandene Dateien dürfen erst nach gespeicherter Linkentfernung oder
    /// nach bestätigter Aufräumvorschau aus dem Images-Ordner verschwinden.
    struct StoredImage: Sendable {
        let link: String
        let fileURL: URL
        let createdByInsertion: Bool
        let imagesDirectoryCreated: Bool
        let identity: StoredFileIdentity
        let contentSHA256: String
        let reservationKey: String
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

    private static func reservationKey(for url: URL) -> String {
        let directory = url.deletingLastPathComponent().deletingLastPathComponent()
        var info = stat()
        guard stat(directory.path, &info) == 0 else { return url.standardizedFileURL.path }
        return "\(info.st_dev):\(info.st_ino):\(url.lastPathComponent)"
    }

    static func isReserved(_ url: URL) -> Bool {
        reservationLock.lock()
        defer { reservationLock.unlock() }
        return reservedPaths[reservationKey(for: url), default: 0] > 0
    }

    static func releaseReservations(_ images: [StoredImage]) {
        reservationLock.lock()
        defer { reservationLock.unlock() }
        for image in images {
            let key = image.reservationKey
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
        reservedPaths[image.reservationKey, default: 0] += 1
    }

    /// Dateiendungen, die als Bild-Datei eingefügt (statt geöffnet) werden.
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
        case imageNamesExhausted
        case invalidImagesDirectory

        var errorDescription: String? {
            switch self {
            case .documentNotSaved:
                return L10n.string("Das Dokument hat noch keinen Speicherort. Bitte erst speichern (⌘S) — dann kann Fastra Bilder im Unterordner „images“ ablegen.")
            case .unreadableImage:
                return L10n.string("Die Bilddaten konnten nicht gelesen werden.")
            case .imageNamesExhausted:
                return L10n.string("Alle 9.999 Bildnamen für diese Dateiendung im Ordner „images“ sind bereits belegt oder für Rückgängig reserviert.")
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
        var publication = MarkdownImagePublication.Hooks()

        init(afterOpeningSource: (() -> Void)? = nil,
             afterOpeningImagesDirectory: (() -> Void)? = nil,
             beforePublishing: ((URL) -> Void)? = nil,
             failCopyAfterBytes: Int? = nil,
             publication: MarkdownImagePublication.Hooks = .init()) {
            self.afterOpeningSource = afterOpeningSource
            self.afterOpeningImagesDirectory = afterOpeningImagesDirectory
            self.beforePublishing = beforePublishing
            self.failCopyAfterBytes = failCopyAfterBytes
            self.publication = publication
        }
    }

    private struct OpenDirectory {
        let parentFD: Int32
        let fd: Int32
        let url: URL
        let identity: LockIdentity
        let created: Bool
    }

    private struct LockIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    /// Legt rohe Bilddaten als neue Datei im `images`-Unterordner ab.
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
                Darwin.close(opened.parentFD)
            }
            // Auch ein leerer images-Ordner bleibt erhalten. macOS bietet kein
            // identitätsgebundenes rmdir; ein fremder Ersatz darf nicht verschwinden.
            let temporaryName = ".fastra-paste-\(UUID().uuidString).tmp"
            let temporaryFD = try createFile(named: temporaryName, in: opened.fd)
            var temporaryExists = true
            defer {
                Darwin.close(temporaryFD)
                if temporaryExists { _ = unlinkat(opened.fd, temporaryName, 0) }
            }
            try writeAll(prepared.data, to: temporaryFD)
            try MarkdownImagePublication.syncFile(temporaryFD, hooks: hooks.publication)
            let contentSHA256 = try storedFileHash(fromFD: temporaryFD)
            for counter in 1..<10_000 {
                let name = shortImageName(counter: counter, fileExtension: prepared.fileExtension)
                let target = directory.appendingPathComponent(name)
                if isReserved(target) { continue }
                hooks.beforePublishing?(target)
                let publication = try MarkdownImagePublication(file: temporaryFD, directory: opened.fd, name: name, expectedSHA256: contentSHA256)
                do {
                    try publication.publish(temporaryName: temporaryName)
                } catch let error as POSIXError where error.code == .EEXIST { continue }
                catch { throw error }
                temporaryExists = false
                do {
                    try hooks.publication.afterRenameBeforeIdentity?(publication.url)
                    try publication.capturePublishedIdentity()
                    try hooks.publication.afterRename?(target)
                    guard directoryStillMatches(opened),
                          let relative = relativeLinkPath(from: linkDocumentURL, to: target) else { throw StoreError.invalidImagesDirectory }
                    try MarkdownImagePublication.syncDirectories(images: opened.fd, parent: opened.parentFD, hooks: hooks.publication)
                    guard directoryStillMatches(opened) else { throw StoreError.invalidImagesDirectory }
                    let result = StoredImage(
                        link: markdownImageLink(fileName: name, relativePath: relative),
                        fileURL: target, createdByInsertion: true,
                        imagesDirectoryCreated: opened.created,
                        identity: try publication.identity(), contentSHA256: contentSHA256,
                        reservationKey: reservationKey(for: target))
                    if reserveForTransaction { reserve(result) }
                    return result
                } catch {
                    throw MarkdownImagePublication.failure(error, publications: [publication],
                        images: opened.fd, parent: opened.parentFD, hooks: hooks.publication)
                }
            }
            throw StoreError.imageNamesExhausted
        }
    }

    /// Kopiert eine Bild-Datei unverändert in den `images`-Unterordner:
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
        // O_NONBLOCK verhindert, dass eine Pipe schon vor fstat auf einen Schreiber wartet.
        let sourceFD = open(source.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
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
                Darwin.close(opened.parentFD)
            }
            // Auch ein leerer images-Ordner bleibt erhalten. macOS bietet kein
            // identitätsgebundenes rmdir; ein fremder Ersatz darf nicht verschwinden.
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
            try MarkdownImagePublication.syncFile(temporaryFD, hooks: hooks.publication)
            var sourceAfter = stat()
            guard fstat(sourceFD, &sourceAfter) == 0,
                  sameSnapshot(sourceBefore, sourceAfter) else {
                throw StoreError.unreadableImage
            }

            let fileExtension = sourceURL.pathExtension
            let contentSHA256 = try storedFileHash(fromFD: temporaryFD)
            for counter in 1..<10_000 {
                let candidateName = shortImageName(counter: counter, fileExtension: fileExtension)
                let candidate = directory.appendingPathComponent(candidateName)
                if isReserved(candidate) { continue }
                hooks.beforePublishing?(candidate)
                let publication = try MarkdownImagePublication(file: temporaryFD, directory: opened.fd, name: candidateName, expectedSHA256: contentSHA256)
                do {
                    try publication.publish(temporaryName: temporaryName)
                } catch let error as POSIXError where error.code == .EEXIST { continue }
                catch { throw error }
                temporaryExists = false
                do {
                    try hooks.publication.afterRenameBeforeIdentity?(publication.url)
                    try publication.capturePublishedIdentity()
                    try hooks.publication.afterRename?(candidate)
                    guard directoryStillMatches(opened),
                          let relative = relativeLinkPath(from: linkDocumentURL, to: candidate) else { throw StoreError.invalidImagesDirectory }
                    try MarkdownImagePublication.syncDirectories(images: opened.fd, parent: opened.parentFD, hooks: hooks.publication)
                    guard directoryStillMatches(opened) else { throw StoreError.invalidImagesDirectory }
                    let result = StoredImage(
                        link: markdownImageLink(fileName: candidateName, relativePath: relative),
                        fileURL: candidate, createdByInsertion: true,
                        imagesDirectoryCreated: opened.created,
                        identity: try publication.identity(), contentSHA256: contentSHA256,
                        reservationKey: reservationKey(for: candidate))
                    if reserveForTransaction { reserve(result) }
                    return result
                } catch {
                    throw MarkdownImagePublication.failure(error, publications: [publication],
                        images: opened.fd, parent: opened.parentFD, hooks: hooks.publication)
                }
            }
            throw StoreError.imageNamesExhausted
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
                        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                        mode_t(0o644))
        guard fd >= 0 else { throw currentPOSIXError() }
        return fd
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            try POSIXBufferWriter.writeAll(bytes, to: fd, makeError: {
                NSError(domain: NSPOSIXErrorDomain, code: Int($0))
            })
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
                try POSIXBufferWriter.writeAll(
                    UnsafeRawBufferPointer(rebasing: bytes[..<count]),
                    to: targetFD, makeError: {
                        NSError(domain: NSPOSIXErrorDomain, code: Int($0))
                    })
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

    static func captureExisting(_ url: URL) throws -> StoredImage {
        let directory = url.deletingLastPathComponent()
        guard directory.lastPathComponent == "images" else { throw StoreError.invalidImagesDirectory }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw StoreError.invalidImagesDirectory }
        defer { Darwin.close(directoryFD) }
        let fd = openat(directoryFD, url.lastPathComponent, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw StoreError.unreadableImage }
        defer { Darwin.close(fd) }
        let identity = try storedFileIdentity(fromFD: fd)
        let hash = try storedFileHash(fromFD: fd)
        guard identity == (try storedFileIdentity(fromFD: fd)) else { throw StoreError.unreadableImage }
        return StoredImage(link: "", fileURL: url, createdByInsertion: false,
                           imagesDirectoryCreated: false, identity: identity, contentSHA256: hash, reservationKey: reservationKey(for: url))
    }

    private static func storedFileHash(fromFD fd: Int32) throws -> String {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0 else {
            throw StoreError.unreadableImage
        }
        return try FileSnapshot.readSnapshotOnly(
            descriptor: fd, fileStat: info, byteLimit: UInt64(info.st_size)).sha256
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
    /// eingefügt, alles andere behält das bestehende Verhalten „öffnen“.
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
