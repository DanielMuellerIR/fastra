// PrintPanelAccessory.swift
//
// Zubehörfeld im System-Druckdialog: Kopf-/Fußzeile und Zeilennummern lassen
// sich direkt im Dialog umschalten (beauftragt 2026-08-18 nach der manuellen
// Druckabnahme). Eine Änderung wirkt dreifach:
//   1. Sie steht sofort im `NSPrintInfo`-Dictionary des laufenden Auftrags —
//      `PrintDocumentTextView` liest seine Optionen bei JEDER Seitenaufteilung
//      frisch von dort (siehe `resolvedPrintOptions`), die Dialog-Vorschau
//      paginiert also live neu.
//   2. Sie wird in den Einstellungen gespeichert (`PrintPreferences`) — Dialog
//      und Einstellungsfenster bleiben dieselbe eine Quelle, der nächste
//      Ausdruck startet mit der zuletzt getroffenen Wahl.
//   3. Die Vorschau des Systemdialogs beobachtet die unten deklarierten
//      Preview-Schlüsselpfade und zeichnet nach jedem Umschalten neu.
//
// Die Seitenränder bleiben während eines laufenden Auftrags bewusst fest auf
// dem Stand beim Öffnen des Dialogs: Ein Umschalten der Kopf-/Fußzeile
// verschiebt also keine Ränder mitten in der Vorschau. Die Eckangaben passen
// auch in den Mindestrand von 40 Punkt — eingeschaltet ohne reservierten
// Zusatzrand stehen sie nur etwas dichter am Text.

import AppKit

/// Schlüssel für die Dialog-Optionen im `NSPrintInfo`-Dictionary des
/// laufenden Auftrags. Werte sind `Bool` (als `NSNumber`).
enum PrintDialogOption {
    static let headerFooter = NSPrintInfo.AttributeKey(rawValue: "FastraPrintHeaderFooter")
    static let lineNumbers = NSPrintInfo.AttributeKey(rawValue: "FastraPrintLineNumbers")

    /// Liest eine Bool-Option aus einem PrintInfo; `nil`, wenn nie gesetzt.
    static func value(_ key: NSPrintInfo.AttributeKey,
                      in printInfo: NSPrintInfo?) -> Bool? {
        guard let printInfo else { return nil }
        return printInfo.dictionary()[key] as? Bool
    }
}

/// Das Zubehörfeld selbst. `NSPrintPanelAccessorizing` verlangt die
/// Zusammenfassungs-Einträge; die Preview-Schlüsselpfade sorgen dafür, dass
/// die Dialog-Vorschau nach jedem Umschalten neu aufgebaut wird.
final class PrintOptionsAccessoryController: NSViewController, NSPrintPanelAccessorizing {
    private let printInfo: NSPrintInfo
    private let defaults: UserDefaults
    /// Bild- und Hex-Ausdruck haben keine Zeilennummern-Option; die Checkbox
    /// entfällt dort ganz, statt wirkungslos anwählbar zu sein.
    private let offersLineNumbers: Bool

    /// KVO-fähig für die Vorschau-Beobachtung des Druckdialogs.
    @objc dynamic private(set) var headerFooterEnabled: Bool
    @objc dynamic private(set) var lineNumbersEnabled: Bool

    init(printInfo: NSPrintInfo, defaults: UserDefaults, offersLineNumbers: Bool) {
        self.printInfo = printInfo
        self.defaults = defaults
        self.offersLineNumbers = offersLineNumbers
        self.headerFooterEnabled =
            PrintDialogOption.value(PrintDialogOption.headerFooter, in: printInfo)
            ?? PrintPreferences.showsHeaderFooter(defaults)
        self.lineNumbersEnabled =
            PrintDialogOption.value(PrintDialogOption.lineNumbers, in: printInfo)
            ?? PrintPreferences.showsLineNumbers(defaults)
        super.init(nibName: nil, bundle: nil)
        // Eigenname, bewusst unübersetzt: beschriftet den Options-Abschnitt
        // im Druckdialog.
        title = "Fastra"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("nicht unterstützt") }

    override func loadView() {
        let headerFooterButton = NSButton(
            checkboxWithTitle: L10n.string("Kopf- und Fußzeile drucken"),
            target: self, action: #selector(toggleHeaderFooter(_:))
        )
        headerFooterButton.state = headerFooterEnabled ? .on : .off
        var buttons: [NSView] = [headerFooterButton]
        if offersLineNumbers {
            let lineNumbersButton = NSButton(
                checkboxWithTitle: L10n.string("Zeilennummern drucken"),
                target: self, action: #selector(toggleLineNumbers(_:))
            )
            lineNumbersButton.state = lineNumbersEnabled ? .on : .off
            buttons.append(lineNumbersButton)
        }
        let stack = NSStackView(views: buttons)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
        view = stack
    }

    @objc private func toggleHeaderFooter(_ sender: NSButton) {
        setHeaderFooter(sender.state == .on)
    }

    @objc private func toggleLineNumbers(_ sender: NSButton) {
        setLineNumbers(sender.state == .on)
    }

    /// Auch für Tests direkt aufrufbar — gleiche Wirkung wie der Klick.
    func setHeaderFooter(_ enabled: Bool) {
        headerFooterEnabled = enabled
        printInfo.dictionary()[PrintDialogOption.headerFooter] = enabled
        defaults.set(enabled, forKey: PrintPreferences.Keys.headerFooter)
    }

    func setLineNumbers(_ enabled: Bool) {
        lineNumbersEnabled = enabled
        printInfo.dictionary()[PrintDialogOption.lineNumbers] = enabled
        defaults.set(enabled, forKey: PrintPreferences.Keys.lineNumbers)
    }

    // MARK: - NSPrintPanelAccessorizing

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        var items: [[NSPrintPanel.AccessorySummaryKey: String]] = [[
            .itemName: L10n.string("Kopf- und Fußzeile drucken"),
            .itemDescription: headerFooterEnabled
                ? L10n.string("Ein") : L10n.string("Aus"),
        ]]
        if offersLineNumbers {
            items.append([
                .itemName: L10n.string("Zeilennummern drucken"),
                .itemDescription: lineNumbersEnabled
                    ? L10n.string("Ein") : L10n.string("Aus"),
            ])
        }
        return items
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> {
        ["headerFooterEnabled", "lineNumbersEnabled"]
    }
}
