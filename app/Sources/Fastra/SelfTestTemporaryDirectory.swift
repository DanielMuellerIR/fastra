// SelfTestTemporaryDirectory.swift
//
// Wegwerf-Wurzel der Selbsttest-Fixtures. `selftest.sh` setzt TMPDIR auf seine
// Sandbox; Foundations `temporaryDirectory` kann auf macOS trotzdem den
// Benutzer-Temp-Ordner (`getconf DARWIN_USER_TEMP_DIR`) liefern. Deshalb hier
// ausdrücklich die Runner-Wurzel verwenden, damit auch bei Timeout keine
// Fixtures außerhalb der Sandbox bleiben. Im Normalbetrieb setzt launchd
// TMPDIR auf denselben Ordner, den Foundation liefert.
//
// Separate Datei wegen der Quelltext-Wächter über `SelfTest.swift`.
// `TestTemporaryDirectoryTests` verlangt die Nutzung dieses Helfers.

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
