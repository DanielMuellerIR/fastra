// SelfTestFourDCompletion.swift
//
// Besitzt den vollständigen mehrstufigen 4D-Completion-Ablauf samt Fixture
// und Fehlerzustand. Gemeinsame Mess- und Abschlussdienste bleiben im Root.

import AppKit
import CodeEditTextView

struct SelfTestFourDCompletion {
    struct Runtime {
        let currentWorkspace: () -> Workspace?
        let windows: () -> [NSWindow]
        let missingWorkspaceMessage: () -> String
        let waitFor: (TimeInterval, TimeInterval, @escaping () -> Bool,
                      @escaping (SelfTestPollBudget) -> Void, @escaping () -> Void) -> Void
        let finish: (SelfTestOutcome, String) -> Never
        let postKey: (String, UInt16, Int) -> Void
        let editorTextView: (NSView) -> NSView?
        let fourDComponentMethodExpectedColor: (Bool) -> (Int, Int, Int)
        let storageSubstringHasColor: (String, NSView, Int, Int, Int) -> Bool
        let storageSubstringHasStyle: (String, NSView, Bool, Bool) -> Bool
    }

    private let runtime: Runtime

    init(runtime: Runtime) { self.runtime = runtime }

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

    private func postKey(_ character: String, keyCode: UInt16, windowNumber: Int) {
        runtime.postKey(character, keyCode, windowNumber)
    }

    private func editorTextView(in view: NSView) -> NSView? { runtime.editorTextView(view) }

    private func fourDComponentMethodExpectedColor(dark: Bool) -> (Int, Int, Int) {
        runtime.fourDComponentMethodExpectedColor(dark)
    }

    private func storageSubstringHasColor(_ substring: String, in root: NSView,
                                         r: Int, g: Int, b: Int) -> Bool {
        runtime.storageSubstringHasColor(substring, root, r, g, b)
    }

    private func storageSubstringHasStyle(_ substring: String, in root: NSView,
                                         bold: Bool, italic: Bool) -> Bool {
        runtime.storageSubstringHasStyle(substring, root, bold, italic)
    }


    /// Zustand für den mehrstufigen Completion-Selbsttest. Die Prüfschritte
    /// sammeln ihre Befunde, damit ein defektes Auto-Popup die unabhängige
    /// Prüfung von ⌃Leertaste, Pfeil und Maus nicht überspringt.
    private final class FourDCompletionTestState {
        let projectRoot: URL
        let fileURL: URL
        let initialText: String
        let componentMethod = "ZZF_ComponentShared"
        var failures: [String] = []

        init(projectRoot: URL, fileURL: URL, initialText: String) {
            self.projectRoot = projectRoot
            self.fileURL = fileURL
            self.initialText = initialText
        }
    }

    /// Reproduziert die 4D-Vervollständigung am laufenden
    /// CodeEditSourceEditor: Eine echte `.4dm` wird geladen, `A` und `L`
    /// gehen über die öffentliche TextView-Eingabe hinein, anschließend öffnet
    /// ⌃Leertaste die gleiche Liste. Gemessen wird nicht die Delegate-Logik, sondern das
    /// sichtbare CESE-Fenster mit seiner echten `NSTableView`.
    ///
    /// Danach muss ↓ die Auswahl bewegen, ein gezielter Mausklick die Auswahl
    /// ändern und ein Doppelklick die erste 4D-Vervollständigung übernehmen.
    /// Damit schützt der Test genau die Anbindung, die reine Unit-Tests nicht
    /// sehen: Text-Delegate, Event-Monitore, Fenster und Hit-Testing.
    func runFourDCompletionTest() {
        guard let ws = runtime.currentWorkspace() else {
            finish(false, runtime.missingWorkspaceMessage())
        }
        guard let mainWindow = runtime.windows().first(where: {
            $0.frameAutosaveName != SearchWindow.frameAutosaveName
                && $0.contentView != nil && $0.isVisible
        }), let root = mainWindow.contentView else {
            finish(false, "kein Hauptfenster gefunden")
        }

        // Echtes temporäres 4D-Projekt: Die geteilte Methode muss durch den
        // produktiven Komponentenindex in den produktiven Completion-Provider
        // gelangen. Das leere Aufruferdokument erzeugt danach nur die
        // ausdrücklich eingegebenen Präfixe.
        let projectRoot = selfTestTemporaryDirectory()
            .appendingPathComponent("fastra-completion4d-\(UUID().uuidString)")
        let methods = projectRoot.appendingPathComponent(
            "Project/Sources/Methods", isDirectory: true
        )
        let componentMethods = projectRoot.appendingPathComponent(
            "Components/FastraTools.4dbase/Project/Sources/Methods",
            isDirectory: true
        )
        let url = methods.appendingPathComponent("Aufrufer.4dm")
        // `Workspace.loadFile` kanonisiert `/var` zu `/private/var`. Der Test
        // muss dieselbe URL-Form speichern, sonst würde er einen korrekt
        // geladenen 4D-Tab fälschlich nie als aktiv erkennen.
        let fixtureText = "// Completion-Selbsttest\n"
        let state = FourDCompletionTestState(
            projectRoot: projectRoot.canonicalFileURL,
            fileURL: url.canonicalFileURL,
            initialText: fixtureText
        )
        do {
            try FileManager.default.createDirectory(
                at: methods, withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: componentMethods, withIntermediateDirectories: true
            )
            try fixtureText.write(to: url, atomically: true, encoding: .utf8)
            try "//%attributes = {\"shared\":true}\n".write(
                to: componentMethods.appendingPathComponent("\(state.componentMethod).4dm"),
                atomically: true, encoding: .utf8
            )
        } catch {
            try? FileManager.default.removeItem(at: projectRoot)
            finish(false, "Completion-Fixture nicht schreibbar: \(error.localizedDescription)")
        }

        NSApp.appearance = NSAppearance(named: .aqua)
        ws.openProject(at: state.projectRoot)
        pollForFourDCompletionComponentIndex(
            ws: ws, mainWindow: mainWindow, root: root, state: state
        )
    }

