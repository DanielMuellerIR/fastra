import Foundation
import Testing
@testable import Fastra

private enum ManifestRollbackTarget: String, CaseIterable, Sendable {
    case original
    case foreignBytes
    case foreignReplacementBytes

    var bytes: Data {
        switch self {
        case .original: Data("foo two".utf8)
        case .foreignBytes: Data("foreign two".utf8)
        case .foreignReplacementBytes: Data("bar two".utf8)
        }
    }
}

private enum ManifestRollbackSessionSource: String, CaseIterable, Sendable {
    case returnedPartial
    case reloadedManifest
}

private enum ManifestRollbackFailure: Error {
    case beforeSecondSwap
    case rollbackManifest
}

@Test("Fehlgeschlagenes Manifest-Rollback schützt nie angewendete Ziele beim Undo",
      arguments: ManifestRollbackTarget.allCases, ManifestRollbackSessionSource.allCases)
private func applyManifestRollbackPreservesUnwrittenTarget(
    targetState: ManifestRollbackTarget,
    sessionSource: ManifestRollbackSessionSource
) throws {
    let directory = testTemporaryDirectory().appendingPathComponent(
        "fastra-manifest-rollback-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first.txt")
    let second = directory.appendingPathComponent("second.txt")
    let backups = directory.appendingPathComponent("backups", isDirectory: true)
    let firstOriginal = Data("foo one".utf8)
    let secondOriginal = Data("foo two".utf8)
    try firstOriginal.write(to: first)
    try secondOriginal.write(to: second)
    let secondOriginalIdentity = try #require(FileIdentity(url: second))
    let options = SearchOptions(find: "foo", replace: "bar", isRegex: false,
                                caseSensitive: true)
    let plan = ApplyEngine.plan(files: [first, second], options: options)
    let inputs = try plan.changedFiles.map {
        ApplyTransaction.Input(url: $0.url, snapshot: try #require($0.originalSnapshot),
                               matches: $0.matches)
    }
    #expect(inputs.map(\.url) == [first, second])
    let transaction = ApplyTransaction(inputs: inputs, options: options)

    var partial: ApplySession?
    var secondRejectedBeforeSwap = false
    var rollbackFailures = 0
    var manifestCandidates: [ApplySession] = []
    var errorMessage = ""
    do {
        _ = try transaction.execute(
            backupRoot: backups, cleanupOlderThan: nil,
            beforeAtomicReplace: { url in
                if url == second {
                    #expect(try Data(contentsOf: first) == Data("bar one".utf8))
                    #expect(try Data(contentsOf: second) == secondOriginal)
                    #expect(FileIdentity(url: second) == secondOriginalIdentity)
                    secondRejectedBeforeSwap = true
                    throw ManifestRollbackFailure.beforeSecondSwap
                }
            }, manifestWriter: { candidate in
                manifestCandidates.append(candidate)
                if secondRejectedBeforeSwap,
                   candidate.entries.map(\.originalPath) == [first.path],
                   candidate.entries.map(\.state) == [.applied] {
                    rollbackFailures += 1
                    throw ManifestRollbackFailure.rollbackManifest
                }
                try ApplyEngine.writeManifest(candidate)
            })
        Issue.record("Der Fehler vor dem zweiten Swap hätte Apply abbrechen müssen")
    } catch ApplyError.writeFailed(let session, let message) {
        partial = session
        errorMessage = message
        #expect(!message.isEmpty)
    }
    #expect(secondRejectedBeforeSwap)
    #expect(rollbackFailures == 1)
    let returned = try #require(partial)
    #expect(manifestCandidates.map { $0.entries.map(\.state) }
            == [[], [.pending], [.applied], [.applied, .pending], [.applied]])
    #expect(returned.entries.map(\.originalPath) == [first.path])
    #expect(returned.entries.map(\.state) == [.applied])

    // Der fehlgeschlagene Rückschritt darf den tatsächlich persistierten
    // pending-Eintrag nicht aus dem Testaufbau verschwinden lassen.
    let persisted = try ApplyEngine.loadSession(at: returned.sessionDirectory)
    #expect(persisted.entries.map(\.originalPath) == [first.path, second.path])
    #expect(persisted.entries.map(\.state) == [.applied, .pending])
    #expect(persisted.entries[1].appliedSnapshot?.identity != nil)
    let anchor = try #require(persisted.entries[1].pendingFile)
    #expect(anchor.isValid)
    #expect(anchor.snapshot == persisted.entries[1].appliedSnapshot)
    #expect(returned.retainedPendingFiles == [anchor] + persisted.retainedPendingFiles)
    #expect(persisted.retainedPendingFiles.count == 1)
    #expect(persisted.retainedPendingFiles[0].snapshot == anchor.snapshot)
    #expect(errorMessage.contains(returned.sessionDirectory.path))
    #expect(errorMessage.contains("Manifest"))
    #expect(try Data(contentsOf: first) == Data("bar one".utf8))
    #expect(try Data(contentsOf: second) == secondOriginal)
    #expect(FileIdentity(url: second) == secondOriginalIdentity)
    let backupURLs = persisted.entries.map {
        persisted.sessionDirectory.appendingPathComponent($0.backupRelativePath)
    }
    let backupSnapshots = try backupURLs.map { try FileSnapshot.read(from: $0).snapshot }
    #expect(try backupURLs.map { try Data(contentsOf: $0) } == [firstOriginal, secondOriginal])

    let savedOriginal = directory.appendingPathComponent("second-original.txt")
    if targetState != .original {
        // Das alte Objekt bleibt erreichbar: Die neue fremde Datei kann
        // dessen Inode nicht durch sofortige Wiederverwendung erben.
        try FileManager.default.moveItem(at: second, to: savedOriginal)
        try targetState.bytes.write(to: second)
        #expect(FileIdentity(url: savedOriginal) == secondOriginalIdentity)
        #expect(try Data(contentsOf: savedOriginal) == secondOriginal)
    }
    let beforeUndoSecond = try FileSnapshot.read(from: second)
    if targetState != .original {
        let foreignIdentity = try #require(beforeUndoSecond.snapshot.identity)
        #expect(foreignIdentity != secondOriginalIdentity)
    }
    let beforeUndoFirst = try FileSnapshot.read(from: first)

    // Die App behält die zurückgegebene Partial-Session. Das gesonderte
    // Laden prüft nur Engine-Wiederaufnahme, keinen App-Neustartpfad.
    let undoSession = sessionSource == .returnedPartial
        ? returned : try ApplyEngine.loadSession(at: returned.sessionDirectory)
    let expectsConflict = sessionSource == .reloadedManifest && targetState != .original
    var conflictMessage: String?
    var undone: ApplySession?
    do {
        undone = try ApplyEngine.undo(undoSession)
    } catch ApplyError.undoConflict(let message) {
        conflictMessage = message
    }
    if expectsConflict {
        #expect(conflictMessage?.contains(second.lastPathComponent) == true,
                "Das nie angewendete fremde Ziel muss als Konflikt benannt werden")
        #expect(undone == nil)
        #expect(try FileSnapshot.read(from: first).snapshot == beforeUndoFirst.snapshot,
                "Der vollständige Konflikt-Preflight muss auch den ersten Restore verhindern")
        #expect(try ApplyEngine.loadSession(at: returned.sessionDirectory) == persisted)
    } else {
        #expect(conflictMessage == nil)
        let completed = try #require(undone)
        #expect(completed.entries.map(\.state)
                == (sessionSource == .returnedPartial ? [.restored] : [.restored, .restored]))
        #expect(try Data(contentsOf: first) == firstOriginal)
        #expect(!FileManager.default.fileExists(atPath: anchor.url.path))
    }
    #expect(try FileSnapshot.read(from: second).snapshot == beforeUndoSecond.snapshot,
            "Undo darf weder Bytes noch Inode des nie angewendeten Ziels ersetzen")
    #expect(try Data(contentsOf: second) == targetState.bytes)
    #expect(try backupURLs.map { try FileSnapshot.read(from: $0).snapshot } == backupSnapshots)
    #expect(try backupURLs.map { try Data(contentsOf: $0) } == [firstOriginal, secondOriginal])
    if targetState != .original {
        #expect(FileIdentity(url: savedOriginal) == secondOriginalIdentity)
        #expect(try Data(contentsOf: savedOriginal) == secondOriginal)
    }
}

