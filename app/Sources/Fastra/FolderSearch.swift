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

    /// Optionale Messwerte eines synchronen Diagnoselaufs; kein globaler Zustand.
    final class Diagnostics {
        let started = ProcessInfo.processInfo.systemUptime
        var enumerationSeconds: Double = 0
        var fileSearchSeconds: Double = 0
        var firstFileSearchSeconds: Double?
        var candidateCount = 0
        var searchedFiles = 0

        func beginFile() -> Double {
            let now = ProcessInfo.processInfo.systemUptime
            if firstFileSearchSeconds == nil { firstFileSearchSeconds = now - started }
            searchedFiles += 1
            return now
        }
    }

    // MARK: - Datenmodell

    /// Warum eine Datei nicht in die Suche eingegangen ist. Sichtbar
    /// im Ergebnis, damit der Nutzer sieht, was übersprungen wurde
    /// — stilles Überspringen wäre ein Sicherheits-Schluckauf
    /// (siehe ApplyEngine, gleiches Prinzip).
    enum SkipReason: Equatable {
        /// Null-Byte ohne BOM → wahrscheinlich binär, übersprungen.
        case binary
        /// Encoding ließ sich nicht erkennen.
        case undecodable
        /// Datei nicht lesbar (Rechte, kaputter Symlink, FIFO etc.).
        case unreadable
        /// Datei überschreitet die Sicherheitsgrenze für vollständige
        /// Reads (`FileSnapshot.maximumReadBytes`) und wird bewusst nicht
        /// in den Speicher geladen.
        case tooLarge
    }

    /// Ein einzelnes Such-Ergebnis pro Datei. Treffer kommen direkt aus
    /// `BufferSearch.Match` — die Maske kann denselben Highlight-Pfad
    /// nutzen wie für die Buffer-Suche.
    struct PerFileResult: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let matches: [BufferSearch.Match]
        /// Echte Trefferzahl in dieser Datei — kann `matches.count` übersteigen,
        /// wenn der Pro-Datei-Cap (`maxMatches`) gegriffen hat. `BufferSearch`
        /// zählt immer alle Treffer, materialisiert aber nur die ersten N
        /// (BBEdit-Verhalten: wahrer Count in der Statuszeile, gekürzte Liste).
        /// Für die Gesamt-Zählung verwenden, nicht `matches.count`.
        let totalMatches: Int
        let skipped: SkipReason?
        /// Exakte Dateibasis dieser sichtbaren Treffer. Apply akzeptiert nur
        /// dieselbe Basis und verlangt sonst eine neue Suche/Vorschau.
        let snapshot: FileSnapshot?
        /// Such-/Ersetzungssemantik, unter der diese Treffer entstanden sind.
        /// Sie schützt auch das kurze Debounce-Fenster nach einer UI-Änderung.
        let searchOptions: SearchOptions
        var isWritable = true

        var hasMatches: Bool { skipped == nil && !matches.isEmpty }

        static func == (lhs: PerFileResult, rhs: PerFileResult) -> Bool {
            lhs.url == rhs.url && lhs.matches == rhs.matches
                && lhs.totalMatches == rhs.totalMatches && lhs.skipped == rhs.skipped
                && lhs.snapshot == rhs.snapshot && lhs.searchOptions == rhs.searchOptions
                && lhs.isWritable == rhs.isWritable
        }
    }

    /// Gesamt-Ergebnis. Wenn das Find-Pattern syntaktisch kaputt ist,
    /// wird in jedem `perFile`-Eintrag das `skipped == nil` mit 0 Matches
    /// stehen und `invalidPatternMessage` enthält den Text — die Maske
    /// zeigt dieselbe Fehler-Anzeige wie bei der Buffer-Suche.
    ///
    /// `wasCapped`: `true`, wenn der Gesamt-Cap (`maxTotalMatches`) während
    /// der Enumeration ausgelöst hat und die Suche deshalb frühzeitig
    /// abgebrochen wurde. Die Maske zeigt in diesem Fall einen Hinweis,
    /// damit der Nutzer weiß, dass er nicht alle Treffer sieht.
    struct Result: Equatable {
        let perFile: [PerFileResult]
        let invalidPatternMessage: String?
        /// `true` = Gesamt-Cap wurde ausgelöst; Trefferliste ist unvollständig.
        let wasCapped: Bool
        var sourceBasis: SourceBasis? = nil

        static let empty = Result(perFile: [], invalidPatternMessage: nil, wasCapped: false)

        /// Summe der echten Per-Datei-Counts (nicht der materialisierten
        /// `matches.count`) — sonst untercountete eine Datei mit mehr Treffern
        /// als dem Pro-Datei-Cap.
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
    /// `folders` mit Tilde-Pfaden werden nicht expandiert — das ist
    /// Sache des Aufrufers (UserDefaults-Adapter macht das).
    ///
    /// `maxTotalMatches`: Gesamt-Cap über alle Dateien. Sobald die Summe
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
                     maxTotalMatches: Int = 10_000,
                     shouldCancel: @escaping @Sendable () -> Bool = { false }) -> Result {
        guard !options.isEmpty, !shouldCancel() else { return .empty }
        do {
            return find(
                in: folders, filter: filter,
                plan: try SearchPlan(options: options),
                excludedPatterns: excludedPatterns,
                relativeTo: projectRoot,
                maxResultsPerFile: maxResultsPerFile,
                maxTotalMatches: maxTotalMatches,
                shouldCancel: shouldCancel
            )
        } catch {
            let msg = (error as NSError).localizedDescription
            return Result(perFile: [], invalidPatternMessage: msg, wasCapped: false)
        }
    }

    /// Ordnersuche mit einem bereits kompilierten Plan. Der SearchRunner
    /// validiert damit einmal und reicht genau denselben Wert an den
    /// Hintergrundlauf weiter; direkte Engine-Aufrufer verwenden weiterhin
    /// den bequemen `options`-Wrapper.
    static func find(in folders: [URL],
                     filter: FileTypeFilter,
                     plan searchPlan: SearchPlan,
                     excludedPatterns: [String] = [],
                     relativeTo projectRoot: URL? = nil,
                     maxResultsPerFile: Int = 5000,
                     maxTotalMatches: Int = 10_000,
                     diagnostics: Diagnostics? = nil,
                     shouldCancel: @escaping @Sendable () -> Bool = { false }) -> Result {
        let options = searchPlan.options
        guard !options.isEmpty, !shouldCancel() else { return .empty }

        var perFile: [PerFileResult] = []
        // Laufende Summe aller Treffer über alle Dateien. Sobald der
        // Gesamt-Cap erreicht ist, wird die Enumeration abgebrochen.
        var totalSoFar = 0
        // Wurde der Cap während der Enumeration ausgelöst?
        var capped = false
        let selection = SourceSelection(roots: folders, filter: filter, exclusions: excludedPatterns,
                                        projectRoot: projectRoot)
        var textFiles: [URL: FileSnapshot] = [:]
        var scannedBytes: UInt64 = 0

        do {
            try selection.visitFiles(diagnostics: diagnostics, shouldCancel: shouldCancel) { url in
                // Der letzte gelesene Treffer zählt vollständig, auch wenn nur
                // ein Teil seiner Datei noch in die sichtbare Liste passt.
                let effectivePerFile = min(maxResultsPerFile, maxTotalMatches - totalSoFar)
                // Ohne lokalen Pool bleiben Foundation-Objekte eines langen
                // detached Tasks bis zum Laufende liegen.
                let fileStarted = diagnostics?.beginFile()
                let result = autoreleasepool {
                    searchOneFile(at: url, plan: searchPlan,
                                  maxMatches: effectivePerFile, shouldCancel: shouldCancel)
                }
                if let fileStarted {
                    diagnostics?.fileSearchSeconds += ProcessInfo.processInfo.systemUptime - fileStarted
                }
                if shouldCancel() { throw CancellationError() }
                if let snapshot = result.snapshot {
                    scannedBytes += UInt64(snapshot.byteCount)
                    if result.skipped == nil { textFiles[url] = snapshot }
                }
                // Leere und trefferlose Textdateien gehören zur Suchbasis,
                // aber nicht zur sichtbaren Trefferliste.
                if result.skipped != nil || !result.matches.isEmpty { perFile.append(result) }
                totalSoFar += result.totalMatches
                capped = totalSoFar >= maxTotalMatches
                return !capped
            }
        } catch is CancellationError {
            return .empty
        } catch SourceSelection.Failure.missingRoot(let folder) {
            return Result(perFile: [], invalidPatternMessage: L10n.format(
                "Die Suchquelle „%@“ fehlt oder ist nicht zugänglich. Die Suche ist unvollständig.", folder.lastPathComponent),
                wasCapped: false)
        } catch let failure as RipgrepFileEnumerator.Failure {
            return failedEnumerationResult(failure)
        } catch {
            return Result(perFile: [], invalidPatternMessage: L10n.format(
                "Die Ordnersuche konnte die Dateiliste nicht vollständig lesen: %@",
                error.localizedDescription), wasCapped: false)
        }
        let complete = !capped && perFile.allSatisfy { $0.skipped == nil || $0.skipped == .binary }
        return Result(perFile: perFile, invalidPatternMessage: nil, wasCapped: capped,
                      sourceBasis: complete ? SourceBasis(selection: selection, textFiles: textFiles,
                                                         scannedBytes: scannedBytes) : nil)
    }

    /// Dieselbe Pfadauswahl für den Suchlauf und seine spätere Prüfung.
    struct SourceSelection: Equatable, Sendable {
        enum Failure: Error { case missingRoot(URL) }

        let roots: [URL]
        let filter: FileTypeFilter
        let exclusions: [String]
        let projectRoot: URL?

        func visitFiles(diagnostics: Diagnostics? = nil,
                        shouldCancel: @escaping @Sendable () -> Bool,
                        visit: (URL) throws -> Bool) throws {
            // Überlappende Datei-Set-Wurzeln durchsuchen jede Datei nur einmal.
            var seenFiles = Set<String>()
            let exclusionMatcher = PathExclusion.Matcher(patterns: exclusions, relativeTo: projectRoot)
            for root in roots {
                if shouldCancel() { throw CancellationError() }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                    throw Failure.missingRoot(root)
                }
                let urls: [URL]
                if isDirectory.boolValue {
                    let started = diagnostics.map { _ in ProcessInfo.processInfo.systemUptime }
                    do {
                        urls = try RipgrepFileEnumerator.files(in: root, excludedPatterns: exclusions,
                                                               shouldCancel: shouldCancel)
                    } catch RipgrepFileEnumerator.Failure.unavailable {
                        // Abbruch, Timeout und unvollständige Ausgabe dürfen
                        // keinen zweiten Vollscan mit anderen Regeln auslösen.
                        urls = try legacyFileURLs(in: root, shouldCancel: shouldCancel)
                    }
                    if let started {
                        diagnostics?.enumerationSeconds += ProcessInfo.processInfo.systemUptime - started
                        diagnostics?.candidateCount += urls.count
                    }
                } else {
                    urls = [root]
                }

                var packageCache = PackageMembershipCache(root: root)
                for url in urls {
                    if shouldCancel() { throw CancellationError() }
                    // Billige Filter vor macOS-Metadatenabfragen anwenden.
                    guard !exclusionMatcher.matches(url), passesFilter(url: url, filter: filter) else { continue }
                    // ripgrep kennt macOS-Pakete nicht.
                    guard !isDirectory.boolValue || !packageCache.contains(url) else { continue }
                    // Navigation und Apply vergleichen dieselbe, bereits im
                    // Worker ermittelte kanonische Pfadform.
                    let canonical = url.canonicalFileURL
                    guard seenFiles.insert(canonical.path).inserted else { continue }
                    if try !visit(canonical) { return }
                }
            }
        }
    }

    /// Der bewusst schmale Fallback für Umgebungen, in denen der mitgelieferte
    /// ripgrep-Prozess nicht starten kann. Er bildet das frühere Verhalten
    /// nach: versteckte Dateien und Paket-Inhalte bleiben außen vor.
    private static func legacyFileURLs(
        in folder: URL,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> [URL] {
        var enumerationError: (any Error)?
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw SourceSelection.Failure.missingRoot(folder) }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if shouldCancel() { throw CancellationError() }
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                urls.append(url)
            }
        }
        if let enumerationError { throw enumerationError }
        return urls
    }

    private static func failedEnumerationResult(
        _ failure: RipgrepFileEnumerator.Failure
    ) -> Result {
        let message: String
        switch failure {
        case .timedOut:
            message = L10n.string(
                "Die Ordnersuche wurde beendet, weil ripgrep nicht rechtzeitig geantwortet hat.")
        case .outputLimit:
            message = L10n.string(
                "Die Ordnersuche wurde beendet, weil die ripgrep-Dateiliste zu groß war.")
        case .failed(let details), .captureFailed(let details):
            let explanation = details.isEmpty
                ? L10n.string("Unbekannter ripgrep-Fehler") : details
            message = L10n.format(
                "Die Ordnersuche konnte die Dateiliste nicht vollständig lesen: %@",
                explanation)
        case .unavailable, .cancelled:
            return .empty
        }
        return Result(perFile: [], invalidPatternMessage: message, wasCapped: false)
    }

    /// Merkt für jeden Elternordner, ob er selbst oder ein Vorfahr unterhalb
    /// der Suchwurzel ein macOS-Paket ist. So kostet ein Ordner mit tausenden
    /// Dateien nur eine `resourceValues`-Abfrage statt tausender identischer.
    struct PackageMembershipCache {
        let rootPath: String
        var membershipByDirectory: [String: Bool] = [:]

        init(root: URL) {
            rootPath = root.standardizedFileURL.path
        }

        mutating func contains(_ file: URL) -> Bool {
            containsDirectory(file.deletingLastPathComponent().standardizedFileURL)
        }

        private mutating func containsDirectory(_ directory: URL) -> Bool {
            let path = directory.standardizedFileURL.path
            let prefix = rootPath == "/" ? "/" : rootPath + "/"
            guard path == rootPath || path.hasPrefix(prefix) else { return false }
            if let cached = membershipByDirectory[path] { return cached }

            let directoryIsPackage =
                (try? directory.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
            let result: Bool
            if directoryIsPackage {
                result = true
            } else if path == rootPath {
                result = false
            } else {
                result = containsDirectory(directory.deletingLastPathComponent())
            }
            membershipByDirectory[path] = result
            return result
        }
    }

    /// Sucht in genau einer Datei. Liest die Datei, dekodiert sie
    /// (BOM zuerst, dann UTF-8 beziehungsweise die gemeinsame
    /// CP1252/Latin-1-Heuristik aus `ApplyEngine`), und ruft `BufferSearch.find`
    /// auf dem dekodierten String. Auf großen Dateien mit vielen Treffern
    /// kappt `maxMatches` die Liste, damit der UI-Speicher nicht explodiert.
    static func searchOneFile(at url: URL,
                              options: SearchOptions,
                              maxMatches: Int = 5000,
                              shouldCancel: () -> Bool = { false }) -> PerFileResult {
        guard let plan = try? SearchPlan(options: options) else {
            return PerFileResult(url: url, matches: [], totalMatches: 0,
                                 skipped: nil, snapshot: nil,
                                 searchOptions: options)
        }
        return searchOneFile(at: url, plan: plan, maxMatches: maxMatches,
                             shouldCancel: shouldCancel)
    }

    /// Einzeldateipfad eines bereits vorbereiteten Ordnerlaufs. Der äußere
    /// `find`-Aufruf reicht denselben Plan für jede Datei herein.
    static func searchOneFile(at url: URL,
                              plan: SearchPlan,
                              maxMatches: Int = 5000,
                              shouldCancel: () -> Bool = { false }) -> PerFileResult {
        let options = plan.options
        if shouldCancel() {
            return PerFileResult(url: url, matches: [], totalMatches: 0,
                                 skipped: nil, snapshot: nil,
                                 searchOptions: options)
        }
        let read: (data: Data, snapshot: FileSnapshot)
        do {
            // Treffer müssen anschließend im normalen Texteditor navigierbar
            // sein. Dessen Volllade-Grenze ist daher auch die Suchgrenze;
            // Dateien zwischen 32 und 256 MiB erschienen früher als Treffer,
            // ließen sich aber nur abschnittsweise und damit nie am Treffer
            // öffnen.
            read = try FileSnapshot.read(
                from: url, byteLimit: FileLoader.largeFileThreshold, isCancelled: shouldCancel)
        } catch FileSnapshotReadError.tooLarge {
            // Bewusst eigener Grund statt „unlesbar": Die Datei existiert und
            // wäre lesbar, sie ist nur größer als die Speicher-Grenze.
            return PerFileResult(url: url, matches: [], totalMatches: 0,
                                 skipped: .tooLarge, snapshot: nil,
                                 searchOptions: options)
        } catch {
            return PerFileResult(url: url, matches: [], totalMatches: 0,
                                 skipped: .unreadable, snapshot: nil,
                                 searchOptions: options)
        }
        if shouldCancel() {
            return PerFileResult(url: url, matches: [], totalMatches: 0,
                                 skipped: nil, snapshot: nil,
                                 searchOptions: options)
        }
        let text: String
        switch classify(read.data) {
        case .text(let decoded):
            text = decoded
        case .binary:
            return PerFileResult(url: url, matches: [], totalMatches: 0,
                                 skipped: .binary, snapshot: read.snapshot,
                                 searchOptions: options)
        case .undecodable:
            return PerFileResult(url: url, matches: [], totalMatches: 0,
                                 skipped: .undecodable, snapshot: read.snapshot,
                                 searchOptions: options)
        }
        // Pro-Datei-Cap direkt an find() geben — sonst griffe dort der
        // niedrigere Default-Cap und schnitte Treffer unter den vom Ordner-
        // Lauf vorgesehenen Rest-bis-Gesamtcap. `prefix` bleibt als Gürtel.
        let search = BufferSearch.find(in: text, plan: plan,
                                       maxMatches: maxMatches,
                                       shouldCancel: shouldCancel)
        let capped = Array(search.matches.prefix(maxMatches))
        // `search.totalMatches` ist die echte Trefferzahl (zählt alle, auch über
        // dem Cap) — als wahren Per-Datei-Count durchreichen, damit die Gesamt-
        // Statistik bei >maxMatches-Dateien nicht untercountet. `matches`/`capped`
        // bleiben materialisiert begrenzt (UI-Speicher).
        return PerFileResult(url: url, matches: capped,
                             totalMatches: search.totalMatches, skipped: nil,
                             snapshot: read.snapshot, searchOptions: options,
                             isWritable: ApplyEngine.isWritableTarget(url))
    }

    enum FileContent {
        case text(String), binary, undecodable
    }

    static func classify(_ data: Data) -> FileContent {
        let (bom, bomEncoding) = ApplyEngine.detectBOM(in: data)
        // Dieselben Bytes müssen im Editor als Text öffnen. Eine UTF-8-BOM
        // erklärt keine Nullbytes im Inhalt.
        if !FileLoader.bomEncodingAllowsNUL(bomEncoding) && data.contains(0) { return .binary }
        guard let decoded = ApplyEngine.decode(payload: Data(data.dropFirst(bom.count)),
                                               bomEncoding: bomEncoding) else { return .undecodable }
        return .text(decoded.0)
    }
}

