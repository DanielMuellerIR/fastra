//
// RipgrepFileEnumerator.swift
//
// Der gebündelte `rg` ersetzt die langsame FileManager-Rekursion im
// Folder-Scope. Er liefert ausschließlich Kandidatpfade; das Einlesen,
// Encoding und die eigentliche NSRegularExpression-Suche bleiben bewusst
// bei Fastra. So sind Capture-Groups, Platzhalter, Ausschlüsse und alle
// bisherigen Sicherheitsregeln bitgleich zum alten Pfad.

import Foundation

enum RipgrepFileEnumerator {
    enum Failure: Error { case unavailable, failed(String) }

    /// Liefert reguläre, nicht versteckte Dateien. `--no-ignore` ist wichtig:
    /// Fastra suchte bisher auch in gitignorierten Quellen. `rg` respektiert
    /// ohne diesen Schalter `.gitignore` und würde damit Ergebnisse verlieren.
    static func files(in root: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue { return [root] }
        guard let executable = executableURL else { throw Failure.unavailable }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--files", "--null", "--no-ignore", "--glob", "!.git/**", root.path]
        let output = Pipe(); let errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        do { try process.run() } catch { throw Failure.unavailable }
        // Während `rg` noch läuft lesen. Erst auf `waitUntilExit()` zu
        // warten kann bei vielen Dateien den Pipe-Puffer füllen: rg wartet
        // dann aufs Schreiben, Fastra aufs Beenden — ein klassischer Deadlock.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Failure.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data.split(separator: 0).compactMap { bytes in
            guard let path = String(bytes: bytes, encoding: .utf8) else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    private static var executableURL: URL? {
        // SwiftPM-Tests verwenden Bundle.module, die gepackte App Bundle.main.
        let bundles = [Bundle.main, Bundle.module]
        // SwiftPM flacht verarbeitete Ressourcen ab, die gepackte App darf
        // den Unterordner dagegen behalten. Beide Layouts unterstützen.
        return bundles.lazy.compactMap {
            $0.url(forResource: "rg", withExtension: nil, subdirectory: "ripgrep")
                ?? $0.url(forResource: "rg", withExtension: nil)
        }
            .first
    }
}
