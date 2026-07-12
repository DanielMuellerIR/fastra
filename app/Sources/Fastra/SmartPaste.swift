// SmartPaste.swift
//
// Roadmap H, v0.8 — „Markdown Smart-Paste"
//
// Zwei Paste-Modi in Fastra:
//   1. Plain-Paste (CMD+V): normales Einfügen, hier NICHT implementiert.
//   2. Smart-Paste (CMD+SHIFT+V): formatierter Clipboard-Inhalt (HTML/RTF
//      aus Browser, Word, Notion…) wird als sauberes Markdown eingefügt.
//
// Konvertierungsstrategie: Das externe CLI-Tool `md-clip` (Daniel Müller,
// https://github.com/DanielMuellerIR/md-clip) kapselt pandoc (GPL) und
// übernimmt die ganze Konvertierungsarbeit. Da pandoc GPL ist, wird es
// NICHT in Fastra eingebettet — md-clip muss separat installiert sein.
//
// WICHTIG für den Aufrufer:
//   `markdownFromClipboard` ist synchron-blockierend (bis ~10 s)
//   und darf NICHT auf dem Main-Thread aufgerufen werden.
//   Starte sie aus einer `Task.detached` oder `DispatchQueue.global`.

import AppKit
import Darwin
import Foundation

// MARK: - Nicht blockierende Prozessausgabe

/// Liest eine Prozess-Pipe fortlaufend in den Arbeitsspeicher.
///
/// Ein Lesen erst nach Prozessende kann doppelt blockieren: Ein großer Output
/// füllt den Pipe-Puffer, bevor der Prozess endet, oder ein Unterprozess hält
/// den Schreib-Descriptor nach dem Ende von `md-clip` noch offen. Die
/// Dispatch-Quelle leert die Pipe deshalb schon während der Laufzeit. Beim
/// Abschluss wird nur noch sofort verfügbare Ausgabe gelesen — niemals bis EOF
/// gewartet.
private final class ProcessPipeCapture {
    let pipe = Pipe()

    private let queue = DispatchQueue(label: "app.fastra.smartpaste-pipe")
    private let cancellationFinished = DispatchSemaphore(value: 0)
    private let source: DispatchSourceRead
    private let readDescriptor: Int32
    private var data = Data()
    private var isFinished = false

    init() throws {
        readDescriptor = pipe.fileHandleForReading.fileDescriptor

        // Nicht blockierend lesen: So wartet auch der abschließende Drain nie
        // auf einen Unterprozess, der den Schreib-Descriptor geerbt hat.
        let flags = fcntl(readDescriptor, F_GETFL)
        guard flags != -1,
              fcntl(readDescriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Prozess-Pipe konnte nicht vorbereitet werden."]
            )
        }

        source = DispatchSource.makeReadSource(
            fileDescriptor: readDescriptor,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.drainAvailableData()
        }
        source.setCancelHandler { [cancellationFinished] in
            cancellationFinished.signal()
        }
        source.resume()
    }

    /// Liefert die bisherige Ausgabe und schließt alle Pipe-Descriptoren.
    /// Mehrfache Aufrufe sind absichtlich sicher, damit Fehlerpfade über
    /// `defer` zuverlässig aufräumen können.
    func finish() -> Data {
        let (result, didCancel): (Data, Bool) = queue.sync {
            guard !isFinished else { return (data, false) }
            drainAvailableData()
            isFinished = true
            source.cancel()
            return (data, true)
        }

        if didCancel {
            // Die Cancel-Callback läuft auf derselben seriellen Queue. Erst
            // danach dürfen die von Dispatch beobachteten Descriptoren zu.
            _ = cancellationFinished.wait(timeout: .now() + .seconds(1))
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        return result
    }

    deinit {
        _ = finish()
    }

    /// Liest bis zum momentan verfügbaren Ende. `EAGAIN` bedeutet hier
    /// ausdrücklich „für jetzt fertig", nicht Fehler.
    private func drainAvailableData() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var bytesDrained = 0
        // Ein dauerhaft schreibender geerbter Descriptor darf den seriellen
        // Reader nicht monopolisieren. Während der Laufzeit löst Dispatch bei
        // weiterem Input erneut aus; beim Abschluss kann `finish()` danach die
        // Quelle abbrechen und die Descriptoren schließen.
        let maximumBytesPerPass = 1024 * 1024

        while bytesDrained < maximumBytesPerPass {
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(readDescriptor, bytes.baseAddress, bytes.count)
            }

            if bytesRead > 0 {
                data.append(contentsOf: buffer.prefix(bytesRead))
                bytesDrained += bytesRead
                continue
            }
            if bytesRead == 0 {
                return
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            return
        }
    }
}

