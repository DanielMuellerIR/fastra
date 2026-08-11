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
//   * Er arbeitet, wo vorhanden, mit ECHTEN Dokumenten statt nur mit
//     Fixtures: einer realen Markdown-Datei, einem RTFD-Bundle, das über
//     den echten Öffnen-Pfad umgewandelt und SOFORT weiterbearbeitet wird,
//     und einem echten 4D-Projekt samt Completion, Signaturhilfe und
//     ALT-Doppelklick. (Die Dateien stellt das Skript bereit; Namen und
//     Pfade echter Quellen gehören nicht in diesen Code.)
//   * Er verschiebt und skaliert Fenster, kopiert über die Zwischenablage
//     zwischen Fenstern (⌘C/⌘V über die Responder-Chain) und löst Sichern,
//     „Neuer Tab" und Rückgängig über die ECHTEN Menübefehle aus — nicht
//     über direkte Modellaufrufe.
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

    /// Hinweis ins Lauf-Log (stderr) — bewusst KEIN Befund. Für optionale
    /// Schritte, die mangels passender Stelle übersprungen werden.
    static func note(_ text: String) {
        FileHandle.standardError.write(Data("SOAK-HINWEIS \(text)\n".utf8))
    }

    // MARK: - Zustandsschnappschuss

    /// Alles an einem Fenster, was sich ohne Zutun NICHT ändern darf.
    struct WindowSnapshot: Equatable {
        let title: String
        let documentPath: String?
        let selection: NSRange
        let scrollY: CGFloat
        let textLength: Int
        let textHash: Int
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
            let text = textView.string
            result[ObjectIdentifier(window)] = WindowSnapshot(
                title: window.title,
                documentPath: workspace?.activeTab?.url?.path,
                selection: textView.selectedRange(),
                scrollY: textView.enclosingScrollView?.documentVisibleRect.minY ?? 0,
                textLength: (text as NSString).length,
                textHash: text.hashValue,
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
    ///
    /// Ausnahme: `{NSNotFound, 0}` ist KEIN kaputter Zustand, sondern der
    /// dokumentierte Normalfall eines Fensters, in das noch niemand geklickt
    /// hat — nach der Sitzungswiederherstellung steht jedes Fenster so da.
    /// Ein Mensch klickt vor dem Tippen; der Test bildet das nach, indem er
    /// den Einfügepunkt an den Textanfang setzt, ohne einen Befund zu melden.
    private static func safeSelection(in textView: TextView,
                                      window: NSWindow) -> NSRange {
        let length = (textView.string as NSString).length
        let range = textView.selectedRange()
        if range.location == NSNotFound, range.length == 0 {
            return NSRange(location: 0, length: 0)
        }
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
    /// Fenster, deren scrollY-Prüfung nach einem Resize vorübergehend
    /// ausgesetzt ist: Ein Breiten-Resize wickelt Soft-Wrap-Text neu, und
    /// `documentVisibleRect.minY` zieht dabei VERZÖGERT nach — auch erst in
    /// der Folgerunde. Auswahl, Textlänge und Änderungspunkt bleiben für
    /// diese Fenster scharf geprüft.
    private static var scrollForgiven: Set<ObjectIdentifier> = []
    /// Runden bis zur Leerung von `scrollForgiven` (Ende der übernächsten
    /// Runde nach dem Resize), heruntergezählt am Ende von `finishRound`.
    private static var scrollForgivenRoundsRemaining = 0

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
            if old.documentPath != new.documentPath {
                record("Fremdes Fenster unverändert",
                       "\(old.title): aktives Dokument wechselte von "
                       + "\(old.documentPath ?? "keinem Dateipfad") auf "
                       + "\(new.documentPath ?? "keinen Dateipfad")")
            }
            if old.textLength != new.textLength || old.textHash != new.textHash {
                let lengthDetail = old.textLength == new.textLength
                    ? "bei gleichbleibender Textlänge \(old.textLength)"
                    : "von \(old.textLength) auf \(new.textLength) Zeichen"
                record("Fremdes Fenster unverändert",
                       "\(old.title): Textinhalt änderte sich \(lengthDetail) — "
                       + "die Änderung landete im falschen Dokument")
            }
            if old.isEdited != new.isEdited {
                record("Fremdes Fenster unverändert",
                       "\(old.title): Änderungspunkt wechselte von "
                       + "\(old.isEdited ? "gesetzt" : "nicht gesetzt") auf "
                       + "\(new.isEdited ? "gesetzt" : "nicht gesetzt")")
            }
            if abs(old.scrollY - new.scrollY) > 1,
               !scrollForgiven.contains(id) {
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
        case moveWindow
        case resizeWindow
        case copy
        case paste

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
            case .moveWindow:   "Fenster verschieben"
            case .resizeWindow: "Fenstergröße ändern"
            case .copy:         "kopieren (⌘C)"
            case .paste:        "einfügen (⌘V)"
            }
        }
    }

    /// Fester Pseudozufall (linear kongruent). Bewusst kein
    /// systemabhängiger Zufall: Ein Lauf muss sich wiederholen lassen.
    private static var randomState: UInt64 = 0x5DEECE66D
    /// Externes 4D-Projekt der dritten Phase. Nach jeder nachgewiesenen eigenen
    /// Textmutation protokolliert der Test den aktiven Pfad genau einmal; nur
    /// diese Pfade darf der Runner später überhaupt zurücksetzen.
    private static var fourDProjectRoot: URL?
    private static var touchedFourDPaths: Set<String> = []

    static func seedRandom(_ seed: UInt64) { randomState = seed | 1 }

    private static func nextRandom(_ upperBound: Int) -> Int {
        randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((randomState >> 33) % UInt64(max(1, upperBound)))
    }

    private static func noteFourDMutation(in workspace: Workspace) {
        guard let rootPath = fourDProjectRoot?.standardizedFileURL.path,
              let filePath = workspace.activeTab?.url?.standardizedFileURL.path,
              filePath == rootPath || filePath.hasPrefix(rootPath + "/"),
              touchedFourDPaths.insert(filePath).inserted else { return }
        FileHandle.standardError.write(Data("SOAK-4D-DATEI: \(filePath)\n".utf8))
    }

    /// Führt eine Aktion im vorderen Fenster aus und meldet, welches Fenster
    /// sie verändern durfte. `nil` heißt: Die Aktion war nicht möglich (etwa
    /// Sichern ohne Datei) und zählt nicht als Prüfung.
    static func perform(_ action: Action) -> (
        target: NSWindow, label: String, pasteboardChangeCount: Int?
    )? {
        guard let window = documentWindows().first,
              let content = window.contentView,
              let textView = descendantTextView(in: content),
              let workspace = WorkspaceWindowRegistry.workspace(for: window)
        else { return nil }

        // Ein Mensch bedient immer das vordere, aktive Fenster. Die direkte
        // Teststeuerung kann dagegen ein geordnetes Fenster erwischen, das
        // noch nicht Key Window ist. Dann findet `NSApp.sendAction` trotz
        // vorhandener TextView keinen Empfänger, und Menübefehle können gegen
        // das zuletzt aktive andere Fenster aufgelöst werden. Vor jeder
        // menschlichen Aktion deshalb dieselbe Fokuslage herstellen wie ein
        // echter Klick in den Editor.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(textView)

        var pasteboardChangeCount: Int?
        switch action {
        case .type:
            // An der Cursorposition einfügen — wie Tippen, nur in einem Rutsch.
            let textBefore = textView.string
            let insertion = "Soak\(actionsRun) "
            textView.replaceCharacters(in: safeSelection(in: textView, window: window),
                                       with: insertion)
            if textView.string != textBefore { noteFourDMutation(in: workspace) }

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
            let textBefore = textView.string
            let command: MarkdownFormatCommand = action == .bold ? .bold : .italic
            NotificationCenter.default.post(name: .fastraMarkdownFormat,
                                            object: command.rawValue)
            if textView.string != textBefore { noteFourDMutation(in: workspace) }

        case .save:
            // Nur mit gespeicherter Datei — sonst öffnete „Sichern" den
            // modalen „Sichern unter…"-Dialog und hielte den Lauf an.
            // Geprüft werden BEIDE beteiligten Workspaces: der des
            // Vorderfensters und der an die Menübefehle gebundene
            // `Workspace.shared`, der nur bei `didBecomeKey` nachgeführt
            // wird. Genau diese Kopplung soll der Test über den ECHTEN
            // Menübefehl treffen — schlägt dabei eine Invariante an, ist
            // das ein Produktbefund, kein Testproblem.
            guard workspace.activeTab?.url != nil,
                  Workspace.shared?.activeTab?.url != nil else { return nil }
            guard let item = commandMenuItem(forKeyEquivalent: "s"),
                  let menuAction = item.action else { return nil }
            _ = NSApp.sendAction(menuAction, to: item.target, from: item)

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
            return (other, action.label, nil)

        case .undo:
            guard textView.undoManager?.canUndo == true else { return nil }
            let textBefore = textView.string
            // Der echte Weg von ⌘Z: über die Responder-Chain, nicht direkt
            // am Undo-Verwalter vorbei. `undo:` implementiert die TextView
            // modulintern, deshalb per Name statt `#selector`.
            let responderAccepted = window.makeFirstResponder(textView)
            let commandAccepted = NSApp.sendAction(
                NSSelectorFromString("undo:"), to: nil, from: nil)
            if !commandAccepted {
                record("Rückgängig erreicht den Editor",
                       responderState(window: window, textView: textView,
                                      responderAccepted: responderAccepted))
            }
            if textView.string != textBefore { noteFourDMutation(in: workspace) }

        case .scroll:
            guard let scrollView = textView.enclosingScrollView else { return nil }
            let target = CGFloat(nextRandom(max(1, Int(textView.frame.height))))
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(scrollView.contentView)

        case .newTab:
            // Nicht unbegrenzt wachsen lassen — sonst misst der Test am Ende
            // nur noch Tabverwaltung. Ausgelöst über den echten ⌘T-Menüpunkt,
            // der wie „Sichern" an `Workspace.shared` gebunden ist.
            guard workspace.tabs.count < 6 else { return nil }
            guard let item = commandMenuItem(forKeyEquivalent: "t"),
                  let menuAction = item.action else { return nil }
            _ = NSApp.sendAction(menuAction, to: item.target, from: item)

        case .moveWindow:
            // Zufällige Position, aber der Rahmen bleibt vollständig im
            // sichtbaren Bildschirmbereich: Der Test prüft Fensterbewegung,
            // nicht das Wiederfinden verlorener Fenster.
            guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            else { return nil }
            let frame = window.frame
            let spanX = Int(visible.maxX - frame.width - visible.minX)
            let spanY = Int(visible.maxY - frame.height - visible.minY)
            guard spanX >= 0, spanY >= 0 else { return nil }
            window.setFrameOrigin(NSPoint(
                x: visible.minX + CGFloat(nextRandom(spanX + 1)),
                y: visible.minY + CGFloat(nextRandom(spanY + 1))))

        case .resizeWindow:
            // Zufällige Größe zwischen Mindestgröße und sichtbarem Bereich;
            // die Position wird so geklemmt, dass das Fenster sichtbar
            // bleibt. Nie miniaturisieren.
            guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            else { return nil }
            let minWidth = MainWindowSizing.minimumWidth
            let minHeight = MainWindowSizing.minimumHeight
            guard visible.width >= minWidth, visible.height >= minHeight
            else { return nil }
            let width = minWidth
                + CGFloat(nextRandom(Int(visible.width - minWidth) + 1))
            let height = minHeight
                + CGFloat(nextRandom(Int(visible.height - minHeight) + 1))
            var origin = window.frame.origin
            origin.x = min(max(visible.minX, origin.x), visible.maxX - width)
            origin.y = min(max(visible.minY, origin.y), visible.maxY - height)
            window.setFrame(NSRect(x: origin.x, y: origin.y,
                                   width: width, height: height),
                            display: true)
            // Ein Breiten-Resize wickelt Soft-Wrap-Text neu;
            // `documentVisibleRect.minY` zieht dabei verzögert nach — auch
            // erst in der FOLGERUNDE. Die scrollY-Prüfung für dieses Fenster
            // deshalb zwei Runden lang aussetzen (siehe `scrollForgiven`).
            scrollForgiven.insert(ObjectIdentifier(window))
            scrollForgivenRoundsRemaining = 2

        case .copy:
            // Zufällige Auswahl, dann ⌘C über die Responder-Chain — der
            // echte Weg in die gepatchte TextView. Zusammen mit
            // `.switchWindow` und `.paste` entsteht über die Zeit echtes
            // Kopieren zwischen Fenstern.
            let length = (textView.string as NSString).length
            guard length > 40 else { return nil }
            let start = nextRandom(max(1, length - 30))
            textView.selectionManager.setSelectedRange(
                NSRange(location: start, length: min(25, length - start))
            )
            let responderAccepted = window.makeFirstResponder(textView)
            let beforeCopy = NSPasteboard.general.changeCount
            if !NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) {
                record("Kopierbefehl erreicht den Editor",
                       "\(window.title): sendAction(copy:) fand keinen Empfänger; "
                       + responderState(window: window, textView: textView,
                                        responderAccepted: responderAccepted))
            } else {
                let afterCopy = NSPasteboard.general.changeCount
                if afterCopy != beforeCopy { pasteboardChangeCount = afterCopy }
            }

        case .paste:
            // Nur mit Textinhalt in der Zwischenablage; Bild-Paste und
            // Smart Paste (⇧⌘V, modale Fehlermeldung) bleiben bewusst außen
            // vor. Der Einfügepunkt wird auf den gültigen Bereich geklemmt.
            guard let clip = NSPasteboard.general.string(forType: .string),
                  !clip.isEmpty else { return nil }
            let textBefore = textView.string
            _ = window.makeFirstResponder(textView)
            textView.selectionManager.setSelectedRange(
                safeSelection(in: textView, window: window)
            )
            if !NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) {
                record("Einfügebefehl erreicht den Editor",
                       "\(window.title): sendAction(paste:) fand keinen Empfänger")
            }
            if textView.string != textBefore { noteFourDMutation(in: workspace) }
        }
        return (window, action.label, pasteboardChangeCount)
    }

    /// Fokuslage für einen fehlgeschlagenen Responder-Befehl. Die Diagnose
    /// enthält nur AppKit-Zustand, niemals Dokumentinhalt.
    private static func responderState(window: NSWindow, textView: TextView,
                                       responderAccepted: Bool) -> String {
        let firstResponder = window.firstResponder.map { String(describing: type(of: $0)) }
            ?? "nil"
        return "active=\(NSApp.isActive), key=\(window.isKeyWindow), "
            + "makeFirstResponder=\(responderAccepted), first=\(firstResponder), "
            + "textViewImFenster=\(textView.window === window)"
    }

    /// Sucht den ⌘-Menüpunkt FRISCH im aktuellen Hauptmenü. Referenzen werden
    /// bewusst nie gecacht: SwiftUI baut das Menü laufend neu auf, ein
    /// gemerkter `NSMenuItem` zeigte dann ins Leere. `update()` entspricht dem
    /// Aufklappen des Menüs samt SwiftUI-Validierung; ein deaktivierter Punkt
    /// führt zum Überspringen der Aktion.
    private static func commandMenuItem(forKeyEquivalent key: String) -> NSMenuItem? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        mainMenu.update()
        guard let item = menuItem(forKeyEquivalent: key, in: mainMenu),
              item.isEnabled, item.action != nil else { return nil }
        return item
    }

    /// Rekursive Suche wie im Selbsttest: Modifier werden geprüft, damit
    /// nicht ⇧⌘S („Sichern unter…") statt ⌘S getroffen wird. Der Vergleich
    /// ist bewusst exakt (Kleinbuchstabe): Ein Shift-Kürzel kann auch als
    /// GROSSBUCHSTABE ohne .shift-Maske codiert sein.
    private static func menuItem(forKeyEquivalent key: String,
                                 in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.keyEquivalent == key,
               item.keyEquivalentModifierMask.contains(.command),
               !item.keyEquivalentModifierMask.contains(.shift) {
                return item
            }
            if let submenu = item.submenu,
               let found = menuItem(forKeyEquivalent: key, in: submenu) {
                return found
            }
        }
        return nil
    }

    /// Zwischenstand einer Runde: Die Aktion ist bereits ausgeführt, die
    /// Prüfung folgt getrennt. Der Treiber legt zwischen beide einen
    /// Runloop-Durchlauf, weil SwiftUI abgeleitete Ansichten (etwa die
    /// Markdown-Vorschau-Spalte) erst in der nächsten Transaktion umbaut —
    /// eine synchrone Prüfung fände noch den alten View-Baum und meldete
    /// einen Fehler, den es im Betrieb nie gibt.
    struct PendingRound {
        let label: String
        let target: NSWindow
        let action: Action
        let before: [ObjectIdentifier: WindowSnapshot]
        let undoBaseline: (String, TextView, NSWindow)?
        /// Nur direkt nach einer nachweislich erfolgreichen test-eigenen Kopie
        /// gesetzt. Andere Aktionen dürfen einen inzwischen fremden
        /// Zwischenablage-Zähler niemals als Testbesitz übernehmen.
        let pasteboardChangeCount: Int?
    }

    /// Erste Hälfte einer Runde: Aktion wählen, Zustand sichern, ausführen.
    ///
    /// `nil` heißt: Es wurde nichts ausgeführt — eine übersprungene Aktion
    /// darf nicht als Prüfung zählen.
    static func startRound() -> PendingRound? {
        let all = Action.allCases
        let action = all[nextRandom(all.count)]
        // `perform` kann bereits während der Aktion einen Befund melden
        // (etwa wenn die Responder-Kette einen Kopierbefehl ablehnt). Der
        // Report muss dann diese und nicht die vorherige Aktion nennen.
        lastAction = action.label
        let before = snapshot()
        // Vor dem Rückgängigmachen den Text merken, um (8) prüfen zu können.
        let undoBaseline: (String, TextView, NSWindow)? = {
            guard action == .undo,
                  let window = documentWindows().first,
                  let content = window.contentView,
                  let textView = descendantTextView(in: content) else { return nil }
            return (textView.string, textView, window)
        }()

        guard let done = perform(action) else { return nil }
        return PendingRound(label: done.label, target: done.target,
                            action: action, before: before,
                            undoBaseline: undoBaseline,
                            pasteboardChangeCount: done.pasteboardChangeCount)
    }

    /// Zweite Hälfte einer Runde: die Invarianten gegen den inzwischen
    /// gesetzten Zustand prüfen.
    static func finishRound(_ round: PendingRound) {
        checkInvariants(action: round.label, before: round.before,
                        target: round.target, expectedWindowCount: nil)
        if round.action == .save {
            checkSaveWroteWindowContent(window: round.target)
        }
        if let (baseline, textView, window) = round.undoBaseline {
            // Nach dem Rückgängigmachen muss der Text ANDERS sein als vorher
            // (sonst hat Undo nichts getan). Die bisherige Nicht-leer-Prüfung
            // bleibt als eigener Schutz für Datei-Tabs bestehen. Danach wird
            // die Aktion per Redo wiederholt: Erst dieser zweite Schritt kann
            // exakt mit dem Text VOR dem Undo verglichen werden.
            let tabHasFile = WorkspaceWindowRegistry.workspace(for: window)?
                .activeTab?.url != nil
            if textView.string.isEmpty, tabHasFile {
                record("Rückgängig stellt den vorigen Text her",
                       "\(window.title): Editor ist nach dem Rückgängigmachen leer")
            }
            if textView.undoManager?.canRedo != true {
                record("Rückgängig stellt den vorigen Text her",
                       "\(window.title): nach dem Rückgängigmachen ist kein "
                       + "Wiederholen möglich")
            } else {
                _ = window.makeFirstResponder(textView)
                let handled = NSApp.sendAction(NSSelectorFromString("redo:"),
                                               to: nil, from: nil)
                if handled {
                    checkUndoRestored(expected: baseline, in: textView, window: window)
                } else {
                    record("Rückgängig stellt den vorigen Text her",
                           "\(window.title): Wiederholen wurde von der "
                           + "Responder-Kette nicht angenommen")
                }
            }
        }
        // Die scrollY-Nachsicht nach einem Resize endet mit dem Abschluss der
        // ÜBERNÄCHSTEN Runde: erst dann ist die verzögerte Neuauslegung des
        // Soft-Wrap-Textes sicher durch.
        if scrollForgivenRoundsRemaining > 0 {
            scrollForgivenRoundsRemaining -= 1
            if scrollForgivenRoundsRemaining == 0 {
                scrollForgiven.removeAll()
            }
        }
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
        scrollForgiven.removeAll()
        scrollForgivenRoundsRemaining = 0
        fourDProjectRoot = nil
        touchedFourDPaths.removeAll()
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

    /// Ein Nicht-Markdown-Dokument für die gemischte Tab-Lage. Ohne ein
    /// solches Dokument könnte die Invariante „Vorschau gehört zu ihrem
    /// Fenster" nie echt anschlagen: Ein leerer neuer Tab zeigt die
    /// Startansicht (ganz ohne Editor und Vorschau), erst ein aktives
    /// Nicht-Markdown-DOKUMENT lässt eine stehengebliebene Vorschau auffliegen.
    static func prepareTextDocument(in directory: URL) -> URL {
        var lines: [String] = []
        for line in 1...200 {
            lines.append("Notizzeile \(line): einfacher Text ohne Auszeichnung, "
                + "damit ein Tab mit fremdem Dateityp im Spiel ist.")
        }
        let url = directory.appendingPathComponent("notizen.txt")
        try? Data(lines.joined(separator: "\n").utf8).write(to: url)
        return url
    }

    // MARK: - Echte Dokumente (Phase 1)
    //
    // `soak-test.sh` kann unter `<soakDir>/real/` Kopien echter Dokumente
    // bereitstellen. Fehlen sie, läuft alles wie bisher mit den Fixtures.

    /// Die optional bereitgestellte echte Markdown-Datei:
    /// `<soakDir>/real/markdown/` enthält genau eine `.md` (plus `images/`).
    /// `nil` = nicht vorhanden.
    static func realMarkdownDocument(in directory: URL) -> URL? {
        let folder = directory.appendingPathComponent("real/markdown",
                                                      isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.first { $0.pathExtension.lowercased() == "md" }
    }

    /// Das optional bereitgestellte echte RTFD-Bundle. `nil` = nicht vorhanden.
    static func realRTFDBundle(in directory: URL) -> URL? {
        let bundle = directory.appendingPathComponent("real/protokoll-import.rtfd",
                                                      isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bundle.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return bundle
    }

    /// Öffnet das RTFD-Bundle über den ECHTEN Öffnen-Pfad (`openFileOrFolder`),
    /// wählt die Rückfrage automatisch mit „umwandeln" und bearbeitet den
    /// entstandenen Markdown-Tab SOFORT weiter — genau in diesem Zustand
    /// werden Fehler vermutet. `MarkdownImportService` ist ein Singleton;
    /// es läuft nie eine zweite Umwandlung parallel.
    static func runRTFDImport(bundle: URL, workspace: Workspace,
                              completion: @escaping @MainActor () -> Void) {
        // Das erste Fenster nach vorn holen: Notification- und Menübefehle
        // der folgenden Schritte wirken auf das VORDERSTE Fenster.
        let window = documentWindows().first {
            WorkspaceWindowRegistry.workspace(for: $0) === workspace
        }
        window?.makeKeyAndOrderFront(nil)
        // Die echte Rückfrage ist ein modaler NSAlert und würde den Lauf
        // anhalten; der Testhaken wählt automatisch „In Markdown umwandeln".
        Workspace.markdownImportPackageChoiceProvider = { _, _ in .convert }
        workspace.openFileOrFolder(at: bundle)
        pollRTFDImportResult(workspace: workspace, window: window, tick: 0,
                             completion: completion)
    }

    /// Wartet auf das Ende der Umwandlung: Zustand `finished`, der erzeugte
    /// Markdown-Tab ist aktiv und fertig geladen. Frist 60 s.
    private static func pollRTFDImportResult(
        workspace: Workspace, window: NSWindow?, tick: Int,
        completion: @escaping @MainActor () -> Void
    ) {
        let invariant = "RTFD-Umwandlung liefert einen bearbeitbaren Tab"
        if case .failed(let message) = MarkdownImportService.shared.state {
            Workspace.markdownImportPackageChoiceProvider = nil
            record(invariant, "Umwandlung fehlgeschlagen: \(message)")
            completion()
            return
        }
        // Fertig heißt: Zustand `finished`, der erzeugte Tab ist aktiv und
        // geladen UND der Editor steht wirklich im Fenster. Das Modell ist
        // dem View-Baum einen Runloop voraus — ohne die letzte Bedingung
        // prüfte der Test einen Editor, den SwiftUI noch gar nicht gebaut hat.
        if case .finished(let markdownFile, _) = MarkdownImportService.shared.state,
           let tab = workspace.activeTab, !tab.isLoading,
           tab.url?.canonicalFileURL.path == markdownFile.canonicalFileURL.path,
           let window, let content = window.contentView,
           descendantTextView(in: content) != nil {
            Workspace.markdownImportPackageChoiceProvider = nil
            runRTFDEditSteps(window: window, workspace: workspace,
                             completion: completion)
            return
        }
        if tick >= 600 {
            Workspace.markdownImportPackageChoiceProvider = nil
            record(invariant,
                   "Umwandlung nicht binnen 60 s fertig "
                   + "(aktiver Tab: \(workspace.activeTab?.title ?? "—"))")
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                pollRTFDImportResult(workspace: workspace, window: window,
                                     tick: tick + 1, completion: completion)
            }
        }
    }

    /// Bearbeitet den frisch umgewandelten Tab sofort weiter: tippen, fett,
    /// sichern — je Schritt mit Runloop-Settling und Invariantenprüfung.
    private static func runRTFDEditSteps(window: NSWindow, workspace: Workspace,
                                         completion: @escaping @MainActor () -> Void) {
        guard let content = window.contentView,
              let textView = descendantTextView(in: content) else {
            record("RTFD-Umwandlung liefert einen bearbeitbaren Tab",
                   "\(window.title): kein Editor nach der Umwandlung")
            completion()
            return
        }
        // Schritt 1: an der Cursorposition tippen (frischer Tab → Textanfang).
        let beforeType = snapshot()
        textView.replaceCharacters(in: safeSelection(in: textView, window: window),
                                   with: "Soak-RTFD ")
        settleThenCheck(label: "RTFD: tippen", before: beforeType,
                        target: window) {
            // Schritt 2: fett über die Menü-Notification, wie `perform(.bold)`.
            let beforeBold = snapshot()
            let length = (textView.string as NSString).length
            if length > 20 {
                let start = nextRandom(max(1, length - 12))
                textView.selectionManager.setSelectedRange(
                    NSRange(location: start, length: 8)
                )
            }
            NotificationCenter.default.post(name: .fastraMarkdownFormat,
                                            object: MarkdownFormatCommand.bold.rawValue)
            settleThenCheck(label: "RTFD: fett (⌘B)", before: beforeBold,
                            target: window) {
                // Schritt 3: sichern und die Sichern-Zusage prüfen.
                let beforeSave = snapshot()
                workspace.saveActiveTab()
                settleThenCheck(label: "RTFD: sichern", before: beforeSave,
                                target: window) {
                    checkSaveWroteWindowContent(window: window)
                    completion()
                }
            }
        }
    }

    /// Ein Runloop-Durchlauf (0,1 s) wie in `runSoakRounds`, dann die
    /// Invarianten prüfen — für gescriptete Schritte außerhalb der Runden.
    private static func settleThenCheck(
        label: String,
        before: [ObjectIdentifier: WindowSnapshot],
        target: NSWindow,
        then body: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                checkInvariants(action: label, before: before, target: target,
                                expectedWindowCount: nil)
                body()
            }
        }
    }

    // MARK: - 4D-Szenario (Phase 3)
    //
    // Nur mit `-soak4DProject` (Wurzel eines echten 4D-Projekts) und
    // `-soak4DMethod` (vom Skript gewählte lange, git-saubere Methode).
    // Die Completion-/Signatur-Popups sind Kindfenster und werden von
    // `documentWindows()` bereits herausgefiltert.

    /// Öffnet das 4D-Projekt in einem NEUEN Fenster, wartet auf den
    /// Methodenindex, lädt die vorgegebene Methode und prüft die drei
    /// Sprachfunktionen. Danach nimmt das Fenster am Zufallsbetrieb teil.
    static func runFourDScenario(projectURL: URL, methodURL: URL,
                                 completion: @escaping @MainActor () -> Void) {
        fourDProjectRoot = projectURL.standardizedFileURL
        let fourDWorkspace = DocumentWindowController.openNewDocument()
        fourDWorkspace.openProject(at: projectURL)
        // Frist 30 s: Erst mit stehendem Methodenindex sind Completion,
        // Signaturhilfe und Methodensprünge überhaupt möglich.
        pollCondition(tick: 0, maxTicks: 120, interval: 0.25, condition: {
            !fourDWorkspace.fourDProjectMethodNames.isEmpty
        }) { indexed in
            if !indexed {
                record("4D-Methodenindex steht",
                       "Projektindex blieb 30 s leer — Runden starten trotzdem")
                completion()
                return
            }
            fourDWorkspace.loadFile(at: methodURL) { loaded in
                guard loaded else {
                    record("4D-Methodenindex steht",
                           "\(methodURL.lastPathComponent) ließ sich nicht laden")
                    completion()
                    return
                }
                waitForFourDEditor(workspace: fourDWorkspace, tick: 0) { found in
                    guard let (window, textView) = found else {
                        record("4D-Methodenindex steht",
                               "4D-Editor nicht binnen 10 s montiert")
                        completion()
                        return
                    }
                        runFourDCompletionStep(workspace: fourDWorkspace,
                                               window: window, textView: textView) {
                        runFourDSignatureStep(workspace: fourDWorkspace,
                                              window: window,
                                              textView: textView) {
                            runFourDGoToStep(projectURL: projectURL,
                                             workspace: fourDWorkspace,
                                             window: window,
                                             textView: textView,
                                             completion: completion)
                        }
                    }
                }
            }
        }
    }

    /// Allgemeines Pollen auf dem Main-Thread; ruft `body(true)` sobald die
    /// Bedingung gilt, `body(false)` nach Fristablauf.
    private static func pollCondition(
        tick: Int, maxTicks: Int, interval: TimeInterval,
        condition: @escaping @MainActor () -> Bool,
        then body: @escaping @MainActor (Bool) -> Void
    ) {
        if condition() { body(true); return }
        if tick >= maxTicks { body(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            MainActor.assumeIsolated {
                pollCondition(tick: tick + 1, maxTicks: maxTicks,
                              interval: interval, condition: condition,
                              then: body)
            }
        }
    }

    /// Wartet auf die fertig geladene `.4dm`-Ansicht samt TextView im
    /// zugehörigen Fenster. Frist 10 s.
    private static func waitForFourDEditor(
        workspace: Workspace, tick: Int,
        then body: @escaping @MainActor ((NSWindow, TextView)?) -> Void
    ) {
        if workspace.activeTab?.isLoading == false,
           workspace.activeTab?.url?.pathExtension.lowercased() == "4dm",
           let window = documentWindows().first(where: {
               WorkspaceWindowRegistry.workspace(for: $0) === workspace
           }),
           let content = window.contentView,
           let textView = descendantTextView(in: content),
           !textView.string.isEmpty {
            body((window, textView))
            return
        }
        if tick >= 100 { body(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                waitForFourDEditor(workspace: workspace, tick: tick + 1,
                                   then: body)
            }
        }
    }

    /// Schritt 1: Zwei Zeichen auf einer frischen Zeile am Dokumentende
    /// tippen — über `insertText`, also durch dieselbe CESE-Textmutation wie
    /// eine echte Taste, bewusst NICHT am Delegate vorbei. Danach muss das
    /// Vorschlagsfenster erscheinen; geschlossen wird es wie beim
    /// Completion-Selbsttest mit Escape.
    private static func runFourDCompletionStep(
        workspace: Workspace, window: NSWindow, textView: TextView,
        completion: @escaping @MainActor () -> Void
    ) {
        let before = snapshot()
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(textView)
        appendText("\nA", to: textView)
        noteFourDMutation(in: workspace)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated {
                appendText("L", to: textView)
                pollCondition(tick: 0, maxTicks: 50, interval: 0.1, condition: {
                    completionPopup(of: window) != nil
                }) { appeared in
                    if !appeared {
                        record("4D: Completion zeigt Vorschläge",
                               "kein Vorschlagsfenster binnen 5 s nach zwei "
                               + "getippten Zeichen am Zeilenanfang")
                    }
                    closeCompletionPopup(window: window, tick: 0) {
                        settleThenCheck(label: "4D: Completion", before: before,
                                        target: window) { completion() }
                    }
                }
            }
        }
    }

    /// Schritt 2: Cursor in die Klammern eines Aufrufs setzen und auf das
    /// Signaturhilfe-Panel warten.
    ///
    /// Die Stelle wird gezielt gewählt und VORHER verifiziert:
    /// `fourDProjectMethodDisplayNames` liefert die Original-Schreibweise —
    /// der Namensindex selbst ist kleingeschrieben und träfe im Text nie —
    /// und `FourDSignatureHelpLogic.callContext` bestätigt, dass die Stelle
    /// wirklich als Aufruf zählt (kein Kommentar, kein Keyword, Klammer noch
    /// offen). Gibt es im Dokument keinen solchen Aufruf, tippt der Test
    /// selbst einen ans Dokumentende — über `insertText`, den echten
    /// Tastenweg. Erst mit verifizierter Stelle ist ein ausbleibendes Panel
    /// ein BEFUND; an einer beliebigen Klammer wäre es nur geraten.
    ///
    /// Das Panel hat zusätzlich ein Sichtbarkeits-Gate: Liegt die öffnende
    /// Klammer außerhalb von `visibleRect`, blendet es sich sofort wieder
    /// aus. Deshalb wird die Stelle erst gescrollt und der Cursor einen
    /// Runloop-Tick später gesetzt.
    private static func runFourDSignatureStep(
        workspace: Workspace, window: NSWindow, textView: TextView,
        completion: @escaping @MainActor () -> Void
    ) {
        let text = textView.string as NSString
        var cursorLocation = NSNotFound
        outer: for name in workspace.fourDProjectMethodDisplayNames {
            var search = NSRange(location: 0, length: text.length)
            while true {
                let call = text.range(of: "\(name)(", range: search)
                guard call.location != NSNotFound else { break }
                let candidate = call.location + call.length
                if FourDSignatureHelpLogic.callContext(
                    in: textView.string, utf16CursorLocation: candidate) != nil {
                    cursorLocation = candidate
                    break outer
                }
                let next = call.location + 1
                search = NSRange(location: next, length: text.length - next)
            }
        }
        if cursorLocation == NSNotFound {
            // Für den selbst getippten Aufruf einen Namen wählen, der auch
            // als Aufruf ZÄHLT: `calleeName` verlangt Buchstabe oder
            // Unterstrich am Anfang — „00_Done(" wäre kein Methodenaufruf.
            let callable = workspace.fourDProjectMethodDisplayNames.first {
                guard let first = $0.first else { return false }
                return first.isLetter || first == "_"
            }
            guard let name = callable else {
                note("4D-Signaturhilfe übersprungen: keine indizierte Methode "
                     + "mit aufrufbarem Namen")
                completion()
                return
            }
            _ = window.makeFirstResponder(textView)
            appendText("\n\(name)(", to: textView)
            noteFourDMutation(in: workspace)
            cursorLocation = (textView.string as NSString).length
            guard FourDSignatureHelpLogic.callContext(
                in: textView.string, utf16CursorLocation: cursorLocation) != nil
            else {
                note("4D-Signaturhilfe übersprungen: selbst getippter Aufruf "
                     + "ergibt keinen Aufrufkontext")
                completion()
                return
            }
        }
        let before = snapshot()
        _ = window.makeFirstResponder(textView)
        // Erst die Stelle sichtbar machen (Sichtbarkeits-Gate des Panels),
        // dann den Cursor setzen — dieselbe Reihenfolge wie beim
        // ALT-Doppelklick-Schritt.
        if let rect = textView.layoutManager.rectsFor(
            range: NSRange(location: max(0, cursorLocation - 1), length: 1)).first {
            textView.scrollToVisible(rect.insetBy(dx: 0, dy: -40))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated {
                textView.selectionManager.setSelectedRange(
                    NSRange(location: cursorLocation, length: 0)
                )
                pollCondition(tick: 0, maxTicks: 50, interval: 0.1, condition: {
                    signaturePanelText(of: window) != nil
                }) { appeared in
                    if !appeared {
                        record("4D: Signaturhilfe erscheint am Aufruf",
                               "kein Panel binnen 5 s, obwohl die Stelle laut "
                               + "callContext ein gültiger Methodenaufruf ist")
                    }
                    settleThenCheck(label: "4D: Signaturhilfe", before: before,
                                    target: window) { completion() }
                }
            }
        }
    }

    /// Schritt 3: ALT-Doppelklick auf einen Methodennamen, der als Datei
    /// existiert, indiziert ist und im Text vorkommt. Erfolg = der aktive Tab
    /// wechselt zur Zieldatei (Frist 5 s). ACHTUNG: `GoToTargetGesture` nutzt
    /// intern `Workspace.shared` — landet der Sprung in einem FREMDEN
    /// Fenster, ist das ein echter Produktbefund, den die Invarianten melden
    /// sollen; hier wird nichts unterdrückt.
    private static func runFourDGoToStep(
        projectURL: URL, workspace: Workspace,
        window: NSWindow, textView: TextView,
        completion: @escaping @MainActor () -> Void
    ) {
        let methodsDirectory = projectURL
            .appendingPathComponent("Project/Sources/Methods", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: methodsDirectory, includingPropertiesForKeys: nil)) ?? []
        let text = textView.string as NSString
        let currentFile = workspace.activeTab?.url?.lastPathComponent
        // Der Name darf nicht die gerade offene Methode selbst sein — sonst
        // wäre kein Tabwechsel beobachtbar.
        var chosen: (file: String, range: NSRange)?
        for file in files where file.pathExtension.lowercased() == "4dm" {
            let name = file.deletingPathExtension().lastPathComponent
            guard file.lastPathComponent != currentFile,
                  workspace.fourDProjectMethodNames.contains(name.lowercased())
            else { continue }
            let range = text.range(of: name)
            guard range.location != NSNotFound else { continue }
            chosen = (file.lastPathComponent, range)
            break
        }
        guard let chosen else {
            note("4D-ALT-Doppelklick übersprungen: kein indizierter "
                 + "Methodenname aus dem Projekt im Text gefunden")
            completion()
            return
        }
        guard let rect = textView.layoutManager.rectsFor(
            range: NSRange(location: chosen.range.location, length: 1)).first
        else {
            note("4D-ALT-Doppelklick übersprungen: keine Layout-Position "
                 + "für den Methodennamen")
            completion()
            return
        }
        let before = snapshot()
        // Die Stelle sichtbar machen — ein Klick auf eine Position außerhalb
        // des Viewports träfe eine andere Zeile oder gar nicht den Editor.
        textView.scrollToVisible(rect.insetBy(dx: 0, dy: -40))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated {
                // down/up/down/up mit clickCount 1,1,2,2 und ⌥ über die
                // App-Queue, damit der lokale Monitor (GoToTargetGesture)
                // die Events wirklich sieht.
                let windowPoint = textView.convert(
                    NSPoint(x: rect.midX, y: rect.midY), to: nil)
                let time = ProcessInfo.processInfo.systemUptime
                for (clickCount, type) in [(1, NSEvent.EventType.leftMouseDown),
                                           (1, .leftMouseUp),
                                           (2, .leftMouseDown),
                                           (2, .leftMouseUp)] {
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: windowPoint,
                        modifierFlags: [.option], timestamp: time,
                        windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: clickCount, pressure: 1
                    ) else { continue }
                    NSApp.postEvent(event, atStart: false)
                }
                pollCondition(tick: 0, maxTicks: 20, interval: 0.25, condition: {
                    workspace.activeTab?.url?.lastPathComponent == chosen.file
                }) { jumped in
                    if !jumped {
                        record("4D: ALT-Doppelklick öffnet die Methode",
                               "Sprung zur Zielmethode blieb binnen 5 s aus "
                               + "(aktiver Tab: \(workspace.activeTab?.title ?? "—"))")
                    }
                    settleThenCheck(label: "4D: ALT-Doppelklick", before: before,
                                    target: window) { completion() }
                }
            }
        }
    }

    /// Fügt Text am Dokumentende ein — wie `insertCompletionCharacter` im
    /// Selbsttest: über die öffentliche AppKit-Eingabemethode.
    private static func appendText(_ text: String, to textView: TextView) {
        let end = (textView.string as NSString).length
        textView.selectionManager.setSelectedRange(
            NSRange(location: end, length: 0)
        )
        textView.insertText(text as NSString,
                            replacementRange: NSRange(location: end, length: 0))
    }

    /// Das Completion-Fenster ist ein sichtbares Kindfenster mit Tabelle —
    /// dieselbe öffentliche Form, über die es auch der Completion-Selbsttest
    /// beobachtet.
    private static func completionPopup(of window: NSWindow) -> NSWindow? {
        (window.childWindows ?? []).first { child in
            guard child.isVisible, let content = child.contentView else {
                return false
            }
            return descendantTableView(in: content) != nil
        }
    }

    private static func descendantTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews {
            if let found = descendantTableView(in: sub) { return found }
        }
        return nil
    }

    /// Text des Signaturhilfe-Panels (randloses Kindfenster mit Label);
    /// `nil`, wenn keines sichtbar ist.
    private static func signaturePanelText(of window: NSWindow) -> String? {
        for child in window.childWindows ?? [] {
            guard child.styleMask.contains(.borderless), child.isVisible,
                  let content = child.contentView else { continue }
            for view in content.subviews {
                if let label = view as? NSTextField {
                    return label.attributedStringValue.string
                }
            }
        }
        return nil
    }

    /// Schließt das Vorschlagsfenster mit Escape; bleibt es hängen, wird es
    /// nach 1,5 s hart geschlossen (Notnagel wie im Completion-Selbsttest).
    private static func closeCompletionPopup(
        window: NSWindow, tick: Int,
        then body: @escaping @MainActor () -> Void
    ) {
        guard let popup = completionPopup(of: window) else { body(); return }
        if tick == 0 {
            postEscapeKey(windowNumber: window.windowNumber)
        } else if tick >= 30 {
            popup.close()
            body()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated {
                closeCompletionPopup(window: window, tick: tick + 1, then: body)
            }
        }
    }

    private static func postEscapeKey(windowNumber: Int) {
        guard let key = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ) else { return }
        NSApp.postEvent(key, atStart: false)
    }
}
