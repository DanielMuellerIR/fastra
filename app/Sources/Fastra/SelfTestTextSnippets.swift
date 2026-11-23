// Vollständige Textbaustein-Selbsttests; Start, gemeinsame Ereignishelfer und
// Prozessabschluss bleiben beim gestarteten SelfTest.
import AppKit
import Foundation
import WebKit
import CodeEditTextView

@MainActor
struct SelfTestTextSnippets {
    private let workspace: @MainActor () -> Workspace?
    private let finishBody: @MainActor (SelfTestOutcome, String) -> Never
    private let activateApplicationBody: @MainActor (Bool) -> Void
    private let nativeUIWaitBody: @MainActor (String, @MainActor () -> Bool) async throws -> Void
    private let stableMarkerClickBody: @MainActor (String, NSWindow, String) async throws -> Void
    private let markerViewBody: @MainActor (String, NSView) -> NSView?
    private let sendMouseClickBody: @MainActor (NSPoint, NSWindow, NSEvent.ModifierFlags, Bool) -> Bool
    private let collectEditableFieldsBody: @MainActor (NSView, inout [NSTextField]) -> Void
    private let postKeyBody: @MainActor (String, UInt16, Int, NSEvent.ModifierFlags) -> Void
    private let postHistoryKeyBody: @MainActor (Int) -> Void
    private let redoFromEditMenu: @MainActor () async throws -> Void
    private let captureBody: @MainActor (NSWindow, @escaping (Data?) -> Void) -> Void

    init(
        workspace: @escaping @MainActor () -> Workspace?,
        finishBody: @escaping @MainActor (SelfTestOutcome, String) -> Never,
        activateApplicationBody: @escaping @MainActor (Bool) -> Void,
        nativeUIWaitBody: @escaping @MainActor (String, @MainActor () -> Bool) async throws -> Void,
        stableMarkerClickBody: @escaping @MainActor (String, NSWindow, String) async throws -> Void,
        markerViewBody: @escaping @MainActor (String, NSView) -> NSView?,
        sendMouseClickBody: @escaping @MainActor (NSPoint, NSWindow, NSEvent.ModifierFlags, Bool) -> Bool,
        collectEditableFieldsBody: @escaping @MainActor (NSView, inout [NSTextField]) -> Void,
        postKeyBody: @escaping @MainActor (String, UInt16, Int, NSEvent.ModifierFlags) -> Void,
        postHistoryKeyBody: @escaping @MainActor (Int) -> Void,
        redoFromEditMenu: @escaping @MainActor () async throws -> Void,
        captureBody: @escaping @MainActor (NSWindow, @escaping (Data?) -> Void) -> Void
    ) {
        self.workspace = workspace
        self.finishBody = finishBody
        self.activateApplicationBody = activateApplicationBody
        self.nativeUIWaitBody = nativeUIWaitBody
        self.stableMarkerClickBody = stableMarkerClickBody
        self.markerViewBody = markerViewBody
        self.sendMouseClickBody = sendMouseClickBody
        self.collectEditableFieldsBody = collectEditableFieldsBody
        self.postKeyBody = postKeyBody
        self.postHistoryKeyBody = postHistoryKeyBody
        self.redoFromEditMenu = redoFromEditMenu
        self.captureBody = captureBody
    }

    private func finish(_ ok: Bool, _ message: String) -> Never { finishBody(ok ? .pass : .fail, message) }
    private func finish(_ outcome: SelfTestOutcome, _ message: String) -> Never { finishBody(outcome, message) }
    private func activateApplication(ignoringOtherApps: Bool) { activateApplicationBody(ignoringOtherApps) }
    private func nativeUIWait(_ detail: String, _ condition: @MainActor () -> Bool) async throws {
        try await nativeUIWaitBody(detail, condition)
    }
    private func stableMarkerClick(_ id: String, in target: NSWindow, stage: String) async throws {
        try await stableMarkerClickBody(id, target, stage)
    }
    private func markerView(id: String, in view: NSView) -> NSView? { markerViewBody(id, view) }
    private func sendMouseClick(at point: NSPoint, in window: NSWindow,
                                modifiers: NSEvent.ModifierFlags, viaApp: Bool) -> Bool {
        sendMouseClickBody(point, window, modifiers, viaApp)
    }
    private func collectEditableFields(in view: NSView, into fields: inout [NSTextField]) {
        collectEditableFieldsBody(view, &fields)
    }
    private func postKey(_ char: String, keyCode: UInt16, windowNumber: Int,
                         modifiers: NSEvent.ModifierFlags = []) {
        postKeyBody(char, keyCode, windowNumber, modifiers)
    }
    private func postHistoryKey(windowNumber: Int) { postHistoryKeyBody(windowNumber) }
    private func typeScrollCapture(window: NSWindow, completion: @escaping (Data?) -> Void) {
        captureBody(window, completion)
    }