// MARK: - Fehlertypen

/// Alle möglichen Fehler bei einem Smart-Paste-Vorgang.
///
/// `Equatable` erlaubt direkte Vergleiche in Tests (z.B. `== .timeout`).
enum SmartPasteError: Error, Equatable {
    /// md-clip ist auf diesem System nicht installiert.
    case mdClipNotInstalled
    /// Das Clipboard enthält keinen formatierten Inhalt (kein HTML, kein RTF).
    case noFormattedContent
    /// md-clip lief durch, lieferte aber keinen verwertbaren Output.
    /// Der assoziierte String enthält technische Details (z.B. stderr-Text).
    case conversionFailed(String)
    /// md-clip hat innerhalb des Timeouts (10 s) keine Antwort geliefert.
    case timeout

    /// Benutzerfreundliche Erklärung auf Deutsch.
    /// Wird in `performSmartPaste` im NSAlert angezeigt.
    var userMessage: String {
        switch self {
        case .mdClipNotInstalled:
            // Hinweis: Releases auf GitHub, damit der Nutzer weiß, wo er
            // das Tool herbekommt.
            return L10n.format(
                "„md-clip“ ist nicht installiert. Das Tool wird benötigt, um formatierten Text (HTML/RTF) in Markdown zu konvertieren.\n\nBitte installiere es über:\n%@",
                "https://github.com/DanielMuellerIR/md-clip/releases"
            )
        case .noFormattedContent:
            return L10n.string("Das Clipboard enthält keinen formatierten Inhalt (HTML oder RTF). Smart-Paste benötigt kopierten Text aus einem Browser oder einer Office-Anwendung.")
        case .conversionFailed(let detail):
            return L10n.format("Die Markdown-Konvertierung ist fehlgeschlagen.\n\nDetails: %@", detail)
        case .timeout:
            return L10n.string("Die Konvertierung hat zu lange gedauert (Zeitlimit: 10 Sekunden). Bitte versuche es erneut oder verwende kleinere Inhalte.")
        }
    }
}

// MARK: - Hauptlogik

/// Kapselt die gesamte „Smart-Paste"-Funktionalität.
///
/// Alle Methoden sind statisch — kein Zustand, alles rein funktional und
/// damit direkt unit-testbar.
enum SmartPaste {

    // MARK: md-clip suchen

