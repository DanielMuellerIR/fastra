import AppKit
import CodeEditTextView
import Foundation

/// Die Dateiseite einer konkreten Bildbearbeitung. Gespeicherte Verweise bleiben
/// geschützt; entfernte Bilder werden nur bis zum Verwerfen ihres RAM-Tickets gehalten.
final class MarkdownImageUndoSideEffect: @unchecked Sendable {
    static let pendingIO = DispatchGroup()
    static let ioQueue = DispatchQueue(label: "Fastra.MarkdownImageUndo", qos: .userInitiated)
    private enum FileState { case onDisk, inMemory, finished }
    private let images: [MarkdownImageStore.StoredImage]
    private let files: MarkdownImageUndoFiles
    private var fileState: FileState = .onDisk
    private var protectedBySavedDocument: Bool
    private var removalPending = false

    init(images: [MarkdownImageStore.StoredImage], alreadySaved: Bool = false,
         buffer: MarkdownImageUndoBuffer = .shared, historyLost: @escaping () -> Void = {}) {
        self.images = images
        protectedBySavedDocument = alreadySaved
        MarkdownImageStore.reserveForUndo(images)
        files = MarkdownImageUndoFiles(images: images, buffer: buffer, invalidated: historyLost)
    }

    deinit { discard() }
    var currentURLs: Set<URL> { files.currentURLs }

    func referenceDocumentURL(_ original: URL?) -> URL? {
        guard let original, let directory = files.documentDirectoryURL else { return nil }
        return directory.appendingPathComponent(original.lastPathComponent)
    }

    /// Save As lässt das Ursprungsdokument bestehen. Sein Plattenstand und
    /// Finder-Umbenennungen gehören deshalb zur Herkunft der Bilder, nicht zum neuen Tabpfad.
    func savedReferences(documentURL: URL?, opened: [URL: [String]]) -> Set<URL>? {
        guard let documentURL else { return [] }
        guard let origin = referenceDocumentURL(documentURL) else { return nil }
        return MarkdownImageUndo.savedReferences(documentURL: origin, opened: opened)
    }

    func protectSavedReferences(_ referenced: Set<URL>) {
        if MarkdownImageCleanup.protects(files.currentURLs, in: referenced) { protectedBySavedDocument = true }
    }

    @discardableResult
    func undo(usedImages: Set<URL> = [], gate: (() -> Bool) -> Bool = { $0() }) -> Bool {
        guard !MarkdownImageCleanup.protects(files.currentURLs, in: usedImages) else { return true }
        if protectedBySavedDocument { removalPending = true; return true }
        guard fileState == .onDisk else { return fileState == .inMemory }
        guard files.removeForUndo(gate: gate) else { return false }
        fileState = .inMemory
        return true
    }

    @discardableResult
    func redo() -> Bool {
        removalPending = false
        guard fileState == .inMemory else { return fileState == .onDisk }
        guard files.restoreFromMemory() else { return false }
        fileState = .onDisk
        return true
    }

    @discardableResult
    func documentSaved(visible: Bool, gate: (() -> Bool) -> Bool = { $0() }) -> Bool {
        if visible { protectedBySavedDocument = true; removalPending = false; return true }
        guard removalPending else { return true }
        guard fileState == .onDisk, files.removeForUndo(gate: gate) else { return false }
        fileState = .inMemory
        protectedBySavedDocument = false
        removalPending = false
        return true
    }

    func discard(unusedBy references: Set<URL>? = nil, gate: (() -> Bool) -> Bool = { $0() }) {
        guard fileState != .finished else { return }
        if fileState == .onDisk, let references, !MarkdownImageCleanup.protects(files.currentURLs, in: references),
           images.allSatisfy(\.createdByInsertion), !files.removePermanently(gate: gate) { return }
        files.discardMemory()
        MarkdownImageStore.releaseReservations(images)
        fileState = .finished
    }

    /// Der Abschluss gehört vor die Invalidierungen. Das RAM-Limit darf eine
    /// gerade ausgeführte Textänderung nicht nachträglich verhindern.
    static func perform(_ work: @escaping () -> Bool, buffer: MarkdownImageUndoBuffer = .shared,
                        completion: @escaping (Bool) -> Void) {
        pendingIO.enter()
        ioQueue.async {
            let result = work()
            let invalidations = buffer.takeInvalidations()
            DispatchQueue.main.async {
                defer { pendingIO.leave() }
                completion(result)
                for invalidate in invalidations { invalidate() }
            }
        }
    }
}

final class MarkdownImageRemovalCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    var isStale: Bool { lock.lock(); defer { lock.unlock() }; return changed }
    func markStale() { lock.lock(); changed = true; lock.unlock() }
}

@MainActor
enum MarkdownImageUndo {
    static var applicationIsClosing = false

    static func openDocumentContents(excluding manager: CEUndoManager? = nil, tabID: UUID? = nil, workspace owner: Workspace? = nil) -> [URL: [String]] {
        guard !applicationIsClosing else { return [:] }
        var documents: [URL: [String]] = [:]
        for workspace in Workspace.allLive {
            for tab in workspace.tabs {
                if workspace === owner, tab.id == tabID { continue }
                guard let url = tab.url, manager == nil || !tab.undoHistory.owns(manager!) else { continue }
                documents[url, default: []].append(tab.content)
            }
        }
        return documents
    }

