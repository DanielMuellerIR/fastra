import AppKit
import CodeEditTextView
import Darwin

/// Zustand der direkt an die konkrete CEUndoManager-Gruppe gebundenen
/// Bilddatei-Nebenwirkung. Gleiche Linktexte in anderen Gruppen spielen keine
/// Rolle mehr; es wird weder das Dokument gescannt noch global beobachtet.
final class MarkdownImageUndoSideEffect {
    private enum FileState { case onDisk, stashed, finished }

    private let mover: MarkdownImageUndoFileMover
    private var fileState: FileState = .onDisk
    init(images: [MarkdownImageStore.StoredImage]) {
        mover = MarkdownImageUndoFileMover(images: images)
    }

    func undo() {
        guard fileState == .onDisk else { return }
        if mover.stashCreatedFiles() { fileState = .stashed }
    }

    func redo() {
        guard fileState == .stashed else { return }
        if mover.restoreStashedFiles() { fileState = .onDisk }
    }

    func discard() {
        guard fileState == .stashed else {
            fileState = .finished
            return
        }
        mover.discardStash()
        fileState = .finished
    }
}

@MainActor
enum MarkdownImageUndo {
    static func register(textView: TextView, insertion: String,
                         storedImages: [MarkdownImageStore.StoredImage]) {
        let created = storedImages.filter(\.createdByInsertion)
        guard !insertion.isEmpty, !created.isEmpty,
              let undoManager = textView.undoManager as? CEUndoManager else { return }
        let sideEffect = MarkdownImageUndoSideEffect(images: created)
        _ = undoManager.fastraRegisterSideEffectForLatestUndo(
            undo: { sideEffect.undo() },
            redo: { sideEffect.redo() },
            discard: { sideEffect.discard() }
        )
    }
}

/// Verschiebt Bilddateien für Redo in einen eigenen versteckten Ordner neben
/// dem Dokument. Vor jedem Verschieben/Löschen wird die beim Erzeugen erfasste
/// Dateiidentität geprüft. Ein später ausgetauschtes Nutzerobjekt bleibt damit
/// unangetastet.
final class MarkdownImageUndoFileMover: @unchecked Sendable {
    private let images: [MarkdownImageStore.StoredImage]
    private let backupDirectory: URL
    private let backupName: String
    private var currentIdentities: [URL: MarkdownImageStore.StoredFileIdentity]

    init(images: [MarkdownImageStore.StoredImage]) {
        self.images = images
        let documentDirectory = images[0].fileURL.deletingLastPathComponent()
            .deletingLastPathComponent()
        backupName = ".fastra-image-undo-\(UUID().uuidString)"
        backupDirectory = documentDirectory.appendingPathComponent(
            backupName, isDirectory: true)
        currentIdentities = Dictionary(uniqueKeysWithValues: images.map {
            ($0.fileURL, $0.identity)
        })
    }

    func stashCreatedFiles() -> Bool {
        guard let handles = openDirectoriesForStash() else { return false }
        defer { handles.close() }
        var moved: [MarkdownImageStore.StoredImage] = []
        for image in images {
            guard move(image, from: handles.imagesFD, to: handles.backupFD,
                       expected: currentIdentities[image.fileURL]) else {
                rollback(moved.reversed(), from: handles.backupFD,
                         to: handles.imagesFD)
                _ = unlinkat(handles.documentFD, backupName, AT_REMOVEDIR)
                return false
            }
            moved.append(image)
        }
        if images.contains(where: \.imagesDirectoryCreated) {
            // `rmdir` entfernt ausschließlich einen leeren echten Ordner;
            // fremde Inhalte und Symlinks werden niemals rekursiv angerührt.
            _ = unlinkat(handles.documentFD, "images", AT_REMOVEDIR)
        }
        return true
    }

    func restoreStashedFiles() -> Bool {
        guard let handles = openDirectoriesForRestore() else { return false }
        defer { handles.close() }
        var restored: [MarkdownImageStore.StoredImage] = []
        for image in images {
            guard move(image, from: handles.backupFD, to: handles.imagesFD,
                       expected: currentIdentities[image.fileURL]) else {
                rollback(restored.reversed(), from: handles.imagesFD,
                         to: handles.backupFD)
                return false
            }
            restored.append(image)
        }
        _ = unlinkat(handles.documentFD, backupName, AT_REMOVEDIR)
        return true
    }

