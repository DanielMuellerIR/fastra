// SelfTestBackgroundScroll.swift
//
// Besitzt den vollständigen Mehrfenster-Scrollablauf und seine Datei-Fixture.
// Geteilte UI-, Start- und Abschlussdienste bleiben im Root.

import AppKit
import CodeEditTextView
import CodeEditSourceEditor

final class SelfTestBackgroundScroll {
    struct Runtime {
        let currentWorkspace: () -> Workspace?
        let windows: () -> [NSWindow]
        let workspaceDefaults: () -> UserDefaults
        let activateApplication: (Bool) -> Void
        let editorTextView: (NSView) -> NSView?
        let sourceEditorController: (TextView) -> TextViewController?
        let waitFor: (TimeInterval, TimeInterval, @escaping () -> Bool,
                      @escaping (SelfTestPollBudget) -> Void, @escaping () -> Void) -> Void
        let finish: (SelfTestOutcome, String) -> Never
    }

    private let runtime: Runtime

    init(runtime: Runtime) { self.runtime = runtime }

    var fixtureDirectory: URL? { backgroundScrollFixtureDirectory }

    /// Die Rootschleife entfernt erst die Verzeichnisse und leert danach
    /// die Referenz an derselben Stelle wie vor der Familientrennung.
    func clearFixtureDirectoryReference() { backgroundScrollFixtureDirectory = nil }

    private func workspaceDefaults() -> UserDefaults { runtime.workspaceDefaults() }

    private func activateApplication(ignoringOtherApps: Bool) {
        runtime.activateApplication(ignoringOtherApps)
    }

    private func editorTextView(in view: NSView) -> NSView? { runtime.editorTextView(view) }

    private func sourceEditorController(for textView: TextView) -> TextViewController? {
        runtime.sourceEditorController(textView)
    }

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

    /// Echte gespeicherte Datei des Mehrfenster-Scrolltests. Das Sichern im
    /// Vorderfenster ist der gemeldete Auslöser, nicht nur eine künstliche
    /// SwiftUI-Neubewertung.
    private var backgroundScrollFixtureDirectory: URL?

    // MARK: - -selftest bgscroll

