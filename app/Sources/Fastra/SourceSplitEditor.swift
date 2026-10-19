import AppKit
import Combine
import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages
import CodeEditTextView

enum SourcePaneID: Hashable { case primary, secondary }

final class SourcePaneMemory: ObservableObject {
    @Published var editorState = SourceEditorState(cursorPositions: [], findPanelVisible: false)
    var cursorMemory = EditorCursorMemory()
    /// Das Dokument des bisherigen Auswahlzustands. Beim Wechsel ist die
    /// aktive Workspace-ID bereits neu; die alte Auswahl gehört weiter hierher.
    var cursorMemoryTabID: UUID?
    var scrollMemory = EditorScrollMemory()
    /// Bis zur Wiederherstellung keinen anfänglichen Null-Ausschnitt speichern.
    var pendingScrollRestore: CGPoint?
    /// Feste Kante der Auswahl; der Footer zeigt die bewegte Kante.
    var selectionAnchor: Int?
    init() { _ = objectWillChange }
}

final class SourcePaneRegistry: ObservableObject {
    @Published private(set) var activePane: SourcePaneID = .primary
    private struct Entry { weak var view: TextView?; let documentID: UUID? }
    private var entries: [SourcePaneID: Entry] = [:]
    private let documentIDs = NSMapTable<TextView, NSUUID>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private let primaryMemory = SourcePaneMemory()
    private let secondaryMemory = SourcePaneMemory()
    func memory(for pane: SourcePaneID) -> SourcePaneMemory {
        pane == .primary ? primaryMemory : secondaryMemory
    }

    init() { _ = objectWillChange }

    @MainActor func register(_ view: TextView, pane: SourcePaneID, documentID: UUID?) {
        entries[pane] = Entry(view: view, documentID: documentID)
        if let documentID { documentIDs.setObject(documentID as NSUUID, forKey: view) }
        else { documentIDs.removeObject(forKey: view) }
    }
    @MainActor func view(for pane: SourcePaneID, documentID: UUID?) -> TextView? {
        guard let entry = entries[pane], entry.documentID == documentID else { return nil }
        return entry.view
    }
    @MainActor func allowsTargeting(_ view: TextView, documentID: UUID?) -> Bool {
        guard let owner = documentIDs.object(forKey: view) as UUID? else { return true }
        return owner == documentID
    }
    @MainActor func select(_ pane: SourcePaneID) {
        if activePane != pane { activePane = pane }
    }
    @MainActor func preferred(in root: NSView, documentID: UUID?) -> TextView? {
        if let first = root.window?.firstResponder as? TextView, first.isDescendant(of: root),
           allowsTargeting(first, documentID: documentID) { return first }
        if let current = view(for: activePane, documentID: documentID), current.isDescendant(of: root) { return current }
        return nil
    }
}

@MainActor
final class SourcePaneCoordinator: ObservableObject, @preconcurrency TextViewCoordinator {
    private weak var workspace: Workspace?
    private weak var controller: TextViewController?
    let pane: SourcePaneID
    private var observers: [NSObjectProtocol] = []
    private let documentIDs = NSMapTable<TextViewController, NSUUID>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    init(workspace: Workspace, pane: SourcePaneID) { self.workspace = workspace; self.pane = pane }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func prepareCoordinator(controller: TextViewController) {
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        guard let workspace, let view = controller.textView else { return }
        self.controller = controller
        let documentID = workspace.activeDocumentID
        if let documentID { documentIDs.setObject(documentID as NSUUID, forKey: controller) }
        let binding = workspace.sourceEditorContent
        workspace.sourcePanes.register(view, pane: pane, documentID: documentID)
        observers.append(NotificationCenter.default.addObserver(forName: TextView.textDidChangeNotification,
            object: view, queue: .main) { [weak view] _ in
                guard let view else { return }
                binding.wrappedValue = view.string
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: .init("com.CodeEdit.TextView.TextDidBecomeFirstResponder"), object: view, queue: .main) {
                [weak self, weak workspace, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let workspace, let view,
                          workspace.sourcePanes.view(for: self.pane, documentID: workspace.activeDocumentID) === view else { return }
                    workspace.sourcePanes.select(self.pane)
                }
            })
    }
    func resolveCursorPosition(_ position: CursorPosition) -> CursorPosition? {
        guard let workspace, let controller,
              documentIDs.object(forKey: controller) as UUID? == workspace.activeDocumentID else { return nil }
        return controller.resolveCursorPosition(position)
    }

