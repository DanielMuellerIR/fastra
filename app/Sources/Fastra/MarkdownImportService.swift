// MarkdownImportService.swift
//
// Der laufende Teil von „Dokument in Markdown umwandeln": Formatabfrage mit
// Zwischenspeicher und die eigentliche Umwandlung über `poormans-text`.
//
// Zwei Eigenschaften bestimmen den Aufbau:
//
// 1. Das Öffnen einer Datei darf NIE auf diesen Dienst warten. Der Katalog wird
//    beim App-Start vorgewärmt und danach höchstens alle fünf Minuten neu
//    erfragt. Wer poormans-text aktualisiert und die neuen Formate sofort
//    nutzen will, startet Fastra neu.
// 2. Die Quelle wird nie verändert. Das Werkzeug schreibt in ein verstecktes
//    Zwischenverzeichnis; erst das fertige Ergebnis wandert unter seinen
//    endgültigen Namen. Bricht etwas ab, bleibt neben der Quelle nichts liegen.

import Foundation
import AppKit

/// Nur vom Main-Thread benutzen — wie `Workspace`, mit dem dieser Dienst
/// zusammenspielt. Alle Prozessergebnisse kommen bereits auf dem Main-Thread
/// zurück; hier läuft nichts nebenläufig.
final class MarkdownImportService: ObservableObject {
    static let shared = MarkdownImportService()

    /// Gültigkeit des Formatkatalogs. Bewusst großzügig: Der Katalog ändert sich
    /// nur, wenn poormans-text oder Pandoc neu installiert werden.
    static let catalogLifetime: TimeInterval = 5 * 60

    /// Die Formatabfrage kostet gemessen rund 10 ms. Reißt sie diese Frist,
    /// stimmt etwas grundsätzlich nicht — dann lieber ohne Angebot weitermachen,
    /// als das Öffnen einer Datei aufzuhalten.
    static let catalogTimeout: TimeInterval = 5
    /// Eine echte Umwandlung darf deutlich länger dauern (Pandoc, große Bilder).
    static let conversionTimeout: TimeInterval = 120

    /// Zuletzt erfragter Katalog. `nil` = noch nie erfolgreich erfragt.
    @Published private(set) var catalog: MarkdownImportCatalog?
    /// Sichtbarer Zustand der laufenden/letzten Umwandlung — treibt die Leiste.
    @Published var state: MarkdownImportState = .idle

    private var catalogProbedAt: Date?
    private var isProbing = false
    private var pendingCatalogRequests: [(MarkdownImportCatalog?) -> Void] = []

    /// Testhaken: ersetzt den echten Prozessaufruf. `nil` = echter Aufruf.
    var runProcess: ((URL, [String], TimeInterval, @escaping (Int32, Data, Data) -> Void) -> Void)?

    // MARK: - Formatkatalog

    /// Beim App-Start aufrufen. Danach steht die Antwort, bevor der Nutzer die
    /// erste Datei öffnet.
    func warmCatalog() {
        withCatalog { _ in }
    }

    /// Liefert den Katalog — sofort aus dem Zwischenspeicher, sonst nach einer
    /// Abfrage. `completion` läuft immer auf dem Main-Thread.
    func withCatalog(_ completion: @escaping (MarkdownImportCatalog?) -> Void) {
        if let catalogProbedAt,
           Date().timeIntervalSince(catalogProbedAt) < Self.catalogLifetime {
            completion(catalog)
            return
        }

        pendingCatalogRequests.append(completion)
        guard !isProbing else { return }
        isProbing = true

        guard let executable = MarkdownImportTool.locate() else {
            // Werkzeug nicht installiert: still ausblenden, wie bei fehlendem
            // git. Auch dieses Ergebnis wird zwischengespeichert, sonst würde
            // bei jedem Öffnen erneut das Dateisystem abgesucht.
            finishProbe(with: nil)
            return
        }

        run(executable: executable,
            arguments: ["--formats", "--json"],
            timeout: Self.catalogTimeout) { [weak self] status, stdout, _ in
            guard let self else { return }
            // Eine ältere CLI kennt `--formats` nicht und endet mit 64. Das ist
            // kein Fehler, sondern schlicht „kann Fastra nicht bedienen".
            self.finishProbe(with: status == 0 ? MarkdownImportCatalog.decode(stdout) : nil)
        }
    }

    private func finishProbe(with catalog: MarkdownImportCatalog?) {
        self.catalog = catalog
        catalogProbedAt = Date()
        isProbing = false
        let requests = pendingCatalogRequests
        pendingCatalogRequests.removeAll()
        for request in requests { request(catalog) }
    }

    /// Nur der bereits vorliegende Katalog — ohne jede Abfrage. Für Ansichten,
    /// die bei jedem Neuzeichnen aufgerufen werden.
    var cachedCatalog: MarkdownImportCatalog? { catalog }

    // MARK: - Umwandlung

