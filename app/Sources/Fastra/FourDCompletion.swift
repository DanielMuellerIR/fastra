// FourDCompletion.swift
//
// 4D-Vervollständigung mit Signatur-Hilfe (Etappe 6 Wunschpaket 2026-07c).
//
// Nutzt das CodeSuggestion-System von CodeEditSourceEditor (0.15.2): Fastra
// liefert nur den Delegate — Popup, Tastatur (↑/↓, Return/Tab übernimmt,
// Esc schließt) und Filter-Lebenszyklus kommen aus CESE und verhalten sich
// wie macOS-üblich (Esc bzw. ⌃Leertaste öffnen die Vorschläge manuell).
// Aktiv NUR bei aktiver 4D-Sprache: der Delegate wird in `EditorView`
// ausschließlich für 4D-Tabs an den `SourceEditor` gereicht.
//
// Unaufdringlich: Vorschläge erscheinen erst ab zwei getippten Zeichen
// (manuelles Öffnen zeigt auch kürzere Präfixe), und der Delegate liefert
// `nil`, sobald kein sinnvolles Präfix unter dem Cursor liegt.

import SwiftUI
import CodeEditSourceEditor
import CodeEditTextView

/// Reine, unit-testbare Vorschlags-Logik (Präfix-Erkennung + Matching).
enum FourDCompletionLogic {

    /// Ein Treffer: kanonischer Name plus Signatur (Befehle) bzw.
    /// Konstanten-, Projektmethoden- oder Komponenten-Kennzeichnung.
    struct Match: Equatable {
        let name: String
        let signature: String?
        let isConstant: Bool
        var isProjectMethod: Bool = false
        /// Name der Komponente, wenn der Treffer eine geteilte
        /// Komponentenmethode ist; sonst `nil`.
        var componentName: String? = nil
    }

    /// Eine anbietbare Komponentenmethode (reine Daten für das Matching).
    struct ComponentMethodEntry: Equatable {
        let name: String
        let componentName: String
    }

    /// Ab so vielen Zeichen erscheinen Vorschläge beim Tippen
    /// (unaufdringlich); manuelles Öffnen (Esc/⌃Leertaste) zeigt ab 1.
    static let automaticMinimumPrefixLength = 2
    /// Obergrenze der Liste — mehr hilft niemandem.
    static let maximumMatches = 200

    /// Das aktuell getippte Wort RÜCKWÄRTS vom Cursor: Wortzeichen plus
    /// einzelne Leerzeichen zwischen Wörtern (4D-Befehle sind mehrwortig,
    /// „OBJECT SET …"). `nil`, wenn unter dem Cursor kein sinnvolles
    /// Befehls-/Konstanten-Präfix liegt (z. B. direkt hinter `$`, `.`,
    /// `[` oder `<>` — dort beginnen Variablen/Member/Tabellen).
    static func prefixRange(in text: String, utf16CursorLocation cursor: Int) -> NSRange? {
        let scalars = Array(text.utf16)
        guard cursor > 0, cursor <= scalars.count else { return nil }

        func char(_ at: Int) -> Character? {
            guard at >= 0, at < scalars.count,
                  let scalar = Unicode.Scalar(scalars[at]) else { return nil }
            return Character(scalar)
        }
        func isWordChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_"
        }

