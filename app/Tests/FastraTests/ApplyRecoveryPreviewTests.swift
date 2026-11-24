import Darwin
import Foundation
import Testing
@testable import Fastra

private typealias RecoveryPreview = ApplyRecoveryPreview

private struct RecoveryPreviewFixture {
    let directory: URL
    let sources: URL
    let backups: URL
    let targets: [URL]
    let control: URL
    let original = Data([0xEF, 0xBB, 0xBF]) + Data("rot\r\nzweite Zeile\r\n".utf8)

    init() throws {
        let proposed = testTemporaryDirectory().appendingPathComponent("recovery-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: proposed, withIntermediateDirectories: true)
        directory = try ApplyPersistenceBarriers.resolvingRootAliases(proposed)
        let sources = directory.appendingPathComponent("sources")
        self.sources = sources
        backups = directory.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: false)
        targets = ["first.txt", "second.txt"].map { sources.appendingPathComponent($0) }
        control = sources.appendingPathComponent("control.txt")
        for target in targets { try original.write(to: target) }
        try Data("unbeteiligt\r\n".utf8).write(to: control)
    }

    func apply(manifestWriter: ((ApplySession) throws -> Void)? = nil) throws -> ApplySession {
        try ApplyEngine.apply(plan: ApplyEngine.plan(files: targets,
            options: SearchOptions(find: "rot", replace: "blau", isRegex: false)),
            backupRoot: backups, cleanupOlderThan: nil, manifestWriter: manifestWriter)
    }

    func observe(_ session: ApplySession) throws -> ApplyRecoverySessionReader.Observation {
        try ApplyRecoverySessionReader.read(sessionNamed: session.sessionDirectory.lastPathComponent, in: backups)
    }

    func preview(_ session: ApplySession, roots: [URL]? = nil,
                 limits: RecoveryPreview.Limits = .init()) throws -> RecoveryPreview {
        try RecoveryPreview.build(observation: observe(session), selectedRoots: roots ?? [sources], limits: limits)
    }

    func artifacts() throws -> [String: FileSnapshot] {
        let paths = try #require(FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: nil)?.allObjects as? [URL])
        return try Dictionary(uniqueKeysWithValues: paths.compactMap { url in
            var info = stat()
            try #require(lstat(url.path, &info) == 0)
            return info.st_mode & S_IFMT == S_IFREG
                ? (url.path, try FileSnapshot.readSnapshotOnly(from: url)) : nil
        })
    }

    func claim(_ session: ApplySession) throws -> ApplyRecoveryDirectoryClaim {
        try ApplyRecoveryDirectoryClaim(root: backups, sessionName: session.sessionDirectory.lastPathComponent)
    }

    func persist(_ session: ApplySession, states: [UndoEntry.State]) throws -> ApplySession {
        let entries = zip(session.entries, states).map { entry, state in
            UndoEntry(originalPath: entry.originalPath, backupRelativePath: entry.backupRelativePath,
                originalSHA256: entry.originalSHA256, encodingRawValue: entry.encodingRawValue, bom: entry.bom,
                appliedSnapshot: entry.appliedSnapshot, state: state, pendingFile: entry.pendingFile)
        }
        let result = ApplySession(timestamp: session.timestamp, sessionDirectory: session.sessionDirectory,
                                  entries: entries, retainedPendingFiles: session.retainedPendingFiles)
        try ApplyEngine.writeManifest(result)
        return result
    }
}

@Test("Wiederherstellungsvorschau bindet reguläres Mehrdatei-Apply samt BOM/CRLF und bleibt lesend")
private func recoveryPreviewNormalApply() throws {
    let fixture = try RecoveryPreviewFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    let before = try fixture.artifacts()
    let listed = try RecoveryPreview.list(in: fixture.backups, createdBefore: Date().addingTimeInterval(1))
    #expect(listed.candidates.count == 1)
    #expect(!listed.reachedLimit && !listed.scanWasLimited)
    #expect(try listed.candidates[0].open() == fixture.observe(session))
    #expect(try RecoveryPreview.list(in: fixture.backups, createdBefore: .distantPast).candidates.isEmpty)
    let preview = try fixture.preview(session)
    #expect(preview.targets.map(\.state) == [.restore, .restore])
    #expect(preview.targets.map(\.url) == fixture.targets)
    #expect(preview.hasFileWrites)
    #expect(!preview.remainingCleanupURLs.isEmpty)
    let difference = try preview.diff(forTargetAt: 0)
    #expect(difference.currentBOM == Data([0xEF, 0xBB, 0xBF]))
    #expect(difference.originalBOM == difference.currentBOM)
    let diff = try #require(difference.document.result)
    #expect(diff.rows.contains { $0.before == "blau" && $0.after == "rot" })
    #expect(!diff.isIdentical)
    let claim = try fixture.claim(session)
    try preview.validate(holding: claim)
    try claim.finish()
    #expect(try fixture.artifacts() == before)
}

