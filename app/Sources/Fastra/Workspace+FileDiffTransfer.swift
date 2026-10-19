import Foundation

@MainActor
extension Workspace {
    func fileDiffTransferStatus(tabID: UUID, requestID: UUID) -> String? {
        guard let state = tabs.first(where: { $0.id == tabID })?.fileDiff,
              state.request.id == requestID else { return nil }
        if let error = state.transferError { return error }
        if let document = state.document,
           let left = document.leftSource, let right = document.rightSource,
           !left.referencesCurrentDocument(in: self) || !right.referencesCurrentDocument(in: self) {
            return FileDiffTransfer.Failure.stale.localizedDescription
        }
        return nil
    }

    func refreshFileDiffOnReturn(tabID: UUID, requestID: UUID) {
        guard activeTabID == tabID, fileDiffTransferPreview == nil,
              let state = tabs.first(where: { $0.id == tabID })?.fileDiff,
              state.request.id == requestID, state.pendingTransferID == nil,
              let document = state.document,
              let left = document.leftSource, let right = document.rightSource else { return }
        // Dateiänderungen werden im Hintergrund erneut gelesen. Dokumente
        // brauchen nach Undo/Redo einen neuen, an ihre Revision gebundenen Diff.
        if left.fileURL != nil || right.fileURL != nil
            || !left.referencesCurrentDocument(in: self) || !right.referencesCurrentDocument(in: self) {
            refreshFileDiffComparison(tabID: tabID, requestID: requestID)
        }
    }

    func fileDiffTransferIsAvailable(tabID: UUID, requestID: UUID, direction: FileDiffTransfer.Direction) -> Bool {
        guard activeTabID == tabID,
              let state = tabs.first(where: { $0.id == tabID })?.fileDiff,
              state.request.id == requestID, state.pendingTransferID == nil,
              let document = state.document, let left = document.leftSource, let right = document.rightSource,
              left.referencesCurrentDocument(in: self), right.referencesCurrentDocument(in: self),
              let target = (direction == .toLeft ? left : right).documentOrigin?.currentTab(in: self),
              textEditingIsAllowed(for: target) else { return false }
        return document.result?.isIdentical == false
    }

    func prepareFileDiffTransfer(tabID: UUID, requestID: UUID, blockID: Int, direction: FileDiffTransfer.Direction) {
        guard fileDiffTransferIsAvailable(tabID: tabID, requestID: requestID, direction: direction),
              let index = tabs.firstIndex(where: { $0.id == tabID }),
              let request = tabs[index].fileDiffRequest,
              let document = tabs[index].fileDiffDocument else { return }
        let targetName = direction == .toLeft ? request.left.name : request.right.name
        let ticket = fileDiffComputations.begin(tabID: tabID)
        tabs[index].fileDiff?.pendingTransferID = ticket.id
        tabs[index].fileDiff?.transferError = nil
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Swift.Result<FileDiffTransferPreview, Error>
            do {
                result = .success(try FileDiffTransferPreview.prepare(tabID: tabID, requestID: requestID,
                    direction: direction, blockID: blockID, targetName: targetName,
                    document: document, isCancelled: { Task.isCancelled }))
            } catch is CancellationError { return }
            catch { result = .failure(error) }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.fileDiffComputations.isCurrent(ticket) else { return }
                self.fileDiffComputations.finish(ticket)
                guard let index = self.tabs.firstIndex(where: { $0.id == tabID }),
                      self.tabs[index].fileDiffRequest?.id == requestID,
                      self.tabs[index].fileDiff?.pendingTransferID == ticket.id else { return }
                self.tabs[index].fileDiff?.pendingTransferID = nil
                guard self.activeTabID == tabID else { return }
                switch result {
                case .success(let preview):
                    if preview.isCurrent(in: self) { self.fileDiffTransferPreview = preview }
                    else { self.tabs[index].fileDiff?.transferError = FileDiffTransfer.Failure.stale.localizedDescription }
                case .failure(let error):
                    self.tabs[index].fileDiff?.transferError = TextWorkflowFailure.message(error)
                }
            }
        }
        fileDiffComputations.attach(task, to: ticket)
    }

    func cancelFileDiffTransfer(tabID: UUID, requestID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[index].fileDiffRequest?.id == requestID,
              tabs[index].fileDiff?.pendingTransferID != nil else { return }
        fileDiffComputations.cancel(tabID: tabID)
        tabs[index].fileDiff?.pendingTransferID = nil
    }

    func refreshFileDiffComparison(tabID: UUID, requestID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              let request = tabs[index].fileDiffRequest, request.id == requestID else { return }
        func refreshed(_ side: FileDiffSide) -> FileDiffSide? {
            guard let origin = side.documentOrigin else { return side }
            guard origin.workspaceID == ObjectIdentifier(self),
                  CommandTargeting.registeredWindow(for: self).map(ObjectIdentifier.init) == origin.windowID,
                  let tab = tabs.first(where: { $0.id == origin.tabID && $0.documentID == origin.documentID }) else { return nil }
            return FileDiffSide.document(tab, in: self)
        }
        guard let left = refreshed(request.left), let right = refreshed(request.right) else {
            tabs[index].fileDiff?.transferError = FileDiffTransfer.Failure.stale.localizedDescription
            return
        }
        fileDiffTransferPreview = nil
        openFileDiffTab(request: FileDiffRequest(left: left, right: right, options: request.options))
    }

    func applyFileDiffTransfer(_ validation: FileDiffTransferPreview.ValidatedApply) throws {
        let preview = validation.preview
        // Ein geschlossenes Sheet entwertet auch die verspätete Rückmeldung
        // der unmittelbar davor ausgeführten Datei-Snapshotprüfung.
        guard fileDiffTransferPreview?.id == preview.id, preview.isCurrent(in: self), validation.filesAreCurrent(),
              let origin = preview.destination.documentOrigin else { throw FileDiffTransfer.Failure.stale }
        let target = try TextWorkflowOpenDocumentsPlan.Source.capture(in: self, tabIDs: [origin.tabID])
        _ = try TextWorkflowOpenDocumentsPlan.applyReplacements([origin.tabID: preview.change.output], source: target, in: self)
        fileDiffTransferPreview = nil
        refreshFileDiffComparison(tabID: preview.comparisonTabID, requestID: preview.requestID)
    }
}
