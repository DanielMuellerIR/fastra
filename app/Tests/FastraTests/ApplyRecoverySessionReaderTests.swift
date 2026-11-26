import Darwin
import Foundation
import Testing
@testable import Fastra

private typealias RecoveryReader = ApplyRecoverySessionReader

private struct RecoveryReaderFixture {
    let directory: URL
    let root: URL
    let targets: [URL]
    let control: URL
    let original = Data([0xEF, 0xBB, 0xBF]) + Data("rot\r\nzweite Zeile\r\n".utf8)

    init(targetNames: [String] = ["first.txt", "second.txt"]) throws {
        let proposed = testTemporaryDirectory().appendingPathComponent("recovery-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: proposed, withIntermediateDirectories: true)
        let resolved = try ApplyPersistenceBarriers.resolvingRootAliases(proposed)
        directory = resolved
        root = resolved.appendingPathComponent("backups")
        targets = targetNames.map { resolved.appendingPathComponent($0) }
        control = resolved.appendingPathComponent("control.txt")
        for target in targets { try original.write(to: target) }
        try Data("unbeteiligt\r\n".utf8).write(to: control)
    }

    func apply(manifestWriter: ((ApplySession) throws -> Void)? = nil) throws -> ApplySession {
        let plan = ApplyEngine.plan(files: targets,
            options: SearchOptions(find: "rot", replace: "blau", isRegex: false))
        return try ApplyEngine.apply(plan: plan, backupRoot: root, cleanupOlderThan: nil,
                                     manifestWriter: manifestWriter)
    }

    func read(_ session: ApplySession, matching expected: RecoveryReader.Observation? = nil,
              beforeFinalValidation: (() throws -> Void)? = nil) throws -> RecoveryReader.Observation {
        try RecoveryReader.read(sessionNamed: session.sessionDirectory.lastPathComponent, in: root,
                                matching: expected, beforeFinalValidation: beforeFinalValidation)
    }

    func artifacts() throws -> [String: FileSnapshot] {
        let paths = try #require(FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: nil)?.allObjects as? [URL])
        return try Dictionary(uniqueKeysWithValues: paths.compactMap { url in
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError(.EIO) }
            guard info.st_mode & S_IFMT == S_IFREG else { return nil }
            return (url.path, try FileSnapshot.readSnapshotOnly(from: url))
        })
    }

    func directoryIdentities() throws -> [String: FileIdentity] {
        let paths = try #require(FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: nil)?.allObjects as? [URL])
        return try Dictionary(uniqueKeysWithValues: ([directory] + paths).compactMap { url in
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError(.EIO) }
            return info.st_mode & S_IFMT == S_IFDIR ? (url.path, FileIdentity(stat: info)) : nil
        })
    }
}

@Test("Der Sitzungsleser bindet echte BOM-/CRLF-Apply-Sicherungen ohne Schreibwirkung")
private func recoveryReaderReadsNormalApply() throws {
    let fixture = try RecoveryReaderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    let before = try fixture.artifacts()
    let directoriesBefore = try fixture.directoryIdentities()
    let sessionIdentity = try #require(FileIdentity(url: session.sessionDirectory))
    let observed = try fixture.read(session)
    #expect(observed.session == session)
    #expect(observed.directory.identity == sessionIdentity)
    #expect(observed.backups.count == 2)
    #expect(observed.manifest.snapshot == before[session.sessionDirectory.appendingPathComponent("manifest.json").path])
    for entry in session.entries {
        let backup = try #require(observed.backups[entry.backupRelativePath])
        #expect(backup.snapshot.sha256 == FileSnapshot.sha256Hex(fixture.original))
        #expect(backup.snapshot.byteCount == fixture.original.count)
        #expect(entry.bom == Data([0xEF, 0xBB, 0xBF]))
    }
    #expect(try fixture.read(session, matching: observed) == observed)
    #expect(try fixture.artifacts() == before)
    #expect(try fixture.directoryIdentities() == directoriesBefore)
    #expect(FileIdentity(url: session.sessionDirectory) == sessionIdentity)
}

@Test("Gültige macOS-Zielnamen mit mehr als MAXNAMLEN UTF-8-Bytes bleiben lesbar")
private func recoveryReaderReadsUnicodeTargetPath() throws {
    let fixture = try RecoveryReaderFixture(targetNames: [String(repeating: "😀", count: 70) + ".txt"])
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    let before = try fixture.artifacts()
    #expect(try #require(session.entries.first).originalPath == fixture.targets[0].path)
    #expect(try fixture.read(session).session == session)
    #expect(try fixture.artifacts() == before)
}