        var start = cursor
        var index = cursor - 1
        while index >= 0, let c = char(index) {
            if isWordChar(c) {
                start = index
                index -= 1
                continue
            }
            // EIN Leerzeichen gehört zur Phrase, wenn davor ein Wortzeichen
            // steht — auch als letztes getipptes Zeichen („OBJECT SET “),
            // damit mehrwortige Befehle beim Weitertippen gefiltert bleiben.
            if c == " ", let before = char(index - 1), isWordChar(before) {
                start = index
                index -= 1
                continue
            }
            break
        }
        guard start < cursor else { return nil }
        // Hinter $, <>, . oder [ beginnt keine Befehls-/Konstanten-Phrase.
        if let boundary = char(start - 1),
           boundary == "$" || boundary == "." || boundary == "[" || boundary == ">" {
            return nil
        }
        // Phrasen beginnen mit einem Buchstaben (Zahlen sind Zahlen).
        guard let first = char(start), first.isLetter else { return nil }
        return NSRange(location: start, length: cursor - start)
    }

    /// Case-tolerante Präfix-Treffer: Befehle (mit Signatur), dann
    /// Projektmethoden des geöffneten Projekts, dann geteilte
    /// Komponentenmethoden, dann Konstanten — jeweils alphabetisch (die
    /// generierten Listen sind sortiert, die Methodenlisten kommen sortiert
    /// aus den Indizes). So funktioniert das Typeahead auch in
    /// verschachtelten Aufrufen, wo Argumente selbst Methodenaufrufe sind.
    static func matches(forPrefix prefix: String,
                        projectMethods: [String] = [],
                        componentMethods: [ComponentMethodEntry] = [],
                        limit: Int = maximumMatches) -> [Match] {
        let needle = prefix.lowercased()
        guard !needle.isEmpty else { return [] }
        var result: [Match] = []
        for command in FourDSymbols.commands
        where command.lowercased().hasPrefix(needle) {
            result.append(Match(
                name: command,
                signature: FourDSymbols.commandDetails[command.lowercased()]?.signature,
                isConstant: false
            ))
            if result.count >= limit { return result }
        }
        for method in projectMethods
        where method.lowercased().hasPrefix(needle) {
            result.append(Match(name: method, signature: nil,
                                isConstant: false, isProjectMethod: true))
            if result.count >= limit { return result }
        }
        // Bei Namensgleichheit gewinnt die Projektmethode
        // (Produktentscheidung 2026-07-24): nur ein Eintrag pro Name.
        let projectNames = Set(projectMethods.map { $0.lowercased() })
        for entry in componentMethods
        where entry.name.lowercased().hasPrefix(needle)
            && !projectNames.contains(entry.name.lowercased()) {
            result.append(Match(name: entry.name, signature: nil,
                                isConstant: false,
                                componentName: entry.componentName))
            if result.count >= limit { return result }
        }
        for constant in FourDSymbols.constants
        where constant.lowercased().hasPrefix(needle) {
            result.append(Match(name: constant, signature: nil, isConstant: true))
            if result.count >= limit { return result }
        }
        return result
    }
}

/// Ein Eintrag der Vorschlagsliste (CESE-Modellprotokoll).
struct FourDSuggestion: CodeSuggestionEntry {
    let label: String
    let detail: String?
    var documentation: String? { nil }
    var pathComponents: [String]? { nil }
    var targetPosition: CursorPosition? { nil }
    var sourcePreview: String? { nil }
    let image: Image
    let imageColor: Color
    var deprecated: Bool { false }

    init(match: FourDCompletionLogic.Match) {
        label = match.name
        // Signatur als dezente Zweitinformation; Konstanten und
        // Projektmethoden sind als solche gekennzeichnet.
        if match.isProjectMethod {
            detail = L10n.string("Projektmethode")
            image = Image(systemName: "m.square")
            imageColor = Color.green
        } else if let componentName = match.componentName {
            // Kennzeichnung mit Komponentenname — der Nutzer sieht sofort,
            // woher die Methode kommt.
            detail = L10n.format("Komponente „%@“", componentName)
            image = Image(systemName: "shippingbox")
            imageColor = Color.orange
        } else if match.isConstant {
            detail = L10n.string("Konstante")
            image = Image(systemName: "k.square")
            imageColor = Color.purple
        } else {
            detail = match.signature
            image = Image(systemName: "function")
            imageColor = Color.blue
        }
    }
}

/// Delegate für das CESE-Vorschlagsfenster. Wird in `EditorView` stark
/// gehalten (`@StateObject`) und nur für 4D-Tabs an den Editor gereicht.
@MainActor
final class FourDCompletionDelegate: ObservableObject, CodeSuggestionDelegate {

    /// Liefert die Original-Schreibweisen der Projektmethoden des aktiven
    /// Projekts (sortiert). Wird von `EditorView` gesetzt und liest den
    /// Workspace erst beim Aufruf — so bleibt die Liste auch nach einem
    /// Index-Refresh aktuell.
    var projectMethodProvider: () -> [String] = { [] }

    /// Liefert die geteilten Komponentenmethoden des aktiven Projekts
    /// (sortiert) — gleiche Lebensdauer-Logik wie `projectMethodProvider`.
    var componentMethodProvider: () -> [FourDCompletionLogic.ComponentMethodEntry] = { [] }

    /// `true`, solange das Fenster offen ist — beim Weitertippen darf die
    /// Liste auch unter der automatischen Mindestlänge weiterfiltern.
    private var windowIsOpen = false

    /// Vom CESE-Patch (`build.sh` 4b-2) per Notification gesetzt: Der nächste
    /// Vorschlags-Request stammt aus dem manuellen Aufruf (Esc/⌃Leertaste)
    /// und darf schon ab EINEM Zeichen liefern. Beim Lesen verbraucht und
    /// zusätzlich zeitlich begrenzt — eine verirrte Scharfschaltung ohne
    /// folgenden Request darf nicht Minuten später ein Tipp-Popup bei einem
    /// Zeichen auslösen (Selbsttestbefund completion4d, 2026-08-09).
    private var manualTriggerArmedAt: Date?
    private static let manualTriggerLifetime: TimeInterval = 0.5
    private var manualTriggerObserver: NSObjectProtocol?
    /// Der Editor-Controller, der den manuellen Aufruf ausgelöst hat. Die
    /// Notification läuft prozessweit; ohne diese Zuordnung schaltet ein
    /// ⌃Leertaste in Fenster A auch die Delegates ALLER anderen 4D-Fenster
    /// scharf, und dort erschiene beim nächsten getippten Zeichen ein
    /// ungewolltes Popup (Review 2026-08-10). Schwach gehalten: Der
    /// Controller hält seinerseits den Delegate.
    private weak var manualTriggerController: TextViewController?