/// Projekt-relative Glob-Ausschlüsse. Ein Muster ohne Slash gilt für jede
/// Pfadkomponente (`build`, `*.generated.swift`); mit Slash für den gesamten
/// relativen Pfad. Unterstützt `*`, `?` und `**`.
enum PathExclusion {
    /// Ein pro Suchlauf wiederverwendbarer Satz kompilierter Ausschlüsse.
    struct Matcher {
        private struct Rule {
            let matchesWholeRelativePath: Bool
            let expression: NSRegularExpression

            func matches(_ value: String) -> Bool {
                // Verzeichnislisten können zerlegte Zeichen liefern,
                // Eingabemuster zusammengesetzte. Beide Schreibweisen
                // müssen dieselben Ausschlüsse treffen.
                let candidate = value.precomposedStringWithCanonicalMapping
                let range = NSRange(location: 0, length: (candidate as NSString).length)
                return expression.firstMatch(in: candidate, range: range) != nil
            }
        }

        private let rootPath: String?
        private let rules: [Rule]

        init(patterns: [String], relativeTo root: URL?) {
            rootPath = root?.standardizedFileURL.path
            rules = patterns.compactMap { raw in
                guard let pattern = PathExclusion.normalizedPattern(raw) else { return nil }
                let regex = PathExclusion.regularExpression(for: pattern.precomposedStringWithCanonicalMapping)
                return Rule(
                    matchesWholeRelativePath: pattern.contains("/"),
                    expression: try! NSRegularExpression(pattern: regex)
                )
            }
        }

