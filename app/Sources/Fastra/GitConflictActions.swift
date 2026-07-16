import AppKit
import Foundation

enum ActiveConflictSupport: Equatable {
    case none
    case text(change: GitChange, blocks: [ConflictMarkerBlock])
    case unsafe(change: GitChange, reason: String)
    case unsupported(change: GitChange, reason: String)

    var change: GitChange? {
        switch self {
        case .none: return nil
        case .text(let change, _), .unsafe(let change, _),
             .unsupported(let change, _): return change
        }
    }

    var blocks: [ConflictMarkerBlock] {
        if case .text(_, let blocks) = self { return blocks }
        return []
    }
}

enum GitConflictNavigation {
    /// Eine andere Konfliktdatei beginnt stets beim ersten Block – auch wenn
    /// beide Dateien zufällig dieselbe Blockanzahl besitzen.
    static func indexAfterActiveFileChange() -> Int { 0 }
}

extension Workspace {
    /// Gemeinsamer Eventpfad für einen echten Tabwechsel. SwiftUI ruft diesen
    /// Helfer aus `onChange(activeTabID)` auf; Tests können damit dieselbe
    /// Zustandsänderung ohne ein Fenster auslösen.
    func activeGitConflictFileDidChange() {
        activeConflictIndex = GitConflictNavigation.indexAfterActiveFileChange()
        invalidateAndRefreshActiveConflictInspection()
        jumpToActiveConflict()
    }

    var conflictedGitChanges: [GitChange] {
        gitStatus?.changes.filter {
            $0.staged == .conflicted || $0.unstaged == .conflicted
        } ?? []
    }

    var activeConflictSupport: ActiveConflictSupport {
        guard let tab = activeTab, let url = tab.url,
              let root = projectURL,
              let relative = Self.repositoryRelativePath(file: url, root: root),
              let change = conflictedGitChanges.first(where: { $0.actionPath == relative })
        else { return .none }
        guard change.isPathActionable else {
            return .unsupported(change: change,
                reason: L10n.string("Dieser Konfliktpfad ist kein gültiges UTF-8 und kann von Fastra nicht verlustfrei an Git übergeben werden."))
        }
        guard tab.displayMode == .text else {
            let reason = tab.displayMode == .hex
                ? L10n.string("Dieser Konflikt ist binär oder nicht sicher als Text dekodierbar. Fastra wählt keine Seite automatisch.")
                : L10n.string("Diese Datei ist für eine vollständige, sichere Textauflösung zu groß. Öffne ein Terminal für die Git-Auflösung.")
            return .unsupported(change: change, reason: reason)
        }
        let markerSize: Int
        switch gitConflictInspections[change.rawPath] {
        case .text(let inspectedSize):
            markerSize = inspectedSize
        case .unsupportedBinary:
            return .unsupported(
                change: change,
                reason: L10n.string("Git klassifiziert diesen Konflikt über Dateiattribute als binär. Fastra bietet keine Textauflösung oder Stage-Aktion an. Öffne ein Terminal für die Git-Auflösung.")
            )
        case .unavailable:
            return .unsupported(
                change: change,
                reason: L10n.string("Git konnte die Dateiattribute dieses Konflikts nicht eindeutig prüfen. Fastra bietet keine Textauflösung oder Stage-Aktion an. Öffne ein Terminal für die Git-Auflösung.")
            )
        case .checking, nil:
            return .unsupported(
                change: change,
                reason: L10n.string("Fastra prüft die Git-Dateiattribute, bevor Textauflösung oder Staging angeboten werden.")
            )
        }
        switch ConflictMarkerParser.parse(tab.content, markerSize: markerSize) {
        case .parsed(let blocks):
            return .text(change: change, blocks: blocks)
        case .unsafe(let reason):
            return .unsafe(change: change, reason: reason)
        }
    }

    var activeConflictBlock: ConflictMarkerBlock? {
        let blocks = activeConflictSupport.blocks
        guard !blocks.isEmpty else { return nil }
        return blocks[min(max(0, activeConflictIndex), blocks.count - 1)]
    }

    var activeConflictMarkerSize: Int {
        activeConflictSupport.change.flatMap { gitConflictMarkerSizes[$0.rawPath] } ?? 7
    }

    func moveActiveConflict(by offset: Int) {
        let blocks = activeConflictSupport.blocks
        guard !blocks.isEmpty else { return }
        activeConflictIndex = min(max(0, activeConflictIndex + offset), blocks.count - 1)
        jumpToActiveConflict()
    }