private func makePendingIdentityFixture() throws -> (directory: URL, target: URL, backups: URL, plan: ReplacePlan) {
    let directory = testTemporaryDirectory().appendingPathComponent(
        "fastra-pending-identity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = directory.appendingPathComponent("target.txt")
    try Data("foo".utf8).write(to: target)
    return (directory, target, directory.appendingPathComponent("backups"),
            ApplyEngine.plan(files: [target], options: SearchOptions(
                find: "foo", replace: "bar", isRegex: false, caseSensitive: true)))
}

@Test("Applied-Manifest-Write mit anschließendem Fehler erhält RAM- und Reload-Undo",
      arguments: ManifestRollbackSessionSource.allCases)
private func pendingIdentityAppliedManifestWriteThenThrow(
    sessionSource: ManifestRollbackSessionSource
) throws {
    let fixture = try makePendingIdentityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let foreignURL = fixture.directory.appendingPathComponent("foreign.txt")
    try Data("foreign unchanged".utf8).write(to: foreignURL)
    let foreign = try FileSnapshot.readSnapshotOnly(from: foreignURL)
    let failure = NSError(domain: "ManifestRollbackTest", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "applied manifest written then rejected"])
    var candidates: [ApplySession] = []
    var partial: ApplySession?
    var backupSnapshot: FileSnapshot?
    var message = ""
    do {
        _ = try ApplyEngine.apply(plan: fixture.plan, backupRoot: fixture.backups,
            cleanupOlderThan: nil, manifestWriter: { candidate in
                candidates.append(candidate)
                if candidate.entries.isEmpty {
                    backupSnapshot = try FileSnapshot.readSnapshotOnly(
                        from: candidate.sessionDirectory.appendingPathComponent("files/0.bin"))
                }
                try ApplyEngine.writeManifest(candidate)
                if candidate.entries.last?.state == .applied { throw failure }
            })
        Issue.record("Der Fehler nach dem Applied-Write hätte weitergegeben werden müssen")
    } catch ApplyError.writeFailed(let session, let detail) {
        partial = session
        message = detail
    }
    #expect(candidates.map { $0.entries.map(\.state) } == [[], [.pending], [.applied]])
    let returned = try #require(partial)
    let pending = try #require(candidates.first { $0.entries.last?.state == .pending })
    let applied = try #require(candidates.first { $0.entries.last?.state == .applied })
    let persisted = try ApplyEngine.loadSession(at: returned.sessionDirectory)
    // Ein bestätigter Write und ein erfolgreicher Writer-Aufruf sind verschieden.
    // Der Throw lässt RAM auf pending, obwohl das Manifest bereits applied ist.
    #expect(returned == pending)
    #expect(persisted == applied)
    #expect(returned.entries.map(\.state) == [.pending])
    #expect(persisted.entries.map(\.state) == [.applied])
    #expect(returned.retainedPendingFiles.count == 1)
    #expect(persisted.retainedPendingFiles.isEmpty)
    let entry = try #require(returned.entries.first)
    let persistedEntry = try #require(persisted.entries.first)
    let anchor = try #require(entry.pendingFile)
    #expect(anchor.isValid)
    #expect(entry.originalPath == fixture.target.path)
    #expect(persistedEntry.originalPath == entry.originalPath)
    #expect(persistedEntry.backupRelativePath == entry.backupRelativePath)
    #expect(persistedEntry.originalSHA256 == entry.originalSHA256)
    #expect(persistedEntry.appliedSnapshot == entry.appliedSnapshot)
    #expect(persistedEntry.pendingFile == anchor)
    #expect(entry.appliedSnapshot == anchor.snapshot)
    #expect(returned.retainedPendingFiles[0].snapshot == anchor.snapshot)
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == anchor.snapshot)
    #expect(try Data(contentsOf: fixture.target) == Data("bar".utf8))
    #expect(message.contains(failure.localizedDescription))
    let backupURL = returned.sessionDirectory.appendingPathComponent(entry.backupRelativePath)
    let originalBackup = try #require(backupSnapshot)
    #expect(try FileSnapshot.readSnapshotOnly(from: backupURL) == originalBackup)
    #expect(try Data(contentsOf: backupURL) == Data("foo".utf8))
    let cleanupFiles = pending.retainedPendingFiles + pending.entries.compactMap(\.pendingFile)
    #expect(cleanupFiles.count == 2)
    let undone = try ApplyEngine.undo(sessionSource == .returnedPartial ? returned : persisted)
    #expect(undone.entries.map(\.state) == [.restored])
    #expect(try ApplyEngine.loadSession(at: undone.sessionDirectory) == undone)
    #expect(try Data(contentsOf: fixture.target) == Data("foo".utf8))
    #expect(try FileSnapshot.readSnapshotOnly(from: foreignURL) == foreign)
    #expect(try Data(contentsOf: foreignURL) == Data("foreign unchanged".utf8))
    #expect(try FileSnapshot.readSnapshotOnly(from: backupURL) == originalBackup)
    for file in cleanupFiles {
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(!FileManager.default.fileExists(atPath: try #require(file.cleanupClaimURL).path))
        #expect(!FileManager.default.fileExists(atPath: try #require(file.cleanupDirectory).url.path))
    }
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path))
        == [fixture.target.lastPathComponent, fixture.backups.lastPathComponent, foreignURL.lastPathComponent])
}

private func applyWithFailedAppliedManifest(_ fixture: (directory: URL, target: URL, backups: URL, plan: ReplacePlan)) throws -> ApplySession {
    do {
        _ = try ApplyEngine.apply(plan: fixture.plan, backupRoot: fixture.backups,
            cleanupOlderThan: nil, manifestWriter: { candidate in
                if candidate.entries.last?.state == .applied {
                    throw ManifestRollbackFailure.rollbackManifest
                }
                try ApplyEngine.writeManifest(candidate)
            })
        Issue.record("Der Applied-Manifestfehler hätte weitergegeben werden müssen")
    } catch ApplyError.writeFailed(let partial, _) {
        #expect(partial.entries.map(\.state) == [.pending])
        return try ApplyEngine.loadSession(at: partial.sessionDirectory)
    }
    throw ManifestRollbackFailure.rollbackManifest
}

@Test("Fremder bytegleicher Replace nach echtem Apply legitimiert pending nicht")
private func pendingIdentityRejectsForeignReplacementAfterSuccessfulSwap() throws {
    let fixture = try makePendingIdentityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let pending = try applyWithFailedAppliedManifest(fixture)
    let entry = try #require(pending.entries.first)
    let anchor = try #require(entry.pendingFile)
    #expect(anchor.isValid)
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == anchor.snapshot)
    // Kein Verschieben nötig: Auch nach echtem Unlink des Zielnamens hält der
    // Manifest-Anker die eigene Inode fest und verhindert deren Wiedervergabe.
    try Data("bar".utf8).write(to: fixture.target, options: .atomic)
    let foreign = try FileSnapshot.readSnapshotOnly(from: fixture.target)
    #expect(foreign.identity != anchor.snapshot.identity)
    #expect(anchor.isValid)
    do {
        _ = try ApplyEngine.undo(pending)
        Issue.record("Ein fremder bytegleicher Ersatz muss als Konflikt schließen")
    } catch ApplyError.undoConflict(let message) {
        #expect(message.contains(fixture.target.lastPathComponent))
    }
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == foreign)
    #expect(try ApplyEngine.loadSession(at: pending.sessionDirectory) == pending)
    #expect(anchor.isValid)
    #expect(try Data(contentsOf: pending.sessionDirectory.appendingPathComponent(entry.backupRelativePath)) == Data("foo".utf8))
}

