import AppKit
import Foundation
import CodeEditTextView
import FastraControlProtocol

/// Nur der externe Integrationstest startet diesen Host. Fixtures und Marker
/// liegen in seiner eigenen Sandbox; der produktive Steuerungsvertrag enthält
/// keine Test- oder Schreiboperation.
@MainActor
enum ControlTestHost {
    private struct FixtureState: Equatable {
        let documentIDs: [UUID]
        let contents: [String]
        let dirty: [Bool]
        let activeTabID: UUID?
        let projectPath: String?
        let selection: NSRange
        let frame: NSRect
    }
    private static var fixtures: [(Workspace, NSWindow, FixtureState)] = []
    private static var defaultsBefore: NSDictionary = [:]
    private static var preferencesBefore: NSDictionary = [:]
    private static var root: URL?
    private static var finished = false
    private static var capturedToken = ""
    private static var playerToken = ""
    private static var checkedResult: Bool?
    private static var hardDeadline: TimeInterval = 0
    private static var completion: ((Bool) -> Void)?

    static func start(deadline: TimeInterval, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        hardDeadline = deadline
        guard let directory = ProcessInfo.processInfo.environment["FASTRA_CONTROL_HOST_DIR"],
              let first = CommandTargeting.targetWorkspace() else { completion(false); return }
        root = URL(fileURLWithPath: directory, isDirectory: true)
        let state = RestorableWindowState(projectPath: nil, documentPaths: [], activeDocumentPath: nil, frame: nil)
        let second = DocumentWindowController.openRestoredDocument(state, defaults: SelfTest.workspaceDefaults())
        for (index, workspace) in [first, second].enumerated() {
            let tab = EditorTab(title: "Unsaved fixture \(index)", path: "", content: "private unsaved \(index)\nsecond line\n", isDirty: true)
            workspace.tabs = [tab]; workspace.activeTabID = tab.id
            workspace.projectURL = root
        }
        collectWhenMounted([first, second], attempts: 100)
    }

    private static func state(_ workspace: Workspace, window: NSWindow) -> FixtureState? {
        guard let editor = CommandTargeting.editorTextView(for: workspace),
              editor.string == workspace.activeTab?.content else { return nil }
        return FixtureState(documentIDs: workspace.tabs.map(\.documentID), contents: workspace.tabs.map(\.content),
                            dirty: workspace.tabs.map(\.isDirty), activeTabID: workspace.activeTabID,
                            projectPath: workspace.projectURL?.path, selection: editor.fastraSafeSelectedRange,
                            frame: window.frame)
    }

