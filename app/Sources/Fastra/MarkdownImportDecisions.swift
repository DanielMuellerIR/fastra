import AppKit
import Foundation

/// Datei- und Paketentscheidungen eines Workspace, einschließlich ihrer Dialoge.
/// Konstruktion ist fensterlos; Aufrufe erfolgen im Main-Vertrag des Workspace.
final class MarkdownImportDecisions {
    enum FileChoice {
        case convert
        case openAsText
        case cancel
    }

    /// Optionaler Ersatz der Dateientscheidung; nil verwendet den nativen Dialog.
    var fileChoiceProvider:
        ((URL, MarkdownImportFormat) -> FileChoice)?

    func askFileChoice(
        for url: URL,
        format: MarkdownImportFormat
    ) -> FileChoice {
        if let provider = fileChoiceProvider {
            return provider(url, format)
        }
        let alert = NSAlert()
        alert.messageText = L10n.format("„%@“ ist ein %@-Dokument.",
                                        url.lastPathComponent, format.identifier.uppercased())
        guard format.isAvailable else {
            alert.informativeText = [
                L10n.format(
                    "Fastra könnte das %@-Dokument in Markdown umwandeln, doch dafür fehlt gerade etwas.",
                    format.identifier.uppercased()
                ),
                Workspace.markdownImportUnavailableExplanation(for: format),
            ].compactMap { $0 }.joined(separator: "\n\n")
            alert.addButton(withTitle: L10n.string("Als Quelltext öffnen"))
            alert.addButton(withTitle: L10n.string("Abbrechen"))
            return alert.runModal() == .alertFirstButtonReturn ? .openAsText : .cancel
        }
        alert.informativeText = L10n.format(
            "Fastra kann das %@-Dokument in Markdown umwandeln und danach öffnen. Das Original bleibt unverändert.",
            format.identifier.uppercased()
        )
        addConversionButton(to: alert)
        alert.addButton(withTitle: L10n.string("Als Quelltext öffnen"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .convert
        case .alertSecondButtonReturn: return .openAsText
        default: return .cancel
        }
    }

    /// Wie ein Dokumentpaket geöffnet werden soll.
    enum PackageChoice {
        case convert
        case openAsFolder
        case cancel
    }

    /// Optionaler Ersatz der Paketentscheidung; nil verwendet den nativen Dialog.
    var packageChoiceProvider:
        ((URL, MarkdownImportFormat) -> PackageChoice)?

    /// Ein Dokumentpaket sieht im Finder aus wie ein Ordner. Fastra kann es
    /// nicht gleichzeitig als Ordner zeigen und umwandeln, deshalb ist hier —
    /// anders als bei einer Datei — eine echte Rückfrage nötig.
    ///
    /// Die Frage selbst kennt keinen Aufrufer-Kontext: Was „als Ordner öffnen"
    /// bedeutet, entscheidet die aufrufende Stelle (Projekt laden bzw. im
    /// Dateibaum aufklappen).
    func askPackageChoice(
        for url: URL,
        format: MarkdownImportFormat
    ) -> PackageChoice {
        if let provider = packageChoiceProvider {
            return provider(url, format)
        }
        let alert = NSAlert()
        alert.messageText = L10n.format("„%@“ ist ein Dokument, kein Projektordner.",
                                        url.lastPathComponent)
        // Bei fehlendem Zusatzwerkzeug erklärt der Dialog Voraussetzung und
        // Installation, statt einen nicht ausführbaren Umwandeln-Knopf anzubieten.
        guard format.isAvailable else {
            alert.informativeText = [
                L10n.format(
                    "Fastra könnte das %@-Dokument in Markdown umwandeln, doch dafür fehlt gerade etwas.",
                    format.identifier.uppercased()
                ),
                Workspace.markdownImportUnavailableExplanation(for: format),
            ].compactMap { $0 }.joined(separator: "\n\n")
            alert.addButton(withTitle: L10n.string("Als Ordner öffnen"))
            alert.addButton(withTitle: L10n.string("Abbrechen"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .openAsFolder
            default:                      return .cancel
            }
        }
        // Bewusst ein Literal: Ein per `+` zusammengesetzter Text wäre kein
        // statisch erkennbarer Lokalisierungsschlüssel mehr.
        alert.informativeText = L10n.format(
            "Fastra kann das %@-Dokument in Markdown umwandeln und danach öffnen. Das Original bleibt unverändert.",
            format.identifier.uppercased()
        )
        addConversionButton(to: alert)
        alert.addButton(withTitle: L10n.string("Als Ordner öffnen"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .convert
        case .alertSecondButtonReturn: return .openAsFolder
        default:                       return .cancel
        }
    }


    private func addConversionButton(to alert: NSAlert) {
        let button = alert.addButton(withTitle: L10n.string("In Markdown umwandeln"))
        if MarkdownImportService.shared.isRunning {
            button.isEnabled = false
            alert.informativeText += "\n\n" + L10n.string("Eine andere Umwandlung läuft bereits.")
        }
    }
}
