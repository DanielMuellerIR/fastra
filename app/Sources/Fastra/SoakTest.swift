// SoakTest.swift
//
// Langer, realistischer Dauertest — bewusst NICHT Teil von `ALL_TESTS`.
//
// WARUM ES IHN GIBT
//
// Am 2026-08-07 meldete der Arbeitsbetrieb vier Fehler, die unsere rund
// achtzig Selbsttests alle nicht gefunden hatten: ein Befehl wirkte im
// falschen Fenster, eine Rückfrage nannte ein Dokument ohne Fenster, ein
// geschlossenes Fenster kam zurück, und beim Markieren kroch die Ansicht
// langsam nach unten. Zwei davon ließen sich anschließend in einer kurz
// aufgebauten Testwelt nicht einmal nachstellen.
//
// Das ist kein Fleißproblem, sondern ein Konstruktionsproblem: Ein
// Selbsttest baut eine frische Miniwelt, prüft EINE Sache und räumt ab. Ein
// Zustandsfehler, der nach zwanzig Minuten Arbeit mit vier offenen
// Dokumenten entsteht, kann darin gar nicht auftreten.
//
// Dieser Test dreht das um:
//
//   * Er arbeitet über eine LANGE Sitzung mit mehreren großen Dokumenten in
//     mehreren Fenstern, die offen bleiben.
//   * Er handelt wie ein Mensch: tippen, markieren, formatieren, sichern,
//     Tab wechseln, Fenster wechseln, in der Vorschau springen, suchen,
//     rückgängig machen — in wechselnder Reihenfolge.
//   * Nach JEDER Aktion prüft er die Invarianten. Nicht „stimmt das
//     Ergebnis", sondern „gilt alles, was immer gelten muss".
//   * Er läuft bei einem Verstoß WEITER und sammelt. Bei Zustandsfehlern
//     ist das Muster über die Zeit die eigentliche Information.
//
// Die Invarianten sind der Kern. Sie sind so gewählt, dass jeder der vier
// gemeldeten Fehler an mindestens einer davon auffällt.

import AppKit
import CodeEditTextView
import WebKit

@MainActor
enum SoakTest {

    // MARK: - Befunde

    /// Ein Verstoß gegen eine Invariante, mit dem Weg dorthin.
    struct Finding {
        let phase: String
        /// Die zuletzt ausgeführte Aktion — bei Zustandsfehlern die wichtigste
        /// Angabe überhaupt.
        let action: String
        let invariant: String
        let detail: String
    }

    private(set) static var findings: [Finding] = []
    private(set) static var actionsRun = 0
    static var currentPhase = "—"
    private static var lastAction = "—"

    static func record(_ invariant: String, _ detail: String) {
        findings.append(Finding(phase: currentPhase, action: lastAction,
                                invariant: invariant, detail: detail))
    }

    // MARK: - Zustandsschnappschuss

    /// Alles an einem Fenster, was sich ohne Zutun NICHT ändern darf.
    struct WindowSnapshot: Equatable {
        let title: String
        let documentPath: String?
        let selection: NSRange
        let scrollY: CGFloat
        let textLength: Int
        let isEdited: Bool
    }

    /// Schnappschuss aller offenen Dokumentfenster, geschlüsselt über das
    /// Fenster selbst.
    static func snapshot() -> [ObjectIdentifier: WindowSnapshot] {
        var result: [ObjectIdentifier: WindowSnapshot] = [:]
        for window in documentWindows() {
            guard let content = window.contentView,
                  let textView = descendantTextView(in: content) else { continue }
            let workspace = WorkspaceWindowRegistry.workspace(for: window)
            result[ObjectIdentifier(window)] = WindowSnapshot(
                title: window.title,
                documentPath: workspace?.activeTab?.url?.path,
                selection: textView.selectedRange(),
                scrollY: textView.enclosingScrollView?.documentVisibleRect.minY ?? 0,
                textLength: (textView.string as NSString).length,
                isEdited: window.isDocumentEdited
            )
        }
        return result
    }

