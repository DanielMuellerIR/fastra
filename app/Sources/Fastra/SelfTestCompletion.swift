// SelfTestCompletion.swift

/// Maschinenlesbares Ergebnis eines In-App-Selbsttests. Die Reihenfolge
/// bestimmt, welches Ergebnis gewinnt, wenn beim Aufräumen noch ein Fehler
/// hinzukommt: Ein Funktionsfehler darf nie als Skip oder Umgebungsproblem
/// erscheinen.
enum SelfTestOutcome: Int, Comparable {
    case pass = 0
    case skip = 1
    case environment = 2
    case fail = 3

    static func < (lhs: SelfTestOutcome, rhs: SelfTestOutcome) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var protocolStatus: String {
        switch self {
        case .pass: "PASS"
        case .skip: "SKIP"
        case .environment: "ENV"
        case .fail: "FAIL"
        }
    }

    /// Verknüpft einen späteren Abschlussgrund mit bereits beobachteten
    /// Funktionsfehlern. Die Fehler bleiben sowohl im Status als auch in der
    /// Diagnose sichtbar; ein späterer Fokusverlust darf sie nicht verdecken.
    static func resolving(
        recordedFailures: [String],
        requestedOutcome: SelfTestOutcome,
        message: String
    ) -> (outcome: SelfTestOutcome, message: String) {
        guard !recordedFailures.isEmpty else {
            return (requestedOutcome, message)
        }
        let recordedMessage = recordedFailures.joined(separator: "; ")
        return (
            .fail,
            message == recordedMessage ? message : recordedMessage + "; " + message
        )
    }
}


/// Wertet den Abschluss aus, ohne selbst aufzuräumen oder den Prozess zu beenden.
enum SelfTestCompletion {
    enum PasteboardCleanup {
        case none
        case restored
        case keptNewerContent
        case failed(String)
    }

    static func resolve(
        outcome: SelfTestOutcome,
        message: String,
        pasteboardCleanup: PasteboardCleanup
    ) -> (outcome: SelfTestOutcome, message: String) {
        switch pasteboardCleanup {
        case .none, .restored:
            return (outcome, message)
        case .keptNewerContent:
            return (
                max(outcome, .environment),
                message + " (Zwischenablage inzwischen anderweitig beschrieben — "
                    + "neuerer Inhalt behalten)"
            )
        case .failed(let error):
            return (
                max(outcome, .fail),
                message + " — Zwischenablage nicht zurückgegeben (\(error))"
            )
        }
    }
}
