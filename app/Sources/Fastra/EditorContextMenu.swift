// EditorContextMenu.swift
//
// Rechtsklick-Menü für den Editor (v0.8): Ausschneiden/Kopieren/Einfügen
// plus die Fastra-eigenen Einträge „Formatiert als Markdown einfügen"
// (Smart-Paste, eine der drei Alleinstellungen), „Zeilen sortieren" und
// „Duplikate entfernen" (LineOperations).
//
// WARUM EIN EVENT-MONITOR STATT EINES VIEW-HOOKS:
// CodeEditTextViews `TextView.menu(for:)` liefert ein HARTKODIERTES
// Cut/Copy/Paste-Menü (TextView+Menu.swift im Checkout) — es gibt keine
// öffentliche Erweiterungs-API. Ein sechster build.sh-Checkout-Patch wäre
// unverhältnismäßig (Wartungslast, siehe Gutter-Entscheidung in
// _log/decisions.md). Stattdessen nutzen wir das im Projekt etablierte
// Muster der lokalen NSEvent-Monitore (vgl. CMD+F im AppDelegate):
// Ein Monitor fängt `.rightMouseDown` ab; liegt der Klick über der
// Editor-TextView, zeigen wir UNSER Menü und konsumieren das Event —
// das eingebaute Menü kommt dann nie zum Zug.

import AppKit
import CodeEditTextView

/// Pure Klemmung einer gemeldeten Textauswahl — ohne AppKit prüfbar.
///
/// Bewusst von der TextView getrennt: Ein Editor braucht ein Fenster, die
/// Rechnung nicht. So lässt sich jeder Grenzfall als Unit-Test festnageln,
/// statt ihn in einem Fenstertest zu hoffen.
enum SelectionClamping {
    /// Bringt `range` in einen Bereich, der für einen Text der Länge
    /// `textLength` gefahrlos verwendbar ist.
    ///
    /// `NSNotFound` ist der Normalfall eines Editors ohne Auswahl und wird
    /// zum Dokumentanfang — dort erwartet auch AppKit einen frischen
    /// Einfügepunkt.
    static func clamp(_ range: NSRange, textLength: Int) -> NSRange {
        let length = max(0, textLength)
        guard range.location != NSNotFound, range.location >= 0 else {
            return NSRange(location: 0, length: 0)
        }
        let location = min(range.location, length)
        return NSRange(location: location,
                       length: min(max(0, range.length), length - location))
    }
}

/// Führt rechenintensive Dokumenttransformationen außerhalb des UI-Threads
/// aus und liefert ihr Ergebnis für die eigentliche Editoränderung zurück auf
/// den Main-Thread. Formatieren und Minifizieren teilen damit dieselbe
/// Nebenläufigkeitsgrenze.
enum EditorDocumentTransformationScheduler {
    static func run<Output>(
        operation: @escaping () -> Output,
        completion: @escaping (Output) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let output = operation()
            DispatchQueue.main.async {
                completion(output)
            }
        }
    }
}

extension TextView {
    /// Auswahl, die garantiert INNERHALB des Textes liegt.
    ///
    /// `selectedRange()` liefert `{NSNotFound, 0}`, solange der Editor
    /// überhaupt keine Auswahl hat — der Normalzustand eines frisch
    /// geöffneten Fensters, in das noch niemand geklickt hat
    /// (`TextView+NSTextInput.swift`: `textSelections.first?.range ??
    /// NSRange(location: NSNotFound, length: 0)`).
    ///
    /// Wer diesen Wert ungeprüft an `replaceCharacters` weitergibt, bricht
    /// die ganze Anwendung ab: Der Undo-Verwalter bildet die Umkehrung der
    /// Änderung und trifft dabei auf „Range invalid for string". Real
    /// auslösbar, indem man in ein gerade geöffnetes Markdown-Dokument ein
    /// Bild zieht, ohne vorher hineingeklickt zu haben (vom Dauertest
    /// gefunden, 2026-08-08).
    ///
    /// Dieselbe Wurzel hat der `IndexSet`-Absturz aus den Fenstertests:
    /// Auch dort war eine Auswahl mit `NSNotFound` die Ursache. Deshalb
    /// gehen ALLE Lesezugriffe auf die Auswahl über diese eine Stelle.
    var fastraSafeSelectedRange: NSRange {
        SelectionClamping.clamp(selectedRange(), textLength: textStorage.length)
    }

    /// Wendet eine Fastra-Textoperation als eigene Undo-Gruppe an und hält die
    /// Auswahl an einer stabilen, zum Ergebnis passenden Position.
    ///
    /// CodeEditTextView setzt die Auswahl bei einer großen Ersetzung sonst ans
    /// Ende des Ersatztexts. Bei „Zeilen verbinden“ ist das eine einzige,
    /// tausende Zeichen lange Soft-Wrap-Zeile; Layout und Scroll-Anker können
    /// dadurch auseinanderlaufen. Eine per Cmd+A gewählte Ganzdokument-Range
    /// darf ebenfalls nicht als riesige Einzeilen-Auswahl bestehen bleiben:
    /// Genau dieser Zustand lässt CodeEdit ohne Soft Wrap leer erscheinen.
    /// Die expliziten Auswahl-Snapshots verhindern beide Zustände, ohne
    /// normales Tippen oder Einfügen zu verändern.
    func fastraApplyTextOperation(replacing range: NSRange, with replacement: String) {
        let selectionBefore = fastraSafeSelectedRange
        let selectedWholeDocument = range.location == 0
            && range.length == textStorage.length
            && selectionBefore == range
        let stableSelectionBefore = selectedWholeDocument
            ? NSRange(location: 0, length: 0)
            : selectionBefore
        let replacementLength = (replacement as NSString).length
        let selectionAfter = fastraSelection(
            afterReplacing: range,
            replacementLength: replacementLength,
            selectionBefore: selectionBefore,
            selectedWholeDocument: selectedWholeDocument
        )
        let undoManager = _undoManager
        let startsUndoGroup = !(undoManager?.isGrouping ?? false)

        if startsUndoGroup {
            undoManager?.beginUndoGrouping()
        }
        replaceCharacters(in: range, with: replacement)
        selectionManager.setSelectedRange(selectionAfter)
        undoManager?.fastraSetSelectionSnapshotsForLatestUndo(
            before: [stableSelectionBefore],
            after: [selectionAfter]
        )
        if startsUndoGroup {
            undoManager?.endUndoGrouping()
        }

        // Die neue Auswahl ist der Layout-Anker. Das synchrone Neulayout ist
        // für große Zeilenstruktur-Änderungen nötig, bevor asynchrones
        // Markdown-Highlighting erneut Attribute invalidiert.
        layoutManager.setNeedsLayout()
        layoutManager.layoutLines()
        scrollSelectionToVisible()
    }

    private func fastraSelection(
        afterReplacing range: NSRange,
        replacementLength: Int,
        selectionBefore: NSRange,
        selectedWholeDocument: Bool
    ) -> NSRange {
        // Cmd+A dient hier als Scope-Angabe für die Textoperation, nicht als
        // sinnvoller dauerhafter Layoutanker. Auch Undo kehrt deshalb stabil
        // an den Dokumentanfang zurück, statt die alte Vollauswahl aufzubauen.
        if selectedWholeDocument {
            return NSRange(location: 0, length: 0)
        }
        if selectionBefore.length > 0 {
            return NSRange(location: range.location, length: replacementLength)
        }

        let newDocumentLength = textStorage.length - range.length + replacementLength
        let location: Int
        if selectionBefore.location < range.location {
            location = selectionBefore.location
        } else if selectionBefore.location > range.max {
            location = selectionBefore.location - range.length + replacementLength
        } else {
            // Eine Transformation des ganzen Dokuments hat keine eindeutige
            // Zeichenabbildung. Der Anfang des bearbeiteten Blocks ist stabil
            // und verhindert den Sprung ans Ende einer riesigen Soft-Wrap-Zeile.
            location = range.location
        }
        return NSRange(
            location: min(max(0, location), max(0, newDocumentLength)),
            length: 0
        )
    }
}

