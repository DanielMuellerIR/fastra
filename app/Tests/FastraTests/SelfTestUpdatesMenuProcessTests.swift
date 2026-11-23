import AppKit
import Foundation
import Sparkle
import Testing
@testable import Fastra

@Test("Der echte Updates-Start wartet auf ein korrekt gebundenes Menü und diagnostiziert Fristablauf",
      arguments: ["missing", "wrong-target", "late-target"])
func updatesMenuFailuresUseRealLauncher(_ fixture: String) throws {
    let token = UUID().uuidString
    let root = testTemporaryDirectory()
        .appendingPathComponent("fastra-updates-menu-\(token)", isDirectory: true)
    let suite = "FastraTests.UpdatesMenu.\(UUID().uuidString)"
    try #require(TestDefaultsPurge.register(suite))
    try #require(!FileManager.default.fileExists(atPath: root.path))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    var childrenFinished = true
    defer {
        if childrenFinished {
            // AppKit und benannte Domains sind nicht allein durch HOME isoliert.
            // Nur die eigene UUID-Domain nach bestätigtem Kindende leeren.
            if let defaults = UserDefaults(suiteName: suite) {
                defaults.removePersistentDomain(forName: suite)
                #expect(defaults.synchronize())
            }
            try? FileManager.default.removeItem(at: root)
        } else {
            Issue.record("Kindende nicht bestätigt; Fixture bleibt unter \(root.path), Domain: \(suite)")
        }
    }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let temporary = root.appendingPathComponent("tmp", isDirectory: true)
    for directory in [home.appendingPathComponent("Library/Preferences", isDirectory: true), temporary] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let (executable, arguments) = try filteredUnitTestProcessInvocation("selfTestUpdatesMenuProcessChild")
    childrenFinished = false
    let exited = try runTestProcess(executable, arguments: arguments, environment: [
        "FASTRA_UPDATES_MENU_ROOT": root.path,
        "FASTRA_UPDATES_MENU_TOKEN": token,
        "FASTRA_UPDATES_MENU_FIXTURE": fixture,
        "FASTRA_SELFTEST": "updates",
        "FASTRA_SELFTEST_DEFAULTS_SUITE": suite,
        "FASTRA_SELFTEST_PASTEBOARD_DIR": "",
        "FASTRA_TEST_DEFAULTS_REGISTRY": root.appendingPathComponent("registry.txt").path,
        "HOME": home.path,
        "CFFIXED_USER_HOME": home.path,
        "CFPREFERENCES_AVOID_DAEMON": "1",
        "TMPDIR": temporary.path,
    ], timeout: 30)
    childrenFinished = true
    try #require(exited.status == 1, "Updates-Testkind ohne echten Fehlerexit: \(exited.output)")
    func marker(_ phase: String) -> String {
        "UPDATES-MENU-\(phase) token=\(token) fixture=\(fixture) windows=0 active=false policy=2"
    }
    let markers = ["ENTRY", "SERVICED", fixture == "late-target" ? "READY" : "WAITING"]
    let lines = exited.output.components(separatedBy: "\n")
    for phase in markers {
        try #require(lines.filter { $0 == marker(phase) }.count == 1,
                     "Entry oder bedienter Menüstand fehlt: \(exited.output)")
    }
    let diagnostic: String
    switch fixture {
    case "missing": diagnostic = "Sparkle-Menüpunkt fehlt im echten App-Menü"
    case "wrong-target": diagnostic = "Update-Menüpunkt zielt nicht direkt auf Sparkle"
    default: diagnostic = "Sparkle-Sicherheitskonfiguration im App-Bundle unvollständig"
    }
    let diagnosticPosition = try #require(exited.output.range(of: diagnostic),
                                         "Falsche Menüdiagnose: \(exited.output)")
    let lastMarkerPosition = try #require(exited.output.range(of: marker(markers[2])))
    #expect(lastMarkerPosition.lowerBound < diagnosticPosition.lowerBound)
    #expect(!lines.contains(marker("READY-OVERDUE")), "Fertiges Menü blieb bis zum Fristablauf offen")
    let results = lines.filter { $0.hasPrefix("SELFTEST-RESULT") }
    try #require(results.count == 1, "Genau ein echter Abschluss erwartet: \(exited.output)")
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
        classify_selftest_result updates "$2" ''
        [ -z "$SELFTEST_PROTOCOL_ERROR" ]
        printf '%s\n' "$SELFTEST_RESULT_STATUS"
        """#, "updates-result-parser", parser.path, outputFile.path,
    ], timeout: 10)
    childrenFinished = true
    try #require(parsed.status == 0 && parsed.output == "FAIL\n", "Ungültiger Updates-Abschluss: \(parsed.output)\n\(exited.output)")
    print("UPDATES-MENU-PROBE token=\(token) fixture=\(fixture) child_exit=1 reaped=true result_count=1 status=FAIL windows=0 active=false policy=2")
}

@Test("Gezieltes Testkind für echte Updates-Menüfehler",
      .enabled(if: ProcessInfo.processInfo.environment["FASTRA_UPDATES_MENU_ROOT"] != nil))
@MainActor
func selfTestUpdatesMenuProcessChild() async throws {
    let environment = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(environment["FASTRA_UPDATES_MENU_ROOT"]), isDirectory: true)
    let token = try #require(environment["FASTRA_UPDATES_MENU_TOKEN"])
    let fixture = try #require(environment["FASTRA_UPDATES_MENU_FIXTURE"])
    let suite = try #require(environment["FASTRA_SELFTEST_DEFAULTS_SUITE"])
    try #require(UUID(uuidString: token) != nil && root.lastPathComponent == "fastra-updates-menu-\(token)")
    try #require(["missing", "wrong-target", "late-target"].contains(fixture))
    let prefix = "FastraTests.UpdatesMenu."
    try #require(suite.hasPrefix(prefix) && UUID(uuidString: String(suite.dropFirst(prefix.count))) != nil)
    try #require(environment["FASTRA_SELFTEST"] == "updates")
    try #require(environment["FASTRA_SELFTEST_PASTEBOARD_DIR"] == "")
    try #require(environment["FASTRA_TEST_DEFAULTS_REGISTRY"] == root.appendingPathComponent("registry.txt").path)
    try #require(environment["HOME"] == root.appendingPathComponent("home").path)
    try #require(environment["CFFIXED_USER_HOME"] == root.appendingPathComponent("home").path)
    try #require(environment["TMPDIR"] == root.appendingPathComponent("tmp").path)
    try #require(environment["CFPREFERENCES_AVOID_DAEMON"] == "1")
    try await MainActor.run { try #require(Thread.isMainThread) }
    let app = NSApplication.shared
    try #require(app.activationPolicy() == .prohibited)
    try #require(app.windows.isEmpty && !app.isActive)
    let menu = NSMenu(title: "Updates fixture")
    let appItem = NSMenuItem(title: "Application", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "Application")
    appItem.submenu = submenu
    menu.addItem(appItem)
    app.mainMenu = menu
    let wrongTarget = NSObject()
    let updater: SPUStandardUpdaterController?
    if fixture == "late-target" {
        try #require(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil)
        updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    } else {
        updater = nil
    }
    func marker(_ phase: String) {
        FileHandle.standardError.write(Data("UPDATES-MENU-\(phase) token=\(token) fixture=\(fixture) windows=\(app.windows.count) active=\(app.isActive) policy=\(app.activationPolicy().rawValue)\n".utf8))
    }
    marker("ENTRY")
    // Erst nach Rückkehr des echten Starts liefert Main den endgültigen Menüstand.
    // Ohne dessen Warteschleife fehlen dieser Marker und die zweite Diagnose.
    DispatchQueue.main.async {
        if fixture != "missing" {
            let item = NSMenuItem(title: "Check for Updates", action: NSSelectorFromString("checkForUpdates:"), keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("Fastra.CheckForUpdates")
            item.target = wrongTarget
            submenu.addItem(item)
        }
        marker("SERVICED")
        if let updater {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
                submenu.removeAllItems()
                submenu.addItem(AppDelegate.makeUpdateMenuItem(target: updater))
                marker("READY")
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3)) {
                    marker("READY-OVERDUE")
                }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(4)) {
                marker("WAITING")
            }
        }
    }
    // NSMenuItem hält sein Target schwach; bis zum echten Abschluss muss es leben.
    defer { withExtendedLifetime((menu, submenu, wrongTarget, updater)) {} }
    SelfTest.runIfRequested()
    // Den Main-Executor für die echte private Polling-Schleife freigeben.
    try await Task.sleep(for: .seconds(15))
    Issue.record("Der echte Updates-Start lieferte keinen Prozessabschluss")
}
