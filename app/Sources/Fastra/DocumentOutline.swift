import AppKit
import SwiftUI

struct DocumentOutlineEntry: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable { case markdown, method, function, getter, setter, query, orderBy, constructor }
    var id: String { "\(line):\(kind.rawValue)" }
    let title: String
    let level: Int
    let line: Int
    let range: NSRange
    let kind: Kind

    init(title: String, level: Int, line: Int, range: NSRange, kind: Kind = .markdown) {
        self.title = title; self.level = level; self.line = line; self.range = range; self.kind = kind
    }
}


struct DocumentNavigationPoint: Equatable {
    let offset: Int
    let line: Int
    let heading: DocumentOutlineEntry?
    let documentID: UUID?
    let anchor: NavigationAnchor?
    let documentURL: URL?

    init(offset: Int, line: Int, heading: DocumentOutlineEntry?, documentID: UUID? = nil,
         anchor: NavigationAnchor? = nil, documentURL: URL? = nil) {
        self.offset = offset; self.line = line; self.heading = heading; self.documentID = documentID
        self.anchor = anchor; self.documentURL = documentURL
    }
}

struct DocumentNavigationHistory {
    private(set) var points: [DocumentNavigationPoint] = []
    private(set) var index = -1
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < points.count }

    mutating func visit(_ point: DocumentNavigationPoint, from origin: DocumentNavigationPoint) {
        if index < 0 { points = [origin]; index = 0 }
        else {
            let previous = points[index]
            // Ein unverändert angesprungenes Ziel behält seinen stabilen Anker.
            if origin.documentID != previous.documentID || origin.heading != nil || previous.offset != origin.offset || previous.line != origin.line || previous.heading == nil {
                points[index] = origin
            }
        }
        points = Array(points.prefix(index + 1))
        let samePlace = points.last.map {
            $0.documentID == point.documentID && $0.offset == point.offset && $0.line == point.line && $0.heading == point.heading
        } ?? false
        if samePlace { points[points.count - 1] = point }
        else { points.append(point) }
        if points.count > 100 { points.removeFirst(points.count - 100) }
        index = points.count - 1
    }

    mutating func move(_ delta: Int) -> DocumentNavigationPoint? {
        let next = index + delta
        guard points.indices.contains(next) else { return nil }
        index = next
        return points[next]
    }
}

final class DocumentOutlineController: ObservableObject {
    @Published private(set) var headings: [DocumentOutlineEntry] = []
    @Published private(set) var activeHeading: Int?
    @Published private(set) var ready = false
    @Published private(set) var history = DocumentNavigationHistory()
    @Published private(set) var notice: String?
    @Published var isPresented = false
    private(set) var source = ""
    private var documentID: UUID?
    private var revision: UInt64?
    private var formatID: DocumentFormatID?
    private var generation = UUID()
    private var analysisTask: Task<Void, Never>?
    private var navigationTask: Task<Void, Never>?
    private var navigationGeneration = UUID()

    init() { _ = objectWillChange }
    deinit { analysisTask?.cancel(); navigationTask?.cancel() }

    static func supportsOutline(in workspace: Workspace) -> Bool {
        workspace.activeTab?.isOrdinaryTextDocument == true
            && (workspace.activeTabIsMarkdown || workspace.activeDocumentFormat.id == .fourD)
    }