/// Identifiziert eine Text-Transformation (BBEdit-„Text"-Menü-Basics).
/// `Int`-rohwertig, damit die SwiftUI-Menüleiste die Aktion verlustfrei per
/// Notification (`.fastraTextOp`, `object` = `rawValue`) an den AppDelegate
/// schicken kann, der sie auf den aktiven Editor anwendet.
enum TextOpKind: Int, CaseIterable {
    case uppercase, lowercase, titlecase
    case trimTrailing, detab, entab
    case zapGremlins, straightenQuotes, educateQuotes, convertEscapeSequences
    case shiftRight, shiftLeft
    case reverseLines, removeBlankLines, joinLines, joinLinesTight, prefixLines, suffixLines
    case addLineNumbers, removeLineNumbers
    case exchangeCharacters, exchangeWords
    // BBEdit „Process Lines Containing": Zeilen nach RegEx-Muster behalten/löschen.
    case keepLinesMatching, deleteLinesMatching
    // BBEdit „Process Duplicate Lines": Dubletten finden bzw. mehrfache entfernen.
    case keepDuplicateLines, removeAllDuplicatedLines
    // BBEdit „Hard Wrap": Zeilen auf eine feste Spaltenbreite umbrechen.
    case hardWrap
    // Unicode-Gruppe (BBEdit Kap. 5): Leerzeichen-Varianten vereinheitlichen,
    // Diakritika strippen, NFC-/NFD-Normalisierung. Neue Fälle IMMER hinten
    // anhängen — der Int-Rohwert wandert durch die Notification, Einschieben
    // würde bestehende Werte verschieben.
    case normalizeSpaces, stripDiacriticals, precomposeUnicode, decomposeUnicode
    // 4D-Export-Transformation (Etappe 6 Wunschpaket 2026-07c):
    // Token-Suffixe strippen bzw. Befehls-Token ergänzen.
    case fourDDetokenize, fourDTokenizeCommands
    // Emoji-Präsentation (Daniel-Befund 2026-07-27): Variantenselektor
    // U+FE0F ergänzen bzw. entfernen. Wieder hinten angehängt.
    case addEmojiPresentation, removeEmojiPresentation

    /// Menü-Beschriftung.
    var title: String {
        let key = switch self {
        case .uppercase:        "GROSSBUCHSTABEN"
        case .lowercase:        "kleinbuchstaben"
        case .titlecase:        "Wörter Groß"
        case .trimTrailing:     "Leerzeichen am Zeilenende entfernen"
        case .detab:            "Tabs → Leerzeichen"
        case .entab:            "Leerzeichen → Tabs"
        case .zapGremlins:      "Steuerzeichen entfernen"
        case .straightenQuotes: "Anführungszeichen gerade richten"
        case .educateQuotes:    "Anführungszeichen schwungvoll (englisch)"
        case .convertEscapeSequences: "Escape-Sequenzen auflösen"
        case .shiftRight:       "Einrücken"
        case .shiftLeft:        "Ausrücken"
        case .reverseLines:     "Zeilen umkehren"
        case .removeBlankLines: "Leerzeilen entfernen"
        case .joinLines:        "Zeilen verbinden (mit Leerzeichen)"
        case .joinLinesTight:   "Zeilen verbinden (ohne Trenner)"
        case .prefixLines:      "Präfix an Zeilen…"
        case .suffixLines:      "Suffix an Zeilen…"
        case .addLineNumbers:     "Zeilennummern hinzufügen"
        case .removeLineNumbers:  "Zeilennummern entfernen"
        case .exchangeCharacters: "Zeichen tauschen"
        case .exchangeWords:      "Wörter tauschen"
        case .keepLinesMatching:        "Nur Zeilen mit Treffer behalten…"
        case .deleteLinesMatching:      "Zeilen mit Treffer löschen…"
        case .keepDuplicateLines:       "Nur doppelte Zeilen behalten"
        case .removeAllDuplicatedLines: "Mehrfach vorkommende Zeilen entfernen"
        case .hardWrap:                 "Zeilen hart umbrechen…"
        case .normalizeSpaces:   "Leerzeichen vereinheitlichen"
        case .stripDiacriticals: "Diakritische Zeichen entfernen"
        case .precomposeUnicode: "Unicode zusammensetzen (NFC)"
        case .decomposeUnicode:  "Unicode zerlegen (NFD)"
        case .fourDDetokenize:        "4D: Token-Suffixe entfernen (:Cnnn/:Knnn)"
        case .fourDTokenizeCommands:  "4D: Befehls-Token ergänzen (:Cnnn)"
        case .addEmojiPresentation:    "Emoji-Darstellung erzwingen (U+FE0F)"
        case .removeEmojiPresentation: "Emoji-Darstellung aufheben (U+FE0F)"
        }
        return L10n.string(key)
    }

    /// `true`, wenn die Operation vorher eine Texteingabe braucht: Präfix/Suffix
    /// (anzuhängender Text), Process Lines Containing (RegEx-Muster) und Hard Wrap
    /// (Spaltenbreite). Alle drei holen den Wert über einen `promptForText`-Dialog.
    var needsInput: Bool {
        switch self {
        case .prefixLines, .suffixLines, .keepLinesMatching, .deleteLinesMatching, .hardWrap:
            return true
        default:
            return false
        }
    }

    /// Nur Operationen mit echtem Zeichen-Scope dürfen jeden Teilbereich
    /// eines Rechtecks unabhängig verändern. Zeilen-Scope, Cursor-Nachbarn
    /// und mögliche neue Zeilen würden die sichtbare Trefferbasis verlassen.
    var supportsColumnSelection: Bool {
        switch self {
        case .uppercase, .lowercase, .titlecase,
             .zapGremlins, .straightenQuotes, .educateQuotes,
             .normalizeSpaces, .stripDiacriticals,
             .precomposeUnicode, .decomposeUnicode,
             .addEmojiPresentation, .removeEmojiPresentation,
             .fourDDetokenize, .fourDTokenizeCommands:
            return true
        default:
            return false
        }
    }
}

/// Installiert den Rechtsklick-Monitor und führt die Menü-Aktionen aus.
/// Eine Instanz lebt im AppDelegate (stark referenziert), der Monitor
/// selbst hält sie über die Action-Targets am Leben.
final class EditorContextMenu: NSObject {

    /// Bindet eine nebenläufige Formatierung an genau den Editorzustand ihres
    /// Starts. Tippen, Tabwechsel oder eine neue Auswahl lassen das späte
    /// Ergebnis kontrolliert verfallen, statt fremden Text zu überschreiben.
    private final class FormattingTargetLease {
        private weak var workspace: Workspace?
        private weak var window: NSWindow?
        private weak var editor: TextView?
        let source: String
        let selection: NSRange
        let formatID: DocumentFormatID
        private let tabID: UUID
        private let contentRevision: UInt64

        init?(editor: TextView, workspace: Workspace, formatID: DocumentFormatID) {
            guard let window = editor.window,
                  WorkspaceWindowRegistry.workspace(for: window) === workspace,
                  let tab = workspace.activeTab else { return nil }
            self.workspace = workspace
            self.window = window
            self.editor = editor
            self.source = editor.string
            self.selection = editor.fastraSafeSelectedRange
            self.formatID = formatID
            self.tabID = tab.id
            self.contentRevision = tab.contentRevision
        }