@Test("Alte identitylose pending-Manifeste schreiben keine unbewiesenen Ersatzstände",
      arguments: ["foo", "bar", "foreign"])
private func pendingIdentityRejectsUnprovenLegacyReplacement(_ targetText: String) throws {
    let fixture = try makePendingIdentityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let actual = try applyWithFailedAppliedManifest(fixture)
    let entry = try #require(actual.entries.first)
    let legacy = ApplySession(timestamp: actual.timestamp, sessionDirectory: actual.sessionDirectory,
        entries: [UndoEntry(originalPath: entry.originalPath,
            backupRelativePath: entry.backupRelativePath, originalSHA256: entry.originalSHA256,
            appliedSnapshot: FileSnapshot(data: Data("bar".utf8), identity: nil), state: .pending)])
    try ApplyEngine.writeManifest(legacy)
    try Data(targetText.utf8).write(to: fixture.target, options: .atomic)
    let before = try FileSnapshot.readSnapshotOnly(from: fixture.target)
    if targetText == "foo" {
        let restored = try ApplyEngine.undo(ApplyEngine.loadSession(at: legacy.sessionDirectory))
        #expect(restored.entries.map(\.state) == [.restored])
    } else {
        do {
            _ = try ApplyEngine.undo(ApplyEngine.loadSession(at: legacy.sessionDirectory))
            Issue.record("Identitätsloses pending muss vor jedem Write schließen")
        } catch ApplyError.undoConflict(let message) {
            #expect(message.contains(fixture.target.lastPathComponent))
        }
        #expect(try ApplyEngine.loadSession(at: legacy.sessionDirectory) == legacy)
    }
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == before)
    #expect(try Data(contentsOf: actual.sessionDirectory.appendingPathComponent(entry.backupRelativePath)) == Data("foo".utf8))
}

@Test("Manifestfehler vor Swap erhält das Ziel und räumt erst nach Rückschritt auf",
      arguments: [false, true], [false, true])
private func pendingIdentityManifestFailureBeforeSwap(afterPersist: Bool, failRollback: Bool) throws {
    let fixture = try makePendingIdentityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let original = try FileSnapshot.readSnapshotOnly(from: fixture.target)
    var anchor: ApplyPendingFile?
    var pendingAttempted = false
    var partial: ApplySession?
    var message = ""
    do {
        _ = try ApplyEngine.apply(plan: fixture.plan, backupRoot: fixture.backups,
            cleanupOlderThan: nil, manifestWriter: { candidate in
                if let pending = candidate.entries.last, pending.state == .pending {
                    pendingAttempted = true
                    anchor = pending.pendingFile
                    #expect(anchor?.isValid == true)
                    #expect(pending.appliedSnapshot == anchor?.snapshot)
                    if afterPersist { try ApplyEngine.writeManifest(candidate) }
                    throw ManifestRollbackFailure.beforeSecondSwap
                }
                if pendingAttempted && failRollback { throw ManifestRollbackFailure.rollbackManifest }
                try ApplyEngine.writeManifest(candidate)
            })
        Issue.record("Der pending-Manifestfehler hätte werfen müssen")
    } catch ApplyError.writeFailed(let session, let text) {
        partial = session
        message = text
    }
    let session = try #require(partial)
    let retained = try #require(anchor)
    #expect(session.entries.isEmpty)
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == original)
    if failRollback {
        #expect(session.retainedPendingFiles.first == retained)
        #expect(session.retainedPendingFiles.count == 2)
        #expect(session.retainedPendingFiles[1].snapshot == retained.snapshot)
        #expect(retained.isValid)
        #expect(message.contains("Manifest"))
        #expect(message.contains(session.sessionDirectory.path))
        #expect(try Data(contentsOf: session.sessionDirectory.appendingPathComponent("files/0.bin")) == Data("foo".utf8))
        let retried = try ApplyEngine.undo(session)
        #expect(retried.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: retained.url.path))
        #expect(try ApplyEngine.loadSession(at: session.sessionDirectory).entries.isEmpty)
    } else {
        #expect(!FileManager.default.fileExists(atPath: retained.url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.backups.path).isEmpty)
    }
}

@Test("Ausgetauschter Anker bleibt bei Cleanup-Fehler erhalten und erlaubt Retry")
private func pendingIdentityCleanupRetainsForeignAnchor() throws {
    let fixture = try makePendingIdentityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let initial = try FileSnapshot.readSnapshotOnly(from: fixture.target)
    let saved = fixture.directory.appendingPathComponent("saved-anchor")
    var ownAnchor: ApplyPendingFile?
    var partial: ApplySession?
    do {
        _ = try ApplyEngine.apply(plan: fixture.plan, backupRoot: fixture.backups,
            cleanupOlderThan: nil, manifestWriter: { candidate in
                if let file = candidate.entries.last?.pendingFile,
                   candidate.entries.last?.state == .pending {
                    ownAnchor = file
                    try ApplyEngine.writeManifest(candidate)
                    try FileManager.default.moveItem(at: file.url, to: saved)
                    try Data("foreign anchor".utf8).write(to: file.url)
                    throw ManifestRollbackFailure.beforeSecondSwap
                }
                try ApplyEngine.writeManifest(candidate)
            })
        Issue.record("Der Fehler hätte werfen müssen")
    } catch ApplyError.writeFailed(let session, let message) {
        partial = session
        #expect(message.contains(session.sessionDirectory.path))
    }
    let anchor = try #require(ownAnchor)
    let session = try #require(partial)
    let foreign = try FileSnapshot.readSnapshotOnly(from: anchor.url)
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == initial)
    #expect(session.retainedPendingFiles.first == anchor)
    #expect(session.retainedPendingFiles.count == 2)
    let reloaded = try ApplyEngine.loadSession(at: session.sessionDirectory)
    #expect(reloaded.entries.isEmpty)
    #expect(reloaded.retainedPendingFiles == session.retainedPendingFiles)
    #expect(throws: ApplyError.self) { try ApplyEngine.undo(reloaded) }
    #expect(try FileSnapshot.readSnapshotOnly(from: anchor.url) == foreign)
    // Fremdstand separat erhalten, danach das noch gebundene eigene Objekt
    // zurückstellen: Derselbe persistierte Cleanup-Auftrag ist wiederholbar.
    let foreignSaved = fixture.directory.appendingPathComponent("foreign-anchor")
    try FileManager.default.moveItem(at: anchor.url, to: foreignSaved)
    try FileManager.default.moveItem(at: saved, to: anchor.url)
    _ = try ApplyEngine.undo(reloaded)
    #expect(!FileManager.default.fileExists(atPath: anchor.url.path))
    #expect(try FileSnapshot.readSnapshotOnly(from: foreignSaved) == foreign)
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == initial)
}

