// SelfTestTypeScroll.swift
//
// Besitzt den vollständigen Tipp-/Scrollablauf mit Fixture und Fehlerzustand.
// Gemeinsame Aufnahme-, Start- und Abschlussdienste bleiben im Root.

import AppKit
import CodeEditTextView

final class SelfTestTypeScroll {
    struct Runtime {
        let currentWorkspace: () -> Workspace?
        let windows: () -> [NSWindow]
        let mainWindowForAXChecks: () -> NSWindow?
        let workspaceDefaults: () -> UserDefaults
        let activateApplication: (Bool) -> Void
        let emojiSplitFixtureContent: () -> String
        let editorTextView: (NSView) -> NSView?
        let waitFor: (TimeInterval, TimeInterval, @escaping () -> Bool,
                      @escaping (SelfTestPollBudget) -> Void, @escaping () -> Void) -> Void
        let finish: (SelfTestOutcome, String) -> Never
        let postCmd: (String, UInt16, Int) -> Void
        let typeScrollCapture: (NSWindow,
                                @escaping (SelfTest.TypeScrollSnapshot?) -> Void) -> Void
    }

    private let runtime: Runtime

    init(runtime: Runtime) { self.runtime = runtime }

    private func mainWindowForAXChecks() -> NSWindow? { runtime.mainWindowForAXChecks() }

    private func workspaceDefaults() -> UserDefaults { runtime.workspaceDefaults() }

    private func activateApplication(ignoringOtherApps: Bool) {
        runtime.activateApplication(ignoringOtherApps)
    }

    private func emojiSplitFixtureContent() -> String { runtime.emojiSplitFixtureContent() }

    private func editorTextView(in view: NSView) -> NSView? { runtime.editorTextView(view) }

    private func waitFor(budget: TimeInterval, pause: TimeInterval,
                         condition: @escaping () -> Bool,
                         onTimeout: @escaping (SelfTestPollBudget) -> Void,
                         then body: @escaping () -> Void) {
        runtime.waitFor(budget, pause, condition, onTimeout, body)
    }

    private func finish(_ ok: Bool, _ message: String) -> Never {
        runtime.finish(ok ? .pass : .fail, message)
    }

    private func finish(_ outcome: SelfTestOutcome, _ message: String) -> Never {
        runtime.finish(outcome, message)
    }

    private func postCmd(_ character: String, keyCode: UInt16, windowNumber: Int) {
        runtime.postCmd(character, keyCode, windowNumber)
    }

    private func typeScrollCapture(window: NSWindow,
                                   completion: @escaping (SelfTest.TypeScrollSnapshot?) -> Void) {
        runtime.typeScrollCapture(window, completion)
    }