    private static func entries(in source: String, format: DocumentFormatID, title: String,
                                isCancelled: () -> Bool) -> [DocumentOutlineEntry]? {
        guard source.utf8.count <= 10 * 1024 * 1024, !isCancelled() else { return nil }
        let text = source as NSString
        var lines = 0, offset = 0
        while offset < text.length {
            if isCancelled() || lines >= 200_000 { return nil }
            var end = 0
            text.getLineStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: offset, length: 0))
            guard end > offset else { return nil }
            lines += 1; offset = end
        }
        if format == .fourD {
            guard let definitions = FourDDefinitions.definitions(in: source, isCancelled: isCancelled) else { return nil }
            if definitions.isEmpty { return [.init(title: title, level: 1, line: 1, range: NSRange(location: 0, length: 0), kind: .method)] }
            return definitions.map { definition in
                let kind: DocumentOutlineEntry.Kind = .init(rawValue: definition.kind.rawValue) ?? .function
                return .init(title: definition.name, level: 1, line: definition.line, range: definition.range, kind: kind)
            }
        }
        return MarkdownOutline.headings(in: source, maximumHeadings: 10_000, isCancelled: isCancelled)
    }

    func refresh(in workspace: Workspace) {
        guard let tab = workspace.activeTab else {
            analysisTask?.cancel(); analysisTask = nil; generation = UUID()
            headings = []; activeHeading = nil; ready = false; return
        }
        let format = workspace.activeDocumentFormat.id
        guard documentID != tab.documentID || revision != tab.contentRevision || formatID != format || (!ready && analysisTask == nil) else { return }
        documentID = tab.documentID; revision = tab.contentRevision; formatID = format
        source = tab.content; ready = false; headings = []; activeHeading = nil; notice = nil
        generation = UUID(); let request = generation
        analysisTask?.cancel(); analysisTask = nil
        guard Self.supportsOutline(in: workspace) else { ready = true; return }
        let text = tab.content, id = tab.documentID, revision = tab.contentRevision, title = tab.title
        analysisTask = Task.detached(priority: .userInitiated) { [weak self, weak workspace] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let entries = Self.entries(in: text, format: format, title: title, isCancelled: { Task.isCancelled })
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == request else { return }
                self.analysisTask = nil
                guard let workspace, workspace.activeTab?.documentID == id,
                      workspace.activeTab?.contentRevision == revision else { return }
                self.headings = entries ?? []; self.ready = true
                if entries == nil { self.notice = L10n.string("Die Gliederung ist für diese Quelle nicht vollständig prüfbar (10 MiB / 200.000 Zeilen).") }
                else if entries?.count == 10_000 { self.notice = L10n.string("Die Gliederung hat die Grenze von 10.000 Einträgen erreicht.") }
                self.follow(line: workspace.cursorLine ?? 1)
                if workspace.activeMarkdownIsVisual { workspace.visualMarkdownEditor?.reportOutlinePosition() }
            }
        }
    }

    func follow(line: Int) { let next = headings.lastIndex { $0.line <= line }; if activeHeading != next { activeHeading = next } }
    func followVisualHeading(_ index: Int) {
        guard ready, headings.indices.contains(index) else { activeHeading = nil; return }
        if activeHeading != index { activeHeading = index }
    }

    @MainActor func currentPoint(in workspace: Workspace, range: NSRange? = nil) -> DocumentNavigationPoint? {
        guard let tab = workspace.activeTab, tab.isOrdinaryTextDocument else { return nil }
        let currentAnalysis = ready && documentID == tab.documentID && revision == tab.contentRevision
        let heading = currentAnalysis ? activeHeading.flatMap { headings.indices.contains($0) ? headings[$0] : nil } : nil
        let pending = workspace.pendingEditorJump.flatMap { $0.documentID == tab.documentID ? $0.range : nil }
        let selected = range ?? (workspace.activeMarkdownIsVisual ? heading?.range : CommandTargeting.editorTextView(for: workspace)?.fastraSafeSelectedRange)
            ?? pending ?? heading?.range ?? NSRange(location: 0, length: 0)
        let anchor = NavigationAnchor(source: tab.content, revision: tab.contentRevision, range: selected)
        return .init(offset: anchor.range.location, line: workspace.activeMarkdownIsVisual ? heading?.line ?? 1 : workspace.cursorLine ?? 1,
                     heading: currentAnalysis ? headings.first(where: { $0.range.location == anchor.range.location }) : nil,
                     documentID: tab.documentID, anchor: anchor, documentURL: tab.url)
    }

    @MainActor func jump(to heading: DocumentOutlineEntry, in workspace: Workspace) {
        if workspace.synchronizeVisualMarkdownBefore({ self.jump(to: heading, in: workspace) }) { return }
        guard ready, documentID == workspace.activeTab?.documentID, revision == workspace.activeTab?.contentRevision,
              headings.contains(heading), let origin = currentPoint(in: workspace), let tab = workspace.activeTab else { refresh(in: workspace); return }
        let point = DocumentNavigationPoint(offset: heading.range.location, line: heading.line, heading: heading,
            documentID: tab.documentID, anchor: NavigationAnchor(source: tab.content, revision: tab.contentRevision, range: heading.range), documentURL: tab.url)
        history.visit(point, from: origin); apply(point, range: heading.range, in: workspace)
    }

    @MainActor func recordJump(in workspace: Workspace, from origin: DocumentNavigationPoint?, range: NSRange) {
        guard let origin, let target = currentPoint(in: workspace, range: range) else { return }
        history.visit(target, from: origin)
    }

    @MainActor func jump(to range: NSRange, in workspace: Workspace, originRange: NSRange? = nil) {
        if workspace.synchronizeVisualMarkdownBefore({ self.jump(to: range, in: workspace, originRange: originRange) }) { return }
        let origin = currentPoint(in: workspace, range: originRange)
        guard let point = currentPoint(in: workspace, range: range) else { return }
        history.visit(point, from: origin ?? point)
        apply(point, range: point.anchor?.range ?? range, in: workspace)
    }

    @MainActor func openFile(at url: URL, in workspace: Workspace, originRange: NSRange? = nil) {
        if workspace.synchronizeVisualMarkdownBefore({ self.openFile(at: url, in: workspace, originRange: originRange) }) { return }
        let origin = currentPoint(in: workspace, range: originRange)
        navigationTask?.cancel(); navigationGeneration = UUID(); let request = navigationGeneration
        let acceptance = FileLoadAcceptance { [weak self, weak workspace] in
            guard self?.navigationGeneration == request, let workspace else { return false }
            guard let origin, let id = origin.documentID, let anchor = origin.anchor else { return true }
            return workspace.tabs.contains { $0.documentID == id && $0.contentRevision == anchor.revision && $0.url == origin.documentURL }
        }
        workspace.loadFile(at: url, acceptance: acceptance) { [weak self, weak workspace] success in
            guard let self, let workspace, success, self.navigationGeneration == request,
                  workspace.activeTab?.url?.canonicalFileURL == url.canonicalFileURL else { return }
            self.recordJump(in: workspace, from: origin, range: NSRange(location: 0, length: 0))
        }
    }

    @MainActor func move(_ delta: Int, in workspace: Workspace) {
        if workspace.synchronizeVisualMarkdownBefore({ self.move(delta, in: workspace) }) { return }
        let next = history.index + delta
        guard history.points.indices.contains(next) else { return }
        let point = history.points[next]
        guard let id = point.documentID, let tab = workspace.tabs.first(where: { $0.documentID == id && $0.isOrdinaryTextDocument }) else {
            workspace.showSidebarNotice(L10n.string("Das Dokument im Sprungverlauf wurde geschlossen oder ersetzt.")); return
        }
        navigationTask?.cancel(); navigationGeneration = UUID(); let request = navigationGeneration
        let active = workspace.activeTab?.documentID, activeRevision = workspace.activeTab?.contentRevision
        func finish(_ range: NSRange?) {
            guard self.navigationGeneration == request, workspace.activeTab?.documentID == active,
                  workspace.activeTab?.contentRevision == activeRevision,
                  self.history.points.indices.contains(next), self.history.points[next] == point,
                  let current = workspace.tabs.first(where: { $0.documentID == id && $0.contentRevision == tab.contentRevision }) else { return }
            guard let range else { workspace.showSidebarNotice(L10n.string("Das Ziel im Sprungverlauf wurde geändert oder ist nicht mehr eindeutig.")); return }
            _ = self.history.move(delta); workspace.selectTab(id: current.id)
            self.refresh(in: workspace); self.apply(point, range: range, in: workspace)
        }
        if point.anchor?.revision == tab.contentRevision { finish(point.anchor?.range); return }
        let format = DocumentFormatResolver.resolve(tab: tab).id
        if documentID == id, revision == tab.contentRevision, ready, let old = point.heading {
            let matches = headings.filter { $0.kind == old.kind && $0.title == old.title && $0.level == old.level }
            finish(matches.count == 1 ? matches[0].range : nil); return
        }
        navigationTask = Task.detached(priority: .userInitiated) { [weak self, weak workspace] in
            let range: NSRange?
            if let old = point.heading {
                let entries = Self.entries(in: tab.content, format: format, title: tab.title, isCancelled: { Task.isCancelled }) ?? []
                let matches = entries.filter { $0.kind == old.kind && $0.title == old.title && $0.level == old.level }
                range = matches.count == 1 ? matches[0].range : nil
            } else { range = point.anchor?.resolve(in: tab.content, revision: tab.contentRevision, isCancelled: { Task.isCancelled }) }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, let workspace, self.navigationGeneration == request,
                      workspace.activeTab?.documentID == active, workspace.activeTab?.contentRevision == activeRevision else { return }
                self.navigationTask = nil
                finish(range)
            }
        }
    }

    func visualHeadingIndex(for point: DocumentNavigationPoint) -> Int { headings.lastIndex { $0.line <= point.line } ?? -1 }
    @MainActor private func apply(_ point: DocumentNavigationPoint, range: NSRange, in workspace: Workspace) {
        isPresented = false
        if workspace.activeMarkdownIsVisual, point.heading != nil,
           let index = headings.firstIndex(where: { $0.range.location == range.location }) {
            workspace.visualMarkdownEditor?.revealHeading(index)
        } else {
            if workspace.activeMarkdownIsVisual { workspace.toggleMarkdownEditingMode() }
            workspace.pendingEditorJump = PendingEditorJump(documentID: workspace.activeTab?.documentID, startLine: nil, startColumn: nil,
                endLine: nil, endColumn: nil, range: range)
            NotificationCenter.default.post(name: .fastraJumpToRange, object: workspace, userInfo: ["range": NSValue(range: range)])
        }
        follow(line: point.heading?.line ?? point.line)
    }
}

