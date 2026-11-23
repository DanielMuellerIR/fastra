// Syntaxfarben im echten Editor; Laufzeit, Abschluss und Cleanup bleiben
// beim gestarteten SelfTest. Asynchrone Fortsetzungen halten diesen Wert.
import Foundation
import AppKit
import CodeEditLanguages
import CodeEditTextView

struct SelfTestHighlighting {
    private let workspace: Workspace
    private let root: NSView
    private let waitForBody: (TimeInterval, TimeInterval, @escaping () -> Bool,
                      @escaping (SelfTestPollBudget) -> Void, @escaping () -> Void) -> Void
    private let finish: (Bool, String) -> Never
    private let editorTextViewBody: (NSView) -> NSView?
    private let fourDExpectedColorsBody: (Bool) -> [(String, Int, Int, Int)]
    private let fourDComponentMethodExpectedColorBody: (Bool) -> (Int, Int, Int)
    private let storageSubstringHasColorBody: (String, NSView, Int, Int, Int) -> Bool
    private let storageSubstringHasStyleBody: (String, NSView, Bool, Bool) -> Bool

    init(workspace: Workspace, root: NSView,
         waitFor: @escaping (TimeInterval, TimeInterval, @escaping () -> Bool,
                            @escaping (SelfTestPollBudget) -> Void, @escaping () -> Void) -> Void,
         finish: @escaping (Bool, String) -> Never,
         editorTextView: @escaping (NSView) -> NSView?,
         fourDExpectedColors: @escaping (Bool) -> [(String, Int, Int, Int)],
         fourDComponentMethodExpectedColor: @escaping (Bool) -> (Int, Int, Int),
         storageSubstringHasColor: @escaping (String, NSView, Int, Int, Int) -> Bool,
         storageSubstringHasStyle: @escaping (String, NSView, Bool, Bool) -> Bool) {
        self.workspace = workspace
        self.root = root
        self.waitForBody = waitFor
        self.finish = finish
        self.editorTextViewBody = editorTextView
        self.fourDExpectedColorsBody = fourDExpectedColors
        self.fourDComponentMethodExpectedColorBody = fourDComponentMethodExpectedColor
        self.storageSubstringHasColorBody = storageSubstringHasColor
        self.storageSubstringHasStyleBody = storageSubstringHasStyle
    }

    // Argumentlabels bleiben an den unveränderten Ablaufaufrufen lesbar;
    // die Funktionswerte führen weiterhin SelfTests private Helfer aus.
    private func waitFor(budget: TimeInterval, pause: TimeInterval,
                         condition: @escaping () -> Bool,
                         onTimeout: @escaping (SelfTestPollBudget) -> Void,
                         then: @escaping () -> Void) {
        waitForBody(budget, pause, condition, onTimeout, then)
    }

    private func editorTextView(in root: NSView) -> NSView? {
        editorTextViewBody(root)
    }

    private func fourDExpectedColors(dark: Bool) -> [(String, Int, Int, Int)] {
        fourDExpectedColorsBody(dark)
    }

    private func fourDComponentMethodExpectedColor(dark: Bool) -> (Int, Int, Int) {
        fourDComponentMethodExpectedColorBody(dark)
    }

    private func storageSubstringHasColor(_ substring: String, in root: NSView,
                                          r: Int, g: Int, b: Int) -> Bool {
        storageSubstringHasColorBody(substring, root, r, g, b)
    }

    private func storageSubstringHasStyle(_ substring: String, in root: NSView,
                                          bold: Bool, italic: Bool) -> Bool {
        storageSubstringHasStyleBody(substring, root, bold, italic)
    }

