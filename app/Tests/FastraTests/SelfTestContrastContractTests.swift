// Der vollständige asynchrone Einstieg läuft in einem Kindprozess, weil sein
// Abschluss Never liefert. Die Fenster sind nur logisch sichtbar: keine
// Fensterordnung, Fokusänderung oder Aussage über tatsächlich gerenderte Pixel.
import Foundation
import Testing

@Test("Kontrastprüfung verlangt messbare Such- und Hauptfenstergruppen")
func contrastWindowContractSerialRunnerIntegration() throws {
    let directory = testTemporaryDirectory().appendingPathComponent("contrast-contract-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = #"""
        import AppKit
        import Darwin

        enum SearchWindow { static let frameAutosaveName = "contrast-fixture-search" }
        extension Notification.Name {
            static let fastraShowSearchFile = Notification.Name("contrast-fixture-show-search")
        }
        final class LogicalWindow: NSWindow {
            var role = "main"
            var logicallyVisible = true
            override var frameAutosaveName: String { role }
            override var isVisible: Bool { logicallyVisible }
        }
        @main struct ContrastProcess {
            @MainActor static func main() {
                NSApplication.shared.setActivationPolicy(.prohibited)
                let mode = CommandLine.arguments[1]
                func window(search: Bool) -> LogicalWindow {
                    let window = LogicalWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    window.role = search ? SearchWindow.frameAutosaveName : "main"
                    window.backgroundColor = .white
                    let field = NSTextField(labelWithString: search ? "search-text" : "main-text")
                    field.textColor = .black
                    if !search && mode.hasPrefix("hidden-first-") {
                        field.drawsBackground = true
                        field.backgroundColor = .white
                    }
                    if search && mode == "hidden-first-low" { field.textColor = .white }
                    field.frame = NSRect(x: 10, y: 10, width: 200, height: 20)
                    window.contentView?.addSubview(field)
                    if mode == (search ? "search-empty" : "main-empty") { field.stringValue = "" }
                    if mode == (search ? "search-hidden-field" : "main-hidden-field") { field.isHidden = true }
                    if mode == (search ? "search-hidden-window" : "main-hidden-window") {
                        window.logicallyVisible = false
                    }
                    if mode == (search ? "search-env" : "main-env")
                        || mode == (search ? "fail-main-env-search" : "fail-search-env-main") {
                        field.textColor = NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))
                    }
                    if mode == (search ? "fail-search-env-main" : "fail-main-env-search") {
                        field.textColor = .white
                    }
                    return window
                }
                var windows: [NSWindow] = []
                if mode.hasPrefix("hidden-first-") {
                    let hiddenSearch = window(search: true)
                    hiddenSearch.logicallyVisible = false
                    hiddenSearch.backgroundColor = .black
                    windows.append(hiddenSearch)
                }
                if mode != "main-only" { windows.append(window(search: true)) }
                if mode != "search-only" { windows.append(window(search: false)) }
                let start = Date()
                SelfTestContrast(windows: { windows }, finish: { outcome, message in
                    let result: [String: Any] = ["status": outcome.protocolStatus, "message": message,
                        "elapsed": Date().timeIntervalSince(start)]
                    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data([10]))
                    exit(outcome == .pass ? 0 : outcome == .environment ? 2 : 1)
                }).runContrastTest()
                RunLoop.main.run()
            }
        }
        """#
    let script = directory.appendingPathComponent("fixture.swift")
    let binary = directory.appendingPathComponent("fixture")
    try fixture.write(to: script, atomically: true, encoding: .utf8)
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Fastra")
    let compiler = try runTestProcess("/usr/bin/xcrun", arguments: [
        "swiftc", "-swift-version", "5", "-module-cache-path", directory.appendingPathComponent("cache").path,
        sources.appendingPathComponent("SelfTestContrast.swift").path,
        sources.appendingPathComponent("SelfTestCompletion.swift").path,
        script.path, "-o", binary.path
    ], timeout: 120)
    try #require(compiler.status == 0, Comment(rawValue: compiler.output))
    let cases: [(String, String)] = [
        ("main-only", "FAIL"), ("search-only", "FAIL"), ("healthy", "PASS"),
        ("search-empty", "FAIL"), ("main-empty", "FAIL"),
        ("search-hidden-field", "FAIL"), ("main-hidden-field", "FAIL"),
        ("search-hidden-window", "FAIL"), ("main-hidden-window", "FAIL"),
        ("search-env", "ENV"), ("main-env", "ENV"),
        ("fail-main-env-search", "FAIL"), ("fail-search-env-main", "FAIL"),
        ("hidden-first-low", "FAIL"), ("hidden-first-readable", "PASS")
    ]
    for (mode, expected) in cases {
        let process = try runTestProcess(binary.path, arguments: [mode], timeout: 10)
        print("CONTRAST-CONTRACT \(mode): \(process.output)")
        let line = try #require(process.output.split(separator: "\n").first { $0.hasPrefix("{") })
        let result = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(result["status"] as? String == expected, Comment(rawValue: "\(mode): \(process.output)"))
        #expect(process.status == (expected == "PASS" ? 0 : expected == "ENV" ? 2 : 1))
        #expect((result["elapsed"] as? Double ?? 0) >= 1.0)
        let message = try #require(result["message"] as? String)
        #expect(message.contains("Suchfenster") && message.contains("Hauptfenster"))
        if mode.hasPrefix("fail-") {
            #expect(message.contains("contrast=1.00"), Comment(rawValue: message))
            #expect(message.contains("nicht nach sRGB konvertierbar"), Comment(rawValue: message))
        }
    }
}