@Test("Historische Schema-2-Modi und fehlende optionale Cleanup-Felder bleiben lesbar")
private func recoveryReaderAcceptsHistoricalSchemaTwo() throws {
    let fixture = try RecoveryReaderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    let manifest = session.sessionDirectory.appendingPathComponent("manifest.json")
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
    json.removeValue(forKey: "retainedPendingFiles")
    var entries = try #require(json["entries"] as? [[String: Any]])
    for index in entries.indices { entries[index].removeValue(forKey: "pendingFile") }
    json["entries"] = entries
    try JSONSerialization.data(withJSONObject: json).write(to: manifest, options: .atomic)
    for directory in [fixture.root, session.sessionDirectory, session.sessionDirectory.appendingPathComponent("files")] {
        try #require(chmod(directory.path, 0o755) == 0)
    }
    for file in [manifest] + session.entries.map({ session.sessionDirectory.appendingPathComponent($0.backupRelativePath) }) {
        try #require(chmod(file.path, 0o644) == 0)
    }
    let before = try fixture.artifacts()
    let observed = try fixture.read(session)
    #expect(observed.session.entries.allSatisfy { $0.pendingFile == nil })
    #expect(observed.directory.mode & 0o777 == 0o755)
    #expect(observed.manifest.mode & 0o777 == 0o644)
    #expect(try fixture.artifacts() == before)
}

private enum RecoveryReaderFixtureError: Error { case retainCleanup, interruptUndo }

private func recoveryReaderPersistedPartialUndo(_ fixture: RecoveryReaderFixture) throws -> ApplySession {
    let session = try fixture.apply()
    let second = try #require(session.entries.last)
    var partial: ApplySession?
    do {
        _ = try ApplyEngine.undo(session, beforeAtomicReplace: { target in
            if target.path == second.originalPath { throw RecoveryReaderFixtureError.interruptUndo }
        })
        Issue.record("Die zweite Rücknahme hätte unterbrochen werden müssen")
    } catch ApplyError.undoFailed(let candidate, _) { partial = candidate }
    let persisted = try ApplyEngine.loadSession(at: session.sessionDirectory)
    try #require(persisted == partial)
    try #require(persisted.entries.map(\.state) == [.restored, .applied])
    return persisted
}

@Test("Persistierter Teilfortschritt benötigt nur noch die offene Sicherung",
      arguments: ["missing-restored", "corrupt-restored", "corrupt-open"])
private func recoveryReaderReadsPersistedPartialUndo(kind: String) throws {
    let fixture = try RecoveryReaderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try recoveryReaderPersistedPartialUndo(fixture)
    let restored = session.entries[0]
    let open = session.entries[1]
    let restoredBackup = session.sessionDirectory.appendingPathComponent(restored.backupRelativePath)
    if kind == "missing-restored" {
        try FileManager.default.removeItem(at: restoredBackup)
    } else {
        try Data("beschädigte erledigte Sicherung".utf8).write(to: restoredBackup)
    }
    if kind == "corrupt-open" {
        try Data("beschädigte offene Sicherung".utf8).write(
            to: session.sessionDirectory.appendingPathComponent(open.backupRelativePath))
    }
    let before = try fixture.artifacts()
    let directoriesBefore = try fixture.directoryIdentities()
    if kind == "corrupt-open" {
        #expect(throws: RecoveryReader.Failure.invalid(.backup(open.backupRelativePath), .backupContent)) {
            try fixture.read(session)
        }
        #expect(try fixture.artifacts() == before)
        #expect(try fixture.directoryIdentities() == directoriesBefore)
        return
    }
    let observed = try fixture.read(session)
    #expect(observed.session == session)
    #expect(Set(observed.backups.keys) == [open.backupRelativePath])
    #expect(try fixture.read(session, matching: observed) == observed)
    #expect(try fixture.artifacts() == before)
    #expect(try fixture.directoryIdentities() == directoriesBefore)
    let finished = try ApplyEngine.undo(observed.session)
    #expect(finished.entries.allSatisfy { $0.state == .restored })
    for target in fixture.targets { #expect(try Data(contentsOf: target) == fixture.original) }
    #expect(try FileSnapshot.readSnapshotOnly(from: fixture.control) == before[fixture.control.path])
}

@Test("Erledigte Einträge behalten die Strukturprüfung ihrer gespeicherten Referenzen",
      arguments: ["backup", "target", "cleanup"])