    /// Hintergrundfenster dürfen bei prozessweiten SwiftUI-Neubewertungen nie
    /// ungefragt scrollen.
    ///
    /// Hintergrund: Der Treffer-Sprung schreibt eine `CursorPosition` mit
    /// `range == .notFound` in den Editor-State; der CESE-Coordinator verwirft
    /// die aufgelöste Rückmeldung im `isUpdatingFromRepresentable`-Fenster —
    /// State und Controller konvergieren danach nie. Der 4c-Patch in build.sh
    /// (`updateControllerWithState`) feuerte deshalb bei jeder Neubewertung
    /// erneut `setCursorPositions(..., scrollToVisible: true)`: Sobald eine
    /// prozessweite Einstellung (hier: UI-Zoom) alle EditorViews neu bewertete,
    /// scrollte auch ein nie angefasstes Hintergrund-Fenster zurück zu seinem
    /// alten Sprungziel. Der Fix bindet das Scrollen ans Key-Window; dieser
    /// Test stellt genau das Szenario nach und misst, dass der Ausschnitt des
    /// hinteren Fensters stehen bleibt.
    func runBackgroundScrollTest() {
        guard let frontWorkspace = self.runtime.currentWorkspace(),
              let frontWindow = self.runtime.windows().first(where: {
                  !SearchWindow.isSearchWindow($0)
                      && WorkspaceWindowRegistry.workspace(for: $0) === frontWorkspace
                      && $0.isVisible
              }) else {
            self.finish(false, "kein erstes Dokumentfenster mit Workspace-Zuordnung")
        }
        // Zweites Fenster öffnen — es wird nach dem präparierten Sprung das
        // Hintergrund-Fenster (siehe `MainActor.assumeIsolated` in multisearch).
        let backWorkspace = MainActor.assumeIsolated {
            DocumentWindowController.openNewDocument(defaults: self.workspaceDefaults())
        }
        guard let backWindow = self.runtime.windows().first(where: {
            !SearchWindow.isSearchWindow($0)
                && WorkspaceWindowRegistry.workspace(for: $0) === backWorkspace
                && $0.isVisible
        }) else {
            self.finish(false, "kein zweites Dokumentfenster mit Workspace-Zuordnung")
        }

        // Langer Inhalt in beiden Fenstern; der Treffer liegt weit unten,
        // damit der Sprung im hinteren Fenster sichtbar scrollen muss.
        var backLines = (1...200).map { "Hinteres Fenster, Zeile \($0): leer" }
        backLines[169] = "Hinteres Fenster, Zeile 170: bgscrolltreffer"
        let frontContent = (1...200)
            .map { "Vorderes Fenster, Zeile \($0)" }.joined(separator: "\n")
        let fixtureDirectory = selfTestTemporaryDirectory()
            .appendingPathComponent("fastra-bgscroll-\(UUID().uuidString)",
                                    isDirectory: true)
        let fixtureURL = fixtureDirectory.appendingPathComponent("vorn.txt")
        do {
            try FileManager.default.createDirectory(
                at: fixtureDirectory, withIntermediateDirectories: false
            )
            try frontContent.write(to: fixtureURL, atomically: true,
                                   encoding: .utf8)
            guard let index = frontWorkspace.tabs.firstIndex(where: {
                $0.id == frontWorkspace.activeTabID
            }) else {
                self.finish(false, "aktiver Vorderfenster-Tab fehlt")
            }
            var tab = frontWorkspace.tabs[index]
            tab.title = fixtureURL.lastPathComponent
            tab.path = fixtureURL.path
            tab.url = fixtureURL
            tab.content = frontContent
            tab.diskSnapshot = FileSnapshot(data: Data(frontContent.utf8),
                                             at: fixtureURL)
            tab.recordSavedContentBaseline()
            frontWorkspace.tabs[index] = tab
            self.backgroundScrollFixtureDirectory = fixtureDirectory
        } catch {
            try? FileManager.default.removeItem(at: fixtureDirectory)
            self.finish(false, "Speicher-Fixture konnte nicht angelegt werden: \(error)")
        }
        backWorkspace.activeTabContent.wrappedValue = backLines.joined(separator: "\n")
        // CESE übernimmt programmatische Binding-Änderungen nicht live; der
        // produktive Reload-Zähler remountet beide Editoren mit dem Testinhalt.
        frontWorkspace.editorReloadNonce += 1
        backWorkspace.editorReloadNonce += 1

        self.activateApplication(ignoringOtherApps: true)
        self.pollBackgroundScrollEditors(frontWindow: frontWindow,
                                    backWorkspace: backWorkspace,
                                    backWindow: backWindow)
    }

    /// Wartet, bis beide Editoren montiert sind und der hintere den Testinhalt
    /// wirklich zeigt, und löst dann den echten Treffer-Sprung aus (derselbe
    /// Weg wie Suchtreffer-Klick und ⌘G, siehe `postMatchJump`).
    private func pollBackgroundScrollEditors(frontWindow: NSWindow,
                                                    backWorkspace: Workspace,
                                                    backWindow: NSWindow) {
        // Der hintere Editor muss über drei Durchläufe dieselbe View bleiben.
        var previousBackTV: TextView?
        var stableTicks = 0
        var frontTV: TextView?
        var backTV: TextView?
        self.waitFor(budget: 5, pause: 0.05,
                condition: {
                    frontTV = frontWindow.contentView.flatMap { self.editorTextView(in: $0) as? TextView }
                    backTV = backWindow.contentView.flatMap { self.editorTextView(in: $0) as? TextView }
                    stableTicks = backTV === previousBackTV ? stableTicks + 1 : 0
                    previousBackTV = backTV
                    guard let backTV, frontTV != nil,
                          self.sourceEditorController(for: backTV) != nil,
                          (backTV.string as NSString).range(of: "bgscrolltreffer").location != NSNotFound,
                          stableTicks >= 3 else { return false }
                    return true
                },
                onTimeout: { book in
                    self.finish(false, "Editoren mit Testinhalt wurden nicht bereit "
                           + "(vorderer=\(frontTV != nil), hinterer=\(backTV != nil), "
                           + "Controller=\(backTV.map { self.sourceEditorController(for: $0) != nil } ?? false), "
                           + "stabil=\(stableTicks)) — \(book.summary)")
                },
                then: {
                    guard let backTV else { self.finish(false, "hinterer Editor nach Erfolg verschwunden") }
                    self.pollBackgroundScrollReadyForJump(frontWindow: frontWindow,
                                                     backWorkspace: backWorkspace,
                                                     backWindow: backWindow,
                                                     backTV: backTV)
                })
    }

