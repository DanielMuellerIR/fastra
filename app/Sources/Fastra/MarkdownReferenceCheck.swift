import Darwin
import Foundation

enum MarkdownReferenceCheck {
    struct Options: Sendable {
        var maximumFiles = 200
        var maximumBytes = 64 * 1024 * 1024
        var maximumReferences = 10_000
        var excludedPatterns: [String] = []
    }

    struct Source: Identifiable, Sendable {
        let id: UUID
        let documentID: UUID?
        let contentRevision: UInt64?
        let url: URL?
        let title: String
        let content: String
        let snapshot: FileSnapshot?

        init(id: UUID = UUID(), documentID: UUID? = nil, contentRevision: UInt64? = nil,
             url: URL?, title: String, content: String, snapshot: FileSnapshot? = nil) {
            self.id = id; self.documentID = documentID; self.url = url
            self.contentRevision = contentRevision
            self.title = title; self.content = content; self.snapshot = snapshot
        }
    }

    enum Status: String, Sendable, CaseIterable {
        case valid, missing, ambiguous, unverified
        var title: String {
            switch self {
            case .valid: L10n.string("Ziel vorhanden")
            case .missing: L10n.string("Ziel fehlt")
            case .ambiguous: L10n.string("Anker mehrdeutig")
            case .unverified: L10n.string("Nicht prüfbar")
            }
        }
    }

    struct Finding: Identifiable, Sendable {
        let id = UUID()
        let sourceID: UUID
        let reference: MarkdownReferences.Reference
        let status: Status
        let message: String
    }

    struct Report: Sendable {
        var sources: [Source] = []
        var findings: [Finding] = []
        var issues: [String] = []
        var remoteCount = 0
        var isComplete = true
        var readBytes = 0
        var projectRoot: URL?
        var completedAt = Date()
    }

    struct Progress: Sendable {
        let files: Int
        let references: Int
        let title: String
    }

