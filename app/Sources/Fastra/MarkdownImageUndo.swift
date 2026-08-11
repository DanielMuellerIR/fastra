import AppKit
import CodeEditTextView
import Darwin
import ObjectiveC

/// Verbindet genau EINEN von Fastra erzeugten Bild-Link-Edit mit seinen neu
/// angelegten Dateien. Manuell verlinkte und bereits vorhandene Bilder kommen
/// gar nicht erst in diese Registrierung.
@MainActor
final class MarkdownImageUndoRegistration: NSObject {
    private enum FileState { case onDisk, stashed, finished }

    private weak var textView: TextView?
    private weak var undoManager: UndoManager?
    private let insertion: String
    private let mover: MarkdownImageUndoFileMover
    private var fileState: FileState = .onDisk
    private var countBeforeUndo = 0
    private var countBeforeRedo = 0
    private var observers: [NSObjectProtocol] = []

    init?(textView: TextView, insertion: String,
          storedImages: [MarkdownImageStore.StoredImage]) {
        let created = storedImages.filter(\.createdByInsertion)
        guard !created.isEmpty, let undoManager = textView.undoManager else { return nil }
        self.textView = textView
        self.undoManager = undoManager
        self.insertion = insertion
        mover = MarkdownImageUndoFileMover(images: created)
        super.init()

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .NSUndoManagerWillUndoChange, object: undoManager, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.willUndo() } })
        observers.append(center.addObserver(
            forName: .NSUndoManagerDidUndoChange, object: undoManager, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.didUndo() } })
        observers.append(center.addObserver(
            forName: .NSUndoManagerWillRedoChange, object: undoManager, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.willRedo() } })
        observers.append(center.addObserver(
            forName: .NSUndoManagerDidRedoChange, object: undoManager, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.didRedo() } })
        observers.append(center.addObserver(
            forName: TextView.textDidChangeNotification, object: textView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.textDidChange() } })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if fileState == .stashed { mover.discardStash() }
    }

    private func willUndo() {
        countBeforeUndo = occurrenceCount()
    }

    private func didUndo() {
        let after = occurrenceCount()
        guard fileState == .onDisk, countBeforeUndo > after, after == 0 else { return }
        if mover.stashCreatedFiles() { fileState = .stashed }
    }

    private func willRedo() {
        countBeforeRedo = occurrenceCount()
    }

    private func didRedo() {
        let after = occurrenceCount()
        guard fileState == .stashed, after > countBeforeRedo else { return }
        if mover.restoreStashedFiles() { fileState = .onDisk }
    }

    private func textDidChange() {
        guard fileState == .stashed, let undoManager,
              !undoManager.isUndoing, !undoManager.isRedoing else { return }
        // Während textDidChange kann der Undo-Manager den alten Redo-Zweig
        // noch melden. Einen Runloop-Tick später ist eindeutig, ob ein neuer
        // Edit ihn verworfen hat; dann die versteckte Sicherung entfernen.
        DispatchQueue.main.async { [weak self, weak undoManager] in
            guard let self, self.fileState == .stashed,
                  let undoManager, !undoManager.canRedo else { return }
            self.mover.discardStash()
            self.fileState = .finished
        }
    }

    private func occurrenceCount() -> Int {
        guard let textView, !insertion.isEmpty else { return 0 }
        let text = textView.string as NSString
        var count = 0
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let found = text.range(of: insertion, options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            count += 1
            let next = NSMaxRange(found)
            search = NSRange(location: next, length: text.length - next)
        }
        return count
    }
}

@MainActor
enum MarkdownImageUndo {
    private static var associationKey: UInt8 = 0

