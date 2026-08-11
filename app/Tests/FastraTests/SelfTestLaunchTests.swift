// SelfTestLaunchTests.swift
//
// Prüft die früh gesetzten, rein prozesslokalen UI-Fixtures der Shot-Tests.

import Foundation
import Testing
@testable import Fastra

@Test("Gitshot setzt die Änderungen-Sidebar vor dem Fensteraufbau")
func gitShot_preparesChangesSidebarEnvironment() {
    var captured: [(String, String)] = []
    SelfTest.prepareLaunchEnvironment(requestedTest: "gitshot") { key, value in
        captured.append((key, value))
    }

    #expect(captured.count == 1)
    #expect(captured.first?.0 == "FASTRA_SIDEBAR")
    #expect(captured.first?.1 == "changes")
}

@Test("Ordner-Staging-Test setzt die Änderungen-Sidebar vor dem Fensteraufbau")
func gitStageFolder_preparesChangesSidebarEnvironment() {
    var captured: [(String, String)] = []
    SelfTest.prepareLaunchEnvironment(requestedTest: "gitstagefolder") { key, value in
        captured.append((key, value))
    }

    #expect(captured.count == 1)
    #expect(captured.first?.0 == "FASTRA_SIDEBAR")
    #expect(captured.first?.1 == "changes")
}

@Test("Push-Ziel-Test setzt die Änderungen-Sidebar vor dem Fensteraufbau")
func gitPushButton_preparesChangesSidebarEnvironment() {
    var captured: [(String, String)] = []
    SelfTest.prepareLaunchEnvironment(requestedTest: "gitpushbutton") { key, value in
        captured.append((key, value))
    }

    #expect(captured.count == 1)
    #expect(captured.first?.0 == "FASTRA_SIDEBAR")
    #expect(captured.first?.1 == "changes")
}

@Test("Normale Starts setzen keine Shot-Sidebar")
func normalLaunch_doesNotPrepareSidebarEnvironment() {
    var captured: [(String, String)] = []
    SelfTest.prepareLaunchEnvironment(requestedTest: nil) { key, value in
        captured.append((key, value))
    }

    #expect(captured.isEmpty)
}

private func runSelfTestRunner(arguments: [String], environment: [String: String]) async
    throws -> Int32 {
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("selftest.sh")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [script.path] + arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) {
        _, new in new
    }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    return try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { process in
            continuation.resume(returning: process.terminationStatus)
        }
        do { try process.run() } catch { continuation.resume(throwing: error) }
    }
}

@Test("Fehlendes Selbsttest-Binary ist ein Umgebungsfehler")
func selfTestRunner_missingBinaryExitsTwo() async throws {
    let status = try await runSelfTestRunner(
        arguments: ["search"],
        environment: ["FASTRA_SELFTEST_APP_BIN": "/definitely/missing/Fastra"])
    #expect(status == 2)
}

@Test("LaunchServices-Test verlangt ein wirklich vorhandenes App-Bundle")
func selfTestRunner_launchServicesValidatesBundle() async throws {
    let status = try await runSelfTestRunner(
        arguments: ["coldopen"],
        environment: [
            "FASTRA_SELFTEST_APP_BIN": "/usr/bin/true",
            "FASTRA_SELFTEST_APP_BUNDLE": "/definitely/missing/Fastra.app",
        ])
    #expect(status == 2)
}
