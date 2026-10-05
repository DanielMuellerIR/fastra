import AppKit
import Foundation
import Testing
import FastraControlProtocol
@testable import Fastra

/// Separat filtern: fremde MainActor-Tests würden dieselbe Tick-Lücke erzeugen.
@Suite("Lokale Snapshot-Steuerung: Main-Thread", .serialized)
@MainActor
struct LocalControlResponsivenessTests {
    @Test("Snapshot an der Größenobergrenze bleibt beim Sprung zum EOF bedienbar",
          .enabled(if: ProcessInfo.processInfo.environment["FASTRA_CONTROL_HEARTBEAT"] == "1"),
          arguments: [false, true])
    func boundedSnapshotHeartbeat(singleLogicalLine: Bool) async throws {
        _ = NSApplication.shared
        let url = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        let line = "one two three four\n"
        let repeated = String(repeating: line, count: ControlProtocol.maximumSnapshotBytes / line.utf8.count)
        let text = singleLogicalLine ? repeated.replacingOccurrences(of: "\n", with: " ") : repeated
        let bytes = Data(text.utf8)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = LocalControlController(showWindows: false)
        var lastTick = ProcessInfo.processInfo.systemUptime
        var maximumGap = 0.0
        var ticks = 0
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            maximumGap = max(maximumGap, now - lastTick)
            lastTick = now; ticks += 1
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        let request = ControlRequest(operation: "snapshot", path: url.path,
                                     sha256: FileSnapshot.sha256Hex(bytes), location: text.utf16.count, length: 0)
        let job = try #require(controller.execute(request).job)
        defer { _ = try? controller.execute(ControlRequest(operation: "close", sessionID: job.sessionID)) }
        for _ in 0..<200 {
            let report = try #require(controller.execute(ControlRequest(operation: "status", jobID: job.id)).job)
            if report.isTerminal {
                print("CONTROL_HEARTBEAT bytes=\(bytes.count) singleLogicalLine=\(singleLogicalLine) interval_ms=10 max_gap_ms=\(maximumGap * 1000) ticks=\(ticks)")
                #expect(report.state == "ready")
                #expect(ticks >= 3)
                #expect(maximumGap < 0.250, "größte Main-Thread-Tick-Lücke: \(maximumGap) s bei \(bytes.count) Bytes")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Snapshot erreichte keinen Endzustand")
    }
}
