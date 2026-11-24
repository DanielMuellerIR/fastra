import Darwin
import Foundation
import Testing
@testable import Fastra

private struct PersistenceFixture {
    let directory: URL
    let target: URL
    let root: URL
    let original = Data("foo original".utf8)

    init() throws {
        directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        target = directory.appendingPathComponent("target.txt")
        root = directory.appendingPathComponent("new/parents/undo")
        try original.write(to: target)
    }

    func transaction() throws -> ApplyTransaction {
        let options = SearchOptions(find: "foo", replace: "bar", isRegex: false)
        let plan = ApplyEngine.plan(files: [target], options: options)
        let input = try #require(plan.changedFiles.first)
        return ApplyTransaction(inputs: [ApplyTransaction.Input(url: target,
            snapshot: try #require(input.originalSnapshot), matches: input.matches)], options: options)
    }

    func session() throws -> URL {
        try #require(FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("session-") })
    }
}

@Test("Apply synchronisiert eine neue Verzeichniskette und bewahrt gültige Originalbackups")
func applyPersistenceNewDirectoryChain() throws {
    let fixture = try PersistenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.transaction().execute(backupRoot: fixture.root, cleanupOlderThan: nil)
    #expect(try Data(contentsOf: fixture.target) == Data("bar original".utf8))
    #expect(try Data(contentsOf: session.sessionDirectory.appendingPathComponent("files/0.bin"))
        == fixture.original)
    #expect(try ApplyEngine.loadSession(at: session.sessionDirectory) == session)
    _ = try ApplyEngine.undo(session)
    #expect(try Data(contentsOf: fixture.target) == fixture.original)
}

@Test("Apply lehnt fehlerhafte Backupablagen vor jedem Zieltausch ab und erhält die Ablage",
      arguments: ["bytes", "size", "symlink", "directory", "files-exchange", "session-exchange"])
func applyPersistenceRejectsAlteredBackup(kind: String) throws {
    let fixture = try PersistenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let original = try FileSnapshot.readSnapshotOnly(from: fixture.target)
    var sessionDirectory: URL?
    var displacedDirectory: URL?
    var swapAttempted = false
    do {
        _ = try fixture.transaction().execute(backupRoot: fixture.root, cleanupOlderThan: nil,
            beforePreflight: {
                let session = try fixture.session()
                sessionDirectory = session
                let backup = session.appendingPathComponent("files/0.bin")
                switch kind {
                case "bytes": try Data("BAD original".utf8).write(to: backup)
                case "size": try Data("BAD".utf8).write(to: backup)
                case "symlink", "directory":
                    try FileManager.default.removeItem(at: backup)
                    if kind == "symlink" {
                        try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: fixture.target)
                    } else {
                        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
                    }
                default:
                    let exchanged = kind == "files-exchange" ? session.appendingPathComponent("files") : session
                    let moved = exchanged.appendingPathExtension("displaced")
                    try FileManager.default.moveItem(at: exchanged, to: moved)
                    displacedDirectory = moved
                    try FileManager.default.createDirectory(at: exchanged, withIntermediateDirectories: true)
                    try Data("foreign".utf8).write(to: exchanged.appendingPathComponent("foreign.txt"))
                }
            }, beforeAtomicReplace: { _ in swapAttempted = true })
        Issue.record("Die veränderte Ablage hätte Apply abbrechen müssen")
    } catch ApplyError.backupFailed(let message) {
        #expect(message.contains(try #require(sessionDirectory).path))
    }
    #expect(!swapAttempted)
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == original)
    #expect(try Data(contentsOf: fixture.target) == fixture.original)
    let session = try #require(sessionDirectory)
    #expect(FileManager.default.fileExists(atPath: session.path))
    let retained = displacedDirectory.flatMap { kind == "session-exchange" ? $0 : nil } ?? session
    #expect(try Data(contentsOf: retained.appendingPathComponent("staged/0.bin")) == Data("bar original".utf8))
    #expect(!FileManager.default.fileExists(atPath: session.appendingPathComponent("manifest.json").path))
    if let displacedDirectory {
        #expect(FileManager.default.fileExists(atPath: displacedDirectory.path))
        let exchanged = kind == "files-exchange" ? session.appendingPathComponent("files") : session
        #expect(try Data(contentsOf: exchanged.appendingPathComponent("foreign.txt")) == Data("foreign".utf8))
    }
}

