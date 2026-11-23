import Darwin
import Foundation
import Testing
@testable import Fastra

private let registryWriterCount = 4
private let registryNamesPerWriter = 256

private func registryNames(token: String, writer: Int) -> [String] {
    (0..<registryNamesPerWriter).map { "FastraTests.RegistryAppend.\(token).\(writer).\($0)" }
}

private func openRegistryDescriptors(at registry: URL) -> [Int32] {
    let expectedPath = registry.resolvingSymlinksInPath().path
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    return (0..<getdtablesize()).filter { descriptor in
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else { return false }
        return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path == expectedPath
    }
}

@Test("Unabhängige Testhosts erhalten alle erfolgreichen Registry-Appends")
func testDefaultsRegistrySerialRunnerIntegration() async throws {
    for existing in [true, false] {
        try await checkRegistryWriters(existing: existing)
    }
}

private func checkRegistryWriters(existing: Bool) async throws {
    let token = UUID().uuidString
    let root = testTemporaryDirectory()
        .appendingPathComponent("fastra-registry-append-\(token)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    var childrenFinished = true
    var keepFixture = false
    defer {
        if !childrenFinished {
            Issue.record("Kindende nicht bestätigt; Registry-Fixture bleibt unter \(root.path)")
        } else if keepFixture {
            print("REGISTRY-APPEND Fixture bis zum äußeren Runner-Cleanup erhalten: \(root.path)")
        } else {
            try? FileManager.default.removeItem(at: root)
        }
    }
    let registry = root.appendingPathComponent("registry.txt")
    let seed = "FastraTests.RegistrySeed.\(token)"
    if existing {
        try (seed + "\n").write(to: registry, atomically: true, encoding: .utf8)
    }
    var expected = Set((0..<registryWriterCount).flatMap { registryNames(token: token, writer: $0) })
    if existing { expected.insert(seed) }
    let (executable, arguments) = try filteredUnitTestProcessInvocation("testDefaultsRegistryProcessChild")
    var environments: [[String: String]] = []
    for writer in 0..<registryWriterCount {
        let child = root.appendingPathComponent("writer-\(writer)", isDirectory: true)
        let home = child.appendingPathComponent("home", isDirectory: true)
        let temporary = child.appendingPathComponent("tmp", isDirectory: true)
        for directory in [home.appendingPathComponent("Library/Preferences", isDirectory: true), temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        environments.append([
            "FASTRA_REGISTRY_APPEND_ROOT": root.path,
            "FASTRA_REGISTRY_APPEND_TOKEN": token,
            "FASTRA_REGISTRY_APPEND_WRITER": String(writer),
            "FASTRA_TEST_DEFAULTS_REGISTRY": registry.path,
            "FASTRA_SELFTEST_DEFAULTS_SUITE": "FastraTests.RegistryLaunch.\(UUID().uuidString)",
            "CFFIXED_USER_HOME": home.path,
            "TMPDIR": temporary.path,
        ])
    }
    childrenFinished = false
    var readyPIDs: [Int32] = []
    var gateError: (any Error)?
    let results = await withTaskGroup(of: Result<TestProcessResult, any Error>.self) { group in
        for environment in environments {
            group.addTask {
                Result { try runTestProcess(executable, arguments: arguments,
                                            environment: environment, timeout: 30) }
            }
        }
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while readyPIDs.count != registryWriterCount {
                readyPIDs = try (0..<registryWriterCount).compactMap { writer in
                    let marker = root.appendingPathComponent("ready-\(writer).txt")
                    guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
                    let fields = try String(contentsOf: marker, encoding: .utf8).split(separator: " ")
                    try #require(fields.count == 2 && fields[0] == token)
                    let pid = try #require(Int32(fields[1]))
                    try #require(pid > 1 && kill(pid, 0) == 0)
                    return pid
                }
                try #require(ProcessInfo.processInfo.systemUptime < deadline,
                             "Nur \(readyPIDs.count) von \(registryWriterCount) Testhosts bereit")
                if readyPIDs.count != registryWriterCount {
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            try #require(Set(readyPIDs).count == registryWriterCount)
            try token.write(to: root.appendingPathComponent("start.txt"), atomically: true, encoding: .utf8)
        } catch {
            gateError = error
        }
        // Auch nach einem Gatefehler alle begrenzten Prozesshelfer abholen.
        var results: [Result<TestProcessResult, any Error>] = []
        for await result in group { results.append(result) }
        return results
    }
    // Nur normale Rückkehr des Helfers bestätigt waitpid und geschlossene Pipes.
    childrenFinished = results.count == registryWriterCount && results.allSatisfy {
        if case .success = $0 { return true }
        return false
    }
    keepFixture = true
    for result in results {
        let child = try result.get()
        try #require(child.status == 0, "Registry-Testkind fehlgeschlagen: \(child.output)")
    }
    if let gateError { throw gateError }
    for writer in 0..<registryWriterCount {
        let marker = try String(contentsOf: root.appendingPathComponent("finished-\(writer).txt"), encoding: .utf8)
        try #require(marker == "\(token) \(readyPIDs[writer]) \(registryNamesPerWriter * 2)")
    }
    let recorded = try String(contentsOf: registry, encoding: .utf8)
    let lines = recorded.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    let missing = expected.subtracting(lines).sorted()
    let unexpected = Set(lines).subtracting(expected).sorted()
    keepFixture = !recorded.hasSuffix("\n") || !lines.allSatisfy(TestDefaultsPurge.isTestDomain)
        || lines.count != Set(lines).count || !missing.isEmpty || !unexpected.isEmpty
    if keepFixture {
        // Der äußere Runner entfernt seine Sandbox auch bei Funktionsfehlern.
        // Die Originalbytes bleiben deshalb zusätzlich im erfassten Fehlerlog.
        print("REGISTRY-APPEND raw-base64 token=\(token) data=\(try Data(contentsOf: registry).base64EncodedString())")
    }
    print("REGISTRY-APPEND existing=\(existing) token=\(token) ready-pids=\(readyPIDs) successful-calls=\(registryWriterCount * registryNamesPerWriter * 2) expected=\(expected.count) lines=\(lines.count) missing=\(missing.count) unexpected=\(unexpected.count)")
    try #require(recorded.hasSuffix("\n"), "Registry endet mit unvollständiger Zeile")
    #expect(lines.allSatisfy(TestDefaultsPurge.isTestDomain), "Registry enthält ungültige Zeilen")
    #expect(lines.count == Set(lines).count, "Registry enthält Duplikate")
    #expect(missing.isEmpty, "Erfolgreiche Namen fehlen: \(missing)")
    #expect(unexpected.isEmpty, "Unerwartete Registryzeilen: \(unexpected)")
}

@Test("Gezieltes Testkind registriert ausschließlich seine vorausberechneten Namen",
      .enabled(if: ProcessInfo.processInfo.environment["FASTRA_REGISTRY_APPEND_ROOT"] != nil))
func testDefaultsRegistryProcessChild() throws {
    let environment = ProcessInfo.processInfo.environment
    let token = try #require(environment["FASTRA_REGISTRY_APPEND_TOKEN"])
    try #require(UUID(uuidString: token) != nil)
    let root = URL(fileURLWithPath: try #require(environment["FASTRA_REGISTRY_APPEND_ROOT"]), isDirectory: true)
    try #require(root.lastPathComponent == "fastra-registry-append-\(token)")
    let writerValue = try #require(environment["FASTRA_REGISTRY_APPEND_WRITER"])
    let writer = try #require(Int(writerValue))
    try #require((0..<registryWriterCount).contains(writer))
    let child = root.appendingPathComponent("writer-\(writer)", isDirectory: true)
    let registry = root.appendingPathComponent("registry.txt")
    try #require(environment["FASTRA_TEST_DEFAULTS_REGISTRY"] == registry.path)
    try #require(environment["CFFIXED_USER_HOME"] == child.appendingPathComponent("home").path)
    try #require(environment["TMPDIR"] == child.appendingPathComponent("tmp").path)
    let launchSuite = try #require(environment["FASTRA_SELFTEST_DEFAULTS_SUITE"])
    try #require(launchSuite.hasPrefix("FastraTests.RegistryLaunch.") && TestDefaultsPurge.isTestDomain(launchSuite))
    let names = registryNames(token: token, writer: writer)
    try #require(names.allSatisfy(TestDefaultsPurge.isTestDomain))
    try "\(token) \(getpid())".write(to: root.appendingPathComponent("ready-\(writer).txt"),
                                   atomically: true, encoding: .utf8)
    let gate = root.appendingPathComponent("start.txt")
    let deadline = ProcessInfo.processInfo.systemUptime + 20
    while !FileManager.default.fileExists(atPath: gate.path) {
        try #require(ProcessInfo.processInfo.systemUptime < deadline, "Startgate blieb geschlossen")
        usleep(1_000)
    }
    try #require(try String(contentsOf: gate, encoding: .utf8) == token)
    var successfulCalls = 0
    // Kein Suite-Aufbau und kein Purge: Diese Kinder schreiben nur Registryzeilen.
    for name in names {
        for _ in 0..<2 {
            try #require(TestDefaultsPurge.register(name))
            successfulCalls += 1
        }
    }
    try #require(openRegistryDescriptors(at: registry).isEmpty,
                 "Registry-Descriptor blieb nach dem Schreiben offen")
    try "\(token) \(getpid()) \(successfulCalls)".write(
        to: root.appendingPathComponent("finished-\(writer).txt"), atomically: true, encoding: .utf8)
}
