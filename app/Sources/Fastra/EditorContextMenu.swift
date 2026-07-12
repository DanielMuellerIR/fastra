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
}

/// Installiert den Rechtsklick-Monitor und führt die Menü-Aktionen aus.
/// Eine Instanz lebt im AppDelegate (stark referenziert), der Monitor
/// selbst hält sie über die Action-Targets am Leben.
final class EditorContextMenu: NSObject {

    /// Die TextView unter dem letzten Rechtsklick — Ziel aller Aktionen.
    /// `weak`, damit ein geschlossener Editor nicht festgehalten wird.
    private weak var targetTextView: TextView?

    private var monitor: Any?

    /// Lokalen Monitor installieren. Idempotent (mehrfacher Aufruf ok).
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
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
        let hasSelection = textView.selectedRange().length > 0

        let cut = NSMenuItem(title: L10n.string("Ausschneiden"), action: #selector(NSText.cut(_:)), keyEquivalent: "")
        cut.target = textView
        cut.isEnabled = hasSelection
        let copy = NSMenuItem(title: L10n.string("Kopieren"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copy.target = textView
        copy.isEnabled = hasSelection
        let paste = NSMenuItem(title: L10n.string("Einfügen"), action: #selector(NSText.paste(_:)), keyEquivalent: "")
        paste.target = textView

        let smartPaste = NSMenuItem(title: L10n.string("Formatiert als Markdown einfügen"),
                                    action: #selector(performSmartPaste(_:)),
                                    keyEquivalent: "")
        smartPaste.target = self
        smartPaste.toolTip = L10n.string("Formatierten Inhalt aus der Zwischenablage (z.B. aus dem Browser) als sauberes Markdown einfügen.")

        let sort = NSMenuItem(title: L10n.string("Zeilen sortieren"),
                              action: #selector(sortLines(_:)),
                              keyEquivalent: "")
        sort.target = self
        sort.toolTip = L10n.string("Sortiert die selektierten Zeilen alphabetisch — sind sie schon sortiert, wird die Reihenfolge umgedreht. Ohne Auswahl: die ganze Datei.")

        let dedupe = NSMenuItem(title: L10n.string("Duplikate entfernen"),
                                action: #selector(removeDuplicates(_:)),
                                keyEquivalent: "")
        dedupe.target = self
        dedupe.toolTip = L10n.string("Entfernt doppelte Zeilen — das erste Vorkommen bleibt stehen. Ohne Auswahl: die ganze Datei.")

        // „Text"-Submenü mit den BBEdit-Basics (TextOperations). Tag trägt die
        // TextOpKind; ein gemeinsamer Handler liest ihn. Gruppen durch Trenner.
        let textItem = NSMenuItem(title: L10n.string("Text"), action: nil, keyEquivalent: "")
        let textSub = NSMenu()
        let groupBreaksAfter: Set<TextOpKind> = [.titlecase, .entab, .convertEscapeSequences, .shiftLeft, .joinLinesTight, .removeLineNumbers, .exchangeWords, .removeAllDuplicatedLines, .hardWrap]
        for kind in TextOpKind.allCases {
            let item = NSMenuItem(title: kind.title,
                                  action: #selector(runTextOp(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = kind.rawValue
            textSub.addItem(item)
            if groupBreaksAfter.contains(kind) { textSub.addItem(.separator()) }
        }
        textItem.submenu = textSub

        menu.items = [
            cut, copy, paste,
            .separator(),
            smartPaste,
            .separator(),
            sort, dedupe,
            .separator(),
            textItem,
        ]
        // Wir steuern isEnabled selbst (statt Responder-Chain-Validierung).
        menu.autoenablesItems = false
        return menu
    }

    // MARK: - Aktionen

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

    /// Wendet eine Text-Operation auf den AKTIVEN Editor an (Aufruf aus der
    /// Menüleiste über `.fastraTextOp`). Sucht die Editor-TextView im
    /// vorderen Hauptfenster (NICHT dem Such-Panel).
    func applyToActiveEditor(_ kind: TextOpKind) {
        guard let textView = activeEditorTextView() else { NSSound.beep(); return }
        apply(kind, on: textView)
    }

    /// Führt `kind` auf `textView` aus. Die Eingabe-Operationen (Präfix/Suffix,
    /// Process Lines Containing, Hard Wrap) holen vorher ihren Parameter über einen
    /// modalen Dialog; alle übrigen laufen direkt über `operation(for:)`.
    private func apply(_ kind: TextOpKind, on textView: TextView) {
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
        // Eingabe-Operationen werden in apply() per Dialog abgefangen und erreichen
        // operation() nie — der nil-Pfad ist nur zur Vollständigkeit des switch.
        case .prefixLines, .suffixLines, .keepLinesMatching, .deleteLinesMatching, .hardWrap:
            return { _, _ in nil }
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
            if window.frameAutosaveName == SearchWindow.frameAutosaveName { continue }
            if let content = window.contentView, let tv = descendantTextView(in: content) {
                return tv
            }
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
        let oldLength = (text as NSString).length
        let newNS = result.newText as NSString
        // codereview-ok: Formel ist per Konstruktionsinvariante korrekt — LineOperations baut newText immer via replacingCharacters(in: affectedRange, …), affectedRange ist also exakt der ersetzte Bereich (2026-07-06)
        let newBlockLength = newNS.length - (oldLength - result.affectedRange.length)
        let newBlock = newNS.substring(with: NSRange(location: result.affectedRange.location,
                                                     length: max(0, newBlockLength)))
        textView.replaceCharacters(in: result.affectedRange, with: newBlock)
    }
}
