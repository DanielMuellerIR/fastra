// MarkdownImport.swift
//
// Reine, UI- und prozessfreie Logik für „Dokument in Markdown umwandeln".
//
// Fastra bringt KEIN eigenes Formatwissen mit. Welche Dateitypen umwandelbar
// sind, beantwortet ausschließlich das externe Werkzeug `poormans-text` über
// `--formats --json`. Dadurch wirken später hinzukommende Formate sofort, ohne
// dass hier eine Liste gepflegt werden müsste. Diese Datei kennt daher nur:
// wo das Werkzeug liegt, wie seine Antworten aussehen und wie das Ziel neben
// der Quelle heißen soll.
//
// Kein AppKit, kein SwiftUI, kein Prozessstart — alles hier ist vom
// Hintergrund-Thread aufrufbar und ohne installiertes Werkzeug testbar.

import Foundation

// MARK: - Werkzeugsuche

/// Findet das installierte `poormans-text`.
///
/// Eine GUI-App erbt NICHT den PATH der Login-Shell: Homebrew-Pfade fehlen dort
/// regelmäßig. Deshalb werden die bekannten Orte zuerst direkt geprüft und der
/// PATH nur als Ergänzung benutzt — dieselbe Lehre wie bei der git-Suche.
enum MarkdownImportTool {
    static let executableName = "poormans-text"

    /// Umgebungsvariable für einen ausdrücklich gewählten Stand. Sie erlaubt es
    /// Selbsttests, gegen ein frisch gebautes Werkzeug zu laufen, ohne die
    /// installierte Fassung anzufassen.
    static let overrideEnvironmentKey = "FASTRA_POORMANS_TEXT"

    static let candidateDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Innerhalb des App-Bundles von Poor Man's Text liegt dieselbe CLI. Sie
    /// wird gebraucht, wenn der Nutzer die App installiert, aber den Symlink
    /// in `/usr/local/bin` nicht angelegt hat.
    static let bundleRelativeExecutablePath =
        "Poor Man's Text.app/Contents/Resources/poormans-text"

    static var defaultApplicationDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications"),
        ]
    }

    /// Erster ausführbarer Fundort — oder `nil`, wenn das Werkzeug fehlt.
    /// Alle Quellen sind injizierbar; der Test braucht keine echte Installation.
    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationDirectories: [URL] = defaultApplicationDirectories,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidates = [URL]()
        if let override = environment[overrideEnvironmentKey], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates += candidateDirectories.map {
            URL(fileURLWithPath: $0).appendingPathComponent(executableName)
        }
        candidates += applicationDirectories.map {
            $0.appendingPathComponent(bundleRelativeExecutablePath)
        }
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").compactMap { directory in
                directory.isEmpty
                    ? nil
                    : URL(fileURLWithPath: String(directory))
                        .appendingPathComponent(executableName)
            }
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

// MARK: - Formatkatalog

/// Ein vom Werkzeug gemeldetes Quellformat.
struct MarkdownImportFormat: Equatable {
    /// Formatkennung des Werkzeugs, z. B. `docx`. Nur für Anzeige und Diagnose.
    let identifier: String
    /// Kleingeschriebene Endungen ohne Punkt.
    let fileExtensions: [String]
    /// `true` = die Quelle ist ein Ordner-Paket (`.rtfd`) und keine Datei.
    let isPackage: Bool
    /// `false`, wenn ein benötigtes Werkzeug (meist Pandoc) gerade fehlt.
    let isAvailable: Bool
    let unavailableReason: String?

