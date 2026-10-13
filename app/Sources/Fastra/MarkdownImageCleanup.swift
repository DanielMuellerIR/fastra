import Foundation
import AppKit
import Darwin

/// Gemeinsame Referenzprüfung für gespeicherte Löschungen und die explizite
/// Bereinigung. Andere Markdown-Dateien im selben Ordner behalten ihre Bilder.
enum MarkdownImageCleanup {
    struct Plan {
        let documentURL: URL
        let content: String
        let openDocuments: [URL: [String]]
        let candidates: [MarkdownImageStore.StoredImage]
    }

    static func references(_ content: String, documentURL: URL) -> Set<URL> {
        Set(MarkdownVisualDocument.render(content, documentURL: documentURL)
            .fragment.imageURLs.values.map(\.canonicalFileURL))
    }

    static func sharedReferences(documentURL: URL, openDocuments: [URL: [String]]) throws -> Set<URL> {
        let directory = documentURL.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        guard files.count <= 10_000 else { throw CocoaError(.fileReadTooLarge) }
        var used = Set<URL>()
        for file in files where file.canonicalFileURL != documentURL.canonicalFileURL && ["md", "markdown", "mdown", "mkd"].contains(file.pathExtension.lowercased()) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 10 * 1024 * 1024 else { throw CocoaError(.fileReadUnknown) }
            // Auch der gespeicherte Stand zählt: Ein anderer offener Tab kann
            // seine noch ungesicherte Entfernung später wieder verwerfen.
            used.formUnion(references(try String(contentsOf: file), documentURL: file))
        }
        for (url, versions) in openDocuments {
            for content in versions { used.formUnion(references(content, documentURL: url)) }
        }
        return used
    }

    static func plan(documentURL: URL, content: String, openDocuments: [URL: [String]]) throws -> Plan {
        let directory = documentURL.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            if errno == ENOENT { return Plan(documentURL: documentURL, content: content, openDocuments: openDocuments, candidates: []) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw MarkdownImageStore.StoreError.invalidImagesDirectory }
        var used = try sharedReferences(documentURL: documentURL, openDocuments: openDocuments)
        used.formUnion(references(content, documentURL: documentURL))
        let documentSize = try documentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard documentSize <= 10 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        used.formUnion(references(try String(contentsOf: documentURL), documentURL: documentURL))
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var candidates: [MarkdownImageStore.StoredImage] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  !used.contains(file.canonicalFileURL), !MarkdownImageStore.isReserved(file) else { continue }
            candidates.append(try MarkdownImageStore.captureExisting(file))
        }
        return Plan(documentURL: documentURL, content: content, openDocuments: openDocuments, candidates: candidates)
    }

    static func apply(_ preview: Plan) throws {
        let current = try plan(documentURL: preview.documentURL, content: preview.content, openDocuments: preview.openDocuments)
        guard current.candidates.count == preview.candidates.count,
              zip(current.candidates, preview.candidates).allSatisfy({
                  $0.fileURL == $1.fileURL && $0.identity == $1.identity && $0.contentSHA256 == $1.contentSHA256
              }) else { throw CocoaError(.fileWriteUnknown) }
        guard !preview.candidates.isEmpty else { return }
        let mover = MarkdownImageUndoFileMover(images: preview.candidates)
        guard mover.stashCreatedFiles() else { throw CocoaError(.fileWriteUnknown) }
        mover.discardStash()
    }
}

@MainActor
extension MarkdownImageCleanup {
    private static func openDocumentContents() -> [URL: [String]] {
        var result: [URL: [String]] = [:]
        for workspace in Workspace.allLive {
            for tab in workspace.tabs {
                guard let url = tab.url else { continue }
                // Mehrere offene Fassungen schützen die Vereinigung ihrer Links.
                result[url, default: []].append(tab.content)
            }
        }
        return result
    }

    static func present() {
        guard let target = CommandTargeting.targetDocument(), target.workspace.activeTabIsMarkdown else { return }
        let workspace = target.workspace
        if let visual = workspace.visualMarkdownEditor, visual.ready {
            visual.synchronize(holdingInput: true) { success in
                if success { preparePresentation(workspace: workspace, window: target.window, completion: { visual.completeAction() }) }
                else { visual.completeAction() }
            }
        } else {
            preparePresentation(workspace: workspace, window: target.window, completion: {})
        }
    }

    private static func preparePresentation(workspace: Workspace, window: NSWindow, completion: @escaping () -> Void) {
        guard let tab = workspace.activeTab, let url = tab.url, !tab.hasUnsavedChanges else {
            workspace.saveSafetyWarningHandler(L10n.string("Images-Ordner aufräumen"),
                L10n.string("Speichere das Markdown-Dokument vor dem Aufräumen."))
            completion()
            return
        }
        let opened = openDocumentContents()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try plan(documentURL: url, content: tab.content, openDocuments: opened) }
            DispatchQueue.main.async {
                guard workspace.activeTab?.id == tab.id, workspace.activeTab?.content == tab.content else { completion(); return }
                switch result {
                case .failure(let error):
                    workspace.saveSafetyWarningHandler(L10n.string("Images-Ordner aufräumen"), error.localizedDescription)
                    completion()
                case .success(let preview):
                    let alert = NSAlert()
                    alert.messageText = L10n.string("Images-Ordner aufräumen")
                    if preview.candidates.isEmpty {
                        alert.informativeText = L10n.string("Keine unbenutzten Dateien im Images-Ordner gefunden.")
                        alert.addButton(withTitle: L10n.string("OK"))
                        alert.beginSheetModal(for: window) { _ in completion() }
                        return
                    }
                    alert.informativeText = L10n.string("Diese Dateien werden gelöscht. Bilder anderer Markdown-Dateien im selben Ordner und offener Dokumente bleiben erhalten. Unterordner werden nicht verändert.")
                    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 180))
                    let text = NSTextView(frame: scroll.bounds)
                    text.isEditable = false
                    text.isVerticallyResizable = true
                    text.autoresizingMask = [.width]
                    text.textContainer?.widthTracksTextView = true
                    text.maxSize = NSSize(width: 440, height: CGFloat.greatestFiniteMagnitude)
                    text.font = .systemFont(ofSize: 12)
                    text.string = preview.candidates.map { $0.fileURL.lastPathComponent }.joined(separator: "\n")
                    scroll.documentView = text
                    scroll.hasVerticalScroller = true
                    alert.accessoryView = scroll
                    alert.addButton(withTitle: L10n.string("Abbrechen"))
                    alert.addButton(withTitle: L10n.string("Löschen"))
                    alert.beginSheetModal(for: window) { response in
                        guard response == .alertSecondButtonReturn,
                              workspace.activeTab?.id == tab.id,
                              workspace.activeTab?.content == tab.content,
                              openDocumentContents() == opened else { completion(); return }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let result = Result { try apply(preview) }
                            DispatchQueue.main.async {
                                if case .failure(let error) = result {
                                    workspace.saveSafetyWarningHandler(L10n.string("Images-Ordner aufräumen"), error.localizedDescription)
                                }
                                completion()
                            }
                        }
                    }
                }
            }
        }
    }
}
