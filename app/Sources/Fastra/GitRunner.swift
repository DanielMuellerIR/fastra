import Foundation

/// Ergebnis eines git-Aufrufs — roher Prozess-Ausgang, absichtlich un-interpretiert.
/// Die UX-Regel „Fehler = echte git-Ausgabe zeigen" lebt davon, dass `stderr`
/// wortwörtlich erhalten bleibt (ROADMAP → Projekt- & Git-Ausbau).
struct GitResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var ok: Bool { exitCode == 0 }
}

/// Dünner Wrapper um das `git`-Kommandozeilenprogramm. Philosophie der Etappe:
/// **Git liefert Logik und Daten, Fastra liefert Sichtbarkeit und Knöpfe.**
/// Kein libgit2, kein Eigenbau — nur Unterprozess-Aufrufe. Der CLI-Weg erbt
/// automatisch die Auth-Konfiguration des Nutzers (SSH-Keys, Keychain-Helper).
///
/// UX-Regeln, die hier verdrahtet sind:
/// - **Git fehlt → still weg.** `resolvedPath` liefert `nil`, ohne je den
///   `/usr/bin/git`-Stub anzufassen (der löst sonst den CLT-Installations-
///   Dialog aus — genau das „nervige Gefrage", das wir vermeiden).
/// - **Nie den Main-Thread blockieren.** `run` arbeitet auf einer eigenen Queue
///   und ruft die Completion auf Main.
enum GitRunner {
    /// Kandidaten-Pfade für ein NUTZBARES git-Binary, in Prioritätsreihenfolge.
    /// Bewusst NICHT `/usr/bin/git`: das ist unter macOS ein Shim, der bei
    /// fehlenden Command Line Tools einen modalen Installations-Dialog öffnet.
    /// Das echte CLT-git liegt unter `/Library/Developer/...` und wird direkt
    /// angesprochen; Homebrew-git (Apple Silicon / Intel) hat Vorrang, falls da.
    static let candidatePaths = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
    ]

    /// Der aktive Xcode-Developer-Ordner (Fallback-Quelle für git). `xcode-select`
    /// liegt fest unter `/usr/bin` und löst KEINEN Installations-Dialog aus — es
    /// meldet bei fehlenden Tools nur einen Fehler. Als Closure gehalten, damit
    /// Tests die reine Pfad-Auswahl ohne echten Prozess prüfen können.
    static var developerDirProvider: () -> String? = Self.queryXcodeSelect

    /// Erster existierender, ausführbarer git-Pfad — oder `nil` (git fehlt).
    /// Reine Auswahl-Logik, injizierbar für Tests.
    static func resolvePath(candidates: [String],
                            developerDir: String?,
                            fileManager: FileManager = .default) -> String? {
        var paths = candidates
        // Xcode-only-Setups (CLT fehlt): git liegt im aktiven Developer-Ordner.
        if let dev = developerDir {
            paths.append("\(dev)/usr/bin/git")
        }
        return paths.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Gecachter git-Pfad. `nil` nach Auflösung = git nicht verfügbar.
    /// Doppelt-optional, um „noch nicht ermittelt" von „ermittelt: keins" zu
    /// unterscheiden.
    private static var cachedPath: String?? = nil

    static var resolvedPath: String? {
        if let cached = cachedPath { return cached }
        let path = resolvePath(candidates: candidatePaths,
                               developerDir: developerDirProvider())
        cachedPath = .some(path)
        return path
    }

    /// Ist ein nutzbares git vorhanden? Steuert, ob Git-UI überhaupt erscheint.
    static var isAvailable: Bool { resolvedPath != nil }

    /// Führt git asynchron aus und liefert das rohe Ergebnis auf dem Main-Thread.
    /// `completion(nil)` = git nicht verfügbar oder Start fehlgeschlagen (der
    /// Aufrufer blendet die Funktion dann still aus, statt zu meckern).
    ///
    /// - `--no-pager` erzwingt reine stdout-Ausgabe (kein `less`), und ein
    ///   leerer `GIT_TERMINAL_PROMPT=0` verhindert, dass git bei fehlenden
    ///   Credentials auf einer unsichtbaren Konsole nach einem Passwort fragt
    ///   und hängt.
    static func run(_ args: [String],
                    in directory: URL,
                    completion: @escaping (GitResult?) -> Void) {
        guard let gitPath = resolvedPath else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gitPath)
            process.arguments = ["--no-pager"] + args
            process.currentDirectoryURL = directory
            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Beide Pipes VOR waitUntilExit vollständig leeren: readDataToEnd
            // blockiert bis EOF, aber nur diesen Hintergrund-Thread. Würde man
            // erst nach waitUntilExit lesen, könnte ein großer Output (git diff,
            // git log) den Pipe-Puffer füllen und den Prozess vor seinem Ende
            // blockieren (klassischer Deadlock).
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let result = GitResult(
                exitCode: process.terminationStatus,
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: errData, as: UTF8.self)
            )
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Fragt den aktiven Developer-Ordner über `xcode-select -p` ab (dialogfrei).
    private static func queryXcodeSelect() -> String? {
        let path = "/usr/bin/xcode-select"
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()   // stderr verschlucken (Fehlermeldung bei fehlenden Tools)
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let dir = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.isEmpty ? nil : dir
    }
}