private func recoveryReaderValidatesRestoredReferences(kind: String) throws {
    let fixture = try RecoveryReaderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try recoveryReaderPersistedPartialUndo(fixture)
    let manifest = session.sessionDirectory.appendingPathComponent("manifest.json")
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
    var entries = try #require(json["entries"] as? [[String: Any]])
    let reason: RecoveryReader.InvalidReason
    switch kind {
    case "backup": entries[0]["backupRelativePath"] = "files/../outside.bin"; reason = .backupReference
    case "target": entries[0]["originalPath"] = "/tmp/../outside.txt"; reason = .targetReference
    default:
        var pending = try #require(entries[0]["pendingFile"] as? [String: Any])
        pending["url"] = fixture.control.absoluteString
        entries[0]["pendingFile"] = pending
        reason = .cleanupReference
    }
    json["entries"] = entries
    try JSONSerialization.data(withJSONObject: json).write(to: manifest, options: .atomic)
    let before = try fixture.artifacts()
    #expect(throws: RecoveryReader.Failure.invalid(.manifest, reason)) { try fixture.read(session) }
    #expect(try fixture.artifacts() == before)
}

@Test("Vollständig restaurierte Sitzungen benötigen keinen Sicherungsordner mehr")
private func recoveryReaderReadsFullyRestoredWithoutBackups() throws {
    let fixture = try RecoveryReaderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let applied = try fixture.apply()
    let session = try ApplyEngine.undo(applied)
    try #require(ApplyEngine.loadSession(at: session.sessionDirectory) == session)
    try FileManager.default.removeItem(at: session.sessionDirectory.appendingPathComponent("files"))
    let before = try fixture.artifacts()
    let observed = try fixture.read(session)
    #expect(observed.session == session)
    #expect(observed.files == nil)
    #expect(observed.backups.isEmpty)
    #expect(try fixture.artifacts() == before)
}

@Test("Ein echtes Cleanup-only-Manifest bleibt ohne erfundenen Undo-Eintrag lesbar")
private func recoveryReaderReadsRealCleanupOnly() throws {
    let fixture = try RecoveryReaderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let saved = fixture.directory.appendingPathComponent("saved-anchor")
    var cleanup: ApplySession?
    do {
        _ = try fixture.apply { candidate in
            if let pending = candidate.entries.last?.pendingFile, candidate.entries.last?.state == .pending {
                try ApplyEngine.writeManifest(candidate)
                try FileManager.default.moveItem(at: pending.url, to: saved)
                try Data("fremder Anker".utf8).write(to: pending.url)
                throw RecoveryReaderFixtureError.retainCleanup
            }
            try ApplyEngine.writeManifest(candidate)
        }
        Issue.record("Der vorbereitete Manifestfehler hätte werfen müssen")
    } catch ApplyError.writeFailed(let partial, _) { cleanup = partial }
    let session = try #require(cleanup)
    try #require(session.isCleanupOnly)
    try #require(session.retainedPendingFiles.count == 2)
    let before = try fixture.artifacts()
    let sessionIdentity = FileIdentity(url: session.sessionDirectory)
    let directoriesBefore = try fixture.directoryIdentities()
    let observed = try fixture.read(session)
    #expect(observed.session == session)
    #expect(observed.session.entries.isEmpty)
    #expect(observed.backups.isEmpty)
    #expect(observed.files == nil)
    #expect(try fixture.artifacts() == before)
    #expect(try fixture.directoryIdentities() == directoriesBefore)
    #expect(FileIdentity(url: session.sessionDirectory) == sessionIdentity)
    #expect(try fixture.read(session, matching: observed) == observed)
}

@Test("Manifesttyp und Manifestgrenze werden vor der Dekodierung geprüft", arguments: ["symlink", "fifo", "directory", "oversize"])
private func recoveryReaderRejectsManifestStorage(kind: String) throws {
    let fixture = try RecoveryReaderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    let manifest = session.sessionDirectory.appendingPathComponent("manifest.json")
    try FileManager.default.removeItem(at: manifest)
    switch kind {
    case "symlink": try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: fixture.control)
    case "fifo": try #require(mkfifo(manifest.path, 0o600) == 0)
    case "directory": try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
    default:
        let descriptor = open(manifest.path, O_CREAT | O_RDWR | O_EXCL, 0o600)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(ftruncate(descriptor, off_t(RecoveryReader.maximumManifestBytes + 1)) == 0)
    }
    let expected: RecoveryReader.Failure = kind == "oversize"
        ? .unsupported(.manifestLimit) : .invalid(.manifest, .fileType)
    #expect(throws: expected) { try fixture.read(session) }
    #expect(try Data(contentsOf: fixture.control) == Data("unbeteiligt\r\n".utf8))
}

