import AppKit
import Foundation
import Testing
import FastraControlProtocol
@testable import Fastra

struct ExplanationFixture {
    let root: URL
    let manifest: URL
    init() throws {
        root = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        manifest = root.appendingPathComponent("explanation.json")
        let sources = try ["one\r\n😀 two\n", "other\nlast\n"].enumerated().map { index, text in
            let path = "source\(index).txt", bytes = Data(text.utf8)
            try bytes.write(to: root.appendingPathComponent(path))
            return CodeExplanationManifest.Source(id: UUID(), path: path, sha256: FileSnapshot.sha256Hex(bytes), encoding: "utf8")
        }
        let steps = sources.enumerated().map { index, source in
            CodeExplanationManifest.Step(id: UUID(), title: "Step \(index)", text: "Saved explanation \(index)",
                sourceID: source.id, location: index == 0 ? 5 : 0, length: index == 0 ? 2 : 5)
        }
        let value = CodeExplanationManifest(schemaVersion: 1, id: UUID(), title: "Code question", question: "How does this work?",
            language: "en", createdAt: "2026-10-04T18:00:00+02:00", projectID: UUID(), projectName: "Fixture",
            sources: sources, steps: steps, codeFontSize: 13, explanationFontSize: 14)
        try JSONEncoder().encode(value).write(to: manifest)
    }
    func change(_ edit: (inout [String: Any]) -> Void) throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        edit(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: manifest)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Gespeicherte Code-Erklärung: Quellen und Paketgrenzen")
struct CodeExplanationPackageTests {
    @Test("UTF-8-Vertrag weist Nullbytes und fremde BOMs trotz passendem Hash ab")
    func strictText() throws {
        let fixture = try ExplanationFixture(); defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.manifest)
        for bytes in [Data([0, 1, 2]), Data([0xFF, 0xFE, 65, 0, 66, 0]),
                      Data([0xFE, 0xFF, 0, 65]), Data(repeating: 65, count: 9000) + Data([0]),
                      Data([0xC3, 0x28])] {
            try original.write(to: fixture.manifest)
            try bytes.write(to: fixture.root.appendingPathComponent("source0.txt"))
            try fixture.change {
                var sources = $0["sources"] as! [[String: Any]]
                sources[0]["sha256"] = FileSnapshot.sha256Hex(bytes); $0["sources"] = sources
            }
            #expect(throws: ControlFailure.source) { try CodeExplanationPackage.load(path: fixture.manifest.path) }
        }
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("one\r\n😀 two\n".utf8)
        try original.write(to: fixture.manifest)
        try bytes.write(to: fixture.root.appendingPathComponent("source0.txt"))
        try fixture.change {
            var sources = $0["sources"] as! [[String: Any]]
            sources[0]["sha256"] = FileSnapshot.sha256Hex(bytes); $0["sources"] = sources
        }
        #expect(try CodeExplanationPackage.load(path: fixture.manifest.path).loadedSources.values.contains {
            $0.content == "one\r\n😀 two\n" && $0.bom == Data([0xEF, 0xBB, 0xBF])
        })
    }
    @Test("Hashabweichung, ungültiges Schema und Graphemgrenze werden abgewiesen")
    func invalid() throws {
        let fixture = try ExplanationFixture(); defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.manifest)
        let valid = try CodeExplanationPackage.load(path: fixture.manifest.path)
        #expect(valid.loadedSources.count == 2)
        try Data("changed".utf8).write(to: fixture.root.appendingPathComponent("source0.txt"))
        #expect(throws: ControlFailure.stale) { try CodeExplanationPackage.load(path: fixture.manifest.path) }
        try Data("one\r\n😀 two\n".utf8).write(to: fixture.root.appendingPathComponent("source0.txt"))
        for edit: (inout [String: Any]) -> Void in [
            { $0["execute"] = "command" }, { $0["schemaVersion"] = 2 }, { $0["codeFontSize"] = 100 },
            { var steps = $0["steps"] as! [[String: Any]]; steps[0]["location"] = 6; $0["steps"] = steps }
        ] {
            try original.write(to: fixture.manifest); try fixture.change(edit)
            #expect(throws: (any Error).self) { try CodeExplanationPackage.load(path: fixture.manifest.path) }
        }
    }
    @Test("Ausbruch, Symlink, FIFO und fehlende Quelle werden nicht gelesen")
    func paths() throws {
        let fixture = try ExplanationFixture(); defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.manifest)
        let link = fixture.root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root.appendingPathComponent("source0.txt"))
        let nested = fixture.root.appendingPathComponent("nested")
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: fixture.root)
        let rootLink = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: fixture.root)
        defer { try? FileManager.default.removeItem(at: rootLink) }
        #expect(throws: ControlFailure.source) { try CodeExplanationPackage.load(path: rootLink.appendingPathComponent("explanation.json").path) }
        let fifo = fixture.root.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        for path in ["../source0.txt", "/source0.txt", "link.txt", "nested/source0.txt", "fifo", "missing.txt"] {
            try original.write(to: fixture.manifest)
            try fixture.change { var sources = $0["sources"] as! [[String: Any]]; sources[0]["path"] = path; $0["sources"] = sources }
            #expect(throws: (any Error).self) { try CodeExplanationPackage.load(path: fixture.manifest.path) }
        }
        try original.write(to: fixture.manifest)
        try Data(repeating: 65, count: ControlProtocol.maximumSnapshotBytes + 1).write(to: fixture.root.appendingPathComponent("source0.txt"))
        #expect(throws: ControlFailure.source) { try CodeExplanationPackage.load(path: fixture.manifest.path) }
    }
}