    /// Namen der laut Werkzeug fehlenden Zusatzprogramme, z. B. `["pandoc"]`.
    ///
    /// `poormans-text` meldet sie in `unavailableReason` in der festen
    /// Maschinenform `missing required tool: a, b`. Nur dieses Präfix wird
    /// verstanden; jede andere Meldung liefert eine leere Liste — dann zeigt
    /// die Oberfläche den Grund wörtlich statt einer Deutung.
    var missingTools: [String] {
        let prefix = "missing required tool: "
        guard let unavailableReason, unavailableReason.hasPrefix(prefix) else {
            return []
        }
        return unavailableReason.dropFirst(prefix.count)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Die vollständige Antwort auf `poormans-text --formats --json`.
struct MarkdownImportCatalog: Equatable {
    let toolVersion: String
    let formats: [MarkdownImportFormat]

    /// Leerer Katalog = Werkzeug fehlt oder versteht `--formats` nicht. Fastra
    /// blendet das Angebot dann still aus, genau wie bei fehlendem git.
    static let unavailable = MarkdownImportCatalog(toolVersion: "", formats: [])

    var isUsable: Bool { formats.contains { $0.isAvailable } }

    /// Format zu einer Endung — Punkt und Groß-/Kleinschreibung egal.
    func format(forExtension rawExtension: String) -> MarkdownImportFormat? {
        let needle = rawExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !needle.isEmpty else { return nil }
        return formats.first { $0.fileExtensions.contains(needle) }
    }

    /// Nur Formate, die JETZT auch wirklich konvertierbar sind. Ein Angebot für
    /// ein Format ohne installiertes Pandoc würde verlässlich scheitern.
    func availableFormat(forExtension rawExtension: String) -> MarkdownImportFormat? {
        guard let format = format(forExtension: rawExtension), format.isAvailable else {
            return nil
        }
        return format
    }

    /// Liest die JSON-Antwort. `nil` bei allem, was nicht eindeutig ein
    /// erfolgreicher Katalog ist — eine ältere CLI ohne `--formats` liefert
    /// beispielsweise einen Fehler auf stderr und gar kein JSON.
    static func decode(_ data: Data) -> MarkdownImportCatalog? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["ok"] as? Bool == true,
              let rawFormats = root["formats"] as? [[String: Any]] else {
            return nil
        }
        let formats: [MarkdownImportFormat] = rawFormats.compactMap { entry in
            guard let identifier = entry["format"] as? String,
                  let extensions = entry["extensions"] as? [String],
                  !extensions.isEmpty else { return nil }
            return MarkdownImportFormat(
                identifier: identifier,
                fileExtensions: extensions.map { $0.lowercased() },
                // Unbekannte Container-Wörter gelten als Datei. Ein künftiges
                // Paketformat unter anderem Namen öffnete dann wie bisher als
                // Ordner — das ist das bekannte Verhalten, kein neuer Schaden.
                isPackage: (entry["container"] as? String) == "package",
                isAvailable: entry["available"] as? Bool ?? false,
                unavailableReason: entry["unavailableReason"] as? String
            )
        }
        guard !formats.isEmpty else { return nil }
        return MarkdownImportCatalog(
            toolVersion: root["version"] as? String ?? "",
            formats: formats
        )
    }
}

// MARK: - Ergebnis einer Umwandlung

/// Die vom Werkzeug gemeldete Ausgabe, noch im Zwischenverzeichnis.
struct MarkdownImportOutput: Equatable {
    let markdownFile: URL
    /// Zusätzlich entstandene Dateien (Bilder). Leer = das Markdown steht allein.
    let assets: [URL]
    let warnings: [String]

    static func decode(_ data: Data) -> MarkdownImportOutput? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["ok"] as? Bool == true,
              let markdownPath = root["markdownFile"] as? String else { return nil }
        return MarkdownImportOutput(
            markdownFile: URL(fileURLWithPath: markdownPath),
            assets: (root["assets"] as? [String] ?? []).map { URL(fileURLWithPath: $0) },
            warnings: root["warnings"] as? [String] ?? []
        )
    }

    /// Die Fehlermeldung aus einer misslungenen `--json`-Antwort.
    static func decodeError(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["ok"] as? Bool == false else { return nil }
        return root["error"] as? String
    }
}

/// Prüft die vom Werkzeug gemeldeten Pfade, BEVOR Fastra damit eine Datei
/// bewegt.
///
/// Die Antwort des Werkzeugs ist eine fremde Eingabe. Sie nennt einen
/// absoluten Pfad, und Fastra verschiebt danach genau diesen. Ungeprüft könnte
/// eine fehlerhafte oder manipulierte Antwort die Quelldatei selbst oder eine
/// beliebige andere erreichbare Datei verschieben und damit die zentrale
/// Zusage „Die Quelle wird nie verändert" brechen (Review 2026-08-02).
enum MarkdownImportOutputGuard {