@Test("Ausgetauschte Namen werden am Ende des gebundenen Reads erkannt", arguments: ["manifest", "backup", "session", "files"])
private func recoveryReaderRejectsExchangeDuringRead(kind: String) throws {
    let fixture = try RecoveryReaderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    let relative = try #require(session.entries.first?.backupRelativePath)
    let target: URL
    let resource: RecoveryReader.Resource
    switch kind {
    case "manifest": target = session.sessionDirectory.appendingPathComponent("manifest.json"); resource = .manifest
    case "backup": target = session.sessionDirectory.appendingPathComponent(relative); resource = .backup(relative)
    case "files": target = session.sessionDirectory.appendingPathComponent("files"); resource = .files
    default: target = session.sessionDirectory; resource = .session
    }
    #expect(throws: RecoveryReader.Failure.changed(resource)) {
        try fixture.read(session, beforeFinalValidation: {
            if kind == "manifest" || kind == "backup" {
                try Data(contentsOf: target).write(to: target, options: .atomic)
            } else {
                try FileManager.default.moveItem(at: target, to: target.appendingPathExtension("saved"))
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            }
        })
    }
}

@Test("Eine neue Bestätigung erkennt bytegleichen Manifest- oder Sitzungsersatz", arguments: ["manifest", "session"])
private func recoveryReaderRequiresFreshIdentity(kind: String) throws {
    let fixture = try RecoveryReaderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    let observation = try fixture.read(session)
    if kind == "manifest" {
        let manifest = session.sessionDirectory.appendingPathComponent("manifest.json")
        try Data(contentsOf: manifest).write(to: manifest, options: .atomic)
    } else {
        let saved = session.sessionDirectory.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: session.sessionDirectory, to: saved)
        try FileManager.default.copyItem(at: saved, to: session.sessionDirectory)
    }
    #expect(throws: RecoveryReader.Failure.changed(.session)) { try fixture.read(session, matching: observation) }
}

@Test("Eingebettete Sitzungs-, Sicherungs- und Aufräumreferenzen begründen keinen Pfadzugriff",
      arguments: ["session", "backup", "long-session", "target", "cleanup"])
private func recoveryReaderRejectsUnboundReferences(kind: String) throws {
    let fixture = try RecoveryReaderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    let manifest = session.sessionDirectory.appendingPathComponent("manifest.json")
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
    var entries = try #require(json["entries"] as? [[String: Any]])
    let reason: RecoveryReader.InvalidReason
    switch kind {
    case "session":
        json["sessionDirectory"] = fixture.directory.appendingPathComponent(session.sessionDirectory.lastPathComponent).absoluteString
        reason = .sessionReference
    case "long-session":
        json["sessionDirectory"] = "file:///" + String(repeating: "x", count: Int(PATH_MAX))
        reason = .sessionReference
    case "backup": entries[0]["backupRelativePath"] = "files/../../control.txt"; reason = .backupReference
    case "target": entries[0]["originalPath"] = "/tmp/../outside.txt"; reason = .targetReference
    default:
        var pending = try #require(entries[0]["pendingFile"] as? [String: Any])
        pending["url"] = fixture.control.absoluteString
        entries[0]["pendingFile"] = pending
        reason = .cleanupReference
    }
    json["entries"] = entries
    try JSONSerialization.data(withJSONObject: json).write(to: manifest, options: .atomic)
    let before = try fixture.artifacts()
    #expect(throws: RecoveryReader.Failure.invalid(.manifest, reason)) { try fixture.read(session) }
    #expect(try fixture.artifacts() == before)
}

@Test("Fehlende Sicherungen und fremde Schreibrechte werden getrennt erklärt", arguments: ["missing", "writable-session", "writable-manifest", "linked-backup"])
private func recoveryReaderExplainsStorageFailures(kind: String) throws {
    let fixture = try RecoveryReaderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    let relative = try #require(session.entries.first?.backupRelativePath)
    let backup = session.sessionDirectory.appendingPathComponent(relative)
    let expected: RecoveryReader.Failure
    switch kind {
    case "missing": try FileManager.default.removeItem(at: backup); expected = .missing(.backup(relative))
    case "writable-session":
        try #require(chmod(session.sessionDirectory.path, 0o775) == 0)
        expected = .invalid(.session, .writableByOthers)
    case "writable-manifest":
        try #require(chmod(session.sessionDirectory.appendingPathComponent("manifest.json").path, 0o666) == 0)
        expected = .invalid(.manifest, .writableByOthers)
    default:
        try #require(link(backup.path, fixture.directory.appendingPathComponent("linked-backup").path) == 0)
        expected = .invalid(.backup(relative), .hardLink)
    }
    #expect(throws: expected) { try fixture.read(session) }
}