    func runHighlightTest() {
        let ws = workspace

        let tmp = selfTestTemporaryDirectory()
            .appendingPathComponent("fastra-highlight-\(UUID().uuidString).py")
        let code = """
        # Kommentar in eigener Farbe
        def greet(name):
            count = 42
            return "Hallo " + name + str(count)
        """
        do { try code.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { finish(false, "Temp-Datei nicht schreibbar: \(error.localizedDescription)") }

        ws.loadFile(at: tmp) { ok in
            guard ok else {
                try? FileManager.default.removeItem(at: tmp)
                finish(false, "loadFile schlug fehl (completion false)")
            }
            pollHighlightColors(root: root, url: tmp)
        }
    }

    /// Pollt (max. 10 s, 0,25-s-Takt), bis der Editor-TextStorage ≥ 2
    /// verschiedene Vordergrundfarben trägt. Timeout → FAIL inkl. Diagnose
    /// (erkannte Sprache, tree-sitter-Grammatik vorhanden?, Query-Pfad).
    private func pollHighlightColors(root: NSView, url: URL) {
        var farben = 0
        waitFor(budget: 10, pause: 0.25,
                condition: {
                    farben = distinctForegroundColors(in: root)
                    return farben >= 2
                },
                onTimeout: { book in
                    let lang = CodeLanguage.detectLanguageFrom(url: url)
                    let query = lang.queryURL
                    let queryExists = query.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                    try? FileManager.default.removeItem(at: url)
                    finish(false, "monochrom (\(farben) Farbe(n)) — \(book.summary) — "
                        + "Sprache=\(lang.id.rawValue), "
                        + "tsLanguage=\(lang.language != nil ? "ok" : "NIL"), "
                        + "queryURL=\(query?.path ?? "nil") existiert=\(queryExists)")
                },
                then: {
                    try? FileManager.default.removeItem(at: url)
                    finish(true, "Editor färbt: \(farben) verschiedene Vordergrundfarben im TextStorage")
                })
    }

    func runFourDHighlightTest() {
        let ws = workspace

        // Selbst geschriebene exportierte 4D-Fixture (nichts aus der
        // 4D-Doku). Der zweite Methodenname muss nur im Projektindex stehen,
        // damit der Test die Unterscheidung von Prozessvariablen beobachtet.
        let code = """
        // Prüfsumme neu berechnen
        If (True)
        \t$summe:=$summe+1
        \tAbr_init
        \tABR_LISTE_LB_AB:=1
        \tNachtrag
        \tComponent_Shared
        \tQUERY([Auftraege:1]; [Auftraege:1]Nummer=42)
        \tALERT("fertig")
        End if
        """
        let projectRoot = selfTestTemporaryDirectory()
            .appendingPathComponent("fastra-highlight4d-\(UUID().uuidString)")
        let methods = projectRoot.appendingPathComponent("Project/Sources/Methods",
                                                          isDirectory: true)
        let componentMethods = projectRoot.appendingPathComponent(
            "Components/FastraTools.4dbase/Project/Sources/Methods",
            isDirectory: true
        )
        let tmp = methods.appendingPathComponent("Highlight.4dm")
        do {
            try FileManager.default.createDirectory(at: methods, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: componentMethods, withIntermediateDirectories: true
            )
            try code.write(to: tmp, atomically: true, encoding: .utf8)
            try "// Projektindex-Fixture\n".write(
                to: methods.appendingPathComponent("Abr_init.4dm"), atomically: true,
                encoding: .utf8
            )
            try "//%attributes = {\"shared\":true}\n".write(
                to: componentMethods.appendingPathComponent("Component_Shared.4dm"),
                atomically: true, encoding: .utf8
            )
        } catch {
            try? FileManager.default.removeItem(at: projectRoot)
            finish(false, "4D-Projekt-Fixture nicht schreibbar: \(error.localizedDescription)")
        }

        // Erst hell erzwingen — der Test darf nicht vom System-Modus abhängen.
        NSApp.appearance = NSAppearance(named: .aqua)
        ws.openProject(at: projectRoot)
        pollFourDProjectMethodIndex(ws: ws, root: root, projectRoot: projectRoot,
                                    file: tmp, code: code)
    }

    private func pollFourDProjectMethodIndex(ws: Workspace, root: NSView,
                                                    projectRoot: URL, file: URL,
                                                    code: String) {
        waitFor(budget: 10, pause: 0.25,
                condition: {
                    ws.fourDProjectMethodNames.contains("abr_init")
                        && ws.fourDComponentMethods["component_shared"] != nil
                },
                onTimeout: { book in
                    ws.closeProject()
                    try? FileManager.default.removeItem(at: projectRoot)
                    finish(false, "4D-Indizes enthalten Abr_init/Component_Shared "
                        + "nicht — \(book.summary)")
                },
                then: {
                    ws.loadFile(at: file) { ok in
                        guard ok else {
                            ws.closeProject()
                            try? FileManager.default.removeItem(at: projectRoot)
                            finish(false, "loadFile (.4dm) schlug fehl")
                        }
                        pollFourDColors(
                            root: root, url: file, dark: false,
                            indexedMethod: "Abr_init", componentMethod: "Component_Shared") {
                            // Hell bestanden → dunkel umschalten und erneut beobachten.
                            NSApp.appearance = NSAppearance(named: .darkAqua)
                            pollFourDColors(
                                root: root, url: file, dark: true,
                                indexedMethod: "Abr_init", componentMethod: "Component_Shared") {
                                runFourDDynamicProjectMethodIndexTest(
                                    ws: ws, root: root, projectRoot: projectRoot, file: file, code: code
                                )
                            }
                        }
                }
                })
    }

    /// Ergänzt nach dem tatsächlichen Öffnen nur die Indexdatei einer Methode.
    /// `Nachtrag` steht schon im sichtbaren Text: Er muss zuerst die Farbe
    /// einer Prozessvariablen haben und wechselt dann ohne Textmutation zur
    /// Projektmethodenfarbe. So prüft der Test ausschließlich den Index-
    /// Refresh und nicht eine nebenbei ausgelöste Editor-Neuerstellung.
    private func runFourDDynamicProjectMethodIndexTest(
        ws: Workspace, root: NSView, projectRoot: URL, file: URL, code: String
    ) {
        pollFourDProcessVariableColor(root: root, url: file, dark: true,
                                      name: "Nachtrag") {
            beginFourDProjectMethodIndexRefresh(
                ws: ws, root: root, projectRoot: projectRoot, file: file, code: code
            )
        }
    }

    private func beginFourDProjectMethodIndexRefresh(
        ws: Workspace, root: NSView, projectRoot: URL, file: URL, code: String
    ) {
        guard let textView = editorTextView(in: root) as? TextView else {
            ws.closeProject()
            try? FileManager.default.removeItem(at: projectRoot)
            finish(false, "4D-Index-Refresh ohne sichtbare TextView")
        }
        let identity = ObjectIdentifier(textView)
        let selection = textView.selectedRange()
        let visibleOrigin = textView.visibleRect.origin
        let addedMethod = projectRoot.appendingPathComponent("Project/Sources/Methods/Nachtrag.4dm")
        do {
            try "// nachträglich angelegte Projektmethode\n".write(
                to: addedMethod, atomically: true, encoding: .utf8
            )
        } catch {
            ws.closeProject()
            try? FileManager.default.removeItem(at: projectRoot)
            finish(false, "4D-Index-Fixture nicht ergänzbar: \(error.localizedDescription)")
        }
        pollFourDAddedMethod(
            ws: ws, root: root, projectRoot: projectRoot, file: file, code: code,
            textViewIdentity: identity, selection: selection, visibleOrigin: visibleOrigin)
    }

    private func pollFourDAddedMethod(
        ws: Workspace, root: NSView, projectRoot: URL, file: URL, code: String,
        textViewIdentity: ObjectIdentifier, selection: NSRange, visibleOrigin: NSPoint
    ) {
        waitFor(budget: 10, pause: 0.25,
                condition: { ws.fourDProjectMethodNames.contains("nachtrag") },
                onTimeout: { book in
                    ws.closeProject()
                    try? FileManager.default.removeItem(at: projectRoot)
                    finish(false, "4D-Index aktualisiert die nachträglich angelegte Methode nicht — \(book.summary)")
                },
                then: {
                    pollFourDColors(root: root, url: file, dark: true, indexedMethod: "Nachtrag") {
                        guard let textView = editorTextView(in: root) as? TextView,
                              ObjectIdentifier(textView) == textViewIdentity,
                              textView.selectedRange() == selection,
                              abs(textView.visibleRect.origin.x - visibleOrigin.x) < 1,
                              abs(textView.visibleRect.origin.y - visibleOrigin.y) < 1 else {
                            ws.closeProject()
                            try? FileManager.default.removeItem(at: projectRoot)
                            finish(false, "4D-Index-Refresh veränderte TextView, Selektion oder Scrollposition")
                        }
                        ws.closeProject()
                        guard ws.projectURL == nil, ws.fourDProjectMethodNames.isEmpty else {
                            try? FileManager.default.removeItem(at: projectRoot)
                            finish(false, "4D-Methodenindex blieb nach Projekt-Schließen aktiv")
                        }
                        NSApp.appearance = NSAppearance(named: .aqua)
                        try? FileManager.default.removeItem(at: projectRoot)
                        // 4D ist auch manuell
                        // wählbar — an einer Nicht-.4dm-Datei prüfen.
                        runFourDManualOverridePhase(ws: ws, root: root, code: code)
                }
                })
    }

    /// Manueller 4D-Override end-to-end: eine .txt-Datei mit 4D-Inhalt zeigt
    /// zunächst keine 4D-Farben; nach `setCustomLanguageOverride(.fourD)`
    /// erscheinen sie; „Automatisch“ entfernt sie wieder. Beobachtet wird
    /// jeweils der echte Editor-TextStorage (wie in den Phasen davor).
    private func runFourDManualOverridePhase(ws: Workspace, root: NSView,
                                                    code: String) {
        let txt = selfTestTemporaryDirectory()
            .appendingPathComponent("fastra-highlight4d-\(UUID().uuidString).txt")
        do { try code.write(to: txt, atomically: true, encoding: .utf8) }
        catch { finish(false, "(override) Temp-Datei nicht schreibbar") }
        ws.loadFile(at: txt) { ok in
            guard ok else {
                try? FileManager.default.removeItem(at: txt)
                finish(false, "(override) loadFile (.txt) schlug fehl")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                // Vorbedingung: als Plaintext keine 4D-Befehlsfarbe.
                let cmd = fourDExpectedColors(dark: false)[0]
                guard !storageContainsColor(in: root, r: cmd.1, g: cmd.2, b: cmd.3) else {
                    try? FileManager.default.removeItem(at: txt)
                    finish(false, "(override) .txt zeigt 4D-Farben schon OHNE Override")
                }
                ws.setCustomLanguageOverride(CustomLanguageRegistry.fourD)
                pollFourDColors(root: root, url: txt, dark: false) {
                    // Zurück auf Automatik → Farben müssen verschwinden.
                    ws.setLanguageOverride(nil)
                    pollFourDColorsGone(ws: ws, root: root, url: txt)
                }
            }
        }
    }

    private func pollFourDColorsGone(ws: Workspace, root: NSView, url: URL) {
        let cmd = fourDExpectedColors(dark: false)[0]
        waitFor(budget: 10, pause: 0.25,
                condition: { !storageContainsColor(in: root, r: cmd.1, g: cmd.2, b: cmd.3) },
                onTimeout: { book in
                    NSApp.appearance = nil
                    try? FileManager.default.removeItem(at: url)
                    finish(false, "(override) 4D-Farben bleiben nach Rückkehr zur Automatik — \(book.summary)")
                },
                then: {
                    NSApp.appearance = nil   // zurück zum Systemmodus
                    try? FileManager.default.removeItem(at: url)
                    finish(true, "4D-Farben hell + dunkel beobachtet; manueller Override "
                        + "färbt .txt und „Automatisch“ räumt wieder")
                })
    }

    private func fourDMethodExpectedColor(dark: Bool) -> (Int, Int, Int) {
        dark ? (0x0F, 0x93, 0x0A) : (0x00, 0x00, 0x88)
    }

    private func pollFourDColors(root: NSView, url: URL, dark: Bool,
                                        indexedMethod: String? = nil,
                                        componentMethod: String? = nil,
                                        then next: @escaping () -> Void) {
        let expected = fourDExpectedColors(dark: dark)
        var missing: [(String, Int, Int, Int)] = []
        waitFor(budget: 10, pause: 0.25,
                condition: {
                    // Jede Kategorie wird an ihrem eigenen 4D-Substring geprüft. Das ist
                    // strenger als „irgendein Pixel hat diese Farbe“ und verhindert etwa,
                    // dass eine Zeichenkette versehentlich durch eine andere Kategorie
                    // als vorhanden gilt.
                    let expectedSubstrings = [
                        (expected[0], "QUERY"),
                        (expected[1], "If"),
                        (expected[2], "$summe"),
                        (expected[3], "ABR_LISTE_LB_AB"),
                        (expected[4], "[Auftraege:1]"),
                        (expected[5], "Nummer"),
                        (expected[6], "\"fertig\""),
                        (expected[7], "// Prüfsumme neu berechnen"),
                    ]
                    missing = expectedSubstrings.compactMap { expected, substring in
                        storageSubstringHasColor(substring, in: root,
                                                 r: expected.1, g: expected.2, b: expected.3)
                            ? nil : expected
                    }
                    let methodColor = fourDMethodExpectedColor(dark: dark)
                    if let indexedMethod, (!storageSubstringHasColor(
                        indexedMethod, in: root, r: methodColor.0, g: methodColor.1, b: methodColor.2
                    ) || !storageSubstringHasStyle(indexedMethod, in: root, bold: true, italic: true)) {
                        missing.append(("Projektmethode \(indexedMethod)", methodColor.0,
                                        methodColor.1, methodColor.2))
                    }
                    let componentColor = fourDComponentMethodExpectedColor(dark: dark)
                    if let componentMethod, (!storageSubstringHasColor(
                        componentMethod, in: root, r: componentColor.0,
                        g: componentColor.1, b: componentColor.2
                    ) || !storageSubstringHasStyle(
                        componentMethod, in: root, bold: true, italic: false
                    )) {
                        missing.append(("Komponentenmethode \(componentMethod)", componentColor.0,
                                        componentColor.1, componentColor.2))
                    }
                    return missing.isEmpty
                },
                onTimeout: { book in
                    try? FileManager.default.removeItem(at: url)
                    NSApp.appearance = nil
                    finish(false, "\(dark ? "dunkel" : "hell"): Farben fehlen: "
                        + missing.map(\.0).joined(separator: ", ") + " — \(book.summary)")
                },
                then: next)
    }

    /// Wartet, bis der bereits sichtbare Name die Prozessvariablenfarbe hat.
    /// Erst danach wird die neue `.4dm`-Datei angelegt, damit der spätere
    /// Vergleich wirklich dieselbe Textstelle vor und nach dem Indexwechsel
    /// betrachtet.
    private func pollFourDProcessVariableColor(
        root: NSView, url: URL, dark: Bool, name: String,
        then next: @escaping () -> Void
    ) {
        let expected = fourDExpectedColors(dark: dark)[3]
        waitFor(budget: 10, pause: 0.25,
                condition: {
                    storageSubstringHasColor(name, in: root,
                                             r: expected.1, g: expected.2, b: expected.3)
                },
                onTimeout: { book in
                    try? FileManager.default.removeItem(at: url)
                    NSApp.appearance = nil
                    finish(false, "Prozessvariable \(name) hat nicht die erwartete Farbe — \(book.summary)")
                },
                then: next)
    }

    /// Sucht eine konkrete sRGB-Farbe unter den `.foregroundColor`-Attributen
    /// des echten Editor-TextStorage (Toleranz ~1,5/255 je Kanal).
    private func storageContainsColor(in root: NSView,
                                             r: Int, g: Int, b: Int) -> Bool {
        guard let tv = editorTextView(in: root) as? TextView,
              let storage = tv.textStorage, storage.length > 0 else { return false }
        var found = false
        storage.enumerateAttribute(.foregroundColor,
                                   in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else { return }
            let tolerance = 1.5 / 255.0
            if abs(color.redComponent - Double(r) / 255) < tolerance,
               abs(color.greenComponent - Double(g) / 255) < tolerance,
               abs(color.blueComponent - Double(b) / 255) < tolerance {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Zählt die verschiedenen `.foregroundColor`-Attribute im echten
    /// Editor-TextStorage (sRGB-normalisiert, damit gleiche Farben in
    /// unterschiedlichen Colorspaces nicht doppelt zählen).
    private func distinctForegroundColors(in root: NSView) -> Int {
        guard let tv = editorTextView(in: root) as? TextView,
              let storage = tv.textStorage, storage.length > 0 else { return 0 }
        var seen = Set<String>()
        storage.enumerateAttribute(.foregroundColor,
                                   in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let color = value as? NSColor,
                  let srgb = color.usingColorSpace(.sRGB) else { return }
            seen.insert(String(format: "%.3f/%.3f/%.3f",
                               srgb.redComponent, srgb.greenComponent, srgb.blueComponent))
        }
        return seen.count
    }
}