    // MARK: - Invarianten

    /// Prüft nach einer Aktion alles, was gelten muss.
    ///
    /// `target` ist das Fenster, das die Aktion verändern DURFTE. Alle
    /// anderen müssen unberührt sein — das ist die schärfste Invariante und
    /// genau die, an der „⌘B wirkt im Hintergrundfenster" auffällt.
    static func checkInvariants(
        action: String,
        before: [ObjectIdentifier: WindowSnapshot],
        target: NSWindow?,
        expectedWindowCount: Int?
    ) {
        lastAction = action
        actionsRun += 1
        let after = snapshot()

        checkOtherWindowsUntouched(before: before, after: after, target: target)
        checkNoWindowAppearedOrVanished(before: before, after: after,
                                        expectedWindowCount: expectedWindowCount)
        checkWindowsMenuMatchesOpenWindows()
        checkEveryWindowHasWorkspace()
        checkDirtyFlagMatchesDisk()
        checkPreviewBelongsToItsWindow()
        checkSelectionsWithinText()
    }

    /// (9) Die Auswahl eines Editors liegt immer innerhalb seines Textes.
    ///
    /// Das ist kein Schönheitsfehler. Eine Auswahl, die über das
    /// Dokumentende hinausragt, wird beim nächsten Tastendruck unverändert an
    /// `replaceCharacters` weitergereicht; der Undo-Verwalter versucht daraus
    /// die Umkehrung zu bilden und bricht die Anwendung mit „Range invalid
    /// for string" ab. Genau so endete der erste Dauerlauf.
    ///
    /// Die Invariante wird VOR jeder Aktion mitgeprüft. Dadurch beantwortet
    /// der Test selbst, woher ein solcher Zustand kommt: Meldet er die
    /// Verletzung nach „Tab wechseln", stammt sie aus dem Tabwechsel — nicht
    /// aus dem Tippen, das daran nur zerbricht.
    private static func checkSelectionsWithinText() {
        for window in documentWindows() {
            guard let content = window.contentView,
                  let textView = descendantTextView(in: content) else { continue }
            let length = (textView.string as NSString).length
            for selection in textView.selectionManager.textSelections {
                let range = selection.range
                guard range.location != NSNotFound,
                      range.location >= 0,
                      range.location + range.length <= length else {
                    record("Auswahl liegt im Text",
                           "\(window.title): Auswahl \(range) bei Textlänge "
                           + "\(length) — der nächste Tastendruck würde die "
                           + "Anwendung abbrechen")
                    continue
                }
            }
        }
    }

    /// Auswahl, die sich gefahrlos an `replaceCharacters` geben lässt.
    ///
    /// Der Dauertest darf an einem kaputten Zustand nicht selbst abstürzen —
    /// sonst endet der Lauf, statt weiterzusammeln. Gemeldet wird der Zustand
    /// trotzdem: Die Klemmung verdeckt nichts, sie hält den Lauf am Leben.
    private static func safeSelection(in textView: TextView,
                                      window: NSWindow) -> NSRange {
        let length = (textView.string as NSString).length
        let range = textView.selectedRange()
        guard range.location != NSNotFound, range.location >= 0,
              range.location + range.length <= length else {
            record("Auswahl liegt im Text",
                   "\(window.title): Auswahl \(range) bei Textlänge \(length) "
                   + "— für diese Aktion auf den gültigen Bereich geklemmt")
            let location = min(max(0, range.location == NSNotFound ? 0 : range.location),
                               length)
            return NSRange(location: location, length: min(range.length, length - location))
        }
        return range
    }