    static let manualTriggerNotification =
        Notification.Name("fastra.completion.manualTrigger")

    init() {
        manualTriggerObserver = NotificationCenter.default.addObserver(
            forName: Self.manualTriggerNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // queue: .main garantiert den Main-Thread; die Klasse ist
            // MainActor-isoliert.
            MainActor.assumeIsolated {
                self?.manualTriggerArmedAt = Date()
                // Der Patch schickt den auslösenden Controller als Objekt der
                // Notification mit; nur dessen eigener Request darf den
                // Ein-Zeichen-Modus später verbrauchen.
                self?.manualTriggerController =
                    notification.object as? TextViewController
            }
        }
    }

    deinit {
        if let manualTriggerObserver {
            NotificationCenter.default.removeObserver(manualTriggerObserver)
        }
    }

    /// Vorschläge zum aktuellen Cursor. `nil` = nichts anzeigen.
    private func suggestions(textView: TextViewController,
                             cursorPosition: CursorPosition,
                             minimumLength: Int) -> [CodeSuggestionEntry]? {
        let text = textView.textView.string
        guard cursorPosition.range.length == 0,
              // In Kommentaren und String-Literalen sind Methodennamen-
              // Vorschläge sinnlos und stören beim Prosa-Tippen
              // (Review 2026-08-02).
              !FourDSignatureHelpLogic.isInsideCommentOrString(
                  in: text, utf16Location: cursorPosition.range.location),
              let range = FourDCompletionLogic.prefixRange(
                in: text, utf16CursorLocation: cursorPosition.range.location
              ),
              range.length >= minimumLength,
              let stringRange = Range(range, in: text) else { return nil }
        let prefix = String(text[stringRange])
        let matches = FourDCompletionLogic.matches(
            forPrefix: prefix, projectMethods: projectMethodProvider(),
            componentMethods: componentMethodProvider()
        )
        guard !matches.isEmpty else { return nil }
        return matches.map(FourDSuggestion.init(match:))
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        // Beim manuellen Öffnen (Esc/⌃Leertaste, vom CESE-Patch gemeldet)
        // genügt EIN Zeichen; das automatische Tipp-Popup bleibt
        // unaufdringlich (ab zwei Zeichen). Ein offenes Fenster filtert
        // ebenfalls ab einem Zeichen weiter. Verbraucht wird die
        // Scharfschaltung nur vom Request DESSELBEN Editors — sonst reichte
        // ein manueller Aufruf in einem Fenster in alle anderen hinüber.
        let manual = manualTriggerController === textView
            && (manualTriggerArmedAt.map {
                Date().timeIntervalSince($0) <= Self.manualTriggerLifetime
            } ?? false)
        // Verbrauchen darf nur der zugeordnete Editor. Ein fremder Request
        // löscht die Scharfschaltung nicht, sonst käme sie beim eigentlichen
        // Aufrufer nie an.
        if manualTriggerController === textView {
            manualTriggerArmedAt = nil
            manualTriggerController = nil
        }
        let minimum = (windowIsOpen || manual)
            ? 1 : FourDCompletionLogic.automaticMinimumPrefixLength
        guard let items = suggestions(textView: textView,
                                      cursorPosition: cursorPosition,
                                      minimumLength: max(1, minimum)) else {
            return nil
        }
        windowIsOpen = true
        return (cursorPosition, items)
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        // Offenes Fenster: live weiterfiltern; kein Präfix mehr → schließen.
        suggestions(textView: textView, cursorPosition: cursorPosition,
                    minimumLength: 1)
    }

    func completionWindowDidClose() {
        windowIsOpen = false
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        guard let suggestion = item as? FourDSuggestion,
              let cursorPosition else { return }
        let text = textView.textView.string
        // Das getippte Teilwort wird ERSETZT (nicht angehängt) — ein
        // normaler, mit ⌘Z widerrufbarer Textedit.
        let replaceRange = FourDCompletionLogic.prefixRange(
            in: text, utf16CursorLocation: cursorPosition.range.location
        ) ?? cursorPosition.range
        textView.textView.undoManager?.beginUndoGrouping()
        textView.textView.selectionManager.setSelectedRange(replaceRange)
        textView.textView.insertText(suggestion.label)
        textView.textView.undoManager?.endUndoGrouping()
    }
}