@Test("Vollständige Einzeldatei-Wurzeln erlauben nur ihre gebundenen Nebenressourcen")
private func recoveryPreviewExactProjectFiles() throws {
    let fixture = try RecoveryPreviewFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    let preview = try fixture.preview(session, roots: fixture.targets)
    #expect(preview.targets.count == 2)
    #expect(throws: RecoveryPreview.Failure.self) {
        try fixture.preview(session, roots: [fixture.targets[0]])
    }
}

@Test("Pending-Manifest erlaubt den vorbereiteten Zwilling nur neben seiner gewählten Einzeldatei")
private func recoveryPreviewPendingProjectFiles() throws {
    let fixture = try RecoveryPreviewFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var pending: ApplySession?
    _ = try fixture.apply { candidate in
        if pending == nil, candidate.entries.contains(where: { $0.state == .pending }) {
            pending = candidate
        }
        try ApplyEngine.writeManifest(candidate)
    }
    let session = try #require(pending)
    try #require(!session.retainedPendingFiles.isEmpty)
    try fixture.original.write(to: fixture.targets[0], options: .atomic)
    try ApplyEngine.writeManifest(session)
    let preview = try fixture.preview(session, roots: [fixture.targets[0]])
    #expect(preview.targets.map(\.state) == [.originalAlreadyPresent])
    let cleanupOnly = ApplySession(timestamp: session.timestamp, sessionDirectory: session.sessionDirectory,
                                    entries: [], retainedPendingFiles: session.retainedPendingFiles)
    try ApplyEngine.writeManifest(cleanupOnly)
    #expect(throws: RecoveryPreview.Failure.self) {
        try fixture.preview(cleanupOnly, roots: [fixture.targets[0]])
    }
}

@Test("Zu groß gewordene Zieldatei meldet die feste Lesegrenze")
private func recoveryPreviewReportsTargetReadLimit() throws {
    let fixture = try RecoveryPreviewFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    let handle = try FileHandle(forWritingTo: fixture.targets[0])
    try handle.truncate(atOffset: FileSnapshot.maximumReadBytes + 1)
    try handle.close()
    #expect(throws: RecoveryPreview.Failure.limit) { try fixture.preview(session) }
}

@Test("Wurzelgrenzen vergleichen Komponenten und lehnen fremde Quellen ab")
private func recoveryPreviewRejectsPathPrefix() throws {
    let fixture = try RecoveryPreviewFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    let prefix = fixture.directory.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
    #expect(throws: RecoveryPreview.Failure.outsideSelectedRoots(fixture.targets[0])) {
        try fixture.preview(session, roots: [prefix])
    }
    let linked = fixture.directory.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.sources)
    #expect(throws: RecoveryPreview.Failure.self) { try fixture.preview(session, roots: [linked]) }
}

@Test("Geänderte Dateisystembindungen verwerfen die Vorschau", arguments:
      ["target-replace", "target-write", "backup-replace", "backup-write", "manifest", "root", "parent-symlink"])
private func recoveryPreviewRevalidatesBindings(kind: String) throws {
    let fixture = try RecoveryPreviewFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    let preview = try fixture.preview(session)
    let claim = try fixture.claim(session)
    defer { try? claim.finish() }
    let entry = try #require(session.entries.first)
    let backup = session.sessionDirectory.appendingPathComponent(entry.backupRelativePath)
    switch kind {
    case "target-replace", "backup-replace":
        let url = kind == "target-replace" ? fixture.targets[0] : backup
        let bytes = try Data(contentsOf: url)
        try bytes.write(to: url, options: .atomic)
    case "target-write", "backup-write":
        let url = kind == "target-write" ? fixture.targets[0] : backup
        let bytes = try Data(contentsOf: url)
        let file = try FileHandle(forWritingTo: url)
        try file.write(contentsOf: bytes)
        try file.close()
    case "manifest": try ApplyEngine.writeManifest(session)
    case "root":
        try FileManager.default.moveItem(at: fixture.sources,
                                        to: fixture.directory.appendingPathComponent("old-sources"))
        try FileManager.default.createDirectory(at: fixture.sources, withIntermediateDirectories: false)
    default:
        let moved = fixture.directory.appendingPathComponent("old-sources")
        try FileManager.default.moveItem(at: fixture.sources, to: moved)
        try FileManager.default.createSymbolicLink(at: fixture.sources, withDestinationURL: moved)
    }
    #expect(throws: (any Error).self) { try preview.validate(holding: claim) }
    #expect(throws: (any Error).self) { try preview.diff(forTargetAt: 0) }
}