@Suite("Gespeicherte Code-Erklärung: realer Player", .serialized)
@MainActor
struct CodeExplanationPlayerTests {
    private func capture(_ window: ControlSnapshotWindow, stage: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["FASTRA_EXPLANATION_UNIT_CAPTURE"],
              let root = window.window.contentView else { return }
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for width in [400, 900] {
            window.window.setContentSize(NSSize(width: width, height: 650))
            root.layoutSubtreeIfNeeded()
            if let player = window.explanationPlayer {
                for item in player.view.arrangedSubviews {
                    #expect(player.view.bounds.contains(item.alignmentRect(forFrame: item.frame)),
                            "Erklärbereich muss die nativen Layoutgrenzen aller Bedienelemente enthalten")
                }
            }
            let frame = root.superview ?? root
            let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            let image = NSImage(size: frame.bounds.size)
            image.lockFocus()
            frame.effectiveAppearance.performAsCurrentDrawingAppearance {
                window.window.backgroundColor.setFill()
                NSRect(origin: .zero, size: frame.bounds.size).fill()
                bitmap.draw(in: NSRect(origin: .zero, size: frame.bounds.size))
            }
            image.unlockFocus()
            let tiff = try #require(image.tiffRepresentation)
            let composed = try #require(NSBitmapImageRep(data: tiff))
            let data = try #require(composed.representation(using: .png, properties: [:]))
            try data.write(to: destination.appendingPathComponent("unit.\(stage).\(width).png"))
        }
    }
    private func wait(_ player: CodeExplanationPlayer) async throws {
        for _ in 0..<100 {
            if player.state != "loadingStep" { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ControlFailure.expired
    }
    private func opened(_ controller: LocalControlController, path: String) async throws -> ControlSnapshotWindow {
        let job = try #require(controller.execute(ControlRequest(operation: "explanation", path: path)).job)
        for _ in 0..<100 {
            if controller.jobValues.first(where: { $0.id == job.id })?.isTerminal == true {
                #expect(controller.jobValues.first(where: { $0.id == job.id })?.state == "ready")
                return try #require(controller.snapshotWindowsForTesting.first { $0.sessionID == job.sessionID })
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ControlFailure.expired
    }
    @Test("Echte Knöpfe, unabhängige Schriften, Erkunden, Rückkehr und Neustart")
    func lifecycle() async throws {
        _ = NSApplication.shared
        let fixture = try ExplanationFixture(); defer { fixture.remove() }
        let controller = LocalControlController(showWindows: false)
        let window = try await opened(controller, path: fixture.manifest.path)
        let player = try #require(window.explanationPlayer)
        try await wait(player)
        #expect(player.state == "ready")
        #expect(window.textView.selectedRange() == NSRange(location: 5, length: 2))
        try capture(window, stage: "ready")
        let firstID = window.documentID
        player.next.performClick(nil); try await wait(player)
        #expect(player.state == "completed" && player.index == 1)
        #expect(window.documentID != firstID && window.textView.string == "other\nlast\n")
        player.previous.performClick(nil); try await wait(player)
        #expect(window.documentID == firstID)
        let oldTextSize = player.explanationFontSize
        player.resize(code: 2, text: 0)
        #expect(player.codeFontSize == 15 && player.explanationFontSize == oldTextSize)
        window.textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(player.state == "paused")
        try capture(window, stage: "paused")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(window.textView.selectedRange() == NSRange(location: 0, length: 0))
        player.returnButton.performClick(nil); try await wait(player)
        #expect(window.textView.selectedRange() == NSRange(location: 5, length: 2))
        player.next.performClick(nil); player.pauseButton.performClick(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(player.state == "paused")
        player.end.performClick(nil)
        #expect(controller.snapshotWindowsForTesting.isEmpty && player.state == "cancelled")
        let fresh = LocalControlController(showWindows: false)
        let reopened = try await opened(fresh, path: fixture.manifest.path)
        defer { _ = try? fresh.execute(ControlRequest(operation: "close", sessionID: reopened.sessionID)) }
        #expect(fresh.runtimeID != controller.runtimeID)
        #expect(reopened.explanationPlayer?.index == 0 && reopened.explanationPlayer?.codeFontSize == 13)
    }
    @Test("Abbruch vor unkooperativer Paketcompletion öffnet keinen Player")
    func delayed() async throws {
        _ = NSApplication.shared
        let fixture = try ExplanationFixture(); defer { fixture.remove() }
        let package = try CodeExplanationPackage.load(path: fixture.manifest.path)
        let controller = LocalControlController(showWindows: false, loadExplanation: { _ in
            try? await Task.sleep(nanoseconds: 80_000_000)
            return package
        })
        let job = try #require(controller.execute(ControlRequest(operation: "explanation", path: fixture.manifest.path)).job)
        await Task.yield()
        _ = try controller.execute(ControlRequest(operation: "cancel", jobID: job.id))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(controller.jobValues.first(where: { $0.id == job.id })?.state == "cancelled")
        let window = try #require(controller.snapshotWindowsForTesting.first)
        #expect(window.loaded == nil && window.explanationPlayer == nil)
        _ = try controller.execute(ControlRequest(operation: "close", sessionID: window.sessionID))
    }

    @Test("Volle Jobliste zeigt den bewusst gewählten Zielschritt ohne falschen Quellenbezug")
    func capacity() async throws {
        _ = NSApplication.shared
        let fixture = try ExplanationFixture(); defer { fixture.remove() }
        let controller = LocalControlController(showWindows: false)
        let window = try await opened(controller, path: fixture.manifest.path)
        defer { _ = try? controller.execute(ControlRequest(operation: "close", sessionID: window.sessionID)) }
        let player = try #require(window.explanationPlayer)
        try await wait(player)
        for _ in 1..<ControlProtocol.maximumJobs {
            _ = try controller.execute(ControlRequest(operation: "navigate", sha256: window.loaded?.diskSnapshot?.sha256,
                location: 0, length: 0, sessionID: window.sessionID, documentID: window.documentID))
        }
        let pending = try #require(controller.jobValues.first(where: { !$0.isTerminal }))
        player.next.performClick(nil)
        #expect(player.state == "failed" && player.index == 1)
        #expect(window.textView.string == "other\nlast\n")
        #expect(window.textView.selectedRange() == NSRange(location: 0, length: 0))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(controller.jobValues.first(where: { $0.id == pending.id })?.state == "cancelled")
        #expect(window.textView.selectedRange() == NSRange(location: 0, length: 0))
        #expect(player.state == "failed")
        try capture(window, stage: "capacity")
        for _ in 0..<(ControlProtocol.maximumJobs * 3) {
            _ = try controller.execute(ControlRequest(operation: "cancel", jobID: pending.id))
        }
        player.end.performClick(nil)
        #expect(controller.snapshotWindowsForTesting.isEmpty)
    }

    @Test("Framework-Ausnahme übersieht keine persistente Einstellung")
    func preferenceProtection() {
        let suite = "fastra-test-control-preferences-\(UUID().uuidString)"
        let defaults = testSuiteDefaults(named: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.register(defaults: ["METAL_ERROR_MODE": 6])
        let before = ControlTestHost.preferencesState(defaults: defaults, domains: [suite])
        defaults.set(6, forKey: "METAL_ERROR_MODE")
        #expect(ControlTestHost.preferencesState(defaults: defaults, domains: [suite]) != before)
        defaults.removeObject(forKey: "METAL_ERROR_MODE")
        defaults.set(24, forKey: "editor.fontSize")
        #expect(ControlTestHost.preferencesState(defaults: defaults, domains: [suite]) != before)
    }

    @Test("Terminale Abbrüche blockieren weder neue Arbeit noch wiederholtes Schließen")
    func cleanupCapacity() async throws {
        _ = NSApplication.shared
        let fixture = try ExplanationFixture(); defer { fixture.remove() }
        let controller = LocalControlController(showWindows: false)
        let window = try await opened(controller, path: fixture.manifest.path)
        let terminal = try #require(controller.jobValues.first)
        for _ in 0..<(ControlProtocol.maximumJobs * 3) {
            _ = try controller.execute(ControlRequest(operation: "cancel", jobID: terminal.id))
        }
        let another = try await opened(controller, path: fixture.manifest.path)
        let close = ControlRequest(operation: "close", sessionID: window.sessionID)
        _ = try controller.execute(close)
        _ = try controller.execute(close)
        #expect(controller.snapshotWindowsForTesting.count == 1)
        _ = try controller.execute(ControlRequest(operation: "close", sessionID: another.sessionID))
    }

    @Test("Präsentation bestätigt keine inzwischen ausgetauschte Dokumentidentität")
    func identityAtPresentation() async throws {
        _ = NSApplication.shared
        let fixture = try ExplanationFixture(); defer { fixture.remove() }
        let controller = LocalControlController(showWindows: false)
        let window = try await opened(controller, path: fixture.manifest.path)
        defer { _ = try? controller.execute(ControlRequest(operation: "close", sessionID: window.sessionID)) }
        let loaded = try #require(window.loaded)
        let request = ControlRequest(operation: "navigate", sha256: loaded.diskSnapshot?.sha256,
            location: 0, length: 3, sessionID: window.sessionID, documentID: window.documentID)
        let job = try #require(controller.execute(request).job)
        // Simuliert eine Installation, die künftig die Controller-Entwertung umgeht.
        window.install(loaded, documentID: UUID())
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(controller.jobValues.first(where: { $0.id == job.id })?.error == ControlFailure.stale)
        #expect(window.textView.selectedRange() == NSRange(location: 0, length: 0))
    }
}