@Test("Die Backuprotation schützt neu belegte Namen eines erledigten Aufräumauftrags")
private func backupRotationPreservesReoccupiedCleanupPaths() throws {
    let fixture = try makePendingIdentityFixture()
    let fm = FileManager.default
    defer { try? fm.removeItem(at: fixture.directory) }
    let targetBefore = try FileSnapshot.readSnapshotOnly(from: fixture.target)
    let preparedURL = fixture.directory.appendingPathComponent(".prepared.tmp")
    let preparedBytes = Data("bar".utf8)
    let pending = try ApplyPendingFile.prepare(preparedBytes, at: preparedURL)
    let work = try #require(pending.cleanupDirectory)
    let sessionDirectory = fixture.backups.appendingPathComponent("session-old")
    let files = sessionDirectory.appendingPathComponent("files")
    try fm.createDirectory(at: files, withIntermediateDirectories: true)
    let backup = files.appendingPathComponent("0.bin")
    try Data(contentsOf: fixture.target).write(to: backup)
    let backupBefore = try FileSnapshot.readSnapshotOnly(from: backup)
    let session = ApplySession(timestamp: Date(), sessionDirectory: sessionDirectory,
                               entries: [], retainedPendingFiles: [pending])
    try ApplyEngine.writeManifest(session)

    // Beide Fremdobjekte entstehen vor der Bereinigung und haben eigene Identitäten.
    let foreignSource = fixture.directory.appendingPathComponent("foreign-source")
    try preparedBytes.write(to: foreignSource)
    let foreignBefore = try FileSnapshot.readSnapshotOnly(from: foreignSource)
    try #require(foreignBefore.identity != pending.snapshot.identity)
    let foreignDirectory = fixture.directory.appendingPathComponent("foreign-work")
    try fm.createDirectory(at: foreignDirectory, withIntermediateDirectories: false,
                           attributes: [.posixPermissions: 0o700])
    let witness = foreignDirectory.appendingPathComponent("witness")
    let witnessBytes = Data("foreign".utf8)
    try witnessBytes.write(to: witness)
    let witnessBefore = try FileSnapshot.readSnapshotOnly(from: witness)

    _ = try ApplyEngine.undo(ApplyEngine.loadSession(at: sessionDirectory))
    try #require(!fm.fileExists(atPath: preparedURL.path))
    try #require(!fm.fileExists(atPath: work.url.path))
    #expect(try ApplyEngine.loadSession(at: sessionDirectory) == session)
    let retention: TimeInterval = 30 * 24 * 60 * 60
    try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-retention - 24 * 60 * 60)],
                         ofItemAtPath: sessionDirectory.path)

    try fm.moveItem(at: foreignSource, to: preparedURL)
    try ApplyEngine.cleanupBackups(maxAge: retention, in: fixture.backups)
    #expect(try FileSnapshot.readSnapshotOnly(from: preparedURL) == foreignBefore)
    #expect(try ApplyEngine.loadSession(at: sessionDirectory) == session)
    #expect(try FileSnapshot.readSnapshotOnly(from: backup) == backupBefore)
    try fm.moveItem(at: preparedURL, to: foreignSource)

    try fm.moveItem(at: foreignDirectory, to: work.url)
    try ApplyEngine.cleanupBackups(maxAge: retention, in: fixture.backups)
    #expect(try FileSnapshot.readSnapshotOnly(from: work.url.appendingPathComponent("witness")) == witnessBefore)
    #expect(try ApplyEngine.loadSession(at: sessionDirectory) == session)
    #expect(try FileSnapshot.readSnapshotOnly(from: backup) == backupBefore)
    try fm.moveItem(at: work.url, to: foreignDirectory)

    // Der nächste reguläre Apply rotiert die alte Session, wenn ihre Pfade wieder frei sind.
    let nextTarget = fixture.directory.appendingPathComponent("next.txt")
    try Data("foo".utf8).write(to: nextTarget)
    let nextPlan = ApplyEngine.plan(files: [nextTarget], options: fixture.plan.options)
    let next = try ApplyEngine.apply(plan: nextPlan, backupRoot: fixture.backups)
    #expect(!fm.fileExists(atPath: sessionDirectory.path))
    #expect(try Data(contentsOf: nextTarget) == Data("bar".utf8))
    #expect(try ApplyEngine.loadSession(at: next.sessionDirectory) == next)
    #expect(try FileSnapshot.readSnapshotOnly(from: foreignSource) == foreignBefore)
    #expect(try FileSnapshot.readSnapshotOnly(from: witness) == witnessBefore)
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == targetBefore)
}

@Test("Altersbereinigung wartet auf den Wiederherstellungsanspruch",
      arguments: [false, true])
private func backupRotationSkipsClaimedSession(hasManifest: Bool) throws {
    let fixture = try makePendingIdentityFixture()
    let fm = FileManager.default
    defer { try? fm.removeItem(at: fixture.directory) }
    let session = try ApplyEngine.apply(plan: fixture.plan, backupRoot: fixture.backups, cleanupOlderThan: nil)
    let directory = session.sessionDirectory
    let manifest = directory.appendingPathComponent("manifest.json")
    let backup = directory.appendingPathComponent(try #require(session.entries.first).backupRelativePath)
    let originalManifest = try Data(contentsOf: manifest)
    let originalBackup = try FileSnapshot.readSnapshotOnly(from: backup)
    if !hasManifest { try fm.removeItem(at: manifest) }
    let retention: TimeInterval = 30 * 24 * 60 * 60
    try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-retention - 24 * 60 * 60)],
                         ofItemAtPath: directory.path)

    let root = try ApplyPersistenceBarriers.resolvingRootAliases(fixture.backups)
    let claim = try ApplyRecoveryDirectoryClaim(root: root, sessionName: directory.lastPathComponent)
    try ApplyEngine.cleanupBackups(maxAge: retention, in: fixture.backups)
    try claim.validateBinding()
    #expect(try FileSnapshot.readSnapshotOnly(from: backup) == originalBackup)
    if hasManifest { #expect(try Data(contentsOf: manifest) == originalManifest) }
    try claim.finish()

    try ApplyEngine.cleanupBackups(maxAge: retention, in: fixture.backups)
    #expect(!fm.fileExists(atPath: directory.path))
    #expect(try Data(contentsOf: fixture.target) == Data("bar".utf8))
}

@Test("Altersbereinigung bewahrt ungewöhnliche Manifeste und läuft weiter", arguments: ["link", "large"])
private func backupRotationSkipsInvalidManifest(kind: String) throws {
    let fixture = try makePendingIdentityFixture()
    let fm = FileManager.default
    defer { try? fm.removeItem(at: fixture.directory) }
    let session = try ApplyEngine.apply(plan: fixture.plan, backupRoot: fixture.backups, cleanupOlderThan: nil)
    let directory = session.sessionDirectory
    let manifest = directory.appendingPathComponent("manifest.json")
    let backup = directory.appendingPathComponent(try #require(session.entries.first).backupRelativePath)
    let before = try FileSnapshot.readSnapshotOnly(from: backup)
    let foreign = fixture.directory.appendingPathComponent("manifest-copy")
    if kind == "link" {
        try fm.moveItem(at: manifest, to: foreign)
        try fm.createSymbolicLink(at: manifest, withDestinationURL: foreign)
    } else {
        let handle = try FileHandle(forWritingTo: manifest)
        try handle.truncate(atOffset: UInt64(ApplyRecoverySessionReader.maximumManifestBytes) + 1)
        try handle.close()
    }
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
                         ofItemAtPath: directory.path)
    try ApplyEngine.cleanupBackups(maxAge: 86_400, in: fixture.backups)
    #expect(try FileSnapshot.readSnapshotOnly(from: backup) == before)
    if kind == "link" { #expect(try fm.destinationOfSymbolicLink(atPath: manifest.path) == foreign.path) }
}

@Test("Sichere bisherige Applied-Manifeste bleiben ohne Anker rückgängig")
private func pendingIdentityKeepsExistingAppliedManifestCompatible() throws {
    let fixture = try makePendingIdentityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let actual = try ApplyEngine.apply(plan: fixture.plan, backupRoot: fixture.backups,
                                      cleanupOlderThan: nil)
    let entry = try #require(actual.entries.first)
    // Vorhandenes Schema 2 hatte noch keine der beiden optionalen
    // Cleanup-Ergänzungen. Nicht nur den neuen Initializer dafür verwenden.
    let encoder = JSONEncoder()
    var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(actual)) as? [String: Any])
    json.removeValue(forKey: "retainedPendingFiles")
    var entries = try #require(json["entries"] as? [[String: Any]])
    entries[0].removeValue(forKey: "pendingFile")
    json["entries"] = entries
    try JSONSerialization.data(withJSONObject: json).write(
        to: actual.sessionDirectory.appendingPathComponent("manifest.json"), options: .atomic)
    let old = try ApplyEngine.loadSession(at: actual.sessionDirectory)
    #expect(old.entries[0].pendingFile == nil)
    #expect(old.entries[0].appliedSnapshot == entry.appliedSnapshot)
    _ = try ApplyEngine.undo(old)
    #expect(try Data(contentsOf: fixture.target) == Data("foo".utf8))
}