    /// Stellt vor dem einmaligen Treffer-Sprung denselben Zustand her, den ein
    /// Nutzer durch den Wechsel in das zweite Fenster erzeugt. Ein gerade neu
    /// montierter CESE-Editor kann schon Inhalt und Controller besitzen, aber
    /// noch keine Auswahl. Trifft der Sprung genau in diesen ersten
    /// Abgleich, wird die Zeile gescrollt, während die Auswahl `NSNotFound`
    /// bleibt. Passives Warten heilt diesen verlorenen Abgleich nicht.
    private func pollBackgroundScrollReadyForJump(frontWindow: NSWindow,
                                                         backWorkspace: Workspace,
                                                         backWindow: NSWindow,
                                                         backTV: TextView) {
        var previousSelection: NSRange?
        var stableTicks = 0
        var selection = NSRange(location: NSNotFound, length: 0)
        var acceptedFirstResponder = false
        self.waitFor(budget: 5, pause: 0.05,
                condition: {
                    let mountedBackTV = backWindow.contentView.flatMap {
                        self.editorTextView(in: $0) as? TextView
                    }
                    guard mountedBackTV === backTV else {
                        self.finish(false, "hinterer Editor wurde vor dem Treffer-Sprung neu aufgebaut")
                    }
                    self.activateApplication(ignoringOtherApps: true)
                    backWindow.makeKeyAndOrderFront(nil)
                    acceptedFirstResponder = backWindow.makeFirstResponder(backTV)
                    if backTV.selectionManager.textSelections.isEmpty {
                        // Entspricht `EditorView.focusActiveEditor`: Erst die echte
                        // Anfangsauswahl anlegen, dann auf CESEs Rückmeldung warten.
                        backTV.selectionManager.setSelectedRange(
                            NSRange(location: 0, length: 0)
                        )
                    }
                    selection = backTV.selectedRange()
                    let validSelection = selection.location != NSNotFound
                        && NSMaxRange(selection) <= (backTV.string as NSString).length
                    let sameSelection = previousSelection.map {
                        NSEqualRanges($0, selection)
                    } ?? false
                    stableTicks = sameSelection ? stableTicks + 1 : 0
                    previousSelection = validSelection ? selection : nil
                    return NSApp.isActive && backWindow.isKeyWindow
                        && backWindow.firstResponder === backTV
                        && acceptedFirstResponder && validSelection
                        && backWorkspace.cursorLine != nil
                        && stableTicks >= 2
                },
                onTimeout: { book in
                    // Ein fremdes Vordergrundprogramm verhindert den Fokusnachweis.
                    // Ein falsches eigenes Key-Fenster bei aktiver App bleibt ein Fehler.
                    self.finish(NSApp.isActive ? .fail : .environment, "hinterer Editor wurde vor dem Treffer-Sprung nicht eingabebereit "
                           + "(App aktiv=\(NSApp.isActive), Fenster key=\(backWindow.isKeyWindow), "
                           + "First Responder=\(backWindow.firstResponder === backTV), "
                           + "Fokus angenommen=\(acceptedFirstResponder), Auswahl=\(selection), "
                           + "Cursorzeile=\(backWorkspace.cursorLine.map(String.init) ?? "nil"), "
                           + "stabil=\(stableTicks)) — \(book.summary)")
                },
                then: {
                    let result = BufferSearch.find(
                        in: backWorkspace.activeTab?.content ?? "",
                        options: SearchOptions(find: "bgscrolltreffer", replace: "",
                                               isRegex: false, caseSensitive: true)
                    )
                    guard let target = result.matches.first, target.line == 170 else {
                        self.finish(false, "bgscrolltreffer-Testtreffer auf Zeile 170 fehlt")
                    }
                    // Der Sprung hinterlässt im Editor-State des hinteren Fensters die
                    // nie konvergierende `.notFound`-CursorPosition — genau der
                    // Zustand, in dem der alte 4c-Patch bei jeder Neubewertung erneut
                    // scrollte.
                    NotificationCenter.default.postMatchJump(target, for: backWorkspace)
                    self.pollBackgroundScrollJump(frontWindow: frontWindow,
                                             backWindow: backWindow, backTV: backTV)
                })
    }

