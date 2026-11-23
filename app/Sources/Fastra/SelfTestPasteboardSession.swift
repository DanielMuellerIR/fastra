// SelfTestPasteboardSession.swift

import Foundation

/// Property-List-fähige Sicherung; auch der Soak-Rettungsprozess liest dieses Format.
struct SelfTestPasteboardBackup {
    typealias Items = [[String: Data]]

    var items: Items
    var ownedChangeCount: Int
    /// Ein vorbereiteter Zähler ist noch kein Besitznachweis. Nach einem
    /// Abbruch bleibt diese Sicherung ausschließlich zur manuellen Rettung.
    var mutationConfirmed: Bool

    /// Items und Bezugzähler müssen denselben Stand beschreiben. Eine Kopie
    /// während Capture darf nicht mit dem nachträglichen Zähler gebunden werden.
    static func capture(
        currentChangeCount: () -> Int,
        captureItems: () throws -> Items
    ) throws -> Self {
        let count = currentChangeCount()
        let items = try captureItems()
        guard currentChangeCount() == count else {
            throw NSError(
                domain: "FastraSelfTestPasteboard", code: 5,
                userInfo: [NSLocalizedDescriptionKey:
                    "Umgebungsproblem: Zwischenablage wurde während der Sicherung benutzt"]
            )
        }
        return Self(items: items, ownedChangeCount: count, mutationConfirmed: true)
    }
}

/// Ein abweichender Zähler zusammen mit fremdem Inhalt belegt einen externen
/// Zwischenablagezugriff. Bleibt dagegen genau der erwartete Testinhalt liegen
/// oder ist er nicht lesbar, hat der Test seinen eigenen Schreibvorgang nicht
/// wie vereinbart ausgeführt.
enum SelfTestPasteboardMutationRouting {
    static func unexpectedCountOutcome(
        contentMatchesExpected: Bool?
    ) -> SelfTestOutcome {
        contentMatchesExpected == false ? .environment : .fail
    }
}

/// Besitzt die Sicherung eines kurzen Copy/Paste-Selbsttests. AppKit und das
/// Journal bleiben beim Harness; nur dieser Besitzer bestätigt Übergänge.
final class SelfTestPasteboardSession<PreparedItems> {
    typealias Items = SelfTestPasteboardBackup.Items

    struct Backend {
        var currentChangeCount: () -> Int
        var captureItems: () throws -> Items
        var persistBackup: (SelfTestPasteboardBackup) throws -> Void
        var abandonBackup: () -> Void
        var prepareRestore: (Items) throws -> PreparedItems
        var writeRestore: (PreparedItems) throws -> Void
    }

    private let backend: Backend
    private var backupState: SelfTestPasteboardBackup?

    init(backend: Backend) {
        self.backend = backend
    }

    /// Nur der erwartete Zähler wird für asynchrone Copy-Menüaufrufe benötigt.
    var expectedChangeCount: Int? { backupState?.ownedChangeCount }

    /// Journalisiert den nächsten unbestätigten Schritt vor jeder Änderung.
    func prepare() throws {
        var backup: SelfTestPasteboardBackup
        if let existing = backupState {
            guard backend.currentChangeCount() == existing.ownedChangeCount else {
                throw NSError(
                    domain: "FastraSelfTestPasteboard", code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Umgebungsproblem: Zwischenablage wurde während des Tests benutzt"]
                )
            }
            backup = existing
        } else {
            backup = try SelfTestPasteboardBackup.capture(
                currentChangeCount: backend.currentChangeCount,
                captureItems: backend.captureItems
            )
        }
        backup.ownedChangeCount &+= 1
        backup.mutationConfirmed = false
        // Das Journal muss vor der Änderung auf Platte stehen. Danach darf
        // auch SIGKILL die Rückgabe nicht mehr vom alten Zähler abkoppeln.
        try backend.persistBackup(backup)
        backupState = backup
    }

