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

import Darwin
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
    /// Das gebundene Dokument änderte sich, bevor der eingereihte Lauf seine
    /// serielle Queue erreichte. Es gab noch keine Prozess-Nebenwirkung.
    case cancelledBeforeStart
    /// Erklärter Fehler — Text kommt aus der Statusdatei oder beschreibt den
    /// Prozessfehler verständlich.
    case failed(String)
}

enum FourDMacroEngine {

    /// Besitzt den bereits verifizierten Ordner-Deskriptor bis zum Ende des
    /// tool4d-Laufs. Ein umbenannter oder am alten Pfad ersetzter
    /// `userPreferences`-Ordner kann die Wiederherstellung dadurch nicht in
    /// einen fremden Ordner umlenken.
    final class DebuggerWatchesBackup: @unchecked Sendable {
        fileprivate let backupName: String

        private let lock = NSLock()
        private var directoryFD: Int32?

        fileprivate init(backupName: String, directoryFD: Int32) {
            self.backupName = backupName
            self.directoryFD = directoryFD
        }

        /// Genau ein Abschlussweg übernimmt den Deskriptor. Bleibt der Lauf
        /// vorher liegen, schließt `deinit` ihn trotzdem.
        fileprivate func takeDirectoryFD() -> Int32? {
            lock.withLock {
                defer { directoryFD = nil }
                return directoryFD
            }
        }

        deinit {
            if let directoryFD { Darwin.close(directoryFD) }
        }
    }

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
    static func run(tool4d: URL, engineProjectRoot: URL,
                    engineProjectFile: URL, code: String,
                    variant: String, methodName: String,
                    shouldStart: @escaping () -> Bool = { true },
                    completion: @escaping (FourDMacroEngineResult) -> Void) {
        runQueue.async {
            runOnQueue(tool4d: tool4d, engineProjectRoot: engineProjectRoot,
                       engineProjectFile: engineProjectFile,
                       code: code, variant: variant, methodName: methodName,
                       shouldStart: shouldStart,
                       completion: completion)
        }
    }