@Test("Nicht unterstützte Sitzungsstände erhalten einen eigenen Grund", arguments: ["schema", "legacy", "basis"])
private func recoveryReaderExplainsUnsupportedState(kind: String) throws {
    let fixture = try RecoveryReaderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    let manifest = session.sessionDirectory.appendingPathComponent("manifest.json")
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
    var entries = try #require(json["entries"] as? [[String: Any]])
    let reason: RecoveryReader.UnsupportedReason
    switch kind {
    case "schema": json["schemaVersion"] = 1; reason = .schema(1)
    case "legacy": entries[0]["state"] = "legacy"; reason = .legacyEntry
    default: entries[0].removeValue(forKey: "appliedSnapshot"); reason = .missingAppliedBasis
    }
    json["entries"] = entries
    try JSONSerialization.data(withJSONObject: json).write(to: manifest, options: .atomic)
    #expect(throws: RecoveryReader.Failure.unsupported(reason)) { try fixture.read(session) }
}

@Test("Sicherungsinhalt, Dateityp und Größe bleiben Teil des Lesevertrags", arguments: ["content", "symlink", "oversize"])
private func recoveryReaderRejectsInvalidBackup(kind: String) throws {
    let fixture = try RecoveryReaderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    let relative = try #require(session.entries.first?.backupRelativePath)
    let backup = session.sessionDirectory.appendingPathComponent(relative)
    let expected: RecoveryReader.Failure
    switch kind {
    case "content":
        try Data("fremde Bytes".utf8).write(to: backup)
        expected = .invalid(.backup(relative), .backupContent)
    case "symlink":
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: fixture.control)
        expected = .invalid(.backup(relative), .fileType)
    default:
        let descriptor = open(backup.path, O_WRONLY)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(ftruncate(descriptor, off_t(FileSnapshot.maximumReadBytes + 1)) == 0)
        expected = .unsupported(.backupLimit)
    }
    #expect(throws: expected) { try fixture.read(session) }
}

@Test("Zusätzliche ACL-Leserechte bleiben zulässig, Änderungsrechte werden abgewiesen", arguments: [false, true])
private func recoveryReaderChecksExtendedACL(writable: Bool) throws {
    let fixture = try RecoveryReaderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let session = try fixture.apply()
    let descriptor = open(session.sessionDirectory.path, O_RDONLY | O_DIRECTORY)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    var access = acl_init(1)
    try #require(access != nil)
    defer { if let access { acl_free(UnsafeMutableRawPointer(access)) } }
    var entry: acl_entry_t?
    try #require(acl_create_entry(&access, &entry) == 0)
    try #require(acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0)
    var principal = UUID().uuid
    try #require(acl_set_qualifier(entry, &principal) == 0)
    var permissions: acl_permset_t?
    try #require(acl_get_permset(entry, &permissions) == 0)
    try #require(acl_add_perm(permissions, writable ? ACL_ADD_FILE : ACL_LIST_DIRECTORY) == 0)
    try #require(acl_set_permset(entry, permissions) == 0)
    try #require(acl_set_fd_np(descriptor, access, ACL_TYPE_EXTENDED) == 0)
    if writable {
        #expect(throws: RecoveryReader.Failure.invalid(.session, .extendedACL)) { try fixture.read(session) }
    } else {
        #expect(try fixture.read(session).session == session)
    }
}

@Test("Ein überlanger Sitzungsname wird vor jedem Dateizugriff abgewiesen")
private func recoveryReaderRejectsOverlongSessionName() throws {
    #expect(throws: RecoveryReader.Failure.invalid(.session, .name)) {
        try RecoveryReader.read(sessionNamed: "session-" + String(repeating: "x", count: Int(MAXNAMLEN)),
                                in: URL(fileURLWithPath: "/unbenutzter-reader-root"))
    }
}

