import Foundation

enum ApplyRecoveryFailure {
    private struct Rejection: LocalizedError {
        let errorDescription: String?
    }

    /// Der Undo-Kern sichert Callbackfehler als Text. Vor dieser Grenze muss
    /// deshalb auch ein fachlicher Enum-Fehler bereits Nutzersprache besitzen.
    static func checked(_ action: () throws -> Void) throws {
        do { try action() }
        catch { throw Rejection(errorDescription: message(error)) }
    }

    static var stale: String { L10n.string("Die Sitzung, der Suchbereich oder die Vorschau hat sich geändert. Prüfe die Sitzung erneut; die alte Freigabe gilt nicht mehr.") }

    static func message(_ error: Error) -> String {
        if let failure = error as? ApplyRecoverySessionReader.Failure {
            switch failure {
            case .missing: return L10n.string("Eine benötigte Sicherung oder ein Teil der Sitzungsablage fehlt. Die Wiederherstellung wurde nicht freigegeben.")
            case .changed: return stale
            case .invalid(_, let reason):
                switch reason {
                case .backupContent: return L10n.string("Der Inhalt einer Sicherung stimmt nicht mit dem gespeicherten Original überein.")
                case .owner, .writableByOthers, .extendedACL: return L10n.string("Die Sitzungsablage ist nicht ausreichend gegen Änderungen durch andere Benutzer geschützt.")
                case .sessionReference, .backupReference, .targetReference, .cleanupReference:
                    return L10n.string("Die gespeicherten Pfade lassen sich dieser Sitzung nicht sicher zuordnen.")
                default: return L10n.string("Die Sitzung enthält ungültige oder nicht sicher gebundene Dateien. Bewahre die Sicherungen zur Klärung auf.")
                }
            case .unsupported(let reason):
                switch reason {
                case .manifestLimit, .entryLimit, .backupLimit: return limit
                case .emptySession: return L10n.string("Diese Sitzung enthält keine Wiederherstellungsarbeit.")
                default: return L10n.string("Diese ältere Sitzung besitzt keine vollständig prüfbare Wiederherstellungsbasis und kann nicht automatisch angewendet werden.")
                }
            case .system(_, let code): return system(code)
            }
        }
        if let failure = error as? ApplyRecoveryPreview.Failure {
            switch failure {
            case .limit: return limit
            case .changed, .wrongClaim: return stale
            case .outsideSelectedRoots(let url): return L10n.format("Die vollständige Sitzung liegt nicht innerhalb der gewählten Quellen. Ergänze im Ordnerbereich alle zugehörigen Wurzeln und öffne die Wiederherstellung erneut.\n%@", url.path)
            case .targetConflict(let url): return L10n.format("Die Datei entspricht nicht mehr dem bestätigten Stand nach der Änderung oder ist schreibgeschützt.\n%@", url.path)
            case .cleanupConflict(let url): return L10n.format("Diese Aufräumressource lässt sich nicht unverändert der Sitzung zuordnen. Sie bleibt erhalten.\n%@", url.path)
            case .duplicateTarget(let url): return L10n.format("Mehrere Einträge bezeichnen dieselbe Zieldatei. Die vollständige Sitzung wird abgewiesen.\n%@", url.path)
            case .undecodable(let url): return L10n.format("Für diese Datei lässt sich keine vollständige Textvorschau darstellen.\n%@", url.path)
            case .incompleteDiff, .noDifference: return L10n.string("Die Wiederherstellungsvorschau ist nicht vollständig darstellbar. Es wurde nichts freigegeben.")
            case .invalidPath(let url), .invalidResource(let url): return L10n.format("Dieser Pfad ist für eine geschützte Wiederherstellung ungeeignet.\n%@", url.path)
            case .system(let url, let code): return L10n.format("%@\n%@", system(code), url.path)
            }
        }
        if let failure = error as? ApplyRecoveryProcessScope.Rejection {
            switch failure {
            case .unreadableProcessList: return L10n.string("Fastra konnte laufende Besitzer der Sitzung nicht zuverlässig prüfen. Die Wiederherstellung bleibt gesperrt.")
            case .currentProcessSession: return L10n.string("Diese Sitzung gehört zum laufenden App-Start. Nutze die zugehörige Rückgängig- oder Aufräumen-Aktion.")
            case .possibleLiveOwner: return L10n.string("Eine zweite Fastra-Instanz läuft. Beende die weitere Kopie regulär und prüfe die Sitzung erneut.")
            }
        }
        if error is ApplyRecoveryDirectoryClaim.Rejection || error is FileSnapshotReadError { return stale }
        if let failure = error as? ApplyRecoveryDirectoryClaim.CloseFailure {
            let errors = failure.primary.map { [$0] } ?? []
            return (errors + failure.closeErrors).map(message).joined(separator: "\n")
        }
        if let failure = error as? ApplyPersistenceBarriers.Failure {
            return ([failure.primary] + failure.closeErrors).map(message).joined(separator: "\n")
        }
        if error is ApplyError || error is CancellationError { return TextWorkflowFailure.message(error) }
        return L10n.format("Die Dateiwiederherstellung konnte nicht abgeschlossen werden: %@", error.localizedDescription)
    }

    private static var limit: String {
        L10n.string("Die Sitzung überschreitet eine sichere Lese- oder Vorschaugrenze. Pro Datei sind höchstens 4 MiB für den Vergleich und insgesamt 32 MiB Vorschautext erlaubt. Es wird keine Teilvorschau freigegeben.")
    }

    private static func system(_ code: Int32) -> String {
        let cause = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        return L10n.format("Die geschützte Sitzungsablage konnte nicht geprüft werden: %@", cause.localizedDescription)
    }
}

extension ApplyRecoveryDirectoryClaim.Rejection: LocalizedError {
    var errorDescription: String? { ApplyRecoveryFailure.message(self) }
}

extension ApplyRecoveryProcessScope.Rejection: LocalizedError {
    var errorDescription: String? { ApplyRecoveryFailure.message(self) }
}