    static func register(textView: TextView, insertion: String,
                         storedImages: [MarkdownImageStore.StoredImage]) {
        guard let registration = MarkdownImageUndoRegistration(
            textView: textView, insertion: insertion, storedImages: storedImages
        ) else { return }
        let registrations: NSMutableArray
        if let existing = objc_getAssociatedObject(textView, &associationKey)
            as? NSMutableArray {
            registrations = existing
        } else {
            registrations = NSMutableArray()
            objc_setAssociatedObject(textView, &associationKey, registrations,
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        registrations.add(registration)
    }
}

/// Verschiebt Bilddateien für Redo in einen eigenen versteckten Ordner neben
/// dem Dokument. Vor jedem Verschieben/Löschen wird die beim Erzeugen erfasste
/// Dateiidentität geprüft. Ein später ausgetauschtes Nutzerobjekt bleibt damit
/// unangetastet.
final class MarkdownImageUndoFileMover: @unchecked Sendable {
    private let images: [MarkdownImageStore.StoredImage]
    private let backupDirectory: URL
    private let fileManager = FileManager.default

    init(images: [MarkdownImageStore.StoredImage]) {
        self.images = images
        let documentDirectory = images[0].fileURL.deletingLastPathComponent()
            .deletingLastPathComponent()
        backupDirectory = documentDirectory.appendingPathComponent(
            ".fastra-image-undo-\(UUID().uuidString)", isDirectory: true
        )
    }

    func stashCreatedFiles() -> Bool {
        guard (try? fileManager.createDirectory(at: backupDirectory,
                                                withIntermediateDirectories: false)) != nil
        else { return false }
        var moved: [MarkdownImageStore.StoredImage] = []
        for image in images {
            guard identity(at: image.fileURL) == image.identity else {
                rollbackStash(moved)
                return false
            }
            let backup = backupURL(for: image)
            do {
                try fileManager.moveItem(at: image.fileURL, to: backup)
            } catch {
                rollbackStash(moved)
                return false
            }
            guard identity(at: backup) == image.identity else {
                rollbackStash(moved + [image])
                return false
            }
            moved.append(image)
        }
        if images.contains(where: \.imagesDirectoryCreated),
           let imagesDirectory = images.first?.fileURL.deletingLastPathComponent() {
            // `rmdir` entfernt ausschließlich einen leeren echten Ordner;
            // fremde Inhalte und Symlinks werden niemals rekursiv angerührt.
            _ = rmdir(imagesDirectory.path)
        }
        return true
    }

    func restoreStashedFiles() -> Bool {
        guard let imagesDirectory = images.first?.fileURL.deletingLastPathComponent(),
              ensureRealDirectory(imagesDirectory) else { return false }
        var restored: [MarkdownImageStore.StoredImage] = []
        for image in images {
            let backup = backupURL(for: image)
            guard identity(at: backup) == image.identity,
                  !fileManager.fileExists(atPath: image.fileURL.path) else {
                rollbackRestore(restored)
                return false
            }
            do {
                try fileManager.moveItem(at: backup, to: image.fileURL)
            } catch {
                rollbackRestore(restored)
                return false
            }
            restored.append(image)
        }
        _ = rmdir(backupDirectory.path)
        return true
    }

    func discardStash() {
        for image in images {
            let backup = backupURL(for: image)
            if identity(at: backup) == image.identity { _ = unlink(backup.path) }
        }
        _ = rmdir(backupDirectory.path)
    }

    private func rollbackStash(_ moved: [MarkdownImageStore.StoredImage]) {
        for image in moved.reversed() {
            let backup = backupURL(for: image)
            guard identity(at: backup) == image.identity,
                  !fileManager.fileExists(atPath: image.fileURL.path) else { continue }
            try? fileManager.moveItem(at: backup, to: image.fileURL)
        }
        _ = rmdir(backupDirectory.path)
    }

    private func rollbackRestore(_ restored: [MarkdownImageStore.StoredImage]) {
        for image in restored.reversed() {
            guard identity(at: image.fileURL) == image.identity else { continue }
            try? fileManager.moveItem(at: image.fileURL, to: backupURL(for: image))
        }
    }

    private func backupURL(for image: MarkdownImageStore.StoredImage) -> URL {
        backupDirectory.appendingPathComponent(image.fileURL.lastPathComponent)
    }

    private func ensureRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info.st_mode & S_IFMT == S_IFDIR }
        guard errno == ENOENT else { return false }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            return true
        } catch {
            return false
        }
    }

    private func identity(at url: URL) -> MarkdownImageStore.StoredFileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return MarkdownImageStore.StoredFileIdentity(
            device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }
}