@Test("Apply-Abbruch erhält eine ausgetauschte Sicherungsablage")
func applyPersistenceCancellationPreservesForeignSession() throws {
    let fixture = try PersistenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let original = try FileSnapshot.readSnapshotOnly(from: fixture.target)
    let displaced = fixture.directory.appendingPathComponent("displaced")
    var sessionDirectory: URL?
    var foreignIdentity: FileIdentity?
    var swapAttempted = false
    do {
        _ = try fixture.transaction().execute(backupRoot: fixture.root, cleanupOlderThan: nil,
            shouldCancel: { FileManager.default.fileExists(atPath: displaced.path) },
            beforePreflight: {
                let session = try fixture.session()
                sessionDirectory = session
                try FileManager.default.moveItem(at: session, to: displaced)
                try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
                try Data("foreign".utf8).write(to: session.appendingPathComponent("foreign.txt"))
                foreignIdentity = FileIdentity(url: session)
            }, beforeAtomicReplace: { _ in swapAttempted = true })
        Issue.record("Der bestätigte Abbruch hätte Apply beenden müssen")
    } catch ApplyError.backupFailed(let message) {
        #expect(message.contains(try #require(sessionDirectory).path))
    } catch ApplyError.cancelled {
        Issue.record("Die ausgetauschte Ablage hätte als Sicherungsfehler sichtbar bleiben müssen")
    }
    #expect(!swapAttempted)
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == original)
    #expect(try Data(contentsOf: fixture.target) == fixture.original)
    let session = try #require(sessionDirectory)
    let expectedIdentity = try #require(foreignIdentity)
    #expect(FileIdentity(url: session) == expectedIdentity)
    #expect(try Data(contentsOf: session.appendingPathComponent("foreign.txt")) == Data("foreign".utf8))
    #expect(try Data(contentsOf: displaced.appendingPathComponent("files/0.bin")) == fixture.original)
    #expect(try Data(contentsOf: displaced.appendingPathComponent("staged/0.bin")) == Data("bar original".utf8))
}

@Test("Ein bytegleiches Backup vor dem ersten Open bleibt eine gültige Undo-Basis")
func applyPersistenceAcceptsEqualBackupReplacementBeforeOpen() throws {
    let fixture = try PersistenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var before: FileSnapshot?
    var after: FileSnapshot?
    let session = try fixture.transaction().execute(backupRoot: fixture.root, cleanupOlderThan: nil,
        beforePreflight: {
            let backup = try fixture.session().appendingPathComponent("files/0.bin")
            before = try FileSnapshot.readSnapshotOnly(from: backup)
            try fixture.original.write(to: backup, options: .atomic)
            after = try FileSnapshot.readSnapshotOnly(from: backup)
        })
    #expect(try #require(before).identity != #require(after).identity)
    #expect(try #require(before).hasSameContent(as: #require(after)))
    _ = try ApplyEngine.undo(session)
    #expect(try Data(contentsOf: fixture.target) == fixture.original)
}

private enum InitialManifestFailure: Error { case injected }

@Test("Ein Fehler des leeren Initialmanifests erhält Backups und Staging ohne Undoauftrag",
      arguments: [false, true])
func applyPersistenceInitialManifestFailure(afterWrite: Bool) throws {
    let fixture = try PersistenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let original = try FileSnapshot.readSnapshotOnly(from: fixture.target)
    var candidates: [ApplySession] = []
    do {
        _ = try fixture.transaction().execute(backupRoot: fixture.root, cleanupOlderThan: nil,
            manifestWriter: { candidate in
                candidates.append(candidate)
                if afterWrite { try ApplyEngine.writeManifest(candidate) }
                throw InitialManifestFailure.injected
            })
        Issue.record("Der Initialwriter hätte Apply abbrechen müssen")
    } catch ApplyError.backupFailed(let message) {
        #expect(message.contains(try fixture.session().path))
    }
    #expect(candidates.count == 1)
    let candidate = try #require(candidates.first)
    #expect(candidate.entries.isEmpty)
    #expect(candidate.retainedPendingFiles.isEmpty)
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == original)
    #expect(try Data(contentsOf: candidate.sessionDirectory.appendingPathComponent("files/0.bin")) == fixture.original)
    #expect(try Data(contentsOf: candidate.sessionDirectory.appendingPathComponent("staged/0.bin")) == Data("bar original".utf8))
    #expect(FileManager.default.fileExists(atPath: candidate.sessionDirectory.appendingPathComponent("manifest.json").path)
        == afterWrite)
    if afterWrite { #expect(try ApplyEngine.loadSession(at: candidate.sessionDirectory) == candidate) }
}

@Test("Ein bewusst konfigurierter Rootalias funktioniert mit fehlender Unterkette")
func applyPersistenceRootAlias() throws {
    let fixture = try PersistenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let alias = fixture.directory.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.directory)
    let session = try fixture.transaction().execute(backupRoot: alias.appendingPathComponent("new/parents/undo"),
                                                   cleanupOlderThan: nil)
    #expect(try #require(FileIdentity(url: session.sessionDirectory.deletingLastPathComponent()))
        == #require(FileIdentity(url: fixture.root)))
    _ = try ApplyEngine.undo(session)
    #expect(try Data(contentsOf: fixture.target) == fixture.original)
}

@Test("Der Defaultmanifestwriter folgt keinem ausgetauschten Session-Symlink")
func applyPersistenceManifestRejectsSessionSymlink() throws {
    let fixture = try PersistenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.transaction().execute(backupRoot: fixture.root, cleanupOlderThan: nil)
    let displaced = session.sessionDirectory.appendingPathExtension("displaced")
    try FileManager.default.moveItem(at: session.sessionDirectory, to: displaced)
    let foreign = fixture.directory.appendingPathComponent("foreign")
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
    let foreignManifest = foreign.appendingPathComponent("manifest.json")
    try Data("foreign manifest".utf8).write(to: foreignManifest)
    let original = try FileSnapshot.readSnapshotOnly(from: foreignManifest)
    try FileManager.default.createSymbolicLink(at: session.sessionDirectory, withDestinationURL: foreign)
    #expect(throws: ApplyPersistenceBarriers.Failure.self) { try ApplyEngine.writeManifest(session) }
    #expect(try FileSnapshot.readSnapshotOnly(from: foreignManifest) == original)
    #expect(try Data(contentsOf: displaced.appendingPathComponent("files/0.bin")) == fixture.original)
}

