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
                              action: #selector(sortLines(_:)),
                              keyEquivalent: "")
        sort.target = self
        sort.toolTip = L10n.string("Sortiert die selektierten Zeilen alphabetisch — sind sie schon sortiert, wird die Reihenfolge umgedreht. Ohne Auswahl: die ganze Datei.")
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
        let filename = Workspace.shared?.activeTab?.url?.pathExtension
            ?? (Workspace.shared?.activeTab?.title as NSString?)?.pathExtension
        format.isEnabled = !hasColumnSelection
            && DocumentFormatter.supports(fileExtension: filename)

        // Prüfen und Minifizieren spiegeln „Text → Dokument prüfen/
        // minifizieren“ aus der Menüleiste. Der Linter deckt mehr Endungen ab
        // als der Formatter (4D-Container, svg), deshalb je eigene Prüfung.
        let lint = NSMenuItem(title: L10n.string("Dokument prüfen"),
                              action: #selector(lintDocument(_:)),
                              keyEquivalent: "")
        lint.target = self
        lint.toolTip = L10n.string("Prüft JSON oder XML auf Syntaxfehler und nennt Zeile und Spalte.")
        lint.isEnabled = DocumentLinter.supports(fileExtension: filename)

        let minify = NSMenuItem(title: L10n.string("Dokument minifizieren"),
                                action: #selector(minifyDocument(_:)),
                                keyEquivalent: "")
        minify.target = self
        minify.toolTip = L10n.string("Schreibt JSON oder XML kompakt ohne überflüssigen Leerraum. Eine Auswahl wird einzeln minifiziert.")
        minify.isEnabled = !hasColumnSelection
            && DocumentFormatter.supports(fileExtension: filename)

        // „Text"-Submenü mit den BBEdit-Basics (TextOperations). Tag trägt die
        // TextOpKind; ein gemeinsamer Handler liest ihn. Gruppen durch Trenner.
        let textItem = NSMenuItem(title: L10n.string("Text"), action: nil, keyEquivalent: "")
        let textSub = NSMenu()
        let groupBreaksAfter: Set<TextOpKind> = [.titlecase, .entab, .convertEscapeSequences, .shiftLeft, .joinLinesTight, .removeLineNumbers, .exchangeWords, .removeAllDuplicatedLines, .hardWrap, .decomposeUnicode]
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
        if MainActor.assumeIsolated({ MarkdownAssist.isMarkdownTabActive(in: Workspace.shared) }) {
            let markdownItem = NSMenuItem(title: "Markdown", action: nil, keyEquivalent: "")
            let markdownSub = NSMenu()
            let breaksAfter: Set<MarkdownFormatCommand> = [.code, .plainParagraph, .quote, .link]
            for command in MarkdownFormatCommand.allCases {
                let item = NSMenuItem(title: command.menuTitle,
                                      action: #selector(runMarkdownFormat(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.tag = command.rawValue
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
        guard let workspace = Workspace.shared else { NSSound.beep(); return }
        // performSmartPaste blockiert synchron (md-clip-Prozess, bis 10 s
        // Timeout) — deshalb NICHT auf dem Main-Thread starten. UI-Arbeit
        // (Alert, Einfügen) dispatcht die Funktion intern selbst zurück.
        DispatchQueue.global(qos: .userInitiated).async {
            SmartPaste.performSmartPaste(into: workspace)
        }
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
        guard let tab = Workspace.shared?.activeTab else { NSSound.beep(); return }
        let fileExtension = tab.url?.pathExtension ?? (tab.title as NSString).pathExtension
        do {
            guard let result = try DocumentFormatter.format(in: textView.string,
                                                            selection: textView.selectedRange(),
                                                            fileExtension: fileExtension) else {
                NSSound.beep()
                return
            }
            textView.replaceCharacters(in: result.affectedRange, with: result.replacement)
        } catch {
            NSAlert.runWarning(title: L10n.string("Formatieren fehlgeschlagen"),
                               text: error.localizedDescription)
        }
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

    private func minify(on textView: TextView) {
        guard textView.fastraColumnSelectionSnapshot == nil else {
            warnColumnSelectionUnsupported()
            return
        }
        guard let tab = Workspace.shared?.activeTab else { NSSound.beep(); return }
        let fileExtension = tab.url?.pathExtension
            ?? (tab.title as NSString).pathExtension
        do {
            guard let result = try DocumentFormatter.minify(
                in: textView.string,
                selection: textView.selectedRange(),
                fileExtension: fileExtension
            ) else {
                NSSound.beep()   // bereits minimal → No-op
                return
            }
            textView.replaceCharacters(in: result.affectedRange,
                                       with: result.replacement)
        } catch {
            NSAlert.runWarning(title: L10n.string("Minifizieren fehlgeschlagen"),
                               text: error.localizedDescription)
        }
    }

    /// „Text → Dokument prüfen“ (Etappe 6): validiert JSON/XML nativ und
    /// nennt bei Fehlern Zeile/Spalte; ein Klick springt zur Fehlerstelle.
    func lintActiveDocument() {
        guard let textView = activeEditorTextView() else { NSSound.beep(); return }
        lint(on: textView)
    }

    private func lint(on textView: TextView) {
        guard let workspace = Workspace.shared,
              let tab = workspace.activeTab else {
            NSSound.beep()
            return
        }
        let fileExtension = tab.url?.pathExtension
            ?? (tab.title as NSString).pathExtension
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
                if let finding, projectExists {
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
            guard let self, self.tool4DValidation === validation,
                  let workspace, workspace.activeTabID == tabID else { return }
            self.tool4DValidation = nil
            self.tool4DWorkspace = nil
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

    /// Menüleisten-/Toolbar-Pfad der Markdown-Formatbefehle (Etappe 5
    /// Wunschpaket 2026-07b). Nur für Markdown-Tabs sinnvoll — die Menüs
    /// sind sonst deaktiviert, defensiv wird trotzdem geprüft.
    func applyMarkdownFormatToActiveEditor(_ command: MarkdownFormatCommand) {
        MainActor.assumeIsolated {
            guard MarkdownAssist.isMarkdownTabActive(in: Workspace.shared),
                  let textView = activeEditorTextView() else { NSSound.beep(); return }
            guard textView.fastraColumnSelectionSnapshot == nil else {
                warnColumnSelectionUnsupported()
                return
            }
            MarkdownAssist.applyFormat(command, on: textView)
        }
    }

    /// Rechtsklick-Handler des Markdown-Submenüs (Tag = Command-Rohwert).
    @objc private func runMarkdownFormat(_ sender: NSMenuItem) {
        guard let command = MarkdownFormatCommand(rawValue: sender.tag),
              let textView = targetTextView else { NSSound.beep(); return }
        MainActor.assumeIsolated {
            guard textView.fastraColumnSelectionSnapshot == nil else {
                warnColumnSelectionUnsupported()
                return
            }
            MarkdownAssist.applyFormat(command, on: textView)
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
            let op = operation(for: kind)
            applyLineOperation(on: textView) { text, selection in op(text, selection) }
        }
    }

    /// Mappt eine `TextOpKind` auf die zugehörige pure `TextOperations`-Funktion.
    private func operation(for kind: TextOpKind) -> (String, NSRange) -> LineOperations.Result? {
        switch kind {
        case .uppercase:        return TextOperations.uppercase
        case .lowercase:        return TextOperations.lowercase
        case .titlecase:        return TextOperations.titlecase
        case .trimTrailing:     return TextOperations.trimTrailingWhitespace
        case .detab:            return TextOperations.detab
        case .entab:            return TextOperations.entab
        case .zapGremlins:      return TextOperations.zapGremlins
        case .straightenQuotes: return TextOperations.straightenQuotes
        case .educateQuotes:    return TextOperations.educateQuotes
        case .convertEscapeSequences: return TextOperations.convertEscapeSequences
        case .shiftRight:       return TextOperations.shiftRight
        case .shiftLeft:        return TextOperations.shiftLeft
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
        let transform = operation(for: kind)
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
    private func activeEditorTextView() -> TextView? {
        for window in NSApp.windows where window.isVisible {
            if SearchWindow.isSearchWindow(window) { continue }
            if let content = window.contentView, let tv = descendantTextView(in: content) {
                return tv
            }
        }
        return nil
    }

    private func activeEditorTextView(for workspace: Workspace) -> TextView? {
        let prioritized = NSApp.windows.sorted { lhs, rhs in
            (lhs.isKeyWindow ? 1 : 0) > (rhs.isKeyWindow ? 1 : 0)
        }
        for window in prioritized where window.isVisible {
            guard !SearchWindow.isSearchWindow(window),
                  WorkspaceWindowRegistry.workspace(for: window) === workspace,
                  let content = window.contentView else { continue }
            if let textView = descendantTextView(in: content) { return textView }
        }
        return nil
    }

    private func descendantTextView(in view: NSView) -> TextView? {
        if let tv = view as? TextView { return tv }
        for sub in view.subviews {
            if let tv = descendantTextView(in: sub) { return tv }
        }
        return nil
    }

    @objc private func sortLines(_ sender: Any?) {
        applyLineOperation { text, selection in
            LineOperations.sortLines(in: text, selection: selection)
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
        let selection = textView.selectedRange()
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
        textView.replaceCharacters(in: result.affectedRange, with: newBlock)
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