    func discardStash() {
        guard let documentFD = openDocumentDirectory() else { return }
        defer { Darwin.close(documentFD) }
        let backupFD = openat(documentFD, backupName,
                              O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard backupFD >= 0 else { return }
        defer { Darwin.close(backupFD) }
        for image in images where identity(named: image.fileURL.lastPathComponent,
                                            in: backupFD)
            == currentIdentities[image.fileURL] {
            _ = unlinkat(backupFD, image.fileURL.lastPathComponent, 0)
        }
        _ = unlinkat(documentFD, backupName, AT_REMOVEDIR)
    }

    private struct DirectoryHandles {
        let documentFD: Int32
        let imagesFD: Int32
        let backupFD: Int32

        func close() {
            Darwin.close(backupFD)
            Darwin.close(imagesFD)
            Darwin.close(documentFD)
        }
    }

    private func openDocumentDirectory() -> Int32? {
        let directory = backupDirectory.deletingLastPathComponent()
        let fd = open(directory.path,
                      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        return fd >= 0 ? fd : nil
    }

    private func openDirectoriesForStash() -> DirectoryHandles? {
        guard let documentFD = openDocumentDirectory() else { return nil }
        guard mkdirat(documentFD, backupName, mode_t(0o700)) == 0 else {
            Darwin.close(documentFD)
            return nil
        }
        guard let handles = openChildDirectories(documentFD: documentFD) else {
            _ = unlinkat(documentFD, backupName, AT_REMOVEDIR)
            Darwin.close(documentFD)
            return nil
        }
        return handles
    }

    private func openDirectoriesForRestore() -> DirectoryHandles? {
        guard let documentFD = openDocumentDirectory() else { return nil }
        let createdImagesDirectory = mkdirat(documentFD, "images", mode_t(0o755)) == 0
        if !createdImagesDirectory, errno != EEXIST {
            Darwin.close(documentFD)
            return nil
        }
        guard let handles = openChildDirectories(documentFD: documentFD) else {
            if createdImagesDirectory {
                _ = unlinkat(documentFD, "images", AT_REMOVEDIR)
            }
            Darwin.close(documentFD)
            return nil
        }
        return handles
    }

    private func openChildDirectories(documentFD: Int32) -> DirectoryHandles? {
        let imagesFD = openat(documentFD, "images",
                              O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard imagesFD >= 0 else { return nil }
        let backupFD = openat(documentFD, backupName,
                              O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard backupFD >= 0 else {
            Darwin.close(imagesFD)
            return nil
        }
        return DirectoryHandles(documentFD: documentFD, imagesFD: imagesFD,
                                backupFD: backupFD)
    }

    private func move(_ image: MarkdownImageStore.StoredImage,
                      from sourceFD: Int32,
                      to targetFD: Int32,
                      expected: MarkdownImageStore.StoredFileIdentity?) -> Bool {
        let name = image.fileURL.lastPathComponent
        guard let expected,
              !name.isEmpty, name != ".", name != "..",
              identity(named: name, in: sourceFD) == expected else {
            return false
        }
        guard renameatx_np(sourceFD, name, targetFD, name,
                           UInt32(RENAME_EXCL)) == 0 else { return false }
        guard let movedIdentity = identity(named: name, in: targetFD),
              sameFileAcrossRename(expected, movedIdentity) else {
            // Der Name kann zwischen Vorprüfung und `renameatx_np` ersetzt
            // worden sein. Eine fremde Datei wird dann nicht zur neuen
            // erwarteten Identität; wir legen sie bestmöglich zurück und
            // brechen die ganze Undo-Nebenwirkung ab.
            _ = renameatx_np(targetFD, name, sourceFD, name,
                             UInt32(RENAME_EXCL))
            return false
        }
        currentIdentities[image.fileURL] = movedIdentity
        return true
    }

    private func sameFileAcrossRename(
        _ before: MarkdownImageStore.StoredFileIdentity,
        _ after: MarkdownImageStore.StoredFileIdentity
    ) -> Bool {
        // Ein Rename ändert ctime, alle übrigen Identitätsfelder müssen aber
        // dieselbe, unveränderte reguläre Datei belegen.
        before.device == after.device
            && before.inode == after.inode
            && before.size == after.size
            && before.modificationSeconds == after.modificationSeconds
            && before.modificationNanoseconds == after.modificationNanoseconds
    }

    private func rollback<S: Sequence>(_ moved: S, from sourceFD: Int32,
                                       to targetFD: Int32)
    where S.Element == MarkdownImageStore.StoredImage {
        for image in moved {
            _ = move(image, from: sourceFD, to: targetFD,
                     expected: currentIdentities[image.fileURL])
        }
    }

    private func identity(named name: String, in directoryFD: Int32)
        -> MarkdownImageStore.StoredFileIdentity? {
        let fd = openat(directoryFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return MarkdownImageStore.StoredFileIdentity(
            device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(info.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }
}