    private func pollForFourDCompletionComponentIndex(
        ws: Workspace,
        mainWindow: NSWindow,
        root: NSView,
        state: FourDCompletionTestState
    ) {
        waitFor(budget: 6, pause: 0.05,
                condition: { ws.fourDComponentMethods[state.componentMethod.lowercased()] != nil },
                onTimeout: { book in
                    finishFourDCompletionTest(
                        state, ok: false,
                        message: "Shared-Component-Methode nicht indiziert — \(book.summary)"
                    )
                },
                then: {
                    ws.loadFile(at: state.fileURL) { ok in
                        guard ok else {
                            finishFourDCompletionTest(state, ok: false,
                                                      message: "loadFile (.4dm) schlug fehl")
                        }
                        pollForFourDCompletionEditor(
                            ws: ws, mainWindow: mainWindow, root: root, state: state
                        )
                    }
                })
    }

    /// Wartet auf die neu gemountete TextView der `.4dm`-Datei. Ein
    /// gewöhnlicher Delay wäre hier unscharf: Der Tab-Wechsel erzeugt den
    /// SourceEditor neu, und erst diese Instanz trägt den 4D-Delegate.
    private func pollForFourDCompletionEditor(
        ws: Workspace,
        mainWindow: NSWindow,
        root: NSView,
        state: FourDCompletionTestState
    ) {
        // Zwei Stufen in einer Frist: erst der montierte `.4dm`-Editor, dann
        // das Key-Fenster.
        var stage = 0
        var textView: TextView?
        waitFor(budget: 6, pause: 0.05,
                condition: {
                    // Die vom Workspace kanonisierte URL kann auf macOS einen anderen
                    // Pfad-Alias tragen. Für diese Test-Fixture ist die aktive, geladene
                    // `.4dm`-Endung die robuste und zugleich produktrelevante Bedingung.
                    let isFourDTab = ws.activeTab?.isLoading == false
                        && ws.activeTab?.url?.pathExtension.lowercased() == "4dm"
                    guard isFourDTab,
                          let candidate = completionEditorTextView(in: root, window: mainWindow,
                                                                   expectedText: state.initialText) else {
                        stage = 0
                        return false
                    }
                    textView = candidate
                    stage = 1
                    // Der CESE-Monitor reagiert nur im Key-Window. Der Runner holt
                    // die Test-App dafür nach vorn; verliert der Nutzer oder macOS
                    // diesen Fokus, wäre ein fehlendes Popup kein Produktbefund.
                    return mainWindow.isKeyWindow
                },
                onTimeout: { book in
                    if stage == 0 {
                        finishFourDCompletionTest(state, ok: false,
                                                  message: "`.4dm`-Editor nicht aktiv/montiert — \(book.summary)")
                    }
                    finishFourDCompletionTest(state, outcome: .environment,
                                              message: "Umgebungsproblem: 4D-Editor wurde nicht Key-Window (\(book.summary))")
                },
                then: {
                    guard let textView else {
                        finishFourDCompletionTest(state, ok: false, message: "4D-Editor nach Erfolg verschwunden")
                    }
                    guard mainWindow.makeFirstResponder(textView) else {
                        finishFourDCompletionTest(state, ok: false,
                                                  message: "4D-Editor wurde nicht First Responder")
                    }
                    // Zwei Einfügungen am laufenden TextView. Diese öffentliche
                    // AppKit-Eingabemethode läuft durch dieselbe CESE-Textmutation und
                    // deren Delegate wie eine getippte Taste; ein Queue-`keyDown` kann
                    // in der bewusst nicht aktivierten Selbsttest-App dagegen schon im
                    // System-Input-Context enden, bevor die TextView ihn sieht.
                    textView.selectionManager.setSelectedRange(
                        NSRange(location: (textView.string as NSString).length, length: 0)
                    )
                    guard insertCompletionCharacter("A", into: textView) else {
                        finishFourDCompletionTest(state, ok: false,
                                                  message: "konnte A für 4D-Editor nicht einfügen")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        guard insertCompletionCharacter("L", into: textView) else {
                            finishFourDCompletionTest(state, ok: false,
                                                      message: "konnte L für 4D-Editor nicht einfügen")
                        }
                        pollForAutomaticFourDCompletion(mainWindow: mainWindow,
                                                        textView: textView, state: state)
                    }
                })
    }

