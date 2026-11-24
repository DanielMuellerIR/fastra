import Darwin
import Foundation
import Testing
@testable import Fastra

private final class RecoveryReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    let release = DispatchSemaphore(value: 0)
    var didStart: Bool { lock.withLock { started } }
    func wait() {
        lock.withLock { started = true }
        _ = release.wait(timeout: .now() + 15)
    }
}

private struct RecoveryIntegrationFixture {
    let root: URL
    let sources: URL
    let backups: URL
    let targets: [URL]
    let control: URL
    let original = Data([0xEF, 0xBB, 0xBF]) + Data("rot\r\nzweite Zeile\r\n".utf8)
    let session: ApplySession

    init(secondOriginal: Data? = nil) throws {
        let proposed = testTemporaryDirectory().appendingPathComponent("recovery-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: proposed, withIntermediateDirectories: true)
        root = try ApplyPersistenceBarriers.resolvingRootAliases(proposed)
        let sources = root.appendingPathComponent("sources")
        self.sources = sources
        backups = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: false)
        targets = ["first.txt", "second.txt"].map { sources.appendingPathComponent($0) }
        control = sources.appendingPathComponent("control.txt")
        for (index, url) in targets.enumerated() { try (index == 1 ? secondOriginal ?? original : original).write(to: url) }
        try Data("Kontrolle\r\n".utf8).write(to: control)
        session = try ApplyEngine.apply(plan: ApplyEngine.plan(files: targets,
            options: SearchOptions(find: "rot", replace: "blau", isRegex: false)),
            backupRoot: backups, cleanupOlderThan: nil)
    }

    @MainActor func workspace(_ defaults: UserDefaults) throws -> Workspace {
        let ws = Workspace(defaults: defaults)
        ws.scope = .folder
        ws.recentSearchFolders = [SearchFolderEntry(path: sources.path, enabled: true)]
        ws.folderApplyBackupRoot = backups
        ws.showSearchDialog = true
        ws.fileTreeMutationWorkspaceProvider = { [] }
        ws.tabs = try targets.map { url in
            let loaded = try FileLoader.load(url: url)
            var tab = EditorTab(title: url.lastPathComponent, path: url.path, url: url,
                                content: loaded.content, diskSnapshot: loaded.diskSnapshot)
            tab.recordSavedContentBaseline()
            return tab
        }
        ws.activeTabID = ws.tabs[0].id
        return ws
    }

    static func historicalProcesses() -> ApplyRecoveryProcessScope.Observation {
        .init(current: .init(pid: getpid(), startedAt: .distantFuture), otherFastraProcesses: [])
    }

    @MainActor func selected(_ ws: Workspace, selectedSession: ApplySession? = nil,
                            processes: @escaping () throws -> ApplyRecoveryProcessScope.Observation = historicalProcesses) async throws -> ApplyRecoverySession {
        let model = ApplyRecoverySession(workspace: ws, processes: processes)
        ws.fileRecoverySession = model
        model.load()
        try #require(await recoveryWait { !model.isBusy })
        #expect(model.selectedName == nil && model.review == nil && !model.canConfirm)
        model.select((selectedSession ?? session).sessionDirectory.lastPathComponent)
        try #require(await recoveryWait { !model.isBusy })
        try #require(model.canConfirm, "\(model.error ?? "keine Vorschau")")
        return model
    }
}

