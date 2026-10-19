import AppKit
import SwiftUI
import WebKit

final class MarkdownVisualFindController: ObservableObject {
    enum Status: Equatable { case idle, searching, found, missing }
    @Published var query = ""
    @Published var caseSensitive = false
    @Published private(set) var isPresented = false
    @Published private(set) var focusRequest = 0
    @Published private(set) var status: Status = .idle
    private var documentID: UUID?
    private var request = 0
    private var pendingSearch: DispatchWorkItem?
    private weak var searchedWeb: WKWebView?
    private var saved: [UUID: (query: String, caseSensitive: Bool)] = [:]

    init() { _ = objectWillChange }

    @MainActor func bind(in workspace: Workspace) {
        let id = workspace.activeTab?.documentID
        guard documentID != id else { return }
        if let documentID { saved[documentID] = (query, caseSensitive) }
        saved = saved.filter { id, _ in workspace.tabs.contains { $0.documentID == id } }
        close(in: workspace, focusEditor: false)
        documentID = id
        query = id.flatMap { saved[$0]?.query } ?? ""
        caseSensitive = id.flatMap { saved[$0]?.caseSensitive } ?? false
    }

    @MainActor func present(in workspace: Workspace) {
        let id = workspace.activeTab?.documentID
        if workspace.synchronizeVisualMarkdownBefore({ [weak self, weak workspace] in
            guard let workspace, workspace.activeTab?.documentID == id else { return }
            self?.present(in: workspace)
        }) { return }
        guard workspace.activeMarkdownIsVisual else { return }
        let alreadyPresented = isPresented && documentID == id
        bind(in: workspace)
        workspace.showSearchDialog = false
        isPresented = true
        focusRequest += 1
        if !alreadyPresented { schedule(in: workspace) }
    }

    @MainActor func close(in workspace: Workspace, focusEditor: Bool = true) {
        pendingSearch?.cancel()
        request += 1
        isPresented = false
        status = .idle
        searchedWeb?.find("", configuration: WKFindConfiguration()) { _ in }
        searchedWeb = nil
        guard focusEditor, workspace.activeMarkdownIsVisual,
              workspace.activeTab?.documentID == documentID,
              let editor = workspace.visualMarkdownEditor, editor.tabID == workspace.activeTabID,
              let web = editor.web else { return }
        web.window?.makeFirstResponder(web)
        web.evaluateJavaScript("document.getElementById('fastra-visual')?.focus();", completionHandler: nil)
    }