        func matches(_ url: URL) -> Bool {
            guard !rules.isEmpty else { return false }
            let relative: String
            if let rootPath {
                let path = url.standardizedFileURL.path
                let prefix = rootPath == "/" ? "/" : rootPath + "/"
                guard path == rootPath || path.hasPrefix(prefix) else { return false }
                relative = path == rootPath
                    ? "" : String(path.dropFirst(prefix.count))
            } else {
                relative = url.lastPathComponent
            }
            let components = relative.split(separator: "/").map(String.init)
            return rules.contains { rule in
                if rule.matchesWholeRelativePath {
                    return rule.matches(relative)
                }
                return components.contains(where: rule.matches)
            }
        }
    }

    static func matches(_ url: URL, patterns: [String], relativeTo root: URL?) -> Bool {
        Matcher(patterns: patterns, relativeTo: root).matches(url)
    }

    /// Sichere ripgrep-Negativglobs für komponentenbezogene Muster. Pfad-
    /// muster mit Slash bleiben ausschließlich im projekt-relativen Fastra-
    /// Matcher. Ebenso bleiben Zeichen draußen, deren Glob-Bedeutung (`[]`,
    /// `{}` usw.) von Fastras bewusst kleiner Syntax abweicht.
    static func ripgrepExclusionGlobs(for patterns: [String]) -> [String] {
        let unsafe = CharacterSet(charactersIn: "/[]{}\\!")
        var result: [String] = []
        var seen = Set<String>()
        for raw in patterns {
            guard let pattern = normalizedPattern(raw),
                  pattern.rangeOfCharacter(from: unsafe) == nil else { continue }
            for glob in ["!**/\(pattern)", "!**/\(pattern)/**"]
            where seen.insert(glob).inserted {
                result.append(glob)
            }
        }
        return result
    }

    static func glob(_ pattern: String, matches value: String) -> Bool {
        guard let normalized = normalizedPattern(pattern) else { return false }
        let regex = regularExpression(for: normalized)
        return value.range(of: regex, options: .regularExpression) != nil
    }

    /// `.json` ist die nutzerfreundliche Kurzform für `*.json`. Dieselbe
    /// Regel lässt `.git` und `.build` als Ordnerkomponenten weiterarbeiten.
    private static func normalizedPattern(_ raw: String) -> String? {
        let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return nil }
        if pattern.count > 1,
           pattern.hasPrefix("."),
           !pattern.contains("/"),
           !pattern.contains("*"),
           !pattern.contains("?") {
            return "*" + pattern
        }
        return pattern
    }

    private static func regularExpression(for pattern: String) -> String {
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
        return regex
    }
}