@Test("Apply-Cleanup löscht keine fremd ersetzte bytegleiche Nachbardatei")
private func pendingIdentityCleanupPreservesForeignPreparedFile() throws {
    let fixture = try makePendingIdentityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let original = try FileSnapshot.readSnapshotOnly(from: fixture.target)
    var foreignURL: URL?
    var foreignSnapshot: FileSnapshot?
    var partial: ApplySession?
    do {
        _ = try ApplyEngine.apply(plan: fixture.plan, backupRoot: fixture.backups,
            cleanupOlderThan: nil, manifestWriter: { candidate in
                if candidate.entries.last?.state == .pending {
                    let temporary = try #require(FileManager.default.contentsOfDirectory(
                        at: fixture.directory, includingPropertiesForKeys: nil).first {
                            $0.lastPathComponent.contains(".fastra-apply-")
                        })
                    try Data("bar".utf8).write(to: temporary, options: .atomic)
                    foreignURL = temporary
                    foreignSnapshot = try FileSnapshot.readSnapshotOnly(from: temporary)
                }
                try ApplyEngine.writeManifest(candidate)
            })
        Issue.record("Die ausgetauschte Nachbardatei hätte Apply abbrechen müssen")
    } catch ApplyError.writeFailed(let session, let message) {
        partial = session
        #expect(message.contains(session.sessionDirectory.path))
    }
    let foreign = try #require(foreignURL)
    let snapshot = try #require(foreignSnapshot)
    let session = try #require(partial)
    #expect(session.entries.isEmpty)
    #expect(session.retainedPendingFiles.map { $0.url.resolvingSymlinksInPath() }
        .contains(foreign.resolvingSymlinksInPath()))
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == original)
    #expect(try FileSnapshot.readSnapshotOnly(from: foreign) == snapshot)
    #expect(try Data(contentsOf: foreign) == Data("bar".utf8))
    #expect(try ApplyEngine.loadSession(at: session.sessionDirectory) == session)
    #expect(try Data(contentsOf: session.sessionDirectory.appendingPathComponent("files/0.bin")) == Data("foo".utf8))
}

@Test("Eigenes pending nach Standard-Replace bleibt einschließlich Undo-Manifest-Retry rückgängig",
      arguments: [false, true])
private func pendingIdentityOwnReplacementRecovers(failUndoManifest: Bool) throws {
    let fixture = try makePendingIdentityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let pending = try applyWithFailedAppliedManifest(fixture)
    let anchor = try #require(pending.entries.first?.pendingFile)
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == anchor.snapshot)
    var attempts = 0
    var retry: ApplySession?
    do {
        let restored = try ApplyEngine.undo(pending, manifestWriter: { candidate in
            attempts += 1
            if failUndoManifest && candidate.entries.first?.state == .restored {
                throw ManifestRollbackFailure.rollbackManifest
            }
            try ApplyEngine.writeManifest(candidate)
        })
        #expect(!failUndoManifest)
        #expect(restored.entries.map(\.state) == [.restored])
    } catch ApplyError.undoFailed(let partial, _) {
        #expect(failUndoManifest)
        retry = partial
    }
    #expect(attempts == 2)
    #expect(try Data(contentsOf: fixture.target) == Data("foo".utf8))
    if !failUndoManifest {
        #expect(!FileManager.default.fileExists(atPath: anchor.url.path))
    } else {
        #expect(FileManager.default.fileExists(atPath: anchor.url.path))
        #expect(try FileSnapshot.readSnapshotOnly(from: anchor.url) == anchor.snapshot)
    }
    if let retry {
        let before = try FileSnapshot.readSnapshotOnly(from: fixture.target)
        let complete = try ApplyEngine.undo(retry)
        #expect(complete.entries.map(\.state) == [.restored])
        #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == before)
        #expect(!FileManager.default.fileExists(atPath: anchor.url.path))
    }
}

@Test("pending-Manifestfehler beim zweiten Ziel verliert weder A noch dessen Undo")
private func pendingIdentitySecondPendingManifestFailureRetainsAppliedPrefix() throws {
    let fixture = try makePendingIdentityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let first = fixture.directory.appendingPathComponent("first.txt")
    try Data("foo first".utf8).write(to: first)
    let originalSecond = try FileSnapshot.readSnapshotOnly(from: fixture.target)
    let plan = ApplyEngine.plan(files: [first, fixture.target], options: fixture.plan.options)
    var rejected = false
    var partial: ApplySession?
    do {
        _ = try ApplyEngine.apply(plan: plan, backupRoot: fixture.backups,
            cleanupOlderThan: nil, manifestWriter: { candidate in
                if candidate.entries.count == 2 {
                    #expect(try Data(contentsOf: first) == Data("bar first".utf8))
                    rejected = true
                    try ApplyEngine.writeManifest(candidate)
                    throw ManifestRollbackFailure.beforeSecondSwap
                }
                if rejected { throw ManifestRollbackFailure.rollbackManifest }
                try ApplyEngine.writeManifest(candidate)
            })
        Issue.record("Der zweite pending-Manifestfehler hätte werfen müssen")
    } catch ApplyError.writeFailed(let session, let message) {
        partial = session
        #expect(message.contains(session.sessionDirectory.path))
    }
    let session = try #require(partial)
    #expect(session.entries.map(\.originalPath) == [first.resolvingSymlinksInPath().path])
    #expect(session.entries.map(\.state) == [.applied])
    #expect(session.retainedPendingFiles.count == 2)
    #expect(session.retainedPendingFiles[0].isValid)
    #expect(session.retainedPendingFiles[1].snapshot == session.retainedPendingFiles[0].snapshot)
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == originalSecond)
    #expect(try ApplyEngine.loadSession(at: session.sessionDirectory).entries.map(\.state) == [.applied, .pending])
    _ = try ApplyEngine.undo(session)
    #expect(try Data(contentsOf: first) == Data("foo first".utf8))
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == originalSecond)
    #expect(!FileManager.default.fileExists(atPath: session.retainedPendingFiles[0].url.path))
}


@Test("Erfolgreicher Pre-Swap-Rückschritt persistiert jeden noch vorhandenen Cleanup-Namen")
private func pendingIdentitySuccessfulRollbackPersistsOutstandingTemporary() throws {
    let fixture = try makePendingIdentityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let initial = try FileSnapshot.readSnapshotOnly(from: fixture.target)
    var pendingWasWritten = false
    var rollback: ApplySession?
    var pathsAtSuccessfulRollback: [URL] = []
    var cleanupCompletionWasWritten = false
    do {
        _ = try ApplyEngine.apply(plan: fixture.plan, backupRoot: fixture.backups,
            cleanupOlderThan: nil, manifestWriter: { candidate in
                try ApplyEngine.writeManifest(candidate)
                if candidate.entries.last?.state == .pending {
                    pendingWasWritten = true
                    throw ManifestRollbackFailure.beforeSecondSwap
                }
                if pendingWasWritten && !candidate.retainedPendingFiles.isEmpty {
                    rollback = try ApplyEngine.loadSession(at: candidate.sessionDirectory)
                    #expect(rollback == candidate)
                    #expect(candidate.entries.isEmpty)
                    #expect(candidate.retainedPendingFiles.count == 2)
                    for file in candidate.retainedPendingFiles {
                        #expect(FileManager.default.fileExists(atPath: file.url.path))
                        #expect(file.cleanupDirectory != nil)
                        #expect(file.cleanupClaimURL?.deletingLastPathComponent()
                                == file.cleanupDirectory?.url)
                        #expect(try FileSnapshot.readSnapshotOnly(from: file.url) == file.snapshot)
                        pathsAtSuccessfulRollback.append(file.url)
                    }
                } else if pendingWasWritten {
                    cleanupCompletionWasWritten = true
                    #expect(rollback != nil)
                    #expect(try ApplyEngine.loadSession(at: candidate.sessionDirectory) == candidate)
                    for path in pathsAtSuccessfulRollback {
                        #expect(!FileManager.default.fileExists(atPath: path.path))
                    }
                }
            })
        Issue.record("Der pending-Fehler hätte Apply abbrechen müssen")
    } catch ApplyError.writeFailed(let partial, _) {
        #expect(partial.entries.isEmpty)
    }
    #expect(rollback != nil)
    #expect(cleanupCompletionWasWritten)
    #expect(pathsAtSuccessfulRollback.count == 2)
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == initial)
    for path in pathsAtSuccessfulRollback {
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
    let leftovers = try FileManager.default.contentsOfDirectory(at: fixture.directory,
        includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".fastra-pending-work-") }
    #expect(leftovers.isEmpty)
}


