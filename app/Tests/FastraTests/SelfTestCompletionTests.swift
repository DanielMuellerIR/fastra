import Testing
@testable import Fastra

struct SelfTestCompletionTests {
    struct CompletionCase {
        let outcome: SelfTestOutcome
        let message: String
        let cleanup: SelfTestCompletion.PasteboardCleanup
        let expectedOutcome: SelfTestOutcome
        let expectedMessage: String
    }

    // Fachliche Falltabelle: vorhandene Fehlerursachen bleiben erhalten;
    // fremder Inhalt ist ein Umgebungsproblem, gescheiterte Rückgabe ein Fehler.
    static let cases: [CompletionCase] = [
        .init(outcome: .pass, message: "Prüfung erfolgreich", cleanup: .none,
              expectedOutcome: .pass, expectedMessage: "Prüfung erfolgreich"),
        .init(outcome: .pass, message: "Prüfung erfolgreich", cleanup: .restored,
              expectedOutcome: .pass, expectedMessage: "Prüfung erfolgreich"),
        .init(outcome: .pass, message: "Prüfung erfolgreich", cleanup: .keptNewerContent,
              expectedOutcome: .environment,
              expectedMessage: "Prüfung erfolgreich (Zwischenablage inzwischen anderweitig beschrieben — neuerer Inhalt behalten)"),
        .init(outcome: .pass, message: "Prüfung erfolgreich", cleanup: .failed("Journal nicht lesbar"),
              expectedOutcome: .fail,
              expectedMessage: "Prüfung erfolgreich — Zwischenablage nicht zurückgegeben (Journal nicht lesbar)"),
        .init(outcome: .skip, message: "Voraussetzung fehlt", cleanup: .none,
              expectedOutcome: .skip, expectedMessage: "Voraussetzung fehlt"),
        .init(outcome: .skip, message: "Voraussetzung fehlt", cleanup: .restored,
              expectedOutcome: .skip, expectedMessage: "Voraussetzung fehlt"),
        .init(outcome: .skip, message: "Voraussetzung fehlt", cleanup: .keptNewerContent,
              expectedOutcome: .environment,
              expectedMessage: "Voraussetzung fehlt (Zwischenablage inzwischen anderweitig beschrieben — neuerer Inhalt behalten)"),
        .init(outcome: .skip, message: "Voraussetzung fehlt", cleanup: .failed("Journal nicht lesbar"),
              expectedOutcome: .fail,
              expectedMessage: "Voraussetzung fehlt — Zwischenablage nicht zurückgegeben (Journal nicht lesbar)"),
        .init(outcome: .environment, message: "Fensterfokus verloren", cleanup: .none,
              expectedOutcome: .environment, expectedMessage: "Fensterfokus verloren"),
        .init(outcome: .environment, message: "Fensterfokus verloren", cleanup: .restored,
              expectedOutcome: .environment, expectedMessage: "Fensterfokus verloren"),
        .init(outcome: .environment, message: "Fensterfokus verloren", cleanup: .keptNewerContent,
              expectedOutcome: .environment,
              expectedMessage: "Fensterfokus verloren (Zwischenablage inzwischen anderweitig beschrieben — neuerer Inhalt behalten)"),
        .init(outcome: .environment, message: "Fensterfokus verloren", cleanup: .failed("Journal nicht lesbar"),
              expectedOutcome: .fail,
              expectedMessage: "Fensterfokus verloren — Zwischenablage nicht zurückgegeben (Journal nicht lesbar)"),
        .init(outcome: .fail, message: "Dokumentinhalt falsch", cleanup: .none,
              expectedOutcome: .fail, expectedMessage: "Dokumentinhalt falsch"),
        .init(outcome: .fail, message: "Dokumentinhalt falsch", cleanup: .restored,
              expectedOutcome: .fail, expectedMessage: "Dokumentinhalt falsch"),
        .init(outcome: .fail, message: "Dokumentinhalt falsch", cleanup: .keptNewerContent,
              expectedOutcome: .fail,
              expectedMessage: "Dokumentinhalt falsch (Zwischenablage inzwischen anderweitig beschrieben — neuerer Inhalt behalten)"),
        .init(outcome: .fail, message: "Dokumentinhalt falsch", cleanup: .failed("Journal nicht lesbar"),
              expectedOutcome: .fail,
              expectedMessage: "Dokumentinhalt falsch — Zwischenablage nicht zurückgegeben (Journal nicht lesbar)")
    ]

    @Test("Abschluss erhält Statuspriorität und ursprünglichen Prüfgrund", arguments: cases)
    func completion(_ test: CompletionCase) {
        let result = SelfTestCompletion.resolve(
            outcome: test.outcome, message: test.message, pasteboardCleanup: test.cleanup
        )
        #expect(result.outcome == test.expectedOutcome)
        #expect(result.message == test.expectedMessage)
    }
}
