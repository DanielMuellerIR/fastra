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
        for name in ["turndown-7.2.0.js", "visual-editor.js"] {
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
        guard coordinator.markdown != tab.content || coordinator.style != style else { return }
        if coordinator.ready, coordinator.markdown == tab.content, coordinator.documentURL == tab.url {
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
    let assets = MarkdownPreviewSchemeHandler()
    var markdown = ""
    var style = ""
    private(set) var documentURL: URL?
    var pasteboard: NSPasteboard = .general
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

    private func discardImageUndo() {
        for transaction in imageTransactions.values { transaction.effect.discard() }
        imageTransactions.removeAll()
    }

    deinit { discardImageUndo() }

    /// WebKits Undo stellt die konkreten Bildknoten samt Transaktions-ID wieder
    /// her. Gleichlautende Links oder Bilder anderer Fenster sind kein Signal.
    private func reconcileImageUndo(_ visibleIDs: [String], previous: String, inputType: String, newEdit: Bool) -> Bool {
        let visible = Set(visibleIDs)
        let discardedRedo = newEdit && inputType != "historyUndo" && inputType != "historyRedo"
            ? imageTransactions.filter { !$0.value.visible && $0.value.insertionUndone }.map(\.key) : []
        var applied: [(String, ImageTransaction)] = []
        for (id, transaction) in imageTransactions where transaction.visible != visible.contains(id) {
            let show = visible.contains(id)
            let succeeded = show ? transaction.effect.redo() : transaction.effect.undo()
            guard succeeded else {
                for (key, previousState) in applied.reversed() {
                    if previousState.visible { imageTransactions[key]?.effect.redo() }
                    else { imageTransactions[key]?.effect.undo() }
                    imageTransactions[key] = previousState
                }
                web?.callAsyncJavaScript("window.fastraVisual.rollbackImageChange(inputType, previous);",
                    arguments: ["inputType": inputType, "previous": previous], in: nil, in: .page) { _ in }
                workspace?.saveSafetyWarningHandler(L10n.string("Bild einfügen"),
                    L10n.string("Die Bilddatei wurde außerhalb des Editors geändert. Der Bearbeitungsschritt wurde zurückgenommen, damit kein falsches Bild verknüpft wird."))
                return false
            }
            applied.append((id, transaction))
            imageTransactions[id]?.visible = show
            imageTransactions[id]?.insertionUndone = !show && inputType == "historyUndo"
        }
        for id in discardedRedo where !visible.contains(id) {
            imageTransactions.removeValue(forKey: id)?.effect.discard()
        }
        return true
    }

    func load(_ source: String, documentURL: URL?, fontName: String,
              fontSize: CGFloat, darkMode: Bool, style: String) {
        discardImageUndo()
        markdown = source
        self.documentURL = documentURL
        self.style = style
        generation &+= 1
        let request = generation
        session = UUID().uuidString
        ready = false
        pending = nil
        currentNavigation = nil
        acceptedInputRevision = 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let document = MarkdownVisualDocument.render(source, documentURL: documentURL)
            DispatchQueue.main.async {
                guard let self, self.generation == request, let web = self.web else { return }
                self.pending = document
                self.assets.setImageURLs(document.fragment.imageURLs)
                let fragment = MarkdownRenderedFragment(
                    html: "<main id=\"fastra-visual\">\(document.fragment.html)</main>",
                    imageURLs: document.fragment.imageURLs)
                let html = MarkdownRichText.htmlDocument(fragment: fragment, fontName: fontName,
                                                         fontSize: fontSize, darkMode: darkMode)
                    .replacingOccurrences(of: "</style>", with: "#fastra-visual { outline: none; min-height: calc(100vh - 40px); } #fastra-visual > div:first-child > :first-child { margin-top: 0; } #fastra-visual [contenteditable=false] { user-select: all; }</style>")
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
            arguments: ["configuration": ["blocks": blocks, "opaqueSources": pending.opaqueSources, "markdown": markdown, "session": session]],
            in: nil, in: .page) { [weak self] result in
                guard let self, self.generation == request else { return }
                if case .success(let value) = result, value as? Bool == true {
                    self.ready = true
                } else {
                    self.workspace?.saveSafetyWarningHandler(L10n.string("Markdown-Ansicht konnte nicht gestartet werden"),
                        L10n.string("Der Dokumentinhalt blieb erhalten. Bitte öffne das Dokument erneut oder wechsle mit dem Umschalter zur Quelltext-Ansicht."))
                }
            }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any] else { return }
        if message.name == "markdownCopy", let plain = body["plain"] as? String,
           let html = body["html"] as? String {
            guard body["session"] as? String == session else { return }
            guard let copied = body["markdown"] as? String else { return }
            let sourceURL = documentURL, request = generation, capturedSession = session
            let imageURLs = assets.imageURLSnapshot()
            let changeCount = pasteboard.changeCount
            let bookmark = body["bookmark"] as? String ?? ""
            let cut = body["cut"] as? Bool == true
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let result = Result { () -> (Data, MarkdownClipboardImages.Transport) in
                    let images = try sourceURL.map { try MarkdownSaveAs.clipboardImages(content: copied, sourceURL: $0) } ?? [:]
                    // String-Werte erhalten das bisherige private Paketformat.
                    let encodedImages = try JSONEncoder().encode(images).base64EncodedString()
                    let data = try JSONSerialization.data(withJSONObject: ["markdown": copied, "url": sourceURL?.absoluteString ?? "", "images": encodedImages])
                    let transport = MarkdownClipboardImages.prepare(html, imageURLs: imageURLs, loadImages: true)
                    return (data, transport)
                }
                DispatchQueue.main.async { [self] in
                    guard generation == request, session == capturedSession else { return }
                    var published = false
                    switch result {
                    case .success(let (data, transport)):
                        if pasteboard.changeCount == changeCount {
                            published = MarkdownPasteboard.write(plain: plain, htmlFragment: html, to: pasteboard,
                                additionalData: [Self.clipboardType: data], imageTransport: transport)
                        }
                    case .failure(let error):
                        workspace?.saveSafetyWarningHandler(L10n.string("Bild einfügen"), error.localizedDescription)
                    }
                    web?.callAsyncJavaScript("return window.fastraVisual.completeClipboard(bookmark, cut, succeeded);",
                        arguments: ["bookmark": bookmark, "cut": cut, "succeeded": published], in: nil, in: .page) { _ in }
                }
            }
            return
        }
        guard body["session"] as? String == session,
              let workspace, let tabID else { return }
        switch body["kind"] as? String {
        case "change":
            guard let base = body["base"] as? String,
                  let value = body["markdown"] as? String,
                  workspace.tabs.contains(where: { $0.id == tabID && $0.content == base }),
                  reconcileImageUndo(body["imageTransactions"] as? [String] ?? [], previous: base,
                                     inputType: body["inputType"] as? String ?? "", newEdit: true),
                  workspace.acceptVisualMarkdown(value, previous: base, tabID: tabID) else { return }
            markdown = value
            acceptedInputRevision = body["revision"] as? Int ?? acceptedInputRevision
        case "pasteImage", "pasteMarkdown": _ = pasteImages(bookmark: body["bookmark"] as? String)
        default: break
        }
    }

    /// WebKit liefert Eingaben asynchron. Speichern und Ansichtswechsel warten
    /// deshalb auf den aktuellen DOM-Stand, bevor sie den nativen Tab benutzen.
    func synchronize(holdingInput: Bool = false, _ completion: @escaping (Bool) -> Void) {
        guard ready, let web else { completion(true); return }
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
            guard generation == request, let workspace, let tabID,
                  case .success(let value) = result, let snapshot = value as? [String: Any],
                  let content = snapshot["markdown"] as? String,
                  let revision = snapshot["revision"] as? Int, revision >= acceptedInputRevision else {
                if generation == request { completeAction(session: requestSession) }
                completion(false)
                return
            }
            let accepted = workspace.tabs.contains(where: { $0.id == tabID && $0.content == markdown })
                && reconcileImageUndo(snapshot["imageTransactions"] as? [String] ?? [], previous: markdown,
                                      inputType: snapshot["inputType"] as? String ?? "", newEdit: revision > acceptedInputRevision)
                && workspace.acceptVisualMarkdown(content, previous: markdown, tabID: tabID)
            if accepted { markdown = content; acceptedInputRevision = revision }
            else {
                workspace.saveSafetyWarningHandler(L10n.string("Markdown-Eingabe noch nicht übernommen"),
                    L10n.string("Das Dokument wurde gleichzeitig geändert. Bitte sichere deine sichtbare Eingabe, bevor du die Ansicht schließt."))
            }
            completion(accepted)
            if generation == request, !holdingInput || !accepted { completeAction(session: requestSession) }
        }
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
        generation &+= 1
        pending = nil
        currentNavigation = nil
    }

    func updateStyle(fontName: String, fontSize: CGFloat, darkMode: Bool, style: String) {
        self.style = style
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
            let cell = configuration.header ? "th" : "td"
            value = "<table><tbody><tr>" + String(repeating: "<\(cell)> </\(cell)>", count: configuration.columns)
                + "</tr><tr>" + String(repeating: "<td> </td>", count: configuration.columns) + "</tr></tbody></table><p><br></p>"
        }
        execute(names[command.rawValue], value: value)
        MarkdownAssist.noteFirstUse(in: workspace)
    }

    func execute(_ command: String, value: String) {
        web?.callAsyncJavaScript("window.fastraVisual.command(command, value);",
                                 arguments: ["command": command, "value": value], in: nil, in: .page) { _ in }
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

    private func storeImages(bookmark: String?, _ operation: @escaping (URL) throws -> [MarkdownImageStore.StoredImage]) {
        insertPrepared(bookmark: bookmark) { url in
            guard let url else { throw MarkdownImageStore.StoreError.documentNotSaved }
            let images = try operation(url)
            return MarkdownSaveAs.Prepared(content: images.map(\.link).joined(separator: "\n\n"),
                                           createdImages: images.filter(\.createdByInsertion))
        }
    }

    private func insertMarkdown(_ source: String, from sourceURL: URL?, bookmark: String?, imageData: [String: Data] = [:]) {
        insertPrepared(bookmark: bookmark) { target in
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

    private func insertPrepared(bookmark: String?, _ operation: @escaping (URL?) throws -> MarkdownSaveAs.Prepared) {
        guard ready, let workspace, workspace.activeTabID == tabID,
              let web else {
            self.workspace?.saveSafetyWarningHandler(L10n.string("Bild einfügen"), MarkdownImageStore.StoreError.documentNotSaved.localizedDescription)
            return
        }
        let url = workspace.activeTab?.url
        let capturedSession = session
        let request = generation
        func isCurrent() -> Bool {
            self.ready && self.generation == request && self.session == capturedSession
                && workspace.visualMarkdownEditor === self
                && workspace.activeTabID == self.tabID && workspace.activeTab?.url == url
                && workspace.activeMarkdownIsVisual
        }
        web.callAsyncJavaScript("return window.fastraVisual.bookmark(bookmark);", arguments: ["bookmark": bookmark ?? ""], in: nil, in: .page) { [weak self] bookmarkResult in
            guard self != nil, isCurrent() else { return }
            guard case .success(let bookmark) = bookmarkResult, let bookmark = bookmark as? String else {
                workspace.saveSafetyWarningHandler(L10n.string("Einfügen abgebrochen"),
                    L10n.string("Die Einfügestelle konnte nicht festgehalten werden. Bitte versuche es erneut."))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { () -> (MarkdownSaveAs.Prepared, MarkdownVisualDocument) in
                    let prepared = try operation(url)
                    return (prepared, MarkdownVisualDocument.render(prepared.content, documentURL: url))
                }
                DispatchQueue.main.async {
                    guard let self, isCurrent() else {
                        if case .success(let (prepared, _)) = result { DispatchQueue.global(qos: .utility).async { prepared.rollback() } }
                        return
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
                            self.imageTransactions[transactionID] = ImageTransaction(effect: MarkdownImageUndoSideEffect(images: created))
                        }
                        let createdURLs = Set(created.map(\.fileURL))
                        let imageSources = visual.fragment.imageURLs.filter { createdURLs.contains($0.value) }
                            .map { "fastra-preview://image/" + $0.key }
                        web.callAsyncJavaScript("return window.fastraVisual.insertBookmarked(bookmark, html, atoms, transaction, imageSources);",
                            arguments: ["bookmark": bookmark, "html": html, "atoms": visual.opaqueSources, "transaction": transactionID, "imageSources": imageSources], in: nil, in: .page) { result in
                                if case .success(let inserted) = result, inserted as? Bool == true { prepared.commit() }
                                else {
                                    self.imageTransactions.removeValue(forKey: transactionID)?.effect.discard()
                                    DispatchQueue.global(qos: .utility).async { prepared.rollback() }
                                    guard isCurrent() else { return }
                                    workspace.saveSafetyWarningHandler(L10n.string("Einfügen abgebrochen"),
                                        L10n.string("Das Dokument wurde während des Einfügens bearbeitet. Die vorhandene Eingabe blieb erhalten; bitte füge erneut ein."))
                                }
                            }
                    case .failure(let error): workspace.saveSafetyWarningHandler(L10n.string("Bild einfügen"), error.localizedDescription)
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