    func runTextSnippetFilesTest() async {
            guard let ws = workspace(), let window = CommandTargeting.registeredWindow(for: ws),
                  let path = ProcessInfo.processInfo.environment["FASTRA_TEXT_WORKFLOW_DIR"] else { finish(.environment, "Dateidialog-Test benötigt den vorhandenen externen Tastenpfad") }
            let output = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: output.appendingPathComponent("panel-driver-ready").path) else { finish(.environment, "Externer Dateidialog-Treiber fehlt") }
            let base = selfTestTemporaryDirectory().appendingPathComponent("fastra-snippet-files-\(UUID())")
            let initial = base.appendingPathComponent("Initial/Sammlung.json")
            let exported = base.appendingPathComponent("Export/Sammlung.json")
            let bulk = base.appendingPathComponent("Bulk/Sammlung.json")
            let invalid = base.appendingPathComponent("Invalid/Sammlung.json")
            let source = "Dokument bleibt unverändert 😀\n"
            let store = TextSnippetStore()
            let originalAppearance = NSApp.appearance
            var stage = "Fixture", keyIndex = 0, panelTimer: Timer?, panelError: String?
            @Sendable nonisolated func require(_ ok: Bool, _ message: String) throws {
                if !ok { throw NSError(domain: "SnippetFiles", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            }
            @MainActor func wait(_ detail: String, _ condition: @MainActor () -> Bool) async throws { try await nativeUIWait(stage + " / " + detail, condition) }
            @MainActor func request(_ code: Int?, capture: String? = nil, window: NSWindow? = nil) throws {
                var value: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "nonce": UUID().uuidString]
                if let code { value["keyCode"] = code }
                if let capture, let window { value["capture"] = capture; value["windowID"] = window.windowNumber }
                try JSONSerialization.data(withJSONObject: value).write(to: output.appendingPathComponent("panel-key-\(keyIndex).json"), options: .atomic)
                keyIndex += 1
            }
            @MainActor func confirmationList(in view: NSView) -> NSTextView? {
                if let text = view as? NSTextView, !text.isEditable, text.enclosingScrollView != nil { return text }
                return view.subviews.lazy.compactMap { confirmationList(in: $0) }.first
            }
            @MainActor func button(_ title: String, in view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.title == title { return button }
                return view.subviews.lazy.compactMap { button(title, in: $0) }.first
            }
            @MainActor func startPanel(importing file: URL? = nil, names: [String]? = nil, capture: String) {
                panelTimer?.invalidate(); TextSnippetPanelConfiguration.clearObservedPanel(); panelError = nil
                var step = 0, next = Date.distantPast, topCaptureIndex: Int?, captureIndex = 0
                let appearances: [(NSAppearance.Name, Bool, String)] = [
                    (.aqua, false, "light-top"), (.darkAqua, false, "dark-top"),
                    (.aqua, true, "light-end"), (.darkAqua, true, "dark-end")
                ]
                let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
                    do {
                        if step == 0, let panel = TextSnippetPanelConfiguration.observedPanel {
                            guard panel.directoryURL?.canonicalFileURL == (file?.deletingLastPathComponent() ?? exported.deletingLastPathComponent()).canonicalFileURL else { return }
                            if file != nil { try request(124); next = Date().addingTimeInterval(0.3); step = 1 }
                            else { try request(36); panelTimer?.invalidate(); step = 6 }
                        } else if step == 1, Date() >= next, let panel = TextSnippetPanelConfiguration.observedPanel {
                            guard panel.directoryURL?.canonicalFileURL == file?.deletingLastPathComponent().canonicalFileURL else { throw NSError(domain: "SnippetFiles", code: 2, userInfo: [NSLocalizedDescriptionKey: "Dateidialog verließ die Fixture"]) }
                            try request(125); step = 7
                        } else if step == 7, let panel = TextSnippetPanelConfiguration.observedPanel as? NSOpenPanel,
                                  panel.urls.count == 1, panel.urls.first?.canonicalFileURL == file?.canonicalFileURL {
                            try request(36); step = 2
                            if names == nil { panelTimer?.invalidate(); step = 6 }
                        } else if step == 2, let alert = NSApp.modalWindow, !(alert is NSSavePanel),
                                  let root = alert.contentView, button(L10n.string("Importieren"), in: root) != nil,
                                  let names, let list = confirmationList(in: root), list.string == names.joined(separator: "\n") {
                            guard let scroll = list.enclosingScrollView, scroll.frame.height > 0 else { return }
                            try require(scroll.frame.height <= 180, "Importnamen sind nicht in begrenzter Scrollansicht")
                            step = 3
                        } else if step == 3, let alert = NSApp.modalWindow, let root = alert.contentView,
                                  let list = confirmationList(in: root) {
                            let appearance = appearances[captureIndex]
                            NSApp.appearance = NSAppearance(named: appearance.0)
                            list.scrollRangeToVisible(NSRange(location: appearance.1 ? list.string.utf16.count : 0, length: 0))
                            next = Date().addingTimeInterval(0.2); step = 4
                        } else if step == 4, Date() >= next, let alert = NSApp.modalWindow {
                            topCaptureIndex = keyIndex
                            try request(nil, capture: capture + "-" + appearances[captureIndex].2, window: alert); step = 5
                        } else if step == 5, let index = topCaptureIndex,
                                  FileManager.default.fileExists(atPath: output.appendingPathComponent("panel-response-\(index).json").path) {
                            let reply = try Data(contentsOf: output.appendingPathComponent("panel-response-\(index).json"))
                            let replyObject = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
                            try require(replyObject?["ok"] as? Bool == true, "Native Aufnahme wurde nicht bestätigt")
                            captureIndex += 1
                            if captureIndex < appearances.count { step = 3 }
                            else {
                                NSApp.appearance = originalAppearance
                                try request(36); panelTimer?.invalidate(); step = 6
                            }
                        }
                    } catch {
                        panelError = error.localizedDescription; panelTimer?.invalidate(); TextSnippetPanelConfiguration.observedPanel?.cancel(nil)
                    }
                }
                panelTimer = timer; RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
            }
            @MainActor func cleanup() {
                panelTimer?.invalidate(); TextSnippetPanelConfiguration.observedPanel?.cancel(nil); TextSnippetPanelConfiguration.clearObservedPanel()
                TextSnippetPanelConfiguration.clearFixture()
                NSApp.appearance = originalAppearance
                ws.textSnippetSession?.close()
                try? Data("done".utf8).write(to: output.appendingPathComponent("panel-driver-done"))
                try? FileManager.default.removeItem(at: base)
            }
            do {
                for directory in [initial, exported, bulk, invalid].map({ $0.deletingLastPathComponent() }) { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
                let seed = TextSnippetDefinition(name: "Roundtrip 😀", template: "Hallo {{Name}}\n{{Name}}")
                try TextSnippetArchive.encode([seed]).write(to: initial, options: .atomic)
                let incoming = (0..<48).map { TextSnippetDefinition(name: String(format: "%02d ", $0) + String(repeating: "Langer Unicode-Name 😀 ", count: 3), template: "{{Name}}") }
                let bulkData = try TextSnippetArchive.encode(incoming)
                try bulkData.write(to: bulk, options: .atomic); try Data("kein JSON".utf8).write(to: invalid)
                let tab = EditorTab(title: "SnippetFiles.txt", path: "", content: source)
                ws.tabs = [tab]; ws.activeTabID = tab.id
                window.setContentSize(NSSize(width: 1100, height: 700))
                activateApplication(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
                try await wait("Editor bereit") { CommandTargeting.editorTextView(for: ws)?.string == source }
                try await stableMarkerClick("snippetOpen", in: window, stage: stage)
                try await wait("Picker offen") { ws.textSnippetSession != nil && !window.sheets.isEmpty }
                guard let session = ws.textSnippetSession, let picker = window.sheets.first else { throw NSError(domain: "SnippetFiles", code: 3) }
                stage = "Erster Import in die leere Sammlung"
                try require(session.saved.isEmpty && session.canSave && !session.canInsert, "Unveränderte Startvorlage wurde wie eine gespeicherte Vorlage behandelt")
                TextSnippetPanelConfiguration.setImportDirectory(initial.deletingLastPathComponent())
                startPanel(importing: initial, names: [seed.name], capture: "import-initial")
                try await stableMarkerClick("snippetImport", in: picker, stage: stage)
                try await wait("Import ohne Entwurfsrückfrage abgeschlossen") { session.saved.count == 1 && !session.isBusy }
                guard let original = session.saved.first else { throw NSError(domain: "SnippetFiles", code: 4) }
                try require(panelError == nil && session.error == nil && original.name == seed.name && original.template == seed.template, "Falscher Textbaustein beim Erstimport")
                TextSnippetPanelConfiguration.setExportDestination(exported)
                stage = "Sammlung über echten Speicherdialog exportieren"
                startPanel(capture: "export")
                try await stableMarkerClick("snippetExport", in: picker, stage: stage)
                try await wait("Exportdatei und UI-Rückgabe") { FileManager.default.fileExists(atPath: exported.path) && !session.isBusy && TextSnippetPanelConfiguration.observedPanel?.isVisible != true }
                try require(panelError == nil && session.error == nil, panelError ?? session.error ?? "Exportfehler")
                let exportedData = try FileSnapshot.read(from: exported, byteLimit: UInt64(TextSnippetArchive.maximumBytes)).data
                try require(try TextSnippetArchive.decode(exportedData) == [original], "Export enthält andere Definitionen")
                stage = "Exportdatei über echten Öffnendialog importieren"
                TextSnippetPanelConfiguration.setImportDirectory(exported.deletingLastPathComponent())
                let roundtripNames = try store.previewImport(exportedData).map(\.name)
                startPanel(importing: exported, names: roundtripNames, capture: "import-roundtrip")
                try await stableMarkerClick("snippetImport", in: picker, stage: stage)
                try await wait("Import und Konfliktumbenennung") { session.saved.count == 2 && !session.isBusy }
                try require(panelError == nil && session.error == nil && session.saved.first == original, "Import überschreibt Original oder meldet Fehler")
                try require(session.saved[1].name == "Roundtrip 😀 (2)" && session.saved[1].id != original.id, "Importkonflikt nicht getrennt")
                stage = "Lange vollständige Importliste"
                TextSnippetPanelConfiguration.setImportDirectory(bulk.deletingLastPathComponent())
                let names = try store.previewImport(bulkData).map(\.name)
                startPanel(importing: bulk, names: names, capture: "import-bulk")
                try await stableMarkerClick("snippetImport", in: picker, stage: stage)
                try await wait("Alle 48 Definitionen übernommen") { session.saved.count == 50 && !session.isBusy }
                try require(panelError == nil && session.error == nil && session.saved.first == original, "Großimport verändert vorhandene Daten")
                stage = "Ungültige Datei vollständig abweisen"
                TextSnippetPanelConfiguration.setImportDirectory(invalid.deletingLastPathComponent())
                let before = try store.load()
                startPanel(importing: invalid, capture: "import-invalid")
                try await stableMarkerClick("snippetImport", in: picker, stage: stage)
                try await wait("Importfehler sichtbar") { session.error != nil && !session.isBusy }
                try require(try store.load() == before && ws.activeTab?.content == source, "Ungültiger Import verändert Daten")
                try require(panelError == nil, panelError ?? "Dialogfehler")
                let finalResponse = output.appendingPathComponent("panel-response-\(keyIndex - 1).json")
                try await wait("Letzte native Eingabe bestätigt") { FileManager.default.fileExists(atPath: finalResponse.path) }
                let finalReply = try JSONSerialization.jsonObject(with: Data(contentsOf: finalResponse)) as? [String: Any]
                try require(finalReply?["ok"] as? Bool == true, "Letzte native Eingabe meldet einen Fehler")
                panelTimer?.invalidate()
                try await stableMarkerClick("snippetClose", in: picker, stage: stage)
                try await wait("Picker geschlossen") { ws.textSnippetSession == nil && window.sheets.isEmpty }
                cleanup()
                finish(true, "Echter Export/Import über macOS-Dateidialoge mit nativen Systemtasten, unveränderte Originale, Konfliktumbenennung, vollständige begrenzte 48-Namen-Vorschau, 50er-Grenze und ungültige JSON-Datei")
            } catch {
                let detail = "Textbaustein-Dateien [\(stage)]: \(error.localizedDescription); Panel=\(panelError ?? "nil"), UI=\(ws.textSnippetSession?.error ?? "nil")"
                cleanup(); finish(false, detail)
            }
    }

    func runTextSnippetTest() async {
            guard let ws = workspace(), let window = CommandTargeting.registeredWindow(for: ws) else { finish(false, "Dokumentfenster fehlt") }
            let base = selfTestTemporaryDirectory().appendingPathComponent("fastra-snippets-\(UUID())")
            let file = base.appendingPathComponent("Snippet.txt")
            let source = "vor OLD nach\r\nUnberührt 😀\n"
            let originalAppearance = NSApp.appearance
            var stage = "Fixture"
            @Sendable nonisolated func require(_ ok: Bool, _ message: String) throws {
                if !ok { throw NSError(domain: "TextSnippetSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            }
            @MainActor func wait(_ detail: String, _ condition: @MainActor () -> Bool) async throws { try await nativeUIWait(stage + " / " + detail, condition) }
            @MainActor func sheet() throws -> NSWindow {
                guard let sheet = window.sheets.first else { throw NSError(domain: "TextSnippetSelfTest", code: 2) }; return sheet
            }
            @MainActor func input(_ id: String, in target: NSWindow) -> NSTextView? {
                func find(_ view: NSView) -> NSTextView? {
                    if let text = view as? NSTextView, text.accessibilityIdentifier() == id { return text }
                    for child in view.subviews { if let found = find(child) { return found } }; return nil
                }
                return target.contentView.flatMap(find)
            }
            @MainActor func fill(_ id: String, _ value: String, in target: NSWindow) async throws {
                try await wait("Textfeld montiert: " + id) { input(id, in: target)?.window === target && input(id, in: target)?.isEditable == true }
                guard let text = input(id, in: target), target.makeFirstResponder(text) else { throw NSError(domain: "TextSnippetSelfTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "Textfeld fehlt: " + id]) }
                try await wait("Textfeld fokussiert: " + id) { target.firstResponder === text }
                text.selectAll(nil); text.insertText(value, replacementRange: text.selectedRange())
                try await wait("Native Eingabe übernommen: " + id) { input(id, in: target)?.string.utf8.elementsEqual(value.utf8) == true }
            }
            @MainActor func matrix(_ name: String, in target: NSWindow) async throws {
                guard let output = ProcessInfo.processInfo.environment["FASTRA_TEXT_WORKFLOW_DIR"] else { return }
                for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    for width in [760, 1100] {
                        target.setContentSize(NSSize(width: width, height: width == 760 ? 650 : 740))
                        try await Task.sleep(for: .milliseconds(300))
                        guard let root = target.contentView else { continue }
                        for id in ["snippetSave", "snippetClose", "snippetInsert"] {
                            guard let marker = markerView(id: id, in: root) else { try require(false, "Control fehlt: " + id); continue }
                            let rect = marker.convert(marker.bounds, to: root)
                            try require(root.bounds.contains(NSPoint(x: rect.midX, y: rect.midY)), "Control abgeschnitten: " + id)
                        }
                        let url = URL(fileURLWithPath: output).appendingPathComponent("\(name)-\(mode)-\(width).png")
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                            typeScrollCapture(window: target) { snapshot in try? snapshot?.write(to: url); done.resume() }
                        }
                    }
                }
            }
            @MainActor func cleanup() {
                ws.textSnippetSession?.close(); NSApp.appearance = originalAppearance
                try? FileManager.default.removeItem(at: base)
            }
            do {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                try source.write(to: file, atomically: true, encoding: .utf8)
                var loaded = false; ws.loadFile(at: file) { loaded = $0 }
                window.setContentSize(NSSize(width: 1100, height: 700))
                activateApplication(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
                try await wait("Quelle bereit") { loaded && CommandTargeting.editorTextView(for: ws)?.string == source }
                guard let editor = CommandTargeting.editorTextView(for: ws) else { throw NSError(domain: "TextSnippetSelfTest", code: 4) }
                try require(window.makeFirstResponder(editor), "Editor nimmt Fokus nicht an")
                editor.selectionManager.setSelectedRange((source as NSString).range(of: "OLD"))
                stage = "Sichtbaren Befehl öffnen"
                try await stableMarkerClick("snippetOpen", in: window, stage: stage)
                try await wait("Sheet geöffnet") { ws.textSnippetSession != nil && !window.sheets.isEmpty }
                guard let session = ws.textSnippetSession else { throw NSError(domain: "TextSnippetSelfTest", code: 5) }
                let picker = try sheet()
                await Task.yield()
                stage = "Neue Vorlage tatsächlich bearbeiten"
                try await stableMarkerClick("snippetName", in: picker, stage: stage)
                func nameEditor() -> NSTextView? {
                    guard let root = picker.contentView else { return nil }
                    var fields: [NSTextField] = []; collectEditableFields(in: root, into: &fields)
                    guard let field = fields.first(where: { $0.placeholderString == L10n.string("Name des Textbausteins") }),
                          let editor = field.currentEditor() as? NSTextView, picker.firstResponder === editor else { return nil }
                    return editor
                }
                try await wait("Namensfeld besitzt konkreten Editor") { nameEditor() != nil }
                guard let name = nameEditor() else { throw NSError(domain: "TextSnippetSelfTest", code: 6) }
                name.selectAll(nil); name.insertText("Brief 😀", replacementRange: name.selectedRange())
                try await fill("snippetTemplateInput", "{{Name}} / {{Ort}} / {{Name}}", in: picker)
                try await wait("Vorlage übernommen") { session.definition.name == "Brief 😀" && session.placeholders == ["Name", "Ort"] }
                try require(session.requiresDiscardConfirmation, "Bearbeitete Startvorlage hat keinen Verwerfenschutz")
                try await stableMarkerClick("snippetSave", in: picker, stage: stage)
                try await wait("Vorlage gespeichert") { !session.dirty && session.saved.count == 1 }
                let savedID = session.definition.id
                try await fill("snippetValue-0", "Hallo 😀\ne\u{301}", in: picker)
                let first = input("snippetValue-0", in: picker)
                postKey("\t", keyCode: 48, windowNumber: picker.windowNumber)
                try await wait("Tab erreicht zweites Feld") { picker.firstResponder === input("snippetValue-1", in: picker) }
                try await fill("snippetValue-1", "{{Name}} Köln", in: picker)
                postKey("\u{19}", keyCode: 48, windowNumber: picker.windowNumber, modifiers: .shift)
                try await wait("Umschalt-Tab erreicht erstes Feld") { picker.firstResponder === first }
                let replacement = "Hallo 😀\ne\u{301} / {{Name}} Köln / Hallo 😀\ne\u{301}"
                try await wait("Vorschau vollständig") { session.preview?.utf8.elementsEqual(replacement.utf8) == true && session.canInsert }
                try require(input("snippetPreviewInput", in: picker)?.string.utf8.elementsEqual(replacement.utf8) == true, "Sichtbare Vorschau weicht ab")
                try require(ws.activeTab?.content == source && (try String(contentsOf: file, encoding: .utf8)) == source, "Vorlage oder Vorschau schreibt ins Dokument")
                try await matrix("snippets-values", in: picker)
                stage = "Vorlagenfehler sichtbar"
                try await fill("snippetTemplateInput", "{{offen", in: picker)
                try await wait("Fehler blockiert Einfügen") { session.validationMessage != nil && !session.canInsert && !session.canSave }
                try await matrix("snippets-invalid", in: picker)
                try await fill("snippetTemplateInput", "{{Name}} / {{Ort}} / {{Name}}", in: picker)
                try await wait("Vorlage wieder sauber") { !session.dirty }
                try await fill("snippetValue-0", "Hallo 😀\ne\u{301}", in: picker)
                try await fill("snippetValue-1", "{{Name}} Köln", in: picker)
                stage = "Auswahl einfügen, Undo und Redo"
                try await stableMarkerClick("snippetInsert", in: picker, stage: stage)
                let expected = (source as NSString).replacingOccurrences(of: "OLD", with: replacement)
                try await wait("Einfügung fertig") { ws.textSnippetSession == nil && window.sheets.isEmpty && ws.activeTab?.content.utf8.elementsEqual(expected.utf8) == true }
                try require((try String(contentsOf: file, encoding: .utf8)) == source, "Einfügen speichert ungefragt")
                try await wait("Dokumentfenster nach Sheet bereit") { window.sheets.isEmpty && window.isKeyWindow }
                try require(window.makeFirstResponder(editor), "Dokumentfokus nach Sheet fehlt")
                try await wait("Dokument besitzt Fokus") { window.firstResponder === editor }
                postHistoryKey(windowNumber: window.windowNumber)
                try await wait("Ein Undo stellt Quelle wieder her") { ws.activeTab?.content.utf8.elementsEqual(source.utf8) == true }
                try await wait("Redo verfügbar") { editor.undoManager?.canRedo == true }
                try await redoFromEditMenu()
                try await wait("Redo") { ws.activeTab?.content.utf8.elementsEqual(expected.utf8) == true }
                postHistoryKey(windowNumber: window.windowNumber)
                try await wait("Original wieder da") { ws.activeTab?.content == source }
                stage = "Erneut öffnen und Abbrechen"
                editor.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
                try await stableMarkerClick("snippetOpen", in: window, stage: stage)
                try await wait("Gespeicherter Baustein") { ws.textSnippetSession?.definition.id == savedID && !window.sheets.isEmpty }
                let reopened = try sheet()
                try await matrix("snippets-reopened", in: reopened)
                try await stableMarkerClick("snippetClose", in: reopened, stage: stage)
                try await wait("Abgebrochen") { ws.textSnippetSession == nil && window.sheets.isEmpty }
                try require(ws.activeTab?.content == source, "Abbrechen verändert Quelle")
                stage = "Duplizieren und Löschen"
                try await stableMarkerClick("snippetOpen", in: window, stage: stage)
                try await wait("Verwaltung offen") { ws.textSnippetSession != nil && !window.sheets.isEmpty }
                let management = try sheet()
                guard let managed = ws.textSnippetSession else { throw NSError(domain: "TextSnippetSelfTest", code: 8) }
                try await stableMarkerClick("snippetDuplicate", in: management, stage: stage)
                try await wait("Unabhängige Kopie") { managed.dirty && managed.definition.id != savedID }
                let duplicateID = managed.definition.id
                try await stableMarkerClick("snippetSave", in: management, stage: stage)
                try await wait("Kopie gespeichert") { !managed.dirty && managed.saved.count == 2 }
                try require(managed.definition.template == "{{Name}} / {{Ort}} / {{Name}}", "Duplikat verliert Vorlage")
                try await matrix("snippets-management", in: management)
                try await stableMarkerClick("snippetDelete", in: management, stage: stage)
                func deleteButton(_ view: NSView) -> NSButton? {
                    if let button = view as? NSButton, button.title == L10n.string("Löschen") { return button }
                    return view.subviews.lazy.compactMap { deleteButton($0) }.first
                }
                var confirmation: (NSWindow, NSButton)?
                try await wait("Sichtbare Löschbestätigung") {
                    for alert in management.sheets + window.sheets {
                        if let root = alert.contentView, let button = deleteButton(root) { confirmation = (alert, button); return true }
                    }
                    return false
                }
                if let (alert, button) = confirmation {
                    try require(sendMouseClick(at: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil), in: alert, modifiers: [], viaApp: true), "Löschbestätigung nicht bedienbar")
                }
                try await wait("Nur Kopie gelöscht") { managed.saved.count == 1 && !managed.saved.contains(where: { $0.id == duplicateID }) && managed.definition.id == savedID }
                try await wait("Löschbestätigung vollständig geschlossen") { management.sheets.isEmpty && management.isKeyWindow }
                stage = "Exportdialog abbrechen"
                var exportPanelSeen = false
                var panelTimer: Timer?
                panelTimer = Timer(timeInterval: 0.05, repeats: true) { _ in
                    guard let panel = NSApp.modalWindow as? NSSavePanel else { return }
                    exportPanelSeen = true; panelTimer?.invalidate(); panelTimer = nil; panel.cancel(nil)
                }
                if let panelTimer { RunLoop.main.add(panelTimer, forMode: .common); RunLoop.main.add(panelTimer, forMode: .modalPanel) }
                try await stableMarkerClick("snippetExport", in: management, stage: stage)
                try await wait("Exportpanel abgebrochen") { exportPanelSeen && NSApp.modalWindow == nil }
                panelTimer?.invalidate(); panelTimer = nil
                try require(managed.saved.count == 1 && ws.activeTab?.content == source, "Exportabbruch verändert Daten")
                try await stableMarkerClick("snippetClose", in: management, stage: stage)
                try await wait("Verwaltung geschlossen") { ws.textSnippetSession == nil && window.sheets.isEmpty }
                stage = "WYSIWYG-Einfügen"
                var markdown = EditorTab(title: "Snippet.md", path: "", content: "# Kopf\n\nOLD\n\nUnberührt  _Original_ 😀\n")
                markdown.markdownVisualOverride = true
                ws.tabs.append(markdown); ws.activeTabID = markdown.id
                try await wait("WebKit bereit") { ws.visualMarkdownEditor?.ready == true }
                guard let web = ws.visualMarkdownEditor?.web else { throw NSError(domain: "TextSnippetSelfTest", code: 7) }
                _ = try await web.evaluateJavaScript("const p=Array.from(document.querySelectorAll('p')).find(p=>p.textContent==='OLD'),r=document.createRange();r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r);document.dispatchEvent(new Event('selectionchange'));void 0;")
                try await stableMarkerClick("snippetOpen", in: window, stage: stage)
                try await wait("Visueller Picker") { ws.textSnippetSession != nil && !window.sheets.isEmpty }
                let visualPicker = try sheet()
                try await fill("snippetValue-0", "Visuell 😀\nzweite Zeile", in: visualPicker)
                try await fill("snippetValue-1", "Köln", in: visualPicker)
                try await matrix("snippets-visual", in: visualPicker)
                try await stableMarkerClick("snippetInsert", in: visualPicker, stage: stage)
                try await wait("Visuelle Einfügung") { ws.textSnippetSession == nil && window.sheets.isEmpty && ws.activeTab?.content.contains("Visuell 😀") == true }
                try require(ws.activeTab?.content.hasPrefix("# Kopf\n\n") == true && ws.activeTab?.content.hasSuffix("Unberührt  _Original_ 😀\n") == true && ws.activeTab?.content.contains("OLD") == false, "Fremde Markdown-Blöcke wurden verändert")
                try await wait("Visuelles Dokumentfenster nach Sheet bereit") { window.sheets.isEmpty && window.isKeyWindow }
                try require(window.makeFirstResponder(web), "WebKit-Fokus nach Sheet fehlt")
                try await wait("WebKit besitzt Fokus") { window.firstResponder === web }
                postHistoryKey(windowNumber: window.windowNumber)
                try await wait("Visuelles Undo") { ws.activeTab?.content.utf8.elementsEqual(markdown.content.utf8) == true }
                stage = "Veraltetes Ziel"
                try await stableMarkerClick("snippetOpen", in: window, stage: stage)
                try await wait("Picker erneut offen") { ws.textSnippetSession != nil && !window.sheets.isEmpty }
                let stalePicker = try sheet()
                ws.tabs[ws.tabs.firstIndex(where: { $0.id == markdown.id })!].content = "Extern neuer Inhalt\n"
                try await wait("Stale blockiert") { ws.textSnippetSession?.targetIsCurrent == false && ws.textSnippetSession?.canInsert == false }
                try await matrix("snippets-stale", in: stalePicker)
                try await stableMarkerClick("snippetClose", in: stalePicker, stage: stage)
                try await wait("Stale geschlossen") { ws.textSnippetSession == nil && window.sheets.isEmpty }
                try require(ws.activeTab?.content == "Extern neuer Inhalt\n", "Stale-Abbruch überschreibt Dokument")
                cleanup()
                finish(true, "Sichtbarer Picker, Vorlage speichern, wiederholte Unicode-/Mehrzeilenwerte, Tab/Shift-Tab, vollständige Vorschau, echte Quelle-/WYSIWYG-Einfügung und natives Undo, Abbruch und stale Ziel; DE/EN-Layoutmatrix")
            } catch {
                fputs("SNIPPET-DIAG stage=\(stage) error=\(error.localizedDescription) session=\(String(describing: ws.textSnippetSession?.error)) responder=\(String(describing: window.sheets.first?.firstResponder))\n", stderr)
                if let session = ws.textSnippetSession {
                    fputs("SNIPPET-MODEL name=\(String(reflecting: session.definition.name)) template=\(String(reflecting: session.definition.template)) placeholders=\(session.placeholders) values=\(session.values)\n", stderr)
                }
                if let output = ProcessInfo.processInfo.environment["FASTRA_TEXT_WORKFLOW_DIR"] {
                    let url = URL(fileURLWithPath: output).appendingPathComponent("snippets-failure.png")
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        typeScrollCapture(window: window.sheets.first ?? window) { snapshot in try? snapshot?.write(to: url); done.resume() }
                    }
                }
                cleanup(); finish(false, "Textbausteine [\(stage)]: \(error.localizedDescription)")
            }
    }

}