    @MainActor func schedule(in workspace: Workspace) {
        pendingSearch?.cancel()
        request += 1
        guard isPresented, workspace.activeMarkdownIsVisual,
              workspace.activeTab?.documentID == documentID else { return }
        status = query.isEmpty ? .idle : .searching
        let token = request
        let work = DispatchWorkItem { [weak self, weak workspace] in
            guard let self, let workspace, self.request == token else { return }
            self.perform(in: workspace, backwards: false, reset: true, token: token)
        }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @MainActor func find(in workspace: Workspace, backwards: Bool = false) {
        pendingSearch?.cancel()
        request += 1
        perform(in: workspace, backwards: backwards, reset: false, token: request)
    }

    @MainActor func editorBecameReady(in workspace: Workspace) {
        if isPresented, workspace.activeTab?.documentID == documentID { schedule(in: workspace) }
    }

    @MainActor private func perform(in workspace: Workspace, backwards: Bool, reset: Bool, token: Int) {
        guard isPresented, workspace.activeMarkdownIsVisual, workspace.activeTab?.documentID == documentID,
              let editor = workspace.visualMarkdownEditor, editor.ready, editor.tabID == workspace.activeTabID,
              let content = workspace.activeTab?.content, editor.markdown.utf8.elementsEqual(content.utf8),
              let web = editor.web else { return }
        let generation = editor.generation, id = documentID, query = query, sensitive = caseSensitive
        let source = content
        searchedWeb = web
        status = query.isEmpty ? .idle : .searching
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = sensitive
        configuration.wraps = true
        let search = { [weak self, weak workspace, weak editor, weak web] in
            guard let self, let workspace, let editor, let web,
                  self.request == token, self.isPresented, workspace.activeMarkdownIsVisual,
                  workspace.activeTab?.documentID == id, workspace.visualMarkdownEditor === editor,
                  editor.generation == generation else { return }
            // WebKit sucht in gerendertem Text und zeichnet eigene Markierungen.
            // Das editierbare DOM, Markdown-Originale und Undo bleiben unangetastet.
            web.find(query, configuration: configuration) { [weak self, weak workspace, weak editor] result in
                guard let self, let workspace, let editor, self.request == token,
                      self.isPresented, workspace.activeTab?.documentID == id,
                      workspace.visualMarkdownEditor === editor, editor.generation == generation else { return }
                guard let current = workspace.activeTab?.content, current.utf8.elementsEqual(source.utf8) else {
                    self.schedule(in: workspace); return
                }
                self.status = query.isEmpty ? .idle : (result.matchFound ? .found : .missing)
            }
        }
        if reset { web.find("", configuration: WKFindConfiguration()) { _ in search() } }
        else { search() }
    }
}

struct MarkdownVisualFindBar: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var find: MarkdownVisualFindController
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if find.isPresented {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        TextField("Im formatierten Text suchen", text: $find.query)
                            .textFieldStyle(.roundedBorder).focused($searchFocused)
                            .accessibilityIdentifier("markdownVisualFindField")
                            .background(SelfTestMarker(id: "markdownVisualFindField").frame(width: 0, height: 0))
                            .onKeyPress(.return, phases: .down) { key in
                                find.find(in: workspace, backwards: key.modifiers.contains(.shift))
                                return .handled
                            }
                            .onExitCommand { find.close(in: workspace) }
                        Button { find.find(in: workspace, backwards: true) } label: { Image(systemName: "chevron.up").frame(width: 24, height: 24) }
                            .help("Voriger Treffer im formatierten Text (⇧⌘G)")
                            .accessibilityLabel("Voriger Treffer im formatierten Text")
                            .disabled(find.query.isEmpty)
                            .background(SelfTestMarker(id: "markdownVisualFindPrevious").frame(width: 0, height: 0))
                        Button { find.find(in: workspace) } label: { Image(systemName: "chevron.down").frame(width: 24, height: 24) }
                            .help("Nächster Treffer im formatierten Text (⌘G)")
                            .accessibilityLabel("Nächster Treffer im formatierten Text")
                            .disabled(find.query.isEmpty)
                            .background(SelfTestMarker(id: "markdownVisualFindNext").frame(width: 0, height: 0))
                        Button { find.close(in: workspace) } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                            .help("Textsuche schließen (Escape)").accessibilityLabel("Textsuche schließen")
                            .background(SelfTestMarker(id: "markdownVisualFindClose").frame(width: 0, height: 0))
                    }.buttonStyle(.plain)
                    HStack(spacing: 8) {
                        Toggle("Aa", isOn: $find.caseSensitive).toggleStyle(.checkbox)
                            .help("Groß-/Kleinschreibung beachten")
                            .accessibilityLabel("Groß-/Kleinschreibung beachten")
                        Text(verbatim: statusText).foregroundStyle(find.status == .missing ? Color.red : Theme.textSecondary)
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Quelltext…") {
                            NotificationCenter.default.post(name: .fastraShowSearchFile, object: workspace, userInfo: ["source": true])
                        }.help("Markdown-Quelltext suchen und ersetzen (⌥⌘F)")
                            .background(SelfTestMarker(id: "markdownVisualFindSource").frame(width: 0, height: 0))
                    }.fastraFont(.small)
                }.padding(8).background(Theme.surfaceSand)
                    .background(SelfTestMarker(id: "markdownVisualFindBar"))
                    .onAppear { requestSearchFocus() }
                    .onChange(of: find.focusRequest) { _, _ in requestSearchFocus() }
                    .onChange(of: find.query) { _, _ in find.schedule(in: workspace) }
                    .onChange(of: find.caseSensitive) { _, _ in find.schedule(in: workspace) }
                Divider().opacity(0.3)
            }
        }
        .onChange(of: find.isPresented) { _, presented in
            if !presented { searchFocused = false }
        }
        .onAppear { find.bind(in: workspace) }
        .onChange(of: workspace.activeTab?.documentID) { _, _ in find.bind(in: workspace) }
        .onChange(of: workspace.activeTab?.contentRevision) { _, _ in if find.isPresented { find.schedule(in: workspace) } }
        .onDisappear { find.close(in: workspace, focusEditor: false) }
    }

    private func requestSearchFocus() {
        let request = find.focusRequest, documentID = workspace.activeDocumentID
        // Beim Wiederöffnen ist das alte Feld schon abgebaut, der FocusState
        // aber noch wahr. Den neuen Fokus erst nach der Montage anfordern.
        searchFocused = false
        DispatchQueue.main.async {
            guard find.isPresented, find.focusRequest == request,
                  workspace.activeDocumentID == documentID,
                  workspace.activeMarkdownIsVisual else { return }
            searchFocused = true
        }
    }

    private var statusText: String {
        switch find.status {
        case .idle: return ""
        case .searching: return L10n.string("Suche läuft…")
        case .found: return L10n.string("Treffer gefunden")
        case .missing: return L10n.string("Keine Treffer")
        }
    }
}
