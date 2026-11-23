// TestTemporaryDirectory.swift
//
// Wegwerf-Wurzel aller Test-Fixtures. Foundation kann auf macOS trotz
// umgeleitetem TMPDIR den Benutzer-Temp-Ordner liefern. Hier TMPDIR selbst
// lesen, damit Fixtures innerhalb der Runner-Sandbox bleiben und nach Timeout
// mit ihr verschwinden. Ohne Sandbox gilt der Foundation-Pfad.
// `TestTemporaryDirectoryTests` schützt die Verwendung dieses Helfers.

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