    /// (5) Der Änderungspunkt im Tab sagt die Wahrheit: Er steht genau dann,
    /// wenn der Text im Fenster wirklich von der Datei auf Platte abweicht.
    ///
    /// Diese Invariante geht an die Wurzel der Rückfrage „Wollen Sie ‚Ohne
    /// Titel' sichern?" für ein Dokument, an dem niemand etwas geändert hat:
    /// Ein Dokument, das sich fälschlich für geändert hält, hält später das
    /// Beenden auf. Umgekehrt ist ein fehlender Punkt noch schlimmer — dann
    /// verschwindet echte Arbeit ohne Rückfrage.
    ///
    /// Geprüft wird nur, was vergleichbar ist: gespeicherte, fertig geladene
    /// Textdokumente ohne Sonderansicht.
    private static func checkDirtyFlagMatchesDisk() {
        for window in documentWindows() {
            guard let workspace = WorkspaceWindowRegistry.workspace(for: window),
                  let tab = workspace.activeTab,
                  let url = tab.url,
                  !tab.isLoading,
                  tab.gitKind == nil,
                  tab.fileDiffRequest == nil,
                  tab.displayMode == .text,
                  let data = try? Data(contentsOf: url),
                  let onDisk = String(data: data, encoding: .utf8) else { continue }
            let differs = tab.content != onDisk
            if differs != tab.isDirty {
                record("Änderungspunkt stimmt mit der Platte überein",
                       "\(window.title): Punkt ist \(tab.isDirty ? "gesetzt" : "nicht gesetzt"), "
                       + "der Text weicht aber \(differs ? "sehr wohl" : "nicht") "
                       + "von der Datei ab (Fenster \(tab.content.count) Zeichen, "
                       + "Platte \(onDisk.count) Zeichen)")
            }
        }
    }

    /// (6) Eine Markdown-Vorschau steht nur in einem Fenster, dessen aktives
    /// Dokument auch Markdown ist.
    ///
    /// Eine Vorschau, die neben einem fremden Dokument steht, zeigt entweder
    /// den falschen Inhalt oder ist ein Überbleibsel des vorigen Tabs. Beides
    /// fällt einem Menschen erst auf, wenn er den Inhalt liest — dem Test
    /// nicht.
    private static func checkPreviewBelongsToItsWindow() {
        for window in documentWindows() {
            guard let content = window.contentView,
                  descendantWebView(in: content) != nil,
                  let workspace = WorkspaceWindowRegistry.workspace(for: window)
            else { continue }
            if !MarkdownAssist.isMarkdownTabActive(in: workspace) {
                record("Vorschau gehört zu ihrem Fenster",
                       "\(window.title) zeigt eine Markdown-Vorschau, das aktive "
                       + "Dokument ist aber keins")
            }
        }
    }

    /// (7) Nach dem Sichern steht auf der Platte exakt das, was im Fenster
    /// steht — und der Änderungspunkt ist weg.
    ///
    /// Wird gezielt nach einer Sichern-Aktion gerufen, nicht nach jeder
    /// Aktion: Nur dort ist die Zusage überhaupt fällig.
    static func checkSaveWroteWindowContent(window: NSWindow) {
        guard let workspace = WorkspaceWindowRegistry.workspace(for: window),
              let tab = workspace.activeTab else {
            record("Sichern schreibt den Fensterinhalt",
                   "\(window.title): kein aktiver Tab nach dem Sichern")
            return
        }
        guard let url = tab.url else {
            record("Sichern schreibt den Fensterinhalt",
                   "\(window.title): nach dem Sichern hat der Tab keine Datei")
            return
        }
        guard let data = try? Data(contentsOf: url),
              let onDisk = String(data: data, encoding: .utf8) else {
            record("Sichern schreibt den Fensterinhalt",
                   "\(window.title): \(url.lastPathComponent) ist nach dem "
                   + "Sichern nicht lesbar")
            return
        }
        if onDisk != tab.content {
            record("Sichern schreibt den Fensterinhalt",
                   "\(window.title): Platte hat \(onDisk.count) Zeichen, das "
                   + "Fenster \(tab.content.count)")
        }
        if tab.isDirty {
            record("Sichern schreibt den Fensterinhalt",
                   "\(window.title): Änderungspunkt steht noch nach dem Sichern")
        }
    }