    func note(
        expectedItems: Items
    ) throws {
        guard var backup = backupState else { return }
        let actual = backend.currentChangeCount()
        guard actual == backup.ownedChangeCount else {
            let actualItems = try? backend.captureItems()
            let contentMatchesExpected = actualItems.map { $0 == expectedItems }
            let contentDiagnostic: String
            switch contentMatchesExpected {
            case true: contentDiagnostic = "gleich"
            case false: contentDiagnostic = "abweichend"
            case nil: contentDiagnostic = "unlesbar"
            }
            let outcome = SelfTestPasteboardMutationRouting
                .unexpectedCountOutcome(
                    contentMatchesExpected: contentMatchesExpected
                )
            if outcome == .environment {
                // Ein fremder Inhalt ist neuer als unsere Sicherung. Der Test
                // gibt den Besitz auf, damit `finish` ihn nicht zurückschreibt.
                abandon()
            }
            throw NSError(
                domain: "FastraSelfTestPasteboard",
                code: outcome == .environment ? 5 : 10,
                userInfo: [NSLocalizedDescriptionKey:
                    (outcome == .environment
                        ? "Umgebungsproblem: Zwischenablage wurde während des Tests benutzt"
                        : "Teständerung der Zwischenablage verwendete einen unerwarteten "
                            + "Zählerschritt (erwartet \(backup.ownedChangeCount), "
                            + "erhalten \(actual))")
                        + "; Testinhalt \(contentDiagnostic)"]
            )
        }
        do {
            guard try backend.captureItems() == expectedItems else {
                throw NSError(
                    domain: "FastraSelfTestPasteboard", code: 9,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Zwischenablage-Zähler passte, der Inhalt stammt aber nicht vom Test"]
                )
            }
            guard backend.currentChangeCount() == actual else {
                throw NSError(domain: "FastraSelfTestPasteboard", code: 5)
            }
        } catch {
            // Auch ein zugesagter Datentyp kann erst während des Lesens durch
            // eine fremde Kopie verschwinden. Vor `finish` den Besitz abgeben.
            if backend.currentChangeCount() != actual {
                abandon()
                throw NSError(domain: "FastraSelfTestPasteboard", code: 5,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Umgebungsproblem: Zwischenablage wurde während der Nachkontrolle benutzt"])
            }
            throw error
        }
        backup.mutationConfirmed = true
        try backend.persistBackup(backup)
        backupState = backup
    }

    static func outcome(for error: Error) -> SelfTestOutcome {
        let error = error as NSError
        guard error.domain == "FastraSelfTestPasteboard" else { return .fail }
        switch error.code {
        case 1, 4, 5: return .environment
        default: return .fail
        }
    }

    func abandon() {
        backupState = nil
        backend.abandonBackup()
    }

    func finish() -> SelfTestCompletion.PasteboardCleanup {
        guard var backup = backupState else { return .none }
        guard backup.mutationConfirmed else {
            return .failed("vorbereitete Zwischenablage-Änderung wurde nicht bestätigt; "
                           + "Sicherung bleibt zur manuellen Rettung erhalten")
        }
        guard backend.currentChangeCount() == backup.ownedChangeCount else {
            abandon()
            return .keptNewerContent
        }
        do {
            let items = try backend.prepareRestore(backup.items)
            // Auch die Rückgabe ist ein globaler Schreibvorgang. Den nächsten
            // Zähler vorab journalisieren, damit ein fehlgeschlagener
            // `writeObjects`-Versuch die einzige Plattensicherung nicht für
            // jeden späteren Rettungsversuch unbrauchbar macht.
            backup.ownedChangeCount &+= 1
            backup.mutationConfirmed = false
            try backend.persistBackup(backup)
            backupState = backup
            try backend.writeRestore(items)
            guard backend.currentChangeCount() == backup.ownedChangeCount else {
                throw NSError(domain: "FastraSelfTestPasteboard", code: 6,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Zwischenablage-Rückgabe änderte den Zähler unerwartet"])
            }
            backup.mutationConfirmed = true
            try backend.persistBackup(backup)
            abandon()
            return .restored
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
