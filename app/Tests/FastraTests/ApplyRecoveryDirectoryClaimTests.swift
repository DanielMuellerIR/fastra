import Darwin
import Foundation
import Testing
@testable import Fastra

private struct RecoveryClaimFixture {
    let directory: URL
    let root: URL
    let session: URL

    init(rootMode: mode_t = 0o700, sessionMode: mode_t = 0o700) throws {
        let proposed = testTemporaryDirectory().appendingPathComponent("fastra-recovery-claim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: proposed, withIntermediateDirectories: true)
        let resolved = try #require(realpath(proposed.path, nil))
        defer { free(resolved) }
        directory = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        root = directory.appendingPathComponent("backups")
        session = root.appendingPathComponent("session-existing")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try #require(chmod(root.path, rootMode) == 0)
        try #require(chmod(session.path, sessionMode) == 0)
        var filesystem = statfs()
        try #require(statfs(root.path, &filesystem) == 0)
        let name = withUnsafeBytes(of: filesystem.f_fstypename) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        try #require(name == "apfs", "Die Verzeichnissperre muss auf echtem APFS geprüft werden")
    }

    func claim(rootIdentity: FileIdentity? = nil, sessionIdentity: FileIdentity? = nil) throws
        -> ApplyRecoveryDirectoryClaim {
        try ApplyRecoveryDirectoryClaim(root: root, sessionName: session.lastPathComponent,
            expectedRootIdentity: rootIdentity, expectedSessionIdentity: sessionIdentity)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Suite("Anspruch auf bestehende Wiederherstellungsordner", .serialized)
struct ApplyRecoveryDirectoryClaimSerialRunnerIntegrationTests {
    @Test("Getrennte FDs konkurrieren ohne Warten; Close und Scopeende geben frei",
          arguments: [mode_t(0o700), mode_t(0o755)], [mode_t(0o700), mode_t(0o755)])
    func separateDescriptorsAndRelease(rootMode: mode_t, sessionMode: mode_t) throws {
        let fixture = try RecoveryClaimFixture(rootMode: rootMode, sessionMode: sessionMode)
        defer { fixture.remove() }
        var owner: ApplyRecoveryDirectoryClaim? = try fixture.claim()
        let rootIdentity = try #require(owner?.rootIdentity)
        let sessionIdentity = try #require(owner?.sessionIdentity)
        #expect(rootIdentity == FileIdentity(url: fixture.root))
        #expect(sessionIdentity == FileIdentity(url: fixture.session))
        #expect(throws: POSIXError(.EWOULDBLOCK)) { try fixture.claim() }
        try owner?.finish()
        #expect(throws: ApplyRecoveryDirectoryClaim.Rejection.closed) { try owner?.validateBinding() }
        try owner?.finish()
        owner = try fixture.claim(rootIdentity: rootIdentity, sessionIdentity: sessionIdentity)
        #expect(throws: POSIXError(.EWOULDBLOCK)) { try fixture.claim() }
        owner = nil
        let next = try fixture.claim()
        try next.validateBinding()
        try next.finish()
    }

    @Test("Die bloße Beanspruchung verändert weder Ablage noch Manifest")
    func existingContentsRemainUnchanged() throws {
        let fixture = try RecoveryClaimFixture(rootMode: 0o755, sessionMode: 0o755)
        defer { fixture.remove() }
        let manifest = fixture.session.appendingPathComponent("manifest.json")
        let bytes = Data("vorhandenes Manifest\r\n".utf8)
        try bytes.write(to: manifest)
        var beforeRoot = stat(), beforeSession = stat()
        try #require(lstat(fixture.root.path, &beforeRoot) == 0)
        try #require(lstat(fixture.session.path, &beforeSession) == 0)
        let claim = try fixture.claim()
        try claim.validateBinding()
        try claim.finish()
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["session-existing"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.session.path) == ["manifest.json"])
        #expect(try Data(contentsOf: manifest) == bytes)
        var afterRoot = stat(), afterSession = stat()
        try #require(lstat(fixture.root.path, &afterRoot) == 0)
        try #require(lstat(fixture.session.path, &afterSession) == 0)
        for (before, after) in [(beforeRoot, afterRoot), (beforeSession, afterSession)] {
            #expect(FileIdentity(stat: before) == FileIdentity(stat: after))
            #expect(before.st_mode == after.st_mode)
            #expect(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec)
            #expect(before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
            #expect(before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec)
            #expect(before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec)
        }
    }

    @Test("Erwartete Reader-Identität weist einen gleichnamigen Fremdersatz ab",
          arguments: ["root", "session"])
    func expectedIdentityRejectsReplacement(component: String) throws {
        let fixture = try RecoveryClaimFixture()
        defer { fixture.remove() }
        let rootIdentity = try #require(FileIdentity(url: fixture.root))
        let sessionIdentity = try #require(FileIdentity(url: fixture.session))
        let replaced = component == "root" ? fixture.root : fixture.session
        try FileManager.default.moveItem(at: replaced, to: replaced.appendingPathExtension("old"))
        try FileManager.default.createDirectory(at: fixture.session, withIntermediateDirectories: true)
        #expect(throws: ApplyRecoveryDirectoryClaim.Rejection.changedDirectory) {
            try fixture.claim(rootIdentity: rootIdentity, sessionIdentity: sessionIdentity)
        }
        let foreign = try fixture.claim()
        try foreign.finish()
    }

    @Test("Umbenennung hält den alten Anspruch; der neue Name gehört ihm nicht",
          arguments: ["root", "session", "ancestor"])
    func renameKeepsOriginalInodeLocked(component: String) throws {
        let fixture = try RecoveryClaimFixture()
        var cleanup = fixture.directory
        defer { try? FileManager.default.removeItem(at: cleanup); fixture.remove() }
        let claim = try fixture.claim()
        defer { try? claim.finish() }
        let replaced = component == "root" ? fixture.root
            : (component == "session" ? fixture.session : fixture.directory)
        let moved = replaced.appendingPathExtension("old")
        try FileManager.default.moveItem(at: replaced, to: moved)
        if component == "ancestor" { cleanup = moved }
        try FileManager.default.createDirectory(at: fixture.session, withIntermediateDirectories: true)
        #expect(throws: ApplyRecoveryDirectoryClaim.Rejection.changedDirectory) { try claim.validateBinding() }
        let oldSession = component == "session" ? moved
            : moved.appendingPathComponent(component == "ancestor" ? "backups/session-existing" : "session-existing")
        let descriptor = open(oldSession.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == -1)
        #expect(errno == EWOULDBLOCK)
        let foreign = try fixture.claim()
        #expect(foreign.sessionIdentity != claim.sessionIdentity)
        try foreign.finish()
        try claim.finish()
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    }

    @Test("Verknüpfungen und fremd beschreibbare Verzeichnisse werden abgewiesen",
          arguments: ["root-link", "session-link", "ancestor-link", "root-write", "session-write"])
    func unsafeDirectoriesAreRejected(kind: String) throws {
        let fixture = try RecoveryClaimFixture()
        var cleanup = fixture.directory
        defer { try? FileManager.default.removeItem(at: cleanup); fixture.remove() }
        let owner = try fixture.claim()
        defer { try? owner.finish() }
        if kind.hasSuffix("link") {
            let link = kind == "root-link" ? fixture.root
                : (kind == "session-link" ? fixture.session : fixture.directory)
            let moved = link.appendingPathExtension("moved")
            try FileManager.default.moveItem(at: link, to: moved)
            if kind == "ancestor-link" { cleanup = moved }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: moved)
        } else {
            try #require(chmod((kind == "root-write" ? fixture.root : fixture.session).path, 0o770) == 0)
        }
        #expect(throws: (any Error).self) { try owner.validateBinding() }
        #expect(throws: (any Error).self) { try fixture.claim() }
    }