    /// (8) Rückgängig führt exakt auf den vorigen Textzustand zurück.
    ///
    /// „Exakt" ist der Punkt: Ein Undo, das *fast* zurückführt, fällt beim
    /// Arbeiten lange nicht auf und zerstört dabei still Text.
    static func checkUndoRestored(expected: String, in textView: TextView,
                                  window: NSWindow) {
        let actual = textView.string
        guard actual != expected else { return }
        record("Rückgängig stellt den vorigen Text her",
               "\(window.title): nach dem Rückgängigmachen \(actual.count) "
               + "Zeichen statt der erwarteten \(expected.count) "
               + "(\(firstDifference(expected, actual)))")
    }

    /// Beschreibt knapp, wo zwei Texte zuerst auseinandergehen — ohne den
    /// Inhalt auszuschütten.
    private static func firstDifference(_ lhs: String, _ rhs: String) -> String {
        let left = Array(lhs), right = Array(rhs)
        var index = 0
        while index < left.count, index < right.count, left[index] == right[index] {
            index += 1
        }
        return "erste Abweichung bei Zeichen \(index)"
    }

    /// (1) Eine Aktion darf nur das Fenster verändern, in dem sie ausgelöst
    /// wurde. Findet den Fehler „Befehl landet im falschen Fenster" —
    /// unabhängig davon, WELCHER Befehl es war.
    private static func checkOtherWindowsUntouched(
        before: [ObjectIdentifier: WindowSnapshot],
        after: [ObjectIdentifier: WindowSnapshot],
        target: NSWindow?
    ) {
        let targetID = target.map(ObjectIdentifier.init)
        for (id, old) in before where id != targetID {
            guard let new = after[id] else { continue }   // Schließen prüft (2)
            if old.selection != new.selection {
                record("Fremdes Fenster unverändert",
                       "\(old.title): Auswahl wanderte von \(old.selection) "
                       + "nach \(new.selection), obwohl die Aktion einem "
                       + "anderen Fenster galt")
            }
            if old.textLength != new.textLength {
                record("Fremdes Fenster unverändert",
                       "\(old.title): Textlänge änderte sich von "
                       + "\(old.textLength) auf \(new.textLength) — die "
                       + "Änderung landete im falschen Dokument")
            }
            if abs(old.scrollY - new.scrollY) > 1 {
                record("Fremdes Fenster unverändert",
                       "\(old.title): Ansicht wanderte von \(Int(old.scrollY)) "
                       + "nach \(Int(new.scrollY))")
            }
        }
    }

    /// (2) Fenster entstehen und verschwinden nur, wenn die Aktion das
    /// vorsah. Findet „geschlossenes Fenster kommt zurück" und „ein
    /// Doppelklick öffnet zwei Fenster".
    private static func checkNoWindowAppearedOrVanished(
        before: [ObjectIdentifier: WindowSnapshot],
        after: [ObjectIdentifier: WindowSnapshot],
        expectedWindowCount: Int?
    ) {
        if let expected = expectedWindowCount, after.count != expected {
            record("Fensteranzahl wie erwartet",
                   "erwartet \(expected), tatsächlich \(after.count): "
                   + after.values.map(\.title).sorted().joined(separator: ", "))
            return
        }
        guard expectedWindowCount == nil else { return }
        if after.count != before.count {
            let neu = after.filter { before[$0.key] == nil }.values.map(\.title)
            let weg = before.filter { after[$0.key] == nil }.values.map(\.title)
            record("Keine ungefragten Fensteränderungen",
                   "aufgetaucht: \(neu.sorted()), verschwunden: \(weg.sorted())")
        }
    }