@Test("Identische Originalbytes erlauben ohne Write fortzufahren; fremde Applied-Inodes nicht")
private func recoveryPreviewHonorsUndoContentRules() throws {
    let fixture = try RecoveryPreviewFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    let applied = try Data(contentsOf: fixture.targets[0])
    try applied.write(to: fixture.targets[0], options: .atomic)
    #expect(throws: RecoveryPreview.Failure.targetConflict(fixture.targets[0])) {
        try fixture.preview(session)
    }
    try fixture.original.write(to: fixture.targets[0], options: .atomic)
    let preview = try fixture.preview(session)
    #expect(preview.targets.map(\.state) == [.originalAlreadyPresent, .restore])
    #expect(try preview.diff(forTargetAt: 0).document.result?.isIdentical == true)
}

@Test("Pending braucht bei Applied-Bytes seinen bestehenden Anker")
private func recoveryPreviewPendingNeedsAnchor() throws {
    let fixture = try RecoveryPreviewFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.persist(fixture.apply(), states: [.pending, .applied])
    #expect(try fixture.preview(session).targets[0].state == .restore)
    let pending = try #require(session.entries[0].pendingFile)
    try FileManager.default.removeItem(at: pending.url)
    #expect(throws: RecoveryPreview.Failure.targetConflict(fixture.targets[0])) {
        try fixture.preview(session)
    }
    try fixture.original.write(to: fixture.targets[0], options: .atomic)
    #expect(try fixture.preview(session).targets[0].state == .originalAlreadyPresent)
}

@Test("Erledigtes Teil-Undo benötigt seine alte Sicherung und Zieldatei nicht mehr")
private func recoveryPreviewSkipsRestoredInputs() throws {
    let fixture = try RecoveryPreviewFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.persist(fixture.apply(), states: [.restored, .applied])
    try FileManager.default.removeItem(at: fixture.targets[0])
    try FileManager.default.removeItem(at: session.sessionDirectory.appendingPathComponent(session.entries[0].backupRelativePath))
    let preview = try fixture.preview(session)
    #expect(preview.targets.map(\.state) == [.previouslyRestored, .restore])
    #expect(preview.targets[0].current == nil)
    #expect(preview.targets[0].backup == nil)
    #expect(throws: RecoveryPreview.Failure.noDifference) { try preview.diff(forTargetAt: 0) }
}

@Test("Eine inzwischen große erledigte Datei blockiert die offenen Rücknahmen nicht")
private func recoveryPreviewDoesNotReadRestoredFileContents() throws {
    let fixture = try RecoveryPreviewFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let applied = try fixture.apply()
    let pending = try #require(applied.entries[0].pendingFile)
    let anchor = try FileSnapshot.readSnapshotOnly(from: pending.url)
    let anchorBytes = try Data(contentsOf: pending.url)
    try #require(FileIdentity(url: fixture.targets[0]) == anchor.identity)
    // Ein abgeschlossenes Undo trennt das Ziel vom Pending-Hardlink. Erst
    // danach darf eine fremde Änderung die erledigte Datei vergrößern.
    try fixture.original.write(to: fixture.targets[0], options: .atomic)
    try #require(Data(contentsOf: fixture.targets[0]) == fixture.original)
    try #require(FileIdentity(url: fixture.targets[0]) != anchor.identity)
    let session = try fixture.persist(applied, states: [.restored, .applied])
    let file = try FileHandle(forWritingTo: fixture.targets[0])
    try file.truncate(atOffset: FileSnapshot.maximumReadBytes + 1)
    #expect(try file.seekToEnd() == FileSnapshot.maximumReadBytes + 1)
    try file.close()
    #expect(try FileSnapshot.readSnapshotOnly(from: pending.url) == anchor)
    #expect(try Data(contentsOf: pending.url) == anchorBytes)
    let preview = try fixture.preview(session, roots: fixture.targets)
    #expect(preview.targets.map(\.state) == [.previouslyRestored, .restore])
    #expect(preview.targets[0].current == nil)
    #expect(preview.targets[0].backup == nil)
    #expect(throws: RecoveryPreview.Failure.noDifference) { try preview.diff(forTargetAt: 0) }
    #expect(try preview.diff(forTargetAt: 1).document.result?.isIdentical == false)
    let claim = try fixture.claim(session)
    try preview.validate(holding: claim)
    try claim.finish()
    #expect(try FileSnapshot.readSnapshotOnly(from: pending.url) == anchor)
    #expect(try Data(contentsOf: pending.url) == anchorBytes)
}

