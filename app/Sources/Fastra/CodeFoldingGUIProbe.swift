import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView

@MainActor
enum CodeFoldingGUIProbe {
    static func run(checkCopy: (TextView, String) -> Bool) async -> (Bool, String) {
        let text = "If (True)\nWhile (True)\n"
            + (0..<80).map { "ALERT(\"Zeile \($0) 😀\")\n" }.joined()
            + "End while\nElse\nALERT(\"Andere\")\nEnd if\n"
            + String(repeating: "// Abstand\n", count: 90)
            + "If (False)\nALERT(\"Unten\")\nEnd if\n"
        let controller = TextViewController(string: text, language: .default,
            configuration: .init(appearance: .init(theme: EditorView.fastraTheme,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: true)),
            cursorPositions: [], highlightProviders: [FourDHighlightProvider()],
            foldProvider: CodeFoldProvider(language: .default, isFourD: true))
        controller.loadView()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Code Folding"
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 760, height: 560))
        window.makeKeyAndOrderFront(nil)
        SelfTest.activateApplication(ignoringOtherApps: true)
        window.makeFirstResponder(controller.textView)
        try? await Task.sleep(for: .milliseconds(250))
        defer { window.orderOut(nil); window.close() }
        let tv = controller.textView!
        for _ in 0..<200 {
            if controller.fastraFoldRegions.count == 4 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard controller.fastraFoldRegions.count == 4 else { return (false, "Faltbereiche fehlen") }

        func capture(_ name: String) {
            guard let directory = ProcessInfo.processInfo.environment["FASTRA_FOLDING_SCREENSHOT_DIR"],
                  let root = window.contentView else { return }
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            root.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: folder.appendingPathComponent("folding.\(name).png"))
                }
            }
        }

        func findRibbon(_ root: NSView) -> NSView? {
            if String(describing: type(of: root)) == "LineFoldRibbonView" { return root }
            return root.subviews.lazy.compactMap(findRibbon).first
        }

        func click(_ range: NSRange, option: Bool = false) -> Bool {
            controller.view.layoutSubtreeIfNeeded()
            tv.layoutManager.layoutLines()
            guard let ribbon = findRibbon(controller.view),
                  let line = tv.layoutManager.textLineForOffset(range.location) else { return false }
            let local = ribbon.convert(NSPoint(x: 0, y: line.yPos + tv.font.lineHeight / 2), from: tv)
            let point = ribbon.convert(NSPoint(x: ribbon.bounds.midX, y: local.y), to: nil)
            let contentPoint = window.contentView!.convert(point, from: nil)
            guard window.contentView!.hitTest(contentPoint) === ribbon,
                  let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                    modifierFlags: option ? .option : [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
            window.sendEvent(event)
            if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                modifierFlags: event.modifierFlags, timestamp: event.timestamp + 0.04,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0) {
                window.sendEvent(up)
            }
            return true
        }

        func doubleClickPlaceholder(_ range: NSRange) -> Bool {
            controller.view.layoutSubtreeIfNeeded()
            tv.layoutManager.layoutLines()
            guard let rect = tv.layoutManager.rectForOffset(range.location) else { return false }
            let charWidth = (" " as NSString).size(withAttributes: [.font: tv.font]).width
            let point = tv.convert(NSPoint(x: rect.minX + charWidth * 2.5,
                                           y: rect.midY), to: nil)
            let contentPoint = window.contentView!.convert(point, from: nil)
            guard window.contentView!.hitTest(contentPoint) === tv else { return false }
            // AppKit merkt sich den Empfänger des ersten Klicks. Ein allein
            // gesendeter Zweitklick würde noch an die zuvor geklickte Faltleiste gehen.
            for count in 1...2 {
                controller.view.layoutSubtreeIfNeeded()
                tv.layoutManager.layoutLines()
                guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: count * 2,
                    clickCount: count, pressure: 1),
                      let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                    modifierFlags: [], timestamp: down.timestamp + 0.04,
                    windowNumber: window.windowNumber, context: nil, eventNumber: count * 2 + 1,
                    clickCount: count, pressure: 0) else { return false }
                window.sendEvent(down)
                window.sendEvent(up)
            }
            return true
        }

        let parent = controller.fastraFoldRegions[0], child = controller.fastraFoldRegions[1]
        capture("open")
        guard click(child.range), click(parent.range), controller.fastraFoldRegions[0].isCollapsed else {
            return (false, "Echte Dreieckklicks wirkungslos")
        }
        capture("nested-closed")
        guard click(parent.range), controller.fastraFoldRegions[1].isCollapsed else {
            return (false, "Kindzustand beim Öffnen des Elternbereichs verloren")
        }
        capture("child-closed")
        guard doubleClickPlaceholder(child.range) else { return (false, "Platzhalter nicht erreichbar") }
        capture("placeholder-clicked")
        guard controller.fastraFoldRegions[1].isCollapsed == false,
              tv.fastraSafeSelectedRange == child.range else {
            return (false, "Platzhalter-Doppelklick: collapsed=\(controller.fastraFoldRegions[1].isCollapsed), Auswahl=\(tv.selectedRange()), erwartet=\(child.range)")
        }
        guard click(child.range), controller.fastraFoldRegions[1].isCollapsed else {
            return (false, "Nach Platzhalter-Doppelklick sofortiges Schließen wirkungslos")
        }
        guard click(parent.range, option: true), click(parent.range, option: true),
              controller.fastraFoldRegions.filter({ $0.range.location < parent.range.upperBound })
                .allSatisfy({ !$0.isCollapsed }) else { return (false, "Option-Klick schaltet Kinder nicht gemeinsam") }
        let bottom = controller.fastraFoldRegions.last!
        if let scroll = tv.enclosingScrollView,
           let line = tv.layoutManager.lineStorage.getLine(atOffset: bottom.range.location) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, line.yPos - 100)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        controller.view.layoutSubtreeIfNeeded()
        guard (tv.enclosingScrollView?.contentView.bounds.minY ?? 0) > 0,
              click(bottom.range), controller.fastraFoldRegions.last?.isCollapsed == true else {
            return (false, "Dreieck nach Scrollen wirkungslos")
        }
        capture("scrolled-closed")
        guard checkCopy(tv, text), tv.string == text, tv.undoManager?.canUndo != true else {
            return (false, "Folding verändert Text, Copy oder Undo")
        }
        controller.unfoldAllFastraFolds()
        return (true, "Echte Dreiecke, Option-Klick, Kindzustand, Scrollen und vollständiges Copy ohne Text-/Undo-Änderung")
    }
}
