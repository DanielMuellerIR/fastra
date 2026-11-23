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
    private let removalHooks: MarkdownImageRemoval.Hooks
    private var fileState: FileState = .onDisk
    private var protectedBySavedDocument: Bool
    private var removalPending = false

    init(images: [MarkdownImageStore.StoredImage], alreadySaved: Bool = false,
         buffer: MarkdownImageUndoBuffer = .shared, historyLost: @escaping () -> Void = {},
         removalHooks: MarkdownImageRemoval.Hooks = .init()) {
        self.images = images
        self.removalHooks = removalHooks
        protectedBySavedDocument = alreadySaved
        MarkdownImageStore.reserveForUndo(images)
        files = MarkdownImageUndoFiles(images: images, buffer: buffer, invalidated: historyLost)
    }

    deinit { discard() }
    var currentURLs: Set<URL> { files.currentURLs }
    var restoreFailureDescription: String? {
        files.lastPresenceFailure?.localizedDescription ?? files.lastRestoreFailure?.localizedDescription ?? removalFailureDescription
    }
    var removalFailureDescription: String? {
        files.removalFailureDescription
    }

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
        withoutActuallyEscaping(gate) { gate in
            undo(usedImages: usedImages, gate: MarkdownImageRemoval.legacyGate(gate))
        }
    }

    @discardableResult
    func undo(usedImages: Set<URL> = [], gate: MarkdownImageRemoval.DetailedGate) -> Bool {
        if MarkdownImageCleanup.protects(files.currentURLs, in: usedImages) {
            files.forgetProtectedReferenceRejection()
            return true
        }
        if protectedBySavedDocument {
            files.forgetProtectedReferenceRejection()
            removalPending = true
            return true
        }
        guard fileState == .onDisk else { return fileState == .inMemory }
        guard files.removeForUndo(gate: gate, hooks: removalHooks) else { return false }
        fileState = .inMemory
        return true
    }

    @discardableResult
    func redo(hooks: MarkdownImagePublication.Hooks = .init()) -> Bool {
        prepareRedo(hooks: hooks) != .failed
    }

    enum RedoPreparation { case alreadyOnDisk, restoredFromMemory, failed }

    func prepareRedo(hooks: MarkdownImagePublication.Hooks = .init()) -> RedoPreparation {
        if fileState == .onDisk { return files.checkOnDiskImages() ? .alreadyOnDisk : .failed }
        guard fileState == .inMemory, files.restoreFromMemory(hooks: hooks) else { return .failed }
        fileState = .onDisk
        removalPending = false
        return .restoredFromMemory
    }

    @discardableResult
    func documentSaved(visible: Bool, gate: (() -> Bool) -> Bool = { $0() }) -> Bool {
        withoutActuallyEscaping(gate) { gate in
            documentSaved(visible: visible, gate: MarkdownImageRemoval.legacyGate(gate))
        }
    }

    @discardableResult
    func documentSaved(visible: Bool, gate: MarkdownImageRemoval.DetailedGate) -> Bool {
        if visible {
            files.forgetProtectedReferenceRejection()
            protectedBySavedDocument = true
            removalPending = false
            return true
        }
        guard removalPending else { return true }
        guard fileState == .onDisk, files.removeForUndo(gate: gate, hooks: removalHooks) else { return false }
        fileState = .inMemory
        protectedBySavedDocument = false
        removalPending = false
        return true
    }

    func discard(unusedBy references: Set<URL>? = nil, gate: (() -> Bool) -> Bool = { $0() }) {
        withoutActuallyEscaping(gate) { gate in
            discard(unusedBy: references, gate: MarkdownImageRemoval.legacyGate(gate))
        }
    }

    func discard(unusedBy references: Set<URL>? = nil, gate: MarkdownImageRemoval.DetailedGate) {
        guard fileState != .finished else { return }
        if fileState == .onDisk, let references, MarkdownImageCleanup.protects(files.currentURLs, in: references) {
            files.forgetProtectedReferenceRejection()
        }
        if fileState == .onDisk, let references, !MarkdownImageCleanup.protects(files.currentURLs, in: references),
           images.allSatisfy(\.createdByInsertion), !files.removePermanently(gate: gate, hooks: removalHooks) { return }
        files.discardMemory()
        MarkdownImageStore.releaseReservations(images)
        fileState = .finished
    }

    struct WorkResult: Sendable {
        let success: Bool
        let removalFailures: [String]
        let restoreFailures: [String]

        /// Unter dem bestehenden I/O-Besitzer sichern, bevor ein Folgejob die
        /// Fehlerfelder verändert. Der Main-Payload enthält nur fertige Texte.
        static func capture(_ success: Bool, effects: [MarkdownImageUndoSideEffect]) -> Self {
            let restoreFailures = effects.compactMap(\.restoreFailureDescription)
            return Self(success: success, removalFailures: effects.compactMap { $0.files.captureRemovalFailureDescription() },
                        restoreFailures: restoreFailures)
        }
    }

    /// Der Abschluss gehört vor die Invalidierungen. Das RAM-Limit darf eine
    /// gerade ausgeführte Textänderung nicht nachträglich verhindern.
    static func perform<Result: Sendable>(_ work: @escaping () -> Result, buffer: MarkdownImageUndoBuffer = .shared,
                        completion: @escaping (Result) -> Void) {
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
        let detailed = detailedRemovalGate(for: snapshot, excluding: manager, tabID: tabID,
            workspace: workspace, allow: allow, onStale: onStale)
        return { detailed($0).allowed }
    }

    static func detailedRemovalGate(for snapshot: [URL: [String]], excluding manager: CEUndoManager? = nil,
                            tabID: UUID? = nil, workspace: Workspace? = nil,
                            allow: @escaping () -> Bool = { true },
                            onStale: @escaping () -> Void = {}) -> MarkdownImageRemoval.DetailedGate {
        return { commit in
            withoutActuallyEscaping(commit) { commit in
                let check = {
                    // Generation/Session haben Vorrang, auch bei gleichzeitig
                    // geänderten Referenzen. Beide behalten ihren bisherigen Retry.
                    guard allow() else { onStale(); return MarkdownImageRemoval.GateDecision.disallowed }
                    let current = openDocumentContents(excluding: manager, tabID: tabID, workspace: workspace)
                    guard current.count == snapshot.count, snapshot.allSatisfy({ url, versions in
                        guard let now = current[url], now.count == versions.count else { return false }
                        return zip(now, versions).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
                    }) else { onStale(); return .referencesChanged }
                    return .committed(commit())
                }
                return Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
            }
        }
    }

    enum ReferenceWorkOutcome: Sendable {
        case completed(Bool)
        case notSettled
    }

    struct ReferenceWorkResult: Sendable {
        let outcome: ReferenceWorkOutcome
        let files: MarkdownImageUndoSideEffect.WorkResult

        var removalWarning: String? {
            var messages = files.removalFailures
            if case .notSettled = outcome {
                messages.insert(L10n.string("Die Prüfung offener Dokumente wurde nicht stabil abgeschlossen. Verbliebene Bilddateien wurden nicht weiter bereinigt."), at: 0)
            }
            return messages.isEmpty ? nil : messages.joined(separator: "\n\n")
        }
    }

    static func performWithReferences(excluding manager: CEUndoManager? = nil,
        buffer: MarkdownImageUndoBuffer,
        work: @escaping ([URL: [String]], MarkdownImageRemoval.DetailedGate) -> MarkdownImageUndoSideEffect.WorkResult,
        completion: @escaping (ReferenceWorkResult) -> Void) {
        performReferenceAttempt(excluding: manager, buffer: buffer, attemptsRemaining: 3,
                                work: work, completion: completion)
    }

    private static func performReferenceAttempt(excluding manager: CEUndoManager?,
        buffer: MarkdownImageUndoBuffer, attemptsRemaining: Int,
        work: @escaping ([URL: [String]], MarkdownImageRemoval.DetailedGate) -> MarkdownImageUndoSideEffect.WorkResult,
        completion: @escaping (ReferenceWorkResult) -> Void) {
        let opened = openDocumentContents(excluding: manager)
        let check = MarkdownImageRemovalCheck()
        let gate = detailedRemovalGate(for: opened, excluding: manager, onStale: { check.markStale() })
        MarkdownImageUndoSideEffect.perform({ work(opened, gate) }, buffer: buffer) { result in
            guard check.isStale else { completion(.init(outcome: .completed(result.success), files: result)); return }
            guard attemptsRemaining > 1 else { completion(.init(outcome: .notSettled, files: result)); return }
            // Der Folgejob tritt noch vor dem pendingIO-Abschluss dieses Versuchs
            // ein. Auch bei wechselnden Referenzen entsteht so kein Idle-Fenster.
            performReferenceAttempt(excluding: manager, buffer: buffer,
                                    attemptsRemaining: attemptsRemaining - 1,
                                    work: work, completion: completion)
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
                         buffer: MarkdownImageUndoBuffer = .shared,
                         restoreHooks: MarkdownImagePublication.Hooks = .init(),
                         removalHooks: MarkdownImageRemoval.Hooks = .init(),
                         redoWarningHandler: ((String, String) -> Void)? = nil) {
        let created = storedImages.filter(\.createdByInsertion)
        guard !insertion.isEmpty, !created.isEmpty,
              let manager = textView.undoManager as? CEUndoManager else { return }
        let hasWorkspace = workspace != nil
        let effect = MarkdownImageUndoSideEffect(images: created, buffer: buffer, historyLost: { [weak manager] in
            manager?.clearStack()
        }, removalHooks: removalHooks)
        // Beide Callbacks laufen seriell unter dem bestehenden I/O-Besitzer.
        var rollbackPreparedRedo = false
        let reportRemovalFailure: (ReferenceWorkResult) -> Void = { [weak textView, weak workspace] outcome in
            // Der bisherige Reporter hielt auch den Dateibesitzer bis zu seinem Abschluss.
            defer { withExtendedLifetime(effect) {} }
            guard let message = outcome.removalWarning else { return }
            let title = L10n.string("Bilddateien konnten nicht vollständig entfernt werden")
            if let redoWarningHandler { redoWarningHandler(title, message) }
            else if let workspace { workspace.saveSafetyWarningHandler(title, message) }
            else if let window = textView?.window, window.attachedSheet == nil {
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = message
                alert.beginSheetModal(for: window)
            }
        }
        _ = manager.fastraRegisterSideEffectForLatestUndo(
            undo: {}, redo: {},
            undoAsync: { [weak manager] content, completion in
                performWithReferences(excluding: manager, buffer: buffer, work: { opened, gate in
                    guard let saved = effect.savedReferences(documentURL: documentURL, opened: opened) else { return .capture(true, effects: [effect]) }
                    effect.protectSavedReferences(saved)
                    let visible = effect.referenceDocumentURL(documentURL).map { MarkdownImageCleanup.references(content, documentURL: $0) } ?? []
                    _ = effect.undo(usedImages: visible, gate: gate)
                    return .capture(true, effects: [effect])
                }, completion: { outcome in reportRemovalFailure(outcome); completion() })
            },
            prepareRedoAsync: { [weak textView] completion in
                MarkdownImageUndoSideEffect.perform({
                    let prepared = effect.prepareRedo(hooks: restoreHooks)
                    rollbackPreparedRedo = prepared == .restoredFromMemory
                    return .capture(prepared != .failed, effects: [effect])
                }, buffer: buffer, completion: { (result: MarkdownImageUndoSideEffect.WorkResult) in
                    defer { withExtendedLifetime(effect) {} }
                    if !result.success {
                        let title = L10n.string("Bild konnte nicht wiederhergestellt werden")
                        let message: String
                        if let details = result.restoreFailures.first {
                            message = L10n.string("Der Text blieb unverändert. Die Wiederherstellung der Bilder wurde nicht abgeschlossen.") + "\n\n" + details
                        } else {
                            message = L10n.string("Der Bildpfad ist inzwischen belegt oder nicht beschreibbar. Der Text blieb unverändert. Gib den ursprünglichen Bildpfad frei und versuche Wiederholen erneut.")
                        }
                        if let redoWarningHandler { redoWarningHandler(title, message) }
                        else if let window = textView?.window, window.attachedSheet == nil {
                            let alert = NSAlert()
                            alert.messageText = title
                            alert.informativeText = message
                            alert.beginSheetModal(for: window)
                        }
                    }
                    completion(result.success)
                })
            },
            cancelRedoAsync: { completion in
                performWithReferences(buffer: buffer, work: { opened, gate in
                    guard rollbackPreparedRedo else { return .capture(true, effects: [effect]) }
                    // Der Übergangsbeleg gilt auch für begrenzte Referenz-Retries.
                    let protected = effect.savedReferences(documentURL: documentURL, opened: opened) ?? effect.currentURLs
                    return .capture(effect.undo(usedImages: protected, gate: gate), effects: [effect])
                }, completion: { outcome in reportRemovalFailure(outcome); completion() })
            },
            documentSaved: { content, url in
                performWithReferences(buffer: buffer, work: { opened, gate in
                    guard let protected = effect.savedReferences(documentURL: documentURL ?? url, opened: opened) else { return .capture(true, effects: [effect]) }
                    var visible = MarkdownImageCleanup.references(content, documentURL: url)
                    visible.formUnion(protected)
                    _ = effect.documentSaved(visible: MarkdownImageCleanup.protects(effect.currentURLs, in: visible), gate: gate)
                    return .capture(true, effects: [effect])
                }, completion: { outcome in reportRemovalFailure(outcome) })
            },
            discard: { [weak textView] in
                let standaloneText = !hasWorkspace ? textView?.string : nil
                performWithReferences(buffer: buffer, work: { opened, gate in
                    var opened = opened
                    if let standaloneText, let documentURL { opened[documentURL, default: []].append(standaloneText) }
                    effect.discard(unusedBy: effect.savedReferences(documentURL: documentURL, opened: opened), gate: gate)
                    return .capture(true, effects: [effect])
                }, completion: { outcome in reportRemovalFailure(outcome) })
            }
        )
    }
}

extension MarkdownImageUndoSideEffect {
    var referenceRejectionID: UUID? { files.referenceRejectionID }

    func retireReferenceRejection(_ id: UUID) {
        files.retireReferenceRejection(id)
    }
}
