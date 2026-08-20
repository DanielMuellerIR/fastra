// FourDMacroEngine.swift
//
// Headless-Ausführung der Komplettieren-Makros über tool4d (Idee #28,
// 2026-08-19). Fastra schreibt den Puffer in eine Temp-Datei, startet tool4d
// mit der Startup-Methode `MacroRun` des konfigurierten Engine-Projekts
// (Daniels MAO_Makros) und liest Ergebnis- und Statusdatei zurück.
//
// Wichtige Eigenheiten des Wegs (am 2026-08-19 real gemessen):
// - Exit-Code und stdout von tool4d sind NICHT verlässlich — ausschließlich
//   die Statusdatei (`<Ausgabe>.status`, eine Zeile: OK/UNVERAENDERT/FEHLER…)
//   zählt als Ergebnis.
// - `MacroRun` erwartet UNTOKENISIERTEN Code (wie ihn `METHOD GET CODE`
//   liefert); tokenisierte `.4dm`-Zeilen wie `C_TEXT:C284(...)` zerlegt das
//   Makro in Müll. Der Aufrufer detokenisiert deshalb vorher und stellt die
//   Token nach dem Lauf über `FourDTokenTransform.retokenize` wieder her.
// - Eine `debuggerWatches.json` in den `userPreferences.<Nutzer>`-Ordnern des
//   Engine-Projekts kann tool4d mit Exit 139 abstürzen lassen; die
//   Fehlermeldung nennt diesen bekannten Auslöser.

import Foundation

/// Einstellungen der 4D-Makro-Engine (Einstellungen-Fenster, Abschnitt „4D").
enum FourDMacroEngineSettings {
    static let projectPathKey = "fourD.macroEngine.projectPath"

    /// Konfigurierte Wurzel des Engine-Projekts (Ordner, der `Project/…` mit
    /// der `MacroRun`-Methode enthält). Leer/unkonfiguriert = `nil`; die
    /// Aufrufer zeigen dann eine klare Anleitung statt eines stillen Fallbacks.
    static var projectRootPath: String? {
        let raw = SelfTest.workspaceDefaults().string(forKey: projectPathKey)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }
}

/// Ausgang eines MacroRun-Laufs in Nutzer-Reihenfolge der Statusdatei.
enum FourDMacroEngineResult: Equatable {
    /// Das Makro hat den Code verändert; der neue Code hat LF-Zeilenenden.
    case changed(String)
    /// Das Makro hatte nichts zu tun („Keine Änderungen").
    case unchanged
    /// Erklärter Fehler — Text kommt aus der Statusdatei oder beschreibt den
    /// Prozessfehler verständlich.
    case failed(String)
}

enum FourDMacroEngine {

    /// Zeitlimit eines Makrolaufs. tool4d-Kaltstart + Makro liegen real bei
    /// wenigen Sekunden; nach Ablauf wird die Prozessgruppe beendet.
    static let timeout: TimeInterval = 60

    // MARK: - Pure, unit-getestete Bausteine

    /// Baut die tool4d-Argumente für einen MacroRun-Aufruf. Die Form
    /// `--option wert` (getrennte argv-Einträge) ist am 2026-08-19 gegen
    /// tool4d v21 verifiziert.
    static func arguments(projectFile: URL, inputFile: URL, outputFile: URL,
                          variant: String, methodName: String) -> [String] {
        ["--project", projectFile.path,
         "--dataless", "--skip-onstartup",
         "--opening-mode", "interpreted",
         "--startup-method", "MacroRun",
         "--user-param",
         "\(inputFile.path)|\(outputFile.path)|\(variant)|\(methodName)"]
    }

    /// Wertet Statusdatei und Ausgabedatei aus. `status` ist der rohe Inhalt
    /// der `.status`-Datei (eine Zeile), `output` der Inhalt der Ausgabedatei,
    /// falls vorhanden.
    static func interpret(status: String?, output: String?)
        -> FourDMacroEngineResult {
        guard let status else {
            return .failed(L10n.string(
                "tool4d hat keine Statusdatei geschrieben. Prüfe den Engine-Projektpfad in den Einstellungen (das Projekt braucht die Methode MacroRun) und eine eventuell vorhandene debuggerWatches.json in dessen userPreferences-Ordnern."))
        }
        let line = status
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if line == "OK" {
            guard let output, !output.isEmpty else {
                return .failed(L10n.string(
                    "Status OK, aber die Ergebnisdatei fehlt oder ist leer."))
            }
            return .changed(output)
        }
        if line == "UNVERAENDERT" { return .unchanged }
        if line.hasPrefix("FEHLER") {
            let detail = line.dropFirst("FEHLER".count)
                .trimmingCharacters(in: .whitespaces)
            return .failed(detail.isEmpty
                           ? L10n.string("Das Makro meldete einen Fehler ohne Text.")
                           : detail)
        }
        return .failed(L10n.format(
            "Unverständliche Statusmeldung des Makrolaufs: %@", line))
    }