struct DocumentOutlineControls: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var outline: DocumentOutlineController

    private func displayTitle(_ entry: DocumentOutlineEntry) -> String {
        let name = entry.title.isEmpty ? L10n.string("Ohne Titel") : entry.title
        switch entry.kind {
        case .getter: return "get " + name
        case .setter: return "set " + name
        case .query: return "query " + name
        case .orderBy: return "orderBy " + name
        default: return name
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Button { outline.move(-1, in: workspace) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                .disabled(!outline.history.canGoBack)
                .help("Voriger Sprung")
                .accessibilityLabel("Voriger Sprung")
                .background(SelfTestMarker(id: "documentOutlineBack").frame(width: 0, height: 0))
            Button { outline.move(1, in: workspace) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 24) }
                .disabled(!outline.history.canGoForward)
                .help("Nächster Sprung")
                .accessibilityLabel("Nächster Sprung")
                .background(SelfTestMarker(id: "documentOutlineForward").frame(width: 0, height: 0))
            Button { outline.isPresented.toggle() } label: { Image(systemName: "list.bullet.indent").frame(width: 26, height: 24) }
                .disabled(!DocumentOutlineController.supportsOutline(in: workspace))
                .help("Dokumentgliederung anzeigen")
                .accessibilityLabel("Dokumentgliederung anzeigen")
                .background(SelfTestMarker(id: "documentOutlineButton").frame(width: 0, height: 0))
                .popover(isPresented: $outline.isPresented, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dokumentgliederung").fastraFont(size: 14, weight: .semibold)
                        if !outline.ready { ProgressView().frame(maxWidth: .infinity) }
                        else if let notice = outline.notice { Text(verbatim: notice).foregroundStyle(Theme.textSecondary) }
                        else if outline.headings.isEmpty { Text("Keine Gliederungseinträge im Dokument").foregroundStyle(Theme.textSecondary) }
                        else {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 2) {
                                        ForEach(Array(outline.headings.enumerated()), id: \.element.id) { index, heading in
                                            Button { outline.jump(to: heading, in: workspace) } label: {
                                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                                    if heading.kind == .markdown {
                                                        Text("H\(heading.level)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                                                    } else {
                                                        Image(systemName: heading.kind == .method ? "doc.text" : "function").foregroundStyle(Theme.textSecondary)
                                                    }
                                                    Text(verbatim: displayTitle(heading)).lineLimit(3)
                                                    if heading.kind != .markdown { Text(verbatim: "\(heading.line)").fastraFont(.small).foregroundStyle(Theme.textSecondary) }
                                                    Spacer(minLength: 0)
                                                    if outline.activeHeading == index { Image(systemName: "checkmark") }
                                                }
                                                .padding(.leading, CGFloat(heading.level - 1) * 12)
                                                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                                                .background(outline.activeHeading == index ? Theme.accentReadable.opacity(0.12) : Color.clear)
                                                .contentShape(Rectangle())
                                            }.buttonStyle(.plain).id(heading.id)
                                                .background(SelfTestMarker(id: "documentOutlineHeading-\(index)").frame(width: 0, height: 0))
                                        }
                                    }
                                }.onAppear { if let index = outline.activeHeading, outline.headings.indices.contains(index) { proxy.scrollTo(outline.headings[index].id) } }
                            }
                        }
                    }.fastraFont(.ui).padding(14).frame(width: 320, height: 340)
                        .foregroundStyle(Theme.textPrimary)
                        .background(Theme.surfaceRaised)
                        .background(SelfTestMarker(id: "documentOutlinePopover"))
                }
        }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            .onAppear { outline.refresh(in: workspace) }
            .onChange(of: workspace.activeTab?.documentID) { _, _ in outline.refresh(in: workspace) }
            .onChange(of: workspace.activeTab?.contentRevision) { _, _ in outline.refresh(in: workspace) }
            .onChange(of: workspace.activeDocumentFormat.id) { _, _ in outline.refresh(in: workspace) }
            .onChange(of: workspace.cursorLine) { _, line in if !workspace.activeMarkdownIsVisual { outline.follow(line: line ?? 1) } }
    }
}

struct DocumentNavigationCommands: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var outline: DocumentOutlineController
    var body: some View {
        Button("Voriger Sprung") { outline.move(-1, in: workspace) }.disabled(!outline.history.canGoBack)
        Button("Nächster Sprung") { outline.move(1, in: workspace) }.disabled(!outline.history.canGoForward)
        Button("Dokumentgliederung anzeigen") { outline.isPresented.toggle() }
            .disabled(!DocumentOutlineController.supportsOutline(in: workspace) || workspace.activeViewMode != .text)
    }
}

struct DocumentNavigationBar: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var outline: DocumentOutlineController
    var body: some View {
        if DocumentOutlineController.supportsOutline(in: workspace) || outline.history.canGoBack || outline.history.canGoForward {
            HStack(spacing: 0) {
                DocumentOutlineControls(workspace: workspace, outline: outline).padding(.leading, 6)
                Spacer()
            }.padding(.vertical, 3)
            Divider().opacity(0.3)
        }
    }
}
