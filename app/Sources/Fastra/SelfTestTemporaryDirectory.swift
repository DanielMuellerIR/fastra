// SelfTestTemporaryDirectory.swift
//
// Wegwerf-Wurzel der Selbsttest-Fixtures.
//
// `selftest.sh` startet jeden Testprozess mit `TMPDIR` in seiner
// Wegwerf-Sandbox, damit Fixtures eines abgebrochenen Tests mit der Sandbox
// verschwinden. `FileManager.default.temporaryDirectory` ignoriert `TMPDIR`
// auf macOS aber und liefert immer den Benutzer-Temp-Ordner (`getconf
// DARWIN_USER_TEMP_DIR`; belegt 2026-09-17). Deshalb lagen dort Reste von
// `gitsticky`, `mdassist`, `sessionrestore` und anderen Fenstertests, die
// nach einem Timeout nie zu ihrem Aufräumen kamen (CodeQA-Fund
// test-temp-leaks). Die Selbsttests holen ihre Wurzel deshalb hier; im
// normalen Betrieb ist `TMPDIR` derselbe Ordner, den auch Foundation liefert
// (launchd setzt ihn für jede App), es ändert sich also nichts.
//
// Eigene Datei, damit die Quelltext-Wächter über `SelfTest.swift` unberührt
// bleiben; ein eigener Wächter (`TestTemporaryDirectoryTests`) verlangt, dass
// `SelfTest.swift` ausschließlich diesen Helfer nutzt.

import Foundation

/// Wegwerf-Wurzel der Selbsttest-Fixtures: `TMPDIR`, sofern gesetzt und
/// vorhanden, sonst der Foundation-Temp-Ordner.
func selfTestTemporaryDirectory() -> URL {
    if let raw = ProcessInfo.processInfo.environment["TMPDIR"], !raw.isEmpty {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: raw, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        }
    }
    return FileManager.default.temporaryDirectory
}