    /// Findet die `.4DProject`-Datei der konfigurierten Engine-Wurzel.
    static func engineProjectFile(root: URL,
                                  fileManager: FileManager = .default) -> URL? {
        Tool4DProjectLocator.projectFile(in: root)
    }

    // MARK: - Ausführung

    /// Serielle Queue aller Engine-Läufe. Sie hält Vorbereitung (Arbeitsordner
    /// anlegen, Code schreiben), die Watch-Transaktion und das Auslesen des
    /// Ergebnisses vom Main-Thread fern — sonst hinge die Oberfläche bei einer
    /// großen Methode oder einem langsamen Laufwerk vor dem Prozessstart und
    /// nach dessen Ende. Zugleich serialisiert sie die Läufe prozessweit: Zwei
    /// Fenster dürfen die Watch-Dateien desselben Engine-Projekts nicht
    /// überlappend beiseitelegen und zurücklegen.
    private static let runQueue = DispatchQueue(label: "fastra.fourd.macroengine")

    /// Führt genau einen MacroRun-Lauf asynchron aus. `code` ist der bereits
    /// DETOKENISIERTE Methodencode (LF-Zeilenenden sind in Ordnung, MacroRun
    /// normalisiert selbst). Die Completion kommt auf der Main-Queue.
    static func run(tool4d: URL, engineProjectFile: URL, code: String,
                    variant: String, methodName: String,
                    completion: @escaping (FourDMacroEngineResult) -> Void) {
        runQueue.async {
            runOnQueue(tool4d: tool4d, engineProjectFile: engineProjectFile,
                       code: code, variant: variant, methodName: methodName,
                       completion: completion)
        }
    }

    /// Der eigentliche Lauf — läuft ausschließlich auf `runQueue`.
    /// Die Queue wird währenddessen mit einem Semaphor blockiert, damit ein
    /// zweiter Lauf erst nach dem Zurücklegen der Watch-Dateien beginnt.
    private static func runOnQueue(
        tool4d: URL, engineProjectFile: URL, code: String,
        variant: String, methodName: String,
        completion: @escaping (FourDMacroEngineResult) -> Void
    ) {
        let fm = FileManager.default
        /// Ergebnis immer auf der Main-Queue melden — die Aufrufer in
        /// `FourDMacroAssist` arbeiten auf dem Main-Actor.
        func finish(_ result: FourDMacroEngineResult) {
            DispatchQueue.main.async { completion(result) }
        }
        let workDirectory = fm.temporaryDirectory
            .appendingPathComponent("fastra-4dmacro-\(UUID().uuidString)")
        let inputFile = workDirectory.appendingPathComponent("input.4dm")
        let outputFile = workDirectory.appendingPathComponent("output.4dm")
        let statusFile = workDirectory.appendingPathComponent("output.4dm.status")
        do {
            try fm.createDirectory(at: workDirectory,
                                   withIntermediateDirectories: true)
            try code.write(to: inputFile, atomically: true, encoding: .utf8)
        } catch {
            fm.removeItemQuietly(at: workDirectory)
            finish(.failed(L10n.format(
                "Temporäre Makro-Dateien konnten nicht angelegt werden: %@",
                error.localizedDescription)))
            return
        }

        // Bekannte tool4d-Falle: Eine `debuggerWatches.json` in den
        // `userPreferences.<Nutzer>`-Ordnern des Engine-Projekts lässt tool4d
        // mit Exit 139 abstürzen. Das dokumentierte Verfahren (MAO_Makros-
        // Projektregeln) ist Beiseitelegen vor dem Lauf und Zurücklegen
        // danach — genau das tut die Engine hier selbst; die Datei ist ein
        // regenerierbarer 4D-Cache und gitignored.
        let engineRoot = engineProjectFile
            .deletingLastPathComponent()  // …/Project
            .deletingLastPathComponent()  // Projektwurzel
        let debuggerWatchesBackups = setAsideDebuggerWatches(in: engineRoot,
                                                             fileManager: fm)

        // Hält die Queue bis zum Abschluss der Nachbereitung besetzt.
        let done = DispatchSemaphore(value: 0)
        var policy = GitExecutionPolicy.default
        policy.timeout = timeout
        GitRunner.runExecutable(
            tool4d,
            arguments: arguments(projectFile: engineProjectFile,
                                 inputFile: inputFile, outputFile: outputFile,
                                 variant: variant, methodName: methodName),
            in: workDirectory,
            policy: policy,
            // Ergebnisdateien lesen und Watch-Dateien zurücklegen gehören
            // nicht auf den Main-Thread.
            completionQueue: DispatchQueue.global(qos: .userInitiated)
        ) { outcome in
            defer {
                fm.removeItemQuietly(at: workDirectory)
                done.signal()
            }
            restoreDebuggerWatches(debuggerWatchesBackups, fileManager: fm)
            // Statusdatei zuerst: Sie ist die einzige verlässliche Auskunft.
            let status = try? String(contentsOf: statusFile, encoding: .utf8)
            let output = try? String(contentsOf: outputFile, encoding: .utf8)
            if status == nil {
                // Ohne Status hilft nur der Prozessausgang bei der Erklärung.
                switch outcome {
                case .timedOut:
                    finish(.failed(L10n.format(
                        "Der Makrolauf hat das Zeitlimit von %.0f Sekunden überschritten und wurde beendet.",
                        timeout)))
                    return
                case .startFailed(.launchFailed(let detail)):
                    finish(.failed(L10n.format(
                        "tool4d konnte nicht gestartet werden: %@", detail)))
                    return
                case .cancelled:
                    return
                case .completed(let result):
                    var text = L10n.format(
                        "tool4d endete mit Exit-Code %ld, ohne eine Statusdatei zu schreiben.",
                        Int(result.exitCode))
                    if result.exitCode == 139 {
                        text += "\n" + L10n.string(
                            "Exit 139 ist ein bekannter tool4d-Absturz durch eine debuggerWatches.json in den userPreferences-Ordnern des Engine-Projekts. Diese Datei beiseitelegen und erneut versuchen.")
                    }
                    let raw = [result.stderrForDisplay, result.stdoutForDisplay]
                        .first(where: { !$0.isEmpty }) ?? ""
                    if !raw.isEmpty { text += "\n\n" + raw }
                    finish(.failed(text))
                    return
                default:
                    break
                }
            }
            finish(Self.interpret(status: status, output: output))
        }
        // Warten blockiert nur diese eigene Queue, nie den Main-Thread.
        done.wait()
    }