@Test("Ein später erfolgreicher Rückschritt löscht keine zuvor unbekannte Manifestablage")
func applyPersistenceRetainsArtifactsAfterRecoveredManifestFailure() throws {
    let fixture = try PersistenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let original = try FileSnapshot.readSnapshotOnly(from: fixture.target)
    var injected = false
    var returned: ApplySession?
    var candidates: [[UndoEntry.State]] = []
    do {
        _ = try fixture.transaction().execute(backupRoot: fixture.root, cleanupOlderThan: nil,
            manifestWriter: { candidate in
                candidates.append(candidate.entries.map(\.state))
                if !injected, candidate.entries.last?.state == .pending {
                    injected = true
                    let displaced = candidate.sessionDirectory.appendingPathExtension("displaced")
                    try FileManager.default.moveItem(at: candidate.sessionDirectory, to: displaced)
                    try FileManager.default.createSymbolicLink(at: candidate.sessionDirectory,
                                                              withDestinationURL: displaced)
                    let failure: Error
                    do {
                        try ApplyEngine.writeManifest(candidate)
                        Issue.record("Der Defaultwriter hätte den Session-Symlink ablehnen müssen")
                        throw InitialManifestFailure.injected
                    } catch { failure = error }
                    try FileManager.default.removeItem(at: candidate.sessionDirectory)
                    try FileManager.default.moveItem(at: displaced, to: candidate.sessionDirectory)
                    throw failure
                }
                try ApplyEngine.writeManifest(candidate)
            })
        Issue.record("Der Writerfehler hätte Apply abbrechen müssen")
    } catch ApplyError.writeFailed(let session, _) { returned = session }
    #expect(injected)
    #expect(candidates == [[], [.pending], [], []])
    let session = try #require(returned)
    #expect(session.entries.isEmpty)
    #expect(session.retainedPendingFiles.isEmpty)
    #expect(try ApplyEngine.loadSession(at: session.sessionDirectory) == session)
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == original)
    #expect(try Data(contentsOf: session.sessionDirectory.appendingPathComponent("files/0.bin")) == fixture.original)
    #expect(try Data(contentsOf: session.sessionDirectory.appendingPathComponent("staged/0.bin")) == Data("bar original".utf8))
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)) == ["target.txt", "new"])
}

private enum ApplyExchangeTiming: CaseIterable, Sendable {
    case initialManifest, pendingManifest, beforeSwap, appliedManifest, finalProgress
}

private struct ApplyExchangeCase: Sendable {
    let timing: ApplyExchangeTiming
    let completed: Int
    let workflow: Bool

    static var all: [Self] {
        ApplyExchangeTiming.allCases.flatMap { timing in
            let counts: [Int]
            switch timing {
            case .initialManifest: counts = [0]
            case .pendingManifest, .beforeSwap: counts = [0, 1]
            case .appliedManifest: counts = [1, 2]
            case .finalProgress: counts = [2]
            }
            return counts.flatMap { completed in
                [false, true].map { Self(timing: timing, completed: completed, workflow: $0) }
            }
        }
    }
}

@Test("Apply bindet Sicherungsordner über Manifest, Tausch und Abschluss in beiden Aufrufwegen",
      arguments: ["session", "files", "staged"], ApplyExchangeCase.all)
