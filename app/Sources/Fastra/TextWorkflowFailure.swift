import Foundation

enum TextWorkflowFailure {
    static let stale = L10n.string("Die Eingaben haben sich seit der Vorschau geändert. Berechne die Vorschau erneut; es wurde nichts angewendet.")
    static let busy = L10n.string("Eine andere Dateioperation ist noch aktiv. Warte auf ihren Abschluss und berechne die Vorschau erneut.")
    static let workspaceChanged = L10n.string("Offene Dokumente oder ihre Zustände haben sich während der Prüfung geändert. Prüfe sie und wiederhole die Aktion.")
    static func message(_ error: Error) -> String {
        if let failure = error as? TextWorkflowFilePlan.Failure {
            switch failure {
            case .empty: return L10n.string("Der Bereich enthält keine passenden Eingaben. Prüfe Ordner, Datei-Set und Filter.")
            case .noChanges: return L10n.string("Keine wirksame Änderung")
            case .sizeLimit: return L10n.string("Die Vorschau ist unvollständig: höchstens 500 Eingaben, je 64 MiB Original-, Ausgabe- und Vorschautext sowie 4 MiB Text pro Eingabe. Verfeinere den Bereich.")
            case .cancelled: return L10n.string("Die Berechnung wurde abgebrochen.")
            case .timeout: return L10n.string("Die gemeinsame Vorschau überschreitet 60 Sekunden. Verfeinere den Bereich.")
            case .duplicateInput: return L10n.string("Mehrere Eingaben bezeichnen dieselbe Datei (Alias oder Hardlink). Entferne die doppelte Eingabe.")
            case .unreadable: return L10n.string("Die Datei ist nicht vollständig lesbar oder hat sich beim Lesen geändert.")
            case .readOnly: return L10n.string("Die Datei oder ihr Ordner ist schreibgeschützt.")
            case .binary: return L10n.string("Die Datei enthält Binärdaten und kann nicht als Textablauf verarbeitet werden.")
            case .encodingConflict: return L10n.string("Die gewählte Kodierung widerspricht der Byte-Reihenfolgemarkierung (BOM).")
            case .unsupportedEncoding: return L10n.string("Diese Kodierung wird für Textabläufe nicht unterstützt.")
            case .undecodable: return L10n.string("Die Datei lässt sich nicht verlustfrei dekodieren und zurückkodieren.")
            case .unrepresentable: return L10n.string("Das Ergebnis enthält Zeichen, die sich in der ursprünglichen Kodierung nicht verlustfrei speichern lassen.")
            case .processing(_, let cause): return TextWorkflowSession.message(cause)
            }
        }
        if let failure = error as? TextWorkflowOpenDocumentsPlan.Failure {
            switch failure {
            case .empty: return message(TextWorkflowFilePlan.Failure.empty)
            case .stale: return stale
            case .noChanges: return message(TextWorkflowFilePlan.Failure.noChanges)
            case .sizeLimit: return message(TextWorkflowFilePlan.Failure.sizeLimit)
            case .cancelled: return message(TextWorkflowFilePlan.Failure.cancelled)
            case .timeout: return message(TextWorkflowFilePlan.Failure.timeout)
            case .processing(_, let cause): return TextWorkflowSession.message(cause)
            }
        }
        if let failure = error as? RipgrepFileEnumerator.Failure {
            switch failure {
            case .cancelled: return message(TextWorkflowFilePlan.Failure.cancelled)
            case .timedOut: return L10n.string("Die Dateiliste konnte nicht rechtzeitig vollständig gelesen werden.")
            case .outputLimit: return L10n.string("Die Dateiliste ist zu groß. Verfeinere den Bereich; es wurde nichts angewendet.")
            case .unavailable: return L10n.string("Das gebündelte Werkzeug für die Dateiliste ist nicht verfügbar. Es wurde nichts angewendet.")
            case .failed(let detail), .captureFailed(let detail):
                return L10n.format("Die Dateiliste konnte nicht vollständig gelesen werden: %@", detail)
            }
        }
        if let failure = error as? ApplyError {
            switch failure {
            case .cancelled: return message(TextWorkflowFilePlan.Failure.cancelled)
            case .planNotApplyable(let detail), .conflict(let detail), .backupFailed(let detail),
                 .undoConflict(let detail), .legacySession(let detail): return detail
            case .writeFailed(let partial, let detail):
                if partial.entries.isEmpty { return L10n.format("%@\nEs wurden keine Dateien geschrieben.", detail) }
                return L10n.format("%@\nBereits geschriebene Dateien bilden eine geschützte Teilsitzung. Nutze „Plattenänderungen zurücknehmen“.", detail)
            case .undoFailed(_, let detail): return L10n.format("%@\nDie Rücknahme ist teilweise erfolgt. Die geschützte Rücknahme kann fortgesetzt werden.", detail)
            }
        }
        if error is CancellationError { return message(TextWorkflowFilePlan.Failure.cancelled) }
        return TextWorkflowSession.message(error)
    }
}
