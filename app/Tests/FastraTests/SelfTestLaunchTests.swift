// SelfTestLaunchTests.swift
//
// Prüft die früh gesetzten, rein prozesslokalen UI-Fixtures der Shot-Tests.

import Foundation
import Testing
@testable import Fastra

@Test("Git-Selbsttests wählen die Änderungen-Sidebar",
      arguments: ["gitshot", "gitstagefolder", "gitpushbutton", "gitmultidiscard", "gitstickyheader", "gitstickyshot"])
func gitLaunch_preparesChangesSidebarEnvironment(_ name: String) {
    var captured: [(String, String)] = []
    SelfTest.prepareLaunchEnvironment(requestedTest: name) { key, value in
        captured.append((key, value))
    }
    #expect(captured.count == 1)
    #expect(captured.first?.0 == "FASTRA_SIDEBAR")
    #expect(captured.first?.1 == "changes")
}

@Test("Normale und andere Selbsttest-Starts setzen keine Shot-Sidebar",
      arguments: [nil, "search", "unknown"] as [String?])
func normalLaunch_doesNotPrepareSidebarEnvironment(_ name: String?) {
    var captured: [(String, String)] = []
    SelfTest.prepareLaunchEnvironment(requestedTest: name) { key, value in
        captured.append((key, value))
    }
    #expect(captured.isEmpty)
}

private func runSelfTestRunner(arguments: [String], environment: [String: String]) throws -> TestProcessResult {
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("selftest.sh")
    return try runTestProcess("/bin/bash", arguments: [script.path] + arguments,
                              environment: environment, timeout: 5)
}

@Test("Fehlendes Selbsttest-Binary ist ein Umgebungsfehler")
func selfTestRunner_missingBinaryExitsTwo() throws {
    let result = try runSelfTestRunner(
        arguments: ["search"],
        environment: ["FASTRA_SELFTEST_APP_BIN": "/definitely/missing/Fastra"])
    #expect(result.status == 2, "Runner-Diagnose: \(result.output)")
    #expect(result.output.contains("Kein Debug-Build gefunden (/definitely/missing/Fastra)"))
}

@Test("LaunchServices-Test verlangt ein wirklich vorhandenes App-Bundle")
func selfTestRunner_launchServicesValidatesBundle() throws {
    let result = try runSelfTestRunner(
        arguments: ["coldopen"],
        environment: [
            "FASTRA_SELFTEST_APP_BIN": "/usr/bin/true",
            "FASTRA_SELFTEST_APP_BUNDLE": "/definitely/missing/Fastra.app",
        ])
    #expect(result.status == 2, "Runner-Diagnose: \(result.output)")
    #expect(result.output.contains("LaunchServices-Test verlangt ein gültiges Fastra-Bundle"))
    #expect(result.output.contains("/definitely/missing/Fastra.app"))
}