@MainActor private func recoveryWait(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<1500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite("Historische Wiederherstellung: Produktbindung und echte Reload-Abschlüsse", .serialized)
struct ApplyRecoveryIntegrationTests {
    @Test("Bestätigtes BOM-/CRLF-Undo hält Claim und Editiersperre bis zum tatsächlichen Reload",
          arguments: [false, true])
    @MainActor func serialRunnerIntegrationReloadLifetime(_ failReload: Bool) async throws {
        let fixture = try RecoveryIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let domain = "fastra-test-recovery-" + UUID().uuidString
        let defaults = testSuiteDefaults(named: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let ws = try fixture.workspace(defaults)
        let other = try fixture.workspace(defaults)
        ws.fileTreeMutationWorkspaceProvider = { [other] }
        let selectedTab = other.activeTabID
        let newer = try ApplyEngine.apply(plan: ApplyEngine.plan(files: [fixture.control],
            options: SearchOptions(find: "Kontrolle", replace: "Neue Kontrolle", isRegex: false)),
            backupRoot: fixture.backups, cleanupOlderThan: nil)
        ws.lastApplySession = newer
        let control = try FileSnapshot.readSnapshotOnly(from: fixture.control)
        let model = try await fixture.selected(ws)
        let gate = RecoveryReadGate()
        defer { gate.release.signal() }
        ws.reloadFileLoader = { url in
            if url == fixture.targets[0] {
                gate.wait()
                if failReload { throw CocoaError(.fileReadNoPermission) }
            }
            return try FileLoader.load(url: url)
        }
        model.confirm()
        try #require(await recoveryWait { gate.didStart })
        #expect(model.isExecuting && ws.fileRecoveryApplying)
        #expect(ws.fileMutationIsInFlight(for: fixture.targets[0]))
        #expect(!ws.textEditingIsAllowed(for: ws.tabs[0]))
        #expect(!ws.prepareToCloseWindow() && !ws.confirmCloseAllDirtyForQuit())
        #expect(throws: (any Error).self) {
            try ApplyRecoveryDirectoryClaim(root: fixture.backups, sessionName: fixture.session.sessionDirectory.lastPathComponent)
        }
        #expect(try Data(contentsOf: fixture.targets[0]) == fixture.original)
        gate.release.signal()
        try #require(await recoveryWait { !model.isExecuting })
        #expect(!ws.fileRecoveryApplying && !ws.fileMutationIsInFlight(for: fixture.targets[0]))
        let claim = try ApplyRecoveryDirectoryClaim(root: fixture.backups, sessionName: fixture.session.sessionDirectory.lastPathComponent)
        try claim.finish()
        #expect(ws.lastApplySession?.sessionDirectory == newer.sessionDirectory)
        #expect(other.activeTabID == selectedTab)
        #expect(other.tabs[0].content == "rot\r\nzweite Zeile\r\n")
        #expect(!other.tabs[0].hasUnsavedChanges)
        #expect(try FileSnapshot.readSnapshotOnly(from: fixture.control) == control)
        #expect((model.error != nil) == failReload)
        if !failReload { #expect(ws.tabs[0].content == other.tabs[0].content) }
        #expect(model.review == nil && !model.canConfirm)
        model.close()
    }

    @Test("Ordner-Rückgängig sperrt die betroffenen Editoren bis zum geprüften Reload")
    @MainActor func serialRunnerIntegrationFolderUndoReloadLifetime() async throws {
        let fixture = try RecoveryIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let domain = "fastra-test-folder-undo-" + UUID().uuidString
        let defaults = testSuiteDefaults(named: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let ws = try fixture.workspace(defaults)
        ws.lastApplySession = fixture.session
        let target = fixture.targets[0]
        let aliased = target.standardizedFileURL
        ws.tabs[0].url = aliased
        let gate = RecoveryReadGate()
        defer { gate.release.signal() }
        ws.reloadFileLoader = { url in
            if url == aliased { gate.wait() }
            return try FileLoader.load(url: url)
        }

        let undo = Task { await ws.undoLastFolderApply() }
        try #require(await recoveryWait { gate.didStart })
        #expect(ws.diskMutationIsActive && ws.fileMutationIsInFlight(for: target))
        #expect(!ws.textEditingIsAllowed(for: ws.tabs[0]))
        #expect(ws.tabs[0].content.contains("blau"))
        #expect(try Data(contentsOf: target) == fixture.original)
        gate.release.signal()
        #expect(await undo.value)
        #expect(ws.lastApplySession == nil && !ws.diskMutationIsActive)
        #expect(!ws.fileMutationIsInFlight(for: target))
        #expect(ws.tabs[0].content == "rot\r\nzweite Zeile\r\n")
    }

    @Test("Abbruch, neue Quellen und spätere Dateiversion entziehen die historische Freigabe", arguments: [0, 1, 2, 3])
    @MainActor func serialRunnerIntegrationRevokedApproval(_ kind: Int) async throws {
        let fixture = try RecoveryIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let domain = "fastra-test-recovery-revoke-" + UUID().uuidString
        let defaults = testSuiteDefaults(named: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let ws = try fixture.workspace(defaults)
        let model = try await fixture.selected(ws)
        let manifestURL = fixture.session.sessionDirectory.appendingPathComponent("manifest.json")
        let manifest = try FileSnapshot.readSnapshotOnly(from: manifestURL)
        switch kind {
        case 0: model.close()
        case 1: ws.recentSearchFolders = []; model.reconcile()
        case 2: try Data("Fremdstand\r\n".utf8).write(to: fixture.targets[0], options: .atomic)
        default: ws.tabs[0].content += "ungesichert"; ws.tabs[0].isDirty = true
        }
        let target = try FileSnapshot.readSnapshotOnly(from: fixture.targets[0])
        model.confirm()
        try #require(await recoveryWait { !model.isExecuting })
        #expect(try FileSnapshot.readSnapshotOnly(from: fixture.targets[0]) == target)
        #expect(try FileSnapshot.readSnapshotOnly(from: manifestURL) == manifest)
        #expect(!ws.fileMutationIsInFlight(for: fixture.targets[0]))
        #expect(ws.lastApplySession == nil)
        model.close()
    }

    @Test("Eine zweite Kopie nach der Vorschau sperrt die Ausführung vor dem ersten Schreiben")
    @MainActor func serialRunnerIntegrationSecondCopyAfterPreview() async throws {
        let fixture = try RecoveryIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let domain = "fastra-test-recovery-process-" + UUID().uuidString
        let defaults = testSuiteDefaults(named: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let ws = try fixture.workspace(defaults)
        let marker = fixture.root.appendingPathComponent("second-copy-observed")
        let model = try await fixture.selected(ws, processes: {
            var current = RecoveryIntegrationFixture.historicalProcesses()
            if FileManager.default.fileExists(atPath: marker.path) {
                current = .init(current: current.current, otherFastraProcesses: [.init(pid: 42, startedAt: .distantFuture)])
            }
            return current
        })
        let before = try FileSnapshot.readSnapshotOnly(from: fixture.targets[0])
        try Data().write(to: marker)
        model.confirm()
        try #require(await recoveryWait { !model.isExecuting })
        #expect(model.error?.contains("Fastra") == true)
        #expect(try FileSnapshot.readSnapshotOnly(from: fixture.targets[0]) == before)
        #expect(!ws.fileMutationIsInFlight(for: fixture.targets[0]))
        model.close()
    }

    @Test("Eine nach dem ersten Restore beobachtete zweite Kopie erhält Teilfortschritt für neue Prüfung")
    @MainActor func serialRunnerIntegrationPartialAndRetry() async throws {
        let fixture = try RecoveryIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let domain = "fastra-test-recovery-partial-" + UUID().uuidString
        let defaults = testSuiteDefaults(named: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let ws = try fixture.workspace(defaults)
        let stop = fixture.root.appendingPathComponent("observe-copy-after-first-restore")
        try Data().write(to: stop)
        let model = try await fixture.selected(ws, processes: {
            let initial = RecoveryIntegrationFixture.historicalProcesses()
            if FileManager.default.fileExists(atPath: stop.path),
               (try? Data(contentsOf: fixture.targets[0])) == fixture.original {
                return .init(current: initial.current, otherFastraProcesses: [.init(pid: 42, startedAt: .distantFuture)])
            }
            return initial
        })
        let second = try FileSnapshot.readSnapshotOnly(from: fixture.targets[1])
        model.confirm()
        try #require(await recoveryWait { !model.isExecuting })
        #expect(model.error != nil && model.review == nil)
        #expect(model.error?.contains("ApplyRecoveryProcessScope") == false)
        #expect(try Data(contentsOf: fixture.targets[0]) == fixture.original)
        #expect(try FileSnapshot.readSnapshotOnly(from: fixture.targets[1]) == second)
        #expect(try ApplyEngine.loadSession(at: fixture.session.sessionDirectory).entries.map(\.state) == [.restored, .applied])
        #expect(ws.lastApplySession == nil)
        try FileManager.default.removeItem(at: stop)
        model.refreshSelected()
        try #require(await recoveryWait { !model.isBusy })
        try #require(model.canConfirm)
        #expect(model.review?.preview.targets[0].state == .previouslyRestored)
        model.confirm()
        try #require(await recoveryWait { !model.isExecuting })
        #expect(model.error == nil)
        #expect(try Data(contentsOf: fixture.targets[1]) == fixture.original)
        model.close()
    }

    @Test("Cleanup-only behält nach Abweisung seinen eigenen Retry ohne den normalen Undo-Slot zu übernehmen")
    @MainActor func serialRunnerIntegrationCleanupOnlyRetry() async throws {
        let fixture = try RecoveryIntegrationFixture()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: fixture.root) }
        let saved = fixture.root.appendingPathComponent("saved-cleanup-anchor")
        var anchor: ApplyPendingFile?
        var cleanup: ApplySession?
        do {
            _ = try ApplyEngine.apply(plan: ApplyEngine.plan(files: fixture.targets,
                options: SearchOptions(find: "blau", replace: "gruen", isRegex: false)),
                backupRoot: fixture.backups, cleanupOlderThan: nil, manifestWriter: { candidate in
                    try ApplyEngine.writeManifest(candidate)
                    if let pending = candidate.entries.last?.pendingFile, candidate.entries.last?.state == .pending {
                        anchor = pending
                        try fm.moveItem(at: pending.url, to: saved)
                        try Data("fremder Anker".utf8).write(to: pending.url)
                        throw CocoaError(.fileWriteNoPermission)
                    }
                })
            Issue.record("Die Fixture hätte einen echten Cleanup-only-Auftrag hinterlassen müssen")
        } catch ApplyError.writeFailed(let partial, _) { cleanup = partial }
        let retained = try #require(anchor)
        let cleanupSession = try #require(cleanup)
        try #require(cleanupSession.isCleanupOnly)
        try fm.removeItem(at: retained.url)
        try fm.moveItem(at: saved, to: retained.url)
        let domain = "fastra-test-recovery-cleanup-" + UUID().uuidString
        let defaults = testSuiteDefaults(named: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let ws = try fixture.workspace(defaults)
        ws.lastApplySession = fixture.session
        let before = try fixture.targets.map { try FileSnapshot.readSnapshotOnly(from: $0) }
        let model = try await fixture.selected(ws, selectedSession: cleanupSession)
        #expect(model.review?.preview.hasFileWrites == false)
        #expect(model.review?.differences.isEmpty == true)
        try fm.moveItem(at: retained.url, to: saved)
        try Data("neue fremde Belegung".utf8).write(to: retained.url)
        let foreign = try FileSnapshot.readSnapshotOnly(from: retained.url)
        model.confirm()
        try #require(await recoveryWait { !model.isExecuting })
        #expect(model.error != nil && model.review == nil)
        #expect(try FileSnapshot.readSnapshotOnly(from: retained.url) == foreign)
        #expect(ws.lastApplySession?.sessionDirectory == fixture.session.sessionDirectory)
        try fm.removeItem(at: retained.url)
        try fm.moveItem(at: saved, to: retained.url)
        model.refreshSelected()
        try #require(await recoveryWait { !model.isBusy })
        try #require(model.canConfirm)
        model.confirm()
        try #require(await recoveryWait { !model.isExecuting })
        #expect(model.error == nil)
        #expect(!fm.fileExists(atPath: retained.url.path))
        #expect(!fm.fileExists(atPath: try #require(retained.cleanupDirectory).url.path))
        #expect(try fixture.targets.map { try FileSnapshot.readSnapshotOnly(from: $0) } == before)
        #expect(ws.lastApplySession?.sessionDirectory == fixture.session.sessionDirectory)
        model.refreshSelected()
        try #require(await recoveryWait { !model.isBusy })
        #expect(!model.canConfirm)
        model.close()
    }

    @Test("Tab-Invalidierung und Workspace-Abbau schließen Reload erst nach seiner physischen Antwort ab", arguments: [false, true])
    @MainActor func serialRunnerIntegrationReloadTerminalCompletion(_ releaseWorkspace: Bool) async throws {
        let fixture = try RecoveryIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let domain = "fastra-test-recovery-reload-terminal-" + UUID().uuidString
        let defaults = testSuiteDefaults(named: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        var ws: Workspace? = try fixture.workspace(defaults)
        weak var weakWorkspace = ws
        let adapter = Workspace.DocumentFileLoadAdapter(workspace: try #require(ws))
        let loads = DocumentFileLoads(adapter: adapter)
        let gate = RecoveryReadGate()
        defer { gate.release.signal() }
        var completed: [URL]?
        loads.reloadAfterDiskMutation(changedURLs: [fixture.targets[0]], loader: {
            { url in gate.wait(); return try FileLoader.load(url: url) }
        }) { completed = $0 }
        try #require(await recoveryWait { gate.didStart })
        if releaseWorkspace { ws = nil; #expect(weakWorkspace == nil) }
        else { loads.invalidateAll() }
        #expect(completed == nil)
        gate.release.signal()
        try #require(await recoveryWait { completed != nil })
        #expect(completed == [fixture.targets[0]])
    }

    @Test("Der normale Projektbereich bindet vollständiges Projekt und exakte Datei-Sets", arguments: [false, true])
    @MainActor func serialRunnerIntegrationProjectScope(_ exactFiles: Bool) async throws {
        let fixture = try RecoveryIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let domain = "fastra-test-recovery-project-" + UUID().uuidString
        let defaults = testSuiteDefaults(named: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let ws = try fixture.workspace(defaults)
        ws.projectURL = fixture.sources; ws.scope = .project
        var configuration = ProjectSearchConfiguration.fresh()
        if exactFiles { configuration.fileSets[0].paths = fixture.targets.map(\.lastPathComponent) }
        ws.projectSearchConfiguration = configuration
        let model = try await fixture.selected(ws)
        #expect(model.scope == .project)
        #expect(model.review?.differences.count == 2)
        model.confirm()
        try #require(await recoveryWait { !model.isExecuting })
        #expect(model.error == nil)
        #expect(try Data(contentsOf: fixture.targets[0]) == fixture.original)
        model.close()
    }

    @Test("Bewusst gewählte Quellaliasauflösung bleibt nach der Vorschau gebunden")
    @MainActor func serialRunnerIntegrationSourceAliasBinding() async throws {
        let fixture = try RecoveryIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let domain = "fastra-test-recovery-alias-" + UUID().uuidString
        let defaults = testSuiteDefaults(named: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let ws = try fixture.workspace(defaults)
        let alias = fixture.root.appendingPathComponent("selected-source")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.sources)
        ws.recentSearchFolders = [SearchFolderEntry(path: alias.path, enabled: true)]
        let model = try await fixture.selected(ws)
        let before = try FileSnapshot.readSnapshotOnly(from: fixture.targets[0])
        let otherRoot = fixture.root.appendingPathComponent("other-source")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: otherRoot)
        model.confirm()
        try #require(await recoveryWait { !model.isExecuting })
        #expect(model.error != nil)
        #expect(try FileSnapshot.readSnapshotOnly(from: fixture.targets[0]) == before)
        model.close()
    }

    @Test("Nicht darstellbare zweite Datei und Gesamtbudget geben keine Teilvorschau frei")
    func completeReviewRejectsPartialDiff() throws {
        let fixture = try RecoveryIntegrationFixture(secondOriginal: Data(("rot\n" + String(repeating: "x", count: 128)).utf8))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let observation = try ApplyRecoverySessionReader.read(sessionNamed: fixture.session.sessionDirectory.lastPathComponent,
                                                               in: fixture.backups)
        #expect(throws: ApplyRecoveryPreview.Failure.limit) {
            try ApplyRecoveryReview.build(observation: observation, roots: [fixture.sources], maximumDisplayBytes: 1)
        }
        var limits = ApplyRecoveryPreview.Limits()
        limits.diffBytes = 64
        let preview = try ApplyRecoveryPreview.build(observation: observation, selectedRoots: [fixture.sources], limits: limits)
        _ = try preview.diff(forTargetAt: 0)
        #expect(throws: ApplyRecoveryPreview.Failure.limit) { try preview.diff(forTargetAt: 1) }
        #expect(throws: ApplyRecoveryPreview.Failure.limit) {
            try ApplyRecoveryReview.build(observation: observation, roots: [fixture.sources], limits: limits)
        }
    }
}

@Test("Ein bestätigtes Original bleibt für den Reload bekannt, wenn der folgende Manifestabschluss scheitert")
func serialRunnerIntegrationRecoveryKeepsVerifiedOriginalOnManifestFailure() throws {
    let fixture = try RecoveryIntegrationFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let directory = fixture.session.sessionDirectory
    let name = directory.lastPathComponent
    let observation = try ApplyRecoverySessionReader.read(sessionNamed: name, in: fixture.backups)
    let claim = try ApplyRecoveryDirectoryClaim(root: fixture.backups, sessionName: name)
    defer { try? claim.finish() }
    defer { _ = chmod(directory.path, 0o700) }

    var verified: [URL: FileSnapshot] = [:]
    #expect(throws: (any Error).self) {
        try ApplyEngine.undoRecovery(fixture.session, holding: claim, expectedManifest: observation.manifest.snapshot,
                                     expectedBackups: observation.backups.mapValues(\.snapshot),
                                     verifiedOriginal: { url, snapshot in
            verified[url] = snapshot
            #expect(chmod(directory.path, 0o500) == 0)
        })
    }

    let restored = try #require(verified.keys.first)
    #expect(verified.count == 1)
    #expect(verified[restored] == (try FileSnapshot.readSnapshotOnly(from: restored)))
    #expect(try Data(contentsOf: restored) == fixture.original)
    let other = try #require(fixture.targets.first { $0 != restored })
    #expect(try Data(contentsOf: other) != fixture.original)
    #expect(try FileSnapshot.readSnapshotOnly(from: directory.appendingPathComponent("manifest.json")) == observation.manifest.snapshot)
}
