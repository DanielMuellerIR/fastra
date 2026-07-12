// FolderSearch.swift
//
// Such-Modul für den Ordner-Scope. Iteriert rekursiv über alle aktivierten
// Ordner, dekodiert jede Datei (BOM-Erkennung vor Null-Byte-Heuristik —
// dieselbe Logik wie ApplyEngine), filtert nach Dateityp und ruft pro
// Textdatei `BufferSearch.find` auf.
//
// Bewusst pur und synchron implementiert: die teure Folder-Iteration
// passiert in `Task.detached` (Aufrufer-Seite), die Logik hier ist
// damit voll testbar — Korpus aufbauen, `find(in:filter:options:)`
// aufrufen, Ergebnis prüfen.

import Foundation

enum FolderSearch {

    // MARK: - Datenmodell

    /// Warum eine Datei nicht in die Suche eingegangen ist. Sichtbar
    /// im Ergebnis, damit der Nutzer SIEHT, was übersprungen wurde
    /// — stilles Überspringen wäre ein Sicherheits-Schluckauf
    /// (siehe ApplyEngine, gleiches Prinzip).
    enum SkipReason: Equatable {
        /// Null-Byte ohne BOM → wahrscheinlich binär, übersprungen.
        case binary
        /// Encoding ließ sich nicht erkennen.
        case undecodable
        /// Datei nicht lesbar (Rechte, kaputter Symlink etc.).
        case unreadable
        /// Wurde durch den `FileTypeFilter` ausgeschlossen.
        case excludedByFilter
    }

    /// Ein einzelnes Such-Ergebnis pro Datei. Treffer kommen direkt aus
    /// `BufferSearch.Match` — die Maske kann denselben Highlight-Pfad
    /// nutzen wie für die Buffer-Suche.
    struct PerFileResult: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let matches: [BufferSearch.Match]
        /// ECHTE Trefferzahl in dieser Datei — kann `matches.count` ÜBERSTEIGEN,
        /// wenn der Pro-Datei-Cap (`maxMatches`) gegriffen hat. `BufferSearch`
        /// zählt immer ALLE Treffer, materialisiert aber nur die ersten N
        /// (BBEdit-Verhalten: wahrer Count in der Statuszeile, gekürzte Liste).
        /// Für die Gesamt-Zählung verwenden, NICHT `matches.count`.
        let totalMatches: Int
        let skipped: SkipReason?

        var hasMatches: Bool { skipped == nil && !matches.isEmpty }