    /// Der Name der Watch-Datei und das gemeinsame Präfix ihrer Beiseite-
    /// Kopien. An das Präfix hängt jeder Lauf noch seine eigene Kennung —
    /// ein fester Name wäre für zwei Läufe derselbe, und der zweite hätte
    /// die Sicherung des ersten überschrieben.
    private static let watchesFileName = "debuggerWatches.json"
    private static let watchesBackupPrefix = "debuggerWatches.json.fastra-macro-backup"

    /// Legt alle `userPreferences.*/debuggerWatches.json` des Engine-Projekts
    /// unter einem laufeigenen Backup-Namen im selben Ordner beiseite und
    /// liefert die Paare (Original, Backup) für die Wiederherstellung.
    private static func setAsideDebuggerWatches(
        in engineRoot: URL, fileManager: FileManager
    ) -> [(original: URL, backup: URL)] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: engineRoot, includingPropertiesForKeys: nil)) ?? []
        var backups: [(URL, URL)] = []
        for entry in entries
        where entry.lastPathComponent.hasPrefix("userPreferences") {
            // Rest eines abgebrochenen früheren Laufs zuerst RETTEN, nicht
            // wegwerfen: Er kann die einzige verbliebene Fassung sein.
            recoverLeftoverWatchesBackups(in: entry, fileManager: fileManager)
            let watches = entry.appendingPathComponent(watchesFileName)
            guard fileManager.fileExists(atPath: watches.path) else { continue }
            let backup = entry.appendingPathComponent(
                "\(watchesBackupPrefix)-\(UUID().uuidString)")
            if (try? fileManager.moveItem(at: watches, to: backup)) != nil {
                backups.append((watches, backup))
            }
        }
        return backups
    }

    /// Räumt liegen gebliebene Beiseite-Kopien eines früheren Laufs auf, der
    /// zum Beispiel durch einen Programmabbruch nie zurücklegen konnte.
    /// Fehlt die Watch-Datei, wandert die Kopie zurück; hat 4D inzwischen eine
    /// neue geschrieben, ist die Kopie ein überholter Cache und darf weg.
    private static func recoverLeftoverWatchesBackups(
        in directory: URL, fileManager: FileManager
    ) {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        let original = directory.appendingPathComponent(watchesFileName)
        for leftover in entries.sorted(by: { $0.path < $1.path })
        where leftover.lastPathComponent.hasPrefix(watchesBackupPrefix) {
            if fileManager.fileExists(atPath: original.path) {
                try? fileManager.removeItem(at: leftover)
            } else {
                try? fileManager.moveItem(at: leftover, to: original)
            }
        }
    }

    /// Stellt die beiseitegelegten Dateien wieder her. Hat 4D währenddessen
    /// eine neue Datei geschrieben, bleibt die neue stehen.
    private static func restoreDebuggerWatches(
        _ backups: [(original: URL, backup: URL)], fileManager: FileManager
    ) {
        for (original, backup) in backups
        where !fileManager.fileExists(atPath: original.path) {
            try? fileManager.moveItem(at: backup, to: original)
        }
    }
}

private extension FileManager {
    /// Aufräumen der Temp-Dateien darf nie einen Ergebnispfad stören.
    func removeItemQuietly(at url: URL) {
        try? removeItem(at: url)
    }
}