    func jumpToActiveConflict() {
        guard let block = activeConflictBlock else { return }
        NotificationCenter.default.post(
            name: .fastraJumpToRange, object: self,
            userInfo: ["range": NSValue(range: block.fullRange)]
        )
        EditorView.focusActiveEditor(in: self)
    }

    func acceptActiveConflict(_ choice: ConflictResolutionChoice) {
        guard let tab = activeTab, let block = activeConflictBlock,
              let change = activeConflictSupport.change,
              let replacement = ConflictMarkerParser.replacement(
                in: tab.content, block: block, choice: choice
              ) else {
            NSSound.beep(); return
        }
        let tabID = tab.id
        let request = ConflictEditorReplacementRequest(
            workspace: self, tabID: tabID, expectedText: tab.content,
            replacement: replacement
        ) { [weak self] editorText in
            guard let self,
                  let index = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            // Die TextView hat zuerst ersetzt und ihre native Undo-Aktion
            // registriert. Das Modell wird anschließend nur auf denselben
            // Editorstand synchronisiert, niemals als Ersatz für den Undo-Pfad.
            self.tabs[index].content = editorText
            self.tabs[index].isDirty = true
            let markerSize = self.gitConflictMarkerSizes[change.rawPath] ?? 7
            let remaining = ConflictMarkerParser.parse(
                editorText, markerSize: markerSize
            ).blocks.count
            self.activeConflictIndex = remaining == 0 ? 0
                : min(self.activeConflictIndex, remaining - 1)
        }
        conflictTextReplacementHandler(request)
    }