private func applyPersistenceDirectoryExchangeDuringCommit(kind: String, checkpoint: ApplyExchangeCase) throws {
    let fixture = try PersistenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let second = fixture.directory.appendingPathComponent("second.txt")
    let originals = [fixture.original, Data("foo second".utf8)]
    try originals[1].write(to: second)
    let targets = [fixture.target, second]
    let options = SearchOptions(find: "foo", replace: "bar", isRegex: false)
    let plan = ApplyEngine.plan(files: targets, options: options)
    let transaction = ApplyTransaction(inputs: try plan.changedFiles.map {
        ApplyTransaction.Input(url: $0.url, snapshot: try #require($0.originalSnapshot), matches: $0.matches)
    }, options: options)
    var step = TextWorkflowStep(kind: .replace)
    step.find = "foo"; step.replacement = "bar"
    let workflow = try TextWorkflowFilePlan.build(TextWorkflow(name: "Replace", steps: [step]),
        inputs: targets.map { .init(url: $0) })
    var exchanged: URL?
    var displaced: URL?
    var originalSession: URL?
    var originalManifest: FileSnapshot?
    var foreign: FileSnapshot?
    func exchange() throws {
        guard exchanged == nil else { return }
        let session = try fixture.session()
        originalSession = session
        originalManifest = try FileSnapshot.readSnapshotOnly(from: session.appendingPathComponent("manifest.json"))
        let source = kind == "session" ? session : session.appendingPathComponent(kind)
        let moved = source.appendingPathExtension("displaced")
        try FileManager.default.moveItem(at: source, to: moved)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let foreignURL = source.appendingPathComponent("foreign.txt")
        try Data("foreign bytes".utf8).write(to: foreignURL)
        foreign = try FileSnapshot.readSnapshotOnly(from: foreignURL)
        exchanged = source; displaced = moved
    }
    let usesManifestHook = checkpoint.timing == .initialManifest || checkpoint.timing == .pendingManifest
        || checkpoint.timing == .appliedManifest
    let writer: ((ApplySession) throws -> Void)? = usesManifestHook ? { candidate in
        try ApplyEngine.writeManifest(candidate)
        let selected: Bool
        switch checkpoint.timing {
        case .initialManifest: selected = candidate.entries.isEmpty
        case .pendingManifest:
            selected = candidate.entries.last?.state == .pending && candidate.entries.count == checkpoint.completed + 1
        case .appliedManifest:
            selected = candidate.entries.last?.state == .applied && candidate.entries.count == checkpoint.completed
        default: selected = false
        }
        if selected { try exchange() }
    } : nil
    let beforeSwap: (URL) throws -> Void = { target in
        if checkpoint.timing == .beforeSwap, target.canonicalFileURL == targets[checkpoint.completed].canonicalFileURL { try exchange() }
    }
    var progressError: Error?
    let progress: (ApplyTransaction.Progress) -> Void = { value in
        if checkpoint.timing == .finalProgress, value.phase == .applied, value.completedFiles == 2 {
            do { try exchange() } catch { progressError = error }
        }
    }
    var partial: ApplySession?
    var message = ""
    var unavailable = false
    do {
        if checkpoint.workflow {
            _ = try ApplyEngine.execute(workflowPlan: workflow, backupRoot: fixture.root, cleanupOlderThan: nil,
                progress: progress, beforeAtomicReplace: beforeSwap, manifestWriter: writer)
        } else {
            _ = try transaction.execute(backupRoot: fixture.root, cleanupOlderThan: nil,
                progress: progress, beforeAtomicReplace: beforeSwap, manifestWriter: writer)
        }
        Issue.record("Apply hätte den Austausch erkennen müssen")
    } catch ApplyError.recoveryUnavailable(let session, let detail) {
        partial = session; message = detail; unavailable = true
    } catch ApplyError.writeFailed(let session, let detail) {
        partial = session; message = detail
    } catch ApplyError.backupFailed(let detail) { message = detail }
    #expect(progressError == nil)
    #expect(!message.isEmpty)
    let lostCleanupSession = kind == "session" && checkpoint.completed == 0
        && (checkpoint.timing == .pendingManifest || checkpoint.timing == .beforeSwap)
    #expect(unavailable == ((checkpoint.completed > 0 && kind != "staged") || lostCleanupSession))
    if lostCleanupSession {
        let cleanup = try #require(partial)
        #expect(cleanup.isCleanupOnly)
        let retained = try #require(cleanup.retainedPendingFiles.first { $0.isValid })
        #expect(retained.cleanupDirectory != nil)
        #expect(try FileSnapshot.readSnapshotOnly(from: retained.url) == retained.snapshot)
        for index in targets.indices {
            #expect(try FileSnapshot.readSnapshotOnly(from: targets[index])
                == #require(plan.changedFiles[index].originalSnapshot))
        }
    }
    if let partial {
        for entry in partial.entries { #expect(message.contains(entry.originalPath)) }
    }
    let source = try #require(exchanged)
    let moved = try #require(displaced)
    let session = try #require(originalSession)
    #expect(message.contains(source.path))
    #expect(message.contains(moved.path))
    #expect(try FileSnapshot.readSnapshotOnly(from: source.appendingPathComponent("foreign.txt")) == #require(foreign))
    #expect(try FileManager.default.contentsOfDirectory(atPath: source.path) == ["foreign.txt"])
    let actualSession = kind == "session" ? moved : session
    #expect(try FileSnapshot.readSnapshotOnly(from: actualSession.appendingPathComponent("manifest.json")) == #require(originalManifest))
    for index in targets.indices {
        let expected = index < checkpoint.completed
            ? Data(String(decoding: originals[index], as: UTF8.self).replacingOccurrences(of: "foo", with: "bar").utf8)
            : originals[index]
        #expect(try Data(contentsOf: targets[index]) == expected)
    }
    let originalFiles = kind == "session" ? moved.appendingPathComponent("files")
        : kind == "files" ? moved : session.appendingPathComponent("files")
    for index in originals.indices {
        let backup = originalFiles.appendingPathComponent("\(index).bin")
        #expect(try Data(contentsOf: backup) == originals[index])
        #expect(message.contains(backup.path))
    }
    // Ursache beheben und dieselbe Partial-Session zurücknehmen: kein neuer
    // Auftrag und kein Formatwechsel sind für die erhaltenen Originale nötig.
    let foreignDirectory = source.appendingPathExtension("foreign-preserved")
    try FileManager.default.moveItem(at: source, to: foreignDirectory)
    try FileManager.default.moveItem(at: moved, to: source)
    if let partial { _ = try ApplyEngine.undo(partial) }
    for (target, original) in zip(targets, originals) { #expect(try Data(contentsOf: target) == original) }
    #expect(try FileSnapshot.readSnapshotOnly(from: foreignDirectory.appendingPathComponent("foreign.txt")) == #require(foreign))
}

@Test("Ein vor Bindung belegter fremder Sessionname wird weder benutzt noch aufgeräumt")
func applyPersistenceNeverOwnsPreexistingSession() throws {
    let fixture = try PersistenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = fixture.directory.appendingPathComponent("foreign-session")
    let binding = try ApplyPersistenceBarriers(beforeCreating: session)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
    let foreign = session.appendingPathComponent("foreign.txt")
    try Data("foreign bytes".utf8).write(to: foreign)
    let snapshot = try FileSnapshot.readSnapshotOnly(from: foreign)
    #expect(throws: (any Error).self) { try binding.createAndBindDirectories() }
    try binding.finish()
    #expect(try FileSnapshot.readSnapshotOnly(from: foreign) == snapshot)
    #expect(try FileManager.default.contentsOfDirectory(atPath: session.path) == ["foreign.txt"])
}

@Test("Cleanup erhält ausgetauschte einzelne Stagingdateien auch bei gleichen Bytes",
      arguments: [false, true])
func applyPersistencePreservesForeignStagingFile(equalBytes: Bool) throws {
    let fixture = try PersistenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var foreign: FileSnapshot?
    var staged: URL?
    var partial: ApplySession?
    var injectionError: Error?
    do {
        _ = try fixture.transaction().execute(backupRoot: fixture.root, cleanupOlderThan: nil,
            progress: { value in
                guard value.phase == .applied else { return }
                do {
                    let url = try fixture.session().appendingPathComponent("staged/0.bin")
                    staged = url
                    try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("original"))
                    try Data((equalBytes ? "bar original" : "foreign bytes").utf8).write(to: url)
                    foreign = try FileSnapshot.readSnapshotOnly(from: url)
                } catch { injectionError = error }
            })
        Issue.record("Das nicht eigene Stagingobjekt muss erhalten und gemeldet werden")
    } catch ApplyError.writeFailed(let session, let message) {
        partial = session
        #expect(message.contains(session.sessionDirectory.path))
    }
    #expect(injectionError == nil)
    let url = try #require(staged)
    #expect(try FileSnapshot.readSnapshotOnly(from: url) == #require(foreign))
    let session = try #require(partial)
    #expect(session.entries.map(\.state) == [.applied])
    #expect(try Data(contentsOf: fixture.target) == Data("bar original".utf8))
    _ = try ApplyEngine.undo(session)
    #expect(try Data(contentsOf: fixture.target) == fixture.original)
    #expect(try FileSnapshot.readSnapshotOnly(from: url) == #require(foreign))
}

@Test("Späte Backupersetzung erhält fremde Bytes und akzeptiert unveränderte Originalbytes",
      arguments: [0, 1], [false, true])
func applyPersistenceLateBackupReplacement(completed: Int, equalBytes: Bool) throws {
    let fixture = try PersistenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let second = fixture.directory.appendingPathComponent("second.txt")
    let targets = [fixture.target, second]
    let originals = [fixture.original, Data("foo second".utf8)]
    try originals[1].write(to: second)
    let options = SearchOptions(find: "foo", replace: "bar", isRegex: false)
    let plan = ApplyEngine.plan(files: targets, options: options)
    let transaction = ApplyTransaction(inputs: try plan.changedFiles.map {
        ApplyTransaction.Input(url: $0.url, snapshot: try #require($0.originalSnapshot), matches: $0.matches)
    }, options: options)
    var replacement: FileSnapshot?
    var backup: URL?
    var partial: ApplySession?
    var succeeded = false
    do {
        partial = try transaction.execute(backupRoot: fixture.root, cleanupOlderThan: nil,
            beforeAtomicReplace: { target in
                guard target.canonicalFileURL == targets[completed].canonicalFileURL else { return }
                let url = try fixture.session().appendingPathComponent("files/\(completed).bin")
                backup = url
                try (equalBytes ? originals[completed] : Data("foreign backup".utf8)).write(to: url, options: .atomic)
                replacement = try FileSnapshot.readSnapshotOnly(from: url)
            })
        succeeded = true
    } catch ApplyError.writeFailed(let session, _) { partial = session }
    #expect(succeeded == equalBytes)
    let url = try #require(backup)
    #expect(try FileSnapshot.readSnapshotOnly(from: url) == #require(replacement))
    for index in targets.indices {
        let changed = equalBytes || index < completed
        let expected = changed
            ? Data(String(decoding: originals[index], as: UTF8.self).replacingOccurrences(of: "foo", with: "bar").utf8)
            : originals[index]
        #expect(try Data(contentsOf: targets[index]) == expected)
    }
    let session = try #require(partial)
    if session.hasRecoveryWork { _ = try ApplyEngine.undo(session) }
    for (target, original) in zip(targets, originals) { #expect(try Data(contentsOf: target) == original) }
    #expect(try FileSnapshot.readSnapshotOnly(from: url) == #require(replacement))
}

// Beide Workspace-Tests nutzen die prozessweite exklusive Plattenreservierung.
// In der schnellen Phase würde sie auch unabhängige Schreibtests sperren.
@Test("Die normalen Rücknahmeknöpfe bleiben nur bei erreichbarer Undo-Basis angeboten",
      arguments: [false, true])
@MainActor
func serialRunnerIntegrationApplyPersistenceCallerOffersOnlyReachableRecovery(unavailable: Bool) async throws {
    let fixture = try PersistenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let originalSnapshot = try FileSnapshot.readSnapshotOnly(from: fixture.target)
    let applied = try fixture.transaction().execute(backupRoot: fixture.root, cleanupOlderThan: nil)
    let domain = "fastra-test-apply-recovery-offer-" + UUID().uuidString
    let defaults = testSuiteDefaults(named: domain)
    defer { defaults.removePersistentDomain(forName: domain) }
    let workspace = Workspace(defaults: defaults)
    workspace.fileTreeMutationWorkspaceProvider = { [] }
    let tab = EditorTab(title: "target.txt", path: fixture.target.path, url: fixture.target,
        content: String(decoding: fixture.original, as: UTF8.self), diskSnapshot: originalSnapshot)
    workspace.tabs = [tab]
    workspace.tabs[0].recordSavedContentBaseline()
    workspace.activeTabID = tab.id
    // Der Plattenabschluss braucht kein Fenster. Diese Identität wird nur
    // von den hier nicht aufgerufenen Speicherbefehlen als Fenster geprüft.
    let snapshot = TextWorkflowDocumentSnapshot(tabID: tab.id, documentID: tab.documentID,
        url: tab.url, revision: tab.contentRevision, source: tab.content,
        selection: NSRange(location: 0, length: 0), windowID: ObjectIdentifier(workspace))
    let workflow = TextWorkflowSession(snapshot: snapshot, workspace: workspace, store: TextWorkflowStore(defaults: defaults))
    defer { workflow.close() }
    workflow.scope = .folder
    var moved: URL?
    if unavailable {
        let displaced = applied.sessionDirectory.appendingPathExtension("displaced")
        try FileManager.default.moveItem(at: applied.sessionDirectory, to: displaced)
        moved = displaced
    }
    let detail = moved.map { "Originals: " + $0.path } ?? "Recoverable partial apply"
    let failure: ApplyError = unavailable
        ? .recoveryUnavailable(partial: applied, message: detail)
        : .writeFailed(partial: applied, message: detail)
    workspace.lastApplySession = applied
    let mutation = try workspace.beginTextWorkflowDiskMutation(urls: [fixture.target])
    workflow.finishDiskOperation(.failure(failure), undo: nil, in: workspace, mutation: mutation, heldEditors: [])
    #expect((workflow.diskAppliedSession != nil) == !unavailable)
    #expect((workspace.lastApplySession != nil) == !unavailable)
    #expect(workflow.error == TextWorkflowFailure.message(failure))
    #expect(await waitUntil { workspace.tabs[0].content == "bar original" && !workspace.tabs[0].isLoading })
    #expect(!workspace.tabs[0].hasUnsavedChanges)
    workflow.restoreDisk()
    if unavailable {
        #expect(!workflow.isBusy)
        #expect(!(await workspace.undoLastFolderApply()))
        #expect(try Data(contentsOf: fixture.target) == Data("bar original".utf8))
        let directory = try #require(moved)
        #expect(try Data(contentsOf: directory.appendingPathComponent("files/0.bin")) == fixture.original)
        #expect(try ApplyEngine.loadSession(at: directory) == applied)
    } else {
        #expect(await waitUntil { !workflow.isBusy && workflow.diskAppliedSession == nil })
        #expect(workspace.lastApplySession == nil)
        #expect(try Data(contentsOf: fixture.target) == fixture.original)
    }
}

@Test("Die letzte Undo-Zusage bestätigt die Sicherungsbindung nach dem tatsächlichen Cleanup",
      arguments: ["session", "files", "unchanged"], [false, true])
func applyPersistenceRecoveryAfterCleanup(kind: String, workflow: Bool) throws {
    let fixture = try PersistenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let second = fixture.directory.appendingPathComponent("second.txt")
    let targets = [fixture.target, second]
    let originals = [fixture.original, Data("foo second".utf8)]
    try originals[1].write(to: second)
    let options = SearchOptions(find: "foo", replace: "bar", isRegex: false)
    let plan = ApplyEngine.plan(files: targets, options: options)
    let transaction = ApplyTransaction(inputs: try plan.changedFiles.map {
        ApplyTransaction.Input(url: $0.url, snapshot: try #require($0.originalSnapshot), matches: $0.matches)
    }, options: options)
    var step = TextWorkflowStep(kind: .replace)
    step.find = "foo"; step.replacement = "bar"
    let workflowPlan = try TextWorkflowFilePlan.build(TextWorkflow(name: "Replace", steps: [step]),
        inputs: targets.map { .init(url: $0) })
    let cause = "second swap deliberately stopped"
    let beforeSwap: (URL) throws -> Void = { url in
        if url.canonicalFileURL == second.canonicalFileURL {
            #expect(try Data(contentsOf: targets[0]) == Data("bar original".utf8))
            throw NSError(domain: "ApplyCleanupBoundaryTest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: cause])
        }
    }
    var sessionDirectory: URL?
    var manifestBeforeCleanup: FileSnapshot?
    var exchanged: URL?
    var displaced: URL?
    var foreign: FileSnapshot?
    var claims: [Data] = []
    let afterClaim: (URL) throws -> Void = { claim in
        #expect(claim.lastPathComponent.hasPrefix(".cleanup-"))
        claims.append(try Data(contentsOf: claim))
        guard claims.count == 1 else { return }
        let session = try fixture.session()
        sessionDirectory = session
        let manifest = session.appendingPathComponent("manifest.json")
        manifestBeforeCleanup = try FileSnapshot.readSnapshotOnly(from: manifest)
        let published = try ApplyEngine.loadSession(at: session)
        #expect(published.entries.map(\.state) == [.applied])
        #expect(published.entries.map(\.originalPath) == [targets[0].canonicalFileURL.path]
            || published.entries.map(\.originalPath) == [targets[0].path])
        guard kind != "unchanged" else { return }
        let source = kind == "session" ? session : session.appendingPathComponent("files")
        let moved = source.appendingPathExtension("displaced")
        try FileManager.default.moveItem(at: source, to: moved)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let foreignURL = source.appendingPathComponent("foreign.txt")
        try Data("foreign cleanup neighbour".utf8).write(to: foreignURL)
        foreign = try FileSnapshot.readSnapshotOnly(from: foreignURL)
        exchanged = source; displaced = moved
    }
    var partial: ApplySession?
    var message = ""
    var unavailable = false
    do {
        if workflow {
            _ = try ApplyEngine.execute(workflowPlan: workflowPlan, backupRoot: fixture.root, cleanupOlderThan: nil,
                beforeAtomicReplace: beforeSwap, afterCleanupClaim: afterClaim)
        } else {
            _ = try transaction.execute(backupRoot: fixture.root, cleanupOlderThan: nil,
                beforeAtomicReplace: beforeSwap, afterCleanupClaim: afterClaim)
        }
        Issue.record("Der ursprüngliche zweite Schreibfehler muss sichtbar bleiben")
    } catch ApplyError.recoveryUnavailable(let session, let detail) {
        partial = session; message = detail; unavailable = true
    } catch ApplyError.writeFailed(let session, let detail) { partial = session; message = detail }
    #expect(unavailable == (kind != "unchanged"))
    #expect(message.contains(cause))
    #expect(Set(claims) == [Data("bar original".utf8), Data("bar second".utf8)])
    #expect(claims.count == 2)
    let session = try #require(partial)
    #expect(session.entries.map(\.state) == [.applied])
    #expect(session.retainedPendingFiles.isEmpty)
    #expect(message.contains(try #require(session.entries.first).originalPath))
    #expect(try Data(contentsOf: targets[0]) == Data("bar original".utf8))
    #expect(try Data(contentsOf: targets[1]) == originals[1])
    let originalSession = kind == "session" ? try #require(displaced) : try #require(sessionDirectory)
    let originalFiles = kind == "files" ? try #require(displaced) : originalSession.appendingPathComponent("files")
    #expect(!FileManager.default.fileExists(atPath: originalSession.appendingPathComponent("staged").path))
    #expect(try FileSnapshot.readSnapshotOnly(from: originalSession.appendingPathComponent("manifest.json"))
        == #require(manifestBeforeCleanup))
    #expect(try ApplyEngine.loadSession(at: originalSession) == session)
    for index in originals.indices {
        let backup = originalFiles.appendingPathComponent("\(index).bin")
        #expect(try Data(contentsOf: backup) == originals[index])
        if unavailable { #expect(message.contains(backup.path)) }
    }
    var foreignDirectory: URL?
    if let source = exchanged, let moved = displaced {
        #expect(try FileSnapshot.readSnapshotOnly(from: source.appendingPathComponent("foreign.txt")) == #require(foreign))
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.path) == ["foreign.txt"])
        let retained = source.appendingPathExtension("foreign-preserved")
        try FileManager.default.moveItem(at: source, to: retained)
        try FileManager.default.moveItem(at: moved, to: source)
        foreignDirectory = retained
    }
    _ = try ApplyEngine.undo(session)
    for (target, original) in zip(targets, originals) { #expect(try Data(contentsOf: target) == original) }
    if let foreignDirectory {
        #expect(try FileSnapshot.readSnapshotOnly(from: foreignDirectory.appendingPathComponent("foreign.txt")) == #require(foreign))
    }
}

@Test("Eine reine Aufräumsitzung schreibt nur in ihre ursprüngliche Sessionablage",
      arguments: ["session", "files", "unchanged"], [false, true])
@MainActor
func serialRunnerIntegrationApplyPersistenceCleanupOnlyOriginalSession(kind: String, workflowButton: Bool) async throws {
    let fixture = try PersistenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let initial = try FileSnapshot.readSnapshotOnly(from: fixture.target)
    let cause = "rollback manifest rejected after publication"
    var rejectedPending = false, rejectedRollback = false
    var originalSession: URL?, exchanged: URL?, displaced: URL?
    var foreignManifest: FileSnapshot?, foreignFile: FileSnapshot?
    var failure: ApplyError?
    do {
        _ = try fixture.transaction().execute(backupRoot: fixture.root, cleanupOlderThan: nil,
            manifestWriter: { candidate in
                try ApplyEngine.writeManifest(candidate)
                if candidate.entries.last?.state == .pending, !rejectedPending {
                    rejectedPending = true
                    throw NSError(domain: "CleanupOnlySessionTest", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "pending manifest rejected after publication"])
                }
                if rejectedPending, candidate.isCleanupOnly, !rejectedRollback {
                    rejectedRollback = true; originalSession = candidate.sessionDirectory
                    if kind != "unchanged" {
                        let source = kind == "session" ? candidate.sessionDirectory
                            : candidate.sessionDirectory.appendingPathComponent("files")
                        let moved = source.appendingPathExtension("displaced")
                        try FileManager.default.moveItem(at: source, to: moved)
                        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
                        let manifest = source.appendingPathComponent("manifest.json")
                        let file = source.appendingPathComponent("foreign.txt")
                        try Data("foreign manifest must stay byte-identical".utf8).write(to: manifest)
                        try Data("foreign file must stay byte-identical".utf8).write(to: file)
                        foreignManifest = try FileSnapshot.readSnapshotOnly(from: manifest)
                        foreignFile = try FileSnapshot.readSnapshotOnly(from: file)
                        exchanged = source; displaced = moved
                    }
                    throw NSError(domain: "CleanupOnlySessionTest", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: cause])
                }
            })
        Issue.record("Der ursprüngliche Manifestfehler muss Apply abbrechen")
    } catch let value as ApplyError { failure = value }
    #expect(rejectedPending && rejectedRollback)
    let partial: ApplySession, message: String, unavailable: Bool
    switch try #require(failure) {
    case .recoveryUnavailable(let value, let detail): partial = value; message = detail; unavailable = true
    case .writeFailed(let value, let detail): partial = value; message = detail; unavailable = false
    default: Issue.record("Der belegte Cleanup-Teilstand muss erhalten bleiben"); return
    }
    #expect(unavailable == (kind == "session"))
    #expect(partial.isCleanupOnly && message.contains(cause))
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == initial)
    let retained = try #require(partial.retainedPendingFiles.first { $0.isValid })
    let storedSession = kind == "session" ? try #require(displaced) : try #require(originalSession)
    #expect(try ApplyEngine.loadSession(at: storedSession) == partial)
    let domain = "fastra-test-cleanup-session-binding-" + UUID().uuidString
    let defaults = testSuiteDefaults(named: domain)
    defer { defaults.removePersistentDomain(forName: domain) }
    let workspace = Workspace(defaults: defaults)
    workspace.fileTreeMutationWorkspaceProvider = { [] }
    let tab = EditorTab(title: "target.txt", path: fixture.target.path, url: fixture.target,
        content: String(decoding: fixture.original, as: UTF8.self), diskSnapshot: initial)
    workspace.tabs = [tab]; workspace.tabs[0].recordSavedContentBaseline(); workspace.activeTabID = tab.id
    let snapshot = TextWorkflowDocumentSnapshot(tabID: tab.id, documentID: tab.documentID,
        url: tab.url, revision: tab.contentRevision, source: tab.content,
        selection: NSRange(location: 0, length: 0), windowID: ObjectIdentifier(workspace))
    let workflow = TextWorkflowSession(snapshot: snapshot, workspace: workspace, store: TextWorkflowStore(defaults: defaults))
    defer { workflow.close() }
    workflow.scope = .folder
    let mutation = try workspace.beginTextWorkflowDiskMutation(urls: [fixture.target])
    workflow.finishDiskOperation(.failure(try #require(failure)), undo: nil,
        in: workspace, mutation: mutation, heldEditors: [])
    #expect((workspace.lastApplySession != nil) == (kind != "session"))
    #expect((workflow.diskAppliedSession != nil) == (kind != "session"))
    let unchangedMessage = L10n.format("%@\nDie Zieldateien blieben unverändert.", "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(workflow.error?.contains(unchangedMessage) == true)
    if workflowButton {
        workflow.restoreDisk(); #expect(await waitUntil { !workflow.isBusy })
    } else { #expect(await workspace.undoLastFolderApply() == (kind != "session")) }
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == initial)
    if let source = exchanged {
        // Vor dem Fix überschreibt der echte Aufräum-Entrypoint hier den
        // fremden Manifestnamen. Bytes und Inode werden danach verglichen.
        #expect(try FileSnapshot.readSnapshotOnly(from: source.appendingPathComponent("manifest.json")) == #require(foreignManifest))
        #expect(try FileSnapshot.readSnapshotOnly(from: source.appendingPathComponent("foreign.txt")) == #require(foreignFile))
    }
    if unavailable {
        #expect(retained.isValid)
        #expect(workspace.lastApplySession == nil && workflow.diskAppliedSession == nil)
        let source = try #require(exchanged), moved = try #require(displaced)
        let preserved = source.appendingPathExtension("foreign-preserved")
        try FileManager.default.moveItem(at: source, to: preserved)
        try FileManager.default.moveItem(at: moved, to: source)
        let retry = try workspace.beginTextWorkflowDiskMutation(urls: [fixture.target])
        workflow.finishDiskOperation(.failure(ApplyError.writeFailed(partial: partial, message: "session binding repaired")),
            undo: nil, in: workspace, mutation: retry, heldEditors: [])
        workflow.restoreDisk()
        #expect(await waitUntil { !workflow.isBusy && workflow.diskAppliedSession == nil })
        #expect(try FileSnapshot.readSnapshotOnly(from: preserved.appendingPathComponent("manifest.json")) == #require(foreignManifest))
        #expect(try FileSnapshot.readSnapshotOnly(from: preserved.appendingPathComponent("foreign.txt")) == #require(foreignFile))
    }
    #expect(!retained.isValid)
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.target) == initial)
}