    func controllerDidAppear(controller: TextViewController) {
        // Erst nach dem Speicheranschluss auf die View zugreifen: Ein Zugriff
        // in prepareCoordinator baut die Minimap am anfänglichen leeren Speicher.
        controller.view.clipsToBounds = true
        guard let workspace, let view = controller.textView else { return }
        EditorView.installMarkdownSourceClickRelay(on: view, workspace: workspace)
        if workspace.activeTabIsMarkdown { MarkdownAssist.configureExternalDrop(on: view, workspace: workspace) }
        else { view.fastraClearExternalDrop() }
    }

    func controllerDidDisappear(controller: TextViewController) {
        guard let workspace else { return }
        let memory = workspace.sourcePanes.memory(for: pane)
        let documentID = documentIDs.object(forKey: controller) as UUID?
        memory.cursorMemory.remember(controller.cursorPositions, for: documentID)
        memory.scrollMemory.remember(controller.scrollView?.contentView.bounds.origin, for: documentID)
    }

    // Der Coordinator überlebt den Controller-Wechsel. Ein spät abgebauter
    // Vorgänger darf die Observer des bereits montierten Nachfolgers nicht lösen.
    func destroy() { }
}

extension Workspace {
    var canSplitSourceEditor: Bool {
        activeTab?.isEditableTextDocument == true && activeViewMode == .text
            && !activeMarkdownIsVisual && !isWelcomeScreen
    }
    @MainActor func toggleSourceSplit() {
        guard sourceSplitEnabled || canSplitSourceEditor else { return }
        sourceSplitEnabled.toggle()
        if !sourceSplitEnabled { sourcePanes.select(.primary) }
        EditorView.focusActiveEditor(in: self)
    }
}

struct SourceSplitEditor: View {
    @ObservedObject var workspace: Workspace
    let language: CodeLanguage
    let configuration: SourceEditorConfiguration

    private var splitIsVisible: Bool { workspace.sourceSplitEnabled && workspace.canSplitSourceEditor }

    private func editor(_ pane: SourcePaneID) -> some View {
        SourceEditorPane(workspace: workspace, pane: pane,
                         language: language, configuration: configuration)
            .frame(minHeight: 100)
            .padding(.vertical, splitIsVisible ? 4 : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            if workspace.canSplitSourceEditor || workspace.sourceSplitEnabled || workspace.canUseTextSnippets {
                HStack {
                    TextSnippetButton(workspace: workspace, compact: MarkdownAssist.isMarkdownTabActive(in: workspace))
                    Spacer(minLength: 0)
                    Button { workspace.toggleSourceSplit() } label: {
                        if workspace.sourceSplitEnabled {
                            Label("Teilung schließen", systemImage: "rectangle")
                        } else {
                            Label("Quelltextansicht teilen", systemImage: "rectangle.split.1x2")
                        }
                    }
                    .buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 5)
                    .disabled(!workspace.sourceSplitEnabled && !workspace.canSplitSourceEditor)
                    .background(SelfTestMarker(id: "sourceSplitToggle"))
                }.fastraFont(.small).foregroundStyle(Theme.textSecondary)
                Divider().opacity(0.3)
            }
            VSplitView {
                editor(.primary)
                if splitIsVisible { editor(.secondary) }
            }
        }
    }
}

struct SourceSplitMenuItem: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        if workspace.sourceSplitEnabled {
            Button("Teilung schließen") { workspace.toggleSourceSplit() }
        } else {
            Button("Quelltextansicht teilen") { workspace.toggleSourceSplit() }
                .disabled(!workspace.canSplitSourceEditor)
        }
    }
}