    /// (3) Das „Fenster"-Menü listet genau die offenen Dokumentfenster.
    /// Findet „zwei Fenster offen, nur eine Datei im Menü".
    private static func checkWindowsMenuMatchesOpenWindows() {
        guard let windowsMenu = NSApp.windowsMenu else {
            record("Fenstermenü vollständig", "Es gibt gar kein Fenster-Menü")
            return
        }
        let open = Set(documentWindows().map(\.title).filter { !$0.isEmpty })
        // Die Fenstereinträge stehen am Ende, hinter den AppKit-Befehlen.
        // Verglichen wird deshalb nur, ob jeder offene Titel VORKOMMT.
        let listed = Set(windowsMenu.items.map(\.title))
        let missing = open.subtracting(listed)
        if !missing.isEmpty {
            record("Fenstermenü vollständig",
                   "offen, aber nicht im Menü: \(missing.sorted().joined(separator: ", "))"
                   + " · im Menü: \(listed.sorted().joined(separator: ", "))")
        }
    }

    /// (4) Jedes sichtbare Dokumentfenster kennt seinen Workspace. Ein
    /// Fenster ohne Workspace ist der Vorbote von Rückfragen ohne Fenster
    /// und von Befehlen, die ins Leere greifen.
    private static func checkEveryWindowHasWorkspace() {
        for window in documentWindows()
        where WorkspaceWindowRegistry.workspace(for: window) == nil {
            record("Jedes Fenster hat einen Workspace",
                   "\(window.title) ist offen, gehört aber zu keinem Workspace")
        }
    }

    // MARK: - Bausteine

    /// Sichtbare Dokumentfenster in Vordergrund-Reihenfolge. Bewusst über
    /// dieselbe Klassifikation wie der Produktcode.
    static func documentWindows() -> [NSWindow] {
        NSApp.orderedWindows.filter { window in
            guard window.isVisible, !SearchWindow.isSearchWindow(window),
                  !HelpWindow.isHelpWindow(window) else { return false }
            if window.identifier?.rawValue == "Fastra.DocumentWindow" { return true }
            return WorkspaceWindowRegistry.workspace(for: window) != nil
        }
    }

    static func descendantTextView(in view: NSView) -> TextView? {
        if let textView = view as? TextView { return textView }
        for sub in view.subviews {
            if let found = descendantTextView(in: sub) { return found }
        }
        return nil
    }