    /// Wartet, bis der Sprung im hinteren Fenster Auswahl und sichtbares
    /// Scrollen bewirkt hat — der Beleg, dass das Sprungziel weit unten liegt.
    ///
    /// Zusätzlich muss die Scrollposition drei Ticks lang stillstehen: Der
    /// Sprung scrollt konvergierend über mehrere Runloop-Durchläufe
    /// (`convergeScroll`); ein zu frühes Zurückscrollen an den Anfang würde
    /// sonst mit dessen letzten Iterationen kollidieren und den Test flaky
    /// machen.
    private func pollBackgroundScrollJump(frontWindow: NSWindow,
                                                 backWindow: NSWindow,
                                                 backTV: TextView) {
        var lastY: CGFloat = -1
        var stableTicks = 0
        var selection = NSRange(location: NSNotFound, length: 0)
        var scrolledY: CGFloat = 0
        self.waitFor(budget: 5, pause: 0.05,
                condition: {
                    selection = backTV.selectedRange()
                    let clip = backTV.enclosingScrollView?.contentView
                    scrolledY = clip?.bounds.origin.y ?? 0
                    let isStable = scrolledY == lastY
                    let mountedBackTV = backWindow.contentView.flatMap {
                        self.editorTextView(in: $0) as? TextView
                    }
                    guard mountedBackTV === backTV else {
                        self.finish(false, "hinterer Editor wurde während des Treffer-Sprungs neu aufgebaut")
                    }
                    let arrived = selection.location != NSNotFound && selection.length > 0
                        && NSMaxRange(selection) <= (backTV.string as NSString).length
                        && (backTV.string as NSString).substring(with: selection) == "bgscrolltreffer"
                        && scrolledY > 300 && isStable && stableTicks >= 2
                    lastY = scrolledY
                    stableTicks = isStable ? stableTicks + 1 : 0
                    return arrived
                },
                onTimeout: { book in
                    self.finish(false, "Sprung im hinteren Fenster kam nicht ruhig an "
                           + "(selection=\(selection), y=\(Int(scrolledY)), stabil=\(stableTicks)) — \(book.summary)")
                },
                then: {
                    // Erst den Fensterwechsel: Solange das hintere Fenster selbst Key
                    // ist, darf auch der reparierte Patch dort scrollen — das
                    // Zurückscrollen an den Anfang passiert deshalb erst, wenn das
                    // vordere Fenster sicher Key ist.
                    frontWindow.makeKeyAndOrderFront(nil)
                    // Gezielte Negativprobe: Die Vorbereitung braucht eine aktive App.
                    // Erst hier die Test-App regulär ausblenden. So verlieren ihre
                    // Fenster über AppKit den Fokus, ohne einen Zustand zu simulieren.
                    if ProcessInfo.processInfo.environment[
                        "FASTRA_SELFTEST_DEACTIVATE_BEFORE_BGSCROLL_SWITCH"
                    ] == "1" {
                        guard NSApp.isActive, frontWindow.isKeyWindow else {
                            self.finish(false, "Fokusprobe begann ohne aktive App und vorderes Key-Fenster")
                        }
                        NSApp.hide(nil)
                        self.pollBackgroundScrollFocusLoss(frontWindow: frontWindow,
                                                      backWindow: backWindow, backTV: backTV)
                        return
                    }
                    self.pollBackgroundScrollKeyWindow(frontWindow: frontWindow,
                                                  backWindow: backWindow, backTV: backTV)
                })
    }

    /// AppKit bestätigt das Ausblenden erst in späteren Runloop-Durchläufen.
    /// Danach läuft die unveränderte eigentliche Timeout-Prüfung.
    private func pollBackgroundScrollFocusLoss(frontWindow: NSWindow,
                                                       backWindow: NSWindow,
                                                       backTV: TextView) {
        self.waitFor(budget: 2, pause: 0.05,
                condition: { NSApp.isHidden && !NSApp.isActive && !frontWindow.isKeyWindow },
                onTimeout: { book in
                    self.finish(false, "Fokusprobe konnte AppKit-Fokus nicht entziehen "
                           + "(hidden=\(NSApp.isHidden), active=\(NSApp.isActive), "
                           + "frontKey=\(frontWindow.isKeyWindow)) — \(book.summary)")
                },
                then: {
                    self.pollBackgroundScrollKeyWindow(frontWindow: frontWindow,
                                                  backWindow: backWindow, backTV: backTV)
                })
    }

