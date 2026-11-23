import CoreFoundation
import Foundation
import Testing
@testable import Fastra

@Test("Der erste Suite-Aufbau räumt beim regulären Prozessende nur registrierte Domains ab")
func testDefaultsCleanupSurvivesProcessExit() throws {
    let token = UUID().uuidString
    let root = testTemporaryDirectory()
        .appendingPathComponent("fastra-defaults-exit-\(token)", isDirectory: true)
    let registeredName = "FastraTests.ExitRegistered.\(UUID().uuidString)"
    let retainedName = "FastraTests.ExitUnregistered.\(UUID().uuidString)"
    let home = root.appendingPathComponent("home", isDirectory: true)
    let temporary = root.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var childrenFinished = true
    defer {
        if childrenFinished {
            // CFFIXED_USER_HOME isoliert benannte Suiten nicht zuverlässig.
            // Deshalb nur diese beiden eigenen UUID-Domains gezielt leeren.
            for name in [registeredName, retainedName] {
                if let defaults = UserDefaults(suiteName: name) {
                    defaults.removePersistentDomain(forName: name)
                    #expect(defaults.synchronize(), "Eigene Fixture-Domain ließ sich nicht synchronisieren: \(name)")
                }
            }
            try? FileManager.default.removeItem(at: root)
        } else {
            // Der Prozesshelfer kann bei Fehlern vor abgeschlossenem Reap
            // werfen. Solange das Ende unklar ist, nichts unter dem Kind löschen.
            Issue.record("Kindende nicht bestätigt; Fixture bleibt unter \(root.path), Domains: \(registeredName), \(retainedName)")
        }
    }
    for directory in [home.appendingPathComponent("Library/Preferences", isDirectory: true), temporary] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let (executable, arguments) = try filteredUnitTestProcessInvocation("testDefaultsExitProcessChild")
    let environment = [
        "FASTRA_DEFAULTS_EXIT_ROOT": root.path,
        "FASTRA_DEFAULTS_EXIT_TOKEN": token,
        "FASTRA_DEFAULTS_EXIT_REGISTERED": registeredName,
        "FASTRA_DEFAULTS_EXIT_RETAINED": retainedName,
        "FASTRA_DEFAULTS_EXIT_INSPECT": "0",
        "FASTRA_TEST_DEFAULTS_REGISTRY": root.appendingPathComponent("registry.txt").path,
        "CFFIXED_USER_HOME": home.path,
        "TMPDIR": temporary.path,
    ]
    childrenFinished = false
    let exited = try runTestProcess(executable, arguments: arguments, environment: environment, timeout: 30)
    childrenFinished = true
    try #require(exited.status == 0, "Testkind endete nicht regulär: \(exited.output)")
    try #require(try String(contentsOf: root.appendingPathComponent("before-exit.txt"), encoding: .utf8) == token)

    childrenFinished = false
    let inspected = try runTestProcess(executable, arguments: arguments,
        environment: environment.merging(["FASTRA_DEFAULTS_EXIT_INSPECT": "1"]) { _, new in new }, timeout: 30)
    childrenFinished = true
    try #require(inspected.status == 0, "Frischer Testhost bestätigt den Persistenzstand nicht: \(inspected.output)")
    #expect(try String(contentsOf: root.appendingPathComponent("after-exit.txt"), encoding: .utf8) == token)
}

@Test("Gezieltes Testkind für reguläres Defaults-Prozessende und frische Inspektion",
      .enabled(if: ProcessInfo.processInfo.environment["FASTRA_DEFAULTS_EXIT_ROOT"] != nil))
func testDefaultsExitProcessChild() throws {
    let environment = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(environment["FASTRA_DEFAULTS_EXIT_ROOT"]), isDirectory: true)
    let token = try #require(environment["FASTRA_DEFAULTS_EXIT_TOKEN"])
    try #require(UUID(uuidString: token) != nil)
    try #require(root.lastPathComponent == "fastra-defaults-exit-\(token)")
    let registeredName = try #require(environment["FASTRA_DEFAULTS_EXIT_REGISTERED"])
    let retainedName = try #require(environment["FASTRA_DEFAULTS_EXIT_RETAINED"])
    for (name, prefix) in [(registeredName, "FastraTests.ExitRegistered."),
                           (retainedName, "FastraTests.ExitUnregistered.")] {
        try #require(name.hasPrefix(prefix))
        try #require(UUID(uuidString: String(name.dropFirst(prefix.count))) != nil)
        try #require(TestDefaultsPurge.isTestDomain(name))
        try #require(!TestDefaultsPurge.isRegistered(name))
    }
    let registry = root.appendingPathComponent("registry.txt")
    try #require(environment["FASTRA_TEST_DEFAULTS_REGISTRY"] == registry.path)
    try #require(environment["CFFIXED_USER_HOME"] == root.appendingPathComponent("home").path)
    try #require(environment["TMPDIR"] == root.appendingPathComponent("tmp").path)
    func persistedSentinel(_ name: String) throws -> String? {
        try #require(CFPreferencesSynchronize(name as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
        return CFPreferencesCopyValue("sentinel" as CFString, name as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }
    if environment["FASTRA_DEFAULTS_EXIT_INSPECT"] == "1" {
        // Dieser frische Prozess ruft testSuiteDefaults absichtlich nie auf:
        // Sein eigener Exit darf einen fehlenden Hook im ersten Kind nicht heilen.
        try #require(try String(contentsOf: root.appendingPathComponent("before-exit.txt"), encoding: .utf8) == token)
        try #require(try persistedSentinel(registeredName) == nil)
        let keys = CFPreferencesCopyKeyList(registeredName as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        if let keys { try #require(CFArrayGetCount(keys) == 0) }
        try #require(try persistedSentinel(retainedName) == token)
        try token.write(to: root.appendingPathComponent("after-exit.txt"), atomically: true, encoding: .utf8)
        return
    }
    try #require(!FileManager.default.fileExists(atPath: registry.path))
    // Genau der erste reguläre Suite-Aufbau muss den unveränderten atexit-Hook
    // installieren. Keine direkte Cleanup-Funktion im Eltern- oder Kindpfad.
    let registered = testSuiteDefaults(named: registeredName)
    let retained = try #require(UserDefaults(suiteName: retainedName))
    registered.set(token, forKey: "sentinel")
    retained.set(token, forKey: "sentinel")
    try #require(registered.synchronize())
    try #require(retained.synchronize())
    try #require(try persistedSentinel(registeredName) == token)
    try #require(try persistedSentinel(retainedName) == token)
    try #require(TestDefaultsPurge.isRegistered(registeredName))
    try #require(!TestDefaultsPurge.isRegistered(retainedName))
    try #require(try String(contentsOf: registry, encoding: .utf8) == registeredName + "\n")
    try token.write(to: root.appendingPathComponent("before-exit.txt"), atomically: true, encoding: .utf8)
    // Regulär zurückkehren: Erst das tatsächliche Testhost-Ende führt atexit aus.
}