    /// BBEdit-Referenzverhalten für Tippen und Sichtbarkeit prüfen:
    /// 1. Return am Dateiende zeigt die neue Zeile.
    /// 2. Tippen nach manuellem Wegscrollen holt die Cursorzeile zurück.
    /// 3. Per Palette eingefügtes Emoji ist vollständig ausgelegt.
    /// 4. Shift+← erweitert die Auswahl über das Emoji.
    func runTypeScrollTest() {
        self.typeScrollEnvironmentNotes = []
        guard let ws = self.runtime.currentWorkspace(),
              let window = self.mainWindowForAXChecks(),
              let root = window.contentView else {
            self.finish(false, "Workspace oder Hauptfenster fehlt")
        }
        // Der Tipp-/Zeichentest braucht ein aktives Fenster; ein Direktstart
        // garantiert das nicht. Die Runner-Sperre bleibt dabei wirksam.
        self.activateApplication(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Wenige lange, weich umbrochene Markdown-Zeilen ohne End-Umbruch.
        // Der Inhalt ist höher als das Fenster; Seitenleiste und integrierte Vorschau
        // verengen den Editor (wie `emojisplit`).
        ws.sidebarWidth = 216.13671875
        ws.markdownPreviewWidth = 332.3515625
        self.workspaceDefaults().set(true, forKey: "markdown.integratedPreview")
        window.setContentSize(NSSize(width: 1100, height: 500))
        // FASTRA_TYPESCROLL_FIXTURE erlaubt die Diagnose mit einer realen
        // Datei (Kopie!); der normale Lauf nutzt das neutrale Abbild.
        let text: String
        if let path = ProcessInfo.processInfo
            .environment["FASTRA_TYPESCROLL_FIXTURE"],
           let fixture = try? String(contentsOfFile: path, encoding: .utf8) {
            text = fixture
        } else {
            text = self.emojiSplitFixtureContent()
        }
        let url = selfTestTemporaryDirectory()
            .appendingPathComponent("fastra-typescroll-\(UUID().uuidString).md")
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.finish(false, "Fixture nicht schreibbar: \(error.localizedDescription)") }
        ws.loadFile(at: url.canonicalFileURL) { ok in
            guard ok else {
                try? FileManager.default.removeItem(at: url)
                self.finish(false, "Fixture lädt nicht")
            }
            // Datei nach dem Öffnen extern ändern und den stillen Reload abwarten.
            // Erst dessen resultierenden Editorzustand prüfen.
            self.typeScrollStageExternalChange(window: window, root: root,
                                          url: url, originalText: text)
        }
    }