    private static func collectWhenMounted(_ workspaces: [Workspace], attempts: Int) {
        let mounted = workspaces.compactMap { workspace -> (Workspace, NSWindow, FixtureState)? in
            guard let window = CommandTargeting.registeredWindow(for: workspace),
                  let editor = CommandTargeting.editorTextView(for: workspace) else { return nil }
            // Eine echte Nutzerauswahl ist Teil der geschützten Ausgangslage.
            editor.selectionManager.setSelectedRange(NSRange(location: 2, length: 5))
            guard let snapshot = state(workspace, window: window) else { return nil }
            return (workspace, window, snapshot)
        }
        guard mounted.count == workspaces.count else {
            guard attempts > 0 else {
                write("failed", "normal fixture editors did not mount")
                finished = true
                completion?(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { collectWhenMounted(workspaces, attempts: attempts - 1) }
            return
        }
        // SwiftUI darf noch einen Folge-Durchlauf reconciliieren, bevor wir
        // die Ausgangslage festhalten und dem externen Sender ready melden.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            fixtures = mounted.compactMap { workspace, window, _ in
                state(workspace, window: window).map { (workspace, window, $0) }
            }
            defaultsBefore = SelfTest.workspaceDefaults().dictionaryRepresentation() as NSDictionary
            preferencesBefore = preferencesState()
            let binding: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                           "runtimeID": LocalControlController.shared.runtimeID.uuidString]
            if let data = try? JSONSerialization.data(withJSONObject: binding) {
                try? data.write(to: root!.appendingPathComponent("host-binding"), options: .atomic)
            }
            write("ready", "normalWindows=2 dirty=true selections=true")
            poll()
        }
    }

    private static func write(_ file: String, _ message: String) {
        guard let root else { return }
        try? message.write(to: root.appendingPathComponent("host-" + file), atomically: true, encoding: .utf8)
    }

    private static func poll() {
        guard !finished, let root else { return }
        guard ProcessInfo.processInfo.systemUptime < hardDeadline else {
            finished = true
            write("failed", "external control test exceeded its deadline")
            completion?(false)
            return
        }
        if let token = try? String(contentsOf: root.appendingPathComponent("host-capture")),
           !token.isEmpty, token != capturedToken {
            capturedToken = token
            capture(stage: token)
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("host-player")),
           let command = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let token = command["token"], token != playerToken {
            playerToken = token
            playerAction(command)
        }
        if checkedResult == nil, FileManager.default.fileExists(atPath: root.appendingPathComponent("host-check").path) {
            var errors: [String] = []
            for (workspace, window, before) in fixtures {
                if state(workspace, window: window) != before { errors.append("normal window state changed") }
            }
            if preferencesState() != preferencesBefore {
                errors.append("global test preferences changed")
                let after = SelfTest.workspaceDefaults().dictionaryRepresentation() as NSDictionary
                let keys = Set(defaultsBefore.allKeys.compactMap { $0 as? String })
                    .union(after.allKeys.compactMap { $0 as? String })
                let changes = keys.sorted().filter { key in
                    !NSDictionary(dictionary: ["value": defaultsBefore[key] ?? NSNull()])
                        .isEqual(to: ["value": after[key] ?? NSNull()])
                }.map { key in ["key": key, "before": String(describing: defaultsBefore[key]),
                                "after": String(describing: after[key])] }
                if let data = try? JSONSerialization.data(withJSONObject: changes, options: [.sortedKeys]) {
                    try? data.write(to: root.appendingPathComponent("host-preferences-diff.json"), options: .atomic)
                }
            }
            if fixtures.count != 2 { errors.append("two mounted fixture windows required") }
            write("result", errors.isEmpty ? "PASS normalWindows=2 dirty/content/selection/project/frame/preferences=unchanged" : "FAIL " + errors.joined(separator: "; "))
            checkedResult = errors.isEmpty
        }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("host-finish").path) {
            finished = true
            completion?(checkedResult == true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
    }

    static func preferencesState(defaults: UserDefaults = SelfTest.workspaceDefaults(),
                                 domains: [String]? = nil) -> NSDictionary {
        let names = domains ?? [ProcessInfo.processInfo.environment["FASTRA_SELFTEST_DEFAULTS_SUITE"],
                               Bundle.main.bundleIdentifier, UserDefaults.globalDomain].compactMap { $0 }
        var persistent: [String: Any] = [:]
        for name in names { persistent[name] = defaults.persistentDomain(forName: name) ?? [:] }
        var effective = defaults.dictionaryRepresentation()
        var registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        registered.merge(defaults.volatileDomain(forName: UserDefaults.registrationDomain)) { _, value in value }
        // Metal/AppKit registrieren diese Werte erst beim ersten Zeichnen.
        // Nur identische Registrierungswerte aus der wirksamen Sicht entfernen;
        // jede persistente Änderung bleibt durch den vollständigen Vergleich erfasst.
        for key in ["METAL_DEBUG_ERROR_MODE", "METAL_ERROR_CHECK_EXTENDED_MODE", "METAL_ERROR_MODE",
                    "METAL_WARNING_MODE", "NSVisualBidiSelectionEnabled"] {
            if let value = registered[key], let current = effective[key],
               NSDictionary(dictionary: ["value": value]).isEqual(to: ["value": current]) {
                effective.removeValue(forKey: key)
            }
        }
        return NSDictionary(dictionary: ["persistent": persistent, "effective": effective])
    }

    private static func playerAction(_ command: [String: String]) {
        guard let sessionID = command["sessionID"],
              let snapshot = LocalControlController.shared.snapshotWindowsForTesting.first(where: { $0.sessionID.uuidString == sessionID }),
              let player = snapshot.explanationPlayer else { write("player-result", "FAIL missing player"); return }
        func button(in view: NSView, id: String) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityIdentifier() == id { return button }
            for child in view.subviews { if let found = button(in: child, id: id) { return found } }
            return nil
        }
        switch command["action"] {
        case "next": player.next.performClick(nil)
        case "previous": player.previous.performClick(nil)
        case "pause": player.pauseButton.performClick(nil)
        case "return": player.returnButton.performClick(nil)
        case "fonts":
            button(in: player.footer, id: "explanationCodeLarger")?.performClick(nil)
            button(in: player.footer, id: "explanationTextSmaller")?.performClick(nil)
        case "wrap": button(in: player.footer, id: "explanationSoftWrap")?.performClick(nil)
        case "grow":
            if let view = snapshot.window.contentView {
                snapshot.window.setContentSize(NSSize(width: view.bounds.width, height: view.bounds.height + 160))
                view.layoutSubtreeIfNeeded()
            }
        case "split":
            if let split = snapshot.window.contentView?.subviews.compactMap({ $0 as? NSSplitView }).first {
                split.setPosition(max(120, split.arrangedSubviews[0].frame.height - 60), ofDividerAt: 0)
                split.layoutSubtreeIfNeeded()
            }
        case "explore": snapshot.textView.setSelectedRange(NSRange(location: 0, length: 0))
        case "end": player.end.performClick(nil)
        default: break
        }
        let result: [String: Any] = ["token": command["token"] ?? "", "state": player.state,
            "step": player.index, "codeFontSize": player.codeFontSize, "explanationFontSize": player.explanationFontSize,
            "documentID": snapshot.documentID.uuidString, "selectionLocation": snapshot.textView.selectedRange().location,
            "selectionLength": snapshot.textView.selectedRange().length, "content": snapshot.textView.string,
            "editable": snapshot.textView.isEditable,
            "wrapped": snapshot.textView.textContainer?.widthTracksTextView ?? false,
            "horizontalScroller": snapshot.textView.enclosingScrollView?.hasHorizontalScroller ?? false,
            "codeHeight": snapshot.textView.enclosingScrollView?.frame.height ?? 0,
            "explanationHeight": player.view.frame.height]
        if let data = try? JSONSerialization.data(withJSONObject: result),
           let text = String(data: data, encoding: .utf8) { write("player-result", text) }
    }

    private static func capture(stage: String) {
        guard let directory = ProcessInfo.processInfo.environment["FASTRA_CONTROL_SCREENSHOTS"],
              let snapshot = LocalControlController.shared.snapshotWindowsForTesting.first,
              let view = snapshot.window.contentView else { write("captured", "SKIP no screenshots requested"); return }
        let language = ProcessInfo.processInfo.environment["FASTRA_CONTROL_TEST_LANGUAGE"] ?? "default"
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let height = stage.hasPrefix("explanation-expanded") ? view.bounds.height
                : (snapshot.explanationPlayer == nil ? 450 : 650)
            for width in [400, 900] {
                snapshot.window.setContentSize(NSSize(width: CGFloat(width), height: height))
                view.layoutSubtreeIfNeeded()
                snapshot.textView.scrollRangeToVisible(snapshot.textView.selectedRange())
                snapshot.window.displayIfNeeded()
                // NSView-Caching enthält transparente Fensterflächen. Den
                // echten Theme-Frame aufnehmen und mit der aufgelösten
                // Fensterfarbe unterlegen, statt Transparenz schwarz zu zeigen.
                let frame = view.superview ?? view
                guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
                    throw ControlFailure.source
                }
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                let image = NSImage(size: frame.bounds.size)
                image.lockFocus()
                frame.effectiveAppearance.performAsCurrentDrawingAppearance {
                    snapshot.window.backgroundColor.setFill()
                    NSRect(origin: .zero, size: frame.bounds.size).fill()
                    bitmap.draw(in: NSRect(origin: .zero, size: frame.bounds.size))
                }
                image.unlockFocus()
                guard let tiff = image.tiffRepresentation,
                      let composed = NSBitmapImageRep(data: tiff),
                      let data = composed.representation(using: .png, properties: [:]) else { throw ControlFailure.source }
                let filename = stage.hasPrefix("explanation") ? "\(stage).\(language).\(width).png"
                    : (stage == "failure" ? "snapshot.\(language).failure.\(width).png" : "snapshot.\(language).\(width).png")
                try data.write(to: destination.appendingPathComponent(filename))
            }
            write("captured", "PASS token=\(stage) language=\(language) caption=\(L10n.string("Schreibgeschützter Snapshot")) widths=400,900")
        } catch { write("captured", "FAIL token=\(stage) screenshot capture") }
    }
}