    /// Beobachtet das automatisch geöffnete CESE-Fenster nach der produktiven
    /// TextView-Eingabe. Die Textprüfung verhindert, dass ein fehlendes Routing
    /// fälschlich als Completion-Fehler gezählt wird.
    private func pollForAutomaticFourDCompletion(
        mainWindow: NSWindow,
        textView: TextView,
        state: FourDCompletionTestState
    ) {
        var popup: NSWindow?
        waitFor(budget: 4, pause: 0.05,   // 4 s für CESE-Task + Layout
                condition: {
                    popup = fourDCompletionWindow(attachedTo: mainWindow)
                    return popup != nil
                },
                onTimeout: { _ in
                    let expectedText = state.initialText + "AL"
                    if textView.string != expectedText {
                        let selections = textView.selectionManager.textSelections.map(\.range)
                        finishFourDCompletionTest(state, ok: false,
                                                  message: "Testeingabe kam nicht im Editor an "
                                                    + "(Text=\"\(textView.string)\", editable=\(textView.isEditable), "
                                                    + "delegate=\(String(describing: textView.delegate)), "
                                                    + "Selektionen=\(selections))")
                    }
                    state.failures.append("automatisches Popup blieb nach der Eingabe von „AL“ aus")
                    startManualFourDCompletion(mainWindow: mainWindow, textView: textView, state: state)
                },
                then: {
                    guard let popup else { finish(false, "Auto-Popup nach Erfolg verschwunden") }
                    guard let table = completionTable(in: popup), table.numberOfRows > 1 else {
                        state.failures.append("automatisches Popup hat keine auswertbare Vorschlagsliste")
                        closeAutomaticCompletionThenStartManual(mainWindow: mainWindow,
                                                                 textView: textView, state: state)
                        return
                    }
                    closeAutomaticCompletionThenStartManual(mainWindow: mainWindow,
                                                             textView: textView, state: state)
                })
    }