    /// Ändert die geöffnete Datei auf der Platte und wartet auf den stillen
    /// Reload des sauberen Tabs. Danach laufen die Tipp-Stufen auf dem
    /// neu geladenen Editorzustand.
    private func typeScrollStageExternalChange(
        window: NSWindow, root: NSView, url: URL, originalText: String
    ) {
        let changed = originalText + "\nextern ergänzte Zeile ohne Umbruch danach"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            do { try changed.write(to: url, atomically: true, encoding: .utf8) }
            catch {
                try? FileManager.default.removeItem(at: url)
                self.finish(false, "externe Änderung nicht schreibbar: \(error.localizedDescription)")
            }
            // Im echten Ablauf stößt die App-Aktivierung die Prüfung an; im
            // Selbsttest bleibt die App durchgehend aktiv → direkt aufrufen.
            self.runtime.currentWorkspace()?.checkExternalChanges()
            self.pollTypeScrollReloaded(window: window, root: root, url: url,
                                   expectedText: changed)
        }
    }

    /// Fixture bis zum Testende behalten: Die Zweitfenster-Stufe lädt dieselbe
    /// Datei erneut, während sie im ersten Fenster im Hintergrund offen bleibt.
    private var typeScrollFixtureURL: URL?
    /// Unvollständige Prüfbedingungen bleiben getrennt von echten
    /// Funktionsfehlern. `finishTypeScroll` lässt einen vorhandenen echten
    /// Fehler immer gewinnen.
    private var typeScrollEnvironmentNotes: [String] = []

    private func pollTypeScrollReloaded(
        window: NSWindow, root: NSView, url: URL, expectedText: String
    ) {
        self.waitFor(budget: 10, pause: 0.1,
                condition: { (self.editorTextView(in: root) as? TextView)?.string == expectedText },
                onTimeout: { book in
                    try? FileManager.default.removeItem(at: url)
                    self.finish(false, "stiller Reload nach externer Änderung kam nicht — \(book.summary)")
                },
                then: {
                    self.typeScrollFixtureURL = url
                    self.pollTypeScrollEditorReady(window: window, root: root,
                                              expectedText: expectedText)
                })
    }

    private func pollTypeScrollEditorReady(
        window: NSWindow, root: NSView, expectedText: String
    ) {
        var textView: TextView?
        self.waitFor(budget: 10, pause: 0.1,
                condition: {
                    guard let candidate = self.editorTextView(in: root) as? TextView,
                          candidate.string == expectedText else { return false }
                    textView = candidate
                    return true
                },
                onTimeout: { book in self.finish(false, "Editor nicht bereit — \(book.summary)") },
                then: {
                    guard let textView else { self.finish(false, "Editor nach Erfolg verschwunden") }
                    window.makeFirstResponder(textView)
                    // Ans Dateiende, Cursor hinter das letzte Zeichen.
                    let length = (textView.string as NSString).length
                    textView.selectionManager.setSelectedRange(
                        NSRange(location: length, length: 0)
                    )
                    textView.scrollSelectionToVisible()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.typeScrollStageReturn(textView: textView, failures: []) { failures in
                            self.typeScrollStageManualScroll(textView: textView,
                                                        failures: failures)
                        }
                    }
                })
    }

    /// Ist der Cursor (Kollaps-Selektion) im sichtbaren Bereich der TextView?
    private func typeScrollCaretVisible(_ textView: TextView) -> Bool {
        guard let selection = textView.selectionManager.textSelections.first,
              let rect = textView.layoutManager.rectForOffset(selection.range.max)
        else { return false }
        return textView.visibleRect.intersects(rect)
    }

    /// Stufe 1: mehrere Returns am Dateiende — jede neue Zeile muss sichtbar
    /// bleiben. Ein einzelnes Return kann noch in den Sichtbereichs-Rest
    /// unterhalb des Cursors passen; erst die Wiederholung ist streng.
    /// `label` kennzeichnet Befunde der Zweitfenster-Wiederholung;
    /// `then` übernimmt die gesammelten Befunde. `failures` hat absichtlich
    /// keinen Standardwert: Ein neuer Abschnitt muss den bisherigen Stand
    /// weitergeben, statt bereits gefundene Fehler versehentlich zu verlieren.
    private func typeScrollStageReturn(
        textView: TextView, iteration: Int = 0, failures: [String],
        label: String = "", then: @escaping ([String]) -> Void
    ) {
        var failures = failures
        if iteration >= 6 {
            // Stufe 1b: Weitertippen auf der (womöglich unsichtbaren) Zeile
            // muss die Zeile ebenfalls sichtbar machen.
            textView.insertText("nachgetippt")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if !self.typeScrollCaretVisible(textView) {
                    failures.append(label + "Tippen auf unsichtbarer Zeile scrollt nicht nach")
                }
                then(failures)
            }
            return
        }
        // Echter Tastenpfad: keyDown-Event durchs Fenster (interpretKeyEvents,
        // Input-Context, TextFormation-Filter) — nicht der Direktselektor.
        // Fällt das Event-Bauen fehl, bleibt der Selektor das Fallback.
        if let window = textView.window,
           let event = NSEvent.keyEvent(
               with: .keyDown, location: .zero, modifierFlags: [],
               timestamp: ProcessInfo.processInfo.systemUptime,
               windowNumber: window.windowNumber, context: nil,
               characters: "\r", charactersIgnoringModifiers: "\r",
               isARepeat: false, keyCode: 36
           ) {
            window.sendEvent(event)
        } else {
            textView.insertNewline(nil)
        }
        // Nach dem Tastendruck ein unabhängiges SwiftUI-Update erzwingen, wie die
        // Fußzeile im Betrieb. CESEs State-Reconcile darf eine veraltete Scrollposition
        // nicht über den frischen Tipp-Scroll zurückschreiben.
        self.runtime.currentWorkspace()?.objectWillChange.send()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if !self.typeScrollCaretVisible(textView) {
                let visible = textView.visibleRect
                let caret = textView.selectionManager.textSelections.first
                    .flatMap { textView.layoutManager.rectForOffset($0.range.max) }
                failures.append(label + "Return \(iteration + 1) am Dateiende scrollt "
                    + "nicht zur neuen Zeile (sichtbar bis y=\(Int(visible.maxY)), "
                    + "Cursor bei y=\(caret.map { Int($0.minY) } ?? -1), "
                    + "Inhaltshöhe \(Int(textView.frame.height)))")
            }
            self.typeScrollStageReturn(textView: textView, iteration: iteration + 1,
                                  failures: failures, label: label, then: then)
        }
    }

    /// Stufe 2: Von Hand nach oben scrollen, dann ein Zeichen tippen — die
    /// Cursorzeile muss zurück in den Sichtbereich kommen (BBEdit-Verhalten).
    private func typeScrollStageManualScroll(
        textView: TextView, failures: [String]
    ) {
        var failures = failures
        textView.enclosingScrollView?.contentView.scroll(to: .zero)
        textView.enclosingScrollView.map {
            $0.reflectScrolledClipView($0.contentView)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if self.typeScrollCaretVisible(textView) {
                self.typeScrollEnvironmentNotes.append(
                    "manuelles Wegscrollen wirkte nicht"
                )
            }
            textView.insertText("x")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if !self.typeScrollCaretVisible(textView) {
                    failures.append("Tippen nach manuellem Wegscrollen holt die "
                        + "Cursorzeile nicht zurück")
                }
                self.typeScrollStageEmoji(textView: textView, failures: failures)
            }
        }
    }

    /// Stufe 3+4: Emoji wie über die macOS-Palette einfügen (insertText mit
    /// replacementRange) — Auslegung sofort vollständig; Shift+← erweitert
    /// die Auswahl um das komplette Emoji.
    private func typeScrollStageEmoji(
        textView: TextView, failures: [String]
    ) {
        let ns = textView.string as NSString
        textView.selectionManager.setSelectedRange(
            NSRange(location: ns.length, length: 0)
        )
        textView.insertText("🤢", replacementRange: NSRange(location: NSNotFound, length: 0))
        // Auf vollständige Fragmente der Cursorzeile warten, statt eine feste
        // Pause anzunehmen. Die Auslegung muss ohne weitere Eingabe vollständig
        // werden; verzögertes Layout unter Last soll keinen falschen Fehler ergeben.
        self.typeScrollAwaitEmojiLayout(textView: textView) { layoutFailure in
            var failures = failures
            let after = textView.string as NSString
            if !(after as String).hasSuffix("🤢") {
                failures.append("Palette-Emoji fehlt im Text")
            }
            if let layoutFailure { failures.append(layoutFailure) }
            // Zweites Emoji wie im Repro, dann Shift+← zweimal.
            textView.insertText("🤮", replacementRange: NSRange(location: NSNotFound, length: 0))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                textView.moveLeftAndModifySelection(nil)
                let firstExtension = textView.selectionManager
                    .textSelections.first?.range.length ?? 0
                if firstExtension != 2 {
                    failures.append("Shift+← markiert hinter Emoji "
                        + "\(firstExtension) statt 2 UTF-16-Einheiten")
                }
                textView.moveLeftAndModifySelection(nil)
                let secondExtension = textView.selectionManager
                    .textSelections.first?.range.length ?? 0
                if secondExtension != 4 {
                    failures.append("Zweites Shift+← markiert "
                        + "\(secondExtension) statt 4 UTF-16-Einheiten")
                }
                self.typeScrollStagePixels(textView: textView, failures: failures)
            }
        }
    }

    /// Wartet auf vollständige Auslegung der Cursorzeile; `nil` bedeutet Erfolg,
    /// sonst folgt die Fehlermeldung mit Messwerten.
    /// CodeEditTextView legt den gezeichneten Bereich aus. Deshalb das Zeichnen
    /// je Durchlauf anstoßen, statt auf den Fenstermanager zu warten.
    /// 200 bediente Main-Queue-Durchläufe geben Gelegenheit zum Layout, ohne
    /// Fremdlast als fehlende Auslegung zu werten.
    private func typeScrollAwaitEmojiLayout(
        textView: TextView,
        completion: @escaping (String?) -> Void
    ) {
        var diagnosis = "Cursorzeile nach dem Emoji nicht auffindbar"
        self.waitFor(budget: 10, pause: 0.05,
                condition: {
                    // Zeichnen und `reflectScrolledClipView` anstoßen, damit CodeEditTextView
                    // den sichtbaren Bereich neu bestimmt und die Cursorzeile auslegt.
                    if let scrollView = textView.enclosingScrollView {
                        // Die Zeile etwas vom unteren Viewport-Rand abrücken: CESEs ausgelegter
                        // Bereich kann kleiner sein als `visibleRect`. Die Tipp-Scroll-Zusage prüft
                        // eine frühere Stufe; hier wird die Vorbedingung für den Glyphentest gesetzt.
                        if let line = textView.layoutManager.textLineForOffset(
                            max((textView.string as NSString).length - 1, 0)) {
                            let margin: CGFloat = 24
                            let bottom = line.yPos + line.height + margin
                            let visible = textView.visibleRect
                            if bottom > visible.maxY {
                                var origin = scrollView.contentView.bounds.origin
                                origin.y += bottom - visible.maxY
                                scrollView.contentView.scroll(to: origin)
                            }
                        }
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                    }
                    textView.needsDisplay = true
                    textView.window?.displayIfNeeded()
                    let text = textView.string as NSString
                    guard text.length > 0,
                          let line = textView.layoutManager.textLineForOffset(text.length - 1)
                    else {
                        // Noch keine Zeile: weiter warten, nicht stillschweigend bestehen.
                        diagnosis = "Cursorzeile nach dem Emoji nicht auffindbar"
                        return false
                    }
                    let covered = line.data.lineFragments.map(\.range.length).reduce(0, +)
                    if covered >= line.range.length - 1 {   // -1: Umbruchzeichen
                        return true
                    }
                    let lineRect = textView.layoutManager
                        .rectsFor(range: line.range).first
                    diagnosis = "Emoji-Zeile unvollständig ausgelegt: "
                        + "\(covered) von \(line.range.length), "
                        + "Zeile=\(line.range), Zeilenrechteck=\(lineRect.map { "\($0)" } ?? "keins"), "
                        + "yPos=\(line.yPos), Hoehe=\(line.height), "
                        + "Fragmente=\(line.data.lineFragments.count), "
                        + "sichtbar=\(textView.visibleRect), "
                        + "Cursor sichtbar=\(self.typeScrollCaretVisible(textView)), "
                        + "Fenster sichtbar=\(textView.window?.isVisible ?? false), "
                        + "App aktiv=\(NSApp.isActive)"
                    return false
                },
                onTimeout: { book in completion(diagnosis + " — \(book.summary)") },
                then: { completion(nil) })
    }


    /// Vergleicht dekodierte Pixel ausschließlich im Zielbereich. Cursor und
    /// frühere Auswahlflächen werden in beiden Aufnahmen vollständig ausgespart.
    static func typeScrollPixelEvaluation(before: SelfTest.TypeScrollSnapshot,
                                          after: SelfTest.TypeScrollSnapshot,
                                          region: NSRect, excluded: [NSRect])
        -> (outcome: SelfTestOutcome, info: String) {
        guard before.source == after.source, before.windowRect == after.windowRect,
              let left = NSBitmapImageRep(data: before.data),
              let right = NSBitmapImageRep(data: after.data),
              left.pixelsWide == right.pixelsWide, left.pixelsHigh == right.pixelsHigh,
              left.pixelsWide > 0, left.pixelsHigh > 0,
              before.windowRect.width > 0, before.windowRect.height > 0,
              before.windowRect.contains(region), !region.isEmpty else {
            return (.environment, "Pixel-Aufnahmen oder Zielbereich nicht vergleichbar")
        }
        let bounds = before.windowRect
        let scaleX = CGFloat(left.pixelsWide) / bounds.width
        let scaleY = CGFloat(left.pixelsHigh) / bounds.height
        guard abs(scaleX - scaleY) < 0.01 else {
            return (.environment, "Pixel-Aufnahme besitzt unerwartetes Seitenverhältnis")
        }
        let x0 = max(0, Int(floor((region.minX - bounds.minX) * scaleX)))
        let x1 = min(left.pixelsWide, Int(ceil((region.maxX - bounds.minX) * scaleX)))
        let y0 = max(0, Int(floor((bounds.maxY - region.maxY) * scaleY)))
        let y1 = min(left.pixelsHigh, Int(ceil((bounds.maxY - region.minY) * scaleY)))
        var compared = 0
        var changed = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let point = NSPoint(x: bounds.minX + (CGFloat(x) + 0.5) / scaleX,
                                    y: bounds.maxY - (CGFloat(y) + 0.5) / scaleY)
                guard region.contains(point), !excluded.contains(where: { $0.contains(point) }) else { continue }
                guard let a = left.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let b = right.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    return (.environment, "Pixel-Farben nicht auswertbar")
                }
                compared += 1
                if abs(a.redComponent - b.redComponent) > 1.0 / 255
                    || abs(a.greenComponent - b.greenComponent) > 1.0 / 255
                    || abs(a.blueComponent - b.blueComponent) > 1.0 / 255
                    || abs(a.alphaComponent - b.alphaComponent) > 1.0 / 255 {
                    changed += 1
                }
            }
        }
        guard compared > 0 else { return (.environment, "Keine Textpixel außerhalb der Ausschlussflächen") }
        return (changed > 0 ? .pass : .fail,
                "\(changed) von \(compared) Textpixeln außerhalb von Cursor und Auswahl verändert")
    }


    /// Stufe 5: Tippen muss den sichtbaren Fensterinhalt ändern.
    /// Korrekte Layout-Rechtecke allein belegen kein aktuelles Zeichnen.
    private func typeScrollStagePixels(
        textView: TextView, failures: [String]
    ) {
        guard let window = textView.window else {
            self.typeScrollEnvironmentNotes.append("Pixel-Stufe übersprungen: kein Fenster")
            self.finishTypeScroll(failures: failures, note: "")
            return
        }
        // Die Emoji-Stufe hinterlässt eine Auswahl. Ihre verschwindende
        // Markierung darf später nicht als frisch gezeichneter Text zählen.
        let oldSelection = textView.fastraSafeSelectedRange
        let insertion = NSRange(location: oldSelection.location, length: 0)
        textView.selectionManager.setSelectedRange(insertion)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard textView.selectedRange() == insertion else {
                self.typeScrollEnvironmentNotes.append(
                    "Pixel-Stufe übersprungen: Einfügeposition vor Aufnahme nicht stabil"
                )
                self.finishTypeScroll(failures: failures, note: "")
                return
            }
            self.typeScrollCapture(window: window) { before in
                guard let before else {
                    self.typeScrollEnvironmentNotes.append(
                        "Pixel-Stufe übersprungen: keine Bildschirmaufnahme"
                    )
                    self.finishTypeScroll(failures: failures, note: "")
                    return
                }
                guard textView.selectedRange() == insertion else {
                    self.typeScrollEnvironmentNotes.append(
                        "Pixel-Stufe abgebrochen: Einfügeposition während Aufnahme verändert"
                    )
                    self.finishTypeScroll(failures: failures, note: "")
                    return
                }
                let viewport = textView.visibleRect
                let editorRect = textView.convert(viewport, to: nil)
                // Die alte Auswahl kann noch in einem Backing-Store stehen.
                // Ihre Glyphzellen deshalb zusätzlich zur Einfügemarke maskieren.
                let maskedOffsets = Array(oldSelection.location..<oldSelection.upperBound) + [insertion.location]
                let beforeMasks = maskedOffsets.compactMap { offset in
                    textView.layoutManager.rectForOffset(offset).map {
                        textView.convert($0.insetBy(dx: -2, dy: -2), to: nil)
                    }
                }
                guard beforeMasks.count == maskedOffsets.count else {
                    self.typeScrollEnvironmentNotes.append("Pixel-Stufe: Cursor-/Auswahlflächen nicht vollständig messbar")
                    self.typeScrollStageSecondWindow(failures: failures, note: "")
                    return
                }
                textView.insertText("PIXELPROBE", replacementRange: NSRange(location: NSNotFound, length: 0))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.typeScrollCapture(window: window) { after in
                        guard let after else {
                            self.typeScrollEnvironmentNotes.append(
                                "Pixel-Stufe abgebrochen: keine Bildschirmaufnahme"
                            )
                            self.finishTypeScroll(failures: failures, note: "")
                            return
                        }
                        var failures = failures
                        let probe = NSRange(location: insertion.location, length: 10)
                        let source = textView.string as NSString
                        guard probe.upperBound <= source.length,
                              source.substring(with: probe) == "PIXELPROBE" else {
                            failures.append("PIXELPROBE fehlt an der Einfügeposition")
                            self.typeScrollStageSecondWindow(failures: failures, note: "")
                            return
                        }
                        let rects = (probe.location..<probe.upperBound).compactMap {
                            textView.layoutManager.rectForOffset($0)
                        }
                        guard textView.selectedRange() == NSRange(location: probe.upperBound, length: 0),
                              textView.visibleRect == viewport,
                              textView.convert(viewport, to: nil) == editorRect,
                              rects.count == probe.length, let first = rects.first,
                              rects.allSatisfy({ abs($0.minY - first.minY) < 0.5 }),
                              let caret = textView.layoutManager.rectForOffset(probe.upperBound) else {
                            self.typeScrollEnvironmentNotes.append("Pixel-Stufe: Scroll-/Zeilengeometrie nicht vergleichbar")
                            self.typeScrollStageSecondWindow(failures: failures, note: "")
                            return
                        }
                        let region = textView.convert(rects.reduce(first) { $0.union($1) }, to: nil)
                        guard editorRect.contains(region) else {
                            self.typeScrollEnvironmentNotes.append("Pixel-Stufe: Probe nicht vollständig im sichtbaren Editor")
                            self.typeScrollStageSecondWindow(failures: failures, note: "")
                            return
                        }
                        let result = Self.typeScrollPixelEvaluation(before: before, after: after,
                            region: region, excluded: beforeMasks + [
                                textView.convert(caret.insetBy(dx: -2, dy: -2), to: nil)
                            ])
                        if result.outcome == .fail { failures.append(result.info) }
                        if result.outcome == .environment { self.typeScrollEnvironmentNotes.append(result.info) }
                        self.typeScrollStageSecondWindow(failures: failures, note: "")
                    }
                }
            }
        }
    }


    /// Stufe 6: Dieselbe Datei in einem zweiten Fenster laden, während das erste
    /// sie im Hintergrund offen behält. Auch dort muss die Return-Serie sichtbar
    /// scrollen.
    private func typeScrollStageSecondWindow(
        failures: [String], note: String
    ) {
        guard let url = self.typeScrollFixtureURL,
              let firstWorkspace = self.runtime.currentWorkspace(),
              let firstWindow = self.runtime.windows().first(where: {
                  !SearchWindow.isSearchWindow($0) && $0.isVisible
                      && WorkspaceWindowRegistry.workspace(for: $0) != nil
              }) else {
            self.finishTypeScroll(
                failures: failures + ["Zweitfenster-Stufe: Ausgangszustand fehlt"],
                note: note
            )
            return
        }
        firstWindow.makeKeyAndOrderFront(nil)
        self.postCmd("n", keyCode: 45, windowNumber: firstWindow.windowNumber)
        self.pollTypeScrollSecondWindow(firstWorkspace: firstWorkspace,
                                   firstWindow: firstWindow, url: url,
                                   failures: failures, note: note)
    }

    private func pollTypeScrollSecondWindow(
        firstWorkspace: Workspace, firstWindow: NSWindow, url: URL,
        failures: [String], note: String
    ) {
        // Das neue Fenster hat einen eigenen Workspace (Registry-Muster wie
        // im newwindow-Selbsttest).
        var found: (workspace: Workspace, window: NSWindow, root: NSView)?
        self.waitFor(budget: 10, pause: 0.1,
                condition: {
                    guard let secondWindow = self.runtime.windows().first(where: {
                              !SearchWindow.isSearchWindow($0) && $0.isVisible
                                  && $0 !== firstWindow
                                  && WorkspaceWindowRegistry.workspace(for: $0) != nil
                                  && WorkspaceWindowRegistry.workspace(for: $0) !== firstWorkspace
                          }),
                          let secondWorkspace = WorkspaceWindowRegistry.workspace(for: secondWindow),
                          let secondRoot = secondWindow.contentView else { return false }
                    found = (secondWorkspace, secondWindow, secondRoot)
                    return true
                },
                onTimeout: { book in
                    self.finishTypeScroll(failures: failures
                        + ["Zweitfenster erschien nicht nach ⌘N — \(book.summary)"], note: note)
                },
                then: {
                    guard let found else {
                        self.finishTypeScroll(failures: failures + ["Zweitfenster nach Erfolg verschwunden"],
                                         note: note)
                        return
                    }
                    found.workspace.loadFile(at: url.canonicalFileURL) { ok in
                        guard ok else {
                            self.finishTypeScroll(failures: failures + ["Zweitfenster: Datei lädt nicht"],
                                             note: note)
                            return
                        }
                        self.pollTypeScrollSecondEditor(root: found.root, window: found.window,
                                                   failures: failures, note: note)
                    }
                })
    }

    private func pollTypeScrollSecondEditor(
        root: NSView, window: NSWindow, failures: [String], note: String
    ) {
        var textView: TextView?
        self.waitFor(budget: 10, pause: 0.1,
                condition: {
                    guard let candidate = self.editorTextView(in: root) as? TextView,
                          !candidate.string.isEmpty else { return false }
                    textView = candidate
                    return true
                },
                onTimeout: { book in
                    self.finishTypeScroll(failures: failures
                        + ["Zweitfenster-Editor nicht bereit — \(book.summary)"], note: note)
                },
                then: {
                    guard let textView else {
                        self.finishTypeScroll(failures: failures + ["Zweitfenster-Editor nach Erfolg verschwunden"],
                                         note: note)
                        return
                    }
                    window.makeFirstResponder(textView)
                    let length = (textView.string as NSString).length
                    textView.selectionManager.setSelectedRange(
                        NSRange(location: length, length: 0)
                    )
                    textView.scrollSelectionToVisible()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.typeScrollStageReturn(textView: textView, failures: failures,
                                              label: "Zweitfenster: ") {
                            self.finishTypeScroll(failures: $0, note: note)
                        }
                    }
                })
    }

    private func finishTypeScroll(failures: [String], note: String) {
        if let url = self.typeScrollFixtureURL {
            try? FileManager.default.removeItem(at: url)
            self.typeScrollFixtureURL = nil
        }
        let environmentNote = self.typeScrollEnvironmentNotes.isEmpty
            ? ""
            : "; unvollständig: " + self.typeScrollEnvironmentNotes.joined(separator: " ;; ")
        let outcome: SelfTestOutcome
        if !failures.isEmpty {
            outcome = .fail
        } else if !self.typeScrollEnvironmentNotes.isEmpty {
            outcome = .environment
        } else {
            outcome = .pass
        }
        self.finish(
            outcome,
            failures.isEmpty
                ? "Tippen scrollt den Cursor sichtbar und zeichnet sichtbar; "
                    + "Emoji sofort ausgelegt; Shift+← erweitert über Emojis"
                    + note + environmentNote
                : failures.joined(separator: " ;; ") + note + environmentNote
        )
    }
}
