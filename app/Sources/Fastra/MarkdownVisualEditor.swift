import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers

enum MarkdownEditingMode {
    static let defaultsKey = "markdown.visualEditing"
    static var choiceOwner: ObjectIdentifier?
    @MainActor
    static func setDefault(_ visual: Bool) {
        let editors = Workspace.allLive.compactMap(\.visualMarkdownEditor).filter(\.ready)
        let group = DispatchGroup()
        var success = true
        for editor in editors {
            group.enter()
            editor.synchronize(holdingInput: true) { succeeded in success = success && succeeded; group.leave() }
        }
        group.notify(queue: .main) {
            if success { SelfTest.workspaceDefaults().set(visual, forKey: defaultsKey) }
            for editor in editors { editor.completeAction() }
        }
    }
}

struct MarkdownEditingModeChoice: View {
    let choose: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Wie möchtest du Markdown bearbeiten?").fastraFont(size: 17, weight: .semibold)
            Text("Im WYSIWYG-Modus arbeitest du direkt in der formatierten Ansicht, ohne Markdown-Kürzel zu sehen. Im Quelltext-Modus stehen Text und Vorschau nebeneinander.")
                .fastraFont(.ui)
            Text("Mit dem Button rechts vom Text/Hex-Umschalter wechselst du den Modus für das aktuelle Dokument (⌃⇧⌘M). Den Standard änderst du jederzeit in den Einstellungen.")
                .fastraFont(.ui).foregroundStyle(Theme.textSecondary)
            HStack {
                Button("Quelltext und Vorschau") { choose(false) }
                    .background(SelfTestMarker(id: "markdownChooseSource").frame(width: 0, height: 0))
                    .keyboardShortcut(.return, modifiers: .option)
                    .help("Markdown-Quelltext mit separater Vorschau als Standard verwenden (⌥↩).")
                Spacer()
                Button("WYSIWYG verwenden") { choose(true) }
                    .background(SelfTestMarker(id: "markdownChooseVisual").frame(width: 0, height: 0))
                    .keyboardShortcut(.defaultAction)
                    .help("Direkt in der formatierten Markdown-Ansicht schreiben (↩).")
            }
        }.padding(24).frame(width: 470)
        .interactiveDismissDisabled()
        .background(SelfTestMarker(id: "markdownModeChoice").frame(width: 0, height: 0))
    }
}

struct MarkdownVisualEditorView: View {
    @ObservedObject var workspace: Workspace
    let tab: EditorTab
    @AppStorage(DocumentZoom.defaultsKey, store: SelfTest.workspaceDefaults()) private var zoom = 0
    @AppStorage(PreviewFonts.defaultsKey, store: SelfTest.workspaceDefaults()) private var fontName = PreviewFonts.systemName
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MarkdownVisualWebView(workspace: workspace, tab: tab,
                              fontName: fontName, fontSize: 14 * DocumentZoom.scale(for: zoom),
                              darkMode: colorScheme == .dark)
            .background(Theme.surfaceRaised)
            .background(SelfTestMarker(id: "markdownVisualEditor").frame(width: 0, height: 0))
            .onAppear { updateDocumentStats() }
            .onChange(of: tab.contentRevision) { _, _ in updateDocumentStats() }
    }

    private func updateDocumentStats() {
        // Die Quelltext-View ist hier unmontiert und zählt geladene Dateien nicht.
        workspace.selectionRange = nil
        workspace.recomputeDocumentStats(fullText: tab.content, selectionNSRange: nil)
    }
}

struct MarkdownVisualWebView: NSViewRepresentable {
    let workspace: Workspace
    let tab: EditorTab
    let fontName: String
    let fontSize: CGFloat
    let darkMode: Bool

    func makeCoordinator() -> MarkdownVisualCoordinator { MarkdownVisualCoordinator() }
    func makeNSView(context: Context) -> MarkdownVisualWKWebView {
        let web = Self.makeWebView(coordinator: context.coordinator)
        updateNSView(web, context: context)
        return web
    }

    static func makeWebView(coordinator: MarkdownVisualCoordinator) -> MarkdownVisualWKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(coordinator.assets, forURLScheme: MarkdownPreviewAssets.scheme)
        configuration.userContentController.add(coordinator, name: "visualMarkdown")
        configuration.userContentController.add(coordinator, name: "markdownCopy")
        configuration.userContentController.add(coordinator, name: "markdownCodeCopy")
        for name in ["turndown-7.2.0.js", "visual-tables.js", "visual-editor.js"] {
            if let url = AppResources.bundle.url(forResource: name, withExtension: nil, subdirectory: "MarkdownVendor")
                ?? AppResources.bundle.url(forResource: name, withExtension: nil),
               let source = try? String(contentsOf: url, encoding: .utf8) {
                configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            }
        }
        let web = MarkdownVisualWKWebView(frame: .zero, configuration: configuration)
        web.visualCoordinator = coordinator
        web.navigationDelegate = coordinator
        coordinator.web = web
        return web
    }
    func updateNSView(_ web: MarkdownVisualWKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.workspace = workspace
        coordinator.tabID = tab.id
        workspace.visualMarkdownEditor = coordinator
        let style = "\(fontName)|\(fontSize)|\(darkMode)|\(tab.url?.path ?? "")"
        let sameContent = coordinator.markdown.utf8.elementsEqual(tab.content.utf8)
        guard !sameContent || coordinator.style != style else { return }
        if coordinator.ready, sameContent, coordinator.documentURL == tab.url {
            coordinator.updateStyle(fontName: fontName, fontSize: fontSize, darkMode: darkMode, style: style)
            return
        }
        coordinator.load(tab.content, documentURL: tab.url,
                         fontName: fontName, fontSize: fontSize, darkMode: darkMode, style: style)
    }
    static func dismantleNSView(_ web: MarkdownVisualWKWebView, coordinator: MarkdownVisualCoordinator) {
        // Schließen und Ansichtswechsel synchronisieren VOR der Entscheidung.
        // Danach darf ein abgebauter Editor verworfene Eingaben nicht nachtragen.
        coordinator.invalidateForSourceReplacement()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.navigationDelegate = nil
        if coordinator.workspace?.visualMarkdownEditor === coordinator {
            coordinator.workspace?.visualMarkdownEditor = nil
        }
    }
}