    /// Wandelt `sourceURL` um und legt das Ergebnis daneben ab.
    ///
    /// - Parameter completion: `markdownFile` bei Erfolg, sonst `nil`. Der
    ///   sichtbare Zustand (`state`) trägt Warnungen beziehungsweise Fehlertext.
    func convert(_ sourceURL: URL, completion: ((URL?) -> Void)? = nil) {
        // Eine Umwandlung nach der anderen: zwei gleichzeitige Läufe könnten
        // denselben freien Zielnamen wählen.
        if case .running = state {
            NSSound.beep()
            completion?(nil)
            return
        }
        beginConversion(sourceURL, completion: completion)
    }

    private func beginConversion(_ sourceURL: URL, completion: ((URL?) -> Void)?) {
        guard let executable = MarkdownImportTool.locate() else {
            fail(L10n.string("„Poor Man's Text“ ist nicht installiert."), completion)
            return
        }

        let parent = sourceURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            fail(L10n.format("Der Ordner „%@“ ist nicht beschreibbar.",
                             parent.lastPathComponent), completion)
            return
        }

        // Das Zwischenverzeichnis liegt bewusst NEBEN der Quelle und nicht in
        // /tmp: Nur so ist das abschließende Umbenennen ein echtes Rename auf
        // demselben Volume. Aus /tmp wäre es ein Kopiervorgang, bei dem ein
        // Abbruch ein halbes Ergebnis neben der Quelle hinterlassen könnte.
        let staging = parent.appendingPathComponent(
            ".fastra-markdown-\(UUID().uuidString)", isDirectory: true
        )
        let output = staging.appendingPathComponent("out", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging,
                                                    withIntermediateDirectories: false)
        } catch {
            fail(error.localizedDescription, completion)
            return
        }

        state = .running(sourceURL)
        run(executable: executable,
            arguments: ["--json", "--output", output.path, "--", sourceURL.path],
            timeout: Self.conversionTimeout) { [weak self] status, stdout, stderr in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: staging) }

            guard status == 0, let produced = MarkdownImportOutput.decode(stdout) else {
                let message = MarkdownImportOutput.decodeError(stdout)
                    ?? String(decoding: stderr, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                self.fail(message.isEmpty
                          ? L10n.string("Die Umwandlung ist fehlgeschlagen.")
                          : message, completion)
                return
            }

            self.publish(produced, output: output, staging: staging,
                         sourceURL: sourceURL, completion: completion)
        }
    }

    /// Verschiebt das fertige Ergebnis unter seinen endgültigen Namen.
    private func publish(_ produced: MarkdownImportOutput, output: URL, staging: URL,
                         sourceURL: URL, completion: ((URL?) -> Void)?) {
        let producesAssets = !produced.assets.isEmpty
        let target = MarkdownImportNaming.availableTarget(forSource: sourceURL,
                                                          producesAssets: producesAssets)
        do {
            // `moveItem` scheitert, wenn am Ziel doch schon etwas liegt. Genau
            // das ist gewollt: lieber ein ehrlicher Fehler als eine
            // überschriebene fremde Datei.
            try FileManager.default.moveItem(
                at: producesAssets ? output : produced.markdownFile,
                to: target
            )
        } catch {
            fail(error.localizedDescription, completion)
            return
        }

        // VOR dem Melden aufräumen: Sonst sähe ein Aufrufer, der sofort auf den
        // Ordner schaut, noch das versteckte Zwischenverzeichnis. Der `defer`
        // des Aufrufers räumt danach nur noch ein bereits leeres Nichts weg.
        try? FileManager.default.removeItem(at: staging)

        let markdownFile = MarkdownImportNaming.markdownFile(inTarget: target,
                                                             sourceURL: sourceURL,
                                                             producesAssets: producesAssets)
        state = .finished(markdownFile: markdownFile, warnings: produced.warnings)
        completion?(markdownFile)
    }

    private func fail(_ message: String, _ completion: ((URL?) -> Void)?) {
        state = .failed(message)
        completion?(nil)
    }

    func clearState() {
        state = .idle
    }

    // MARK: - Prozessaufruf

    /// Startet das Werkzeug. Wiederverwendet bewusst den bereits gehärteten
    /// Runner aus `GitRunner`: eigene Prozessgruppe, Frist, Ausgabegrenze und
    /// bereinigte Umgebung sind dort schon gelöst und gelten hier genauso.
    private func run(executable: URL, arguments: [String], timeout: TimeInterval,
                     completion: @escaping (Int32, Data, Data) -> Void) {
        if let runProcess {
            runProcess(executable, arguments, timeout, completion)
            return
        }
        GitRunner.runExecutable(
            executable,
            arguments: arguments,
            in: FileManager.default.temporaryDirectory,
            policy: GitExecutionPolicy(timeout: timeout, terminationGracePeriod: 0.5)
        ) { outcome in
            switch outcome {
            case .completed(let result):
                completion(result.exitCode, result.stdoutData, result.stderrData)
            case .captureFailed(let failure):
                completion(failure.partialResult.exitCode,
                           failure.partialResult.stdoutData,
                           failure.partialResult.stderrData)
            case .startFailed, .cancelled, .timedOut:
                completion(-1, Data(), Data())
            }
        }
    }
}

/// Sichtbarer Zustand der Umwandlung. Die Leiste über dem Editor liest ihn.
enum MarkdownImportState: Equatable {
    case idle
    case running(URL)
    case finished(markdownFile: URL, warnings: [String])
    case failed(String)
}