@Test("195-Zeichen-Zielname bleibt nach pending-Reload und Pre-Swap-Rückschritt rückgängig",
      arguments: ["postswap", "preswap", "rollback-retry"])
private func pendingIdentityLongTargetNameKeepsCleanupUsable(_ phase: String) throws {
    let directory = testTemporaryDirectory().appendingPathComponent(
        "fastra-pending-long-name-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent(String(repeating: "a", count: 195))
    let backups = directory.appendingPathComponent("backups")
    let original = Data("foo".utf8)
    try original.write(to: target)
    let before = try FileSnapshot.readSnapshotOnly(from: target)
    let plan = ApplyEngine.plan(files: [target], options: SearchOptions(
        find: "foo", replace: "bar", isRegex: false, caseSensitive: true))
    var rejected = false
    var partial: ApplySession?
    var pending: ApplySession?
    do {
        _ = try ApplyEngine.apply(plan: plan, backupRoot: backups, cleanupOlderThan: nil,
            manifestWriter: { candidate in
                if candidate.entries.last?.state == .pending {
                    pending = candidate
                    let temp = try #require(candidate.retainedPendingFiles.last)
                    #expect(temp.url.lastPathComponent.utf8.count == 250)
                    #expect(temp.cleanupClaimURL?.lastPathComponent == "prepared.claim")
                    #expect(candidate.entries.last?.pendingFile?.cleanupClaimURL?.lastPathComponent == "anchor.claim")
                    try ApplyEngine.writeManifest(candidate)
                    if phase != "postswap" {
                        rejected = true
                        throw ManifestRollbackFailure.beforeSecondSwap
                    }
                } else if candidate.entries.last?.state == .applied {
                    throw ManifestRollbackFailure.rollbackManifest
                } else if rejected && phase == "rollback-retry" {
                    throw ManifestRollbackFailure.rollbackManifest
                } else {
                    try ApplyEngine.writeManifest(candidate)
                }
            })
        Issue.record("Der ausgewählte Manifestfehler hätte Apply abbrechen müssen")
    } catch ApplyError.writeFailed(let session, _) { partial = session }
    let returned = try #require(partial)
    let persistedPending = try #require(pending)
    if phase == "postswap" {
        let recovered = try ApplyEngine.loadSession(at: returned.sessionDirectory)
        #expect(recovered.entries.map(\.state) == [.pending])
        #expect(try Data(contentsOf: target) == Data("bar".utf8))
        #expect(try Data(contentsOf: recovered.sessionDirectory.appendingPathComponent("files/0.bin")) == original)
        _ = try ApplyEngine.undo(recovered)
    } else if phase == "rollback-retry" {
        #expect(returned.entries.isEmpty)
        #expect(try ApplyEngine.loadSession(at: returned.sessionDirectory).entries.map(\.state) == [.pending])
        _ = try ApplyEngine.undo(returned)
        #expect(try FileSnapshot.readSnapshotOnly(from: target) == before)
    } else {
        #expect(returned.entries.isEmpty)
        #expect(try FileSnapshot.readSnapshotOnly(from: target) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
    }
    #expect(try Data(contentsOf: target) == original)
    for file in persistedPending.retainedPendingFiles + persistedPending.entries.compactMap(\.pendingFile) {
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(!FileManager.default.fileExists(atPath: file.cleanupClaimURL!.path))
        #expect(!FileManager.default.fileExists(atPath: file.cleanupDirectory!.url.path))
    }
}


private enum ManifestRollbackCompletion: String, CaseIterable, Sendable {
    case success, failBeforeWrite, failAfterWrite
}

@Test("Bereinigter Rückschritt bleibt nach Abschluss oder Manifestfehler sicher rückgängig",
      arguments: ManifestRollbackCompletion.allCases, ManifestRollbackSessionSource.allCases)
private func pendingIdentityRollbackCleanupCompletion(
    completion: ManifestRollbackCompletion,
    sessionSource: ManifestRollbackSessionSource
) throws {
    let fixture = try makePendingIdentityFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let first = fixture.directory.appendingPathComponent("first.txt")
    let firstOriginal = Data("foo first".utf8)
    try firstOriginal.write(to: first)
    let secondOriginal = try FileSnapshot.readSnapshotOnly(from: fixture.target)
    let plan = ApplyEngine.plan(files: [first, fixture.target], options: fixture.plan.options)
    let transaction = ApplyTransaction(inputs: try plan.changedFiles.map {
        .init(url: $0.url, snapshot: try #require($0.originalSnapshot), matches: $0.matches)
    }, options: plan.options)
    let swapFailure = NSError(domain: "ManifestRollbackTest", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "second swap rejected"])
    let manifestFailure = NSError(domain: "ManifestRollbackTest", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "cleanup completion write rejected"])
    var secondRejected = false
    var rollback: ApplySession?
    var cleaned: ApplySession?
    var partial: ApplySession?
    var message = ""
    var completionAttempts = 0
    do {
        _ = try transaction.execute(backupRoot: fixture.backups, cleanupOlderThan: nil,
            beforeAtomicReplace: { url in
                if url == fixture.target {
                    secondRejected = true
                    throw swapFailure
                }
            }, manifestWriter: { candidate in
                if secondRejected && candidate.retainedPendingFiles.count == 2 {
                    // Dieser Stand muss vor jedem Cleanup wiederauffindbar sein.
                    try ApplyEngine.writeManifest(candidate)
                    rollback = try ApplyEngine.loadSession(at: candidate.sessionDirectory)
                    #expect(rollback == candidate)
                    for file in candidate.retainedPendingFiles {
                        #expect(try FileSnapshot.readSnapshotOnly(from: file.url) == file.snapshot)
                        #expect(file.cleanupDirectory != nil)
                    }
                } else if secondRejected {
                    completionAttempts += 1
                    cleaned = candidate
                    let retained = try #require(rollback).retainedPendingFiles
                    #expect(candidate.retainedPendingFiles.isEmpty)
                    #expect(candidate.entries.map(\.originalPath) == [first.path])
                    #expect(candidate.entries.map(\.state) == [.applied])
                    #expect(candidate.entries.first?.pendingFile?.isValid == true)
                    for file in retained {
                        #expect(!FileManager.default.fileExists(atPath: file.url.path))
                        #expect(!FileManager.default.fileExists(atPath: try #require(file.cleanupClaimURL).path))
                        #expect(!FileManager.default.fileExists(atPath: try #require(file.cleanupDirectory).url.path))
                    }
                    if completion == .failBeforeWrite { throw manifestFailure }
                    try ApplyEngine.writeManifest(candidate)
                    if completion == .failAfterWrite { throw manifestFailure }
                } else {
                    try ApplyEngine.writeManifest(candidate)
                }
            })
        Issue.record("Der Fehler vor dem zweiten Swap hätte Apply abbrechen müssen")
    } catch ApplyError.writeFailed(let session, let detail) {
        partial = session
        message = detail
    }
    let returned = try #require(partial)
    let persisted = try ApplyEngine.loadSession(at: returned.sessionDirectory)
    let completed = try #require(cleaned)
    let retained = try #require(rollback)
    #expect(completionAttempts == 1)
    #expect(message.contains(swapFailure.localizedDescription))
    #expect(returned.entries.map(\.originalPath) == [first.path])
    #expect(returned.entries.map(\.state) == [.applied])
    #expect(returned.entries.first?.pendingFile?.isValid == true)
    if completion == .success {
        #expect(returned == completed)
        #expect(persisted == returned)
        #expect(returned.retainedPendingFiles.isEmpty)
    } else {
        // Auch ein Writer, der erst nach seinem Write wirft, hat dem
        // Aufrufer keinen erfolgreichen Abschluss bestätigt.
        #expect(returned == retained)
        #expect(message.contains(L10n.format("Manifest schreiben: %@", manifestFailure.localizedDescription)))
        #expect(message.contains(manifestFailure.localizedDescription))
        #expect(message.contains(returned.sessionDirectory.path))
        #expect(persisted == (completion == .failBeforeWrite ? retained : completed))
    }
    #expect(try Data(contentsOf: first) == Data("bar first".utf8))
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == secondOriginal)
    let backups = ["files/0.bin", "files/1.bin"].map {
        retained.sessionDirectory.appendingPathComponent($0)
    }
    let backupSnapshots = try backups.map { try FileSnapshot.readSnapshotOnly(from: $0) }
    #expect(try backups.map { try Data(contentsOf: $0) } == [firstOriginal, Data("foo".utf8)])
    // Ein fremder, nie angewendeter B-Stand darf A-Restore nicht blockieren
    // und bleibt sowohl aus RAM-Partial als auch nach Reload unangetastet.
    try Data("foreign second".utf8).write(to: fixture.target, options: .atomic)
    let foreignSecond = try FileSnapshot.readSnapshotOnly(from: fixture.target)
    let undoSession = sessionSource == .returnedPartial ? returned : persisted
    let restored = try ApplyEngine.undo(undoSession)
    #expect(restored.entries.map(\.state) == [.restored])
    #expect(try ApplyEngine.loadSession(at: restored.sessionDirectory) == restored)
    #expect(try Data(contentsOf: first) == firstOriginal)
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == foreignSecond)
    #expect(try backups.map { try FileSnapshot.readSnapshotOnly(from: $0) } == backupSnapshots)
    for file in retained.retainedPendingFiles + retained.entries.compactMap(\.pendingFile) {
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(!FileManager.default.fileExists(atPath: try #require(file.cleanupClaimURL).path))
        #expect(!FileManager.default.fileExists(atPath: try #require(file.cleanupDirectory).url.path))
    }
}

@Test("Prepare erhält bei belegtem Fremdnamen Ursache und echten Arbeitsordner ohne Cleanupvollmacht")
private func prepareExistingNameReportsUnboundWork() throws {
    let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let foreign = directory.appendingPathComponent("existing.tmp")
    try Data("foreign".utf8).write(to: foreign)
    let original = try FileSnapshot.readSnapshotOnly(from: foreign)
    do {
        _ = try ApplyPendingFile.prepare(Data("replacement".utf8), at: foreign)
        Issue.record("Ein belegter Dateiname darf nicht überschrieben werden")
    } catch let failure as ApplyPendingFile.PreparationFailure {
        #expect((failure.cause as? POSIXError)?.code == .EEXIST)
        #expect(failure.cleanupCause == nil && failure.pendingFile == nil)
        #expect(failure.remainingURLs.count == 1)
        let work = try #require(failure.remainingURLs.first)
        #expect(work.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path)
        #expect(work.lastPathComponent.hasPrefix(".fastra-pending-work-"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
        #expect(failure.localizedDescription.contains(work.path))
        #expect(!failure.localizedDescription.contains("prepared.claim"))
    }
    #expect(try FileSnapshot.readSnapshotOnly(from: foreign) == original)
}

private func recoveryExpectations(_ session: ApplySession) throws
    -> (manifest: FileSnapshot, backups: [String: FileSnapshot]) {
    let manifest = try FileSnapshot.readSnapshotOnly(from:
        session.sessionDirectory.appendingPathComponent("manifest.json"))
    var backups: [String: FileSnapshot] = [:]
    for entry in session.entries where entry.state != .restored {
        backups[entry.backupRelativePath] = try FileSnapshot.readSnapshotOnly(from:
            session.sessionDirectory.appendingPathComponent(entry.backupRelativePath))
    }
    return (manifest, backups)
}

@Test("Bestätigtes Undo weist bytegleiche Fremdobjekte und verschobene Sitzungen ab",
      arguments: ["manifest", "backup", "session"], [false, true])
private func recoveryUndoRejectsChangedBinding(kind: String, duringUndo: Bool) throws {
    let fixture = try makePendingIdentityFixture()
    let fm = FileManager.default
    defer { try? fm.removeItem(at: fixture.directory) }
    let session = try ApplyEngine.apply(plan: fixture.plan, backupRoot: fixture.backups, cleanupOlderThan: nil)
    let expected = try recoveryExpectations(session)
    let beforeTarget = try FileSnapshot.readSnapshotOnly(from: fixture.target)
    let manifest = session.sessionDirectory.appendingPathComponent("manifest.json")
    let backup = session.sessionDirectory.appendingPathComponent(try #require(session.entries.first).backupRelativePath)
    let beforeBackup = try FileSnapshot.readSnapshotOnly(from: backup)
    let root = try ApplyPersistenceBarriers.resolvingRootAliases(fixture.backups)
    let claim = try ApplyRecoveryDirectoryClaim(root: root, sessionName: session.sessionDirectory.lastPathComponent)
    defer { try? claim.finish() }
    let changed = kind == "session" ? session.sessionDirectory : (kind == "manifest" ? manifest : backup)
    let displaced = fixture.directory.appendingPathComponent("displaced")
    var changedSnapshot: FileSnapshot?
    var didChange = false
    func changeBinding() throws {
        didChange = true
        if kind == "session" {
            try fm.moveItem(at: changed, to: displaced)
            try fm.copyItem(at: displaced, to: changed)
        } else {
            let bytes = try Data(contentsOf: changed)
            try fm.moveItem(at: changed, to: displaced)
            try bytes.write(to: changed)
            changedSnapshot = try FileSnapshot.readSnapshotOnly(from: changed)
            #expect(changedSnapshot?.identity != (kind == "manifest" ? expected.manifest.identity : beforeBackup.identity))
        }
    }
    if !duringUndo { try changeBinding() }
    #expect(throws: (any Error).self) {
        try ApplyEngine.undoRecovery(session, holding: claim,
            expectedManifest: expected.manifest, expectedBackups: expected.backups,
            beforeAtomicReplace: { _ in if duringUndo { try changeBinding() } })
    }
    #expect(didChange)
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == beforeTarget)
    if let changedSnapshot {
        #expect(try FileSnapshot.readSnapshotOnly(from: changed) == changedSnapshot)
    }
    if kind == "session" {
        #expect(try FileSnapshot.readSnapshotOnly(from: displaced.appendingPathComponent("manifest.json")) == expected.manifest)
        #expect(try FileSnapshot.readSnapshotOnly(from: displaced.appendingPathComponent("files/0.bin")) == beforeBackup)
    } else {
        #expect(try FileSnapshot.readSnapshotOnly(from: kind == "backup" ? displaced : backup) == beforeBackup)
        #expect(try FileSnapshot.readSnapshotOnly(from: kind == "manifest" ? displaced : manifest) == expected.manifest)
    }
}

