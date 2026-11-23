import CoreFoundation
import Foundation
import Testing
@testable import Fastra

@Test("Der echte Selbsttest-Launcher räumt registrierte Domains auch beim frühen Fehlerexit ab")
func selfTestLauncherCleanupSurvivesEarlyFailureExit() throws {
    let token = UUID().uuidString
    let root = testTemporaryDirectory()
        .appendingPathComponent("fastra-launcher-exit-\(token)", isDirectory: true)
    let registeredName = "FastraTests.LauncherRegistered.\(UUID().uuidString)"
    let retainedName = "FastraTests.LauncherUnregistered.\(UUID().uuidString)"
    let testName = "launcher-exit-unknown-\(token)"
    let home = root.appendingPathComponent("home", isDirectory: true)
    let temporary = root.appendingPathComponent("tmp", isDirectory: true)
    try #require(!FileManager.default.fileExists(atPath: root.path))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    var childrenFinished = true
    defer {
        if childrenFinished {
            // Benannte Suiten können CFFIXED_USER_HOME umgehen. Ausschließlich
            // diese eigenen Namen leeren, nachdem alle Kinder abgeholt sind.
            for name in [registeredName, retainedName] {
                if let defaults = UserDefaults(suiteName: name) {
                    defaults.removePersistentDomain(forName: name)
                    #expect(defaults.synchronize(), "Eigene Fixture-Domain ließ sich nicht synchronisieren: \(name)")
                }
            }
            try? FileManager.default.removeItem(at: root)
        } else {
            Issue.record("Kindende nicht bestätigt; Fixture bleibt unter \(root.path), Domains: \(registeredName), \(retainedName)")
        }
    }
    for directory in [home.appendingPathComponent("Library/Preferences", isDirectory: true), temporary] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let (executable, arguments) = try filteredUnitTestProcessInvocation("selfTestLauncherExitProcessChild")
    let environment = [
        "FASTRA_LAUNCHER_EXIT_ROOT": root.path,
        "FASTRA_LAUNCHER_EXIT_TOKEN": token,
        "FASTRA_LAUNCHER_EXIT_REGISTERED": registeredName,
        "FASTRA_LAUNCHER_EXIT_RETAINED": retainedName,
        "FASTRA_LAUNCHER_EXIT_INSPECT": "0",
        "FASTRA_SELFTEST": testName,
        "FASTRA_SELFTEST_DEFAULTS_SUITE": registeredName,
        "FASTRA_SELFTEST_PASTEBOARD_DIR": "",
        "FASTRA_TEST_DEFAULTS_REGISTRY": root.appendingPathComponent("registry.txt").path,
        "HOME": home.path,
        "CFFIXED_USER_HOME": home.path,
        "CFPREFERENCES_AVOID_DAEMON": "1",
        "TMPDIR": temporary.path,
    ]
    childrenFinished = false
    let exited = try runTestProcess(executable, arguments: arguments, environment: environment, timeout: 30)
    childrenFinished = true
    try #require(exited.status == 1, "Launcher-Testkind endete nicht mit Fehlerexit 1: \(exited.output)")
    let entryMarker = "LAUNCHER-EXIT-ENTRY token=\(token) registered=\(registeredName) retained=\(retainedName)"
    try #require(exited.output.components(separatedBy: "\n").filter { $0 == entryMarker }.count == 1)
    try #require(try String(contentsOf: root.appendingPathComponent("before-entry.txt"), encoding: .utf8) == token)
    try #require(exited.output.contains("unbekannter Selbsttest-Name \"\(testName)\""))
    let resultLines = exited.output.components(separatedBy: "\n").filter { $0.hasPrefix("SELFTEST-RESULT") }
    try #require(resultLines.count == 1, "Genau ein vollständiger Launcherabschluss erwartet: \(exited.output)")
    let outputFile = root.appendingPathComponent("launcher-output.log")
    try exited.output.write(to: outputFile, atomically: true, encoding: .utf8)
    let parser = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/selftest-results.sh")
    childrenFinished = false
    let parsed = try runTestProcess("/bin/bash", arguments: [
        "-c", #"""
        set -eu
        . "$1"
        classify_selftest_result "$2" "$3" ''
        [ -z "$SELFTEST_PROTOCOL_ERROR" ]
        printf '%s\n' "$SELFTEST_RESULT_STATUS"
        """#, "launcher-result-parser", parser.path, testName, outputFile.path,
    ], timeout: 10)
    childrenFinished = true
    try #require(parsed.status == 0 && parsed.output == "FAIL\n", "Ungültiger Launcherabschluss: \(parsed.output)\n\(exited.output)")
    print("LAUNCHER-EXIT-PROBE token=\(token) child_exit=1 reaped=true result_count=1 test=\(testName) status=FAIL")

    childrenFinished = false
    let inspected = try runTestProcess(executable, arguments: arguments,
        environment: environment.merging(["FASTRA_LAUNCHER_EXIT_INSPECT": "1"]) { _, new in new }, timeout: 30)
    childrenFinished = true
    try #require(inspected.status == 0, "Frisches Inspektionskind bestätigt den Persistenzstand nicht: \(inspected.output)")
    try #require(try String(contentsOf: root.appendingPathComponent("after-exit.txt"), encoding: .utf8) == token)
    print("LAUNCHER-EXIT-PROBE token=\(token) inspection_exit=0 reaped=true registered_empty=true unregistered_unchanged=true")
}

@Test("Gezieltes Testkind für echten Launcher-Fehlerexit und frische Inspektion",
      .enabled(if: ProcessInfo.processInfo.environment["FASTRA_LAUNCHER_EXIT_ROOT"] != nil))
@MainActor
func selfTestLauncherExitProcessChild() throws {
    let environment = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(environment["FASTRA_LAUNCHER_EXIT_ROOT"]), isDirectory: true)
    let token = try #require(environment["FASTRA_LAUNCHER_EXIT_TOKEN"])
    try #require(UUID(uuidString: token) != nil)
    try #require(root.lastPathComponent == "fastra-launcher-exit-\(token)")
    let registeredName = try #require(environment["FASTRA_LAUNCHER_EXIT_REGISTERED"])
    let retainedName = try #require(environment["FASTRA_LAUNCHER_EXIT_RETAINED"])
    for (name, prefix) in [(registeredName, "FastraTests.LauncherRegistered."),
                           (retainedName, "FastraTests.LauncherUnregistered.")] {
        try #require(name.hasPrefix(prefix))
        try #require(UUID(uuidString: String(name.dropFirst(prefix.count))) != nil)
        try #require(TestDefaultsPurge.isTestDomain(name))
        try #require(!TestDefaultsPurge.isRegistered(name))
    }
    let registry = root.appendingPathComponent("registry.txt")
    let home = root.appendingPathComponent("home").path
    try #require(environment["FASTRA_TEST_DEFAULTS_REGISTRY"] == registry.path)
    try #require(environment["HOME"] == home)
    try #require(environment["CFFIXED_USER_HOME"] == home)
    try #require(environment["TMPDIR"] == root.appendingPathComponent("tmp").path)
    try #require(environment["CFPREFERENCES_AVOID_DAEMON"] == "1")
    try #require(environment["FASTRA_SELFTEST"] == "launcher-exit-unknown-\(token)")
    try #require(environment["FASTRA_SELFTEST_DEFAULTS_SUITE"] == registeredName)
    try #require(environment["FASTRA_SELFTEST_PASTEBOARD_DIR"] == "")
    func persistedDomain(_ name: String) throws -> [String: String] {
        try #require(CFPreferencesSynchronize(name as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
        let contents = CFPreferencesCopyMultiple(nil, name as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return try #require(contents as? [String: String])
    }
    if environment["FASTRA_LAUNCHER_EXIT_INSPECT"] == "1" {
        // Ein frischer Prozess liest die Persistenz. Er ruft weder Launcher
        // noch Suite-Helfer auf und kann einen fehlenden Exit-Hook nicht heilen.
        try #require(try String(contentsOf: root.appendingPathComponent("before-entry.txt"), encoding: .utf8) == token)
        try #require(try String(contentsOf: registry, encoding: .utf8) == registeredName + "\n")
        let registeredContents = try persistedDomain(registeredName)
        try #require(registeredContents["sentinel"] == nil,
                     "Registrierter Sentinel blieb nach Launcher-Exit erhalten")
        try #require(registeredContents.isEmpty)
        try #require(try persistedDomain(retainedName) == ["sentinel": token])
        try token.write(to: root.appendingPathComponent("after-exit.txt"), atomically: true, encoding: .utf8)
        return
    }
    try #require(!FileManager.default.fileExists(atPath: registry.path))
    try #require(try persistedDomain(registeredName).isEmpty)
    try #require(try persistedDomain(retainedName).isEmpty)
    let registered = try #require(UserDefaults(suiteName: registeredName))
    let retained = try #require(UserDefaults(suiteName: retainedName))
    registered.set(token, forKey: "sentinel")
    retained.set(token, forKey: "sentinel")
    try #require(registered.synchronize())
    try #require(retained.synchronize())
    try #require(try persistedDomain(registeredName) == ["sentinel": token])
    try #require(try persistedDomain(retainedName) == ["sentinel": token])
    try #require(TestDefaultsPurge.register(registeredName))
    try #require(TestDefaultsPurge.isRegistered(registeredName))
    try #require(!TestDefaultsPurge.isRegistered(retainedName))
    try #require(try String(contentsOf: registry, encoding: .utf8) == registeredName + "\n")
    try token.write(to: root.appendingPathComponent("before-entry.txt"), atomically: true, encoding: .utf8)
    FileHandle.standardError.write(Data("LAUNCHER-EXIT-ENTRY token=\(token) registered=\(registeredName) retained=\(retainedName)\n".utf8))
    // Ausschließlich der echte Launcher darf hier den atexit-Hook installieren.
    // Der unbekannte Name führt keine Katalogaktion und keinen App-Start aus.
    SelfTest.runIfRequested()
    Issue.record("Der unbekannte Selbsttest-Name kehrte ohne echten Fehlerexit zurück")
}
