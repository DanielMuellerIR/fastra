import Foundation
import AppKit
import Darwin
import cmark_gfm

/// Gemeinsame Referenzprüfung für gespeicherte Löschungen und die explizite
/// Bereinigung. Andere Markdown-Dateien im selben Ordner behalten ihre Bilder.
enum MarkdownImageCleanup {
    struct Plan {
        let documentURL: URL
        let content: String
        let openDocuments: [URL: [String]]
        let candidates: [MarkdownImageStore.StoredImage]
    }

    private static let htmlAttributes = try! NSRegularExpression(
        pattern: #"(?i)\s+([a-z_:][a-z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#)

    static func references(_ content: String, documentURL: URL, protecting directory: URL? = nil) -> Set<URL> {
        var used = Set<URL>()
        func protectImagesDirectory() {
            let local = documentURL.deletingLastPathComponent().appendingPathComponent("images")
            for folder in Set([local, directory ?? local]) {
                // Der Images-Ordner kann beim Scan noch fehlen. Deshalb den
                // existierenden Elternordner kanonisieren und den Verzeichnistyp festhalten.
                used.insert(folder.deletingLastPathComponent().canonicalFileURL
                    .appendingPathComponent(folder.lastPathComponent, isDirectory: true))
            }
        }
        func add(_ destination: String) {
            let path = destination.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? destination
            guard !path.isEmpty, !path.hasPrefix("//") else { return }
            if let components = URLComponents(string: path), let scheme = components.scheme {
                guard scheme.lowercased() == "file", components.host == nil || components.host == "" || components.host == "localhost",
                      let url = components.url else { return }
                used.insert(url.canonicalFileURL)
            } else {
                // Auch ein nacktes Prozentzeichen ist ein gültiger Dateiname.
                // Dieselbe Rückfallauflösung wie die Vorschau schützt dessen Bild.
                let decoded = path.removingPercentEncoding ?? path
                let url = decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded)
                    : documentURL.deletingLastPathComponent().appendingPathComponent(decoded)
                used.insert(url.canonicalFileURL)
            }
        }
        // Die Vorschau verwirft SVG und nicht freigegebenes HTML. Für Löschungen
        // zählt stattdessen der unveränderte Parserbaum, einschließlich Downloadlinks.
        guard let document = content.withCString({ cmark_parse_document($0, content.utf8.count, CMARK_OPT_DEFAULT) }) else {
            protectImagesDirectory()
            return used
        }
        defer { cmark_node_free(document) }
        guard let iterator = cmark_iter_new(document) else { protectImagesDirectory(); return used }
        defer { cmark_iter_free(iterator) }
        while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
            guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER,
                  let node = cmark_iter_get_node(iterator) else { continue }
            let type = cmark_node_get_type(node)
            if type == CMARK_NODE_IMAGE || type == CMARK_NODE_LINK {
                if let url = cmark_node_get_url(node) { add(String(cString: url)) }
            } else if type == CMARK_NODE_HTML_INLINE || type == CMARK_NODE_HTML_BLOCK {
                guard let literal = cmark_node_get_literal(node) else { protectImagesDirectory(); continue }
                let html = String(cString: literal)
                let ns = html as NSString
                for match in htmlAttributes.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                    let name = ns.substring(with: match.range(at: 1)).lowercased()
                    guard let range = (2...4).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { continue }
                    let value = MarkdownHTMLEntities.decode(ns.substring(with: range))
                    if ["src", "href", "xlink:href", "poster", "data"].contains(name) { add(value) }
                }
                // CSS, alternative Bildquellen und Vorlagen haben eigene Grammatiken.
                // Ohne sichere Auflösung bleiben alle Dateien dieses Images-Ordners erhalten.
                if html.range(of: #"(?i)\b(?:srcset|imagesrcset|style|codebase|archive|srcdoc|background)\s*=|[{}$]|<\s*(?:script|style)\b"#, options: .regularExpression) != nil {
                    protectImagesDirectory()
                }
            }
        }
        return used
    }

    /// Eine Verzeichnisreferenz schützt auch später hinzugekommene Dateien.
    /// Das verhindert, dass eine unvollständige Ordnerliste zum Löschbeleg wird.
    static func protects(_ images: Set<URL>, in references: Set<URL>) -> Bool {
        images.contains { references.contains($0) || references.contains($0.deletingLastPathComponent().canonicalFileURL) }
    }

    static func sharedReferences(documentURL: URL, openDocuments: [URL: [String]]) throws -> Set<URL> {
        let directory = documentURL.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        guard files.count <= 10_000 else { throw CocoaError(.fileReadTooLarge) }
        let images = directory.appendingPathComponent("images")
        var used = Set<URL>()
        for file in files where file.canonicalFileURL != documentURL.canonicalFileURL && ["md", "markdown", "mdown", "mkd"].contains(file.pathExtension.lowercased()) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 10 * 1024 * 1024 else { throw CocoaError(.fileReadUnknown) }
            // Auch der gespeicherte Stand zählt: Ein anderer offener Tab kann
            // seine noch ungesicherte Entfernung später wieder verwerfen.
            used.formUnion(references(try String(contentsOf: file), documentURL: file, protecting: images))
        }
        for (url, versions) in openDocuments {
            for content in versions { used.formUnion(references(content, documentURL: url, protecting: images)) }
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
        if used.contains(directory.canonicalFileURL) {
            return Plan(documentURL: documentURL, content: content, openDocuments: openDocuments, candidates: [])
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var candidates: [MarkdownImageStore.StoredImage] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  MarkdownPreviewAssets.imageMIMEType(for: file) != nil,
                  !used.contains(file.canonicalFileURL), !MarkdownImageStore.isReserved(file) else { continue }
            candidates.append(try MarkdownImageStore.captureExisting(file))
        }
        return Plan(documentURL: documentURL, content: content, openDocuments: openDocuments, candidates: candidates)
    }

    static func apply(_ preview: Plan, gate: (() -> Bool) -> Bool = { $0() }) throws {
        let current = try plan(documentURL: preview.documentURL, content: preview.content, openDocuments: preview.openDocuments)
        guard current.candidates.count == preview.candidates.count,
              zip(current.candidates, preview.candidates).allSatisfy({
                  $0.fileURL == $1.fileURL && $0.identity == $1.identity && $0.contentSHA256 == $1.contentSHA256
              }) else { throw CocoaError(.fileWriteUnknown) }
        guard !preview.candidates.isEmpty else { return }
        guard MarkdownImageUndoFiles(images: preview.candidates).removePermanently(gate: gate) else { throw CocoaError(.fileWriteUnknown) }
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
                        let gate = MarkdownImageUndo.removalGate(for: opened)
                        MarkdownImageUndoSideEffect.pendingIO.enter()
                        DispatchQueue.global(qos: .userInitiated).async {
                            let result = Result { try apply(preview, gate: gate) }
                            DispatchQueue.main.async {
                                defer { MarkdownImageUndoSideEffect.pendingIO.leave() }
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