@Test("Bestätigtes Undo sichert Teilfortschritt und setzt BOM-/CRLF-Bytes nach neuer Freigabe fort")
private func recoveryUndoPersistsPartialAndResumes() throws {
    let fixture = try makePendingIdentityFixture()
    let fm = FileManager.default
    defer { try? fm.removeItem(at: fixture.directory) }
    let second = fixture.directory.appendingPathComponent("second.txt")
    let originals = [Data([0xEF, 0xBB, 0xBF]) + Data("foo one\r\nfoo\r\n".utf8),
                     Data("foo two\r\n".utf8)]
    try originals[0].write(to: fixture.target)
    try originals[1].write(to: second)
    let plan = ApplyEngine.plan(files: [fixture.target, second], options: fixture.plan.options)
    let session = try ApplyEngine.apply(plan: plan, backupRoot: fixture.backups, cleanupOlderThan: nil)
    let expected = try recoveryExpectations(session)
    let appliedSecond = try FileSnapshot.readSnapshotOnly(from: second)
    let root = try ApplyPersistenceBarriers.resolvingRootAliases(fixture.backups)
    let claim = try ApplyRecoveryDirectoryClaim(root: root, sessionName: session.sessionDirectory.lastPathComponent)
    defer { try? claim.finish() }
    var partial: ApplySession?
    do {
        _ = try ApplyEngine.undoRecovery(session, holding: claim,
            expectedManifest: expected.manifest, expectedBackups: expected.backups,
            beforeAtomicReplace: { url in
                if url == second { throw ManifestRollbackFailure.beforeSecondSwap }
            })
        Issue.record("Der zweite Tausch hätte abbrechen müssen")
    } catch ApplyError.undoFailed(let returned, _) { partial = returned }
    let persisted = try ApplyEngine.loadSession(at: session.sessionDirectory)
    #expect(persisted == partial)
    #expect(persisted.entries.map(\.state) == [.restored, .applied])
    #expect(try Data(contentsOf: fixture.target) == originals[0])
    #expect(try FileSnapshot.readSnapshotOnly(from: second) == appliedSecond)
    let firstBackup = session.sessionDirectory.appendingPathComponent(session.entries[0].backupRelativePath)
    #expect(try FileSnapshot.readSnapshotOnly(from: firstBackup) == expected.backups[session.entries[0].backupRelativePath])
    // Erledigte Einträge brauchen auch beim bestätigten Wiederanlauf kein Backup.
    try fm.removeItem(at: firstBackup)
    let refreshed = try recoveryExpectations(persisted)
    #expect(throws: (any Error).self) {
        try ApplyEngine.undoRecovery(persisted, holding: claim,
            expectedManifest: expected.manifest, expectedBackups: refreshed.backups)
    }
    let completed = try ApplyEngine.undoRecovery(persisted, holding: claim,
        expectedManifest: refreshed.manifest, expectedBackups: refreshed.backups)
    #expect(completed.entries.map(\.state) == [.restored, .restored])
    #expect(try ApplyEngine.loadSession(at: session.sessionDirectory) == completed)
    #expect(try Data(contentsOf: fixture.target) == originals[0])
    #expect(try Data(contentsOf: second) == originals[1])
    let secondBackup = session.entries[1].backupRelativePath
    #expect(try FileSnapshot.readSnapshotOnly(from: session.sessionDirectory.appendingPathComponent(secondBackup))
        == expected.backups[secondBackup])
}