final class MarkdownVisualWKWebView: WKWebView {
    weak var visualCoordinator: MarkdownVisualCoordinator?

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return super.performDragOperation(sender)
        }
        let images = MarkdownImageStore.partitionDroppedURLs(urls).insert
        guard !images.isEmpty else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        let y = isFlipped ? point.y : bounds.height - point.y
        callAsyncJavaScript("return window.fastraVisual.caret(x, y);", arguments: ["x": point.x, "y": y],
                            in: nil, in: .page) { [weak self] result in
            if case .success(let value) = result, let bookmark = value as? String {
                self?.visualCoordinator?.insertImages(images, bookmark: bookmark)
            }
        }
        return true
    }
}

/// Alle Eingaben sind an Tab, Navigationsgeneration und vorherigen Inhalt
/// gebunden. Ein verspätetes WebKit-Ereignis darf keinen neu geöffneten Tab
/// oder eine externe Änderung überschreiben.
final class MarkdownVisualCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var workspace: Workspace?
    weak var web: WKWebView?
    var tabID: UUID?
    private var loadedDocumentID: UUID?
    private var documentIdentityMatches: Bool {
        // Ohne Workspace kann die WebView weiterhin lesen und kopieren;
        // jeder schreibende Commit benötigt zusätzlich seinen Workspace.
        guard let workspace else { return true }
        guard let tabID, let loadedDocumentID else { return false }
        return workspace.tabs.contains { $0.id == tabID && $0.documentID == loadedDocumentID }
    }
    let assets = MarkdownPreviewSchemeHandler()
    var markdown = ""
    var style = ""
    private(set) var documentURL: URL?
    var pasteboard: NSPasteboard = .general
    var clipboardQueue = DispatchQueue.global(qos: .userInitiated)
    var imageIOQueue = MarkdownImageUndoSideEffect.ioQueue
    static let clipboardType = NSPasteboard.PasteboardType("application/x-fastra-markdown")
    var generation: UInt64 = 0
    private var session = UUID().uuidString
    private var pending: MarkdownVisualDocument?
    private var currentNavigation: WKNavigation?
    private(set) var ready = false
    private var acceptedInputRevision = 0
    private struct ImageTransaction {
        let effect: MarkdownImageUndoSideEffect
        var visible = true
        var insertionUndone = false
    }
    private var imageTransactions: [String: ImageTransaction] = [:]
    private var initialImageTransactions: [String: String] = [:]
    private var reconcilingImages = false
    private var imageReconciliationWaiters: [() -> Void] = []
    private var imageHistoryResetPending = false
    private var currentFontName = PreviewFonts.systemName
    private var currentFontSize: CGFloat = 14
    private var currentDarkMode = false

    private func discardImageUndo() {
        let effects = imageTransactions.values.map(\.effect)
        guard !effects.isEmpty else { initialImageTransactions.removeAll(); return }
        let url = documentURL
        imageTransactions.removeAll()
        initialImageTransactions.removeAll()
        MarkdownImageUndo.performWithReferences(buffer: .shared, work: { opened, gate in
            let references = effects.first?.savedReferences(documentURL: url, opened: opened)
            for effect in effects { effect.discard(unusedBy: references, gate: gate) }
            return true
        }, completion: { _ in })
    }

    deinit { discardImageUndo() }

    /// Der Browser hält Bildaktionen kurz an, bis die Dateiseite abgeschlossen
    /// ist. Text und Dateien werden dadurch in derselben Reihenfolge bestätigt.
    private func reconcileImageUndo(_ visibleIDs: [String], previous: String, inputType: String,
                                    newEdit: Bool, completion: @escaping (Bool) -> Void) {
        let visible = Set(visibleIDs)
        let changes = imageTransactions.filter { $0.value.visible != visible.contains($0.key) }
        let discardedRedo = newEdit && inputType != "historyUndo" && inputType != "historyRedo"
            ? imageTransactions.filter { !$0.value.visible && $0.value.insertionUndone }.map(\.key) : []
        if changes.isEmpty {
            let discarded = discardedRedo.compactMap { imageTransactions.removeValue(forKey: $0)?.effect }
            if !discarded.isEmpty {
                MarkdownImageUndoSideEffect.perform({ discarded.forEach { $0.discard() }; return true }, completion: { _ in })
            }
            completion(true)
            return
        }
        guard !reconcilingImages else { completion(false); return }
        reconcilingImages = true
        let request = generation
        let expectedSession = session
        let url = documentURL
        var opened: [URL: [String]] = [:]
        for owner in Workspace.allLive {
            for tab in owner.tabs where !(owner === workspace && tab.id == tabID) {
                if let url = tab.url { opened[url, default: []].append(tab.content) }
            }
        }
        let referenceCheck = MarkdownImageRemovalCheck()
        let gate = MarkdownImageUndo.removalGate(for: opened, tabID: tabID, workspace: workspace,
            allow: { [weak self] in self?.generation == request && self?.session == expectedSession },
            onStale: { referenceCheck.markStale() })
        MarkdownImageUndoSideEffect.pendingIO.enter()
        imageIOQueue.async { [self] in
            var restored: [MarkdownImageUndoSideEffect] = []
            var success = true
            for (id, transaction) in changes where visible.contains(id) {
                if transaction.effect.redo() { restored.append(transaction.effect) }
                else { success = false; break }
            }
            if success {
                let protected = changes.first?.value.effect.savedReferences(documentURL: url, opened: opened)
                for (id, transaction) in changes where !visible.contains(id) {
                    if let protected {
                        transaction.effect.protectSavedReferences(protected)
                        // Eine fremd veränderte Bilddatei bleibt erhalten. Das
                        // Entfernen ihres Links braucht keinen Dateirücktausch.
                        _ = transaction.effect.undo(gate: gate)
                    }
                }
            } else {
                for effect in restored.reversed() { _ = effect.undo() }
            }
            let invalidations = MarkdownImageUndoBuffer.shared.takeInvalidations()
            DispatchQueue.main.async {
                defer { MarkdownImageUndoSideEffect.pendingIO.leave() }
                guard generation == request, session == expectedSession, documentIdentityMatches else {
                    reconcilingImages = false
                    completion(false)
                    let waiters = imageReconciliationWaiters
                    imageReconciliationWaiters.removeAll()
                    waiters.forEach { $0() }
                    invalidations.forEach { $0() }
                    return
                }
                if referenceCheck.isStale {
                    reconcilingImages = false
                    reconcileImageUndo(visibleIDs, previous: previous, inputType: inputType, newEdit: newEdit) { accepted in
                        completion(accepted)
                        invalidations.forEach { $0() }
                    }
                    return
                }
                if success {
                    for (id, _) in changes {
                        imageTransactions[id]?.visible = visible.contains(id)
                        imageTransactions[id]?.insertionUndone = !visible.contains(id) && inputType == "historyUndo"
                    }
                    let discarded = discardedRedo.filter { !visible.contains($0) }
                        .compactMap { imageTransactions.removeValue(forKey: $0)?.effect }
                    if !discarded.isEmpty {
                        MarkdownImageUndoSideEffect.perform({ discarded.forEach { $0.discard() }; return true }, completion: { _ in })
                    }
                } else {
                    web?.callAsyncJavaScript("return window.fastraVisual.rollbackImageChange(inputType, previous);",
                        arguments: ["inputType": inputType, "previous": previous], in: nil, in: .page) { [weak self] result in
                            guard let self, generation == request else { return }
                            if case .success(let value) = result, value as? Bool == true { return }
                            load(previous, documentURL: documentURL, fontName: currentFontName,
                                 fontSize: currentFontSize, darkMode: currentDarkMode, style: style)
                        }
                    workspace?.saveSafetyWarningHandler(L10n.string("Bild konnte nicht wiederhergestellt werden"),
                        L10n.string("Der Bildpfad ist inzwischen belegt oder nicht beschreibbar. Der Text blieb unverändert. Gib den ursprünglichen Bildpfad frei und versuche Wiederholen erneut."))
                }
                reconcilingImages = false
                completion(success)
                let waiters = imageReconciliationWaiters
                imageReconciliationWaiters.removeAll()
                waiters.forEach { $0() }
                invalidations.forEach { $0() }
            }
        }
    }

    private func completeImageAction(revision: Int) {
        web?.callAsyncJavaScript("window.fastraVisual.completeImageAction(session, revision);",
            arguments: ["session": session, "revision": revision], in: nil, in: .page) { _ in }
    }

    private func resetImageUndoHistory() {
        guard !imageHistoryResetPending, ready else { return }
        imageHistoryResetPending = true
        synchronize(holdingInput: true) { [weak self] success in
            guard let self else { return }
            imageHistoryResetPending = false
            guard success, let workspace, let tabID,
                  let index = workspace.tabs.firstIndex(where: { $0.id == tabID }) else { completeAction(); return }
            let content = workspace.tabs[index].content
            workspace.tabs[index].undoHistory.reset(to: content)
            load(content, documentURL: documentURL, fontName: currentFontName,
                 fontSize: currentFontSize, darkMode: currentDarkMode, style: style)
        }
    }

    func discardForTermination() {
        invalidateForSourceReplacement()
    }

    func documentSaved(at url: URL) {
        guard ready, documentURL == url else { return }
        let transactions = Array(imageTransactions.values)
        guard !transactions.isEmpty else { return }
        let content = markdown
        MarkdownImageUndo.performWithReferences(buffer: .shared, work: { opened, gate in
            guard let protected = transactions.first?.effect.savedReferences(documentURL: url, opened: opened) else { return true }
            let visible = MarkdownImageCleanup.references(content, documentURL: url)
            for transaction in transactions {
                _ = transaction.effect.documentSaved(visible: MarkdownImageCleanup.protects(transaction.effect.currentURLs, in: visible.union(protected)), gate: gate)
            }
            return true
        }, completion: { _ in })
    }

    func load(_ source: String, documentURL: URL?, fontName: String,
              fontSize: CGFloat, darkMode: Bool, style: String) {
        discardImageUndo()
        currentFontName = fontName
        currentFontSize = fontSize
        currentDarkMode = darkMode
        markdown = source
        loadedDocumentID = workspace?.tabs.first(where: { $0.id == tabID })?.documentID
        self.documentURL = documentURL
        self.style = style
        generation &+= 1
        let request = generation
        session = UUID().uuidString
        ready = false
        scheduleTableReset()
        pending = nil
        currentNavigation = nil
        acceptedInputRevision = 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let document = MarkdownVisualDocument.render(source, documentURL: documentURL)
            var existing: [URL: MarkdownImageStore.StoredImage] = [:]
            if let documentURL {
                let directory = documentURL.deletingLastPathComponent().appendingPathComponent("images").standardizedFileURL
                for url in Set(document.fragment.imageURLs.values) where url.deletingLastPathComponent() == directory {
                    if let image = try? MarkdownImageStore.captureExisting(url) { existing[url] = image }
                }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == request, self.documentIdentityMatches, let web = self.web else { return }
                self.pending = document
                for (url, image) in existing {
                    let id = UUID().uuidString
                    self.imageTransactions[id] = ImageTransaction(
                        effect: MarkdownImageUndoSideEffect(images: [image], alreadySaved: true, historyLost: { [weak self] in self?.resetImageUndoHistory() }))
                    for (token, imageURL) in document.fragment.imageURLs where imageURL == url {
                        self.initialImageTransactions[token] = id
                    }
                }
                self.assets.setImageURLs(document.fragment.imageURLs)
                let fragment = MarkdownRenderedFragment(
                    html: "<main id=\"fastra-visual\">\(document.fragment.html)</main>",
                    imageURLs: document.fragment.imageURLs)
                let html = MarkdownRichText.htmlDocument(fragment: fragment, fontName: fontName,
                                                         fontSize: fontSize, darkMode: darkMode, blockUpdates: false)
                    .replacingOccurrences(of: "</style>", with: "#fastra-visual { outline: none; min-height: calc(100vh - 40px); } #fastra-visual > div:first-child > :first-child { margin-top: 0; } #fastra-visual [contenteditable=false] { user-select: all; } #fastra-visual table[data-md-table=gfm] :is(td,th) { white-space: pre-wrap; } #fastra-visual img[data-md-selected-image] { outline: 3px solid -apple-system-control-accent; outline-offset: 2px; }</style>")
                web.underPageBackgroundColor = darkMode ? NSColor(srgbRed: 0.09, green: 0.09, blue: 0.09, alpha: 1) : .white
                self.currentNavigation = web.loadHTMLString(html, baseURL: nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === currentNavigation, let pending else { return }
        let request = generation
        let data = try? JSONEncoder().encode(pending.blocks)
        guard let data,
              let blocks = try? JSONSerialization.jsonObject(with: data) else { return }
        webView.callAsyncJavaScript("return await window.fastraVisual.start(configuration);",
            arguments: ["configuration": ["blocks": blocks, "opaqueSources": pending.opaqueSources, "markdown": markdown, "session": session, "imageTransactions": initialImageTransactions]],
            in: nil, in: .page) { [weak self] result in
                guard let self, self.generation == request, self.documentIdentityMatches else { return }
                if case .success(let value) = result, value as? Bool == true {
                    self.ready = true
                    self.reportOutlinePosition()
                    self.reportTableContext()
                    Task { @MainActor [weak self] in
                        guard let self, let workspace = self.workspace, self.ready,
                              workspace.visualMarkdownEditor === self else { return }
                        workspace.markdownVisualFind.editorBecameReady(in: workspace)
                    }
                } else {
                    self.workspace?.saveSafetyWarningHandler(L10n.string("Markdown-Ansicht konnte nicht gestartet werden"),
                        L10n.string("Der Dokumentinhalt blieb erhalten. Bitte öffne das Dokument erneut oder wechsle mit dem Umschalter zur Quelltext-Ansicht."))
                }
            }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, documentIdentityMatches,
              let body = message.body as? [String: Any] else { return }
        if message.name == "markdownCodeCopy" {
            MarkdownPresentation.copyCode(body, in: message.webView, pasteboard: pasteboard)
            return
        }
        if message.name == "markdownCopy", let plain = body["plain"] as? String,
           let html = body["html"] as? String {
            guard body["session"] as? String == session else { return }
            guard let copied = body["markdown"] as? String else { return }
            copySelection(plain: plain, html: html, copied: copied,
                          bookmark: body["bookmark"] as? String ?? "", cut: body["cut"] as? Bool == true)
            return
        }
        guard body["session"] as? String == session,
              let workspace, let tabID else { return }
        switch body["kind"] as? String {
        case "tableContext":
            guard workspace.activeTabID == tabID, workspace.visualMarkdownEditor === self,
                  body["revision"] as? Int == acceptedInputRevision else { return }
            workspace.markdownTable.update(body["context"] as? [String: Any])
        case "tableError":
            guard workspace.activeTabID == tabID, workspace.visualMarkdownEditor === self else { return }
            workspace.markdownTable.showError(body["reason"] as? String ?? "stale")
        case "outlinePosition":
            guard workspace.activeTabID == tabID, body["revision"] as? Int == acceptedInputRevision,
                  let index = body["index"] as? Int else { return }
            workspace.documentOutline.followVisualHeading(index)
        case "change":
            guard let base = body["base"] as? String,
                  let value = body["markdown"] as? String,
                  workspace.tabs.contains(where: { $0.id == tabID && $0.content.utf8.elementsEqual(base.utf8) }) else { return }
            let revision = body["revision"] as? Int ?? acceptedInputRevision
            reconcileImageUndo(body["imageTransactions"] as? [String] ?? [], previous: base,
                               inputType: body["inputType"] as? String ?? "", newEdit: true) { [self] success in
                if success, documentIdentityMatches, workspace.acceptVisualMarkdown(value, previous: base, tabID: tabID) {
                    markdown = value
                    acceptedInputRevision = revision
                    reportTableContext()
                }
                completeImageAction(revision: revision)
            }
        case "imageMenu":
            guard let web, let x = body["x"] as? Double, let y = body["y"] as? Double else { return }
            let menu = NSMenu()
            let item = NSMenuItem(title: L10n.string("Löschen"), action: #selector(deleteSelectedImage), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.popUp(positioning: nil, at: NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y), in: web)
        case "pasteImage", "pasteMarkdown": _ = pasteImages(bookmark: body["bookmark"] as? String)
        default: break
        }
    }

    func revealHeading(_ index: Int) {
        guard ready else { return }
        web?.callAsyncJavaScript("return window.fastraVisual.revealHeading(index);",
                                 arguments: ["index": index], in: nil, in: .page) { _ in }
    }

    func reportOutlinePosition() {
        guard ready, let workspace, workspace.activeTabID == tabID else { return }
        let request = generation
        let source = markdown
        web?.callAsyncJavaScript("return window.fastraVisual.outlinePosition();", arguments: [:], in: nil, in: .page) { [weak self, weak workspace] result in
            guard let self, let workspace, self.generation == request, workspace.activeTabID == self.tabID,
                  self.markdown == source, workspace.activeTab?.content == source,
                  case .success(let value) = result, let index = value as? Int else { return }
            workspace.documentOutline.followVisualHeading(index)
        }
    }

    @objc private func deleteSelectedImage() {
        guard ready else { return }
        web?.evaluateJavaScript("window.fastraVisual.command('deleteImage');", completionHandler: nil)
    }

    func copySelection(plain: String, html: String, copied: String, bookmark: String, cut: Bool) {
        let sourceURL = documentURL, request = generation, capturedSession = session
        let imageURLs = assets.imageURLSnapshot()
        let clipboardRequest = MarkdownPasteboard.beginCopy(to: pasteboard)
        clipboardQueue.async { [self] in
            let result = Result { () -> (Data, MarkdownClipboardImages.Transport) in
                let images = try sourceURL.map { try MarkdownSaveAs.clipboardImages(content: copied, sourceURL: $0) } ?? [:]
                // String-Werte erhalten das bisherige private Paketformat.
                let encodedImages = try JSONEncoder().encode(images).base64EncodedString()
                let data = try JSONSerialization.data(withJSONObject: ["markdown": copied, "url": sourceURL?.absoluteString ?? "", "images": encodedImages])
                let transport = MarkdownClipboardImages.prepare(html, imageURLs: imageURLs, loadImages: true, imageData: images)
                return (data, transport)
            }
            DispatchQueue.main.async { [self] in
                var published = false
                switch result {
                case .success(let (data, transport)):
                    published = MarkdownPasteboard.write(plain: plain, htmlFragment: html, to: pasteboard,
                        additionalData: [Self.clipboardType: data], imageTransport: transport,
                        copyRequest: clipboardRequest)
                case .failure(let error):
                    MarkdownPasteboard.finishCopy(clipboardRequest)
                    workspace?.saveSafetyWarningHandler(L10n.string("Bild einfügen"), error.localizedDescription)
                }
                // Die Kopie gehört der Zwischenablage; nur das Ausschneiden
                // bleibt an den noch gültigen Quell-DOM gebunden.
                guard generation == request, session == capturedSession else { return }
                web?.callAsyncJavaScript("return window.fastraVisual.completeClipboard(bookmark, cut, succeeded);",
                    arguments: ["bookmark": bookmark, "cut": cut, "succeeded": published], in: nil, in: .page) { _ in }
            }
        }
    }

    /// WebKit liefert Eingaben asynchron. Speichern und Ansichtswechsel warten
    /// deshalb auf den aktuellen DOM-Stand, bevor sie den nativen Tab benutzen.
    func synchronize(holdingInput: Bool = false, _ completion: @escaping (Bool) -> Void) {
        if reconcilingImages {
            imageReconciliationWaiters.append { [weak self] in
                guard let self else { completion(false); return }
                synchronize(holdingInput: holdingInput, completion)
            }
            return
        }
        guard ready, let web else { completion(true); return }
        guard documentIdentityMatches else { completion(false); return }
        let request = generation
        let requestSession = session
        web.callAsyncJavaScript("return window.fastraVisual.prepareAction();",
                                arguments: [:], in: nil, in: .page) { [self] result in
            guard generation == request else { completion(false); return }
            if case .success(let value) = result, let snapshot = value as? [String: Any], snapshot["composing"] as? Bool == true {
                workspace?.saveSafetyWarningHandler(L10n.string("Texteingabe noch nicht abgeschlossen"),
                    L10n.string("Bitte schließe die aktuelle Zeicheneingabe ab und führe den Befehl danach erneut aus."))
                completion(false)
                return
            }
            guard generation == request, documentIdentityMatches, let workspace, let tabID,
                  case .success(let value) = result, let snapshot = value as? [String: Any],
                  let content = snapshot["markdown"] as? String,
                  let revision = snapshot["revision"] as? Int, revision >= acceptedInputRevision else {
                if generation == request { completeAction(session: requestSession) }
                completion(false)
                return
            }
            guard workspace.tabs.contains(where: { $0.id == tabID && $0.content.utf8.elementsEqual(markdown.utf8) }) else {
                warnUnacceptedInput()
                completeAction(session: requestSession); completion(false); return
            }
            reconcileImageUndo(snapshot["imageTransactions"] as? [String] ?? [], previous: markdown,
                               inputType: snapshot["inputType"] as? String ?? "", newEdit: revision > acceptedInputRevision) { [self] success in
                let accepted = success && documentIdentityMatches && workspace.acceptVisualMarkdown(content, previous: markdown, tabID: tabID)
                if accepted { markdown = content; acceptedInputRevision = revision }
                else {
                    warnUnacceptedInput()
                }
                completeImageAction(revision: revision)
                completion(accepted)
                if generation == request, !holdingInput || !accepted { completeAction(session: requestSession) }
            }
        }
    }

    private func warnUnacceptedInput() {
        workspace?.saveSafetyWarningHandler(L10n.string("Markdown-Eingabe noch nicht übernommen"),
            L10n.string("Das Dokument wurde gleichzeitig geändert. Bitte sichere deine sichtbare Eingabe, bevor du die Ansicht schließt."))
    }

    func completeAction(session expectedSession: String? = nil) {
        guard ready else { return }
        web?.callAsyncJavaScript("window.fastraVisual.completeAction(session);",
            arguments: ["session": expectedSession ?? session], in: nil, in: .page) { _ in }
    }

    /// Nach einem neuen Speicherziel darf der alte DOM nicht wieder Eingaben
    /// annehmen, während seine Bildpfade und Dokumentbasis ersetzt werden.
    func invalidateForSourceReplacement() {
        discardImageUndo()
        ready = false
        scheduleTableReset()
        generation &+= 1
        pending = nil
        currentNavigation = nil
    }

    func updateStyle(fontName: String, fontSize: CGFloat, darkMode: Bool, style: String) {
        self.style = style
        currentFontName = fontName
        currentFontSize = fontSize
        currentDarkMode = darkMode
        web?.callAsyncJavaScript("window.fastraVisual.updateStyle(font, size, dark);",
            arguments: ["font": fontName == PreviewFonts.systemName ? "System" : fontName,
                        "size": fontSize, "dark": darkMode], in: nil, in: .page) { _ in }
        web?.underPageBackgroundColor = darkMode ? NSColor(srgbRed: 0.09, green: 0.09, blue: 0.09, alpha: 1) : .white
    }

    func format(_ command: MarkdownFormatCommand) {
        guard ready, let workspace, workspace.activeTabID == tabID else { return }
        let names = ["bold", "italic", "code", "heading1", "heading2", "heading3",
                     "plainParagraph", "bulletList", "orderedList", "quote", "link",
                     "insertTable", "highlight", "hardBreak", "taskList"]
        var value = ""
        if command == .link {
            let alert = NSAlert()
            alert.messageText = L10n.string("Link einfügen")
            let field = NSTextField(string: "https://")
            field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.addButton(withTitle: L10n.string("Einfügen"))
            alert.addButton(withTitle: L10n.string("Abbrechen"))
            guard alert.runModal() == .alertFirstButtonReturn,
                  MarkdownHTMLWhitelist.isSafeLink(field.stringValue) else { return }
            value = field.stringValue
        } else if command == .insertTable {
            guard let configuration = MarkdownAssist.promptForTable() else { return }
            let header = "<tr>" + String(repeating: "<th><br></th>", count: configuration.columns) + "</tr>"
            let row = "<tr>" + String(repeating: "<td><br></td>", count: configuration.columns) + "</tr>"
            value = "<table data-md-table=\"gfm\"><thead>" + header + "</thead><tbody>"
                + row + (configuration.header ? "" : row) + "</tbody></table><p><br></p>"
        }
        execute(names[command.rawValue], value: value)
        MarkdownAssist.noteFirstUse(in: workspace)
    }

    func execute(_ command: String, value: String) {
        web?.callAsyncJavaScript("window.fastraVisual.command(command, value);",
                                 arguments: ["command": command, "value": value], in: nil, in: .page) { _ in }
    }

    func reportTableContext() {
        guard ready, let web else { return }
        let request = generation
        web.evaluateJavaScript("window.fastraVisual.tableState()") { [weak self] value, _ in
            guard let self, self.ready, self.generation == request, let workspace = self.workspace,
                  workspace.activeTabID == self.tabID, workspace.visualMarkdownEditor === self,
                  let state = value as? [String: Any], state["revision"] as? Int == self.acceptedInputRevision,
                  let content = workspace.activeTab?.content, content.utf8.elementsEqual(self.markdown.utf8) else { return }
            workspace.markdownTable.update(state["context"] as? [String: Any])
        }
    }

    private func scheduleTableReset() {
        let request = generation, tab = tabID
        // dismantleNSView läuft auch während der Zerstörung des SwiftUI-Graphen.
        // Ein Publisher darf diesen Graphen erst im nächsten Durchlauf ändern.
        DispatchQueue.main.async { [weak self, weak workspace] in
            guard let workspace, workspace.activeTabID == tab else { return }
            if let editor = workspace.visualMarkdownEditor, editor !== self { return }
            if let self, self.generation != request { return }
            workspace.markdownTable.clear()
        }
    }

    func editTable(_ command: String, value: String, token: String, completion: @escaping (String?) -> Void) {
        guard ready, let workspace, workspace.activeMarkdownIsVisual, workspace.activeTabID == tabID,
              workspace.visualMarkdownEditor === self, let content = workspace.activeTab?.content,
              content.utf8.elementsEqual(markdown.utf8) else { completion("stale"); return }
        let request = generation
        web?.callAsyncJavaScript("return window.fastraVisual.tableCommand(command, value, token);",
            arguments: ["command": command, "value": value, "token": token], in: nil, in: .page) { [weak self] result in
                guard let self, self.generation == request, self.ready else { completion("stale"); return }
                if case .success(let value) = result, let body = value as? [String: Any], body["ok"] as? Bool == true {
                    completion(nil)
                } else if case .success(let value) = result, let body = value as? [String: Any] {
                    completion(body["reason"] as? String ?? "stale")
                } else { completion("stale") }
            }
    }

    @discardableResult
    func pasteImages(bookmark: String? = nil) -> Bool {
        if let data = pasteboard.data(forType: Self.clipboardType),
           let package = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let source = package["markdown"] {
            let images = package["images"].flatMap { Data(base64Encoded: $0) }
                .flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
            insertMarkdown(source, from: package["url"].flatMap(URL.init(string:)), bookmark: bookmark, imageData: images)
            return true
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let images = MarkdownImageStore.partitionDroppedURLs(urls).insert
            if !images.isEmpty { insertImages(images, bookmark: bookmark); return true }
        }
        guard let (data, type) = MarkdownAssist.readImageData(from: pasteboard),
              let prepared = MarkdownImageStore.prepare(imageData: data, typeIdentifier: type) else { return false }
        storeImages(bookmark: bookmark) { url in [try MarkdownImageStore.storePastedData(prepared, documentURL: url, reserveForTransaction: true)] }
        return true
    }

    func insertImages(_ urls: [URL], bookmark: String? = nil) {
        storeImages(bookmark: bookmark) { documentURL in
            var images: [MarkdownImageStore.StoredImage] = []
            do {
                for url in urls { images.append(try MarkdownImageStore.storeImageFile(url, documentURL: documentURL, reserveForTransaction: true)) }
                return images
            } catch {
                MarkdownSaveAs.Prepared(content: "", createdImages: images.filter(\.createdByInsertion)).rollback()
                throw error
            }
        }
    }

    struct InsertionBookmark {
        fileprivate let key: String
        fileprivate let generation: UInt64
        fileprivate let session: String
        fileprivate let tabID: UUID
        fileprivate let documentID: UUID
        fileprivate let url: URL?
    }

    @MainActor
    func captureInsertionBookmark(_ completion: @escaping (Result<InsertionBookmark, Error>) -> Void) {
        guard ready, let workspace, let web, let tabID, workspace.activeTabID == tabID,
              let documentID = workspace.activeDocumentID, workspace.activeMarkdownIsVisual else {
            completion(.failure(TextSnippetError.unavailable)); return
        }
        let request = generation, capturedSession = session, url = workspace.activeTab?.url
        func current() -> Bool {
            self.ready && self.generation == request && self.session == capturedSession
                && workspace.visualMarkdownEditor === self && workspace.activeTabID == tabID
                && workspace.activeDocumentID == documentID && workspace.activeTab?.url == url
                && workspace.activeMarkdownIsVisual
        }
        synchronize(holdingInput: true) { [weak self] success in
            guard let self else { completion(.failure(TextSnippetError.staleTarget)); return }
            guard success, current() else {
                self.completeAction(session: capturedSession)
                completion(.failure(TextSnippetError.staleTarget)); return
            }
            web.callAsyncJavaScript("return window.fastraVisual.bookmark();", arguments: [:], in: nil, in: .page) { result in
                defer { self.completeAction(session: capturedSession) }
                guard current(), case .success(let value) = result, let key = value as? String else {
                    completion(.failure(TextSnippetError.staleTarget)); return
                }
                completion(.success(InsertionBookmark(key: key, generation: request, session: capturedSession,
                    tabID: tabID, documentID: documentID, url: url)))
            }
        }
    }

    @MainActor
    func ownsInsertionBookmark(_ bookmark: InsertionBookmark) -> Bool {
        guard let workspace else { return false }
        return ready && generation == bookmark.generation && session == bookmark.session
            && workspace.visualMarkdownEditor === self && workspace.activeTabID == bookmark.tabID
            && workspace.activeDocumentID == bookmark.documentID && workspace.activeTab?.url == bookmark.url
            && workspace.activeMarkdownIsVisual
    }

    @MainActor
    func discardInsertionBookmark(_ bookmark: InsertionBookmark) {
        guard generation == bookmark.generation, session == bookmark.session else { return }
        web?.callAsyncJavaScript("return window.fastraVisual.discardBookmark(bookmark);",
            arguments: ["bookmark": bookmark.key], in: nil, in: .page) { _ in }
    }

    @MainActor
    func insertTextSnippet(_ source: String, at bookmark: InsertionBookmark, completion: @escaping (Bool) -> Void) {
        guard ownsInsertionBookmark(bookmark) else { completion(false); return }
        insertMarkdown(source, from: nil, bookmark: bookmark.key,
            actionTitle: L10n.string("Textbaustein einfügen"), completion: { [weak self] inserted in
                guard inserted, let self else { completion(false); return }
                self.synchronize { accepted in completion(accepted) }
            })
    }

    private func storeImages(bookmark: String?, _ operation: @escaping (URL) throws -> [MarkdownImageStore.StoredImage]) {
        insertPrepared(bookmark: bookmark) { url in
            guard let url else { throw MarkdownImageStore.StoreError.documentNotSaved }
            let images = try operation(url)
            return MarkdownSaveAs.Prepared(content: images.map(\.link).joined(separator: "\n\n"),
                                           createdImages: images.filter(\.createdByInsertion))
        }
    }

    private func insertMarkdown(_ source: String, from sourceURL: URL?, bookmark: String?, imageData: [String: Data] = [:],
                                actionTitle: String = L10n.string("Bild einfügen"), completion: @escaping (Bool) -> Void = { _ in }) {
        insertPrepared(bookmark: bookmark, actionTitle: actionTitle, completion: completion) { target in
            guard let target else {
                if !MarkdownVisualDocument.render(source, documentURL: sourceURL).fragment.imageURLs.isEmpty {
                    throw MarkdownImageStore.StoreError.documentNotSaved
                }
                return MarkdownSaveAs.Prepared(content: source, createdImages: [])
            }
            if let sourceURL { return try MarkdownSaveAs.prepare(content: source, sourceURL: sourceURL, targetURL: target, copyImagesInSameDirectory: true, imageData: imageData) }
            return MarkdownSaveAs.Prepared(content: source, createdImages: [])
        }
    }

    private func insertPrepared(bookmark: String?, actionTitle: String = L10n.string("Bild einfügen"),
                                completion: @escaping (Bool) -> Void = { _ in },
                                _ operation: @escaping (URL?) throws -> MarkdownSaveAs.Prepared) {
        guard ready, documentIdentityMatches, let workspace, workspace.activeTabID == tabID,
              let web else {
            self.workspace?.saveSafetyWarningHandler(actionTitle, MarkdownImageStore.StoreError.documentNotSaved.localizedDescription)
            completion(false); return
        }
        let url = workspace.activeTab?.url
        let capturedSession = session
        let request = generation
        func isCurrent() -> Bool {
            self.ready && self.documentIdentityMatches && self.generation == request && self.session == capturedSession
                && workspace.visualMarkdownEditor === self
                && workspace.activeTabID == self.tabID && workspace.activeTab?.url == url
                && workspace.activeMarkdownIsVisual
        }
        web.callAsyncJavaScript("return window.fastraVisual.bookmark(bookmark);", arguments: ["bookmark": bookmark ?? ""], in: nil, in: .page) { [weak self] bookmarkResult in
            guard self != nil, isCurrent() else { completion(false); return }
            guard case .success(let bookmark) = bookmarkResult, let bookmark = bookmark as? String else {
                workspace.saveSafetyWarningHandler(L10n.string("Einfügen abgebrochen"),
                    L10n.string("Die Einfügestelle konnte nicht festgehalten werden. Bitte versuche es erneut."))
                completion(false); return
            }
            MarkdownImageUndoSideEffect.pendingIO.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { () -> (MarkdownSaveAs.Prepared, MarkdownVisualDocument) in
                    let prepared = try operation(url)
                    return (prepared, MarkdownVisualDocument.render(prepared.content, documentURL: url))
                }
                DispatchQueue.main.async {
                    guard let self, isCurrent() else {
                        if case .success(let (prepared, _)) = result {
                            MarkdownImageUndoSideEffect.perform({ prepared.rollback(); return true }, completion: { _ in })
                        }
                        MarkdownImageUndoSideEffect.pendingIO.leave()
                        completion(false); return
                    }
                    switch result {
                    case .success(let (prepared, visual)):
                        self.assets.addImageURLs(visual.fragment.imageURLs)
                        // Neue IDs sind von den Originalblöcken unabhängig.
                        // Der Einfügeschritt selbst bleibt ein WebKit-Undo-Schritt.
                        let html = visual.blocks.map(\.html).joined()
                        let transactionID = UUID().uuidString
                        let created = prepared.createdImages
                        if !created.isEmpty {
                            self.imageTransactions[transactionID] = ImageTransaction(effect: MarkdownImageUndoSideEffect(images: created, historyLost: { [weak self] in self?.resetImageUndoHistory() }))
                        }
                        let createdURLs = Set(created.map(\.fileURL))
                        let imageSources = visual.fragment.imageURLs.filter { createdURLs.contains($0.value) }
                            .map { "fastra-preview://image/" + $0.key }
                        web.callAsyncJavaScript("return window.fastraVisual.insertBookmarked(bookmark, html, atoms, transaction, imageSources, singleLine);",
                            arguments: ["bookmark": bookmark, "html": html, "atoms": visual.opaqueSources, "transaction": transactionID, "imageSources": imageSources, "singleLine": !prepared.content.contains("\n") && !prepared.content.contains("\r")], in: nil, in: .page) { result in
                                defer { MarkdownImageUndoSideEffect.pendingIO.leave() }
                                if case .success(let inserted) = result, inserted as? Bool == true {
                                    prepared.commit(); completion(true)
                                }
                                else {
                                    self.imageTransactions.removeValue(forKey: transactionID)?.effect.discard()
                                    MarkdownImageUndoSideEffect.perform({ prepared.rollback(); return true }, completion: { _ in })
                                    guard isCurrent() else { completion(false); return }
                                    workspace.saveSafetyWarningHandler(L10n.string("Einfügen abgebrochen"),
                                        L10n.string("Das Dokument wurde während des Einfügens bearbeitet. Die vorhandene Eingabe blieb erhalten; bitte füge erneut ein."))
                                    completion(false)
                                }
                            }
                    case .failure(let error):
                        MarkdownImageUndoSideEffect.pendingIO.leave()
                        workspace.saveSafetyWarningHandler(actionTitle, error.localizedDescription)
                        completion(false)
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.navigationType == .other && action.request.url?.scheme == "about" ? .allow : .cancel)
    }
}
