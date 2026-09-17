// TestTemporaryDirectory.swift
//
// Wegwerf-Wurzel aller Test-Fixtures.
//
// `FileManager.default.temporaryDirectory` ignoriert auf macOS die
// Umgebungsvariable `TMPDIR` und liefert immer den Benutzer-Temp-Ordner
// (`getconf DARWIN_USER_TEMP_DIR`; belegt 2026-09-17 mit einem kleinen
// Prüfprogramm unter gesetztem TMPDIR). `test.sh` lenkt `TMPDIR` aber genau
// deshalb in seine Wegwerf-Sandbox um, damit liegengebliebene Fixtures mit der
// Sandbox verschwinden. Weil Foundation die Umlenkung nicht sah, lagen am
// 2026-09-17 rund 250 Fixture-Ordner früherer Läufe im echten Temp
// (CodeQA-Fund test-temp-leaks). Dieser Helfer liest `TMPDIR` selbst; ohne
// Sandbox (nacktes `swift test`) bleibt es beim Foundation-Pfad. Ein
// Quelltext-Wächter (`TestTemporaryDirectoryTests`) hält die Testsuite auf
// diesem Helfer.

import Foundation

/// Wegwerf-Wurzel der Test-Fixtures: `TMPDIR`, sofern gesetzt und vorhanden,
/// sonst der Foundation-Temp-Ordner. `environment` ist nur für den Test des
/// Helfers austauschbar.
func testTemporaryDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL {
    if let raw = environment["TMPDIR"], !raw.isEmpty {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: raw, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        }
    }
    return FileManager.default.temporaryDirectory
}
