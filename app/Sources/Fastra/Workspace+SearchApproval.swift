import Foundation

extension Workspace {
    var searchApprovalIncompleteFiles: [FolderSearch.PerFileResult] {
        guard scope.isFolderLike else { return [] }
        return folderResults.filter { $0.skipped != nil && $0.skipped != .binary }
    }

    var folderResultsContainCappedFiles: Bool {
        folderResults.contains { $0.totalMatches > $0.matches.count }
    }

    @MainActor @discardableResult
    func applySearchApproval(_ preview: SearchApprovalPreview) throws -> Bool {
        guard preview.request.isCurrent(in: self), preview.changedCount > 0 else {
            throw SearchApprovalPreview.Failure.stale
        }
        switch preview.request.source {
        case .files:
            return applyAllInFolder(approvedPreview: preview)
        case .memory(let source, _, _):
            let oldLength = scope == .file ? activeTab.map { ($0.content as NSString).length } : nil
            // Die volle Basis wurde oben geprüft. Die spätere Rücknahme
            // besitzt nur tatsächlich geänderte Ziele, keine fremden Texte.
            let changedSource = try source.selecting(Set(preview.replacements.keys))
            let change = try TextWorkflowOpenDocumentsPlan.applyReplacements(preview.replacements, source: changedSource, in: self)
            lastSearchApprovalMemoryChange = change
            searchApprovalMemoryRestored = false
            if let oldLength, let tab = activeTab {
                adjustSearchSelectionRange(lengthDelta: (tab.content as NSString).length - oldLength)
            }
            recordSearchHistory()
            return true
        }
    }

    @MainActor func restoreSearchApprovalMemory() throws {
        guard let change = lastSearchApprovalMemoryChange else { throw SearchApprovalPreview.Failure.stale }
        lastSearchApprovalMemoryChange = try change.restore(in: self)
        searchApprovalMemoryRestored.toggle()
    }

    func publishSearchApprovals() {
        let matches = navMatches
        let complete: Bool
        switch scope {
        case .file:
            complete = !bufferSearching && !bufferResultsWereCapped
                && matches.count == bufferTotalMatches
                && visibleBufferResultsOptions == currentSearchOptions
        case .open:
            complete = !bufferSearching && !openResultsWereCapped
                && matches.count == openTotalMatches
                && visibleBufferResultsOptions == currentSearchOptions
        case .folder, .project:
            complete = !folderSearching && !folderNeedsSearch && !folderResultsAreStale
                && !folderResultsWereCapped && matches.count == folderTotalMatches
                && folderResults.allSatisfy { result in
                    if result.skipped == .binary { return true }
                    return result.skipped == nil && result.snapshot != nil
                        && result.totalMatches == result.matches.count
                        && result.searchOptions == currentSearchOptions
                }
        }
        searchApproval.publish(matchIDs: matches.map(\.id),
                               isComplete: complete && searchError == nil,
                               generation: searchApproval.generation)
    }

    func searchMatchIsEditable(_ match: NavMatch) -> Bool {
        if scope.isFolderLike {
            guard let url = match.url else { return false }
            return folderResults.first { $0.url == url }?.isWritable == true
        }
        let target: EditorTab?
        if let tabID = match.tabID { target = tabs.first { $0.id == tabID } }
        else { target = scope == .file ? activeTab : nil }
        return target.map { textEditingIsAllowed(for: $0) } == true
    }

    var editableSearchMatchIDs: Set<UUID> {
        let matches = navMatches
        switch scope {
        case .file:
            return activeTab.map { textEditingIsAllowed(for: $0) } == true ? Set(matches.map(\.id)) : []
        case .open:
            let editableTabs = Set(tabs.filter { textEditingIsAllowed(for: $0) }.map(\.id))
            return Set(matches.filter { $0.tabID.map(editableTabs.contains) == true }.map(\.id))
        case .folder, .project:
            let urls = Set(folderResults.filter(\.isWritable).map(\.url))
            return Set(matches.filter { $0.url.map(urls.contains) == true }.map(\.id))
        }
    }

    @discardableResult
    func setSearchMatchesApproved(_ approved: Bool, ids: Set<UUID>, generation: UInt64) -> Bool {
        if approved {
            guard ids.isSubset(of: editableSearchMatchIDs) else { return false }
        }
        return searchApproval.setApproved(approved, ids: ids, generation: generation)
    }

    @discardableResult
    func setAllSearchMatchesApproved(_ approved: Bool, generation: UInt64) -> Bool {
        let ids = approved
            ? editableSearchMatchIDs
            : Set(searchApproval.matchIDs)
        return setSearchMatchesApproved(approved, ids: ids, generation: generation)
    }
}