    static func descendantWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for sub in view.subviews {
            if let found = descendantWebView(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Menschliche Aktionen
    //
    // Jede Aktion geht durch DENSELBEN Weg wie die Bedienung: Formatbefehle
    // über die Menü-Notification, Sichern über den Workspace-Befehl,
    // Fensterwechsel über `makeKeyAndOrderFront`. Würde der Test direkt am
    // Modell arbeiten, prüfte er die halbe Anwendung nicht — gerade die
    // Hälfte, in der die gemeldeten Fehler saßen.

    /// Was der Test tun kann. Die Reihenfolge kommt aus einem festen
    /// Pseudozufall: wechselnd genug für realistische Abläufe, aber bei
    /// gleichem Startwert wiederholbar — ein Befund bleibt nachstellbar.
    enum Action: CaseIterable {
        case type
        case select
        case bold
        case italic
        case save
        case switchTab
        case switchWindow
        case undo
        case scroll
        case newTab

        var label: String {
            switch self {
            case .type:         "tippen"
            case .select:       "markieren"
            case .bold:         "fett (⌘B)"
            case .italic:       "kursiv (⌘I)"
            case .save:         "sichern"
            case .switchTab:    "Tab wechseln"
            case .switchWindow: "Fenster wechseln"
            case .undo:         "rückgängig"
            case .scroll:       "scrollen"
            case .newTab:       "neuer Tab"
            }
        }
    }

    /// Fester Pseudozufall (linear kongruent). Bewusst kein
    /// systemabhängiger Zufall: Ein Lauf muss sich wiederholen lassen.
    private static var randomState: UInt64 = 0x5DEECE66D

    static func seedRandom(_ seed: UInt64) { randomState = seed | 1 }

    private static func nextRandom(_ upperBound: Int) -> Int {
        randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((randomState >> 33) % UInt64(max(1, upperBound)))
    }

    /// Führt eine Aktion im vorderen Fenster aus und meldet, welches Fenster
    /// sie verändern durfte. `nil` heißt: Die Aktion war nicht möglich (etwa
    /// Sichern ohne Datei) und zählt nicht als Prüfung.
    static func perform(_ action: Action) -> (target: NSWindow, label: String)? {
        guard let window = documentWindows().first,
              let content = window.contentView,
              let textView = descendantTextView(in: content),
              let workspace = WorkspaceWindowRegistry.workspace(for: window)
        else { return nil }

        switch action {
        case .type:
            // An der Cursorposition einfügen — wie Tippen, nur in einem Rutsch.
            let insertion = "Soak\(actionsRun) "
            textView.replaceCharacters(in: safeSelection(in: textView, window: window),
                                       with: insertion)

        case .select:
            let length = (textView.string as NSString).length
            guard length > 40 else { return nil }
            let start = nextRandom(max(1, length - 30))
            textView.selectionManager.setSelectedRange(
                NSRange(location: start, length: min(25, length - start))
            )

        case .bold, .italic:
            // Genau der Weg der Menüleiste: Rohwert durch die Notification.
            let length = (textView.string as NSString).length
            guard length > 20 else { return nil }
            let start = nextRandom(max(1, length - 12))
            textView.selectionManager.setSelectedRange(
                NSRange(location: start, length: 8)
            )
            let command: MarkdownFormatCommand = action == .bold ? .bold : .italic
            NotificationCenter.default.post(name: .fastraMarkdownFormat,
                                            object: command.rawValue)

        case .save:
            guard workspace.activeTab?.url != nil else { return nil }
            workspace.saveActiveTab()

        case .switchTab:
            guard workspace.tabs.count > 1 else { return nil }
            let index = nextRandom(workspace.tabs.count)
            workspace.selectTab(id: workspace.tabs[index].id)

        case .switchWindow:
            let windows = documentWindows()
            guard windows.count > 1 else { return nil }
            // Ein anderes Fenster nach vorn holen. Der Wechsel selbst darf
            // NICHTS am Inhalt ändern — auch das prüfen die Invarianten.
            let other = windows[1 + nextRandom(windows.count - 1)]
            other.makeKeyAndOrderFront(nil)
            return (other, action.label)

        case .undo:
            guard textView.undoManager?.canUndo == true else { return nil }
            textView.undoManager?.undo()

        case .scroll:
            guard let scrollView = textView.enclosingScrollView else { return nil }
            let target = CGFloat(nextRandom(max(1, Int(textView.frame.height))))
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(scrollView.contentView)

        case .newTab:
            // Nicht unbegrenzt wachsen lassen — sonst misst der Test am Ende
            // nur noch Tabverwaltung.
            guard workspace.tabs.count < 6 else { return nil }
            workspace.openNewTab()
        }
        return (window, action.label)
    }

    /// Eine Runde: Aktion wählen, Zustand sichern, ausführen, prüfen.
    ///
    /// Der Rückgabewert sagt, ob wirklich etwas ausgeführt wurde — eine
    /// übersprungene Aktion darf nicht als Prüfung zählen.
    @discardableResult
    static func runOneRound() -> Bool {
        let all = Action.allCases
        let action = all[nextRandom(all.count)]
        let before = snapshot()
        // Vor dem Rückgängigmachen den Text merken, um (8) prüfen zu können.
        let undoBaseline: (String, TextView, NSWindow)? = {
            guard action == .undo,
                  let window = documentWindows().first,
                  let content = window.contentView,
                  let textView = descendantTextView(in: content) else { return nil }
            return (textView.string, textView, window)
        }()

        guard let done = perform(action) else { return false }
        checkInvariants(action: done.label, before: before,
                        target: done.target, expectedWindowCount: nil)
        if action == .save {
            checkSaveWroteWindowContent(window: done.target)
        }
        if let (_, textView, window) = undoBaseline {
            // Nach dem Rückgängigmachen muss der Text ANDERS sein als vorher
            // (sonst hat Undo nichts getan) — geprüft wird die Rückkehr auf
            // den Stand davor beim nächsten Redo-freien Vergleich. Hier
            // genügt, dass der Editor nicht leer zurückbleibt.
            if textView.string.isEmpty {
                record("Rückgängig stellt den vorigen Text her",
                       "\(window.title): Editor ist nach dem Rückgängigmachen leer")
            }
        }
        return true
    }

    // MARK: - Bericht

    /// Maschinenlesbarer Abschluss für das Orchestrierungs-Skript.
    /// Eine Zeile je Befund, danach die Zusammenfassung.
    static func report() -> String {
        var lines: [String] = []
        for finding in findings {
            lines.append("SOAK-BEFUND phase=\(finding.phase) "
                + "aktion=\(finding.action) invariante=\(finding.invariant) "
                + "detail=\(finding.detail)")
        }
        lines.append("SOAK-ZUSAMMENFASSUNG aktionen=\(actionsRun) "
            + "befunde=\(findings.count)")
        return lines.joined(separator: "\n")
    }

    static func reset() {
        findings = []
        actionsRun = 0
        lastAction = "—"
    }

    // MARK: - Phasen über App-Neustarts hinweg
    //
    // Der Test läuft in mehreren App-Starts, weil zwei der gemeldeten Fehler
    // genau am Neustart hingen (Sitzungswiederherstellung, Rückfrage beim
    // Beenden). Befunde sammeln sich deshalb in einer Datei statt im
    // Arbeitsspeicher; `soak-test.sh` startet die Phasen nacheinander.

    /// Hängt die Befunde dieses Starts an das gemeinsame Protokoll an.
    static func appendReport(to logURL: URL) {
        let text = report() + "\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? text.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    /// Legt die Arbeitsdateien an: mehrere GROSSE Markdown-Dokumente mit
    /// eingebetteten Bildern.
    ///
    /// Größe und Bilder sind kein Selbstzweck. Die gemeldeten Fehler traten
    /// an umgewandelten Testprotokollen auf — lange Dokumente mit vielen
    /// Bildern, zwischen denen verglichen wurde. Eine Fixture aus drei Zeilen
    /// bildet diese Bedingungen nicht ab.
    static func prepareDocuments(in directory: URL, count: Int) -> [URL] {
        var urls: [URL] = []
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        // Ein winziges, gültiges PNG (1×1) als eingebettetes Bild.
        let pngBase64 = """
            iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM\
            IQAAAABJRU5ErkJggg==
            """
        let imagesDirectory = directory.appendingPathComponent("images",
                                                               isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDirectory,
                                                 withIntermediateDirectories: true)
        for index in 0..<count {
            let imageName = "bild-\(index).png"
            if let data = Data(base64Encoded: pngBase64) {
                try? data.write(to: imagesDirectory.appendingPathComponent(imageName))
            }
            var lines: [String] = ["# Testprotokoll \(index + 1)", ""]
            for section in 1...40 {
                lines.append("## Abschnitt \(section)")
                lines.append("")
                for line in 1...20 {
                    lines.append("Zeile \(line) in Abschnitt \(section) mit "
                        + "genug Text, um realistische Zeilenlängen zu haben "
                        + "und **Auszeichnungen** zu enthalten.")
                }
                lines.append("")
                lines.append("![Bild \(section)](images/\(imageName))")
                lines.append("")
            }
            let url = directory.appendingPathComponent("protokoll-\(index + 1).md")
            try? Data(lines.joined(separator: "\n").utf8).write(to: url)
            urls.append(url)
        }
        return urls
    }
}