        func applyIfUnchanged(_ result: DocumentFormatResult) -> Bool {
            guard let workspace, let window, let editor,
                  editor.window === window,
                  WorkspaceWindowRegistry.workspace(for: window) === workspace,
                  workspace.activeTabID == tabID,
                  workspace.activeTab?.contentRevision == contentRevision,
                  editor.fastraSafeSelectedRange == selection else { return false }
            editor.fastraApplyTextOperation(
                replacing: result.affectedRange,
                with: result.replacement
            )
            return true
        }
    }

    /// Die TextView unter dem letzten Rechtsklick — Ziel aller Aktionen.
    /// `weak`, damit ein geschlossener Editor nicht festgehalten wird.
    private weak var targetTextView: TextView?

    private var monitor: Any?
    /// Der laufende tool4d-Aufruf bleibt hier stark referenziert. Ein zweiter
    /// Klick beendet den alten Lauf, damit dessen spätes Ergebnis nie ein
    /// inzwischen anderes Dokument überdecken kann.
    private var tool4DValidation: Tool4DLSPValidation?
    private weak var tool4DWorkspace: Workspace?
    private var tool4DProjectObserver: NSObjectProtocol?

    /// Lokalen Monitor installieren. Idempotent (mehrfacher Aufruf ok).
    func install() {
        guard monitor == nil else { return }
        tool4DProjectObserver = NotificationCenter.default.addObserver(
            forName: .fastraProjectContextWillChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let workspace = notification.object as? Workspace,
                  self.tool4DWorkspace === workspace else { return }
            self.tool4DValidation?.cancel()
            self.tool4DValidation = nil
            self.tool4DWorkspace = nil
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    deinit {
        if let tool4DProjectObserver {
            NotificationCenter.default.removeObserver(tool4DProjectObserver)
        }
    }

    /// Prüft, ob der Rechtsklick über der Editor-TextView liegt, und zeigt
    /// dann unser Menü. Rückgabe nil = Event konsumiert (das eingebaute
    /// CodeEditTextView-Menü erscheint nicht).
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window,
              let contentView = window.contentView else { return event }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let hit = contentView.hitTest(point),
              let textView = textViewAncestor(of: hit) else { return event }

        targetTextView = textView
        NSMenu.popUpContextMenu(buildMenu(for: textView), with: event, for: textView)
        return nil
    }

    /// Läuft von der getroffenen View aufwärts und liefert die
    /// CodeEditTextView-`TextView`, falls der Klick in ihr liegt.
    private func textViewAncestor(of view: NSView) -> TextView? {
        var current: NSView? = view
        while let v = current {
            if let tv = v as? TextView { return tv }
            current = v.superview
        }
        return nil
    }

    /// Baut das Menü. Standard-Items zielen direkt auf die TextView
    /// (Responder-Selektoren), unsere Items auf self.
    private func buildMenu(for textView: TextView) -> NSMenu {
        let menu = NSMenu()
        let hasColumnSelection = textView.fastraColumnSelectionSnapshot != nil
        let hasSelection = hasColumnSelection
            || textView.selectionManager.textSelections.contains {
                $0.range.length > 0
            }

        let cut = NSMenuItem(title: L10n.string("Ausschneiden"), action: #selector(NSText.cut(_:)), keyEquivalent: "")
        cut.target = textView
        cut.isEnabled = hasSelection
        let copy = NSMenuItem(title: L10n.string("Kopieren"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copy.target = textView
        copy.isEnabled = hasSelection
        let paste = NSMenuItem(title: L10n.string("Einfügen"), action: #selector(NSText.paste(_:)), keyEquivalent: "")
        paste.target = textView

        let pasteColumn = NSMenuItem(
            title: L10n.string("Spalte einfügen"),
            action: #selector(performPasteColumn(_:)),
            keyEquivalent: ""
        )
        pasteColumn.target = self
        pasteColumn.toolTip = L10n.string(
            "Fügt Zwischenablage-Zeilen untereinander an der linken Rechteckkante oder am Cursor ein."
        )

        let smartPaste = NSMenuItem(title: L10n.string("Formatiert als Markdown einfügen"),
                                    action: #selector(performSmartPaste(_:)),
                                    keyEquivalent: "")
        smartPaste.target = self
        smartPaste.toolTip = L10n.string("Formatierten Inhalt aus der Zwischenablage (z.B. aus dem Browser) als sauberes Markdown einfügen.")
        smartPaste.isEnabled = !hasColumnSelection

        let sort = NSMenuItem(title: L10n.string("Zeilen sortieren"),
                              action: nil, keyEquivalent: "")
        let sortSubmenu = NSMenu()
        for direction in LineOperations.SortDirection.allCases {
            let item = NSMenuItem(title: direction.title,
                                  action: #selector(sortLines(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = direction.rawValue
            item.toolTip = L10n.string(
                "Sortiert die selektierten Zeilen alphabetisch in der gewählten Richtung. Ohne Auswahl: die ganze Datei."
            )
            item.isEnabled = !hasColumnSelection
            sortSubmenu.addItem(item)
        }
        sort.submenu = sortSubmenu
        sort.isEnabled = !hasColumnSelection

        let dedupe = NSMenuItem(title: L10n.string("Duplikate entfernen"),
                                action: #selector(removeDuplicates(_:)),
                                keyEquivalent: "")
        dedupe.target = self
        dedupe.toolTip = L10n.string("Entfernt doppelte Zeilen — das erste Vorkommen bleibt stehen. Ohne Auswahl: die ganze Datei.")
        dedupe.isEnabled = !hasColumnSelection

        let format = NSMenuItem(title: L10n.string("Dokument formatieren"),
                                action: #selector(formatDocument(_:)),
                                keyEquivalent: "")
        format.target = self
        format.toolTip = L10n.string("Formatiert JSON oder XML. Eine Auswahl wird einzeln formatiert.")
        // Der Menüaufbau kennt seinen Editor — die Endung deshalb aus DESSEN
        // Tab holen, nicht aus dem globalen `Workspace.shared`. Sonst richtet
        // sich das Kontextmenü eines Fensters nach dem Dokument eines anderen.
        let menuWorkspace = workspace(forEditor: textView)
        format.isEnabled = !hasColumnSelection
            && menuWorkspace?.activeDocumentFormattingID != nil

        // Prüfen und Minifizieren spiegeln „Text → Dokument prüfen/
        // minifizieren“ aus der Menüleiste. Der Linter deckt mehr Endungen ab
        // als der Formatter (4D-Container, svg), deshalb je eigene Prüfung.
        let lint = NSMenuItem(title: L10n.string("Dokument prüfen"),
                              action: #selector(lintDocument(_:)),
                              keyEquivalent: "")
        lint.target = self
        lint.toolTip = L10n.string("Prüft JSON oder XML auf Syntaxfehler und nennt Zeile und Spalte.")
        lint.isEnabled = menuWorkspace?.activeDocumentLintingExtension != nil

        let minify = NSMenuItem(title: L10n.string("Dokument minifizieren"),
                                action: #selector(minifyDocument(_:)),
                                keyEquivalent: "")
        minify.target = self
        minify.toolTip = L10n.string("Schreibt JSON oder XML kompakt ohne überflüssigen Leerraum. Eine Auswahl wird einzeln minifiziert.")
        minify.isEnabled = !hasColumnSelection
            && menuWorkspace?.activeDocumentFormattingID != nil

        // „Text"-Submenü mit den BBEdit-Basics (TextOperations). Tag trägt die
        // TextOpKind; ein gemeinsamer Handler liest ihn. Gruppen durch Trenner.
        let textItem = NSMenuItem(title: L10n.string("Text"), action: nil, keyEquivalent: "")
        let textSub = NSMenu()
        let groupBreaksAfter: Set<TextOpKind> = [.titlecase, .entab, .convertEscapeSequences, .shiftLeft, .joinLinesTight, .removeLineNumbers, .exchangeWords, .removeAllDuplicatedLines, .hardWrap, .decomposeUnicode, .fourDTokenizeCommands]
        for kind in TextOpKind.allCases {
            let item = NSMenuItem(title: kind.title,
                                  action: #selector(runTextOp(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = kind.rawValue
            item.isEnabled = !hasColumnSelection || kind.supportsColumnSelection
            if hasColumnSelection && !kind.supportsColumnSelection {
                item.toolTip = columnSelectionUnsupportedText
            }
            textSub.addItem(item)
            if groupBreaksAfter.contains(kind) { textSub.addItem(.separator()) }
        }
        textItem.submenu = textSub

        menu.items = [
            cut, copy, paste, pasteColumn,
            .separator(),
            smartPaste,
            .separator(),
            sort, dedupe, format, lint, minify,
            .separator(),
            textItem,
        ]

        // Markdown-Submenü (Etappe 5 Wunschpaket 2026-07b) — nur sichtbar,
        // wenn der aktive Tab ein Markdown-Dokument ist. (Der Monitor läuft
        // auf dem Main-Thread; die Klasse ist nur nicht annotiert.)
        if MainActor.assumeIsolated({
            MarkdownAssist.isMarkdownTabActive(in: CommandTargeting.workspace(for: textView))
        }) {
            let markdownItem = NSMenuItem(title: "Markdown", action: nil, keyEquivalent: "")
            let markdownSub = NSMenu()
            let breaksAfter: Set<MarkdownFormatCommand> = [.hardBreak, .plainParagraph, .quote, .link]
            for command in MarkdownFormatCommand.displayOrder {
                let item = NSMenuItem(title: command.menuTitle,
                                      action: #selector(runMarkdownFormat(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.tag = command.rawValue
                item.toolTip = command.helpText
                item.isEnabled = !hasColumnSelection
                if hasColumnSelection {
                    item.toolTip = columnSelectionUnsupportedText
                }
                markdownSub.addItem(item)
                if breaksAfter.contains(command) { markdownSub.addItem(.separator()) }
            }
            markdownItem.submenu = markdownSub
            menu.addItem(markdownItem)
        }

        // Wir steuern isEnabled selbst (statt Responder-Chain-Validierung).
        menu.autoenablesItems = false
        return menu
    }

    // MARK: - Aktionen

    private var columnSelectionUnsupportedText: String {
        L10n.string(
            "Dieser Befehl verändert ganze Zeilen oder kann Zeilenumbrüche erzeugen. Für eine Rechteckauswahl sind nur unabhängige Zeichen-Transformationen verfügbar."
        )
    }

    private func warnColumnSelectionUnsupported() {
        NSAlert.runWarning(
            title: L10n.string("Für Rechteckauswahl nicht verfügbar"),
            text: columnSelectionUnsupportedText
        )
    }

    @objc private func performPasteColumn(_ sender: Any?) {
        guard let textView = targetTextView else { NSSound.beep(); return }
        textView.fastraPasteColumn(sender)
    }

    @objc private func performSmartPaste(_ sender: Any?) {
        guard let textView = targetTextView,
              let lease = SmartPaste.TargetLease.capture(editor: textView) else {
            NSSound.beep()
            return
        }
        // Das Ziel wird sofort auf dem Main-Thread gebunden. Nur die
        // blockierende Konvertierung wechselt intern in einen Worker.
        SmartPaste.performSmartPaste(using: lease)
    }

    /// Rechtsklick-Handler für alle Text-Operationen (Tag = TextOpKind).
    @objc private func runTextOp(_ sender: NSMenuItem) {
        guard let kind = TextOpKind(rawValue: sender.tag),
              let textView = targetTextView else { NSSound.beep(); return }
        apply(kind, on: textView)
    }

    /// Ersetzt über die native TextView statt über das SwiftUI-Binding. Damit
    /// bleibt die Formatierung eine einzelne Undo-Aktion und die Auswahl gilt
    /// genau für den vom Nutzer markierten Bereich.
    @objc private func formatDocument(_ sender: Any?) {
        guard let textView = targetTextView else { NSSound.beep(); return }
        format(on: textView)
    }

    /// Rechtsklick-Pfad für „Dokument prüfen“ — arbeitet bewusst auf der
    /// angeklickten TextView, nicht auf der zuletzt aktiven.
    @objc private func lintDocument(_ sender: Any?) {
        guard let textView = targetTextView else { NSSound.beep(); return }
        lint(on: textView)
    }

    /// Rechtsklick-Pfad für „Dokument minifizieren“ — siehe `lintDocument`.
    @objc private func minifyDocument(_ sender: Any?) {
        guard let textView = targetTextView else { NSSound.beep(); return }
        minify(on: textView)
    }

    private func format(on textView: TextView) {
        guard textView.fastraColumnSelectionSnapshot == nil else {
            warnColumnSelectionUnsupported()
            return
        }
        // Effektives Format aus dem Workspace GENAU DIESES Editors — nicht
        // aus `Workspace.shared`. So gewinnt auch eine manuelle JSON-Wahl bei
        // `.txt`, ohne dass Fenster A nach dem Format von Fenster B arbeitet.
        guard let workspace = workspace(forEditor: textView),
              let formatID = workspace.activeDocumentFormattingID,
              let lease = FormattingTargetLease(
                editor: textView,
                workspace: workspace,
                formatID: formatID
              ) else {
            NSSound.beep()
            return
        }

        // JSONSerialization/XMLDocument und die Ausgabeerzeugung dürfen bei
        // mehreren MiB niemals die Main-Runloop anhalten. Nur Snapshot und
        // abschließende, validierte Editor-Ersetzung laufen auf dem UI-Thread.
        EditorDocumentTransformationScheduler.run(
            operation: {
                Result {
                    try DocumentFormatter.format(
                        in: lease.source,
                        selection: lease.selection,
                        formatID: lease.formatID
                    )
                }
            },
            completion: { result in
                switch result {
                case .success(let formatted):
                    guard let formatted else {
                        NSSound.beep()
                        return
                    }
                    guard lease.applyIfUnchanged(formatted) else {
                        NSAlert.runWarning(
                            title: L10n.string("Formatierung nicht übernommen"),
                            text: L10n.string(
                                "Das Dokument oder die Auswahl hat sich während der Formatierung geändert. Der neue Stand blieb unverändert."
                            )
                        )
                        return
                    }
                case .failure(let error):
                    NSAlert.runWarning(
                        title: L10n.string("Formatieren fehlgeschlagen"),
                        text: error.localizedDescription
                    )
                }
            }
        )
    }

    /// Menüleisten-Pfad für „Text → Dokument formatieren“.
    func formatActiveDocument() {
        guard let textView = activeEditorTextView() else { NSSound.beep(); return }
        format(on: textView)
    }

    /// „Text → Dokument minifizieren“ (Etappe 6): JSON kompakt (Schlüssel
    /// sortiert wie beim Formatieren), XML konservativ (nur Einrückungs-
    /// Whitespace zwischen Tags). Gleicher Apply-Pfad wie das Formatieren.
    func minifyActiveDocument() {
        guard let textView = activeEditorTextView() else { NSSound.beep(); return }
        minify(on: textView)
    }

    func minify(on textView: TextView) {
        guard textView.fastraColumnSelectionSnapshot == nil else {
            warnColumnSelectionUnsupported()
            return
        }
        // Effektives Format aus dem Workspace GENAU DIESES Editors (siehe
        // `format`).
        guard let workspace = workspace(forEditor: textView),
              let formatID = workspace.activeDocumentFormattingID,
              let lease = FormattingTargetLease(
                editor: textView,
                workspace: workspace,
                formatID: formatID
              ) else {
            NSSound.beep()
            return
        }
        // Dieselbe Größenklasse wie beim Formatieren: Parsing und Ausgabe
        // laufen im Hintergrund, anschließend schützt die Lease gegen Tippen,
        // Tabwechsel und Auswahländerungen während der Berechnung.
        EditorDocumentTransformationScheduler.run(
            operation: {
                Result {
                    try DocumentFormatter.minify(
                        in: lease.source,
                        selection: lease.selection,
                        formatID: lease.formatID
                    )
                }
            },
            completion: { result in
                switch result {
                case .success(let minified):
                    guard let minified else {
                        NSSound.beep()   // bereits minimal → No-op
                        return
                    }
                    guard lease.applyIfUnchanged(minified) else {
                        NSAlert.runWarning(
                            title: L10n.string("Minifizierung nicht übernommen"),
                            text: L10n.string(
                                "Das Dokument oder die Auswahl hat sich während der Minifizierung geändert. Der neue Stand blieb unverändert."
                            )
                        )
                        return
                    }
                case .failure(let error):
                    NSAlert.runWarning(
                        title: L10n.string("Minifizieren fehlgeschlagen"),
                        text: error.localizedDescription
                    )
                }
            }
        )
    }

    /// „Text → Dokument prüfen“ (Etappe 6): validiert JSON/XML nativ und
    /// nennt bei Fehlern Zeile/Spalte; ein Klick springt zur Fehlerstelle.
    func lintActiveDocument() {
        guard let textView = activeEditorTextView() else { NSSound.beep(); return }
        lint(on: textView)
    }

    private func lint(on textView: TextView) {
        // Workspace GENAU DIESES Editors (siehe `format`).
        guard let workspace = workspace(forEditor: textView),
              let tab = workspace.activeTab,
              let fileExtension = workspace.activeDocumentLintingExtension else {
            NSSound.beep()
            return
        }
        let text = textView.string
        if fileExtension.lowercased() == "4dm", let documentURL = tab.url,
           let projectRoot = workspace.projectURL {
            findTool4DForLinting(
                documentURL: documentURL, projectRoot: projectRoot, text: text,
                workspace: workspace, tabID: tab.id, projectGeneration: workspace.projectGeneration,
                fileExtension: fileExtension
            )
            return
        }
        presentLintResult(DocumentLinter.lint(text, fileExtension: fileExtension),
                          text: text, workspace: workspace)
    }

    /// Die Dateisystemsuche nach tool4d und der `.4DProject`-Datei darf den
    /// Editor nicht blockieren. Alle Kontextwerte werden vorher kopiert; vor
    /// einer sichtbaren Meldung prüft der Main-Thread sie erneut gegen Tab
    /// und Projektgeneration, damit ein spätes Ergebnis nie falsch landet.
    private func findTool4DForLinting(
        documentURL: URL, projectRoot: URL, text: String, workspace: Workspace,
        tabID: UUID, projectGeneration: UInt64, fileExtension: String
    ) {
        let canonicalRoot = projectRoot.canonicalFileURL
        let canonicalDocument = documentURL.canonicalFileURL
        Task.detached { [weak self, weak workspace] in
            let pathProblem = Tool4DAssist.executablePathProblem(
                Tool4DAssist.rememberedExecutablePath
            )
            let finding = Tool4DAssist.installedTool()
            let projectExists = Tool4DProjectLocator.projectFile(in: canonicalRoot) != nil
            // Der Dateisystemteil bleibt im Detached-Task. Sichtbare UI darf
            // erst wieder auf der Main-Queue entstehen; diese etablierte
            // Rückkehr vermeidet zugleich nicht-sendbare Actor-Captures.
            DispatchQueue.main.async {
                guard let self, let workspace,
                      workspace.activeTabID == tabID,
                      workspace.projectGeneration == projectGeneration,
                      workspace.projectURL?.canonicalFileURL == canonicalRoot,
                      workspace.activeTab?.url?.canonicalFileURL == canonicalDocument else {
                    return
                }
                if let pathProblem {
                    NSAlert.runWarning(
                        title: L10n.string("Eingetragenes tool4d ist nicht nutzbar"),
                        text: L10n.format("%@\n\nPrüfe den Pfad in den Einstellungen unter „4D“ oder leere das Feld, damit Fastra selbst sucht.",
                                          pathProblem)
                    )
                } else if let finding, projectExists {
                    self.lintFourDWithTool4D(
                        finding: finding, workspaceRoot: canonicalRoot,
                        documentURL: canonicalDocument, text: text,
                        workspace: workspace, tabID: tabID
                    )
                } else {
                    self.presentLintResult(
                        DocumentLinter.lint(text, fileExtension: fileExtension),
                        text: text, workspace: workspace
                    )
                }
            }
        }
    }

    private func presentLintResult(_ result: DocumentLinter.LintResult, text: String,
                                   workspace: Workspace) {
        switch result {
        case .unsupported:
            NSAlert.runWarning(
                title: L10n.string("Dokument prüfen"),
                text: L10n.string("Geprüft werden JSON- und XML-Dokumente (inkl. plist, xsd, xsl, svg und 4D-Containerdateien).")
            )
        case .valid(let label):
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L10n.string("Dokument prüfen")
            alert.informativeText = L10n.format("Gültiges %@ — keine Fehler gefunden.", label)
            alert.addButton(withTitle: L10n.string("OK"))
            alert.runModal()
        case .hintFree:
            // 4D-Struktur-Hinweise (Etappe 5 Wunschpaket 2026-07c):
            // ehrlich als Heuristik benannt — nie als „gültig" verkauft.
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L10n.string("Struktur-Hinweise")
            alert.informativeText = L10n.string("Keine Auffälligkeiten gefunden (Block-, Klammer-, String- und Kommentar-Balance). Das ist eine Heuristik, kein Compiler-Ersatz — verbindlich prüft tool4d, siehe Hilfe „4D und tool4d“.")
            alert.addButton(withTitle: L10n.string("OK"))
            alert.runModal()
        case .hint(let issue):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.string("Struktur-Hinweis")
            alert.informativeText = L10n.format("Zeile %ld, Spalte %ld: %@\n\nHeuristische Prüfung — kein Compiler-Ersatz.",
                                                issue.line, issue.column, issue.message)
            alert.addButton(withTitle: L10n.string("Zur Stelle springen"))
            alert.addButton(withTitle: L10n.string("Schließen"))
            if alert.runModal() == .alertFirstButtonReturn {
                let range = BufferSearch.nsRange(forLine: issue.line,
                                                 column: issue.column, in: text)
                NotificationCenter.default.post(name: .fastraJumpToRange,
                                                object: workspace,
                                                userInfo: ["range": NSValue(range: range)])
            }
        case .issue(let issue):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.string("Dokument prüfen")
            alert.informativeText = L10n.format("Zeile %ld, Spalte %ld: %@",
                                                issue.line, issue.column, issue.message)
            alert.addButton(withTitle: L10n.string("Zur Fehlerstelle springen"))
            alert.addButton(withTitle: L10n.string("Schließen"))
            if alert.runModal() == .alertFirstButtonReturn {
                let range = BufferSearch.nsRange(forLine: issue.line,
                                                 column: issue.column, in: text)
                NotificationCenter.default.post(name: .fastraJumpToRange,
                                                object: workspace,
                                                userInfo: ["range": NSValue(range: range)])
            }
        }
    }

    /// Die echte 4D-Diagnose läuft vollständig nebenläufig. Erst die
    /// Completion kehrt auf den Main-Thread zurück und prüft Tab-ID und
    /// Workspace erneut; ein Projektwechsel oder Tab-Wechsel kann so keine
    /// veraltete Warnung im falschen Dokument öffnen.
    private func lintFourDWithTool4D(
        finding: Tool4DDiscovery.Finding, workspaceRoot: URL, documentURL: URL,
        text: String, workspace: Workspace, tabID: UUID
    ) {
        tool4DValidation?.cancel()
        let validation = Tool4DLSPValidation()
        tool4DValidation = validation
        tool4DWorkspace = workspace
        validation.start(executable: finding.executableURL, workspaceRoot: workspaceRoot,
                         documentURL: documentURL, text: text) { [weak self, weak workspace] result in
            guard let self, self.tool4DValidation === validation else { return }
            // Besitzreferenz IMMER lösen, sobald dieser Lauf fertig ist —
            // auch wenn Tab oder Workspace inzwischen gewechselt haben.
            // Sonst riefe der nächste Klick `cancel()` auf einem bereits
            // abgeschlossenen Lauf auf.
            self.tool4DValidation = nil
            self.tool4DWorkspace = nil
            guard let workspace, workspace.activeTabID == tabID else { return }
            switch result {
            case .success(let diagnostics):
                self.presentTool4DDiagnostics(diagnostics, text: text, workspace: workspace)
            case .failure(let error):
                // Ein abgebrochener älterer Lauf ist kein Nutzerfehler und
                // bekommt daher keinen Alarm. Alle anderen Fehler erklären
                // klar, dass die externe tool4d-Prüfung nicht stattfand.
                guard error != .cancelled else { return }
                NSAlert.runWarning(
                    title: L10n.string("Dokument prüfen"),
                    text: L10n.format("Die tool4d-Prüfung konnte nicht abgeschlossen werden: %@\n\nStruktur-Hinweise bleiben verfügbar; Details stehen in der Hilfe „4D und tool4d“.",
                                      error.localizedDescription)
                )
            }
        }
    }

    private func presentTool4DDiagnostics(_ diagnostics: [Tool4DDiagnostic],
                                           text: String, workspace: Workspace) {
        guard let first = diagnostics.first else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L10n.string("Dokument prüfen")
            alert.informativeText = L10n.string("tool4d hat keine Diagnosen für dieses Dokument gemeldet.")
            alert.addButton(withTitle: L10n.string("OK"))
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Dokument prüfen")
        let more = diagnostics.count > 1
            ? L10n.format("\n\nWeitere tool4d-Diagnosen: %ld", diagnostics.count - 1)
            : ""
        alert.informativeText = L10n.format("Zeile %ld, Spalte %ld: %@%@",
                                            first.line, first.column, first.message, more)
        alert.addButton(withTitle: L10n.string("Zur Fehlerstelle springen"))
        alert.addButton(withTitle: L10n.string("Schließen"))
        if alert.runModal() == .alertFirstButtonReturn {
            let range = BufferSearch.nsRange(forLine: first.line, column: first.column, in: text)
            NotificationCenter.default.post(name: .fastraJumpToRange, object: workspace,
                                            userInfo: ["range": NSValue(range: range)])
        }
    }

    /// Führt eine Konfliktübernahme im sichtbaren nativen Editor aus. Der
    /// Workspace und die Tab-ID adressieren das konkrete Dokumentfenster;
    /// dadurch kann ein appweiter Notification-Pfad nie den falschen Editor
    /// eines zweiten Fensters verändern.
    func replaceConflictText(_ request: ConflictEditorReplacementRequest) {
        guard let workspace = request.workspace,
              workspace.activeTabID == request.tabID,
              let textView = activeEditorTextView(for: workspace) else {
            NSSound.beep()
            return
        }
        guard ConflictNativeTextMutation.apply(request, to: textView) else {
            NSSound.beep()
            return
        }
        textView.window?.makeFirstResponder(textView)
    }

    /// Wendet eine Text-Operation auf den AKTIVEN Editor an (Aufruf aus der
    /// Menüleiste über `.fastraTextOp`). Sucht die Editor-TextView im
    /// vorderen Hauptfenster (NICHT dem Such-Panel).
    func applyToActiveEditor(_ kind: TextOpKind) {
        guard let textView = activeEditorTextView() else { NSSound.beep(); return }
        apply(kind, on: textView)
    }

    /// „Einfügen und Einrückung angleichen" (Etappe 4; BBEdit „Paste and
    /// Match Indentation", ⌥⇧⌘V): fügt den Clipboard-Text so ein, dass er
    /// auf der Einrückung der Zielzeile sitzt; relative Verschachtelung
    /// bleibt erhalten, das Ergebnis nutzt Tabs/Leerzeichen des wirksamen
    /// Profils. Rechteck- und Mehrfachauswahl sind bewusst ausgenommen —
    /// niemals nur den ersten Bereich ändern (sichtbare Erklärung statt
    /// stiller Teilwirkung). Genau EINE Undo-Aktion.
    func pasteMatchingIndentationInActiveEditor() {
        MainActor.assumeIsolated {
            guard let target = CommandTargeting.target() else {
                NSSound.beep()
                return
            }
            let textView = target.textView
            guard textView.fastraColumnSelectionSnapshot == nil,
                  textView.selectionManager.textSelections.count <= 1 else {
                warnColumnSelectionUnsupported()
                return
            }
            guard let clipboard = NSPasteboard.general.string(forType: .string),
                  !clipboard.isEmpty else {
                NSSound.beep()
                return
            }
            let text = textView.string
            let selection = textView.fastraSafeSelectedRange
            let profile = target.workspace.activeIndentationProfile
            let lineEnding = target.workspace.activeTab?.lineEnding
                ?? LineEnding.detect(in: text)
            let context = IndentationMatchingPaste.targetContext(
                documentText: text,
                insertionLocation: selection.location,
                profile: profile
            )
            let matched = IndentationMatchingPaste.matchedText(
                clipboard: clipboard,
                targetColumns: context.columns,
                indentFirstLine: context.prefixIsWhitespaceOnly,
                lineEnding: lineEnding,
                profile: profile
            )
            // Bereits vorhandene Einrückung vor dem Cursor gehört zum
            // ersetzten Bereich: `matchedText` setzt die Zielspalte selbst vor
            // die erste Zeile. Bliebe der vorhandene Whitespace stehen,
            // addierten sich beide und der Block säße auf einer automatisch
            // eingerückten Leerzeile eine Ebene zu tief.
            let replaced = NSRange(
                location: context.replacementStart,
                length: selection.location - context.replacementStart
                    + selection.length)
            // Über denselben Undo-Pfad wie die Text-Operationen: EIN
            // widerrufbarer Edit durch CESEs Undo-Manager.
            textView.fastraApplyTextOperation(replacing: replaced, with: matched)
        }
    }

    /// Sichtbarer Paste-Column-Befehl. Der Editor selbst entscheidet, ob die
    /// linke Rechteckkante oder der primäre Cursor die Zielspalte festlegt.
    func pasteColumnInActiveEditor() {
        guard let textView = activeEditorTextView() else { NSSound.beep(); return }
        textView.fastraPasteColumn(nil)
    }

    /// Erweitert oder verkleinert ein Rechteck um genau eine logische Zeile.
    func selectColumnInActiveEditor(upwards: Bool) {
        guard let textView = activeEditorTextView(),
              textView.fastraSelectColumn(upwards: upwards) else {
            NSSound.beep()
            return
        }
    }

    /// Menüleisten-Pfad für die zwei eindeutigen Sortierrichtungen.
    func sortActiveDocument(_ direction: LineOperations.SortDirection) {
        guard let textView = activeEditorTextView() else { NSSound.beep(); return }
        applyLineOperation(on: textView) { text, selection in
            LineOperations.sortLines(in: text, selection: selection,
                                     direction: direction)
        }
    }

    /// Menüleisten-/Toolbar-Pfad der Markdown-Formatbefehle (Etappe 5
    /// Wunschpaket 2026-07b). Nur für Markdown-Tabs sinnvoll — die Menüs
    /// sind sonst deaktiviert, defensiv wird trotzdem geprüft.
    func applyMarkdownFormatToActiveEditor(_ command: MarkdownFormatCommand) {
        MainActor.assumeIsolated {
            // Workspace UND Editor in einem Zugriff aus demselben Fenster.
            // Vorher stammte die Markdown-Prüfung aus `Workspace.shared` und
            // der Editor aus einer eigenen Suche: Zeigte `shared` auf ein
            // anderes Fenster, blieb ⌘B wirkungslos (nur ein Beep) — oder es
            // wirkte im falschen Dokument (Fehlerbericht 2026-08-07).
            guard let target = CommandTargeting.target(),
                  MarkdownAssist.isMarkdownTabActive(in: target.workspace)
            else { NSSound.beep(); return }
            let textView = target.textView
            guard textView.fastraColumnSelectionSnapshot == nil else {
                warnColumnSelectionUnsupported()
                return
            }
            MarkdownAssist.applyFormat(command, on: textView,
                                       workspace: target.workspace)
        }
    }

    /// Rechtsklick-Handler des Markdown-Submenüs (Tag = Command-Rohwert).
    @objc private func runMarkdownFormat(_ sender: NSMenuItem) {
        guard let command = MarkdownFormatCommand(rawValue: sender.tag),
              let textView = targetTextView else { NSSound.beep(); return }
        MainActor.assumeIsolated {
            guard let workspace = CommandTargeting.workspace(for: textView),
                  MarkdownAssist.isMarkdownTabActive(in: workspace) else {
                NSSound.beep()
                return
            }
            guard textView.fastraColumnSelectionSnapshot == nil else {
                warnColumnSelectionUnsupported()
                return
            }
            MarkdownAssist.applyFormat(command, on: textView,
                                       workspace: workspace)
        }
    }

    /// Führt `kind` auf `textView` aus. Die Eingabe-Operationen (Präfix/Suffix,
    /// Process Lines Containing, Hard Wrap) holen vorher ihren Parameter über einen
    /// modalen Dialog; alle übrigen laufen direkt über `operation(for:)`.
    private func apply(_ kind: TextOpKind, on textView: TextView) {
        if textView.fastraColumnSelectionSnapshot != nil {
            guard kind.supportsColumnSelection else {
                warnColumnSelectionUnsupported()
                return
            }
            applyColumnOperation(kind, on: textView)
            return
        }

        switch kind {
        case .prefixLines, .suffixLines:
            let isPrefix = (kind == .prefixLines)
            guard let input = promptForText(
                title: L10n.string(isPrefix ? "Präfix an jede Zeile" : "Suffix an jede Zeile"),
                message: L10n.string(isPrefix
                    ? "Text, der an jeden Zeilenanfang angefügt wird:"
                    : "Text, der an jedes Zeilenende angefügt wird:")),
                !input.isEmpty else { return }
            applyLineOperation(on: textView) { text, selection in
                isPrefix
                    ? TextOperations.prefixLines(in: text, selection: selection, with: input)
                    : TextOperations.suffixLines(in: text, selection: selection, with: input)
            }

        case .keepLinesMatching, .deleteLinesMatching:
            // BBEdit „Process Lines Containing": ein RegEx-Muster filtert die Zeilen.
            let keep = (kind == .keepLinesMatching)
            guard let pattern = promptForText(
                title: L10n.string(keep ? "Nur Zeilen mit Treffer behalten" : "Zeilen mit Treffer löschen"),
                message: L10n.string(keep
                    ? "RegEx-Muster — nur Zeilen mit Treffer bleiben stehen (Groß-/Kleinschreibung egal):"
                    : "RegEx-Muster — Zeilen mit Treffer werden gelöscht (Groß-/Kleinschreibung egal):")),
                !pattern.isEmpty else { return }
            applyLineOperation(on: textView) { text, selection in
                LineFilter.filter(in: text, selection: selection, pattern: pattern, keepMatching: keep)
            }

        case .hardWrap:
            // BBEdit „Hard Wrap": Spaltenbreite abfragen (Default 72), dann umbrechen.
            guard let raw = promptForText(
                title: L10n.string("Zeilen hart umbrechen"),
                message: L10n.string("Maximale Zeilenbreite in Zeichen:"),
                defaultValue: "72") else { return }
            // Ungültige Eingabe (keine positive Zahl) → Beep, kein Umbruch.
            guard let column = Int(raw.trimmingCharacters(in: .whitespaces)), column > 0 else {
                NSSound.beep(); return
            }
            applyLineOperation(on: textView) { text, selection in
                TextOperations.hardWrap(in: text, selection: selection, column: column)
            }

        default:
            let op = operation(for: kind, profile: indentationProfile(for: textView))
            applyLineOperation(on: textView) { text, selection in op(text, selection) }
        }
    }

    /// Wirksames Einrückungsprofil für Operationen auf dieser TextView —
    /// aus dem Workspace ihres Fensters (Etappe 4). Ohne zuordenbares
    /// Fenster gilt der Werkstandard. Alle Aufrufer arbeiten auf einer
    /// AppKit-View, also auf dem Main-Thread.
    private func indentationProfile(for textView: TextView) -> IndentationProfile {
        MainActor.assumeIsolated {
            CommandTargeting.workspace(for: textView)?.activeIndentationProfile
                ?? .factory
        }
    }

    /// Mappt eine `TextOpKind` auf die zugehörige pure `TextOperations`-Funktion.
    /// Einrückungs-Operationen erhalten das wirksame Profil (Etappe 4).
    private func operation(for kind: TextOpKind,
                           profile: IndentationProfile = .factory)
        -> (String, NSRange) -> LineOperations.Result? {
        switch kind {
        case .uppercase:        return TextOperations.uppercase
        case .lowercase:        return TextOperations.lowercase
        case .titlecase:        return TextOperations.titlecase
        case .trimTrailing:     return TextOperations.trimTrailingWhitespace
        case .detab:            return { TextOperations.detab(in: $0, selection: $1, tabWidth: profile.tabWidth) }
        case .entab:            return { TextOperations.entab(in: $0, selection: $1, tabWidth: profile.tabWidth) }
        case .zapGremlins:      return TextOperations.zapGremlins
        case .straightenQuotes: return TextOperations.straightenQuotes
        case .educateQuotes:    return TextOperations.educateQuotes
        case .convertEscapeSequences: return TextOperations.convertEscapeSequences
        case .shiftRight:       return { TextOperations.shiftRight(in: $0, selection: $1, profile: profile) }
        case .shiftLeft:        return { TextOperations.shiftLeft(in: $0, selection: $1, profile: profile) }
        case .reverseLines:     return TextOperations.reverseLines
        case .removeBlankLines: return TextOperations.removeBlankLines
        // Beide Join-Varianten teilen sich die pure Funktion, nur der Trenner
        // unterscheidet sie (Leerzeichen für Fließtext, leer für Daten-Spalten).
        case .joinLines:        return { TextOperations.joinLines(in: $0, selection: $1, separator: " ") }
        case .joinLinesTight:   return { TextOperations.joinLines(in: $0, selection: $1, separator: "") }
        case .addLineNumbers:     return TextOperations.addLineNumbers
        case .removeLineNumbers:  return TextOperations.removeLineNumbers
        case .exchangeCharacters: return TextOperations.exchangeCharacters
        case .exchangeWords:      return TextOperations.exchangeWords
        // Process Duplicate Lines (BBEdit) — ohne Eingabe, direkt über LineOperations.
        case .keepDuplicateLines:       return LineOperations.keepDuplicateLines
        case .removeAllDuplicatedLines: return LineOperations.removeAllDuplicatedLines
        // Unicode-Gruppe (BBEdit Kap. 5): Zs-Leerzeichen → ASCII-Space,
        // Diakritika strippen, NFC-/NFD-Normalisierung.
        case .normalizeSpaces:   return TextOperations.normalizeSpaces
        case .stripDiacriticals: return TextOperations.stripDiacriticals
        case .precomposeUnicode: return TextOperations.precomposeUnicode
        case .decomposeUnicode:  return TextOperations.decomposeUnicode
        // Emoji-Präsentation: Variantenselektor U+FE0F ergänzen/entfernen.
        case .addEmojiPresentation:    return TextOperations.addEmojiPresentation
        case .removeEmojiPresentation: return TextOperations.removeEmojiPresentation
        // 4D-Export-Transformation (Etappe 6): token-basiert über den
        // FourDTokenizer — Strings/Kommentare bleiben unangetastet.
        case .fourDDetokenize:       return FourDTokenTransform.detokenizeOperation
        case .fourDTokenizeCommands: return FourDTokenTransform.tokenizeCommandsOperation
        // Eingabe-Operationen werden in apply() per Dialog abgefangen und erreichen
        // operation() nie — der nil-Pfad ist nur zur Vollständigkeit des switch.
        case .prefixLines, .suffixLines, .keepLinesMatching, .deleteLinesMatching, .hardWrap:
            return { _, _ in nil }
        }
    }

    /// Rechnet jede logische Rechteckzeile gegen denselben unveränderten
    /// Ausgangstext und ersetzt anschließend alle Teilbereiche gemeinsam.
    /// So bleiben unterschiedliche Ergebnislängen und ein einziges Undo
    /// möglich, ohne dass frühere Zeilen die Ranges späterer verschieben.
    private func applyColumnOperation(_ kind: TextOpKind, on textView: TextView) {
        guard kind.supportsColumnSelection,
              let snapshot = textView.fastraColumnSelectionSnapshot else {
            warnColumnSelectionUnsupported()
            return
        }
        let text = textView.string
        let nsText = text as NSString
        let transform = operation(for: kind, profile: indentationProfile(for: textView))
        var replacements: [String] = []
        replacements.reserveCapacity(snapshot.ranges.count)

        for range in snapshot.ranges {
            // Ein Nullbereich bezeichnet eine zu kurze oder leere logische
            // Zeile. Die normalen Zeichen-Operationen würden Länge 0 als
            // „keine Auswahl = ganzes Dokument" verstehen.
            if range.length == 0 {
                replacements.append("")
                continue
            }
            guard let result = transform(text, range) else {
                replacements.append(nsText.substring(with: range))
                continue
            }
            guard result.affectedRange == range,
                  let replacement = replacementBlock(
                    from: result,
                    replacing: range,
                    inOriginalLength: nsText.length
                  ),
                  !replacement.contains("\n"),
                  !replacement.contains("\r") else {
                warnColumnSelectionUnsupported()
                return
            }
            replacements.append(replacement)
        }

        guard textView.fastraReplaceColumnSelections(with: replacements) else {
            NSSound.beep()
            return
        }
    }

    /// Modaler Eingabe-Dialog mit einem Textfeld. Liefert den eingegebenen Text
    /// oder `nil`, wenn der Nutzer abbricht. `defaultValue` füllt das Feld vor
    /// (z.B. „72" für Hard Wrap). Genutzt von Präfix/Suffix, Process Lines
    /// Containing (RegEx-Muster) und Hard Wrap (Spaltenbreite).
    private func promptForText(title: String, message: String, defaultValue: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.string("Anwenden"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// Sucht die Editor-TextView im vorderen sichtbaren Hauptfenster (ohne das
    /// Such-Panel). Für Menüleisten-Aktionen, die kein Rechtsklick-Ziel haben.
    /// Editor des Fensters, das der Nutzer gerade bedient.
    ///
    /// Lief bis 2026-08-07 über `NSApp.windows` und nahm das erste sichtbare
    /// Fenster mit Editor. Diese Menge ist NICHT nach Vordergrund sortiert:
    /// Bei zwei offenen Dokumenten landete ⌘B im Hintergrundfenster, an der
    /// Cursorposition, die es dort zufällig gab. Die Zielwahl liegt jetzt
    /// vollständig in `CommandTargeting`.
    ///
    /// `assumeIsolated`: Diese Klasse ist nicht als `@MainActor` deklariert,
    /// läuft aber ausschließlich dort — Menü-Aktionen und die
    /// Notification-Beobachter des AppDelegate kommen alle auf dem
    /// Main-Thread an. Dasselbe Muster wie an den übrigen Stellen der Datei.
    private func activeEditorTextView() -> TextView? {
        MainActor.assumeIsolated { CommandTargeting.targetEditorTextView() }
    }

    private func activeEditorTextView(for workspace: Workspace) -> TextView? {
        MainActor.assumeIsolated { CommandTargeting.editorTextView(for: workspace) }
    }

    /// Workspace, zu dem DIESER Editor gehört (siehe `activeEditorTextView`
    /// zur Isolation). Wer Inhalt liest und Text schreibt, muss beides aus
    /// demselben Fenster nehmen.
    private func workspace(forEditor textView: TextView) -> Workspace? {
        MainActor.assumeIsolated { CommandTargeting.workspace(for: textView) }
    }

    @objc private func sortLines(_ sender: NSMenuItem) {
        guard let direction = LineOperations.SortDirection(rawValue: sender.tag) else {
            NSSound.beep()
            return
        }
        applyLineOperation { text, selection in
            LineOperations.sortLines(in: text, selection: selection,
                                     direction: direction)
        }
    }

    @objc private func removeDuplicates(_ sender: Any?) {
        applyLineOperation { text, selection in
            LineOperations.removeDuplicateLines(in: text, selection: selection)
        }
    }

    /// Gemeinsamer Pfad beider Zeilen-Operationen: Text + Selektion aus
    /// der TextView lesen, Operation rechnen, Ergebnis ÜBER DIE TEXTVIEW
    /// zurückschreiben. Wichtig: NICHT über das SwiftUI-Binding — CESE
    /// schiebt Binding-Änderungen nicht in die TextView zurück (bekannte
    /// Einschränkung, siehe Tab-Wechsel-Fix `.id(activeTab.id)`).
    /// `replaceCharacters` läuft durch CESEs Undo-Manager → CMD+Z geht.
    private func applyLineOperation(_ operation: (String, NSRange) -> LineOperations.Result?) {
        guard let textView = targetTextView else { NSSound.beep(); return }
        applyLineOperation(on: textView, operation)
    }

    /// Wie oben, aber auf eine explizit übergebene TextView (Menüleisten-Pfad).
    private func applyLineOperation(on textView: TextView,
                                    _ operation: (String, NSRange) -> LineOperations.Result?) {
        guard textView.fastraColumnSelectionSnapshot == nil else {
            warnColumnSelectionUnsupported()
            return
        }
        let text = textView.string
        let selection = textView.fastraSafeSelectedRange
        guard let result = operation(text, selection) else {
            // Nichts zu tun (eine Zeile / keine Duplikate) — kurzer Beep
            // als Feedback statt stiller Funkstille.
            NSSound.beep()
            return
        }
        // LineOperations liefert den KOMPLETTEN neuen Text + den ersetzten
        // Bereich (im alten Text). Für replaceCharacters brauchen wir nur
        // den neuen Block: Länge = neuer Gesamttext − (alter Gesamttext −
        // alter Block).
        // codereview-ok: Formel ist per Konstruktionsinvariante korrekt —
        // LineOperations baut newText immer via replacingCharacters.
        guard let newBlock = replacementBlock(
            from: result,
            replacing: result.affectedRange,
            inOriginalLength: (text as NSString).length
        ) else {
            NSSound.beep()
            return
        }
        textView.fastraApplyTextOperation(
            replacing: result.affectedRange,
            with: newBlock
        )
    }

    private func replacementBlock(
        from result: LineOperations.Result,
        replacing range: NSRange,
        inOriginalLength oldLength: Int
    ) -> String? {
        let newNS = result.newText as NSString
        let blockLength = newNS.length - (oldLength - range.length)
        guard blockLength >= 0,
              range.location <= newNS.length,
              range.location + blockLength <= newNS.length else {
            return nil
        }
        return newNS.substring(
            with: NSRange(location: range.location, length: blockLength)
        )
    }
}