        static func == (lhs: PerFileResult, rhs: PerFileResult) -> Bool {
            lhs.url == rhs.url && lhs.matches == rhs.matches
                && lhs.totalMatches == rhs.totalMatches && lhs.skipped == rhs.skipped
        }
    }

    /// Gesamt-Ergebnis. Wenn das Find-Pattern syntaktisch kaputt ist,
    /// wird in jedem `perFile`-Eintrag das `skipped == nil` mit 0 Matches
    /// stehen UND `invalidPatternMessage` enthält den Text — die Maske
    /// zeigt dieselbe Fehler-Anzeige wie bei der Buffer-Suche.
    ///
    /// `wasCapped`: `true`, wenn der Gesamt-Cap (`maxTotalMatches`) während
    /// der Enumeration ausgelöst hat und die Suche deshalb frühzeitig
    /// abgebrochen wurde. Die Maske zeigt in diesem Fall einen Hinweis,
    /// damit der Nutzer weiß, dass er NICHT alle Treffer sieht.
    struct Result: Equatable {
        let perFile: [PerFileResult]
        let invalidPatternMessage: String?
        /// `true` = Gesamt-Cap wurde ausgelöst; Trefferliste ist unvollständig.
        let wasCapped: Bool

        static let empty = Result(perFile: [], invalidPatternMessage: nil, wasCapped: false)

        /// Summe der ECHTEN Per-Datei-Counts (nicht der materialisierten
        /// `matches.count`) — sonst untercountete eine Datei mit mehr Treffern
        /// als dem Pro-Datei-Cap (Review-Befund 2026-06-23).
        var totalMatches: Int { perFile.reduce(0) { $0 + $1.totalMatches } }
        var filesWithMatches: [PerFileResult] { perFile.filter(\.hasMatches) }
    }

    // MARK: - Datei-Typ-Filter

    /// Whitelist gängiger Text-Dateiendungen. Bewusst eng — der Filter
    /// soll Binärformate (PDF, Bilder, Office-ZIPs) zuverlässig draußen
    /// halten, nicht jede exotische Endung einsammeln. Erweiterbar
    /// (später konfigurierbar pro Nutzer in v1.1+).
    static let knownTextExtensions: Set<String> = [
        "txt", "md", "markdown", "rst", "log",
        "swift", "py", "rb", "js", "ts", "tsx", "jsx", "mjs", "cjs",
        "java", "kt", "kts", "go", "rs", "c", "cc", "cpp", "h", "hpp",
        "m", "mm", "cs", "php", "lua", "pl", "r", "scala",
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd",
        "html", "htm", "xhtml", "xml", "css", "scss", "sass", "less", "vue", "svelte",
        "json", "jsonl", "yaml", "yml", "toml", "ini", "conf", "env",
        "csv", "tsv", "tab",
        "sql", "graphql", "gql",
        "gitignore", "gitattributes", "dockerignore", "editorconfig",
        "tex", "bib", "rtf", "adoc", "asciidoc",
    ]

    /// Entscheidet, ob eine Datei den `FileTypeFilter` passiert. Dateien
    /// ohne Endung werden im `knownText`-Modus konservativ ausgeschlossen
    /// — die meisten dieser Dateien sind Binär-Artefakte (`.DS_Store`,
    /// Mach-O-Executables ohne Suffix). Im `all`-Modus passiert alles
    /// die Filterstufe, die Binär-Heuristik fängt den Rest später ab.
    static func passesFilter(url: URL, filter: FileTypeFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .knownText:
            let ext = url.pathExtension.lowercased()
            if ext.isEmpty { return false }
            return knownTextExtensions.contains(ext)
        }
    }

    // MARK: - Haupt-Entry-Point

    /// Sucht in allen übergebenen Ordnern rekursiv und liefert ein
    /// `Result`. Reihenfolge: pro Ordner, pro Datei in `enumerator`-
    /// Reihenfolge (≈ alphabetisch je nach Dateisystem). Übergebene
    /// `folders` mit Tilde-Pfaden werden NICHT expandiert — das ist
    /// Sache des Aufrufers (UserDefaults-Adapter macht das).
    ///
    /// `maxTotalMatches`: Gesamt-Cap über ALLE Dateien. Sobald die Summe
    /// aller bisherigen Treffer den Cap erreicht, bricht die Enumeration
    /// sauber ab (keine weiteren Dateien werden gelesen). Das verhindert
    /// Freeze und Speicher-Explosion bei kurzen Patterns in riesigen Repos.
    /// Im Ergebnis signalisiert `wasCapped == true`, dass die Liste
    /// unvollständig ist (sichtbarer Hinweis in der Maske — keine silent
    /// truncation).
    static func find(in folders: [URL],
                     filter: FileTypeFilter,
                     options: SearchOptions,
                     excludedPatterns: [String] = [],
                     relativeTo projectRoot: URL? = nil,
                     maxResultsPerFile: Int = 5000,
                     maxTotalMatches: Int = 10_000) -> Result {
        guard !options.isEmpty else { return .empty }

        // Pattern einmal kompilieren — wenn syntaktisch ungültig, bricht
        // das Ergebnis sauber mit einer Meldung ab.
        do {
            _ = try ApplyEngine.buildRegex(options)
        } catch {
            let msg = (error as NSError).localizedDescription
            return Result(perFile: [], invalidPatternMessage: msg, wasCapped: false)
        }

        var perFile: [PerFileResult] = []
        // Laufende Summe aller Treffer über alle Dateien. Sobald der
        // Gesamt-Cap erreicht ist, wird die Enumeration abgebrochen.
        var totalSoFar = 0
        // Wurde der Cap während der Enumeration ausgelöst?
        var capped = false
        // Überlappende Datei-Set-Wurzeln (z. B. „.“ und „Sources“) dürfen
        // dieselbe Datei nicht zweimal durchsuchen oder ersetzen.
        var seenFiles = Set<String>()

        outerLoop:
        for folder in folders {
            let fm = FileManager.default
            var rootIsDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &rootIsDirectory) else {
                continue
            }
            // Datei-Sets dürfen neben Ordnern auch einzelne Dateien enthalten.
            if !rootIsDirectory.boolValue {
                guard !PathExclusion.matches(folder, patterns: excludedPatterns,
                                             relativeTo: projectRoot),
                      passesFilter(url: folder, filter: filter),
                      seenFiles.insert(folder.canonicalFileURL.path).inserted else { continue }
                let result = searchOneFile(at: folder, options: options,
                                           maxMatches: min(maxResultsPerFile,
                                                           maxTotalMatches - totalSoFar))
                if result.skipped != nil || !result.matches.isEmpty { perFile.append(result) }
                totalSoFar += result.totalMatches
                if totalSoFar >= maxTotalMatches { capped = true; break outerLoop }
                continue
            }
            guard let enumerator = fm.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                if PathExclusion.matches(url, patterns: excludedPatterns,
                                         relativeTo: projectRoot) {
                    if values?.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                let isFile = values?.isRegularFile ?? false
                guard isFile else { continue }
                guard seenFiles.insert(url.canonicalFileURL.path).inserted else { continue }
                if !passesFilter(url: url, filter: filter) {
                    // Filter-Skips werden NICHT ins Ergebnis aufgenommen
                    // (zu viel Lärm in jeder Liste). Bei Bedarf einklappbar
                    // später anzeigen — für jetzt still überspringen.
                    continue
                }

                // Datei durchsuchen. Der effektive Pro-Datei-Cap ist das
                // Minimum aus `maxResultsPerFile` und dem noch verfügbaren
                // Rest bis zum Gesamt-Cap — so wird die Datei nie über den
                // Gesamt-Cap hinaus gelesen (vermeidet unnötige Arbeit UND
                // stellt sicher, dass totalMatches nach dem Cap-Abbruch
                // tatsächlich ≤ maxTotalMatches ist).
                let remaining = maxTotalMatches - totalSoFar
                let effectivePerFile = min(maxResultsPerFile, remaining)
                let result = searchOneFile(at: url, options: options,
                                           maxMatches: effectivePerFile)

                // Nur Dateien aufnehmen, die entweder Treffer ODER einen
                // ernsthaften Skip-Grund (binary/undecodable/unreadable)
                // haben — sonst wäre die Liste voller leerer Einträge.
                if result.skipped != nil || !result.matches.isEmpty {
                    perFile.append(result)
                }

                // Gesamt-Cap prüfen. Skip-Einträge (binär etc.) haben 0 Treffer
                // → addieren sicher, ohne die Zählung zu verfälschen.
                // WICHTIG: den WAHREN Per-Datei-Count zählen (`totalMatches`),
                // nicht die materialisierte, per-Datei gekappte Liste
                // (`matches.count`) — sonst rechnet der Gesamt-Cap bei Dateien
                // über dem Pro-Datei-Cap zu klein und liest Folgedateien,
                // obwohl das Limit längst überschritten ist (Review 2026-07-03).
                totalSoFar += result.totalMatches
                if totalSoFar >= maxTotalMatches {
                    // Cap ausgelöst: Enumeration sauber abbrechen. Keine
                    // weiteren Dateien lesen — das ist der Kern des
                    // Freeze-Schutzes. Das bisherige Ergebnis bleibt gültig.
                    capped = true
                    break outerLoop
                }
            }
        }
        return Result(perFile: perFile, invalidPatternMessage: nil, wasCapped: capped)
    }

    /// Sucht in genau einer Datei. Liest die Datei, dekodiert sie
    /// (BOM zuerst, dann UTF-8/Latin-1/Win-1252 in dieser Reihenfolge —
    /// identisch zu `ApplyEngine.planSingle`), und ruft `BufferSearch.find`
    /// auf dem dekodierten String. Auf großen Dateien mit vielen Treffern
    /// kappt `maxMatches` die Liste, damit der UI-Speicher nicht explodiert.
    static func searchOneFile(at url: URL,
                              options: SearchOptions,
                              maxMatches: Int = 5000) -> PerFileResult {
        guard let data = try? Data(contentsOf: url) else {
            return PerFileResult(url: url, matches: [], totalMatches: 0, skipped: .unreadable)
        }
        let (bom, bomEncoding) = ApplyEngine.detectBOM(in: data)
        // BOM-freie Datei mit Null-Byte → binär, übersprungen.
        if bom.isEmpty && FileScanner.isBinary(data) {
            return PerFileResult(url: url, matches: [], totalMatches: 0, skipped: .binary)
        }
        let payload = Data(data.dropFirst(bom.count))
        guard let decoded = ApplyEngine.decode(payload: payload, bomEncoding: bomEncoding) else {
            return PerFileResult(url: url, matches: [], totalMatches: 0, skipped: .undecodable)
        }
        // Pro-Datei-Cap direkt an find() geben — sonst griffe dort der
        // niedrigere Default-Cap und schnitte Treffer unter den vom Ordner-
        // Lauf vorgesehenen Rest-bis-Gesamtcap. `prefix` bleibt als Gürtel.
        let search = BufferSearch.find(in: decoded.0, options: options, maxMatches: maxMatches)
        let capped = Array(search.matches.prefix(maxMatches))
        // `search.totalMatches` ist die ECHTE Trefferzahl (zählt alle, auch über
        // dem Cap) — als wahren Per-Datei-Count durchreichen, damit die Gesamt-
        // Statistik bei >maxMatches-Dateien nicht untercountet. `matches`/`capped`
        // bleiben materialisiert begrenzt (UI-Speicher).
        return PerFileResult(url: url, matches: capped,
                             totalMatches: search.totalMatches, skipped: nil)
    }
}