    static func check(document: Source, openDocuments: [Source] = [], project: URL? = nil,
                      options: Options = Options(), isCancelled: @escaping @Sendable () -> Bool = { false },
                      progress: (Progress) -> Void = { _ in }) throws -> Report {
        var report = Report()
        var parsedBySource: [UUID: MarkdownReferences.Parsed] = [:]
        var parsedByPath: [Data: MarkdownReferences.Parsed] = [:]
        var parsedByIdentity: [FileIdentity: MarkdownReferences.Parsed] = [:]
        var readBytes = project == nil ? document.content.utf8.count : 0
        var chargedSources: Set<UUID> = project == nil ? [document.id] : []
        var retainedReferences = 0
        var retainedAnchors = 0
        var parsedFiles = 0
        let localPaths = LocalMarkdownPath()
        var lastProgress = 0.0
        func publishProgress(files: Int, references: Int, title: String) {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastProgress >= 0.05 else { return }
            lastProgress = now
            progress(Progress(files: files, references: references, title: title))
        }
        func issue(_ value: String) {
            report.isComplete = false
            if report.issues.count < 20 { report.issues.append(value) }
        }
        func cancelled() throws { if isCancelled() { throw CancellationError() } }
        func pathKey(_ url: URL) -> Data { Data(((try? localPaths.resolve(url)) ?? url).path.utf8) }
        func parseSource(_ source: Source) throws -> MarkdownReferences.Parsed {
            let bytes = source.content.utf8.count
            guard bytes <= MarkdownReferences.maximumSourceBytes, readBytes <= options.maximumBytes,
                  chargedSources.contains(source.id) || bytes <= options.maximumBytes - readBytes else { throw FileSnapshotReadError.tooLarge(byteCount: UInt64(bytes)) }
            if chargedSources.insert(source.id).inserted { readBytes += bytes }
            parsedFiles += 1
            let remaining = max(0, options.maximumReferences - retainedReferences)
            let parsed = try MarkdownReferences.parse(source.content, maximumReferences: remaining,
                maximumAnchors: max(0, 10_000 - retainedAnchors), isCancelled: isCancelled)
            retainedReferences += parsed.references.count
            retainedAnchors += parsed.anchorCount
            return parsed
        }
        func readSource(_ candidate: URL) throws -> Source {
            try cancelled()
            let url = try localPaths.resolve(candidate)
            guard (try url.resourceValues(forKeys: [.volumeIsLocalKey])).volumeIsLocal == true else { throw CocoaError(.fileReadUnsupportedScheme) }
            let remaining = max(0, options.maximumBytes - readBytes)
            let read = try FileSnapshot.read(from: url, byteLimit: UInt64(min(MarkdownReferences.maximumSourceBytes, remaining)))
            readBytes += read.data.count
            try cancelled()
            let (bom, encoding) = ApplyEngine.detectBOM(in: read.data)
            let payload = Data(read.data.dropFirst(bom.count))
            guard encoding != nil || !payload.contains(0),
                  let (content, _) = ApplyEngine.decode(payload: payload, bomEncoding: encoding) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            let source = Source(url: url, title: url.lastPathComponent, content: content, snapshot: read.snapshot)
            chargedSources.insert(source.id)
            return source
        }
        var candidates: [Source] = project == nil ? [document] : []
        var candidateBytes = project == nil ? document.content.utf8.count : 0
        if let project {
            try cancelled()
            do {
                let root = try localPaths.resolve(project)
                report.projectRoot = root
                guard (try root.resourceValues(forKeys: [.volumeIsLocalKey])).volumeIsLocal == true else { throw CocoaError(.fileReadUnsupportedScheme) }
                let matcher = PathExclusion.Matcher(patterns: options.excludedPatterns, relativeTo: root)
                let paths = try RipgrepFileEnumerator.files(in: root, timeout: 15,
                    outputLimit: GitOutputLimit(stdoutBytes: 4 * 1024 * 1024, stderrBytes: 64 * 1024),
                    excludedPatterns: options.excludedPatterns, shouldCancel: isCancelled)
                var seen = Set<Data>()
                var opened = Dictionary(openDocuments.compactMap { source in source.url.map { (pathKey($0), source) } }, uniquingKeysWith: { first, _ in first })
                if let url = document.url { opened[pathKey(url)] = document }
                var packages = FolderSearch.PackageMembershipCache(root: root)
                for path in paths.sorted(by: { $0.path < $1.path }) {
                    try cancelled()
                    let key = pathKey(path)
                    guard MarkdownReferences.markdownExtensions.contains(path.pathExtension.lowercased()) || opened[key] != nil,
                          !matcher.matches(path), !packages.contains(path) else { continue }
                    // Der vorhandene rg-Pfad folgt keinen Verzeichnislinks.
                    // Auch einzelne Linkquellen gehören nicht zum Projekt-Scan.
                    var info = stat()
                    guard lstat(path.path, &info) == 0 else { issue(L10n.format("Quelle konnte nicht geprüft werden: %@", path.path)); continue }
                    guard info.st_mode & S_IFMT == S_IFREG else { continue }
                    guard seen.insert(key).inserted else { continue }
                    guard candidates.count < options.maximumFiles else { issue(L10n.string("Die Grenze der Markdown-Dateien wurde erreicht.")); break }
                    do {
                        let source = try opened[key] ?? readSource(path)
                        if !chargedSources.contains(source.id), source.content.utf8.count > options.maximumBytes - readBytes {
                            issue(L10n.string("Das Lesebudget für Markdown-Quellen wurde erreicht.")); break
                        }
                        guard source.content.utf8.count <= options.maximumBytes - candidateBytes else {
                            issue(L10n.string("Das Lesebudget für Markdown-Quellen wurde erreicht.")); break
                        }
                        candidateBytes += source.content.utf8.count
                        if chargedSources.insert(source.id).inserted { readBytes += source.content.utf8.count }
                        candidates.append(source)
                    } catch is CancellationError { throw CancellationError() }
                    catch { issue(L10n.format("Quelle „%@“ konnte nicht geprüft werden: %@", path.path, explanation(error))) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch RipgrepFileEnumerator.Failure.cancelled { throw CancellationError() }
            catch { issue(L10n.format("Die Projektdateiliste ist unvollständig: %@", explanation(error))) }
        }
        // Erst alle Quellbasen festhalten. Verweise zwischen ungesicherten
        // offenen Projektdateien prüfen dadurch dieselben sichtbaren Fassungen.
        for source in candidates {
            try cancelled()
            publishProgress(files: report.sources.count, references: 0, title: source.title)
            do {
                let parsed = try parseSource(source)
                report.sources.append(source); parsedBySource[source.id] = parsed
                if let url = source.url {
                    parsedByPath[pathKey(url)] = parsed
                    var info = stat()
                    if let resolved = try? localPaths.resolve(url), stat(resolved.path, &info) == 0 { parsedByIdentity[FileIdentity(stat: info)] = parsed }
                }
                if parsed.incomplete { issue(L10n.string("Die Grenze der Verweise oder Anker wurde erreicht.")) }
                if parsed.unsupportedHTML { issue(L10n.format("Nicht unterstützte HTML-Verweise in „%@“ bleiben ungeprüft.", source.title)) }
            } catch is CancellationError { throw CancellationError() }
            catch { issue(L10n.format("Quelle „%@“ konnte nicht geprüft werden: %@", source.title, explanation(error))) }
        }
        var count = 0
        for source in report.sources {
            for reference in parsedBySource[source.id]?.references ?? [] {
                try cancelled()
                guard count < options.maximumReferences else { issue(L10n.string("Die Grenze der Verweise wurde erreicht.")); break }
                count += 1
                func add(_ status: Status, _ message: String) {
                    report.findings.append(Finding(sourceID: source.id, reference: reference, status: status, message: message))
                    if status == .unverified { report.isComplete = false }
                }
                switch MarkdownReferences.destination(reference.destination, documentURL: source.url) {
                case .remote: report.remoteCount += 1
                case .invalid: add(.unverified, L10n.string("Der lokale Pfad oder Anker ist ungültig codiert."))
                case .local(let url, let anchor):
                    if reference.destination.hasPrefix("#") || reference.destination.isEmpty {
                        checkAnchor(anchor, parsed: parsedBySource[source.id], add: add)
                        continue
                    }
                    guard let candidate = url else { add(.unverified, L10n.string("Relative Ziele brauchen eine gespeicherte Datei als Ausgangspunkt.")); continue }
                    do {
                        let url = try localPaths.resolve(candidate)
                        var info = stat()
                        guard stat(url.path, &info) == 0 else {
                            if errno == ENOENT || errno == ENOTDIR { add(.missing, L10n.string("Die lokale Zieldatei fehlt.")) }
                            else { add(.unverified, L10n.string("Das lokale Ziel konnte nicht gelesen werden.")) }
                            continue
                        }
                        guard (try url.resourceValues(forKeys: [.volumeIsLocalKey])).volumeIsLocal == true else { throw CocoaError(.fileReadUnsupportedScheme) }
                        guard info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR else { add(.unverified, L10n.string("Das Ziel ist keine normale Datei und kein Ordner.")); continue }
                        guard let anchor, !anchor.isEmpty else { add(.valid, L10n.string("Das lokale Ziel ist vorhanden.")); continue }
                        let key = pathKey(url)
                        let known = parsedByPath[key] ?? parsedByIdentity[FileIdentity(stat: info)]
                        guard known != nil || MarkdownReferences.markdownExtensions.contains(url.pathExtension.lowercased()), info.st_mode & S_IFMT == S_IFREG else { add(.unverified, L10n.string("Anker werden nur in Markdown-Dateien geprüft.")); continue }
                        let parsed: MarkdownReferences.Parsed
                        if let cached = known { parsed = cached }
                        else {
                            guard parsedFiles < options.maximumFiles else {
                                add(.unverified, L10n.string("Die Grenze der Markdown-Dateien wurde erreicht.")); continue
                            }
                            parsed = try parseSource(readSource(url)); parsedByPath[key] = parsed
                        }
                        checkAnchor(anchor, parsed: parsed, add: add)
                    } catch is CancellationError { throw CancellationError() }
                    catch { add(.unverified, L10n.format("Das lokale Ziel konnte nicht geprüft werden: %@", explanation(error))) }
                }
                if count.isMultiple(of: 50) { publishProgress(files: report.sources.count, references: count, title: source.title) }
            }
        }
        try cancelled()
        report.readBytes = readBytes; report.completedAt = Date()
        return report
    }

    private static func checkAnchor(_ anchor: String?, parsed: MarkdownReferences.Parsed?, add: (Status, String) -> Void) {
        guard let anchor, !anchor.isEmpty else { add(.valid, L10n.string("Das lokale Ziel ist vorhanden.")); return }
        guard let parsed else { add(.unverified, L10n.string("Die Zielquelle konnte nicht geprüft werden.")); return }
        guard !parsed.unsupportedHTML else { add(.unverified, L10n.string("Nicht unterstütztes HTML verhindert eine vollständige Ankerprüfung.")); return }
        guard parsed.anchorsComplete else { add(.unverified, L10n.string("Die Ankerliste ist unvollständig.")); return }
        let count = parsed.anchors[anchor] ?? 0
        if count > 1 { add(.ambiguous, L10n.string("Mehrere Überschriften oder HTML-Ziele verwenden diesen Anker.")) }
        else if count == 1 { add(.valid, L10n.string("Der lokale Anker ist vorhanden.")) }
        else { add(.missing, L10n.string("Der lokale Anker fehlt.")) }
    }

    private static func explanation(_ error: Error) -> String {
        if let error = error as? FileSnapshotReadError {
            switch error {
            case .tooLarge: return L10n.string("Die Quelle überschreitet die Datei- oder Lesebudgetgrenze.")
            case .changedDuringRead: return L10n.string("Die Quelle wurde während des Lesens geändert.")
            case .notRegularFile: return L10n.string("Die Quelle ist keine normale Datei.")
            }
        }
        if let error = error as? CocoaError, error.code == .fileReadUnsupportedScheme {
            return L10n.string("Nur Ziele auf lokalen Datenträgern werden geprüft.")
        }
        if let error = error as? CocoaError, error.code == .fileReadTooLarge {
            return L10n.string("Die Quelle enthält mehr als 200.000 Zeilenumbruchzeichen.")
        }
        if let error = error as? RipgrepFileEnumerator.Failure {
            switch error {
            case .unavailable: return L10n.string("Das Werkzeug für die Projektdateiliste ist nicht verfügbar.")
            case .timedOut: return L10n.string("Die Projektdateiliste konnte nicht rechtzeitig gelesen werden.")
            case .outputLimit: return L10n.string("Die Projektdateiliste überschreitet die Speichergrenze.")
            case .failed(let details), .captureFailed(let details): return details
            case .cancelled: return L10n.string("Abgebrochen – Ergebnis unvollständig.")
            }
        }
        return error.localizedDescription
    }
}