@Test("Viele echte Apply-Sicherungen bleiben mit kleinem Deskriptorbudget lesbar")
private func recoveryReaderSerialRunnerIntegrationBoundedDescriptors() throws {
    let fixture = try RecoveryReaderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let targets = (0..<40).map { fixture.directory.appendingPathComponent("budget-\($0).txt") }
    for target in targets { try fixture.original.write(to: target) }
    let plan = ApplyEngine.plan(files: targets,
        options: SearchOptions(find: "rot", replace: "blau", isRegex: false))
    let session = try ApplyEngine.apply(plan: plan, backupRoot: fixture.root, cleanupOlderThan: nil)
    let before = try fixture.artifacts()
    var original = rlimit()
    try #require(getrlimit(RLIMIT_NOFILE, &original) == 0)
    let highest = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
        .compactMap(Int32.init).max() ?? 2
    var limited = original
    limited.rlim_cur = rlim_t(highest + 12)
    try #require(limited.rlim_cur < original.rlim_cur)
    // Der stabile SerialRunnerIntegration-Marker isoliert diesen vorübergehend
    // prozessweiten Grenzwert vom parallelen Unitlauf.
    try #require(setrlimit(RLIMIT_NOFILE, &limited) == 0)
    defer { if setrlimit(RLIMIT_NOFILE, &original) != 0 { Issue.record("Deskriptorgrenze ließ sich nicht zurückstellen") } }
    let observed = try fixture.read(session)
    #expect(observed.backups.count == 40)
    #expect(try fixture.artifacts() == before)
}

@Test("Revalidierung erkennt nachträglich durch Symlink ersetzten Elternordner der Backup-Wurzel")
private func recoveryReaderRejectsParentSymlinkSwapOnRevalidate() throws {
    let fm = FileManager.default
    let base = try ApplyPersistenceBarriers.resolvingRootAliases(
        testTemporaryDirectory().appendingPathComponent("recovery-parent-symlink-\(UUID().uuidString)"))
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let parentReal = base.appendingPathComponent("parent-real")
    let parentAlt = base.appendingPathComponent("parent-alt")
    let root = parentReal.appendingPathComponent("backups")
    let target = base.appendingPathComponent("target.txt")
    try fm.createDirectory(at: parentReal, withIntermediateDirectories: true)
    try fm.createDirectory(at: parentAlt, withIntermediateDirectories: true)
    try Data("foo".utf8).write(to: target)
    let session = try ApplyEngine.apply(
        plan: ApplyEngine.plan(files: [target], options: SearchOptions(find: "foo", replace: "bar", isRegex: false)),
        backupRoot: root, cleanupOlderThan: nil)

    var swapped = false
    #expect(throws: RecoveryReader.Failure.changed(.root)) {
        try RecoveryReader.read(sessionNamed: session.sessionDirectory.lastPathComponent, in: root) {
            guard !swapped else { return }
            swapped = true
            try fm.moveItem(at: parentReal, to: parentAlt.appendingPathComponent("moved-real"))
            try fm.createSymbolicLink(at: parentReal, withDestinationURL: parentAlt.appendingPathComponent("moved-real"))
        }
    }
    #expect(swapped)
}

@Test("Manifest mit fremdem preparedURL-Dateinamen außerhalb des Fastra-Temp-Musters wird abgewiesen")
private func recoveryReaderRejectsNonTemporaryPreparedURL() throws {
    let fixture = try RecoveryReaderFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var pendingSession: ApplySession?
    _ = try fixture.apply { candidate in
        if pendingSession == nil, !candidate.retainedPendingFiles.isEmpty {
            pendingSession = candidate
        }
        try ApplyEngine.writeManifest(candidate)
    }
    let session = try #require(pendingSession)
    try ApplyEngine.writeManifest(session)
    let manifest = session.sessionDirectory.appendingPathComponent("manifest.json")
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
    var retained = try #require(json["retainedPendingFiles"] as? [[String: Any]])
    var firstRetained = try #require(retained.first)
    var work = try #require(firstRetained["cleanupDirectory"] as? [String: Any])
    let oldPrepared = work["preparedURL"] as? String
    work["preparedURL"] = fixture.control.absoluteString
    if (firstRetained["url"] as? String) == oldPrepared {
        firstRetained["url"] = fixture.control.absoluteString
    }
    firstRetained["cleanupDirectory"] = work
    retained[0] = firstRetained
    json["retainedPendingFiles"] = retained
    try JSONSerialization.data(withJSONObject: json).write(to: manifest, options: .atomic)

    #expect(throws: RecoveryReader.Failure.invalid(.manifest, .cleanupReference)) {
        try fixture.read(session)
    }
}