    /// Sucht das `md-clip`-Binary in den Standard-Installationspfaden.
    ///
    /// Reihenfolge:
    ///   1. `/usr/local/bin/md-clip`  (Homebrew auf Intel-Mac, manuelle Installs)
    ///   2. `/opt/homebrew/bin/md-clip` (Homebrew auf Apple Silicon)
    ///   3. `~/bin/md-clip`           (benutzereigener bin-Ordner, Tilde wird expandiert)
    ///
    /// - Parameter searchPaths: Pfade, in denen gesucht wird. Der Default enthält
    ///   die drei üblichen Installationsorte. Kann in Tests durch eigene
    ///   Temp-Pfade ersetzt werden.
    /// - Returns: URL zum ersten gefundenen, ausführbaren Binary, oder `nil`.
    static func findMdClip(searchPaths: [String] = [
        "/usr/local/bin/md-clip",
        "/opt/homebrew/bin/md-clip",
        "~/bin/md-clip"
    ]) -> URL? {
        let fm = FileManager.default
        for rawPath in searchPaths {
            // Tilde (~) expandieren, damit ~/bin/md-clip korrekt aufgelöst wird.
            let expanded = (rawPath as NSString).expandingTildeInPath
            // Ausführbar = Datei existiert UND hat das x-Bit.
            if fm.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        return nil
    }

    // MARK: Clipboard prüfen

    /// Gibt `true` zurück, wenn das Clipboard formatierten Inhalt enthält.
    ///
    /// „Formatiert" bedeutet: HTML oder RTF. Plain-Text allein genügt nicht —
    /// dann würde Smart-Paste nichts Sinnvolles liefern.
    ///
    /// - Parameter pasteboard: Das zu prüfende Pasteboard. Default: `NSPasteboard.general`.
    ///   In Tests kann ein eigenes, isoliertes Pasteboard übergeben werden.
    static func clipboardHasFormattedContent(_ pasteboard: NSPasteboard = .general) -> Bool {
        let types = pasteboard.types ?? []
        // .html  = "public.html"
        // .rtf   = "public.rtf"
        return types.contains(.html) || types.contains(.rtf)
    }

    // MARK: Konvertierung

    /// Ruft md-clip auf und gibt das erzeugte Markdown als String zurück.
    ///
    /// md-clip schreibt per Default (ohne `--replace`) auf **stdout** und
    /// verändert das Clipboard NICHT. Das ist der von uns bevorzugte Modus,
    /// weil wir das Nutzer-Clipboard unangetastet lassen wollen.
    ///
    /// Ablauf:
    ///   1. md-clip als `Process` starten, stdout + stderr fortlaufend aus Pipes lesen.
    ///   2. Mit `DispatchSemaphore` auf Ende warten (max. 10 Sekunden).
    ///   3. Bei Timeout: md-clip beenden, nötigenfalls SIGKILL senden und `.timeout` zurückgeben.
    ///   4. Bei Exit ≠ 0 (md-clip kennt drei Fehlercodes):
    ///      Code 1 = kein konvertierbares Format → `.noFormattedContent`
    ///      Code 2 = Dependency fehlt (pandoc o.ä.) → `.conversionFailed`
    ///      Code 3 = Pandoc-Fehler → `.conversionFailed`
    ///   5. Bei leerem Output trotz Exit 0 → `.conversionFailed`
    ///
    /// ACHTUNG: Diese Funktion ist **synchron-blockierend** (bis ~10 s).
    /// Sie darf NICHT auf dem Main-Thread aufgerufen werden.
    ///
    /// - Parameter mdClipURL: Absoluter Pfad zum md-clip-Binary.
    /// - Returns: `.success(markdownString)` oder `.failure(SmartPasteError)`.
    static func markdownFromClipboard(
        mdClipURL: URL,
        timeout: TimeInterval = 10
    ) -> Result<String, SmartPasteError> {

        // Process vorbereiten: md-clip ohne --replace → stdout-Modus.
        let process = Process()
        process.executableURL = mdClipURL
        // Keine weiteren Argumente nötig: md-clip --auto-detect (default)
        // liest HTML oder RTF aus dem Clipboard und konvertiert nach GFM.
        // --quiet unterdrückt Status-Logs auf stderr (wir wollen nur Output).
        process.arguments = ["--quiet"]

        // stdout und stderr werden schon während des Prozesses geleert. Das
        // verhindert volle Pipe-Puffer und ein EOF-Warten auf Unterprozesse.
        let stdoutCapture: ProcessPipeCapture
        let stderrCapture: ProcessPipeCapture
        do {
            stdoutCapture = try ProcessPipeCapture()
            stderrCapture = try ProcessPipeCapture()
        } catch {
            return .failure(.conversionFailed(error.localizedDescription))
        }
        process.standardOutput = stdoutCapture.pipe
        process.standardError = stderrCapture.pipe
        defer {
            _ = stdoutCapture.finish()
            _ = stderrCapture.finish()
        }

        // Semaphore: wir blockieren hier auf Ende des Prozesses.
        // Der Hauptthread darf hier NICHT stehen — der Aufrufer muss das
        // sicherstellen (z.B. via Task.detached oder DispatchQueue.global).
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return .failure(.conversionFailed(L10n.format("Prozess konnte nicht gestartet werden: %@", error.localizedDescription)))
        }

        // Auf Abschluss warten — in der App maximal 10 Sekunden. Der Parameter
        // ist injizierbar, damit der echte Timeout-Pfad schnell testbar bleibt.
        let deadline = DispatchTime.now() + timeout
        let didFinish = semaphore.wait(timeout: deadline)

        if didFinish == .timedOut {
            // Erst regulär beenden. Ignoriert das Tool SIGTERM, folgt nach
            // kurzer Schonfrist SIGKILL, damit md-clip nicht weiterläuft.
            if process.isRunning {
                process.terminate()
            }
            if semaphore.wait(timeout: .now() + .milliseconds(250)) == .timedOut,
               process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = semaphore.wait(timeout: .now() + .seconds(1))
            }
            return .failure(.timeout)
        }