    /// `true`, wenn `candidate` eine gewöhnliche Datei INNERHALB von
    /// `directory` ist.
    ///
    /// Beide Seiten werden vorher symbolisch aufgelöst. Das ist nicht
    /// übertriebene Vorsicht, sondern der Normalfall: Fastra übergibt
    /// `/var/folders/…` als Ausgabeordner, das Werkzeug meldet denselben Ort
    /// als `/private/var/folders/…` zurück. Ein reiner Textvergleich würde
    /// also die gültige Antwort abweisen.
    ///
    /// Der Kandidat selbst darf danach kein symbolischer Verweis mehr sein.
    /// Ein Verweis im Ausgabeordner könnte auf ein erlaubtes Ziel zeigen —
    /// verschoben würde aber der Verweis, und übrig bliebe neben der Quelle
    /// ein ins Leere zeigender Link, sobald das Zwischenverzeichnis weg ist.
    static func isPublishableFile(_ candidate: URL, in directory: URL) -> Bool {
        // Der Ausgabeordner selbst muss ein ECHTER Ordner sein. Fastra legt nur
        // das Zwischenverzeichnis an; `out` darin erzeugt das Werkzeug. Wäre
        // `out` ein Verweis auf einen fremden Ordner, zeigten unten beide
        // aufgelösten Pfade dorthin, der Präfixvergleich ginge auf und Fastra
        // holte eine beliebige fremde Datei — und entfernte sie an ihrem
        // Ursprungsort (Review 2026-08-06).
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR else { return false }

        let allowed = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(allowed + "/") else { return false }

        // `lstat` beschreibt den Pfad SELBST und folgt keinem Verweis —
        // genau die Auskunft, die hier gebraucht wird.
        var info = stat()
        guard lstat(candidate.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }
}

// MARK: - Zielname neben der Quelle

/// Bestimmt, wie das Ergebnis neben der Ursprungsdatei heißt.
///
/// Regel (Produktentscheidung 2026-07-26): Entstand NUR Markdown, liegt es als
/// `Name.md` direkt neben der Quelle. Entstanden zusätzlich Bilder, kommt alles
/// in den Ordner `Name` — benannt nach dem Dateinamen ohne Endung.
enum MarkdownImportNaming {

    /// Ist bereits etwas mit diesem Namen da, wird `-2`, `-3` … angehängt.
    /// Bestehendes wird NIE überschrieben: `Dokument.rtf` und `Dokument.docx`
    /// im selben Ordner wollen beide `Dokument.md` — der zweite bekommt
    /// `Dokument-2.md`.
    static func availableTarget(
        forSource sourceURL: URL,
        producesAssets: Bool,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = producesAssets ? nil : "md"

        var attempt = 1
        while true {
            let name = attempt == 1 ? stem : "\(stem)-\(attempt)"
            let candidate = target(named: name, extension: fileExtension, in: directory)
            if !exists(candidate) { return candidate }
            attempt += 1
            // Praktisch unerreichbar; verhindert nur eine Endlosschleife, falls
            // `exists` einmal dauerhaft `true` meldet.
            if attempt > 1000 { return candidate }
        }
    }

    /// Die Markdown-Datei, die nach der Umwandlung geöffnet wird. Im Ordnerfall
    /// liegt sie IM Ordner und behält den Namen der Quelle — der Ordner kann
    /// wegen einer Kollision `-2` heißen, die Datei darin nicht.
    static func markdownFile(inTarget target: URL, sourceURL: URL, producesAssets: Bool) -> URL {
        guard producesAssets else { return target }
        return target.appendingPathComponent(
            sourceURL.deletingPathExtension().lastPathComponent + ".md"
        )
    }

    private static func target(named name: String, extension fileExtension: String?,
                               in directory: URL) -> URL {
        guard let fileExtension else {
            return directory.appendingPathComponent(name, isDirectory: true)
        }
        return directory.appendingPathComponent("\(name).\(fileExtension)", isDirectory: false)
    }
}
