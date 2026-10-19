import Foundation
import Darwin

struct FileDiffDocumentOrigin: Hashable, Sendable {
    let workspaceID: ObjectIdentifier
    let windowID: ObjectIdentifier
    let tabID: UUID
    let documentID: UUID
    let revision: UInt64
    let url: URL?

    @MainActor init?(_ tab: EditorTab, in workspace: Workspace) {
        guard tab.isEligibleForFileComparison,
              let window = CommandTargeting.registeredWindow(for: workspace) else { return nil }
        workspaceID = ObjectIdentifier(workspace); windowID = ObjectIdentifier(window)
        tabID = tab.id; documentID = tab.documentID; revision = tab.contentRevision
        url = tab.url?.standardizedFileURL
    }

    func matchesLogically(_ other: Self) -> Bool {
        workspaceID == other.workspaceID && windowID == other.windowID
            && tabID == other.tabID && documentID == other.documentID
    }

    @MainActor func currentTab(in workspace: Workspace) -> EditorTab? {
        guard workspaceID == ObjectIdentifier(workspace),
              CommandTargeting.registeredWindow(for: workspace).map(ObjectIdentifier.init) == windowID,
              let tab = workspace.tabs.first(where: { $0.id == tabID }),
              tab.documentID == documentID, tab.contentRevision == revision,
              tab.url?.standardizedFileURL == url, tab.isEligibleForFileComparison else { return nil }
        return tab
    }
}

/// Der Inhalt und sein Snapshot stammen aus demselben tatsächlichen Read.
/// Reine Textseiten ohne Dokumentursprung sind unveränderliche, schreibgeschützte Quellen.
struct FileDiffSource: Hashable, Sendable {
    struct ValidatedFile: Equatable, Sendable {
        let url: URL
        private let identity: FileIdentity
        private let byteCount: Int64
        private let modificationSeconds: Int64
        private let modificationNanoseconds: Int64
        private let statusSeconds: Int64
        private let statusNanoseconds: Int64

        fileprivate init(url: URL, fileStat: stat) {
            self.url = url; identity = FileIdentity(stat: fileStat)
            byteCount = Int64(fileStat.st_size)
            modificationSeconds = Int64(fileStat.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(fileStat.st_mtimespec.tv_nsec)
            statusSeconds = Int64(fileStat.st_ctimespec.tv_sec)
            statusNanoseconds = Int64(fileStat.st_ctimespec.tv_nsec)
        }

        func isCurrent() -> Bool {
            guard let opened = try? FileSnapshot.openRegularFile(at: url) else { return false }
            defer { close(opened.descriptor) }
            return self == Self(url: url, fileStat: opened.stat)
        }
    }

    let text: String
    let fileURL: URL?
    let snapshot: FileSnapshot?
    let documentOrigin: FileDiffDocumentOrigin?

    init(text: String, fileURL: URL? = nil, snapshot: FileSnapshot? = nil,
         documentOrigin: FileDiffDocumentOrigin? = nil) {
        self.text = text; self.fileURL = fileURL; self.snapshot = snapshot; self.documentOrigin = documentOrigin
    }

    @MainActor func isCurrent(in workspace: Workspace) -> Bool {
        guard let documentOrigin else { return true }
        return documentOrigin.currentTab(in: workspace).map { $0.content.utf8.elementsEqual(text.utf8) } == true
    }

    @MainActor func referencesCurrentDocument(in workspace: Workspace) -> Bool {
        documentOrigin.map { $0.currentTab(in: workspace) != nil } ?? true
    }

    @discardableResult
    static func validateFiles(_ sources: [Self], isCancelled: () -> Bool) throws -> [ValidatedFile] {
        var versions: [ValidatedFile] = []
        for source in sources {
            if isCancelled() { throw CancellationError() }
            guard let url = source.fileURL else { continue }
            guard let expected = source.snapshot,
                  let opened = try? FileSnapshot.openRegularFile(at: url) else {
                throw FileDiffTransfer.Failure.stale
            }
            defer { close(opened.descriptor) }
            guard let actual = try? FileSnapshot.readSnapshotOnly(descriptor: opened.descriptor,
                fileStat: opened.stat, byteLimit: UInt64(max(0, expected.byteCount))), actual == expected else {
                throw FileDiffTransfer.Failure.stale
            }
            versions.append(ValidatedFile(url: url, fileStat: opened.stat))
        }
        if isCancelled() { throw CancellationError() }
        return versions
    }
}

extension FileDiffSide {
    @MainActor static func document(_ tab: EditorTab, in workspace: Workspace) -> Self? {
        guard let origin = FileDiffDocumentOrigin(tab, in: workspace) else { return nil }
        let name = tab.isDirty && tab.url != nil
            ? L10n.format("%@ (ungespeichert)", tab.title) : tab.title
        return .text(tab.content, name: name, path: tab.url?.path, documentOrigin: origin)
    }
}