/// Projekt-relative Glob-Ausschlüsse. Ein Muster ohne Slash gilt für jede
/// Pfadkomponente (`build`, `*.generated.swift`); mit Slash für den gesamten
/// relativen Pfad. Unterstützt `*`, `?` und `**`.
enum PathExclusion {
    static func matches(_ url: URL, patterns: [String], relativeTo root: URL?) -> Bool {
        guard !patterns.isEmpty else { return false }
        let relative: String
        if let root {
            let rootPath = root.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            guard path == rootPath || path.hasPrefix(rootPath + "/") else { return false }
            relative = path == rootPath ? "" : String(path.dropFirst(rootPath.count + 1))
        } else {
            relative = url.lastPathComponent
        }
        let components = relative.split(separator: "/").map(String.init)
        return patterns.contains { raw in
            let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { return false }
            if pattern.contains("/") {
                return glob(pattern, matches: relative)
            }
            return components.contains { glob(pattern, matches: $0) }
        }
    }

    static func glob(_ pattern: String, matches value: String) -> Bool {
        var regex = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let char = pattern[index]
            if char == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    regex += ".*"
                    index = pattern.index(after: next)
                } else {
                    regex += "[^/]*"
                    index = next
                }
            } else if char == "?" {
                regex += "[^/]"
                index = pattern.index(after: index)
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(char))
                index = pattern.index(after: index)
            }
        }
        regex += "$"
        return value.range(of: regex, options: .regularExpression) != nil
    }
}