    static func removalGate(for snapshot: [URL: [String]], excluding manager: CEUndoManager? = nil,
                            tabID: UUID? = nil, workspace: Workspace? = nil,
                            allow: @escaping () -> Bool = { true },
                            onStale: @escaping () -> Void = {}) -> (() -> Bool) -> Bool {
        return { commit in
            withoutActuallyEscaping(commit) { commit in
            let check = {
                let current = openDocumentContents(excluding: manager, tabID: tabID, workspace: workspace)
                guard allow(), current.count == snapshot.count, snapshot.allSatisfy({ url, versions in
                    guard let now = current[url], now.count == versions.count else { return false }
                    return zip(now, versions).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
                }) else { onStale(); return false }
                return commit()
            }
            return Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
            }
        }
    }

    static func performWithReferences(excluding manager: CEUndoManager? = nil,
        buffer: MarkdownImageUndoBuffer,
        work: @escaping ([URL: [String]], (() -> Bool) -> Bool) -> Bool,
        completion: @escaping (Bool) -> Void) {
        let opened = openDocumentContents(excluding: manager)
        let check = MarkdownImageRemovalCheck()
        let gate = removalGate(for: opened, excluding: manager, onStale: { check.markStale() })
        MarkdownImageUndoSideEffect.perform({ work(opened, gate) }, buffer: buffer) { success in
            if check.isStale {
                // Ein anderes Fenster hat während Lesen/Hashen weitergearbeitet.
                // Mit seinen aktuellen Verweisen neu prüfen, statt Dateien liegenzulassen.
                performWithReferences(excluding: manager, buffer: buffer, work: work, completion: completion)
            } else { completion(success) }
        }
    }

    nonisolated static func savedReferences(documentURL: URL?, opened: [URL: [String]]) -> Set<URL>? {
        guard let documentURL else { return [] }
        do {
            var references = try MarkdownImageCleanup.sharedReferences(documentURL: documentURL, openDocuments: opened)
            if FileManager.default.fileExists(atPath: documentURL.path) {
                let size = try documentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 10 * 1024 * 1024 else { return nil }
                references.formUnion(MarkdownImageCleanup.references(try String(contentsOf: documentURL), documentURL: documentURL))
            }
            return references
        } catch { return nil }
    }

    static func register(textView: TextView, insertion: String,
                         storedImages: [MarkdownImageStore.StoredImage], documentURL: URL? = nil, workspace: Workspace? = nil,
                         buffer: MarkdownImageUndoBuffer = .shared) {
        let created = storedImages.filter(\.createdByInsertion)
        guard !insertion.isEmpty, !created.isEmpty,
              let manager = textView.undoManager as? CEUndoManager else { return }
        let hasWorkspace = workspace != nil
        let effect = MarkdownImageUndoSideEffect(images: created, buffer: buffer, historyLost: { [weak manager] in
            manager?.clearStack()
        })
        _ = manager.fastraRegisterSideEffectForLatestUndo(
            undo: {}, redo: {},
            undoAsync: { [weak manager] content, completion in
                performWithReferences(excluding: manager, buffer: buffer, work: { opened, gate in
                    guard let saved = effect.savedReferences(documentURL: documentURL, opened: opened) else { return true }
                    effect.protectSavedReferences(saved)
                    let visible = effect.referenceDocumentURL(documentURL).map { MarkdownImageCleanup.references(content, documentURL: $0) } ?? []
                    _ = effect.undo(usedImages: visible, gate: gate)
                    return true
                }, completion: { _ in completion() })
            },
            prepareRedoAsync: { [weak textView] completion in
                MarkdownImageUndoSideEffect.perform({ effect.redo() }, buffer: buffer, completion: { success in
                    if !success, let window = textView?.window, window.attachedSheet == nil {
                        let alert = NSAlert()
                        alert.messageText = L10n.string("Bild konnte nicht wiederhergestellt werden")
                        alert.informativeText = L10n.string("Der Bildpfad ist inzwischen belegt oder nicht beschreibbar. Der Text blieb unverändert. Gib den ursprünglichen Bildpfad frei und versuche Wiederholen erneut.")
                        alert.beginSheetModal(for: window)
                    }
                    completion(success)
                })
            },
            cancelRedoAsync: { completion in
                performWithReferences(buffer: buffer, work: { opened, gate in
                    let protected = effect.savedReferences(documentURL: documentURL, opened: opened) ?? effect.currentURLs
                    return effect.undo(usedImages: protected, gate: gate)
                }, completion: { _ in completion() })
            },
            documentSaved: { content, url in
                performWithReferences(buffer: buffer, work: { opened, gate in
                    guard let protected = effect.savedReferences(documentURL: documentURL ?? url, opened: opened) else { return true }
                    var visible = MarkdownImageCleanup.references(content, documentURL: url)
                    visible.formUnion(protected)
                    _ = effect.documentSaved(visible: MarkdownImageCleanup.protects(effect.currentURLs, in: visible), gate: gate)
                    return true
                }, completion: { _ in })
            },
            discard: { [weak textView] in
                let standaloneText = !hasWorkspace ? textView?.string : nil
                performWithReferences(buffer: buffer, work: { opened, gate in
                    var opened = opened
                    if let standaloneText, let documentURL { opened[documentURL, default: []].append(standaloneText) }
                    effect.discard(unusedBy: effect.savedReferences(documentURL: documentURL, opened: opened), gate: gate)
                    return true
                }, completion: { _ in })
            }
        )
    }
}