private enum RecoveryPreviewFixtureFailure: Error { case retainCleanup }

private func recoveryPreviewCleanupFixture(_ fixture: RecoveryPreviewFixture) throws -> ApplySession {
    let saved = fixture.directory.appendingPathComponent("saved-anchor")
    var result: ApplySession?
    var ownAnchor: URL?
    do {
        _ = try fixture.apply { candidate in
            if let pending = candidate.entries.last?.pendingFile, candidate.entries.last?.state == .pending {
                try ApplyEngine.writeManifest(candidate)
                ownAnchor = pending.url
                try FileManager.default.moveItem(at: pending.url, to: saved)
                try Data("fremder Anker".utf8).write(to: pending.url)
                throw RecoveryPreviewFixtureFailure.retainCleanup
            }
            try ApplyEngine.writeManifest(candidate)
        }
        Issue.record("Der Manifestfehler hätte das Apply unterbrechen müssen")
    } catch ApplyError.writeFailed(let partial, _) { result = partial }
    let session = try #require(result)
    try #require(session.isCleanupOnly)
    let anchor = try #require(ownAnchor)
    try FileManager.default.removeItem(at: anchor)
    try FileManager.default.moveItem(at: saved, to: anchor)
    return session
}

@Test("Echtes Cleanup-only bleibt auswählbar und zeigt ausschließlich vorhandene Reste")
private func recoveryPreviewCleanupOnly() throws {
    let fixture = try RecoveryPreviewFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try recoveryPreviewCleanupFixture(fixture)
    let before = try fixture.artifacts()
    let preview = try fixture.preview(session)
    #expect(preview.targets.isEmpty)
    #expect(!preview.hasFileWrites)
    #expect(!preview.remainingCleanupURLs.isEmpty)
    #expect(preview.remainingCleanupURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    #expect(throws: RecoveryPreview.Failure.self) { try fixture.preview(session, roots: fixture.targets) }
    let claim = try fixture.claim(session)
    try preview.validate(holding: claim)
    try claim.finish()
    #expect(try fixture.artifacts() == before)
}

@Test("Cleanup lehnt fremde und nach der Vorschau geänderte Ressourcen ab", arguments:
      ["source", "anchor", "work", "unexpected-child", "claim", "source-write", "anchor-write",
       "source-directory", "anchor-directory", "source-symlink", "anchor-symlink"])
private func recoveryPreviewRejectsCleanupChanges(kind: String) throws {
    let fixture = try RecoveryPreviewFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try recoveryPreviewCleanupFixture(fixture)
    let pending = try #require(session.retainedPendingFiles.first)
    let work = try #require(pending.cleanupDirectory)
    if kind.hasPrefix("source"), !FileManager.default.fileExists(atPath: work.preparedURL.path) {
        // Der echte Fehlerlauf hat den öffentlichen Temp-Namen bereits
        // aufgeräumt. Für diese Varianten denselben erhaltenen Anker dort
        // binden, wie vor dem Cleanup des ursprünglichen Auftrags.
        try #require(link(work.url.appendingPathComponent("anchor").path, work.preparedURL.path) == 0)
    }
    let preview = try fixture.preview(session)
    let claim = try fixture.claim(session)
    defer { try? claim.finish() }
    switch kind {
    case "source", "anchor":
        let url = kind == "source" ? work.preparedURL : work.url.appendingPathComponent("anchor")
        let bytes = try Data(contentsOf: url)
        try bytes.write(to: url, options: .atomic)
    case "source-write", "anchor-write":
        let url = kind == "source-write" ? work.preparedURL : work.url.appendingPathComponent("anchor")
        let bytes = try Data(contentsOf: url)
        let file = try FileHandle(forWritingTo: url)
        try file.write(contentsOf: bytes)
        try file.close()
    case "source-directory", "anchor-directory", "source-symlink", "anchor-symlink":
        let url = kind.hasPrefix("source") ? work.preparedURL : work.url.appendingPathComponent("anchor")
        try FileManager.default.removeItem(at: url)
        if kind.hasSuffix("directory") {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } else {
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: fixture.control)
        }
    case "work":
        let saved = fixture.directory.appendingPathComponent("saved-work")
        try FileManager.default.moveItem(at: work.url, to: saved)
        try FileManager.default.createDirectory(at: work.url, withIntermediateDirectories: false)
    case "claim": try Data("fremd".utf8).write(to: work.url.appendingPathComponent("prepared.claim"))
    default: try Data("fremd".utf8).write(to: work.url.appendingPathComponent("unrelated"))
    }
    let changed = try fixture.artifacts()
    #expect(throws: (any Error).self) { try preview.validate(holding: claim) }
    #expect(try fixture.artifacts() == changed)
}