    /// Wartet, bis das vordere Fenster wirklich Key ist und das hintere nicht,
    /// und scrollt das hintere Fenster dann an den Dateianfang — so, wie ein
    /// Nutzer es dort zuletzt stehen gelassen hätte.
    private func pollBackgroundScrollKeyWindow(frontWindow: NSWindow,
                                                      backWindow: NSWindow,
                                                      backTV: TextView) {
        self.waitFor(budget: 5, pause: 0.05,
                condition: { frontWindow.isKeyWindow && !backWindow.isKeyWindow },
                onTimeout: { book in
                    // Ein fremdes Vordergrundprogramm verhindert den Fokusnachweis.
                    // Ein falsches eigenes Key-Fenster bei aktiver App bleibt ein Fehler.
                    self.finish(NSApp.isActive ? .fail : .environment, "vorderes Fenster wurde nicht Key "
                           + "(App aktiv=\(NSApp.isActive), frontKey=\(frontWindow.isKeyWindow), "
                           + "backKey=\(backWindow.isKeyWindow)) — \(book.summary)")
                },
                then: {
                    // Regulärer AppKit-Weg statt synthetischer Scroll-Events (siehe
                    // AGENTS.md, Scrollen in Fenster-Selbsttests).
                    guard let scrollView = backTV.enclosingScrollView else {
                        self.finish(false, "keine ScrollView am hinteren Editor")
                    }
                    let clip = scrollView.contentView
                    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: 0))
                    scrollView.reflectScrolledClipView(clip)
                    self.pollBackgroundScrollTop(backWindow: backWindow, backTV: backTV)
                })
    }

    /// Wartet, bis der Ausschnitt des hinteren Fensters oben angekommen ist
    /// (Beleg, dass gescrollt wurde), und startet dann die eigentliche Messung.
    private func pollBackgroundScrollTop(backWindow: NSWindow,
                                                backTV: TextView) {
        var y: CGFloat = -1
        self.waitFor(budget: 5, pause: 0.05,
                condition: {
                    y = backTV.enclosingScrollView?.contentView.bounds.origin.y ?? -1
                    return y == 0
                },
                onTimeout: { book in
                    self.finish(false, "Rückscrollen an den Anfang kam nicht an (y=\(Int(y))) — \(book.summary)")
                },
                then: {
                    self.observeBackgroundScroll(backWindow: backWindow, backTV: backTV)
                })
    }

    /// Die eigentliche Prüfung speichert im Vorderfenster eine echte Datei.
    /// Dessen Workspace-/Git-Neubewertungen dürfen den alten Cursorstand im
    /// hinteren Editor nicht erneut sichtbar scrollen.
    private func observeBackgroundScroll(backWindow: NSWindow,
                                                backTV: TextView,
                                                tick: Int = 0) {
        let y = backTV.enclosingScrollView?.contentView.bounds.origin.y ?? -1
        // Toleranz für Reflow-Rauschen beim Zoomwechsel; der Fehlerfall liegt
        // um Größenordnungen darüber (Sprungziel Zeile 170).
        if y > 40 {
            self.finish(false, "Hintergrundfenster scrollte ungefragt (y=\(Int(y)))")
        }
        if tick == 5 {
            let (frontWorkspace, registeredBackWorkspace) = MainActor.assumeIsolated {
                (CommandTargeting.targetWorkspace(),
                 WorkspaceWindowRegistry.workspace(for: backWindow))
            }
            guard let workspace = frontWorkspace,
                  workspace !== registeredBackWorkspace,
                  let tabID = workspace.activeTabID else {
                self.finish(false, "Vorderfenster-Workspace zum Speichern fehlt")
            }
            workspace.activeTabContent.wrappedValue += "\nSpeicher-Auslöser"
            workspace.saveTab(id: tabID)
            guard workspace.activeTab?.isDirty == false else {
                self.finish(false, "Vorderfenster-Datei blieb nach saveTab ungespeichert")
            }
        }
        if tick >= 50 {
            self.finish(true, "Ausschnitt des Hintergrundfensters blieb nach echtem "
                   + "Speichern im Vorderfenster stehen (y=\(Int(y)))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            self.observeBackgroundScroll(backWindow: backWindow, backTV: backTV,
                                    tick: tick + 1)
        }
    }
}
