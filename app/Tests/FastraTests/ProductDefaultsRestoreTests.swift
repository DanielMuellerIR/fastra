// ProductDefaultsRestoreTests.swift
//
// Die Runner sichern vor einem Lauf die echten Fastra-Einstellungen und
// stellen sie danach wieder her. `defaults import` führt dabei aber ZUSAMMEN:
// Ein Schlüssel, den der Lauf neu angelegt hat, blieb in den echten
// Einstellungen stehen, und die Nachprüfung meldete einen Aufräumfehler
// (belegt 2026-09-17 mit dem Fensterrahmen des Einstellungsfensters aus
// `dialoglayout`). Der Test fährt die echte Shell-Funktion beider Runner gegen
// eine eigene, wegwerfbare Test-Domain statt gegen `de.dm0.fastra`.

import Foundation
import Testing

private let restoreRunnerAppDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite("Wiederherstellung der echten Einstellungen", .serialized)
struct ProductDefaultsRestoreTests {
    @Test("Vom Lauf neu angelegte Schlüssel verschwinden wieder",
          arguments: [("selftest.sh", "PRODUCT_DEFAULTS"), ("soak-test.sh", "SOAK_PRODUCT_DEFAULTS")])
    func restoreRemovesKeysAddedDuringRun(runner: String, prefix: String) throws {
        let definition = try shellFunction(
            named: "restore_product_defaults",
            in: restoreRunnerAppDirectory.appendingPathComponent(runner))
        // Präfix und UUID: Bleibt die Domain nach einem Absturz liegen, räumt
        // sie der Test-Defaults-Aufräumer ab.
        let domain = "FastraTests.RestoreProbe.\(UUID().uuidString)"
        let root = testTemporaryDirectory()
            .appendingPathComponent("fastra-restore-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            _ = try? runTestProcess("/usr/bin/defaults", arguments: ["delete", domain], timeout: 10)
        }
        let script = #"""
        set -u
        . "$1"
        domain="$2"
        backup="$3/backup.plist"
        /usr/bin/defaults write "$domain" kept -int 1
        /usr/bin/defaults export "$domain" "$backup"
        # Der „Lauf“: ein neuer Schlüssel und ein geänderter Wert.
        /usr/bin/defaults write "$domain" addedDuringRun -int 2
        # Wie der echte Fall: ein Fensterrahmen-Schlüssel mit Leerzeichen.
        /usr/bin/defaults write "$domain" "NSWindow Frame probe window" -string "0 0 10 10"
        /usr/bin/defaults write "$domain" kept -int 3
        foreign_fastra_process_is_running() { return 1; }
        FASTRA_TEST_SANDBOX="$3"
        eval "${4}_DOMAIN=\$domain ${4}_BACKUP=\$backup ${4}_EXISTED=1 ${4}_SNAPSHOT_READY=1"
        restore_product_defaults
        status=$?
        printf 'STATUS %s\n' "$status"
        /usr/bin/defaults read "$domain" addedDuringRun >/dev/null 2>&1 \
          && printf 'ADDED_KEY_LEFT\n'
        /usr/bin/defaults read "$domain" "NSWindow Frame probe window" >/dev/null 2>&1 \
          && printf 'SPACED_KEY_LEFT\n'
        printf 'KEPT %s\n' "$(/usr/bin/defaults read "$domain" kept)"
        """#
        let scriptURL = root.appendingPathComponent("probe.sh")
        let functionURL = root.appendingPathComponent("function.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try definition.write(to: functionURL, atomically: true, encoding: .utf8)

        let result = try runTestProcess(
            "/bin/bash",
            arguments: [scriptURL.path, functionURL.path, domain, root.path, prefix],
            timeout: 60)

        #expect(result.output.contains("STATUS 0"), "Ausgabe:\n\(result.output)")
        #expect(!result.output.contains("ADDED_KEY_LEFT"), "Ausgabe:\n\(result.output)")
        #expect(!result.output.contains("SPACED_KEY_LEFT"), "Ausgabe:\n\(result.output)")
        #expect(result.output.contains("KEPT 1"), "Ausgabe:\n\(result.output)")
    }
}