    /// Der eigentliche Lauf — läuft ausschließlich auf `runQueue`.
    /// Die Queue wird währenddessen mit einem Semaphor blockiert, damit ein
    /// zweiter Lauf erst nach dem Zurücklegen der Watch-Dateien beginnt.
    private static func runOnQueue(
        tool4d: URL, engineProjectRoot: URL, engineProjectFile: URL, code: String,
        variant: String, methodName: String,
        shouldStart: @escaping () -> Bool,
        completion: @escaping (FourDMacroEngineResult) -> Void
    ) {
        let fm = FileManager.default
        /// Ergebnis immer auf der Main-Queue melden — die Aufrufer in
        /// `FourDMacroAssist` arbeiten auf dem Main-Actor.
        func finish(_ result: FourDMacroEngineResult) {
            DispatchQueue.main.async { completion(result) }
        }
        // Ein zweiter Fensterlauf kann bis zu 60 Sekunden hinter dem ersten
        // warten. Erst nach Erhalt des seriellen Queue-Slots prüfen wir seine
        // Dokumentbindung erneut, noch bevor Temp-Dateien entstehen.
        guard shouldStart() else {
            finish(.cancelledBeforeStart)
            return
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
        guard shouldStart() else {
            fm.removeItemQuietly(at: workDirectory)
            finish(.cancelledBeforeStart)
            return
        }

        // Bekannte tool4d-Falle: Eine `debuggerWatches.json` in den
        // `userPreferences.<Nutzer>`-Ordnern des Engine-Projekts lässt tool4d
        // mit Exit 139 abstürzen. Das dokumentierte Verfahren (MAO_Makros-
        // Projektregeln) ist Beiseitelegen vor dem Lauf und Zurücklegen
        // danach — genau das tut die Engine hier selbst; die Datei ist ein
        // regenerierbarer 4D-Cache und gitignored.
        let debuggerWatchesBackups: [DebuggerWatchesBackup]
        do {
            debuggerWatchesBackups = try setAsideDebuggerWatches(
                in: engineProjectRoot, fileManager: fm
            )
        } catch {
            fm.removeItemQuietly(at: workDirectory)
            finish(.failed(L10n.format(
                "Die debuggerWatches.json konnte vor dem Makrolauf nicht sicher beiseitegelegt werden: %@",
                error.localizedDescription
            )))
            return
        }
        guard shouldStart() else {
            restoreDebuggerWatches(debuggerWatchesBackups)
            fm.removeItemQuietly(at: workDirectory)
            finish(.cancelledBeforeStart)
            return
        }

        // Hält die Queue bis zum Abschluss der Nachbereitung besetzt.
        let done = DispatchSemaphore(value: 0)
        var policy = GitExecutionPolicy.default
        policy.timeout = timeout
        let cancellation = GitRunner.runExecutable(
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
            restoreDebuggerWatches(debuggerWatchesBackups)
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
                    finish(.failed(L10n.string("Der Makrolauf wurde abgebrochen.")))
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
        // Warten blockiert nur diese eigene Queue, nie den Main-Thread. Eine
        // zusätzliche Reserve deckt den Rückruf und das Lesen der kleinen
        // Ergebnisdateien ab. Nach einem Nachschlag warten wir weiter auf die
        // bestätigte Prozessbeendigung: Vorher dürfen weder Watch-Dateien
        // zurückkehren noch der Arbeitsordner oder der serielle Slot frei
        // werden. Bleibt der Runner hängen, bleibt auch dieser Slot bewusst
        // gesperrt und das Backup erhalten.
        if done.wait(timeout: .now() + timeout + 5) == .timedOut {
            cancellation.cancel()
            done.wait()
        }
    }

    /// Der Name der Watch-Datei und das gemeinsame Präfix ihrer Beiseite-
    /// Kopien. An das Präfix hängt jeder Lauf noch seine eigene Kennung —
    /// ein fester Name wäre für zwei Läufe derselbe, und der zweite hätte
    /// die Sicherung des ersten überschrieben.
    private static let watchesFileName = "debuggerWatches.json"
    private static let watchesBackupPrefix = "debuggerWatches.json.fastra-macro-backup"
    private static let preferencesDirectoryPrefix = "userPreferences."

    /// Legt alle `userPreferences.*/debuggerWatches.json` des Engine-Projekts
    /// unter einem laufeigenen Backup-Namen im selben Ordner beiseite und
    /// hält den geprüften Ordner bis zur Wiederherstellung offen.
    static func setAsideDebuggerWatches(
        in engineRoot: URL, fileManager: FileManager,
        exclusiveRename: ((Int32, String, String) -> POSIXErrorCode?)? = nil
    ) throws -> [DebuggerWatchesBackup] {
        let entries = try fileManager.contentsOfDirectory(
            at: engineRoot, includingPropertiesForKeys: nil
        )
        var backups: [DebuggerWatchesBackup] = []
        let rename = exclusiveRename ?? renameExclusively

        func failure(_ code: POSIXErrorCode) -> POSIXError {
            // Wurde ein früherer Ordner schon vorbereitet, stellen wir ihn
            // vor dem Abbruch wieder her. Ein nicht atomarer Fallback wäre
            // gefährlicher als ein erklärter, nicht gestarteter Makrolauf.
            restoreDebuggerWatches(backups)
            return POSIXError(code)
        }

        for entry in entries where isExpectedPreferencesDirectoryName(
            entry.lastPathComponent
        ) {
            var entryInfo = stat()
            guard lstat(entry.path, &entryInfo) == 0 else {
                throw failure(posixErrorCode(errno))
            }
            // Einen passend benannten Symlink darf tool4d ebenfalls sehen.
            // Fastra folgt ihm nicht, startet mit der bekannten Crash-Datei
            // dahinter aber auch nicht still weiter.
            if entryInfo.st_mode & S_IFMT == S_IFLNK {
                throw failure(.ELOOP)
            }
            guard entryInfo.st_mode & S_IFMT == S_IFDIR else { continue }
            // `lstat` schließt einen Verzeichnis-Symlink ausdrücklich aus.
            // Alle folgenden Umbenennungen laufen relativ zum geöffneten FD;
            // ein später ausgetauschter Pfad kann sie deshalb nicht umlenken.
            guard let directoryFD = openVerifiedDirectory(entry) else {
                throw failure(posixErrorCode(errno))
            }
            var descriptorTransferred = false
            defer {
                if !descriptorTransferred { Darwin.close(directoryFD) }
            }
            // Rest eines abgebrochenen früheren Laufs zuerst RETTEN, nicht
            // wegwerfen: Er kann die einzige verbliebene Fassung sein.
            recoverLeftoverWatchesBackups(directoryFD: directoryFD)
            var watchesInfo = stat()
            if fstatat(directoryFD, watchesFileName, &watchesInfo,
                       AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                throw failure(posixErrorCode(errno))
            }
            guard watchesInfo.st_mode & S_IFMT == S_IFREG else {
                throw failure(watchesInfo.st_mode & S_IFMT == S_IFLNK
                              ? .ELOOP : .EINVAL)
            }
            var lastError: POSIXErrorCode = .EEXIST
            for _ in 0..<4 {
                let backupName = "\(watchesBackupPrefix)-\(UUID().uuidString)"
                if let error = rename(directoryFD, watchesFileName, backupName) {
                    lastError = error
                    if error == .EEXIST { continue }
                    break
                }
                backups.append(DebuggerWatchesBackup(
                    backupName: backupName, directoryFD: directoryFD
                ))
                descriptorTransferred = true
                break
            }
            if !descriptorTransferred {
                throw failure(lastError)
            }
        }
        return backups
    }

    /// Räumt liegen gebliebene Beiseite-Kopien eines früheren Laufs auf, der
    /// zum Beispiel durch einen Programmabbruch nie zurücklegen konnte.
    /// Fehlt die Watch-Datei, wandert die Kopie zurück; hat 4D inzwischen eine
    /// neue geschrieben, bleibt die Kopie unter einem eindeutigen Namen
    /// erhalten, damit kein möglicherweise noch benötigter Stand verloren geht.
    static func recoverLeftoverWatchesBackups(
        in directory: URL, fileManager: FileManager,
        beforeExclusiveRename: (() -> Void)? = nil
    ) {
        guard let directoryFD = openVerifiedDirectory(directory) else { return }
        defer { Darwin.close(directoryFD) }
        recoverLeftoverWatchesBackups(
            directoryFD: directoryFD,
            beforeExclusiveRename: beforeExclusiveRename
        )
    }

    private static func recoverLeftoverWatchesBackups(
        directoryFD: Int32,
        beforeExclusiveRename: (() -> Void)? = nil
    ) {
        // Auch die Namensliste stammt aus demselben offenen Ordner wie die
        // folgenden `renameatx_np`-Aufrufe. Eine Pfad-Umbenennung zwischen
        // Öffnen und Auflisten kann die beiden Seiten so nicht trennen.
        let leftovers = directoryEntryNames(in: directoryFD)
            .filter {
                $0.hasPrefix("\(watchesBackupPrefix)-")
                    && isRegularFile(named: $0, in: directoryFD)
            }
            .sorted {
                let leftDate = modificationTime(named: $0, in: directoryFD)
                let rightDate = modificationTime(named: $1, in: directoryFD)
                if leftDate.seconds != rightDate.seconds {
                    return leftDate.seconds > rightDate.seconds
                }
                if leftDate.nanoseconds != rightDate.nanoseconds {
                    return leftDate.nanoseconds > rightDate.nanoseconds
                }
                return $0 < $1
        }
        for leftover in leftovers {
            beforeExclusiveRename?()
            if renameatx_np(directoryFD, leftover,
                            directoryFD, watchesFileName,
                            UInt32(RENAME_EXCL)) == 0 {
                continue
            }
            preserveDebuggerWatchesBackup(named: leftover,
                                           in: directoryFD)
        }
    }

    /// Stellt die beiseitegelegten Dateien wieder her. Hat 4D währenddessen
    /// eine neue Datei geschrieben, bleibt die neue stehen.
    static func restoreDebuggerWatches(
        _ backups: [DebuggerWatchesBackup],
        beforeExclusiveRename: (() -> Void)? = nil
    ) {
        for backup in backups {
            guard let directoryFD = backup.takeDirectoryFD() else { continue }
            defer { Darwin.close(directoryFD) }
            let backupName = backup.backupName
            guard backupName.hasPrefix("\(watchesBackupPrefix)-"),
                  isRegularFile(named: backupName, in: directoryFD) else { continue }
            beforeExclusiveRename?()
            if renameatx_np(directoryFD, backupName,
                            directoryFD, watchesFileName,
                            UInt32(RENAME_EXCL)) != 0 {
                preserveDebuggerWatchesBackup(named: backupName,
                                               in: directoryFD)
            }
        }
    }

    /// Überzählige oder von einer neuen 4D-Datei verdrängte Sicherungen unter
    /// einem Namen behalten, den der nächste automatische Lauf nicht erneut
    /// verarbeitet. Keine Fassung wird still gelöscht.
    private static func preserveDebuggerWatchesBackup(named backupName: String,
                                                       in directoryFD: Int32) {
        guard isRegularFile(named: backupName, in: directoryFD) else { return }
        // `RENAME_EXCL` verhindert auch beim extrem unwahrscheinlichen
        // UUID-Treffer, dass eine bereits bewahrte Fassung überschrieben wird.
        for _ in 0..<4 {
            let preservedName =
                "debuggerWatches.json.fastra-macro-preserved-\(UUID().uuidString)"
            if renameatx_np(directoryFD, backupName,
                            directoryFD, preservedName,
                            UInt32(RENAME_EXCL)) == 0 { return }
            if errno != EEXIST { return }
        }
    }

    private static func isExpectedPreferencesDirectoryName(_ name: String) -> Bool {
        name.hasPrefix(preferencesDirectoryPrefix)
            && name.count > preferencesDirectoryPrefix.count
    }

    /// Öffnet ausschließlich den per `lstat` gesehenen echten Ordner. Der
    /// Identitätsvergleich schließt auch einen Austausch zwischen `lstat`
    /// und `open` aus; danach bindet der FD alle Änderungen an genau ihn.
    private static func openVerifiedDirectory(_ directory: URL) -> Int32? {
        var pathInfo = stat()
        guard lstat(directory.path, &pathInfo) == 0,
              pathInfo.st_mode & S_IFMT == S_IFDIR else { return nil }
        let fd = Darwin.open(directory.path,
                             O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        var openedInfo = stat()
        guard fstat(fd, &openedInfo) == 0,
              openedInfo.st_mode & S_IFMT == S_IFDIR,
              openedInfo.st_dev == pathInfo.st_dev,
              openedInfo.st_ino == pathInfo.st_ino else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    /// Listet einen Ordner über einen duplizierten Deskriptor. `fdopendir`
    /// übernimmt das Duplikat; `closedir` schließt ausschließlich dieses,
    /// während der ursprüngliche FD für die Transaktion offen bleibt.
    private static func directoryEntryNames(in directoryFD: Int32) -> [String] {
        let duplicateFD = Darwin.dup(directoryFD)
        guard duplicateFD >= 0 else { return [] }
        guard let stream = fdopendir(duplicateFD) else {
            Darwin.close(duplicateFD)
            return []
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self,
                                          capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    private static func isRegularFile(named name: String,
                                      in directoryFD: Int32) -> Bool {
        var info = stat()
        return fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            && info.st_mode & S_IFMT == S_IFREG
    }

    private static func modificationTime(named name: String, in directoryFD: Int32)
        -> (seconds: Int, nanoseconds: Int) {
        var info = stat()
        guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            return (.min, .min)
        }
        return (Int(info.st_mtimespec.tv_sec), Int(info.st_mtimespec.tv_nsec))
    }

    private static func renameExclusively(_ directoryFD: Int32,
                                          _ sourceName: String,
                                          _ destinationName: String)
        -> POSIXErrorCode? {
        guard renameatx_np(directoryFD, sourceName,
                           directoryFD, destinationName,
                           UInt32(RENAME_EXCL)) != 0 else { return nil }
        return posixErrorCode(errno)
    }

    private static func posixErrorCode(_ rawValue: Int32) -> POSIXErrorCode {
        POSIXErrorCode(rawValue: rawValue) ?? .EIO
    }
}

private extension FileManager {
    /// Aufräumen der Temp-Dateien darf nie einen Ergebnispfad stören.
    func removeItemQuietly(at url: URL) {
        try? removeItem(at: url)
    }
}
