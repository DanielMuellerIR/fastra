import AppKit
import CodeEditTextView

@MainActor
final class TextSnippetInsertionTarget {
    private weak var workspace: Workspace?
    private weak var window: NSWindow?
    private weak var sourceView: TextView?
    private weak var visual: MarkdownVisualCoordinator?
    private let bookmark: MarkdownVisualCoordinator.InsertionBookmark?
    private let tabID: UUID
    private let documentID: UUID
    private let revision: UInt64
    private let url: URL?
    private let source: String
    private let selection: NSRange?
    private var consumed = false

    private init(workspace: Workspace, window: NSWindow, tab: EditorTab,
                 sourceView: TextView? = nil, visual: MarkdownVisualCoordinator? = nil,
                 bookmark: MarkdownVisualCoordinator.InsertionBookmark? = nil) {
        self.workspace = workspace; self.window = window
        self.sourceView = sourceView; self.visual = visual; self.bookmark = bookmark
        tabID = tab.id; documentID = tab.documentID; revision = tab.contentRevision
        url = tab.url?.canonicalFileURL; source = tab.content
        selection = sourceView?.fastraSafeSelectedRange
    }

    static func capture(in workspace: Workspace,
                        completion: @escaping (Result<TextSnippetInsertionTarget, Error>) -> Void) {
        guard let tab = workspace.activeTab, tab.isEditableTextDocument, workspace.textEditingIsAllowed(for: tab),
              workspace.activeViewMode == .text,
              let window = CommandTargeting.registeredWindow(for: workspace) else {
            completion(.failure(TextSnippetError.unavailable)); return
        }
        if workspace.activeMarkdownIsVisual {
            guard let visual = workspace.visualMarkdownEditor, visual.ready else {
                completion(.failure(TextSnippetError.unavailable)); return
            }
            visual.captureInsertionBookmark { [weak workspace, weak visual, weak window] result in
                switch result {
                case .failure(let error): completion(.failure(error))
                case .success(let bookmark):
                    guard let workspace, let visual, let window, let current = workspace.activeTab,
                          current.documentID == tab.documentID, current.isEditableTextDocument,
                          visual.ownsInsertionBookmark(bookmark),
                          CommandTargeting.registeredWindow(for: workspace) === window else {
                        visual?.discardInsertionBookmark(bookmark)
                        completion(.failure(TextSnippetError.staleTarget)); return
                    }
                    completion(.success(TextSnippetInsertionTarget(workspace: workspace, window: window,
                        tab: current, visual: visual, bookmark: bookmark)))
                }
            }
        } else {
            guard let editor = CommandTargeting.editorTextView(for: workspace), editor.window === window,
                  editor.isEditable, editor.fastraColumnSelectionSnapshot == nil,
                  editor.selectionManager.textSelections.count <= 1,
                  editor.string.utf8.elementsEqual(tab.content.utf8) else {
                completion(.failure(TextSnippetError.unavailable)); return
            }
            completion(.success(TextSnippetInsertionTarget(workspace: workspace, window: window,
                tab: tab, sourceView: editor)))
        }
    }

    var isCurrent: Bool {
        guard !consumed, let workspace, let window, let tab = workspace.activeTab,
              CommandTargeting.registeredWindow(for: workspace) === window,
              tab.id == tabID, tab.documentID == documentID, tab.contentRevision == revision,
              tab.url?.canonicalFileURL == url, tab.isEditableTextDocument, workspace.textEditingIsAllowed(for: tab),
              tab.content.utf8.elementsEqual(source.utf8), workspace.activeViewMode == .text else { return false }
        if let bookmark { return visual?.ownsInsertionBookmark(bookmark) == true }
        guard !workspace.activeMarkdownIsVisual, let editor = sourceView,
              editor.window === window, editor.isEditable,
              CommandTargeting.editorTextView(for: workspace) === editor,
              editor.fastraColumnSelectionSnapshot == nil, editor.selectionManager.textSelections.count <= 1,
              editor.fastraSafeSelectedRange == selection,
              editor.string.utf8.elementsEqual(source.utf8) else { return false }
        return true
    }

    func insert(_ replacement: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard replacement.utf8.count <= TextSnippetTemplate.maximumOutputBytes else {
            completion(.failure(TextSnippetError.sizeLimit)); return
        }
        guard isCurrent else { completion(.failure(TextSnippetError.staleTarget)); return }
        consumed = true
        if let visual, let bookmark {
            visual.insertTextSnippet(replacement, at: bookmark) { success in
                completion(success ? .success(()) : .failure(TextSnippetError.insertionFailed))
            }
        } else if let sourceView, let selection {
            sourceView.fastraApplyTextOperation(replacing: selection, with: replacement)
            window?.makeFirstResponder(sourceView)
            completion(.success(()))
        } else { completion(.failure(TextSnippetError.staleTarget)) }
    }

    func release() {
        consumed = true
        if let bookmark { visual?.discardInsertionBookmark(bookmark) }
    }
}