@Test("Bestätigtes Cleanup-only prüft nach Claim erneut und bleibt wiederholbar",
      arguments: [false, true])
private func recoveryUndoCleanupOnlyRepeats(replaceManifestAfterClaim: Bool) throws {
    let fixture = try makePendingIdentityFixture()
    let fm = FileManager.default
    defer { try? fm.removeItem(at: fixture.directory) }
    let targetBefore = try FileSnapshot.readSnapshotOnly(from: fixture.target)
    let savedAnchor = fixture.directory.appendingPathComponent("saved-anchor")
    let savedForeign = fixture.directory.appendingPathComponent("foreign-anchor")
    var anchor: ApplyPendingFile?
    var failed: ApplySession?
    // Ein echter fehlgeschlagener Apply lässt ausschließlich seine eigenen
    // Aufräumaufträge zurück. Die fremde Belegung verhindert deren Cleanup.
    do {
        _ = try ApplyEngine.apply(plan: fixture.plan, backupRoot: fixture.backups,
            cleanupOlderThan: nil, manifestWriter: { candidate in
                if let file = candidate.entries.last?.pendingFile,
                   candidate.entries.last?.state == .pending {
                    anchor = file
                    try ApplyEngine.writeManifest(candidate)
                    try fm.moveItem(at: file.url, to: savedAnchor)
                    try Data("foreign anchor".utf8).write(to: file.url)
                    throw ManifestRollbackFailure.beforeSecondSwap
                }
                try ApplyEngine.writeManifest(candidate)
            })
        Issue.record("Der Apply hätte abbrechen müssen")
    } catch ApplyError.writeFailed(let partial, _) { failed = partial }
    let session = try ApplyEngine.loadSession(at: try #require(failed).sessionDirectory)
    #expect(session.isCleanupOnly)
    let retained = try #require(anchor)
    let foreign = try FileSnapshot.readSnapshotOnly(from: retained.url)
    try fm.moveItem(at: retained.url, to: savedForeign)
    try fm.moveItem(at: savedAnchor, to: retained.url)
    let backup = session.sessionDirectory.appendingPathComponent("files/0.bin")
    let backupBefore = try FileSnapshot.readSnapshotOnly(from: backup)
    let root = try ApplyPersistenceBarriers.resolvingRootAliases(fixture.backups)
    let claim = try ApplyRecoveryDirectoryClaim(root: root, sessionName: session.sessionDirectory.lastPathComponent)
    defer { try? claim.finish() }
    let expected = try recoveryExpectations(session)
    #expect(expected.backups.isEmpty)
    let manifest = session.sessionDirectory.appendingPathComponent("manifest.json")
    var changedManifest: FileSnapshot?
    var cleanupClaim: URL?
    if replaceManifestAfterClaim {
        #expect(throws: ApplyError.self) {
            try ApplyEngine.undoRecovery(session, holding: claim,
                expectedManifest: expected.manifest, expectedBackups: expected.backups,
                afterCleanupClaim: { url in
                    cleanupClaim = url
                    try Data(contentsOf: manifest).write(to: manifest, options: .atomic)
                    changedManifest = try FileSnapshot.readSnapshotOnly(from: manifest)
                })
        }
        #expect(try FileSnapshot.readSnapshotOnly(from: try #require(cleanupClaim)) == retained.snapshot)
        #expect(try FileSnapshot.readSnapshotOnly(from: manifest) == changedManifest)
    }
    let refreshed = try recoveryExpectations(session)
    let completed = try ApplyEngine.undoRecovery(session, holding: claim,
        expectedManifest: refreshed.manifest, expectedBackups: refreshed.backups)
    #expect(completed == session)
    for file in session.retainedPendingFiles {
        #expect(!fm.fileExists(atPath: file.url.path))
        #expect(!fm.fileExists(atPath: try #require(file.cleanupClaimURL).path))
        #expect(!fm.fileExists(atPath: try #require(file.cleanupDirectory).url.path))
    }
    let repeated = try recoveryExpectations(completed)
    #expect(try ApplyEngine.undoRecovery(completed, holding: claim,
        expectedManifest: repeated.manifest, expectedBackups: repeated.backups) == completed)
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == targetBefore)
    #expect(try FileSnapshot.readSnapshotOnly(from: backup) == backupBefore)
    #expect(try FileSnapshot.readSnapshotOnly(from: savedForeign) == foreign)
    #expect(try ApplyEngine.loadSession(at: session.sessionDirectory) == completed)
}
