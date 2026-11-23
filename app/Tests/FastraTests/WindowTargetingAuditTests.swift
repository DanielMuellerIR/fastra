import Foundation
import Testing

private let windowTargetingScriptURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("window-targeting-audit.sh")

private final class WindowTargetingAuditFixture {
    let root: URL
    let sources: URL
    let script: URL

    init(createSources: Bool = true) throws {
        root = testTemporaryDirectory().appendingPathComponent("fastra-window-audit-\(UUID().uuidString)")
        let app = root.appendingPathComponent("app")
        sources = app.appendingPathComponent("Sources/Fastra")
        script = app.appendingPathComponent("window-targeting-audit.sh")
        do {
            try FileManager.default.createDirectory(at: createSources ? sources : app,
                                                    withIntermediateDirectories: true)
            // Keine nachgebaute Prüflogik: Jede Fixture startet dieselben Skriptbytes.
            try FileManager.default.copyItem(at: windowTargetingScriptURL, to: script)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ source: String, file: String = "BoundaryProbe.swift") throws {
        try source.write(to: sources.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    func run(environment: [String: String] = [:]) throws -> TestProcessResult {
        try runTestProcess("/bin/bash", arguments: [script.path], environment: environment, timeout: 10)
    }

    func failingClassifierEnvironment(status: Int) throws -> [String: String] {
        let commands = root.appendingPathComponent("commands")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        let awk = commands.appendingPathComponent("awk")
        try "#!/bin/bash\necho 'Fixture: classification failed' >&2\nexit \(status)\n"
            .write(to: awk, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: awk.path)
        return ["PATH": commands.path + ":/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    func failingScannerEnvironment(pattern: String) throws -> [String: String] {
        let commands = root.appendingPathComponent("commands")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        let grep = commands.appendingPathComponent("grep")
        try #"""
        #!/bin/bash
        if [ "${1:-}" = "-rn" ]; then
          case "$*" in
            *"$FASTRA_TEST_SCAN_PATTERN"*) echo 'Fixture: scan failed' >&2; exit 73 ;;
          esac
        fi
        exec /usr/bin/grep "$@"
        """#.write(to: grep, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: grep.path)
        return ["PATH": commands.path + ":/usr/bin:/bin:/usr/sbin:/sbin",
                "FASTRA_TEST_SCAN_PATTERN": pattern]
    }
}

@Suite("Fenster-Zielwahl-Audit", .serialized)
struct WindowTargetingAuditSerialRunnerIntegrationTests {
    @Test("NSWorkspace und fremde ASCII-Bezeichner sind keine Workspace-Leser", arguments: [
        "NSWorkspace.shared", "SomeWorkspace.shared", "_Workspace.shared", "Workspace0.shared",
        "Workspace.sharedness", "Workspace.shared_", "Workspace.shared0",
    ])
    func permitsOtherIdentifiers(access: String) throws {
        let fixture = try WindowTargetingAuditFixture()
        try fixture.write("let value = \(access)\n")
        let result = try fixture.run()
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("WINDOW TARGETING AUDIT: PASS"))
    }

    @Test("Direkte Workspace-Leser werden auch neben NSWorkspace erkannt", arguments: [
        "let owner = Workspace.shared",
        "let service = NSWorkspace.shared; let owner = Workspace.shared",
        "let owner = Workspace.shared; let service = NSWorkspace.shared",
        "let owner = Fastra.Workspace.shared",
        "Workspace.shared = workspace; let owner = Workspace.shared",
        "let owner = Workspace.shared; Workspace.shared = workspace",
        "let same = Workspace.shared === workspace; let owner = Workspace.shared",
        "let owner = Workspace.shared; let same = Workspace.shared === workspace",
        "let different = Workspace.shared !== workspace; let owner = Workspace.shared",
        "let owner = Workspace.shared; let different = Workspace.shared !== workspace",
        "Workspace.shared = Workspace.shared",
        "Workspace.shared=Workspace.shared",
        "Workspace.shared = Workspace.shared.editor",
        "Workspace.shared = select(Workspace.shared)",
        "SomeWorkspace.shared = workspace; let owner = Workspace.shared",
        "let owner = Workspace.shared; SomeWorkspace.shared = workspace",
        "let same = NSWorkspace.shared === service; let owner = Workspace.shared",
        "let owner = Workspace.shared; let same = NSWorkspace.shared === service",
        "let same = Workspace.shared === select(Workspace.shared)",
    ])
    func rejectsWorkspaceReads(source: String) throws {
        let fixture = try WindowTargetingAuditFixture()
        try fixture.write(source + "\n")
        let result = try fixture.run()
        #expect(result.status == 1, "\(result.output)")
        #expect(!result.output.contains("PASS"))
        #expect(result.output.contains("Sources/Fastra/BoundaryProbe.swift:1"))
        #expect(result.output.contains(source))
    }

    @Test("Identitäts-RHS bleibt außerhalb der konservativen lexikalischen Freigabe", arguments: [
        "let same = workspace === Workspace.shared",
        "let same = Workspace.shared === Workspace.shared",
    ])
    func rejectsIdentityRHSWithoutFollowingOperator(source: String) throws {
        let fixture = try WindowTargetingAuditFixture()
        try fixture.write(source + "\n")
        let result = try fixture.run()
        #expect(result.status == 1, "\(result.output)")
        #expect(!result.output.contains("PASS"))
        #expect(result.output.contains("Sources/Fastra/BoundaryProbe.swift:1"))
        #expect(result.output.contains(source))
    }

    @Test("Unsortierte AppKit-Fensterzugriffe werden erkannt", arguments: [
        "NSApp.windows", "NSApplication.shared.windows",
    ])
    func rejectsUnsortedWindows(access: String) throws {
        let fixture = try WindowTargetingAuditFixture()
        try fixture.write("let windows = \(access)\n")
        let result = try fixture.run()
        #expect(result.status == 1, "\(result.output)")
        #expect(!result.output.contains("PASS"))
        #expect(result.output.contains("Sources/Fastra/BoundaryProbe.swift:1"))
    }

    @Test("Vollzeilenkommentare, Zuweisungen und Identitätsvergleiche bleiben erlaubt")
    func permitsExistingLineExceptions() throws {
        let fixture = try WindowTargetingAuditFixture()
        try fixture.write("""
          // Workspace.shared und NSApp.windows sind hier nur erklärt.
          /// NSApplication.shared.windows ist unsortiert.
        Workspace.shared = workspace
        Workspace.shared = controller.workspace
        Workspace.shared = self
        Workspace.shared = primaryWorkspace
        let same = Workspace.shared === workspace
        let different = Workspace.shared !== workspace
        Workspace.shared=workspace; Workspace.shared = other
        let sameAgain = Workspace.shared === workspace; let other = Workspace.shared !== other
        // Workspace.shared = workspace; let owner = Workspace.shared
        """)
        let result = try fixture.run()
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("WINDOW TARGETING AUDIT: PASS"))
    }

    @Test("Lifecycle- und Testdateien behalten ihre begründeten Ausnahmen", arguments: [
        "AppDelegate.swift", "SelfTest.swift", "SoakTest.swift",
    ])
    func permitsLifecycleAndTestFiles(file: String) throws {
        let fixture = try WindowTargetingAuditFixture()
        try fixture.write("let owner = Workspace.shared\nlet windows = NSApp.windows\n", file: file)
        let result = try fixture.run()
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("WINDOW TARGETING AUDIT: PASS"))
    }

    @Test("Zentrale Fensterdateien dürfen AppKit-Fenster weiterhin inspizieren", arguments: [
        "CommandTargeting.swift", "DocumentWindowController.swift",
    ])
    func permitsCentralWindowFiles(file: String) throws {
        let fixture = try WindowTargetingAuditFixture()
        try fixture.write("let windows = NSApplication.shared.windows\n", file: file)
        let result = try fixture.run()
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("WINDOW TARGETING AUDIT: PASS"))
    }

    @Test("Fensterdatei-Ausnahme erlaubt keinen zusätzlichen Workspace-Leser", arguments: [
        "CommandTargeting.swift", "DocumentWindowController.swift",
    ])
    func rejectsWorkspaceReadsInCentralWindowFiles(file: String) throws {
        let fixture = try WindowTargetingAuditFixture()
        try fixture.write("let owner = Workspace.shared\n", file: file)
        let result = try fixture.run()
        #expect(result.status == 1, "\(result.output)")
        #expect(!result.output.contains("PASS"))
        #expect(result.output.contains("Sources/Fastra/\(file):1"))
    }

    @Test("Fehlendes Quellverzeichnis ist ein Umgebungsfehler")
    func rejectsMissingSources() throws {
        let fixture = try WindowTargetingAuditFixture(createSources: false)
        let result = try fixture.run()
        #expect(result.status == 2, "\(result.output)")
        #expect(!result.output.contains("PASS"))
        #expect(result.output.contains("Umgebungsfehler"))
    }

    @Test("Klassifiziererfehler sind Umgebungsfehler", arguments: [73, 127])
    func rejectsClassifierErrors(status: Int) throws {
        let fixture = try WindowTargetingAuditFixture()
        try fixture.write("Workspace.shared = workspace\n")
        let environment = try fixture.failingClassifierEnvironment(status: status)
        let result = try fixture.run(environment: environment)
        #expect(result.status == 2, "\(result.output)")
        #expect(!result.output.contains("PASS"))
        #expect(result.output.contains("Umgebungsfehler"))
        #expect(result.output.contains("Fixture: classification failed"))
        #expect(result.output.contains("awk: \(status)"))
    }

    @Test("Beide fehlgeschlagenen Scans verweigern PASS", arguments: ["NSApp", "Workspace"])
    func rejectsScanErrors(pattern: String) throws {
        let fixture = try WindowTargetingAuditFixture()
        try fixture.write("let service = NSWorkspace.shared\n")
        let environment = try fixture.failingScannerEnvironment(pattern: pattern)
        let result = try fixture.run(environment: environment)
        #expect(result.status == 2, "\(result.output)")
        #expect(!result.output.contains("PASS"))
        #expect(result.output.contains("Umgebungsfehler"))
        #expect(result.output.contains("Fixture: scan failed"))
        #expect(result.output.contains("grep: 73"))
    }
}