    func markActiveConflictResolved() {
        guard let tab = activeTab else { return }
        let support = activeConflictSupport
        let change: GitChange
        switch support {
        case .text(let value, _), .unsafe(let value, _): change = value
        case .none, .unsupported:
            Self.presentGitErrorText(
                label: "Konfliktauflösung",
                text: L10n.string("Diese Datei kann nicht sicher als Textkonflikt aufgelöst werden."))
            return
        }
        guard let path = change.actionPath,
              let url = tab.url,
              let context = currentGitActionContext else {
            Self.presentGitErrorText(
                label: "Konfliktauflösung",
                text: L10n.string("Diese Datei kann nicht sicher als Textkonflikt aufgelöst werden."))
            return
        }
        guard !tab.isDirty else {
            Self.presentGitErrorText(
                label: "Konfliktauflösung",
                text: L10n.string("Speichere die Datei zuerst. Erst der gespeicherte Stand darf als gelöst markiert werden."))
            return
        }
        guard let expectedData = FileLoader.encodedData(
            content: tab.content, encoding: tab.encoding,
            bom: tab.bom, lineEnding: tab.lineEnding
        ) else {
            Self.presentGitErrorText(
                label: "Konfliktauflösung",
                text: L10n.string("Der Editorinhalt lässt sich nicht verlustfrei im gewählten Datei-Encoding speichern."))
            return
        }
        let rawPath = change.rawPath
        _ = GitConflictStagingRunner.run(
            repository: context.root, rawPath: rawPath, path: path,
            fileURL: url, expectedData: expectedData, expectedText: tab.content,
            coordinator: gitOperationsCoordinator,
            validate: { inspection in
                let remainsUnmerged = inspection.status.changes.contains {
                    $0.rawPath == rawPath
                        && ($0.staged == .conflicted || $0.unstaged == .conflicted)
                }
                return remainsUnmerged ? nil
                    : L10n.string("Der Konfliktstatus dieser Datei hat sich geändert. Lies den Status neu ein und prüfe die Datei erneut.")
            },
            decision: { [weak self] markerSize, hasMarkers, proceed in
                guard let self, context.isCurrent(in: self) else {
                    proceed(false); return
                }
                self.gitConflictMarkerSizes[rawPath] = markerSize
                proceed(!hasMarkers || self.confirmIntentionalConflictMarkersHandler(path))
            }
        ) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitRepositoryStore.publishOperations(for: context.root)
                guard context.isCurrent(in: self) else { return }
                self.handleValidatedMutationOutcome(outcome, action: .conflictResolution)
            }
        }
        gitRepositoryStore.publishOperations(for: context.root)
    }

    static func defaultConfirmIntentionalConflictMarkers(_ path: String) -> Bool {
        guard presentGitDialogs else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Konfliktmarker absichtlich beibehalten?")
        alert.informativeText = L10n.format(
            "„%@“ enthält weiterhin Zeilen wie <<<<<<<, ======= oder >>>>>>>. Nur fortsetzen, wenn diese Zeichenfolgen beabsichtigter Dateiinhalt und keine ungelösten Konflikte sind. Fastra staged ausschließlich die zuvor geprüften Bytes dieser Datei.",
            path)
        alert.addButton(withTitle: L10n.string("Marker absichtlich beibehalten"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func refreshActiveConflictMarkerSize() {
        invalidateAndRefreshActiveConflictInspection()
    }

    func invalidateAndRefreshActiveConflictInspection() {
        gitConflictInspectionLease?.cancel()
        gitConflictInspectionLease = nil
        // Eine späte Completion des abgebrochenen Pfads darf weder dessen
        // Zustand noch die Lease des inzwischen aktiven Tabs überschreiben.
        gitConflictInspectionRequestIDs = [:]
        guard let tab = activeTab, let url = tab.url,
              let context = currentGitActionContext,
              let relative = Self.repositoryRelativePath(file: url, root: context.root),
              let change = conflictedGitChanges.first(where: { $0.actionPath == relative }),
              let path = change.actionPath else { return }
        let requestID = UUID()
        gitConflictInspectionRequestIDs[change.rawPath] = requestID
        gitConflictInspections[change.rawPath] = .checking
        let request = GitOperationRequest(
            repository: context.root, kind: .refresh,
            arguments: GitConflictAttributeParser.arguments(path: path),
            outputLimit: GitOutputLimit(stdoutBytes: 256 * 1024,
                                        stderrBytes: 64 * 1024)
        )
        gitConflictInspectionLease = gitOperationsCoordinator.perform(request) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self, context.isCurrent(in: self),
                      self.gitConflictInspectionRequestIDs[change.rawPath] == requestID
                else { return }
                self.gitConflictInspectionRequestIDs[change.rawPath] = nil
                self.gitConflictInspectionLease = nil
                guard case .completed(let result) = outcome, result.ok,
                      !result.stdoutWasTruncated,
                      let attributes = GitConflictAttributeParser.parseSelected(
                        result.stdoutData, expectedRawPath: change.rawPath
                      ) else {
                    self.gitConflictInspections[change.rawPath] = .unavailable
                    return
                }
                self.gitConflictMarkerSizes[change.rawPath] = attributes.markerSize
                self.gitConflictInspections[change.rawPath] = attributes.isBinary
                    ? .unsupportedBinary : .text(markerSize: attributes.markerSize)
                self.activeConflictIndex = min(self.activeConflictIndex,
                                               max(0, self.activeConflictSupport.blocks.count - 1))
            }
        }
    }

    static func parseConflictMarkerSize(_ data: Data) -> Int? {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count >= 3,
              String(decoding: fields[1], as: UTF8.self) == "conflict-marker-size"
        else { return nil }
        let value = String(decoding: fields[2], as: UTF8.self)
        if value == "unspecified" || value == "unset" { return 7 }
        guard let size = Int(value), size > 0, size <= 1024 else { return nil }
        return size
    }

    func refreshGitOperationState() {
        guard let context = currentGitActionContext, GitRunner.isAvailable else { return }
        gitRepositoryStore.refresh(repository: context.root, scope: .status)
    }

    static func repositoryRelativePath(file: URL, root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    func handleValidatedMutationOutcome(_ outcome: GitValidatedMutationOutcome,
                                        action: GitActionText,
                                        successArgument: String? = nil) {
        let label = action.labelKey
        switch outcome {
        case .executed(.completed(let result)) where result.ok:
            recordGitSuccess(action.localizedSuccess(successArgument))
        case .executed(.completed(let result)):
            Self.presentGitError(label: label, result: result)
        case .executed(let failure), .inspectionFailed(let failure):
            Self.presentGitExecutionFailure(label: label, outcome: failure)
        case .blocked(let reason):
            Self.presentGitErrorText(label: label, text: reason)
        case .missingIdentity:
            Self.presentGitErrorText(
                label: label,
                text: L10n.string("Git benötigt vor dieser Aktion eine bewusst konfigurierte Commit-Identität."))
        case .repositoryChanged:
            Self.presentGitErrorText(
                label: label,
                text: L10n.string("Repository, Branch oder Arbeitsbaum haben sich während der Sicherheitsprüfung geändert. Prüfe den neuen Stand und starte die Aktion erneut."))
        case .cancelled:
            break
        }
        refreshGitRepositoryFully()
        refreshOpenGitViews()
        refreshGitOperationState()
    }
}