@Test("Bereits fehlende Reste sind kein Auftrag für später neu belegte Namen")
private func recoveryPreviewMissingCleanupDoesNotGrantAuthority() throws {
    let fixture = try RecoveryPreviewFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try recoveryPreviewCleanupFixture(fixture)
    for file in session.retainedPendingFiles { try file.remove() }
    let preview = try fixture.preview(session)
    #expect(preview.remainingCleanupURLs.isEmpty)
    let pending = try #require(session.retainedPendingFiles.first)
    let source = try #require(pending.cleanupDirectory).preparedURL
    try Data("neu belegt".utf8).write(to: source)
    let before = try fixture.artifacts()
    let claim = try fixture.claim(session)
    defer { try? claim.finish() }
    #expect(throws: (any Error).self) { try preview.validate(holding: claim) }
    #expect(try fixture.artifacts() == before)
}

@Test("Listen- und Diffgrenzen geben nie eine abgeschnittene Vorschau zurück")
private func recoveryPreviewLimitsAreExplicit() throws {
    let fixture = try RecoveryPreviewFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    var limits = RecoveryPreview.Limits()
    limits.diffBytes = 1
    let preview = try fixture.preview(session, limits: limits)
    #expect(throws: RecoveryPreview.Failure.limit) { try preview.diff(forTargetAt: 0) }
    limits = .init()
    limits.totalTargetBytes = 1
    #expect(throws: RecoveryPreview.Failure.limit) { try fixture.preview(session, limits: limits) }
    limits = .init()
    limits.directoryEntries = 1
    try FileManager.default.createDirectory(at: fixture.backups.appendingPathComponent("unrelated"),
                                            withIntermediateDirectories: false)
    #expect(try RecoveryPreview.list(in: fixture.backups, createdBefore: .distantFuture,
                                     limits: limits).scanWasLimited)
}

@Test("Die leichte Liste liest keine Manifeste und bindet die Auswahl erneut")
private func recoveryPreviewListsMetadataWithoutReadingBackups() throws {
    let fixture = try RecoveryPreviewFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    let manifest = session.sessionDirectory.appendingPathComponent("manifest.json")
    try Data("beschädigt".utf8).write(to: manifest, options: .atomic)
    var limits = RecoveryPreview.Limits()
    limits.totalBackupBytes = 1
    let listed = try RecoveryPreview.list(in: fixture.backups, createdBefore: .distantFuture, limits: limits)
    let candidate = try #require(listed.candidates.first)
    #expect(throws: ApplyRecoverySessionReader.Failure.invalid(.manifest, .malformedManifest)) {
        try candidate.open()
    }
    try FileManager.default.moveItem(at: session.sessionDirectory,
                                    to: fixture.directory.appendingPathComponent("old-session"))
    try FileManager.default.createDirectory(at: session.sessionDirectory, withIntermediateDirectories: false)
    #expect(throws: RecoveryPreview.Failure.changed(session.sessionDirectory)) { try candidate.open() }
}

@Test("Die leichte Liste behält die neuesten beobachteten Kandidaten und meldet ihr Limit")
private func recoveryPreviewListKeepsNewestCandidates() throws {
    let fixture = try RecoveryPreviewFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try FileManager.default.createDirectory(at: fixture.backups, withIntermediateDirectories: false)
    for name in ["session-first", "session-second", "session-third"] {
        try FileManager.default.createDirectory(at: fixture.backups.appendingPathComponent(name),
                                                withIntermediateDirectories: false)
    }
    let full = try RecoveryPreview.list(in: fixture.backups, createdBefore: .distantFuture)
    var limits = RecoveryPreview.Limits()
    limits.sessions = 2
    let listed = try RecoveryPreview.list(in: fixture.backups, createdBefore: .distantFuture, limits: limits)
    #expect(listed.candidates.map(\.sessionName) == Array(full.candidates.prefix(2)).map(\.sessionName))
    #expect(listed.reachedLimit)
    #expect(!listed.scanWasLimited)
}
