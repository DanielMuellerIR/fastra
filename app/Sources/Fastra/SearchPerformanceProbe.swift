import Foundation
import CryptoKit
import Darwin

/// Ein fensterloser Messlauf pro Prozess. Eingaben werden nur gelesen;
/// Zeitmessung und Speichermaximum enden vor der Ergebnis-Prüfsumme.
enum SearchPerformanceProbe {
    struct Configuration: Decodable {
        let root: String
        let pattern: String
        let exclusions: [String]
        let limit: Int
    }

    /// Fehlende Aufrufparameter, benannt statt als „Datei fehlt" getarnt.
    struct ConfigurationError: LocalizedError {
        let missing: [String]
        var errorDescription: String? {
            "Umgebungsvariable(n) nicht gesetzt: " + missing.joined(separator: ", ")
                + " — FASTRA_SEARCH_PERF_INPUT zeigt auf die JSON-Konfiguration, "
                + "FASTRA_SEARCH_PERF_OUTPUT auf die Ergebnisdatei."
        }
    }

    static func run() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let missing = ["FASTRA_SEARCH_PERF_INPUT", "FASTRA_SEARCH_PERF_OUTPUT"]
            .filter { environment[$0] == nil }
        guard missing.isEmpty,
              let input = environment["FASTRA_SEARCH_PERF_INPUT"],
              let output = environment["FASTRA_SEARCH_PERF_OUTPUT"] else {
            throw ConfigurationError(missing: missing)
        }
        let configuration = try JSONDecoder().decode(Configuration.self,
            from: Data(contentsOf: URL(fileURLWithPath: input)))
        let root = URL(fileURLWithPath: configuration.root)
        let plan = try SearchPlan(options: SearchOptions(
            find: configuration.pattern, replace: "", isRegex: true))
        var before = rusage()
        getrusage(RUSAGE_SELF, &before)
        let diagnostics = FolderSearch.Diagnostics()
        let result = FolderSearch.find(in: [root], filter: .all, plan: plan,
            excludedPatterns: configuration.exclusions, relativeTo: root,
            maxTotalMatches: configuration.limit, diagnostics: diagnostics)
        let total = ProcessInfo.processInfo.systemUptime - diagnostics.started
        var parent = rusage()
        var children = rusage()
        getrusage(RUSAGE_SELF, &parent)
        getrusage(RUSAGE_CHILDREN, &children)
        // UUIDs sind Anzeigeidentitäten und gehören nicht in den Vergleich.
        let records: [[String: Any]] = result.perFile.map { file in
            ["path": String(file.url.path.dropFirst(root.path.count)),
             "count": file.totalMatches,
             "skipped": file.skipped.map { String(describing: $0) } ?? "",
             "matches": file.matches.map { match -> [String: Any] in
                ["offset": match.range.location, "length": match.range.length,
                 "line": match.line, "column": match.column,
                 "text": match.matchText, "replacement": match.replacedText,
                 "remainder": match.lineRemainder]
             }]
        }
        func digest(_ value: Any) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        var report: [String: Any] = [
            "total_ms": total * 1000,
            "enumeration_ms": diagnostics.enumerationSeconds * 1000,
            "file_search_ms": diagnostics.fileSearchSeconds * 1000,
            "first_file_ms": diagnostics.firstFileSearchSeconds.map { $0 * 1000 } as Any? ?? NSNull(),
            "candidates": diagnostics.candidateCount,
            "searched_files": diagnostics.searchedFiles,
            "matches": result.totalMatches,
            "materialized": result.perFile.reduce(0) { $0 + $1.matches.count },
            "capped": result.wasCapped,
            "rss_before_bytes": before.ru_maxrss,
            "parent_peak_bytes": parent.ru_maxrss,
            "child_peak_bytes": children.ru_maxrss,
            "ordered_digest": try digest(records),
            "sorted_digest": try digest(records.sorted {
                ($0["path"] as! String) < ($1["path"] as! String)
            })
        ]
        report["error"] = result.invalidPatternMessage as Any? ?? NSNull()
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
        if let error = result.invalidPatternMessage {
            throw NSError(domain: "Fastra.SearchPerformance", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: error])
        }
        return "Ordnersuche gemessen"
    }
}
