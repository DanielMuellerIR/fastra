// Vollständige Export-Selbsttestfamilie; Start und gemeinsame UI-Adapter
// bleiben beim gestarteten SelfTest. Die Task-Closure erhält die lexikalische
// Isolation der lokalen Helfer; ein direkter MainActor-async-Einstieg änderte sie.
import AppKit
import Foundation
import SwiftUI

enum SelfTestDiffExport {
    struct Runtime {
        let mainWindow: @MainActor () -> NSWindow?
        let finish: @MainActor (SelfTestOutcome, String) -> Never
        let sendMouseClick: @MainActor (NSPoint, NSWindow, NSEvent.ModifierFlags, Bool, Int) -> Bool
        let capture: @MainActor (NSWindow, @escaping (Data?) -> Void) -> Void
    }

    /// Bedient den sichtbaren Exportknopf und den echten Speicherdialog in
    /// einem eigenen Vergleichsfenster. Das Hauptfenster darf kein Sheet erhalten.
    static func run(runtime: Runtime) {
        Task { @MainActor in
            let base = selfTestTemporaryDirectory().appendingPathComponent("diff-export-\(UUID().uuidString)")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = L10n.string("Diff-Liste exportieren…")
            let mainWindow = runtime.mainWindow()
            func require(_ value: Bool, _ message: String) throws {
                if !value { throw NSError(domain: "DiffExportSelfTest", code: 1,
                                           userInfo: [NSLocalizedDescriptionKey: message]) }
            }
            @MainActor func wait(_ condition: @MainActor () -> Bool) async throws {
                for _ in 0..<160 {
                    if condition() { return }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                throw NSError(domain: "DiffExportSelfTest", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Exportzustand wurde nicht bereit"])
            }
            func findButton(_ view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.identifier?.rawValue == "diffExport" { return button }
                return view.subviews.lazy.compactMap(findButton).first
            }
            @MainActor func openPanel(to destination: URL) async throws -> NSSavePanel {
                DiffExportPanelConfiguration.setDestination(destination)
                guard let root = window.contentView, let button = findButton(root) else {
                    throw NSError(domain: "DiffExportSelfTest", code: 3)
                }
                try require(button.isEnabled && button.visibleRect.width >= 20 && button.visibleRect.height >= 20,
                            "Exportknopf fehlt oder hat keine treffbare Fläche")
                window.makeKeyAndOrderFront(nil)
                try require(runtime.sendMouseClick(button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil),
                                           window, [], true, 1), "Exportknopf konnte nicht geklickt werden")
                try await wait { window.attachedSheet is NSSavePanel }
                try require(mainWindow?.attachedSheet == nil, "Export öffnete einen Dialog am Hauptfenster")
                return window.attachedSheet as! NSSavePanel
            }
            // Die Aufnahme liest Fensterzustand; Verzeichnisanlage und PNG-Schreiben
            // bleiben im bisherigen Hintergrundpfad.
            @MainActor func captureData(from target: NSWindow) async -> Data? {
                await withCheckedContinuation { continuation in
                    runtime.capture(target) { continuation.resume(returning: $0) }
                }
            }
            nonisolated func capture(_ name: String, from target: NSWindow) async throws {
                guard let directory = ProcessInfo.processInfo.environment["FASTRA_DIFFEXPORT_DIR"], !directory.isEmpty else { return }
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = await captureData(from: target)
                guard let data else { throw NSError(domain: "DiffExportSelfTest", code: 4) }
                try data.write(to: url)
            }
            var inputStep = 0
            @MainActor func panelKey(_ code: UInt16, panel: NSSavePanel) async throws {
                let directory = try inputDirectoryPath(environment: ProcessInfo.processInfo.environment)
                panel.makeKeyAndOrderFront(nil)
                let root = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let command: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "keyCode": code]
                // Das macOS-Sheet enthält einen fremden Open/Save-Panel-Service.
                // NSApp.postEvent erreicht dessen Eingabefelder nicht verlässlich.
                try JSONSerialization.data(withJSONObject: command).write(to: root.appendingPathComponent("key-\(inputStep).json"), options: .atomic)
                inputStep += 1
            }
            do {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let leftURL = base.appendingPathComponent("Links #1 🇩🇪.txt")
                let rightURL = base.appendingPathComponent("Rechts é.txt")
                let left = "GLEICH  \nalt 🇩🇪\nmitte\nende\n"
                let right = "gleich\nneu é\nzusatz\nmitte\nschluss\n"
                try left.write(to: leftURL, atomically: true, encoding: .utf8)
                try right.write(to: rightURL, atomically: true, encoding: .utf8)
                let options = FileDiffOptions(ignoreTrailingWhitespace: true, ignoreCase: true)
                guard case .result(let result) = FileDiff.compare(left: left, right: right, options: options) else {
                    throw NSError(domain: "DiffExportSelfTest", code: 5)
                }
                let fileRequest = FileDiffRequest(left: .file(leftURL), right: .file(rightURL), options: options)
                let gitRequest = GitDiffRequest(repositoryPath: base.path, source: .workingTree(path: nil))
                let patch = "diff --git a/eins.txt b/eins.txt\n--- a/eins.txt\n+++ b/eins.txt\n@@ -1,3 +1,3 @@\n-alt\n+neu\n mitte\n-ende\n+schluss\n\\ No newline at end of file\ndiff --git a/zwei.bin b/zwei.bin\nBinary files a/zwei.bin and b/zwei.bin differ\n"
                let gitDocument = GitDiffParser.parse(Data(patch.utf8))
                guard case .result(let identical) = FileDiff.compare(left: left, right: left, options: options) else {
                    throw NSError(domain: "DiffExportSelfTest", code: 6)
                }
                let identicalRequest = FileDiffRequest(left: .file(leftURL), right: .file(leftURL), options: options)
                let variants: [(String, AnyView, DiffExportSnapshot)] = [
                    ("file", AnyView(FileDiffView(request: fileRequest, document: .success(result))), .file(fileRequest, result)),
                    ("git", AnyView(GitDualPaneDiffView(request: gitRequest, document: gitDocument, fallbackText: "")), .git(gitRequest, gitDocument)),
                    ("identical", AnyView(FileDiffView(request: identicalRequest, document: .success(identical))), .file(identicalRequest, identical))
                ]
                ApplicationActivation.activate(ignoringOtherApps: true)
                for (name, view, snapshot) in variants {
                    window.contentView = NSHostingView(rootView: view)
                    for width: CGFloat in [760, 1100] {
                        window.setContentSize(NSSize(width: width, height: 620))
                        window.makeKeyAndOrderFront(nil)
                        try await Task.sleep(nanoseconds: 350_000_000)
                        try require(window.contentView.flatMap(findButton) != nil, "Export fehlt bei \(name), \(width) pt")
                        try await capture("\(name)-\(Int(width))", from: window)
                    }
                    if name == "identical" { continue }
                    let target = base.appendingPathComponent("\(name)-Bericht.txt")
                    let cancelled = try await openPanel(to: target)
                    try await Task.sleep(nanoseconds: 350_000_000)
                    try await capture("\(name)-save-panel", from: cancelled)
                    try await panelKey(53, panel: cancelled)
                    try await wait { window.attachedSheet == nil }
                    try require(!FileManager.default.fileExists(atPath: target.path), "Abbruch schrieb einen Bericht")
                    let panel = try await openPanel(to: target)
                    try await Task.sleep(nanoseconds: 500_000_000)
                    try await panelKey(36, panel: panel)
                    try await wait { window.attachedSheet == nil && FileManager.default.fileExists(atPath: target.path) }
                    try require(try String(contentsOf: target, encoding: .utf8) == snapshot.report(), "Gespeicherter Bericht weicht von der fertigen Vergleichsbasis ab")
                    try require(try String(contentsOf: leftURL, encoding: .utf8) == left
                                && String(contentsOf: rightURL, encoding: .utf8) == right, "Export änderte eine Vergleichsquelle")
                }
                window.close()
                DiffExportPanelConfiguration.clearFixture()
                try? FileManager.default.removeItem(at: base)
                runtime.finish(.pass, "Datei- und Git-Diff: echter Exportknopf, Fensterbezug, Abbruch und UTF-8-Speicherung; Quellen bleiben unverändert; Ansichten bei 760/1100 pt")
            } catch {
                if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
                window.close()
                DiffExportPanelConfiguration.clearFixture()
                try? FileManager.default.removeItem(at: base)
                runtime.finish(outcome(for: error), error.localizedDescription)
            }
        }
    }

    static func inputDirectoryPath(environment: [String: String]) throws -> String {
        guard let directory = environment["FASTRA_DIFFEXPORT_INPUT_DIR"], !directory.isEmpty else {
            throw NSError(domain: "DiffExportSelfTest", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "Speicherdialog benötigt den externen Tasten-Treiber"])
        }
        return directory
    }

    static func outcome(for error: Error) -> SelfTestOutcome {
        let error = error as NSError
        return error.domain == "DiffExportSelfTest" && error.code == 7 ? .environment : .fail
    }
}