        // Nach Prozessende nur die bereits vorhandenen Bytes übernehmen. Die
        // Captures warten bewusst nicht auf EOF eines geerbten Descriptors.
        let outputData = stdoutCapture.finish()
        let stderrData = stderrCapture.finish()

        // Exit-Code auswerten.
        // md-clip-Exit-Codes (laut Skript):
        //   0 = Erfolg
        //   1 = Clipboard leer / kein konvertierbares Format
        //   2 = Dependency fehlt (pandoc, Swift-Helper, etc.)
        //   3 = Konvertierungsfehler (Pandoc non-zero exit)
        let exitCode = process.terminationStatus
        if exitCode == 1 {
            return .failure(.noFormattedContent)
        }
        if exitCode != 0 {
            // stderr-Inhalt als Detail mitgeben.
            let detail = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(kein stderr)"
            return .failure(.conversionFailed(L10n.format(
                "md-clip beendete sich mit Code %ld. %@", Int(exitCode), detail
            )))
        }

        // stdout lesen und als Markdown zurückgeben.
        let markdown = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if markdown.isEmpty {
            return .failure(.conversionFailed("md-clip lieferte leeren Output (Exit 0)."))
        }

        return .success(markdown)
    }

    // MARK: Orchestrierung

    /// Führt den vollständigen Smart-Paste-Vorgang durch.
    ///
    /// Ablauf:
    ///   1. Kein formatierter Inhalt im Clipboard?
    ///      → Plain-Text aus Clipboard lesen und einfügen (stiller Fallback).
    ///   2. md-clip nicht installiert?
    ///      → NSAlert mit Installations-Hinweis.
    ///   3. Konvertierung via md-clip.
    ///      → Markdown an Cursor-Position einfügen.
    ///
    /// Einfüge-Strategie (Cursor-genaues Einfügen im CESE-Editor):
    ///   Wir versuchen zuerst `NSTextInputClient.insertText(_:replacementRange:)`
    ///   über den First Responder des Key-Fensters — das ist das gleiche
    ///   Protokoll, das das Betriebssystem beim normalen Tippen nutzt, und
    ///   respektiert die aktuelle Cursor-Position.
    ///   Fallback: `workspace.activeTabContent.wrappedValue += markdown` —
    ///   hängt den Text ans Datei-Ende an. Das ist weniger elegant, aber
    ///   immer verfügbar und nie fehlerhaft.
    ///
    /// ACHTUNG: Diese Funktion ruft `markdownFromClipboard` intern auf und
    /// muss daher ebenfalls AUSSERHALB des Main-Threads gestartet werden.
    /// UI-Operationen (NSAlert, Tab-Inhalt-Update) werden per
    /// `DispatchQueue.main.async` zurück auf den Hauptthread gebracht.
    ///
    /// - Parameter workspace: Der aktive `Workspace` der App.
    static func performSmartPaste(into workspace: Workspace) {

        // Schritt 1: formatierten Inhalt prüfen.
        guard clipboardHasFormattedContent() else {
            // Kein HTML/RTF: normaler Plain-Text-Fallback.
            // `NSPasteboard.general.string(forType: .string)` gibt nil
            // zurück, wenn auch kein Plain-Text vorhanden ist.
            guard let plainText = NSPasteboard.general.string(forType: .string),
                  !plainText.isEmpty else { return }
            DispatchQueue.main.async {
                insertText(plainText, into: workspace)
            }
            return
        }

        // Schritt 2: md-clip suchen.
        guard let mdClipURL = findMdClip() else {
            DispatchQueue.main.async {
                showErrorAlert(SmartPasteError.mdClipNotInstalled)
            }
            return
        }

        // Schritt 3: Konvertierung auf Hintergrund-Thread (blockierend).
        // Wenn performSmartPaste bereits auf einem Hintergrund-Thread läuft,
        // können wir markdownFromClipboard direkt aufrufen. Wenn nicht
        // (z.B. aus einem Menü-Handler auf dem Main-Thread), muss der
        // Aufrufer eine Task.detached oder DispatchQueue.global verwenden.
        let result = markdownFromClipboard(mdClipURL: mdClipURL)
        DispatchQueue.main.async {
            switch result {
            case .success(let markdown):
                insertText(markdown, into: workspace)
            case .failure(let error):
                showErrorAlert(error)
            }
        }
    }

    // MARK: - Private Helfer

    /// Fügt `text` an der aktuellen Cursor-Position des Editors ein.
    ///
    /// Strategie 1 (bevorzugt): `NSTextInputClient.insertText(_:replacementRange:)`.
    ///   Der CESE-Editor implementiert `NSTextInputClient` über seine
    ///   `NSTextView`-Unterklasse `CodeEditTextView.TextView`. Das Protokoll
    ///   ist dasselbe, das das Betriebssystem beim Tippen nutzt — es
    ///   respektiert Cursor-Position und bestehende Selektion.
    ///   `NSRange(location: NSNotFound, length: 0)` bedeutet „aktuelle
    ///   Cursor-Position, keine Ersetzung" (Standard-Konvention).
    ///
    /// Strategie 2 (Fallback): `workspace.activeTabContent.wrappedValue += text`.
    ///   Hängt den Text ans Ende des aktiven Tabs an. Immer verfügbar,
    ///   aber ignoriert die Cursor-Position.
    ///
    /// Muss auf dem Main-Thread aufgerufen werden.
    private static func insertText(_ text: String, into workspace: Workspace) {
        // Versuche First-Responder-Einfügen via NSTextInputClient.
        if let firstResponder = NSApp.keyWindow?.firstResponder,
           let inputClient = firstResponder as? NSTextInputClient {
            // replacementRange: NSNotFound = aktuelle Cursor-Position.
            // `insertText` akzeptiert `Any` (NSString oder NSAttributedString).
            inputClient.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }

        // Fallback: ans Datei-Ende anhängen.
        // Nachteil: ignoriert die Cursor-Position. In der Praxis tritt dieser
        // Pfad auf, wenn kein Editor-Fenster im Vordergrund ist (unwahrscheinlich,
        // aber defensiv abgesichert).
        workspace.activeTabContent.wrappedValue += text
    }

    /// Zeigt einen modalen NSAlert mit der `userMessage` des Fehlers.
    ///
    /// Muss auf dem Main-Thread aufgerufen werden.
    private static func showErrorAlert(_ error: SmartPasteError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Smart-Paste nicht möglich")
        alert.informativeText = error.userMessage
        alert.addButton(withTitle: L10n.string("OK"))
        alert.runModal()
    }
}