    @Test("Ungültige Namen und fehlende Sitzungen legen keine Dateien an",
          arguments: ["", "session-", "other", "session-x/../session-existing", "session-\u{0}", "session-missing"])
    func invalidNamesDoNotCreateAnything(name: String) throws {
        let fixture = try RecoveryClaimFixture()
        defer { fixture.remove() }
        #expect(throws: (any Error).self) {
            try ApplyRecoveryDirectoryClaim(root: fixture.root, sessionName: name)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["session-existing"])
    }

    @Test("Getrennte Prozesse konkurrieren; Close, exit und SIGKILL geben den Anspruch frei",
          arguments: ["close", "exit", "kill"])
    func processOwnershipAndTermination(mode: String) async throws {
        let fixture = try RecoveryClaimFixture()
        defer { fixture.remove() }
        let ready = fixture.directory.appendingPathComponent("ready")
        let release = fixture.directory.appendingPathComponent("release")
        defer { try? Data().write(to: release) }
        let (executable, arguments) = try filteredUnitTestProcessInvocation(
            "applyRecoveryDirectoryClaimSerialRunnerIntegrationChild")
        let environment = ["FASTRA_CLAIM_TEST_ROOT": fixture.directory.path, "FASTRA_CLAIM_TEST_MODE": mode]
        let child = Task.detached {
            try runTestProcess(executable, arguments: arguments, environment: environment, timeout: 15)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !FileManager.default.fileExists(atPath: ready.path), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let didAcquire = FileManager.default.fileExists(atPath: ready.path)
        if didAcquire { #expect(throws: POSIXError(.EWOULDBLOCK)) { try fixture.claim() } }
        try Data().write(to: release)
        let result = try await child.value
        try #require(didAcquire, "Kind erwarb keinen Anspruch: \(result.output)")
        #expect(result.status == (mode == "kill" ? SIGKILL : 0), "\(result.output)")
        let next = try fixture.claim()
        try next.validateBinding()
        try next.finish()
    }
}

@Test("Gezieltes Testkind mit lebendem Verzeichnisanspruch",
      .enabled(if: ProcessInfo.processInfo.environment["FASTRA_CLAIM_TEST_ROOT"] != nil))
func applyRecoveryDirectoryClaimSerialRunnerIntegrationChild() throws {
    let environment = ProcessInfo.processInfo.environment
    let directory = URL(fileURLWithPath: try #require(environment["FASTRA_CLAIM_TEST_ROOT"]))
    let prefix = "fastra-recovery-claim-"
    try #require(directory.lastPathComponent.hasPrefix(prefix))
    try #require(UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) != nil)
    let mode = try #require(environment["FASTRA_CLAIM_TEST_MODE"])
    try #require(["close", "exit", "kill"].contains(mode))
    let claim = try ApplyRecoveryDirectoryClaim(root: directory.appendingPathComponent("backups"),
        sessionName: "session-existing")
    try withExtendedLifetime(claim) {
        try Data().write(to: directory.appendingPathComponent("ready"))
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("release").path),
              ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        try #require(FileManager.default.fileExists(atPath: directory.appendingPathComponent("release").path))
        if mode == "close" { try claim.finish() }
        else if mode == "exit" { _exit(0) }
        else {
            try #require(kill(getpid(), SIGKILL) == 0)
            // Die Signalzustellung darf nicht gegen ein unmittelbar folgendes
            // _exit antreten. Der äußere Prozesshelfer begrenzt jede Wartezeit.
            while true { pause() }
        }
    }
}
