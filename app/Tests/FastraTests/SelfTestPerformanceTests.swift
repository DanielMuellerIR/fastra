import Foundation
import Darwin
import Testing
@testable import Fastra

private let performanceToolsDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // FastraTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // app
    .appendingPathComponent("tools")

private struct PerformanceToolResult {
    let status: Int32
    let output: String
}

private func runPerformanceTool(_ executable: String,
                                arguments: [String],
                                environment: [String: String]? = nil) throws
    -> PerformanceToolResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment {
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment, uniquingKeysWith: { _, new in new }
        )
    }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return PerformanceToolResult(
        status: process.terminationStatus,
        output: String(decoding: data, as: UTF8.self)
    )
}

@Suite("Lokale Selbsttest-Performance", .serialized)
struct SelfTestPerformanceTests {
    @Test("Messdatei ist atomar, begrenzt und ignoriert unqualifizierte Läufe")
    func performanceStorageSelfTest() throws {
        let script = performanceToolsDirectory
            .appendingPathComponent("selftest-performance.py")
        let result = try runPerformanceTool(
            "/usr/bin/python3", arguments: [script.path, "self-test"]
        )
        #expect(result.status == 0)
        #expect(result.output.contains("PERFORMANCE-SELFTEST PASS"))
    }

    @Test("Fenster-Sperre blockiert Parallelbetrieb und übernimmt tote Besitzer")
    func guiLockSerializesAcrossRunners() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-gui-lock-test-\(UUID().uuidString)")
        let release = directory.appendingPathExtension("release")
        let script = performanceToolsDirectory.appendingPathComponent("gui-test-lock.sh")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: release)
        }

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/bash")
        holder.arguments = [
            "-c",
            ". \"$1\"; FASTRA_GUI_LOCK_DIR=\"$2\"; "
                + "acquire_fastra_gui_test_lock || exit $?; "
                + "while [ ! -e \"$3\" ]; do sleep 0.01; done; "
                + "release_fastra_gui_test_lock",
            "lock-holder", script.path, directory.path, release.path,
        ]
        holder.standardOutput = FileHandle.nullDevice
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        defer {
            if holder.isRunning {
                try? Data().write(to: release)
                holder.terminate()
                holder.waitUntilExit()
            }
        }

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("pid").path
        ), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("pid").path
        ))

        let contender = try runPerformanceTool(
            "/bin/bash",
            arguments: [
                "-c",
                ". \"$1\"; FASTRA_GUI_LOCK_DIR=\"$2\"; "
                    + "acquire_fastra_gui_test_lock",
                "lock-contender", script.path, directory.path,
            ]
        )
        #expect(contender.status == 2)
        #expect(contender.output.contains("läuft bereits"))
        try Data().write(to: release)
        holder.waitUntilExit()
        #expect(holder.terminationStatus == 0)
        try? FileManager.default.removeItem(at: release)

        // Das atomare mkdir geschieht knapp vor dem Schreiben der PID. Ein
        // Mitbewerber darf diese frische, noch unvollständige Sperre nicht
        // irrtümlich als verwaist entfernen.
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: false)
        let acquiring = try runPerformanceTool(
            "/bin/bash",
            arguments: [
                "-c",
                ". \"$1\"; FASTRA_GUI_LOCK_DIR=\"$2\"; "
                    + "acquire_fastra_gui_test_lock",
                "lock-acquiring", script.path, directory.path,
            ]
        )
        #expect(acquiring.status == 2)
        #expect(acquiring.output.contains("wird gerade eingerichtet"))
        #expect(FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.removeItem(at: directory)

        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: false)
        try "999999\n".write(
            to: directory.appendingPathComponent("pid"),
            atomically: true,
            encoding: .utf8
        )
        let recovery = try runPerformanceTool(
            "/bin/bash",
            arguments: [
                "-c",
                ". \"$1\"; FASTRA_GUI_LOCK_DIR=\"$2\"; "
                    + "acquire_fastra_gui_test_lock && release_fastra_gui_test_lock",
                "lock-recovery", script.path, directory.path,
            ]
        )
        #expect(recovery.status == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Abgewiesener Runner beendet den Prozess des Sperrenbesitzers nicht")
    func rejectedRunnerDoesNotKillLockOwnersApp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-runner-lock-test-\(UUID().uuidString)")
        let lock = root.appendingPathComponent("runner.lock")
        let fakeApp = root.appendingPathComponent("Fastra")
        let childPID = root.appendingPathComponent("child.pid")
        let release = root.appendingPathComponent("release")
        let lockScript = performanceToolsDirectory.appendingPathComponent("gui-test-lock.sh")
        let runner = performanceToolsDirectory.deletingLastPathComponent()
            .appendingPathComponent("selftest.sh")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        try "#!/bin/bash\nexec sleep 30\n".write(to: fakeApp, atomically: true,
                                              encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeApp.path
        )

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/bash")
        holder.arguments = [
            "-c",
            ". \"$1\"; FASTRA_GUI_LOCK_DIR=\"$2\"; "
                + "acquire_fastra_gui_test_lock || exit $?; "
                + "\"$3\" & child=$!; printf '%s\\n' \"$child\" > \"$4\"; "
                + "while [ ! -e \"$5\" ]; do sleep 0.01; done; "
                + "kill \"$child\" 2>/dev/null || true; "
                + "wait \"$child\" 2>/dev/null || true; "
                + "release_fastra_gui_test_lock",
            "runner-holder", lockScript.path, lock.path, fakeApp.path, childPID.path,
            release.path,
        ]
        holder.standardOutput = FileHandle.nullDevice
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        defer {
            if holder.isRunning {
                try? Data().write(to: release)
                holder.terminate()
                holder.waitUntilExit()
            }
        }

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: childPID.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let pidText = try String(contentsOf: childPID, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(pidText))

        let contender = try runPerformanceTool(
            "/bin/bash",
            arguments: [runner.path, "search"],
            environment: [
                "FASTRA_GUI_LOCK_DIR": lock.path,
                "FASTRA_SELFTEST_APP_BIN": fakeApp.path,
            ]
        )
        #expect(contender.status == 2)
        #expect(kill(pid, 0) == 0)
        try Data().write(to: release)
        holder.waitUntilExit()
        #expect(holder.terminationStatus == 0)
    }
}