    /// Schließt ein vorhandenes Auto-Popup mit einem echten Escape-Event.
    /// Der Fallback räumt nur für den folgenden, unabhängigen ⌃Leertaste-Test
    /// auf; der Fehler bleibt vorher im Befund erhalten.
    private func closeAutomaticCompletionThenStartManual(
        mainWindow: NSWindow,
        textView: TextView,
        state: FourDCompletionTestState
    ) {
        postKey("\u{1b}", keyCode: 53, windowNumber: mainWindow.windowNumber)
        waitFor(budget: 1.5, pause: 0.05,
                condition: { fourDCompletionWindow(attachedTo: mainWindow) == nil },
                onTimeout: { _ in
                    state.failures.append("automatisches Popup ließ sich nicht mit Escape schließen")
                    fourDCompletionWindow(attachedTo: mainWindow)?.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        startManualFourDCompletion(mainWindow: mainWindow, textView: textView, state: state)
                    }
                },
                then: {
                    startManualFourDCompletion(mainWindow: mainWindow, textView: textView, state: state)
                })
    }

    /// Öffnet die Liste ausschließlich über den produktiven CESE-Shortcut
    /// ⌃Leertaste. Der Test ruft bewusst nicht den Delegate oder Controller
    /// direkt auf, damit ein kaputtes Event-Routing sichtbar bleibt.
    private func startManualFourDCompletion(
        mainWindow: NSWindow,
        textView: TextView,
        state: FourDCompletionTestState
    ) {
        guard mainWindow.isKeyWindow else {
            finishFourDCompletionTest(state, outcome: .environment,
                                      message: "Umgebungsproblem: Fokus vor ⌃Leertaste verloren")
        }
        guard mainWindow.makeFirstResponder(textView) else {
            finishFourDCompletionTest(state, ok: false,
                                      message: "4D-Editor verlor vor ⌃Leertaste den First Responder")
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: mainWindow.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49
        ) else {
            finishFourDCompletionTest(state, ok: false,
                                      message: "konnte ⌃Leertaste-Event nicht bauen")
        }
        NSApp.postEvent(event, atStart: false)
        pollForManualFourDCompletion(mainWindow: mainWindow, textView: textView, state: state)
    }

    /// Wartet auf die über ⌃Leertaste geöffnete Liste und beginnt erst dann
    /// die Eingabeprüfung. Das trennt „Popup erscheint nicht“ sauber von
    /// „sichtbares Popup ist nicht bedienbar“.
    private func pollForManualFourDCompletion(
        mainWindow: NSWindow,
        textView: TextView,
        state: FourDCompletionTestState
    ) {
        var found: (popup: NSWindow, table: NSTableView)?
        waitFor(budget: 4, pause: 0.05,
                condition: {
                    guard mainWindow.isKeyWindow else {
                        finishFourDCompletionTest(state, outcome: .environment,
                                                  message: "Umgebungsproblem: Fokus während ⌃Leertaste verloren")
                    }
                    guard let popup = fourDCompletionWindow(attachedTo: mainWindow),
                          let table = completionTable(in: popup), table.numberOfRows > 1 else { return false }
                    found = (popup, table)
                    return true
                },
                onTimeout: { _ in
                    state.failures.append("mit ⌃Leertaste geöffnetes Popup erschien nicht")
                    finishFourDCompletionTest(state, ok: false,
                                              message: state.failures.joined(separator: "; "))
                },
                then: {
                    guard let found else {
                        finishFourDCompletionTest(state, ok: false, message: "Popup nach Erfolg verschwunden")
                    }
                    // `items` wird in CESE über einen asynchronen Publisher in die
                    // Tabelle geschrieben. Erst nach dessen letztem Reload ist die
                    // Auswahl stabil; ein sofort geposteter Pfeil könnte sonst korrekt
                    // wirken und gleich wieder auf Zeile 0 zurückgesetzt werden.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        testFourDCompletionArrow(mainWindow: mainWindow, popup: found.popup,
                                                 textView: textView, table: found.table, state: state)
                    }
                })
    }

    /// Ein Pfeil-Event muss die Selektion der echten Vorschlagstabelle von
    /// Zeile 0 auf Zeile 1 verschieben. Das ist unabhängig davon beobachtbar,
    /// ob ein Fenster zufällig bloß gezeichnet wird.
    private func testFourDCompletionArrow(
        mainWindow: NSWindow,
        popup: NSWindow,
        textView: TextView,
        table: NSTableView,
        state: FourDCompletionTestState
    ) {
        guard mainWindow.isKeyWindow else {
            finishFourDCompletionTest(state, outcome: .environment,
                                      message: "Umgebungsproblem: Fokus vor Pfeiltaste verloren")
        }
        guard table.selectedRow == 0 else {
            state.failures.append("Vorschlagsliste startet nicht mit Zeile 0 (Ist: \(table.selectedRow))")
            testFourDCompletionClick(mainWindow: mainWindow, popup: popup,
                                     textView: textView, table: table, state: state)
            return
        }
        // NSDownArrowFunctionKey beschreibt das Event vollständig; CESE selbst
        // entscheidet aber bewusst über den Hardware-Keycode 125.
        postKey("\u{F701}", keyCode: 125, windowNumber: mainWindow.windowNumber)
        pollForFourDCompletionArrow(mainWindow: mainWindow, popup: popup,
                                    textView: textView, table: table, state: state)
    }

    private func pollForFourDCompletionArrow(
        mainWindow: NSWindow,
        popup: NSWindow,
        textView: TextView,
        table: NSTableView,
        state: FourDCompletionTestState
    ) {
        waitFor(budget: 1.2, pause: 0.03,
                condition: { table.selectedRow == 1 },
                onTimeout: { _ in
                    state.failures.append("↓ bewegte die Vorschlagsauswahl nicht (Zeile blieb \(table.selectedRow))")
                    testFourDCompletionClick(mainWindow: mainWindow, popup: popup,
                                             textView: textView, table: table, state: state)
                },
                then: {
                    testFourDCompletionClick(mainWindow: mainWindow, popup: popup,
                                             textView: textView, table: table, state: state)
                })
    }

    /// Klickt gezielt in die jeweils andere sichtbare Tabellenzeile. Damit
    /// kann der Test eine echte Mausreaktion auch dann beobachten, wenn die
    /// Pfeiltaste zuvor schon ausgefallen ist.
    private func testFourDCompletionClick(
        mainWindow: NSWindow,
        popup: NSWindow,
        textView: TextView,
        table: NSTableView,
        state: FourDCompletionTestState
    ) {
        guard mainWindow.isKeyWindow else {
            finishFourDCompletionTest(state, outcome: .environment,
                                      message: "Umgebungsproblem: Fokus vor Mausklick verloren")
        }
        let targetRow = table.selectedRow == 0 ? 1 : 0
        guard postCompletionMouseClick(in: table, row: targetRow, window: popup, clickCount: 1) else {
            finishFourDCompletionTest(state, ok: false,
                                      message: "konnte gezielten Klick in Vorschlagsliste nicht bauen")
        }
        pollForFourDCompletionClick(mainWindow: mainWindow, popup: popup,
                                    textView: textView, table: table, targetRow: targetRow,
                                    state: state)
    }

    private func pollForFourDCompletionClick(
        mainWindow: NSWindow,
        popup: NSWindow,
        textView: TextView,
        table: NSTableView,
        targetRow: Int,
        state: FourDCompletionTestState
    ) {
        waitFor(budget: 1.2, pause: 0.03,
                condition: { table.selectedRow == targetRow },
                onTimeout: { _ in
                    state.failures.append("gezielter Klick änderte die Vorschlagsauswahl nicht (Zeile blieb \(table.selectedRow))")
                    finishFourDCompletionTest(state, ok: false,
                                              message: state.failures.joined(separator: "; "))
                },
                then: {
                    // Der erste Treffer für „AL“ ist die generierte 4D-Anweisung
                    // `ALERT`. Ein Doppelklick muss sie über den normalen CESE-Pfad
                    // übernehmen — das beweist neben Hit-Testing auch die Aktivierung.
                    guard postCompletionMouseClick(in: table, row: 0, window: popup, clickCount: 2) else {
                        finishFourDCompletionTest(state, ok: false,
                                                  message: "konnte Doppelklick in Vorschlagsliste nicht bauen")
                    }
                    pollForFourDCompletionApply(mainWindow: mainWindow, textView: textView, state: state)
                })
    }

    private func pollForFourDCompletionApply(
        mainWindow: NSWindow,
        textView: TextView,
        state: FourDCompletionTestState
    ) {
        waitFor(budget: 1.2, pause: 0.03,
                condition: { textView.string == state.initialText + "ALERT" },
                onTimeout: { _ in
                    state.failures.append("Doppelklick übernahm den ersten Vorschlag nicht (Text=\"\(textView.string)\")")
                    finishFourDCompletionTest(state, ok: false,
                                              message: state.failures.joined(separator: "; "))
                },
                then: {
                    guard let root = mainWindow.contentView else {
                        finishFourDCompletionTest(
                            state, ok: false, message: "Hauptfenster verlor contentView"
                        )
                    }
                    startFourDComponentCompletion(
                        mainWindow: mainWindow, root: root, textView: textView, state: state
                    )
                })
    }

    /// Zweite, problembezogene Phase: Eine eindeutig benannte geteilte
    /// Komponentenmethode wird real getippt, im echten Popup übernommen und
    /// danach unabhängig im TextStorage auf Farbe und Schrift geprüft.
    private func startFourDComponentCompletion(
        mainWindow: NSWindow,
        root: NSView,
        textView: TextView,
        state: FourDCompletionTestState
    ) {
        // Die erste Anwendung muss ihr Fenster vollständig geschlossen haben,
        // bevor der neue Präfix eingegeben wird. 6 s wie die übrigen
        // Warteschleifen dieses Tests: Mit 2 s meldete er auf belasteter
        // Maschine etwa jeden dritten Lauf einen Fehler, obwohl das Fenster
        // nur später schloss.
        waitFor(budget: 6, pause: 0.05,
                condition: { fourDCompletionWindow(attachedTo: mainWindow) == nil },
                onTimeout: { book in
                    finishFourDCompletionTest(
                        state, ok: false,
                        message: "ALERT-Popup blieb vor der Component-Phase geöffnet — \(book.summary)"
                    )
                },
                then: {
                    if let outcome = SelfTestFocusRouting.outcome(
                        isKeyWindow: mainWindow.isKeyWindow,
                        makeFirstResponder: { mainWindow.makeFirstResponder(textView) }
                    ) {
                        finishFourDCompletionTest(
                            state, outcome: outcome,
                            message: outcome == .environment
                                ? "Umgebungsproblem: Fokus vor Component-Typeahead verloren"
                                : "4D-Editor wurde vor Component-Typeahead nicht First Responder"
                        )
                    }
                    textView.selectionManager.setSelectedRange(
                        NSRange(location: (textView.string as NSString).length, length: 0)
                    )
                    guard insertCompletionCharacter("\nZ", into: textView) else {
                        finishFourDCompletionTest(
                            state, ok: false, message: "konnte ersten Component-Präfix nicht eingeben"
                        )
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        guard insertCompletionCharacter("Z", into: textView) else {
                            finishFourDCompletionTest(
                                state, ok: false, message: "konnte zweiten Component-Präfix nicht eingeben"
                            )
                        }
                        pollForFourDComponentPopup(
                            mainWindow: mainWindow, root: root, textView: textView, state: state
                        )
                }
                })
    }

    private func pollForFourDComponentPopup(
        mainWindow: NSWindow,
        root: NSView,
        textView: TextView,
        state: FourDCompletionTestState
    ) {
        var found: (popup: NSWindow, table: NSTableView)?
        waitFor(budget: 4, pause: 0.05,
                condition: {
                    guard let popup = fourDCompletionWindow(attachedTo: mainWindow),
                          let table = completionTable(in: popup), table.numberOfRows > 0 else { return false }
                    found = (popup, table)
                    return true
                },
                onTimeout: { book in
                    finishFourDCompletionTest(
                        state, ok: false,
                        message: "Component-Typeahead-Popup blieb nach „ZZ“ aus — \(book.summary)"
                    )
                },
                then: {
                    guard let found else {
                        finishFourDCompletionTest(state, ok: false, message: "Component-Popup nach Erfolg verschwunden")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        guard postCompletionMouseClick(
                            in: found.table, row: 0, window: found.popup, clickCount: 2
                        ) else {
                            finishFourDCompletionTest(
                                state, ok: false,
                                message: "konnte Component-Vorschlag nicht doppelklicken"
                            )
                        }
                        pollForFourDComponentApply(
                            mainWindow: mainWindow, root: root,
                            textView: textView, state: state
                        )
                    }
                })
    }

    private func pollForFourDComponentApply(
        mainWindow: NSWindow,
        root: NSView,
        textView: TextView,
        state: FourDCompletionTestState
    ) {
        let expected = state.initialText + "ALERT\n" + state.componentMethod
        waitFor(budget: 3, pause: 0.05,
                condition: { textView.string == expected },
                onTimeout: { book in
                    finishFourDCompletionTest(
                        state, ok: false,
                        message: "Component-Doppelklick übernahm nicht den erwarteten Namen "
                            + "(Text=\"\(textView.string)\") — \(book.summary)"
                    )
                },
                then: {
                    pollForAppliedFourDComponentStyle(root: root, state: state)
                })
    }

    private func pollForAppliedFourDComponentStyle(
        root: NSView,
        state: FourDCompletionTestState
    ) {
        let color = fourDComponentMethodExpectedColor(dark: false)
        var colored = false
        var styled = false
        waitFor(budget: 6, pause: 0.1,
                condition: {
                    colored = storageSubstringHasColor(
                        state.componentMethod, in: root,
                        r: color.0, g: color.1, b: color.2
                    )
                    styled = storageSubstringHasStyle(
                        state.componentMethod, in: root, bold: true, italic: false
                    )
                    return colored && styled
                },
                onTimeout: { book in
                    finishFourDCompletionTest(
                        state, ok: false,
                        message: "übernommene Component-Methode falsch gerendert "
                            + "(Farbe=\(colored), fett/nicht-kursiv=\(styled)) — \(book.summary)"
                    )
                },
                then: { startManualOneCharCompletion(root: root, state: state) })
    }

    /// Manueller Ein-Zeichen-Aufruf: Nach einer neuen
    /// Zeile mit nur einem Buchstaben darf das automatische Popup nicht
    /// erscheinen (Mindestlänge 2), ⌃Leertaste muss die Liste aber öffnen —
    /// das prüft den CESE-Patch `fastra.completion.manualTrigger` am echten
    /// Event-Weg.
    private func startManualOneCharCompletion(
        root: NSView,
        state: FourDCompletionTestState
    ) {
        guard let mainWindow = root.window,
              let textView = editorTextView(in: root) as? TextView else {
            finishFourDCompletionTest(state, ok: false,
                                      message: "Editor-TextView für Ein-Zeichen-Phase nicht gefunden")
        }
        if let outcome = SelfTestFocusRouting.outcome(
            isKeyWindow: mainWindow.isKeyWindow,
            makeFirstResponder: { mainWindow.makeFirstResponder(textView) }
        ) {
            finishFourDCompletionTest(
                state, outcome: outcome,
                message: outcome == .environment
                    ? "Umgebungsproblem: Fokus vor Ein-Zeichen-Phase verloren"
                    : "4D-Editor wurde vor Ein-Zeichen-Phase nicht First Responder"
            )
        }
        // Ein noch offenes Popup der Komponenten-Phase zuerst schließen —
        // sonst gilt legitim die Ein-Zeichen-Filterung des offenen Fensters
        // und die Phase misst nicht den Auto-Trigger.
        closeCompletionPopupIfNeeded(mainWindow: mainWindow) { closed in
            guard closed else {
                finishFourDCompletionTest(
                    state, outcome: mainWindow.isKeyWindow ? .fail : .environment,
                    message: mainWindow.isKeyWindow
                        ? "Vorschlagsfenster wurde vor der Ein-Zeichen-Phase nicht stabil geschlossen"
                        : "Fokus während des Schließens der Vorschläge verloren"
                )
            }
            startManualOneCharTyping(mainWindow: mainWindow, root: root,
                                     textView: textView, state: state)
        }
    }

    /// Schließt ein eventuell offenes Vorschlagsfenster per Esc und wartet,
    /// bis es stabil weg ist (Fallback nach 1,5 s: hartes close()). Eine noch
    /// laufende Vorschlagsanforderung kann das Fenster kurz nach dem Schließen
    /// erneut öffnen; erst sechs Abfragen über mindestens 0,3 s ohne Fenster
    /// starten die nächste Phase. Nach insgesamt 60 Abfragen endet der Versuch.
    private func closeCompletionPopupIfNeeded(
        mainWindow: NSWindow, then continuation: @escaping (Bool) -> Void
    ) {
        Self.waitForCompletionPopupClosure(
            isVisible: { fourDCompletionWindow(attachedTo: mainWindow) != nil },
            escape: { postKey("\u{1b}", keyCode: 53, windowNumber: mainWindow.windowNumber) },
            forceClose: { fourDCompletionWindow(attachedTo: mainWindow)?.close() },
            schedule: { delay, action in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
            },
            completion: continuation
        )
    }

    /// Der echte Warteablauf erhält Fensterzugriff und Zeitplanung von außen,
    /// damit Wiederöffnen und erfolgloses Schließen ohne GUI prüfbar bleiben.
    static func waitForCompletionPopupClosure(
        isVisible: @escaping () -> Bool,
        escape: @escaping () -> Void,
        forceClose: @escaping () -> Void,
        schedule: @escaping (Double, @escaping () -> Void) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        func poll(tick: Int, quietSince: Int?, sentEscape: Bool, forcedClose: Bool) {
            let visible = isVisible()
            let nextQuietSince = visible ? nil : (quietSince ?? tick)
            if let nextQuietSince, tick - nextQuietSince >= 6 {
                completion(true)
                return
            }
            // Wiederöffnen setzt nur die Ruhephase zurück, nie die Gesamtfrist.
            if tick >= 60 {
                completion(false)
                return
            }
            var nextSentEscape = sentEscape
            var nextForcedClose = forcedClose
            if visible {
                if !sentEscape { escape(); nextSentEscape = true }
                if tick >= 30 && !forcedClose {
                    forceClose()
                    nextForcedClose = true
                }
            }
            // Auch nach close() erst erneut beobachten: Der Aufruf allein
            // beweist weder ein verschwundenes noch ein dauerhaft ruhiges Popup.
            schedule(0.05) {
                poll(tick: tick + 1, quietSince: nextQuietSince,
                     sentEscape: nextSentEscape, forcedClose: nextForcedClose)
            }
        }
        poll(tick: 0, quietSince: nil, sentEscape: false, forcedClose: false)
    }

    private func startManualOneCharTyping(
        mainWindow: NSWindow, root: NSView, textView: TextView,
        state: FourDCompletionTestState
    ) {
        textView.selectionManager.setSelectedRange(
            NSRange(location: (textView.string as NSString).length, length: 0)
        )
        guard insertCompletionCharacter("\nA", into: textView) else {
            finishFourDCompletionTest(state, ok: false,
                                      message: "konnte Ein-Zeichen-Präfix nicht eingeben")
        }
        // 0.6 s Karenz: In dieser Zeit dürfte ein (falsches) Auto-Popup
        // längst da sein — die produktive CESE-Task-Kette braucht < 0,2 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if fourDCompletionWindow(attachedTo: mainWindow) != nil {
                state.failures.append("Auto-Popup erschien schon bei EINEM Zeichen")
            }
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .control,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: mainWindow.windowNumber, context: nil,
                characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: false, keyCode: 49
            ) else {
                finishFourDCompletionTest(state, ok: false,
                                          message: "konnte ⌃Leertaste-Event (Ein-Zeichen) nicht bauen")
            }
            NSApp.postEvent(event, atStart: false)
            pollForManualOneCharCompletion(mainWindow: mainWindow, root: root,
                                           textView: textView, state: state)
        }
    }

    private func pollForManualOneCharCompletion(
        mainWindow: NSWindow,
        root: NSView,
        textView: TextView,
        state: FourDCompletionTestState
    ) {
        waitFor(budget: 4, pause: 0.05,
                condition: {
                    guard let popup = fourDCompletionWindow(attachedTo: mainWindow),
                          let table = completionTable(in: popup), table.numberOfRows >= 1 else { return false }
                    return true
                },
                onTimeout: { _ in
                    state.failures.append("⌃Leertaste öffnete bei EINEM Zeichen keine Liste")
                    startCommentSuppressedCompletion(mainWindow: mainWindow, root: root,
                                                     textView: textView, state: state)
                },
                then: {
                    // Popup wieder schließen (Esc), dann die Kommentar-Phase.
                    postKey("\u{1b}", keyCode: 53, windowNumber: mainWindow.windowNumber)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        fourDCompletionWindow(attachedTo: mainWindow)?.close()
                        startCommentSuppressedCompletion(mainWindow: mainWindow,
                                                         root: root, textView: textView,
                                                         state: state)
                    }
                })
    }

    /// In Kommentaren gibt es keine Vorschläge: Weder das
    /// automatische Tipp-Popup noch ⌃Leertaste dürfen hinter `// ` etwas
    /// öffnen.
    private func startCommentSuppressedCompletion(
        mainWindow: NSWindow,
        root: NSView,
        textView: TextView,
        state: FourDCompletionTestState
    ) {
        if let outcome = SelfTestFocusRouting.outcome(
            isKeyWindow: mainWindow.isKeyWindow,
            makeFirstResponder: { mainWindow.makeFirstResponder(textView) }
        ) {
            finishFourDCompletionTest(
                state, outcome: outcome,
                message: outcome == .environment
                    ? "Umgebungsproblem: Fokus vor Kommentar-Phase verloren"
                    : "4D-Editor wurde vor Kommentar-Phase nicht First Responder"
            )
        }
        textView.selectionManager.setSelectedRange(
            NSRange(location: (textView.string as NSString).length, length: 0)
        )
        guard insertCompletionCharacter("\n// A", into: textView) else {
            finishFourDCompletionTest(state, ok: false,
                                      message: "konnte Kommentarzeile nicht eingeben")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard insertCompletionCharacter("L", into: textView) else {
                finishFourDCompletionTest(state, ok: false,
                                          message: "konnte zweiten Kommentar-Buchstaben nicht eingeben")
            }
            // Gleiche Karenz wie oben — diesmal muss es still bleiben.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if fourDCompletionWindow(attachedTo: mainWindow) != nil {
                    state.failures.append("Auto-Popup erschien im Kommentar")
                }
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .control,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: mainWindow.windowNumber, context: nil,
                    characters: " ", charactersIgnoringModifiers: " ",
                    isARepeat: false, keyCode: 49
                ) else {
                    finishFourDCompletionTest(state, ok: false,
                                              message: "konnte ⌃Leertaste-Event (Kommentar) nicht bauen")
                }
                NSApp.postEvent(event, atStart: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if fourDCompletionWindow(attachedTo: mainWindow) != nil {
                        state.failures.append("⌃Leertaste öffnete im Kommentar eine Liste")
                        fourDCompletionWindow(attachedTo: mainWindow)?.close()
                    }
                    finishFourDCompletionTest(
                        state, ok: state.failures.isEmpty,
                        message: state.failures.isEmpty
                            ? "Auto/⌃Leertaste/Pfeil/Maus funktionieren; Shared-Component "
                                + "real übernommen und orange/fett gerendert; manueller "
                                + "Ein-Zeichen-Aufruf öffnet, Kommentar bleibt still"
                            : state.failures.joined(separator: "; ")
                    )
                }
            }
        }
    }

    /// Das CESE-Fenster ist intern; der Test beobachtet es deshalb über die
    /// öffentliche AppKit-Form: sichtbares Child-Window mit `NSTableView`.
    /// So bleibt der Wächter beim echten Fenster-/Hit-Test-Pfad statt an einer
    /// nur für Tests geöffneten Upstream-API hängen.
    private func fourDCompletionWindow(attachedTo mainWindow: NSWindow) -> NSWindow? {
        (mainWindow.childWindows ?? []).first { candidate in
            candidate.isVisible && completionTable(in: candidate) != nil
        }
    }

    private func completionTable(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView else { return nil }
        return completionTable(in: root)
    }

    private func completionTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = completionTable(in: child) { return table }
        }
        return nil
    }

    /// Der SwiftUI-Remount kann auslaufende Editor-Views kurz im View-Baum
    /// lassen. Für einen Eingabetest zählt deshalb nur die editierbare View
    /// des aktuellen Hauptfensters mit dem geladenen Fixture-Text.
    private func completionEditorTextView(
        in view: NSView,
        window: NSWindow,
        expectedText: String
    ) -> TextView? {
        if let textView = view as? TextView,
           textView.window === window,
           textView.isEditable,
           textView.string == expectedText,
           textView.frame.height > 50 {
            return textView
        }
        for child in view.subviews {
            if let found = completionEditorTextView(in: child, window: window,
                                                     expectedText: expectedText) {
                return found
            }
        }
        return nil
    }

    /// Erzeugt Down und Up mit derselben Fenster-Koordinate. Die Ereignisse
    /// gehen durch AppKit-Hit-Testing; ein direkter `tableView`-Methodenaufruf
    /// wäre hier wertlos, weil er den gemeldeten Fensterfehler umgehen würde.
    private func postCompletionMouseClick(
        in table: NSTableView,
        row: Int,
        window: NSWindow,
        clickCount: Int
    ) -> Bool {
        guard row >= 0, row < table.numberOfRows else { return false }
        table.layoutSubtreeIfNeeded()
        let rowRect = table.rect(ofRow: row)
        guard !rowRect.isEmpty else { return false }
        let pointInTable = NSPoint(x: rowRect.midX, y: rowRect.midY)
        let pointInWindow = table.convert(pointInTable, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: pointInWindow, modifierFlags: [],
            timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: clickCount, pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: pointInWindow, modifierFlags: [],
            timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: clickCount, pressure: 0
        ) else {
            return false
        }
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        return true
    }

    /// Fügt einen Buchstaben über die öffentliche Benutzer-Eingabe der
    /// produktiven TextView ein. Ein nicht aktiver Selbsttest-Prozess besitzt
    /// keinen System-Input-Context für `keyDown`; der explizite Range hält den
    /// gleichen CESE-Mutations-/Delegate-Pfad aber ohne dessen leere Cursor-
    /// Liste zuverlässig fest.
    private func insertCompletionCharacter(
        _ character: String,
        into textView: TextView
    ) -> Bool {
        guard !character.isEmpty else { return false }
        let insertionPoint = (textView.string as NSString).length
        textView.insertText(character as NSString,
                            replacementRange: NSRange(location: insertionPoint, length: 0))
        return true
    }

    private func finishFourDCompletionTest(
        _ state: FourDCompletionTestState,
        ok: Bool,
        message: String
    ) -> Never {
        finishFourDCompletionTest(
            state, outcome: ok ? .pass : .fail, message: message
        )
    }

    private func finishFourDCompletionTest(
        _ state: FourDCompletionTestState,
        outcome: SelfTestOutcome,
        message: String
    ) -> Never {
        runtime.currentWorkspace()?.closeProject()
        NSApp.appearance = nil
        try? FileManager.default.removeItem(at: state.projectRoot)
        let resolved = SelfTestOutcome.resolving(
            recordedFailures: state.failures,
            requestedOutcome: outcome,
            message: message
        )
        finish(resolved.outcome, resolved.message)
    }
}
